# Runbook: Deploy a release

**Last verified: 2026-09-28**

Ship a tagged version of an application to [vserver](../servers/vserver.md), or
put an older one back. The server builds what it runs; nothing here needs Docker
on your machine, and no image passes through a registry.

Run every command from the application's checkout. `<app>` is the repository
name, which is also the Compose project name and the directory on the server.

**The application must already be set up on the server.** First time? Use
[new-app.md](new-app.md), then come back.

## Deploy

```sh
git tag v1.2.3 && git push origin main v1.2.3
~/workspace/baseline-ops/bin/deploy v1.2.3
```

From the application's checkout; the working tree may be on any commit, since
the script ships the tag, not the tree. It ends with `deploy: <app> runs
v1.2.3`, or says what failed and what runs instead. What it does, in order:

1. **Clones the tag** into a temporary directory. `.git` travels, and nothing
   that was never committed does — no `.env`, no database, no
   `.claude/settings.local.json`.
2. **Streams it over ssh** into `/opt/<app>/incoming/`, as a `.part` renamed
   once whole. No `scp`, and a stalled copy never looks complete.
3. **Extracts beside the tree, then swaps** `src.new` for `src`, keeping the
   old one as `src.old`. `compose.yaml` comes from the tag too.
4. **Builds with `--pull`** while the old container still serves. A failed
   build puts the old tree back and stops: nothing else changed.
5. **Snapshots the data volume**, cold: stops the app, tars the volume into
   `/opt/<app>/snapshots/<app>-<old version>-<time>.tgz`, keeps the five
   newest. The site is down for these seconds — the price of a copy the
   database and its WAL agree on.
6. **Starts the new image** with `up --no-build --wait`, then asks `/healthz`
   whether it names the new version.
7. **Rolls back by itself** when it does not: the old image starts again. The
   data stays as the new version left it — see *Putting the snapshot back*.
8. **Appends one line** to `/opt/<app>/deploys.log`: when, what, what ran
   before, the outcome, the snapshot.

`DEPLOY_HOST` picks another server (`andygeiss@vserver` by default). One
deploy per application runs at a time; a second is refused.

Why each part is the way it is:

- **`.git` travels.** The toolchain reads it inside the build to stamp
  `info.Main.Version`. Without it there is nothing to stamp and nothing warns
  you: the canonical reader falls back to a per-boot id, so `/healthz` answers a
  different string after every restart and the immutable assets are
  re-downloaded with it. This is also why the source is a clone, not
  `git archive`.
- **A clone, not the working tree.** A tarball of the checkout carries
  whatever lies in it untracked — Lysk's shipped its agent's local settings
  from v0.11.0 on.
- **The build runs before anything stops.** A Dockerfile that breaks, a full
  disk, a network hiccup pulling base images — all of them leave the previous
  container running and healthy. A failed deploy is a deploy that did not
  happen.
- **`--no-build` on `up`.** The image was just built by the previous command;
  this flag makes sure `up` runs *that* image and never quietly builds another.
- **The snapshot is the way back from a migration, not a backup.** It sits on
  the same disk as the database. A backup is Litestream —
  [restore.md](restore.md).
- **`.env` is one line.** It is the deployment record: what is running, right
  now. Everything else lives in `compose.yaml`, which is committed, or in a
  secret file, which is not. The script reads what runs off the container,
  never off `.env`.
- **A script here, not a `make deploy` in the application**, which is where
  server knowledge does not belong.

### By hand

When the script cannot run, the same steps, one command each. **Copy before you
clear:** removing `src/` first and then losing the copy leaves an empty tree,
and the next build ships nothing — which happened.

```sh
VERSION=v1.2.3
rm -rf /tmp/<app> && git clone -q --no-checkout "file://$PWD" /tmp/<app> \
    && git -C /tmp/<app> checkout -q $VERSION
COPYFILE_DISABLE=1 tar --no-xattrs -czf /tmp/<app>-$VERSION.tgz -C /tmp/<app> .
scp /tmp/<app>-$VERSION.tgz andygeiss@vserver:/opt/<app>/
ssh andygeiss@vserver "cd /opt/<app> && rm -rf src.new && mkdir src.new \
    && tar xzf <app>-$VERSION.tgz -C src.new && rm -rf src.old \
    && { [ ! -d src ] || mv src src.old; } && mv src.new src \
    && cp src/compose.yaml . && rm <app>-$VERSION.tgz"
ssh andygeiss@vserver "cd /opt/<app> && IMAGE_TAG=$VERSION docker compose build --pull"
ssh andygeiss@vserver "cd /opt/<app> && echo IMAGE_TAG=$VERSION > .env \
    && docker compose up -d --no-build --wait"
ssh andygeiss@vserver 'cd /opt/<app> && docker compose exec -T app wget -qO- http://127.0.0.1:6060/healthz'
```

