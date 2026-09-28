#requires -Version 5.1
# Codex Desktop 대화 구현(벤더 계약 v1, docs\contract-v1.md). Worker가 impls.json으로 실행한다.
# 내보내기·비교·가져오기는 고정한 Python 백엔드(backend\desktop_sessions.py)가 하고, 전송은 공통 도구 ctxhop.exe bundle이 한다.
$ErrorActionPreference='Stop'
$implArgs=$args   # Worker.ps1을 dot-source하면 $args가 바뀔 수 있어 먼저 보관한다.
. (Join-Path $PSScriptRoot 'Worker.ps1') -LibraryOnly
# Release integration replaces this pin only after reviewing the final candidate.
$script:DesktopBackendSHA256='7BD1B4EBBC33A318B0DDDE1F55409DE88B8076AAEB47E880C55ADEDC61245AA2'
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
    Assert-DesktopInspect $record.preview
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
        $preview=Invoke-DesktopBackend @('inspect','--home',$desktopRoot,'--archive',$archive,'--cwd',$cwd)
        Assert-DesktopInspect $preview
        if ($preview.status -ne 'blocked' -and $preview.source.sessionId -cne $R.nativeId) { throw (T 'WkArchiveIdMismatch') }
        $receipt=Join-Path $stage 'inspect.json'
        @{home=$desktopRoot;cwd=$cwd;archive=$archive;bundleId=$R.remoteId;nativeId=$R.nativeId;token=$preview.token;sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash;preview=$preview} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receipt -Encoding UTF8
        # 손상·호환 불가(blocked) 백업은 복원을 고를 수 없다.
        return @{state=[string]$preview.status;choices=@(if ($preview.status -ne 'blocked') {'incoming'});receipt=$receipt;token=[string]$preview.token;view=$preview;message=(T 'WkPreviewDone')}
    }
    restore={ param($R)
        $record=Read-DesktopReceipt $R
        if ($R.choice -cne 'incoming') { throw (T 'WkChoiceRequired') }
        $run=Assert-OperationId $R.operationId
        if ($record.preview.status -eq 'blocked') { throw (T 'WkBlockedRestore') }
        try { $applied=Invoke-DesktopBackend @('apply','--home',$record.home,'--archive',$record.archive,'--cwd',$record.cwd,'--token',$record.token,'--choice','incoming','--run',$run) }
        catch {
            # 백엔드는 가져오기에 실패하면 이 홈에 남은 복구 기록(pending) 목록을 준다. 비었으면 쓰기 전 실패이고, 목록이 없으면 알 수 없다.
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
    # Codex Desktop은 대화를 여는 공식 명령이 없어 사용자가 직접 연다.
    open={ param($R) @{status='unsupported';reasonCode='open_manually';reason=(T 'WkOpenManually')} }
}
if ($implArgs.Count -and $implArgs[0] -ceq '-LibraryOnly') { return }
Invoke-Impl $script:CodexDesktopOps $implArgs
