# Runbook: Backups and getting the data back

**Last verified: 2026-08-15**

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
ssh deploy@vserver 'chmod 400 /opt/<app>/litestream.yml && chown 10001 /opt/<app>/litestream.yml'
ssh deploy@vserver 'cd /opt/<app> && docker compose up -d'
ssh deploy@vserver 'cd /opt/<app> && docker compose logs litestream | tail -20'
```

The log is the check: replication either started or said why it could not.

## Rehearse the restore before launch

A replica nobody has restored from is a belief, not a backup. Do this once, on
purpose, and write down what you ran:

```sh
# Into a scratch path, never over the live database.
ssh deploy@vserver 'cd /opt/<app> && docker compose run --rm --entrypoint litestream \
    litestream restore -config /etc/litestream.yml -o /tmp/check.db <replica-url>'
```

Then open the copy and look at it — row counts, the newest record, anything that
proves it is the data you expect rather than an empty file with the right name.

## Restore for real

1. **Stop the application first.** Two writers on one SQLite file is how a
   restore becomes a corruption.

   ```sh
   ssh deploy@vserver 'cd /opt/<app> && docker compose stop app litestream'
   ```

2. **Restore to a scratch path and inspect it**, exactly as in the rehearsal.
   Never restore straight over the live file: if the replica is older or emptier
   than you think, you have just destroyed the only other copy.

3. **Move it into place**, then start again:

   ```sh
   ssh deploy@vserver 'cd /opt/<app> && docker compose up -d'
   ssh deploy@vserver 'cd /opt/<app> && docker compose ps'   # healthy, and the app agrees
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
