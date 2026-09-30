<#
Builds the protected app-server from a fixed upstream commit plus reviewed patches.
Run in a separate process with the Rust/MSVC environment prepared by the caller.
This script compiles an executable; it never runs it or touches a Codex home.
The provider pin must be finalized before -VerifyPin or release packaging succeeds.
#>
param(
    [Parameter(Mandatory)][string]$Out,
    [string]$SourceGit = 'https://github.com/openai/codex.git',
    [string]$CargoExe = 'cargo',
    [switch]$VerifyPin
)
$ErrorActionPreference='Stop'
function Invoke-EngineBuildNative([string]$Exe,[string[]]$Arguments) {
    $ErrorActionPreference='Continue'
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe exited $LASTEXITCODE" }
}
$repo=(Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (@(git -C $repo status --porcelain).Count) { throw 'the working tree has uncommitted changes' }
$providerPath=Join-Path $repo 'engine\provider.json'
$provider=Get-Content -LiteralPath $providerPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($provider.schemaVersion -ne 1 -or $provider.baseCommit -cnotmatch '^[0-9a-f]{40}$' -or $provider.target -cne 'x86_64-pc-windows-msvc' -or $provider.rustVersion -cne '1.95.0') { throw 'invalid provider manifest' }
if ($provider.loaderContractId -isnot [string] -or $provider.loaderContractId -cnotmatch '^ctxhop-prestart-v1:[0-9a-f]{64}$' -or -not @($provider.patches).Count) { throw 'protected engine provider is not finalized' }
if ($VerifyPin -and $provider.engineSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'protected engine pin is not finalized' }
$Out=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Out)
if (Test-Path -LiteralPath $Out) { throw "output exists: $Out" }
$null=[IO.Directory]::CreateDirectory($Out)

# Consume committed LF bytes for manifests and patches, regardless of checkout conversion.
$receiptZip=Join-Path $Out 'provider.zip'; $receiptRoot=Join-Path $Out 'provider'
Invoke-EngineBuildNative git @('-c','core.autocrlf=false','-C',$repo,'archive','--format=zip','-o',$receiptZip,'HEAD','engine')
Expand-Archive -LiteralPath $receiptZip -DestinationPath $receiptRoot
$frozenProvider=Join-Path $receiptRoot 'engine\provider.json'
$provider=Get-Content -LiteralPath $frozenProvider -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($patch in $provider.patches) {
    if ($patch.path -isnot [string] -or $patch.path -cnotmatch '^patches/[A-Za-z0-9_.-]+\.patch$' -or $patch.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'invalid provider patch' }
    $path=Join-Path (Join-Path $receiptRoot 'engine') $patch.path
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $patch.sha256) { throw 'provider patch hash mismatch' }
}
if ((& $CargoExe --version) -notmatch '^cargo 1\.95\.0 ') { throw 'need cargo 1.95.0' }
$rustc=if ($env:RUSTC) {$env:RUSTC} else {'rustc'}
if ((& $rustc --version) -notmatch '^rustc 1\.95\.0 ') { throw 'need rustc 1.95.0' }

$src=Join-Path $Out 'source'
Invoke-EngineBuildNative git @('init','-q',$src)
Invoke-EngineBuildNative git @('-C',$src,'config','core.autocrlf','false')
Invoke-EngineBuildNative git @('-C',$src,'fetch','-q','--no-tags',$SourceGit,$provider.baseCommit)
$sourceZip=Join-Path $Out 'source.zip'
Invoke-EngineBuildNative git @('-c','core.autocrlf=false','-C',$src,'archive','--format=zip','-o',$sourceZip,$provider.baseCommit)
$sourceTree=Join-Path $Out 'source-tree'
Expand-Archive -LiteralPath $sourceZip -DestinationPath $sourceTree
foreach ($patch in $provider.patches) {
    $path=Join-Path (Join-Path $receiptRoot 'engine') $patch.path
    Invoke-EngineBuildNative git @('-C',$sourceTree,'apply','--check','--binary',$path)
    Invoke-EngineBuildNative git @('-C',$sourceTree,'apply','--binary',$path)
}

$env:TEMP='D:\Go\temp'; $env:TMP=$env:TEMP
$null=[IO.Directory]::CreateDirectory($env:TEMP)
$env:CARGO_TARGET_DIR=Join-Path $Out 'rust-target'
$env:CTXHOP_LOADER_CONTRACT_ID=$provider.loaderContractId
$env:STABLE_GIT_COMMIT=$provider.baseCommit
Remove-Item Env:RUSTFLAGS -ErrorAction SilentlyContinue
$env:CARGO_ENCODED_RUSTFLAGS=(@('-C','link-arg=/Brepro',"--remap-path-prefix=$sourceTree=.") -join [char]31)
$env:CARGO_INCREMENTAL='0'
$env:SOURCE_DATE_EPOCH='0'
Push-Location -LiteralPath (Join-Path $sourceTree 'codex-rs')
try { Invoke-EngineBuildNative $CargoExe @('build','--release','--locked','--target',$provider.target,'-p','codex-app-server','--bin','ctxhop-codex-engine') }
finally { Pop-Location }
$built=Join-Path $env:CARGO_TARGET_DIR ($provider.target+'\release\ctxhop-codex-engine.exe')
$engine=Join-Path $Out 'ctxhop-codex-engine.exe'
Copy-Item -LiteralPath $built -Destination $engine
$hash=(Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash.ToLowerInvariant()
if ($VerifyPin -and $hash -cne $provider.engineSha256) { throw "protected engine hash mismatch: $hash" }
$info=[ordered]@{schemaVersion=1;baseRepository=$provider.baseRepository;baseCommit=$provider.baseCommit;sourceVersion=$provider.sourceVersion;providerSha256=(Get-FileHash -LiteralPath $frozenProvider -Algorithm SHA256).Hash.ToLowerInvariant();loaderContractId=$provider.loaderContractId;rust=$provider.rustVersion;target=$provider.target;patches=$provider.patches;sha256=$hash;profile='release';cargoLocked=$true;runtimeExecuted=$false}
[IO.File]::WriteAllText((Join-Path $Out 'engine-build-info.json'),($info|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
"$hash  ctxhop-codex-engine.exe"
