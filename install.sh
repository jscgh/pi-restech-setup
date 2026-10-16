#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${PI_SETUP_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PI_AGENT_DIR="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
PI_AGENT_DIR="${PI_AGENT_DIR%/}"
PI_ENV_FILE="$HOME/.pi/.env"
MARKER_BEGIN="# >>> pi-restech-setup >>>"
MARKER_END="# <<< pi-restech-setup <<<"
KEY_ENV_NAME="RESTECH_API_KEY"
BASE_URL_ENV_NAME="RESTECH_API_BASE_URL"
TEMP_PATHS=()

cleanup_temp_paths() {
  [ "${#TEMP_PATHS[@]}" -eq 0 ] || rm -rf -- "${TEMP_PATHS[@]}"
}
trap cleanup_temp_paths EXIT

STAMP="$(date +%Y%m%d-%H%M%S)"
MODE="install"
FORCE_KEY=0
VALIDATE=1
UPDATE_PI=1
UPDATE_PACKAGES=1
PROFILE="${PI_SETUP_PROFILE:-auto}"
[ "${PI_SETUP_NO_UPDATE_PI:-}" = "1" ] && UPDATE_PI=0
[ "${PI_SETUP_NO_UPDATE_PACKAGES:-}" = "1" ] && UPDATE_PACKAGES=0

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

  --check               Verify without changing files
  --profile NAME        Select auto, katana, or default (default: auto)
  --force-key           Replace the stored API key
  --no-validate         Skip the live model check
  --no-update-pi        Keep the installed Pi version
  --no-update-packages  Skip package updates
  -h, --help            Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --profile)
      shift
      [ $# -gt 0 ] || { echo "--profile requires a name" >&2; exit 2; }
      PROFILE="$1"
      ;;
    --no-update-pi) UPDATE_PI=0 ;;
    --no-update-packages) UPDATE_PACKAGES=0 ;;
    --force-key) FORCE_KEY=1 ;;
    --no-validate) VALIDATE=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ "$PROFILE" = "auto" ]; then
  HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
  HOSTNAME_SHORT="${HOSTNAME_SHORT%%.*}"
  HOSTNAME_SHORT="${HOSTNAME_SHORT,,}"
  case "$HOSTNAME_SHORT" in
    katana|katana[1-3]|kdm|k[0-9][0-9][0-9]) PROFILE="katana" ;;
    *) PROFILE="default" ;;
  esac
fi

if [ "$PROFILE" = "default" ]; then
  PROFILE_DIR=""
else
  PROFILE_DIR="$REPO_DIR/profiles/$PROFILE"
  [ -d "$PROFILE_DIR" ] || { echo "Unknown profile: $PROFILE" >&2; exit 2; }
fi

log()  { printf '\033[1;34m[pi-setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[pi-setup] WARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[pi-setup] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v pi >/dev/null 2>&1 || die "pi not found on PATH. Install pi first (https://github.com/earendil-works/pi)."
command -v node >/dev/null 2>&1 || die "node not found on PATH. Install Node.js first."
command -v git >/dev/null 2>&1 || die "git not found on PATH. Install Git first."
if [ "$MODE" = "install" ] && [ "$VALIDATE" = "1" ]; then
  command -v curl >/dev/null 2>&1 || die "curl not found on PATH. Install curl or use --no-validate."
  command -v timeout >/dev/null 2>&1 || die "timeout not found on PATH. Install GNU coreutils or use --no-validate."
fi
log "pi: $(command -v pi)"

detect_base_url() {
  if [ -n "${!BASE_URL_ENV_NAME:-}" ]; then
    printf '%s' "${!BASE_URL_ENV_NAME}"
    return 0
  fi
  if [ -f "$PI_AGENT_DIR/models.json" ]; then
    node - "$PI_AGENT_DIR/models.json" <<'NODE'
const fs = require("node:fs");
const file = process.argv[2];
try {
  const value = JSON.parse(fs.readFileSync(file, "utf8")).providers?.restech?.baseUrl;
  if (typeof value === "string" && value && !value.includes("__RESTECH_")) process.stdout.write(value);
} catch {}
NODE
  fi
}

BASE_URL="$(detect_base_url || true)"
if [ "$MODE" = "install" ] && [ -z "$BASE_URL" ]; then
  if [ -t 0 ]; then
    printf 'ResTech API base URL: '
    read -r BASE_URL || die "Aborted."
  else
    die "No API base URL available. Set ${BASE_URL_ENV_NAME} for the first installation."
  fi
fi
BASE_URL="${BASE_URL%/}"
if [ "$MODE" = "install" ]; then
  case "$BASE_URL" in
    *[[:space:]]*|*[[:cntrl:]]*) die "The API base URL must not contain whitespace or control characters." ;;
    https://*) : ;;
    *) die "The API base URL must use HTTPS." ;;
  esac
