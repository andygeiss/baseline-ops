# Repository tooling. This repo has no code to build; these targets wire it
# into the current user's Claude Code as a personal skill. `install` is the
# first target: a bare `make` installs.

SKILL_DIR = $(HOME)/.claude/skills/engineering-operations

.PHONY: install uninstall

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
