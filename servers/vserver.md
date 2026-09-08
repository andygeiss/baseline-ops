# Server: vserver

**Last verified: 2026-09-08**

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
`ssh -R`, and carries its service in. The command belongs to the service being
carried rather than to whoever calls it — `make omlx-tunnel` in this repository
owns the one tunnel there is.

The server's part is one sshd drop-in, `/etc/ssh/sshd_config.d/10-tunnel.conf`,
which `make sshd-tunnel` in this repository writes:

```
GatewayPorts clientspecified    # the client may bind docker0, not just loopback
ClientAliveInterval 30          # a dead link is noticed within 90 s …
ClientAliveCountMax 3           # … and the port freed for the reconnect
```

The tunnel MUST bind `172.17.0.1` — the `docker0` address — and nothing else.
A container cannot reach the host's loopback, so `127.0.0.1` is useless to it;
`0.0.0.0` would publish the house service to the internet with nothing in front
of it. `172.17.0.1` is reachable by every container on this host and by nothing
outside it. Ports below 10000 are taken or reserved; a tunnel uses 18000 and
up.

### Publishing one through the proxy

A tunnelled service MAY also get a site on the proxy, so a caller outside the
house reaches it over HTTPS. `omlx.ai-at-home.de` is the first one —
[runbooks/caddy.md](../runbooks/caddy.md), "A site for a tunnelled service".
Two rules come with it, because the address stops being private:

- **The service MUST check a credential of its own.** The proxy holds none.
  Every container on this host can already reach the tunnel, and a site adds
  the internet to that list. The proxy does turn away a request that carries no
  bearer token at all, so a flood without one never crosses the tunnel — but
  that is a check on the shape of the header, and it can no more tell a real key
  from a made-up one than an open door can.
- **The `tunnel` snippet names the paths it publishes**, and answers `404` to
  the rest. A model host also serves an admin API that changes which models run.
  That one stays in the house.

Turn the credential on before the site file exists, not after. The proxy asks
Let's Encrypt for the certificate the moment it reads the site, every
certificate issued is written to a public log, and scanners read those logs.

**The tunnel belongs to the service, never to one of its callers.**
`com.andygeiss.omlx-tunnel` — a launchd agent on the house Mac, written by
`make omlx-tunnel` in this repository — is what opens it. It was
kai-orchestrator's until 2026-09-07. That application and `omlx.ai-at-home.de`
were both riding it by then, so removing the one would have taken the other
down: the tunnel moved here first, and the site never noticed. The application
was decommissioned the same day, which leaves the proxy site as the only caller
today. A container that wants the model host joins the tunnel rather than
owning it.

## What is installed

| Software | Why | Notes |
|---|---|---|
| Docker Engine + Compose plugin | Builds and runs everything | From Docker's own repository, never the distribution package — the distro ships an old Engine and often no Compose plugin at all. Follow https://docs.docker.com/engine/install/ for the distribution. Versions in [VERSIONS.md](../VERSIONS.md). |
| The proxy | One Caddy container fronts every application | Runs from `/opt/caddy`, deployed from this repository's `caddy/` — [runbooks/caddy.md](../runbooks/caddy.md). It is the only stack with a `ports:` block. |
| nothing else | — | No Caddy on the host, no Go toolchain, no nginx, no certbot. Caddy is a container; Go runs inside the build stage. A package installed on the host is a package that drifts. |

Portainer is installed, for a look at what is running — its own stack in
`/opt/portainer`, from this repository's `portainer/`
([runbooks/portainer.md](../runbooks/portainer.md)). It sits behind the proxy
at `https://portainer.ai-at-home.de` like every application, and publishes one
port, `127.0.0.1:9443`, for the SSH-tunnel path
(`ssh -L 9443:127.0.0.1:9443 andygeiss@vserver`). It mounts the Docker socket,
which is root — so its login is the only thing between the internet and root
on this host. The password is long, and the socket itself is never published.

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

### Limits on what one address may open

**Not installed yet, as of 2026-09-08.** The proxy's half of this defence is
live; these rules are not. Nothing in this section has run on this machine.

Caddy can refuse a request, but only the kernel can refuse a connection. By the
time Caddy sees anything the socket is accepted and the TLS handshake is paid
for, and the handshake is the expensive part. So a flood is capped twice: at the
proxy, which answers a request carrying no bearer token itself
([runbooks/caddy.md](../runbooks/caddy.md), "A site for a tunnelled service"),
and here.

`DOCKER-USER` is the chain to write it in. Docker jumps to it from `FORWARD`
before reaching its own rules, which is exactly what the `ufw` rule above does
not do:

