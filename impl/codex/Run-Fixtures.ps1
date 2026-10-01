#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$OutputDirectory,[Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceCommit,[string]$RunnerMetadata='',[string]$RunnerMetadataSha256='')
$ErrorActionPreference='Stop'
$fixtureOutput=[IO.Path]::GetFullPath($OutputDirectory)
if (-not [IO.Path]::IsPathRooted($OutputDirectory) -or (Test-Path -LiteralPath $fixtureOutput) -or $fixtureOutput.TrimEnd('\') -ceq [IO.Path]::GetPathRoot($fixtureOutput).TrimEnd('\')) { throw 'A new absolute owned output directory is required.' }
$fixtureMetaArgs=@()
if (($RunnerMetadata -eq '') -ne ($RunnerMetadataSha256 -eq '')) { throw 'Fixture metadata and SHA256 must be provided together.' }
if ($RunnerMetadata -ne '') {
    if (-not [IO.Path]::IsPathRooted($RunnerMetadata) -or $RunnerMetadataSha256 -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $RunnerMetadata -Algorithm SHA256).Hash.ToLowerInvariant() -cne $RunnerMetadataSha256) { throw 'Fixture metadata pin mismatch.' }
    $fixtureMetaArgs=@('-ctxhop-fixture-metadata',$RunnerMetadata,'-ctxhop-fixture-metadata-sha256',$RunnerMetadataSha256)
}
$null=New-Item -ItemType Directory -Path $fixtureOutput
$env:CGO_ENABLED='0'; $env:GOENV='off'; $env:GOTOOLCHAIN='local'; $env:GOPROXY='off'; $env:GOSUMDB='off'; $fixtureTemp=Join-Path $fixtureOutput 'temp'; $null=New-Item -ItemType Directory -Path $fixtureTemp; $env:TEMP=$fixtureTemp; $env:TMP=$fixtureTemp
Push-Location $PSScriptRoot
$fixtureStep='test'
try {
    $ErrorActionPreference='Continue'; $fixtureLog=@(& go test -count=1 -v ./... 2>&1); $fixtureExit=$LASTEXITCODE; $ErrorActionPreference='Stop'
    [IO.File]::WriteAllText((Join-Path $fixtureOutput 'fixtures.log'),($fixtureLog -join "`n")+"`n",[Text.UTF8Encoding]::new($false)); $fixtureLog | Write-Output
    if ($fixtureExit -ne 0) { throw 'Go fixture failed' }
    $fixtureStep='portable-metadata'
    $fixtureTags='ctxhop_schema_export,ctxhop_backend_sequence,ctxhop_store_seed'
    $ErrorActionPreference='Continue'; $fixtureLog=@(& go test -tags $fixtureTags -count=1 -v -run '^TestPortableFixture(MetadataBoundaries|Input)$' . @fixtureMetaArgs 2>&1); $fixtureExit=$LASTEXITCODE; $ErrorActionPreference='Stop'
    [IO.File]::WriteAllText((Join-Path $fixtureOutput 'portable-metadata.log'),($fixtureLog -join "`n")+"`n",[Text.UTF8Encoding]::new($false)); $fixtureLog | Write-Output
    if ($fixtureExit -ne 0) { throw 'Portable fixture metadata check failed' }
    $fixtureStep='vet'; $ErrorActionPreference='Continue'; $fixtureLog=@(& go vet -tags $fixtureTags ./... 2>&1); $fixtureExit=$LASTEXITCODE; $ErrorActionPreference='Stop'
    [IO.File]::WriteAllText((Join-Path $fixtureOutput 'vet.log'),($fixtureLog -join "`n")+"`n",[Text.UTF8Encoding]::new($false)); $fixtureLog | Write-Output
    if ($fixtureExit -ne 0) { throw 'Go vet failed' }
    $fixtureStep='build'
    & go build -trimpath -buildvcs=false -o (Join-Path $fixtureOutput 'ctxhop-codex.exe') .
    if ($LASTEXITCODE -ne 0) { throw 'Go build failed' }
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
