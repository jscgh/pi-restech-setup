---
description: Implement locally, then perform independent local reviews
argument-hint: "<task>"
---

Complete this task without frontier-model usage:

$@

Choose `worker-glm` or `worker-qwen` for implementation in its enforced worktree. After the worker returns a branch, run `review-glm` and `review-qwen` concurrently against that exact branch. Verify actionable findings, then either resume a suitable isolated worker with a focused correction task or report the branch and unresolved findings. Never merge automatically; leave the final branch and integration decision to the user.
