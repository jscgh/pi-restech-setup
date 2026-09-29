# pi-restech-setup

Shared [Pi](https://github.com/earendil-works/pi) configuration for the UNSW ResTech Local Inference service.

## Included

| Path | Purpose |
| --- | --- |
| `agent/models.json` | ResTech provider and model definitions; the API key is read from `RESTECH_API_KEY` |
| `agent/settings.json` | Default model, thinking levels, and pi-subagents package |
| `agent/agents/` | Local workers, reviewers, and optional frontier escalation |
| `agent/prompts/` | Reusable implementation and review prompts |
| `agent/extensions/minimal-mode.ts` | Compact built-in tool rendering based on Pi's `minimal-mode.ts` example |
| `agent/extensions/session-title.ts` | Session and terminal titles |
| `agent/extensions/summary-router.ts` | Compaction through a configurable model fallback chain |
| `agent/extensions/handoff.ts` | `/handoff <goal>` command for starting a focused session |
| `agent/extensions/vcs-guard.ts` | Confirmation gate for remote writes and protection for sensitive config |
| `profiles/katana/` | Shared Katana guidance with optional, gitignored `references/katana-personal.md` |
| `agent/extensions/notify.ts` | Notifications based on Pi's `notify.ts` example |

## Requirements

- `pi` on `PATH`
- A ResTech API key from <https://inference.restech.unsw.edu.au/>
- Bash
- Node.js

## Install

```bash
git clone <repository-url> pi-restech-setup
cd pi-restech-setup
./install.sh
```

The installer:

- validates and stores the API key in `~/.pi/.env` with mode `600`
- adds a marked loader block to the active shell startup file
- copies shared configuration to `~/.pi/agent/`, backing up replaced files
- installs pi-subagents and pi-notify
- updates Pi and packages unless disabled
- runs a ResTech smoke test

The Katana profile is selected automatically on `katana`, `katana1`–`katana3`, `kdm`, and three-digit compute hosts such as `k123`. Other hosts receive only the shared configuration.

`AGENTS.md` template updates are three-way merged with local edits. `settings.json` remains local after first installation. Override the personal-file list with `PI_SETUP_PERSONAL_FILES`.

Useful options:

```bash
./install.sh --check               # verify without changing files
./install.sh --profile katana      # force Katana guidance
./install.sh --profile default     # omit Katana guidance
./install.sh --force-key           # replace the stored key
./install.sh --no-validate         # skip the live model check
./install.sh --no-update-pi        # keep the installed Pi version
./install.sh --no-update-packages  # skip package updates
```

Re-run `./install.sh` after updating the checkout. The script is idempotent.

## Usage

```bash
pi
pi --model restech/qwen3.8-27b
pi --model restech/glm-5.3-flash
```

- `Ctrl+O` toggles compact and expanded tool output.
- `/agents` lists named subagents.
- `/handoff <goal>` creates a focused child session with an editable prompt.
- Compaction uses `restech/qwen3.8-flash-next`, then `openai-codex/gpt-5.6-luna`, then the active model. Override the chain with comma-separated `PI_COMPACT_MODELS` entries.

## Models

| Model | Default thinking | Use |
| --- | --- | --- |
| `qwen3.8-flash-next` | `medium` | Default agent loops |
| `qwen3.8-27b` | `medium` | General-purpose work |
| `glm-5.3-flash` | `high` | Deeper reasoning |

The configured endpoint accepts `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. Change the current level with `/thinking`.

## Remote-write guard

`agent/extensions/vcs-guard.ts` asks before commands that publish, deploy, upload, or modify hosted infrastructure. Without an interactive UI it blocks those commands. It also blocks agent writes to credentials, shell startup files, SSH configuration, and guard-critical Pi configuration.

The guard matches command text; it is not a sandbox. Keep normal repository and infrastructure protections enabled.

Emergency overrides for a session:

```bash
PI_VCS_GUARD=off pi
PI_VCS_ALLOW_PUSH=1 pi
```

## Verification

```bash
node tests/vcs-guard.test.cjs
```

## Security

- The API key is stored only in `~/.pi/.env`; it is not written to repository files.
- `.env`, `auth.json`, and common credential files are ignored.
- Review extensions before installing them; Pi extensions run with the permissions of the Pi process.

## Uninstall

```bash
rm ~/.pi/agent/extensions/{handoff,minimal-mode,notify,session-title,summary-router,vcs-guard}.ts
```

Remove the marked shell block and `~/.pi/.env` manually if they are no longer needed.
