# Repository tooling. This repo has no code to build; `install` and `uninstall`
# wire it into the current user's Claude Code as a personal skill, and three
# targets set up a machine rather than build anything: `sshd-tunnel` and
# `conn-limits` on the server, `omlx-tunnel` on the house machine — each a line
# that must be typed exactly, so it is not typed. `install` is the first
# target: a bare `make` installs.

SKILL_DIR = $(HOME)/.claude/skills/engineering-operations

# Host setup only. Every runbook uses the deploy account; root is for the
# few things that change sshd or install a package. Override per run:
# make sshd-tunnel ROOT=root@other-host
ROOT = root@vserver

.PHONY: conn-limits install omlx-tunnel omlx-tunnel-stop sshd-tunnel uninstall

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

# Lets an `ssh -R` from a house machine bind the server's docker0 address
# (172.17.0.1) instead of loopback, so a container can reach a service the
# house carries in — servers/vserver.md, "Tunnels from the house". Runs twice
# safely: the drop-in is rewritten, sshd -t checks it before the reload, and
# the last line prints the settings sshd actually runs with.
sshd-tunnel:
	ssh $(ROOT) 'printf "GatewayPorts clientspecified\nClientAliveInterval 30\nClientAliveCountMax 3\n" > /etc/ssh/sshd_config.d/10-tunnel.conf && sshd -t && systemctl reload ssh && sshd -T | grep -E "^(gatewayports|clientaliveinterval|clientalivecountmax) "'

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
