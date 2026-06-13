#!/usr/bin/env bash
set -euo pipefail

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARNING] %s\n' "$*" >&2; }
abort() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

expand_home_path() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

resolve_agent_and_workspace() {
  local configured_agent configured_workspace

  if [[ -z "$MEMORY_AGENT" && -f "$CONFIG_PATH" ]]; then
    configured_agent="$(jq -r '([.agents.list[]? | select(.default == true) | .id][0] // .agents.list[0].id // empty)' "$CONFIG_PATH")"
    MEMORY_AGENT="$configured_agent"
  fi
  MEMORY_AGENT="${MEMORY_AGENT:-main}"

  if [[ -z "$OPENCLAW_WORKSPACE" && -f "$CONFIG_PATH" ]]; then
    configured_workspace="$(jq -r --arg agent "$MEMORY_AGENT" '([.agents.list[]? | select(.id == $agent) | .workspace][0] // .agents.defaults.workspace // empty)' "$CONFIG_PATH")"
    OPENCLAW_WORKSPACE="$configured_workspace"
  fi
  if [[ -z "$OPENCLAW_WORKSPACE" ]]; then
    if [[ "$MEMORY_AGENT" == "main" ]]; then
      OPENCLAW_WORKSPACE="$OPENCLAW_HOME/workspace"
    else
      OPENCLAW_WORKSPACE="$OPENCLAW_HOME/workspace-$MEMORY_AGENT"
    fi
  fi
  OPENCLAW_WORKSPACE="$(expand_home_path "$OPENCLAW_WORKSPACE")"

  log "目标 Agent：$MEMORY_AGENT"
  log "目标 workspace：$OPENCLAW_WORKSPACE"
}

run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    abort "需要管理员权限执行：$*。请安装 sudo 或以 root 用户运行。"
  fi
}

try_run_privileged() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    return 1
  fi
}

run_or_print() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY-RUN]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

install_package() {
  local package="$1"
  log "正在安装缺失依赖：$package"
  if command_exists apt-get; then
    run_privileged apt-get update
    run_privileged apt-get install -y "$package"
  elif command_exists dnf; then
    run_privileged dnf install -y "$package"
  elif command_exists yum; then
    run_privileged yum install -y "$package"
  else
    abort "未找到 apt-get、dnf 或 yum，无法安装 $package。"
  fi
  [[ "$DRY_RUN" == "1" ]] || command_exists "$package" || abort "$package 安装后仍不可用。"
}

ensure_dependency() {
  command_exists "$1" || install_package "${2:-$1}"
}

ollama_is_running() {
  curl -fsS --connect-timeout 3 --max-time 5 "${OLLAMA_BASE_URL%/}/api/tags" >/dev/null 2>&1
}

configure_ollama_cpu_tuning() {
  local override_dir="/etc/systemd/system/ollama.service.d"
  local override_path="$override_dir/openclaw-cpu.conf"
  local temp_override

  temp_override="$(mktemp)"
  cat > "$temp_override" <<EOF
[Service]
Environment="OLLAMA_NUM_PARALLEL=$OLLAMA_NUM_PARALLEL"
Environment="OLLAMA_MAX_LOADED_MODELS=$OLLAMA_MAX_LOADED_MODELS"
Environment="OLLAMA_KEEP_ALIVE=$OLLAMA_KEEP_ALIVE"
Environment="OLLAMA_LOAD_TIMEOUT=$OLLAMA_LOAD_TIMEOUT"
Environment="OLLAMA_MAX_QUEUE=$OLLAMA_MAX_QUEUE"
EOF
  if ! try_run_privileged mkdir -p "$override_dir" || \
     ! try_run_privileged install -m 0644 "$temp_override" "$override_path" || \
     ! try_run_privileged systemctl daemon-reload; then
    rm -f "$temp_override"
    return 1
  fi
  rm -f "$temp_override"
  log "已写入 Ollama CPU 调优：$override_path"
}

