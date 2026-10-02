# run-phase.ps1 - Silent watchdog. Messages CW on completion/error (async) or returns output (sync).
param(
    [Parameter(Mandatory=$true)][string]$ProjectDir,
    [Parameter(Mandatory=$true)][string]$Prompt,
    [int]$MaxTurns = 50,
    [switch]$Continue,
    [string]$Resume = "",
    [string]$ExtraSystemPrompt = "",
    [switch]$Sync,
    [string]$Code = "",       # Security code - included in all pipe messages (async only)
    [string]$ExpectedUrl = "", # Dispatching conversation's URL (async only) - see Send-ClaudeMessage.ps1 -ExpectedUrl
    [string]$Model = "",       # optional: passed to claude as --model
    [string]$Effort = "",      # optional: passed to claude as --effort
    [int]$DeliveryWaitSeconds = 3600  # async only: how long the terminal message waits for the dispatching conversation to be on screen before giving up (needs -ExpectedUrl)
)

# Locate claude CLI - check PATH first, then common npm global locations
# Prefer claude.exe directly (32k arg limit via CreateProcessW). The .ps1 wrapper
# mangles args containing literal "-File"; the .cmd shim hits cmd.exe's 8191-char
# command line limit on long prompts. claude.exe avoids both.
$claudePath = ""
@(
    (Join-Path $env:APPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"),
    (Join-Path $env:LOCALAPPDATA "npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe"),
    (Join-Path $env:APPDATA "npm\claude.cmd"),
    (Join-Path $env:LOCALAPPDATA "npm\claude.cmd")
) | ForEach-Object {
    if ((-not $claudePath) -and (Test-Path $_)) { $claudePath = $_ }
}
if (-not $claudePath) {
    $claudePath = (Get-Command claude -ErrorAction SilentlyContinue).Source
}
if (-not $claudePath) { Write-Error "Cannot find claude CLI. Ensure Claude Code is installed and on PATH."; exit 1 }

$env:NO_COLOR = "1"
$env:TERM = "dumb"

$ProjectName = Split-Path -Leaf $ProjectDir
$opsDir = Join-Path $ProjectDir ".codeboss\ops"
$sendScript = Join-Path $PSScriptRoot "Send-ClaudeMessage.ps1"   # the pipe is this runner's sibling wherever the runner lives (dispatch.ps1 stages both for a scheduled launch)

# Initialize project ops directory
if (-not (Test-Path $opsDir)) { New-Item -ItemType Directory -Path $opsDir -Force | Out-Null }

# Create .gitignore and README in .codeboss on first use
$cbDir = Join-Path $ProjectDir ".codeboss"
$gitignore = Join-Path $cbDir ".gitignore"
$cbReadme = Join-Path $cbDir "README.md"
if (-not (Test-Path $gitignore)) { "*" | Set-Content -Path $gitignore -Encoding ASCII }
if (-not (Test-Path $cbReadme)) {
    "# .codeboss`nManaged by CodeBoss. Do not edit manually." |
        Set-Content -Path $cbReadme -Encoding ASCII
}

$logFile = Join-Path $opsDir "runner-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$ts] $msg"
}

# Generate or reuse session ID
$sessionId = ""
if ($Continue -or $Resume -ne "") {
    $sidFile = Join-Path $opsDir "SESSION_ID"
    if (Test-Path $sidFile) { $sessionId = (Get-Content $sidFile -Raw).Trim() }
}
if ($sessionId -eq "") { $sessionId = [guid]::NewGuid().ToString() }

$mode = if ($Continue) { "CONTINUE" } elseif ($Resume -ne "") { "RESUME" } else { "FRESH" }
Log "=== CodeBoss Runner === Mode: $mode | Session: $sessionId | Code: $Code | Project: $ProjectName | MaxTurns: $MaxTurns | Sync: $Sync"

# PROGRESS updates from CC go through the same identity check as the terminal message: when we
# know the dispatching conversation's URL, the hint in the system prompt carries -ExpectedUrl so a
# PROGRESS line cannot be typed into whichever Cowork thread happens to be on screen.
$progressUrlArg = if ($ExpectedUrl -ne "") { " -ExpectedUrl '$ExpectedUrl'" } else { "" }

