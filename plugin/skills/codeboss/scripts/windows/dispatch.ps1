# dispatch.ps1 - Launches Claude Code via run-phase.ps1 (async or sync)
# Scripts must be installed at %APPDATA%\codeboss\ before use.
#
# ASYNC LAUNCHER (Windows, since 0.3.0): the runner is started through Task Scheduler, so Claude
# Code and everything it spawns live under the Schedule service - OUTSIDE the Claude desktop app's
# process tree. Under that tree the app's process supervision silently kills long-running children
# (nine of nine full-solution `dotnet test` runs died 20 s - 4 min in, 2026-09-22/23); under Task
# Scheduler two of two completed, and every PROGRESS and the DONE still reached Cowork through
# Send-ClaudeMessage.ps1 (UI Automation works from the interactive session either way).
# -InProcess restores the pre-0.3.0 Start-Process launch under this shell. If the scheduled launch
# cannot be set up, the dispatch falls back to the in-process launch and says so on its output line.
#
# The desktop app is MSIX-packaged: a process started from its tool shell sees a VIRTUALIZED
# %APPDATA% (an overlay under %LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\), while a Task
# Scheduler process sees the PHYSICAL one, and the two can differ silently. So the scheduled launch
# stages the runner and the pipe scripts THIS shell can see into <ProjectDir>\.codeboss\bin\ (never
# virtualized) and runs them from there, and the prompt / system-prompt temp files go under
# <ProjectDir>\.codeboss\ops\ for the same reason. run-phase.ps1 finds Send-ClaudeMessage.ps1 as
# its own sibling ($PSScriptRoot), so the staged copies work as a set.
param(
    [Parameter(Mandatory=$true)][string]$ProjectDir,
    [Parameter(Mandatory=$true)][string]$Prompt,
    [int]$MaxTurns = 50,
    [switch]$Continue,
    [string]$Resume = "",
    [string]$ExtraSystemPrompt = "",
    [string]$Model = "",      # optional: claude --model (e.g. claude-fable-5-1, opus[1m])
    [string]$Effort = "",     # optional: claude --effort (low|medium|high|xhigh)
    [switch]$Sync,
    [switch]$InProcess        # async only: launch under THIS shell with Start-Process (pre-0.3.0 behaviour)
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
    # No security code needed - no pipe involved. Runs in this shell (short tasks only).
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
    # --- Async: fire-and-forget; launched through Task Scheduler unless -InProcess (see header) ---
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
        # The UIA read is occasionally empty on the first try (observed ~1 in 10); an empty result
        # would silently disable the identity check for this whole run, so retry a few times.
        for ($try = 0; $try -lt 4 -and -not $dispatchUrl; $try++) {
            if ($try -gt 0) { Start-Sleep -Milliseconds 400 }
            try { $dispatchUrl = (& $sendScript -CaptureUrlOnly -Quiet 2>$null | Select-Object -Last 1) } catch { $dispatchUrl = "" }
        }
    }
    if (-not $dispatchUrl) { $dispatchUrl = "" }

    # Project-local, unvirtualized working folders (see header).
    $opsDir = Join-Path $ProjectDir ".codeboss\ops"
    $binDir = Join-Path $ProjectDir ".codeboss\bin"
    foreach ($d in @($opsDir, $binDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

    # Stage the runner and the pipe scripts for a scheduled launch.
    $useScheduler = -not $InProcess
    $runnerToUse  = $runner
    $note = ""
    if ($useScheduler) {
        try {
            foreach ($n in 'run-phase.ps1', 'Send-ClaudeMessage.ps1', 'Get-ClaudePanel.ps1') {
                $src = Join-Path $scriptsDir $n
                if (Test-Path $src) { Copy-Item $src (Join-Path $binDir $n) -Force }
            }
            $runnerToUse = Join-Path $binDir "run-phase.ps1"
        } catch {
            $note = " | WARNING: could not stage scripts into $binDir ($($_.Exception.Message)); launched in-process"
            $useScheduler = $false
            $runnerToUse  = $runner
        }
    }

    $ts = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $promptFile = Join-Path $opsDir ".prompt-temp-$ts.txt"
    $Prompt | Set-Content -Path $promptFile -Encoding UTF8

    $cmdParts = @(
        "`$p = Get-Content -Path '$promptFile' -Raw;"
        "& '$runnerToUse'"
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
        $sysFile = Join-Path $opsDir ".sysprompt-temp-$ts.txt"
        $ExtraSystemPrompt | Set-Content -Path $sysFile -Encoding UTF8
        $cmdParts += "-ExtraSystemPrompt (Get-Content -Path '$sysFile' -Raw)"
    }

    if ($dispatchUrl -ne "") {
        $escapedUrl = $dispatchUrl -replace "'", "''"
        $cmdParts += "-ExpectedUrl '$escapedUrl'"
    }

    $cmdParts += "; Remove-Item -Path '$promptFile' -ErrorAction SilentlyContinue"
    $argString = "-NoProfile -ExecutionPolicy Bypass -Command `"& { $($cmdParts -join ' ') }`""

    $t0 = Get-Date
    $launcher = ""
    if ($useScheduler) {
        try {
            # Sweep finished CodeBoss-* tasks from earlier dispatches (State Ready = not running).
            Get-ScheduledTask -TaskName 'CodeBoss-*' -ErrorAction SilentlyContinue |
                Where-Object { $_.State -eq 'Ready' } |
                ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue }

            $taskName  = "CodeBoss-$ProjectName-$Code"
            $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-WindowStyle Hidden $argString" -WorkingDirectory $ProjectDir
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
            $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Days 3) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            $launcher = "TaskScheduler:$taskName"
        } catch {
            $note = " | WARNING: Task Scheduler launch failed ($($_.Exception.Message)); launched in-process"
            $useScheduler = $false
        }
    }
    if (-not $useScheduler) {
        Start-Process powershell -WindowStyle Hidden -ArgumentList $argString
        $launcher = "InProcess"
    }
    else {
        # Confirm the runner started: its runner-*.log appears in <ProjectDir>\.codeboss\ops within seconds.
        $started = $false
        for ($i = 0; $i -lt 30 -and -not $started; $i++) {
            Start-Sleep -Milliseconds 500
            $started = [bool](Get-ChildItem $opsDir -Filter 'runner-*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $t0 })
        }
        if (-not $started) {
            # Tell a slow start (task still Running: PowerShell/claude coming up on a loaded box) apart
            # from a launch that never ran or already died (task back to Ready). Unregistering a
            # Running task kills the live run, and a re-dispatch on top of it doubles the work.
            $tState = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
            $tInfo  = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            $tResult = if ($tInfo) { '0x{0:X}' -f [uint32]$tInfo.LastTaskResult } else { '?' }
            if ($tState -eq 'Running') {
                $note = " | NOTE: task is Running but no runner log yet after 15 s (slow start) - check $opsDir\runner-*.log in a minute; do NOT unregister or re-dispatch"
            } else {
                $note = " | WARNING: task $launcher is '$tState' (LastTaskResult=$tResult) and no runner log appeared within 15 s - the scheduled launch did not run; Unregister-ScheduledTask it and re-dispatch with -InProcess"
            }
        }
    }

    $mode = if ($Continue) { "CONTINUE" } elseif ($Resume -ne "") { "RESUME" } else { "NEW" }
    $urlNote = if ($dispatchUrl -ne "") { " | Watching=$dispatchUrl" } else { " | Watching=(unavailable, will deliver unverified)" }
    $modelNote = if ($Model -ne "" -or $Effort -ne "") { " | Model=$Model Effort=$Effort" } else { "" }
    Write-Host "Dispatched [$mode]: Project=$ProjectName, MaxTurns=$MaxTurns, Code=$Code$urlNote$modelNote | Launcher=$launcher$note"
}
