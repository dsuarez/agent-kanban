#!/usr/bin/env bash
# launch-vibe-win.sh — agent launcher for agent-kanban + Mistral Vibe (Windows version)
# Adaptado para funcionar en Git Bash en Windows

# Set UTF-8 codepage for Windows
chcp 65001 > /dev/null 2>&1

set -uo pipefail

# Export UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Configuracion
TASK_ID="${1:?usage: launch-vibe-win.sh <task_id> [project_id]}"
PROJECT_ID="${2:-}"
KANBAN_URL="${KANBAN_URL:-http://localhost:7777}"
ACTOR="${KANBAN_LAUNCHER_ACTOR:-agent:launcher}"
TIMEOUT="${AGENT_TIMEOUT_SEC:-1800}"
MODEL="${VIBE_MODEL:-mistral-large}"

# Rutas de Windows
KANBAN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Python en Windows
PY="$KANBAN_ROOT/.venv/Scripts/python.exe"

# Configurar VIBE_MCP_SERVERS
export VIBE_MCP_SERVERS='[{"transport": "http", "name": "agent-kanban", "url": "http://localhost:7777/mcp"}]'

# Directorios
RUNS_DIR="${KANBAN_RUNS_DIR:-$KANBAN_ROOT/kanban_data/logs/runs}"
RUN_DIR="$RUNS_DIR/$TASK_ID"
mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/launcher.log"

# Funciones
log() { echo "[$(date -u +%FT%TZ)] $TASK_ID: $*" | tee -a "$LOG" >&2; }

api_get() {
    curl -fsS -m 20 "$KANBAN_URL$1" 2>/dev/null
}

api_post() {
    curl -fsS -m 20 -X POST "$KANBAN_URL$1" \
        -H 'Content-Type: application/json' \
        -H "X-Kanban-Actor: $ACTOR" \
        -d "$2" >/dev/null 2>&1
}

# Obtener JSON y extraer campo
json_field() {
    local json="$1"
    local field="$2"
    echo "$json" | "$PY" -c "import json,sys; d=json.load(sys.stdin); print(d.get('${field}', ''))"
}

comment() {
    local text="$1"
    api_post "/api/tasks/$TASK_ID/comment" "{\"text\": \"$text\"}" || log "could not comment: $1"
}

move_to() {
    local to_status="$1"
    local comment="$2"
    local expected_from="$3"
    local exp=""
    if [ -n "$expected_from" ]; then
        exp=", \"expected_from\": \"$expected_from\""
    fi
    api_post "/api/tasks/$TASK_ID/move" "{\"to_status\": \"$to_status\", \"comment\": \"$comment\"$exp}" || log "could not move to $to_status"
}

block() {
    log "BLOCK: $1"
    move_to blocked "launcher: $1" "$STATUS"
}

# Verificar que el kanban es accesible
TASK_JSON="$(api_get "/api/tasks/$TASK_ID?history_limit=0")" || { log "kanban not reachable at $KANBAN_URL"; exit 1; }

# Obtener estado
STATUS="$(echo "$TASK_JSON" | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('status',''))")"

# Solo procesar si esta en approved o analyst
if [ "$STATUS" != "approved" ] && [ "$STATUS" != "analyst" ]; then
    log "card is in '$STATUS' now, not approved — nothing to do"
    exit 0
fi

# Obtener informacion de la tarjeta
TITLE="$(echo "$TASK_JSON" | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('title',''))")"
DESC="$(echo "$TASK_JSON" | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('description',''))")"
ACCEPTANCE="$(echo "$TASK_JSON" | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('acceptance',''))")"
SIZE="$(echo "$TASK_JSON" | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('size',''))")"

if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID="$(echo "$TASK_JSON" | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('project_id','default'))")"
fi

# Obtener ruta del proyecto
PROJ_PATH="$(curl -fsS -m 20 "$KANBAN_URL/api/projects" | "$PY" -c "import json, sys; ps = json.load(sys.stdin)['projects']; m = [p for p in ps if p['id'] == sys.argv[1]]; print(m[0].get('path','') if m else '')" "$PROJECT_ID")"

if [ -z "$PROJ_PATH" ] || [ ! -d "$PROJ_PATH" ]; then
    block "project '$PROJECT_ID' has no directory"
    exit 0
fi

