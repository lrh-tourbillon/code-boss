#!/usr/bin/env bash
# dispatch.sh - Launches Claude Code via run-phase.sh (async or sync)
# Scripts must be installed at ~/Library/Application Support/codeboss/ before use.
#
# macOS equivalent of dispatch.ps1

set -euo pipefail

# --- Defaults ---
PROJECT_DIR=""
PROMPT=""
MAX_TURNS=50
CONTINUE=false
RESUME=""
EXTRA_SYSTEM_PROMPT=""
SYNC=false

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)          PROJECT_DIR="$2"; shift 2 ;;
        --prompt)               PROMPT="$2"; shift 2 ;;
        --max-turns)            MAX_TURNS="$2"; shift 2 ;;
        --continue)             CONTINUE=true; shift ;;
        --resume)               RESUME="$2"; shift 2 ;;
        --extra-system-prompt)  EXTRA_SYSTEM_PROMPT="$2"; shift 2 ;;
        --sync)                 SYNC=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$PROJECT_DIR" ]]; then echo "ERROR: --project-dir is required" >&2; exit 1; fi
if [[ -z "$PROMPT" ]]; then echo "ERROR: --prompt is required" >&2; exit 1; fi

SCRIPTS_DIR="$HOME/Library/Application Support/codeboss"
RUNNER="$SCRIPTS_DIR/run-phase.sh"

if [[ ! -f "$RUNNER" ]]; then
    echo "ERROR: CodeBoss scripts not found at $SCRIPTS_DIR. Bootstrap required: deploy scripts from plugin to this directory." >&2
    exit 1
fi

PROJECT_NAME=$(basename "$PROJECT_DIR")

if [[ "$SYNC" == "true" ]]; then
    # --- Synchronous: block until CC finishes, return output directly ---
    # No security code needed - no pipe involved
    RUN_ARGS=(--project-dir "$PROJECT_DIR" --prompt "$PROMPT" --max-turns "$MAX_TURNS" --sync)
    if [[ "$CONTINUE" == "true" ]]; then RUN_ARGS+=(--continue); fi
    if [[ -n "$RESUME" ]]; then RUN_ARGS+=(--resume "$RESUME"); fi
    if [[ -n "$EXTRA_SYSTEM_PROMPT" ]]; then RUN_ARGS+=(--extra-system-prompt "$EXTRA_SYSTEM_PROMPT"); fi

    bash "$RUNNER" "${RUN_ARGS[@]}"
else
    # --- Async: fire-and-forget in background ---
    # Generate security code (6-char hex) for pipe authentication
    CODE=$(openssl rand -hex 3)

    TS="$(date '+%Y%m%d-%H%M%S')-$$"
    PROMPT_FILE="$SCRIPTS_DIR/.prompt-temp-$TS.txt"
    printf '%s' "$PROMPT" > "$PROMPT_FILE"

    RUN_ARGS=(--project-dir "$PROJECT_DIR" --prompt-file "$PROMPT_FILE" --max-turns "$MAX_TURNS" --code "$CODE")
    if [[ "$CONTINUE" == "true" ]]; then RUN_ARGS+=(--continue); fi
    if [[ -n "$RESUME" ]]; then RUN_ARGS+=(--resume "$RESUME"); fi

    if [[ -n "$EXTRA_SYSTEM_PROMPT" ]]; then
        SYS_FILE="$SCRIPTS_DIR/.sysprompt-temp-$TS.txt"
        printf '%s' "$EXTRA_SYSTEM_PROMPT" > "$SYS_FILE"
        RUN_ARGS+=(--extra-system-prompt-file "$SYS_FILE")
    fi

    # Launch in background with nohup (macOS equivalent of Start-Process -WindowStyle Hidden)
    nohup bash "$RUNNER" "${RUN_ARGS[@]}" > /dev/null 2>&1 &

    MODE="NEW"
    if [[ "$CONTINUE" == "true" ]]; then MODE="CONTINUE"; fi
    if [[ -n "$RESUME" ]]; then MODE="RESUME"; fi

    echo "Dispatched [$MODE]: Project=$PROJECT_NAME, MaxTurns=$MAX_TURNS, Code=$CODE"
fi
