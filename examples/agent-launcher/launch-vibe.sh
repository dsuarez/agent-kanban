#!/usr/bin/env bash
# launch-vibe.sh — agent launcher for agent-kanban + Mistral Vibe.
#
# Invoked by the rule engine when a card lands in a chosen column:
#
#   {
#     "name": "Vibe on approved",
#     "trigger": {"type": "task_moved", "to_status": "approved", "project_id": "myproj"},
#     "action": {
#       "type": "run_command",
#       "cmd": "/abs/path/to/agent-kanban/examples/agent-launcher/launch-vibe.sh",
#       "args": ["{task_id}", "{project_id}"],
#       "max_concurrent": 1,
#       "max_runs": 3
#     }
#   }
#
# The script stays in the foreground while Vibe works, so the kanban
# knows the launch is alive (one run per card, max_concurrent queueing).
#
# What it does, in order:
#   1. Preflight: board reachable, card still in approved/analyst
#   2. Per-card lock (mkdir)
#   3. Runs Vibe with the task prompt via HTTP MCP
#   4. Hard timeout (AGENT_TIMEOUT_SEC)
#   5. Checks the card and blocks it if Vibe left it in an agent column
#
# Exit codes: 0 done; 75 usage limit hit; 1 launcher error

# Set UTF-8 codepage for Windows
chcp 65001 > /dev/null 2>&1

set -uo pipefail

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
if [[ -d "$HOME/.nvm/versions/node" ]]; then
    _node_dir="$(/bin/ls -1d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | tail -1)"
    [[ -n "$_node_dir" ]] && export PATH="$_node_dir:$PATH"
fi
export LANG="${LANG:-en_US.UTF-8}"

TASK_ID="${1:?usage: launch-vibe.sh <task_id> [project_id]}"
PROJECT_ID="${2:-}"
KANBAN_URL="${KANBAN_URL:-http://127.0.0.1:7777}"
ACTOR="${KANBAN_LAUNCHER_ACTOR:-agent:launcher}"
TIMEOUT="${AGENT_TIMEOUT_SEC:-3600}"
MODEL="${VIBE_MODEL:-}"

# Configure Vibe MCP servers
export VIBE_MCP_SERVERS='[{"transport": "http", "name": "agent-kanban", "url": "http://127.0.0.1:7777/mcp"}]'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KANBAN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PY="$KANBAN_ROOT/.venv/bin/python"
[[ -x "$PY" ]] || PY="$(command -v python3)"

RUNS_DIR="${KANBAN_RUNS_DIR:-$HOME/Library/Logs/agent-kanban/runs}"
RUN_DIR="$RUNS_DIR/$TASK_ID"
mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/launcher.log"

log() { echo "[$(date -u +%FT%TZ)] $TASK_ID: $*" | tee -a "$LOG" >&2; }

api_get() { curl -fsS -m 20 "$KANBAN_URL$1"; }
api_post() { curl -fsS -m 20 -X POST "$KANBAN_URL$1" -H 'Content-Type: application/json' -H "X-Kanban-Actor: $ACTOR" -d "$2" >/dev/null; }
json_field() { printf '%s' "$1" | "$PY" -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[1]); print("") if v is None else print(v)' "$2"; }
json_str() { printf '%s' "$1" | "$PY" -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
comment() { api_post "/api/tasks/$TASK_ID/comment" "{\"text\": $(json_str "$1")}" || log "could not comment: $1"; }
move() { local exp=""; [[ -n "${3:-}" ]] && exp=", \"expected_from\": \"$3\""; api_post "/api/tasks/$TASK_ID/move" "{\"to_status\": \"$1\", \"comment\": $(json_str "$2")$exp}" || log "could not move to $1"; }
card_status() { json_field "$(api_get "/api/tasks/$TASK_ID?history_limit=0" 2>/dev/null || echo '{}')" status; }
block() { log "BLOCK: $1"; move blocked "launcher: $1" "$STATUS"; }

TASK_JSON="$(api_get "/api/tasks/$TASK_ID?history_limit=0")" || { log "kanban not reachable at $KANBAN_URL"; exit 1; }
STATUS="$(json_field "$TASK_JSON" status)"
case "$STATUS" in
    approved|analyst) ;;
    *) log "card is in '$STATUS' now, not approved — nothing to do"; exit 0 ;;
