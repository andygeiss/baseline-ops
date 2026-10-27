# Plan: close the operations gaps

**Written: 2026-10-27.** The repository already explains each step, deploys
safely, and documents its own reasoning. What it lacks is the part of operations
that runs when nobody is looking. Nothing tells you that a site is down. The
backups are mostly a runbook nobody has rehearsed. The server cannot be rebuilt,
or checked against its document, by running anything.

**Status, 2026-10-27.** The boxes ticked below are written, and `checks.yml`
passes on them, shellcheck included. `make backup` ran on the Mac on
2026-10-27, and its archive was rehearsed the same day. The rest has not run on
vserver yet. Next, in order:

1. Pick the monitoring service, write its ping URL to the server
   (servers/vserver.md, "How you find out"), and run `make health-check
   verify-host`.
2. Run each phase's "Done when". A phase is done only after that.

Each phase below can be shipped on its own and ends in something you can check.
They are in order of what a lost server would cost you. Delete this file when
the last phase is done. What it decides moves into the runbooks, as everything
else here does.

## 0. Fix what is already wrong

- [x] README, "How the sandbox image is verified", lists five checks. The
      workflow has six since the Opus 5.5 check. Count them again, or stop
      counting: point at the workflow's step names, so the list cannot drift
      (see phase 5).

**Done when:** the README and the workflow agree.

## 1. Find out when something breaks

The server cannot report its own death, so the check has to run somewhere
else. There are two kinds of signal:

- **From outside: is it up?** An HTTP check on each public site and its
  certificate's expiry, run from outside vserver. A Caddy that is down, a
  container that is wedged, and DNS that is wrong all look the same from there:
  no answer.
- **From inside: is it healthy?** A dead man's switch. A systemd timer on
  vserver pings a URL after each check passes, and silence raises the alert.
  Silence also covers a server that never came back from the 04:00 reboot.

Checks for the timer to run, each one pinging only on success:

- [ ] disk: root filesystem and `/var/lib/docker` below 80 %
- [ ] every application container `healthy` (`docker compose ps` per `/opt/*`)
- [ ] the server's own stacks running: caddy, portainer
- [ ] the iptables rules from `conn-limits` and `wg-exit` present
- [ ] `/var/run/reboot-required` older than two days, which means the
      automatic reboot is not happening

Deliverables:

- [x] `servers/health-check`, a script, and `make health-check`, which ships it
      with its unit and timer the way `conn-limits` is shipped
- [x] the ping URL is a secret: a file on the server, `0400`, never in git
- [x] `servers/vserver.md`, a new section, "How you find out": what is checked,
      from where, and who gets the alert
- [ ] each runbook's "When it goes wrong" starts from the alert that would have
      fired

**Decide first:** which service. healthchecks.io, hosted or self-run, does the
dead man's switch. An external uptime checker does the outside view. One
self-run Uptime Kuma in the house can do both, but then a house outage
silences the alerts too. Recommendation: a hosted service for both, because the
whole point is that it lives on neither of your two places.

**Done when:** stopping caddy, filling a scratch file past 80 %, and stopping
the timer each raise an alert within ten minutes. Write down what you ran.

## 2. Make the data survive the server

Two separate things are at risk.

**The applications' data.** Litestream is opt-in, and no application runs it.

- [ ] Answer new-app.md step 5, the off-box question, for `game` and for every
      other application on the server, in writing, in the application's own
      repository
- [ ] For each one that answers "seconds": add the sidecar, and settle
      Litestream's exact tag (VERSIONS.md leaves that open until the first
      application)
- [ ] Rehearse a restore from the replica, following runbooks/restore.md, and
      update its "Last verified"

**The server's own state**, which is in no repository by design:

| What | Where | Lost means |
|---|---|---|
| site files | `/opt/caddy/sites/*.caddy` | every domain, rewritten from memory |
| application secrets, `site.env`, `litestream.yml` | `/opt/<app>/` | every credential reissued |
| wg0's key | `/etc/systemd/network/wg0.key` | the house reconfigured; `make wg-house` again |
| Portainer's admin user and settings | volume `portainer_data` | set up again |
| certificates and the ACME account | volume `caddy_data` | Caddy fetches them again; rate limits if many at once |

