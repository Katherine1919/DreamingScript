#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_SCRIPT="$ROOT_DIR/setup-openclaw-dreaming-ollama-embedding.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local output="$1"
  local expected="$2"
  [[ "$output" == *"$expected"* ]] || fail "expected output to contain: $expected"
}

make_fake_commands() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  printf '#!/usr/bin/env bash\nprintf "Linux\\n"\n' > "$bin_dir/uname"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/openclaw"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin_dir/ollama"
  chmod +x "$bin_dir/uname" "$bin_dir/openclaw" "$bin_dir/ollama"
}

run_setup() {
  local case_dir="$1"
  shift
  mkdir -p "$case_dir/home/.openclaw"
  make_fake_commands "$case_dir/bin"
  cat > "$case_dir/os-release" <<'EOF'
NAME="Test Linux"
PRETTY_NAME="Test Linux"
EOF
  cat > "$case_dir/home/.openclaw/openclaw.json" <<'EOF'
{
  "agents": {
    "list": [
      {"id": "main", "default": true, "workspace": "~/.openclaw/workspace-main"},
      {"id": "youtuber", "workspace": "~/.openclaw/workspace-youtuber"}
    ]
  }
}
EOF

  env \
    HOME="$case_dir/home" \
    PATH="$case_dir/bin:$PATH" \
    OS_RELEASE_FILE="$case_dir/os-release" \
    DRY_RUN=1 \
    "$@" \
    bash "$SETUP_SCRIPT"
}

default_output="$(run_setup "$TEST_ROOT/default")"
assert_contains "$default_output" "OpenClaw workspace: $TEST_ROOT/default/home/.openclaw/workspace-main"
assert_contains "$default_output" "openclaw memory index --force --agent main"

agent_output="$(run_setup "$TEST_ROOT/agent" MEMORY_AGENT=youtuber)"
assert_contains "$agent_output" "OpenClaw workspace: $TEST_ROOT/agent/home/.openclaw/workspace-youtuber"
assert_contains "$agent_output" "openclaw memory index --force --agent youtuber"

override_output="$(run_setup "$TEST_ROOT/override" MEMORY_AGENT=main OPENCLAW_WORKSPACE="$TEST_ROOT/custom-workspace")"
assert_contains "$override_output" "OpenClaw workspace: $TEST_ROOT/custom-workspace"

fallback_dir="$TEST_ROOT/fallback"
mkdir -p "$fallback_dir/home/.openclaw" "$fallback_dir/bin"
make_fake_commands "$fallback_dir/bin"
printf '{}\n' > "$fallback_dir/home/.openclaw/openclaw.json"
cat > "$fallback_dir/os-release" <<'EOF'
NAME="Test Linux"
PRETTY_NAME="Test Linux"
EOF
fallback_output="$(env HOME="$fallback_dir/home" PATH="$fallback_dir/bin:$PATH" OS_RELEASE_FILE="$fallback_dir/os-release" DRY_RUN=1 bash "$SETUP_SCRIPT")"
assert_contains "$fallback_output" "OpenClaw workspace: $fallback_dir/home/.openclaw/workspace"
assert_contains "$fallback_output" "openclaw memory index --force --agent main"

printf 'PASS: workspace resolution\n'
