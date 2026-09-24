---
description: Run independent GLM and Qwen reviews in parallel
argument-hint: "[branch, diff, or review scope]"
---

Review ${@:-the current changes} using `review-glm` and `review-qwen` concurrently. Give each reviewer the exact branch, diff, or scope to inspect. They must remain read-only. After both finish, deduplicate their findings, verify disputed claims against the repository, and return a severity-ordered synthesis. Do not invoke a frontier model.
