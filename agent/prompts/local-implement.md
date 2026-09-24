---
description: Implement a task using isolated RESTECH workers
argument-hint: "<task>"
---

Implement this task using local RESTECH agents only:

$@

First inspect enough context to split the work safely. Delegate substantial edits to `worker-glm` or `worker-qwen`; both are locked to isolated Git worktrees. If the task has genuinely independent components, launch multiple background workers with explicit, non-overlapping ownership. Do not ask two writers to modify the same subsystem. Wait for their results, inspect their branches and verification evidence, then recommend an integration order. Do not invoke any frontier agent.
