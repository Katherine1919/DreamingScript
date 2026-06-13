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

require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    abort "此脚本已针对阿里云 ECS 优化，仅支持 Linux。"
  fi

  local os_name="Linux"
  if [[ -r /etc/os-release ]]; then
    os_name="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")"
  fi
  log "检测到 Linux 系统：$os_name"
}

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    abort "需要管理员权限执行：$*。请安装 sudo 或以 root 用户运行此脚本。"
  fi
}

install_package() {
  local package="$1"

  log "正在安装缺失依赖：${package}"
  if command_exists apt-get; then
    run_privileged apt-get update
    run_privileged apt-get install -y "$package"
  elif command_exists dnf; then
    run_privileged dnf install -y "$package"
  elif command_exists yum; then
    run_privileged yum install -y "$package"
  else
    abort "未找到 apt-get、dnf 或 yum，无法自动安装 ${package}。请在 ECS 上手动安装后重试。"
  fi

  command_exists "$package" || abort "${package} 安装后仍不可用，请检查 PATH 后重试。"
}

ensure_dependency() {
  local command_name="$1"
  local package_name="${2:-$1}"

  if command_exists "$command_name"; then
    log "已找到 ${command_name}。"
  else
    install_package "$package_name"
  fi
}

ollama_is_running() {
  curl -fsS --connect-timeout 3 --max-time 5 "${OLLAMA_BASE_URL%/}/api/tags" >/dev/null 2>&1
}

systemd_ollama_available() {
  command_exists systemctl && systemctl list-unit-files ollama.service >/dev/null 2>&1
}

configure_ollama_cpu_only() {
  local override_dir="/etc/systemd/system/ollama.service.d"
  local override_path="$override_dir/cpu-only.conf"
  local temp_override

  temp_override="$(mktemp)"
  printf '[Service]\nEnvironment="OLLAMA_LLM_LIBRARY=%s"\n' "$OLLAMA_LLM_LIBRARY" > "$temp_override"
  run_privileged mkdir -p "$override_dir"
  run_privileged install -m 0644 "$temp_override" "$override_path"
  rm -f "$temp_override"
  run_privileged systemctl daemon-reload
  log "Ollama systemd 服务已配置为 CPU-only：$OLLAMA_LLM_LIBRARY"
}

start_ollama() {
  if systemd_ollama_available; then
    configure_ollama_cpu_only
    run_privileged systemctl enable ollama
    run_privileged systemctl restart ollama
  elif ollama_is_running; then
    abort "检测到非 systemd 管理的 Ollama 已在运行，无法确认 CPU-only。请停止该进程后重新运行本脚本。"
  else
    log "Ollama endpoint 当前不可访问，正在以 CPU-only 模式后台启动服务。"
    nohup env OLLAMA_HOST="$OLLAMA_BASE_URL" OLLAMA_LLM_LIBRARY="$OLLAMA_LLM_LIBRARY" ollama serve > "$OPENCLAW_HOME/ollama.log" 2>&1 &
  fi

  local waited=0
  while (( waited < 30 )); do
    if ollama_is_running; then
      log "Ollama 服务已启动。"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  warning "Ollama 服务在 30 秒内未就绪。排查命令："
  warning "  ollama serve"
  warning "  curl ${OLLAMA_BASE_URL%/}/api/tags"
  warning "  journalctl -u ollama -n 100 --no-pager"
  abort "无法连接 Ollama endpoint：${OLLAMA_BASE_URL%/}"
}

initialize_memory_workspace() {
  mkdir -p "$MEMORY_DIR"
  if [[ ! -e "$MEMORY_FILE" ]]; then
    : > "$MEMORY_FILE"
    chmod 600 "$MEMORY_FILE"
    log "已创建空记忆文件：$MEMORY_FILE"
  else
    log "记忆文件已存在，保留原内容：$MEMORY_FILE"
  fi
}

