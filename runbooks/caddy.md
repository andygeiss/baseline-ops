# Runbook: The proxy

**Last verified: 2026-08-27**

One Caddy container fronts every application on
[vserver](../servers/vserver.md). It holds `:80` and `:443`, gets and renews
every certificate, and reaches each application by name on the `web` network.
Install it once; then each application is one file here and a reload.

Run every command from a checkout of this repository.

## Install, once per server

```sh
# 1. The network every application joins, and the directory the proxy runs from.
#    /opt belongs to root, so root makes the directory and hands it over.
ssh root@vserver 'mkdir -p /opt/caddy && chown andygeiss:andygeiss /opt/caddy'
ssh andygeiss@vserver 'docker network create web && mkdir -p /opt/caddy/sites'

# 2. The stack, from this repository.
scp caddy/compose.yaml caddy/Caddyfile andygeiss@vserver:/opt/caddy/

# 3. The first site — see "Add a site" below. Do this BEFORE the first start:
#    Caddy asks Let's Encrypt for a certificate the moment it reads a site, and
#    a request for a name that does not resolve yet retries into a rate limit.

# 4. Start it, and watch it get the certificate.
ssh andygeiss@vserver 'cd /opt/caddy && docker compose up -d && docker compose logs -f caddy'
```

`caddy_data` holds the certificates and the Let's Encrypt account. It is a named
volume so it outlives the container; never put it under a path a deploy
overwrites.

## Add a site

Do this once per application, from [new-app.md](new-app.md). The A record MUST
exist first.

```sh
ssh andygeiss@vserver "printf 'todo.example.com {\n\timport site todo\n}\n' > /opt/caddy/sites/todo.caddy"
ssh andygeiss@vserver 'cd /opt/caddy \
    && docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile \
    && docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile'
```

`todo` is the application's alias on the `web` network — the same name as
`/opt/todo` and `name:` in its `compose.yaml`. Nothing else in `/opt/caddy`
changes: the policy every site shares (compression, the upstream port) is the
`site` snippet in `Caddyfile`, and the file you just wrote only names a domain
and an alias.

`validate` runs first so a typo never reaches the running proxy. `reload` swaps
the configuration without dropping a connection; the other sites never notice.
Check:

```sh
curl -sI https://todo.example.com | head -1     # 200, and a real certificate
```

A `502` means Caddy is fine and the upstream is not: the application is not on
`web`, or its alias is not the name in the site file.

## Remove a site

```sh
ssh andygeiss@vserver 'rm /opt/caddy/sites/todo.caddy && cd /opt/caddy \
    && docker compose exec caddy caddy validate --config /etc/caddy/Caddyfile \
    && docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile'
```

The certificate stays in `caddy_data` until Caddy cleans it up; that is fine.

## Upgrade Caddy

One place, not one per application. Bump the row in
[VERSIONS.md](../VERSIONS.md), then:

```sh
scp caddy/compose.yaml andygeiss@vserver:/opt/caddy/
ssh andygeiss@vserver 'cd /opt/caddy && docker compose pull && docker compose up -d && docker compose ps'
```

Every site is down for the seconds the container takes to restart. The
certificates are in the volume, so nothing is requested again.

The same two commands ship an edit to `caddy/Caddyfile`. Edit it in this
repository, never on the server: the copy there is overwritten by the next
upgrade.

## When it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `502` on one site | The upstream is unreachable: the app is not on `web`, or the alias in the site file is not the alias in the app's `compose.yaml` | `docker network inspect web` lists who is on it and under which names |
| `validate` fails | A site file with a typo, or two files claiming one domain | The message names the file and line; fix it, then reload |
| A site answers with the wrong certificate, or a self-signed one | The domain in the site file does not resolve to this server, so Let's Encrypt refused | `dig +short <domain>`; fix DNS, then `reload` |
| Certificate errors after an upgrade | `caddy_data` was recreated | `docker volume ls` MUST show `caddy_caddy_data`; check that the volume is still named in `compose.yaml` |
| `bind: address already in use` on `up` | Something else holds `:80` or `:443` — an application still running its own Caddy | `docker ps` finds it; that stack needs the current template |
