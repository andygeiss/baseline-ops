# Repository tooling. This repo has no code to build; `install` and `uninstall`
# wire it into the current user's Claude Code as a personal skill, and the
# rest set up or check a machine rather than build anything: `sshd-hardening`,
# `sshd-tunnel`, `conn-limits`, `auto-reboot`, `wg-exit`, `wg-house`,
# `health-check` and `verify-host` on the server, `omlx-tunnel` on the house
# machine, `backup`, `backup-daily` and `claude-sandbox` on the Mac you work on —
# each a line that must be typed exactly, so it is not typed. `install` is the
# first target: a bare `make` installs.

SKILL_DIR = $(HOME)/.claude/skills/engineering-operations

# Host setup only. Every runbook uses the deploy account; root is for the
# few things that change sshd or install a package. Override per run:
# make sshd-tunnel ROOT=root@other-host
ROOT = root@vserver

.PHONY: auto-reboot backup backup-daily backup-daily-stop claude-sandbox conn-limits health-check install omlx-tunnel omlx-tunnel-stop sshd-hardening sshd-tunnel uninstall verify-host wg-exit wg-house

# Symlink, not copy: the repo stays the single source of truth and
# `git pull` is the update mechanism. Neither target ever removes anything
# but a symlink: if something else occupies the path, install refuses and
# stops, and uninstall leaves it alone.
install:
	test -f "$(CURDIR)/SKILL.md" || \
		{ echo "run make from the baseline-ops repo root, not via -f" >&2; exit 1; }
	mkdir -p "$(HOME)/.claude/skills"
	if [ -e "$(SKILL_DIR)" ] && [ ! -L "$(SKILL_DIR)" ]; then \
		echo "refusing to replace $(SKILL_DIR): not a symlink" >&2; exit 1; fi
	rm -f "$(SKILL_DIR)"
	ln -s "$(CURDIR)" "$(SKILL_DIR)"

uninstall:
	if [ -L "$(SKILL_DIR)" ]; then rm "$(SKILL_DIR)"; fi

# Key-only ssh, which servers/vserver.md, "Reaching it", says MUST hold. 01-
# sorts before the drop-ins Ubuntu's cloud images ship, such as
# 50-cloud-init.conf, which can turn password authentication back on, and sshd
# keeps the first value it reads. Runs twice safely: the drop-in is rewritten,
# sshd -t checks it before the reload, a reload keeps the session you are in,
# and the last line prints the settings sshd actually runs with.
sshd-hardening:
	ssh $(ROOT) 'printf "PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n" > /etc/ssh/sshd_config.d/01-hardening.conf && sshd -t && systemctl reload ssh && sshd -T | grep -E "^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin) "'

# Lets an `ssh -R` from a house machine bind the server's docker0 address
# (172.17.0.1) instead of loopback, so a container can reach a service the
# house carries in — servers/vserver.md, "Tunnels from the house". It also
# stops every key forwarding a Unix socket: /var/run/docker.sock is root, and
# the tunnel's key has no passphrase. Runs twice safely: the drop-in is
# rewritten, sshd -t checks it before the reload, and the last line prints the
# settings sshd actually runs with.
sshd-tunnel:
	ssh $(ROOT) 'printf "GatewayPorts clientspecified\nClientAliveInterval 30\nClientAliveCountMax 3\nAllowStreamLocalForwarding no\n" > /etc/ssh/sshd_config.d/10-tunnel.conf && sshd -t && systemctl reload ssh && sshd -T | grep -E "^(gatewayports|clientaliveinterval|clientalivecountmax|allowstreamlocalforwarding) "'

# Caps how many connections one address may hold open on :443, and how fast it
# may open them, in DOCKER-USER — the chain Docker reads before its own
# published ports (servers/vserver.md, "Limits on what one address may open").
# The rules go in a script rather than this line, because there are four of them
# and they have to survive a reboot; the unit runs the script after Docker,
# which is what creates the chain. Runs twice safely: the script inserts only a
# rule that is missing, and the last line prints the rules the kernel actually
# has.
conn-limits:
	scp servers/conn-limits $(ROOT):/usr/local/sbin/conn-limits
	ssh $(ROOT) 'chmod 0755 /usr/local/sbin/conn-limits && sh -n /usr/local/sbin/conn-limits'
	ssh $(ROOT) 'printf "%s\n" "[Unit]" "Description=Per-address connection limits on :443" "After=docker.service" "Requires=docker.service" "" "[Service]" "Type=oneshot" "RemainAfterExit=yes" "ExecStart=/usr/local/sbin/conn-limits" "" "[Install]" "WantedBy=multi-user.target" > /etc/systemd/system/conn-limits.service'
	ssh $(ROOT) 'systemctl daemon-reload && systemctl enable --now conn-limits && iptables -S DOCKER-USER && ip6tables -S DOCKER-USER'

