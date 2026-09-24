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
#   5. Copies shared agent config into ~/.pi/agent/ with backups; personal
#      AGENTS.md and settings.json are installed once and never overwritten.
#   6. Updates pi to the latest public release and installs/updates packages.
#   7. Runs a live smoke test against the gateway.
#
# Writes only below ~/.pi/agent, ~/.pi/.env, and the marked shell-init block.
# Re-running is safe (idempotent). Use --no-update-pi and/or
# --no-update-packages to pin installed software for one run.
#
set -euo pipefail

REPO_DIR="${PI_SETUP_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
# Normalize a caller-supplied trailing slash so the overlap guard cannot be
# bypassed by spelling the same directory as ~/.pi/agent/.
PI_AGENT_DIR="${PI_AGENT_DIR%/}"
PI_ENV_FILE="$HOME/.pi/.env"
MARKER_BEGIN="# >>> pi-restech-setup >>>"
MARKER_END="# <<< pi-restech-setup <<<"
KEY_ENV_NAME="RESTECH_API_KEY"
KEY_URL_HINT="https://inference.restech.unsw.edu.au/ (Request access)"

STAMP="$(date +%Y%m%d-%H%M%S)"   # single timestamp for every backup this run
MODE="install"
FORCE_KEY=0
VALIDATE=1
UPDATE_PI=1
UPDATE_PACKAGES=1
[ "${PI_SETUP_NO_UPDATE_PI:-}" = "1" ] && UPDATE_PI=0
[ "${PI_SETUP_NO_UPDATE_PACKAGES:-}" = "1" ] && UPDATE_PACKAGES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --no-update-pi) UPDATE_PI=0 ;;
    --no-update-packages) UPDATE_PACKAGES=0 ;;
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

