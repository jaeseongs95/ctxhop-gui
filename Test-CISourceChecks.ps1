#requires -Version 5.1
param([string]$SourceRoot=$PSScriptRoot,[string]$FixtureRoot=([IO.Path]::GetTempPath()))
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Utility/Microsoft.PowerShell.Utility.psd1')
$script:Checks=0;$script:Failures=[Collections.Generic.List[string]]::new()
function Assert([bool]$Value,[string]$Message) {
    $script:Checks++
    if (-not $Value) {$script:Failures.Add($Message);Write-Output "ASSERT: $Message"}
}
function Invoke-CISourceChild([string]$Shell) {
    $fileIndex=[Array]::IndexOf($args,'-File')
    $test=[IO.Path]::GetFileNameWithoutExtension($args[$fileIndex+1])
    $global:LASTEXITCODE=0
    if ($Shell -ceq 'powershell.exe' -and $test -ceq 'Test-BuildPreflight' -and $global:CISourceCase -in @('ps51-failure','two-failures')) {$global:LASTEXITCODE=7}
    if ($Shell -ceq 'pwsh.exe' -and $test -ceq 'Test-EngineBuildPreflight' -and $global:CISourceCase -in @('ps7-failure','two-failures')) {$global:LASTEXITCODE=9}
    $global:CISourceCalls.Add([pscustomobject]@{shell=$Shell;test=$test;argv=@($args);exitCode=$global:LASTEXITCODE})
}
# Only the child process boundary is replaced; the actual CI run block is unchanged.
function powershell.exe {Invoke-CISourceChild 'powershell.exe' @args}
function pwsh.exe {Invoke-CISourceChild 'pwsh.exe' @args}
$lines=[IO.File]::ReadAllLines((Join-Path $SourceRoot '.github/workflows/ci.yml'))
$marker='      - name: Build and CI fixture checks (no vendor engine)'
$indices=@(0..($lines.Length-1)|Where-Object {$lines[$_] -ceq $marker})
Assert ($indices.Count -eq 1) 'CI source checks step present exactly once'
$run=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('ctxhop-ci-source-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($run)
if ($indices.Count -eq 1) {
    $start=$indices[0]
    $rust=[Array]::IndexOf($lines,'      - name: Prepare the pinned Rust and MSVC toolchain')
    $self=[Array]::IndexOf($lines,'      - name: Preparation runner self-checks (no vendor engine)')
    Assert ($self -ge 0 -and $self -lt $start -and $start -lt $rust) 'CI source checks precede vendor setup after existing source checks'
    Assert ($lines[$start+1] -ceq '        shell: pwsh' -and $lines[$start+2] -ceq '        run: |') 'CI source checks use declared PowerShell runner'
    $body=[Collections.Generic.List[string]]::new()
    for ($i=$start+3;$i -lt $lines.Length;$i++) {
        if ($lines[$i].StartsWith('      - ')) {break}
        if ($lines[$i].StartsWith('          ')) {$body.Add($lines[$i].Substring(10))}
        elseif ($lines[$i].Trim()) {throw 'unexpected CI source indentation'}
    }
    $block=[scriptblock]::Create(($body -join "`n"))
    $names=@('Test-BuildPreflight','Test-EngineBuildPreflight','Test-CISuiteArguments','Test-CISourceChecks')
    $order=@();foreach ($shell in @('powershell.exe','pwsh.exe')) {foreach ($test in $names) {$order+="$shell/$test"}}
    foreach ($case in @('valid','ps51-failure','ps7-failure','two-failures')) {
        $fixture=Join-Path $run ($case+' with spaces');$null=[IO.Directory]::CreateDirectory($fixture)
        $global:CISourceCase=$case;$global:CISourceCalls=[Collections.Generic.List[object]]::new()
        $before=@{};foreach ($key in @('RUNNER_TEMP','GITHUB_WORKSPACE')) {$before[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
        $message=''
        try {
            $env:RUNNER_TEMP=$fixture;$env:GITHUB_WORKSPACE=$SourceRoot
            try {& $block|Out-Null} catch {$message=$_.Exception.Message}
            $expected=switch ($case) {'valid' {''};'ps51-failure' {'failed: powershell.exe/Test-BuildPreflight'};'ps7-failure' {'failed: pwsh.exe/Test-EngineBuildPreflight'};'two-failures' {'failed: powershell.exe/Test-BuildPreflight, pwsh.exe/Test-EngineBuildPreflight'}}
            $calls=@($global:CISourceCalls.ToArray())
            Assert ($message -ceq $expected) "$case propagates child failures; got [$message]"
            Assert ($calls.Count -eq 8 -and (($calls|ForEach-Object {"$($_.shell)/$($_.test)"}) -join '|') -ceq ($order -join '|')) "$case covers both shells and four suites in order"
            $argumentsValid=$true;$workspaces=@()
            foreach ($call in $calls) {
                $argv=$call.argv;$fileIndex=[Array]::IndexOf($argv,'-File');$fixtureIndex=[Array]::IndexOf($argv,'-FixtureRoot')
                if (-not ($argv -contains '-NoProfile') -or -not ($argv -contains '-ExecutionPolicy') -or $argv[$fileIndex+1] -cne (Join-Path $SourceRoot ($call.test+'.ps1')) -or $fixtureIndex -lt 0) {$argumentsValid=$false;continue}
                $workspace=$argv[$fixtureIndex+1];$workspaces+=$workspace
                if ([IO.Path]::GetDirectoryName($workspace) -cne $fixture -or [IO.Path]::GetFileName($workspace) -notmatch '^ctxhop-build-checks-[a-f0-9]{32}$') {$argumentsValid=$false}
            }
            Assert $argumentsValid "$case uses source scripts and owned fixture arguments"
            Assert (@($workspaces|Select-Object -Unique).Count -eq 1) "$case shares one owned root with child-local GUID fixtures"
            [IO.File]::WriteAllText((Join-Path $fixture 'receipt.json'),([ordered]@{caseId=$case;expected=$expected;actual=$message;calls=$calls}|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
        } finally {foreach ($key in $before.Keys) {[Environment]::SetEnvironmentVariable($key,$before[$key],'Process')}}
    }
}
Write-Output "CI source checks: $script:Checks checks; failures=$($script:Failures.Count); fixtures=$run"
if ($script:Failures.Count) {throw "ASSERT: CI source checks failed ($($script:Failures.Count) checks)"}
