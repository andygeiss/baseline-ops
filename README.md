# Engineering Operations

**Single source of truth for running the applications.** How they are *built* is
the [engineering baseline](https://github.com/andygeiss/baseline)'s job; this
repository answers three different questions: what is on the server, how an
application gets there, and what to do when something breaks.

The split is deliberate. A fact belongs here when it changes only the server,
and in the baseline when it changes the code:

| Question | Repository |
|---|---|
| "Does the app log to stdout, and on which port does `/healthz` live?" | baseline |
| "Which proxy terminates TLS, and where do its certificates live?" | here |

- **Last verified:** 2026-08-27
- **Servers:** one — `vserver`. Everything here is written for it.
- **Format:** Markdown, plus the templates every application copies, one
  script the server runs, and the sandbox Claude Code runs in on the Mac. No
  application code.

## How to use this repository (AI agents)

1. **Find the runbook** for what you are doing in [`runbooks/`](runbooks/).
   Follow it top to bottom; do not improvise a step.
2. **Read [`servers/vserver.md`](servers/vserver.md)** before touching the
   machine for the first time. It says what is installed and why.
3. **Check [`VERSIONS.md`](VERSIONS.md)** for every image and package version.
   If your training data says something newer exists, this file still wins —
   flag the discrepancy instead of upgrading silently.
4. **Never change an application to make a runbook work.** The application
   satisfies the deployment contract in the baseline's
   `operations/web-application.md`. If a runbook needs the app to behave
   differently, that is a contract change: fix the baseline first, then the app,
   then come back.

Rules use RFC-2119 keywords: **MUST**, **MUST NOT**, **SHOULD**, **MAY**.
Prose follows the baseline's `STYLE.md`.

## Install into Claude Code

```sh
make install    # symlinks this repo to ~/.claude/skills/engineering-operations
make uninstall  # removes the symlink
```

## Server setup that runs from here

```sh
make sshd-tunnel    # once per server: let a house machine's ssh -R bind docker0
make conn-limits    # once per server: cap what one address may open on :443
make auto-reboot    # once per server: reboot at 04:00 when an update needs it
make wg-exit        # once per server: let the house's WireGuard tunnel out to the internet
make wg-house       # once, and again to change the key: the house gateway's WireGuard file
make omlx-tunnel    # on the house Mac: hold the oMLX tunnel open, across reboots
make claude-sandbox # on the Mac you work on: Claude Code in a sandbox that sees one directory
```

Seven targets, and none of them an application's. Two are the two sides of one
tunnel — the server's sshd drop-in and the Mac's launchd agent (`make
omlx-tunnel-stop` takes that one away again); [servers/vserver.md](servers/vserver.md),
"Tunnels from the house", says why a house machine carries a service in over
SSH, and who owns the command. The third caps what a single address may open on
the public port, in the one chain a published Docker port cannot walk around —
same document, "Limits on what one address may open". The fourth lets the
server boot into the kernel and libc fixes it installs by itself — same
document, "Updates and the nightly reboot". The last two carry the house's own
traffic out to the internet, over a WireGuard tunnel the house's gateway opens:
`wg-exit` sets up the server's side, and `wg-house` gives the gateway its key —
same document, "The house's way out".

The seventh sets up the Mac you work on, not a server: `make claude-sandbox`
installs the sandbox Claude Code runs in there
([runbooks/claude-sandbox.md](runbooks/claude-sandbox.md)). Unlike `make
install`, it copies its files out of this checkout instead of linking them,
because the agent inside the sandbox can edit the checkout.

Two stacks are the server's own rather than an application's, and this
repository deploys them: [`caddy/`](caddy/), the one proxy every application
sits behind ([runbooks/caddy.md](runbooks/caddy.md)), and
[`portainer/`](portainer/), the optional look at what is running
([runbooks/portainer.md](runbooks/portainer.md)). Neither has a `make` target
yet — the steps have not run twice.

## Repository structure

```
baseline-ops/
├── .github/workflows/
│   └── templates.yml           ← builds templates/Dockerfile against baseline-reference
├── bin/
│   └── deploy                  ← runbooks/deploy.md as one command: ship a tag, or roll back
├── caddy/                      ← the server's one proxy stack; deployed from here, copied by nobody
│   ├── Caddyfile               ← the policy every site shares, plus `import sites/*`
│   └── compose.yaml
├── claude-sandbox/             ← the sandbox Claude Code runs in on the Mac; make claude-sandbox installs it
│   ├── allowlist               ← the hosts the agent may reach, and nothing else
│   ├── claude-sandbox          ← the launcher: one session, two containers
│   ├── Containerfile           ← the image both containers run
│   └── tinyproxy.conf          ← the proxy: HTTPS to the allowlist only
├── LICENSE                     ← MIT
├── Makefile                    ← make install / make uninstall (Claude Code); make sshd-tunnel + make conn-limits + make auto-reboot + make wg-exit + make wg-house (server), make omlx-tunnel (house Mac), make claude-sandbox (the Mac you work on)
├── portainer/                  ← the optional look at what is running; the server's own stack, like caddy/
│   └── compose.yaml
├── README.md                   ← you are here
├── runbooks/                   ← procedures, in the order you run them
│   ├── caddy.md                ← install the proxy; add or remove a site; upgrade it
│   ├── claude-sandbox.md       ← run Claude Code in a sandbox that sees one directory; widen what it reaches
│   ├── deploy.md               ← ship a tagged release; roll one back
│   ├── host.md                 ← patch the host and reboot it by hand; check it after any reboot
│   ├── new-app.md              ← put an application on the server the first time
│   ├── portainer.md            ← install Portainer behind the proxy; reach it; upgrade it
│   └── restore.md              ← get the data back
├── servers/
│   ├── conn-limits             ← per-address limits on :443; make conn-limits ships it
│   ├── vserver.md              ← the machine: what is installed, which accounts, which ports
│   ├── wg-exit                 ← forwarding and NAT for the house's tunnel; make wg-exit ships it
│   └── wg-house                ← a new key for the house's gateway; make wg-house runs it
├── SKILL.md                    ← makes the repo a Claude Code skill
├── templates/                  ← copied into each application repository
│   ├── compose.yaml
│   ├── dockerignore            ← copy as .dockerignore
│   └── Dockerfile
└── VERSIONS.md                 ← pinned versions, dated, with sources
```

## How the templates are verified

The container templates are the only files here a machine can check, and nothing
in this repository can build them — it holds no code. So
[`.github/workflows/templates.yml`](.github/workflows/templates.yml) borrows
some: it checks out
[baseline-reference](https://github.com/andygeiss/baseline-reference), the
baseline's acceptance test, copies `templates/Dockerfile` and
`templates/dockerignore` in exactly as an application would, and builds the
image. It then runs the container under `compose.yaml`'s constraints —
read-only root, state volume, tmpfs, dropped capabilities — and asserts four
things the templates promise that nothing else would catch:

1. the image's own `HEALTHCHECK` reaches the ops listener and reports healthy;
2. `/healthz` names a real version, and names **the same one after a restart** —
   a build stage without `git`, or a `.dockerignore` that excludes `.git`, each
   silently leave the binary with no VCS metadata, and the baseline's canonical
   reader then answers a per-boot id rather than `unknown`. Only restarting the
   container tells the two apart;
3. the application answers on the port Caddy proxies;
4. the container runs as `10001:10001`, not root.

Nothing it builds ships: the image dies with the runner, and deploys stay
manual. The weekly run is the one that earns its keep — `alpine:3.24` and
`golang:1.27-alpine` are minor tags, so what they name changes under a template
nobody edited.

**`compose.yaml`, `caddy/`, and `portainer/` are not gated.** Validating either needs a server
context invented on the runner — an external `web` network, a secrets file, a
site file with a domain — and an invented context is one more thing that
drifts. Both are reviewed by hand against
[runbooks/new-app.md](runbooks/new-app.md) and
[runbooks/caddy.md](runbooks/caddy.md).

An application repository MUST NOT keep its own copy of a template under its own
edits. Copies nothing builds drift: baseline-reference carried one that had
grown extra directives, rewritten comments, and a link to a baseline document
that no longer exists — which is why the gate lives here now, and the copy does
not live there.

## What is deliberately not here

- **No Kubernetes, Swarm, or Nomad.** One host, Compose, a person who decides
  when to deploy. Anything more needs a written justification, and none is on
  file.
- **No image registry.** The server builds what it runs, from source that
  arrived over `scp`.
- **No CD pipeline.** The gates prove the code is good; a person decides when it goes
  live. The one exception is a CLI tool, whose release *is* its distribution —
  that stays in the baseline.
- **No secrets.** Every credential lives on the server, mode `0400`, and nowhere
  else. This repository names the files; it never contains them.
