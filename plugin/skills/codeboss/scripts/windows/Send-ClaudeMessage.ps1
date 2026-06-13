# Send-ClaudeMessage.ps1 - Sends a message to a Claude Desktop panel via UI Automation.
#
# DESIGN (why UIA, not SendKeys): SendKeys/{ENTER} go to whatever window is FOREGROUND,
# so if Claude is not in front the keystrokes leak into the user's other app (e.g. SSMS) -
# an injected Enter could run a query. UI Automation patterns instead target a specific
# element regardless of focus, and work on background windows. So the primary path uses:
#   - InvokePattern on the tab button  -> switch panels (no Ctrl+2/3 keystroke)
#   - ValuePattern.SetValue            -> fill the composer (no typing)
#   - InvokePattern on the Send button -> submit (no {ENTER})
# Nothing is ever sent to the foreground window, so nothing can leak. SendKeys is used
# ONLY as a last-resort fallback and ONLY after confirming Claude is foreground.
#
# Panels: Chat / Cowork / Code in one window. Cowork composer = Edit (ValuePattern).
# Code composer = Group 'Prompt' (NO ValuePattern -> needs clipboard paste, which is a
# keystroke and therefore foreground-guarded). Active panel = mounted claude.ai web-doc URL.
# Tab buttons are matched by NAME (their AutomationIds are regenerated each session).
# ASCII only.
param(
    [Parameter(Mandatory=$true)][string]$Message,
    [ValidateSet("active","cowork","code","chat")][string]$Panel = "active",
    [switch]$NewChat,
    [switch]$NoSend,
    [switch]$DryRun,
    [switch]$Quiet,
    [int]$Delay = 5,
    [int]$MaxRetries = 6,
    [int]$RetryDelay = 5,
    [int]$SwitchTimeout = 6,
    [int]$FgTries = 8,
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

# Robust foreground - used ONLY for the keystroke fallback paths (Code paste, Enter fallback).
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinFg {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint act, uint p, IntPtr v, uint w);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    const int SW_RESTORE = 9; const byte VK_MENU = 0x12; const uint KEYUP = 0x2;
    const uint SPI_SETFGLOCK = 0x2001; const uint SPIF_SEND = 0x2;
    public static IntPtr Fg() { return GetForegroundWindow(); }
    public static bool IsFg(IntPtr h) { return GetForegroundWindow() == h; }
    public static void HideConsole() { IntPtr c = GetConsoleWindow(); if (c != IntPtr.Zero) ShowWindow(c, 0); }
    public static bool Force(IntPtr h) {
        if (h == IntPtr.Zero) return false;
        try { SystemParametersInfo(SPI_SETFGLOCK, 0, IntPtr.Zero, SPIF_SEND); } catch {}
        keybd_event(VK_MENU, 0, 0, UIntPtr.Zero); keybd_event(VK_MENU, 0, KEYUP, UIntPtr.Zero);
        ShowWindow(h, SW_RESTORE);
        uint pid; uint ft = GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        uint tt = GetWindowThreadProcessId(h, out pid); uint me = GetCurrentThreadId();
        bool a1=false,a2=false;
        if (ft!=0 && ft!=me) a1=AttachThreadInput(me,ft,true);
        if (tt!=0 && tt!=me && tt!=ft) a2=AttachThreadInput(me,tt,true);
        BringWindowToTop(h); SetForegroundWindow(h);
        if (a1) AttachThreadInput(me,ft,false);
        if (a2) AttachThreadInput(me,tt,false);
        return GetForegroundWindow()==h;
    }
}
"@

# --- helpers ---------------------------------------------------------------

function Get-ClaudeWindow {
    $proc = Get-Process -Name "claude" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -ne "" } | Select-Object -First 1
    if (-not $proc) { return $null }
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children,
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $proc.Id)))
    if (-not $win) { return $null }
    return @{ Process = $proc; Window = $win }
}

function Confirm-Foreground($info) {
    $h = $info.Process.MainWindowHandle
    for ($i = 0; $i -lt $FgTries; $i++) { if ([WinFg]::Force($h)) { return $true }; Start-Sleep -Milliseconds 250 }
    return [WinFg]::IsFg($h)
}

function Supports($el, $patternName) {
    foreach ($p in $el.GetSupportedPatterns()) { if ($p.ProgrammaticName -like "*$patternName*") { return $true } }
    return $false
}

function Invoke-El($el) {
    try { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); return $true } catch { return $false }
}