```sh
ssh root@vserver 'iptables -S FORWARD'
-P FORWARD DROP
-A FORWARD -j DOCKER-USER       # ← whatever is here is read first
-A FORWARD -j DOCKER-FORWARD    # ← Docker's own published ports
```

Four rules go in it, so a script holds them. It is safe to run twice: `-C` asks
whether a rule is already there, and only a missing one is inserted.

```sh
ssh root@vserver 'cat > /usr/local/sbin/conn-limits' <<'SCRIPT'
#!/bin/sh
# Per-address limits on the one public port. Safe to run twice: -C asks whether
# the rule is already there, and only a missing one is inserted. Both families,
# because an AAAA record is one DNS edit away and the rules should be waiting
# when it lands.
set -eu

add()  { iptables  -C DOCKER-USER "$@" 2>/dev/null || iptables  -I DOCKER-USER "$@"; }
add6() { ip6tables -C DOCKER-USER "$@" 2>/dev/null || ip6tables -I DOCKER-USER "$@"; }

# How many connections one address may hold open at once. REJECT, not DROP: a
# client that hits the cap learns so at once instead of waiting for a timeout.
add  -p tcp --dport 443 -m connlimit --connlimit-above 64 --connlimit-mask 32 \
    -j REJECT --reject-with tcp-reset
add6 -p tcp --dport 443 -m connlimit --connlimit-above 64 --connlimit-mask 64 \
    -j REJECT --reject-with tcp-reset

# How fast it may open new ones. DROP here, because answering a flood is work.
add  -p tcp --dport 443 -m conntrack --ctstate NEW -m hashlimit \
    --hashlimit-name https --hashlimit-mode srcip \
    --hashlimit-above 30/sec --hashlimit-burst 60 -j DROP
add6 -p tcp --dport 443 -m conntrack --ctstate NEW -m hashlimit \
    --hashlimit-name https6 --hashlimit-mode srcip \
    --hashlimit-above 30/sec --hashlimit-burst 60 -j DROP
SCRIPT
```

The v6 mask is 64, not 128, because a /64 is the smallest block that means one
customer: counting per single address counts nothing when whoever floods this
server was handed 2^64 of them. Only IPv4 carries traffic today — the sites have
no AAAA record — and the rules are there for the DNS edit that changes that.

**The rules are gone after a reboot, and nothing announces it.**
`iptables-persistent` is a package on the host, which is the thing this machine
does not do. A systemd unit runs the script instead. It runs after Docker,
because Docker is what creates `DOCKER-USER`:

```sh
ssh root@vserver 'chmod 0755 /usr/local/sbin/conn-limits \
    && cat > /etc/systemd/system/conn-limits.service' <<'UNIT'
[Unit]
Description=Per-address connection limits on :443
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/conn-limits

[Install]
WantedBy=multi-user.target
UNIT

ssh root@vserver 'systemctl daemon-reload && systemctl enable --now conn-limits \
    && iptables -S DOCKER-USER && ip6tables -S DOCKER-USER'
```

**Check the chain is there before trusting any of this.** `iptables -S
DOCKER-USER` MUST print a chain. If it prints nothing, this Engine runs its
nftables backend, the chain answers to another name, and every rule above goes
where nothing reads it. Engine 29.8.0 here still uses the iptables backend, and
both `xt_connlimit` and `xt_hashlimit` load (checked 2026-09-08).

**conntrack carries weight once these rules exist.** `connlimit` counts entries
in it, and a full table drops every new connection on this host — including the
ssh you would fix it from. There is room already; the point is noticing if that
stops being true:

```sh
ssh andygeiss@vserver 'cat /proc/sys/net/netfilter/nf_conntrack_{count,max}'   # 30 of 262144
```

The sysctls that matter are mostly set. `net.ipv4.tcp_syncookies` is `1`, which
is the real answer to a SYN flood, and `net.core.somaxconn` is `4096`. One is
low: `net.ipv4.tcp_max_syn_backlog` is `512`, and `4096` in
`/etc/sysctl.d/99-net.conf` would give a burst somewhere to wait before the
kernel falls back to cookies. A small win, not a fix — syncookies keep this box
up without it.

**What these rules cannot do is count requests.** The kernel sees connections,
and HTTP/2 carries hundreds of requests on one of them. Someone who opens a
single socket walks past all four untouched. That is why the proxy's own check
is the first line and this is the second, and not the other way round.

One address misbehaving right now is one line, and one line to undo:

```sh
iptables -I DOCKER-USER -s 203.0.113.9 -j DROP    # -D in place of -I lets it back in
```

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
/opt/portainer/
└── compose.yaml      ← from this repository's portainer/; its data is the volume portainer_data
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
