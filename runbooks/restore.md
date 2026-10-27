# Runbook: Backups and getting the data back

**Last verified: 2026-08-15.** "Get the server's own state back" added 2026-10-27, not yet run.

The database is one file in a volume on one machine, and so is every snapshot
written beside it. This runbook covers the two things that follow from that:
replicating the file off the box, and putting it back.

**The decision is the application's, not this repository's.** The baseline's
`patterns/go-sqlite.md` asks it: *if this server disappears right now, what have
you lost?* — with three legitimate answers ("nothing that matters", "up to a
day", "seconds"). What follows is how the server implements the third one.

## Add the Litestream sidecar

Litestream streams the write-ahead log to S3-compatible storage as it is
written, so the recovery point is seconds and there is no timer, no rotation,
and no second mechanism to copy anything anywhere. It is opt-in: an application
that loses nothing worth losing should not pay for it.

Paste this service into the application's `compose.yaml`:

```yaml
  litestream:
    image: litestream/litestream:0.5
    command: replicate
    user: "10001:10001"         # same UID as the app, or it cannot read the database
    restart: unless-stopped
    volumes:
      - data:/var/lib/app
      - ./litestream.yml:/etc/litestream.yml:ro
    logging:
      driver: json-file
      options: {max-size: "10m", max-file: "3"}
```

Then, on the server only, `/opt/<app>/litestream.yml` — mode `0400`, owned by
`10001`. It names the database, the replica URL, and the S3 credentials, which
is why it is a mounted file and not the environment variables Litestream would
also accept. It is never committed and never deployed.

```sh
ssh andygeiss@vserver 'chmod 400 /opt/<app>/litestream.yml && chown 10001 /opt/<app>/litestream.yml'
ssh andygeiss@vserver 'cd /opt/<app> && docker compose up -d'
ssh andygeiss@vserver 'cd /opt/<app> && docker compose logs litestream | tail -20'
```

The log is the check: replication either started or said why it could not.

## Rehearse the restore before launch

A replica nobody has restored from is a belief, not a backup. Do this once, on
purpose, and write down what you ran:

```sh
# Into a scratch path, never over the live database.
ssh andygeiss@vserver 'cd /opt/<app> && docker compose run --rm --entrypoint litestream \
    litestream restore -config /etc/litestream.yml -o /tmp/check.db <replica-url>'
```

Then open the copy and look at it — row counts, the newest record, anything that
proves it is the data you expect rather than an empty file with the right name.

## Restore for real

1. **Stop the application first.** Two writers on one SQLite file is how a
   restore becomes a corruption.

   ```sh
   ssh andygeiss@vserver 'cd /opt/<app> && docker compose stop app litestream'
   ```

2. **Restore to a scratch path and inspect it**, exactly as in the rehearsal.
   Never restore straight over the live file: if the replica is older or emptier
   than you think, you have just destroyed the only other copy.

3. **Move it into place**, then start again:

   ```sh
   ssh andygeiss@vserver 'cd /opt/<app> && docker compose up -d'
   ssh andygeiss@vserver 'cd /opt/<app> && docker compose ps'   # healthy, and the app agrees
   ```

4. **Check the version at `/healthz`** afterwards. A restore that also silently
   rolled the application back is worth catching now rather than tomorrow.

## The snapshot answer, if that is the one you picked

An application that takes `VACUUM INTO` snapshots writes them inside its own data
volume — `read_only: true` makes every other path unwritable, and the failure is
silent. That placement is also the limit: **the snapshot sits on the same disk as
the thing it protects.** Getting it off the box is a separate job with its own
credentials and its own rehearsal, and it is not written here because no
application has needed it yet. If yours does, that job belongs in this runbook
before it belongs in a cron line nobody remembers.

## Get the server's own state back

Some files are true of this machine only, so no repository holds them.
`servers/backup` copies them off the box every night, with restic, encrypted,
to S3-compatible storage:

| What | Where | Lost means |
|---|---|---|
| site files | `/opt/caddy/sites/*.caddy` | every domain, written again from memory |
| secrets, `site.env`, `litestream.yml`, `.env` | `/opt/<app>/` | every credential issued again |
| wg0's key, and the house's peer | `/etc/systemd/network/` | the house set up again: `make wg-house` |
| Portainer's admin user and settings | volume `portainer_data` | Portainer set up again |
| certificates and the ACME account | volume `caddy_caddy_data` | Caddy asks for them again, and many at once meets Let's Encrypt's rate limits |

The applications' databases are not in it. They are the first half of this
runbook: Litestream, or the application's own answer.

### Set it up, once per server

Use a bucket of its own and a key of its own. The Litestream replicas get
another bucket and another key, so a leaked application key cannot delete the
host backup.

1. Make two checks on the monitoring service, one for the health check and one
   for the backup (servers/vserver.md, "How you find out"). Write the first
   URL to the server:

   ```sh
   ssh root@vserver 'umask 077 && cat > /etc/health-check.url'   # paste the URL, then ctrl-d
   ```

2. Write `/etc/backup.env`. The format is in `servers/backup`'s header. Make
   the password long and random, and **save it in your password manager
   too**. Without it, the backup cannot be read.

   ```sh
   ssh root@vserver 'umask 077 && cat > /etc/backup.env'   # paste, then ctrl-d
   ```

3. Make the repository, once:

   ```sh
   ssh root@vserver 'apt-get install -y restic && set -a && . /etc/backup.env && restic init'
   ```

4. Install both timers, and check them:

   ```sh
   make health-check backup
   make verify-host
   ```

### Rehearse it

Restore the latest snapshot into a scratch directory, never over `/`, and
look at it. Check that the site files name your domains and that a secret is
the right size, not empty:

```sh
ssh root@vserver 'set -a && . /etc/backup.env && restic restore latest --target /root/restore-check'
ssh root@vserver 'ls -R /root/restore-check/opt/caddy/sites && rm -rf /root/restore-check'
```

Write down the date here when you have. **Not rehearsed yet.**

### Restore for real

On a server that lost its disk: rebuild it far enough to run Docker and
restic, then write `/etc/backup.env` again from your password manager and the
storage provider's console. Restore into a scratch directory as in the
rehearsal, then copy back what you need, with the owners and modes the table
in servers/vserver.md, "Directory layout", names. Stop a stack before you put
back its volume.
