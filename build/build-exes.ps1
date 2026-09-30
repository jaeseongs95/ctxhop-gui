<#
Rebuilds bin\ctxhop.exe (Codex Desktop bundle transport) and bin\ctxhop-claude.exe (0.2.0-gui.3) from the pinned
upstream CtxHop commit plus upstream\patches\*.patch, and checks each against the SHA-256 the GUI pins.

Run it in its own process; it sets Go and TMP variables for that process only:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\build-exes.ps1 -Out <new folder> [-GoExe <go.exe>]
Needs git and Go go1.27.1 windows/amd64 (official zip SHA-256 a3911b5e0e1b1053f25ed0675f4c1c6aad1e2bfcf253df2b9be4caabd2edd95d).
Go modules come from the Go proxy and are checked against go.sum. Exit code = number of exes that differ.
#>
param(
    [Parameter(Mandatory)][string]$Out,                              # new folder: upstream sources and the two exes
    [string]$Upstream = 'https://github.com/CCCCY-ci/ctxhop',        # any git URL or local clone that has $Commit
    [string]$GoExe = 'go',
    [string]$TempDir = (Join-Path ([IO.Path]::GetTempPath()) 'ctxhop-go'),   # TMP, TEMP and GOTMPDIR
    [string]$GoWork = '',                                            # GOPATH and GOCACHE parent; empty = Go defaults
    [string]$EngineSourceGit = 'https://github.com/openai/codex.git',
    [string]$CargoExe = 'cargo'
)
$ErrorActionPreference = 'Stop'
# Upstream main "release: CtxHop v0.2.0". The v0.2.0 tag (b8a18e9) has the same parent and the same Go files;
# 0001 is cut against this commit's .gitignore.
$Commit = 'b84de46c6fa0cc68f10b7852f4230b9da6bc75f1'
$patches = Join-Path $PSScriptRoot '..\upstream\patches'
$targets = @(
    @{ Name = 'ctxhop.exe'
       Patches = '0001-gui1-no-environment.patch', '0002-transport-desktop-bundle.patch'
       LdFlags = '-s -w -X main.version=desktop-bundle-candidate-20260926'
       Sha256 = '9B14CCD3B33C75EDFD9D424D76FBAF17092364C58721C1BB9C0FD6BA73C7C006' },
    @{ Name = 'ctxhop-claude.exe'
       Patches = '0001-gui1-no-environment.patch', '0003-gui2-sidecar.patch', '0004-gui3-relocate.patch'
       # The exact -X strings are part of the build ID, so they stay as first shipped.
       LdFlags = '-s -w -X main.version=0.2.0-gui.3 -X main.commit=b8a18e9+gui.3 -X main.date=2026-09-27'
       Sha256 = '45186B1017A0F8969DFC27D248351C275ACB0DFEBF21276AD968E03DC84E650B' }
)

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'  # PowerShell 5.1 may turn native stderr into errors; the exit code decides
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') exited $LASTEXITCODE" }
}