# Lets unattended-upgrades reboot the server when an update it installed needs
# one (servers/vserver.md, "Updates and the nightly reboot"). It installs kernel
# and libc fixes every morning, and without this the server never boots into
# them. The reboot waits for 04:00, when nobody uses the sites. A file of its
# own rather than an edit to 50unattended-upgrades, which the package owns.
# Runs twice safely: the drop-in is rewritten, and the last line prints the
# settings apt actually reads.
auto-reboot:
	ssh $(ROOT) 'printf "Unattended-Upgrade::Automatic-Reboot \"true\";\nUnattended-Upgrade::Automatic-Reboot-Time \"04:00\";\n" > /etc/apt/apt.conf.d/52auto-reboot && apt-config dump | grep -E "^Unattended-Upgrade::Automatic-Reboot"'

# The house's way out: a WireGuard tunnel, wg0, that the house's gateway opens,
# and the rules that let its traffic leave by eth0 under this server's address
# (servers/vserver.md, "The house's way out"). systemd-networkd brings wg0 up,
# as it does eth0, so the tunnel runs no service of its own; wireguard-tools
# brings only the `wg` command, for keys and for looking. The server's key is
# made on the server and never leaves it. wg0 starts with no peer — `make
# wg-house` adds the gateway. Runs twice safely: a key that exists is kept, the
# files are rewritten, the script adds only a rule that is missing, and the last
# line prints the tunnel and the rules the kernel actually has. servers/wg-exit
# and servers/wg-house hold the same numbers — 10.77.0.0/24, MTU 1380, port
# 51820 — and change with them. So does caddy/Caddyfile: its house-only
# snippet lets in the house's end of the tunnel, 10.77.0.2, and nothing else.
wg-exit:
	scp servers/wg-exit $(ROOT):/usr/local/sbin/wg-exit
	ssh $(ROOT) 'chmod 0755 /usr/local/sbin/wg-exit && sh -n /usr/local/sbin/wg-exit'
	ssh $(ROOT) 'NEEDRESTART_SUSPEND=1 DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends -o DPkg::Lock::Timeout=300 wireguard-tools'
	ssh $(ROOT) 'cd /etc/systemd/network && { test -s wg0.key || (umask 077 && wg genkey > wg0.key); } && chgrp systemd-network wg0.key && chmod 0640 wg0.key'
	ssh $(ROOT) 'printf "%s\n" "[NetDev]" "Name=wg0" "Kind=wireguard" "MTUBytes=1380" "" "[WireGuard]" "ListenPort=51820" "PrivateKeyFile=/etc/systemd/network/wg0.key" > /etc/systemd/network/50-wg0.netdev'
	ssh $(ROOT) 'printf "%s\n" "[Match]" "Name=wg0" "" "[Network]" "Address=10.77.0.1/24" "" "[Link]" "RequiredForOnline=no" > /etc/systemd/network/50-wg0.network'
	ssh $(ROOT) 'printf "net.ipv4.ip_forward = 1\n" > /etc/sysctl.d/60-wg-exit.conf && sysctl -p /etc/sysctl.d/60-wg-exit.conf'
	ssh $(ROOT) 'printf "%s\n" "[Unit]" "Description=Forwarding and NAT for the house tunnel, wg0" "After=docker.service" "Requires=docker.service" "" "[Service]" "Type=oneshot" "RemainAfterExit=yes" "ExecStart=/usr/local/sbin/wg-exit" "" "[Install]" "WantedBy=multi-user.target" > /etc/systemd/system/wg-exit.service'
	ssh $(ROOT) 'networkctl reload && systemctl daemon-reload && systemctl enable --now wg-exit && wg show wg0 && iptables -S DOCKER-USER && iptables -t nat -S POSTROUTING && iptables -t mangle -S FORWARD'

# Gives the house's gateway a new key, and saves the WireGuard file its VPN
# client reads to $(WG_HOUSE_CONF), mode 0600 (servers/vserver.md, "The house's
# way out"). The script runs on the server from stdin, so it never lands there,
# and the gateway's private key goes into that file and nowhere else. Upload the
# file to the gateway, then delete it: whoever holds it can send anything
# through the server, under the server's address. Every run makes a new key and
# retires the old one — a second run is how the key is changed, and the house
# is offline until its gateway has the new file.
WG_HOUSE_CONF = $(HOME)/Downloads/vserver-wireguard.conf

wg-house:
	sh -n servers/wg-house
	rm -f '$(WG_HOUSE_CONF)'
	umask 077 && ssh $(ROOT) sh -s < servers/wg-house > '$(WG_HOUSE_CONF)'
	ssh $(ROOT) 'wg show wg0'
	ls -l '$(WG_HOUSE_CONF)'

