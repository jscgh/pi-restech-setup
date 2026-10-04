---
description: Implement locally, then perform a cross-model review
argument-hint: "<task>"
---

Complete this task without frontier-model usage:

$@

Use `worker-glm` by default for complex, multi-file, or reasoning-heavy implementation. Use `worker-qwen` when the task is primarily mechanical or format-sensitive, or when an independent Qwen implementation is explicitly wanted. If architecture or decomposition is genuinely uncertain, delegate a bounded read-only plan to `Plan` first. After the worker returns a branch, run one reviewer from the other model family against that exact branch: use `review-qwen` after `worker-glm`, or `review-glm` after `worker-qwen`. Run both reviewers concurrently only when the user requests dual review or the change is high-risk (security, authentication, data integrity, migrations, concurrency, or a consequential public-interface change). Verify actionable findings, then either resume a suitable isolated worker with a focused correction task or report the branch and unresolved findings. Never merge automatically; leave the final branch and integration decision to the user.
