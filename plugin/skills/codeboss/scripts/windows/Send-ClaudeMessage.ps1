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
    [Alias("NewSession")][switch]$NewChat,
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

function Get-ActiveUrl($win) {
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Document)
    foreach ($d in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
        try {
            $v = $d.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
            if ($v -like 'https://claude.ai/*') { return $v }
        } catch {}
    }
    return ""
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
    $key = switch ($target) { "chat" {"^1"} "cowork" {"^2"} "code" {"^3"} default {""} }
    # Primary: Invoke the tab button (works backgrounded IF the build honors it).
    $btn = Find-TabButton $info.Window $target
    if ($btn -and (Supports $btn "Invoke")) {
        Log "Switching to '$target' via Invoke on tab button"
        Invoke-El $btn | Out-Null
        $t1 = (Get-Date).AddSeconds(2)
        while ((Get-Date) -lt $t1) {
            Start-Sleep -Milliseconds 300
            if ((Get-ActivePanel $info.Window) -eq $target) { Log "Now on '$target' (invoke)"; return $true }
        }
        Log "Invoke did not switch (no-op in build 1.12603.x); falling back to hotkey"
    }
    # Fallback: Ctrl+1/2/3 hotkey. Requires foreground; reliable on Desktop 1.12603.x.
    if ($key -ne "" -and (Confirm-Foreground $info)) {
        Log "Switching to '$target' via hotkey ($key)"
        [System.Windows.Forms.SendKeys]::SendWait($key)
        $deadline = (Get-Date).AddSeconds($SwitchTimeout)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
            if ((Get-ActivePanel $info.Window) -eq $target) { Log "Now on '$target' (hotkey)"; return $true }
        }
    } else {
        Log "ABORT: cannot switch to '$target' (no hotkey/foreground)"
    }
    Log "WARNING: panel did not switch to '$target'"
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
    # Match ONLY the composer's send button by EXACT name (Code: 'Send'; Cowork: 'Send message'
    # / 'Queue message'). A loose \bsend\b once matched a conversation history pill named
    # 'Ran Send completion message...', invoking the wrong element (a no-op) and forcing the
    # Enter fallback - exact-name matching avoids grabbing history controls.
    foreach ($b in $win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $bc)) {
        $n = $b.Current.Name
        if ($n -match '(?i)^(send|submit|send message|queue message)$' -and $b.Current.IsEnabled) { return $b }
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
    [System.Windows.Forms.SendKeys]::SendWait("^a"); Start-Sleep -Milliseconds 120
    [System.Windows.Forms.SendKeys]::SendWait("^v"); Start-Sleep -Milliseconds 300
    Log "Filled composer via clipboard paste (foreground-confirmed)"
    return $true
}

# Submit. Returns $true ONLY after VERIFYING the message left the composer. On Desktop
# 1.12603.x, InvokePattern.Invoke() on the Send button no-ops intermittently (returns
# success but does nothing), so trusting Invoke's return silently drops the message. We
# Invoke, verify the composer cleared, then fall back to a focused {ENTER} (confirmed to
# submit both the Cowork Edit and the Code Group composer), then Ctrl+Enter, before aborting.

# Did the message actually leave the composer? Empty or a known placeholder == sent.
# Unreadable text (rare) is treated as inconclusive so the caller keeps polling.
function Test-Sent($node) {
    if (-not $node) { return $false }
    $t = Get-InputText $node
    if ($null -eq $t) { return $false }
    $tr = $t.Trim()
    return ($tr -eq "" -or
            $tr -match 'Type / for commands' -or
            $tr -match 'Describe a task or ask a question' -or
            $tr -match 'Write a message' -or
            $tr -match 'Write your prompt to Claude' -or
            $tr -match '^(Reply\.\.\.|Type a message|Message\.\.\.?)$')
}