install_ollama() {
  command_exists ollama && return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY-RUN] 将安装 Ollama。"
    return 0
  fi
  log "正在使用 Ollama 官方 Linux 安装脚本。"
  curl -fsSL --connect-timeout 10 --max-time 300 https://ollama.com/install.sh | sh || \
    abort "Ollama 官方安装失败，请检查网络后重试。"
  command_exists ollama || abort "Ollama 安装后仍不可用，请检查 PATH。"
  ollama --version >/dev/null 2>&1 || abort "ollama --version 执行失败。"
}

start_ollama() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY-RUN] 将检查并启动 Ollama：$OLLAMA_BASE_URL"
    return 0
  fi
  if command_exists systemctl && systemctl list-unit-files ollama.service >/dev/null 2>&1; then
    if ! configure_ollama_cpu_tuning || ! try_run_privileged systemctl enable --now ollama; then
      warn "systemd 启动失败，将尝试 nohup ollama serve。"
      nohup env OLLAMA_HOST="$OLLAMA_BASE_URL" \
        OLLAMA_NUM_PARALLEL="$OLLAMA_NUM_PARALLEL" \
        OLLAMA_MAX_LOADED_MODELS="$OLLAMA_MAX_LOADED_MODELS" \
        OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE" \
        OLLAMA_LOAD_TIMEOUT="$OLLAMA_LOAD_TIMEOUT" \
        OLLAMA_MAX_QUEUE="$OLLAMA_MAX_QUEUE" \
        ollama serve > "$OPENCLAW_HOME/ollama.log" 2>&1 &
    fi
  elif ollama_is_running; then
    log "Ollama 服务已在运行；非 systemd 进程将保留当前启动参数。"
    return 0
  else
    nohup env OLLAMA_HOST="$OLLAMA_BASE_URL" \
      OLLAMA_NUM_PARALLEL="$OLLAMA_NUM_PARALLEL" \
      OLLAMA_MAX_LOADED_MODELS="$OLLAMA_MAX_LOADED_MODELS" \
      OLLAMA_KEEP_ALIVE="$OLLAMA_KEEP_ALIVE" \
      OLLAMA_LOAD_TIMEOUT="$OLLAMA_LOAD_TIMEOUT" \
      OLLAMA_MAX_QUEUE="$OLLAMA_MAX_QUEUE" \
      ollama serve > "$OPENCLAW_HOME/ollama.log" 2>&1 &
  fi
  local waited=0
  while (( waited < 30 )); do
    ollama_is_running && { log "Ollama 服务已启动。"; return 0; }
    sleep 2
    waited=$((waited + 2))
  done
  warn "排查命令：ollama serve"
  warn "排查命令：curl ${OLLAMA_BASE_URL%/}/api/tags"
  warn "排查命令：journalctl -u ollama -n 100 --no-pager"
  warn "排查命令：systemctl status ollama --no-pager"
  abort "Ollama 在 30 秒内未就绪。"
}

initialize_official_artifacts() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY-RUN] 将确保 $MEMORY_DIR、$DREAM_STATE_DIR、$MEMORY_PATH 和 Dream Diary 存在。"
    DREAM_DIARY_PATH="$OPENCLAW_WORKSPACE/DREAMS.md"
    [[ -f "$OPENCLAW_WORKSPACE/dreams.md" ]] && DREAM_DIARY_PATH="$OPENCLAW_WORKSPACE/dreams.md"
    [[ -f "$OPENCLAW_WORKSPACE/DREAMS.md" && ! -f "$OPENCLAW_WORKSPACE/dreams.md" ]] && DREAM_DIARY_PATH="$OPENCLAW_WORKSPACE/DREAMS.md"
    return 0
  fi
  mkdir -p "$MEMORY_DIR" "$DREAM_STATE_DIR"
  if [[ ! -e "$MEMORY_PATH" ]]; then
    printf '# MEMORY\n' > "$MEMORY_PATH"
    log "已创建：$MEMORY_PATH"
  fi
  if [[ -f "$OPENCLAW_WORKSPACE/dreams.md" ]]; then
    DREAM_DIARY_PATH="$OPENCLAW_WORKSPACE/dreams.md"
  elif [[ -f "$OPENCLAW_WORKSPACE/DREAMS.md" ]]; then
    DREAM_DIARY_PATH="$OPENCLAW_WORKSPACE/DREAMS.md"
  else
    DREAM_DIARY_PATH="$OPENCLAW_WORKSPACE/DREAMS.md"
    cat > "$DREAM_DIARY_PATH" <<'EOF'
