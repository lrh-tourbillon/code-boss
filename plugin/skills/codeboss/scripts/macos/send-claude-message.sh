#!/usr/bin/env bash
# send-claude-message.sh - Sends a message to Claude Desktop via macOS Accessibility/AppleScript
# Includes text-box detection: checks if input already has text before sending
#
# macOS equivalent of Send-ClaudeMessage.ps1
# Requires: macOS Accessibility permissions granted to the calling terminal/app
#   (System Settings > Privacy & Security > Accessibility)

set -o pipefail

# --- Defaults ---
MESSAGE=""
NEW_CHAT=false
NO_SEND=false
QUIET=false
DELAY=5            # seconds to wait before sending (lets CW finish inference)
MAX_RETRIES=6      # max retries if text box is occupied (5s between retries = 30s max wait)
RETRY_DELAY=5      # seconds between retries when text box is occupied
LOG_FILE=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --message|-m)       MESSAGE="$2"; shift 2 ;;
        --new-chat)         NEW_CHAT=true; shift ;;
        --no-send)          NO_SEND=true; shift ;;
        --quiet|-q)         QUIET=true; shift ;;
        --delay)            DELAY="$2"; shift 2 ;;
        --max-retries)      MAX_RETRIES="$2"; shift 2 ;;
        --retry-delay)      RETRY_DELAY="$2"; shift 2 ;;
        --log-file)         LOG_FILE="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$MESSAGE" ]]; then
    echo "ERROR: --message is required" >&2
    exit 1
fi

# --- Functions ---

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[$ts] [send-claude-message] $1"
    if [[ "$QUIET" != "true" ]]; then
        echo "$line"
    fi
    if [[ -n "$LOG_FILE" ]]; then
        echo "$line" >> "$LOG_FILE"
    fi
}

check_claude_running() {
    # Check if Claude Desktop process is running
    if ! osascript -e 'tell application "System Events" to (name of processes) contains "Claude"' 2>/dev/null | grep -q "true"; then
        log "ERROR: Claude Desktop is not running"
        return 1
    fi
    # Get the PID for logging
    local pid
    pid=$(pgrep -x "Claude" | head -1 2>/dev/null || echo "unknown")
    log "Claude Desktop is running (PID=$pid)"
    return 0
}

activate_claude() {
    # Bring Claude Desktop to the foreground
    osascript -e 'tell application "Claude" to activate' 2>/dev/null
    sleep 0.5
}

get_input_text() {
    # Try to read current text in Claude's focused input element via Accessibility API.
    # Returns the text content, or a sentinel value if reading fails.
    #
    # For Electron apps (like Claude Desktop), the focused UI element's AXValue
    # attribute exposes the text content of the input field.
    local result
    result=$(osascript 2>/dev/null <<'APPLESCRIPT'
tell application "System Events"
    tell process "Claude"
        if (count of windows) = 0 then
            return "<<NO_WINDOW>>"
        end if
        try
            set focusedEl to value of attribute "AXFocusedUIElement"
            try
                set currentVal to value of focusedEl
                if currentVal is missing value then
                    return ""
                end if
                return currentVal
            on error
                return "<<CANNOT_READ>>"
            end try
        on error
            return "<<NO_FOCUS>>"
        end try
    end tell
end tell
APPLESCRIPT
    ) || true
    echo "$result"
}

open_new_chat() {
    log "Opening new chat (Cmd+N)"
    activate_claude
    osascript 2>/dev/null <<'APPLESCRIPT'
tell application "System Events"
    tell process "Claude"
        keystroke "n" using command down
    end tell
end tell
APPLESCRIPT
    sleep 2
}

