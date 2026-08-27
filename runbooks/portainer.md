# Runbook: Portainer

**Last verified: 2026-08-27**

Portainer is the optional look at what is running on
[vserver](../servers/vserver.md). It runs as its own stack from
`/opt/portainer`, sits behind the proxy like every application, and is reached
at `https://portainer.ai-at-home.de` — or through an SSH tunnel when DNS is not
there yet.

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

## Put it behind the proxy

Create the A record for `portainer.ai-at-home.de` first, then
[caddy.md](caddy.md) "Add a site" — with one difference. Portainer is not an
application built on the template, so it does not answer on `:8080`, and the
site file says the port itself instead of importing the `site` snippet:

```sh
ssh andygeiss@vserver "printf 'portainer.ai-at-home.de {\n\tencode zstd gzip\n\treverse_proxy portainer:9000\n}\n' > /opt/caddy/sites/portainer.caddy"
ssh andygeiss@vserver 'cd /opt/caddy \
    && docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile \
    && docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile'
curl -sI https://portainer.ai-at-home.de | head -1     # 200, and a real certificate
```

`:9000` is Portainer's plain-HTTP listener. The proxy terminates TLS, so the
hop from Caddy to Portainer stays inside the `web` network in plain HTTP — the
same as for every application.

## Reach it without DNS

```sh
ssh -L 9443:127.0.0.1:9443 andygeiss@vserver    # then https://localhost:9443
```

The certificate there is Portainer's own, self-signed; the browser will say so.
That is the only place it is ever seen.

## Upgrade

Bump the row in [VERSIONS.md](../VERSIONS.md) — the LTS line, and the version
behind the `lts` tag, never the tag itself — then:

```sh
scp portainer/compose.yaml andygeiss@vserver:/opt/portainer/
ssh andygeiss@vserver 'cd /opt/portainer && docker compose pull && docker compose up -d && docker compose ps'
```

Portainer refuses to start on a downgrade. Read the version it is running
(`docker compose logs portainer | grep version=`) before pinning a number.