env_file_value() {
  # $1 = file, $2 = var name -> prints the value (quotes/space stripped), or nothing.
  local file="$1" name="$2" line
  [ -f "$file" ] || return 1
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${name}=" "$file" | tail -n1 || true)"
  [ -n "$line" ] || return 1
  printf '%s' "${line#*=}" | tr -d "\"'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Files a hand-written setup may legitimately load the key from. Checked only as a
# last resort, and only by --check / read-only paths (never written to).
KNOWN_KEY_FILES=("$HOME/.codex/.env" "$HOME/.config/pi/.env" "$HOME/.restech.env")

detect_api_key() {
  # Precedence for existing key: env var, then ~/.pi/.env, then known loader files.
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
  local f v
  for f in "${KNOWN_KEY_FILES[@]}"; do
    if v="$(env_file_value "$f" "$KEY_ENV_NAME")" && [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done
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

# Validate format lightly and verify the key live before writing anything, so we
# never leave a broken config behind. --check is read-only and validates key
# *reachability* later instead, so an unconfigured/alternate-loader key must not
# abort the whole check here.
if [ "$MODE" != "check" ]; then
  case "$NEW_KEY" in
    sk-*) : ;;
    *) die "Key does not look like a ResTech key (expected it to start with 'sk-')." ;;
  esac
fi

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
# 4b. Safety guards -- evaluated before any config is copied
# ---------------------------------------------------------------------------

# Hard stop if the repo/agent trees overlap: an odd REPO_DIR (e.g. the script
# invoked via `bash -c` from inside the agent dir) would otherwise copy
# $PI_AGENT_DIR onto itself and silently revert personal files like AGENTS.md.
case "$REPO_DIR/agent" in
  "$PI_AGENT_DIR"|"$PI_AGENT_DIR"/*) die "REPO_DIR ($REPO_DIR) is inside $PI_AGENT_DIR -- refusing to sync." ;;
esac
case "$PI_AGENT_DIR" in
  "$REPO_DIR/agent"/*) die "PI_AGENT_DIR ($PI_AGENT_DIR) is inside the source tree -- refusing to sync." ;;
esac
[ -d "$REPO_DIR/agent" ] || die "REPO_DIR ($REPO_DIR) has no agent/ dir -- is this the pi-restech-setup repo?"
  # Only meaningful on the install path: --check must not warn about a package
  # dir that a read-only verification of an already-working install never uses.
  if [ "$MODE" = "install" ]; then
    if [ ! -d "$REPO_DIR/package/pi-notify" ]; then
      warn "$REPO_DIR/package/pi-notify missing; pi-notify cannot be installed from this checkout."
    fi
  fi

# ---------------------------------------------------------------------------
# 5. Copy agent config into ~/.pi/agent/ (backup-then-copy, per file)
# ---------------------------------------------------------------------------
copy_tree() {
  local src_root="$1" dst_root="$2" rel src dst bak
  mkdir -p "$dst_root"
  while IFS= read -r -d '' rel; do
    local src="$src_root/$rel" dst="$dst_root/$rel"
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ]; then
      if cmp -s "$src" "$dst"; then
        continue
      fi
      # NB: `bak` is declared with the other locals, and we mkdir its *dirname*
      # rather than `$bak` itself. The original code did `local
      # bak="$dst_root/.backup-$STAMP"; mkdir -p "$bak"; cp "$dst" "$bak/$rel"`,
      # which for a nested rel (e.g. extensions/vcs-guard.ts) tried to write into
      # a `.backup-<STAMP>/extensions/` subdirectory that was never created:
      #   cp: cannot create regular file '.../.backup-TEST/extensions/vcs-guard.ts':
      #       No such file or directory
      # and under `set -e` that aborted the install mid-copy -- top-level files
      # already done, the nested one left stale AND unbacked. (Reproduced against
      # the verbatim original function.)
      # NOT the cause, despite how it reads: `local` inside an `if` block does
      # persist for the rest of the *function* scope, so `bak` was never unset.
      bak="$dst_root/.backup-$STAMP/$rel"
      mkdir -p "$(dirname "$bak")"
      cp -p "$dst" "$bak"
      log "Backed up existing ${rel} -> $bak"
    fi
    cp -p "$src" "$dst"
    log "Installed $(echo "$dst" | sed "s|$dst_root/||")"
  done < <(
    cd "$src_root"
    # Strip ./ without GNU-only `sed -z`; this remains NUL-safe.
    while IFS= read -r -d '' found; do printf '%s\0' "${found#./}"; done \
      < <(find . -type f -print0) | excluded_files
  )
}

# ---------------------------------------------------------------------------
# 4b. Personal files: never overwrite, and never install a stale template over
#     a live config. Anything the user may customise belongs in this list.
#     AGENTS.md is per-person etiquette; settings.json is where pi itself writes
#     state (lastChangelogVersion) and where `pi install` records packages --
#     copying the template over it would silently unregister pi-notify.
# ---------------------------------------------------------------------------
PERSONAL_FILES="${PI_SETUP_PERSONAL_FILES:-AGENTS.md settings.json}"


is_personal() {
  local rel="$1" pf base
  for pf in $PERSONAL_FILES; do
    # Exact relative paths only. Basename matching silently excluded future
    # shared files such as prompts/AGENTS.md.
    [ "$rel" = "$pf" ] && return 0
  done
  return 1
}

# Drop excluded entries from the find stream (NUL-delimited).
excluded_files() {
  local rel
  while IFS= read -r -d '' rel; do
    is_personal "$rel" || printf '%s\0' "$rel"
  done
}

install_personal_file() {
  local pf_rel="$1" src dst
  [ -n "$pf_rel" ] || return 0
  src="$REPO_DIR/agent/$pf_rel"; dst="$PI_AGENT_DIR/$pf_rel"
  [ -f "$src" ] || return 0
  if [ ! -f "$dst" ]; then
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst.bak" ]; then
      cp -p "$dst.bak" "$dst"
      log "Restored your $pf_rel from $dst.bak (template not applied)."
    else
      cp -p "$src" "$dst"
      log "Installed $pf_rel (first time; now yours to keep)."
    fi
  elif cmp -s "$src" "$dst"; then
    log "$pf_rel unchanged."
  else
    # Keep ONE pristine copy of the user's file (never overwritten), so they can
    # always recover their original even after many runs, and tell them how to
    # inspect the delta against the template.
    [ -f "$dst.bak" ] || cp -p "$dst" "$dst.bak" 2>/dev/null || true
    log "$pf_rel differs from the template -> kept yours. See: diff '$REPO_DIR/agent/$pf_rel' '$dst'"
  fi
}

if [ "$MODE" = "install" ]; then
  for pf_ in $PERSONAL_FILES; do install_personal_file "$pf_"; done
fi

if [ "$MODE" = "install" ]; then
  copy_tree "$REPO_DIR/agent" "$PI_AGENT_DIR"
  # Never clobber a coworker's auth.json or models-store.json (regenerable cache).
  log "Config installed into $PI_AGENT_DIR"
fi

# ---------------------------------------------------------------------------
# 5b. Keep pi itself on the latest public release
# ---------------------------------------------------------------------------
# pi is a *managed* install (see ~/.pi/agent/install/managed-install.json), so
# the supported way to move versions is `pi update` -- never npm install -g,
# which would fight the releases-v1 layout and the ~/.local/bin/pi symlink.
#
# Off-switches, because auto-updating the tool an agent is currently driving is
# a real hazard (docs: cli.md "pi update"):
#   ./install.sh --no-update-pi      one run
#   PI_SETUP_NO_UPDATE_PI=1          persistent, for people pinned to a version
#   PI_NOTIFY... (unrelated)         package-level switches live below
if [ "$MODE" = "install" ]; then
  if [ "$UPDATE_PI" = "1" ]; then
    before="$(pi --version 2>/dev/null | tail -n1 | tr -d '[:space:]' || true)"
    log "Updating pi (currently ${before:-unknown})..."
    update_out=""
    if update_out="$(pi update 2>&1)"; then
      [ -z "$update_out" ] || printf '%s\n' "$update_out"
      after="$(pi --version 2>/dev/null | tail -n1 | tr -d '[:space:]' || true)"
      if [ -n "$after" ] && [ "$after" != "$before" ]; then
        log "pi updated ${before:-?} -> ${after:-?}. Restart pi to run the new build."
      elif [ "$after" = "$before" ] && [ -n "$after" ]; then
        log "pi already at latest (${after})."
      else
        warn "Could not confirm pi version after update (got '${after:-empty}')."
      fi
    else
      [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
      warn "'pi update' failed; leaving pi at ${before:-unknown} (offline?). Continuing."
    fi
  else
    log "Skipping pi self-update (--no-update-pi)."
  fi
fi

# ---------------------------------------------------------------------------
# 6. pi packages
# ---------------------------------------------------------------------------
# `pi install` can print success for a git clone that contains no discoverable
# extension. Validate the installed package path and its manifest, not the
# source label alone.
notify_package_registered() {
  local path manifest
  while IFS= read -r path; do
    path="${path#    }"
    [ -d "$path" ] || continue
    manifest="$path/package.json"
    [ -f "$manifest" ] || continue
    if grep -q 'package/pi-notify/extensions/notify.ts\|extensions/notify.ts' "$manifest"; then
      return 0
    fi
  done < <(pi list 2>/dev/null | grep '^    /' || true)
  return 1
}

if [ "$MODE" = "install" ]; then
  if pi list 2>/dev/null | grep -q "pi-subagents"; then
    log "pi-subagents already installed."
  else
    log "Installing pi-subagents package..."
    pi install npm:@tintinweb/pi-subagents@0.7.3
  fi

  # The root package.json explicitly declares the nested notify entry point,
  # so a normal git install is now supported. This was verified in a fresh pi
  # process: one agent settle produced exactly one D-Bus Notify frame.
  PI_NOTIFY_SOURCE="${PI_NOTIFY_SOURCE:-git:github.com/jscgh/pi-restech-setup}"
  if notify_package_registered; then
    log "pi-notify already installed."
  else
    log "Installing pi-notify from $PI_NOTIFY_SOURCE ..."
    if ! pi install "$PI_NOTIFY_SOURCE"; then
      die "pi install '$PI_NOTIFY_SOURCE' failed."
    fi
    notify_package_registered \
      || die "pi installed '$PI_NOTIFY_SOURCE' but its manifest exposes no notify extension."
  fi

  # Package updates are independent from the pi binary update/pin decision.
  if [ "$UPDATE_PACKAGES" = "1" ]; then
    pi update --extensions || warn "Could not refresh installed pi packages."
  else
    log "Skipping package updates (--no-update-packages)."
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
  log "Tip: vcs-guard.ts asks before any 'git push'/gh/npm publish; it never blocks local commits."
else
  # --check mode
  # Verify the key is actually reachable, not that it lives in one specific file.
  # install.sh puts it in ~/.pi/.env, but a hand-written loader (e.g. sourcing
  # ~/.codex/.env from ~/.profile) is equally valid and must not fail the check.
  key_ok=0
  if [ -n "${!KEY_ENV_NAME:-}" ]; then
    key_ok=1
    log "${KEY_ENV_NAME} is present in the environment."
  elif [ -f "$PI_ENV_FILE" ] && grep -qE "^[[:space:]]*(export[[:space:]]+)?${KEY_ENV_NAME}=" "$PI_ENV_FILE"; then
    key_ok=1
    log "${KEY_ENV_NAME} found in $PI_ENV_FILE."
  else
    for cand in "$HOME/.codex/.env" "$HOME/.config/pi/.env" "$HOME/.restech.env"; do
      [ -f "$cand" ] && grep -qE "^[[:space:]]*(export[[:space:]]+)?${KEY_ENV_NAME}=" "$cand" && {
        key_ok=1; log "${KEY_ENV_NAME} found in $cand (loaded by your own shell config)."; break; }
    done
  fi
  [ "$key_ok" = 1 ] || die "Cannot find ${KEY_ENV_NAME} in the environment, $PI_ENV_FILE, or any known env file. Run ./install.sh."
  [ -f "$PI_AGENT_DIR/settings.json" ] || die "settings.json missing from $PI_AGENT_DIR."
  [ -f "$PI_AGENT_DIR/models.json" ] || die "models.json missing from $PI_AGENT_DIR."
  # Personal files are never overwritten, so tell the user when their copy has
  # drifted from the template (they may want the new bits by hand).
  for pf_ in $PERSONAL_FILES; do
    if [ -f "$REPO_DIR/agent/$pf_" ] && [ -f "$PI_AGENT_DIR/$pf_" ]; then
      if cmp -s "$REPO_DIR/agent/$pf_" "$PI_AGENT_DIR/$pf_"; then
        log "$pf_ matches the template."
      else
        log "$pf_ is personal & differs from template (kept yours). Diff: diff '$REPO_DIR/agent/$pf_' '$PI_AGENT_DIR/$pf_'"
      fi
    fi
  done

  [ -f "$PI_AGENT_DIR/extensions/minimal-mode.ts" ] || die "minimal-mode.ts extension missing."

  # Check the installed manifest, not a display name: pi can register an empty
  # git clone and still print "Installed".
  notify_pkg=0
  notify_package_registered && notify_pkg=1
  notify_file=0
  [ -f "$PI_AGENT_DIR/extensions/notify.ts" ] && notify_file=1
  if [ "$notify_pkg" -eq 1 ] && [ "$notify_file" -eq 1 ]; then
    warn "pi-notify is installed BOTH as a package and as $PI_AGENT_DIR/extensions/notify.ts -- you will get two banners. Delete the file."
  elif [ "$notify_pkg" -eq 0 ] && [ "$notify_file" -eq 0 ]; then
    die "pi-notify is not installed -- agent-finished notifications will not fire."
  else
    log "pi-notify present (package=$notify_pkg, file=$notify_file)."
    grep -q "PI_NOTIFY_DISABLE" "$HOME/.bashrc" 2>/dev/null || \
      log "Tip: for scripted 'pi -p' use, set PI_NOTIFY_DISABLE=1 (banners would pop)."
  fi
  # The guard is a safety control, so a silent failure to install it is worth a
  # hard stop rather than a note -- without it, remote writes are unpoliced.
  [ -f "$PI_AGENT_DIR/extensions/vcs-guard.ts" ] || die "vcs-guard.ts extension missing (remote writes are NOT being gated)."
  node "$REPO_DIR/tests/vcs-guard.test.cjs" >/dev/null 2>&1 || die "vcs-guard rules failed their test suite; do not rely on the guard."
  log "vcs-guard installed and its rule suite passes."
  if [ -f "$PI_ENV_FILE" ]; then
    perms="$(stat -c '%a' "$PI_ENV_FILE" 2>/dev/null || stat -f '%Lp' "$PI_ENV_FILE")"
    [ "$perms" = "600" ] || warn "$PI_ENV_FILE mode is $perms (expected 600)."
  fi
  if ! grep -qF "$MARKER_BEGIN" "$(shell_init_files)" 2>/dev/null; then
    # Not fatal: the key check above is the real test. A hand-written loader in
    # another init file is supported, so only warn when the key is NOT reachable.
    warn "No installer block in $(shell_init_files). Fine if you wire ${KEY_ENV_NAME} up yourself (e.g. via ~/.profile); re-run ./install.sh to add it."
  fi
  log "Check passed: key reachable, agent config present, vcs-guard rules verified."
fi
