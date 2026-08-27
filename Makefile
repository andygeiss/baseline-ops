# Repository tooling. This repo has no code to build; `install` and `uninstall`
# wire it into the current user's Claude Code as a personal skill, and
# `sshd-tunnel` is the one piece of server setup with a target: a single line
# that must be typed exactly, so it is not typed. `install` is the first
# target: a bare `make` installs.

SKILL_DIR = $(HOME)/.claude/skills/engineering-operations

# Host setup only. Every runbook uses the deploy account; root is for the
# few things that change sshd or install a package. Override per run:
# make sshd-tunnel ROOT=root@other-host
ROOT = root@vserver

.PHONY: install sshd-tunnel uninstall

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