write_setup_notes() {
  cat > "$SETUP_NOTES_PATH" <<EOF
# OpenClaw Dreaming + Ollama Embedding 配置记录

- Dreaming frequency: \`$DREAMING_FREQUENCY\`
- Dreaming timezone: \`$DREAMING_TIMEZONE\`
- Dreaming model 策略：沿用 OpenClaw 当前默认聊天模型，没有单独设置 \`dreaming.model\`
- memorySearch.provider: \`ollama\`
- memorySearch.model: \`$EMBEDDING_MODEL\`
- Ollama endpoint: \`${OLLAMA_BASE_URL%/}\`
- Ollama runtime: CPU-only (\`OLLAMA_LLM_LIBRARY=$OLLAMA_LLM_LIBRARY\`)
- OpenClaw config path: \`$CONFIG_PATH\`
- Memory directory: \`$MEMORY_DIR\`
- Backup path: \`$BACKUP_PATH\`

## 验证命令

\`\`\`bash
openclaw memory status --deep
openclaw memory status --index --agent "$MEMORY_AGENT"
curl -fsS "${OLLAMA_BASE_URL%/}/api/tags"
\`\`\`

进入 OpenClaw 聊天通道发送：

\`\`\`text
/dreaming status
\`\`\`

如果 Dreaming 未开启，可发送 \`/dreaming on\`。

更换 embedding model 后需要重建索引：

\`\`\`bash
openclaw memory index --force --agent "$MEMORY_AGENT"
\`\`\`

## 回滚方法

\`\`\`bash
cp "$BACKUP_PATH" "$CONFIG_PATH"
openclaw gateway restart
\`\`\`

如果 gateway 子命令不可用，请改用 \`openclaw restart\`。
EOF
}

restart_openclaw() {
  log "正在尝试重启 OpenClaw。"
  if openclaw gateway restart; then
    log "已执行 openclaw gateway restart。"
  elif openclaw restart; then
    log "gateway restart 失败，已执行 openclaw restart。"
  else
    warning "OpenClaw 自动重启失败，配置已保留。请手动运行："
    warning "  openclaw gateway restart"
    warning "  或 openclaw restart"
  fi
}

verify_openclaw() {
  log "正在验证 OpenClaw memory 状态。"
  if ! openclaw memory status --deep; then
    warning "验证命令失败：openclaw memory status --deep"
  fi
  if ! openclaw memory status --index --agent "$MEMORY_AGENT"; then
    warning "验证命令失败：openclaw memory status --index --agent $MEMORY_AGENT"
  fi
}

CONFIG_PATH="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-nomic-embed-text}"
DREAMING_TIMEZONE="${DREAMING_TIMEZONE:-Asia/Shanghai}"
DREAMING_FREQUENCY="${DREAMING_FREQUENCY:-0 3 * * *}"
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
OLLAMA_LLM_LIBRARY="${OLLAMA_LLM_LIBRARY:-cpu}"
MEMORY_AGENT="${MEMORY_AGENT:-default}"
OPENCLAW_HOME="$HOME/.openclaw"
SETUP_NOTES_PATH="$OPENCLAW_HOME/dreaming-ollama-embedding-setup.md"
MEMORY_DIR="$OPENCLAW_HOME/workspace/$MEMORY_AGENT/memory"
MEMORY_FILE="$MEMORY_DIR/MEMORY.md"

require_linux
command_exists openclaw || abort "未找到 openclaw 命令。请先安装 OpenClaw 并确认它已加入 PATH。"

mkdir -p "$(dirname "$CONFIG_PATH")"
mkdir -p "$OPENCLAW_HOME"

if [[ ! -f "$CONFIG_PATH" ]]; then
  log "配置文件不存在，正在创建最小合法 JSON：$CONFIG_PATH"
  printf '{}\n' > "$CONFIG_PATH"
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_PATH="${CONFIG_PATH}.bak-${TIMESTAMP}"
while [[ -e "$BACKUP_PATH" ]]; do
  sleep 1
  TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
  BACKUP_PATH="${CONFIG_PATH}.bak-${TIMESTAMP}"
done
cp -p "$CONFIG_PATH" "$BACKUP_PATH"
log "已备份配置：$BACKUP_PATH"

ensure_dependency jq
ensure_dependency curl

if ! jq -e 'type == "object"' "$CONFIG_PATH" >/dev/null 2>&1; then
  abort "OpenClaw 配置不是合法的 JSON 对象，未进行修改：$CONFIG_PATH。备份位于：$BACKUP_PATH"
fi

if ! command_exists ollama; then
  log "未找到 Ollama，正在使用官方安装脚本安装。"
  curl -fsSL --connect-timeout 10 --max-time 300 https://ollama.com/install.sh | sh || \
    abort "Ollama 官方安装脚本执行失败。请检查网络后重试，或手动安装 Ollama。"
fi

command_exists ollama || abort "Ollama 安装后仍不可用，请检查 PATH。"
ollama --version >/dev/null 2>&1 || abort "ollama --version 执行失败，请检查 Ollama 安装。"

start_ollama

log "正在拉取 embedding 模型：$EMBEDDING_MODEL"
env OLLAMA_HOST="$OLLAMA_BASE_URL" ollama pull "$EMBEDDING_MODEL" || \
  abort "拉取 embedding 模型失败：$EMBEDDING_MODEL。请运行 ollama pull \"$EMBEDDING_MODEL\" 排查。"

initialize_memory_workspace

CONFIG_DIR="$(dirname "$CONFIG_PATH")"
TEMP_CONFIG="$(mktemp "$CONFIG_DIR/.openclaw.json.tmp.XXXXXX")"
ORIGINAL_MODE=""
if ORIGINAL_MODE="$(stat -c '%a' "$CONFIG_PATH" 2>/dev/null)"; then
  :
else
  ORIGINAL_MODE="600"
fi

log "正在使用 jq 合并 Dreaming 与 memorySearch 配置。"
if ! jq \
  --arg embedding_model "$EMBEDDING_MODEL" \
  --arg dreaming_timezone "$DREAMING_TIMEZONE" \
  --arg dreaming_frequency "$DREAMING_FREQUENCY" \
  --arg ollama_base_url "${OLLAMA_BASE_URL%/}" \
  '. * {
    "plugins": {
      "entries": {
        "memory-core": {
          "config": {
            "dreaming": {
              "enabled": true,
              "timezone": $dreaming_timezone,
              "frequency": $dreaming_frequency
            }
          }
        }
      }
    },
    "agents": {
      "defaults": {
        "memorySearch": {
          "enabled": true,
          "provider": "ollama",
          "model": $embedding_model,
          "remote": {
            "baseUrl": $ollama_base_url,
            "nonBatchConcurrency": 1
          }
        }
      }
    }
  }' "$CONFIG_PATH" > "$TEMP_CONFIG"; then
  rm -f "$TEMP_CONFIG"
  abort "jq 合并配置失败。原配置未被修改，备份位于：$BACKUP_PATH"
fi

if ! jq -e 'type == "object"' "$TEMP_CONFIG" >/dev/null 2>&1; then
  rm -f "$TEMP_CONFIG"
  abort "合并结果不是合法 JSON 对象。原配置未被修改，备份位于：$BACKUP_PATH"
fi

chmod "$ORIGINAL_MODE" "$TEMP_CONFIG"
mv "$TEMP_CONFIG" "$CONFIG_PATH"
log "OpenClaw 配置已更新。"

write_setup_notes
log "配置说明已写入：$SETUP_NOTES_PATH"

restart_openclaw
verify_openclaw

OLLAMA_STATUS="not running"
if ollama_is_running; then
  OLLAMA_STATUS="running"
fi

cat <<EOF

OpenClaw Dreaming + Ollama Embedding setup complete.

OpenClaw config path: $CONFIG_PATH

Backup path: $BACKUP_PATH

Ollama status:
$OLLAMA_STATUS

Dreaming:
enabled=true
frequency=$DREAMING_FREQUENCY
timezone=$DREAMING_TIMEZONE
model=OpenClaw current default chat model

Memory embedding:
provider=ollama
model=$EMBEDDING_MODEL
baseUrl=${OLLAMA_BASE_URL%/}
runtime=CPU-only ($OLLAMA_LLM_LIBRARY)

Memory workspace:
$MEMORY_DIR

Next commands:
openclaw memory status --deep
openclaw memory status --index --agent $MEMORY_AGENT
openclaw memory index --force --agent $MEMORY_AGENT
/dreaming status
EOF