# DREAMS

This is an OpenClaw Dream Diary placeholder. Real Dreaming entries are appended by memory-core Dreaming sweeps or grounded rem-backfill.
EOF
    log "已创建官方 Dream Diary 占位文件：$DREAM_DIARY_PATH"
  fi
}

backup_and_merge_config() {
  if [[ "$DRY_RUN" == "1" ]]; then
    BACKUP_PATH="${CONFIG_PATH}.bak-DRY-RUN"
    log "[DRY-RUN] 将使用 jq 备份并合并配置。"
    return 0
  fi
  TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
  BACKUP_PATH="${CONFIG_PATH}.bak-${TIMESTAMP}"
  while [[ -e "$BACKUP_PATH" ]]; do sleep 1; TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"; BACKUP_PATH="${CONFIG_PATH}.bak-${TIMESTAMP}"; done
  cp -p "$CONFIG_PATH" "$BACKUP_PATH"
  local config_dir temp_config original_mode
  config_dir="$(dirname "$CONFIG_PATH")"
  temp_config="$(mktemp "$config_dir/.openclaw.json.tmp.XXXXXX")"
  original_mode="600"
  original_mode="$(stat -c '%a' "$CONFIG_PATH" 2>/dev/null || printf '600')"
  if ! jq --arg model "$EMBEDDING_MODEL" --arg timezone "$DREAMING_TIMEZONE" \
    --arg frequency "$DREAMING_FREQUENCY" --arg base_url "${OLLAMA_BASE_URL%/}" \
    '. * {plugins:{entries:{"memory-core":{config:{dreaming:{enabled:true,timezone:$timezone,frequency:$frequency}}}}},agents:{defaults:{memorySearch:{enabled:true,provider:"ollama",model:$model,remote:{baseUrl:$base_url,apiKey:"ollama-local",nonBatchConcurrency:1}}}}}' \
    "$CONFIG_PATH" > "$temp_config"; then
    rm -f "$temp_config"
    abort "jq 合并失败，原配置未修改。备份：$BACKUP_PATH"
  fi
  jq -e 'type == "object"' "$temp_config" >/dev/null || { rm -f "$temp_config"; abort "合并结果不是合法 JSON。"; }
  chmod "$original_mode" "$temp_config"
  mv "$temp_config" "$CONFIG_PATH"
  log "配置已更新，备份：$BACKUP_PATH"
}

restart_openclaw() {
  [[ "$DRY_RUN" == "1" ]] && { log "[DRY-RUN] 将重启 OpenClaw。"; return 0; }
  openclaw gateway restart && return 0
  openclaw restart && return 0
  warn "自动重启失败，请手动运行 openclaw gateway restart 或 openclaw restart。"
}

run_status_checks() {
  [[ "$DRY_RUN" == "1" ]] && { log "[DRY-RUN] 将运行 memory status、rem-harness 和 promote preview。"; return 0; }
  openclaw memory status --deep || warn "openclaw memory status --deep 失败。"
  openclaw memory status --index --agent "$MEMORY_AGENT" || \
    openclaw memory status --deep --agent "$MEMORY_AGENT" || warn "agent memory status 检查失败。"
  openclaw memory rem-harness --agent "$MEMORY_AGENT" --json || \
    openclaw memory rem-harness --json || warn "rem-harness preview 失败或当前版本不支持。"
}

