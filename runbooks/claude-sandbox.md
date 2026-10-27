# Runbook: Claude Code sandbox

**Last verified: 2026-10-27**

`claude-sandbox` runs Claude Code in a rootless podman container on the Mac you
work on. The agent sees the directory you start it in — `~/workspace` or one
below it — and nothing else of the Mac. It reaches the internet only through a
proxy that lets through the hosts in
[`claude-sandbox/allowlist`](../claude-sandbox/allowlist).

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
| The directory it started in, read and write, at the same path as on the Mac. What it changes there are your files. | The rest of the Mac: your home, `~/.ssh`, the keychain, the other projects, and the `~/.claude` of the Claude Code you run outside the sandbox. |
| A home of its own: one podman volume per directory, holding Claude's settings and sessions, and Go's caches. | Another directory's volume, so the sessions of one project never show up in another. |
| The hosts in `allowlist`, over HTTPS, through the proxy. | Any other host, DNS, the Mac's own services on `localhost`, or your LAN. |
| | Root, a Linux capability, or a write outside its home, the directory, and `/tmp`. |
| | claude.ai connectors, which reach your mail and your files, or publishing pages to claude.ai. The image turns both off. |
| | The web through WebSearch or WebFetch. WebSearch runs on Anthropic's side, where the proxy cannot see it, so the launcher starts Claude with both turned off. |

## How a session runs

One session is two containers from one image, on the rootless side of the
default podman machine. The Mac's default connection is the rootful one, and
`--userns keep-id`, which makes the agent's files yours, works only rootless.

```
agent ──(network claude-sandbox: no gateway, no DNS)──▶ proxy ──(podman network)──▶ allowlisted hosts
```

- **The agent** runs as uid 1000, which podman maps to your Mac user, with no
  capabilities and a read-only root filesystem. Its only route anywhere is the
  proxy, through `HTTPS_PROXY`.
- **The proxy** is tinyproxy, running as `nobody`. It filters by the
  `tinyproxy.conf` and `allowlist` built into the image, and stops when the
  session ends.

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

The token lasts a year. When it runs out, run both commands again: `-U`
replaces the old token in the keychain.

## Check that it holds

Run these after an install or an upgrade, in any directory under `~/workspace`:

```sh
claude-sandbox --shell -c "ls -A $HOME"    # workspace: nothing else of your home
claude-sandbox --shell -c 'curl -s -o /dev/null -w "%{http_code}\n" https://api.anthropic.com/'    # 404: the API answered
claude-sandbox --shell -c 'curl -sS https://example.com/'    # CONNECT tunnel failed, response 403
claude-sandbox -p --output-format stream-json --verbose hi | jq 'select(.subtype == "init") | .tools | index("WebSearch")'    # null: no WebSearch
```

The third one ends with the launcher naming the host it refused:

```text
claude-sandbox: the proxy refused these hosts (claude-sandbox/allowlist in baseline-ops lets one in):
   1 example.com
```

## Let the agent reach another host

Every session ends with that list, when the proxy refused something. Add the
host to [`claude-sandbox/allowlist`](../claude-sandbox/allowlist), one per
line, or `*.example.com` for every subdomain. Then run `make claude-sandbox`
and start a new session.

Each host you add is a place the agent can send your code to. Add the hosts a
task needs, not the ones that would be handy.

## Upgrade Claude Code

Bump `ARG CLAUDE_CODE_VERSION` in
[`claude-sandbox/Containerfile`](../claude-sandbox/Containerfile) and its row
in [VERSIONS.md](../VERSIONS.md), then:

```sh
make claude-sandbox                                       # the last line prints the new version
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
podman --connection podman-machine-default rmi localhost/claude-sandbox:2.1.310
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
  instead.
- **The podman machine shares all of `~/workspace`.** The container shows the
  agent one directory, but the Linux VM it runs in sees every project. An
  agent that broke out of the container, through a bug in podman or in the
  Linux kernel, would see them too — and nothing else of the Mac.
- **An allowed host can carry data out.** The agent sends your code to
  `api.anthropic.com`, because that is how Claude Code works. And the Go module
  proxy fetches any module path it is asked for, so a request can carry data
  to a server someone else runs. The allowlist makes a leak smaller. It does
  not make one impossible.
- **The agent can read its own sign-in.** The token is in its environment. It
  can send it only to the hosts above.
- **A Claude you start from `--shell` can search the web.** The launcher turns
  WebSearch and WebFetch off only for the Claude it starts itself.
