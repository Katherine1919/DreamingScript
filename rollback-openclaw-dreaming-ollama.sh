#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[INFO] %s\n' "$*"
}

warning() {
  printf '[WARNING] %s\n' "$*" >&2
}

abort() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

expand_home_path() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

resolve_workspace() {
  local agent="${MEMORY_AGENT:-}"
  local workspace="${OPENCLAW_WORKSPACE:-}"

  if [[ -z "$agent" && -f "$CONFIG_PATH" ]] && command_exists jq; then
    agent="$(jq -r '([.agents.list[]? | select(.default == true) | .id][0] // .agents.list[0].id // empty)' "$CONFIG_PATH")"
  fi
  agent="${agent:-main}"

  if [[ -z "$workspace" && -f "$CONFIG_PATH" ]] && command_exists jq; then
    workspace="$(jq -r --arg agent "$agent" '([.agents.list[]? | select(.id == $agent) | .workspace][0] // .agents.defaults.workspace // empty)' "$CONFIG_PATH")"
  fi
  if [[ -z "$workspace" ]]; then
    if [[ "$agent" == "main" ]]; then
      workspace="$OPENCLAW_HOME/workspace"
    else
      workspace="$OPENCLAW_HOME/workspace-$agent"
    fi
  fi
  expand_home_path "$workspace"
}

