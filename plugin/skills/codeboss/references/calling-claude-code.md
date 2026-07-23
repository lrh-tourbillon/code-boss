# Calling Claude Code

Reference for how Claude Code (CC) is invoked, CLI flags, and session management.

**Platform note:** The commands below use Windows PowerShell (`dispatch.ps1`,
backtick line continuations, `-Flag` parameters). On macOS the equivalents use
`dispatch.sh` with `--flag` options and backslash line continuations; the flag
names map one-to-one: `-ProjectDir` -> `--project-dir`, `-MaxTurns` ->
`--max-turns`, `-Continue` -> `--continue`, `-Resume` -> `--resume`,
`-ExtraSystemPrompt` -> `--extra-system-prompt`, `-Sync` -> `--sync`. The JSON
output fields, session modes, output files, and MaxTurns guidance are identical
across platforms (macOS paths use `/` and `.codeboss/ops/`). See "Finding the
claude CLI" below for the macOS lookup order.

## Basic Invocation

CC is called via `dispatch.ps1`, which calls `run-phase.ps1`, which calls the `claude` CLI:

```powershell
claude -p "prompt" `
    --max-turns N `
    --output-format json `
    --dangerously-skip-permissions `
    --append-system-prompt "..." `
    --session-id "..."
```

Stderr is redirected separately (`2>$stderrFile`) to prevent Node.js startup warnings from corrupting the JSON output.

## dispatch.ps1 Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-ProjectDir` | string | Yes | Full path to the project directory CC will work in |
| `-Prompt` | string | Yes | Task description for CC |
| `-MaxTurns` | int | No (default: 50) | Max agentic turns before CC exits |
| `-Continue` | switch | No | Resume most recent CC session for this project |
| `-Resume` | string | No | Resume specific session by ID |
| `-ExtraSystemPrompt` | string | No | Appended to the built-in system prompt |
| `-Sync` | switch | No | Block until CC finishes (sync mode, no pipe) |

## Session Modes

### Fresh Session (default)
CC starts a new session. A new session ID is generated and saved to `.codeboss\ops\SESSION_ID`.

### Continue (`-Continue`)
CC resumes the most recent session. Reads SESSION_ID from `.codeboss\ops\SESSION_ID`. Use this to pick up where a previous task left off.

### Resume (`-Resume SESSION_ID`)
CC resumes a specific session by ID. Use when you need to go back to a session that is not the most recent one.

## CC Output JSON

CC outputs a JSON object with these fields:

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Always "result" |
| `subtype` | string | "success", "error_max_turns", "error_during_tool_use", etc. |
| `is_error` | bool | Whether the run ended in error |
| `num_turns` | int | How many agentic turns were used |
| `result` | string | CC's final output text |
| `session_id` | string | The session ID (save this for resuming) |
| `total_cost_usd` | float | API cost for this run |

A successful run has `subtype: "success"` and `is_error: false`.

## Output Files

Per run, in `.codeboss\ops\`:

| File | Contents |
|------|----------|
| `runner-TIMESTAMP.log` | Runner activity log (timing, status, messages sent) |
| `run-TIMESTAMP.json` | Raw CC JSON output |
| `stderr-TIMESTAMP.log` | CC stderr (Node warnings, etc.) - usually ignorable |
| `SESSION_ID` | Most recent session ID (updated on each successful run) |

## MaxTurns Guidance

| Task type | Recommended MaxTurns |
|-----------|----------------------|
| Quick/sync task | 5-15 |
| Feature implementation | 30-50 |
| Large refactor | 50-100 |
| Full project build | 100+ |

If CC exits with `subtype: "error_max_turns"`, use `-Continue` to resume where it left off.

## ExtraSystemPrompt

Use `-ExtraSystemPrompt` to add task-specific constraints without editing the base system prompt. Examples:

```
"Focus only on the authentication module. Do not touch unrelated files."
"Use TypeScript. Do not use any external packages not already in package.json."
```

## Finding the claude CLI

### Windows
`run-phase.ps1` looks for claude in this order:
1. System PATH (`Get-Command claude`)
2. `%APPDATA%\npm\claude.cmd`
3. `%LOCALAPPDATA%\npm\claude.cmd`

### macOS
`run-phase.sh` first prepends the common CLI locations to PATH -- GUI-launched
processes on macOS inherit only a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`)
and do not source the user's shell profile -- then looks for claude in this order:
1. System PATH (`command -v claude`)
2. `/opt/homebrew/bin/claude` (Apple Silicon Homebrew)
3. `/usr/local/bin/claude` (Intel Homebrew / manual installs)
4. `~/.local/bin/claude`
5. `~/.npm-global/bin/claude`
6. `$(npm config get prefix)/bin/claude`

If not found, the runner exits with an error. Ensure Claude Code is installed: `npm install -g @anthropic-ai/claude-code`