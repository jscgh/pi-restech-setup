# ResTech model/tool-use benchmark

This benchmark evaluates model behaviour for scientific workflow development through Pi: Nextflow, Open OnDemand, HPC configuration, ProteinFold, and `kod-wisps` workflows. It is not a general intelligence leaderboard.

## Method

The benchmark has two related campaigns conducted between 4 and 8 October 2026 against the ResTech service and model versions available during that period:

1. **Thinking-level sweep:** 21 configurations (three ResTech models × seven thinking levels), two focused repository tasks each, for 42 candidate runs. Each candidate ran in a fresh checkout and home directory under Bubblewrap filesystem isolation. The candidate was limited to 25 tool calls and four minutes. GPT-5.6 Sol adjudicated valid outputs.
2. **Finalist replication:** five configurations × four representative repository tasks × three repetitions, for 60 candidate runs:
   - GLM-low
   - GLM-medium
   - Qwen-low
   - Qwen-high
   - Luna-low

The replicated tasks were:

- `ood-random-seed-boltz` — expose and correctly propagate an optional Boltz seed;
- `proteinfold-random-production-seed` — use random production seeds while retaining deterministic debug behaviour;
- `review-ood-scratch-maintenance` — review quota monitoring, cleanup, cache scope and scheduler safety;
- `review-kod-wisps-output-claims` — review output-claim races, stale reclamation and retry safety.

The replication used fresh contexts, real repository checkouts, tool-call and wall-time limits, and one Sol adjudication per candidate. Invalid Bubblewrap mount failures were removed and rerun; the final dataset contains no infrastructure-error runs. Task-repository revisions, the generated report, and raw artifacts are retained privately and are not included here, so this summary is not independently reproducible.

Scores are adjudicator scores from 0–100, not a percentage accuracy metric. A timeout or tool-limit result can still receive a nonzero score if the candidate produced a useful patch or review, but completion reliability is reported separately.

## Replicated results

| Configuration | Valid runs | Mean score | Median | Normal completion | Main observation |
| --- | ---: | ---: | ---: | ---: | --- |
| **Luna-low** | 12/12 | **74.2** | **77** | **12/12** | Strongest and most reliable; only Luna-low was tested |
| **GLM-low** | 12/12 | 54.2 | 60 | 10/12 | Best local default; comparatively disciplined and useful on reviews |
| **GLM-medium** | 9/12 valid | 55.7* | 67 | 6/9 | Better on some reviews, but more timeouts/limits and three integrity-disqualified runs |
| **Qwen-high** | 12/12 | 33.1 | 20 | 4/12 | Good occasional implementation result, but unreliable and tool-heavy |
| **Qwen-low** | 12/12 | 19.5 | 0 | 2/12 | Frequently exhausted tool limits; initial two-task result did not replicate |

\*The three GLM-medium integrity-disqualified runs are excluded from the mean. Including them as failures gives an effective mean of approximately 41.8.

Per-task mean scores:

| Task | Luna-low | GLM-low | GLM-medium | Qwen-high | Qwen-low |
| --- | ---: | ---: | ---: | ---: | ---: |
| OOD seed implementation | **98.3** | 55.7 | 69.3 | 82.0 | 62.7 |
| ProteinFold production seed | **85.0** | 36.7 | — | 0.7 | 0 |
| `kod-wisps` output-claim review | 55.3 | 60.7 | **76.3** | 36.3 | 15.3 |
| OOD scratch-maintenance review | 58.3 | **64.0** | 21.3 | 13.3 | 0 |

Luna-low was also the only finalist with 12/12 normal completions. Its candidate runs recorded approximately 1.31M total tokens, including approximately 1.02M cache-read tokens. Pi estimated candidate API cost at about US$0.10; this is not a direct conversion to ChatGPT subscription credits.

Task-specific patches and review findings are retained in the per-run artifacts and the generated benchmark report. They are deliberately not treated as conclusions about this setup repository or generalized into the routing recommendations below.

## Conclusions and routing

### Distributable/team settings

For the tested October 2026 service snapshot, the results support this shared routing profile:

- **Default:** GLM-5.3-Flash low.
- **Plan, implementation and review:** GLM-low unless a second opinion is needed.
- **Optional independent worker/reviewer:** Qwen3.8-27B high, with no assumption that it will complete reliably.
- **Flash-Next:** manual or tightly bounded use, not a default review route.
- OpenAI-backed models and agents are not part of the team routing recommendation; users with personal provider access may configure their own overlays separately.

Luna-low was benchmarked only as an external baseline. Luna medium/high should not be inferred to be better from these results.

No hard turn limits were added to production agents. Benchmark limits remain measurement controls only; production agents should retain their existing unlimited worker behaviour to avoid losing context and paying re-entry costs.

## Confidence and caveats

- The 60-run replication is substantially stronger than the original single-sample matrix, but it still covers only four tasks and one Luna thinking level.
- Results are stochastic and path-dependent. Early tool choices can cause large score changes, especially near the tool limit.
- Tool limits measure both correctness and exploration discipline; they can create cliff effects.
- The Qwen results show genuine tool-loop behaviour, but shared endpoint load may also contribute to some timeouts.
- Sol adjudication itself introduces some noise and consumes substantially more subscription quota than Luna candidate runs.
- No fixed seed was used: this is intentional because the goal is real-world operating behaviour, not deterministic replay.
- Ruby and Nextflow validation availability differed by environment; skipped or unavailable validators are recorded in run artifacts.
- Context sizes and hardware came from provider documentation; quantization, KV-cache formats, and exact serving revisions were not available for independent verification.
- Model and serving updates can change these conclusions. Re-run a smaller replicated finalist set after consequential endpoint changes.
