# Server: vserver

**Last verified: 2026-09-13**

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
owns the one such tunnel there is. The WireGuard tunnel in "The house's way
out" is another kind: it carries the house's own traffic out to the internet,
and opens no way in to a device in the house.

The server's part is one sshd drop-in, `/etc/ssh/sshd_config.d/10-tunnel.conf`,
which `make sshd-tunnel` in this repository writes:

```
GatewayPorts clientspecified    # the client may bind docker0, not just loopback
ClientAliveInterval 30          # a dead link is noticed within 90 s …
ClientAliveCountMax 3           # … and the port freed for the reconnect
AllowStreamLocalForwarding no   # no key forwards a Unix socket
```

The tunnel MUST bind `172.17.0.1` — the `docker0` address — and nothing else.
A container cannot reach the host's loopback, so `127.0.0.1` is useless to it;
`0.0.0.0` would publish the house service to the internet with nothing in front
of it. `172.17.0.1` is reachable by every container on this host and by nothing
outside it. Ports below 10000 are taken or reserved; a tunnel uses 18000 and
up.

**The house machine's key may do one thing: bind that port.** oMLX runs on the
Mac Studio, and the tunnel's key there, `~/.ssh/omlx-tunnel`, has no
passphrase, because launchd uses it with nobody at the keyboard. So its line in
`~andygeiss/.ssh/authorized_keys` takes everything else away:

```
from="10.77.0.2",restrict,port-forwarding,permitlisten="172.17.0.1:18000",permitopen="127.0.0.1:9",command="/usr/bin/false" ssh-ed25519 … omlx-tunnel@AndysMacStudio
```

- `restrict` takes everything away, and `port-forwarding` gives forwarding
  back. `permitlisten` narrows `-R` to the one port, and `permitopen` sends
  `-L` to port 9, where nothing listens.
- `command` runs `false` in place of anything the key asks to run.
- `from` takes the key only from `10.77.0.2`, the house's end of wg0. The
  Studio reaches this server through "The house's way out" and no other way,
  so a copy of the key is no use outside the house.

`port-forwarding` would also give back forwarding a Unix socket, and no option
in `authorized_keys` narrows that. So the drop-in turns it off for every key,
since 2026-10-18: `/var/run/docker.sock` is a Unix socket, and it is root.

The Studio finds this server through its own `~/.ssh/config`, not
`/etc/hosts`: `Host vserver` there names the address and the key. When the
address changes, that line changes too.

**The house machine stays on.** The Mac Studio does not sleep (`pmset -g` says
`sleep 0`), so a `502` from `omlx.ai-at-home.de` is worth chasing at any hour.
A minute at 04:00 can be this server rebooting. Otherwise one of two things is
down:

- **The house's way out.** The tunnel rides wg0 and goes down with it. The
  launchd agent reopens it once wg0 is back.
- **The Studio itself.** After a power cut it stays off, because `autorestart`
  is off. After a restart it waits at the login window: oMLX is an app and the
  tunnel a launchd agent, and both start only when someone logs in.

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
`com.andygeiss.omlx-tunnel` — a launchd agent on the Mac Studio, written by
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
| wireguard-tools | The `wg` command: makes WireGuard keys, and shows the tunnel | From Ubuntu's archive, so unattended-upgrades patches it. The tunnel itself is the kernel's, and systemd-networkd brings it up, so it runs no service of its own — "The house's way out". |
| nothing else | — | No Caddy on the host, no Go toolchain, no nginx, no certbot. Caddy is a container; Go runs inside the build stage. A package installed on the host is a package that drifts. |

Portainer is installed, for a look at what is running — its own stack in
`/opt/portainer`, from this repository's `portainer/`
([runbooks/portainer.md](../runbooks/portainer.md)). It mounts the Docker
socket, which is root, so whoever logs in to it is root on this host. That is
why only the house gets through to its login. It sits behind the proxy at
`https://portainer.ai-at-home.de`, and the proxy answers `403` to every
request that does not come from `10.77.0.2`, the house's end of wg0. A request
from `KNOPPERS` or the Mac Studio to this server rides wg0 like any other
("The house's way out"), so it comes from that address. Portainer also
publishes one port, `127.0.0.1:9443`, for the SSH-tunnel path
(`ssh -L 9443:127.0.0.1:9443 andygeiss@vserver`), the way in from anywhere
else. The password is long, and the socket itself is never published.

