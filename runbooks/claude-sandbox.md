# Runbook: Claude Code sandbox

**Last verified: 2026-10-27**

`claude-sandbox` runs Claude Code in a rootless podman container on the Mac you
work on. The agent sees the directory you start it in — `~/workspace` or one
below it — and two skills, read-only. It sees nothing else of the Mac. It
reaches the internet only through
[egress](https://github.com/andygeiss/egress), a proxy that lets through HTTPS
to public addresses and nothing else: not the Mac, and not your LAN.

```sh
cd ~/workspace/baseline-reference
claude-sandbox                                  # Claude Code, in the sandbox
claude-sandbox --continue                       # every claude argument passes through
claude-sandbox --dangerously-skip-permissions   # no prompts: the sandbox is the limit
claude-sandbox --shell                          # a shell in the same sandbox, to look around
```

## What the agent reaches, and what it does not

| Reaches | Does not reach |
|---|---|
| The directory it started in, read and write, at the same path as on the Mac. What it changes there are your files. | The rest of the Mac: your home, `~/.ssh`, the keychain, every other project but the two skills, and the `~/.claude` of the Claude Code you run outside the sandbox. |
| A home of its own: one podman volume per directory, holding Claude's settings and sessions, and Go's caches. | Another directory's volume, so the sessions of one project never show up in another. |
| The skills `engineering-baseline` and `engineering-operations`, read-only. | A write to either skill: the Claude Code outside the sandbox follows them too. |
| Any public HTTPS site, through the proxy: what `curl` and WebFetch fetch. WebSearch too, which runs on Anthropic's side. | A private address, whatever name points at it: the Mac's own services, your LAN, the podman machine. Plain HTTP, ports other than 443, and DNS. |
| | Root, a Linux capability, or a write outside its home, the directory, and `/tmp`. |
| | claude.ai connectors, which reach your mail and your files, or publishing pages to claude.ai. The image turns both off. |
| | A git remote. The sandbox holds no GitHub login, no SSH key, and no `gh`, so `git push` fails. The agent commits, and you push from the Mac. The image's `/etc/claude-code/CLAUDE.md`, from [`claude-sandbox/instructions.md`](../claude-sandbox/instructions.md), tells every session so. |

## How a session runs

One session is two containers from one image, on the rootless side of the
default podman machine. The Mac's default connection is the rootful one, and
`--userns keep-id`, which makes the agent's files yours, works only rootless.

```
agent ──(network claude-sandbox: no gateway, no DNS)──▶ proxy ──(podman network)──▶ public addresses, port 443
```

- **The agent** runs as uid 1000, which podman maps to your Mac user, with no
  capabilities and a read-only root filesystem. Its only route anywhere is the
  proxy, through `HTTPS_PROXY`.
- **The proxy** is egress, running as `nobody`. It lets a CONNECT to port 443
  through when the address it connects to is public. It checks that address
  after DNS, so a name that points into your LAN is refused like the address
  itself. It stops when the session ends. A launcher killed outright cannot
  stop it, so the next `claude-sandbox` does, once that session's agent is
  gone too.

## The skills it reads

The agent gets two skills of the Claude Code you run on the Mac,
`engineering-baseline` and `engineering-operations`, in `~/.claude/skills`.
Each is the checkout that the Mac's `~/.claude/skills/<name>` links to, so
`make install` in that repository is what puts it there. Both are read-only:
the Claude outside the sandbox follows the same files, and an agent that could
edit them could steer that Claude.

The launcher leaves out a skill it cannot find, or one outside `~/workspace`,
and says which. To give the agent another skill, add its name to the list in
[`claude-sandbox/claude-sandbox`](../claude-sandbox/claude-sandbox), then run
`make claude-sandbox`.

## The status line

Claude Code in the sandbox shows the same status line as on the Mac:
[statusline](https://github.com/andygeiss/statusline), built into the image.
The image's `/etc/claude-code/managed-settings.json` points Claude Code at it,
and starts every session on Opus 5.5 (`claude-opus-5-5`); `/model` switches
for one session. A setting in `~/.claude` would live in each directory's volume, which an image
change never reaches.

```text
…/workspace/sandbox-status-check │ Opus 5.5 │ medium │ ⎇ main
```

The directory starts with `…`, not `~`: the agent's home is `/home/agent`, so
statusline cannot shorten your path the way it does on the Mac.

## Install, once per Mac

The podman machine is a Linux VM, and it must share only `~/workspace` with
the Mac. Out of the box it shares all of `/Users`, `/private`, and
`/var/folders`, and `~/.config/containers` read-write — the folder that holds
the machine's own settings, the shared folders among them. So the default
machine is replaced with one that shares `~/workspace` and nothing else.

Removing a machine deletes every image, container and volume in it, so save
what you need first. `podman volume export <volume> --output <file>` writes a
volume to a tar file, and `podman volume import` reads it back into the new
machine. Then:

```sh
podman machine stop
podman machine rm podman-machine-default
podman machine init --rootful --volume "$HOME/workspace:$HOME/workspace"
podman machine start
podman machine ssh ls -A "$HOME"            # workspace: nothing else of your home
```

`--volume` replaces podman's whole default list, so the one folder named is the
only one shared. `--rootful` keeps the machine's default connection rootful;
the sandbox uses the rootless one either way.

Rosetta goes with `~/.config/containers`: podman 6.1 switches it on through
that folder and has no flag for it. amd64 images still run, through QEMU, only
slower. Every image the sandbox and the templates use has an arm64 build.

From then on, no container on this Mac can bind-mount a folder outside
`~/workspace`. That is why abi-peak's local proxy lives in
`~/workspace/abi-peak/caddy`, apart from its services' stacks.

Then, from this repository:

```sh
make claude-sandbox    # the last line prints the Claude Code version the image runs
```

The target copies the files to `~/.local/share/claude-sandbox` and links the
launcher into `~/.local/bin`. The copy is the point, not a detail. The launcher
decides what the agent sees, and the agent can edit this checkout. A launcher
it could edit would let it out on its next start. So a change in
`claude-sandbox/` reaches the sandbox only through `make claude-sandbox`, and
you read the diff first.

## Sign in, once per Mac

The sandbox signs in with a token. Claude Code does not start without one.
Making the token needs a Claude subscription. On the Mac, outside the sandbox:

```sh
claude setup-token                                                 # prints a token that lasts a year
security add-generic-password -U -a "$USER" -s claude-sandbox -w   # paste it at the prompt
```

The launcher reads the token from the keychain at every start and gives it to
the agent as `CLAUDE_CODE_OAUTH_TOKEN`. With no token, it stops and prints
these two commands. Only `claude-sandbox --shell` starts without one.

A token, not `/login`: a `/login` sign-in would live in one directory's volume,
so every new directory would ask again. And `claude-sandbox -p` cannot answer
a sign-in prompt at all.

Claude's own first-run setup would still ask, in every new directory: a theme
picker, then a sign-in prompt that the token makes pointless, then whether you
trust the folder. So the launcher marks that setup done in the directory's
volume before Claude starts, and answers the trust question with yes: you chose
the folder when you started the sandbox in it.

The token lasts a year. When it runs out, run both commands again: `-U`
replaces the old token in the keychain.

## Check that it holds

Run these after an install or an upgrade, in any directory under `~/workspace`:

```sh
claude-sandbox --shell -c "ls -A $HOME"    # workspace: nothing else of your home
claude-sandbox --shell -c 'ls ~/.claude/skills'    # engineering-baseline  engineering-operations
claude-sandbox --shell -c 'touch ~/.claude/skills/engineering-baseline/x'    # Read-only file system
claude-sandbox --shell -c 'jq -c "[.hasCompletedOnboarding, .projects[\"$PWD\"].hasTrustDialogAccepted]" ~/.claude.json'    # [true,true]: no setup, no trust question
claude-sandbox -p --output-format stream-json --verbose hi | jq -c 'select(.subtype == "init") | .skills | map(select(startswith("engineering-")))'    # both skills: Claude found them
claude-sandbox --shell -c 'curl -s -o /dev/null -w "%{http_code}\n" https://example.com/'    # 200: a public site answered
claude-sandbox --shell -c 'curl -sS https://192.168.1.1/'    # CONNECT tunnel failed, response 403
claude-sandbox --shell -c 'curl -sS https://host.containers.internal/'    # the same 403: that name is the Mac
claude-sandbox -p --allowedTools=WebFetch 'Fetch https://example.com/ and reply with its title only'    # Example Domain
```

The third one ends with the launcher naming what the proxy refused:

```text
claude-sandbox: the proxy refused these — it lets through HTTPS to public addresses only:
   1 192.168.1.1:443 (192.168.1.1 is not a public address)
```

## Read what the proxy refused

A session ends with that list whenever egress refused something. Nothing in
this repository lets one of them through: what counts as public is egress's
own code, and changing it is an egress release. So the list is for reading.

- **A private address** means something sent the agent toward the Mac or your
  LAN: a page it read, a file in the directory, or your own prompt. Find out
  which before you run what it wrote.
- **A port other than 443, or plain HTTP,** is a tool that asked for something
  egress does not carry. It carries HTTPS on port 443, and nothing else.

## Upgrade Claude Code, egress, or statusline

Bump `ARG CLAUDE_CODE_VERSION`, `ARG EGRESS_VERSION`, or
`ARG STATUSLINE_VERSION` in
[`claude-sandbox/Containerfile`](../claude-sandbox/Containerfile), and its row
in [VERSIONS.md](../VERSIONS.md), then:

```sh
make claude-sandbox                                       # the last line prints Claude Code's version
claude-sandbox --shell -c 'egress -version; statusline version'    # then egress's and statusline's
podman --connection podman-machine-default image prune    # drops the image it replaced
```

The image never updates itself (`DISABLE_AUTOUPDATER=1`). Run
`make claude-sandbox` after a Go patch release too: it builds with `--pull`, so
the image picks up Go's and Debian's patches under the minor tags.

GitHub builds the same image every Tuesday, and on every change to
`claude-sandbox/` — [`.github/workflows/claude-sandbox.yml`](../.github/workflows/claude-sandbox.yml).
A red run means something moved upstream: a base image, a Debian package, or
the way Claude Code's npm package ships its binary. The run names the check
that failed. Fix it here before your next `make claude-sandbox`, which would
build the same broken image.

The Tuesday run also turns red while `ARG CLAUDE_CODE_VERSION` is behind npm's
latest release, and names that release. That is the reminder to upgrade, above:
the image still builds, it is only behind.

## Start a directory over, or remove the sandbox

A directory's volume holds its settings and sessions. Remove the volume, and
the next start in that directory begins from nothing:

```sh
podman --connection podman-machine-default volume ls --filter name=claude-sandbox
podman --connection podman-machine-default volume rm claude-sandbox-<name>-<hash>
```

To remove the whole sandbox, remove those volumes, then:

```sh
rm ~/.local/bin/claude-sandbox
rm -r ~/.local/share/claude-sandbox
podman --connection podman-machine-default rmi $(podman --connection podman-machine-default images -q localhost/claude-sandbox)
podman --connection podman-machine-default network rm claude-sandbox
security delete-generic-password -s claude-sandbox
```

## What the sandbox does not stop

- **The directory works both ways.** Files the agent writes there run on your
  Mac later, outside the sandbox. A hook in `.git/hooks`, or a
  `core.hooksPath` in `.git/config`, runs on your next `git commit`. A
  `Makefile`, an `.envrc`, or the hooks in `.claude/settings.json` run when
  you use them. Read the diff before you run anything in a directory the agent
  worked in.
- **Started in `~/workspace` itself, the agent reaches every project.** That
  includes `baseline/` and `baseline-ops/`: the skills of the Claude Code you
  run outside the sandbox, and this launcher's source. Start it in the project
  instead. Started in `baseline/` or `baseline-ops/`, it can change that one
  skill: the skill's mount is read-only, but the project's is not.
- **The podman machine shares all of `~/workspace`.** The container shows the
  agent one directory, but the Linux VM it runs in sees every project. An
  agent that broke out of the container, through a bug in podman or in the
  Linux kernel, would see them too — and nothing else of the Mac.
- **The launcher answers Claude's trust question for you.** It says yes for
  the folder you start in, so the project's own settings and hooks in
  `.claude/` take effect without asking. They run inside the sandbox, like
  everything else the agent runs.
- **The agent reads the open web.** A page can carry instructions, and the
  agent may follow them: write something into the directory, or send your code
  to any public HTTPS site. egress keeps the agent off the Mac and your LAN. It
  does not keep your code in.
- **The agent can read its own sign-in.** The token is in its environment, and
  egress lets it reach any public host. Whoever gets the token can use your
  Claude subscription with it.
- **On `KNOPPERS`, the agent gets as far as what only the house may open.**
  egress judges the address, not who is asking. A Mac on `KNOPPERS` reaches
  vserver through the house's tunnel, from `10.77.0.2`, the one address a
  `house-only` site lets in. So the agent can open Portainer's login page, and
  the password is all that stands between it and root on vserver
  ([runbooks/portainer.md](portainer.md)).
