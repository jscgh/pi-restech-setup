---
description: Run an independent cross-model review
argument-hint: "[branch, diff, or review scope]"
---

Review ${@:-the current changes} with one reviewer from a different model family than the implementation model: use `review-qwen` for GLM-authored changes or `review-glm` for Qwen-authored changes. If the implementation model is unknown, use `review-qwen`. Run both reviewers concurrently only when the user requests dual review or the change is high-risk (security, authentication, data integrity, migrations, concurrency, or a consequential public-interface change). Give each reviewer the exact branch, diff, or scope; keep them read-only. Verify findings against the repository and return a severity-ordered synthesis. Do not invoke a frontier model.
