#requires -Version 5.1
param([string]$SourceRoot=$PSScriptRoot,[string]$FixtureRoot=([IO.Path]::GetTempPath()))
$ErrorActionPreference='Stop'
foreach ($module in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Archive')) {
    Import-Module (Join-Path $PSHOME "Modules/$module/$module.psd1")
}
$script:Checks=0
$script:Failures=[Collections.Generic.List[string]]::new()
function Assert([bool]$Value,[string]$Message) {
    $script:Checks++
    if (-not $Value) { $script:Failures.Add($Message); Write-Output "ASSERT: $Message" }
}
function Write-Utf8([string]$Path,[string]$Text) { [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false)) }
function git {
    $global:LASTEXITCODE=0
    if ($args -contains 'status') {
        if ($global:CtxHopEngineGitCase -like 'git-status-*') { & $global:CtxHopEngineGitStatusTool @args; return }
        if ($global:CtxHopEngineGitCase -eq 'git-dirty') { return ' M synthetic.txt' }
        return
    }
    if ($args -contains 'archive') {
        $global:CtxHopEngineArchiveCalls++
        $zip=$args[[Array]::IndexOf($args,'-o')+1]
        Compress-Archive -LiteralPath $global:CtxHopEngineFixtureEngine -DestinationPath $zip
        return
    }
    $global:CtxHopEngineSourceCalls.Add(($args -join ' '))
    throw 'SOURCE_INIT_SENTINEL'
}
function Write-VersionTool([string]$Path,[string]$Version,[int]$ExitCode) {
    $output=if ($Version) { "echo $Version`r`n" } else { '' }
    # This is a real native process; version output and exit status vary independently.
    $text="@echo off`r`necho %*>> `"%~dp0tool-calls.txt`"`r`n"+$output+"exit /b $ExitCode`r`n"
    [IO.File]::WriteAllText($Path,$text,[Text.ASCIIEncoding]::new())
}
$run=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('ctxhop-engine-preflight-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($run)
$cases=@(
    @{id='cargo-fail-version';tool='cargo';version='cargo 1.95.0 (fixture)';exit=42},
    @{id='cargo-fail-empty';tool='cargo';version='';exit=42},
    @{id='rustc-fail-version';tool='rustc';version='rustc 1.95.0 (fixture)';exit=42},
    @{id='rustc-fail-empty';tool='rustc';version='';exit=42},
    @{id='cargo-wrong-version';tool='cargo';version='cargo 1.94.0 (fixture)';exit=0},
    @{id='rustc-wrong-version';tool='rustc';version='rustc 1.94.0 (fixture)';exit=0},
    @{id='valid';exit=0},
    @{id='git-status-empty';exit=0},
    @{id='git-status-output';exit=0},
    @{id='git-dirty';exit=0}
)
$keys=@('RUSTC','TEMP','TMP','CARGO_TARGET_DIR','CTXHOP_LOADER_CONTRACT_ID','CTXHOP_NORMAL_ENGINE_SHA256','STABLE_GIT_COMMIT','RUSTFLAGS','CARGO_ENCODED_RUSTFLAGS','CARGO_INCREMENTAL','SOURCE_DATE_EPOCH')
foreach ($case in $cases) {
    $fixture=Join-Path $run $case.id
    $build=Join-Path $fixture 'build'
    $engine=Join-Path $fixture 'engine'
    $null=[IO.Directory]::CreateDirectory($build)
    $null=[IO.Directory]::CreateDirectory((Join-Path $engine 'patches'))
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'build/build-codex-engine.ps1') -Destination (Join-Path $build 'build-codex-engine.ps1')
    $patch=Join-Path $engine 'patches/fixture.patch'
    Write-Utf8 $patch 'synthetic patch bytes; never applied'
    $provider=@{schemaVersion=1;baseCommit=('a'*40);target='x86_64-pc-windows-msvc';rustVersion='1.95.0';migrationLineEndings='CRLF';normalEngineSha256=('b'*64);engineSha256=('c'*64);loaderContractId=('ctxhop-prestart-v2:'+('d'*64));patches=@(@{path='patches/fixture.patch';sha256=(Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.ToLowerInvariant()})}
    Write-Utf8 (Join-Path $engine 'provider.json') ($provider|ConvertTo-Json -Depth 4)
    $cargo=Join-Path $fixture 'cargo.cmd';$rustc=Join-Path $fixture 'rustc.cmd'
    foreach ($tool in @('cargo','rustc')) {
        $version=if ($case.tool -eq $tool) {$case.version} else {"$tool 1.95.0 (fixture)"}
        $exit=if ($case.tool -eq $tool) {$case.exit} else {0}
        Write-VersionTool (Join-Path $fixture "$tool.cmd") $version $exit
    }
    $global:CtxHopEngineFixtureEngine=$engine
    $global:CtxHopEngineGitCase=$case.id
    $global:CtxHopEngineArchiveCalls=0
    $global:CtxHopEngineGitStatusTool=Join-Path $fixture 'git-status.cmd'
    $statusOutput=if ($case.id -eq 'git-status-output') {"echo  M synthetic.txt"} else {''}
    [IO.File]::WriteAllText($global:CtxHopEngineGitStatusTool,("@echo off`r`n"+$statusOutput+"`r`nexit /b 128`r`n"),[Text.ASCIIEncoding]::new())
    $global:CtxHopEngineSourceCalls=[Collections.Generic.List[string]]::new()
    $before=@{};foreach ($key in $keys) {$before[$key]=[Environment]::GetEnvironmentVariable($key,'Process')}
    $message=''
    try {
        $env:RUSTC=$rustc
        try { & (Join-Path $build 'build-codex-engine.ps1') -Out (Join-Path $fixture 'output') -CargoExe $cargo -VerifyPin | Out-Null }
        catch { $message=$_.Exception.Message }
        $expected=if ($case.id -like 'git-status-*') {'git exited 128'} elseif ($case.id -eq 'git-dirty') {'the working tree has uncommitted changes'} elseif ($case.exit -eq 42) {"$(Join-Path $fixture ($case.tool+'.cmd')) exited 42"} elseif ($case.tool) {"need $($case.tool) 1.95.0"} else {'SOURCE_INIT_SENTINEL'}
        Assert ($message -ceq $expected) "$($case.id) expected version error; got [$message]"
        $sourceCount=if ($case.id -eq 'valid') {1} else {0}
        Assert ($global:CtxHopEngineSourceCalls.Count -eq $sourceCount) "$($case.id) source preparation boundary"
        $calls=if (Test-Path -LiteralPath (Join-Path $fixture 'tool-calls.txt')) {@(Get-Content -LiteralPath (Join-Path $fixture 'tool-calls.txt'))} else {@()}
        $versionCount=if ($case.id -like 'git-*') {0} elseif ($case.tool -eq 'cargo') {1} else {2}
        Assert ($calls.Count -eq $versionCount -and @($calls|Where-Object {$_ -cne '--version'}).Count -eq 0) "$($case.id) only required version commands run"
        $outputExpected=$case.id -notlike 'git-*'
        $outputExists=Test-Path -LiteralPath (Join-Path $fixture 'output')
        $archiveExpected=if ($outputExpected) {1} else {0}
        Assert ($outputExists -eq $outputExpected -and $global:CtxHopEngineArchiveCalls -eq $archiveExpected) "$($case.id) output/archive boundary"
        $unchanged=$true
        foreach ($key in $keys) {if ($key -ne 'RUSTC' -and [Environment]::GetEnvironmentVariable($key,'Process') -cne $before[$key]) {$unchanged=$false}}
        Assert ($unchanged) "$($case.id) preserves compiler environment"
        Write-Utf8 (Join-Path $fixture 'receipt.json') ([ordered]@{caseId=$case.id;expected=$expected;actual=$message;versionCalls=$calls;sourceCalls=@($global:CtxHopEngineSourceCalls.ToArray());environmentUnchanged=$unchanged;outputExists=$outputExists;archiveCalls=$global:CtxHopEngineArchiveCalls}|ConvertTo-Json -Depth 4)
    } finally {foreach ($key in $keys) {[Environment]::SetEnvironmentVariable($key,$before[$key],'Process')}}
}
Write-Output "Engine preflight: $script:Checks checks; failures=$($script:Failures.Count); fixtures=$run"
if ($script:Failures.Count) {throw "ASSERT: engine preflight failed ($($script:Failures.Count) checks)"}