function Get-ActivePanel($win) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Document)
    foreach ($d in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
        try {
            $v = $d.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
            if ($v -like 'https://claude.ai/*') {
                if     ($v -match '://claude\.ai/cowork')  { return "cowork" }
                elseif ($v -match '://claude\.ai/epitaxy') { return "code" }
                elseif ($v -match '://claude\.ai/chat')    { return "chat" }
                else                                       { return "chat" }
            }
        } catch {}
    }
    return "unknown"
}

function Find-TabButton($win, $panel) {
    $label = switch ($panel) { "chat" {"Chat"} "cowork" {"Cowork"} "code" {"Code"} default {""} }
    if ($label -eq "") { return $null }
    $bc = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    foreach ($b in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) {
        if ($b.Current.Name -eq $label -and $b.Current.ClassName -match 'df-pill') { return $b }
    }
    foreach ($b in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) {
        if ($b.Current.Name -eq $label) { return $b }
    }
    return $null
}

function Switch-ToPanel($info, $target) {
    if ((Get-ActivePanel $info.Window) -eq $target) { Log "Already on '$target'"; return $true }
    # Primary: Invoke the tab button (no keystroke, works backgrounded).
    $btn = Find-TabButton $info.Window $target
    if ($btn -and (Supports $btn "Invoke")) {
        Log "Switching to '$target' via Invoke on tab button"
        Invoke-El $btn | Out-Null
    } else {
        # Fallback: hotkey, but only if we can confirm foreground.
        $key = switch ($target) { "chat" {"^1"} "cowork" {"^2"} "code" {"^3"} default {""} }
        if ($key -eq "" -or -not (Confirm-Foreground $info)) { Log "ABORT: cannot switch to '$target' (no Invoke, no foreground)"; return $false }
        Log "Switching to '$target' via hotkey fallback ($key)"
        [System.Windows.Forms.SendKeys]::SendWait($key)
    }
    $deadline = (Get-Date).AddSeconds($SwitchTimeout)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 350
        if ((Get-ActivePanel $info.Window) -eq $target) { Log "Now on '$target'"; return $true }
    }
    Log "WARNING: panel did not switch to '$target' within ${SwitchTimeout}s"
    return $false
}

function Find-Composer($win) {
    $fc = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::IsKeyboardFocusableProperty, $true)
    foreach ($el in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $fc)) {
        if ($el.Current.ClassName -match 'ProseMirror' -or $el.Current.Name -eq 'Prompt') { return $el }
    }
    foreach ($type in @([System.Windows.Automation.ControlType]::Edit, [System.Windows.Automation.ControlType]::Document)) {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty, $type)
        foreach ($el in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
            if ($el.Current.IsEnabled -and $el.Current.IsKeyboardFocusable) { return $el }
        }
    }
    return $null
}

function Find-SendButton($win) {
    $bc = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    foreach ($b in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) {
        $n = $b.Current.Name
        if ($n -match '(?i)^(send|queue) message$' -and $b.Current.IsEnabled) { return $b }
    }
    foreach ($b in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) {
        $n = $b.Current.Name
        if ($n -match '(?i)\b(send|submit)\b' -and $b.Current.IsEnabled) { return $b }
    }
    return $null
}

function Has-ValuePattern($el) {
    try { return ($null -ne $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)) } catch { return $false }
}

function Get-InputText($el) {
    try { $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); if ($vp) { return $vp.Current.Value } } catch {}
    try { $tp = $el.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern); if ($tp) { return $tp.DocumentRange.GetText(-1) } } catch {}
    return $null
}

# Fill the composer. Returns $true on success. Uses SetValue (no focus) when possible;
# falls back to clipboard paste (keystroke) ONLY with confirmed foreground.
function Set-ComposerText($info, $el, $text) {
    if (Has-ValuePattern $el) {
        try {
            $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
            if (-not $vp.Current.IsReadOnly) { $vp.SetValue($text); Log "Filled composer via ValuePattern (no focus needed)"; return $true }
        } catch { Log "ValuePattern.SetValue failed: $_" }
    }
    # No ValuePattern (Code composer): must paste -> requires foreground.
    if (-not (Confirm-Foreground $info)) { Log "ABORT: composer has no ValuePattern and Claude not foreground; refusing keystroke paste"; return $false }
    try { $el.SetFocus(); Start-Sleep -Milliseconds 250 } catch {}
    [System.Windows.Forms.Clipboard]::SetText($text); Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait("^v"); Start-Sleep -Milliseconds 300
    Log "Filled composer via clipboard paste (foreground-confirmed)"
    return $true
}

