param(
  [string]$BeamNGUserPath = "$env:LOCALAPPDATA\BeamNG\BeamNG.drive\current",
  [string]$ModName = "els_controller",
  [switch]$Force
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$sourceRoot = Resolve-Path (Join-Path $repoRoot "src")
$unpackedRoot = Join-Path $BeamNGUserPath "mods\unpacked"
$linkPath = Join-Path $unpackedRoot $ModName

if (-not (Test-Path -LiteralPath $unpackedRoot)) {
  New-Item -ItemType Directory -Force -Path $unpackedRoot | Out-Null
}

if (Test-Path -LiteralPath $linkPath) {
  $item = Get-Item -LiteralPath $linkPath -Force
  if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
    if (-not $Force) {
      throw "Refusing to replace real folder: $linkPath. Move it manually or rerun with -Force."
    }

    $backupPath = $linkPath + ".backup-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    Move-Item -LiteralPath $linkPath -Destination $backupPath
    Write-Output "Moved existing folder to $backupPath"
  } else {
    Remove-Item -LiteralPath $linkPath -Force
  }
}

New-Item -ItemType Junction -Path $linkPath -Target $sourceRoot | Out-Null
Write-Output "Linked $linkPath -> $sourceRoot"
