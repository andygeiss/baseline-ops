# Runbook: Deploy a release

**Last verified: 2026-08-15**

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
COPYFILE_DISABLE=1 tar czf bin/<app>-$VERSION-src.tar.gz \
    --exclude=./bin --exclude=./.env --exclude='./*.db*' .

# 3. Copy it over, with the two files that describe the stack.
ssh deploy@vserver 'rm -rf /opt/<app>/src && mkdir -p /opt/<app>/src'
scp bin/<app>-$VERSION-src.tar.gz compose.yaml Caddyfile deploy@vserver:/opt/<app>/

# 4. Extract, and record what is about to run.
ssh deploy@vserver "cd /opt/<app> && tar xzf <app>-$VERSION-src.tar.gz -C src \
    && rm <app>-$VERSION-src.tar.gz && echo IMAGE_TAG=$VERSION > .env"

# 5. Build, then run exactly what was built.
ssh deploy@vserver 'cd /opt/<app> && docker compose build && docker compose up -d --no-build'

# 6. Check.
ssh deploy@vserver 'cd /opt/<app> && docker compose ps'
curl -sI https://example.com | head -1
```

Why each part is the way it is:

- **`.git` travels.** The toolchain reads it inside the build to stamp
  `info.Main.Version`. Without it every binary reports `unknown` and nothing
  warns you. This is also why the tarball is not `git archive`.
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
ssh deploy@vserver 'cd /opt/<app> && echo IMAGE_TAG=v1.2.2 > .env \
    && docker compose up -d --no-build'
```

It works because building never deletes anything: the previous image is still in
the server's image store under its own tag. Graceful shutdown makes the swap
invisible.

**`--no-build` is load-bearing here.** Without it, an image the server no longer
has is rebuilt from whatever sits in `src/` right now — which is the *new*
version wearing the *old* version's tag. With it, a missing image is an error,
and the fix is to deploy that tag from source again:

```sh
git checkout v1.2.2      # then the deploy steps above
```

## When it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `required variable IMAGE_TAG is missing a value` | `.env` was not written — step 4 failed | Re-run step 4, then step 5 |
| Build fails on `go mod download` | The server has no outbound network, or the module proxy is down | The old container is still running; retry later |
| Container restarts in a loop | The app failed at boot — usually configuration | `docker compose logs app`; the message is the app's own |
| `docker compose ps` says `unhealthy` | `/healthz` is failing: the database is unreachable or the app never bound its port | `docker compose logs app`; check the `data` volume exists |
| Version reports `unknown` at `/healthz` | `.git` did not reach the build context | Check the tarball's excludes and `.dockerignore` |
| Certificate errors after a deploy | `caddy_data` was recreated | Confirm it is a named volume, not a path inside `src/` |
