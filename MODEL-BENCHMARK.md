# ResTech model/tool-use benchmark

This setup's model defaults were informed by a local benchmark run on 4 October 2026 against the ResTech OpenAI-compatible endpoint through headless Pi. The goal was not to rank general intelligence, but to compare the behaviour that matters for a coding agent: correctness, responsiveness, tool-call discipline, instruction following, and failure modes.

## Method

The main matrix contained **126 fresh-context runs**:

- three models: Qwen3.8 Flash Next, Qwen3.8 27B, and GLM-5.3 Flash;
- seven thinking levels: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`;
- three task families: targeted repository retrieval, Git/tool-syntax work, and multi-file synthesis;
- two equivalent task variants per family.

Every run used the same five basic Pi tools (`read`, `grep`, `find`, `ls`, and `bash`), a read-only prompt, concurrency of three, independently checked answers, and a 20-minute timeout. A second campaign added **42 exact repeat runs** for the seven most promising configurations, giving three observations for each selected task/configuration pair.

The configured context windows were intentionally left at their locally benchmarked practical limits rather than the service's advertised maximum limits.

## Repeat results

| Configuration | Factual accuracy | Tool calls/run | Cumulative tokens/run | Time/run | Notable behaviour |
| --- | ---: | ---: | ---: | ---: | --- |
| GLM medium | 84.1% | 6.3 | 13k | 14.3 s | Best quality/efficiency compromise |
| GLM high | 84.1% | 9.3 | 43k | 29.4 s | No accuracy gain over medium |
| Flash minimal | 84.1% | 168.9 | 11.4M | 191.8 s | Accurate but severe over-exploration |
| GLM low | 79.4% | 3.7 | 11k | 4.3 s | Best responsive general default |
| Qwen 27B max | 77.8% | 10.2 | 31k | 4.9 s | Best strict-format compliance |
| Flash medium | 77.8% | 114.0 | 11.0M | 240.3 s | One repeat timed out |
| Qwen 27B low | 71.4% | 11.9 | 56k | 7.0 s | Inferior to Qwen max here |

In the full matrix, Flash Next produced the only malformed plain-text tool call and four timeouts. Its inexpensive individual inference calls were outweighed by repeated searches and very long agent loops. Qwen 27B was consistently responsive and followed requested JSON formatting well. GLM generally used the fewest tools and tokens, but often ignored a requested JSON envelope unless output was constrained by something stronger than prompt instructions.

## Interpretation and defaults

The benchmark supports the following routing:

- **GLM low** for the responsive human-facing main thread and bounded exploration;
- **GLM medium** for planning, substantial implementation, review, and difficult synthesis;
- **Qwen 27B max** for format-sensitive work, structured responses, and independent cross-model review;
- **Flash Next medium** only for short, bounded, preferably tool-free tasks such as titles or single-pass summaries.

These choices optimize completed-task behaviour rather than parameter count or advertised context size. For a small group of users, GLM-low should be a reasonable default; larger deployments should also consider server-side queue latency, batching throughput, KV-cache pressure, and the impact on other services hosted on the same nodes.

## Caveats

- This was a repository/tool-use benchmark, not a broad coding, conversational, or scientific-reasoning evaluation.
- Cumulative token totals sum the context reported on every turn. They represent API workload but are not a direct measurement of GPU FLOPs, especially if the server performs unreported prefix caching.
- Concurrent runs introduce latency noise, so large timing differences are more meaningful than small ones.
- GLM's JSON result measures instruction following, not the endpoint's schema-constrained `response_format` capability.
- Model and serving updates may change these conclusions; the matrix should be rerun after consequential endpoint changes.