# How you find out: a timer that asks the server whether it is healthy every
# five minutes, and pings a dead man's switch outside it (servers/vserver.md,
# "How you find out"). The ping URL is a secret, written by hand to
# /etc/health-check.url, mode 0400. This target refuses to start the timer
# without it. Runs twice safely: the script and units are rewritten, and the
# last line runs the check once and prints the timer.
health-check:
	sh -n servers/health-check
	scp servers/health-check $(ROOT):/usr/local/sbin/health-check
	scp servers/health-check.service servers/health-check.timer $(ROOT):/etc/systemd/system/
	ssh $(ROOT) 'chmod 0755 /usr/local/sbin/health-check && test -s /etc/health-check.url || { echo "write the ping URL to /etc/health-check.url, mode 0400, first" >&2; exit 1; }'
	ssh $(ROOT) 'systemctl daemon-reload && systemctl enable --now health-check.timer && systemctl start health-check.service && journalctl -u health-check.service -n 10 --no-pager && systemctl list-timers health-check.timer'

# The server's own state and each application's data, onto this Mac, as one
# dated tar.gz in ~/Backups/vserver (runbooks/restore.md, "Get the server's own
# state back" and "Get an application's data back"). Each application stops
# for the seconds its copy takes. servers/backup runs on the server from
# stdin, as wg-house does, and installs nothing there. servers/backup-pull is
# the Mac's half: it refuses without FileVault, keeps the newest 30, and pings
# the backup's dead man's switch when $(BACKUP_PING) exists. Run it as often
# as you like.
BACKUP_AGENT = com.andygeiss.vserver-backup
BACKUP_HOME  = $(HOME)/.local/share/vserver-backup
BACKUP_PING  = $(HOME)/.config/vserver-backup/ping.url
BACKUP_PLIST = $(HOME)/Library/LaunchAgents/$(BACKUP_AGENT).plist

backup:
	sh -n servers/backup-pull
	ROOT='$(ROOT)' BACKUP_PING_FILE='$(BACKUP_PING)' sh servers/backup-pull

# The same backup every night at 02:30, from launchd, so it no longer waits for
# you to remember it. The files are copied, as claude-sandbox's are, never
# linked: the agent in the sandbox can edit this checkout, and this job runs
# ssh as root on the server. So a change here reaches the nightly run only
# through this target — read the diff first. The ping URL is a secret, written
# by hand, mode 0400, and this target refuses without it: a nightly backup
# nobody hears about is the gap it closes. Runs twice safely: the copies and
# the plist are rewritten, the agent is booted out and in again, and the last
# line prints what launchd actually has.
backup-daily:
	sh -n servers/backup-pull && sh -n servers/backup
	test -s '$(BACKUP_PING)' || { echo "write the backup's ping URL to $(BACKUP_PING), mode 0400, first" >&2; exit 1; }
	mkdir -p '$(BACKUP_HOME)' '$(HOME)/Library/LaunchAgents' '$(HOME)/Library/Logs'
	install -m 0755 servers/backup-pull '$(BACKUP_HOME)/'
	install -m 0644 servers/backup '$(BACKUP_HOME)/'
	install -m 0644 servers/$(BACKUP_AGENT).plist '$(BACKUP_PLIST)'
	launchctl bootout gui/$$(id -u)/$(BACKUP_AGENT) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) '$(BACKUP_PLIST)'
	launchctl print gui/$$(id -u)/$(BACKUP_AGENT) | grep -E '^\s(state|last exit code) ='

# Stops the nightly backup and forgets it. The archives stay.
backup-daily-stop:
	launchctl bootout gui/$$(id -u)/$(BACKUP_AGENT) 2>/dev/null || true
	rm -f '$(BACKUP_PLIST)'
	rm -rf '$(BACKUP_HOME)'

# Checks the server against servers/vserver.md and changes nothing: every
# claim the document makes that a command can answer, one line each, ok or
# FAIL. The script runs from stdin, as wg-house does, and takes Docker's
# versions from VERSIONS.md, so neither lives in two places. Run it after any
# change to the server, after a rebuild, and as the quarterly re-verify.
verify-host:
	sh -n servers/verify-host
	ssh $(ROOT) sh -s -- \
		"$$(sed -n 's/^| Docker Engine | \*\*\([^*]*\)\*\*.*/\1/p' VERSIONS.md)" \
		"$$(sed -n 's/^| Docker Compose | \*\*\([^*]*\)\*\*.*/\1/p' VERSIONS.md)" \
		< servers/verify-host