run_promote() {
  PROMOTE_REPORT_PATH="$MEMORY_DIR/promote-preview-${TIMESTAMP}.json"
  PROMOTE_PREVIEW_RAN=false
  PROMOTE_APPLY_RAN=false
  MEMORY_BACKUP_PATH=none
  [[ "$DRY_RUN" == "1" ]] && { log "[DRY-RUN] promote preview 将写入 $PROMOTE_REPORT_PATH"; return 0; }
  local args=(memory promote --agent "$MEMORY_AGENT" --limit "$PROMOTE_LIMIT" --min-score "$PROMOTE_MIN_SCORE" --min-recall-count "$PROMOTE_MIN_RECALL_COUNT" --min-unique-queries "$PROMOTE_MIN_UNIQUE_QUERIES")
  [[ "$PROMOTE_INCLUDE_PROMOTED" == "1" ]] && args+=(--include-promoted)
  [[ "$PROMOTE_JSON" == "1" ]] && args+=(--json)
  if openclaw "${args[@]}" > "$PROMOTE_REPORT_PATH"; then
    PROMOTE_PREVIEW_RAN=true
  elif openclaw memory promote --agent "$MEMORY_AGENT" --json > "$PROMOTE_REPORT_PATH"; then
    PROMOTE_PREVIEW_RAN=true
    warn "完整 promote 参数不受支持，已使用基础 preview。"
  elif openclaw memory promote --json > "$PROMOTE_REPORT_PATH"; then
    PROMOTE_PREVIEW_RAN=true
    warn "--agent 不受支持，已使用默认 agent 基础 preview。"
  else
    rm -f "$PROMOTE_REPORT_PATH"
    PROMOTE_REPORT_PATH=none
    warn "promote preview 失败；未执行 apply。"
  fi
  if [[ "$APPLY_PROMOTE" == "1" ]]; then
    MEMORY_BACKUP_PATH="${MEMORY_PATH}.bak-${TIMESTAMP}"
    cp -p "$MEMORY_PATH" "$MEMORY_BACKUP_PATH"
    local apply_args=("${args[@]}" --apply)
    if openclaw "${apply_args[@]}"; then
      PROMOTE_APPLY_RAN=true
    elif openclaw memory promote --agent "$MEMORY_AGENT" --apply; then
      PROMOTE_APPLY_RAN=true
      warn "完整 apply 参数不受支持，已使用基础显式 apply。"
    else
      warn "promote apply 失败，MEMORY.md 备份保留：$MEMORY_BACKUP_PATH"
    fi
  else
    log "未写入 MEMORY.md。确认 preview 后可运行：APPLY_PROMOTE=1 ./$SCRIPT_NAME"
  fi
}

run_optional_writes() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  if [[ "$RUN_BACKFILL" == "1" ]]; then
    local args=(memory rem-backfill --path "$MEMORY_DIR")
    [[ "$STAGE_SHORT_TERM" == "1" ]] && args+=(--stage-short-term)
    openclaw "${args[@]}" || warn "rem-backfill 失败。"
  elif [[ "$STAGE_SHORT_TERM" == "1" ]]; then
    warn "STAGE_SHORT_TERM=1 仅在 RUN_BACKFILL=1 时生效。"
  fi
  if [[ "$FORCE_REINDEX" == "1" ]]; then
    openclaw memory index --force --agent "$MEMORY_AGENT" || warn "强制重建索引失败。"
  fi
}

write_setup_notes() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  cat > "$SETUP_NOTES_PATH" <<EOF
# OpenClaw Official Dreaming + Ollama Embedding Setup