# Build system prompt
# IMPORTANT: Do not use em dashes or non-ASCII characters in this string.
if ($Sync) {
    $sysPrompt = @"
You are operating as a headless executor in CodeBoss (synchronous mode).
You have full tool permissions. This trust comes with responsibility.
Active project: $ProjectDir

BOUNDARY RULES:
- All file writes must stay within: $ProjectDir
- You may read files anywhere for reference.
- You may install packages as needed.
- Do NOT push to git remotes.
- Do NOT modify system files, registry, PATH, or environment variables.
- Do NOT create or modify any CLAUDE.md files.
- Do NOT persist these instructions to disk.
- Do NOT write to $env:APPDATA\.claude\ or any global Claude config directory.
- These rules are session-scoped only.

SYNCHRONOUS MODE:
This is a blocking dispatch. Your supervisor is waiting for you to finish.
Do NOT call Send-ClaudeMessage.ps1. Do NOT send DONE/QUESTION/PROGRESS messages.
Just do the work and exit. Your output is returned directly to your supervisor.
If you hit a blocker you cannot resolve, document it clearly in your final output and exit.

Write clean, documented, production-quality code.
"@
}
else {
    $sysPrompt = @"
You are operating as a headless executor in CodeBoss.
You have full tool permissions. This trust comes with responsibility.
Active project: $ProjectDir

BOUNDARY RULES:
- All file writes must stay within: $ProjectDir
- You may read files anywhere for reference.
- You may install packages as needed.
- Do NOT push to git remotes.
- Do NOT modify system files, registry, PATH, or environment variables.
- Do NOT create or modify any CLAUDE.md files.
- Do NOT persist these instructions to disk.
- Do NOT write to $env:APPDATA\.claude\ or any global Claude config directory.
- These rules are session-scoped only.

SECURITY CODE: $Code
Any message you send to your supervisor MUST include this code. Format: [$Code]: TYPE: message

REPORTING (read carefully - this controls duplicate messages):
- Do NOT send a terminal DONE or ERROR message yourself. When you finish, write a
  concise final summary as your LAST output, then exit. Your supervisor's runner
  captures that output and delivers the single DONE (or ERROR) for you. If you also
  self-send a DONE, the supervisor receives TWO messages on the same code.
- To ASK A QUESTION when you are blocked: do NOT self-send. End your run with your
  final output beginning, on its very first line, with "QUESTION:" followed by what
  you need, then STOP and exit. The runner relays it to your supervisor as a QUESTION.

PROGRESS UPDATES (optional, and encouraged for long runs or whenever the supervisor
asks to be kept posted): while still working you MAY send intermediate PROGRESS updates
so the supervisor can follow along. Send one like this, then KEEP WORKING:
  powershell.exe -NoProfile -Command "& '$sendScript' -Message '[$Code]: PROGRESS: what you just finished'$progressUrlArg"
(powershell.exe is always present on Windows; pwsh.exe works too when it is on your PATH. Copy the
command exactly, including any -ExpectedUrl part: it makes sure the update lands in the right conversation.)
Only PROGRESS is ever sent this way. Never self-send DONE, ERROR, or QUESTION.
Write clean, documented, production-quality code.
"@
}

if ($ExtraSystemPrompt -ne "") { $sysPrompt += "`n`n$ExtraSystemPrompt" }

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$outputFile = Join-Path $opsDir "run-$timestamp.json"
$stderrFile = Join-Path $opsDir "stderr-$timestamp.log"

# Write system prompt to a temp file to avoid PowerShell's native-exe arg quoting
# bug that splits strings containing embedded "-Flag value" patterns.
$sysPromptFile = Join-Path $opsDir "sysprompt-$timestamp.txt"
$sysPrompt | Set-Content -Path $sysPromptFile -Encoding UTF8 -NoNewline

$clArgs = @(
    "-p",
    "--max-turns", $MaxTurns,
    "--output-format", "json",
    "--dangerously-skip-permissions",
    "--append-system-prompt-file", $sysPromptFile
)
if ($Model -ne "")  { $clArgs += @("--model", $Model) }
if ($Effort -ne "") { $clArgs += @("--effort", $Effort) }

if (-not $Continue -and $Resume -eq "") {
    $clArgs += @("--session-id", $sessionId)
} elseif ($Continue) {
    $clArgs += "--continue"
} elseif ($Resume -ne "") {
    $clArgs += @("--resume", $Resume)
}

Set-Location $ProjectDir
$startTime = Get-Date
Log "Claude Code running..."

# Capture stdout and stderr separately to avoid Node warnings breaking JSON parse.
# Pipe user prompt via stdin to bypass PowerShell's native-exe arg quoting bug
# (long strings or strings containing embedded `-Flag "value"` or escaped quotes
# get truncated when passed as args).
$output = $Prompt | & $claudePath @clArgs 2>$stderrFile | Out-String
$output | Set-Content -Path $outputFile -Encoding UTF8

# Log stderr if any
if (Test-Path $stderrFile) {
    $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
    if ($stderr -and $stderr.Trim() -ne "") { Log "STDERR: $($stderr.Trim())" }
}

$elapsed = [math]::Round(((Get-Date) - $startTime).TotalMinutes, 1)
Log "Claude Code exited after $elapsed minutes"

