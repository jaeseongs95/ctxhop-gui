#requires -Version 5.1
# Claude Code 대화 구현(벤더 계약 v1, docs\contract-v1.md). Worker가 impls.json으로 실행한다.
# 대화 작업·저장 형식·전송(ctxhop-claude push/resume)과 복구 기록은 ClaudeWorker.ps1 그대로이고, 여기서는 계약에 맞춰 감싸기만 한다.
$ErrorActionPreference='Stop'
$implArgs=$args   # Worker.ps1을 dot-source하면 $args가 바뀔 수 있어 먼저 보관한다.
. (Join-Path $PSScriptRoot 'Worker.ps1') -LibraryOnly
function Get-ClaudeSessionFiles([string]$Id) {
    # Claude Code 대화 파일과, 있으면 그 옆 폴더의 하위 에이전트 대화 파일.
    foreach ($file in @(Get-NativeFiles 'claude-code' $Id)) {
        $file.FullName
        $subagents=Join-Path $file.DirectoryName "$Id\subagents"
        if (Test-Path -LiteralPath $subagents -PathType Container) { Get-ChildItem -LiteralPath $subagents -Filter '*.jsonl' -File | ForEach-Object FullName }
    }
}
function Invoke-ClaudeCore([object]$Request,[string]$Action) {
    $job=[pscustomobject]@{action=$Action;agent='claude-code';projectPath=[string]$Request.projectPath;identity=[string]$Request.identity;nativeId=[string]$Request.nativeId;remoteId=[string]$Request.remoteId;operationId=[string]$Request.operationId}
    & $script:ClaudeJobCore $job
}
function Get-ClaudeWorkFolders([object]$Request) {
    # Claude 대화는 등록한 프로젝트 폴더(GUI의 프로젝트 폴더)를 시작 폴더로 쓴다.
    Assert-NativeId $Request.nativeId
    $start=Normalize-ProjectPath (Resolve-Path -LiteralPath $Request.projectPath).Path
    $work=Read-ClaudeWorkData @(Get-ClaudeSessionFiles $Request.nativeId)
    $folders=@{sourceCwd=$start;cwds=@($work.cwds);edits=@($work.edits)}
    $folders.sourceStamp=Get-SourceStamp $start $folders.cwds $folders.edits
    return $folders
}
function Get-ClaudePending {
    $root=Get-JournalRoot
    if (Test-Path -LiteralPath $root) { @(Get-ChildItem -LiteralPath $root -Filter '*.pending.json' -File | ForEach-Object FullName) }
}
function Get-ClaudeRecord([string]$RecordId) {
    # 복구 기록의 상태(S3 명세 2.3절). 기록 이름은 작업 ID다(예전 기록도 32자 hex 이름). 읽기만 한다.
    $null=Assert-OperationId $RecordId
    $root=Get-JournalRoot
    $row=[ordered]@{recordId=$RecordId;operationId=$null;nativeId=$null;path=$null;state='absent';sha256=$null;canRollback=$false;files=$null}
    $found=[ordered]@{}
    foreach ($kind in 'pending','completed','rolledback','resolved') { $file=Join-Path $root "$RecordId.$kind.json"; if ([IO.File]::Exists($file)) { $found[$kind]=$file } }
    if (-not $found.Count) { return $row }
    $row.state='unreadable'; $row.path=@($found.Values)[0]
    try {
        $row.sha256=(Get-FileHash -LiteralPath $row.path -Algorithm SHA256).Hash
        # 닫힌 기록은 내용을 읽지 않는다. 읽을 수 없던 기록도 사용자가 보고 닫을 수 있기 때문이다.
        if ($found.Count -eq 1 -and $found.Contains('resolved')) { $row.state='resolved'; return $row }
        $record=Get-Content -LiteralPath $row.path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.operationId -and [string]$record.operationId -cne $RecordId) { return $row }
        $row.operationId=if ($record.operationId) {$RecordId} else {$null}; $row.nativeId=[string]$record.nativeId
        if ($found.Count -eq 1) { $row.state=@{pending='pending';completed='complete';rolledback='rolled_back';resolved='resolved'}[@($found.Keys)[0]] }
        elseif ($found.Count -eq 2 -and $found.Contains('pending') -and $found.Contains('completed') -and (Test-CompletedTwin $found.pending)) { $row.state='complete' }
        $row.canRollback=$row.state -eq 'pending' -and [bool]$record.prepared
    } catch { $row.state='unreadable' }
    return $row
}
function Get-ClaudeRecordRows {
    # 되돌리거나 닫아야 할 기록(pending·unreadable)과, 되돌릴 수 있으면 파일별 분류.
    $root=Get-JournalRoot
    if (-not [IO.Directory]::Exists($root)) { return @() }
    $ids=@([IO.Directory]::GetFiles($root,'*.json') | ForEach-Object { if ([IO.Path]::GetFileName($_) -cmatch '^([0-9a-f]{32})\.(pending|completed|rolledback|resolved)\.json$') { $Matches[1] } } | Sort-Object -Unique)
    foreach ($id in $ids) {
        $row=Get-ClaudeRecord $id
        if ($row.state -notin @('pending','unreadable')) { continue }
        if ($row.canRollback) { try { $row.files=@(Get-ProjectUndoView (Get-ClaudeUndoFiles $id (Get-Content -LiteralPath $row.path -Raw -Encoding UTF8 | ConvertFrom-Json))) } catch { $row.canRollback=$false } }
        [pscustomobject]$row
    }
}
function Get-ClaudeUndoFiles([string]$RecordId,[object]$Record,[switch]$Save) {
    # 되돌릴 파일 목록(S3 명세 3.4절): 대화 파일 하나와 옆 폴더. Claude 파일은 "이 작업이 씀"으로 인증하지 않으므로 after가 없다.
    # 옆 폴더 원본은 companion의 같은 상대 경로 파일이다. 새로 생긴 파일은 before=absent다. 목록은 <op>.rollback\files.json에 고정해
    # 다시 실행해도 같은 번호를 쓰고, 그사이 새로 생긴 파일만 뒤에 붙인다.
    $folder=Join-Path (Get-JournalRoot) "$RecordId.rollback"; $saved=Join-Path $folder 'files.json'
    $files=[Collections.Generic.List[object]]::new(); $known=@{}
    if ([IO.File]::Exists($saved)) { foreach ($file in @((Get-Content -LiteralPath $saved -Raw -Encoding UTF8 | ConvertFrom-Json).files)) { $files.Add($file); $known[([string]$file.target).ToLowerInvariant()]=$true } }
    $add={ param($Target,$Before,$Copy) if (-not $known.ContainsKey($Target.ToLowerInvariant())) { $known[$Target.ToLowerInvariant()]=$true; $files.Add([pscustomobject]@{index=$files.Count;target=$Target;before=$Before;beforeCopy=$Copy;after=$null}) } }
    $prepared=$Record.prepared; $conversation=$prepared.conversation
    $target=if ($conversation.target) { [string]$conversation.target } else {
        $current=@(Get-NativeFiles 'claude-code' ([string]$Record.nativeId))
        if ($current.Count -gt 1) { throw (T 'CwRecordAmbiguous' $Record.nativeId) }
        if ($current.Count) { $current[0].FullName } else { $null }
    }
    if ($target) { & $add $target ([string]$conversation.before) $conversation.beforeCopy }
    $side=if ($prepared.sidecar.root) { [string]$prepared.sidecar.root } elseif ($target) { Join-Path ([IO.Path]::GetDirectoryName($target)) ([string]$Record.nativeId) } else { $null }
    if ($side) {
        foreach ($file in @($prepared.sidecar.files)) { & $add (Join-Path $side $file.path) ([string]$file.sha256) (Join-Path ([string]$prepared.sidecarBackup) $file.path) }
        if ([IO.Directory]::Exists($side)) { foreach ($file in [IO.Directory]::GetFiles($side,'*','AllDirectories')) { & $add $file 'absent' $null } }
    }
    # 되돌리기는 대상 폴더 안에서 이름을 바꾼다. Claude 대화 폴더 밖이거나 링크를 거치는 대상은 거부한다.
    $projects=Join-Path $(if ($env:CLAUDE_CONFIG_DIR) {$env:CLAUDE_CONFIG_DIR} else {Join-Path $env:USERPROFILE '.claude'}) 'projects'
    $cache=@{}
    foreach ($file in $files) { if (-not (Test-ProjectInside $file.target $projects) -or -not (Test-ProjectLinkFree $file.target $projects $cache)) { throw (T 'PfTargetUnsafe' $file.target) } }
    if ($Save) { $null=[IO.Directory]::CreateDirectory($folder); Save-ProjectJson $saved ([ordered]@{version=1;files=$files.ToArray()}) }
    return $files.ToArray()
}
$script:ClaudeCodeOps=@{
    list={ param($R)
        $listed=Invoke-ClaudeCore $R 'List'
        $rows=foreach ($row in @($listed.sessions)) {
            # ctxhop은 기록이 0개인 대화의 recordCount를 빼고 보낸다. 다른 필드는 ctxhop이 준 그대로 둔다.
            if ($null -eq $row.recordCount) { $row | Add-Member -NotePropertyName recordCount -NotePropertyValue 0 }
            $row | Add-Member -NotePropertyName title -NotePropertyValue ([string]$row.title) -Force
            $row
        }
        return @{sessions=@($rows);excluded=[int]$listed.excluded;message=[string]$listed.message}
    }
    describe={ param($R) Get-ClaudeWorkFolders $R }
    backup={ param($R)
        # describe 뒤에 작업 폴더가 바뀌었으면 확인하지 않은 폴더가 생겼을 수 있으므로 올리지 않는다.
        if ($R.sourceStamp -and (Get-ClaudeWorkFolders $R).sourceStamp -cne $R.sourceStamp) { return @{status='changed';reasonCode='source_changed';reason=(T 'WkSourceChanged')} }
        $done=Invoke-ClaudeCore $R 'Backup'
        # ctxhop은 같은 대화를 목록의 같은 원격 ID로 올린다.
        return @{remoteId=[string]$R.remoteId;message=[string]$done.message}
    }
    preview={ param($R)
        $shown=Invoke-ClaudeCore $R 'Preview'
        # 복원할 때 ClaudeWorker가 대화 미리보기를 다시 검사하므로 receipt는 쓰지 않는다. token은 이 미리보기를 가리키는 일회용 값이고,
        # Worker가 프로젝트 파일 미리보기와 짝을 맞출 때만 쓴다.
        return @{state='ready';choices=@('incoming');receipt='';token=[guid]::NewGuid().ToString();view=$shown.preview;message=[string]$shown.message}
    }
    restore={ param($R)
        if ($R.choice -cne 'incoming') { throw (T 'WkChoiceRequired') }
        # 복구 기록은 Worker가 준 작업 ID 이름으로 쓰기 전에 만든다(S3 명세 2.1절).
        $null=Assert-OperationId $R.operationId
        $before=@(Get-ClaudePending)
        try { $done=Invoke-ClaudeCore $R 'Restore' }
        catch {
            # 복원은 쓰기 전에 복구 기록(pending)을 남기고 끝나면 지운다. 새 기록이 남았으면 복구가 필요하고, 다음 백업·복원은 ClaudeWorker가 막는다.
            $failure=$_
            $new=@(Get-ClaudePending | Where-Object { $_ -notin $before })
            $failure.Exception.Data['recovery']=if ($new.Count) {'required'} else {'none'}
            if ($new.Count) { $failure.Exception.Data['backendResult']=[pscustomobject]@{status='failed';pending=$new} }
            throw $failure
        }
        return @{effect='restored';nativeId=[string]$done.restored.session;view=$done.restored;message=[string]$done.message}
    }
    open={ param($R) @{message=[string](Invoke-ClaudeCore $R 'Open').message} }
    recover={ param($R)
        # 복구 기록 조회·되돌리기·닫기(S3 명세 3.4·4.2절).
        switch -CaseSensitive ([string]$R.mode) {
            status { return @{state=(Get-ClaudeRecord ([string]$R.operationId)).state} }
            list { return @{records=@(Get-ClaudeRecordRows)} }
            rollback {
                $row=Get-ClaudeRecord ([string]$R.recordId)
                if ($row.state -eq 'rolled_back') { return @{effect='rolled_back';message=(T 'WkRecoverRolledBack' $row.path)} }
                if (-not $row.canRollback) { return @{status='failed';reasonCode='unsupported_record';reason=(T 'WkRecordNotPending' $row.state);records=@([pscustomobject]$row)} }
                try { Assert-AgentClosed 'claude-code' } catch { return @{status='failed';reasonCode='busy';reason=$_.Exception.Message;records=@([pscustomobject]$row)} }
                $record=Get-Content -LiteralPath $row.path -Raw -Encoding UTF8 | ConvertFrom-Json
                $files=Get-ClaudeUndoFiles $row.recordId $record -Save
                $undo=Undo-ProjectRestorePlan $files (Join-Path (Get-JournalRoot) "$($row.recordId).rollback") $row.recordId @($R.confirmedUnknown | Where-Object { $_ })
                if (-not $undo.complete) { $row.files=@($undo.files); return @{status='failed';reasonCode='needs_attention';reason=(T 'WkRollbackIncomplete');records=@([pscustomobject]$row)} }
                # 모두 원래대로면 pending을 rolledback으로 바꾼다. 같은 이름이 이미 있으면 덮어쓰지 않고 실패한다.
                [IO.File]::Move($row.path,(Join-Path (Get-JournalRoot) "$($row.recordId).rolledback.json"))
                return @{effect='rolled_back';message=(T 'WkRecoverRolledBack' (Join-Path (Get-JournalRoot) "$($row.recordId).rollback"))}
            }
            resolve {
                # 사용자가 창에서 본 pending 내용(SHA-256)과 같을 때만 닫는다. 이미 닫혔으면 성공이고, 닫은 이름이 있으면 덮어쓰지 않는다.
                $row=Get-ClaudeRecord ([string]$R.recordId)
                if ($row.state -eq 'resolved') { return @{effect='resolved';message=(T 'WkRecoverResolved' $row.path)} }
                $pending=Join-Path (Get-JournalRoot) "$($row.recordId).pending.json"
                if ($row.state -notin @('pending','unreadable') -or $row.path -ne $pending) { return @{status='failed';reasonCode='unsupported_record';reason=(T 'WkRecordNotPending' $row.state);records=@([pscustomobject]$row)} }
                if ($row.sha256 -ne [string]$R.sha256) { return @{status='failed';reasonCode='changed';reason=(T 'WkRecordChanged');records=@([pscustomobject]$row)} }
                [IO.File]::Move($pending,(Join-Path (Get-JournalRoot) "$($row.recordId).resolved.json"))
                return @{effect='resolved';message=(T 'WkRecoverResolved' $pending)}
            }
        }
        throw (T 'WkRecoverModeInvalid' ([string]$R.mode))
    }
    guard={ param($R)
        # 프로젝트 파일을 먼저 쓰기 전에, 복원과 같은 검사로 Claude Code가 닫혔는지 본다. 열려 있으면 busy다.
        try { Assert-AgentClosed 'claude-code' } catch { return @{status='busy';reasonCode='engine_open';reason=$_.Exception.Message} }
        return @{}
    }
}
if ($implArgs.Count -and $implArgs[0] -ceq '-LibraryOnly') { return }
Invoke-Impl $script:ClaudeCodeOps $implArgs
