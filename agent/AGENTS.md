# Global working agreement

These rules apply in every directory, including inside subagents.
`~/.pi/agent/extensions/vcs-guard.ts` enforces the repository parts mechanically;
this file is the intent behind them.

## Publishing to remote hosts — always ask first

Never mutate shared/remote state without my **explicit approval in this
conversation**. Approval means I named the action, not that you inferred it from
an unrelated instruction.

Blocked pending approval (enforced by the extension):

- `git push` (any form, including `--force`, `--force-with-lease`, tags,
  `git send-email`, `git filter-branch`)
- `gh pr create|merge|close|review|comment`, `gh release`, `gh repo`, `gh api`
  with a write method — same for `glab`, `hub`, `arc`, `cr`
- Package/artifact publication: `npm|pnpm|yarn|cargo|uv publish`,
  `twine upload`, `mvn|gradle deploy`, `docker|podman push`
- Infrastructure writes: `kubectl apply|delete`, `terraform apply|destroy`,
  `helm install|upgrade`
- Raw `curl`/`wget` POST/PUT/PATCH/DELETE against any hosted API

Read-only remote operations need no approval: `git fetch`/`pull`/`log`/`diff`/`status`,
`gh pr view`, `gh issue list`, `gh api -X GET`, `npm view`, `curl -s GET`.

## Commits are tolerated, not preferred

Local commits do not touch shared state, so they are permitted — but **do not
commit unless the task needs it or I have discussed it with you.** Prefer leaving
changes in the working tree so I can review the diff myself. Never amend, squash,
or rewrite commits I did not ask you to create, and never sign off / co-author
without being asked.

If you think a commit is warranted, say so and tell me the message — then wait.

## Verification before proposing any of the above

Before asking to push/publish, show me the evidence that it is safe:

1. The test/build command you ran and its **real** output (not your summary of it).
2. `git status` + `git diff --stat` for the exact scope.
3. Anything destructive or irreversible in the change (migrations, dependency
   bumps, deleted files, credentials, `.env`, generated data).

Never claim a push is "just the agreed change" without re-reading the diff.

## Self-modification is off-limits

Do not edit, delete, or work around the guard:
`~/.pi/agent/extensions/`, `settings.json`, `models.json`, `auth.json`,
`~/.pi/.env`, `~/.bashrc`/`.zshrc`/`.profile`, `~/.ssh/`, `.git-credentials`.
This includes setting `PI_VCS_GUARD=off` or `PI_VCS_ALLOW_PUSH=1` in a shell you
run for me, and includes asking the user to "just try disabling it" to get unblocked.
If the guard is genuinely in the way, tell me what you needed and let me change it.

Files that must never be written even with approval: `.env`, `auth.json`,
private keys, `~/.ssh/`, `~/.gnupg/`, `~/.netrc`, `.git/config`, `.git/hooks/`.

## Local-only work is unrestricted

Editing source, running builds/tests/linters, `git add`, creating branches,
stashes, worktrees, `git reset`/`rebase`/`cherry-pick` within a scratch or
feature branch: go ahead, no approval needed. The line is at the network boundary.

## Subagents

Named subagents inherit the guard (tool-level handlers see their calls), but
they are one reasoning step removed from me — so state these rules in the
prompt when spawning anything that might touch a repo, and do not let a
subagent "clean up" by pushing on your behalf.
