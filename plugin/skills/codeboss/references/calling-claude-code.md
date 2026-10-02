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
| `-Model` | string | No | Passed to claude as `--model` (e.g. `claude-fable-5-1`, `opus[1m]`); default = the CLI's own picker state |
| `-Effort` | string | No | Passed to claude as `--effort` (`low`, `medium`, `high`, `xhigh`) |
| `-InProcess` | switch | No | Windows, async only: launch the runner under this shell with `Start-Process` instead of through Task Scheduler (see below) |

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
| `.prompt-temp-*.txt`, `.sysprompt-temp-*.txt` | Windows: the prompt handed to the runner (deleted when the runner has read it) and the extra system prompt |
| `..\bin\` | Windows: the runner and pipe scripts staged for the Task Scheduler launch (`run-phase.ps1`, `Send-ClaudeMessage.ps1`, `Get-ClaudePanel.ps1`) -- overwritten at every async dispatch |

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

## Windows launcher: Task Scheduler (0.3.0+)

An async `dispatch.ps1` no longer starts the runner with `Start-Process` under the tool shell. It
registers a scheduled task `CodeBoss-<project>-<code>` (run as the current user, interactive,
limited rights, 3-day execution limit, hidden window), starts it, and waits up to 15 s for the
runner's `runner-*.log` to appear (if it does not, the `Dispatched` line distinguishes a task still
`Running` - a slow start, leave it - from one back at `Ready`, which never ran). The process tree is then
`claude.exe <- powershell.exe <- svchost.exe (Schedule) <- services.exe` -- **outside the Claude
desktop app's process tree**, whose supervision silently kills long-running children (full-solution
`dotnet test` runs died 20 s-4 min in, nine of nine, 2026-09-22/23; two of two completed under Task
Scheduler). UI Automation to Cowork works from the interactive session either way, so PROGRESS and
DONE still arrive. Finished `CodeBoss-*` tasks are swept at the next dispatch.

Two consequences of the desktop app being MSIX-packaged:

1. The app's tool shell sees a **virtualized** `%APPDATA%` (an overlay under
   `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\`); a Task Scheduler process sees the
   **physical** one, and the two can differ silently (it happened twice). So the scheduled launch
   copies the runner and the pipe scripts it can see into `<ProjectDir>\.codeboss\bin\` and runs
   them from there; `run-phase.ps1` finds `Send-ClaudeMessage.ps1` as its own sibling
   (`$PSScriptRoot`). No manual sync of the two `%APPDATA%` copies is needed.
2. The prompt / system-prompt temp files are written under `<ProjectDir>\.codeboss\ops\`, never
   under `%APPDATA%`.

`pwsh.exe` is usually **not** on a scheduled process's PATH; the runner's PROGRESS hint therefore
names `powershell.exe`. `-InProcess` restores the old launch; `-Sync` is unchanged (in-process,
blocking). If registering or starting the task fails, the dispatch falls back to the in-process
launch on its own and says so on the `Dispatched` line.

**Delivery:** both the terminal message and CC's PROGRESS updates carry `-ExpectedUrl`, so they are
only ever typed into the conversation that dispatched the run. The terminal message waits up to
`-DeliveryWaitSeconds` (run-phase.ps1, default 3600) for that conversation to be back on screen; if
it never is, the runner saves the message to `.codeboss\ops\UNDELIVERED-<code>.txt` and logs
`DELIVERY FAILED`. See troubleshooting.md.
