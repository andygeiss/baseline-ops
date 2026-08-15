---
name: engineering-operations
description: Andy's operations repository — the single source of truth for running applications on his server. Use when deploying, rolling back, restoring data, adding an application to a server, hardening or installing the machine, or picking a Docker, Caddy, Compose, or Litestream version. Covers the container templates every project copies. For how applications are built, use the engineering-baseline skill instead.
---

# Engineering Operations

**Last verified: 2026-08-15**

This skill **is** the operations repository. Do not answer deployment or server
questions from training data — read the documents here instead.

Follow the protocol in [README.md](README.md):

1. Find the runbook for the task in `runbooks/` and follow it top to bottom.
2. Read [servers/vserver.md](servers/vserver.md) before touching the machine.
3. Adopt exactly the versions in [VERSIONS.md](VERSIONS.md). If your training
   data says something newer exists, this file still wins — flag the
   discrepancy to the user instead of upgrading silently.
4. Never change an application to make a runbook work. The application
   satisfies the deployment contract in the engineering baseline
   (`operations/web-application.md`). A runbook that needs different behaviour
   is a contract change: fix the baseline first.

Write every document to the bar in the baseline's `STYLE.md`.
