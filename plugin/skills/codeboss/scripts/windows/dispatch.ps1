# dispatch.ps1 - Launches Claude Code via run-phase.ps1 (async or sync)
# Scripts must be installed at %APPDATA%\codeboss\ before use.
param(
    [Parameter(Mandatory=$true)][string]$ProjectDir,
    [Parameter(Mandatory=$true)][string]$Prompt,
    [int]$MaxTurns = 50,
    [switch]$Continue,
    [string]$Resume = "",
    [string]$ExtraSystemPrompt = "",
    [string]$Model = "",      # optional: claude --model (e.g. claude-fable-5-1, opus[1m])
    [string]$Effort = "",     # optional: claude --effort (low|medium|high|xhigh)
    [switch]$Sync
)

$scriptsDir = Join-Path $env:APPDATA "codeboss"
$runner = Join-Path $scriptsDir "run-phase.ps1"

if (-not (Test-Path $runner)) {
    Write-Error "CodeBoss scripts not found at $scriptsDir. Bootstrap required: deploy scripts from plugin to this directory."
    exit 1
}

$ProjectName = Split-Path -Leaf $ProjectDir

if ($Sync) {
    # --- Synchronous: block until CC finishes, return output directly ---
    # No security code needed - no pipe involved
    $runArgs = @{
        ProjectDir = $ProjectDir
        Prompt     = $Prompt
        MaxTurns   = $MaxTurns
        Sync       = $true
    }
    if ($Continue)                { $runArgs.Continue = $true }
    if ($Resume -ne "")           { $runArgs.Resume = $Resume }
    if ($ExtraSystemPrompt -ne "") { $runArgs.ExtraSystemPrompt = $ExtraSystemPrompt }
    if ($Model -ne "")             { $runArgs.Model = $Model }
    if ($Effort -ne "")            { $runArgs.Effort = $Effort }

    & $runner @runArgs
}
else {
    # --- Async: fire-and-forget in hidden window ---
    # Generate security code (6-char hex) for pipe authentication
    $Code = -join ((1..6) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })

    # Record which Cowork conversation is dispatching this, so the completion message
    # can be verified against it later instead of being typed into whatever conversation
    # happens to be on screen when the run finishes (see run-phase.ps1 -ExpectedUrl and
    # Send-ClaudeMessage.ps1 -ExpectedUrl / -CaptureUrlOnly). Best-effort: if this fails
    # or Claude Desktop is not in a readable state, delivery falls back to the old
    # un-verified behavior rather than blocking the dispatch.
    $sendScript = Join-Path $scriptsDir "Send-ClaudeMessage.ps1"
    $dispatchUrl = ""
    if (Test-Path $sendScript) {
        try { $dispatchUrl = (& $sendScript -CaptureUrlOnly -Quiet 2>$null | Select-Object -Last 1) } catch { $dispatchUrl = "" }
    }
    if (-not $dispatchUrl) { $dispatchUrl = "" }

    $ts = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $promptFile = Join-Path $scriptsDir ".prompt-temp-$ts.txt"
    $Prompt | Set-Content -Path $promptFile -Encoding UTF8

    $cmdParts = @(
        "`$p = Get-Content -Path '$promptFile' -Raw;"
        "& '$runner'"
        "-ProjectDir '$ProjectDir'"
        "-Prompt `$p"
        "-MaxTurns $MaxTurns"
        "-Code '$Code'"
    )

    if ($Continue)      { $cmdParts += "-Continue" }
    if ($Resume -ne "") { $cmdParts += "-Resume '$Resume'" }
    if ($Model -ne "")  { $cmdParts += "-Model '$Model'" }
    if ($Effort -ne "") { $cmdParts += "-Effort '$Effort'" }

    if ($ExtraSystemPrompt -ne "") {
        $sysFile = Join-Path $scriptsDir ".sysprompt-temp-$ts.txt"
        $ExtraSystemPrompt | Set-Content -Path $sysFile -Encoding UTF8
        $cmdParts += "-ExtraSystemPrompt (Get-Content -Path '$sysFile' -Raw)"
    }

    if ($dispatchUrl -ne "") {
        $escapedUrl = $dispatchUrl -replace "'", "''"
        $cmdParts += "-ExpectedUrl '$escapedUrl'"
    }

    $cmdParts += "; Remove-Item -Path '$promptFile' -ErrorAction SilentlyContinue"
    $argString = "-NoProfile -ExecutionPolicy Bypass -Command `"& { $($cmdParts -join ' ') }`""

    Start-Process powershell -WindowStyle Hidden -ArgumentList $argString

    $mode = if ($Continue) { "CONTINUE" } elseif ($Resume -ne "") { "RESUME" } else { "NEW" }
    $urlNote = if ($dispatchUrl -ne "") { " | Watching=$dispatchUrl" } else { " | Watching=(unavailable, will deliver unverified)" }
    $modelNote = if ($Model -ne "" -or $Effort -ne "") { " | Model=$Model Effort=$Effort" } else { "" }
    Write-Host "Dispatched [$mode]: Project=$ProjectName, MaxTurns=$MaxTurns, Code=$Code$urlNote$modelNote"
}
