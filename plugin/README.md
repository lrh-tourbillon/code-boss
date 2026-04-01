# CodeBoss

Orchestrates Claude Code (CC) headless from Cowork. You (Cowork) are the supervisor with UI access. Claude Code runs silently in a hidden PowerShell window and messages back when done.

## What It Does

- Dispatches tasks to Claude Code via PowerShell
- Monitors CC via Windows UI Automation (the "pipe")
- Verifies all incoming messages with a security code
- Supports async (fire-and-forget) and sync (blocking) dispatch modes
- Handles session continuity (continue, resume, handoff)

## Requirements

- Claude Desktop with Cowork mode
- Claude Code installed globally (`npm install -g @anthropic-ai/claude-code`)
- Windows MCP connector (~~windows-os)

## First Use

On first use, CodeBoss will deploy three PowerShell scripts to `%APPDATA%\codeboss\`:

- `dispatch.ps1` - Entry point: launches CC async or sync
- `run-phase.ps1` - Runner: invokes claude CLI, monitors exit, sends DONE/ERROR via pipe
- `Send-ClaudeMessage.ps1` - Pipe: uses Windows UI Automation to type into Claude Desktop

## Usage

Tell Cowork to dispatch a task. Example phrases:
- "CodeBoss: build a REST API in C:\projects\myapp"
- "dispatch a task to Claude Code: refactor the auth module in C:\work\backend"
- "run CC on C:\projects\site - add dark mode to the CSS"

## Project Structure

CodeBoss creates a `.codeboss\` folder in your project directory:

```
your-project\
  .codeboss\
    .gitignore       (ignores everything inside - keeps your repo clean)
    README.md        (managed by CodeBoss)
    ops\
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
| Sync (-Sync flag) | Tasks < ~60s | Blocks until CC exits. Output returned directly. |

The Windows MCP PowerShell tool has a hard 60-second timeout, so sync dispatch only works for fast tasks.

## Session Continuity

- `-Continue`: Resume most recent CC session for a project
- `-Resume SESSION_ID`: Resume a specific session

Session IDs are saved to `.codeboss\ops\SESSION_ID` after each run.

## Reference Files

- `skills/codeboss/references/calling-claude-code.md` - CLI flags, output format, session management
- `skills/codeboss/references/boundary-rules.md` - CC system prompt, CLAUDE.md guard, permission model
- `skills/codeboss/references/troubleshooting.md` - Known bugs, encoding issues, timing fixes
- `skills/codeboss/references/context-handoff.md` - How to checkpoint and continue in fresh sessions
