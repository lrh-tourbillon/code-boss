# Context Handoff Protocol

How to checkpoint a CodeBoss session and continue in a fresh Cowork context when your context window gets heavy.

## When to Hand Off

- Your context is getting long (many tool calls, large responses)
- You are about to start a new long CC task and want a clean slate
- You notice yourself forgetting earlier decisions

## CRITICAL: Never Hand Off Mid-Async

If you are waiting for an async CC task (you dispatched and have not yet received DONE/ERROR), do NOT hand off. The new session will not have the security code and cannot verify CC's completion message.

Either:
1. Wait for CC to finish (DONE or ERROR), THEN hand off
2. Or tell the user: "CC is still running with code XXXXXX. I need to wait for it to finish before handing off."

## Handoff Steps

### 1. Write SESSION_HANDOFF.md

Write a handoff file to the project's `.codeboss\` directory. Use ~~windows-os FileSystem (mode: write).

Path: `<ProjectDir>\.codeboss\SESSION_HANDOFF.md`

Include:
- Current state of the project (what has been built, what is in progress)
- Any active session IDs from `.codeboss\ops\SESSION_ID`
- The immediate next task
- Any important decisions made in this session
- Known issues or blockers

Template:
```markdown
# CodeBoss Session Handoff
Generated: [date]
Previous session: [brief description]

## Project State
[What has been built. What works. What doesn't.]

## Active Session ID
[Content of .codeboss\ops\SESSION_ID, if relevant]

## Immediate Next Task
[Exactly what the next session should do first]

## Key Decisions
[Architecture choices, constraints, preferences established this session]

## Known Issues
[Anything the next session needs to watch out for]
```

### 2. Tell the User

Say: "Context is getting heavy. I'm writing a handoff and moving to a fresh session."

### 3. Initiate Handoff

**Option A: New Chat via pipe** (requires Send-ClaudeMessage.ps1 to be installed)

Use ~~windows-os PowerShell:
```powershell
& "$env:APPDATA\codeboss\Send-ClaudeMessage.ps1" `
    -NewChat `
    -Message "CodeBoss: Read the handoff at <ProjectDir>\.codeboss\SESSION_HANDOFF.md and continue."
```

This opens a new Cowork session (Ctrl+N) and auto-submits the message. Confirmed working.

**Option B: Scheduled task** (for automated continuations)

Create a scheduled task with the `_continued_NN` naming convention. The task should:
1. Read the SESSION_HANDOFF.md
2. Read the scripts
3. Continue the work

**Option C: Tell the user to start fresh manually**

If pipes are unavailable, just tell the user: "Please start a new Cowork session and paste: 'CodeBoss: Read <path> and continue.'"

## What the New Session Should Do First

When you (or a new session) receives a "read this handoff and continue" message:

1. Read the SESSION_HANDOFF.md at the specified path
2. Read the three working scripts from `%APPDATA%\codeboss\` (to know the current state)
3. Verify bootstrap (scripts should already be installed)
4. Summarize to the user: what was done, what you are about to do
5. Execute the immediate next task from the handoff

## Security Code Continuity

Security codes are session-scoped and do NOT persist across handoffs. After a handoff:
- Any in-flight async tasks from the previous session are orphaned (no way to verify their DONE message)
- Start fresh async tasks in the new session with new codes
- The previous session's security code should be considered expired