<#
.SYNOPSIS
  herdr-skill installer for Windows PowerShell — download- and harness-agnostic.
.DESCRIPTION
  Installs the `herdr` agent skill into the AI coding harness of your choice.
  Run from a checkout, or piped from GitHub:

    irm https://raw.githubusercontent.com/Sebastiangmz/herdr-skill/main/install.ps1 | iex
    iex "& { $(irm https://raw.githubusercontent.com/Sebastiangmz/herdr-skill/main/install.ps1) } -Target claude -Yes"
    .\install.ps1 -Dir C:\my-tool\skills
    .\install.ps1 -List
.PARAMETER Target
  claude | claude-project | omp | portable
.PARAMETER Dir
  Install into <Dir>\herdr (any tool that loads SKILL.md skills)
.PARAMETER Yes
  Don't prompt; overwrite an existing install
.PARAMETER List
  List supported targets and exit
#>
[CmdletBinding()]
param(
  [string]$Target = "",
  [string]$Dir = "",
  [switch]$Yes,
  [switch]$List,
  [switch]$Help
)

$ErrorActionPreference = "Stop"
$Repo   = "Sebastiangmz/herdr-skill"
$Branch = "main"
$Name   = "herdr"
$Zip    = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"

function Show-Targets {
@"
Supported targets:
  claude          Claude Code, global      -> ~\.claude\skills\herdr
  claude-project  Claude Code, this repo   -> .\.claude\skills\herdr
  omp             OMP / oh-my-pi, global   -> ~\.omp\agent\skills\herdr
  cursor          Cursor, this repo        -> .\.cursor\skills\herdr
  agents          Vendor-neutral, project  -> .\.agents\skills\herdr
  portable        Tools without skills     -> ~\.herdr-skill  (+ paste-in instructions)
  -Dir <path>     Any SKILL.md-compatible  -> <path>\herdr
"@ | Write-Host
}

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }
if ($List) { Show-Targets; exit 0 }

function Find-Source {
  $self = if ($PSScriptRoot) { $PSScriptRoot } else { "" }
  if ($self -and (Test-Path (Join-Path $self "SKILL.md"))) { return $self }
  Write-Host "Downloading $Name skill from $Repo ..."
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("herdr-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $zipPath = Join-Path $tmp "src.zip"
  Invoke-WebRequest -Uri $Zip -OutFile $zipPath -UseBasicParsing
  Expand-Archive -Path $zipPath -DestinationPath $tmp -Force
  return (Join-Path $tmp ((Split-Path $Repo -Leaf) + "-" + $Branch))
}

function Install-Skill($src, $root) {
  if (-not (Test-Path (Join-Path $src "SKILL.md"))) { throw "source has no SKILL.md ($src)" }
  $dest = Join-Path $root $Name
  if ((Test-Path $dest) -and -not $Yes) {
    $ans = Read-Host "Overwrite existing $dest ? [y/N]"
    if ($ans -notmatch '^(y|yes)$') { throw "aborted" }
  }
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  New-Item -ItemType Directory -Path (Join-Path $dest "references") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $dest "bin") -Force | Out-Null
  Copy-Item (Join-Path $src "SKILL.md") (Join-Path $dest "SKILL.md")
  Copy-Item (Join-Path $src "references\*.md") (Join-Path $dest "references")
  Copy-Item (Join-Path $src "bin\herd.sh") (Join-Path $dest "bin\herd.sh")
  return $dest
}

if (-not $Target -and -not $Dir) {
  Write-Host "Where should the herdr skill be installed?"
  Write-Host "  1) Claude Code (global)   ~\.claude\skills"
  Write-Host "  2) Claude Code (project)  .\.claude\skills"
  Write-Host "  3) OMP / oh-my-pi         ~\.omp\agent\skills"
  Write-Host "  4) Cursor (project)       .\.cursor\skills"
  Write-Host "  5) Vendor-neutral (project) .\.agents\skills"
  Write-Host "  6) Custom skills directory (any SKILL.md tool)"
  Write-Host "  7) Portable + paste-in instructions (any other tool)"
  switch (Read-Host "Choice [1-7]") {
    "1" { $Target = "claude" }
    "2" { $Target = "claude-project" }
    "3" { $Target = "omp" }
    "4" { $Target = "cursor" }
    "5" { $Target = "agents" }
    "6" { $Dir = Read-Host "Skills directory path"; $Target = "dir" }
    "7" { $Target = "portable" }
    default { throw "invalid choice" }
  }
}
if ($Dir -and -not $Target) { $Target = "dir" }

$src = Find-Source
$home = $env:USERPROFILE

switch ($Target) {
  "claude"         { $root = Join-Path $home ".claude\skills" }
  "claude-project" { $root = Join-Path (Get-Location) ".claude\skills" }
  "omp"            { $root = Join-Path $home ".omp\agent\skills" }
  "cursor"         { $root = Join-Path (Get-Location) ".cursor\skills" }
  "agents"         { $root = Join-Path (Get-Location) ".agents\skills" }
  "dir"            { if (-not $Dir) { throw "-Dir requires a path" }; $root = $Dir }
  "portable"       { $root = $home }
  default          { throw "unknown target '$Target' (see -List)" }
}

if ($Target -eq "portable") {
  $dest = Join-Path $home ".herdr-skill"
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  New-Item -ItemType Directory -Path (Join-Path $dest "references") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $dest "bin") -Force | Out-Null
  Copy-Item (Join-Path $src "SKILL.md") (Join-Path $dest "SKILL.md")
  Copy-Item (Join-Path $src "references\*.md") (Join-Path $dest "references")
  Copy-Item (Join-Path $src "bin\herd.sh") (Join-Path $dest "bin\herd.sh")
  Write-Host ""
  Write-Host "Installed (portable) at: $dest"
  Write-Host "Your tool does not auto-load SKILL.md skills. Add this to its global"
  Write-Host "instructions / rules file (AGENTS.md, .cursorrules, system prompt):"
  Write-Host ""
  Write-Host "  When operating Herdr (HERDR_ENV=1) or orchestrating agents in Herdr,"
  Write-Host "  read the skill at ~\.herdr-skill\SKILL.md and follow it."
  exit 0
}

$dest = Install-Skill $src $root
Write-Host ""
Write-Host "Installed the '$Name' skill at: $dest"
switch ($Target) {
  "claude"         { Write-Host "Claude Code loads it automatically as the 'herdr' skill (new session)." }
  "claude-project" { Write-Host "Claude Code loads it for this project (new session)." }
  "omp"            { Write-Host "OMP surfaces it as skill://herdr next session." }
  "cursor"         { Write-Host "Cursor discovers it from .cursor\skills (also reads .agents\skills). Commit it to share." }
  "agents"         { Write-Host "Vendor-neutral .agents\skills — read by Cursor, Codex, and other Agent Skills tools." }
  "dir"            { Write-Host "If your tool loads SKILL.md skills from that directory, it will pick up 'herdr'." }
}
