#requires -Version 5.1
param(
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceCommit,
    [Parameter(Mandatory=$true)][string]$SeedHandoff,
    [string]$ReaderExecutable='',
    [string]$ReaderSha256='',
    [switch]$ReaderLifecycleOnly
)
$ErrorActionPreference='Stop'
$seedOutput=[IO.Path]::GetFullPath($OutputDirectory)
$seedRoot=[IO.Path]::GetFullPath('D:\Go\codex-s4')+'\'
if (-not $seedOutput.StartsWith($seedRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($seedOutput) -notmatch '^run-helper2-r45-[0-9a-f]{32}$' -or (Test-Path -LiteralPath $seedOutput)) { throw '새 owned run-helper2-r45 폴더만 사용할 수 있습니다.' }
if (-not $ReaderLifecycleOnly -and (Get-FileHash -LiteralPath $SeedHandoff -Algorithm SHA256).Hash -cne '712AC77321F1706B9892BA4B682F8950C2A9E77A2FC2666C7CFE3FAC0B2259BC') { throw '고정 actual8 seed handoff 변경' }
if ($ReaderLifecycleOnly -and $ReaderExecutable -ne '') { throw 'lifecycle 검사에는 Rust 실행 파일을 넘기지 않습니다.' }
if (($ReaderExecutable -eq '') -ne ($ReaderSha256 -eq '') -or ($ReaderSha256 -ne '' -and $ReaderSha256 -cnotmatch '^[0-9a-f]{64}$')) { throw 'Rust fixture 실행 파일과 소문자 SHA256 pin이 함께 필요합니다.' }
if ($ReaderExecutable -ne '' -and (Get-FileHash -LiteralPath $ReaderExecutable -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ReaderSha256) { throw 'Rust fixture 실행 파일 pin 변경' }
$null=New-Item -ItemType Directory -Path $seedOutput
$env:CGO_ENABLED='0'; $env:GOENV='off'; $env:GOTOOLCHAIN='local'; $env:GOPROXY='off'; $env:GOSUMDB='off'; $env:TEMP='D:\Go\temp'; $env:TMP='D:\Go\temp'
Push-Location $PSScriptRoot
try {
    $seedArgs=@('test','-tags','ctxhop_store_seed','-count=1','-v','-run','^(TestStoreCanonicalSeedPrivateProof|TestStoreSeedReaderJob|TestStoreSeedSchemaReceipt)$','.', '-ctxhop-store-seed-handoff',$SeedHandoff)
    if ($ReaderLifecycleOnly) { $seedArgs=@('test','-tags','ctxhop_store_seed','-count=1','-v','-run','^(TestStoreSeedReaderJob|TestStoreSeedSchemaReceipt)$','.') }
    if ($ReaderExecutable -ne '') { $seedArgs+=@('-ctxhop-store-seed-output',$seedOutput,'-ctxhop-store-seed-reader',$ReaderExecutable,'-ctxhop-store-seed-reader-sha256',$ReaderSha256) }
    $ErrorActionPreference='Continue'; $seedLog=@(& go @seedArgs 2>&1); $seedExit=$LASTEXITCODE; $ErrorActionPreference='Stop'
    [IO.File]::WriteAllText((Join-Path $seedOutput 'seed-private-proof.log'),($seedLog -join "`n")+"`n",[Text.UTF8Encoding]::new($false)); $seedLog | Write-Output
    $seedResult=@{status=if ($seedExit -eq 0) {'passed'} else {'failed'};sourceCommit=$SourceCommit;exitCode=$seedExit;seedHandoffSha256=if ($ReaderLifecycleOnly) {$null} else {'712ac77321f1706b9892ba4b682f8950c2a9e77a2fc2666c7cfe3fac0b2259bc'};schemaSealSha256='6cad182f2f78614d5b239b56d5326c497e41e8a6e2b558b40d6ef5a3c9179067';readerExeSha256=$ReaderSha256;seedPrivateProof=if ($ReaderLifecycleOnly) {'notRun'} elseif ($seedExit -eq 0) {'passed'} else {'failed'};rustHandoff=if ($ReaderExecutable -eq '') {'notRun'} elseif ($seedExit -eq 0) {'passed'} else {'failed'};originalSQLiteOpens=0;engineExecutions=0;productionAdmission='notRun';purpose=if ($ReaderLifecycleOnly) {'owned reader Job drain and unbound receipt rejection; seed reads=0'} else {'actual8 seed bytes in new owned private readonly copies'}}
    [IO.File]::WriteAllText((Join-Path $seedOutput 'result.json'),($seedResult | ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false))
    if ($seedExit -ne 0) { throw 'actual8 private seed proof failed' }
} finally { Pop-Location }
