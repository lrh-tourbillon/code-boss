# CodeBoss

Orchestrates Claude Code (CC) headless from Cowork. You (Cowork) are the supervisor with UI access. Claude Code runs silently in the background and messages back when done.

## What It Does

- Dispatches tasks to Claude Code via platform-specific scripts
- Monitors CC via the OS's UI automation layer (the "pipe")
- Verifies all incoming messages with a security code
- Supports async (fire-and-forget) and sync (blocking) dispatch modes
- Handles session continuity (continue, resume, handoff)
- Works on both **Windows** (PowerShell + UI Automation) and **macOS** (bash + Accessibility API)

## Requirements

Both platforms:
- Claude Desktop with Cowork mode
- Claude Code installed globally (`npm install -g @anthropic-ai/claude-code`)

Windows:
- Windows MCP connector (~~windows-os)

macOS:
- Accessibility permissions for your terminal app (System Settings > Privacy & Security > Accessibility)

## First Use

On first use, CodeBoss deploys three scripts to a platform-specific location:

### Windows (`%APPDATA%\codeboss\`)

- `dispatch.ps1` - Entry point: launches CC async or sync
- `run-phase.ps1` - Runner: invokes claude CLI, monitors exit, sends DONE/ERROR via pipe
- `Send-ClaudeMessage.ps1` - Pipe: uses Windows UI Automation to type into Claude Desktop

### macOS (`~/Library/Application Support/codeboss/`)

- `dispatch.sh` - Entry point: launches CC async or sync
- `run-phase.sh` - Runner: invokes claude CLI, monitors exit, sends DONE/ERROR via pipe
- `send-claude-message.sh` - Pipe: uses AppleScript + Accessibility API to type into Claude Desktop

## Usage

Tell Cowork to dispatch a task. Example phrases:
- "CodeBoss: build a REST API in C:\projects\myapp"
- "dispatch a task to Claude Code: refactor the auth module in ~/work/backend"
- "run CC on ~/projects/site - add dark mode to the CSS"

## Project Structure

CodeBoss creates a `.codeboss/` folder in your project directory (same structure on both platforms):

```
your-project/
  .codeboss/
    .gitignore       (ignores everything inside - keeps your repo clean)
    README.md        (managed by CodeBoss)
    ops/
      runner-*.log   (runner activity and timing)
      run-*.json     (raw CC output)
      stderr-*.log   (CC stderr - usually ignorable)
      SESSION_ID     (most recent CC session ID)
```

## Security Model

Every async dispatch generates a 6-character hex security code. All messages from CC must include this code (`[CODE]: TYPE: message`). Cowork verifies the code before acting on any message. Unverified messages are flagged to the user.

## Sync vs Async

| Mode | When to use | How |
|------|-------------|-----|
| Async (default) | Tasks > ~30s | Fire-and-forget. CC messages back when done. |
| Sync | Tasks < ~60s | Blocks until CC exits. Output returned directly. |

Note: The Windows MCP PowerShell tool has a hard 60-second timeout for sync dispatch.

## Session Continuity

- Resume most recent session: `--continue` (macOS) / `-Continue` (Windows)
- Resume specific session: `--resume SESSION_ID` (macOS) / `-Resume SESSION_ID` (Windows)

Session IDs are saved to `.codeboss/ops/SESSION_ID` after each run.

## Reference Files

- `skills/codeboss/references/calling-claude-code.md` - CLI flags, output format, session management
- `skills/codeboss/references/boundary-rules.md` - CC system prompt, CLAUDE.md guard, permission model
- `skills/codeboss/references/troubleshooting.md` - Known bugs, encoding issues, timing fixes
- `skills/codeboss/references/context-handoff.md` - How to checkpoint and continue in fresh sessions
