#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$OutputDirectory,[Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceCommit)
$ErrorActionPreference='Stop'
$fixtureOutput=[IO.Path]::GetFullPath($OutputDirectory)
$fixtureRoot=[IO.Path]::GetFullPath('D:\Go\codex-s4')+'\'
if (-not $fixtureOutput.StartsWith($fixtureRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($fixtureOutput) -notmatch '^run-helper2-r45-[0-9a-f]{32}$' -or (Test-Path -LiteralPath $fixtureOutput)) { throw '새 owned run-helper2-r45 폴더만 사용할 수 있습니다.' }
$null=New-Item -ItemType Directory -Path $fixtureOutput
$env:CGO_ENABLED='0'; $env:GOENV='off'; $env:GOTOOLCHAIN='local'; $env:GOPROXY='off'; $env:GOSUMDB='off'; $env:TEMP='D:\Go\temp'; $env:TMP='D:\Go\temp'
Push-Location $PSScriptRoot
$fixtureStep='test'
try {
    $ErrorActionPreference='Continue'; $fixtureLog=@(& go test -count=1 -v ./... 2>&1); $fixtureExit=$LASTEXITCODE; $ErrorActionPreference='Stop'
    [IO.File]::WriteAllText((Join-Path $fixtureOutput 'fixtures.log'),($fixtureLog -join "`n")+"`n",[Text.UTF8Encoding]::new($false)); $fixtureLog | Write-Output
    if ($fixtureExit -ne 0) { throw 'Go fixture failed' }
    $fixtureStep='vet'; $ErrorActionPreference='Continue'; $fixtureLog=@(& go vet ./... 2>&1); $fixtureExit=$LASTEXITCODE; $ErrorActionPreference='Stop'
    [IO.File]::WriteAllText((Join-Path $fixtureOutput 'vet.log'),($fixtureLog -join "`n")+"`n",[Text.UTF8Encoding]::new($false)); $fixtureLog | Write-Output
    if ($fixtureExit -ne 0) { throw 'Go vet failed' }
    $fixtureStep='build'
    & go build -trimpath -buildvcs=false -o (Join-Path $fixtureOutput 'ctxhop-codex.exe') .
    if ($LASTEXITCODE -ne 0) { throw 'Go build 실패' }
    & go build -trimpath -buildvcs=false -o (Join-Path $fixtureOutput 'ctxhop-codex-repeat.exe') .
    if ($LASTEXITCODE -ne 0) { throw 'Go repeat build failed' }
    $fixtureHash=(Get-FileHash -LiteralPath (Join-Path $fixtureOutput 'ctxhop-codex.exe') -Algorithm SHA256).Hash
    if ((Get-FileHash -LiteralPath (Join-Path $fixtureOutput 'ctxhop-codex-repeat.exe') -Algorithm SHA256).Hash -cne $fixtureHash) { throw 'Go build bytes differ' }
    $fixtureFiles=@{}; Get-ChildItem -LiteralPath $PSScriptRoot -File | ForEach-Object { $fixtureFiles[$_.Name]=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    $fixtureResult=@{status='passed';sourceCommit=$SourceCommit;sourceFiles=$fixtureFiles;goVersion=((& go version) -join '');powerShellVersion=$PSVersionTable.PSVersion.ToString();engineExecutions=0;enginePin='unset-fail-closed';reproducibleBuild=$true;exeSha256=$fixtureHash}
    [IO.File]::WriteAllText((Join-Path $fixtureOutput 'result.json'),($fixtureResult | ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false))
} catch {
    $fixtureResult=@{status='failed';step=$fixtureStep;sourceCommit=$SourceCommit;engineExecutions=0;error=$_.Exception.Message}
    [IO.File]::WriteAllText((Join-Path $fixtureOutput 'result.json'),($fixtureResult | ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false)); throw
} finally { Pop-Location }
