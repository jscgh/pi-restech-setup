#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/bin" "$TEMP/home"
cat > "$TEMP/bin/pi" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' 'pi 1.3.0' ;;
  list) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TEMP/bin/pi"

run_installer() {
  env -i \
    HOME="$TEMP/home" \
    PATH="$TEMP/bin:$PATH" \
    SHELL=/bin/bash \
    PI_SETUP_REPO_DIR="$ROOT" \
    PI_CODING_AGENT_DIR="$TEMP/home/.pi/agent" \
    RESTECH_API_BASE_URL="https://example.invalid/v1" \
    bash "$ROOT/install.sh" "$@"
}

run_installer_without_url() {
  env -i \
    HOME="$TEMP/home" \
    PATH="$TEMP/bin:$PATH" \
    SHELL=/bin/bash \
    PI_SETUP_REPO_DIR="$ROOT" \
    PI_CODING_AGENT_DIR="$TEMP/home/.pi/agent" \
    bash "$ROOT/install.sh" "$@"
}

KEY="sk-test_'\$&123"
printf '"%s"\n' "$KEY" | run_installer --profile default --no-validate --no-update-pi --no-update-packages >/dev/null
[ "$(bash -c '. "$1"; printf "%s" "$RESTECH_API_KEY"' _ "$TEMP/home/.pi/.env")" = "$KEY" ]
[ "$(stat -c '%a' "$TEMP/home/.pi/.env")" = 600 ]
grep -Fq '"baseUrl": "https://example.invalid/v1"' "$TEMP/home/.pi/agent/models.json"
grep -Fq '"baseUrl": "__RESTECH_API_BASE_URL__"' "$ROOT/agent/models.json"
run_installer_without_url --profile default --no-validate --no-update-pi --no-update-packages >/dev/null
run_installer_without_url --check --profile default >/dev/null

REPLACEMENT="sk-replaced_'\$&456"
printf '"%s"\n' "$REPLACEMENT" | run_installer --force-key --profile default --no-validate --no-update-pi --no-update-packages >/dev/null
[ "$(bash -c '. "$1"; printf "%s" "$RESTECH_API_KEY"' _ "$TEMP/home/.pi/.env")" = "$REPLACEMENT" ]
run_installer --check --profile default >/dev/null
