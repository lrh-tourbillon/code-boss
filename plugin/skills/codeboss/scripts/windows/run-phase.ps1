# run-phase.ps1 - Silent watchdog. Messages CW on completion/error (async) or returns output (sync).
param(
    [Parameter(Mandatory=$true)][string]$ProjectDir,
    [Parameter(Mandatory=$true)][string]$Prompt,
    [int]$MaxTurns = 50,
    [switch]$Continue,
    [string]$Resume = "",
    [string]$ExtraSystemPrompt = "",
    [switch]$Sync,
    [string]$Code = ""   # Security code - included in all pipe messages (async only)
)

# Locate claude CLI - check PATH first, then common npm global locations
$claudePath = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $claudePath) {
    @(
        (Join-Path $env:APPDATA "npm\claude.cmd"),
        (Join-Path $env:LOCALAPPDATA "npm\claude.cmd")
    ) | ForEach-Object {
        if ((-not $claudePath) -and (Test-Path $_)) { $claudePath = $_ }
    }
}
if (-not $claudePath) { Write-Error "Cannot find claude CLI. Ensure Claude Code is installed and on PATH."; exit 1 }

$env:NO_COLOR = "1"
$env:TERM = "dumb"

$ProjectName = Split-Path -Leaf $ProjectDir
$opsDir = Join-Path $ProjectDir ".codeboss\ops"
$sendScript = Join-Path $env:APPDATA "codeboss\Send-ClaudeMessage.ps1"

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
All messages to your supervisor MUST include this code. Format: [$Code]: TYPE: message

COMMUNICATION:
You can message your supervisor (Cowork) at any time:
  powershell -File "$sendScript" -Message "[$Code]: YOUR MESSAGE"

Message types:
- DONE: "[$Code]: DONE: summary of what you built"
- QUESTION: "[$Code]: QUESTION: what you need" - then STOP and exit
- PROGRESS: "[$Code]: PROGRESS: what you finished" - keep working

You MUST send a DONE message when you finish. This is how your supervisor knows.
Write clean, documented, production-quality code.
"@
}

if ($ExtraSystemPrompt -ne "") { $sysPrompt += "`n`n$ExtraSystemPrompt" }

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$outputFile = Join-Path $opsDir "run-$timestamp.json"
$stderrFile = Join-Path $opsDir "stderr-$timestamp.log"

$clArgs = @(
    "-p", $Prompt,
    "--max-turns", $MaxTurns,
    "--output-format", "json",
    "--dangerously-skip-permissions",
    "--append-system-prompt", $sysPrompt
)

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

# Capture stdout and stderr separately to avoid Node warnings breaking JSON parse
$output = & $claudePath @clArgs 2>$stderrFile | Out-String
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
    # Async mode: runner sends DONE on success, ERROR on failure
    # Safety net - CC should also send DONE, but runner catches the case where it forgets
    if ($isError) {
        $msg = "[$Code]: ERROR: $ProjectName exited status=$status, $turns turns, cost=$cost, ${elapsed}min"
        Log "Sending error alert"
    } else {
        $summary = if ($resultText.Length -gt 200) { $resultText.Substring(0, 200) + "..." } else { $resultText }
        $msg = "[$Code]: DONE: $ProjectName | ${turns} turns | cost=$cost | ${elapsed}min - $summary"
        Log "Sending DONE message"
    }
    # Send via base64-encoded command to avoid quoting issues in nested PowerShell
    $cmd = "& '{0}' -Message '{1}' -LogFile '{2}'" -f $sendScript, ($msg -replace "'", "''"), ($logFile -replace "'", "''")
    $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    Start-Process powershell -ArgumentList "-NoProfile -EncodedCommand $b64" -Wait
}

Log "=== Runner complete ==="