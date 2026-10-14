#requires -Version 5.1
param(
    [string]$SourceRoot = $PSScriptRoot,
    [string]$FixtureRoot = ([IO.Path]::GetTempPath())
)
$ErrorActionPreference='Stop'
$script:Checks=0
$script:Failures=[Collections.Generic.List[string]]::new()
function Assert([bool]$Value,[string]$Message) {
    $script:Checks++
    if (-not $Value) { $script:Failures.Add($Message); Write-Output "ASSERT: $Message" }
}
function Write-Utf8([string]$Path,[string]$Text) { [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false)) }

# Only the harness replaces commands; the copied public build scripts stay intact.
function git {
    $global:LASTEXITCODE=0
    if ($args -contains 'status') {
        $global:CtxHopBuildPreflightGitCalls.Add('status')
        if ($global:CtxHopBuildPreflightGitCase -like 'git-status-*') {
            $global:LASTEXITCODE=128
            if ($global:CtxHopBuildPreflightGitCase -eq 'git-status-output') { return ' M synthetic.txt' }
            return
        }
        if ($global:CtxHopBuildPreflightGitCase -eq 'git-dirty') { return ' M synthetic.txt' }
        return
    }
    if ($args -contains 'rev-parse') {
        $global:CtxHopBuildPreflightGitCalls.Add('head')
        if ($global:CtxHopBuildPreflightGitCase -like 'git-head-*') {
            $global:LASTEXITCODE=128
            if ($global:CtxHopBuildPreflightGitCase -eq 'git-head-output') { return ('1'*40) }
            return
        }
        return ('1'*40)
    }
    $global:CtxHopBuildPreflightToolCalls.Add('git')
    throw 'BUILD_TOOL_SENTINEL'
}
function Invoke-BuildToolSentinel {
    $global:CtxHopBuildPreflightToolCalls.Add('go')
    throw 'BUILD_TOOL_SENTINEL'
}
function powershell.exe {
    $global:CtxHopBuildPreflightToolCalls.Add('child-build')
    throw 'BUILD_TOOL_SENTINEL'
}

