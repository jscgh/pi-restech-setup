# pi-restech-setup

Shared [Pi](https://github.com/earendil-works/pi) configuration for the UNSW ResTech Local Inference service. This is a user-maintained setup, not an official UNSW or ResTech support channel.

## Included

| Path | Purpose |
| --- | --- |
| `agent/models.json` | ResTech provider and model definitions; the installer materializes the private base URL and the API key is read from `RESTECH_API_KEY` |
| `agent/settings.json` | Default model, thinking levels, enabled models, and the pi-subagents package |
| `agent/AGENTS.md` | Shared instructions, three-way merged with local edits during installation |
| `agent/subagents.json` | Subagent concurrency and scheduling settings |
| `agent/agents/` | Local workers, reviewers, and optional frontier escalation |
| `agent/prompts/` | Reusable implementation and review prompts |
| `agent/extensions/` | Compact rendering, notifications, session titles, handoff, compaction routing, and remote-write guarding |
| `profiles/katana/` | Katana instructions, prompts, and public reference material |
| `MODEL-BENCHMARK.md` | Initial benchmark and replicated comparison used to select defaults |

Several extensions are adapted from Pi examples. See [NOTICE.md](NOTICE.md) and [LICENSES/pi-MIT.txt](LICENSES/pi-MIT.txt).

## Requirements

- Pi, Node.js, Git, and Bash
- `curl` and GNU `timeout` for live validation; omit them only when using `--no-validate`
- A ResTech API key and API base URL supplied through the ResTech access process
- Optional: separate OpenAI Codex access for the Luna, Sol, and Terra models

## Install

```bash
git clone <repository-url> pi-restech-setup
cd pi-restech-setup
./install.sh
```

The key can instead be supplied through `RESTECH_API_KEY` or piped on standard input. The installer looks for an existing key in the process environment, `~/.pi/.env`, `~/.codex/.env`, `~/.config/pi/.env`, and `~/.restech.env`, in that order.

On the first installation, set `RESTECH_API_BASE_URL` to the private API base URL or enter it at the interactive prompt. Later runs recover it from the installed `~/.pi/agent/models.json`; it is never written into this checkout.

Installation can:

- validate the key and write it to `~/.pi/.env` with mode `600`
- add a marked loader block to the active shell startup file
- make `~/.profile` source `~/.bashrc` when needed for Bash login shells
- copy shared files to `~/.pi/agent/`, materialize the private API base URL in `models.json`, and back up changed destinations under `.backup-<timestamp>/`
- merge `AGENTS.md` template changes while preserving local edits
- install or update `npm:@tintinweb/pi-subagents`
- update Pi and installed packages unless disabled
- run a live ResTech smoke test from a temporary directory under `~/.cache/pi-restech-setup/`

The Katana profile is selected automatically on `katana`, `katana1`–`katana3`, `kdm`, and three-digit compute hosts such as `k123`. It installs `APPEND_SYSTEM.md`, `prompts/nf-test-lanes.md`, and `references/katana-jobs.md`. Other hosts receive only the shared configuration.

`settings.json` becomes user-owned after its first installation. `AGENTS.md` is maintained through a recorded merge base under `~/.pi/agent/.pi-restech-setup/`. `PI_SETUP_PERSONAL_FILES` changes which files receive this preservation treatment and should be changed only deliberately.

Useful options:

```bash
./install.sh --check               # verify local key discovery and installed files without writing
./install.sh --profile katana      # force Katana guidance
./install.sh --profile default     # omit Katana guidance
./install.sh --force-key           # replace the stored key
./install.sh --no-validate         # skip live key validation and the model smoke test
./install.sh --no-update-pi        # keep the installed Pi version
./install.sh --no-update-packages  # skip package updates
```

The installer is safe to rerun with the same options: unchanged files are left alone, changed shared files are backed up before replacement, and personal files are preserved or merged. Package updates, live checks, and shell/configuration checks still run on each invocation unless disabled.

## Usage

```bash
pi
pi --model restech/qwen3.8-27b
pi --model restech/glm-5.3-flash
```

The configured default is `restech/glm-5.3-flash` at `low` thinking. Tool output is rendered compactly, `/agents` lists named subagents, and `/handoff <goal>` starts a focused child session with an editable prompt.

Compaction tries `restech/qwen3.8-flash-next`, then `openai-codex/gpt-5.6-luna`, then the active model. Unavailable providers are skipped. Override the chain with comma-separated `PI_COMPACT_MODELS` entries.

## Models

| Model | Default thinking | Use |
| --- | --- | --- |
| `qwen3.8-flash-next` | `medium` | Short, non-agent tasks and single-pass summarization |
| `qwen3.8-27b` | `high` | Format-sensitive work and independent review |
| `glm-5.3-flash` | `low` | Main-thread orchestration, planning, implementation, and review |

GLM agents use `low`, Qwen workers and reviewers use `high`, and bounded exploration uses `low`. The configured endpoint accepts `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. Change the current level with `/thinking`.

OpenAI Codex models are optional and require separate access. Luna is used by `worker-luna`; Sol is used for frontier architecture and review; Terra is enabled for manual selection.

See [MODEL-BENCHMARK.md](MODEL-BENCHMARK.md) for the evaluation method, replication, limitations, and rationale behind these defaults.

## Remote-write guard

`agent/extensions/vcs-guard.ts` requests confirmation before recognised remote publication, hosted-repository writes, package or image publication, infrastructure mutation, and explicit HTTP writes. It covers Pi's `bash` and `powershell` tools plus common shell-tool aliases. Without an interactive UI, recognised writes are blocked. Selected credential, shell, SSH, and Pi configuration paths are protected from Pi's edit and write tools.

The guard matches command text and known tool names. It is not a sandbox and can be bypassed by indirect scripts, aliases, encodings, or other tools. Keep normal operating-system, repository, credential, and infrastructure protections enabled.

Emergency overrides for one session:

```bash
PI_VCS_GUARD=off pi
PI_VCS_ALLOW_PUSH=1 pi
```

## Verification

```bash
bash -n install.sh
bash tests/install.test.sh
node tests/vcs-guard.test.cjs
```

`./install.sh --check` additionally verifies an installed configuration. It confirms that a key can be found locally; it does not contact the gateway.

## Security

- The installer writes a newly supplied key only to `~/.pi/.env` and sets mode `600`.
- Existing keys may remain in the environment or supported external env files.
- No API key value or private API base URL is stored in this repository.
- Review extensions before installing them; Pi extensions run with the permissions of the Pi process.

## Uninstall

The installer does not keep an ownership ledger, so there is no safe blanket removal command. Before removing files, compare them with the checkout and inspect `.backup-<timestamp>/`, `AGENTS.md.bak`, and `settings.json.bak` for local content.

Remove the subagent package with:

```bash
pi remove npm:@tintinweb/pi-subagents
```

Then remove only setup-managed files that you have confirmed contain no local changes, including the extensions, agent definitions, prompts, `models.json`, `subagents.json`, and any installed Katana profile files. Treat `settings.json` and `AGENTS.md` as personal files. Remove the marked shell block, `~/.pi/agent/.pi-restech-setup/`, and `~/.pi/.env` only if they are no longer needed.

## License

MIT. See [LICENSE](LICENSE). Adapted Pi example code retains its upstream MIT notice in [LICENSES/pi-MIT.txt](LICENSES/pi-MIT.txt).
