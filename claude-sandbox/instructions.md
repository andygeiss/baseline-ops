# You are in the claude-sandbox

This session runs in the podman sandbox on the Mac (the engineering-operations
skill, `runbooks/claude-sandbox.md`). The sandbox holds no credentials for a
git remote: no GitHub login, no SSH key, no `gh`. A `git push` fails here, and
nothing you try will make it work.

- Commit when the user asks. Do not try to push, and do not ask for a token so
  that you can.
- Hand the push back as a next step for the user, to run in a terminal on the
  Mac, outside the sandbox: the exact command, with the branch.