## Updates and the nightly reboot

unattended-upgrades installs Ubuntu's security updates every morning, at a
random minute between 06:00 and 07:00 server time (Europe/Berlin). Most of
them work at once. A kernel or libc fix does not: it waits for a reboot, and
`/run/reboot-required` says one is waiting. `make auto-reboot` writes two
settings to `/etc/apt/apt.conf.d/52auto-reboot`, so the morning run that finds
one waiting reboots the server at the next 04:00:

```
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

04:00 is after the hour that daylight saving time skips or repeats, and an
hour nobody uses the sites. On a night a reboot waits, every site is gone for
a minute, and nothing announces it. Every container comes back by itself,
because each one says `restart: unless-stopped`, and the house machine's
launchd agent reopens its tunnel. The reboot on 2026-10-18 showed all of it:
ssh answered 33 seconds after the command, and every container, `docker0`, and
the tunnel were back without help.

Before `make auto-reboot` ran on 2026-10-18, nothing rebooted the server: it
ran kernel 7.0.0-30 for 52 days while -31, -34 and -38 were installed and
waited. [runbooks/host.md](../runbooks/host.md) is the same
job by hand: in a version pass, or for a fix that should not wait for 04:00.

## Ports

| Port | Who | Public |
|---|---|---|
| 22 | sshd, key-only | yes |
| 80 | the Caddy container: ACME challenge + redirect to HTTPS | yes |
| 443 (tcp + udp) | the Caddy container: TLS, HTTP/3 | yes |
| 51820 (udp) | WireGuard, wg0: the house's tunnel — "The house's way out" | yes |
| everything else | — | no |

**Docker writes its own iptables rules, so a published port is public even
behind a firewall that says otherwise.** A `ufw` rule does not stop it. That is
why no application publishes a port: only Caddy has a `ports:` block, and it is
meant to be public.

### Limits on what one address may open

**Not installed yet, as of 2026-09-08.** The proxy's half of this defence is
live; these rules are not. `make conn-limits` in this repository is what changes
that.

Caddy can refuse a request, but only the kernel can refuse a connection. By the
time Caddy sees anything the socket is accepted and the TLS handshake is paid
for, and the handshake is the expensive part. So a flood is capped twice: at the
proxy, which answers a request carrying no bearer token itself
([runbooks/caddy.md](../runbooks/caddy.md), "A site for a tunnelled service"),
and here.

`DOCKER-USER` is the chain the rules go in. Docker jumps to it from `FORWARD`
before reaching its own rules, which is exactly what the `ufw` rule above does
not do:

```sh
ssh root@vserver 'iptables -S FORWARD'
-P FORWARD DROP
-A FORWARD -j DOCKER-USER       # ← whatever is here is read first
-A FORWARD -j DOCKER-FORWARD    # ← Docker's own published ports
```

Four rules, two per address family, and [conn-limits](conn-limits) holds them.
One caps how many connections a single address may hold open at once — 64,
`REJECT` with a reset, so a client that hits the cap learns at once instead of
waiting for a timeout. The other caps how fast it may open new ones — 30 a
second, bursting to 60, `DROP`, because answering a flood is work.

**Every rule counts only what arrives on `eth0`.** The house's traffic crosses
`DOCKER-USER` too, on its way out through wg0 ("The house's way out"), and there
the whole house is one address. Counted with the internet's, it would pass 64
open connections on an ordinary evening, and its pages would load half. The cap
also counts only a SYN, a new connection: `connlimit` matches every packet of
an address over the cap, so without `--syn` the reset would cut the
connections that address already has as well.

The IPv6 mask is 64 rather than 128, because a /64 is the smallest block that
means one customer: counting per single address counts nothing when whoever
floods this server was handed 2^64 of them. Only IPv4 carries traffic today —
the sites have no AAAA record — and the v6 rules are there for the DNS edit that
changes that.

**The rules are gone after a reboot, and nothing announces it.**
`iptables-persistent` is a package on the host, which is the thing this machine
does not do, so a systemd unit runs the script instead. `make conn-limits` ships
both, and the unit runs after Docker, because Docker is what creates the chain.

**Check the chain is there before trusting any of this.** `iptables -S
DOCKER-USER` MUST print a chain — the script refuses to run when it does not. If
it prints nothing, this Engine runs its nftables backend, the chain answers to
another name, and every rule above would go where nothing reads it. Engine
29.9.1 here still uses the iptables backend, and both `xt_connlimit` and
`xt_hashlimit` load (checked 2026-10-18).

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

## The house's way out

A device on the house's `KNOPPERS` network reaches the internet through this
server, so every site it talks to sees this server's address instead of the
house's. That is every device on the `KNOPPERS` WLAN, and the Mac Studio, which
is on the network by cable. The house's gateway, a UniFi, opens a WireGuard
tunnel to UDP 51820 and routes that one network into it. This server lets the
traffic out by `eth0`, under its own address.

```
device on KNOPPERS ─► UniFi ══ WireGuard ══► wg0 ─► eth0 ─► the internet
                      10.77.0.2              10.77.0.1      under this server's address
