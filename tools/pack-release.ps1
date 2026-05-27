param(
  [string]$Output = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$sourceRoot = Join-Path $repoRoot "src"
$modName = Split-Path $repoRoot -Leaf
$distRoot = Join-Path $repoRoot "dist"
$defaultOutput = Join-Path $distRoot "$modName.zip"
if (-not $Output) {
  $Output = $defaultOutput
}

if (-not (Test-Path -LiteralPath $sourceRoot)) {
  throw "Missing mod source folder: $sourceRoot"
}

$outputPath = [System.IO.Path]::GetFullPath($Output)
$outputDirectory = Split-Path $outputPath -Parent
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("beamng_mod_pack_" + [System.Guid]::NewGuid().ToString("N"))
$stage = Join-Path $tempRoot $modName

$excludedDirectories = @(
  "mod_info",
  "node_modules"
)

$excludedFiles = @(
  ".gitignore",
  ".gitattributes",
  "*.ps1",
  "*.zip",
  "*.log",
  "Thumbs.db",
  ".DS_Store"
)

function Test-ExcludedDirectory {
  param([System.IO.DirectoryInfo]$Directory)

  return $excludedDirectories -contains $Directory.Name
}

function Test-ExcludedFile {
  param([System.IO.FileInfo]$File)

  foreach ($pattern in $excludedFiles) {
    if ($File.Name -like $pattern) {
      return $true
    }
  }

  return $false
}

function Copy-ModDirectory {
  param(
    [string]$Source,
    [string]$Destination
  )

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null

  Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
    if ($_.PSIsContainer) {
      if (-not (Test-ExcludedDirectory $_)) {
        Copy-ModDirectory -Source $_.FullName -Destination (Join-Path $Destination $_.Name)
      }
    } elseif (-not (Test-ExcludedFile $_)) {
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Destination $_.Name) -Force
    }
  }
}

if (Test-Path -LiteralPath $outputPath) {
  Remove-Item -LiteralPath $outputPath -Force
}

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
Copy-ModDirectory -Source $sourceRoot -Destination $stage

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open($outputPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
  $files = Get-ChildItem -LiteralPath $stage -Recurse -File
  $stagePrefix = $stage.TrimEnd("\", "/") + "\"
  foreach ($file in $files) {
    $relativePath = $file.FullName.Substring($stagePrefix.Length).Replace("\", "/")
    [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $relativePath, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
  }
} finally {
  $archive.Dispose()
}

Remove-Item -LiteralPath $tempRoot -Recurse -Force

Write-Output "Packed $outputPath"
