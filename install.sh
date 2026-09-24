#!/usr/bin/env bash
#
# install.sh - Install the shared Pi + ResTech Local Inference setup.
#
# Usage:
#   ./install.sh              # interactive: prompts for your RESTECH key
#   ./install.sh --check      # verify an existing install (no changes)
#
# What it does:
#   1. Checks prerequisites (pi on PATH, bash-capable shell).
#   2. Prompts for the ResTech API key (hidden input) and validates the
#      format. Skips the prompt if --check or if RESTECH_API_KEY is set
#      and non-empty (unless --force-key).
#   3. Writes the key to ~/.pi/.env (chmod 600, group/other 000).
#   4. Appends a guarded source line to the user's shell init file so
#      interactive shells (and therefore pi, subagents, and the
#      documented ResTech quickstarts) pick the key up from the
#      environment.
#   5. Copies this repo's agent/ config into ~/.pi/agent/ (backing up
#      any files it replaces into ~/.pi/agent/.backup-<timestamp>/).
#   6. Installs the pi-subagents package if missing.
#   7. Runs a live smoke test against the gateway.
#
# Nothing outside ~/.pi/agent and the one appended shell-init line is
# modified. Re-running is safe (idempotent).
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PI_ENV_FILE="$HOME/.pi/.env"
MARKER_BEGIN="# >>> pi-restech-setup >>>"
MARKER_END="# <<< pi-restech-setup <<<"
KEY_ENV_NAME="RESTECH_API_KEY"
KEY_URL_HINT="https://inference.restech.unsw.edu.au/ (Request access)"

MODE="install"
FORCE_KEY=0
VALIDATE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --force-key) FORCE_KEY=1 ;;
    --no-validate) VALIDATE=0 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '\033[1;34m[pi-setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[pi-setup] WARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[pi-setup] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
command -v pi >/dev/null 2>&1 || die "pi not found on PATH. Install pi first (https://github.com/earendil-works/pi)."
log "pi: $(command -v pi)"

# ---------------------------------------------------------------------------
# Shell init file detection (most robust across systems):
#   - login shells: ~/.bash_profile / ~/.profile
#   - interactive: ~/.bashrc / ~/.zshrc
# We target the file that the user's *current interactive* shell actually
# reads, with a source-guard block between markers so re-runs stay
# idempotent. For bash we also make sure ~/.profile sources ~/.bashrc so
# login-only sessions (ssh host, no tmux) pick it up.
# ---------------------------------------------------------------------------
shell_init_files() {
  local shell_name
  shell_name="$(basename "${SHELL:-/bin/bash}")"
  case "$shell_name" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash) echo "$HOME/.bashrc" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

detect_api_key() {
  # Precedence for existing key: env var, then ~/.pi/.env
  if [ -n "${!KEY_ENV_NAME:-}" ]; then
    printf '%s' "${!KEY_ENV_NAME}"
    return 0
  fi
  if [ -f "$PI_ENV_FILE" ]; then
    local line
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${KEY_ENV_NAME}=" "$PI_ENV_FILE" | tail -n1 || true)"
    if [ -n "$line" ]; then
      # strip optional 'export ', var name, '=', surrounding quotes
      printf '%s' "${line#*=}" | tr -d "\"'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
      return 0
    fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 2. API key
# ---------------------------------------------------------------------------
EXISTING_KEY=""
EXISTING_KEY="$(detect_api_key || true)"

need_key() {
  [ "$MODE" = "install" ] && { [ "$FORCE_KEY" = "1" ] || [ -z "$EXISTING_KEY" ]; }
}

# Non-interactive keys can also be piped on stdin (for scripted installs).
if need_key && [ ! -t 0 ] && [ -z "${RESTECH_API_KEY:-}" ] && [ -z "$EXISTING_KEY" ]; then
  ENTERED_KEY="$(head -n1)"
  NEW_KEY="$(printf '%s' "$ENTERED_KEY" | tr -d '"'"'" | tr -d '[:space:]')"
  [ -n "$NEW_KEY" ] || die "Empty key on stdin."
fi

if need_key; then
  if [ ! -t 0 ]; then
    # Non-interactive and nothing usable found.
    if [ -n "$EXISTING_KEY" ]; then
      NEW_KEY="$EXISTING_KEY"
    else
      die "No TTY and no ${KEY_ENV_NAME} available. Set ${KEY_ENV_NAME}=sk-... in the environment, pipe the key on stdin, or run install.sh interactively."
    fi
  else
    log "Enter your ResTech Local Inference API key (looks like: sk-...)."
    log "Get one via 'Request access' at https://inference.restech.unsw.edu.au/"
    printf 'Key (hidden, empty line to abort): '
    read -rs ENTERED_KEY || die "Aborted."
    echo
    [ -n "$ENTERED_KEY" ] || die "No key entered."
    case "$ENTERED_KEY" in
      *[[:space:]]*) die "Key contains whitespace - re-enter the bare sk-... value." ;;
    esac
    NEW_KEY="$ENTERED_KEY"
  fi
