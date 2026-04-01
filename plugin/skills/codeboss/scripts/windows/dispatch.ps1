# dispatch.ps1 - Launches Claude Code via run-phase.ps1 (async or sync)
# Scripts must be installed at %APPDATA%\codeboss\ before use.
param(
    [Parameter(Mandatory=$true)][string]$ProjectDir,
    [Parameter(Mandatory=$true)][string]$Prompt,
    [int]$MaxTurns = 50,
    [switch]$Continue,
    [string]$Resume = "",
    [string]$ExtraSystemPrompt = "",
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

    & $runner @runArgs
}
else {
    # --- Async: fire-and-forget in hidden window ---
    # Generate security code (6-char hex) for pipe authentication
    $Code = -join ((1..6) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })

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

    if ($ExtraSystemPrompt -ne "") {
        $sysFile = Join-Path $scriptsDir ".sysprompt-temp-$ts.txt"
        $ExtraSystemPrompt | Set-Content -Path $sysFile -Encoding UTF8
        $cmdParts += "-ExtraSystemPrompt (Get-Content -Path '$sysFile' -Raw)"
    }

    $cmdParts += "; Remove-Item -Path '$promptFile' -ErrorAction SilentlyContinue"
    $argString = "-NoProfile -ExecutionPolicy Bypass -Command `"& { $($cmdParts -join ' ') }`""

    Start-Process powershell -WindowStyle Hidden -ArgumentList $argString

    $mode = if ($Continue) { "CONTINUE" } elseif ($Resume -ne "") { "RESUME" } else { "NEW" }
    Write-Host "Dispatched [$mode]: Project=$ProjectName, MaxTurns=$MaxTurns, Code=$Code"
}