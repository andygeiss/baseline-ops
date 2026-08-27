# Server: vserver

**Last verified: 2026-08-27**

One small Linux VPS. It builds and runs every application, terminates TLS, and
holds every secret. There is exactly one of these; when a second server exists,
it gets its own document rather than a branch in this one.

```sh
ssh andygeiss@vserver 'docker compose ls'    # what is running, per application
ssh andygeiss@vserver 'ls /opt/caddy/sites'  # what the proxy serves, one file per site
```

## Reaching it

The name comes from your own `/etc/hosts`, not from DNS and not from a Makefile:

```
203.0.113.10    vserver
```

One line changes when the address does. SSH is key-only:

- `andygeiss` is the deploy account. It is in the `docker` group and in
  `sudo`; sudo asks for its password, and that password never works over SSH.
- Password authentication MUST be off in `sshd_config`.
- Your private key stays on your machine, protected by a passphrase.

**Membership in the `docker` group is root on this host.** Anyone who reaches
the Docker socket can start a container that mounts `/`. A leaked deploy key is
a compromised host — rotate it, do not reason about blast radius.

## Tunnels from the house

The house network has no public address (a CGNAT WAN), so this server cannot
open a connection to a machine in it. A house machine opens one instead, with
`ssh -R`, and carries its service in: the application's Makefile owns that
command, because the application knows which service and which port.

The server's part is one sshd drop-in, `/etc/ssh/sshd_config.d/10-tunnel.conf`,
which `make sshd-tunnel` in this repository writes:

```
GatewayPorts clientspecified    # the client may bind docker0, not just loopback
ClientAliveInterval 30          # a dead link is noticed within 90 s …
ClientAliveCountMax 3           # … and the port freed for the reconnect
```

The tunnel MUST bind `172.17.0.1` — the `docker0` address — and nothing else.
A container cannot reach the host's loopback, so `127.0.0.1` is useless to it;
`0.0.0.0` would publish the house service to the internet, and the services
carried in this way send no API key. `172.17.0.1` is reachable by every
container on this host and by nothing outside it. Ports below 10000 are taken
or reserved; a tunnel uses 18000 and up.

## What is installed

| Software | Why | Notes |
|---|---|---|
| Docker Engine + Compose plugin | Builds and runs everything | From Docker's own repository, never the distribution package — the distro ships an old Engine and often no Compose plugin at all. Follow https://docs.docker.com/engine/install/ for the distribution. Versions in [VERSIONS.md](../VERSIONS.md). |
| The proxy | One Caddy container fronts every application | Runs from `/opt/caddy`, deployed from this repository's `caddy/` — [runbooks/caddy.md](../runbooks/caddy.md). It is the only stack with a `ports:` block. |
| nothing else | — | No Caddy on the host, no Go toolchain, no nginx, no certbot. Caddy is a container; Go runs inside the build stage. A package installed on the host is a package that drifts. |

Portainer MAY be installed for a read-only look at what is running. If it is:
publish it to `127.0.0.1` only and reach it through an SSH tunnel
(`ssh -L 9443:127.0.0.1:9443 andygeiss@vserver`). It mounts the Docker socket,
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

## The `web` network

One Docker network, `web`, created once by hand. The proxy is on it, and so is
every application, each under an alias equal to its repository name — the name
the proxy's site file uses in `reverse_proxy todo:8080`. An application on
`web` needs no `ports:` block; the proxy reaches it by name, and the internet
cannot.

**Every container on `web` can reach every other on `:8080`.** The deployment
contract says the app trusts `X-Forwarded-*` "because nothing else can reach
it"; on this host that means nothing *outside the host*. One person's own
applications share the network, and that is the whole reason a container that
is not one of them — a third party's image, a tool someone tries out — MUST
NOT join `web`. It gets its own network, or it does not run here.

## Directory layout

One directory per application, named after its repository, owned by
`andygeiss`:

```
/opt/<app>/
├── compose.yaml      ← from the repository; overwritten by every deploy
├── .env              ← one line: IMAGE_TAG=v1.2.3; written by every deploy
├── litestream.yml    ← only with the backup sidecar; 0400, holds S3 credentials
├── secrets/          ← 0400 secret files, owned by 10001
├── site.env          ← optional: KEY=value settings true of this server, not secret
└── src/              ← the extracted repository; the build context
```

**Two kinds of file, and the difference is the whole discipline.** The deploy
owns `compose.yaml`, `.env`, and `src/` — it overwrites them every time, and
deletes `src/` first, so a file deleted from the repository is gone from the
server too. The server owns `site.env`, `secrets/`, and `litestream.yml` — they
say what is true about *this* machine, no deploy reads or writes them, and they
survive every release.

The proxy has a directory of its own, not owned by any application:

```
/opt/caddy/
├── Caddyfile         ← from this repository's caddy/; overwritten by every proxy upgrade
├── compose.yaml      ← from this repository's caddy/; overwritten by every proxy upgrade
└── sites/            ← one <app>.caddy per application: its domain and its alias; server-owned
```

Its certificates live in the named volume `caddy_caddy_data`, which no deploy
touches. Where a site's domain is written down is `sites/`, and nowhere else: an
application repository names no domain, which is what lets one repository serve
two servers.

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