else
  NEW_KEY="$EXISTING_KEY"
fi

# Validate format lightly and (in install mode) verify the key live before
# writing anything, so we never leave a broken config behind.
case "$NEW_KEY" in
  sk-*) : ;;
  *) die "Key does not look like a ResTech key (expected it to start with 'sk-')." ;;
esac

validate_key_live() {
  local key="$1"
  local body
  body="{\"model\":\"qwen3.8-flash-next\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":8,\"stream\":false}"
  local http_code
  http_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' \
    -d "$body" https://inference.restech.unsw.edu.au/v1/chat/completions)"
  case "$http_code" in
    200) return 0 ;;
    401|403) die "Key rejected by the gateway (HTTP $http_code). Double-check you pasted the full sk-... key." ;;
    000) warn "Could not reach the gateway (network?). Continuing; validation skipped." ;;
    *)   warn "Unexpected HTTP $http_code from the gateway; key may still be OK (endpoint status can be transient). Continuing." ;;
  esac
}

if [ "$MODE" = "install" ] && [ "$VALIDATE" = "1" ]; then
  validate_key_live "$NEW_KEY"
  log "Key accepted by the gateway."
elif [ "$MODE" = "install" ]; then
  warn "Live key validation skipped (--no-validate)."
fi

# ---------------------------------------------------------------------------
# 3. Write ~/.pi/.env with strict permissions
# ---------------------------------------------------------------------------
if [ "$MODE" = "install" ] && { [ -n "$NEW_KEY" ] && [ "$NEW_KEY" != "$EXISTING_KEY" ] || [ "$FORCE_KEY" = "1" ] || [ ! -f "$PI_ENV_FILE" ]; }; then
  mkdir -p "$(dirname "$PI_ENV_FILE")"
  umask 077
  touch "$PI_ENV_FILE"
  chmod 600 "$PI_ENV_FILE"
  # Replace an existing RESTECH_API_KEY line in place, else append.
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?${KEY_ENV_NAME}=" "$PI_ENV_FILE"; then
    tmp="$(mktemp)"
    sed -E "s|^[[:space:]]*(export[[:space:]]+)?${KEY_ENV_NAME}=.*|export ${KEY_ENV_NAME}=\"${NEW_KEY}\"|" "$PI_ENV_FILE" > "$tmp"
    cat "$tmp" > "$PI_ENV_FILE"; rm -f "$tmp"
  else
    printf 'export %s="%s"\n' "$KEY_ENV_NAME" "$NEW_KEY" >> "$PI_ENV_FILE"
  fi
  log "Wrote key to $PI_ENV_FILE (mode 600)."
fi

# ---------------------------------------------------------------------------
# 4. Shell init: guarded export block (idempotent)
# ---------------------------------------------------------------------------
INIT_FILE="$(shell_init_files)"
log "Shell init file: $INIT_FILE"

if [ "$MODE" = "install" ]; then
  if ! grep -qF "$MARKER_BEGIN" "$INIT_FILE" 2>/dev/null; then
    {
      printf '\n%s\n' "$MARKER_BEGIN"
      printf '# Loads the ResTech API key for pi and the documented curl quickstarts.\n'
      printf '# Managed by pi-restech-setup install.sh - safe to edit, keep the markers.\n'
      printf '[ -f "$HOME/.pi/.env" ] && . "$HOME/.pi/.env"\n'
      printf '%s\n' "$MARKER_END"
    } >> "$INIT_FILE"
    log "Appended source block to $INIT_FILE."
  else
    log "Source block already present in $INIT_FILE - left as-is."
  fi

  # For bash: ensure login shells (ssh without tmux, non-interactive
  # profiles) also load ~/.bashrc, so the key is present there too.
  if [ "$(basename "${SHELL:-/bin/bash}")" = "bash" ]; then
    PROFILE="$HOME/.profile"
    if [ -f "$PROFILE" ] && ! grep -qE "bashrc" "$PROFILE" 2>/dev/null; then
      printf '\nif [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi\n' >> "$PROFILE"
      log "Made ~/.profile source ~/.bashrc for login shells."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. Copy agent config into ~/.pi/agent/ (backup-then-copy, per file)
