# In-UI Code Mode (Windows)

An alternative to the headless `claude` CLI dispatch: drive the **Code** tab that is
built into Claude Desktop, in the same window as Cowork. Cowork (the supervisor) drops
a prompt into the Code panel; Code runs interactively; when finished it hands the baton
back to Cowork. This is an *addition* to headless dispatch, not a replacement.

## The window model (probed June 2026, Claude Desktop 1.12603.x)

Claude Desktop hosts three tabs in ONE window: **Chat / Cowork / Code**.

- Switch tabs: **Ctrl+1** (Chat), **Ctrl+2** (Cowork), **Ctrl+3** (Code). Reliable.
- The tab pills (`Button`, class `df-pill`) expose **no** selection/toggle state via UI
  Automation. Do not try to read "active tab" from them.
- The **inactive panel is fully unmounted**. Only the active panel's composer exists in
  the accessibility tree at any moment. So you must switch to a panel *before* you can
  put text in its composer.

## Detecting the active panel

The active panel mounts a `claude.ai` web document whose URL identifies it:

| URL                              | Panel  |
|----------------------------------|--------|
| `https://claude.ai/cowork/...`   | cowork |
| `https://claude.ai/epitaxy/...`  | code   |
| `https://claude.ai/chat/...`     | chat   |

`Get-ClaudePanel.ps1 -Quiet` returns `cowork` | `code` | `chat` | `unknown`.

## The two composers differ (important)

| Panel  | ControlType | Name                         | Patterns                | How to fill        |
|--------|-------------|------------------------------|-------------------------|--------------------|
| Cowork | `Edit`      | `Write your prompt to Claude`| Value + Text + ScrollItem | SetValue or paste |
| Code   | `Group`     | `Prompt`                     | Text + ScrollItem only  | **clipboard paste**|

Both share class `tiptap ProseMirror`, so the finder keys on that class.
The Code composer has **no ValuePattern** - `SetValue` is impossible; you must paste.
Its placeholder ("Type / for commands") is a CSS placeholder, not an accessibility
node, so the occupied-check reads empty there (safe, no clobber risk).

`Send-ClaudeMessage.ps1 -Panel code -Message "..."` switches to Code (if needed),
finds the `Prompt` group, pastes, and presses Enter. Verified end to end: a pasted
prompt submits and Code responds. Use `-DryRun` to test detection/switch/find without
sending. Use `-Panel cowork` for the baton handoff back to the supervisor.

## CRITICAL: Code must run non-interactively and hand the baton back

In the Code panel, **any question or permission menu blocks everything** - the menu
appears and the session stalls waiting for a human. Cowork is not watching the Code
panel, so a blocked Code session just hangs. Therefore every prompt sent to Code MUST
include a non-interactive handoff preamble. Prepend this (or equivalent) to the task:

```
You are running inside the Claude Desktop Code panel, dispatched by the Cowork
supervisor. Operate FULLY NON-INTERACTIVELY:
- NEVER ask the user a question and NEVER wait for input. If you would normally ask
  a clarifying question, instead make a reasonable, clearly-stated assumption and
  proceed. Do not run anything that opens a blocking/interactive prompt or menu.
- BEFORE handing back, ALWAYS write your full result to:
      <ProjectDir>\.codeboss\ops\codeout-<timestamp>.md
  This file is the source of truth and must be written even if the hand-back fails.
- When finished (or if blocked/erroring), hand the baton back to Cowork by running:
      powershell -ExecutionPolicy Bypass -File "%APPDATA%\codeboss\Send-ClaudeMessage.ps1" `
        -Panel cowork -Message "[<CODE>]: DONE: <one-line summary> (full output: <path>)"
  Use DONE on success, ERROR on failure, QUESTION if you are truly blocked (state the
  question AND your best-guess default so the supervisor can answer in one shot).
- Then stop. Do not continue working after handing back.
```

Notes:
- `<CODE>` is the per-dispatch security code (same scheme as headless). The supervisor
  verifies it before acting on the returned message.
- If the hand-back post fails (e.g. focus stolen), the `.codeboss/ops/codeout-*.md`
  file remains. The user can ask the supervisor "are you stuck?" and it reads the
  latest `codeout-*` file for that project.
- The Code session should have edit auto-accept enabled ("Accept edits" in the Code
  composer footer) so tool actions do not raise blocking permission menus. If a task
  needs an action that would prompt, the preamble tells Code to avoid it or assume.

## Flow summary

1. Supervisor (Cowork) builds the task prompt + non-interactive preamble + security code.
2. `Send-ClaudeMessage.ps1 -Panel code -Message "<wrapped prompt>"` -> switches to Code,
   pastes, Enter. Supervisor then goes idle (async).
3. Code runs non-interactively, writes `codeout-<timestamp>.md`, then runs
   `Send-ClaudeMessage.ps1 -Panel cowork -Message "[<CODE>]: DONE: ..."`.
4. The posted message lands in the Cowork composer and wakes the supervisor, which
   verifies the code and relays the result to the user.


## Starting a fresh Code session (-NewSession)

By default a Desktop dispatch reuses whatever Code session is currently open. To force a
FRESH session, pass `-NewSession` (an alias of `-NewChat`):

    & "$env:APPDATA\codeboss\Send-ClaudeMessage.ps1" -Panel code -NewSession -Message $p -Delay 0

It switches to Code, presses **Ctrl+N**, and VERIFIES a new session actually began by
watching the session URL change: a used session is `.../epitaxy/local_<id>`; a fresh one
drops the id. On this build `Invoke()` on the "New session" button no-ops, so the
foreground-confirmed Ctrl+N hotkey is the reliable path. If the session was already fresh
the URL won't change - that's fine, the result is still a clean session. Verified: a seeded
session (`local_da9aa6e8...`) plus `-NewSession` produced a brand-new session
(`local_c2b327e4...`) and the message landed in the new one.