# Relative paths are taken from the current location once, before the builds change it.
$full = { param($p) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p) }
$Out = & $full $Out; $TempDir = & $full $TempDir
if ($GoWork) { $GoWork = & $full $GoWork }
if ($GoExe -match '[\\/]') { $GoExe = & $full $GoExe }   # a bare name is looked up in PATH
if (Test-Path -LiteralPath $Out) { throw "output exists: $Out" }
New-Item -ItemType Directory -Path $Out | Out-Null
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
$env:TMP = $TempDir; $env:TEMP = $TempDir; $env:GOTMPDIR = $TempDir
if ($GoWork) { $env:GOPATH = Join-Path $GoWork 'gopath'; $env:GOCACHE = Join-Path $GoWork 'gocache' }
# Build settings that change the output bytes are fixed here. Module download settings (GOPROXY, GOSUMDB,
# GONOSUMDB, GOPRIVATE, GOINSECURE) and the cache locations are left to the caller; go.sum still pins every module.
foreach ($v in 'GOFLAGS', 'GOEXPERIMENT', 'GOFIPS140', 'GOROOT', 'GOMODCACHE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
$env:GOENV = 'off'; $env:GOWORK = 'off'; $env:GOTOOLCHAIN = 'local'; $env:CGO_ENABLED = '0'; $env:GOOS = 'windows'; $env:GOARCH = 'amd64'; $env:GOAMD64 = 'v1'
$goVersion = & $GoExe version
if ($goVersion -ne 'go version go1.27.1 windows/amd64') { throw "need go1.27.1 windows/amd64, got: $goVersion" }
$goVersion
"upstream: $Upstream $Commit"

$failed = 0
$info = [ordered]@{ upstream = $Upstream; upstreamCommit = $Commit; go = "$goVersion"; exes = @() }
foreach ($t in $targets) {
    $src = Join-Path $Out ('src-' + [IO.Path]::GetFileNameWithoutExtension($t.Name))
    Invoke-Native git @('init', '-q', $src)
    Invoke-Native git @('-C', $src, 'config', 'core.autocrlf', 'false')
    # Byte-exact checkout and apply whatever the global git settings are.
    New-Item -ItemType Directory -Force -Path (Join-Path $src '.git\info') | Out-Null
    [IO.File]::WriteAllText((Join-Path $src '.git\info\attributes'), "* -text`n")
    Invoke-Native git @('-C', $src, 'fetch', '-q', '--no-tags', $Upstream, $Commit)
    Invoke-Native git @('-C', $src, 'checkout', '-q', '--detach', $Commit)
    foreach ($p in $t.Patches) { Invoke-Native git @('-C', $src, 'apply', '--whitespace=nowarn', (Join-Path $patches $p)) }
    $exe = Join-Path $Out $t.Name
    Push-Location -LiteralPath $src
    try {
        # -buildvcs=false: the shipped exes carry no VCS stamp (they were built from folders without .git).
        Invoke-Native $GoExe @('build', '-buildvcs=false', '-trimpath', '-ldflags', $t.LdFlags, '-o', $exe, './cmd/ctxhop')
    } finally { Pop-Location }
    $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    if ($hash -eq $t.Sha256) { $verdict = 'MATCH' } else { $verdict = "MISMATCH, pinned $($t.Sha256)"; $failed++ }
    '{0}  {1}  {2}' -f $hash, $t.Name, $verdict
    $info.exes += [ordered]@{ name = $t.Name; sha256 = $hash; ldflags = $t.LdFlags
        patches = @($t.Patches | ForEach-Object { [ordered]@{ name = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $patches $_)).Hash } }) }
}
# Build the protected provider first and bind the local Go helper to its exact image.
$providerPath=Join-Path $PSScriptRoot '..\engine\provider.json'
$provider=Get-Content -LiteralPath $providerPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($provider.engineSha256 -cnotmatch '^[0-9a-f]{64}$' -or $provider.normalEngineSha256 -cnotmatch '^[0-9a-f]{64}$' -or $provider.loaderContractId -cnotmatch '^ctxhop-prestart-v1:[0-9a-f]{64}$') { throw 'protected provider pins are not finalized' }
$goAdapter=Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\CodexDesktop.ps1') -Raw -Encoding UTF8
$goPin=[regex]::Match($goAdapter, "DesktopGoSHA256='([A-Fa-f0-9]{64})'")
if (-not $goPin.Success) { throw 'Codex Go adapter pin is not finalized' }
$engineOut=Join-Path $Out 'protected-build'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build-codex-engine.ps1') -Out $engineOut -SourceGit $EngineSourceGit -CargoExe $CargoExe -VerifyPin
if ($LASTEXITCODE -ne 0) { throw "protected engine build failed: $LASTEXITCODE" }
$engine=Join-Path $Out 'engine'; $null=[IO.Directory]::CreateDirectory($engine)
Copy-Item -LiteralPath (Join-Path $engineOut 'ctxhop-codex-engine.exe') -Destination (Join-Path $engine 'ctxhop-codex-engine.exe')
Copy-Item -LiteralPath (Join-Path $engineOut 'engine-build-info.json') -Destination (Join-Path $engine 'engine-build-info.json')

# No checkout conversion: this helper is built only from committed LF archive bytes.
$repo=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$helperZip=Join-Path $Out 'codex-helper.zip'; $helperSource=Join-Path $Out 'codex-helper-source'
Invoke-Native git @('-c','core.autocrlf=false','-C',$repo,'archive','--format=zip','-o',$helperZip,'HEAD','impl/codex')
Expand-Archive -LiteralPath $helperZip -DestinationPath $helperSource
$helperExe=Join-Path $Out 'ctxhop-codex.exe'
$helperFlags='-s -w -X main.engineSHA256='+$provider.engineSha256+' -X main.normalEngineSHA256='+$provider.normalEngineSha256+' -X main.loaderContractID='+$provider.loaderContractId
Push-Location -LiteralPath (Join-Path $helperSource 'impl\codex')
try { Invoke-Native $GoExe @('build','-buildvcs=false','-trimpath','-ldflags',$helperFlags,'-o',$helperExe,'.') }
finally { Pop-Location }
$helperHash=(Get-FileHash -LiteralPath $helperExe -Algorithm SHA256).Hash
if ($helperHash -cne $goPin.Groups[1].Value.ToUpperInvariant()) { $failed++; "Codex Go helper hash mismatch: $helperHash" }
$info.exes += [ordered]@{name='ctxhop-codex.exe';sha256=$helperHash;ldflags=$helperFlags;source='impl/codex';engineSha256=$provider.engineSha256;normalEngineSha256=$provider.normalEngineSha256;loaderContractId=$provider.loaderContractId}
$info | Add-Member -NotePropertyName protectedEngine -NotePropertyValue (Get-Content -LiteralPath (Join-Path $engineOut 'engine-build-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
[IO.File]::WriteAllText((Join-Path $Out 'build-info.json'), ($info | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding $false))
exit $failed