```

`make wg-exit` in this repository sets up this side, once. `make wg-house`
gives the gateway a key, and saves the file its VPN client reads on your
machine, as `~/Downloads/vserver-wireguard.conf`. Upload it, then delete it:
whoever holds that file can send anything through this server, under this
server's address.

```sh
ssh root@vserver 'wg show wg0'    # "latest handshake" under 3 minutes ago: the house is connected
```

**No device in the house is reachable from here**, and "Tunnels from the
house" depends on that. wg0 knows one address in the house, the gateway's own,
`10.77.0.2`. WireGuard sends a packet into the tunnel only to an address the
peer's `AllowedIPs` names, and lets one out of it only from such an address, so
the gateway puts its own address on everything it sends — UniFi's VPN client
does, because a VPN provider demands the same. No container reaches even that
one address: Docker lets every container connect anywhere, so a rule drops
whatever enters wg0 that is not an answer.

### Three things the kernel needs

[wg-exit](wg-exit) holds the rules, and `wg-exit.service` runs it after Docker,
for the same reason as conn-limits: the rules are gone after a reboot, and
Docker creates the chain.

- **Forwarding.** Docker sets `FORWARD`'s policy to `DROP`, so a packet from the
  house dies here unless `DOCKER-USER` accepts it.
- **This server's address.** `MASQUERADE` on `eth0` puts it in place of
  `10.77.0.2`, so the answers come back here.
- **Smaller packets.** WireGuard takes 60 bytes of every packet, and the house's
  line may not carry a full 1500 to begin with, so wg0's MTU is 1380. TCP learns
  the size only from the MSS in a SYN, so the rules set it to 1340 for every
  connection through wg0. Without that, a page hangs half loaded.

### Where it lives

| What | Where |
|---|---|
| wg0 | `/etc/systemd/network/50-wg0.netdev` and `50-wg0.network`. systemd-networkd brings it up, as it does `eth0`. |
| This server's key | `/etc/systemd/network/wg0.key`, `root:systemd-network`, `0640`, because networkd reads it as that group. It is made here and never leaves. |
| The gateway's public key | `/etc/systemd/network/50-wg0.netdev.d/house.conf`, written by `make wg-house`. |
| The rules | `/usr/local/sbin/wg-exit`, run by `wg-exit.service`. |
| Forwarding on | `/etc/sysctl.d/60-wg-exit.conf`. Docker turns it on as well; this does not count on that. |

**networkd never changes a netdev that already exists.** An edit to
`50-wg0.netdev` takes effect after `networkctl delete wg0` and `networkctl
reload`, which is how `make wg-house` brings in a new key.

**The gateway knows this server by its address, not by a name.** When the
address changes, run `make wg-house` again and upload the new file.

### What the gateway does

This server forwards whatever reaches wg0; the gateway decides what does. Four
of its settings decide whether anything goes round the tunnel:

- **`KNOPPERS` is a network of its own**, a VLAN with its own WLAN. A UniFi
  route picks a network or a device, never a WLAN's name. The Mac Studio is on
  it by cable: a "Virtual Network Override" for that one client puts it there,
  with the fixed address `192.168.69.40`.
- **A route sends `KNOPPERS` into the VPN client, with its kill switch on.**
  Without the kill switch, the network falls back to the house's line whenever
  the tunnel is down. One forum report says the switch did not hold with
  WireGuard, so test it after any change to the route: pause the VPN client,
  and a device on `KNOPPERS` must go offline.
- **DHCP on `KNOPPERS` hands out `9.9.9.9` as DNS.** With the gateway as its
  resolver, DNS would take the house's line, and the provider would see every
  name. On the main LAN a device does not even get to choose: the gateway
  answers every query to port 53 itself, whatever address it went to, and asks
  over the house's line. That is why the Studio joined `KNOPPERS` instead of
  only the route. In the route alone, its traffic took the tunnel and its
  lookups did not.
- **`KNOPPERS` has no IPv6.** The tunnel carries IPv4 only, so IPv6 would go
  round it.

### What it costs

- **`KNOPPERS` is no faster than this server**, and every connection makes the
  detour through netcup, a model download on the Studio included.
- **Sites see a data centre's address.** Streaming services and some banks block
  one, or ask more often. That is why `KNOPPERS` is a second WLAN, not the
  house's only one.
- **The sites' address is the house's now, too.** An abuse report about
  something done on `KNOPPERS` reaches netcup, and then you.
- **Root here sees where the house connects.** Whoever takes this server sees
  it too. Portainer's login would hand root over, so it answers only the house
  ("What is installed").
- **A reboot at 04:00** ("Updates and the nightly reboot") takes `KNOPPERS`
  offline for the same minute as the sites.
- **ssh from `KNOPPERS` rides the tunnel too.** sshd sees `10.77.0.2`, and a
  session that was open when a machine joined `KNOPPERS` hangs, because its
  address changed under it. The Studio's oMLX tunnel is such a session. When
  the Studio joined, its agent's log said `remote port forwarding failed` six
  times in a minute, until this server let go of the old session's port, and
  the tunnel was back within two minutes. When the tunnel is down, the kill
  switch keeps ssh out as well, and the oMLX tunnel with it: mend the tunnel
  from the house's other WLAN.

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

A static page is an application without a build, so its directory holds the
file instead of `src/`. None has run here since kimmich came off on
2026-10-18; the next one looks like this:

```
/opt/<page>/
├── .env              ← one line: STYLE_HASH=…; written by every deploy
├── Caddyfile         ← from the repository; overwritten by every deploy
├── compose.yaml      ← from the repository; overwritten by every deploy
└── site/index.html   ← the page; overwritten by every deploy
```

[runbooks/caddy.md](../runbooks/caddy.md), "A site for a static page", says
why it looks like this.

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

One credential belongs to the host rather than to an application: wg0's key,
`/etc/systemd/network/wg0.key`. It is mode `0640` and group `systemd-network`,
because networkd reads it as that group ("The house's way out").

## Disk

Two things grow without asking: images and logs.

- **Images.** Every deploy builds a new one and the old ones stay, which is what
  makes rollback instant. Each is named after its application, `<app>:<version>`,
  so one application's build can never replace another's image. Delete them by
  tag when the disk gets tight, oldest first. Never `docker image prune -a` — it
  removes the tagged images rollback depends on. `docker image prune` (no `-a`)
  removes only dangling layers and is safe.

  **Both applications moved on 2026-09-13**, by
  [runbooks/deploy.md](../runbooks/deploy.md), "Moving off the shared `app:`
  name", and `game` is the one still here: it holds its images from
  `game:v0.1.0` on. The ones from before the move were re-tagged by the
  project label Compose wrote on them, except `game:v0.1.1`, whose image
  carries none — it was rebuilt by hand from the game's tag during a recovery
  on 2026-09-11 — and was tagged by hand. Their old names, `app:v0.1.0` to
  `app:v0.2.7`, still point at the same images, so they cost no disk. A tag
  from before the move still ships a `compose.yaml` that names `app:`, which
  is the one way back onto the shared name: redeploying such a tag from
  source builds under it again. `lysk` came off the server on 2026-10-18, and
  its images and `app:` names went with it.
- **Logs.** Docker's default `json-file` driver rotates nothing, which is why
  every service in the template sets `max-size` and `max-file`. A service
  without that block will fill this disk eventually.