run_privileged() {
  if [[ -n "$ROLLBACK_SYSTEM_ROOT" ]]; then
    "$@"
  elif [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    abort "需要管理员权限执行：$*。请安装 sudo 或以 root 用户运行。"
  fi
}

system_path() {
  printf '%s%s' "$ROLLBACK_SYSTEM_ROOT" "$1"
}

validate_json_file() {
  local path="$1"
  if command_exists jq; then
    jq -e 'type == "object"' "$path" >/dev/null 2>&1
  elif command_exists python3; then
    python3 -m json.tool "$path" >/dev/null 2>&1
  else
    abort "无法验证备份 JSON：未找到 jq 或 python3。请先安装 jq。"
  fi
}

find_earliest_backup() {
  local config_dir config_name
  config_dir="$(dirname "$CONFIG_PATH")"
  config_name="$(basename "$CONFIG_PATH")"
  find "$config_dir" -maxdepth 1 -type f -name "${config_name}.bak-*" -print 2>/dev/null \
    | LC_ALL=C sort \
    | head -n 1
}

restart_openclaw() {
  if ! command_exists openclaw; then
    warning "未找到 openclaw 命令，无法自动重启。"
    return 0
  fi

  if openclaw gateway restart; then
    log "已执行 openclaw gateway restart。"
  elif openclaw restart; then
    log "已执行 openclaw restart。"
  else
    warning "OpenClaw 自动重启失败，请手动运行：openclaw gateway restart"
  fi
}

stop_ollama() {
  if command_exists systemctl; then
    run_privileged systemctl stop ollama 2>/dev/null || true
    run_privileged systemctl disable ollama 2>/dev/null || true
  fi
  if command_exists pkill; then
    run_privileged pkill -x ollama 2>/dev/null || true
  fi
}

remove_ollama_files() {
  local path
  local system_paths=(
    "/etc/systemd/system/ollama.service"
    "/etc/systemd/system/ollama.service.d"
    "/usr/lib/systemd/system/ollama.service"
    "/lib/systemd/system/ollama.service"
    "/usr/local/bin/ollama"
    "/usr/bin/ollama"
    "/bin/ollama"
    "/usr/local/lib/ollama"
    "/usr/lib/ollama"
    "/lib/ollama"
    "/usr/share/ollama"
    "/var/lib/ollama"
    "/var/cache/ollama"
    "/root/.ollama"
  )

  for path in "${system_paths[@]}"; do
    run_privileged rm -rf -- "$(system_path "$path")"
  done
  rm -rf -- "$HOME/.ollama"

  if command_exists systemctl; then
    run_privileged systemctl daemon-reload 2>/dev/null || true
    run_privileged systemctl reset-failed ollama 2>/dev/null || true
  fi
}

remove_ollama_account() {
  if [[ -n "$ROLLBACK_SYSTEM_ROOT" ]]; then
    log "测试根目录模式：跳过系统用户和组删除。"
    return 0
  fi

  if command_exists id && id ollama >/dev/null 2>&1; then
    run_privileged userdel ollama 2>/dev/null || warning "无法删除 ollama 用户，请手动运行：sudo userdel ollama"
  fi
  if command_exists getent && getent group ollama >/dev/null 2>&1; then
    run_privileged groupdel ollama 2>/dev/null || warning "无法删除 ollama 组，请手动运行：sudo groupdel ollama"
  fi
}

clean_openclaw_artifacts() {
  rm -f -- "$SETUP_NOTES_PATH" "$LEGACY_SETUP_NOTES_PATH" "$OPENCLAW_HOME/ollama.log"
}

CONFIG_PATH="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
OPENCLAW_HOME="$HOME/.openclaw"
RESOLVED_WORKSPACE="$(resolve_workspace)"
SETUP_NOTES_PATH="$RESOLVED_WORKSPACE/dreaming-official-ollama-embedding-setup.md"
LEGACY_SETUP_NOTES_PATH="$OPENCLAW_HOME/dreaming-ollama-embedding-setup.md"
ROLLBACK_SYSTEM_ROOT="${ROLLBACK_SYSTEM_ROOT:-}"

[[ "$(uname -s)" == "Linux" ]] || abort "此回滚脚本仅支持 Linux。"
[[ "${CONFIRM_FULL_ROLLBACK:-}" == "YES" ]] || abort "这是不可逆操作。请设置 CONFIRM_FULL_ROLLBACK=YES 后重新运行。"

if [[ -n "$ROLLBACK_SYSTEM_ROOT" ]]; then
  [[ "$ROLLBACK_SYSTEM_ROOT" == /* && "$ROLLBACK_SYSTEM_ROOT" != "/" ]] || \
    abort "ROLLBACK_SYSTEM_ROOT 必须是非根目录的绝对路径。"
fi

[[ -d "$(dirname "$CONFIG_PATH")" ]] || abort "OpenClaw 配置目录不存在：$(dirname "$CONFIG_PATH")"

BACKUP_PATH="$(find_earliest_backup)"
[[ -n "$BACKUP_PATH" && -f "$BACKUP_PATH" ]] || \
  abort "没有找到 ${CONFIG_PATH}.bak-*。为避免不可逆误操作，未恢复配置，也未卸载 Ollama。"
validate_json_file "$BACKUP_PATH" || abort "最早备份不是合法 JSON 对象，未执行任何修改：$BACKUP_PATH"

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
PRE_ROLLBACK_PATH="${CONFIG_PATH}.pre-full-rollback-${TIMESTAMP}"
if [[ -f "$CONFIG_PATH" ]]; then
  cp -p "$CONFIG_PATH" "$PRE_ROLLBACK_PATH"
else
  PRE_ROLLBACK_PATH="not created (current config was absent)"
fi

log "将恢复最早备份：$BACKUP_PATH"
cp -p "$BACKUP_PATH" "$CONFIG_PATH"
validate_json_file "$CONFIG_PATH" || abort "恢复后的配置校验失败，请从以下文件手动恢复：$PRE_ROLLBACK_PATH"

clean_openclaw_artifacts

log "正在停止并彻底卸载 Ollama，包括全部模型和缓存。"
stop_ollama
remove_ollama_files
remove_ollama_account

restart_openclaw

cat <<EOF

OpenClaw Dreaming + Ollama full rollback complete.

Restored config from: $BACKUP_PATH
OpenClaw config path: $CONFIG_PATH
Pre-rollback config copy: $PRE_ROLLBACK_PATH
Ollama: removed
Ollama models and caches: removed
CPU-only systemd override: removed

Check:
openclaw memory status --deep
EOF
