# Troubleshooting

Known bugs, workarounds, and lessons learned from building CodeBoss.

## Script Encoding: ASCII Only

**Problem**: Windows MCP FileSystem tool corrupts non-ASCII characters on write. Em dashes (--) become garbled multi-byte sequences. Any Unicode outside basic ASCII is at risk.

**Rule**: ALL scripts must be ASCII only. No em dashes, no curly quotes, no Unicode.

**Check**: If a script behaves unexpectedly after being written via Windows MCP, inspect it character by character. Even invisible BOM characters (byte order marks) at the start of files can cause issues.

**Fix**: Rewrite the file using only ASCII characters.

## Stderr Pollution Breaking JSON Parse

**Problem**: CC outputs JSON to stdout, but Node.js prints startup warnings to stderr. If both streams are captured together, the JSON parse fails with garbage prepended.

**Fix** (already in run-phase.ps1): Redirect stderr separately: `& $claudePath @clArgs 2>$stderrFile | Out-String`

The stderr file is logged but usually safe to ignore (it contains Node version warnings, not errors).

## Hidden Window UI Automation: Enter Key Not Sending

**Problem**: A PowerShell process spawned with `-WindowStyle Hidden` cannot directly call `SetFocus` on Claude Desktop's input element. The `{ENTER}` key send silently fails.

**Fix** (already in Send-ClaudeMessage.ps1):
1. Call `SetForegroundWindow` on Claude Desktop's main window handle
2. Call `RestoreWindow` to un-minimize if hidden
3. Wait 200ms
4. SetFocus on the element
5. Wait 300ms
6. THEN send `{ENTER}`

**Also**: run-phase.ps1 spawns Send-ClaudeMessage.ps1 as a separate `Start-Process` rather than calling it directly, to avoid nested quoting issues with base64-encoded commands.

## Placeholder Text Triggering Occupied Check

**Problem**: Claude Desktop's input field shows "Reply..." as placeholder text. The text-box detection in Send-ClaudeMessage.ps1 was triggering on this, thinking the field was occupied.

**Fix** (already in Send-ClaudeMessage.ps1): Regex check for common placeholder strings:
```powershell
$existingText.Trim() -match "^(Reply\.\.\.|Type a message|Message\.\.\.?)$"
```
If matched, treat as empty/safe.

## Quoting Hell in Nested PowerShell

**Problem**: When run-phase.ps1 needs to invoke Send-ClaudeMessage.ps1 as a background process, the message string often contains quotes, colons, and brackets that break nested PowerShell argument parsing.

**Fix** (already in run-phase.ps1): Use base64-encoded commands:
```powershell
$cmd = "& '$sendScript' -Message '$msg' -LogFile '$logFile'"
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
Start-Process powershell -ArgumentList "-NoProfile -EncodedCommand $b64" -Wait
```

## CLAUDE.md Global Contamination

**Problem**: CC with `--dangerously-skip-permissions` has previously written CodeBoss boundary rules to `C:\Users\Lou\.claude\CLAUDE.md`, affecting all subsequent CC sessions globally.

**Prevention**: The system prompt now explicitly forbids this. See boundary-rules.md.

**Detection**: If CC sessions start behaving oddly (e.g., refusing to write files, adding unexpected rules), check:
```powershell
Get-Content "C:\Users\$env:USERNAME\.claude\CLAUDE.md"
```

**Cleanup**: Remove any CodeBoss-injected content from that file using ~~windows-os FileSystem.

## Sync Mode Timeout

**Problem**: The ~~windows-os PowerShell tool has a hard 60-second timeout. Sync dispatch blocks until CC finishes - if CC takes longer than 60s, the tool call times out and you lose the output.

**Rule**: Only use `-Sync` for tasks that will genuinely complete in under 60 seconds. When in doubt, use async.

## CC Not Found

**Problem**: run-phase.ps1 reports "Cannot find claude CLI."

**Fix**: Ensure Claude Code is installed globally: `npm install -g @anthropic-ai/claude-code`. Then verify with `where claude` in a new PowerShell window. If installed in a non-standard location, the runner checks PATH, `%APPDATA%\npm`, and `%LOCALAPPDATA%\npm`.

## No DONE Message Received

**Problem**: CC finished but you never got a DONE message.

**Causes and checks**:
1. CC crashed before sending DONE - check `runner-*.log` in `.codeboss\ops\`. The runner sends DONE itself as a safety net after CC exits.
2. The message was sent but Claude Desktop was not focused - check the runner log for "Enter sent" and "Done".
3. Input field was occupied - check for "Input field still occupied" in runner log.
4. Wrong process found - Send-ClaudeMessage.ps1 grabs the first Claude process with a window title. If multiple Claude instances are running, it may have targeted the wrong one.

**If the runner log shows DONE was sent but you didn't receive it**: Try the manual recovery - check `.codeboss\ops\SESSION_ID` and use `-Resume SESSION_ID` with a sync dispatch asking CC to summarize what it built.