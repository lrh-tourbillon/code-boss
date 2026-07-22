# Get-ClaudePanel.ps1 - Detect which in-app panel is active in Claude Desktop.
#
# Claude Desktop hosts three tabs in one window: Chat / Cowork / Code (switch with
# Ctrl+1 / Ctrl+2 / Ctrl+3). The tab pills expose NO selection state via UI Automation,
# so we cannot read "which tab is active" off the buttons. Instead, the active panel
# mounts a claude.ai web document whose URL identifies the panel:
#   https://claude.ai/cowork/...    -> cowork
#   https://claude.ai/epitaxy/...   -> code   (epitaxy is the Code panel's route)
#   https://claude.ai/chat/...      -> chat
# The inactive panels are fully unmounted, so exactly one such doc exists at a time.
#
# Prints the panel token on stdout: cowork | code | chat | unknown
# With -Quiet, ONLY the token is emitted (for clean parsing by callers).
# ASCII only.
param([switch]$Quiet, [string]$LogFile = "")

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

function Log($m){ if(-not $Quiet){ Write-Host $m }; if($LogFile -ne ""){ Add-Content -Path $LogFile -Value $m } }

$proc = Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -ne "" } | Select-Object -First 1
if(-not $proc){ Log "ERROR: no claude window"; Write-Output "unknown"; exit 1 }
$root = [System.Windows.Automation.AutomationElement]::RootElement
$win = $root.FindFirst('Children',(New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty,$proc.Id)))
if(-not $win){ Log "ERROR: window not in UIA tree"; Write-Output "unknown"; exit 1 }

$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Document)
$docs = $win.FindAll('Descendants',$cond)
$url = ""
foreach($d in $docs){
  try { $v = $d.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
        if($v -like 'https://claude.ai/*'){ $url = $v; break } } catch {}
}

$panel = "unknown"
if     ($url -match '://claude\.ai/cowork')  { $panel = "cowork" }
elseif ($url -match '://claude\.ai/epitaxy') { $panel = "code" }
elseif ($url -match '://claude\.ai/chat')    { $panel = "chat" }
elseif ($url -match '://claude\.ai/')        { $panel = "chat" }   # fallback: generic app route

Log ("panel=$panel url='$url'")
Write-Output $panel
exit 0
