<#
.SYNOPSIS
  Sync the source plugin folder (E:\cowork\codeboss\plugin) into the
  Cowork marketplace install AND the active rpm runtime extract.

.DESCRIPTION
  CodeBoss is registered as a "directory" marketplace plugin. There are
  two install locations Cowork looks at:

    1. Marketplace source (read from known_marketplaces.json)
       -> .../cowork_plugins/marketplaces/local-desktop-app-uploads/codeboss
    2. RPM runtime extract (read from rpm/manifest.json by plugin name)
       -> .../rpm/plugin_<id>/

  This script mirrors the repo's plugin/ folder into both, so changes to
  SKILL.md / scripts / references take effect on the next Cowork session
  (and immediately for #2 after a Cowork restart or new conversation).

.PARAMETER Pull
  If set, runs `git pull --ff-only` on the current branch first.

.PARAMETER SkipRpm
  Skip syncing into the rpm runtime extract. Useful if you only want to
  update the marketplace source and let Cowork re-extract on its own.

.EXAMPLE
  .\Update-Installed.ps1
  .\Update-Installed.ps1 -Pull
#>

[CmdletBinding()]
param(
    [switch]$Pull,
    [switch]$SkipRpm
)

$ErrorActionPreference = 'Stop'

$RepoRoot   = "E:\cowork\codeboss"
$Source     = Join-Path $RepoRoot 'plugin'
$PluginName = 'codeboss'

# --- Resolve Cowork session paths ----------------------------------------
$claudeRoot = Join-Path $env:APPDATA 'Claude'
$lams       = Join-Path $claudeRoot 'local-agent-mode-sessions'

if (-not (Test-Path $lams)) {
    throw "Cowork session root not found: $lams"
}

# Find the most recently touched session/workspace pair that has a
# cowork_plugins folder.
$workspace = Get-ChildItem $lams -Directory | ForEach-Object {
    Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue
} | Where-Object {
    Test-Path (Join-Path $_.FullName 'cowork_plugins')
} | Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $workspace) {
    throw "Could not locate a Cowork workspace with a cowork_plugins folder under $lams."
}

Write-Host "[i] Cowork workspace: $($workspace.FullName)"

$knownMktPath = Join-Path $workspace.FullName 'cowork_plugins\known_marketplaces.json'
$rpmManifest  = Join-Path $workspace.FullName 'rpm\manifest.json'

if (-not (Test-Path $knownMktPath)) { throw "Missing $knownMktPath" }
if (-not (Test-Path $rpmManifest))  { throw "Missing $rpmManifest" }

# --- Optional: git pull ---------------------------------------------------
if ($Pull) {
    Write-Host "[i] git pull --ff-only on $(git -C $RepoRoot rev-parse --abbrev-ref HEAD)"
    git -C $RepoRoot fetch --all --prune
    git -C $RepoRoot pull --ff-only
}

# --- Resolve marketplace install location --------------------------------
$known = Get-Content $knownMktPath -Raw | ConvertFrom-Json
$mkt   = $known.'local-desktop-app-uploads'
if (-not $mkt) { throw "Marketplace 'local-desktop-app-uploads' not in known_marketplaces.json" }

$mktDir = Join-Path $mkt.installLocation $PluginName
Write-Host "[i] Marketplace install: $mktDir"

# --- Resolve rpm runtime extract location --------------------------------
$rpmDir = $null
if (-not $SkipRpm) {
    $manifest = Get-Content $rpmManifest -Raw | ConvertFrom-Json
    $entry    = $manifest.plugins | Where-Object { $_.name -eq $PluginName } | Select-Object -First 1
    if ($entry) {
        $rpmDir = Join-Path $workspace.FullName "rpm\$($entry.id)"
        Write-Host "[i] RPM runtime extract: $rpmDir  (plugin id: $($entry.id))"
    } else {
        Write-Warning "Plugin '$PluginName' not in rpm/manifest.json -- skipping runtime sync."
    }
}

# --- Sync ---------------------------------------------------------------
function Sync-Dir {
    param([string]$From, [string]$To, [string]$Label)
    Write-Host ""
    Write-Host "[*] Syncing -> $Label"
    Write-Host "    $From"
    Write-Host " -> $To"
    if (-not (Test-Path $To)) { New-Item -ItemType Directory -Path $To -Force | Out-Null }
    # /MIR mirrors (delete extraneous), /NFL /NDL /NJH /NJS /NP /R:1 /W:1 keep it quiet & non-blocking
    $rc = & robocopy $From $To /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1
    # robocopy exit codes 0-7 are success-ish (8+ = failure)
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed (exit $LASTEXITCODE) syncing to $Label"
    }
    $files = (Get-ChildItem $To -Recurse -File).Count
    $bytes = (Get-ChildItem $To -Recurse -File | Measure-Object Length -Sum).Sum
    Write-Host "    OK -> $files files, $bytes bytes"
}

if (-not (Test-Path $Source)) { throw "Source plugin folder not found: $Source" }

Sync-Dir -From $Source -To $mktDir -Label 'marketplace install'
if ($rpmDir) {
    Sync-Dir -From $Source -To $rpmDir -Label 'rpm runtime extract'
}

# Bump marketplace lastUpdated so Cowork notices on next start.
$known.'local-desktop-app-uploads'.lastUpdated = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
$known | ConvertTo-Json -Depth 10 | Set-Content -Path $knownMktPath -Encoding UTF8
Write-Host ""
Write-Host "[i] Bumped lastUpdated on local-desktop-app-uploads marketplace."

Write-Host ""
Write-Host "[OK] CodeBoss plugin updated."
Write-Host "     Restart Cowork or start a new conversation to load fresh content."
