#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$fixtureOutput=[IO.Path]::GetFullPath($OutputDirectory)
$fixtureRoot=[IO.Path]::GetFullPath('D:\Go\codex-s4')+'\'
if (-not $fixtureOutput.StartsWith($fixtureRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($fixtureOutput) -notmatch '^run-helper2-r45-[0-9a-f]{32}$' -or (Test-Path -LiteralPath $fixtureOutput)) { throw '새 owned run-helper2-r45 폴더만 사용할 수 있습니다.' }
$null=New-Item -ItemType Directory -Path $fixtureOutput
$env:CGO_ENABLED='0'; $env:GOENV='off'; $env:GOTOOLCHAIN='local'; $env:GOPROXY='off'; $env:GOSUMDB='off'; $env:TEMP='D:\Go\temp'; $env:TMP='D:\Go\temp'
Push-Location $PSScriptRoot
try {
    & go test -count=1 -v ./... 2>&1 | Tee-Object -FilePath (Join-Path $fixtureOutput 'fixtures.log')
    if ($LASTEXITCODE -ne 0) { throw 'Go fixture 실패' }
    & go vet ./... 2>&1 | Tee-Object -FilePath (Join-Path $fixtureOutput 'vet.log')
    if ($LASTEXITCODE -ne 0) { throw 'Go vet 실패' }
    & go build -trimpath -buildvcs=false -o (Join-Path $fixtureOutput 'ctxhop-codex.exe') .
    if ($LASTEXITCODE -ne 0) { throw 'Go build 실패' }
    $fixtureResult=@{status='passed';engineExecutions=0;enginePin='unset-fail-closed';exeSha256=(Get-FileHash -LiteralPath (Join-Path $fixtureOutput 'ctxhop-codex.exe') -Algorithm SHA256).Hash}
    [IO.File]::WriteAllText((Join-Path $fixtureOutput 'result.json'),($fixtureResult | ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false))
} finally { Pop-Location }