# Resolver Vibe CLI
VIBE_BIN="${VIBE_BIN:-}"
if [ -z "$VIBE_BIN" ]; then
    # Buscar en paths comunes
    for candidate in "$HOME/.local/bin/vibe" "$HOME/.cargo/bin/vibe" "$LOCALAPPDATA/Programs/Microsoft VS Code/bin/vibe" "$APPDATA/../Local/Microsoft/WindowsApps/vibe.exe" "$LOCALAPPDATA/Programs/vibe/bin/vibe.exe"; do
        if [ -x "$candidate" ] || [ -f "$candidate" ]; then
            VIBE_BIN="$candidate"
            break
        fi
    done
fi

if [ -z "$VIBE_BIN" ] || [ ! -f "$VIBE_BIN" ]; then
    block "vibe CLI not found. Set VIBE_BIN in the rule's env."
    exit 0
fi

# Crear lock
LOCK="$RUN_DIR/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    old_pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        log "already running (pid $old_pid)"
        exit 0
    fi
    rm -rf "$LOCK" && mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

# Crear prompt
PROMPT="$RUN_DIR/prompt.md"
printf '%s\n' \
    "You are connected to agent-kanban via MCP. Use kanban_* tools to interact with the board." \
    "" \
    "Workflow:" \
    "1. kanban_pull(task_id=\"$TASK_ID\") - claim the task (approved -> analyst)" \
    "2. Plan, write plan as comment via kanban_comment" \
    "3. kanban_move(task_id=\"$TASK_ID\", to_status=\"in_progress\") before editing files" \
    "4. Implement. Use kanban_comment for progress, kanban_link for files/PRs" \
    "5. Verify. Claims must be backed by command output." \
    "6. kanban_move(task_id=\"$TASK_ID\", to_status=\"testing\", comment=\"what was done\")" \
    "7. Stop. Do NOT move to uat/done - human decides." \
    "" \
    "If blocked: kanban_move to \"blocked\" with kanban_comment explaining why." \
    "" \
    "=== Task ===" \
    "ID: $TASK_ID" \
    "Title: $TITLE" \
    "Description: $DESC" \
    "Acceptance: $ACCEPTANCE" \
    "Size: $SIZE" \
    "=== End ===" > "$PROMPT"

# Ejecutar Vibe
log "starting vibe in $PROJ_PATH (timeout ${TIMEOUT}s); run dir $RUN_DIR"
cd "$PROJ_PATH" || { block "cannot cd to $PROJ_PATH"; exit 0; }

# Configurar timeout
timeout_command=""
if command -v timeout >/dev/null 2>&1; then
    # Linux timeout
    timeout_command="timeout $TIMEOUT"
else
    # Windows: no timeout available in bash, run without timeout
    log "WARNING: timeout command not available, running without timeout"
    timeout_command=""
fi

# Ejecutar Vibe
PROMPT_CONTENT=$(cat "$PROMPT")
if [ -n "$timeout_command" ]; then
    VIBE_ACTIVE_MODEL="$MODEL" $timeout_command "$VIBE_BIN" -p "$PROMPT_CONTENT" --auto-approve > "$RUN_DIR/result.json" 2> "$RUN_DIR/agent.log"
    RC=$?
else
    VIBE_ACTIVE_MODEL="$MODEL" "$VIBE_BIN" -p "$PROMPT_CONTENT" --auto-approve > "$RUN_DIR/result.json" 2> "$RUN_DIR/agent.log" &
    AGENT_PID=$!
    # Esperar con un loop
    SECONDS=0
    while [ $SECONDS -lt $TIMEOUT ]; do
        if ! kill -0 $AGENT_PID 2>/dev/null; then
            break
        fi
        sleep 1
        SECONDS=$((SECONDS + 1))
    done
    
    if kill -0 $AGENT_PID 2>/dev/null; then
        log "BLOCK: agent timed out after ${TIMEOUT}s"
        kill -TERM $AGENT_PID 2>/dev/null
        sleep 2
        kill -KILL $AGENT_PID 2>/dev/null
        RC=1
    else
        wait $AGENT_PID
        RC=$?
    fi
fi

# Verificar estado final
NOW="$(api_get "/api/tasks/$TASK_ID?history_limit=0" | "$PY" -c "import json,sys; print(json.load(sys.stdin).get('status',''))")"

case "$NOW" in
    approved|analyst|in_progress)
        log "BLOCK: agent exited (rc=$RC) but left card in '$NOW'. Log: $RUN_DIR"
        comment "launcher: agent exited (rc=$RC) but left card in '$NOW'. Log: $RUN_DIR"
        ;;
    *)
        comment "launcher: agent finished in '$NOW'"
        ;;
esac

exit 0
