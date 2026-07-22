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

**Problem**: Claude Desktop's input field shows placeholder text (e.g. "Reply...", "Write a message..."). The text-box detection in Send-ClaudeMessage.ps1 reads it via UIA ValuePattern and mistakes it for a real user message, aborting the send after MaxRetries.

**Fix** (already in Send-ClaudeMessage.ps1): regex allowlist of known placeholders. Entries currently include "Reply...", "Type a message", "Message...", the Apr 2026 TipTap/ProseMirror placeholder ("Write a message" + U+2026 HORIZONTAL ELLIPSIS), and the input's accessible Name ("Write your prompt to Claude"). Trim() handles the trailing U+000A that ProseMirror leaks from its empty paragraph.

```powershell
$ellipsis = [char]0x2026  # ASCII-safe construction; never embed U+2026 literally
$isPlaceholder = $trimmed -eq "" -or
                 $trimmed -match "^(Reply\.\.\.|Type a message|Message\.\.\.?)$" -or
                 $trimmed -match ("^Write a message[" + $ellipsis + "\.\s]*$") -or
                 $trimmed -match ("^Write your prompt to Claude[" + $ellipsis + "\.\s]*$")
```

**When the placeholder changes again**: run the diagnostic script with Claude Desktop open and the chat empty:
```powershell
powershell -ExecutionPolicy Bypass -File `
    "%APPDATA%\codeboss\..\..\plugin\skills\codeboss\scripts\windows\Inspect-ClaudeTree.ps1" `
    -OutFile "$env:TEMP\claude-tree.log"
```
It walks the RawView UIA tree, dumps codepoints for every focusable+ValuePattern element, and prints a ranked candidate list. The chat input shows up as `Edit` with ClassName `tiptap ProseMirror`. Read off the Value codepoints and add a new entry to the regex above (build any non-ASCII char via `[char]0xNNNN` - the file must stay ASCII-only).

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

## Wrong-Window Injection: Use UI Automation, Not SendKeys

**Problem**: Send-ClaudeMessage used SetForegroundWindow + SendKeys ({ENTER}, ^v) to
submit. SetForegroundWindow is unreliable - Windows blocks background processes from
stealing focus - so when the user was working in another app (e.g. SSMS), the keystrokes,
including Enter, were injected into THAT app. An injected Enter in a SQL window could run a
query. Dangerous.

**Fix** (in Send-ClaudeMessage.ps1): the primary path is now pure UI Automation, which
targets a specific element regardless of which window is foreground and works on background
windows:
- Switch panels via InvokePattern.Invoke() on the Chat/Cowork/Code tab Button (matched by
  NAME - the AutomationIds regenerate each session). No Ctrl+1/2/3 keystroke.
- Fill the composer via ValuePattern.SetValue() (the Cowork Edit). No typing.
- Submit via InvokePattern.Invoke() on the "Send message" / "Queue message" Button. No
  {ENTER}. (The button can render a beat after SetValue, so retry the lookup for ~3s.)

Because nothing is sent to the foreground window, nothing can leak into another app.

SendKeys survives ONLY as a last-resort fallback (e.g. the Code composer has no ValuePattern
and needs a clipboard paste). Every fallback is gated on a confirmed-foreground check using a
robust sequence (foreground-lock-timeout reset + ALT-key unlock + AttachThreadInput + verify
GetForegroundWindow). If Claude cannot be confirmed foreground, the script ABORTS rather than
risk a stray keystroke; the codeout file remains the source of truth.

**Rule**: For any future UI injection, prefer UIA patterns (Invoke / SetValue) over SendKeys.
Only use SendKeys after confirming the target window is foreground, and abort if it is not.


## Code-panel Submit No-Op (Invoke returns success but nothing sends)

**Problem**: On Claude Desktop 1.12603.x, `InvokePattern.Invoke()` on the Code panel's
"Send" button (and on the tab pills) intermittently NO-OPS: the call throws nothing and
returns, but the message is never submitted - it just sits in the composer. The supervisor
then waits forever for an async result that never arrives. The leftover text also trips the
occupied-field guard on the NEXT dispatch, so the failure compounds.

**Fix** (`Submit-Composer`): never trust `Invoke()`'s return. After Invoking the Send button,
VERIFY the composer actually cleared (it reads empty or a known placeholder: "Type / for
commands" on Code, "Write a message..." on Cowork). If it did not clear within ~3s, fall back
to a focused `{ENTER}` (confirmed to submit BOTH the Cowork `Edit` and the Code `Group`
composer - `SetFocus` on the Group does place the caret), then `Ctrl+Enter`, and only then
abort. Same verify-then-fallback pattern as the tab-switch fix (bug #1).

Notes verified this session: the Code send control is a `Button` named exactly **`Send`** (not
"Send message"), so `Find-SendButton`'s second regex pass (`\b(send|submit)\b`) is what matches
it. A real submit on Code leaves the composer reading `Type / for commands` - a reliable
"sent" signal.

**Lesson**: For React-rendered controls on this build, treat UIA `Invoke()` as best-effort.
Always verify the resulting STATE CHANGE; keep a foreground-confirmed keystroke fallback.


## Duplicate Terminal Message on Same Code (async): CC and runner both sent DONE

**Problem**: In async dispatch the supervisor received TWO messages carrying the same
security code, a few seconds apart. Not a dupe - the texts differed, and the second one
flashed a console window on screen. Root cause: two independent report-back paths both fired
on completion:
1. The async system prompt told CC "You MUST send a DONE message when you finish" and handed
   it the Send-ClaudeMessage command, so CC self-sent its own DONE before exiting.
2. run-phase.ps1's post-exit "safety net" then ALSO sent a DONE built from the parsed JSON,
   via a visible Start-Process powershell (the console flash). It fired unconditionally, not
   only when CC forgot - so on the normal path you always got two.
The QUESTION path had the same latent bug (CC self-sent QUESTION, then the runner appended a
spurious DONE).

**Fix**: Make the runner the SOLE sender of the terminal message.
- System prompt: CC no longer self-sends DONE/ERROR/QUESTION. It writes its final summary as
  its last output and exits; to ask, it starts that final output with "QUESTION:". CC may
  still send live PROGRESS updates (only the runner cannot do those, since it is blocked
  waiting on the CLI).
- run-phase.ps1: after CC exits, send exactly one message - ERROR if the run errored,
  QUESTION if the result text starts with "QUESTION:", else DONE. The send now uses
  -WindowStyle Hidden so no console flashes.
This keeps the crash safety net (CC dies -> no output -> runner still sends ERROR) while
guaranteeing one message per dispatch.

**Note on drift**: the deployed copy at %APPDATA%\codeboss\run-phase.ps1 had diverged from
this plugin source (claude.exe resolution, stdin prompt piping, --append-system-prompt-file,
--model). Both were patched for this fix, but source and deployed should be reconciled.
