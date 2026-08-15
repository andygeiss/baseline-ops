# Pinned Versions

**Last verified: 2026-08-15.** These are the versions [vserver](servers/vserver.md)
runs. If your training data disagrees, this file wins. Verify against the source
links when updating it.

Application dependencies — Go, htmx, scs, GitHub Actions — are not here. They
live in the engineering baseline's own `VERSIONS.md`, because they change the
code rather than the server.

| Component | Pinned version | Released | Notes |
|---|---|---|---|
| `alpine` base image | **3.24** | 2026-06-16 | Runtime stage of every application image. Minor tag: patches arrive, surprises do not. |
| Caddy image | **2.11-alpine** | 2.11.4, 2026-06-03 | TLS termination, automatic certificates and renewal, compression, HTTP/3. One per application stack, or one shared instance once a second app exists. |
| Docker Compose | **v5.4.0** | 2026-08-03 | The `docker compose` plugin, not the retired `docker-compose` script. Ships with the Engine install. |
| Docker Engine | **29.7.2** | 2026-08-05 | On the server only — it builds and runs everything. Install from Docker's own repository, never the distribution package. |
| `golang` base image | **1.26-alpine** | 2026-08-13 | Build stage only. Minor tag, so it follows the baseline's Go patch pin without a second place to update. Ships **no git**, which the build stage installs — the version stamp depends on it. |
| Litestream image | **0.5** | 0.5.16, 2026-08-05 | Opt-in backup sidecar — see [runbooks/restore.md](runbooks/restore.md). |
| Portainer CE | **2.39.6** | 2026-08-12 | Optional, and the LTS line. 2.44.x is the STS (short-term) line — newer, but this server wants current-stable. Publish to `127.0.0.1` only. |

## Version policy

- **Third-party images are pinned to their minor tag** (`caddy:2.11-alpine`,
  `alpine:3.24`), so security patches arrive without a new major landing
  unannounced. Re-verify quarterly, and after any published container CVE.
- **An application's own image is tagged with the exact version `git describe`
  produces.** `:latest` MUST NOT appear anywhere: a tag that moves makes "what is
  running?" unanswerable and rollback impossible.
- **Docker Engine follows the current stable release.** It is the one piece of
  software installed on the host, so it is also the one that must never be a
  surprise: read the release notes before bumping a major.
- **A version bump is a deploy.** Editing a template here changes nothing until
  each application is redeployed — [runbooks/deploy.md](runbooks/deploy.md).

## Sources checked (2026-08-15)

- Docker Engine: https://docs.docker.com/engine/release-notes/29/
- Docker Compose: https://github.com/docker/compose/releases
- Caddy: https://github.com/caddyserver/caddy/releases and
  https://hub.docker.com/_/caddy
- Base images: https://hub.docker.com/_/golang and https://hub.docker.com/_/alpine —
  the `apk add` lines in https://github.com/docker-library/golang are what say
  which tools the build stage actually has
- Litestream: https://github.com/benbjohnson/litestream/releases and
  https://hub.docker.com/r/litestream/litestream/tags
- Portainer: https://hub.docker.com/r/portainer/portainer-ce/tags — the `lts` and
  `sts` tags name the two lines; read the version behind `lts`, do not deploy the
  moving tag
