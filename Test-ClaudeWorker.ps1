#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# All native calls and process queries are mocked; one group compiles its own fixture exe in the temporary root.
# Only this new temporary root is mutated.
$script:Assertions = 0
$script:Failures = @()
$script:Groups = 0
$script:Root = Join-Path ([IO.Path]::GetTempPath()) ('CtxHopGUI-worker-tests-' + [guid]::NewGuid().ToString('N'))
$script:TestOperationMutexName = 'Local\CtxHopGUI-test-operation-' + [guid]::NewGuid().ToString('N')
$savedEnvironment = @{}
foreach ($name in @('CODEX_HOME','CLAUDE_CONFIG_DIR','CTXHOP_CONFIG_DIR')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$savedLocation = Get-Location

function Assert([bool]$Condition, [string]$Message) {
    $script:Assertions++
    if (-not $Condition) { throw "ASSERT: $Message" }
}
function Assert-Throws([scriptblock]$Body, [string]$Pattern, [string]$Message) {
    $caught = $null
    try { & $Body | Out-Null } catch { $caught = $_ }
    Assert ($null -ne $caught) "$Message must throw"
    if ($caught) { Assert ($caught.Exception.Message -match $Pattern) "$Message wrong exception: $($caught.Exception.Message)" }
}
function Test-Group([string]$Name, [scriptblock]$Action) {
    $script:Groups++
    try { Reset-Fixture; & $Action; Write-Host "PASS: $Name" }
    catch {
        $script:Failures += "$Name : $($_.Exception.Message) [line $($_.InvocationInfo.ScriptLineNumber)]"
        Write-Host "FAIL: $($script:Failures[-1])" -ForegroundColor Red
    }
}
function Write-TestJson([string]$Path, [object]$Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30 -Compress), [Text.UTF8Encoding]::new($false))
}
function New-Preview([string]$Agent = 'claude-code', [string]$Id = $script:ClaudeId) {
    $result=[pscustomobject]@{ preview=$true; session=$Id; agent=$Agent; title='synthetic conversation'; workspace='consistent'; differences=0; replaced=$false; merged=$false; contextInjected=$false; sources=@(); environmentSkipped=$true }
    if ($Agent -eq 'codex') { $result | Add-Member localState 'exact' }
    return $result
}
function New-Job([string]$Action, [string]$Agent = 'claude-code') {
    $id = if ($Agent -eq 'codex') { $script:CodexId } else { $script:ClaudeId }
    $remote = if ($Agent -eq 'codex') { $script:CodexRemote } else { $script:ClaudeRemote }
    [pscustomobject]@{ action=$Action; agent=$Agent; projectPath=$script:Project; identity='synthetic-project'; nativeId=$id; remoteId=$remote }
}
function Write-Claude([string]$Id = $script:ClaudeId, [string]$Cwd = $script:Project, [string]$File = $script:ClaudeFile, [string]$Text = 'original synthetic text') {
    $record = @{type='user'; sessionId=$Id; cwd=$Cwd; version='2.1.1'; uuid=[guid]::NewGuid().ToString(); message=@{role='user'; content=$Text}}
    Write-TestJson $File $record
}
function Write-Codex([string]$Id = $script:CodexId, [string]$Cwd = $script:Project, [object]$Mode = $null, [string]$Originator = 'codex_cli_rs', [string]$Source = 'cli', [string]$Version = '0.116.0', [string]$File = $script:CodexFile) {
    $payload = @{ id=$Id; cwd=$Cwd; cli_version=$Version; originator=$Originator; source=$Source }
    if ($null -ne $Mode) { $payload.history_mode=$Mode }
    Write-TestJson $File @{type='session_meta'; payload=$payload}
}
function Reset-Fixture {
    # Each group gets its own new directories; retained failure journals never affect another group.
    $script:CaseRoot = Join-Path $script:Root ([guid]::NewGuid().ToString('N'))
    $script:Project = Join-Path $script:CaseRoot 'project'
    $env:CODEX_HOME = Join-Path $script:CaseRoot 'codex'
    $env:CLAUDE_CONFIG_DIR = Join-Path $script:CaseRoot 'claude'
    $env:CTXHOP_CONFIG_DIR = Join-Path $script:CaseRoot 'ctxhop'
    $script:TestJournalRoot = Join-Path $script:CaseRoot 'recovery'
    $codexSessions = Join-Path $env:CODEX_HOME 'sessions'
    $claudeProject = Join-Path $env:CLAUDE_CONFIG_DIR 'projects\synthetic-project'
    foreach ($path in @($script:Project,$codexSessions,$claudeProject,$env:CTXHOP_CONFIG_DIR)) { New-Item -ItemType Directory -Path $path | Out-Null }
    $script:ClaudeId = '11111111-1111-4111-8111-111111111111'
    $script:CodexId = '22222222-2222-4222-8222-222222222222'
    $script:OtherId = '33333333-3333-4333-8333-333333333333'
    $script:ClaudeRemote = 'a' * 26
    $script:CodexRemote = 'b' * 26
    $script:ClaudeFile = Join-Path $claudeProject "$($script:ClaudeId).jsonl"
    $script:CodexFile = Join-Path $codexSessions "rollout-synthetic-$($script:CodexId).jsonl"
    Write-Claude
    Write-Codex
    $script:Config = [pscustomobject]@{ syncConfig='disabled'; projects=@{bindings=@(@{localRoot=$script:Project; identity='synthetic-project'})} }
    Write-TestJson (Join-Path $env:CTXHOP_CONFIG_DIR 'config.json') $script:Config
    $script:ListReport = [pscustomobject]@{scope='project'; sessions=@(
        [pscustomobject]@{agent='claude-code'; nativeId=$script:ClaudeId; remoteId=$script:ClaudeRemote; local=$true; recordCount=3},
        [pscustomobject]@{agent='codex'; nativeId=$script:CodexId; remoteId=$script:CodexRemote; local=$true; recordCount=3}
    )}
    $script:Preview = New-Preview
    $script:CtxCalls = @()
    $script:NativeCalls = @()
    $script:Processes = @()
    $script:ProcessQueryError = $false
    $script:ApplyBehavior = 'valid'
    $script:ApplyAgent = 'claude-code'
    $script:SidecarResult = [pscustomobject]@{state='restored'; files=3; written=2; unchanged=1; backedUp=1}
    $script:RuntimeChecks = 0
    $script:RuntimeAllowed = $true
    $script:SkipMarkerPresent = $true
    $script:SkipMarkerValue = $true
    $script:FakeCodexVersion = 'codex-cli 0.116.0'
    $script:FakeCtxVersion = 'ctxhop 0.2.0'
    $script:FakeCtxRaw = '{invalid json'
    $script:RelocateBehavior = 'apply'
    $script:BeforeHash = (Get-FileHash -LiteralPath $script:ClaudeFile -Algorithm SHA256).Hash
    $script:CodexBeforeHash = (Get-FileHash -LiteralPath $script:CodexFile -Algorithm SHA256).Hash
}
function Get-ApplyCalls { @($script:CtxCalls | Where-Object {$_.Arguments[0] -eq 'resume' -and $_.Arguments -notcontains '--preview'}) }
function Assert-RejectedBeforeApply([object]$Job, [string]$Pattern, [string]$Message) {
    $before = @(Get-ApplyCalls).Count
    Assert-Throws { Invoke-Job $Job } $Pattern $Message
    Assert (@(Get-ApplyCalls).Count -eq $before) "$Message reached actual restore"
}
function Read-Pending {
    $pending = @(Get-ChildItem -LiteralPath $script:TestJournalRoot -Filter '*.pending.json' -File)
    Assert ($pending.Count -eq 1) 'exactly one pending journal must remain'
    Get-Content -LiteralPath $pending[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Assert-OriginalJournal([object]$Record, [string]$Agent = 'claude-code') {
    $isCodex=$Agent -eq 'codex'
    $file=if ($isCodex) {$script:CodexFile} else {$script:ClaudeFile}
    $hash=if ($isCodex) {$script:CodexBeforeHash} else {$script:BeforeHash}
    $id=if ($isCodex) {$script:CodexId} else {$script:ClaudeId}
    $remote=if ($isCodex) {$script:CodexRemote} else {$script:ClaudeRemote}
    $originals=@($Record.originals)
    Assert ($originals.Count -eq 1) 'one original must be backed up'
    Assert ($originals[0].original -eq $file) 'journal must identify the actual native original'
    Assert ($originals[0].sha256 -eq $hash) 'journal must record the original SHA256'
    Assert ((Get-FileHash -LiteralPath $originals[0].backup -Algorithm SHA256).Hash -eq $hash) 'backup bytes must match original SHA256'
    Assert ($Record.nativeId -eq $id -and $Record.remoteId -eq $remote -and $Record.agent -eq $Agent -and $Record.projectPath -eq $script:Project) 'journal must bind IDs, agent and project'
}
function New-RestoreResult([string]$Id, [string]$Agent) {
    $result=[pscustomobject]@{session=$Id; agent=$Agent; workspace='consistent'}
    if ($script:SkipMarkerPresent) { $result | Add-Member environmentSkipped $script:SkipMarkerValue }
    if ($Agent -eq 'claude-code' -and $null -ne $script:SidecarResult) { $result | Add-Member sidecar $script:SidecarResult }
    return $result
}
function Invoke-IsolatedRestoreGate([string]$Exe, [string]$Hash, [string]$Version, [switch]$HashFailure) {
    # Test the captured real gate with all external reads mocked, without opening or executing an exe.
    & {
        param($fakeExe,$fakeHash,$fakeVersion,$hashFailure)
        function Find-Executable([string]$Name) {
            Assert ($Name -eq 'ctxhop') 'runtime gate requests only ctxhop'
            return $fakeExe
        }
        function Get-FileHash([string]$LiteralPath, [string]$Algorithm) {
            Assert ($LiteralPath -eq $fakeExe -and $Algorithm -eq 'SHA256') 'runtime gate hashes selected exe with SHA256'
            if ($hashFailure) { throw 'synthetic runtime hash read failure' }
            return [pscustomobject]@{Hash=$fakeHash}
        }
        function Get-CtxVersion { return $fakeVersion }
        & $script:RealRestoreRuntime
    } $Exe $Hash $Version ([bool]$HashFailure)
}

try {
    New-Item -ItemType Directory -Path $script:Root | Out-Null
    . (Join-Path $PSScriptRoot 'ClaudeWorker.ps1') -LibraryOnly
    $script:RealInvokeCtx = (Get-Item Function:Invoke-Ctx).ScriptBlock
    $script:RealFindExecutable = (Get-Item Function:Find-Executable).ScriptBlock
    $script:RealRestoreRuntime = (Get-Item Function:Assert-RestoreRuntime).ScriptBlock
    $script:RealOperationMutexName = (Get-Item Function:Get-OperationMutexName).ScriptBlock
    function Get-OperationMutexName { return $script:TestOperationMutexName }
    function Assert-RestoreRuntime {
        $script:RuntimeChecks++
        if (-not $script:RuntimeAllowed) { throw 'synthetic untrusted restore runtime' }
    }
    function Find-Executable([string]$Name) {
        switch ($Name) {
            ctxhop { return 'Invoke-FakeCtx' }
            codex { return 'Invoke-FakeCodex' }
            claude { return 'Invoke-FakeClaude' }
            default { throw "Test refuses an unknown native executable: $Name" }
        }
    }
    function Invoke-FakeCtx {
        $script:NativeCalls += [pscustomobject]@{Name='ctxhop'; Arguments=@($args)}
        $global:LASTEXITCODE=0
        if ($args[0] -eq 'version') { return $script:FakeCtxVersion }
        return $script:FakeCtxRaw
    }
    function Invoke-FakeCodex {
        $script:NativeCalls += [pscustomobject]@{Name='codex'; Arguments=@($args)}
        $global:LASTEXITCODE=0
        if ($args[0] -eq '--version') { return $script:FakeCodexVersion }
    }
    function Invoke-FakeClaude {
        $script:NativeCalls += [pscustomobject]@{Name='claude'; Arguments=@($args)}
        $global:LASTEXITCODE=0
    }
    function Get-CimInstance {
        if ($script:ProcessQueryError) { throw 'synthetic process query failure' }
        return $script:Processes
    }
    function Invoke-Ctx([string[]]$Arguments, [switch]$Json) {
        $script:CtxCalls += [pscustomobject]@{Arguments=@($Arguments); Json=[bool]$Json}
        switch ($Arguments[0]) {
            list { return $script:ListReport }
            push { return }
            project { return }
            passphrase { return }
            remote {
                # remote relocate: 실제 ctxhop처럼 설정의 저장소 경로를 바꾸거나(apply), 실패하거나(fail), 아무것도 바꾸지 않는다(ignore).
                if ($script:RelocateBehavior -eq 'fail') { throw 'synthetic relocate failure' }
                if ($script:RelocateBehavior -eq 'apply') {
                    # 실제 ctxhop은 새 폴더에 같은 연결의 키 파일이 없으면 거부한다.
                    if (-not (Test-Path -LiteralPath (Join-Path $Arguments[3] 'v1\keyfile'))) { throw 'synthetic relocate: no store at the new path' }
                    $file=Join-Path $env:CTXHOP_CONFIG_DIR 'config.json'
                    $config=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
                    $config.remote.path=$Arguments[3]
                    Write-TestJson $file $config
                }
                return
            }
            resume {
                Assert ($Arguments -contains '--no-environment') 'every preview and actual resume must disable receiving environment application'
                if ($Arguments -contains '--preview') { return $script:Preview }
                # This observation occurs at the boundary before the mocked restore writes anything.
                $pending=Read-Pending
                $agentIndex=[array]::IndexOf($Arguments,'--agent')
                $selectedAgent=$Arguments[$agentIndex+1]
                # Claude 옆 폴더에서 바뀌는 파일의 원본은 이 복원 기록 옆 .companion 폴더에 남긴다. Codex CLI는 옆 폴더가 없다.
                $companion=@(Get-ChildItem -LiteralPath $script:TestJournalRoot -Filter '*.pending.json' -File)[0].FullName.Replace('.pending.json','.companion')
                $backupIndex=[array]::IndexOf($Arguments,'--sidecar-backup')
                if ($selectedAgent -eq 'codex') { Assert ($backupIndex -lt 0 -and $null -eq $pending.companionBackup) 'Codex restore has no companion backup' }
                else { Assert ($backupIndex -ge 0 -and $Arguments[$backupIndex+1] -eq $companion -and $pending.companionBackup -eq $companion -and $Arguments[-1] -notmatch 'companion') 'Claude restore keeps replaced companion files beside its journal' }
                if ($selectedAgent -eq 'codex') {
                    Assert-OriginalJournal $pending 'codex'
                    Write-Codex
                    [IO.File]::AppendAllText($script:CodexFile,"`n" + '{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}',[Text.UTF8Encoding]::new($false))
                    return (New-RestoreResult $script:CodexId 'codex')
                }
                if (Test-Path -LiteralPath $script:ClaudeFile) { Assert-OriginalJournal $pending }
                switch ($script:ApplyBehavior) {
                    partial { Write-Claude -Text 'partial synthetic restore'; throw 'synthetic partial restore failure' }
                    wrong-file-id { Write-Claude -Id $script:OtherId -Text 'synthetic wrong ID' }
                    wrong-file-cwd { Write-Claude -Cwd $script:CaseRoot -Text 'synthetic wrong project' }
                    default { Write-Claude -Text 'restored synthetic text' }
                }
                $id=if ($script:ApplyBehavior -eq 'wrong-result-id') {$script:OtherId} else {$script:ClaudeId}
                $agent=if ($script:ApplyBehavior -eq 'wrong-result-agent') {'codex'} else {'claude-code'}
                return (New-RestoreResult $id $agent)
            }
            default { throw "Test refuses an unexpected ctxhop command: $($Arguments -join ' ')" }
        }
    }

    Test-Group 'production mutex default and isolated test mutex naming' {
        Assert ((& $script:RealOperationMutexName) -eq 'Local\CtxHopGUI-operation') 'production operation mutex default must remain unchanged'
        Assert ((Get-OperationMutexName) -eq $script:TestOperationMutexName -and $script:TestOperationMutexName -ne 'Local\CtxHopGUI-operation') 'tests must use their own generated operation mutex'
    }
    Test-Group 'same isolated mutex rejects concurrent jobs and releases for later jobs' {
        $ready=[Threading.ManualResetEvent]::new($false)
        $release=[Threading.ManualResetEvent]::new($false)
        $holder=[PowerShell]::Create()
        $async=$null
        try {
            $null=$holder.AddScript({
                param($name,$ready,$release)
                $mutex=[Threading.Mutex]::new($false,$name)
                $held=$false
                try {
                    $held=$mutex.WaitOne(5000)
                    if (-not $held) { throw 'synthetic mutex holder could not acquire test mutex' }
                    $null=$ready.Set()
                    $null=$release.WaitOne(10000)
                } finally { if ($held) {$mutex.ReleaseMutex()}; $mutex.Dispose() }
            }).AddArgument((Get-OperationMutexName)).AddArgument($ready).AddArgument($release)
            $async=$holder.BeginInvoke()
            Assert ($ready.WaitOne(5000)) 'separate test runspace must acquire the same isolated mutex'
            Assert-Throws { Invoke-Job (New-Job 'Backup') } '다른 CtxHop GUI' 'concurrent test job rejected'
            Assert ($script:CtxCalls.Count -eq 0 -and $script:NativeCalls.Count -eq 0) 'mutex conflict must reject before native or ctxhop calls'
        } finally {
            $null=$release.Set()
            if ($async) { $null=$holder.EndInvoke($async) }
            $holder.Dispose(); $ready.Dispose(); $release.Dispose()
        }
        $null=Invoke-Job (New-Job 'Backup')
        Assert (@($script:CtxCalls | Where-Object {$_.Arguments[0] -eq 'push'}).Count -eq 1) 'released isolated mutex permits the next test job'
    }
    Test-Group 'native UUID and lowercase Crockford remote ID validation' {
        Assert-NativeId $script:ClaudeId
        Assert-RemoteId $script:ClaudeRemote
        Assert-RemoteId '0123456789abcdefghjkmnpqrs'
        Assert ($true) 'valid IDs accepted'
        foreach ($bad in @('--workspace','--replace-existing',($script:ClaudeId.Replace('-','')),('{' + $script:ClaudeId + '}'),'not-a-guid')) {
            Assert-Throws { Assert-NativeId $bad } 'UUID' "native ID $bad"
        }
        foreach ($bad in @('--workspace','--replace-existing',$script:ClaudeId,('a'*64),('a'*25),('A'*26),('i'*26),('o'*26),('l'*26),('u'*26))) {
            Assert-Throws { Assert-RemoteId $bad } 'ID' "remote ID $bad"
        }
    }
    Test-Group 'list schema and per-agent filtering' {
        foreach ($agent in @('claude-code','codex')) {
            $items=@(Get-AgentSessions $agent)
            Assert ($items.Count -eq 1 -and $items[0].agent -eq $agent) "$agent list must contain only that agent"
        }
        $script:ListReport.scope='global'
        Assert-Throws { Get-AgentSessions 'claude-code' } '목록' 'global list rejected'
        $script:ListReport.scope='project'
        $script:ListReport.sessions[0].local='true'
        Assert (@(Get-AgentSessions 'claude-code').Count -eq 0) 'non-boolean local entry excluded'
        Assert ($script:UnknownMetadata -eq 1) 'excluded metadata count recorded'
        Assert (@(Get-AgentSessions 'codex').Count -eq 1) 'unknown Claude metadata does not block valid Codex entry'
        $script:ListReport.sessions[0].local=$true
        $script:ListReport.sessions[0].remoteId='--workspace'
        Assert (@(Get-AgentSessions 'claude-code').Count -eq 0) 'unsafe remote ID in list excluded'
        Assert ($script:UnknownMetadata -eq 1) 'unsafe remote ID counted as excluded'
        $script:ListReport.sessions=$null
        Assert-Throws { Get-AgentSessions 'claude-code' } '목록' 'missing sessions array rejected'
    }
    Test-Group 'backup reaches only selected native ID for both agents' {
        foreach ($agent in @('claude-code','codex')) {
            $job=New-Job 'Backup' $agent
            $null=Invoke-Job $job
            $push=@($script:CtxCalls | Where-Object {$_.Arguments[0] -eq 'push'})[-1]
            Assert ($push.Arguments.Count -eq 2 -and $push.Arguments[1] -eq $job.nativeId) "$agent push must use native UUID"
        }
        Assert ((Get-FileHash -LiteralPath $script:ClaudeFile -Algorithm SHA256).Hash -eq $script:BeforeHash) 'mock backup must preserve original bytes'
        $script:Config.syncConfig='enabled'
        Write-TestJson (Join-Path $env:CTXHOP_CONFIG_DIR 'config.json') $script:Config
        $before=@($script:CtxCalls | Where-Object {$_.Arguments[0] -eq 'push'}).Count
        Assert-Throws { Invoke-Job (New-Job 'Backup') } 'disabled' 'backup refuses config sync enabled'
        Assert (@($script:CtxCalls | Where-Object {$_.Arguments[0] -eq 'push'}).Count -eq $before) 'config rejection must occur before push'
    }
    Test-Group 'preview uses remote ID, chosen agent and no workspace context' {
        foreach ($agent in @('claude-code','codex')) {
            $job=New-Job 'Preview' $agent
            $script:Preview=New-Preview $agent $job.nativeId
            $result=Invoke-Job $job
            $call=@($script:CtxCalls | Where-Object {$_.Arguments[0] -eq 'resume'})[-1]
            Assert ($result.preview.session -eq $job.nativeId) "$agent preview native ID"
            Assert ($call.Arguments[-1] -eq $job.remoteId) "$agent preview must use remote ID"
            Assert ($call.Arguments -contains '--preview' -and $call.Arguments -contains '--json' -and $call.Arguments -contains '--no-workspace-context' -and $call.Arguments -contains '--no-environment') 'preview flags'
            $agentIndex=[array]::IndexOf($call.Arguments,'--agent')
            Assert ($agentIndex -ge 0 -and $call.Arguments[$agentIndex+1] -eq $agent) 'preview must explicitly bind agent'
            Assert ($call.Arguments -notcontains '--workspace' -and $call.Arguments -notcontains '--replace-existing' -and $call.Arguments -notcontains '--allow-limited') 'no workspace/overwrite/compatibility bypass'
        }
        Assert (@(Get-ApplyCalls).Count -eq 0) 'preview never calls apply'
        Assert ($script:RuntimeChecks -eq 2) 'each agent preview must verify the trusted bundled runtime'
    }
    Test-Group 'preview and restore cannot proceed through an untrusted runtime' {
        $script:RuntimeAllowed=$false
        foreach ($action in @('Preview','Restore')) {
            Assert-RejectedBeforeApply (New-Job $action) 'untrusted restore runtime' "$action runtime gate"
        }
        Assert ($script:RuntimeChecks -eq 2) 'both preview and restore invoke runtime verification'
        Assert (@($script:CtxCalls | Where-Object {$_.Arguments[0] -eq 'resume'}).Count -eq 0) 'untrusted runtime cannot reach any resume'
        Assert (-not (Test-Path -LiteralPath $script:TestJournalRoot)) 'untrusted runtime cannot begin restore journal'
    }
    Test-Group 'option injection never reaches push or resume' {
        foreach ($field in @('nativeId','remoteId')) {
            foreach ($bad in @('--workspace','--replace-existing')) {
                foreach ($action in @('Backup','Preview','Restore','Open')) {
                    $job=New-Job $action
                    $job.$field=$bad
                    Assert-Throws { Invoke-Job $job } 'UUID|ID' "$action $field option rejected"
                }
            }
        }
        Assert ($script:CtxCalls.Count -eq 0) 'invalid selected IDs must fail before ctxhop list/push/resume'
        Assert (@($script:NativeCalls | Where-Object {$_.Arguments[0] -ne 'version'}).Count -eq 0) 'invalid selected IDs must never open native agents'
    }
    Test-Group 'preview response binds true, expected ID, agent and required fields' {
        foreach ($variant in @('false','string-true','wrong-id','wrong-agent','missing-preview','missing-sources','missing-environmentSkipped','skip-false','skip-string','skip-null','string-differences','negative-differences','unknown-workspace','replaced-string','merged-string','context-string','replaced-true','merged-true','context-true','sources-string','ahead','diverged','incompatible')) {
            $script:Preview=New-Preview
            switch ($variant) {
                false { $script:Preview.preview=$false }
                string-true { $script:Preview.preview='true' }
                wrong-id { $script:Preview.session=$script:OtherId }
                wrong-agent { $script:Preview.agent='codex' }
                missing-preview { $script:Preview.PSObject.Properties.Remove('preview') }
                missing-sources { $script:Preview.PSObject.Properties.Remove('sources') }
                missing-environmentSkipped { $script:Preview.PSObject.Properties.Remove('environmentSkipped') }
                skip-false { $script:Preview.environmentSkipped=$false }
                skip-string { $script:Preview.environmentSkipped='true' }
                skip-null { $script:Preview.environmentSkipped=$null }
                string-differences { $script:Preview.differences='0' }
                negative-differences { $script:Preview.differences=-1 }
                unknown-workspace { $script:Preview.workspace='future-state' }
                replaced-string { $script:Preview.replaced='false' }
                merged-string { $script:Preview.merged='false' }
                context-string { $script:Preview.contextInjected='false' }
                replaced-true { $script:Preview.replaced=$true }
                merged-true { $script:Preview.merged=$true }
                context-true { $script:Preview.contextInjected=$true }
                sources-string { $script:Preview.sources='unexpected source' }
                default { $script:Preview | Add-Member localState $variant }
            }
            Assert-RejectedBeforeApply (New-Job 'Restore') '미리보기|로컬 대화' "preview $variant"
        }
    }
    Test-Group 'actual v0.2.0 preview null sources is a known safe schema' {
        $script:Preview.sources=$null
        $result=Invoke-Job (New-Job 'Preview')
        Assert ($result.preview.preview -eq $true -and $result.preview.session -eq $script:ClaudeId) 'nil []string sources from v0.2.0 preview accepted'
        Assert (@(Get-ApplyCalls).Count -eq 0) 'null sources preview remains read-only'
    }
    Test-Group 'disabled config cannot authorize receiving environment components or changes' {
        foreach ($field in @('components','changes')) {
            $script:Preview=New-Preview
            $environment=[pscustomobject]@{status='observed-only'; components=@(); changes=@()}
            $environment.$field=@([pscustomobject]@{kind='settings'; content='synthetic untrusted config'})
            $script:Preview | Add-Member environment $environment
            Assert-RejectedBeforeApply (New-Job 'Restore') '환경 설정' "receiving $field with syncConfig disabled"
        }
        $script:Preview=New-Preview
        $script:Preview | Add-Member environment ([pscustomobject]@{status='future-schema'; components=@(); changes=@()})
        Assert-RejectedBeforeApply (New-Job 'Restore') '환경 설정' 'unknown receiving environment status'
    }
    Test-Group 'non-empty falsy environment arrays cannot bypass receiving guard' {
        foreach ($field in @('components','changes')) {
            foreach ($value in @($false,0,'')) {
                $script:Preview=New-Preview
                $environment=[pscustomobject]@{status='observed-only'; components=@(); changes=@()}
                $environment.$field=@($value)
                $script:Preview | Add-Member environment $environment
                Assert-RejectedBeforeApply (New-Job 'Restore') '환경|형식|미리보기' "non-empty $field containing falsy value"
            }
        }
    }
    Test-Group 'invalid JSON from native ctxhop is rejected by actual JSON wrapper' {
        Assert-Throws { & $script:RealInvokeCtx -Arguments @('list','--json') -Json } 'JSON|json|primitive|기본|개체|속성|Invalid' 'malformed JSON response'
        Assert (@(Get-ApplyCalls).Count -eq 0) 'invalid JSON cannot restore'
        Assert ($script:NativeCalls[-1].Name -eq 'ctxhop') 'actual JSON wrapper reached only fake ctxhop'
    }
    Test-Group 'writer process matrix and unrelated node allowance' {
        foreach ($name in @('codex.exe','codex-app.exe','codex-code-mode-host.exe','code-mode-host.exe','Code.exe','Cursor.exe','Windsurf.exe')) {
            $script:Processes=@([pscustomobject]@{Name=$name; CommandLine='synthetic writer'; ProcessId=101})
            Assert-Throws { Assert-AgentClosed 'codex' } '실행 중' "Codex writer $name"
        }
        foreach ($command in @('node C:\npm\node_modules\@openai\codex\bin\codex.js app-server','node codex app-server')) {
            $script:Processes=@([pscustomobject]@{Name='node.exe'; CommandLine=$command; ProcessId=102})
            Assert-Throws { Assert-AgentClosed 'codex' } '실행 중' 'Codex node writer'
        }
        foreach ($name in @('claude.exe','claude-code.exe')) {
            $script:Processes=@([pscustomobject]@{Name=$name; CommandLine='synthetic writer'; ProcessId=103})
            Assert-Throws { Assert-AgentClosed 'claude-code' } '실행 중' "Claude writer $name"
        }
        $script:Processes=@([pscustomobject]@{Name='node.exe'; CommandLine='node C:\npm\node_modules\@anthropic-ai\claude-code\cli.js'; ProcessId=104})
        Assert-Throws { Assert-AgentClosed 'claude-code' } '실행 중' 'Claude node writer'
        foreach ($command in @('node C:\synthetic\ordinary-server.js',$null)) {
            $script:Processes=@([pscustomobject]@{Name='node.exe'; CommandLine=$command; ProcessId=105})
            Assert-AgentClosed 'codex'; Assert-AgentClosed 'claude-code'
            Assert ($true) 'unrelated node accepted for both agents'
        }
        $script:ProcessQueryError=$true
        Assert-Throws { Assert-AgentClosed 'codex' } 'query failure' 'process query failure is closed'
    }
    Test-Group 'native file metadata verifies actual UUID and project mapping' {
        foreach ($agent in @('claude-code','codex')) {
            $job=New-Job 'Backup' $agent
            $meta=Assert-NativeMapping $agent $job.nativeId $job.projectPath -Required
            Assert ($meta.id -eq $job.nativeId -and $meta.cwd -eq $job.projectPath) "$agent native mapping accepted"
        }
        Write-Claude -Id $script:OtherId
        Assert-Throws { Invoke-Job (New-Job 'Backup') } '실제 ID|프로젝트' 'Claude mismatched content UUID'
        Write-Claude -Cwd $script:CaseRoot
        Assert-Throws { Invoke-Job (New-Job 'Open') } '실제 ID|프로젝트' 'Claude mismatched content project'
        Write-Claude
        Write-Codex -Id $script:OtherId
        Assert-Throws { Invoke-Job (New-Job 'Backup' 'codex') } '실제 ID|프로젝트' 'Codex mismatched content UUID'
        Write-Codex -Cwd $script:CaseRoot
        Assert-Throws { Invoke-Job (New-Job 'Open' 'codex') } '실제 ID|프로젝트' 'Codex mismatched content project'
        Write-Codex
        $extra=Join-Path (Split-Path $script:CodexFile) "duplicate-$($script:CodexId).jsonl"
        Copy-Item -LiteralPath $script:CodexFile -Destination $extra
        Assert-Throws { Assert-NativeMapping 'codex' $script:CodexId $script:Project -Required } '여러 개' 'duplicate native files refused'
    }
    Test-Group 'Codex paginated, unknown mode, source and version are blocked' {
        foreach ($mode in @('paginated','future-mode')) {
            Write-Codex -Mode $mode
            Assert-RejectedBeforeApply (New-Job 'Restore' 'codex') 'Codex|CLI' "Codex $mode mode"
        }
        Write-Codex -Originator 'codex_desktop'
        Assert-Throws { Invoke-Job (New-Job 'Backup' 'codex') } 'Codex|CLI' 'Codex desktop originator'
        Write-Codex -Source 'vscode'
        Assert-Throws { Invoke-Job (New-Job 'Open' 'codex') } 'Codex|CLI' 'Codex IDE source'
        Write-Codex -Version ''
        Assert-Throws { Invoke-Job (New-Job 'Backup' 'codex') } 'Codex|CLI' 'Codex missing version'
        Write-Codex
        $script:FakeCodexVersion='codex-cli 0.999.0'
        Assert-Throws { Invoke-Job (New-Job 'Open' 'codex') } '버전' 'Codex executable version differs from recorded version'
    }
    Test-Group 'Codex remote-only provenance cannot reach restore' {
        Remove-Item -LiteralPath $script:CodexFile
        $script:ListReport.sessions[1].local=$false
        $script:Preview=New-Preview 'codex' $script:CodexId
        foreach ($action in @('Preview','Restore')) {
            Assert-RejectedBeforeApply (New-Job $action 'codex') '원본|Codex|검증' "Codex remote-only $action"
        }
        Assert (-not (Test-Path -LiteralPath $script:TestJournalRoot)) 'Codex remote-only must fail before journal creation'
    }
    Test-Group 'Codex preview requires explicit exact or behind remote prefix proof' {
        foreach ($state in @('exact','behind')) {
            $script:Preview=New-Preview 'codex' $script:CodexId
            $script:Preview.localState=$state
            $result=Invoke-Job (New-Job 'Preview' 'codex')
            Assert ($result.preview.localState -eq $state) "Codex $state proof accepted"
        }
        foreach ($state in @('','unknown','absent','missing')) {
            $script:Preview=New-Preview 'codex' $script:CodexId
            if ($state -eq 'missing') { $script:Preview.PSObject.Properties.Remove('localState') }
            else { $script:Preview.localState=$state }
            Assert-RejectedBeforeApply (New-Job 'Restore' 'codex') 'Codex.*확인|지원하지' "Codex unconfirmed state $state"
        }
    }
    Test-Group 'unreadable or missing native metadata fails closed' {
        [IO.File]::WriteAllText($script:ClaudeFile,'{invalid',[Text.UTF8Encoding]::new($false))
        Assert-Throws { Invoke-Job (New-Job 'Backup') } 'JSON|json|primitive|기본|개체|속성|Invalid' 'Claude invalid JSON file'
        Write-TestJson $script:CodexFile @{type='response_item'; payload=@{}}
        Assert-Throws { Invoke-Job (New-Job 'Backup' 'codex') } '메타데이터' 'Codex missing session_meta'
        $lines=@(); for ($i=0;$i -lt 501;$i++) { $lines+='{"type":"response_item"}' }
        [IO.File]::WriteAllText($script:CodexFile,($lines -join "`n"),[Text.UTF8Encoding]::new($false))
        Assert-Throws { Assert-CodexSession $script:CodexId $script:Project } '메타데이터' 'Codex unconfirmed metadata after scan limit'
    }
    Test-Group 'successful restore keeps unique original backup and completes journal' {
        $job=New-Job 'Restore'
        $result=Invoke-Job $job
        Assert ($result.restored.session -eq $script:ClaudeId -and $result.restored.agent -eq 'claude-code') 'restored result must retain native ID and agent'
        Assert ($result.restored.environmentSkipped -is [bool] -and $result.restored.environmentSkipped) 'restore must explicitly acknowledge skipped environment application'
        $completed=@(Get-ChildItem -LiteralPath $script:TestJournalRoot -Filter '*.completed.json' -File)
        Assert ($completed.Count -eq 1) 'success must produce one completed journal'
        Assert (@(Get-ChildItem -LiteralPath $script:TestJournalRoot -Filter '*.pending.json' -File).Count -eq 0) 'success must remove pending marker'
        $record=Get-Content -LiteralPath $completed[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-OriginalJournal $record
        Assert ($record.restoredSha256 -eq (Get-FileHash -LiteralPath $script:ClaudeFile -Algorithm SHA256).Hash) 'completed journal must record restored SHA256'
        Assert ($record.sidecar.state -eq 'restored' -and $record.sidecar.backedUp -eq 1 -and $record.companionBackup -like '*.companion') 'completed journal records the companion folder result and backup folder'
        Assert ($result.message -like '*파일 3개*' -and $result.message -like '*복구 폴더에 남긴 파일 1개*') "restore message reports subagent files: $($result.message)"
        $null=Assert-NativeMapping 'claude-code' $script:ClaudeId $script:Project -Required
        $call=@(Get-ApplyCalls)[0]
        Assert ($call.Arguments[-1] -eq $script:ClaudeRemote -and $call.Arguments -contains '--no-workspace-context' -and $call.Arguments -contains '--no-environment') 'restore must use remote ID and disable context/environment application'
        Assert ($call.Arguments -notcontains '--workspace' -and $call.Arguments -notcontains '--replace-existing') 'restore cannot overwrite forcibly or sync workspace'
        $firstBackup=@($record.originals)[0].backup
        $script:BeforeHash=(Get-FileHash -LiteralPath $script:ClaudeFile -Algorithm SHA256).Hash
        $null=Invoke-Job $job
        Assert (@(Get-ChildItem -LiteralPath $script:TestJournalRoot -Filter '*.completed.json' -File).Count -eq 2) 'second restore creates its own journal'
        Assert (@(Get-ChildItem -LiteralPath $script:TestJournalRoot -Filter '*.original.jsonl' -File).Count -eq 2) 'second restore preserves separate original backups'
        Assert (Test-Path -LiteralPath $firstBackup) 'first original backup remains present'
        Assert-NoPending
    }
    Test-Group 'Claude remote-only successful restore verifies newly created mapping' {
        Remove-Item -LiteralPath $script:ClaudeFile
        $script:ListReport.sessions[0].local=$false
        $result=Invoke-Job (New-Job 'Restore')
        Assert ($result.restored.session -eq $script:ClaudeId) 'remote-only Claude retains native UUID'
        $completed=@(Get-ChildItem -LiteralPath $script:TestJournalRoot -Filter '*.completed.json' -File)
        $record=Get-Content -LiteralPath $completed[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert (@($record.originals).Count -eq 0) 'absent local original must be recorded as no originals'
        Assert (Test-Path -LiteralPath $script:ClaudeFile) 'mock restore must create native file inside fixture'
        $null=Assert-NativeMapping 'claude-code' $script:ClaudeId $script:Project -Required
    }
    Test-Group 'Codex verified prefix restore retains UUID, backup SHA and project mapping' {
        $script:Preview=New-Preview 'codex' $script:CodexId
        $result=Invoke-Job (New-Job 'Restore' 'codex')
        Assert ($result.restored.session -eq $script:CodexId -and $result.restored.agent -eq 'codex') 'Codex result retains original native UUID'
        $completed=@(Get-ChildItem -LiteralPath $script:TestJournalRoot -Filter '*.completed.json' -File)
        Assert ($completed.Count -eq 1) 'Codex produces completed journal'
        $record=Get-Content -LiteralPath $completed[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-OriginalJournal $record 'codex'
        Assert ($result.message -notlike '*하위 에이전트*' -and $null -eq $record.sidecar) 'Codex CLI restore has no companion folder result'
        Assert ($record.restoredSha256 -eq (Get-FileHash -LiteralPath $script:CodexFile -Algorithm SHA256).Hash) 'Codex completed journal records restored SHA'
        $null=Assert-NativeMapping 'codex' $script:CodexId $script:Project -Required
        Assert-NoPending
    }
    Test-Group 'partial restore retains pending and blocks backup, restore and open' {
        $script:ApplyBehavior='partial'
        Assert-Throws { Invoke-Job (New-Job 'Restore') } 'partial restore failure' 'partial restore failure surfaced'
        $record=Read-Pending
        Assert-OriginalJournal $record
        Assert ((Get-FileHash -LiteralPath $script:ClaudeFile -Algorithm SHA256).Hash -ne $script:BeforeHash) 'fixture proves partial restore really changed the local original'
        $before=$script:CtxCalls.Count
        foreach ($action in @('Backup','Restore','Open')) {
            Assert-Throws { Invoke-Job (New-Job $action) } '이전 복원|pending' "$action refused after interrupted restore"
        }
        Assert ($script:CtxCalls.Count -eq $before) 'pending must block before list, backup or restore calls'
        Assert (@($script:NativeCalls | Where-Object {$_.Name -eq 'claude'}).Count -eq 0) 'pending must block native open'
        Assert (@(Get-ChildItem -LiteralPath $script:TestJournalRoot -Filter '*.completed.json' -File).Count -eq 0) 'failed restore cannot have completed journal'
    }
    Test-Group 'wrong restored result ID retains pending' {
        $script:ApplyBehavior='wrong-result-id'
        Assert-Throws { Invoke-Job (New-Job 'Restore') } '에이전트|세션 ID' 'wrong restore result ID rejected'
        Assert-OriginalJournal (Read-Pending)
    }
    Test-Group 'wrong restored result agent retains pending' {
        $script:ApplyBehavior='wrong-result-agent'
        Assert-Throws { Invoke-Job (New-Job 'Restore') } '에이전트|세션 ID' 'wrong restore result agent rejected'
        Assert-OriginalJournal (Read-Pending)
    }
    foreach ($markerVariant in @('missing','false','string-true','zero','null')) {
        Test-Group "unconfirmed environmentSkipped $markerVariant retains pending" {
            switch ($markerVariant) {
                missing { $script:SkipMarkerPresent=$false }
                false { $script:SkipMarkerValue=$false }
                string-true { $script:SkipMarkerValue='true' }
                zero { $script:SkipMarkerValue=0 }
                null { $script:SkipMarkerValue=$null }
            }
            Assert-Throws { Invoke-Job (New-Job 'Restore') } '환경|environment|pending|확인' "environmentSkipped $markerVariant rejected"
            Assert-OriginalJournal (Read-Pending)
            Assert (@(Get-ChildItem -LiteralPath $script:TestJournalRoot -Filter '*.completed.json' -File).Count -eq 0) 'unconfirmed environment skip must not complete journal'
            foreach ($blockedAction in @('Backup','Restore','Open')) {
                $blockedJob=New-Job $blockedAction
                Assert-Throws { Invoke-Job $blockedJob } '이전 복원|pending' "$blockedAction blocked after unconfirmed skip"
            }
        }
    }
    Test-Group 'backup made by an older release restores without the companion folder and says so' {
        $script:SidecarResult=[pscustomobject]@{state='absent'; files=0; written=0; unchanged=0; backedUp=0}
        $result=Invoke-Job (New-Job 'Restore')
        Assert ($result.message -like '*이전 판*다시 백업*') "older backup is explained: $($result.message)"
        Assert-NoPending
    }
    foreach ($sidecarVariant in @('missing','unknown-state','negative-count','string-count')) {
        Test-Group "unverified companion folder result $sidecarVariant retains pending" {
            switch ($sidecarVariant) {
                missing { $script:SidecarResult=$null }
                unknown-state { $script:SidecarResult.state='partial' }
                negative-count { $script:SidecarResult.written=-1 }
                string-count { $script:SidecarResult.files='3' }
            }
            Assert-Throws { Invoke-Job (New-Job 'Restore') } '도구 결과|pending' "companion result $sidecarVariant rejected"
            Assert-OriginalJournal (Read-Pending)
            Assert (@(Get-ChildItem -LiteralPath $script:TestJournalRoot -Filter '*.completed.json' -File).Count -eq 0) 'unverified companion folder result must not complete journal'
        }
    }
    Test-Group 'actual restored file ID mismatch retains pending' {
        $script:ApplyBehavior='wrong-file-id'
        Assert-Throws { Invoke-Job (New-Job 'Restore') } '실제 ID|프로젝트' 'actual restored file ID rejected'
        Assert-OriginalJournal (Read-Pending)
    }
    Test-Group 'actual restored file project mismatch retains pending' {
        $script:ApplyBehavior='wrong-file-cwd'
        Assert-Throws { Invoke-Job (New-Job 'Restore') } '실제 ID|프로젝트' 'actual restored file project rejected'
        Assert-OriginalJournal (Read-Pending)
    }
    Test-Group 'native open uses original UUID and selected project' {
        foreach ($agent in @('claude-code','codex')) {
            $job=New-Job 'Open' $agent
            $null=Invoke-Job $job
            $name=if ($agent -eq 'codex') {'codex'} else {'claude'}
            $call=@($script:NativeCalls | Where-Object {$_.Name -eq $name -and $_.Arguments[0] -ne '--version'})[-1]
            Assert ($call.Arguments -contains $job.nativeId) "$agent opens native UUID"
            if ($agent -eq 'codex') { Assert ($call.Arguments[0] -eq 'resume' -and $call.Arguments -contains '--cd' -and $call.Arguments[-1] -eq $script:Project) 'Codex opens chosen project' }
            else { Assert ($call.Arguments[0] -eq '--resume') 'Claude uses native resume' }
        }
        Assert ((Get-FileHash -LiteralPath $script:ClaudeFile -Algorithm SHA256).Hash -eq $script:BeforeHash) 'fake open preserves native original'
    }
    Test-Group 'ctxhop unrecognized version fails before all operations' {
        $script:FakeCtxVersion='ctxhop 0.3.0'
        Assert-Throws { Invoke-Job (New-Job 'Backup') } '0.2.0|버전' 'ctxhop version pinned'
        Assert ($script:CtxCalls.Count -eq 0) 'version failure prevents ctxhop session operations'
    }
    Test-Group 'general operations accept only official or the pinned custom version' {
        foreach ($version in @('ctxhop 0.2.0','ctxhop 0.2.0-gui.1','ctxhop 0.2.0-gui.2','ctxhop 0.2.0-gui.3')) {
            $script:FakeCtxVersion=$version
            Assert-CtxVersion
            Assert ($true) "general version $version accepted"
        }
        foreach ($version in @('ctxhop 0.2.0-gui.4','ctxhop 0.2.0-gui.3 extra','ctxhop 0.2.0-unknown','ctxhop 0.1.9')) {
            $script:FakeCtxVersion=$version
            Assert-Throws { Assert-CtxVersion } '버전|0.2.0' "general version $version rejected"
        }
    }
    Test-Group 'real executable discovery prefers bundled ctxhop without running it' {
        $expected=Join-Path $PSScriptRoot 'bin\ctxhop.exe'
        $found = & {
            param($expected)
            function Test-Path([string]$LiteralPath, [string]$PathType) {
                Assert ($PathType -eq 'Leaf') 'executable discovery checks files'
                return $LiteralPath -eq $expected
            }
            function Get-Command { throw 'bundled executable discovery must not fall back to PATH' }
            & $script:RealFindExecutable 'ctxhop'
        } $expected
        Assert ($found -eq $expected) 'bundled bin path must take precedence over installed and PATH executables'
    }
    Test-Group 'real restore gate accepts only bundled path plus pinned hash plus custom version' {
        Assert ($script:RestoreBinarySHA256 -cmatch '^[A-Fa-f0-9]{64}$') 'Worker must contain an actual pinned SHA256, not a build placeholder'
        $expected=Join-Path $PSScriptRoot 'bin\ctxhop.exe'
        Invoke-IsolatedRestoreGate $expected $script:RestoreBinarySHA256 'ctxhop 0.2.0-gui.3'
        Assert ($true) 'bundled pinned custom runtime accepted'
        $fallback=Join-Path $script:CaseRoot 'official-ctxhop.exe'
        Assert-Throws { Invoke-IsolatedRestoreGate $fallback $script:RestoreBinarySHA256 'ctxhop 0.2.0-gui.3' } '포함|실행 파일' 'custom version outside bundled path rejected'
        Assert-Throws { Invoke-IsolatedRestoreGate $expected ('0'*64) 'ctxhop 0.2.0-gui.3' } 'SHA256' 'bundled custom version with wrong binary hash rejected'
        foreach ($version in @('ctxhop 0.2.0','ctxhop 0.2.0-gui.1','ctxhop 0.2.0-gui.2','ctxhop 0.2.0-gui.3 extra')) {
            Assert-Throws { Invoke-IsolatedRestoreGate $expected $script:RestoreBinarySHA256 $version } '버전' "restore runtime $version rejected"
        }
        Assert-Throws { Invoke-IsolatedRestoreGate $expected $script:RestoreBinarySHA256 'ctxhop 0.2.0-gui.3' -HashFailure } 'hash read failure' 'unreadable runtime hash rejected'
        Assert ($script:NativeCalls.Count -eq 0) 'runtime gate tests must never invoke a real or fake native exe'
    }
    Test-Group 'nested project bindings with another identity are refused before ctxhop' {
        function New-BindJob([string]$Path, [string]$Identity) { $job=New-Job 'Bind'; $job.projectPath=$Path; $job.identity=$Identity; return $job }
        $child=Join-Path $script:Project 'child'; $sibling=Join-Path $script:CaseRoot 'sibling'; $prefix="$($script:Project)-2"
        foreach ($path in @($child,$sibling,$prefix)) { New-Item -ItemType Directory -Path $path | Out-Null }
        Assert-Throws { Invoke-Job (New-BindJob $child 'other') } '겹칩니다' 'child of a registered folder with another identity'
        Assert-Throws { Invoke-Job (New-BindJob $script:CaseRoot 'other') } '겹칩니다' 'parent of a registered folder with another identity'
        # ctxhop은 공통 이름의 대소문자를 구분한다.
        Assert-Throws { Invoke-Job (New-BindJob $child 'Synthetic-Project') } '겹칩니다' 'identity that differs only in case'
        Assert (@($script:CtxCalls | Where-Object { $_.Arguments[0] -eq 'project' }).Count -eq 0) 'refused bindings never reach ctxhop'
        foreach ($case in @(@($child,'synthetic-project'),@($sibling,'other'),@($prefix,'other'))) { $null=Invoke-Job (New-BindJob $case[0] $case[1]) }
        Assert (@($script:CtxCalls | Where-Object { $_.Arguments[0] -eq 'project' -and $_.Arguments[1] -eq 'bind' }).Count -eq 3) 'same identity, sibling and name-prefix folders are allowed'
    }
    Test-Group 'first registration works when no project is registered yet' {
        # ctxhop은 등록이 없으면 bindings를 빼고 저장한다.
        foreach ($config in @([pscustomobject]@{syncConfig='disabled'; projects=@{}},[pscustomobject]@{syncConfig='disabled'})) {
            Write-TestJson (Join-Path $env:CTXHOP_CONFIG_DIR 'config.json') $config
            $job=New-Job 'Bind'; $job.identity='first-project'
            Assert ((Invoke-Job $job).message -eq (T 'CwBindDone')) 'bind with no registrations reaches ctxhop'
            Assert (($script:CtxCalls[-1].Arguments -join ' ') -eq "project bind --path $($script:Project) --identity first-project") 'bind arguments with no registrations'
            Assert-Throws { Invoke-Job (New-Job 'List') } '먼저 등록' 'list with no registrations asks to register'
        }
    }
    Test-Group 'unregister and password actions call the matching ctxhop commands' {
        $job=New-Job 'Unbind'
        Assert ((Invoke-Job $job).message -eq (T 'CwUnbindDone')) 'unbind reports completion'
        Assert (($script:CtxCalls[-1].Arguments -join ' ') -eq "project unbind --identity synthetic-project --path $($script:Project)") 'existing folder is unbound by Identity and path'
        # ctxhop은 --path의 폴더를 확인하므로, 지워진 폴더는 그 이름의 등록이 이 경로 하나뿐일 때만 이름으로 해제한다.
        $gone=Join-Path $script:CaseRoot 'deleted-folder'
        $bindings=@(@{localRoot=$script:Project; identity='synthetic-project'},@{localRoot=$gone; identity='old-name'})
        Write-TestJson (Join-Path $env:CTXHOP_CONFIG_DIR 'config.json') ([pscustomobject]@{syncConfig='disabled'; projects=@{bindings=$bindings}})
        $job=New-Job 'Unbind'; $job.projectPath=$gone; $job.identity='old-name'
        $null=Invoke-Job $job
        Assert (($script:CtxCalls[-1].Arguments -join ' ') -eq 'project unbind --identity old-name') 'deleted folder is unbound by its only Identity'
        $calls=$script:CtxCalls.Count
        $job=New-Job 'Unbind'; $job.projectPath=(Join-Path $script:CaseRoot 'other-deleted'); $job.identity='old-name'
        Assert-Throws { Invoke-Job $job } '해제하지 않았습니다' 'deleted folder that is not the registered path'
        Write-TestJson (Join-Path $env:CTXHOP_CONFIG_DIR 'config.json') ([pscustomobject]@{syncConfig='disabled'; projects=@{bindings=@($bindings[1],@{localRoot=$script:Project; identity='old-name'})}})
        $job=New-Job 'Unbind'; $job.projectPath=$gone; $job.identity='old-name'
        Assert-Throws { Invoke-Job $job } '해제하지 않았습니다' 'deleted folder whose Identity is registered elsewhere too'
        Assert ($script:CtxCalls.Count -eq $calls) 'refused unbinds never reach ctxhop'
        $null=Invoke-Job (New-Job 'PassphraseChange'); $null=Invoke-Job (New-Job 'PassphraseReset')
        Assert ((($script:CtxCalls | Select-Object -Last 2 | ForEach-Object { $_.Arguments -join ' ' }) -join ';') -eq 'passphrase change;passphrase reset') 'password actions run passphrase change and reset'
        $job=New-Job 'Unbind'; $job.identity=''
        Assert-Throws { Invoke-Job $job } '입력하세요' 'unbind requires an identity'
    }
    Test-Group 'store move copies only missing files and switches only through ctxhop relocate' {
        function Write-StoreFile([string]$Root,[string]$Relative,[string]$Text) { $path=Join-Path $Root $Relative; $null=New-Item -ItemType Directory -Force -Path (Split-Path $path); [IO.File]::WriteAllText($path,$Text) }
        function Get-Tree([string]$Root) { if (-not (Test-Path -LiteralPath $Root)) { return '' }; @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($Root.Length)+'='+[IO.File]::ReadAllText($_.FullName) }) -join '|' }
        $old=Join-Path $script:CaseRoot 'drive\old store'; $new=Join-Path $script:CaseRoot 'drive\new store'
        Write-StoreFile $old 'v1\keyfile' 'key'; Write-StoreFile $old 'v1\desktop-bundles\d\1\metadata' 'one'; Write-StoreFile $old 'v1\desktop-bundles\d\2\metadata' 'two'
        Write-StoreFile $new 'v1\desktop-bundles\d\2\metadata' 'two'
        $configFile=Join-Path $env:CTXHOP_CONFIG_DIR 'config.json'
        function Set-Store([string]$Path,[string]$Type='dir') { Write-TestJson $configFile ([pscustomobject]@{syncConfig='disabled'; remote=[pscustomobject]@{type=$Type;path=$Path}; projects=$script:Config.projects}) }
        function New-MoveJob([string]$Store) { $job=New-Job 'MoveStore'; $job | Add-Member -NotePropertyName store -NotePropertyValue $Store; return $job }
        Set-Store $old; $oldTree=Get-Tree $old
        $result=Invoke-Job (New-MoveJob $new)
        Assert ($result.store -eq $new -and $result.copied -eq 2 -and $result.same -eq 1 -and $result.message -like "*$new*") "move result: $($result | ConvertTo-Json -Compress)"
        Assert (($script:CtxCalls[-1].Arguments -join '|') -eq "remote|relocate|--path|$new") 'the connection switches only through ctxhop remote relocate'
        Assert ((Get-Tree $new) -eq ($oldTree -replace [regex]::Escape($old),'') -and (Get-Tree $old) -eq $oldTree) 'missing files are copied, nothing else is written and the old store stays'
        Assert ((Get-Tree $new) -eq '\v1\desktop-bundles\d\1\metadata=one|\v1\desktop-bundles\d\2\metadata=two|\v1\keyfile=key') "new store tree: $(Get-Tree $new)"
        # 같은 이름인데 내용이 다른 파일이 있으면(다른 저장소 등) 아무것도 복사하지 않고 연결도 그대로다.
        $calls=$script:CtxCalls.Count
        $other=Join-Path $script:CaseRoot 'drive\other store'; Write-StoreFile $other 'v1\keyfile' 'another key'
        Set-Store $old
        Assert-Throws { Invoke-Job (New-MoveJob $other) } '내용이 다른 저장소 파일이 1개' 'a store file with other content stops the move'
        Assert ((Get-Tree $other) -eq '\v1\keyfile=another key') 'nothing is copied next to a conflicting file'
        $inside=Join-Path $old 'inside'; $null=New-Item -ItemType Directory -Path $inside
        Assert-Throws { Invoke-Job (New-MoveJob $old) } '이미' 'the same store is refused'
        Assert-Throws { Invoke-Job (New-MoveJob $inside) } '품고 있어' 'a folder inside the store is refused'
        Assert-Throws { Invoke-Job (New-MoveJob (Join-Path $script:CaseRoot 'missing')) } '저장소 폴더가 없습니다' 'a missing folder is refused'
        Set-Store $old 's3'
        Assert-Throws { Invoke-Job (New-MoveJob $other) } '폴더 저장소만' 'only a folder store moves'
        Assert ($script:CtxCalls.Count -eq $calls) 'refused moves never reach ctxhop'
        # ctxhop이 옮기기를 거부하거나 설정이 바뀌지 않으면 실패로 끝난다.
        $fresh=Join-Path $script:CaseRoot 'drive\fresh store'; $null=New-Item -ItemType Directory -Path $fresh
        Set-Store $old; $script:RelocateBehavior='fail'
        Assert-Throws { Invoke-Job (New-MoveJob $fresh) } 'synthetic relocate failure' 'a ctxhop relocate failure is reported'
        Assert (((Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json).remote.path) -eq $old) 'the connection stays when ctxhop refuses'
        $script:RelocateBehavior='ignore'
        Assert-Throws { Invoke-Job (New-MoveJob $fresh) } '바뀌지 않았습니다' 'a move that does not reach the settings is reported'
        # 복사본의 해시가 원본과 다르면 제자리로 옮기지 않고 임시 파일도 남기지 않는다.
        $script:RelocateBehavior='apply'; $calls=$script:CtxCalls.Count
        $bad=Join-Path $script:CaseRoot 'drive\bad copy'; $null=New-Item -ItemType Directory -Path $bad
        function Get-FileHash([string]$LiteralPath,[string]$Algorithm) { if ($LiteralPath -like '*.part') { return [pscustomobject]@{Hash=('0'*64)} }; Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm }
        Assert-Throws { Invoke-Job (New-MoveJob $bad) } '원본과 다릅니다' 'a copy with another hash stops the move'
        Assert ((Get-Tree $bad) -eq '' -and $script:CtxCalls.Count -eq $calls) 'a bad copy is neither kept nor followed by relocate'
    }
    Test-Group 'store move checks real folders, links and the settings folder before copying anything' {
        function Write-StoreFile([string]$Root,[string]$Relative,[string]$Text) { $path=Join-Path $Root $Relative; $null=New-Item -ItemType Directory -Force -Path (Split-Path $path); [IO.File]::WriteAllText($path,$Text) }
        function Get-Tree([string]$Root) { if (-not (Test-Path -LiteralPath $Root)) { return '' }; @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($Root.Length)+'='+[IO.File]::ReadAllText($_.FullName) }) -join '|' }
        function New-MoveJob([string]$Store) { $job=New-Job 'MoveStore'; $job | Add-Member -NotePropertyName store -NotePropertyValue $Store; return $job }
        $links=[Collections.Generic.List[string]]::new()
        function New-Link([string]$Path,[string]$Target) { $null=New-Item -ItemType Junction -Path $Path -Target $Target; $links.Add($Path) }
        function Remove-Link([string]$Path) { [IO.Directory]::Delete($Path); $null=$links.Remove($Path) }
        $configFile=Join-Path $env:CTXHOP_CONFIG_DIR 'config.json'
        function Set-Store([string]$Path) { Write-TestJson $configFile ([pscustomobject]@{syncConfig='disabled'; remote=[pscustomobject]@{type='dir';path=$Path}; projects=$script:Config.projects}) }
        $old=Join-Path $script:CaseRoot 'drive\old store'; Write-StoreFile $old 'v1\keyfile' 'key'; Write-StoreFile $old 'v1\desktop-bundles\d\1\metadata' 'one'
        $inside=Join-Path $old 'inside'; $null=New-Item -ItemType Directory -Path $inside
        $secret=Join-Path $script:CaseRoot 'outside secret'; Write-StoreFile $secret 'private\data' 'not a store file'
        $sink=Join-Path $script:CaseRoot 'outside sink'; $null=New-Item -ItemType Directory -Path $sink
        Set-Store $old
        $oldTree=Get-Tree $old; $secretTree=Get-Tree $secret; $configBytes=[IO.File]::ReadAllText($configFile); $calls=$script:CtxCalls.Count
        try {
            # 옛 저장소 안의 정션: 저장소 밖 파일을 새 저장소로 복사하지 않는다.
            New-Link (Join-Path $old 'v1\desktop-bundles\leak') $secret
            $new1=Join-Path $script:CaseRoot 'drive\new one'; $null=New-Item -ItemType Directory -Path $new1
            Assert-Throws { Invoke-Job (New-MoveJob $new1) } '링크나 정션' 'a junction inside the old store stops the move'
            Assert ((Get-Tree $new1) -eq '') 'nothing from outside the old store is copied'
            Remove-Link (Join-Path $old 'v1\desktop-bundles\leak')
            # 새 저장소의 v1 자체나 그 안의 정션: 저장소 밖에 파일을 만들지 않는다.
            $new2=Join-Path $script:CaseRoot 'drive\new two'; $null=New-Item -ItemType Directory -Path $new2
            New-Link (Join-Path $new2 'v1') $sink
            Assert-Throws { Invoke-Job (New-MoveJob $new2) } '링크나 정션' 'a junction as the new v1 stops the move'
            Remove-Link (Join-Path $new2 'v1')
            $null=New-Item -ItemType Directory -Path (Join-Path $new2 'v1')
            New-Link (Join-Path $new2 'v1\desktop-bundles') $sink
            Assert-Throws { Invoke-Job (New-MoveJob $new2) } '링크나 정션' 'a junction inside the new v1 stops the move'
            Assert ((Get-Tree $sink) -eq '') 'nothing is written outside the new store'
            Remove-Link (Join-Path $new2 'v1\desktop-bundles')
            # 다른 이름(정션)으로 가린 같은 폴더·중첩 폴더도 실제 위치로 알아본다.
            $alias=Join-Path $script:CaseRoot 'drive\alias of old'; New-Link $alias $old
            Assert-Throws { Invoke-Job (New-MoveJob $alias) } '이미' 'the current store under another name is refused'
            Assert-Throws { Invoke-Job (New-MoveJob (Join-Path $alias 'inside')) } '품고 있어' 'a folder inside the store under another name is refused'
            Set-Store $alias
            Assert-Throws { Invoke-Job (New-MoveJob $old) } '이미' 'the configured store under another name is recognized'
            Set-Store $old
            # ctxhop 설정 폴더와 겹치면 복사하기 전에 멈춘다.
            $settingsAlias=Join-Path $script:CaseRoot 'drive\alias of settings'; New-Link $settingsAlias $env:CTXHOP_CONFIG_DIR
            $settingsInside=Join-Path $env:CTXHOP_CONFIG_DIR 'sub'; $null=New-Item -ItemType Directory -Path $settingsInside
            foreach ($target in @($env:CTXHOP_CONFIG_DIR,$settingsInside,$settingsAlias)) {
                Assert-Throws { Invoke-Job (New-MoveJob $target) } '설정 폴더' "a store overlapping the settings folder is refused: $target"
            }
            Assert (-not (Test-Path -LiteralPath (Join-Path $env:CTXHOP_CONFIG_DIR 'v1')) -and -not (Test-Path -LiteralPath (Join-Path $settingsInside 'v1'))) 'nothing is copied into the settings folder'
            Assert ($script:CtxCalls.Count -eq $calls -and [IO.File]::ReadAllText($configFile) -eq $configBytes) 'refused moves never reach ctxhop and keep the settings'
            Assert ((Get-Tree $old) -eq $oldTree -and (Get-Tree $secret) -eq $secretTree -and (Get-Tree $sink) -eq '') 'the old store and the outside folders are unchanged'
            # 저장소 폴더 자체를 정션으로 골라도 실제 폴더에 복사하고, ctxhop에는 고른 경로를 넘긴다.
            $real=Join-Path $script:CaseRoot 'real new'; $null=New-Item -ItemType Directory -Path $real
            $viaLink=Join-Path $script:CaseRoot 'drive\linked new'; New-Link $viaLink $real
            $result=Invoke-Job (New-MoveJob $viaLink)
            Assert ($result.store -eq $viaLink -and $result.copied -eq 2 -and ($script:CtxCalls[-1].Arguments -join '|') -eq "remote|relocate|--path|$viaLink") "a store folder reached through a junction moves: $($result | ConvertTo-Json -Compress)"
            Assert ((Get-Tree $real) -eq '\v1\desktop-bundles\d\1\metadata=one|\v1\keyfile=key') "the files land in the real folder: $(Get-Tree $real)"
        } finally { foreach ($link in @($links)) { [IO.Directory]::Delete($link) } }
    }
    Test-Group 'failure reason is read from the same command log line after the start time' {
        $logs=Join-Path $env:CTXHOP_CONFIG_DIR 'logs'; New-Item -ItemType Directory -Path $logs | Out-Null
        $log=Join-Path $logs ('ctxhop-{0}.log' -f (Get-Date).ToString('yyyy-MM-dd'))
        Assert ((Get-CtxFailureReason 'list' ([datetimeoffset]::Now)) -eq '') 'missing log gives no reason'
        $stamp={ param($offset) ([datetimeoffset]::Now.AddSeconds($offset)).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz') }
        $lines=@(
            "time=$(& $stamp -60) level=ERROR msg=command_finished command=list result=failed class=command-failed error=`"old failure`"",
            "time=$(& $stamp 0) level=INFO msg=command_started command=list",
            "time=$(& $stamp 0) level=ERROR msg=command_finished command=push result=failed class=command-failed error=`"other command`"",
            "time=$(& $stamp 0) level=ERROR msg=command_finished command=list result=failed class=command-failed error=`"list: identify the current project: D:\\codex \`"한글\`" conflicting project bindings`""
        )
        [IO.File]::WriteAllLines($log,[string[]]$lines,[Text.UTF8Encoding]::new($false))
        Assert ((Get-CtxFailureReason 'list' ([datetimeoffset]::Now.AddSeconds(-5))) -eq 'list: identify the current project: D:\codex "한글" conflicting project bindings') 'latest matching failure is unescaped'
        Assert ((Get-CtxFailureReason 'init' ([datetimeoffset]::Now.AddSeconds(-5))) -eq '') 'other commands are ignored'
        [IO.File]::AppendAllText($log,"time=$(& $stamp 0) level=ERROR msg=command_finished command=list result=failed class=command-failed error=locked`n",[Text.UTF8Encoding]::new($false))
        # ctxhop처럼 쓰기용으로 열어 둔 채로도 읽혀야 한다.
        $writer=[IO.FileStream]::new($log,'Open','Write','ReadWrite')
        try { Assert ((Get-CtxFailureReason 'list' ([datetimeoffset]::Now.AddSeconds(-5))) -eq 'locked') 'unquoted reason is read while another ctxhop keeps the log open' }
        finally { $writer.Dispose() }
        Remove-Item -LiteralPath $log
        $message = & {
            function Find-Executable([string]$Name) { return 'Invoke-FailingCtx' }
            function Invoke-FailingCtx {
                $line="time=$([datetimeoffset]::Now.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')) level=ERROR msg=command_finished command=init result=failed class=command-failed error=`"init: encryption passwords do not match; run init again`""
                [IO.File]::AppendAllText($log,"$line`n",[Text.UTF8Encoding]::new($false))
                $global:LASTEXITCODE=1
            }
            try { & $script:RealInvokeCtx @('init','--no-hook'); '' } catch { $_.Exception.Message }
        }
        Assert ($message -match 'ctxhop init' -and $message -match 'encryption passwords do not match') "the GUI error includes the ctxhop reason: $message"
    }

    Test-Group 'ctxhop output is read as UTF-8 even when the console code page is 949' {
        # GUI 작업 창은 새 콘솔이라 한국어 Windows에서 코드 페이지가 949다. 실제로 UTF-8 바이트를 쓰는 시험용 실행 파일로 확인한다.
        $exe=Join-Path $script:CaseRoot 'fake-ctxhop-utf8.exe'
        Add-Type -OutputAssembly $exe -OutputType ConsoleApplication -TypeDefinition @'
public static class FakeCtxUtf8 { public static void Main() {
    byte[] b = System.Text.Encoding.UTF8.GetBytes("{\"title\":\"\uD55C\uAE00 \uC81C\uBAA9\",\"path\":\"D:\\\\codex\\\\\uBCF4\uACE0\uC11C\"}");
    System.IO.Stream o = System.Console.OpenStandardOutput(); o.Write(b, 0, b.Length); o.Flush(); } }
'@
        $saved=[Console]::OutputEncoding
        try {
            [Console]::OutputEncoding=[Text.Encoding]::GetEncoding(949)
            $report = & {
                function Find-Executable([string]$Name) { return $exe }
                & $script:RealInvokeCtx @('list','--json') -Json
            }
            Assert ($report.title -eq '한글 제목' -and $report.path -eq 'D:\codex\보고서') "Korean text survives: $($report.title) / $($report.path)"
            Assert ([Console]::OutputEncoding.CodePage -eq 949) 'the console code page is put back after the call'
        } finally { [Console]::OutputEncoding=$saved }
    }
}
catch {
    $script:Failures += "Harness: $($_.Exception.Message) [line $($_.InvocationInfo.ScriptLineNumber)]"
    Write-Host $script:Failures[-1] -ForegroundColor Red
}
finally {
    Set-Location -LiteralPath $savedLocation.Path
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process') }
    $script:TestJournalRoot=$null
    if (Test-Path -LiteralPath $script:Root) {
        $resolved=(Resolve-Path -LiteralPath $script:Root).Path
        $tmp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $expected=[IO.Path]::GetFullPath($script:Root)
        if (-not $resolved.StartsWith($tmp,[StringComparison]::OrdinalIgnoreCase) -or $resolved -ne $expected -or [IO.Path]::GetFileName($resolved) -notmatch '^CtxHopGUI-worker-tests-[a-f0-9]{32}$') {
            throw "Refusing recursive cleanup outside the exact temporary fixture root: $resolved"
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Host "RESULT: $($script:Groups) groups, $($script:Assertions) assertions, $($script:Failures.Count) failures. Native commands mocked; temporary fixtures removed."
if ($script:Failures.Count) {
    foreach ($failure in $script:Failures) { Write-Host $failure -ForegroundColor Red }
    exit 1
}
exit 0