send_text_to_claude() {
    local text="$1"
    local press_enter="$2"

    # Ensure Claude is in the foreground
    activate_claude

    # Save current clipboard for later restoration
    local saved_clipboard
    saved_clipboard=$(pbpaste 2>/dev/null || true)

    # Attempt 1: Set value directly via Accessibility API (avoids clipboard)
    if osascript - "$text" 2>/dev/null <<'APPLESCRIPT'
on run argv
    set messageText to item 1 of argv
    tell application "System Events"
        tell process "Claude"
            set focusedEl to value of attribute "AXFocusedUIElement"
            set value of focusedEl to messageText
        end tell
    end tell
end run
APPLESCRIPT
    then
        log "Text entered via set value (direct AppleScript)"
    else
        # Attempt 2: Fall back to clipboard paste
        printf '%s' "$text" | pbcopy
        sleep 0.2

        osascript 2>/dev/null <<'APPLESCRIPT'
tell application "System Events"
    tell process "Claude"
        keystroke "v" using command down
    end tell
end tell
APPLESCRIPT
        sleep 0.3
        log "Text pasted via clipboard (fallback)"
    fi

    if [[ "$press_enter" == "true" ]]; then
        # Brief delay, then re-activate to ensure focus before pressing Return
        sleep 0.2
        osascript 2>/dev/null <<'APPLESCRIPT'
tell application "Claude" to activate
delay 0.2
tell application "System Events"
    tell process "Claude"
        keystroke return
    end tell
end tell
APPLESCRIPT
        log "Return key sent"
    fi

    # Restore original clipboard
    printf '%s' "$saved_clipboard" | pbcopy
}

check_accessibility_permissions() {
    # Quick test: ask System Events for the name of a process that is always running.
    # If this fails, the calling app lacks Accessibility permissions.
    if ! osascript -e 'tell application "System Events" to get name of process "Finder"' &>/dev/null; then
        log "ERROR: Accessibility permissions not granted."
        log "  Go to: System Settings > Privacy & Security > Accessibility"
        log "  Add your terminal app (e.g., Terminal, iTerm2) to the allowed list."
        echo "ERROR: Accessibility permissions required." >&2
        echo "  Go to: System Settings > Privacy & Security > Accessibility" >&2
        echo "  Add your terminal app (e.g., Terminal, iTerm2) to the allowed list." >&2
        return 1
    fi
    log "Accessibility permissions verified"
    return 0
}

# === Main ===

preview="${MESSAGE:0:80}"
log "Delay: ${DELAY}s | Message: $preview"

if [[ "$DELAY" -gt 0 ]]; then
    log "Waiting ${DELAY}s for CW to finish inference..."
    sleep "$DELAY"
fi

# Verify accessibility permissions before any osascript calls
check_accessibility_permissions || exit 1

# Verify Claude Desktop is running
check_claude_running || exit 1

# Activate Claude Desktop (bring to foreground)
activate_claude

# Open new chat if requested
if [[ "$NEW_CHAT" == "true" ]]; then
    open_new_chat
    # Re-activate after new chat opens
    activate_claude
fi

# --- Text-box detection: check if input already has content ---
retries=0
while [[ $retries -lt $MAX_RETRIES ]]; do
    existing_text=$(get_input_text)

    if [[ "$existing_text" == "<<NO_WINDOW>>" ]]; then
        log "ERROR: No Claude window found"
        exit 1
    fi

    if [[ "$existing_text" == "<<NO_FOCUS>>" ]] || [[ "$existing_text" == "<<CANNOT_READ>>" ]]; then
        log "WARNING: Could not read input field text - proceeding anyway"
        break
    fi

    # Check if empty or placeholder text
    trimmed=$(echo "$existing_text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ -z "$trimmed" ]] || echo "$trimmed" | grep -qE '^(Reply\.\.\.|Type a message|Message\.\.\.?)$'; then
        log "Input field is clear (empty or placeholder) - safe to send"
        break
    fi

    # Text detected in the field
    retries=$((retries + 1))
    preview_existing="${existing_text:0:60}"
    log "WARNING: Text already in input field (attempt $retries/$MAX_RETRIES): '$preview_existing'"

    if [[ $retries -ge $MAX_RETRIES ]]; then
        log "ERROR: Input field still occupied after $MAX_RETRIES retries. Aborting send to avoid clobbering."
        exit 2
    fi

    log "Waiting ${RETRY_DELAY}s before retry..."
    sleep "$RETRY_DELAY"

    # Re-activate in case UI changed
    activate_claude
done

# Send the message
if [[ "$NO_SEND" == "true" ]]; then
    send_text_to_claude "$MESSAGE" "false"
else
    send_text_to_claude "$MESSAGE" "true"
fi

log "Done"
exit 0
