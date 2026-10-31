# Runbook: Rebuild the server

**Last verified: never.** Written 2026-10-31; not yet rehearsed — "Rehearse it",
at the end.

This takes a new, empty VPS to one that serves every site
[vserver](../servers/vserver.md) served, from the newest `make backup` on your
Mac. Use it when the server is lost: its disk, its provider, or its address.
Every step either runs a `make` target or is written out here, and the last one
is `make verify-host`.

Run every command from a checkout of this repository, on the Mac, unless a step
says otherwise.

```sh
ls -1t ~/Backups/vserver/vserver-*.tgz | head -n 1    # the archive this rebuild starts from
```

**If the old server was broken into, stop here.** Its secrets, its keys, and
its certificates' private keys are in that archive, and an attacker has them
too. Rebuild from the steps below, but put back only the site files and each
application's data, and issue every credential again — new secrets, `make
wg-house`, an empty `caddy_caddy_data`, the machine's own host keys (and
`ssh-keygen -R vserver` on every client), and a new ping URL.

## 1. Get a machine, and give it the old one's identity

Order an Ubuntu 26.04 VPS with your ssh key for root. If the old server still
answers, run `make backup` once more first: whatever it writes after that is
lost.

Point `vserver` at the new address in the Mac's `/etc/hosts`
([vserver.md](../servers/vserver.md), "Reaching it"). Then copy the archive
over and put the old server's host keys back. Until they are back, the machine
answers with a key of its own, which your `known_hosts` rightly refuses, so
the two commands that use `$new` skip the check, and only they do:

```sh
f=$(ls -1t ~/Backups/vserver/vserver-*.tgz | head -n 1)
new='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
scp $new "$f" root@vserver:/root/backup.tgz
ssh $new root@vserver 'mkdir /root/restore && tar -xzf /root/backup.tgz -C /root/restore --wildcards "etc/ssh/*" \
    && cp -a /root/restore/etc/ssh/ssh_host_* /etc/ssh/ && systemctl restart ssh'
ssh root@vserver 'head -n 2 /etc/os-release'    # no warning: it is vserver again
```

From here on, every `make` target and `bin/deploy` reach the new machine, and
no ssh client can tell it from the old one. The archive stays in `/root` until
the end: it holds every secret.

## 2. Patch it, set its clock, and close passwords

```sh
make sshd-hardening
ssh root@vserver 'timedatectl set-timezone Europe/Berlin'
```

Europe/Berlin is the zone the 04:00 reboot means
([vserver.md](../servers/vserver.md), "Updates and the nightly reboot"). Then
install every update and reboot, as [host.md](host.md) does: "Install the
updates", then "Reboot". A new image is weeks behind its archive.

## 3. Install Docker, at the pinned versions

From Docker's own repository, never Ubuntu's
([vserver.md](../servers/vserver.md), "What is installed"). Follow
https://docs.docker.com/engine/install/ubuntu/ up to the point where it adds the
repository, then install the exact versions in [VERSIONS.md](../VERSIONS.md)
rather than the newest:

```sh
ssh root@vserver 'apt-cache madison docker-ce docker-compose-plugin | grep -E " (5:29\.9\.1|5\.6\.0)-"'
ssh root@vserver 'apt-get install -y docker-ce=<engine> docker-ce-cli=<engine> containerd.io \
    docker-buildx-plugin docker-compose-plugin=<compose>'
```

`<engine>` and `<compose>` are the full strings `madison` printed. If the
repository no longer carries those versions, install the newest and bump
VERSIONS.md: `make verify-host` compares against that file.

## 4. Make the deploy account

`andygeiss` gets a password for sudo and the `docker` group. That group exists
only once Docker is installed, which is why this step comes after it.

```sh
ssh -t root@vserver 'adduser --gecos "" andygeiss && usermod -aG sudo,docker andygeiss'
```

## 5. Unpack the rest of the backup

Into the scratch directory, never over `/`. tar run as root keeps every owner
and mode by name, and `andygeiss` exists by now, so the account's files come
back as its own, whatever number the new machine gave it.

```sh
ssh root@vserver 'tar -xzf /root/backup.tgz -C /root/restore'
ssh root@vserver 'install -d -m 700 -o andygeiss -g andygeiss ~andygeiss/.ssh \
    && cp -a /root/restore/home/andygeiss/.ssh/authorized_keys ~andygeiss/.ssh/ && cp -a /root/restore/opt/. /opt/'
