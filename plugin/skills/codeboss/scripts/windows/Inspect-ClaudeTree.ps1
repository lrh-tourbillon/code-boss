# Inspect-ClaudeTree.ps1 - Wide diagnostic. Walks the RAW UI Automation tree of
# Claude Desktop and dumps anything plausibly the chat input: focusable, has a
# ValuePattern, or whose Name/HelpText/AutomationId mentions message/reply/etc.
# Also prints a focused candidate list with their text content.
#
# ASCII only.

param(
    [int]$MaxDepth = 40,
    [int]$MaxNodes = 20000,
    [string]$OutFile = "",
    [switch]$DumpAll
)

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$walker = [System.Windows.Automation.TreeWalker]::RawViewWalker

$script:nodeCount = 0
$script:hits = New-Object System.Collections.ArrayList

function Out($line) {
    Write-Host $line
    if ($OutFile -ne "") { Add-Content -Path $OutFile -Value $line }
}

function ReadValue($el) {
    try {
        $vp = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($vp) { return @{ ok=$true; v=$vp.Current.Value; ro=$vp.Current.IsReadOnly } }
    } catch {}
    return @{ ok=$false; v=$null; ro=$null }
}

function ReadText($el) {
    try {
        $tp = $el.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
        if ($tp) { return $tp.DocumentRange.GetText(-1) }
    } catch {}
    return $null
}

function CodepointPreview($s, $max=60) {
    if ($null -eq $s) { return "<null>" }
    if ($s.Length -eq 0) { return "<empty>" }
    $sb = New-Object System.Text.StringBuilder
    $cnt = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($cnt -ge $max) { [void]$sb.Append("..."); break }
        $code = [int]$ch
        if ($code -ge 32 -and $code -lt 127) { [void]$sb.Append($ch) }
        else { [void]$sb.AppendFormat("\u{0:X4}", $code) }
        $cnt++
    }
    return $sb.ToString()
}

function Walk($el, $depth) {
    if ($script:nodeCount -ge $MaxNodes) { return }
    if ($depth -gt $MaxDepth) { return }
    $script:nodeCount++

    try { $c = $el.Current } catch { return }

    $ct   = $c.ControlType.ProgrammaticName -replace "ControlType.",""
    $name = $c.Name
    $aid  = $c.AutomationId
    $cls  = $c.ClassName
    $help = $c.HelpText
    $foc  = $c.IsKeyboardFocusable
    $ena  = $c.IsEnabled

    $val = ReadValue $el
    $valText = if ($val.ok) { $val.v } else { $null }

    # Decide if interesting
    $hint = ("$name $help $aid $cls" -match "(?i)(message|reply|prompt|chat|compose|textbox|editable)")
    $hit = $false
    if ($foc -and ($val.ok -or $ct -in @("Edit","Document","Custom","Group"))) { $hit = $true }
    if ($val.ok -and $valText -and $valText.Length -gt 0 -and $valText -notlike "http*") { $hit = $true }
    if ($hint) { $hit = $true }

    if ($DumpAll -or $hit) {
        $focFlag = if ($foc) { "[F]" } else { "   " }
        $valFlag = if ($val.ok) { "[V]" } else { "   " }
        $indent  = ("  " * $depth)
        Out ("{0,5}: {1}{2}{3} {4,-12} name='{5}' aid='{6}' cls='{7}' help='{8}'" -f `
            $script:nodeCount, $indent, $focFlag, $valFlag, $ct,
            (CodepointPreview $name 60), (CodepointPreview $aid 30),
            (CodepointPreview $cls 30), (CodepointPreview $help 60))
        if ($val.ok -and $val.v) {
            Out ("{0}      value='{1}' (len={2}, ro={3})" -f $indent,
                (CodepointPreview $val.v 100), $val.v.Length, $val.ro)
        }
    }

    if ($hit) {
        [void]$script:hits.Add([pscustomobject]@{
            Index=$script:nodeCount; Depth=$depth; ControlType=$ct;
            Name=$name; AutomationId=$aid; ClassName=$cls; HelpText=$help;
            Focusable=$foc; Enabled=$ena; HasValuePattern=$val.ok; Value=$valText
        })
    }

    $child = $walker.GetFirstChild($el)
    while ($child) {
        Walk $child ($depth + 1)
        if ($script:nodeCount -ge $MaxNodes) { return }
        $child = $walker.GetNextSibling($child)
    }
}

# === main ===
$procs = Get-Process -Name "claude" -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -ne "" }
if (-not $procs) { Out "ERROR: no 'claude' processes with a window"; exit 1 }

$uiaRoot = [System.Windows.Automation.AutomationElement]::RootElement

foreach ($p in $procs) {
    Out ("===== Walking PID {0} '{1}' (RawView) =====" -f $p.Id, $p.MainWindowTitle)
    $win = $uiaRoot.FindFirst(
        [System.Windows.Automation.TreeScope]::Children,
        (New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id))
    )
    if (-not $win) { Out "  (window not in UIA tree)"; continue }

    # Also use FindAll for a sanity check on common control types
    foreach ($t in @("Edit","Document","Custom")) {
        try {
            $cond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::$t)
            $els = $win.FindAll([System.Windows.Automation.TreeScope]::Subtree, $cond)
            Out ("  FindAll Subtree ControlType.{0,-8} -> {1}" -f $t, $els.Count)
        } catch { Out ("  FindAll {0} threw: {1}" -f $t, $_) }
    }

    $script:nodeCount = 0
    $script:hits = New-Object System.Collections.ArrayList
    Walk $win 0

    Out ""
    Out ("Walked {0} nodes; {1} interesting hits" -f $script:nodeCount, $script:hits.Count)

    # Show ranked candidates that are focusable AND have ValuePattern (most likely chat input)
    Out ""
    Out "--- Top candidates (Focusable + ValuePattern) ---"
    $rank = $script:hits | Where-Object { $_.Focusable -and $_.HasValuePattern }
    if ($rank.Count -eq 0) {
        Out "  (none)  -- this is the smoking gun if true"
    } else {
        $i = 0
        foreach ($h in $rank) {
            Out ("  [{0,3}] node#{1} d={2} {3,-10} foc={4} val={5}" -f $i, $h.Index, $h.Depth, $h.ControlType, $h.Focusable, $h.HasValuePattern)
            Out ("           name='{0}'" -f (CodepointPreview $h.Name 80))
            Out ("           aid='{0}' cls='{1}'" -f (CodepointPreview $h.AutomationId 40), (CodepointPreview $h.ClassName 60))
            Out ("           help='{0}'" -f (CodepointPreview $h.HelpText 80))
            if ($h.Value) {
                Out ("           value='{0}' (len={1})" -f (CodepointPreview $h.Value 120), $h.Value.Length)
                # Codepoints for the suspected placeholder
                $sb = New-Object System.Text.StringBuilder
                $cc = 0
                foreach ($ch in $h.Value.ToCharArray()) {
                    if ($cc -ge 30) { [void]$sb.Append(" ..."); break }
                    [void]$sb.AppendFormat(" U+{0:X4}", [int]$ch)
                    $cc++
                }
                Out ("           codepoints:{0}" -f $sb.ToString())
            }
            $i++
        }
    }
}

Out ""
Out "Done."