# ---------------------------------------------------------------------------
copy_tree() {
  local src_root="$1" dst_root="$2" rel
  mkdir -p "$dst_root"
  while IFS= read -r -d '' rel; do
    local src="$src_root/$rel" dst="$dst_root/$rel"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ]; then
      if cmp -s "$src" "$dst"; then
        continue
      fi
      local bak="$dst_root/.backup-$STAMP"
      mkdir -p "$bak"
      cp -p "$dst" "$bak/$rel"
      log "Backed up existing $(echo "$dst" | sed "s|$dst_root/||") -> $bak/$rel"
    fi
    cp -p "$src" "$dst"
    log "Installed $(echo "$dst" | sed "s|$dst_root/||")"
  done < <(cd "$src_root" && find . -type f -print0 | sed -z 's|^\./||')
}

if [ "$MODE" = "install" ]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  copy_tree "$REPO_DIR/agent" "$PI_AGENT_DIR"
  # Never clobber a coworker's auth.json or models-store.json (regenerable cache).
  log "Config installed into $PI_AGENT_DIR"
fi

# ---------------------------------------------------------------------------
# 6. pi-subagents package
# ---------------------------------------------------------------------------
if [ "$MODE" = "install" ]; then
  if pi list 2>/dev/null | grep -q "pi-subagents"; then
    log "pi-subagents already installed."
  else
    log "Installing pi-subagents package..."
    pi install npm:@tintinweb/pi-subagents@0.7.3
  fi
fi

# ---------------------------------------------------------------------------
# 7. Smoke test + check mode
# ---------------------------------------------------------------------------
smoke_test() {
  log "Running live smoke test (pi -p)..."
  local out
  if ! out="$(cd /tmp && env -i HOME="$HOME" PATH="$PATH" TERM=xterm \
      RESTECH_API_KEY="$NEW_KEY" \
      timeout 60 pi --no-session --model restech/qwen3.8-flash-next -p "Reply with just: ok" 2>&1)"; then
    printf '%s\n' "$out" | head -5
    die "Smoke test failed - check the output above."
  fi
  printf '%s\n' "$out" | grep -qi "ok" || { printf '%s\n' "$out" | head -5; die "Smoke test returned unexpected output."; }
  log "Smoke test passed: pi + restech model are working."
}

if [ "$MODE" = "install" ] && [ "$VALIDATE" = "1" ]; then
  smoke_test
  log "Done. Open a NEW shell (or: source $INIT_FILE) and run 'pi' to start."
elif [ "$MODE" = "install" ]; then
  log "Done (smoke test skipped). Open a NEW shell (or: source $INIT_FILE) and run 'pi' to start."
  log "Tip: pi --model restech/qwen3.8-flash-next   (recommended default)"
  log "Tip: Ctrl+O toggles tool output expand/collapse in pi."
else
  # --check mode
  [ -f "$PI_ENV_FILE" ] || die "$PI_ENV_FILE not found. Run ./install.sh first."
  grep -qE "^[[:space:]]*(export[[:space:]]+)?${KEY_ENV_NAME}=" "$PI_ENV_FILE" || die "No ${KEY_ENV_NAME} line in $PI_ENV_FILE."
  [ -f "$PI_AGENT_DIR/settings.json" ] || die "settings.json missing from $PI_AGENT_DIR."
  [ -f "$PI_AGENT_DIR/models.json" ] || die "models.json missing from $PI_AGENT_DIR."
  [ -f "$PI_AGENT_DIR/extensions/minimal-mode.ts" ] || die "minimal-mode.ts extension missing."
  perms="$(stat -c '%a' "$PI_ENV_FILE" 2>/dev/null || stat -f '%Lp' "$PI_ENV_FILE")"
  [ "$perms" = "600" ] || warn "$PI_ENV_FILE mode is $perms (expected 600)."
  grep -qF "$MARKER_BEGIN" "$(shell_init_files)" || die "Source block missing from $(shell_init_files). Run ./install.sh."
  log "Everything looks good: key file perms, agent config, and shell block are all present."
fi