function Submit-Composer($info, $el) {
    # Attempt 1: Invoke the Send button, THEN verify (do not trust Invoke's return).
    $btn = $null
    for ($i=0; $i -lt 12; $i++) { $btn = Find-SendButton $info.Window; if ($btn) { break }; Start-Sleep -Milliseconds 350 }
    if ($btn) {
        Log "Submit: Invoke on '$($btn.Current.Name)', then verify"
        Invoke-El $btn | Out-Null
        $deadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 300
            if (Test-Sent (Find-Composer $info.Window)) { Log "Submit confirmed (Invoke button)"; return $true }
        }
        Log "Send-button Invoke did not submit (no-op); falling back to focused Enter"
    } else { Log "No send button found; falling back to focused Enter" }

    # Attempt 2: focused {ENTER} (keystroke -> requires foreground).
    if (-not (Confirm-Foreground $info)) { Log "ABORT submit: cannot foreground Claude; not pressing Enter (message left in composer)"; return $false }
    $el2 = Find-Composer $info.Window; if (-not $el2) { $el2 = $el }
    try { $el2.SetFocus(); Start-Sleep -Milliseconds 250 } catch {}
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        if (Test-Sent (Find-Composer $info.Window)) { Log "Submit confirmed (focused Enter)"; return $true }
    }

    # Attempt 3: Ctrl+Enter (some composers bind submit there).
    Log "Enter did not submit; trying Ctrl+Enter"
    try { $el2.SetFocus(); Start-Sleep -Milliseconds 150 } catch {}
    [System.Windows.Forms.SendKeys]::SendWait("^{ENTER}")
    $deadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 300
        if (Test-Sent (Find-Composer $info.Window)) { Log "Submit confirmed (Ctrl+Enter)"; return $true }
    }
    Log "ABORT submit: composer still occupied after Invoke + Enter + Ctrl+Enter"
    return $false
}

# === Main ===
Log "Panel: $Panel | Delay: ${Delay}s | Message: $($Message.Substring(0, [Math]::Min(80, $Message.Length)))"
$info = Get-ClaudeWindow
if (-not $info) { Log "ERROR: No Claude Desktop found"; exit 1 }
$origPanel = Get-ActivePanel $info.Window
Log "Active panel on entry: $origPanel | foreground-is-claude=$([WinFg]::IsFg($info.Process.MainWindowHandle))"

if ($Panel -ne "active") {
    if (-not (Switch-ToPanel $info $Panel)) { Log "ERROR: could not reach panel '$Panel' - aborting"; exit 4 }
    Start-Sleep -Milliseconds 600  # settle: let the inactive panel composer unmount (avoids cross-panel race)
}

if ($Delay -gt 0 -and -not $DryRun) { Log "Waiting ${Delay}s..."; Start-Sleep -Seconds $Delay }

if ($NewChat -and -not $DryRun) {
    # Start a fresh session. On this build Invoke() on the 'New session' button no-ops, but
    # Ctrl+N is reliable - so use the hotkey and VERIFY the session URL changed (a used Code
    # session is .../epitaxy/local_<id>; a fresh one drops the id). Best-effort: proceed either way.
    $beforeUrl = Get-ActiveUrl $info.Window
    if (Confirm-Foreground $info) {
        Log "New session: Ctrl+N (current url: $beforeUrl)"
        [System.Windows.Forms.SendKeys]::SendWait("^n")
        $deadline = (Get-Date).AddSeconds(5); $created = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            $now = Get-ActiveUrl $info.Window
            if ($now -ne "" -and $now -ne $beforeUrl) { $created = $true; break }
        }
        if ($created) { Log "New session confirmed (url -> $(Get-ActiveUrl $info.Window))" }
        else { Log "Note: session URL unchanged after Ctrl+N (already fresh, or no-op); proceeding" }
    } else { Log "WARNING: cannot foreground for Ctrl+N; proceeding with current session" }
    Start-Sleep -Milliseconds 800
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
                     $trimmed -match "^(Reply\.\.\.|Type a message|Message\.\.\.?|Type / for commands|Describe a task or ask a question)$" -or
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
