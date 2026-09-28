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
    $job=[pscustomobject]@{action=$Action;agent='claude-code';projectPath=[string]$Request.projectPath;identity=[string]$Request.identity;nativeId=[string]$Request.nativeId;remoteId=[string]$Request.remoteId}
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
        # 복원할 때 ClaudeWorker가 미리보기를 다시 검사하므로 receipt·token은 쓰지 않는다.
        return @{state='ready';choices=@('incoming');receipt='';token='';view=$shown.preview;message=[string]$shown.message}
    }
    restore={ param($R)
        if ($R.choice -cne 'incoming') { throw (T 'WkChoiceRequired') }
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
}
if ($implArgs.Count -and $implArgs[0] -ceq '-LibraryOnly') { return }
Invoke-Impl $script:ClaudeCodeOps $implArgs
