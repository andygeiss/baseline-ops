# Runbook: Portainer

**Last verified: 2026-08-27**

Portainer is the optional look at what is running on
[vserver](../servers/vserver.md). It runs as its own stack from
`/opt/portainer`, and sits behind the proxy like every application. Only the
house gets through to it there: `https://portainer.ai-at-home.de` opens on
`KNOPPERS` and on the Mac Studio, and answers `403` to everyone else. From
anywhere else, an SSH tunnel is the way in.

Run every command from a checkout of this repository. The proxy must already be
running — [caddy.md](caddy.md).

## Install, once per server

```sh
# 1. The directory (root owns /opt) and the volume that holds the admin user.
ssh root@vserver 'mkdir -p /opt/portainer && chown andygeiss:andygeiss /opt/portainer'
ssh andygeiss@vserver 'docker volume create portainer_data'

# 2. The stack, from this repository.
scp portainer/compose.yaml andygeiss@vserver:/opt/portainer/

# 3. Start it.
ssh andygeiss@vserver 'cd /opt/portainer && docker compose up -d && docker compose ps'
```

A Portainer that was started by hand before this file existed is stopped and
removed first — `docker stop portainer && docker rm portainer` — and its
`portainer_data` volume is the one step 1 names, so the admin user survives.
`docker volume create` on a volume that exists does nothing, which is why the
step is safe to repeat.

## Put it behind the proxy, for the house only

Create the A record for `portainer.ai-at-home.de` first, then
[caddy.md](caddy.md) "Add a site" — with two differences. Portainer's login is
root on this host, so the site file imports `house-only` instead of `site`.
And Portainer is not an application built on the template, so it does not
answer on `:8080`, and the site file names its port:

```sh
ssh andygeiss@vserver "printf 'portainer.ai-at-home.de {\n\timport house-only portainer:9000\n}\n' > /opt/caddy/sites/portainer.caddy"
ssh andygeiss@vserver 'cd /opt/caddy \
    && docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile \
    && docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile'
```

Check both sides. Run the first `curl` on a machine on `KNOPPERS`. The second
runs on the server itself, and the server is not the house, so it gets the
`403`:

```sh
curl -so /dev/null -w '%{http_code}\n' https://portainer.ai-at-home.de/     # 200, and a real certificate
ssh andygeiss@vserver "curl -so /dev/null -w '%{http_code}\n' https://portainer.ai-at-home.de/"   # 403
```

**The proxy lets in one address, `10.77.0.2`.** It is the house's end of the
WireGuard tunnel ([vserver.md](../servers/vserver.md), "The house's way out").
`KNOPPERS` and the Mac Studio reach this server only through that tunnel, so
the proxy sees both of them at that address. Everyone else gets the `403`, and
never sees the login. So the gateway's route decides who gets in: a device
added to the route can open Portainer too.

A device on `SCHNIPOSA` takes the house's own line, and gets the `403`. That
line's address cannot be let in as well: the line is behind CGNAT, so the
address is shared with strangers, and it changes.

**The A record stays.** The house looks the name up in public DNS like
everyone else, so without the record no device there finds the server either.
Let's Encrypt checks the name from the internet too, and the `403` does not
stand in its way, so the certificate renews as before. Deleting the record
would hide nothing: every certificate is written to a public log, and this
name's first one was in August 2026.

`:9000` is Portainer's plain-HTTP listener. The proxy terminates TLS, so the
hop from Caddy to Portainer stays inside the `web` network in plain HTTP — the
same as for every application.

## Reach it from outside the house

```sh
ssh -L 9443:127.0.0.1:9443 andygeiss@vserver    # then https://localhost:9443
```

This works from any network, and before DNS exists. When the house's tunnel is
down, `KNOPPERS` is offline, so run it from `SCHNIPOSA`. The certificate there
is Portainer's own, self-signed; the browser will say so. That is the only
place it is ever seen.

## Upgrade

Bump the row in [VERSIONS.md](../VERSIONS.md) and the tag in
`portainer/compose.yaml` — the LTS line, and the version behind the `lts` tag,
never the tag itself — then:

```sh
scp portainer/compose.yaml andygeiss@vserver:/opt/portainer/
ssh andygeiss@vserver 'cd /opt/portainer && docker compose pull && docker compose up -d && docker compose ps'
curl -s https://portainer.ai-at-home.de/api/system/status    # {"Version":"2.45.2",…}
```

Portainer refuses to start on a downgrade, so read the version it runs before
pinning a number. The `curl` above answers that on `KNOPPERS`. Anywhere else,
or before DNS, ask the loopback port instead with `ssh andygeiss@vserver 'curl
-sk https://127.0.0.1:9443/api/system/status'`. Do not grep the log for
`version=`: the line that names Portainer's version also names the Go,
Node.js, pnpm and webpack versions it was built with.
