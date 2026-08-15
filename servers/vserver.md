# Server: vserver

**Last verified: 2026-08-15**

One small Linux VPS. It builds and runs every application, terminates TLS, and
holds every secret. There is exactly one of these; when a second server exists,
it gets its own document rather than a branch in this one.

```sh
ssh deploy@vserver 'docker compose ls'    # what is running, per application
```

## Reaching it

The name comes from your own `/etc/hosts`, not from DNS and not from a Makefile:

```
203.0.113.10    vserver
```

One line changes when the address does. SSH is key-only:

- The `deploy` account has a password of no kind, and no sudo rights.
- Password authentication MUST be off in `sshd_config`.
- Your private key stays on your machine, protected by a passphrase.

**Membership in the `docker` group is root on this host.** Anyone who reaches
the Docker socket can start a container that mounts `/`. A leaked deploy key is
a compromised host — rotate it, do not reason about blast radius.

## What is installed

| Software | Why | Notes |
|---|---|---|
| Docker Engine + Compose plugin | Builds and runs everything | From Docker's own repository, never the distribution package — the distro ships an old Engine and often no Compose plugin at all. Follow https://docs.docker.com/engine/install/ for the distribution. Versions in [VERSIONS.md](../VERSIONS.md). |
| nothing else | — | No Caddy on the host, no Go toolchain, no nginx, no certbot. Caddy runs as a container inside each application's stack; Go runs inside the build stage. A package installed on the host is a package that drifts. |

Portainer MAY be installed for a read-only look at what is running. If it is:
publish it to `127.0.0.1` only and reach it through an SSH tunnel
(`ssh -L 9443:127.0.0.1:9443 deploy@vserver`). It mounts the Docker socket,
which is root — never expose one to the internet.

## Ports

| Port | Who | Public |
|---|---|---|
| 22 | sshd, key-only | yes |
| 80 | the Caddy container: ACME challenge + redirect to HTTPS | yes |
| 443 (tcp + udp) | the Caddy container: TLS, HTTP/3 | yes |
| everything else | — | no |

**Docker writes its own iptables rules, so a published port is public even
behind a firewall that says otherwise.** A `ufw` rule does not stop it. That is
why no application publishes a port: only Caddy has a `ports:` block, and it is
meant to be public.

## Directory layout

One directory per application, named after its repository, owned by `deploy`:

```
/opt/<app>/
├── Caddyfile         ← from the repository; overwritten by every deploy
├── compose.yaml      ← from the repository; overwritten by every deploy
├── .env              ← one line: IMAGE_TAG=v1.2.3; written by every deploy
├── litestream.yml    ← only with the backup sidecar; 0400, holds S3 credentials
├── secrets/          ← 0400 secret files, owned by 10001
├── site.env          ← one line: DOMAIN=example.com
└── src/              ← the extracted repository; the build context
```

**Two kinds of file, and the difference is the whole discipline.** The deploy
owns `Caddyfile`, `compose.yaml`, `.env`, and `src/` — it overwrites them every
time, and deletes `src/` first, so a file deleted from the repository is gone
from the server too. The server owns `site.env`, `secrets/`, and
`litestream.yml` — they say what is true about *this* machine, no deploy reads
or writes them, and they survive every release.

## Secrets

Every credential is a file on this machine and nowhere else: not in git, not in
an image, not in a tarball, not in a Compose `environment:` block —
`docker inspect` prints that, and every child process inherits it.

- Mode `0400`, owned by UID `10001`, the UID every application container runs as.
- Compose mounts them read-only at `/run/secrets/<name>`, and sets
  `CREDENTIALS_DIRECTORY=/run/secrets` so the application finds them there. That
  variable is the contract; the path is this server's answer to it.

## Disk

Two things grow without asking: images and logs.

- **Images.** Every deploy builds a new one and the old ones stay, which is what
  makes rollback instant. Delete them by tag when the disk gets tight, oldest
  first. Never `docker image prune -a` — it removes the tagged images rollback
  depends on. `docker image prune` (no `-a`) removes only dangling layers and is
  safe.
- **Logs.** Docker's default `json-file` driver rotates nothing, which is why
  every service in the template sets `max-size` and `max-file`. A service
  without that block will fill this disk eventually.
