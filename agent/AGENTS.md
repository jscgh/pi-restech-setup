# Global working agreement

These rules apply in every directory, including inside subagents.
`~/.pi/agent/extensions/vcs-guard.ts` enforces the repository parts mechanically;
this file is the intent behind them.

## Be concise

- Lead with the answer; cut restatement of the question and of what was just said.
- One clear clarifying question beats hedging several branches.
- State an uncertainty once, plainly; don't re-litigate a past mistake unless asked.

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

Read-only remote operations need no approval: `git fetch`/`log`/`diff`/`status`,
`gh pr view`, `gh issue list`, `gh api -X GET`, `npm view`, `curl -s GET`.

## Commits are tolerated, not preferred

Local commits do not touch shared state, so they are permitted — but **do not
commit unless the task needs it or I have discussed it with you.** Prefer leaving
changes in the working tree so I can review the diff myself. Never amend, squash,
or rewrite commits I did not ask you to create, and never sign off / co-author
without being asked.

## Local-only work is unrestricted

Editing source, running builds/tests/linters, `git add`, creating branches,
stashes, worktrees, `git reset`/`rebase`/`cherry-pick` within a scratch or
feature branch: go ahead, no approval needed. The line is at the network boundary.

## Subagents

Delegate only genuinely long operations whose benefit exceeds the added
overhead; do not spawn an agent for a single read or a one-line edit.
