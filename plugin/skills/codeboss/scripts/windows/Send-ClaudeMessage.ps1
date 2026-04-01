# Send-ClaudeMessage.ps1 - Sends a message to Claude Desktop via UI Automation
# Includes text-box detection: checks if input already has text before sending
param(
    [Parameter(Mandatory=$true)][string]$Message,
    [switch]$NewChat,
    [switch]$NoSend,
    [switch]$Quiet,
    [int]$Delay = 5,          # seconds to wait before sending (lets CW finish inference)
    [int]$MaxRetries = 6,     # max retries if text box is occupied (5s between retries = 30s max wait)
    [int]$RetryDelay = 5,     # seconds between retries when text box is occupied
    [string]$LogFile = ""
)

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [Send-ClaudeMessage] $msg"
    if (-not $Quiet) { Write-Host $line }
    if ($LogFile -ne "") { Add-Content -Path $LogFile -Value $line }
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Msg {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    public static void RestoreWindow(IntPtr h) { ShowWindow(h, 9); }
    public static void HideConsole() { IntPtr c = GetConsoleWindow(); if (c != IntPtr.Zero) ShowWindow(c, 0); }
}
"@

function Find-ClaudeInput {
    $uiaRoot = [System.Windows.Automation.AutomationElement]::RootElement
    $proc = Get-Process -Name "claude" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -ne "" } | Select-Object -First 1
    if (-not $proc) { Log "ERROR: No Claude Desktop found"; return $null }
    Log "Claude PID=$($proc.Id)"

    $win = $uiaRoot.FindFirst(
        [System.Windows.Automation.TreeScope]::Children,
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id))
    )
    if (-not $win) { Log "ERROR: Window not in automation tree"; return $null }

    foreach ($type in @([System.Windows.Automation.ControlType]::Edit,
                        [System.Windows.Automation.ControlType]::Document)) {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $type)
        $els = $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        foreach ($el in $els) {
            if ($el.Current.IsEnabled -and $el.Current.IsKeyboardFocusable) {
                Log "Found input: $($el.Current.ControlType.ProgrammaticName)"
                return @{ Element = $el; Window = $win; Process = $proc }
            }
        }
    }
    Log "ERROR: No input element found"; return $null
}

function Get-InputText($Info) {
    # Try to read current text in the input field
    try {
        $vp = $Info.Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($vp) {
            $current = $vp.Current.Value
            return $current
        }
    } catch {}

    # Fallback: try TextPattern
    try {
        $tp = $Info.Element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        if ($tp) {
            $range = $tp.DocumentRange
            $text = $range.GetText(-1)
            return $text
        }
    } catch {}

    return $null  # Could not read - unknown state
}

function Send-Message($Text, $Info, [bool]$PressEnter) {
    [Win32Msg]::SetForegroundWindow($Info.Process.MainWindowHandle)
    [Win32Msg]::RestoreWindow($Info.Process.MainWindowHandle)
    Start-Sleep -Milliseconds 500

    # Always focus the element first
    try { $Info.Element.SetFocus(); Start-Sleep -Milliseconds 300 } catch {
        Log "SetFocus failed, relying on foreground window"
    }

    $set = $false
    try {
        $vp = $Info.Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($vp) { $vp.SetValue($Text); $set = $true; Log "Set via ValuePattern" }
    } catch { Log "ValuePattern unavailable" }

    if (-not $set) {
        [System.Windows.Forms.Clipboard]::SetText($Text)
        Start-Sleep -Milliseconds 200
        [System.Windows.Forms.SendKeys]::SendWait("^v")
        Start-Sleep -Milliseconds 300
    }

    if ($PressEnter) {
        # Re-focus and bring to front before sending Enter
        [Win32Msg]::SetForegroundWindow($Info.Process.MainWindowHandle)
        Start-Sleep -Milliseconds 200
        try { $Info.Element.SetFocus(); Start-Sleep -Milliseconds 300 } catch {}
        [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
        Log "Enter sent"
    }
}

# === Main ===
Log "Delay: ${Delay}s | Message: $($Message.Substring(0, [Math]::Min(80, $Message.Length)))"

if ($Delay -gt 0) {
    Log "Waiting ${Delay}s for CW to finish inference..."
    Start-Sleep -Seconds $Delay
}

$info = Find-ClaudeInput
if (-not $info) { exit 1 }

if ($NewChat) {
    [Win32Msg]::RestoreWindow($info.Process.MainWindowHandle)
    [Win32Msg]::SetForegroundWindow($info.Process.MainWindowHandle)
    Start-Sleep -Milliseconds 500
    [System.Windows.Forms.SendKeys]::SendWait("^n")
    Start-Sleep -Seconds 2
    $info = Find-ClaudeInput
    if (-not $info) { exit 1 }
}

# --- Text-box detection: check if input already has content ---
$retries = 0
while ($retries -lt $MaxRetries) {
    $existingText = Get-InputText $info
    if ($null -eq $existingText) {
        Log "WARNING: Could not read input field text - proceeding anyway"
        break
    }
    if ($existingText.Trim() -eq "" -or $existingText.Trim() -match "^(Reply\.\.\.|Type a message|Message\.\.\.?)$") {
        Log "Input field is clear (empty or placeholder) - safe to send"
        break
    }
    # Text detected in the field
    $retries++
    $preview = $existingText.Substring(0, [Math]::Min(60, $existingText.Length))
    Log "WARNING: Text already in input field (attempt $retries/$MaxRetries): '$preview'"
    if ($retries -ge $MaxRetries) {
        Log "ERROR: Input field still occupied after $MaxRetries retries. Aborting send to avoid clobbering."
        exit 2
    }
    Log "Waiting ${RetryDelay}s before retry..."
    Start-Sleep -Seconds $RetryDelay
    # Re-find input in case UI changed
    $info = Find-ClaudeInput
    if (-not $info) { exit 1 }
}

Send-Message $Message $info (-not $NoSend)
[Win32Msg]::HideConsole()
Log "Done"
exit 0