#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Worker.ps1') -LibraryOnly
$script:Checks=0
function Assert([bool]$Value,[string]$Message) { $script:Checks++; if (-not $Value) { throw "ASSERT: $Message" } }
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
            return [pscustomobject]@{total=201;sessions=@(for($i=0;$i -lt $count;$i++){[pscustomobject]@{id=('00000000-0000-4000-8000-{0:d12}' -f ($offset+$i));title='fixture';cwd='D:\all-projects';updatedAt='2026-09-26T01:00:00Z';historyMode='paginated';archived=($i%2 -eq 0);subagent=($i -eq 1)}})}
        }
        export {
            $file=$Arguments[[array]::IndexOf($Arguments,'--output')+1]
            Assert (-not (Test-Path -LiteralPath $file)) 'export must use new file'
            [IO.File]::WriteAllText($file,'synthetic archive',[Text.UTF8Encoding]::new($false))
            return @{metadata=$script:Metadata}
        }
        inspect { return [pscustomobject]@{status=$script:State;reason='fixture_content_comparison';token='exact-token-A';source=@{sessionId=$script:Id};target=@{sessionId=$script:Id}} }
        apply {
            if ($script:ApplyFail) {
                $e=[InvalidOperationException]::new('복원 실패, 복구 기록 유지')
                $e.Data['backendResult']=[pscustomobject]@{error='partial write';journal='fixture/recovery/pending.json';recoveryRequired=$true}
                throw $e
            }
            return @{status='imported';journal='fixture/recovery/completed.json'}
        }
        default { throw 'unexpected backend operation' }
    }
}
function Invoke-Bundle([string[]]$Arguments) {
    $script:Calls+=,[pscustomobject]@{kind='bundle';arguments=$Arguments}
    switch ($Arguments[0]) {
        list {
            $a=$script:Metadata.PSObject.Copy(); $b=$script:Metadata.PSObject.Copy()
            $a.updatedAt='2099-09-26T01:00:00Z'; $b.updatedAt='1990-09-26T01:00:00Z'
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
    Assert (@($script:Calls | Where-Object {$_.kind -eq 'backend' -and $_.arguments[0] -eq 'list'}).Count -eq 2) 'metadata list must paginate 200 at a time'
    Assert (@($list.sessions | Where-Object archived).Count -gt 0) 'archived conversations must remain visible'
    Assert (@($list.sessions | Where-Object nativeId -eq $script:Id).Count -eq 2) 'same UUID branches must not collapse by date'
    Assert ($list.sessions[-1].blockedReason -and -not $list.sessions[-1].local) 'invalid metadata stays visible and blocked'
    Assert (@($list.sessions | Where-Object {$_.local -and $_.blockedReason -match '하위 에이전트'}).Count -eq 1) 'subagent conversation stays visible but blocked'
    $staging=Join-Path $testDirectory 'CtxHopGUI\staging'
    $job.action='Backup'; $backup=Invoke-JobCore $job
    Assert ($backup.bundle.id -eq $script:BundleA) 'export publishes opaque encrypted bundle'
    Assert (-not @(Get-ChildItem -LiteralPath $staging -Force)) 'uploaded plaintext backup copy is removed'
    $job.action='Preview'; $preview=Invoke-JobCore $job
    Assert ($preview.preview.status -eq 'conflict') 'backend content comparison controls status'
    $previewStage=Split-Path -Parent $preview.receipt
    Assert (Get-Acl -LiteralPath $previewStage).AreAccessRulesProtected 'plaintext preview staging must disable ACL inheritance'
    $job.action='Restore'; $job.receipt=$preview.receipt; $job.token=$preview.preview.token; $job.choice='skip'
    $before=$script:Calls.Count; $null=Invoke-JobCore $job
    Assert ($script:Calls.Count -eq $before) 'skip must preserve the local branch without any backend write'
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
    Assert ($failure.Exception.Data['backendResult'].journal -eq 'fixture/recovery/pending.json') 'failure must preserve backend recovery journal data'
    Assert (Test-Path -LiteralPath $r.receipt) 'failed restore must retain inspect and archive evidence'
    # 안정판 ctxhop-gui\Worker.ps1(최종 감사 D08E9A15…)과 바이트 동일해야 한다.
    Assert ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'ClaudeWorker.ps1') -Algorithm SHA256).Hash -eq 'D08E9A15A19C8F3D09126EF8535CFD13AE39D9CFF3BC9BADA1DCE53C4741E47F') 'Claude worker copy must be byte identical'
    Throws {Assert-FrozenFile (Join-Path $testDirectory 'nonexistent.py') ''} '준비되지'
    Throws {Assert-BundleId '../aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'} '잘못된'
    Throws {Assert-BundleId 'peer-a/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'} '잘못된'
    # GUI처럼 Worker.ps1을 별도 프로세스로 실행해 요청·결과 경로가 ClaudeWorker dot-source 뒤에도 남는지 확인한다.
    $request=Join-Path $testDirectory 'request.json'; $result=Join-Path $testDirectory 'result.json'
    @{action='Open';agent='codex-desktop';home=$desktopRoot} | ConvertTo-Json | Set-Content -LiteralPath $request -Encoding UTF8
    $null=& (Join-Path $PSHOME 'powershell.exe') -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File (Join-Path $PSScriptRoot 'Worker.ps1') -RequestFile $request -ResultFile $result
    Assert ($LASTEXITCODE -eq 1 -and (Test-Path -LiteralPath $result)) 'Worker process must write its result file for the GUI'
    $answer=Get-Content -LiteralPath $result -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($answer.ok -eq $false -and $answer.error -match 'Codex Desktop') 'Worker process reports the job error in the result file'
    Write-Output "PASS: $script:Checks isolated desktop worker assertions. All native backend and bundle calls mocked."
} finally {
    $env:LOCALAPPDATA=$oldLocal
    $resolved=[IO.Path]::GetFullPath($testDirectory); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^CtxHop-vnext-worker-[a-f0-9]{32}$') { throw 'Refusing cleanup outside fixture directory' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