- Dreaming frequency: \`$DREAMING_FREQUENCY\`
- Dreaming timezone: \`$DREAMING_TIMEZONE\`
- Dreaming model: OpenClaw current default chat model; no \`dreaming.model\` override
- memorySearch provider/model: \`ollama\` / \`$EMBEDDING_MODEL\`
- Ollama endpoint: \`${OLLAMA_BASE_URL%/}\`
- Ollama CPU tuning: parallel=\`$OLLAMA_NUM_PARALLEL\`, loadedModels=\`$OLLAMA_MAX_LOADED_MODELS\`, keepAlive=\`$OLLAMA_KEEP_ALIVE\`, loadTimeout=\`$OLLAMA_LOAD_TIMEOUT\`, maxQueue=\`$OLLAMA_MAX_QUEUE\`
- OpenClaw config: \`$CONFIG_PATH\`
- OpenClaw workspace: \`$OPENCLAW_WORKSPACE\`
- MEMORY.md: \`$MEMORY_PATH\`
- Dream Diary: \`$DREAM_DIARY_PATH\`
- Dream machine state: \`$DREAM_STATE_DIR\`
- Optional phase reports: \`$PHASE_REPORTS_PATH\`
- Config backup: \`$BACKUP_PATH\`

## Validation

\`\`\`bash
openclaw memory status --deep
openclaw memory status --index --agent "$MEMORY_AGENT"
openclaw memory rem-harness --agent "$MEMORY_AGENT" --json
openclaw memory index --force --agent "$MEMORY_AGENT"
\`\`\`

## Grounded backfill rollback

\`\`\`bash
openclaw memory rem-backfill --rollback
openclaw memory rem-backfill --rollback-short-term
\`\`\`

## Config rollback

\`\`\`bash
cp "$BACKUP_PATH" "$CONFIG_PATH"
openclaw gateway restart
\`\`\`
EOF
}

SCRIPT_NAME="$(basename "$0")"
OS_NAME="$(uname -s)"
[[ "$OS_NAME" == "Linux" ]] || abort "This script is intended for Linux ECS only."
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
[[ -r "$OS_RELEASE_FILE" ]] || abort "无法读取 /etc/os-release，无法确认 ECS Linux 发行版。"
OS_PRETTY_NAME="$(. "$OS_RELEASE_FILE" && printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}")"
log "检测到 Linux ECS：$OS_PRETTY_NAME"
CONFIG_PATH="${OPENCLAW_CONFIG:-$HOME/.openclaw/openclaw.json}"
OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-}"
EMBEDDING_MODEL="${EMBEDDING_MODEL:-nomic-embed-text}"
DREAMING_TIMEZONE="${DREAMING_TIMEZONE:-Asia/Shanghai}"
DREAMING_FREQUENCY="${DREAMING_FREQUENCY:-0 3 * * *}"
OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-1}"
OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-1}"
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:-10m}"
OLLAMA_LOAD_TIMEOUT="${OLLAMA_LOAD_TIMEOUT:-10m}"
OLLAMA_MAX_QUEUE="${OLLAMA_MAX_QUEUE:-64}"
MEMORY_AGENT="${MEMORY_AGENT:-}"
RUN_BACKFILL="${RUN_BACKFILL:-0}"
STAGE_SHORT_TERM="${STAGE_SHORT_TERM:-0}"
FORCE_REINDEX="${FORCE_REINDEX:-0}"
APPLY_PROMOTE="${APPLY_PROMOTE:-0}"
PROMOTE_LIMIT="${PROMOTE_LIMIT:-10}"
PROMOTE_MIN_SCORE="${PROMOTE_MIN_SCORE:-0.8}"
PROMOTE_MIN_RECALL_COUNT="${PROMOTE_MIN_RECALL_COUNT:-3}"
PROMOTE_MIN_UNIQUE_QUERIES="${PROMOTE_MIN_UNIQUE_QUERIES:-3}"
PROMOTE_INCLUDE_PROMOTED="${PROMOTE_INCLUDE_PROMOTED:-0}"
PROMOTE_JSON="${PROMOTE_JSON:-1}"
DRY_RUN="${DRY_RUN:-0}"
OPENCLAW_HOME="$HOME/.openclaw"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_PATH=none
PROMOTE_REPORT_PATH=none
MEMORY_BACKUP_PATH=none
PROMOTE_PREVIEW_RAN=false
PROMOTE_APPLY_RAN=false

[[ "${OLLAMA_BASE_URL%/}" != */v1 ]] || abort "OLLAMA_BASE_URL 必须是原生 Ollama URL，不能带 /v1。"
command_exists openclaw || abort "未找到 openclaw；脚本不会自动安装 OpenClaw。"

if [[ "$DRY_RUN" != "1" ]]; then
  mkdir -p "$(dirname "$CONFIG_PATH")" "$OPENCLAW_HOME"
  [[ -f "$CONFIG_PATH" ]] || printf '{}\n' > "$CONFIG_PATH"
  ensure_dependency jq
  ensure_dependency curl
  jq -e 'type == "object"' "$CONFIG_PATH" >/dev/null || abort "配置文件不是合法 JSON 对象：$CONFIG_PATH"
else
  log "DRY_RUN=1：不会安装、写文件、改配置、重启或执行写入命令。"
  command_exists jq || abort "DRY_RUN 需要 jq 来只读解析 Agent workspace。"
  [[ ! -f "$CONFIG_PATH" ]] || jq -e 'type == "object"' "$CONFIG_PATH" >/dev/null || abort "配置文件不是合法 JSON 对象：$CONFIG_PATH"
fi

resolve_agent_and_workspace
MEMORY_DIR="$OPENCLAW_WORKSPACE/memory"
DREAM_STATE_DIR="$MEMORY_DIR/.dreams"
MEMORY_PATH="$OPENCLAW_WORKSPACE/MEMORY.md"
PHASE_REPORTS_PATH="$MEMORY_DIR/dreaming/<phase>/YYYY-MM-DD.md"
SETUP_NOTES_PATH="$OPENCLAW_WORKSPACE/dreaming-official-ollama-embedding-setup.md"
DREAM_DIARY_PATH="$OPENCLAW_WORKSPACE/DREAMS.md"
[[ "$DRY_RUN" == "1" ]] || mkdir -p "$OPENCLAW_WORKSPACE"

install_ollama
start_ollama
if [[ "$DRY_RUN" == "1" ]]; then
  log "[DRY-RUN] 将执行 ollama pull $EMBEDDING_MODEL"
else
  env OLLAMA_HOST="$OLLAMA_BASE_URL" ollama pull "$EMBEDDING_MODEL" || abort "拉取 embedding 模型失败：$EMBEDDING_MODEL"
fi

initialize_official_artifacts
backup_and_merge_config
restart_openclaw
run_status_checks
run_promote
run_optional_writes
write_setup_notes

OLLAMA_STATUS=not-running
[[ "$DRY_RUN" == "1" ]] && OLLAMA_STATUS=dry-run
[[ "$DRY_RUN" != "1" ]] && ollama_is_running && OLLAMA_STATUS=running

cat <<EOF

OpenClaw official Dreaming + Ollama embedding setup complete.

OpenClaw config path: $CONFIG_PATH
OpenClaw workspace: $OPENCLAW_WORKSPACE
Backup path: $BACKUP_PATH

Ollama status:
$OLLAMA_STATUS

Dreaming config:
enabled=true
frequency=$DREAMING_FREQUENCY
timezone=$DREAMING_TIMEZONE
model=OpenClaw current default chat model

Official Dreaming artifacts:
MEMORY.md=$MEMORY_PATH
Dream Diary=$DREAM_DIARY_PATH
Dream machine state=$DREAM_STATE_DIR
Optional phase reports=$PHASE_REPORTS_PATH

Memory embedding:
provider=ollama
model=$EMBEDDING_MODEL
baseUrl=${OLLAMA_BASE_URL%/}

Ollama CPU tuning:
numParallel=$OLLAMA_NUM_PARALLEL
maxLoadedModels=$OLLAMA_MAX_LOADED_MODELS
keepAlive=$OLLAMA_KEEP_ALIVE
loadTimeout=$OLLAMA_LOAD_TIMEOUT
maxQueue=$OLLAMA_MAX_QUEUE

Promote:
preview_ran=$PROMOTE_PREVIEW_RAN
apply_ran=$PROMOTE_APPLY_RAN
limit=$PROMOTE_LIMIT
minScore=$PROMOTE_MIN_SCORE
minRecallCount=$PROMOTE_MIN_RECALL_COUNT
minUniqueQueries=$PROMOTE_MIN_UNIQUE_QUERIES
report=$PROMOTE_REPORT_PATH
memory_backup=$MEMORY_BACKUP_PATH

Next commands:
openclaw memory status --deep
openclaw memory status --index --agent $MEMORY_AGENT
openclaw memory rem-harness --agent $MEMORY_AGENT --json
openclaw memory index --force --agent $MEMORY_AGENT
/dreaming status

If Dreaming is blocked, check that the default agent heartbeat is enabled and its target is not none.
Dreaming sweeps run automatically on the configured schedule. Only Deep promotes qualified evidence into MEMORY.md.

Optional immediate grounded diary generation:
RUN_BACKFILL=1 ./$SCRIPT_NAME

Optional grounded diary + short-term staging:
RUN_BACKFILL=1 STAGE_SHORT_TERM=1 ./$SCRIPT_NAME

Apply promote only after reviewing the preview:
APPLY_PROMOTE=1 ./$SCRIPT_NAME

Optional force reindex:
FORCE_REINDEX=1 ./$SCRIPT_NAME
EOF
