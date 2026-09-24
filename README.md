Agent generated docs:

# pi-restech-setup

Shared [pi](https://github.com/earendil-works/pi) configuration for using UNSW
**ResTech Local Inference** (`https://inference.restech.unsw.edu.au/`) — the
on-premise OpenAI-compatible gateway — as your coding-agent backend.

Includes:

| Component | Purpose |
| --- | --- |
| `agent/models.json` | restech provider + the three local models (env-var key reference, no secrets) |
| `agent/settings.json` | sensible defaults: qwen3.8-flash-next as the workhorse, `hideThinkingBlock`, pi-subagents package |
| `agent/subagents.json` | concurrency knobs for the subagent extension |
| `agent/agents/*.md` | named subagents: Qwen/GLM workers + reviewers, frontier escalation |
| `agent/prompts/*.md` | slash prompt templates (implement, review, escalate) |
| `agent/extensions/minimal-mode.ts` | Codex-style collapsed tool rows (one line per call, Ctrl+O expands) |
| `agent/extensions/notify.ts` | desktop/terminal notification when the agent waits for input (OSC 777/99 + BEL, tmux-safe over ssh) |

## Prerequisites

1. **pi** installed and on your `PATH`.
2. A **ResTech API key** (`sk-…`). Local Inference is a PoC with invite-only,
   per-project keys — request one via *Request access* on
   <https://inference.restech.unsw.edu.au/>.

## Install

```bash
git clone <this repo> pi-restech-setup   # or copy the folder
cd pi-restech-setup
./install.sh
```

The script will:

- prompt for your `sk-…` key (hidden input), verify it live against the
  gateway, and store it in `~/.pi/.env` with mode **600**
- append a small, clearly-marked source block to your shell init file
  (`~/.bashrc` / `~/.zshrc` / `~/.profile`) so interactive and login shells
  export the key — this is required because pi reads provider keys from the
  **process environment**, not from `~/.pi/.env` automatically
- copy the config into `~/.pi/agent/`, backing up (never deleting) any file
  it replaces into `~/.pi/agent/.backup-<timestamp>/`
- install the `pi-subagents` extension package
- run an end-to-end smoke test against the gateway

Re-running is safe. Nothing outside `~/.pi/agent/`, `~/.pi/.env`, and the
marked shell-init block is touched.

Check an existing install without changing anything:

```bash
./install.sh --check
```

Replace the stored key (e.g. after re-requesting access):

```bash
./install.sh --force-key
```

## Usage

```bash
pi                                      # new session, qwen3.8-flash-next by default
pi --model restech/glm-5.3-flash        # bigger model for hard reasoning/tool use
pi --model restech/qwen3.8-27b          # general purpose
```

- **Ctrl+O** toggles tool output collapse/expand (thanks to the minimal-mode
  extension, collapsed = one line per call).
- `/agents` lists the named subagents; `@worker-glm`, `@review-qwen` etc. can
  be invoked via the subagents extension's `Agent` tool.

## Model guidance (from the ResTech service page)

| Model | Tier | Notes |
| --- | --- | --- |
| `qwen3.8-flash-next` | Fast | **Recommended default for agent loops.** 125B, two serving replicas = most capacity. |
| `qwen3.8-27b` | High quality | General-purpose chat/reasoning. 27B, federated node. |
| `glm-5.3-flash` | Deep reasoning | 320B MoE (A18B). Strongest, but shares one node with the qwen replicas — occasionally 503s under load. |

### Thinking levels

The endpoint accepts `reasoning_effort` in
`none|minimal|low|medium|high|xhigh|max` on all three ResTech models, so
`models.json` declares a full `thinkingLevelMap` for each. Without that map Pi
hides `xhigh`/`max` and collapses `low`/`medium`/`high` onto one token budget —
if you add a model, copy the map.

Startup levels are pinned per model in `settings.json`:

| Model | Default | Why |
| --- | --- | --- |
| `qwen3.8-flash-next`, `qwen3.8-27b` | `medium` | Levels barely separate below `high`; `medium` is the cheaper default for agent loops. |
| `glm-5.3-flash` | `high` | `low`/`medium` collapse its thinking to near-zero tokens. Do not drop it. |
| `openai-codex/*` | `low` | ChatGPT quota is finite — raise per session only when needed. |

Override for one session with `/thinking` (press `Ctrl+S` there to save it as
that model's default, which rewrites `modelThinkingLevels`).

## Security notes

- Your `sk-…` key is stored **only** in `~/.pi/.env` (mode 600) and exported
  from your shell init file. It is never written into `models.json` or any
  file in this repo.
- This repo is safe to share as-is; if you fork it, keep a `.gitignore` with
  `.env` and `auth.json` to stay that way.

## Uninstall

```bash
rm ~/.pi/agent/extensions/minimal-mode.ts ~/.pi/agent/extensions/notify.ts
# restore your previous agent config if the installer backed one up:
ls ~/.pi/agent/.backup-*
# remove the key + shell block by hand:
#   delete the ~/.pi/.env line and the MARKER block in your shell rc
```

