# Runbook: Patch and reboot the host

**Last verified: 2026-10-18**

This is how a person updates [vserver](../servers/vserver.md)'s own packages,
reboots it, and checks that it came back. The server can do the first two by
itself ([vserver.md](../servers/vserver.md), "Updates and the nightly
reboot"); this runbook is for a version pass, or for a fix that should not
wait. The checks at the end are worth running after any reboot, the nightly
one included.

Run every command from a checkout of this repository. Packages are root's job,
so the first half uses `root@vserver`.

## Install the updates

```sh
# 1. What would change. -s only simulates.
ssh root@vserver 'apt-get update -q && apt-get -s full-upgrade | grep -E "^(Inst|Remv) "'

# 2. Install, detached from this ssh session.
ssh root@vserver 'DEBIAN_FRONTEND=noninteractive nohup apt-get full-upgrade -y -q \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    >> /var/log/apt/by-hand.log 2>&1 & wait $!; echo "apt-get exited $?"'

# 3. Whether it needs a reboot, and which packages asked for one.
ssh root@vserver 'cat /run/reboot-required.pkgs 2>/dev/null || echo "no reboot needed"'
```

`full-upgrade`, not `upgrade`: a new kernel arrives as a new package, and
`upgrade` never installs a new package.

Step 2 is built around a dropped connection. `nohup … &` keeps apt running if
the ssh session dies, so dpkg never stops halfway through a package. `wait`
holds the session open until apt is done, so you still see it end. The two
`-o` options answer the one question dpkg asks by itself: a package ships a
new version of a file that was edited here, and the edited one stays. With no
terminal to ask, dpkg would stop at that question instead.

A package Ubuntu is still phasing in is missing from both steps, on purpose.
apt holds it back until the phasing reaches this machine, and the morning run
installs it then.

## Reboot

Every site is down for about a minute.

```sh
old=$(ssh root@vserver 'cat /proc/sys/kernel/random/boot_id')
ssh root@vserver 'systemctl reboot'
until new=$(ssh -o ConnectTimeout=5 andygeiss@vserver 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) \
    && [ "$new" != "$old" ]; do sleep 5; done; echo "back, boot $new"
```

The loop waits for a new boot id rather than for ssh. ssh can answer once more
before the machine goes down, and only a new id proves it rebooted.

## Check it came back

```sh
ssh andygeiss@vserver 'uname -r; systemctl --failed --no-legend'
ssh andygeiss@vserver 'docker ps --format "{{.Names}}\t{{.Status}}"; ip -4 -br addr show docker0; ss -lntH "( sport = :18000 )"'
ssh root@vserver 'journalctl -b -p err -q --no-pager | grep -v " networkctl\[" | tail -5'
ssh root@vserver 'iptables -S DOCKER-USER; ip6tables -S DOCKER-USER; modinfo -F filename xt_connlimit xt_hashlimit'
ssh root@vserver 'wg show wg0 | grep "latest handshake"; iptables -t nat -S POSTROUTING | grep 10.77; iptables -t mangle -S FORWARD | grep -c wg0'
for d in $(ssh andygeiss@vserver 'head -qn1 /opt/caddy/sites/*.caddy' | cut -d' ' -f1); do
    printf '%-28s %s\n' "$d" "$(curl -so /dev/null -w '%{http_code}' "https://$d/")"
done
```

- `uname -r` names the kernel that step 2 installed.
- No unit failed, and this boot's journal holds no errors. The journal is
  root's to read: `andygeiss` sees only its own lines. The `grep -v` drops
  one kind that is noise. networkd-dispatcher asks `networkctl` about every
  new network link, and a container's link has already moved into the
  container by then, so every container start logs that an interface was not
  found. The boot before 2026-10-18 logged 424 of them in 52 days.
- Every container is `Up`, and the applications say `(healthy)`. Each one
  says `restart: unless-stopped`, so a container stopped on purpose stays
  down, and any other that is down is a fault.
- `docker0` is `172.17.0.1/16`, the address a house tunnel binds —
  [vserver.md](../servers/vserver.md), "Tunnels from the house". It says
  `DOWN`, and that is normal: no container uses the default bridge, so the
  link has no carrier, and the address binds all the same. The oMLX tunnel
  holds `172.17.0.1:18000` again. It comes last, a few minutes after the rest:
  the house has to reconnect wg0 before the Studio's `ssh -R` can come back.
- `DOCKER-USER` exists for both address families, and both connection-limit
  modules resolve on the new kernel — [vserver.md](../servers/vserver.md),
  "Limits on what one address may open".
- The house shook hands on wg0 within the last 3 minutes, and `wg-exit.service`
  put its rules back after Docker: three in `DOCKER-USER`, the `MASQUERADE` for
  `10.77.0.0/24`, and the two MSS rules, so the count says `2` —
  [vserver.md](../servers/vserver.md), "The house's way out".
- Every site answers `200`, except a tunnelled one: its root is `404`, from the
  proxy, by design ([caddy.md](caddy.md), "A site for a tunnelled service").
