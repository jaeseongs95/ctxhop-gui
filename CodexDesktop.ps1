#requires -Version 5.1
# Codex Desktop 대화 구현(벤더 계약 v1, docs\contract-v1.md). Worker가 impls.json으로 실행한다.
# 내보내기·기존 대화 비교는 고정 Python 백엔드가, 지원하는 새 대화 복원은 고정 Go helper가 맡는다.
$ErrorActionPreference='Stop'
$implArgs=$args   # Worker.ps1을 dot-source하면 $args가 바뀔 수 있어 먼저 보관한다.
. (Join-Path $PSScriptRoot 'Worker.ps1') -LibraryOnly
# Release integration replaces this pin only after reviewing the final candidate.
$script:DesktopBackendSHA256='DEF1FDB9B9B17721682F38EFEB2BA9322089453C265A334133F6346F0F75B349'
# Final reproducible build integration supplies this pin before acceptance.
$script:DesktopGoSHA256='PENDING_REVIEW'
function Invoke-DesktopGo([string[]]$Arguments) {
    $exe=Join-Path $PSScriptRoot 'bin\ctxhop-codex.exe'
    Assert-FrozenFile $exe $script:DesktopGoSHA256
    try { Invoke-JsonNative $exe $Arguments }
    catch {
        $code=$_.Exception.Data['backendResult'].reasonCode
        if ($code -is [string] -and $code) { $_.Exception.Data['reasonCode']=$code }
        throw
    }
}
function Assert-DesktopGoPlan([object]$Report) {
    if ($Report.status -cnotin @('new','exists','unsupported','blocked') -or $Report.reasonCode -isnot [string] -or $Report.reason -isnot [string]) { throw (T 'WkGoPlanInvalid') }
    if ($Report.status -ceq 'new') {
        if ($Report.token -isnot [string] -or $Report.token -cnotmatch '^[0-9a-f]{64}$' -or $Report.source.sessionId -isnot [string]) { throw (T 'WkGoPlanInvalid') }
        Assert-NativeId $Report.source.sessionId
        if ($Report.projectConfig -isnot [array]) { throw (T 'WkGoPlanInvalid') }
    }
}
function Get-DesktopRuntime {
    $backend=Join-Path $PSScriptRoot 'backend\desktop_sessions.py'
    Assert-FrozenFile $backend $script:DesktopBackendSHA256
    # Python은 Codex Desktop이 설치·갱신하는 런타임이라 PC마다 SHA가 달라 고정하지 않는다(claude/codex 실행 파일과 같은 취급).
    # PATH는 쓰지 않는다. 다른 위치는 이 PC의 backend\runtime.json {"pythonPath":"절대경로"}로만 지정한다.
    $python=Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    $settings=Join-Path $PSScriptRoot 'backend\runtime.json'
    if (Test-Path -LiteralPath $settings -PathType Leaf) {
        $runtime=Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($runtime.pythonPath -isnot [string] -or -not [IO.Path]::IsPathRooted($runtime.pythonPath)) { throw (T 'WkPythonPathNotAbsolute') }
        $python=$runtime.pythonPath
    }
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw (T 'WkPythonMissing' $python) }
    return @{backend=$backend;python=$python}
}
function Invoke-DesktopBackend([string[]]$Arguments) {
    $runtime=Get-DesktopRuntime
    Invoke-JsonNative $runtime.python (@('-I','-B','-u',$runtime.backend) + $Arguments)
}
function Get-DesktopHome([object]$Job) {
    $path=if ($Job.home) {[string]$Job.home} elseif ($env:CODEX_HOME) {$env:CODEX_HOME} else {Join-Path $env:USERPROFILE '.codex'}
    if (-not [IO.Path]::IsPathRooted($path) -or -not (Test-Path -LiteralPath $path -PathType Container)) { throw (T 'WkDesktopHomeMissing') }
    Normalize-ProjectPath (Resolve-Path -LiteralPath $path).Path
}
function Assert-DesktopTarget([object]$Job) {
    if (-not $Job.projectPath -or -not (Test-Path -LiteralPath $Job.projectPath -PathType Container)) { throw (T 'WkTargetFolderRequired') }
    Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path
}
function Assert-DesktopInspect([object]$Report) {
    if ($Report.status -notin @('new','equal','incoming_newer','local_newer','conflict','blocked') -or $Report.reason -isnot [string]) { throw (T 'WkInspectStatusInvalid') }
    if ($Report.status -ne 'blocked' -and ($Report.token -isnot [string] -or -not $Report.token)) { throw (T 'WkInspectTokenMissing') }
    foreach ($field in @('source','target')) { if ($Report.PSObject.Properties.Name -notcontains $field) { throw (T 'WkInspectFieldMissing' $field) } }
}
function Get-DesktopSessions([object]$Job,[string]$DesktopRoot) {
    $offset=0; $items=@()
    do {
        $page=Invoke-DesktopBackend @('list','--home',$DesktopRoot,"--search=$($Job.search)",'--offset',[string]$offset,'--limit','200')
        if (($page.total -isnot [int] -and $page.total -isnot [long]) -or $page.total -lt 0 -or $page.sessions -isnot [array] -or $page.sessions.Count -gt 200) { throw (T 'WkListResponseInvalid') }
        foreach ($row in $page.sessions) {
            Assert-NativeId $row.id
            if ($row.cwd -isnot [string] -or $row.title -isnot [string] -or $row.historyMode -isnot [string] -or $row.archived -isnot [bool] -or ($row.children -isnot [int] -and $row.children -isnot [long]) -or $row.children -lt 0) { throw (T 'WkListMetadataInvalid') }
            # 하위 에이전트 대화는 백엔드가 목록에서 빼고 부모 대화와 한 묶음으로 옮긴다. children은 그 묶음의 하위 대화 수다.
            $items += [pscustomobject]@{agent='codex-desktop';nativeId=$row.id;remoteId='';title=$row.title;updatedAt=$row.updatedAt;local=$true;recordCount=0;sourceCwd=$row.cwd;historyMode=$row.historyMode;archived=$row.archived;children=[int]$row.children;blockedReason=$null}
        }
        $offset+=$page.sessions.Count
        if ($page.sessions.Count -eq 0 -and $offset -lt $page.total) { throw (T 'WkListPageStalled') }
    } while ($offset -lt $page.total)
    $remote=Invoke-Bundle @('list','--json')
    if ($remote.bundles -isnot [array]) { throw (T 'WkBundleListInvalid') }
    foreach ($bundle in $remote.bundles) {
        try {
            Assert-BundleId $bundle.id; Assert-BundleMetadata $bundle.metadata
            $m=$bundle.metadata
            # 프로젝트 파일과 그 연결 기록은 대화가 아니므로 목록에 넣지 않는다.
            if ($m.historyMode -like 'project-*') { continue }
            if ($Job.search -and ($m.title+' '+$m.sessionId+' '+$m.sourceCwd).IndexOf([string]$Job.search,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            # 묶음 형식 백업은 historyMode 끝에 ;family=하위 대화 수가 있다. 없으면 하위 대화가 빠졌을 수 있는 이전 형식이다($null).
            $children=if ($m.historyMode -match ';family=(\d{1,4})$') {[int]$Matches[1]} else {$null}
            $items += [pscustomobject]@{agent='codex-desktop';nativeId=$m.sessionId;remoteId=$bundle.id;title=$m.title;updatedAt=$m.updatedAt;local=$false;recordCount=$m.recordCount;sourceCwd=$m.sourceCwd;historyMode=$m.historyMode;archived=$false;children=$children}
        } catch {
            $items += [pscustomobject]@{agent='codex-desktop';nativeId='';remoteId=[string]$bundle.id;title=(T 'WkUnverifiedBundleTitle');updatedAt='';local=$false;recordCount=0;blockedReason=$_.Exception.Message}
        }
    }
    return @{sessions=@($items);message=(T 'WkListLoaded')}
}
function Read-DesktopReceipt([object]$Job) {
    if ($Job.receipt -isnot [string] -or -not $Job.receipt) { throw (T 'WkReceiptMissing') }
    $root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CtxHopGUI\staging')).TrimEnd('\')+'\'
    $receipt=[IO.Path]::GetFullPath($Job.receipt)
    if (-not $receipt.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($receipt) -ne 'inspect.json') { throw (T 'WkReceiptPathInvalid') }
    $record=Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
    $archive=Join-Path (Split-Path -Parent $receipt) 'session.archive'
    if ($record.archive -ne $archive -or $record.bundleId -cne $Job.remoteId -or $record.nativeId -cne $Job.nativeId -or $record.home -ne (Get-DesktopHome $Job) -or $record.cwd -ne (Assert-DesktopTarget $Job) -or $record.token -cne $Job.token) { throw (T 'WkReceiptMismatch') }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $record.sha256) { throw (T 'WkArchiveChanged') }
    if ($record.route -cnotin @('go','python') -or $record.reasonCode -isnot [string]) { throw (T 'WkReceiptRouteInvalid') }
    Assert-DesktopInspect $record.preview
    if ($record.route -ceq 'go' -and $record.preview.status -cne 'new') { throw (T 'WkReceiptRouteInvalid') }
    if ($record.token -cne $record.preview.token) { throw (T 'WkReceiptTokenMismatch') }
    return $record
}
function Export-DesktopSession([object]$Request) {
    # 대화 하나를 새 staging에 내보낸다. 실패한 내보내기는 쓸 파일이 없거나 버려야 하는 파일뿐이라 평문 staging을 남기지 않는다.
    Assert-NativeId $Request.nativeId
    $desktopRoot=Get-DesktopHome $Request
    $stage=New-DesktopStage; $archive=Join-Path $stage 'session.archive'
    try { $export=Invoke-DesktopBackend @('export','--home',$desktopRoot,'--id',$Request.nativeId,'--output',$archive) }
    catch { $null=Remove-DesktopStage $stage; throw }
    # The backend owns archive semantics; never infer historyMode or recordCount from the list.
    Assert-BundleMetadata $export.metadata
    if ($export.metadata.sessionId -cne $Request.nativeId -or -not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw (T 'WkExportResultInvalid') }
    $folders=@{sourceCwd=[string]$export.metadata.sourceCwd;cwds=@($export.folders.cwds);edits=@($export.folders.edits)}
    $folders.sourceStamp=Get-SourceStamp $folders.sourceCwd $folders.cwds $folders.edits
    return @{stage=$stage;archive=$archive;metadata=$export.metadata;folders=$folders}
}
function ConvertFrom-DesktopBusy([Management.Automation.ErrorRecord]$ErrorRecord) {
    # 진행 중인 대화(busy)는 실패가 아니라 건너뜀이다. 다른 실패는 그대로 던진다.
    $report=$ErrorRecord.Exception.Data['backendResult']
    if ($report.status -ceq 'busy') { return @{status='busy';reason=$ErrorRecord.Exception.Message;detail=$report} }
    throw $ErrorRecord
}
function Get-DesktopRecord([string]$DesktopRoot,[string]$RecordId) {
    # 백엔드 복구 기록(run 폴더)의 상태(S3 명세 2.3절). 백엔드 pending()은 손상된 journal에서 예외를 내므로 직접 읽는다.
    # 기록 이름은 작업 ID다(apply --run). 예전 기록도 32자 hex 이름이라 같은 방법으로 찾는다.
    $null=Assert-OperationId $RecordId
    $run=Join-Path $DesktopRoot ".ctxhop-desktop-recovery\$RecordId"
    $row=[ordered]@{recordId=$RecordId;operationId=$RecordId;nativeId=$null;path=$run;state='absent';sha256=$null;canRollback=$false;files=$null;impl=$null}
    if (-not [IO.Directory]::Exists($run)) { return $row }
    $journal=Join-Path $run 'journal.json'; $resolved=Join-Path $run 'journal.resolved.json'
    $present=@($journal,$resolved | Where-Object { [IO.File]::Exists($_) })
    if (-not $present.Count) { return $row }
    $row.state='unreadable'
    if ($present.Count -ne 1) { return $row }
    try {
        $row.sha256=(Get-FileHash -LiteralPath $present[0] -Algorithm SHA256).Hash
        # 닫힌 기록은 내용을 읽지 않는다. 읽을 수 없던 기록도 사용자가 보고 닫을 수 있기 때문이다.
        if ($present[0] -eq $resolved) { $row.state='resolved'; return $row }
        $record=Get-Content -LiteralPath $journal -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.home -isnot [string] -or $record.home.TrimEnd('\') -ne $DesktopRoot.TrimEnd('\')) { return $row }
        if ($record.id -is [string]) { $row.nativeId=$record.id }
        if ($record.impl -is [string]) { $row.impl=$record.impl }
        if ([string]$record.status -cin @('pending','complete','rolled_back')) { $row.state=[string]$record.status }
    } catch { $row.state='unreadable' }
    $row.canRollback=$row.state -eq 'pending' -and $row.impl -cin @($null,'ctxhop-codex')
    return $row
}
function Get-DesktopRecordRows([string]$DesktopRoot) {
    # 되돌리거나 닫아야 할 기록(pending·unreadable).
    $root=Join-Path $DesktopRoot '.ctxhop-desktop-recovery'
    if (-not [IO.Directory]::Exists($root)) { return @() }
    foreach ($folder in [IO.Directory]::GetDirectories($root)) {
        # 백엔드는 32자 hex 이름으로만 기록을 만든다. 다른 이름의 폴더는 이 도구의 기록이 아니다.
        $name=[IO.Path]::GetFileName($folder)
        if ($name -cnotmatch '^[0-9a-f]{32}$') { continue }
        $row=Get-DesktopRecord $DesktopRoot $name
        if ($row.state -in @('pending','unreadable')) { [pscustomobject]$row }
    }
}
$script:CodexDesktopOps=@{
    list={ param($R) @{sessions=@((Get-DesktopSessions $R (Get-DesktopHome $R)).sessions);message=(T 'WkListLoaded')} }
    describe={ param($R)
        try { $export=Export-DesktopSession $R } catch { return (ConvertFrom-DesktopBusy $_) }
        # 작업 폴더만 알려 주고 평문 사본은 지운다. backup이 다시 내보내 같은 폴더인지 비교한다.
        $null=Remove-DesktopStage $export.stage
        return $export.folders
    }
    backup={ param($R)
        try { $export=Export-DesktopSession $R } catch { return (ConvertFrom-DesktopBusy $_) }
        if ($R.sourceStamp -and $export.folders.sourceStamp -cne $R.sourceStamp) {
            # describe 뒤에 작업 폴더가 바뀌었다. 사용자가 확인하지 않은 폴더가 생겼을 수 있으므로 아무것도 올리지 않는다.
            $null=Remove-DesktopStage $export.stage
            return @{status='changed';reasonCode='source_changed';reason=(T 'WkSourceChanged')}
        }
        $metadata=Join-Path $export.stage 'metadata.json'
        $metadataJson=$export.metadata | Select-Object sessionId,title,sourceCwd,updatedAt,historyMode,cliVersion,recordCount | ConvertTo-Json
        [IO.File]::WriteAllText($metadata,$metadataJson,[Text.UTF8Encoding]::new($false))
        $bundle=Invoke-Bundle @('put','--input',$export.archive,'--metadata',$metadata,'--json')
        Assert-BundleId $bundle.id
        # 원본은 Codex에, 백업은 암호화 bundle로 남았으므로 평문 사본은 지운다. 실패하면 위에서 중단돼 남는다.
        return @{remoteId=$bundle.id;message=(T 'WkBackupDone' $bundle.id (Remove-DesktopStage $export.stage))}
    }
    preview={ param($R)
        Assert-NativeId $R.nativeId; Assert-BundleId $R.remoteId
        $desktopRoot=Get-DesktopHome $R; $cwd=Assert-DesktopTarget $R; $stage=New-DesktopStage; $archive=Join-Path $stage 'session.archive'
        $null=Get-BundleFile $R.remoteId $archive
        $route='go'; $reasonCode=''
        try {
            $plan=Invoke-DesktopGo @('plan','--home',$desktopRoot,'--archive',$archive,'--cwd',$cwd)
            Assert-DesktopGoPlan $plan
            $reasonCode=[string]$plan.reasonCode
            if ($plan.status -cin @('new','blocked')) { $preview=$plan }
            else {
                # Only an explicit exists/unsupported plan selects the compatibility backend.
                $route='python'
                $preview=Invoke-DesktopBackend @('inspect','--home',$desktopRoot,'--archive',$archive,'--cwd',$cwd)
            }
        } catch {
            # Native failure or an invalid plan blocks this preview; never invoke Python after it.
            $code=$_.Exception.Data['reasonCode']
            $reasonCode=if ($code -is [string] -and $code) {$code} else {'plan_failed'}
            $preview=[pscustomobject]@{status='blocked';reason=$_.Exception.Message;reasonCode=$reasonCode;token='';source=$null;target=$null}
        }
        Assert-DesktopInspect $preview
        if ($preview.status -ne 'blocked' -and $preview.source.sessionId -cne $R.nativeId) { throw (T 'WkArchiveIdMismatch') }
        $receipt=Join-Path $stage 'inspect.json'
        @{home=$desktopRoot;cwd=$cwd;archive=$archive;bundleId=$R.remoteId;nativeId=$R.nativeId;token=$preview.token;sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash;preview=$preview;route=$route;reasonCode=$reasonCode} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receipt -Encoding UTF8
        # 손상·호환 불가(blocked) 백업은 복원을 고를 수 없다.
        return @{state=[string]$preview.status;choices=@(if ($preview.status -ne 'blocked') {'incoming'});receipt=$receipt;token=[string]$preview.token;view=$preview;message=(T 'WkPreviewDone')}
    }
    restore={ param($R)
        $record=Read-DesktopReceipt $R
        if ($R.choice -cne 'incoming') { throw (T 'WkChoiceRequired') }
        $run=Assert-OperationId $R.operationId
        if ($record.preview.status -eq 'blocked') { throw (T 'WkBlockedRestore') }
        try {
            if ($record.route -ceq 'go') { $applied=Invoke-DesktopGo @('import','--home',$record.home,'--archive',$record.archive,'--cwd',$record.cwd,'--token',$record.token,'--run',$run) }
            else { $applied=Invoke-DesktopBackend @('apply','--home',$record.home,'--archive',$record.archive,'--cwd',$record.cwd,'--token',$record.token,'--choice','incoming','--run',$run) }
        }
        catch {
            # 구현은 가져오기에 실패하면 이 홈에 남은 복구 기록(pending) 목록을 준다. 비었으면 쓰기 전 실패이고, 목록이 없으면 알 수 없다.
            $pending=$_.Exception.Data['backendResult'].pending
            $_.Exception.Data['recovery']=if ($pending -isnot [array]) {'unknown'} elseif ($pending.Count) {'required'} else {'none'}
            throw
        }
        $effect=@{imported='restored';equal='equal';local_newer='local_newer'}[[string]$applied.status]
        if (-not $effect) {
            $exception=[InvalidOperationException]::new((T 'WkRestoreStatusUnknown' $applied.status))
            $exception.Data['recovery']='unknown'; $exception.Data['backendResult']=$applied
            throw $exception
        }
        $message=switch ($effect) { restored {T 'WkRestoreImported' $R.nativeId} equal {T 'WkRestoreEqual' $R.nativeId} local_newer {T 'WkRestoreLocalNewer' $R.nativeId} }
        # 성공하면 교체 전·후 원본은 백엔드 복구 폴더에 있으므로 내려받은 평문 사본을 지운다. 실패하면 증거로 남긴다.
        $message+=Remove-DesktopStage (Split-Path -Parent $record.archive)
        return @{effect=$effect;nativeId=[string]$R.nativeId;view=$applied;message=$message}
    }
    recover={ param($R)
        # 복구 기록 조회·되돌리기·닫기(S3 명세 4.2절). 되돌리기는 기존 백엔드 recover가 하고, 닫기는 journal 이름만 바꾼다.
        if ([string]$R.mode -cnotin @('status','list','rollback','resolve')) { throw (T 'WkRecoverModeInvalid' ([string]$R.mode)) }
        # Codex 데이터 폴더가 없는 PC(Claude만 쓰는 경우)에는 복구 기록도 없다. 목록은 비어 있고, 나머지 모드는 폴더가 없으면 실패한다.
        if ([string]$R.mode -ceq 'list') {
            $path=if ($R.home) {[string]$R.home} elseif ($env:CODEX_HOME) {$env:CODEX_HOME} else {Join-Path $env:USERPROFILE '.codex'}
            if ([IO.Path]::IsPathRooted($path) -and -not (Test-Path -LiteralPath $path)) { return @{records=@()} }
        }
        $desktopRoot=Get-DesktopHome $R
        switch -CaseSensitive ([string]$R.mode) {
            status { return @{state=(Get-DesktopRecord $desktopRoot ([string]$R.operationId)).state} }
            list { return @{records=@(Get-DesktopRecordRows $desktopRoot)} }
            rollback {
                $row=Get-DesktopRecord $desktopRoot ([string]$R.recordId)
                if ($row.state -eq 'rolled_back') { return @{effect='rolled_back';message=(T 'WkRecoverRolledBack' $row.path)} }
                if ($row.state -ne 'pending') { return @{status='failed';reasonCode='unsupported_record';reason=(T 'WkRecordNotPending' $row.state);records=@([pscustomobject]$row)} }
                if ($row.impl -cnotin @($null,'ctxhop-codex')) { return @{status='failed';reasonCode='unsupported_record';reason=(T 'WkRecordImplUnknown');records=@([pscustomobject]$row)} }
                try {
                    if ($row.impl -ceq 'ctxhop-codex') { $done=Invoke-DesktopGo @('rollback','--home',$desktopRoot,'--run',$row.recordId) }
                    else { $done=Invoke-DesktopBackend @('recover','--home',$desktopRoot,'--run',$row.path) }
                }
                catch {
                    # 백엔드는 중단 뒤 대화가 바뀌었으면 되돌리지 않고 멈춘다. 기록은 pending으로 남는다.
                    $code=if ($_.Exception.Data['backendResult'].status -eq 'busy') {'busy'} else {'needs_attention'}
                    return @{status='failed';reasonCode=$code;reason=$_.Exception.Message;records=@([pscustomobject](Get-DesktopRecord $desktopRoot $row.recordId))}
                }
                if ($done.status -cne 'rolled_back') { throw (T 'WkRestoreStatusUnknown' $done.status) }
                return @{effect='rolled_back';message=(T 'WkRecoverRolledBack' $row.path)}
            }
            resolve {
                # 사용자가 창에서 본 기록 내용(SHA-256)과 같을 때만 닫는다. 이미 닫혔으면 성공이고, 닫은 이름이 있으면 덮어쓰지 않는다.
                $row=Get-DesktopRecord $desktopRoot ([string]$R.recordId)
                if ($row.state -eq 'resolved') { return @{effect='resolved';message=(T 'WkRecoverResolved' $row.path)} }
                if ($row.state -notin @('pending','unreadable')) { return @{status='failed';reasonCode='unsupported_record';reason=(T 'WkRecordNotPending' $row.state);records=@([pscustomobject]$row)} }
                if (-not $row.sha256 -or $row.sha256 -ne [string]$R.sha256) { return @{status='failed';reasonCode='changed';reason=(T 'WkRecordChanged');records=@([pscustomobject]$row)} }
                [IO.File]::Move((Join-Path $row.path 'journal.json'),(Join-Path $row.path 'journal.resolved.json'))
                return @{effect='resolved';message=(T 'WkRecoverResolved' $row.path)}
            }
        }
        throw (T 'WkRecoverModeInvalid' ([string]$R.mode))
    }
    guard={ param($R)
        # 프로젝트 파일을 먼저 쓰기 전에, apply와 같은 검사로 Codex 앱·CLI·IDE가 모두 닫혔는지 본다. 열려 있으면 busy다.
        $desktopRoot=Get-DesktopHome $R
        try { $closed=Invoke-DesktopGo @('guard','--home',$desktopRoot); if ($closed.status -cne 'closed') { throw (T 'WkGoGuardInvalid') } }
        catch {
            if (-not $_.Exception.Data['backendResult']) { throw }
            $detail=$_.Exception.Data['backendResult']
            if ($detail.reasonCode -ceq 'busy' -or $detail.status -ceq 'busy') { return @{status='busy';reasonCode='engine_open';reason=$_.Exception.Message} }
            throw
        }
        return @{}
    }
    # Codex Desktop은 대화를 여는 공식 명령이 없어 사용자가 직접 연다.
    open={ param($R) @{status='unsupported';reasonCode='open_manually';reason=(T 'WkOpenManually')} }
}
if ($implArgs.Count -and $implArgs[0] -ceq '-LibraryOnly') { return }
Invoke-Impl $script:CodexDesktopOps $implArgs
