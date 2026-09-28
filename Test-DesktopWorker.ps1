#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Worker.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'CodexDesktop.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'ClaudeCode.ps1') -LibraryOnly
Enable-WorkerJob   # 복원 시험은 실제 Worker처럼 Job 객체 안에서 돈다.
$script:Checks=0
function Assert([bool]$Value,[string]$Message) { $script:Checks++; if (-not $Value) { throw "ASSERT: $Message" } }
# 벤더 계약 경계: 실제 구현의 처리기를 이 프로세스에서 부르되 요청·응답은 JSON을 거치고 Worker와 같은 응답 검사를 한다.
# 네이티브 호출은 아래 함수 교체로 흉내 낸다. 프로세스 경계와 실제 진입점은 Test-Contract.ps1이 확인한다.
$script:VendorOps=@{'codex-desktop'=$script:CodexDesktopOps;'claude-code'=$script:ClaudeCodeOps}
function Invoke-VendorOp([string]$Vendor,[string]$Op,[Collections.IDictionary]$Request,[string]$JobDir) {
    $id=[guid]::NewGuid().ToString()
    $body=[ordered]@{protocolVersion=1;requestId=$id;op=$Op;language=$script:UiLanguage}
    foreach ($key in $Request.Keys) { $body[$key]=$Request[$key] }
    $script:VendorCalls+=,"$Vendor/$Op"
    $response=ConvertTo-Json -InputObject (Invoke-ImplOp $script:VendorOps[$Vendor] (ConvertTo-Json -InputObject $body -Depth 30 | ConvertFrom-Json)) -Depth 40 | ConvertFrom-Json
    Assert (Test-VendorResponse $response $id $Op) "contract response for $Vendor $Op"
    return $response
}
$script:VendorCalls=@()
function Throws([scriptblock]$Body,[string]$Pattern) {
    $errorRecord=$null; try { & $Body | Out-Null } catch { $errorRecord=$_ }
    Assert ($null -ne $errorRecord) 'operation must fail'
    Assert ($errorRecord.Exception.Message -match $Pattern) "expected $Pattern, got $($errorRecord.Exception.Message)"
}
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('CtxHop-vnext-worker-'+[guid]::NewGuid().ToString('N'))
$oldLocal=$env:LOCALAPPDATA
$script:Calls=@(); $script:Id='11111111-1111-4111-8111-111111111111'; $script:State='conflict'; $script:ApplyFail=$false
$script:BundleA='peer-a/'+('a'*32); $script:BundleB='peer-b/'+('b'*32)
$script:Metadata=[pscustomobject]@{sessionId=$script:Id;title='합성 대화';sourceCwd='D:\source';updatedAt='2026-09-26T01:00:00Z';historyMode='paginated';cliVersion='0.116.0';recordCount=4}
function Invoke-DesktopBackend([string[]]$Arguments) {
    $script:Calls+=,[pscustomobject]@{kind='backend';arguments=$Arguments}
    switch ($Arguments[0]) {
        list {
            $offset=[int]$Arguments[[array]::IndexOf($Arguments,'--offset')+1]
            $count=if ($offset -eq 0) {200} else {1}
            return [pscustomobject]@{total=201;sessions=@(for($i=0;$i -lt $count;$i++){[pscustomobject]@{id=('00000000-0000-4000-8000-{0:d12}' -f ($offset+$i));title='fixture';cwd='D:\all-projects';updatedAt='2026-09-26T01:00:00Z';historyMode='paginated';archived=($i%2 -eq 0);children=$(if ($i -eq 1) {2} elseif ($script:ListBadChildren) {-1} else {0})}})}
        }
        export {
            $file=$Arguments[[array]::IndexOf($Arguments,'--output')+1]
            Assert (-not (Test-Path -LiteralPath $file)) 'export must use new file'
            [IO.File]::WriteAllText($file,'synthetic archive',[Text.UTF8Encoding]::new($false))
            if ($script:ExportStatus) {
                # 내보내는 동안 대화가 바뀌었거나(busy) 다른 이유로 막힌 경우(blocked): 백엔드는 파일을 만든 뒤 멈출 수 있다.
                $e=[InvalidOperationException]::new('내보내기 실패')
                $e.Data['backendResult']=[pscustomobject]@{status=$script:ExportStatus;reason='fixture';token=$null}
                throw $e
            }
            return @{metadata=$script:Metadata}
        }
        inspect { return [pscustomobject]@{status=$script:State;reason='fixture_content_comparison';token='exact-token-A';source=@{sessionId=$script:Id};target=@{sessionId=$script:Id}} }
        apply {
            if ($script:ApplyFail) {
                $e=[InvalidOperationException]::new('복원 실패, 복구 기록 유지')
                $e.Data['backendResult']=[pscustomobject]@{status='blocked';reason='partial write';token=$null;pending=@('fixture/.ctxhop-desktop-recovery/run')}
                throw $e
            }
            return @{status='imported';journal='fixture/recovery/completed.json'}
        }
        guard {
            if ($script:GuardOpen) {
                $e=[InvalidOperationException]::new('Codex 앱/CLI/IDE를 모두 종료하세요. Codex/IDE writer PID: 1')
                $e.Data['backendResult']=[pscustomobject]@{status='blocked';reason='writer';token=$null}
                throw $e
            }
            return @{status='closed';engine='0.158.0'}
        }
        recover {
            if ($script:RecoverStatus) {
                $e=[InvalidOperationException]::new('중단 뒤 세션 파일이 변경됐습니다. 자동 복구를 중단합니다.')
                $e.Data['backendResult']=[pscustomobject]@{status=$script:RecoverStatus;reason='fixture';token=$null}
                throw $e
            }
            $journal=Join-Path $Arguments[[array]::IndexOf($Arguments,'--run')+1] 'journal.json'
            $record=Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json; $record.status='rolled_back'
            [IO.File]::WriteAllText($journal,(ConvertTo-Json -InputObject $record -Compress),[Text.UTF8Encoding]::new($false))
            return @{status='rolled_back';id=$record.id;members=1}
        }
        default { throw 'unexpected backend operation' }
    }
}
function Invoke-Bundle([string[]]$Arguments) {
    $script:Calls+=,[pscustomobject]@{kind='bundle';arguments=$Arguments}
    switch ($Arguments[0]) {
        list {
            $a=$script:Metadata.PSObject.Copy(); $b=$script:Metadata.PSObject.Copy()
            $a.updatedAt='2099-09-26T01:00:00Z'; $b.updatedAt='1990-09-26T01:00:00Z'; $a.historyMode='paginated;family=3'
            return @{bundles=@(@{id=$script:BundleA;metadata=$a},@{id=$script:BundleB;metadata=$b},@{id='invalid';metadata=@{}})}
        }
        put {
            $file=$Arguments[[array]::IndexOf($Arguments,'--metadata')+1]
            Assert (Get-Acl -LiteralPath (Split-Path -Parent $file)).AreAccessRulesProtected 'plaintext backup staging must disable ACL inheritance'
            $m=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            $bytes=[IO.File]::ReadAllBytes($file)
            Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Go JSON metadata must use UTF8 without BOM'
            Assert (($m.PSObject.Properties.Name | Sort-Object) -join ',' -eq 'cliVersion,historyMode,recordCount,sessionId,sourceCwd,title,updatedAt') 'metadata must have exact seven keys'
            Assert ($m.historyMode -eq 'paginated' -and $m.recordCount -eq 4) 'metadata must come from export'
            return @{id=$script:BundleA}
        }
        get {
            $file=$Arguments[[array]::IndexOf($Arguments,'--output')+1]
            Assert (-not (Test-Path -LiteralPath $file)) 'download must use new file'
            [IO.File]::WriteAllText($file,'synthetic archive',[Text.UTF8Encoding]::new($false))
            return @{id=$Arguments[2];sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $file).Length}
        }
        default { throw 'unexpected bundle operation' }
    }
}
try {
    $null=New-Item -ItemType Directory -Path $testDirectory
    $env:LOCALAPPDATA=$testDirectory
    $desktopRoot=Join-Path $testDirectory 'synthetic-home'; $target=Join-Path $testDirectory '프로젝트 폴더'
    $null=New-Item -ItemType Directory -Path $desktopRoot; $null=New-Item -ItemType Directory -Path $target
    $job=@{action='List';agent='codex-desktop';home=$desktopRoot;projectPath=$target;search='';nativeId=$script:Id;remoteId=$script:BundleA}
    $list=Invoke-JobCore $job
    Assert ($list.sessions.Count -eq 204) 'all pages, two branches and blocked metadata must remain visible'
    Assert (-not @($list.sessions | Where-Object { $_.agent -cne 'codex-desktop' }).Count) 'the caller, not the implementation, names the vendor of each row'
    Assert (@($script:Calls | Where-Object {$_.kind -eq 'backend' -and $_.arguments[0] -eq 'list'}).Count -eq 2) 'metadata list must paginate 200 at a time'
    Assert (@($list.sessions | Where-Object archived).Count -gt 0) 'archived conversations must remain visible'
    Assert (@($list.sessions | Where-Object nativeId -eq $script:Id).Count -eq 2) 'same UUID branches must not collapse by date'
    Assert ($list.sessions[-1].blockedReason -and -not $list.sessions[-1].local) 'invalid metadata stays visible and blocked'
    Assert (@($list.sessions | Where-Object {$_.local -and $_.children -eq 2}).Count -eq 1 -and -not @($list.sessions | Where-Object {$_.local -and $_.blockedReason}).Count) 'local rows carry the subagent count and are never blocked for it'
    Assert (@($list.sessions | Where-Object {$_.remoteId -eq $script:BundleA -and $_.children -eq 3}).Count -eq 1 -and @($list.sessions | Where-Object {$_.remoteId -eq $script:BundleB -and $null -eq $_.children}).Count -eq 1) 'family backups report their subagent count; older backups report none'
    $script:ListBadChildren=$true; Throws {Invoke-JobCore @{action='List';agent='codex-desktop';home=$desktopRoot;search=''}} '목록 메타데이터'; $script:ListBadChildren=$false
    $staging=Join-Path $testDirectory 'CtxHopGUI\staging'
    $job.action='Backup'; $backup=Invoke-JobCore $job
    Assert ($backup.remoteId -eq $script:BundleA -and ($script:VendorCalls -join ',') -ceq 'codex-desktop/list,codex-desktop/list,codex-desktop/backup') 'export publishes opaque encrypted bundle through the contract'
    Assert (-not @(Get-ChildItem -LiteralPath $staging -Force)) 'uploaded plaintext backup copy is removed'
    # 프로젝트 파일을 함께 올릴 때는 describe가 먼저 내보낸다. 진행 중이면 대화 백업도 건너뛰고, 다른 실패는 backup이 다시 알린다.
    foreach ($status in 'busy','blocked') {
        foreach ($withProject in $false,$true) {
            $job.projectBackup=$withProject; $script:ExportStatus=$status; $exportError=$null; $script:VendorCalls=@()
            try { $null=Invoke-JobCore $job } catch { $exportError=$_ }
            $script:ExportStatus=$null
            Assert ($exportError -and $exportError.Exception.Data['backendResult'].status -eq $status) "a $status export keeps the backend status for the GUI (project files: $withProject)"
            Assert (-not @(Get-ChildItem -LiteralPath $staging -Force)) "a $status export leaves no plaintext staging copy (project files: $withProject)"
            if ($withProject -and $status -eq 'busy') { Assert (($script:VendorCalls -join ',') -ceq 'codex-desktop/describe') 'a busy conversation is skipped before backup is called' }
        }
    }
    $job.Remove('projectBackup')
    $job.action='Preview'; $preview=Invoke-JobCore $job
    Assert ($preview.preview.status -eq 'conflict') 'backend content comparison controls status'
    $previewStage=Split-Path -Parent $preview.receipt
    Assert (Get-Acl -LiteralPath $previewStage).AreAccessRulesProtected 'plaintext preview staging must disable ACL inheritance'
    $job.action='Restore'; $job.receipt=$preview.receipt; $job.token=$preview.preview.token; $job.choice='skip'
    $before=$script:Calls.Count; Throws {Invoke-JobCore $job} '선택하세요'
    Assert ($script:Calls.Count -eq $before) 'only the incoming choice reaches the backend; skip and keep never start a restore'
    # 미리보기 뒤에 대상 홈이 바뀌면 받지 않는다.
    $job.choice='incoming'; $otherHome=Join-Path $testDirectory 'other-home'; $null=New-Item -ItemType Directory -Path $otherHome
    $job.home=$otherHome; Throws {Invoke-JobCore $job} '선택'; $job.home=$desktopRoot
    # 벤더 구현의 receipt는 그 구현의 staging 안 inspect.json만 받는다.
    $job.receipt=Join-Path $testDirectory 'inspect.json'; Throws {Invoke-JobCore $job} '미리보기'; $job.receipt=$preview.receipt
    Assert ($script:Calls.Count -eq $before) 'a changed home or a foreign receipt never reaches the backend'
    $job.choice='incoming'
    $job.token='another-token'; Throws {Invoke-JobCore $job} '토큰'
    $job.token='exact-token-A'; $oldId=$job.remoteId; $job.remoteId=$script:BundleB; Throws {Invoke-JobCore $job} '선택'
    $job.remoteId=$oldId
    $record=Get-Content -LiteralPath $preview.receipt -Raw -Encoding UTF8 | ConvertFrom-Json
    $original=[IO.File]::ReadAllBytes($record.archive)
    [IO.File]::AppendAllText($record.archive,'tamper')
    Throws {Invoke-JobCore $job} '바뀌었습니다'
    [IO.File]::WriteAllBytes($record.archive,$original)
    $null=Invoke-JobCore $job
    $apply=$script:Calls[-1].arguments
    Assert ($apply[0] -eq 'apply' -and $apply[[array]::IndexOf($apply,'--token')+1] -ceq 'exact-token-A') 'apply must pass exact inspect token'
    Assert ($apply[[array]::IndexOf($apply,'--run')+1] -cmatch '^[0-9a-f]{32}$') 'apply names its recovery record after the operation ID from Worker'
    foreach ($bad in @('../x',('A'*32),('a'*31),$null,32)) { Throws {Assert-OperationId $bad} '작업 ID' }
    # 엔진 사전 검사(guard): 프로젝트 파일을 먼저 쓰기 전에 부른다. 열린 엔진은 busy, 검사 자체를 못 하면 failed다.
    $guardJob=[pscustomobject]@{agent='codex-desktop';home=$desktopRoot}
    $script:GuardOpen=$false
    $g=Invoke-Vendor $guardJob 'guard' @{}
    Assert ($g.status -ceq 'ok') 'Codex guard is ok when no engine or IDE is open'
    Assert ($script:Calls[-1].arguments[0] -ceq 'guard' -and $script:Calls[-1].arguments[[array]::IndexOf($script:Calls[-1].arguments,'--home')+1] -ceq $desktopRoot) 'Codex guard asks the backend for the target home'
    $script:GuardOpen=$true
    $failure=$null; try { $null=Invoke-Vendor $guardJob 'guard' @{} } catch { $failure=$_ }
    Assert ($failure.Exception.Data['vendorResult'].status -ceq 'busy' -and $failure.Exception.Data['vendorResult'].reasonCode -ceq 'engine_open') 'an open Codex engine makes guard busy'
    $script:GuardOpen=$false
    $realClosed=${function:Assert-AgentClosed}
    try {
        ${function:Assert-AgentClosed}={ param($Agent) if ($script:ClaudeOpen) { throw 'Claude Code를 종료하세요.' } }
        $claudeGuard=[pscustomobject]@{agent='claude-code'}
        $script:ClaudeOpen=$false; Assert ((Invoke-Vendor $claudeGuard 'guard' @{}).status -ceq 'ok') 'Claude guard is ok when Claude Code is closed'
        $script:ClaudeOpen=$true
        $failure=$null; try { $null=Invoke-Vendor $claudeGuard 'guard' @{} } catch { $failure=$_ }
        Assert ($failure.Exception.Data['vendorResult'].status -ceq 'busy') 'an open Claude Code makes guard busy'
    } finally { ${function:Assert-AgentClosed}=$realClosed }
    # Codex 복구 기록(S3 명세 2.3·4.2절): 작업 ID 이름의 run 폴더를 직접 읽는다. 되돌리기는 백엔드 recover, 닫기는 journal 이름 바꾸기.
    $recoveryRoot=Join-Path $desktopRoot '.ctxhop-desktop-recovery'
    function Write-RunJournal([string]$Op,[string]$Text,[string]$Name='journal.json') {
        $null=New-Item -ItemType Directory -Path (Join-Path $recoveryRoot $Op) -Force
        [IO.File]::WriteAllText((Join-Path $recoveryRoot "$Op\$Name"),$Text,[Text.UTF8Encoding]::new($false))
    }
    function Get-RunJson([string]$Status,[string]$HomeValue=$desktopRoot) { return (ConvertTo-Json -InputObject ([ordered]@{version=2;status=$Status;home=$HomeValue;id=$script:Id}) -Compress) }
    $recoverJob=[pscustomobject]@{agent='codex-desktop';home=$desktopRoot}
    function Get-CodexState([string]$Op) { return (Invoke-Vendor $recoverJob 'recover' @{mode='status';operationId=$Op}).state }
    $ops=@{}; foreach ($name in 'absent','empty','pending','complete','rolled','resolved','both','broken','foreign') { $ops[$name]=[guid]::NewGuid().ToString('N') }
    $null=New-Item -ItemType Directory -Path (Join-Path $recoveryRoot $ops.empty) -Force
    Write-RunJournal $ops.pending (Get-RunJson 'pending'); Write-RunJournal $ops.complete (Get-RunJson 'complete'); Write-RunJournal $ops.rolled (Get-RunJson 'rolled_back')
    Write-RunJournal $ops.resolved (Get-RunJson 'pending') 'journal.resolved.json'
    Write-RunJournal $ops.both (Get-RunJson 'pending'); Write-RunJournal $ops.both (Get-RunJson 'pending') 'journal.resolved.json'
    Write-RunJournal $ops.broken '{not json'; Write-RunJournal $ops.foreign (Get-RunJson 'pending' 'D:\other-home')
    $null=New-Item -ItemType Directory -Path (Join-Path $recoveryRoot 'not-a-record') -Force
    $expected=@{absent='absent';empty='absent';pending='pending';complete='complete';rolled='rolled_back';resolved='resolved';both='unreadable';broken='unreadable';foreign='unreadable'}
    foreach ($name in $expected.Keys) { Assert ((Get-CodexState $ops[$name]) -ceq $expected[$name]) "Codex record $name is $($expected[$name])" }
    $failure=$null; try { $null=Invoke-Vendor $recoverJob 'recover' @{mode='status';operationId='../x'} } catch { $failure=$_ }
    Assert ($failure.Exception.Data['vendorResult'].status -ceq 'failed') 'a record name that is not an operation ID is refused'
    $listed=@((Invoke-Vendor $recoverJob 'recover' @{mode='list'}).records)
    Assert ((@($listed | ForEach-Object recordId | Sort-Object) -join ',') -eq (@($ops.pending,$ops.both,$ops.broken,$ops.foreign | Sort-Object) -join ',')) 'list shows pending and unreadable records only'
    $pendingRow=@($listed | Where-Object recordId -eq $ops.pending)[0]
    Assert ($pendingRow.canRollback -and $pendingRow.nativeId -eq $script:Id -and $pendingRow.sha256 -eq (Get-FileHash -LiteralPath (Join-Path $recoveryRoot "$($ops.pending)\journal.json") -Algorithm SHA256).Hash) 'a pending row can be rolled back and carries its record hash'
    Assert (-not @($listed | Where-Object { $_.recordId -ne $ops.pending -and $_.canRollback }).Count) 'unreadable rows cannot be rolled back'
    # 되돌리기: pending만 백엔드 recover로 되돌린다. 백엔드가 멈추면 기록은 그대로다.
    $script:RecoverStatus='busy'
    $failure=$null; try { $null=Invoke-Vendor $recoverJob 'recover' @{mode='rollback';recordId=$ops.pending} } catch { $failure=$_ }
    Assert ($failure.Exception.Data['vendorResult'].reasonCode -ceq 'busy' -and (Get-CodexState $ops.pending) -ceq 'pending') 'an open engine stops the rollback and keeps the record'
    $script:RecoverStatus='blocked'
    $failure=$null; try { $null=Invoke-Vendor $recoverJob 'recover' @{mode='rollback';recordId=$ops.pending} } catch { $failure=$_ }
    Assert ($failure.Exception.Data['vendorResult'].reasonCode -ceq 'needs_attention' -and @($failure.Exception.Data['vendorResult'].records).Count -eq 1) 'a changed conversation needs attention and the record is returned'
    $script:RecoverStatus=$null
    $rolled=Invoke-Vendor $recoverJob 'recover' @{mode='rollback';recordId=$ops.pending}
    $call=$script:Calls[-1].arguments
    Assert ($rolled.effect -ceq 'rolled_back' -and $call[0] -ceq 'recover' -and $call[[array]::IndexOf($call,'--run')+1] -ceq (Join-Path $recoveryRoot $ops.pending)) 'rollback runs the backend recover on that record'
    Assert ((Invoke-Vendor $recoverJob 'recover' @{mode='rollback';recordId=$ops.pending}).effect -ceq 'rolled_back') 'a rolled back record stays rolled back'
    $failure=$null; try { $null=Invoke-Vendor $recoverJob 'recover' @{mode='rollback';recordId=$ops.complete} } catch { $failure=$_ }
    Assert ($failure.Exception.Data['vendorResult'].reasonCode -ceq 'unsupported_record') 'a complete record is never rolled back'
    # 닫기: 창에서 본 해시와 같을 때만 이름을 바꾼다.
    $brokenHash=(Get-FileHash -LiteralPath (Join-Path $recoveryRoot "$($ops.broken)\journal.json") -Algorithm SHA256).Hash
    $failure=$null; try { $null=Invoke-Vendor $recoverJob 'recover' @{mode='resolve';recordId=$ops.broken;sha256=('0'*64)} } catch { $failure=$_ }
    Assert ($failure.Exception.Data['vendorResult'].reasonCode -ceq 'changed' -and (Get-CodexState $ops.broken) -ceq 'unreadable') 'a record that differs from what was shown is not closed'
    Assert ((Invoke-Vendor $recoverJob 'recover' @{mode='resolve';recordId=$ops.broken;sha256=$brokenHash}).effect -ceq 'resolved' -and (Get-CodexState $ops.broken) -ceq 'resolved') 'an unreadable record is closed when the user saw its content'
    Assert ((Invoke-Vendor $recoverJob 'recover' @{mode='resolve';recordId=$ops.broken;sha256=$brokenHash}).effect -ceq 'resolved') 'closing again succeeds'
    $failure=$null; try { $null=Invoke-Vendor $recoverJob 'recover' @{mode='resolve';recordId=$ops.both;sha256=$brokenHash} } catch { $failure=$_ }
    Assert ($failure.Exception.Data['vendorResult'].status -ceq 'failed' -and [IO.File]::Exists((Join-Path $recoveryRoot "$($ops.both)\journal.json"))) 'a record whose closed name already exists is not overwritten'
    Remove-Item -LiteralPath $recoveryRoot -Recurse
    Assert (-not (Test-Path -LiteralPath $previewStage)) 'successful restore removes its plaintext staging copy'
    $odd=Join-Path $staging 'not-a-stage'; $null=New-Item -ItemType Directory -Path $odd
    Assert ((Remove-DesktopStage $odd) -match '지우지 못했습니다' -and (Test-Path -LiteralPath $odd)) 'cleanup refuses folders it did not create'
    $extra=New-DesktopStage; [IO.File]::WriteAllText((Join-Path $extra 'user-note.txt'),'keep')
    Assert ((Remove-DesktopStage $extra) -match '지우지 못했습니다' -and (Test-Path -LiteralPath (Join-Path $extra 'user-note.txt'))) 'cleanup never deletes unknown files'
    Assert ((Remove-DesktopStage $staging) -match '지우지 못했습니다' -and (Test-Path -LiteralPath $staging)) 'cleanup never removes the staging root'
    $outside=Join-Path $testDirectory 'outside'; $null=New-Item -ItemType Directory -Path $outside
    [IO.File]::WriteAllText((Join-Path $outside 'session.archive'),'not ours')
    $link=Join-Path $staging ('c'*32); $null=New-Item -ItemType Junction -Path $link -Value $outside
    Assert ((Remove-DesktopStage $link) -match '지우지 못했습니다' -and (Test-Path -LiteralPath (Join-Path $outside 'session.archive'))) 'cleanup never follows a linked staging folder'
    [IO.Directory]::Delete($link)
    foreach ($state in @('new','incoming_newer','local_newer','equal','conflict','blocked')) {
        $script:State=$state; $job.action='Preview'; $r=Invoke-JobCore $job
        Assert ($r.preview.status -eq $state) "status $state must survive without timestamp decisions"
        Assert ($script:Calls[-1].arguments[0] -eq 'inspect') 'preview must never auto apply'
        if ($state -eq 'blocked') {
            $job.action='Restore'; $job.receipt=$r.receipt; $job.token=$r.preview.token; $job.choice='incoming'
            Throws {Invoke-JobCore $job} '호환 불가'
        }
    }
    $script:State='conflict'; $job.action='Preview'; $r=Invoke-JobCore $job
    $job.action='Restore'; $job.receipt=$r.receipt; $job.token=$r.preview.token; $job.choice='incoming'; $script:ApplyFail=$true
    $failure=$null; try {Invoke-JobCore $job} catch {$failure=$_}
    Assert ((@($failure.Exception.Data['backendResult'].pending) -join '|') -eq 'fixture/.ctxhop-desktop-recovery/run' -and $failure.Exception.Data['vendorResult'].recovery -eq 'required') 'failure must preserve backend recovery journal data and say recovery is required'
    Assert (Test-Path -LiteralPath $r.receipt) 'failed restore must retain inspect and archive evidence'
    # 안정판 ctxhop-gui\Worker.ps1(최종 감사 D08E9A15…)에서 문장만 Strings.ps1로 옮긴 판에, ctxhop 0.2.0-gui.3 고정과
    # Claude 세션 옆 폴더(하위 에이전트·도구 결과) 복원 확인, ctxhop 출력 UTF-8 읽기, 저장소 옮기기를 더한 판과 바이트 동일해야 한다.
    Assert ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'ClaudeWorker.ps1') -Algorithm SHA256).Hash -eq '4E601995783B6890901D09C5A0CF4F2B4D71D9618A2D9939310EB8D0379D0CB7') 'Claude worker copy must match the reviewed version'
    Throws {Assert-FrozenFile (Join-Path $testDirectory 'nonexistent.py') ''} '준비되지'
    Throws {Assert-BundleId '../aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'} '잘못된'
    Throws {Assert-BundleId 'peer-a/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'} '잘못된'
    # 프로젝트 폴더 백업·복원: 파일로 만든 가짜 bundle 저장소에 Codex Desktop과 Claude Code 대화를 올리고 받는다.
    $oldTmp=$env:TMP; $oldTemp=$env:TEMP; $oldCeiling=$env:GIT_CEILING_DIRECTORIES
    try {
        # 시험 폴더가 임시 폴더 안이라 추가 작업 폴더가 임시 폴더로 빠지지 않게 하고, git이 위쪽 저장소를 찾지 않게 한다.
        $env:TMP=Join-Path $testDirectory 'fake-temp'; $env:TEMP=$env:TMP; $env:GIT_CEILING_DIRECTORIES=$testDirectory
        $storeDir=Join-Path $testDirectory 'bundle-store'; $null=New-Item -ItemType Directory -Path $storeDir
        # 앞 시험이 일부러 남긴 staging 폴더는 그대로 두고, 이 시험이 새로 남긴 것이 없는지만 본다.
        $stagingBefore=(@(Get-ChildItem -LiteralPath $staging -Force | ForEach-Object Name | Sort-Object)) -join '|'
        function Test-StagingClean { return ((@(Get-ChildItem -LiteralPath $staging -Force | ForEach-Object Name | Sort-Object)) -join '|') -eq $stagingBefore }
        $script:Store=[ordered]@{}; $script:PutCount=0; $script:ApplyStatus='imported'
        function Invoke-Bundle([string[]]$Arguments) {
            $script:Calls+=,[pscustomobject]@{kind='bundle';arguments=$Arguments}
            switch ($Arguments[0]) {
                list { return @{bundles=@($script:Store.Values | ForEach-Object { @{id=$_.id;metadata=$_.metadata} })} }
                put {
                    $source=$Arguments[[array]::IndexOf($Arguments,'--input')+1]; $metaFile=$Arguments[[array]::IndexOf($Arguments,'--metadata')+1]
                    Assert (Get-Acl -LiteralPath (Split-Path -Parent $source)).AreAccessRulesProtected 'project staging must disable ACL inheritance'
                    $bytes=[IO.File]::ReadAllBytes($metaFile)
                    Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239)) 'project metadata must use UTF8 without BOM'
                    $m=Get-Content -LiteralPath $metaFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    Assert (($m.PSObject.Properties.Name | Sort-Object) -join ',' -eq 'cliVersion,historyMode,recordCount,sessionId,sourceCwd,title,updatedAt' -and $m.historyMode.Length -le 128) 'project metadata keeps the seven transport keys'
                    Assert-BundleMetadata $m
                    $script:PutCount++; $id='peer-a/'+('{0:x32}' -f $script:PutCount); $copy=Join-Path $storeDir "$($script:PutCount).bin"
                    Copy-Item -LiteralPath $source -Destination $copy
                    $script:Store[$id]=[pscustomobject]@{id=$id;metadata=$m;file=$copy}
                    return @{id=$id}
                }
                get {
                    $id=$Arguments[[array]::IndexOf($Arguments,'--id')+1]; $file=$Arguments[[array]::IndexOf($Arguments,'--output')+1]
                    Assert (-not (Test-Path -LiteralPath $file)) 'download must use new file'
                    Copy-Item -LiteralPath $script:Store[$id].file -Destination $file
                    return @{id=$id;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $file).Length}
                }
            }
        }
        function Invoke-DesktopBackend([string[]]$Arguments) {
            $script:Calls+=,[pscustomobject]@{kind='backend';arguments=$Arguments}
            switch ($Arguments[0]) {
                list { return [pscustomobject]@{total=0;sessions=@()} }
                export {
                    [IO.File]::WriteAllText($Arguments[[array]::IndexOf($Arguments,'--output')+1],'synthetic archive',[Text.UTF8Encoding]::new($false))
                    return @{metadata=$script:ProjectMeta;folders=@{cwds=$script:Cwds;edits=$script:Edits}}
                }
                inspect { return [pscustomobject]@{status='incoming_newer';reason='fixture';token='project-token';source=@{sessionId=$script:Id};target=@{sessionId=$script:Id}} }
                apply { return @{status=$script:ApplyStatus} }
            }
        }
        function Get-Stored([string]$Mode) { @($script:Store.Values | Where-Object { $_.metadata.historyMode -like $Mode }) }
        function Get-ZipNames([string]$File) { $zip=[IO.Compression.ZipFile]::OpenRead($File); try { @($zip.Entries | ForEach-Object FullName | Sort-Object) } finally { $zip.Dispose() } }
        $projects=Join-Path $testDirectory 'projects'; $projA=Join-Path $projects '앱'; $projB=Join-Path $projects 'lib'; $gone=Join-Path $projects 'gone'
        foreach ($pair in @(@("$projA\src\app.py",'v1'),@("$projA\README.md",'# 앱'),@("$projA\.env",'SECRET=1'),@("$projA\node_modules\x.js",'x'),@("$projB\lib.py",'lib v1'),@("$projA\AB~1.txt",'short'))) {
            $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $pair[0])); [IO.File]::WriteAllText($pair[0],$pair[1])
        }
        $outsideEdit=Join-Path $testDirectory 'elsewhere\notes.md'
        $script:ProjectMeta=[pscustomobject]@{sessionId=$script:Id;title='프로젝트 대화';sourceCwd=$projA;updatedAt='2026-09-27T01:00:00Z';historyMode='paginated;family=0';cliVersion='0.116.0';recordCount=4}
        $script:Cwds=@($projA,"\\?\$projA\src",$projB,$gone); $script:Edits=@("$projA\src\app.py",$outsideEdit)
        $codex=@{action='Backup';agent='codex-desktop';home=$desktopRoot;projectPath=$target;nativeId=$script:Id;remoteId='';projectBackup=$true}

        # 백업: 대화, 작업 폴더 2개, 연결 기록이 올라가고 비밀 파일·생성 폴더는 빠진다. 없는 폴더와 폴더 밖 편집은 기록만 남는다.
        $first=Invoke-JobCore $codex
        Assert ($first.project.folders.Count -eq 3 -and ((@($first.project.folders | ForEach-Object { "$($_.role):$($_.status):$($_.reason)" })) -join '|') -eq 'start:uploaded:|extra:uploaded:|extra:skipped:missing') "project backup folders: $($first.project.folders | ConvertTo-Json -Compress)"
        Assert (($first.project.outside -join '|') -eq $outsideEdit -and $first.message -match '프로젝트 폴더 3개' -and $first.message -match '폴더 밖에서 고친 파일 1개' -and $first.message -match '복원할 수 없는 이름\(짧은 이름 형식 GIT~1, 장치 이름 CON 등\)의 파일 1개') "project backup message: $($first.message)"
        Assert (@(Get-Stored 'project-files;*').Count -eq 2 -and @(Get-Stored 'project-link;*').Count -eq 1 -and @(Get-Stored 'paginated*').Count -eq 1) "conversation, two folders and one link are stored: $(@($script:Store.Values | ForEach-Object { $_.metadata.historyMode }) -join ' / ')"
        $firstLink=@(Get-Stored 'project-link;*')[0]
        Assert ($firstLink.metadata.historyMode -eq 'project-link;v1;codex-desktop' -and $firstLink.metadata.title -ceq $first.remoteId -and $firstLink.metadata.sessionId -eq $script:Id -and $firstLink.metadata.sourceCwd -eq $projA) 'the link names the conversation bundle and start folder'
        $zipA=@(Get-Stored 'project-files;*' | Where-Object { $_.metadata.sourceCwd -eq $projA }).file
        Assert (((Get-ZipNames $zipA) -join '|') -eq 'files/README.md|files/src/app.py|manifest.json') "stored snapshot leaves out secrets and generated folders: $((Get-ZipNames $zipA) -join '|')"
        Assert (Test-StagingClean) 'project backup leaves no plaintext staging copy'

        # 같은 내용이면 올리지 않고 연결만 한다. 바뀐 폴더만 새로 올린다.
        $second=Invoke-JobCore $codex
        Assert ((@($second.project.folders | ForEach-Object status) -join '|') -eq 'reused|reused|skipped' -and @(Get-Stored 'project-files;*').Count -eq 2 -and @(Get-Stored 'project-link;*').Count -eq 2) 'unchanged folders are linked, not uploaded'
        [IO.File]::WriteAllText("$projA\src\app.py",'v2')
        $third=Invoke-JobCore $codex
        Assert ((@($third.project.folders | ForEach-Object status) -join '|') -eq 'uploaded|reused|skipped' -and @(Get-Stored 'project-files;*').Count -eq 3) 'only the changed folder is uploaded again'

        # 큰 폴더: 허락받기 전에는 아무것도 올리지 않고, 모든 큰 폴더를 허락해 다시 실행하면 대화와 함께 올린다.
        $script:ProjectAskBytes=1; $count=$script:Store.Count; $puts=@($script:Calls | Where-Object { $_.kind -eq 'bundle' -and $_.arguments[0] -eq 'put' }).Count
        $ask=Invoke-JobCore $codex
        Assert ($ask.needsProjectConfirm -and (@($ask.folders | ForEach-Object path) -join '|') -eq "$projA|$projB" -and $ask.message -match '200MB') 'large folders are asked about first'
        Assert ($script:Store.Count -eq $count -and @($script:Calls | Where-Object { $_.kind -eq 'bundle' -and $_.arguments[0] -eq 'put' }).Count -eq $puts -and (Test-StagingClean)) 'nothing is uploaded or left in staging before the answer'
        $codex.projectApproved=@($projA)
        $partial=Invoke-JobCore $codex
        Assert ($partial.needsProjectConfirm -and (@($partial.folders | ForEach-Object path) -join '|') -eq $projB -and $script:Store.Count -eq $count -and (Test-StagingClean)) 'a large folder that was not approved is asked about again and nothing is uploaded'
        $codex.projectApproved=@($projA,$projB)
        $answered=Invoke-JobCore $codex
        Assert (-not $answered.needsProjectConfirm -and (@($answered.project.folders | ForEach-Object { "$($_.status):$($_.reason)" }) -join '|') -eq 'reused:|reused:|skipped:missing' -and $script:Store.Count -eq $count+2) 'approved folders are backed up with the conversation'
        $script:ProjectAskBytes=200MB; $codex.Remove('projectApproved')
        # 1GiB를 넘는 압축 파일은 올리지 않고 이유를 남긴다(한도를 낮춰 확인).
        $script:ProjectMaxArchiveBytes=10; [IO.File]::WriteAllText("$projA\src\app.py",'v3')
        $large=Invoke-JobCore $codex
        Assert ($large.project.folders[0].status -eq 'skipped' -and $large.project.folders[0].reason -eq 'tooLarge' -and $large.project.folders[1].status -eq 'reused') 'an archive over the limit is skipped with a reason'
        $script:ProjectMaxArchiveBytes=1GB; [IO.File]::WriteAllText("$projA\src\app.py",'v2')
        # 받는 쪽이 풀지 않는 크기(압축 전 16GiB 초과)도 먼저 대화째 보류해 묻고, 고른 뒤에 그 폴더만 뺀다(한도를 낮춰 확인: 앱 7바이트, lib 6바이트).
        $script:ProjectMaxBytes=6; $script:ProjectAskBytes=1; $count=$script:Store.Count
        try {
            $held=Invoke-JobCore $codex
            Assert ($held.needsProjectConfirm -and (@($held.folders | ForEach-Object path) -join '|') -eq "$projA|$projB" -and $script:Store.Count -eq $count -and (Test-StagingClean)) 'a folder over the receive limit is still held for the user first, and nothing is uploaded'
            $codex.projectApproved=@($projA,$projB)
            $huge=Invoke-JobCore $codex
        } finally { $script:ProjectMaxBytes=16GB; $script:ProjectAskBytes=200MB; $codex.Remove('projectApproved') }
        Assert (-not $huge.needsProjectConfirm -and $huge.project.folders[0].status -eq 'skipped' -and $huge.project.folders[0].reason -eq 'tooLarge' -and $huge.project.folders[1].status -eq 'reused') "a folder the receiver would refuse to unpack is not uploaded: $($huge.project.folders | ConvertTo-Json -Compress)"
        $codex.projectBackup=$false; $count=$script:Store.Count
        $plain=Invoke-JobCore $codex
        Assert ($null -eq $plain.project -and $script:Store.Count -eq $count+1) 'with the option off only the conversation is uploaded'
        $codex.projectBackup=$true
        # 폴더를 고르다 실패해도 대화 백업은 그대로 올라가고 이유만 붙는다.
        $realFolders=${function:Get-ProjectFolders}; $count=$script:Store.Count
        function Get-ProjectFolders { throw '합성 폴더 실패' }
        try { $failedPlan=Invoke-JobCore $codex } finally { ${function:Get-ProjectFolders}=$realFolders }
        Assert ($failedPlan.remoteId -and $null -eq $failedPlan.project -and $failedPlan.message -match '프로젝트 파일은 백업하지 못했습니다' -and $failedPlan.message -match '합성 폴더 실패' -and $script:Store.Count -eq $count+1) "a failure while picking folders never blocks the Codex conversation backup: $($failedPlan.message)"

        # 목록에는 프로젝트 파일과 연결 기록이 대화로 보이지 않는다.
        $listed=Invoke-JobCore @{action='List';agent='codex-desktop';home=$desktopRoot;search=''}
        Assert ($listed.sessions.Count -eq @(Get-Stored 'paginated*').Count -and -not @($listed.sessions | Where-Object { $_.historyMode -like 'project-*' }).Count) 'project bundles are hidden from the conversation list'

        # 미리보기와 복원: 첫 백업 때의 상태(v1)를 복원 폴더에 쓰고, 바뀌는 파일의 원본은 남기며, 이 PC에만 있는 파일은 둔다.
        $restoreTarget=Join-Path $testDirectory 'restore-target'
        foreach ($pair in @(@("$restoreTarget\src\app.py",'local edit'),@("$restoreTarget\local.txt",'keep'))) { $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $pair[0])); [IO.File]::WriteAllText($pair[0],$pair[1]) }
        Rename-Item -LiteralPath $projB -NewName 'lib-moved'; $picked=Join-Path $testDirectory 'picked-lib'
        $restore=@{action='Preview';agent='codex-desktop';home=$desktopRoot;projectPath=$restoreTarget;nativeId=$script:Id;remoteId=$first.remoteId;projectRestore=$true}
        $storedB=@(Get-Stored 'project-files;*' | Where-Object { $_.metadata.sourceCwd -eq $projB })[0].file; $bytesB=[IO.File]::ReadAllBytes($storedB)
        [IO.File]::WriteAllText($storedB,'not a zip')
        try { $iso=Invoke-JobCore $restore } finally { [IO.File]::WriteAllBytes($storedB,$bytesB) }
        Assert ($iso.preview.token -and @($iso.project.folders).Count -eq 3 -and $iso.project.folders[0].state -eq 'ready' -and $iso.project.folders[1].state -eq 'error' -and $iso.project.folders[1].reason -and $iso.project.folders[1].target -eq '' -and $iso.project.folders[2].state -eq 'skipped') "one unreadable folder does not stop the others: $($iso.project | ConvertTo-Json -Depth 3 -Compress)"
        $null=Remove-DesktopStage (Split-Path -Parent $iso.receipt); $null=Remove-DesktopStage (Split-Path -Parent $iso.project.receipt)
        $shown=Invoke-JobCore $restore
        $p=$shown.project
        Assert ($p.state -eq 'found' -and $p.folders.Count -eq 3 -and (($p.outside) -join '|') -eq $outsideEdit) "project preview found: $($p | ConvertTo-Json -Depth 4 -Compress)"
        Assert ($p.folders[0].state -eq 'ready' -and $p.folders[0].target -eq $restoreTarget -and $p.folders[0].compare.new -eq 1 -and $p.folders[0].compare.changed -eq 1 -and $p.folders[0].compare.localOnly -eq 1) 'start folder compares with the chosen restore folder'
        Assert ($p.folders[1].state -eq 'needsFolder' -and $p.folders[1].target -eq '' -and $p.folders[2].state -eq 'skipped') 'an extra folder missing on this PC needs a choice'
        $restore.action='Restore'; $restore.receipt=$shown.receipt; $restore.token=$shown.preview.token; $restore.choice='incoming'; $restore.projectTargets=@{'1'=$picked}; $restore.projectReceipt=$shown.project.receipt
        $restoreJob=$restore | ConvertTo-Json -Depth 5 | ConvertFrom-Json   # GUI처럼 JSON을 거친 요청
        $done=Invoke-JobCore $restoreJob
        Assert ($done.project.folders.Count -eq 2 -and $done.message -match '프로젝트 폴더 2개 복원') "project restore message: $($done.message)"
        Assert ([IO.File]::ReadAllText("$restoreTarget\src\app.py") -eq 'v1' -and [IO.File]::ReadAllText("$restoreTarget\README.md") -eq '# 앱' -and [IO.File]::ReadAllText("$restoreTarget\local.txt") -eq 'keep') 'the state of that backup is restored and local-only files stay'
        Assert ([IO.File]::ReadAllText("$picked\lib.py") -eq 'lib v1' -and -not (Test-Path -LiteralPath "$restoreTarget\.env")) 'the extra folder goes to the chosen folder'
        $recovery=$done.project.recovery
        Assert ($recovery -and [IO.File]::ReadAllText("$recovery\0\src\app.py") -eq 'local edit' -and (Test-Path -LiteralPath "$recovery\restore-log.json") -and (Get-Acl -LiteralPath $recovery).AreAccessRulesProtected) 'replaced originals are kept in a private recovery folder'
        Assert (-not (Test-Path -LiteralPath (Split-Path -Parent $shown.receipt)) -and -not (Test-Path -LiteralPath (Split-Path -Parent $shown.project.receipt))) 'the conversation and project preview staging copies are removed after restore'
        # 이 PC 대화가 더 새로우면 파일도 그대로 둔다. 선택을 끄면 복원하지 않는다. 미리보기 뒤 바뀐 파일은 쓰지 않는다.
        foreach ($case in @(@{status='local_newer';restore=$true},@{status='imported';restore=$false},@{status='imported';restore=$true;tamper=$true})) {
            [IO.File]::WriteAllText("$restoreTarget\src\app.py",'local again'); $script:ApplyStatus=$case.status
            $restore.action='Preview'; $restore.projectRestore=$true; $shown=Invoke-JobCore $restore
            $restore.action='Restore'; $restore.receipt=$shown.receipt; $restore.token=$shown.preview.token; $restore.projectRestore=$case.restore; $restore.projectReceipt=$shown.project.receipt
            if ($case.tamper) { [IO.File]::AppendAllText($shown.project.folders[0].zip,'x') }
            $done=Invoke-JobCore ($restore | ConvertTo-Json -Depth 5 | ConvertFrom-Json)   # GUI처럼 JSON을 거쳐 고른 폴더(projectTargets)도 쓴다
            Assert ([IO.File]::ReadAllText("$restoreTarget\src\app.py") -eq 'local again' -and -not (Test-Path -LiteralPath (Split-Path -Parent $shown.project.receipt))) "project files stay and the project preview copy is removed for $($case | ConvertTo-Json -Compress)"
            if ($case.tamper) { Assert ($done.message -match '폴더는 복원하지 못했습니다' -and $done.restored.status -eq 'imported' -and $done.effect -eq 'restored' -and (@($done.project.folders | ForEach-Object state) -join '|') -eq 'failed|restored' -and (Test-Path -LiteralPath "$($done.project.recovery)\restore-log.json")) "a changed download fails only that folder; the others are restored and logged: $($done.message)" }
        }
        $script:ApplyStatus='imported'; $restore.projectRestore=$true; $restore.Remove('projectReceipt')
        # 미리보기를 꺼 두면 프로젝트 파일을 받지 않는다.
        $restore.action='Preview'; $restore.projectRestore=$false; $gets=@($script:Calls | Where-Object { $_.kind -eq 'bundle' -and $_.arguments[0] -eq 'get' }).Count
        $off=Invoke-JobCore $restore
        Assert ($off.project.state -eq 'off' -and @($script:Calls | Where-Object { $_.kind -eq 'bundle' -and $_.arguments[0] -eq 'get' }).Count -eq $gets+1) 'with restore off only the conversation is downloaded'
        $null=Remove-DesktopStage (Split-Path -Parent $off.receipt)
        Throws { Read-ProjectReceipt (Join-Path $testDirectory 'project-receipt.json') 'codex-desktop' $script:Id $first.remoteId } '미리보기 기록'

        # Claude Code: 대화 작업은 ClaudeWorker(여기서는 가짜)가 하고, 프로젝트 파일은 같은 저장소에 붙는다.
        Rename-Item -LiteralPath (Join-Path $projects 'lib-moved') -NewName 'lib'
        $claudeId='22222222-2222-4222-8222-222222222222'; $claudeRemote='0123456789abcdefghjkmnpqrs'
        $claudeHome=Join-Path $testDirectory 'claude-projects\D--proj'; $null=New-Item -ItemType Directory -Path "$claudeHome\$claudeId\subagents" -Force
        $script:ClaudeSession=Join-Path $claudeHome "$claudeId.jsonl"
        [IO.File]::WriteAllLines($script:ClaudeSession,[string[]]@(('{"type":"user","cwd":' + (ConvertTo-Json $projA) + ',"sessionId":"' + $claudeId + '"}'),('{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":' + (ConvertTo-Json $outsideEdit) + '}}]}}')),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllLines("$claudeHome\$claudeId\subagents\agent-1.jsonl",[string[]]@('{"cwd":' + (ConvertTo-Json $projB) + '}'),[Text.UTF8Encoding]::new($false))
        function Get-NativeFiles([string]$Agent,[string]$Id) { if ($Id -eq $claudeId) { Get-Item -LiteralPath $script:ClaudeSession } }
        $script:ClaudeCalls=@()
        $script:ClaudeJobCore={ param($Job) $script:ClaudeCalls+=$Job.action; switch ($Job.action) { Backup {@{message='대화 백업 완료.'}} Preview {@{message='미리보기 완료.';preview=@{session=$Job.nativeId}}} Restore {@{message='복원 완료.';restored=@{session=$Job.nativeId}}} } }
        $claude=@{action='Backup';agent='claude-code';projectPath=$projA;nativeId=$claudeId;remoteId=$claudeRemote;projectBackup=$true}
        # 받는 쪽 한도(압축 전 16GiB)를 넘는 폴더도 올리기 전에 묻는다(한도를 낮춰 확인).
        $script:ProjectAskBytes=1; $script:ProjectMaxBytes=6
        try { $ask=Invoke-JobCore $claude } finally { $script:ProjectMaxBytes=16GB }
        Assert ($ask.needsProjectConfirm -and (@($ask.folders | ForEach-Object path) -join '|') -eq "$projA|$projB" -and -not $script:ClaudeCalls.Count) 'Claude backup asks before the conversation is pushed, even for a folder over the receive limit'
        $script:ProjectAskBytes=200MB
        $cb=Invoke-JobCore $claude
        Assert (($script:ClaudeCalls -join ',') -eq 'Backup' -and $cb.message -match '^대화 백업 완료\. 프로젝트 폴더 2개' -and (@($cb.project.folders | ForEach-Object { "$($_.role):$($_.sourcePath)" }) -join '|') -eq "start:$projA|extra:$projB") "Claude backup covers the subagent folder: $($cb.message)"
        Assert ((@($cb.project.folders | ForEach-Object status) -join '|') -eq 'reused|reused' -and $cb.project.outside.Count -eq 1) 'identical folders already backed up for Codex are reused'
        $claudeLink=@(Get-Stored 'project-link;v1;claude-code')
        Assert ($claudeLink.Count -eq 1 -and $claudeLink[0].metadata.title -ceq $claudeRemote -and $claudeLink[0].metadata.sessionId -eq $claudeId) 'the Claude link names the remote ID'
        $realRead=${function:Read-ClaudeWorkData}
        function Read-ClaudeWorkData([string[]]$Files) { throw '합성 읽기 실패' }
        try { $failedRead=Invoke-JobCore $claude } finally { ${function:Read-ClaudeWorkData}=$realRead }
        Assert ($failedRead.message -match '^대화 백업 완료\. 프로젝트 파일은 백업하지 못했습니다' -and $failedRead.message -match '합성 읽기 실패' -and $script:ClaudeCalls[-1] -eq 'Backup') "a failure while picking folders never blocks the Claude conversation backup: $($failedRead.message)"
        # describe 뒤에 작업 폴더가 바뀌면 아무것도 올리지 않는다(Claude: 대화도 올리지 않는다).
        $realRead=${function:Read-ClaudeWorkData}; $script:Reads=0; $pushes=@($script:ClaudeCalls).Count; $count=$script:Store.Count
        function Read-ClaudeWorkData([string[]]$Files) { $script:Reads++; $work=& $realRead $Files; if ($script:Reads -eq 2) { $work.cwds=@($work.cwds)+'D:\new-folder' }; $work }
        try { $changed=$null; try { Invoke-JobCore $claude } catch { $changed=$_ } } finally { ${function:Read-ClaudeWorkData}=$realRead }
        Assert ($changed.Exception.Data['vendorResult'].status -eq 'changed' -and $changed.Exception.Message -match '작업 폴더가 바뀌어' -and @($script:ClaudeCalls).Count -eq $pushes -and $script:Store.Count -eq $count -and (Test-StagingClean)) 'Claude: folders that changed after describe stop the backup before the conversation is pushed'
        $realBackend=${function:Invoke-DesktopBackend}; $script:Exports=0; $savedCwds=$script:Cwds
        function Invoke-DesktopBackend([string[]]$Arguments) { if ($Arguments[0] -eq 'export') { $script:Exports++; if ($script:Exports -eq 2) { $script:Cwds=@($script:Cwds)+'D:\new-folder' } }; & $realBackend $Arguments }
        try { $changed=$null; try { Invoke-JobCore $codex } catch { $changed=$_ } } finally { ${function:Invoke-DesktopBackend}=$realBackend; $script:Cwds=$savedCwds }
        Assert ($changed.Exception.Data['vendorResult'].status -eq 'changed' -and $script:Exports -eq 2 -and $script:Store.Count -eq $count -and (Test-StagingClean)) 'Codex: folders that changed after describe stop the backup before anything is uploaded'
        [IO.File]::WriteAllText("$projA\src\app.py",'claude v2'); $null=Invoke-JobCore $claude
        $claudeTarget=Join-Path $testDirectory 'claude-target'; $null=New-Item -ItemType Directory -Path $claudeTarget
        $claude.action='Preview'; $claude.projectPath=$claudeTarget; $claude.projectRestore=$true
        $cp=Invoke-JobCore $claude
        Assert ($cp.message -eq '미리보기 완료.' -and $cp.project.state -eq 'found' -and $cp.project.folders[0].compare.new -eq 2 -and $cp.project.folders[1].target -eq $projB) 'Claude preview uses the latest link and the original extra path'
        $env:TMP=$projects; $env:TEMP=$projects
        try { $inTemp=Invoke-JobCore $claude } finally { $env:TMP=Join-Path $testDirectory 'fake-temp'; $env:TEMP=$env:TMP }
        Assert ($inTemp.project.folders[0].state -eq 'ready' -and $inTemp.project.folders[1].state -eq 'needsFolder' -and $inTemp.project.folders[1].target -eq '') 'an extra folder whose original path is under temp or settings is never picked automatically'
        $null=Remove-DesktopStage (Split-Path -Parent $inTemp.project.receipt)
        # GUI처럼 미리보기의 receipt·token을 돌려준다. 원래 경로가 있는 추가 폴더(ready)는 다른 폴더를 골라 보내도 원래 경로에 쓴다.
        $notAllowed=Join-Path $testDirectory 'not-allowed'
        $claude.action='Restore'; $claude.receipt=$cp.receipt; $claude.token=$cp.token; $claude.projectReceipt=$cp.project.receipt; $claude.projectTargets=@{'1'=$notAllowed}
        $cr=Invoke-JobCore ($claude | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
        Assert ([IO.File]::ReadAllText("$claudeTarget\src\app.py") -eq 'claude v2' -and $cr.message -match '^복원 완료\. 프로젝트 폴더 2개 복원' -and -not (Test-Path -LiteralPath (Split-Path -Parent $cp.project.receipt))) "Claude restore writes the latest backup: $($cr.message)"
        Assert (-not (Test-Path -LiteralPath $notAllowed) -and $cr.project.folders[1].target -eq $projB) 'a folder picked after the preview is used only for a folder that needed one'
        $claude.Remove('projectTargets')

        # 미리보기 짝: 같은 벤더·같은 ID의 서로 다른 미리보기(복원 폴더·대상 홈이 다르거나, 같은 폴더를 다시 본 것)를 섞으면
        # 대화 복원 전에 멈춘다. 대화·파일을 쓰지 않고, 어느 미리보기 사본도 지우지 않는다.
        $pairA=Join-Path $testDirectory 'pair-a'; $pairB=Join-Path $testDirectory 'pair-b'
        foreach ($dir in $pairA,$pairB) { $null=New-Item -ItemType Directory -Path $dir }
        function New-CodexPreview([string]$Target,[string]$HomePath) { Invoke-JobCore @{action='Preview';agent='codex-desktop';home=$HomePath;projectPath=$Target;nativeId=$script:Id;remoteId=$first.remoteId;projectRestore=$true} }
        function New-ClaudePreview([string]$Target) { Invoke-JobCore @{action='Preview';agent='claude-code';projectPath=$Target;nativeId=$claudeId;remoteId=$claudeRemote;projectRestore=$true} }
        $xa=New-CodexPreview $pairA $desktopRoot; $xb=New-CodexPreview $pairB $desktopRoot; $xc=New-CodexPreview $pairA $desktopRoot; $xh=New-CodexPreview $pairA $otherHome
        $ca=New-ClaudePreview $pairA; $cb=New-ClaudePreview $pairB; $cc=New-ClaudePreview $pairA
        $previews=@($xa,$xb,$xc,$xh,$ca,$cb,$cc)
        Assert (-not @($previews | Where-Object { $_.project.state -ne 'found' }).Count -and $xa.token -ceq $xc.token -and $ca.token -cne $cc.token) 'pairing fixture: every preview found project files; Codex tokens repeat, Claude tokens do not'
        $applies=@($script:Calls | Where-Object { $_.kind -eq 'backend' -and $_.arguments[0] -eq 'apply' }).Count; $pushes=@($script:ClaudeCalls).Count
        $mixes=@(
            @{agent='codex-desktop';home=$desktopRoot;target=$pairB;conv=$xb;project=$xa},   # 다른 복원 폴더
            @{agent='codex-desktop';home=$desktopRoot;target=$pairA;conv=$xc;project=$xa},   # 같은 폴더를 다시 본 미리보기
            @{agent='codex-desktop';home=$desktopRoot;target=$pairA;conv=$xa;project=$xh},   # 다른 대상 홈
            @{agent='claude-code';home='';target=$pairB;conv=$cb;project=$ca},
            @{agent='claude-code';home='';target=$pairA;conv=$cc;project=$ca}
        )
        foreach ($mix in $mixes) {
            $ids=if ($mix.agent -eq 'codex-desktop') {@{nativeId=$script:Id;remoteId=$first.remoteId}} else {@{nativeId=$claudeId;remoteId=$claudeRemote}}
            $job=@{action='Restore';agent=$mix.agent;home=$mix.home;projectPath=$mix.target;nativeId=$ids.nativeId;remoteId=$ids.remoteId;receipt=[string]$mix.conv.receipt;token=[string]$mix.conv.token;choice='incoming';projectRestore=$true;projectReceipt=$mix.project.project.receipt}
            Throws {Invoke-JobCore $job} '미리보기 기록'
        }
        Assert (@($script:Calls | Where-Object { $_.kind -eq 'backend' -and $_.arguments[0] -eq 'apply' }).Count -eq $applies -and @($script:ClaudeCalls).Count -eq $pushes) 'mixed previews stop before any conversation write (no apply, no resume)'
        Assert (-not @(Get-ChildItem -LiteralPath $pairA,$pairB -Force).Count) 'mixed previews write no project files'
        Assert (-not @($previews | Where-Object { -not (Test-Path -LiteralPath (Split-Path -Parent $_.project.receipt)) -or ($_.receipt -and -not (Test-Path -LiteralPath (Split-Path -Parent $_.receipt))) }).Count) 'mixed previews delete no preview copies'
        # 짝이 맞는 조합은 그대로 복원한다.
        $okCodex=Invoke-JobCore @{action='Restore';agent='codex-desktop';home=$desktopRoot;projectPath=$pairA;nativeId=$script:Id;remoteId=$first.remoteId;receipt=$xc.receipt;token=$xc.preview.token;choice='incoming';projectRestore=$true;projectReceipt=$xc.project.receipt}
        $okClaude=Invoke-JobCore @{action='Restore';agent='claude-code';projectPath=$pairB;nativeId=$claudeId;remoteId=$claudeRemote;receipt=$cb.receipt;token=$cb.token;projectRestore=$true;projectReceipt=$cb.project.receipt}
        Assert ($okCodex.effect -eq 'restored' -and $okClaude.effect -eq 'restored' -and (Test-Path -LiteralPath "$pairA\src\app.py") -and [IO.File]::ReadAllText("$pairB\src\app.py") -eq 'claude v2') 'the matching preview pair restores'
        foreach ($left in $xa,$xb,$xh,$ca,$cc) { $null=Remove-DesktopStage (Split-Path -Parent $left.project.receipt); if ($left.receipt) { $null=Remove-DesktopStage (Split-Path -Parent $left.receipt) } }

        # 다른 벤더의 같은 UUID: Codex 대화에서 받은 프로젝트 미리보기를 같은 UUID의 Claude 복원에 넘기면 대화 복원 전에 멈춘다.
        $restore.action='Preview'; $restore.projectRestore=$true; $cxp=Invoke-JobCore $restore
        Assert ($cxp.project.state -eq 'found') 'Codex project preview for the cross-vendor check'
        [IO.File]::WriteAllText("$claudeTarget\src\app.py",'cross check'); $pushes=@($script:ClaudeCalls).Count
        Throws {Invoke-JobCore @{action='Restore';agent='claude-code';projectPath=$claudeTarget;nativeId=$script:Id;remoteId=$claudeRemote;token=$cxp.token;projectRestore=$true;projectReceipt=$cxp.project.receipt}} '미리보기 기록'
        Assert (@($script:ClaudeCalls).Count -eq $pushes -and [IO.File]::ReadAllText("$claudeTarget\src\app.py") -eq 'cross check' -and (Test-Path -LiteralPath (Split-Path -Parent $cxp.project.receipt))) "a project preview of another vendor's conversation with the same UUID is refused before anything is written"
        $null=Remove-DesktopStage (Split-Path -Parent $cxp.receipt); $null=Remove-DesktopStage (Split-Path -Parent $cxp.project.receipt)

        # 실제 스냅숏 크기: 계획을 세운 뒤 폴더가 커지면(대화 백업 뒤, 또는 해시와 압축 사이) 허락과 한도를 실제로 읽은 양으로 다시 본다.
        # 대화 백업(remoteId)은 그대로 두고 그 폴더만 올리지 않는다. 두 벤더가 같은 Worker 경로를 쓴다.
        $grow=Join-Path $projects 'grow'; $null=New-Item -ItemType Directory -Path $grow
        $realBundles=${function:Get-ProjectBundles}; $realManifest=${function:Get-ProjectManifest}; $realRead=${function:Read-ClaudeWorkData}
        function Get-ProjectBundles { if ($script:GrowTo) { [IO.File]::WriteAllText("$grow\data.txt",$script:GrowTo); $script:GrowTo=$null }; & $realBundles }
        function Get-ProjectManifest([object]$List,[long]$Limit=[long]::MaxValue) {
            $manifest=& $realManifest $List $Limit
            if ($script:GrowAfterManifest -and @($List.files | Where-Object { $_.full -like "$grow\*" }).Count) { [IO.File]::WriteAllText("$grow\data.txt",$script:GrowAfterManifest); $script:GrowAfterManifest=$null }
            $manifest
        }
        function Read-ClaudeWorkData([string[]]$Files) { [pscustomobject]@{cwds=@($projA,$grow);edits=@()} }
        $savedCwds=$script:Cwds; $savedEdits=$script:Edits; $script:Cwds=@($grow); $script:Edits=@()
        $script:ProjectAskBytes=100; $script:ProjectMaxBytes=1000
        try {
            $cases=@(
                @{name='grew past the question size, not approved';approved=$false;grow=('b'*200);after=$null;status='skipped';reason=(T 'WkProjectGrewUnapproved')},
                @{name='approved but over the uncompressed limit (compresses well)';approved=$true;grow=('a'*5000);after=$null;status='skipped';reason='tooLarge'},
                @{name='approved and within the limit';approved=$true;grow=('c'*500);after=$null;status='uploaded';reason=''},
                @{name='grew between the hash and the zip';approved=$false;grow=$null;after=('d'*200);status='skipped';reason=(T 'WkProjectGrewUnapproved')}
            )
            foreach ($vendor in 'codex-desktop','claude-code') {
                foreach ($case in $cases) {
                    [IO.File]::WriteAllText("$grow\data.txt",('s'+[guid]::NewGuid().ToString('N')))
                    $job=if ($vendor -eq 'codex-desktop') {@{action='Backup';agent=$vendor;home=$desktopRoot;projectPath=$target;nativeId=$script:Id;remoteId='';projectBackup=$true}} else {@{action='Backup';agent=$vendor;projectPath=$projA;nativeId=$claudeId;remoteId=$claudeRemote;projectBackup=$true}}
                    if ($case.approved) { $job.projectApproved=@($grow) }
                    # 올리는 사례는 벤더마다 내용을 달리한다(같은 내용이면 앞 벤더가 올린 백업에 연결만 한다).
                    $script:GrowTo=if ($case.status -eq 'uploaded') {('c'*500)+$vendor} else {$case.grow}; $script:GrowAfterManifest=$case.after
                    $before=@(Get-Stored 'project-files;*' | Where-Object { $_.metadata.sourceCwd -eq $grow }).Count
                    $result=Invoke-JobCore $job
                    $entry=@($result.project.folders | Where-Object { $_.sourcePath -eq $grow })
                    $added=@(Get-Stored 'project-files;*' | Where-Object { $_.metadata.sourceCwd -eq $grow }).Count-$before
                    Assert ($result.remoteId -and -not $result.needsProjectConfirm -and $entry.Count -eq 1 -and $entry[0].status -eq $case.status -and $entry[0].reason -eq $case.reason -and $added -eq [int]($case.status -eq 'uploaded') -and -not $script:GrowTo -and -not $script:GrowAfterManifest -and (Test-StagingClean)) "$vendor, $($case.name): $($entry | ConvertTo-Json -Compress)"
                }
            }
        } finally {
            ${function:Get-ProjectBundles}=$realBundles; ${function:Get-ProjectManifest}=$realManifest; ${function:Read-ClaudeWorkData}=$realRead
            $script:Cwds=$savedCwds; $script:Edits=$savedEdits; $script:ProjectAskBytes=200MB; $script:ProjectMaxBytes=16GB
        }
        $claude.projectRestore=$false; $claude.action='Preview'; $cp=Invoke-JobCore $claude
        Assert ($cp.project.state -eq 'off') 'Claude preview skips project files when the option is off'
        Assert (Test-StagingClean) 'no plaintext project copy remains in staging'
    } finally { $env:TMP=$oldTmp; $env:TEMP=$oldTemp; $env:GIT_CEILING_DIRECTORIES=$oldCeiling }
    # GUI처럼 Worker.ps1을 별도 프로세스로 실행해 요청·결과 경로가 ClaudeWorker dot-source 뒤에도 남는지 확인한다.
    $request=Join-Path $testDirectory 'request.json'; $result=Join-Path $testDirectory 'result.json'
    @{action='Open';agent='codex-desktop';home=$desktopRoot} | ConvertTo-Json | Set-Content -LiteralPath $request -Encoding UTF8
    $null=& (Join-Path $PSHOME 'powershell.exe') -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File (Join-Path $PSScriptRoot 'Worker.ps1') -RequestFile $request -ResultFile $result
    Assert ($LASTEXITCODE -eq 1 -and (Test-Path -LiteralPath $result)) 'Worker process must write its result file for the GUI'
    $answer=Get-Content -LiteralPath $result -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($answer.ok -eq $false -and $answer.error -match 'Codex Desktop') 'Worker process reports the job error in the result file'
    Assert ($answer.vendor.status -eq 'unsupported' -and $answer.vendor.reasonCode -eq 'open_manually' -and $null -eq $answer.vendorOutcome) 'the result file keeps the contract status and reason code for the GUI'
    # Worker가 어떻게 끝나든 벤더 구현·백엔드 같은 자손도 함께 끝나야, 다음 Worker가 작업 mutex만으로 앞 작업의 writer가 없다고 볼 수 있다.
    # Job 객체를 켜기 전에는 복원을 거부하는지도 같은 프로세스에서 본다.
    $probe=Join-Path $testDirectory 'job-probe.ps1'; $pidFile=Join-Path $testDirectory 'job-child.txt'
    Set-Content -LiteralPath $probe -Encoding UTF8 -Value @'
param([string]$Package,[string]$PidFile)
. (Join-Path $Package 'Worker.ps1') -LibraryOnly
$before=try { Assert-WorkerJob; 'allowed' } catch { 'refused' }
Enable-WorkerJob
$start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'),'-NoProfile -Command Start-Sleep 120')
$start.UseShellExecute=$false; $start.CreateNoWindow=$true
$child=[Diagnostics.Process]::Start($start)
[IO.File]::WriteAllText($PidFile,"$($child.Id) $before")
Start-Sleep 120
'@
    $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'),"-NoProfile -ExecutionPolicy Bypass -File `"$probe`" -Package `"$PSScriptRoot`" -PidFile `"$pidFile`"")
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $probeWorker=[Diagnostics.Process]::Start($start)
    try {
        for ($i=0; $i -lt 240 -and -not (Test-Path -LiteralPath $pidFile); $i++) { Start-Sleep -Milliseconds 250 }
        Start-Sleep -Milliseconds 300
        $childId,$before=(Get-Content -LiteralPath $pidFile -Raw).Trim() -split ' '
        Assert ($before -eq 'refused') 'restore is refused until the worker runs inside its Job object'
        Assert ([bool](Get-Process -Id ([int]$childId) -ErrorAction SilentlyContinue)) 'the helper process runs while the worker runs'
        $probeWorker.Kill(); $probeWorker.WaitForExit()
        for ($i=0; $i -lt 40 -and (Get-Process -Id ([int]$childId) -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
        Assert (-not (Get-Process -Id ([int]$childId) -ErrorAction SilentlyContinue)) 'a killed worker takes its helper processes with it (Job object)'
    } finally { if (-not $probeWorker.HasExited) { $probeWorker.Kill() }; $probeWorker.Dispose() }
    # 다음 Worker의 writer 확인(S3 명세 2.2절): 표지에 적힌 Worker가 살아 있으면 busy, Job이 사라졌으면 gone,
    # Worker 없이 자손만 남았으면 Job째 끝내고 gone. 이름 형식이 틀리면 busy.
    $fieldsFile=Join-Path $testDirectory 'job-fields.json'
    Set-Content -LiteralPath $probe -Encoding UTF8 -Value @'
param([string]$Package,[string]$PidFile)
. (Join-Path $Package 'Worker.ps1') -LibraryOnly
Enable-WorkerJob
$start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'),'-NoProfile -Command Start-Sleep 120')
$start.UseShellExecute=$false; $start.CreateNoWindow=$true
$child=[Diagnostics.Process]::Start($start)
$fields=Get-WorkerFields; $fields.child=$child.Id
[IO.File]::WriteAllText($PidFile,(ConvertTo-Json -InputObject $fields))
Start-Sleep 120
'@
    function Start-JobProbe {
        if (Test-Path -LiteralPath $fieldsFile) { Remove-Item -LiteralPath $fieldsFile }
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'),"-NoProfile -ExecutionPolicy Bypass -File `"$probe`" -Package `"$PSScriptRoot`" -PidFile `"$fieldsFile`"")
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $process=[Diagnostics.Process]::Start($start)
        for ($i=0; $i -lt 240 -and -not (Test-Path -LiteralPath $fieldsFile); $i++) { Start-Sleep -Milliseconds 250 }
        Start-Sleep -Milliseconds 300
        return @{process=$process;marker=(Get-Content -LiteralPath $fieldsFile -Raw | ConvertFrom-Json)}
    }
    # 끝났지만 아직 목록에 남은 프로세스는 살아 있지 않은 것으로 본다(핸들로 종료 여부를 확인).
    function Test-Alive([int]$Id) { try { $process=[Diagnostics.Process]::GetProcessById($Id); try { return -not $process.HasExited } finally { $process.Dispose() } } catch { return $false } }
    $probeRun=Start-JobProbe
    try {
        Assert ($probeRun.marker.workerJob -match '^Local\\CtxHopGUI-worker-[0-9a-f]{32}$' -and $probeRun.marker.workerStarted) "the marker names the worker's Job: $($probeRun.marker | ConvertTo-Json -Compress)"
        Assert ((Test-WorkerWritersGone $probeRun.marker 5) -eq 'busy' -and (Test-Alive $probeRun.marker.child)) 'a live worker is busy and nothing is stopped'
        $held=[CtxHopWorkerJob]::Open($probeRun.marker.workerJob)
        try {
            # 이 시험이 Job 핸들을 쥐고 있으면 Worker가 끝나도 자손이 남는다(주인 없는 writer).
            $probeRun.process.Kill(); $probeRun.process.WaitForExit()
            Start-Sleep -Milliseconds 300
            Assert (Test-Alive $probeRun.marker.child) 'an orphan writer survives while another handle holds the Job'
            Assert ((Test-WorkerWritersGone $probeRun.marker 10) -eq 'gone' -and -not (Test-Alive $probeRun.marker.child)) 'an orphan writer is ended with its Job before anything else runs'
        } finally { [CtxHopWorkerJob]::Close($held) }
        Assert ((Test-WorkerWritersGone $probeRun.marker 5) -eq 'gone') 'a Job that no longer exists means no writer is left'
        Assert ((Test-WorkerWritersGone ([pscustomobject]@{workerJob='Global\other';workerPid=1;workerStarted='1'}) 5) -eq 'busy') 'a marker with a foreign Job name is busy'
    } finally { if (-not $probeRun.process.HasExited) { $probeRun.process.Kill() }; $probeRun.process.Dispose() }
    $probeRun=Start-JobProbe
    try {
        $probeRun.process.Kill(); $probeRun.process.WaitForExit()
        for ($i=0; $i -lt 40 -and (Test-Alive $probeRun.marker.child); $i++) { Start-Sleep -Milliseconds 250 }
        Assert ((Test-WorkerWritersGone $probeRun.marker 5) -eq 'gone' -and -not (Test-Alive $probeRun.marker.child)) 'a killed worker leaves no Job and no writer'
    } finally { if (-not $probeRun.process.HasExited) { $probeRun.process.Kill() }; $probeRun.process.Dispose() }
    # 정상 경로: 자손이 스스로 끝나면 alone. 남으면 이 Job 소속만 끝내고(손자 포함) 목록을 다시 받는다.
    Assert ((Get-WorkerFields).workerJob -ceq [CtxHopWorkerJob]::Name -and (Test-WorkerWritersGone ([pscustomobject](Get-WorkerFields)) 1) -eq 'gone') 'the worker itself is never a foreign writer'
    function Start-Helper([string]$Command) {
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'),"-NoProfile -Command $Command")
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        return [Diagnostics.Process]::Start($start)
    }
    $helper=Start-Helper 'Start-Sleep -Milliseconds 800'
    Assert ((Wait-WorkerJobAlone 30 5) -eq 'alone') 'a helper that ends by itself leaves the worker alone'
    $helper.Dispose()
    $grandFile=Join-Path $testDirectory 'grandchild.txt'
    $helper=Start-Helper "`$s=[Diagnostics.ProcessStartInfo]::new('$(Join-Path $PSHOME 'powershell.exe')','-NoProfile -Command Start-Sleep 120'); `$s.UseShellExecute=`$false; `$s.CreateNoWindow=`$true; `$g=[Diagnostics.Process]::Start(`$s); [IO.File]::WriteAllText('$grandFile',[string]`$g.Id); Start-Sleep 120"
    for ($i=0; $i -lt 120 -and -not (Test-Path -LiteralPath $grandFile); $i++) { Start-Sleep -Milliseconds 250 }
    $grandchild=[int](Get-Content -LiteralPath $grandFile -Raw)
    Assert ((Wait-WorkerJobAlone 1 10) -eq 'killed' -and -not (Test-Alive $helper.Id) -and -not (Test-Alive $grandchild)) 'helpers left after the wait are ended with their own children'
    $helper.Dispose()
    Write-Output "PASS: $script:Checks isolated desktop worker assertions. All native backend and bundle calls mocked."
} finally {
    $env:LOCALAPPDATA=$oldLocal
    $resolved=[IO.Path]::GetFullPath($testDirectory); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^CtxHop-vnext-worker-[a-f0-9]{32}$') { throw 'Refusing cleanup outside fixture directory' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
