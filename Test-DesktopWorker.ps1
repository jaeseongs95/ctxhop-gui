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
    Assert (@($script:Calls | Where-Object {$_.kind -eq 'backend' -and $_.arguments[0] -eq 'list'}).Count -eq 2) 'metadata list must paginate 200 at a time'
    Assert (@($list.sessions | Where-Object archived).Count -gt 0) 'archived conversations must remain visible'
    Assert (@($list.sessions | Where-Object nativeId -eq $script:Id).Count -eq 2) 'same UUID branches must not collapse by date'
    Assert ($list.sessions[-1].blockedReason -and -not $list.sessions[-1].local) 'invalid metadata stays visible and blocked'
    Assert (@($list.sessions | Where-Object {$_.local -and $_.children -eq 2}).Count -eq 1 -and -not @($list.sessions | Where-Object {$_.local -and $_.blockedReason}).Count) 'local rows carry the subagent count and are never blocked for it'
    Assert (@($list.sessions | Where-Object {$_.remoteId -eq $script:BundleA -and $_.children -eq 3}).Count -eq 1 -and @($list.sessions | Where-Object {$_.remoteId -eq $script:BundleB -and $null -eq $_.children}).Count -eq 1) 'family backups report their subagent count; older backups report none'
    $script:ListBadChildren=$true; Throws {Invoke-JobCore @{action='List';agent='codex-desktop';home=$desktopRoot;search=''}} '목록 메타데이터'; $script:ListBadChildren=$false
    $staging=Join-Path $testDirectory 'CtxHopGUI\staging'
    $job.action='Backup'; $backup=Invoke-JobCore $job
    Assert ($backup.bundle.id -eq $script:BundleA) 'export publishes opaque encrypted bundle'
    Assert (-not @(Get-ChildItem -LiteralPath $staging -Force)) 'uploaded plaintext backup copy is removed'
    foreach ($status in 'busy','blocked') {
        $script:ExportStatus=$status; $exportError=$null
        try { $null=Invoke-JobCore $job } catch { $exportError=$_ }
        $script:ExportStatus=$null
        Assert ($exportError -and $exportError.Exception.Data['backendResult'].status -eq $status) "a $status export keeps the backend status for the GUI"
        Assert (-not @(Get-ChildItem -LiteralPath $staging -Force)) "a $status export leaves no plaintext staging copy"
    }
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
    # 안정판 ctxhop-gui\Worker.ps1(최종 감사 D08E9A15…)에서 문장만 Strings.ps1로 옮긴 판에, ctxhop 0.2.0-gui.2 고정과
    # Claude 세션 옆 폴더(하위 에이전트·도구 결과) 복원 확인과 ctxhop 출력 UTF-8 읽기를 더한 판과 바이트 동일해야 한다.
    Assert ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'ClaudeWorker.ps1') -Algorithm SHA256).Hash -eq '947D26D610986559F822E3166B99FF50CC210683CD11A0495E21162495CDF69D') 'Claude worker copy must match the reviewed version'
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
        Assert ($firstLink.metadata.historyMode -eq 'project-link;v1;codex-desktop' -and $firstLink.metadata.title -ceq $first.bundle.id -and $firstLink.metadata.sessionId -eq $script:Id -and $firstLink.metadata.sourceCwd -eq $projA) 'the link names the conversation bundle and start folder'
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
        Assert ($failedPlan.bundle.id -and $null -eq $failedPlan.project -and $failedPlan.message -match '프로젝트 파일은 백업하지 못했습니다' -and $failedPlan.message -match '합성 폴더 실패' -and $script:Store.Count -eq $count+1) "a failure while picking folders never blocks the Codex conversation backup: $($failedPlan.message)"

        # 목록에는 프로젝트 파일과 연결 기록이 대화로 보이지 않는다.
        $listed=Invoke-JobCore @{action='List';agent='codex-desktop';home=$desktopRoot;search=''}
        Assert ($listed.sessions.Count -eq @(Get-Stored 'paginated*').Count -and -not @($listed.sessions | Where-Object { $_.historyMode -like 'project-*' }).Count) 'project bundles are hidden from the conversation list'

        # 미리보기와 복원: 첫 백업 때의 상태(v1)를 복원 폴더에 쓰고, 바뀌는 파일의 원본은 남기며, 이 PC에만 있는 파일은 둔다.
        $restoreTarget=Join-Path $testDirectory 'restore-target'
        foreach ($pair in @(@("$restoreTarget\src\app.py",'local edit'),@("$restoreTarget\local.txt",'keep'))) { $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $pair[0])); [IO.File]::WriteAllText($pair[0],$pair[1]) }
        Rename-Item -LiteralPath $projB -NewName 'lib-moved'; $picked=Join-Path $testDirectory 'picked-lib'
        $restore=@{action='Preview';agent='codex-desktop';home=$desktopRoot;projectPath=$restoreTarget;nativeId=$script:Id;remoteId=$first.bundle.id;projectRestore=$true}
        $storedB=@(Get-Stored 'project-files;*' | Where-Object { $_.metadata.sourceCwd -eq $projB })[0].file; $bytesB=[IO.File]::ReadAllBytes($storedB)
        [IO.File]::WriteAllText($storedB,'not a zip')
        try { $iso=Invoke-JobCore $restore } finally { [IO.File]::WriteAllBytes($storedB,$bytesB) }
        Assert ($iso.preview.token -and @($iso.project.folders).Count -eq 3 -and $iso.project.folders[0].state -eq 'ready' -and $iso.project.folders[1].state -eq 'error' -and $iso.project.folders[1].reason -and $iso.project.folders[1].target -eq '' -and $iso.project.folders[2].state -eq 'skipped') "one unreadable folder does not stop the others: $($iso.project | ConvertTo-Json -Depth 3 -Compress)"
        $null=Remove-DesktopStage (Split-Path -Parent $iso.receipt)
        $shown=Invoke-JobCore $restore
        $p=$shown.project
        Assert ($p.state -eq 'found' -and $p.folders.Count -eq 3 -and (($p.outside) -join '|') -eq $outsideEdit) "project preview found: $($p | ConvertTo-Json -Depth 4 -Compress)"
        Assert ($p.folders[0].state -eq 'ready' -and $p.folders[0].target -eq $restoreTarget -and $p.folders[0].compare.new -eq 1 -and $p.folders[0].compare.changed -eq 1 -and $p.folders[0].compare.localOnly -eq 1) 'start folder compares with the chosen restore folder'
        Assert ($p.folders[1].state -eq 'needsFolder' -and $p.folders[1].target -eq '' -and $p.folders[2].state -eq 'skipped') 'an extra folder missing on this PC needs a choice'
        $restore.action='Restore'; $restore.receipt=$shown.receipt; $restore.token=$shown.preview.token; $restore.choice='incoming'; $restore.projectTargets=@{'1'=$picked}
        $restoreJob=$restore | ConvertTo-Json -Depth 5 | ConvertFrom-Json   # GUI처럼 JSON을 거친 요청
        $done=Invoke-JobCore $restoreJob
        Assert ($done.project.folders.Count -eq 2 -and $done.message -match '프로젝트 폴더 2개 복원') "project restore message: $($done.message)"
        Assert ([IO.File]::ReadAllText("$restoreTarget\src\app.py") -eq 'v1' -and [IO.File]::ReadAllText("$restoreTarget\README.md") -eq '# 앱' -and [IO.File]::ReadAllText("$restoreTarget\local.txt") -eq 'keep') 'the state of that backup is restored and local-only files stay'
        Assert ([IO.File]::ReadAllText("$picked\lib.py") -eq 'lib v1' -and -not (Test-Path -LiteralPath "$restoreTarget\.env")) 'the extra folder goes to the chosen folder'
        $recovery=$done.project.recovery
        Assert ($recovery -and [IO.File]::ReadAllText("$recovery\0\src\app.py") -eq 'local edit' -and (Test-Path -LiteralPath "$recovery\restore-log.json") -and (Get-Acl -LiteralPath $recovery).AreAccessRulesProtected) 'replaced originals are kept in a private recovery folder'
        Assert (-not (Test-Path -LiteralPath (Split-Path -Parent $shown.receipt))) 'the preview staging copy is removed after restore'
        # 이 PC 대화가 더 새로우면 파일도 그대로 둔다. 선택을 끄면 복원하지 않는다. 미리보기 뒤 바뀐 파일은 쓰지 않는다.
        foreach ($case in @(@{status='local_newer';restore=$true},@{status='imported';restore=$false},@{status='imported';restore=$true;tamper=$true})) {
            [IO.File]::WriteAllText("$restoreTarget\src\app.py",'local again'); $script:ApplyStatus=$case.status
            $restore.action='Preview'; $restore.projectRestore=$true; $shown=Invoke-JobCore $restore
            $restore.action='Restore'; $restore.receipt=$shown.receipt; $restore.token=$shown.preview.token; $restore.projectRestore=$case.restore
            if ($case.tamper) { [IO.File]::AppendAllText($shown.project.folders[0].zip,'x') }
            $done=Invoke-JobCore ($restore | ConvertTo-Json -Depth 5 | ConvertFrom-Json)   # GUI처럼 JSON을 거쳐 고른 폴더(projectTargets)도 쓴다
            Assert ([IO.File]::ReadAllText("$restoreTarget\src\app.py") -eq 'local again') "project files stay for $($case | ConvertTo-Json -Compress)"
            if ($case.tamper) { Assert ($done.message -match '폴더는 복원하지 못했습니다' -and $done.applied.status -eq 'imported' -and (@($done.project.folders | ForEach-Object state) -join '|') -eq 'failed|restored' -and (Test-Path -LiteralPath "$($done.project.recovery)\restore-log.json")) "a changed download fails only that folder; the others are restored and logged: $($done.message)" }
        }
        $script:ApplyStatus='imported'; $restore.projectRestore=$true
        # 미리보기를 꺼 두면 프로젝트 파일을 받지 않는다.
        $restore.action='Preview'; $restore.projectRestore=$false; $gets=@($script:Calls | Where-Object { $_.kind -eq 'bundle' -and $_.arguments[0] -eq 'get' }).Count
        $off=Invoke-JobCore $restore
        Assert ($off.project.state -eq 'off' -and @($script:Calls | Where-Object { $_.kind -eq 'bundle' -and $_.arguments[0] -eq 'get' }).Count -eq $gets+1) 'with restore off only the conversation is downloaded'
        $null=Remove-DesktopStage (Split-Path -Parent $off.receipt)
        Throws { Read-ProjectReceipt (Join-Path $testDirectory 'project-receipt.json') 'codex-desktop' $script:Id $first.bundle.id } '미리보기 기록'

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
        [IO.File]::WriteAllText("$projA\src\app.py",'claude v2'); $null=Invoke-JobCore $claude
        $claudeTarget=Join-Path $testDirectory 'claude-target'; $null=New-Item -ItemType Directory -Path $claudeTarget
        $claude.action='Preview'; $claude.projectPath=$claudeTarget; $claude.projectRestore=$true
        $cp=Invoke-JobCore $claude
        Assert ($cp.message -eq '미리보기 완료.' -and $cp.project.state -eq 'found' -and $cp.project.folders[0].compare.new -eq 2 -and $cp.project.folders[1].target -eq $projB) 'Claude preview uses the latest link and the original extra path'
        $env:TMP=$projects; $env:TEMP=$projects
        try { $inTemp=Invoke-JobCore $claude } finally { $env:TMP=Join-Path $testDirectory 'fake-temp'; $env:TEMP=$env:TMP }
        Assert ($inTemp.project.folders[0].state -eq 'ready' -and $inTemp.project.folders[1].state -eq 'needsFolder' -and $inTemp.project.folders[1].target -eq '') 'an extra folder whose original path is under temp or settings is never picked automatically'
        $null=Remove-DesktopStage (Split-Path -Parent $inTemp.project.receipt)
        $claude.action='Restore'; $claude.projectReceipt=$cp.project.receipt
        $cr=Invoke-JobCore $claude
        Assert ([IO.File]::ReadAllText("$claudeTarget\src\app.py") -eq 'claude v2' -and $cr.message -match '^복원 완료\. 프로젝트 폴더 2개 복원' -and -not (Test-Path -LiteralPath (Split-Path -Parent $cp.project.receipt))) "Claude restore writes the latest backup: $($cr.message)"
        $claude.projectRestore=$false; $claude.action='Preview'; $cp=Invoke-JobCore $claude
        Assert ($null -eq $cp.project) 'Claude preview skips project files when the option is off'
        Assert (Test-StagingClean) 'no plaintext project copy remains in staging'
    } finally { $env:TMP=$oldTmp; $env:TEMP=$oldTemp; $env:GIT_CEILING_DIRECTORIES=$oldCeiling }
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