fi

detect_user_shell() {
  local name login_shell parent
  name="$(basename "${SHELL:-}")"
  case "$name" in bash|zsh) printf '%s\n' "$name"; return ;; esac

  login_shell="$(getent passwd "${USER:-$(id -un)}" 2>/dev/null | cut -d: -f7)"
  name="$(basename "$login_shell")"
  case "$name" in bash|zsh) printf '%s\n' "$name"; return ;; esac

  parent="$(ps -p "$PPID" -o comm= 2>/dev/null | sed 's/^-//')"
  name="$(basename "$parent")"
  case "$name" in bash|zsh) printf '%s\n' "$name"; return ;; esac
  printf '%s\n' sh
}

shell_init_files() {
  case "$(detect_user_shell)" in
    bash) echo "$HOME/.bashrc" ;;
    zsh)  echo "$HOME/.zshrc" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

env_file_value() {
  local file="$1" name="$2"
  [ -f "$file" ] || return 1
  node - "$file" "$name" <<'NODE'
const fs = require("node:fs");
const [file, name] = process.argv.slice(2);
const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const pattern = new RegExp(`^\\s*(?:export\\s+)?${escaped}=`);
const line = fs.readFileSync(file, "utf8").split(/\r?\n/).filter((item) => pattern.test(item)).at(-1);
if (!line) process.exit(1);
let value = line.slice(line.indexOf("=") + 1).trim();
if (value.startsWith("'") && value.endsWith("'")) {
  value = value.slice(1, -1).replace(/'\\''/g, "'");
} else if (value.startsWith('"') && value.endsWith('"')) {
  value = value.slice(1, -1).replace(/\\(["\\$`])/g, "$1");
}
process.stdout.write(value);
NODE
}

KNOWN_KEY_FILES=("$HOME/.codex/.env" "$HOME/.config/pi/.env" "$HOME/.restech.env")

detect_api_key() {
  if [ -n "${!KEY_ENV_NAME:-}" ]; then
    printf '%s' "${!KEY_ENV_NAME}"
    return 0
  fi
  local f v
  if v="$(env_file_value "$PI_ENV_FILE" "$KEY_ENV_NAME")" && [ -n "$v" ]; then
    printf '%s' "$v"
    return 0
  fi
  for f in "${KNOWN_KEY_FILES[@]}"; do
    if v="$(env_file_value "$f" "$KEY_ENV_NAME")" && [ -n "$v" ]; then
      printf '%s' "$v"
      return 0
    fi
  done
  return 1
}

EXISTING_KEY=""
NEW_KEY=""
EXISTING_KEY="$(detect_api_key || true)"

need_key() {
  [ "$MODE" = "install" ] && { [ "$FORCE_KEY" = "1" ] || [ -z "$EXISTING_KEY" ]; }
}

if need_key && [ ! -t 0 ] && [ -z "${RESTECH_API_KEY:-}" ] && { [ -z "$EXISTING_KEY" ] || [ "$FORCE_KEY" = "1" ]; }; then
  ENTERED_KEY="$(head -n1)"
  NEW_KEY="${ENTERED_KEY%$'\r'}"
  case "$NEW_KEY" in
    \"*\") NEW_KEY="${NEW_KEY:1:${#NEW_KEY}-2}" ;;
    \'*\') NEW_KEY="${NEW_KEY:1:${#NEW_KEY}-2}" ;;
  esac
  [ -n "$NEW_KEY" ] || die "Empty key on stdin."
  case "$NEW_KEY" in
    *[[:space:]]*) die "Key contains whitespace - pipe the bare sk-... value." ;;
  esac
fi

if need_key; then
  if [ ! -t 0 ]; then
    if [ -n "$NEW_KEY" ]; then
      :
    elif [ -n "$EXISTING_KEY" ]; then
      NEW_KEY="$EXISTING_KEY"
    else
      die "No TTY and no ${KEY_ENV_NAME} available. Set ${KEY_ENV_NAME}=sk-... in the environment, pipe the key on stdin, or run install.sh interactively."
    fi
  else
    log "Enter your ResTech Local Inference API key (looks like: sk-...)."
    log "Use the key supplied through the ResTech access process."
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
  http_code="$(printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$key" | \
    curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H @- -d "$body" "$BASE_URL/chat/completions")"
  case "$http_code" in
    200) return 0 ;;
    401|403) die "Key rejected by the gateway (HTTP $http_code). Double-check you pasted the full sk-... key." ;;
    000) warn "Could not reach the gateway (network?). Continuing; validation skipped."; return 2 ;;
    *)   warn "Unexpected HTTP $http_code from the gateway; key may still be OK (endpoint status can be transient). Continuing."; return 2 ;;
  esac
}

