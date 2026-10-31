# Runbook: Backups and getting the data back

**Last verified: 2026-08-15.** "Get the server's own state back": 2026-10-27, rehearsed.

The database is one file in a volume on one machine, and so is every snapshot
written beside it. This runbook covers the two things that follow from that:
replicating the file off the box, and putting it back.

**The decision is the application's, not this repository's.** The baseline's
`patterns/go-sqlite.md` asks it: *if this server disappears right now, what have
you lost?* — with three legitimate answers ("nothing that matters", "up to a
day", "seconds"). Litestream, below, is how the server implements the third
one. `make backup` gives every application the second, for as long ago as you
last ran it — "Get an application's data back", at the end.

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

Some files are true of this machine only, so no repository holds them. `make
backup`, run on your Mac, copies them there as one dated archive in
`~/Backups/vserver/`. Run it as often as you like. The newest 30 are kept, and
nothing is installed on the server for it.

| What | Where | Lost means |
|---|---|---|
| site files | `/opt/caddy/sites/*.caddy` | every domain, written again from memory |
| secrets, `site.env`, `litestream.yml`, `.env` | `/opt/<app>/` | every credential issued again |
| wg0's key, and the house's peer | `/etc/systemd/network/wg0.key`, `50-wg0.netdev.d/` | the house set up again: `make wg-house` |
| the ssh host keys | `/etc/ssh/ssh_host_*_key{,.pub}` | every ssh client refuses the new server, the Studio's tunnel included, until told to trust it |
| the deploy account's keys | `/home/andygeiss/.ssh/authorized_keys` | the oMLX tunnel's restricted line written again from vserver.md |
| the health check's ping URL | `/etc/health-check.url` | the URL copied again from the service |
| certificates and the ACME account | volume `caddy_caddy_data` | Caddy asks for them again, and many at once meets Let's Encrypt's rate limits |
| each application's data | volume `<app>_data`, as `data/<app>/` | the users' data, since the last `make backup` |

An application's data is copied cold, as a deploy's snapshot is: the
application stops for the seconds the copy takes, and starts again. An
application is what `bin/deploy` has deployed — it has a `deploy.lock`, which
the backup holds while it copies, so no deploy starts halfway and the health
check does not count the stop.

**The archive holds every secret on the server, unencrypted.** The directory
and each file are mode `0700` and `0600`. The Mac's disk MUST be encrypted
(FileVault), and so MUST the disk Time Machine copies it to.

```sh
make backup    # on the Mac; prints the archive it kept
```

### Rehearse it

Unpack the newest archive into a scratch directory on the Mac and look at it.
Check that the site files name your domains and that a secret is the right
size, not empty:

```sh
f=$(ls -1t ~/Backups/vserver/vserver-*.tgz | head -n 1)
mkdir /tmp/restore-check && tar -xzf "$f" -C /tmp/restore-check
ls -lR /tmp/restore-check/opt/caddy/sites /tmp/restore-check/opt/*/secrets
rm -rf /tmp/restore-check
```

Write down the date here when you have. **Rehearsed 2026-10-27**, from
`vserver-20261027T193322Z.tgz`, the first archive `make backup` kept: the three
site files named their domains, `wg0.key` was 45 bytes, and `game` has no
secrets.

### Restore for real

On a server that lost its disk: rebuild it far enough to run Docker. Copy the
archive over and unpack it into a scratch directory, never over `/`:

```sh
scp ~/Backups/vserver/vserver-<date>.tgz root@vserver:/root/
ssh root@vserver 'mkdir /root/restore && tar -xzf /root/vserver-<date>.tgz -C /root/restore'
```

Then copy back what you need. tar run as root keeps the owners and modes, and
servers/vserver.md, "Directory layout", says what they should be. Stop a stack
before you put back its volume. Delete `/root/restore` and the archive when you
are done: they hold every secret.

## Get an application's data back

`make backup` keeps each application's volume as `data/<app>/` in the archive:
the database, its WAL, and whatever else the application wrote there.

### Rehearse it

On the Mac. `ls` shows what each application keeps. A database gets its own
check, with the sqlite3 that ships with macOS, and only one that is there:
sqlite3 makes an empty database for a name that does not exist, and an empty
database passes.

```sh
f=$(ls -1t ~/Backups/vserver/vserver-*.tgz | head -n 1)
mkdir /tmp/restore-check && tar -xzf "$f" -C /tmp/restore-check data
ls -lR /tmp/restore-check/data
for db in /tmp/restore-check/data/*/*.db; do
	[ -s "$db" ] && echo "$db: $(sqlite3 "file:$db?mode=ro" 'PRAGMA integrity_check')"
done
rm -rf /tmp/restore-check
```

Then open a file, or a row, you know is there. Write down the date here when
you have. **Rehearsed 2026-10-27** for `game`: its volume holds one file,
`rungs.json`, and no database — the template's read-only root leaves it nowhere
else to write.

### Restore for real

It throws away everything written since the backup, so it is a decision, as
putting a deploy's snapshot back is. Into a scratch directory first, never
straight into the volume:

```sh
scp ~/Backups/vserver/vserver-<date>.tgz root@vserver:/root/
ssh root@vserver 'mkdir /root/restore && tar -xzf /root/vserver-<date>.tgz -C /root/restore data/<app>'
ssh root@vserver 'cd /opt/<app> && docker compose stop app \
    && docker run --rm --pull never -v <app>_data:/data -v /root/restore/data/<app>:/in:ro alpine:3.24 \
       sh -c "find /data -mindepth 1 -delete && cp -a /in/. /data/" \
    && docker compose start app'
ssh root@vserver 'rm -rf /root/restore /root/vserver-<date>.tgz'
```

`cp -a` keeps the owner, 10001, that tar kept. Then check `/healthz` and a row
you know is there, as after any restore.
