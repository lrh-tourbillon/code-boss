#!/usr/bin/env bash
# run-phase.sh - Silent watchdog. Messages CW on completion/error (async) or returns output (sync).
#
# macOS equivalent of run-phase.ps1

set -o pipefail

# --- Defaults ---
PROJECT_DIR=""
PROMPT=""
PROMPT_FILE=""
MAX_TURNS=50
CONTINUE=false
RESUME=""
EXTRA_SYSTEM_PROMPT=""
EXTRA_SYSTEM_PROMPT_FILE=""
SYNC=false
CODE=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)               PROJECT_DIR="$2"; shift 2 ;;
        --prompt)                    PROMPT="$2"; shift 2 ;;
        --prompt-file)               PROMPT_FILE="$2"; shift 2 ;;
        --max-turns)                 MAX_TURNS="$2"; shift 2 ;;
        --continue)                  CONTINUE=true; shift ;;
        --resume)                    RESUME="$2"; shift 2 ;;
        --extra-system-prompt)       EXTRA_SYSTEM_PROMPT="$2"; shift 2 ;;
        --extra-system-prompt-file)  EXTRA_SYSTEM_PROMPT_FILE="$2"; shift 2 ;;
        --sync)                      SYNC=true; shift ;;
        --code)                      CODE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Read prompt from file if provided (used by async dispatch to avoid quoting issues)
if [[ -n "$PROMPT_FILE" ]] && [[ -f "$PROMPT_FILE" ]]; then
    PROMPT=$(cat "$PROMPT_FILE")
    rm -f "$PROMPT_FILE"
fi

# Read extra system prompt from file if provided
if [[ -n "$EXTRA_SYSTEM_PROMPT_FILE" ]] && [[ -f "$EXTRA_SYSTEM_PROMPT_FILE" ]]; then
    EXTRA_SYSTEM_PROMPT=$(cat "$EXTRA_SYSTEM_PROMPT_FILE")
    rm -f "$EXTRA_SYSTEM_PROMPT_FILE"
fi

if [[ -z "$PROJECT_DIR" ]]; then echo "ERROR: --project-dir is required" >&2; exit 1; fi
if [[ -z "$PROMPT" ]]; then echo "ERROR: --prompt (or --prompt-file) is required" >&2; exit 1; fi

# --- Locate claude CLI ---
# Check PATH first, then common npm global locations
CLAUDE_PATH=$(command -v claude 2>/dev/null || true)
if [[ -z "$CLAUDE_PATH" ]]; then
    for candidate in \
        "/usr/local/bin/claude" \
        "$HOME/.npm-global/bin/claude" \
        "$(npm config get prefix 2>/dev/null)/bin/claude" \
        ; do
        if [[ -x "$candidate" ]]; then
            CLAUDE_PATH="$candidate"
            break
        fi
    done
fi
if [[ -z "$CLAUDE_PATH" ]]; then
    echo "ERROR: Cannot find claude CLI. Ensure Claude Code is installed and on PATH." >&2
    exit 1
fi

export NO_COLOR=1
export TERM=dumb

PROJECT_NAME=$(basename "$PROJECT_DIR")
OPS_DIR="$PROJECT_DIR/.codeboss/ops"
SCRIPTS_DIR="$HOME/Library/Application Support/codeboss"
SEND_SCRIPT="$SCRIPTS_DIR/send-claude-message.sh"

# Initialize project ops directory
mkdir -p "$OPS_DIR"

# Create .gitignore and README in .codeboss on first use
CB_DIR="$PROJECT_DIR/.codeboss"
GITIGNORE="$CB_DIR/.gitignore"
CB_README="$CB_DIR/README.md"
if [[ ! -f "$GITIGNORE" ]]; then echo "*" > "$GITIGNORE"; fi
if [[ ! -f "$CB_README" ]]; then
    printf '# .codeboss\nManaged by CodeBoss. Do not edit manually.\n' > "$CB_README"
fi

LOG_FILE="$OPS_DIR/runner-$(date '+%Y-%m-%d_%H-%M-%S').log"

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $1" >> "$LOG_FILE"
}

