<#
Builds the release package from git alone: the committed files (build tooling left out through export-ignore in
.gitattributes), bin\*.exe rebuilt by build-exes.ps1, the zip and, unless -NoInstaller, the Inno Setup installer.
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\build.ps1 -Out <new folder> -Tag 20260928 [-GoExe <go.exe>]
Tag 20260928 or 20260928.1 gives installer version 2026.09.28 or 2026.09.28.1.
#>
param(
    [Parameter(Mandatory)][string]$Out,
    [Parameter(Mandatory)][ValidatePattern('^\d{8}(\.\d+)?$')][string]$Tag,
    [string]$GoExe = 'go',
    [string]$TempDir = (Join-Path ([IO.Path]::GetTempPath()) 'ctxhop-go'),
    [string]$GoWork = '',
    [string]$EngineSourceGit = 'https://github.com/openai/codex.git',
    [string]$CargoExe = 'cargo',
    [string]$Iscc = (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    [switch]$NoInstaller
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (@(git -C $repo status --porcelain).Count) { throw 'the working tree has uncommitted changes' }
if (Test-Path -LiteralPath $Out) { throw "output exists: $Out" }
New-Item -ItemType Directory -Path $Out | Out-Null
$Out = (Resolve-Path -LiteralPath $Out).Path
"repo HEAD: $(git -C $repo rev-parse HEAD)"

# Empty values are left out: powershell.exe -File drops an empty argument and the parameter would miss its value.
$exeArgs = @('-Out', (Join-Path $Out 'exes'), '-GoExe', $GoExe, '-TempDir', $TempDir)
if ($GoWork) { $exeArgs += @('-GoWork', $GoWork) }
$exeArgs += @('-EngineSourceGit',$EngineSourceGit,'-CargoExe',$CargoExe)
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-exes.ps1') @exeArgs
if ($LASTEXITCODE -ne 0) { throw "build-exes.ps1 failed (exit $($LASTEXITCODE)): exes that differ from the pins, or a build error" }

# Committed bytes only: no autocrlf conversion, nothing from the working tree.
$pkg = Join-Path $Out 'ctxhop-gui-vnext'
$tar = Join-Path $Out 'package.tar'
git -c core.autocrlf=false -C $repo archive --format=tar -o $tar HEAD
if ($LASTEXITCODE -ne 0) { throw 'git archive failed' }
New-Item -ItemType Directory -Path $pkg | Out-Null
& (Join-Path $env:WINDIR 'System32\tar.exe') -xf $tar -C $pkg
if ($LASTEXITCODE -ne 0) { throw 'tar failed' }
Remove-Item -LiteralPath $tar
New-Item -ItemType Directory -Path (Join-Path $pkg 'bin') | Out-Null
foreach ($exe in 'ctxhop.exe', 'ctxhop-claude.exe', 'ctxhop-codex.exe') { Copy-Item -LiteralPath (Join-Path $Out "exes\$exe") -Destination (Join-Path $pkg "bin\$exe") }
Copy-Item -LiteralPath (Join-Path $Out 'exes\engine') -Destination (Join-Path $pkg 'bin\engine') -Recurse
# What this package was built from: this repository's commit, the upstream commit, patch and exe hashes, Go.
$info = Get-Content -LiteralPath (Join-Path $Out 'exes\build-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$info | Add-Member -NotePropertyName repository -NotePropertyValue 'https://github.com/jaeseongs95/ctxhop-gui'
$info | Add-Member -NotePropertyName commit -NotePropertyValue (git -C $repo rev-parse HEAD)
[IO.File]::WriteAllText((Join-Path $pkg 'build-info.json'), ($info | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
"package files: $(@(Get-ChildItem -LiteralPath $pkg -Recurse -File -Force).Count)"

# Zip entries are ctxhop-gui-vnext/<path> with forward slashes and no directory entries; every entry is checked.
$zip = Join-Path $Out "CtxHop-GUI-vNext-$Tag.zip"
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$files = @(Get-ChildItem -LiteralPath $pkg -Recurse -File -Force | Sort-Object FullName)
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    foreach ($f in $files) {
        $name = 'ctxhop-gui-vnext/' + $f.FullName.Substring($pkg.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $name, 'Optimal') | Out-Null
    }
} finally { $archive.Dispose() }
$sha = [Security.Cryptography.SHA256]::Create(); $bad = 0
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    foreach ($e in $archive.Entries) {
        $s = $e.Open(); try { $h = [BitConverter]::ToString($sha.ComputeHash($s)) -replace '-', '' } finally { $s.Dispose() }
        if ($h -ne (Get-FileHash -LiteralPath (Join-Path $pkg $e.FullName.Substring(17).Replace('/', '\'))).Hash) { $bad++ }
    }
    if ($bad -or $archive.Entries.Count -ne $files.Count) { throw "zip check failed: entries=$($archive.Entries.Count) files=$($files.Count) mismatches=$bad" }
} finally { $archive.Dispose() }

if (-not $NoInstaller) {
    & $Iscc /Q "/DStage=$pkg" "/DTag=$Tag" "/O$Out" (Join-Path $pkg 'installer\CtxHop-GUI-vNext.iss')
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed: $LASTEXITCODE" }
}
Get-ChildItem -LiteralPath $Out -File | Where-Object Extension -in '.exe', '.zip' | ForEach-Object { '{0}  {1}  {2}' -f (Get-FileHash -LiteralPath $_.FullName).Hash, $_.Length, $_.Name }