esac
TITLE="$(json_field "$TASK_JSON" title)"
DESC="$(json_field "$TASK_JSON" description)"
ACCEPTANCE="$(json_field "$TASK_JSON" acceptance)"
SIZE="$(json_field "$TASK_JSON" size)"
[[ -z "$PROJECT_ID" ]] && PROJECT_ID="$(json_field "$TASK_JSON" project_id)"
PROJ_PATH="$(api_get /api/projects | "$PY" -c "import json, sys; ps = json.load(sys.stdin)['projects']; m = [p for p in ps if p['id'] == sys.argv[1]]; print((m[0].get('path') or '') if m else '')" "$PROJECT_ID")"
if [[ -z "$PROJ_PATH" || ! -d "$PROJ_PATH" ]]; then
    block "project '$PROJECT_ID' has no directory"
    exit 0
fi

_resolve_vibe() {
    [[ -n "${VIBE_BIN:-}" ]] && { echo "$VIBE_BIN"; return; }
    for candidate in "$HOME/.local/bin/vibe" "$HOME/.cargo/bin/vibe" "/usr/local/bin/vibe"; do
        [[ -x "$candidate" ]] && { echo "$candidate"; return; }
    done
    echo ""
}
VIBE="$(_resolve_vibe)"
if [[ -z "$VIBE" ]]; then
    block "vibe CLI not found (PATH=$PATH). Set VIBE_BIN in the rule's env."
    exit 0
fi

LOCK="$RUN_DIR/lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    old_pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        log "already running (pid $old_pid)"
        exit 0
    fi
    rm -rf "$LOCK" && mkdir "$LOCK"
fi
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT

PROMPT="$RUN_DIR/prompt.md"
cat > "$PROMPT" <<EOF
You are connected to agent-kanban via MCP. Use kanban_* tools to interact with the board.

Workflow:
1. kanban_pull(task_id="$TASK_ID") — claim the task (approved -> analyst)
2. Plan, write plan as comment via kanban_comment
3. kanban_move(task_id="$TASK_ID", to_status="in_progress") before editing files
4. Implement. Use kanban_comment for progress, kanban_link for files/PRs
5. Verify. Claims must be backed by command output.
6. kanban_move(task_id="$TASK_ID", to_status="testing", comment="what was done")
7. Stop. Do NOT move to uat/done — human decides.

If blocked: kanban_move to "blocked" with kanban_comment explaining why.

=== Task ===
ID: $TASK_ID
Title: $TITLE
Description: $DESC
Acceptance: $ACCEPTANCE
=== End ===
EOF

RESULT="$RUN_DIR/result.json"
AGENT_LOG="$RUN_DIR/agent.log"
: > "$RESULT"
log "starting vibe in $PROJ_PATH (timeout ${TIMEOUT}s); run dir $RUN_DIR"
cd "$PROJ_PATH" || { block "cannot cd to $PROJ_PATH"; exit 0; }

CMD=("$VIBE" -p "$(cat "$PROMPT")" --auto-approve)
[[ -n "$MODEL" ]] && CMD+=(--model "$MODEL")

"${CMD[@]}" > "$RESULT" 2> "$AGENT_LOG" &
AGENT_PID=$!
echo "$AGENT_PID" > "$RUN_DIR/agent.pid"

(
    trap 'kill "$sp" 2>/dev/null; exit 0' TERM
    sleep "$TIMEOUT" & sp=$!; wait "$sp"
    if kill -0 "$AGENT_PID" 2>/dev/null; then
        echo "timeout" > "$RUN_DIR/timed_out"
        kill -TERM "$AGENT_PID" 2>/dev/null
        sleep 2
        kill -KILL "$AGENT_PID" 2>/dev/null
    fi
) > /dev/null 2>&1 &
GUARD_PID=$!
wait "$AGENT_PID"; RC=$?
kill "$GUARD_PID" 2>/dev/null
wait "$GUARD_PID" 2>/dev/null
rm -f "$RUN_DIR/agent.pid"

if kill -0 "-$AGENT_PID" 2>/dev/null; then
    kill -TERM "-$AGENT_PID" 2>/dev/null
    sleep 1
    kill -KILL "-$AGENT_PID" 2>/dev/null
fi

NOW="$(card_status)"
block_if_working() {
    case "$1" in
        approved|analyst|in_progress)
            log "BLOCK: $2"; move blocked "launcher: $2" "$1" ;;
        *) comment "launcher: $2 (card in '$1')" ;;
    esac
}

if [[ -f "$RUN_DIR/timed_out" ]]; then
    rm -f "$RUN_DIR/timed_out"
    block_if_working "$NOW" "agent timed out after ${TIMEOUT}s"
    exit 0
fi

case "$NOW" in
    approved|analyst|in_progress)
        block_if_working "$NOW" "agent exited (rc=$RC) but left card in '$NOW'. Log: $RUN_DIR"
        exit 0 ;;
esac

comment "launcher: agent finished in '$NOW'"
exit 0
