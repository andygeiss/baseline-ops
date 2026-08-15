# Runbook: Put an application on the server

**Last verified: 2026-08-15**

Do this once per application. Afterwards every release is
[deploy.md](deploy.md).

The application must already satisfy the deployment contract in the engineering
baseline (`operations/web-application.md`): it binds `$HOST`/`$PORT`, serves
`/healthz` on the container's own `127.0.0.1:6060`, logs to stdout, reads
secrets from `$CREDENTIALS_DIRECTORY`, and shuts down on SIGTERM. If it does
not, fix that first — nothing here can paper over it.

## 1. Copy the templates into the application repository

```sh
cp ~/workspace/baseline-ops/templates/Dockerfile    ./Dockerfile
cp ~/workspace/baseline-ops/templates/compose.yaml  ./compose.yaml
cp ~/workspace/baseline-ops/templates/Caddyfile     ./Caddyfile
cp ~/workspace/baseline-ops/templates/dockerignore  ./.dockerignore
```

Edit exactly one line: `name:` in `compose.yaml`, to the repository name. Commit
all four. They describe the *server*, not your laptop — local development stays
`make run` over plain HTTP.

## 2. Point the domain at the server

Create the A record (and AAAA, if the server has IPv6) **before** the first
start. Let's Encrypt proves ownership by connecting back to it; a certificate
request that fails retries into a rate limit.

## 3. Prepare the directory on the server

```sh
ssh deploy@vserver 'mkdir -p /opt/<app>/secrets && chmod 700 /opt/<app>/secrets'
ssh deploy@vserver 'echo DOMAIN=example.com > /opt/<app>/site.env'
```

`site.env` is the server's file: it says where this app runs, and no deploy ever
touches it. That is what lets the same repository serve production from one box
and staging from another.

## 4. Put the secrets in place

For each secret the application reads:

```sh
scp smtp-key deploy@vserver:/opt/<app>/secrets/smtp-key
ssh deploy@vserver 'chmod 400 /opt/<app>/secrets/smtp-key && chown 10001 /opt/<app>/secrets/smtp-key'
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

## 6. Deploy, then verify TLS

Run [deploy.md](deploy.md). Then check the things that only exist in production:

```sh
curl -sI https://example.com | head -1                 # 200, and a real certificate
curl -sI http://example.com | head -2                  # 308 to https
ssh deploy@vserver 'cd /opt/<app> && docker compose ps' # app healthy, caddy running
```

## 7. If this is the second application on the server

Only one process can hold `:443`, so the second application cannot bring its own
Caddy. Move the proxy out, once, and every application afterwards is a stack
with no public port at all.

```sh
ssh deploy@vserver 'docker network create web'
```

Run Caddy alone from `/opt/caddy/compose.yaml` — the `caddy` service from the
template, plus `networks: [web]` — with a Caddyfile that names each site
literally:

```caddyfile
todo.example.com {
	encode zstd gzip
	reverse_proxy todo:8080
}

notes.example.com {
	encode zstd gzip
	reverse_proxy notes:8080
}
```

Each application then deletes its own `caddy` service, its `site.env`, and its
`caddy_*` volumes, and joins the shared network:

```yaml
  app:
    # …everything else unchanged, still no ports:
    networks:
      web:
        aliases: [todo]       # MUST be unique per app: every project names its service "app"

networks:
  web:
    external: true
```

**The alias is the part that bites.** Compose gives every service a network
alias equal to its own name, so two projects on one network both answer to
`app`. Naming the alias after the project — the same name as `/opt/<app>` and
`name:` in the file — is what keeps `reverse_proxy todo:8080` pointing at the
right container.

This is the only sanctioned multi-app shape. Two Caddies on one host, a
host-installed Caddy in front of a containerised one, or applications publishing
loopback ports for a proxy to find: all no.
