#requires -Version 5.1
param(
    [string]$SourceRoot=$PSScriptRoot,
    [string]$FixtureRoot=([IO.Path]::GetTempPath()),
    [string]$CurrentWorkerSource=(Join-Path $SourceRoot 'Test-DesktopWorker.ps1'),
    [string]$FutureWorkerSource
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1')
$script:Checks=0;$script:Failures=[Collections.Generic.List[string]]::new()
function Assert([bool]$Value,[string]$Message) {
    $script:Checks++
    if (-not $Value) {$script:Failures.Add($Message);Write-Output "ASSERT: $Message"}
}
function Write-Utf8([string]$Path,[string]$Text) {[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
# The real CI block runs unchanged; only its child-process boundary is replaced.
function powershell.exe {
    $global:LASTEXITCODE=0
    $fileIndex=[Array]::IndexOf($args,'-File')
    $test=[IO.Path]::GetFileNameWithoutExtension($args[$fileIndex+1])
    $extra=@();if ($args.Count -gt $fileIndex+2) {$extra=@($args[($fileIndex+2)..($args.Count-1)])}
    $valid=$true
    if ($test -ceq 'Test-DesktopWorker') {
        $valid=$extra.Count -eq 4 -and $extra[0] -ceq '-RecoveryHelperPath' -and $extra[1] -ceq $global:CISuiteExpectedHelper -and $extra[2] -ceq '-RecoveryHelperSHA256' -and $extra[3] -ceq $global:CISuiteExpectedPin
        if (-not $valid) {$global:LASTEXITCODE=31}
        elseif ($global:CISuiteCase -in @('worker-failure','two-failures')) {$global:LASTEXITCODE=7}
    } elseif ($global:CISuiteCase -eq 'two-failures' -and $test -ceq 'Test-Strings') {$global:LASTEXITCODE=9}
    $global:CISuiteCalls.Add([pscustomobject]@{test=$test;argv=@($args);extra=$extra;workerArgumentsValid=$valid;exitCode=$global:LASTEXITCODE})
}
$lines=[IO.File]::ReadAllLines((Join-Path $SourceRoot '.github/workflows/ci.yml'))
$marker='      - name: Test suites that need no Codex engine'
$indices=@(0..($lines.Length-1)|Where-Object {$lines[$_] -ceq $marker})
if ($indices.Count -ne 1 -or $lines[$indices[0]+2] -cne '        run: |') {throw 'CI suite block not found'}
$body=@($lines[($indices[0]+3)..($lines.Length-1)]|ForEach-Object {if ($_.StartsWith('          ')) {$_.Substring(10)} elseif ($_.Trim()) {throw 'unexpected CI suite indentation'}}) -join "`n"
$block=[scriptblock]::Create($body)
$suiteNames=@('Test-Strings','Test-ProjectFiles','Test-Contract','Test-DesktopWorker','Test-DesktopGUI','Test-ClaudeWorker','Test-ClaudeGUI')
$run=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('ctxhop-ci-suite-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($run)
foreach ($case in @('valid','worker-failure','two-failures','go-pin-missing','provider-pin-missing')) {
    $fixture=Join-Path $run ($case+' with spaces')
    $pkg=Join-Path $fixture 'out/ctxhop-gui-vnext'
    $null=[IO.Directory]::CreateDirectory((Join-Path $fixture 'build'))
    $null=[IO.Directory]::CreateDirectory((Join-Path $pkg 'engine'))
    $null=[IO.Directory]::CreateDirectory((Join-Path $pkg 'bin'))
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'build/Get-BuildPins.ps1') -Destination (Join-Path $fixture 'build/Get-BuildPins.ps1')
    $pin='A'*64
    $goPin=if ($case -eq 'go-pin-missing') {'PENDING_REVIEW'} else {$pin}
    Write-Utf8 (Join-Path $pkg 'CodexDesktop.ps1') ("`$script:DesktopGoSHA256='$goPin'")
    $provider=@{engineSha256=('b'*64);normalEngineSha256=('c'*64);loaderContractId=('ctxhop-prestart-v2:'+('d'*64))}
    if ($case -eq 'provider-pin-missing') {$provider.engineSha256=$null}
    Write-Utf8 (Join-Path $pkg 'engine/provider.json') ($provider|ConvertTo-Json -Compress)
    $global:CISuiteExpectedHelper=Join-Path $pkg 'bin/ctxhop-codex.exe'
    # Inert bytes deliberately differ from the declared pin: forwarding must not derive trust from this file.
    Write-Utf8 $global:CISuiteExpectedHelper 'inert helper; never executed'
    $global:CISuiteExpectedPin=$pin;$global:CISuiteCase=$case
    $global:CISuiteCalls=[Collections.Generic.List[object]]::new()
    $before=[Environment]::GetEnvironmentVariable('RUNNER_TEMP','Process');$message=''
    Push-Location -LiteralPath $fixture
    try {
        $env:RUNNER_TEMP=$fixture
        try {& $block|Out-Null} catch {$message=$_.Exception.Message}
        $expected= switch ($case) {'valid' {''};'worker-failure' {'failed: Test-DesktopWorker'};'two-failures' {'failed: Test-Strings, Test-DesktopWorker'};'go-pin-missing' {'Codex Go adapter pin is not finalized'};'provider-pin-missing' {'protected provider pins are not finalized'}}
        $calls=@($global:CISuiteCalls.ToArray());$blocked=$case -like '*pin-missing'
        Assert ($message -ceq $expected) "$case expected CI outcome; got [$message]"
        Assert ($calls.Count -eq $(if ($blocked) {0} else {7})) "$case suite call count"
        $worker=@($calls|Where-Object test -CEQ 'Test-DesktopWorker')
        Assert ($blocked -or ($worker.Count -eq 1 -and $worker[0].workerArgumentsValid)) "$case explicit pinned Worker arguments"
        $other=@($calls|Where-Object test -CNE 'Test-DesktopWorker')
        Assert (@($other|Where-Object {$_.extra.Count -ne 0}).Count -eq 0 -and ($blocked -or (($calls.test -join '|') -ceq ($suiteNames -join '|')))) "$case preserves other suite calls and order"
        Assert (@($calls|Where-Object {-not ($_.argv -contains '-NoProfile') -or -not ($_.argv -contains '-STA') -or $_.argv -contains '-MockRecoveryRecords'}).Count -eq 0) "$case preserves native command flags"
        Write-Utf8 (Join-Path $fixture 'receipt.json') ([ordered]@{caseId=$case;expected=$expected;actual=$message;declaredPin=$pin;inertHelperSha256=(Get-FileHash -LiteralPath $global:CISuiteExpectedHelper -Algorithm SHA256).Hash;calls=$calls}|ConvertTo-Json -Depth 7)
    } finally {Pop-Location;[Environment]::SetEnvironmentVariable('RUNNER_TEMP',$before,'Process')}
}
foreach ($file in @($CurrentWorkerSource,$FutureWorkerSource)|Where-Object {$_}) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    $names=@($ast.ParamBlock.Parameters|ForEach-Object {$_.Name.VariablePath.UserPath})
    Assert ($errors.Count -eq 0 -and $names -contains 'RecoveryHelperPath') "Worker helper-path param compatibility: $file"
    Assert ($errors.Count -eq 0 -and $names -contains 'RecoveryHelperSHA256') "Worker helper-pin param compatibility: $file"
}
Write-Output "CI suite arguments: $script:Checks checks; failures=$($script:Failures.Count); fixtures=$run"
if ($script:Failures.Count) {throw "ASSERT: CI suite arguments failed ($($script:Failures.Count) checks)"}