`COPYFILE_DISABLE=1` and `--no-xattrs` both address macOS: the first keeps the
`._*` resource-fork files out of the archive; the second keeps the extended
attributes out of the pax headers, which GNU tar on the server would otherwise
report line by line as it extracts.

## Roll back

```sh
~/workspace/baseline-ops/bin/deploy --rollback v1.2.2
```

By hand, the same thing:

```sh
ssh andygeiss@vserver 'cd /opt/<app> && echo IMAGE_TAG=v1.2.2 > .env \
    && docker compose up -d --no-build --wait'
```

It works because building never deletes anything: the previous image is still in
the server's image store as `<app>:v1.2.2`, under the application's own name and
its own tag. Graceful shutdown makes the swap invisible.

**`--no-build` is load-bearing here.** Without it, an image the server no longer
has is rebuilt from whatever sits in `src/` right now — which is the *new*
version wearing the *old* version's tag. With it, a missing image is an error —
the script checks first and says so — and the fix is to deploy that tag from
source again.

**A rollback moves the code, not the data.** If the version rolled back from
migrated the database, the older one now meets a newer schema. Most migrations
only add, and the older code does not notice; when it does, put the snapshot
back.

### Putting the snapshot back

A decision, never automatic: it throws away everything written since the
deploy. With the version the snapshot belongs to already running:

```sh
ssh andygeiss@vserver 'cd /opt/<app> && tail -3 deploys.log'   # which snapshot
ssh andygeiss@vserver 'cd /opt/<app> && docker compose stop app \
    && docker run --rm -v <app>_data:/data -v "$PWD/snapshots:/in:ro" alpine:3.24 \
       sh -c "find /data -mindepth 1 -delete && tar xzf /in/<snapshot>.tgz -C /data" \
    && docker compose up -d --no-build --wait'
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
| `required variable IMAGE_TAG is missing a value` | By hand: `.env` was not written | Write it, then `up` again |
| `deploy: the build failed; v1.2.2 still runs` | Everything that breaks a build — the Dockerfile, the disk, the network | Nothing to undo: the old tree is back, the old container never stopped. Fix, then deploy again |
| `deploy: v1.2.3 did not come up healthy; v1.2.2 runs again` | The new version failed its healthcheck, or `/healthz` named another version | `docker compose logs app`; the data is as the new version left it — *Putting the snapshot back* if that matters |
| `deploy: another deploy of <app> is running` | Two deploys at once | Wait for the other; the lock goes with its process |
| Build fails on `go mod download` | The server has no outbound network, or the module proxy is down | The old container is still running; retry later |
| Container restarts in a loop | The app failed at boot — usually configuration | `docker compose logs app`; the message is the app's own |
| `docker compose ps` says `unhealthy` | `/healthz` is failing: the database is unreachable or the app never bound its port | `docker compose logs app`; check the `data` volume exists |
| The version at `/healthz` changes on every restart | `.git` did not reach the build context, so the build carries no VCS metadata and the reader falls back to a per-boot id | Check `.dockerignore` keeps `.git`, and that the build stage installs `git`. The script refuses such a version: `/healthz` does not name the tag |
| Version reports `unknown` at `/healthz` | Not a deploy fault: the binary is using the CLI version reader, which anything serving `immutable` assets must not | The application's bug — baseline `patterns/go-performance.md` has the three-case reader it needs |
| A rollback says the image does not exist, while `docker images app` lists that version | The version was built while the template named every image `app:` | *Moving off the shared `app:` name* above; if the image is not this application's, deploy that tag from source |
| `502` from the proxy after a deploy | The app is not on the `web` network, or its alias changed | `compose.yaml` MUST carry the `networks:` block from the template, alias = `<app>`; [caddy.md](caddy.md) has the rest |
| Certificate errors after a deploy | Not this deploy's doing: an application never touches TLS | The proxy's own runbook, [caddy.md](caddy.md) |
