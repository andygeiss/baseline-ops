# Repository tooling. This repo has no code to build; `install` and `uninstall`
# wire it into the current user's Claude Code as a personal skill, and two
# targets set up a machine rather than build anything: `sshd-tunnel` on the
# server and `omlx-tunnel` on the house machine — each a single line that
# must be typed exactly, so it is not typed. `install` is the first
# target: a bare `make` installs.

SKILL_DIR = $(HOME)/.claude/skills/engineering-operations

# Host setup only. Every runbook uses the deploy account; root is for the
# few things that change sshd or install a package. Override per run:
# make sshd-tunnel ROOT=root@other-host
ROOT = root@vserver

.PHONY: install omlx-tunnel omlx-tunnel-stop sshd-tunnel uninstall

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
