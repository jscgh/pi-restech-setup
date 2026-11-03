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
cmp -s "$ROOT/completions/pi.bash" "$TEMP/home/.pi/agent/completions/pi.bash"
[ "$(grep -cF 'completions/pi.bash' "$TEMP/home/.bashrc")" = 1 ]
sed -i '/completions\/pi.bash/d' "$TEMP/home/.bashrc"
printf '[[ $- == *i* && -f %s ]] && . %s\n' "$TEMP/home/.pi/agent/completions/pi.bash" "$TEMP/home/.pi/agent/completions/pi.bash" >> "$TEMP/home/.bashrc"
run_installer_without_url --profile default --no-validate --no-update-pi --no-update-packages >/dev/null
[ "$(grep -cF 'completions/pi.bash' "$TEMP/home/.bashrc")" = 1 ]
bash -c 'source "$1"; COMP_WORDS=(pi update --ext); COMP_CWORD=2; _pi_restech_setup_complete; [[ " ${COMPREPLY[*]} " == *" --extensions "* ]]' _ "$TEMP/home/.pi/agent/completions/pi.bash"
HOME="$TEMP/home" bash --noprofile --rcfile "$TEMP/home/.bashrc" -ic 'complete -p pi' >/dev/null 2>&1
node - "$TEMP/home/.bashrc" <<'NODE'
const fs = require('node:fs');
const contents = fs.readFileSync(process.argv[2], 'utf8');
const start = contents.indexOf('# >>> pi-restech-setup >>>');
const end = contents.indexOf('# <<< pi-restech-setup <<<');
const loader = contents.indexOf('completions/pi.bash');
if (!(start < loader && loader < end)) process.exit(1);
NODE
mkdir -p "$TEMP/zhome"
env -i HOME="$TEMP/zhome" PATH="$TEMP/bin:$PATH" SHELL=/bin/zsh PI_SETUP_REPO_DIR="$ROOT" PI_CODING_AGENT_DIR="$TEMP/zhome/.pi/agent" RESTECH_API_BASE_URL=https://example.invalid/v1 RESTECH_API_KEY=sk-test bash "$ROOT/install.sh" --profile default --no-validate --no-update-pi --no-update-packages >/dev/null
cmp -s "$ROOT/completions/pi.zsh" "$TEMP/zhome/.pi/agent/completions/pi.zsh"
grep -Fq 'completions/pi.zsh' "$TEMP/zhome/.zshrc"
if command -v zsh >/dev/null; then
  HOME="$TEMP/zhome" zsh -ic '(( $+functions[_pi_restech_setup_complete] ))' >/dev/null
fi

REPLACEMENT="sk-replaced_'\$&456"
printf '"%s"\n' "$REPLACEMENT" | run_installer --force-key --profile default --no-validate --no-update-pi --no-update-packages >/dev/null
[ "$(bash -c '. "$1"; printf "%s" "$RESTECH_API_KEY"' _ "$TEMP/home/.pi/.env")" = "$REPLACEMENT" ]
run_installer --check --profile default >/dev/null
node - "$TEMP/home/.pi/agent/settings.json" <<'NODE'
const fs = require('node:fs');
const file = process.argv[2];
const settings = JSON.parse(fs.readFileSync(file, 'utf8'));
settings.defaultProvider = 'openai-codex';
settings.defaultModel = 'gpt-6-luna';
settings.enabledModels = ['openai-codex/gpt-6-luna', 'restech/qwen3.8-27b', 'sbf/glm-5.3-flash'];
settings.modelThinkingLevels['restech/qwen3.8-27b'] = 'low';
settings.modelThinkingLevels['custom/model'] = 'max';
settings.theme = 'light';
fs.writeFileSync(file, JSON.stringify(settings));
NODE
run_installer --profile default --no-validate --no-update-pi --no-update-packages -n > "$TEMP/changes.log"
grep -Fq 'Settings update' "$TEMP/changes.log"
grep -Fq 'default provider/model: openai-codex gpt-6-luna -> restech glm-5.3-flash' "$TEMP/changes.log"
[ "$(grep -cF 'enabled models and thinking levels:' "$TEMP/changes.log")" = 1 ]
grep -Fq '+ restech/glm-5.3-flash (thinking: low)' "$TEMP/changes.log"
grep -Fq -- '- sbf/glm-5.3-flash' "$TEMP/changes.log"
grep -Fq '~ restech/qwen3.8-27b: thinking low -> high' "$TEMP/changes.log"
[ "$(node -p 'require(process.argv[1]).defaultModel' "$TEMP/home/.pi/agent/settings.json")" = gpt-6-luna ]
run_installer --profile default --no-validate --no-update-pi --no-update-packages -y >/dev/null
[ "$(node -p 'require(process.argv[1]).defaultModel' "$TEMP/home/.pi/agent/settings.json")" = glm-5.3-flash ]
[ "$(node -p 'require(process.argv[1]).defaultProvider' "$TEMP/home/.pi/agent/settings.json")" = restech ]
[ "$(node -p 'require(process.argv[1]).theme' "$TEMP/home/.pi/agent/settings.json")" = dark ]
[ "$(node -p 'require(process.argv[1]).modelThinkingLevels["custom/model"]' "$TEMP/home/.pi/agent/settings.json")" = max ]
[ "$(node -p 'require(process.argv[1]).modelThinkingLevels["restech/qwen3.8-27b"]' "$TEMP/home/.pi/agent/settings.json")" = high ]
[ "$(node -p 'require(process.argv[1]).modelThinkingLevels["sbf/glm-5.3-flash"]' "$TEMP/home/.pi/agent/settings.json")" = undefined ]
[ "$(node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).defaultModel' "$TEMP/home/.pi/agent/settings.json.bak")" = gpt-6-luna ]
