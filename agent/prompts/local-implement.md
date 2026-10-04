---
description: Implement a task using isolated RESTECH workers
argument-hint: "<task>"
---

Implement this task using local RESTECH agents only:

$@

First inspect enough context to split the work safely. Use `worker-glm` by default for complex or multi-file work, and `worker-qwen` for mechanical or format-sensitive work. Both are locked to isolated Git worktrees. Use `Plan` first only when architecture or ownership is genuinely uncertain. If the task has genuinely independent components, launch multiple background workers with explicit, non-overlapping ownership. Do not ask two writers to modify the same subsystem. Wait for their results, inspect their branches and verification evidence, then recommend an integration order. Do not invoke any frontier agent.