if [ "$MODE" = "install" ] && [ "$VALIDATE" = "1" ]; then
  if validate_key_live "$NEW_KEY"; then
    log "Key accepted by the gateway."
  fi
elif [ "$MODE" = "install" ]; then
  warn "Live key validation skipped (--no-validate)."
fi

if [ "$MODE" = "install" ] && { [ -n "$NEW_KEY" ] && [ "$NEW_KEY" != "$EXISTING_KEY" ] || [ "$FORCE_KEY" = "1" ] || [ ! -f "$PI_ENV_FILE" ]; }; then
  mkdir -p "$(dirname "$PI_ENV_FILE")"
  previous_umask="$(umask)"
  umask 077
  touch "$PI_ENV_FILE"
  chmod 600 "$PI_ENV_FILE"
  escaped_key="${NEW_KEY//\'/\'\\\'\'}"
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?${KEY_ENV_NAME}=" "$PI_ENV_FILE"; then
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${KEY_ENV_NAME}= ]]; then
        printf "export %s='%s'\\n" "$KEY_ENV_NAME" "$escaped_key"
      else
        printf '%s\n' "$line"
      fi
    done < "$PI_ENV_FILE" > "$tmp"
    cat "$tmp" > "$PI_ENV_FILE"
    rm -f "$tmp"
  else
    printf "export %s='%s'\\n" "$KEY_ENV_NAME" "$escaped_key" >> "$PI_ENV_FILE"
  fi
  umask "$previous_umask"
  log "Wrote key to $PI_ENV_FILE (mode 600)."
fi

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

  if [ "$(detect_user_shell)" = bash ]; then
    SHELL_PROFILE="$HOME/.profile"
    if [ -f "$SHELL_PROFILE" ] && ! grep -qE "bashrc" "$SHELL_PROFILE" 2>/dev/null; then
      printf '\nif [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi\n' >> "$SHELL_PROFILE"
      log "Made ~/.profile source ~/.bashrc for login shells."
    fi
  fi
fi