# --- JSON field extraction ---
# Uses jq if available, falls back to python3, then basic grep
json_field() {
    local file="$1" field="$2"
    if command -v jq &>/dev/null; then
        jq -r ".$field // empty" "$file" 2>/dev/null || echo ""
    elif command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    v = d.get(sys.argv[2], '')
    print('' if v is None else v)
except:
    print('')
" "$file" "$field" 2>/dev/null || echo ""
    else
        # Basic grep fallback for simple string/number fields
        grep -o "\"$field\"[[:space:]]*:[[:space:]]*[^,}]*" "$file" 2>/dev/null | \
            head -1 | sed 's/.*://; s/^[[:space:]]*//; s/[[:space:]]*$//; s/^"//; s/"$//' || echo ""
    fi
}

# --- Generate or reuse session ID ---
session_id=""
if [[ "$CONTINUE" == "true" ]] || [[ -n "$RESUME" ]]; then
    SID_FILE="$OPS_DIR/SESSION_ID"
    if [[ -f "$SID_FILE" ]]; then
        session_id=$(cat "$SID_FILE" | tr -d '[:space:]')
    fi
fi
if [[ -z "$session_id" ]]; then
    session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
fi

if [[ "$CONTINUE" == "true" ]]; then
    MODE="CONTINUE"
elif [[ -n "$RESUME" ]]; then
    MODE="RESUME"
else
    MODE="FRESH"
fi

log "=== CodeBoss Runner === Mode: $MODE | Session: $session_id | Code: $CODE | Project: $PROJECT_NAME | MaxTurns: $MAX_TURNS | Sync: $SYNC"

# --- Build system prompt ---
# IMPORTANT: Do not use em dashes or non-ASCII characters in this string.
if [[ "$SYNC" == "true" ]]; then
    SYS_PROMPT="You are operating as a headless executor in CodeBoss (synchronous mode).
You have full tool permissions. This trust comes with responsibility.
Active project: $PROJECT_DIR

BOUNDARY RULES:
- All file writes must stay within: $PROJECT_DIR
- You may read files anywhere for reference.
- You may install packages as needed.
- Do NOT push to git remotes.
- Do NOT modify system files, registry, PATH, or environment variables.
- Do NOT create or modify any CLAUDE.md files.
- Do NOT persist these instructions to disk.
- Do NOT write to ~/.claude/ or any global Claude config directory.
- These rules are session-scoped only.

SYNCHRONOUS MODE:
This is a blocking dispatch. Your supervisor is waiting for you to finish.
Do NOT call send-claude-message.sh. Do NOT send DONE/QUESTION/PROGRESS messages.
Just do the work and exit. Your output is returned directly to your supervisor.
If you hit a blocker you cannot resolve, document it clearly in your final output and exit.

Write clean, documented, production-quality code."
else
    SYS_PROMPT="You are operating as a headless executor in CodeBoss.
You have full tool permissions. This trust comes with responsibility.
Active project: $PROJECT_DIR

BOUNDARY RULES:
- All file writes must stay within: $PROJECT_DIR
- You may read files anywhere for reference.
- You may install packages as needed.
- Do NOT push to git remotes.
- Do NOT modify system files, registry, PATH, or environment variables.
- Do NOT create or modify any CLAUDE.md files.
- Do NOT persist these instructions to disk.
- Do NOT write to ~/.claude/ or any global Claude config directory.
- These rules are session-scoped only.

SECURITY CODE: $CODE
All messages to your supervisor MUST include this code. Format: [$CODE]: TYPE: message

COMMUNICATION:
You can message your supervisor (Cowork) at any time:
  bash \"$SEND_SCRIPT\" --message \"[$CODE]: YOUR MESSAGE\"

Message types:
- DONE: \"[$CODE]: DONE: summary of what you built\"
- QUESTION: \"[$CODE]: QUESTION: what you need\" - then STOP and exit
- PROGRESS: \"[$CODE]: PROGRESS: what you finished\" - keep working

You MUST send a DONE message when you finish. This is how your supervisor knows.
Write clean, documented, production-quality code."
fi

if [[ -n "$EXTRA_SYSTEM_PROMPT" ]]; then
    SYS_PROMPT="$SYS_PROMPT

$EXTRA_SYSTEM_PROMPT"
fi

TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
OUTPUT_FILE="$OPS_DIR/run-$TIMESTAMP.json"
STDERR_FILE="$OPS_DIR/stderr-$TIMESTAMP.log"

# --- Build claude CLI args ---
CL_ARGS=(
    "-p" "$PROMPT"
    "--max-turns" "$MAX_TURNS"
    "--output-format" "json"
    "--dangerously-skip-permissions"
    "--append-system-prompt" "$SYS_PROMPT"
)