# The house side of the oMLX tunnel: a launchd agent that keeps one `ssh -R`
# open, so the proxy — and any container on the server — reaches the model host
# at 172.17.0.1:18000 (servers/vserver.md, "Tunnels from the house"). It lives
# in this repository rather than in an application's Makefile because an
# application that owned it could take the site down by uninstalling, which is
# what nearly happened when kai-orchestrator was removed. macOS only — launchd
# is what brings the tunnel back after a reboot, with no login shell to start
# it.
TUNNEL_AGENT  = com.andygeiss.omlx-tunnel
TUNNEL_REMOTE = andygeiss@vserver
TUNNEL_BIND   = 172.17.0.1:18000
TUNNEL_LOCAL  = 127.0.0.1:8000
TUNNEL_PLIST  = $(HOME)/Library/LaunchAgents/$(TUNNEL_AGENT).plist
TUNNEL_LOG    = $(HOME)/Library/Logs/$(TUNNEL_AGENT).log

# Runs twice safely: the plist is rewritten, the running agent booted out, and
# the last line prints the state and pid launchd actually has. Two options
# carry the tunnel rather than decorate it — ExitOnForwardFailure, so a
# refused bind kills the ssh instead of leaving one up that forwards nothing,
# and KeepAlive, so launchd starts it again.
omlx-tunnel:
	mkdir -p '$(HOME)/Library/LaunchAgents'
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>Label</key><string>%s</string>\n\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>/usr/bin/ssh</string>\n\t\t<string>-N</string>\n\t\t<string>-o</string><string>BatchMode=yes</string>\n\t\t<string>-o</string><string>ExitOnForwardFailure=yes</string>\n\t\t<string>-o</string><string>ServerAliveInterval=30</string>\n\t\t<string>-o</string><string>ServerAliveCountMax=3</string>\n\t\t<string>-R</string><string>%s</string>\n\t\t<string>%s</string>\n\t</array>\n\t<key>RunAtLoad</key><true/>\n\t<key>KeepAlive</key><true/>\n\t<key>ThrottleInterval</key><integer>10</integer>\n\t<key>StandardErrorPath</key><string>%s</string>\n</dict>\n</plist>\n' '$(TUNNEL_AGENT)' '$(TUNNEL_BIND):$(TUNNEL_LOCAL)' '$(TUNNEL_REMOTE)' '$(TUNNEL_LOG)' > '$(TUNNEL_PLIST)'
	launchctl bootout gui/$$(id -u)/$(TUNNEL_AGENT) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) '$(TUNNEL_PLIST)'
	launchctl print gui/$$(id -u)/$(TUNNEL_AGENT) | grep -E '^\s(state|pid) ='

# Stops the tunnel and forgets it. bootout alone is not enough: the plist would
# still be in LaunchAgents, and the next login would start it again.
omlx-tunnel-stop:
	launchctl bootout gui/$$(id -u)/$(TUNNEL_AGENT) 2>/dev/null || true
	rm -f '$(TUNNEL_PLIST)'

# The sandbox Claude Code runs in on the Mac you work on: a rootless podman
# container that sees one directory under ~/workspace, plus two skills
# read-only, and reaches only public HTTPS addresses, through egress
# (runbooks/claude-sandbox.md). The files are copied, where `install` above
# symlinks: an agent in the sandbox can write to this checkout, and a launcher
# it could edit would let it out on the next start. So a change here reaches
# the sandbox only through this target — read the diff first. `install`
# replaces a file rather than writing into it, so a session that is running
# keeps the launcher it started with. Runs twice safely: the copy is
# rewritten, the image is built again with --pull, which brings the base
# images' patches, and the last line prints the Claude Code version the image
# actually runs. The launcher names the same directory and connection.
SANDBOX_DIR  = $(HOME)/.local/share/claude-sandbox
SANDBOX_CONN = podman-machine-default

claude-sandbox:
	sh -n claude-sandbox/claude-sandbox
	mkdir -p '$(SANDBOX_DIR)' '$(HOME)/.local/bin'
	install -m 0644 claude-sandbox/Containerfile '$(SANDBOX_DIR)/'
	install -m 0644 claude-sandbox/instructions.md '$(SANDBOX_DIR)/'
	install -m 0755 claude-sandbox/claude-sandbox '$(SANDBOX_DIR)/'
	ln -sf '$(SANDBOX_DIR)/claude-sandbox' '$(HOME)/.local/bin/claude-sandbox'
	v=$$(sed -n 's/^ARG CLAUDE_CODE_VERSION=//p' claude-sandbox/Containerfile) && podman --connection $(SANDBOX_CONN) build --pull -t "localhost/claude-sandbox:$$v" '$(SANDBOX_DIR)' && podman --connection $(SANDBOX_CONN) run --rm "localhost/claude-sandbox:$$v" claude --version