case "$REPO_DIR/agent" in
  "$PI_AGENT_DIR"|"$PI_AGENT_DIR"/*) die "REPO_DIR ($REPO_DIR) is inside $PI_AGENT_DIR -- refusing to sync." ;;
esac
case "$PI_AGENT_DIR" in
  "$REPO_DIR/agent"/*) die "PI_AGENT_DIR ($PI_AGENT_DIR) is inside the source tree -- refusing to sync." ;;
esac
[ -d "$REPO_DIR/agent" ] || die "REPO_DIR ($REPO_DIR) has no agent/ dir -- is this the pi-restech-setup repo?"

render_models() {
  RESTECH_API_BASE_URL="$BASE_URL" node - "$1" "$2" <<'NODE'
const fs = require("node:fs");
const [source, destination] = process.argv.slice(2);
const value = JSON.parse(fs.readFileSync(source, "utf8"));
value.providers.restech.baseUrl = process.env.RESTECH_API_BASE_URL;
fs.writeFileSync(destination, `${JSON.stringify(value, null, 2)}\n`);
NODE
}

copy_tree() {
  local src_root="$1" dst_root="$2" rel src dst bak generated
  mkdir -p "$dst_root"
  while IFS= read -r -d '' rel; do
    local src="$src_root/$rel" dst="$dst_root/$rel"
    generated=""
    if [ "$src_root" = "$REPO_DIR/agent" ] && [ "$rel" = "models.json" ]; then
      generated="$(mktemp)"
      TEMP_PATHS+=("$generated")
      render_models "$src" "$generated"
      src="$generated"
    fi
    mkdir -p "$(dirname "$dst")"
    if [ -f "$dst" ]; then
      if cmp -s "$src" "$dst"; then
        [ -z "$generated" ] || rm -f "$generated"
        continue
      fi
      bak="$dst_root/.backup-$STAMP/$rel"
      mkdir -p "$(dirname "$bak")"
      cp -p "$dst" "$bak"
      log "Backed up existing ${rel} -> $bak"
    fi
    cp -p "$src" "$dst"
    [ -z "$generated" ] || rm -f "$generated"
    log "Installed $(echo "$dst" | sed "s|$dst_root/||")"
  done < <(
    cd "$src_root"
    while IFS= read -r -d '' found; do printf '%s\0' "${found#./}"; done \
      < <(find . -type f -print0) | excluded_files
  )
}

PERSONAL_FILES="${PI_SETUP_PERSONAL_FILES:-AGENTS.md settings.json}"

settings_match_template() {
  node - "$REPO_DIR/agent/settings.json" "$PI_AGENT_DIR/settings.json" <<'NODE'
const fs = require("fs");
const [templateFile, installedFile] = process.argv.slice(2);
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  }
  return value;
}
function normalized(file) {
  const value = JSON.parse(fs.readFileSync(file, "utf8"));
  delete value.lastChangelogVersion;
  return JSON.stringify(canonical(value));
}
try {
  process.exit(normalized(templateFile) === normalized(installedFile) ? 0 : 1);
} catch (error) {
  console.error(error.message);
  process.exit(2);
}
NODE
}

is_personal() {
  local rel="$1" pf base
  for pf in $PERSONAL_FILES; do
    [ "$rel" = "$pf" ] && return 0
  done
  return 1
}

excluded_files() {
  local rel
  while IFS= read -r -d '' rel; do
    is_personal "$rel" || printf '%s\0' "$rel"
  done
}

install_agents_file() {
  local src="$REPO_DIR/agent/AGENTS.md" dst="$PI_AGENT_DIR/AGENTS.md"
  local state_dir="$PI_AGENT_DIR/.pi-restech-setup/base" base
  local candidate tmp rev status
  base="$state_dir/AGENTS.md"
  mkdir -p "$state_dir"

  if [ ! -f "$dst" ]; then
    cp -p "$src" "$dst"
    cp -p "$src" "$base"
    log "Installed AGENTS.md."
    return
  fi
  if cmp -s "$src" "$dst"; then
    cp -p "$src" "$base"
    log "AGENTS.md unchanged."
    return
  fi

  if [ ! -f "$base" ] && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    candidate="$(mktemp)"
    while IFS= read -r rev; do
      git -C "$REPO_DIR" show "$rev:agent/AGENTS.md" > "$candidate" 2>/dev/null || continue
      if cmp -s "$candidate" "$dst"; then
        cp -p "$candidate" "$base"
        break
      fi
    done < <(git -C "$REPO_DIR" rev-list HEAD -- agent/AGENTS.md)
    rm -f "$candidate"
  fi

  if [ ! -f "$base" ]; then
    cp -p "$src" "$base"
    log "AGENTS.md has untracked personal changes; kept yours and recorded the current template for future merges."
    return
  fi
  if cmp -s "$src" "$base"; then
    log "AGENTS.md has personal changes and is current."
    return
  fi

  tmp="$(mktemp)"
  status=0
  git merge-file -p "$dst" "$base" "$src" > "$tmp" || status=$?
  if [ "$status" -eq 0 ]; then
    cp -p "$dst" "$dst.bak"
    cat "$tmp" > "$dst"
    cp -p "$src" "$base"
    log "Merged template updates into personal AGENTS.md (previous copy: $dst.bak)."
  elif [ "$status" -eq 1 ]; then
    warn "AGENTS.md template update conflicts with personal edits; kept yours."
  else
    rm -f "$tmp"
    die "Could not merge AGENTS.md template updates."
  fi
  rm -f "$tmp"
}

install_personal_file() {
  local pf_rel="$1" src dst
  [ -n "$pf_rel" ] || return 0
  if [ "$pf_rel" = "AGENTS.md" ]; then
    install_agents_file
    return
  fi
  src="$REPO_DIR/agent/$pf_rel"; dst="$PI_AGENT_DIR/$pf_rel"
  [ -f "$src" ] || return 0
  if [ ! -f "$dst" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
    log "Installed $pf_rel (first time; now yours to keep)."
  elif cmp -s "$src" "$dst"; then
    log "$pf_rel unchanged."
  else
    [ -f "$dst.bak" ] || cp -p "$dst" "$dst.bak" 2>/dev/null || true
    log "$pf_rel differs from the template -> kept yours. See: diff '$REPO_DIR/agent/$pf_rel' '$dst'"
  fi
}

if [ "$MODE" = "install" ]; then
  for pf_ in $PERSONAL_FILES; do install_personal_file "$pf_"; done
fi

if [ "$MODE" = "install" ]; then
  copy_tree "$REPO_DIR/agent" "$PI_AGENT_DIR"
  if [ -n "$PROFILE_DIR" ]; then
    copy_tree "$PROFILE_DIR" "$PI_AGENT_DIR"
    log "Applied host profile: $PROFILE"
  fi
  log "Config installed into $PI_AGENT_DIR"
fi

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


if [ "$MODE" = "install" ]; then
  log "Installing/updating pi-subagents (latest release)..."
  if ! pi install npm:@tintinweb/pi-subagents; then
    warn "Could not install/update pi-subagents (offline?). Continuing with whatever is installed."
  fi

  if pi list 2>/dev/null | grep -qF "$REPO_DIR"; then
    log "Removing legacy local pi-notify package registration..."
    pi remove "$REPO_DIR"
  fi

  if [ "$UPDATE_PACKAGES" = "1" ]; then
    pi update --extensions || warn "Could not refresh installed pi packages."
  else
    log "Skipping package updates (--no-update-packages)."
  fi

fi

smoke_test() {
  log "Running live smoke test (pi -p)..."
  local out smoke_parent smoke_dir
  smoke_parent="${PI_SETUP_SMOKE_DIR:-$HOME/.cache/pi-restech-setup}"
  mkdir -p "$smoke_parent"
  smoke_dir="$(mktemp -d "$smoke_parent/smoke.XXXXXX")"
  TEMP_PATHS+=("$smoke_dir")
  if ! out="$(cd "$smoke_dir" && env -i HOME="$HOME" PATH="$PATH" TERM=xterm \
      PI_CODING_AGENT_DIR="$PI_AGENT_DIR" RESTECH_API_KEY="$NEW_KEY" \
      timeout 60 pi --no-session --model restech/qwen3.8-flash-next -p "Reply with just: ok" 2>&1)"; then
    rm -rf "$smoke_dir"
    printf '%s\n' "$out" | head -5
    die "Smoke test failed - check the output above."
  fi
  rm -rf "$smoke_dir"
  out="${out//$'\r'/}"
  [ "${out,,}" = "ok" ] || { printf '%s\n' "$out" | head -5; die "Smoke test returned unexpected output."; }
  log "Smoke test passed: pi + restech model are working."
}

if [ "$MODE" = "install" ] && [ "$VALIDATE" = "1" ]; then
  smoke_test
  log "Done. Open a NEW shell (or: source $INIT_FILE) and run 'pi' to start."
elif [ "$MODE" = "install" ]; then
  log "Done (smoke test skipped). Open a NEW shell (or: source $INIT_FILE) and run 'pi' to start."
  log "Tip: pi --model restech/glm-5.3-flash --thinking low   (recommended default)"
  log "Tip: Ctrl+O toggles tool output expand/collapse in pi."
  log "Tip: vcs-guard.ts asks before any 'git push'/gh/npm publish; it never blocks local commits."
else
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
  for pf_ in $PERSONAL_FILES; do
    if [ -f "$REPO_DIR/agent/$pf_" ] && [ -f "$PI_AGENT_DIR/$pf_" ]; then
      if [ "$pf_" = "settings.json" ]; then
        if settings_match_template; then
          log "$pf_ matches the template (ignoring Pi-managed state)."
        else
          settings_status=$?
          [ "$settings_status" -eq 1 ] \
            || die "Could not parse settings.json while comparing it with the template."
          log "$pf_ is personal & differs from template (ignoring Pi-managed state; kept yours)."
        fi
      elif cmp -s "$REPO_DIR/agent/$pf_" "$PI_AGENT_DIR/$pf_"; then
        log "$pf_ matches the template."
      elif [ "$pf_" = "AGENTS.md" ] \
        && [ -f "$PI_AGENT_DIR/.pi-restech-setup/base/AGENTS.md" ] \
        && cmp -s "$REPO_DIR/agent/AGENTS.md" "$PI_AGENT_DIR/.pi-restech-setup/base/AGENTS.md"; then
        log "AGENTS.md personal changes are based on the current template."
      else
        log "$pf_ is personal & needs merging; run ./install.sh."
      fi
    fi
  done

  while IFS= read -r -d '' shared_rel; do
    [ -f "$PI_AGENT_DIR/$shared_rel" ] || die "Shared config missing: $PI_AGENT_DIR/$shared_rel"
    if [ "$shared_rel" = "models.json" ]; then
      check_models="$(mktemp)"
      TEMP_PATHS+=("$check_models")
      render_models "$REPO_DIR/agent/models.json" "$check_models"
      cmp -s "$check_models" "$PI_AGENT_DIR/models.json" || {
        rm -f "$check_models"
        die "Shared config differs: $PI_AGENT_DIR/models.json; run ./install.sh to update it."
      }
      rm -f "$check_models"
    else
      cmp -s "$REPO_DIR/agent/$shared_rel" "$PI_AGENT_DIR/$shared_rel" \
        || die "Shared config differs: $PI_AGENT_DIR/$shared_rel; run ./install.sh to update it."
    fi
  done < <(
    cd "$REPO_DIR/agent"
    while IFS= read -r -d '' found; do printf '%s\0' "${found#./}"; done \
      < <(find . -type f -print0) | excluded_files
  )
  log "Shared agent configuration is installed and current."

  if [ -n "$PROFILE_DIR" ]; then
    while IFS= read -r -d '' profile_file; do
      profile_rel="${profile_file#"$PROFILE_DIR/"}"
      [ -f "$PI_AGENT_DIR/$profile_rel" ] || die "Profile file missing: $PI_AGENT_DIR/$profile_rel"
      cmp -s "$profile_file" "$PI_AGENT_DIR/$profile_rel" || die "Profile file differs: $PI_AGENT_DIR/$profile_rel"
    done < <(find "$PROFILE_DIR" -type f -print0)
    log "Host profile $PROFILE is installed."
  fi

  node "$REPO_DIR/tests/vcs-guard.test.cjs" >/dev/null 2>&1 || die "vcs-guard rules failed their test suite; do not rely on the guard."
  log "vcs-guard installed and its rule suite passes."
  if [ -f "$PI_ENV_FILE" ]; then
    perms="$(stat -c '%a' "$PI_ENV_FILE" 2>/dev/null || stat -f '%Lp' "$PI_ENV_FILE")"
    [ "$perms" = "600" ] || warn "$PI_ENV_FILE mode is $perms (expected 600)."
  fi
  if ! grep -qF "$MARKER_BEGIN" "$(shell_init_files)" 2>/dev/null; then
    warn "No installer block in $(shell_init_files). Fine if you wire ${KEY_ENV_NAME} up yourself (e.g. via ~/.profile); re-run ./install.sh to add it."
  fi
  log "Check passed: key found, agent config present, vcs-guard rules verified."
fi
