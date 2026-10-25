# Pinned Versions

**Last verified: 2026-10-18.** These are the versions [vserver](servers/vserver.md)
runs, and, in the second table, the ones the agent sandbox on your Mac runs. If
your training data disagrees, this file wins. Verify against the source links
when updating it.

Application dependencies — Go, htmx, scs — are not here. They
live in the engineering baseline's own `VERSIONS.md`, because they change the
code rather than the server.

| Component | Pinned version | Released | Notes |
|---|---|---|---|
| `alpine` base image | **3.24** | 3.24.2, 2026-09-17 | Runtime stage of every application image. Minor tag: patches arrive, surprises do not. |
| Caddy image | **2.11.7-alpine** | 2026-10-03 | TLS termination, automatic certificates and renewal, compression, HTTP/3. One instance, `/opt/caddy`, in front of every application; a bump is [runbooks/caddy.md](runbooks/caddy.md) "Upgrade", not one deploy per app. Never 2.11.6: it cut streamed answers off after a minute. |
| Docker Compose | **v5.6.0** | 2026-10-02 | The `docker compose` plugin, not the retired `docker-compose` script. Ships with the Engine install, so upgrading that package is what moves this row. |
| Docker Engine | **29.9.1** | 2026-10-14 | On the server only — it builds and runs everything. Install from Docker's own repository, never the distribution package. |
| `golang` base image | **1.27-alpine** | 1.27.3, 2026-10-19 | Build stage only. Minor tag, so it follows the baseline's Go patch pin without a second place to update. Ships **no git**, which the build stage installs — the version stamp depends on it. |
| Litestream image | **0.5** | 0.5.17, 2026-08-31 | Opt-in backup sidecar — see [runbooks/restore.md](runbooks/restore.md). |
| Portainer CE | **2.45.2** | 2026-10-08 | Optional, and the LTS line: 2.45 is the LTS that rolled up the 2.40–2.44 STS releases, supported to May 2027; 2.39 LTS ends Nov 2026. The next LTS, 3.3, is planned for December 2026: a new major. Behind the proxy, one loopback port — [runbooks/portainer.md](runbooks/portainer.md). |
| wireguard-tools | **1.0.20250521** | 2025-05-21 | On the server only: the `wg` command, for the house's tunnel — [servers/vserver.md](servers/vserver.md), "The house's way out". Ubuntu 26.04's own package, `-1ubuntu1`, so unattended-upgrades moves it, not an edit here. |

## The agent sandbox on the Mac you work on

**Last verified: 2026-10-25.** `make claude-sandbox` builds these into the
sandbox Claude Code runs in — [runbooks/claude-sandbox.md](runbooks/claude-sandbox.md).
None of them reaches the server.

| Component | Pinned version | Released | Notes |
|---|---|---|---|
| Claude Code | **2.1.310** | 2026-10-23 | `ARG CLAUDE_CODE_VERSION` in `claude-sandbox/Containerfile`. Exact, like the server's own stacks: what the agent can do changes only through an edit someone reads. The image never updates itself. |
| `golang` base image | **1.27-trixie** | 1.27.3, 2026-10-19 | The sandbox image. Debian, not alpine: the commands an agent writes assume GNU tools and glibc. Minor tag; `make claude-sandbox` builds with `--pull`, so Go's and Debian's patches arrive with the next run. |
| `node` base image | **24-trixie-slim** | 24.22.1, 2026-10-20 | The install stage only: npm picks Claude Code's native binary for the platform. Nothing of Node reaches the sandbox. |
| tinyproxy | Debian trixie's `tinyproxy-bin` | 1.11.2 | The proxy, from the same image. Debian's own package, so a rebuild with `--pull` moves it, not an edit here. |
| podman | not pinned | 6.1.4 | Homebrew's, on the Mac; the sandbox was verified with 6.1.4. It needs a rootless connection to the machine — `--userns keep-id` exists only there — and a machine that shares only `~/workspace`: 6.1.4's default shares all of `/Users`, and `~/.config/containers` read-write. |

## Version policy

- **A base image is pinned to its minor tag** (`alpine:3.24`,
  `golang:1.27-alpine`). Every deploy builds with `--pull`, so its security
  patches arrive with the next deploy, and a new major never lands
  unannounced.
- **The server's own stacks are pinned to the exact version**
  (`caddy:2.11.7-alpine`, and Portainer's). Nothing pulls them except their
  runbook's "Upgrade", so a minor tag buys no patches there. It only lets a
  `docker compose pull` take a release nobody read, and Caddy 2.11.6 put
  breaking changes into a patch release. On the exact tag, every move is an
  edit someone reads.
- **Litestream's `0.5` is the one case left open.** Nothing pulls a sidecar on
  its own either, but its tag lives in each application's `compose.yaml`, so
  an exact tag costs an edit in every one of them per release. No application
  runs it yet, and the first one to add it settles which tag it uses.
- **Re-verify quarterly**, and after any published container CVE.
- **An application's own image is tagged with the exact version `git describe`
  produces.** `:latest` MUST NOT appear anywhere: a tag that moves makes "what is
  running?" unanswerable and rollback impossible.
- **An application's own image is named after the application** —
  `<app>:<version>`, from the Compose project's name. Two applications MUST NOT
  build under one name: the second build to tag a version replaces the first's
  image, and a rollback then starts the wrong application.
- **Docker Engine follows the current stable release.** It is the one piece of
  software on the host from outside Ubuntu's archive, so it is also the one that
  must never be a surprise: read the release notes before bumping a major.
- **A version bump is a deploy.** Editing a template here changes nothing until
  each application is redeployed — [runbooks/deploy.md](runbooks/deploy.md).
  Editing `caddy/` changes nothing until the proxy is —
  [runbooks/caddy.md](runbooks/caddy.md).

## Sources checked (2026-10-18)

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
  moving tag. Which line is which, and until when:
  https://docs.portainer.io/start/lifecycle (checked 2026-10-18)
- wireguard-tools: `apt-cache policy wireguard-tools` on vserver, which names
  what Ubuntu's archive offers

## Sources checked for the sandbox (2026-10-25)

- Claude Code: https://www.npmjs.com/package/@anthropic-ai/claude-code — the
  registry's `time` field dates each release — and
  https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md
- Base images: https://hub.docker.com/_/golang and https://hub.docker.com/_/node;
  Node's release dates: https://nodejs.org/dist/index.json
- tinyproxy: https://packages.debian.org/trixie/tinyproxy-bin
- podman: `podman --version` on the Mac
