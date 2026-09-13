# Runbook: Deploy a release

**Last verified: 2026-09-13**

Ship a tagged version of an application to [vserver](../servers/vserver.md), or
put an older one back. The server builds what it runs; nothing here needs Docker
on your machine, and no image passes through a registry.

Run every command from the application's checkout. `<app>` is the repository
name, which is also the Compose project name and the directory on the server.

**The application must already be set up on the server.** First time? Use
[new-app.md](new-app.md), then come back.

## Deploy

```sh
# 1. Release: a clean tree and a tag. The tag becomes the image tag, and the
#    Go toolchain stamps the same commit into the binary.
git status --porcelain          # MUST print nothing
git tag v1.2.3
VERSION=$(git describe --tags --exact-match)

# 2. Pack the repository — .git included, secrets and local state excluded.
mkdir -p bin
COPYFILE_DISABLE=1 tar --no-xattrs -czf bin/<app>-$VERSION-src.tar.gz \
    --exclude=./bin --exclude=./.env --exclude='./*.db*' .

# 3. Copy it over, with the one file that describes the stack.
ssh andygeiss@vserver 'rm -rf /opt/<app>/src && mkdir -p /opt/<app>/src'
scp bin/<app>-$VERSION-src.tar.gz compose.yaml andygeiss@vserver:/opt/<app>/

# 4. Extract, and record what is about to run.
ssh andygeiss@vserver "cd /opt/<app> && tar xzf <app>-$VERSION-src.tar.gz -C src \
    && rm <app>-$VERSION-src.tar.gz && echo IMAGE_TAG=$VERSION > .env"

# 5. Build, then run exactly what was built.
ssh andygeiss@vserver 'cd /opt/<app> && docker compose build && docker compose up -d --no-build'

# 6. Check.
ssh andygeiss@vserver 'cd /opt/<app> && docker compose ps'
curl -sI https://example.com | head -1
```

Why each part is the way it is:

- **`.git` travels.** The toolchain reads it inside the build to stamp
  `info.Main.Version`. Without it there is nothing to stamp and nothing warns
  you: the canonical reader falls back to a per-boot id, so `/healthz` answers a
  different string after every restart and the immutable assets are
  re-downloaded with it. This is also why the tarball is not `git archive`.
- **`COPYFILE_DISABLE=1` and `--no-xattrs` both address macOS.** The first keeps
  the `._*` resource-fork files out of the archive; the second keeps the
  extended attributes (`com.apple.provenance` on every file) out of the pax
  headers, which GNU tar on the server would otherwise report line by line as
  it extracts. Neither changes what is in the archive.
- **The build runs before `up`.** A Dockerfile that breaks, a full disk, a
  network hiccup pulling base images — all of them leave the previous container
  running and healthy. A failed deploy is a deploy that did not happen.
- **`--no-build` on `up`.** The image was just built by the previous command;
  this flag makes sure `up` runs *that* image and never quietly builds another.
- **`.env` is one line.** It is the deployment record: what is running, right
  now. Everything else lives in `compose.yaml`, which is committed, or in a
  secret file, which is not.
- **Nothing is a script yet.** These steps have not run twice in anger. When
  they have, and unchanged, they become `bin/deploy <app> <version>` here — not
  a `make deploy` in the application, which is where server knowledge does not
  belong.

## Roll back

```sh
ssh andygeiss@vserver 'cd /opt/<app> && echo IMAGE_TAG=v1.2.2 > .env \
    && docker compose up -d --no-build'
```

It works because building never deletes anything: the previous image is still in
the server's image store as `<app>:v1.2.2`, under the application's own name and
its own tag. Graceful shutdown makes the swap invisible.

**`--no-build` is load-bearing here.** Without it, an image the server no longer
has is rebuilt from whatever sits in `src/` right now — which is the *new*
version wearing the *old* version's tag. With it, a missing image is an error,
and the fix is to deploy that tag from source again:

```sh
git checkout v1.2.2      # then the deploy steps above
```

## Moving off the shared `app:` name

Once, for an application deployed before 2026-09-13. Until then the template
named every application's image `app:<version>`, so the host holds that
application's earlier versions under `app:` and nothing under `<app>:`. The move
is three steps, and the version running never changes.

1. **In the application's repository**, bring the template's two changes into
   `compose.yaml` — the `image:` line with the comment above it, and the
   sentence the header gained — and commit. Only those: copying the whole
   template again undoes the application's own edits, such as the `secrets:`
   blocks an application without secrets deletes.
2. **Give the application's old images the new name**, keyed by the label
   Compose wrote on each:

   ```sh
   ssh andygeiss@vserver 'for t in $(docker images app --format "{{.Tag}}"); do
     [ "$(docker image inspect -f "{{index .Config.Labels \"com.docker.compose.project\"}}" app:$t)" = <app> ] \
       && docker tag app:$t <app>:$t; done; docker images <app>'
   ```

3. **Start the running version under its new name**, from the new
   `compose.yaml`:

   ```sh
   scp compose.yaml andygeiss@vserver:/opt/<app>/
   ssh andygeiss@vserver 'cd /opt/<app> && docker compose up -d --no-build && docker compose ps'
   ```

   `docker compose ps` names `<app>:<version>`, the version `.env` already
   held: the container is recreated from the same image under its new name,
   which proves step 2 now rather than during a rollback. The next deploy
   builds under the new name without being told.

- **The label decides whose an image is.** Compose writes the project's name
  onto every image it builds, so the loop takes this application's images and
  leaves every other application's alone.
- **An image built by hand has no label** — a `docker build -t app:v1.2.2`
  run to recover a lost tag, say — so the loop skips it. Tag it yourself, and
  only if you know whose it is.
- **A version two applications both built is the last one's.** The first
  build's image lost that tag the moment the second was built, and the label
  names whoever built it last.
- **`docker tag` only adds a name**, so the `app:` names can stay until no
  rollback needs them, and go by tag after that — never `docker image prune -a`.

## When it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `required variable IMAGE_TAG is missing a value` | `.env` was not written — step 4 failed | Re-run step 4, then step 5 |
| Build fails on `go mod download` | The server has no outbound network, or the module proxy is down | The old container is still running; retry later |
| Container restarts in a loop | The app failed at boot — usually configuration | `docker compose logs app`; the message is the app's own |
| `docker compose ps` says `unhealthy` | `/healthz` is failing: the database is unreachable or the app never bound its port | `docker compose logs app`; check the `data` volume exists |
| The version at `/healthz` changes on every restart | `.git` did not reach the build context, so the build carries no VCS metadata and the reader falls back to a per-boot id | Check the tarball's excludes and `.dockerignore`; `git` must also be installed in the build stage |
| Version reports `unknown` at `/healthz` | Not a deploy fault: the binary is using the CLI version reader, which anything serving `immutable` assets must not | The application's bug — baseline `patterns/go-performance.md` has the three-case reader it needs |
| A rollback says the image does not exist, while `docker images app` lists that version | The version was built while the template named every image `app:` | *Moving off the shared `app:` name* above; if the image is not this application's, deploy that tag from source |
| `502` from the proxy after a deploy | The app is not on the `web` network, or its alias changed | `compose.yaml` MUST carry the `networks:` block from the template, alias = `<app>`; [caddy.md](caddy.md) has the rest |
| Certificate errors after a deploy | Not this deploy's doing: an application never touches TLS | The proxy's own runbook, [caddy.md](caddy.md) |
