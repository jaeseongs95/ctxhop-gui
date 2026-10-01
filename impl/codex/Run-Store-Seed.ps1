#requires -Version 5.1
param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceCommit,
    [Parameter(Mandatory=$true)][string]$SeedHandoff,
    [string]$SeedHandoffSha256='',
    [string]$RunnerMetadata='',
    [string]$RunnerMetadataSha256='',
    [string]$ReaderExecutable='',
    [string]$ReaderSha256='',
    [string]$ReaderWorkingDirectory='',
    [ValidateSet('','afterReaders','duringDrain','beforeReceipt')][string]$ReaderCancelPoint='',
    [switch]$ReaderLifecycleOnly
)
$ErrorActionPreference='Stop'
$seedOutput=[IO.Path]::GetFullPath($OutputDirectory)
if (-not [IO.Path]::IsPathRooted($OutputDirectory) -or (Test-Path -LiteralPath $seedOutput)) { throw 'A new absolute owned output directory is required.' }
$fixtureMetaArgs=@()
if (($RunnerMetadata -eq '') -ne ($RunnerMetadataSha256 -eq '')) { throw 'Fixture metadata and SHA256 must be provided together.' }
if ($RunnerMetadata -ne '') {
    if (-not [IO.Path]::IsPathRooted($RunnerMetadata) -or $RunnerMetadataSha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $RunnerMetadata -Algorithm SHA256).Hash.ToLowerInvariant() -cne $RunnerMetadataSha256) { throw 'Fixture metadata pin mismatch.' }
    $fixtureMetaArgs=@('-ctxhop-fixture-metadata',$RunnerMetadata,'-ctxhop-fixture-metadata-sha256',$RunnerMetadataSha256)
}
if (-not $ReaderLifecycleOnly -and ($RunnerMetadata -eq '' -or $SeedHandoffSha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $SeedHandoff -Algorithm SHA256).Hash.ToLowerInvariant() -cne $SeedHandoffSha256)) { throw 'Explicit metadata and seed handoff SHA256 are required.' }
if ($ReaderLifecycleOnly -and $ReaderExecutable -ne '') { throw 'Lifecycle-only checks must not launch a Rust executable.' }
if ($ReaderCancelPoint -ne '' -and ($ReaderLifecycleOnly -or $ReaderExecutable -eq '')) { throw 'Cancellation requires an explicit pinned Rust reader fixture.' }
if ($ReaderExecutable -ne '' -and $ReaderWorkingDirectory -eq '') { throw 'A reviewed Rust fixture working directory is required.' }
if (($ReaderExecutable -eq '') -ne ($ReaderSha256 -eq '') -or ($ReaderSha256 -ne '' -and $ReaderSha256 -cnotmatch '^[0-9a-f]{64}$')) { throw 'Rust fixture executable and lowercase SHA256 are required together.' }
if ($ReaderExecutable -ne '' -and (Get-FileHash -LiteralPath $ReaderExecutable -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ReaderSha256) { throw 'Rust fixture executable pin mismatch' }
$null=New-Item -ItemType Directory -Path $seedOutput
$env:CGO_ENABLED='0'; $env:GOENV='off'; $env:GOTOOLCHAIN='local'; $env:GOPROXY='off'; $env:GOSUMDB='off'; $seedTemp=Join-Path $seedOutput 'temp'; $null=New-Item -ItemType Directory -Path $seedTemp; $env:TEMP=$seedTemp; $env:TMP=$seedTemp
Push-Location $PSScriptRoot
try {
    $seedArgs=@('test','-tags','ctxhop_store_seed','-count=1','-v','-run','^(TestStoreCanonicalSeedPrivateProof|TestStoreSeedReaderJob|TestStoreSeedSchemaReceipt|TestStoreSeedCancelReceipt)$','.', '-ctxhop-store-seed-handoff',$SeedHandoff,'-ctxhop-store-seed-handoff-sha256',$SeedHandoffSha256)+$fixtureMetaArgs
    if ($ReaderLifecycleOnly) { $seedArgs=@('test','-tags','ctxhop_store_seed','-count=1','-v','-run','^(TestStoreSeedReaderJob|TestStoreSeedSchemaReceipt|TestStoreSeedCancelReceipt)$','.') }
    if ($ReaderExecutable -ne '') { $seedArgs+=@('-ctxhop-store-seed-output',$seedOutput,'-ctxhop-store-seed-reader',$ReaderExecutable,'-ctxhop-store-seed-reader-sha256',$ReaderSha256,'-ctxhop-store-seed-reader-cwd',$ReaderWorkingDirectory) }
    if ($ReaderCancelPoint -ne '') { $seedArgs+=@('-ctxhop-store-seed-cancel-point',$ReaderCancelPoint) }
    $ErrorActionPreference='Continue'; $seedLog=@(& go @seedArgs 2>&1); $seedExit=$LASTEXITCODE; $ErrorActionPreference='Stop'
    [IO.File]::WriteAllText((Join-Path $seedOutput 'seed-private-proof.log'),($seedLog -join "`n")+"`n",[Text.UTF8Encoding]::new($false)); $seedLog | Write-Output
    $seedResult=@{status=if ($seedExit -eq 0) {'passed'} else {'failed'};sourceCommit=$SourceCommit;exitCode=$seedExit;seedHandoffSha256=if ($ReaderLifecycleOnly) {$null} else {$SeedHandoffSha256};schemaSealSha256='6cad182f2f78614d5b239b56d5326c497e41e8a6e2b558b40d6ef5a3c9179067';readerExeSha256=$ReaderSha256;expectedCancellationPoint=$ReaderCancelPoint;completedProof=$false;seedPrivateProof=if ($ReaderLifecycleOnly) {'notRun'} elseif ($seedExit -eq 0) {'passed'} else {'failed'};rustHandoff=if ($ReaderExecutable -eq '') {'notRun'} elseif ($seedExit -ne 0) {'failed'} elseif ($ReaderCancelPoint -ne '') {'expectedCancellation'} else {'passed'};originalSQLiteOpens=0;engineExecutions=0;productionAdmission='notRun';purpose=if ($ReaderLifecycleOnly) {'owned reader Job drain and unbound receipt rejection; seed reads=0'} elseif ($ReaderCancelPoint -ne '') {'fixture token cancellation; no production callerDrop or OS cancellation claim'} else {'actual8 seed bytes in new owned private readonly copies'}}
    [IO.File]::WriteAllText((Join-Path $seedOutput 'result.json'),($seedResult | ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false))
    if ($seedExit -ne 0) { if ($ReaderLifecycleOnly) { throw 'reader lifecycle fixture failed' }; throw 'actual8 private seed proof failed' }
} finally { Pop-Location }