$run=Join-Path ([IO.Path]::GetFullPath($FixtureRoot)) ('ctxhop-build-preflight-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($run)
$environmentKeys=@('TMP','TEMP','GOTMPDIR','GOPATH','GOCACHE','GOFLAGS','GOEXPERIMENT','GOFIPS140','GOROOT','GOMODCACHE','GOENV','GOWORK','GOTOOLCHAIN','CGO_ENABLED','GOOS','GOARCH','GOAMD64')
$cases=@(
    @{id='engine-null';field='engineSha256';value=$null},
    @{id='engine-format';field='engineSha256';value=('A'*64)},
    @{id='normal-null';field='normalEngineSha256';value=$null},
    @{id='normal-format';field='normalEngineSha256';value='invalid'},
    @{id='loader-null';field='loaderContractId';value=$null},
    @{id='loader-format';field='loaderContractId';value=('ctxhop-prestart-v2:'+('A'*64))},
    @{id='go-missing'},
    @{id='valid'},
    @{id='git-status-empty';entry='build.ps1';error='git status failed: 128'},
    @{id='git-status-output';entry='build.ps1';error='git status failed: 128'},
    @{id='git-head-empty';entry='build.ps1';error='git rev-parse HEAD failed: 128'},
    @{id='git-head-output';entry='build.ps1';error='git rev-parse HEAD failed: 128'},
    @{id='git-dirty';entry='build.ps1';error='the working tree has uncommitted changes'}
)
foreach ($entry in @('build.ps1','build-exes.ps1')) {
    foreach ($case in $cases) {
        if ($case.entry -and $case.entry -ne $entry) { continue }
        $name=$entry.Replace('.ps1','')+'-'+$case.id
        $fixture=Join-Path $run $name
        $build=Join-Path $fixture 'build'
        $null=[IO.Directory]::CreateDirectory($build)
        $null=[IO.Directory]::CreateDirectory((Join-Path $fixture 'engine'))
        foreach ($file in @('build.ps1','build-exes.ps1','Get-BuildPins.ps1')) {
            $source=Join-Path $SourceRoot ('build/'+$file)
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $build $file) }
        }
        $provider=@{engineSha256=('a'*64);normalEngineSha256=('b'*64);loaderContractId=('ctxhop-prestart-v2:'+('c'*64))}
        if ($case.field) { $provider[$case.field]=$case.value }
        Write-Utf8 (Join-Path $fixture 'engine/provider.json') ($provider|ConvertTo-Json -Compress)
        $goPin=if ($case.id -eq 'go-missing') {'PENDING_REVIEW'} else {'D'*64}
        Write-Utf8 (Join-Path $fixture 'CodexDesktop.ps1') ("`$script:DesktopGoSHA256='$goPin'")
        $out=Join-Path $fixture 'output'
        $temp=Join-Path $fixture 'temp'
        $goWork=Join-Path $fixture 'go-work'
        $global:CtxHopBuildPreflightToolCalls=[Collections.Generic.List[string]]::new()
        $global:CtxHopBuildPreflightGitCalls=[Collections.Generic.List[string]]::new()
        $global:CtxHopBuildPreflightGitCase=$case.id
        $before=@{}
        foreach ($key in $environmentKeys) { $before[$key]=[Environment]::GetEnvironmentVariable($key,'Process') }
        $message=''
        try {
            $arguments=@{Out=$out;TempDir=$temp;GoWork=$goWork;GoExe='Invoke-BuildToolSentinel'}
            if ($entry -eq 'build.ps1') { $arguments.Tag='20261013';$arguments.NoInstaller=$true }
            try { & (Join-Path $build $entry) @arguments | Out-Null }
            catch { $message=$_.Exception.Message }
            $environmentUnchanged=$true
            foreach ($key in $environmentKeys) {
                if ([Environment]::GetEnvironmentVariable($key,'Process') -cne $before[$key]) { $environmentUnchanged=$false }
            }
            $outExists=Test-Path -LiteralPath $out
            $tempExists=Test-Path -LiteralPath $temp
            $expected=if ($case.error) {$case.error} elseif ($case.id -eq 'valid') {'BUILD_TOOL_SENTINEL'} elseif ($case.id -eq 'go-missing') {'Codex Go adapter pin is not finalized'} else {'protected provider pins are not finalized'}
            Assert ($message -ceq $expected) "$name expected pin error or positive sentinel; got [$message]"
            if ($case.id -eq 'valid') {
                $nextTool=if ($entry -eq 'build.ps1') {'child-build'} else {'go'}
                Assert ($global:CtxHopBuildPreflightToolCalls.Count -eq 1 -and $global:CtxHopBuildPreflightToolCalls[0] -ceq $nextTool) "$name reaches the next stub build stage"
                Assert ($outExists) "$name reaches output creation"
            } else {
                Assert (-not $outExists -and -not $tempExists) "$name leaves output and temp absent"
                Assert ($global:CtxHopBuildPreflightToolCalls.Count -eq 0) "$name makes no build tool calls"
                Assert ($environmentUnchanged) "$name preserves the build environment"
            }
            $receipt=[ordered]@{entryPoint=$entry;caseId=$case.id;expected=$expected;actual=$message;gitCalls=@($global:CtxHopBuildPreflightGitCalls.ToArray());toolCalls=@($global:CtxHopBuildPreflightToolCalls.ToArray());outputExists=$outExists;tempExists=$tempExists;environmentUnchanged=$environmentUnchanged}
            Write-Utf8 (Join-Path $fixture 'receipt.json') ($receipt|ConvertTo-Json -Depth 5)
        } finally {
            foreach ($key in $environmentKeys) { [Environment]::SetEnvironmentVariable($key,$before[$key],'Process') }
        }
    }
}
Write-Output "Build preflight: $script:Checks checks; failures=$($script:Failures.Count); fixtures=$run"
if ($script:Failures.Count) { throw "ASSERT: build preflight failed ($($script:Failures.Count) checks)" }
