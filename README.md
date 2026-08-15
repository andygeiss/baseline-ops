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

- **Last verified:** 2026-08-15
- **Servers:** one — `vserver`. Everything here is written for it.
- **Format:** Markdown, plus the templates every application copies. No code.

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

## Repository structure

```
baseline-ops/
├── LICENSE                     ← MIT
├── Makefile                    ← make install / make uninstall (Claude Code)
├── README.md                   ← you are here
├── runbooks/                   ← procedures, in the order you run them
│   ├── deploy.md               ← ship a tagged release; roll one back
│   ├── new-app.md              ← put an application on the server the first time
│   └── restore.md              ← get the data back
├── servers/
│   └── vserver.md              ← the machine: what is installed, which accounts, which ports
├── SKILL.md                    ← makes the repo a Claude Code skill
├── templates/                  ← copied into each application repository
│   ├── Caddyfile
│   ├── compose.yaml
│   ├── dockerignore            ← copy as .dockerignore
│   └── Dockerfile
└── VERSIONS.md                 ← pinned versions, dated, with sources
```

## What is deliberately not here

- **No Kubernetes, Swarm, or Nomad.** One host, Compose, a person who decides
  when to deploy. Anything more needs a written justification, and none is on
  file.
- **No image registry.** The server builds what it runs, from source that
  arrived over `scp`.
- **No CD pipeline.** CI proves the code is good; a person decides when it goes
  live. The one exception is a CLI tool, whose release *is* its distribution —
  that stays in the baseline.
- **No secrets.** Every credential lives on the server, mode `0400`, and nowhere
  else. This repository names the files; it never contains them.