# Submit. Returns $true on success. Invoke the Send button (no keystroke); fall back to
# {ENTER} ONLY with confirmed foreground.
function Submit-Composer($info, $el) {
    # Retry: after an Invoke tab-switch the footer (Send button) can render a beat late.
    $btn = $null
    for ($i=0; $i -lt 12; $i++) { $btn = Find-SendButton $info.Window; if ($btn) { break }; Start-Sleep -Milliseconds 350 }
    if ($btn) {
        Log "Submitting via Invoke on '$($btn.Current.Name)' button"
        if (Invoke-El $btn) { return $true }
        Log "Invoke on send button failed; trying keystroke fallback"
    } else { Log "No send button found; trying keystroke fallback" }
    if (-not (Confirm-Foreground $info)) { Log "ABORT: cannot submit (no send button, Claude not foreground). Message left in composer / use fallback file."; return $false }
    try { $el.SetFocus(); Start-Sleep -Milliseconds 200 } catch {}
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Log "Submitted via {ENTER} (foreground-confirmed)"
    return $true
}

# === Main ===
Log "Panel: $Panel | Delay: ${Delay}s | Message: $($Message.Substring(0, [Math]::Min(80, $Message.Length)))"
$info = Get-ClaudeWindow
if (-not $info) { Log "ERROR: No Claude Desktop found"; exit 1 }
$origPanel = Get-ActivePanel $info.Window
Log "Active panel on entry: $origPanel | foreground-is-claude=$([WinFg]::IsFg($info.Process.MainWindowHandle))"

if ($Panel -ne "active") {
    if (-not (Switch-ToPanel $info $Panel)) { Log "ERROR: could not reach panel '$Panel' - aborting"; exit 4 }
}

if ($Delay -gt 0 -and -not $DryRun) { Log "Waiting ${Delay}s..."; Start-Sleep -Seconds $Delay }

if ($NewChat -and -not $DryRun) {
    $nb = $null
    $bc = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    foreach ($b in $info.Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) {
        if ($b.Current.Name -match '(?i)^new (task|session|chat)$') { $nb = $b; break }
    }
    if ($nb -and (Invoke-El $nb)) { Log "New chat via Invoke '$($nb.Current.Name)'"; Start-Sleep -Seconds 2 }
    elseif (Confirm-Foreground $info) { [System.Windows.Forms.SendKeys]::SendWait("^n"); Start-Sleep -Seconds 2 }
}

$el = Find-Composer $info.Window
if (-not $el) { Log "ERROR: No composer found"; exit 1 }
$ec = $el.Current
Log "Composer: ct=$($ec.ControlType.ProgrammaticName -replace 'ControlType.','') name='$($ec.Name)' cls='$($ec.ClassName)' valuePattern=$(Has-ValuePattern $el)"

if ($DryRun) {
    Log "DryRun: not filling or submitting."
    if ($Panel -ne "active" -and $origPanel -ne "unknown" -and $origPanel -ne $Panel) { Switch-ToPanel $info $origPanel | Out-Null }
    Log "Done (dry run)"; exit 0
}

# Occupied check (only meaningful when readable, i.e. Cowork Edit).
$ellipsis = [char]0x2026
$retries = 0
while ($retries -lt $MaxRetries) {
    $existing = Get-InputText $el
    if ($null -eq $existing) { Log "Input text unreadable (Code composer) - proceeding"; break }
    $trimmed = $existing.Trim()
    $isPlaceholder = $trimmed -eq "" -or
                     $trimmed -match "^(Reply\.\.\.|Type a message|Message\.\.\.?|Type / for commands)$" -or
                     $trimmed -match ("^Write a message[" + $ellipsis + "\.\s]*$") -or
                     $trimmed -match ("^Write your prompt to Claude[" + $ellipsis + "\.\s]*$")
    if ($isPlaceholder) { Log "Input field clear - safe to send"; break }
    $retries++
    if ($retries -ge $MaxRetries) { Log "ERROR: Input field occupied after $MaxRetries retries. Aborting."; exit 2 }
    Log "WARNING: text in field (attempt $retries/$MaxRetries): '$($existing.Substring(0,[Math]::Min(60,$existing.Length)))'"
    Start-Sleep -Seconds $RetryDelay
    $el = Find-Composer $info.Window
    if (-not $el) { exit 1 }
}

if (-not (Set-ComposerText $info $el $Message)) { Log "Done (ABORTED at fill - not delivered)"; exit 5 }
if ($NoSend) { [WinFg]::HideConsole(); Log "Done (NoSend - text placed, not submitted)"; exit 0 }
if (-not (Submit-Composer $info $el)) { [WinFg]::HideConsole(); Log "Done (ABORTED at submit - not delivered; use fallback file)"; exit 5 }
[WinFg]::HideConsole()
Log "Done"
exit 0