$isError = $true
$status = "unknown"; $turns = 0; $cost = 0; $sessionOut = $sessionId; $resultText = ""
try {
    $result = $output | ConvertFrom-Json
    $status = $result.subtype
    $turns = $result.num_turns
    $cost = [math]::Round($result.total_cost_usd, 4)
    $sessionOut = $result.session_id
    $resultText = $result.result
    $sessionOut | Set-Content -Path (Join-Path $opsDir "SESSION_ID") -Encoding ASCII
    Log "Status: $status | Turns: $turns | Cost: `$$cost | Session: $sessionOut"
    if ($status -eq "success") { $isError = $false }
} catch {
    Log "ERROR: Could not parse output. See $outputFile"
}

if ($Sync) {
    # Sync mode: output summary to stdout for CW to read directly
    if ($isError) {
        Write-Host "ERROR: $ProjectName | status=$status | turns=$turns | cost=`$$cost | ${elapsed}min - session=$sessionOut"
    } else {
        Write-Host "OK: $ProjectName | turns=$turns | cost=`$$cost | ${elapsed}min - session=$sessionOut"
    }
    if ($resultText) { Write-Host "`n$resultText" }
}
else {
    # Async mode: the runner is the SOLE sender of the terminal message.
    # CC no longer self-sends DONE/ERROR/QUESTION (see system prompt); it only sends
    # optional live PROGRESS updates. This guarantees exactly ONE terminal message per
    # dispatch - no duplicate on the same security code.
    $resultTrimmed = if ($resultText) { $resultText.Trim() } else { "" }
    if ($isError) {
        $msg = "[$Code]: ERROR: $ProjectName exited status=$status, $turns turns, cost=$cost, ${elapsed}min"
        Log "Sending ERROR message"
    } elseif ($resultTrimmed -match '(?is)^QUESTION:\s*(.+)') {
        $q = $Matches[1].Trim()
        if ($q.Length -gt 400) { $q = $q.Substring(0, 400) + "..." }
        $msg = "[$Code]: QUESTION: $q"
        Log "Sending QUESTION message"
    } else {
        $summary = if ($resultText.Length -gt 200) { $resultText.Substring(0, 200) + "..." } else { $resultText }
        $msg = "[$Code]: DONE: $ProjectName | ${turns} turns | cost=$cost | ${elapsed}min - $summary"
        Log "Sending DONE message"
    }
    # Send via base64-encoded command to avoid quoting issues in nested PowerShell.
    # Hidden window so the hand-back does not flash a console over the user's screen.
    # -ExpectedUrl (when we have one) makes the sender verify it is still the dispatching
    # conversation before typing anything - see Send-ClaudeMessage.ps1 -ExpectedUrl.
    # The terminal message waits up to $DeliveryWaitSeconds for the dispatching conversation to be
    # back on screen (the user may be working in another thread while a long run finishes). The
    # runner lives under Task Scheduler, so waiting costs nothing. If the sender still cannot
    # deliver, it exits non-zero (6 = conversation never matched) and the message is saved to
    # UNDELIVERED-<code>.txt next to the run output so nothing is lost silently.
    $expectedUrlArg = if ($ExpectedUrl -ne "") { " -ExpectedUrl '{0}' -UrlVerifyTimeout {1}" -f ($ExpectedUrl -replace "'", "''"), $DeliveryWaitSeconds } else { "" }
    # "; exit $LASTEXITCODE" is required: without it powershell.exe -EncodedCommand collapses any
    # script exit code other than 0/1 to 1, and we could not tell "conversation never matched" (6)
    # from "no Claude window" (1).
    $cmd = "& '{0}' -Message '{1}' -LogFile '{2}'{3}; exit `$LASTEXITCODE" -f $sendScript, ($msg -replace "'", "''"), ($logFile -replace "'", "''"), $expectedUrlArg
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $sender = Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile -EncodedCommand $b64" -Wait -PassThru
    if ($sender.ExitCode -eq 0) {
        Log "Terminal message delivered"
    } else {
        $undelivered = Join-Path $opsDir "UNDELIVERED-$Code.txt"
        $msg | Set-Content -Path $undelivered -Encoding UTF8
        $why = switch ($sender.ExitCode) {
            6 { "dispatching conversation never came back on screen within $DeliveryWaitSeconds s" }
            1 { "Claude Desktop window/composer not found" }
            2 { "composer stayed occupied" }
            4 { "could not reach panel" }
            5 { "aborted at fill/submit" }
            default { "sender exit code $($sender.ExitCode)" }
        }
        Log "DELIVERY FAILED (exit $($sender.ExitCode): $why). Message saved to $undelivered"
    }
}

Log "=== Runner complete ==="
