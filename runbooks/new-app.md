# Runbook: Put an application on the server

**Last verified: 2026-08-27**

Do this once per application. Afterwards every release is
[deploy.md](deploy.md).

The application must already satisfy the deployment contract in the engineering
baseline (`operations/web-application.md`): it binds `$HOST`/`$PORT`, serves
`/healthz` on the container's own `127.0.0.1:6060`, logs to stdout, reads
secrets from `$CREDENTIALS_DIRECTORY`, and shuts down on SIGTERM. If it does
not, fix that first — nothing here can paper over it.

The server's proxy must already be running — [caddy.md](caddy.md), "Install".
It holds `:80` and `:443` for every application, so no application brings a
proxy of its own.

## 1. Copy the templates into the application repository

```sh
cp ~/workspace/baseline-ops/templates/Dockerfile    ./Dockerfile
cp ~/workspace/baseline-ops/templates/compose.yaml  ./compose.yaml
cp ~/workspace/baseline-ops/templates/dockerignore  ./.dockerignore
```

Edit two lines in `compose.yaml`, to the same value — the repository name:
`name:`, and the alias under `networks: web:`. Commit all three. They describe
the *server*, not your laptop — local development stays `make run` over plain
HTTP.

**The alias is the part that bites.** Compose gives every service a network
alias equal to its own name, so two projects on one network both answer to
`app`. Naming the alias after the project — the same name as `/opt/<app>` and
`name:` in the file — is what keeps the proxy's `reverse_proxy todo:8080`
pointing at the right container.

## 2. Point the domain at the server

Create the A record (and AAAA, if the server has IPv6) **before** the proxy
learns the site. Let's Encrypt proves ownership by connecting back to it; a
certificate request that fails retries into a rate limit.

## 3. Prepare the directory on the server

```sh
ssh root@vserver 'mkdir -p /opt/<app> && chown andygeiss:andygeiss /opt/<app>'   # /opt belongs to root
ssh andygeiss@vserver 'mkdir -p /opt/<app>/secrets && chmod 700 /opt/<app>/secrets'
```

If the application has settings that are true of this server and not secret —
which model host to call, who the tenant is — put them in `/opt/<app>/site.env`,
one `KEY=value` per line. The template reads it when it exists and does not miss
it when it does not. No deploy ever touches it; that is what lets the same
repository serve production from one box and staging from another.

## 4. Put the secrets in place

For each secret the application reads:

```sh
scp smtp-key andygeiss@vserver:/opt/<app>/secrets/smtp-key
ssh andygeiss@vserver 'chmod 400 /opt/<app>/secrets/smtp-key && chown 10001 /opt/<app>/secrets/smtp-key'
```

`chown 10001` matters: the container runs as that UID and cannot read a file it
does not own at mode `0400`. If the application has no secrets, delete both
`secrets:` blocks from `compose.yaml` instead.

## 5. Answer the off-box question

**If this server disappears right now, what have you lost?** The database is one
file in a volume on this machine, and so is any snapshot written beside it. The
baseline's `patterns/go-sqlite.md` has the three legitimate answers; if yours is
"seconds", add the backup sidecar now — [restore.md](restore.md) has the service
block and the credentials it needs.

Whichever answer you pick, rehearse the restore before launch, not during the
incident.

## 6. Register the site with the proxy

[caddy.md](caddy.md), "Add a site": one four-line file in `/opt/caddy/sites/`,
naming the domain and the alias from step 1, then a reload. The proxy asks
Let's Encrypt for the certificate right away — the reason step 2 comes first —
and answers `502` until the application is up, which is next.

## 7. Deploy, then verify TLS

Run [deploy.md](deploy.md). Then check the things that only exist in production:

```sh
curl -sI https://example.com | head -1                 # 200, and a real certificate
curl -sI http://example.com | head -2                  # 308 to https
ssh andygeiss@vserver 'cd /opt/<app> && docker compose ps' # app healthy
ssh andygeiss@vserver 'docker network inspect web -f "{{range .Containers}}{{.Name}} {{end}}"'   # the proxy and this app, both there
```

## What the shape rules out

One proxy, one network, no public port on any application — that is the only
sanctioned multi-app shape. Two Caddies on one host, a host-installed Caddy in
front of a containerised one, or applications publishing loopback ports for a
proxy to find: all no. Only one process can hold `:443`, and the one that does
is in `/opt/caddy`.
