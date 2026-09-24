---
description: Explicitly spend OpenAI frontier allowance on a focused final review
argument-hint: "<branch, diff, or review scope>"
---

This command explicitly authorizes one frontier-model review. Invoke `frontier-reviewer` once to review:

$@

Keep the delegation narrowly scoped and read-only. Do not invoke additional frontier agents unless the user explicitly asks. Verify the returned findings against the repository and report the model used.