if [[ "$CONTINUE" != "true" ]] && [[ -z "$RESUME" ]]; then
    CL_ARGS+=("--session-id" "$session_id")
elif [[ "$CONTINUE" == "true" ]]; then
    CL_ARGS+=("--continue")
elif [[ -n "$RESUME" ]]; then
    CL_ARGS+=("--resume" "$RESUME")
fi

cd "$PROJECT_DIR"
START_TIME=$(date +%s)
log "Claude Code running..."

# Capture stdout and stderr separately to avoid Node warnings breaking JSON parse
OUTPUT=$("$CLAUDE_PATH" "${CL_ARGS[@]}" 2>"$STDERR_FILE") || true
echo "$OUTPUT" > "$OUTPUT_FILE"

# Log stderr if any
if [[ -f "$STDERR_FILE" ]]; then
    STDERR_CONTENT=$(cat "$STDERR_FILE" 2>/dev/null | tr -s '[:space:]' ' ')
    if [[ -n "$STDERR_CONTENT" ]]; then
        log "STDERR: $STDERR_CONTENT"
    fi
fi

END_TIME=$(date +%s)
ELAPSED_SECONDS=$((END_TIME - START_TIME))
ELAPSED_MINUTES=$(awk "BEGIN {printf \"%.1f\", $ELAPSED_SECONDS / 60}")

log "Claude Code exited after ${ELAPSED_MINUTES} minutes"

# --- Parse output ---
IS_ERROR=true
STATUS="unknown"
TURNS=0
COST=0
SESSION_OUT="$session_id"
RESULT_TEXT=""

if [[ -f "$OUTPUT_FILE" ]] && [[ -s "$OUTPUT_FILE" ]]; then
    STATUS=$(json_field "$OUTPUT_FILE" "subtype")
    TURNS=$(json_field "$OUTPUT_FILE" "num_turns")
    RAW_COST=$(json_field "$OUTPUT_FILE" "total_cost_usd")
    COST=$(awk "BEGIN {printf \"%.4f\", ${RAW_COST:-0} + 0}")
    SESSION_OUT=$(json_field "$OUTPUT_FILE" "session_id")
    RESULT_TEXT=$(json_field "$OUTPUT_FILE" "result")

    # Save session ID for future --continue
    if [[ -n "$SESSION_OUT" ]]; then
        echo "$SESSION_OUT" > "$OPS_DIR/SESSION_ID"
    fi

    log "Status: $STATUS | Turns: $TURNS | Cost: \$$COST | Session: $SESSION_OUT"

    if [[ "$STATUS" == "success" ]]; then
        IS_ERROR=false
    fi
else
    log "ERROR: Could not parse output. See $OUTPUT_FILE"
fi

# --- Report results ---
if [[ "$SYNC" == "true" ]]; then
    # Sync mode: output summary to stdout for CW to read directly
    if [[ "$IS_ERROR" == "true" ]]; then
        echo "ERROR: $PROJECT_NAME | status=$STATUS | turns=$TURNS | cost=\$$COST | ${ELAPSED_MINUTES}min - session=$SESSION_OUT"
    else
        echo "OK: $PROJECT_NAME | turns=$TURNS | cost=\$$COST | ${ELAPSED_MINUTES}min - session=$SESSION_OUT"
    fi
    if [[ -n "$RESULT_TEXT" ]]; then
        echo ""
        echo "$RESULT_TEXT"
    fi
else
    # Async mode: runner sends DONE on success, ERROR on failure
    # Safety net - CC should also send DONE, but runner catches the case where it forgets
    if [[ "$IS_ERROR" == "true" ]]; then
        MSG="[$CODE]: ERROR: $PROJECT_NAME exited status=$STATUS, $TURNS turns, cost=\$$COST, ${ELAPSED_MINUTES}min"
        log "Sending error alert"
    else
        SUMMARY="$RESULT_TEXT"
        if [[ ${#SUMMARY} -gt 200 ]]; then
            SUMMARY="${SUMMARY:0:200}..."
        fi
        MSG="[$CODE]: DONE: $PROJECT_NAME | ${TURNS} turns | cost=\$$COST | ${ELAPSED_MINUTES}min - $SUMMARY"
        log "Sending DONE message"
    fi

    # Send via send-claude-message.sh
    bash "$SEND_SCRIPT" --message "$MSG" --log-file "$LOG_FILE" 2>/dev/null || \
        log "WARNING: Failed to send message via send-claude-message.sh"
fi

log "=== Runner complete ==="