ssh andygeiss@vserver 'docker ps && ls -l /opt /opt/*/secrets'    # docker answers without sudo
```

The archive holds `authorized_keys` but not its directory, which is why
`install` makes that first, as the account's own. `authorized_keys` holds your key and the oMLX tunnel's restricted line
([vserver.md](../servers/vserver.md), "Tunnels from the house"). `/opt` holds
every application's `compose.yaml`, `.env`, secrets and `site.env`, and the
proxy's site files. It holds no `src/`: the deploy in step 8 brings that back.

## 6. The house's way out, and the rest of the host

Put back wg0's key and the house's peer before `make wg-exit`, which keeps a key
it finds:

```sh
ssh root@vserver 'cp -a /root/restore/etc/systemd/network/. /etc/systemd/network/'
make auto-reboot conn-limits wg-exit sshd-tunnel
```

`conn-limits` and `wg-exit` need Docker, which creates the chain their rules go
in; that is why they come after step 3.

**If the address changed**, the house's gateway still dials the old one. Run
`make wg-house`, upload `~/Downloads/vserver-wireguard.conf` to the gateway,
and delete it ([vserver.md](../servers/vserver.md), "The house's way out"). On
the same address, the gateway reconnects by itself.

## 7. Point the sites' names at the new address

Skip this when the address did not change. Otherwise every name in
`/opt/caddy/sites` needs its A record changed now, so the names lead here by
the time the proxy starts in step 9:

```sh
ssh andygeiss@vserver 'head -qn1 /opt/caddy/sites/*.caddy' | cut -d' ' -f1
```

## 8. Bring back each application

Before the proxy, so no visitor sees an application with an empty volume. The
`web` network comes first, because every application joins it:

```sh
ssh andygeiss@vserver 'docker network create web'
ssh andygeiss@vserver 'for d in /opt/*/; do [ -f "$d/deploy.lock" ] && echo "$(basename "$d") $(cat "$d/.env")"; done'
```

That prints each application and the version it ran. For each one, from its
checkout, deploy that version. The first deploy builds the image and makes the
volume, empty:

```sh
~/workspace/baseline-ops/bin/deploy <version>
```

Then put its data back with [restore.md](restore.md), "Get an application's
data back", "Restore for real". The archive is already unpacked in
`/root/restore`, so skip its `scp` and `tar` lines, and start at the line that
stops the app.

## 9. Start the proxy

The stack's two files come from this repository, the site files from the
backup, and the certificates from the backup too: Caddy then serves at once and
asks Let's Encrypt for nothing.

```sh
scp caddy/compose.yaml caddy/Caddyfile andygeiss@vserver:/opt/caddy/
ssh andygeiss@vserver 'cd /opt/caddy && docker compose create'
ssh root@vserver 'cp -a /root/restore/var/lib/docker/volumes/caddy_caddy_data/_data/. \
    /var/lib/docker/volumes/caddy_caddy_data/_data/'
ssh andygeiss@vserver 'cd /opt/caddy && docker compose up -d && docker compose logs caddy | tail -20'
```

`create` makes the container and its volume without starting anything, so the
certificates are in place before Caddy first looks for them.

## 10. Turn the health check back on

The ping URL comes from the backup, mode `0400` and root's, as
[vserver.md](../servers/vserver.md), "How you find out", says:

```sh
ssh root@vserver 'cp -a /root/restore/etc/health-check.url /etc/'
make health-check
```

## 11. Check it

```sh
make verify-host
```

Every line says `ok`. Then run [host.md](host.md), "Check it came back": every
container healthy, the house shaken hands on wg0, every site `200`.

**If the address changed**, the Mac Studio's tunnel needs one more step. Its
`~/.ssh/config` names the address, not `vserver`, and ssh files a host key
under the address. Change `HostName` under `Host vserver` there, then let ssh
learn the key under the new address once. It is the old server's key, so this
trusts nothing new. The tunnel's agent runs ssh in batch mode, which never
asks:

```sh
ssh -o StrictHostKeyChecking=accept-new vserver true    # on the Studio; exits 1, because the key runs false
```

The agent reconnects within ten seconds.

Last, clean up and take the new server's first backup:

```sh
ssh root@vserver 'rm -rf /root/restore /root/backup.tgz'    # they hold every secret
make backup
```

Then cancel the old server, if it still exists. Its disk holds every secret.

## Rehearse it

A rebuild nobody has run is a belief. Rehearse it on a throwaway VPS, without
touching the real server, its names, or the house:

- Point `vserver` in `/etc/hosts` at the throwaway machine for the rehearsal,
  and back afterwards. Every command above then reaches it unchanged, and
  step 1 gives it vserver's host keys, so `known_hosts` needs no edit.
- Skip step 7, `make wg-house` in step 6, and the Studio in step 11.
- **Skip step 10.** The throwaway machine would ping the real check, and its
  green would hide a real outage.
- Check each site without DNS:
  `curl -so /dev/null -w '%{http_code}\n' --resolve <domain>:443:<address> https://<domain>/`.
- An application that sends mail or calls out on a timer does it twice while
  the rehearsal runs. Stop it, or rehearse without it.
- Delete the machine when you are done. It holds every secret.

**Done when:** `make verify-host` passes on the throwaway machine, and one
application answers with its data back. Write the date and what you found at the
top of this file.
