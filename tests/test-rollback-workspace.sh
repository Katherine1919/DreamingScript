#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLLBACK_SCRIPT="$ROOT_DIR/rollback-openclaw-dreaming-ollama.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

HOME_DIR="$TEST_ROOT/home"
OPENCLAW_DIR="$HOME_DIR/.openclaw"
WORKSPACE_DIR="$OPENCLAW_DIR/workspace-main"
BIN_DIR="$TEST_ROOT/bin"
SYSTEM_ROOT="$TEST_ROOT/system-root"
mkdir -p "$OPENCLAW_DIR" "$WORKSPACE_DIR" "$BIN_DIR" "$SYSTEM_ROOT"

cat > "$OPENCLAW_DIR/openclaw.json" <<'EOF'
{"current": true, "agents": {"list": [{"id": "main", "default": true, "workspace": "~/.openclaw/workspace-main"}]}}
EOF
cat > "$OPENCLAW_DIR/openclaw.json.bak-20260101-000000" <<'EOF'
{"restored": true}
EOF
printf 'setup notes\n' > "$WORKSPACE_DIR/dreaming-official-ollama-embedding-setup.md"

printf '#!/usr/bin/env bash\nprintf "Linux\\n"\n' > "$BIN_DIR/uname"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_DIR/openclaw"
chmod +x "$BIN_DIR/uname" "$BIN_DIR/openclaw"

env \
  HOME="$HOME_DIR" \
  PATH="$BIN_DIR:$PATH" \
  CONFIRM_FULL_ROLLBACK=YES \
  ROLLBACK_SYSTEM_ROOT="$SYSTEM_ROOT" \
  bash "$ROLLBACK_SCRIPT" >/dev/null

[[ ! -e "$WORKSPACE_DIR/dreaming-official-ollama-embedding-setup.md" ]] || {
  printf 'FAIL: rollback did not remove setup notes from resolved workspace\n' >&2
  exit 1
}
jq -e '.restored == true' "$OPENCLAW_DIR/openclaw.json" >/dev/null

printf 'PASS: rollback workspace resolution\n'