- [x] `servers/backup`: one tar.gz of the table above, written to stdout.
      `make backup` runs it on the Mac, over ssh, and keeps the newest 30 in
      `~/Backups/vserver`. No cloud storage, no timer, nothing installed on
      the server: the Mac holds the backup, and you run it as often as you like
- [ ] FileVault on the Mac, and on Time Machine's disk: the archive holds every
      secret, unencrypted
- [x] `runbooks/restore.md`, "Get the server's own state back", rehearsed once
      into a scratch directory

**Done when:** both restores have run once from the real backup, and the
runbook says when.

## 3. Rebuild the server, and check it against its document

`servers/vserver.md` describes the machine, and nothing checks that the
machine agrees.

- [x] `make verify-host`: read-only, safe to run any time, failing loudly. It
      asserts:
  - `sshd -T`: `passwordauthentication no`, the tunnel drop-in's four settings
  - the deploy account in `docker` and `sudo`, and nothing else in `docker`
  - Docker Engine and Compose at VERSIONS.md's versions
  - the DOCKER-USER, nat and mangle rules that `conn-limits` and `wg-exit` add
  - `52auto-reboot` present, and unattended-upgrades enabled
  - published ports: only Caddy's 80/443 and Portainer's loopback 9443
- [x] `make sshd-hardening`: the one `MUST` with no target behind it, password
      authentication off, as a drop-in like `10-tunnel.conf`
- [ ] `runbooks/rebuild.md`: a new VPS to serving every site, in order. It
      covers Docker from Docker's repository, the account, the make targets,
      caddy, then each app from phase 2's backup. It ends with `make
      verify-host`. Steps that have no target yet stay prose until they have
      run twice, which is the repository's existing rule
- [ ] the quarterly re-verify in VERSIONS.md becomes `make verify-host` plus the
      sources list, not a reading of the document

**Done when:** `make verify-host` passes on vserver, and a rebuild rehearsal on
a throwaway VPS reaches a passing `verify-host` with one application restored.

## 4. Gate what is cheap to gate

The README says compose and Caddy validation need an invented server context.
Most of it does not:

- [x] `caddy validate` on `caddy/Caddyfile` with an empty `sites/` directory,
      plus one example site per snippet (`site`, `tunnel`, `house-only`) taken
      from the Caddyfile's own header comment
- [x] `docker compose config` on `templates/compose.yaml`, `caddy/compose.yaml`,
      and `portainer/compose.yaml`. `IMAGE_TAG` and an empty secrets file are
      all they need
- [x] shellcheck (`-s sh`) on `bin/deploy`, `claude-sandbox/claude-sandbox`, and
      `servers/*`
- [x] pin `actions/checkout` by commit SHA, with Dependabot for
      `github-actions` only. VERSIONS.md stays manual on purpose
- [x] update the README's "not gated" paragraph to match

**Done when:** a typo in the Caddyfile, a compose key spelled wrong, and an
unquoted variable each fail a pull request.

## 5. One fact, one place

- [ ] The tunnel's numbers, `10.77.0.0/24`, `10.77.0.2`, MTU `1380`, and port
      `51820`, are now in the Makefile, `wg-exit`, `wg-house`, the Caddyfile,
      and `vserver.md`. Define them once (Makefile variables passed to the
      scripts), and have phase 4's CI grep for strays
- [ ] The systemd units move out of `printf` one-liners in the Makefile into
      files under `servers/`, so a diff shows a unit change as one
- [ ] The README stops restating each workflow's checks and links to them
- [ ] A scheduled CI step warns when a "Last verified" date is older than 90
      days, which is the quarterly policy VERSIONS.md already states

**Done when:** changing the house's address is one edit plus `make wg-exit
wg-house`.

## 6. Decide on Portainer

Portainer puts the Docker socket, which is root, behind a login on the
internet-facing machine. Its guards are sound and documented. Still, `ssh
vserver docker compose ls` answers the same question with nothing installed.

- [ ] Decide: remove it, keep it as is, or put a read-only socket proxy in
      front of it
- [ ] Whatever the decision is, write it down in `servers/vserver.md`, "What is
      installed"

**Done when:** the decision and its reason are on file.

## Not in this plan

These were left out on purpose, and the README's "What is deliberately not
here" still holds: no second server, no orchestration, no CD, and no registry.
Nothing above changes how an application is built or deployed.
