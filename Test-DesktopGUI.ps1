#requires -Version 5.1
$ErrorActionPreference='Stop'
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('CtxHop-vnext-gui-'+[guid]::NewGuid().ToString('N'))
$oldLocal=$env:LOCALAPPDATA; $oldConfig=$env:CTXHOP_CONFIG_DIR
$script:Checks=0; $script:Errors=@(); $script:StartedJobs=@(); $script:ContinueCalled=$false
function Assert([bool]$Value,[string]$Message) { $script:Checks++; if (-not $Value) { throw "ASSERT: $Message" } }
function Throws([scriptblock]$Body,[string]$Pattern) {
    $errorRecord=$null; try {& $Body | Out-Null} catch {$errorRecord=$_}
    Assert ($null -ne $errorRecord) 'operation must fail'
    Assert ($errorRecord.Exception.Message -match $Pattern) "expected $Pattern, got $($errorRecord.Exception.Message)"
}
try {
    $null=New-Item -ItemType Directory -Path $testDirectory
    $env:LOCALAPPDATA=$testDirectory; $env:CTXHOP_CONFIG_DIR=$testDirectory
    $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'GUI.ps1'),[Text.Encoding]::UTF8)
    $tail=$source.LastIndexOf('if ($SmokeTest) {')
    $fixture=Join-Path $testDirectory 'GUI.ps1'
    [IO.File]::WriteAllText($fixture,$source.Substring(0,$tail),[Text.UTF8Encoding]::new($true))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Strings.ps1') -Destination $testDirectory
    . $fixture -SmokeTest
    $timer.Stop(); $filterTimer.Stop()
    function Show-Error([string]$Message) {$script:Errors+=,$Message; $status.Text=$Message}
    function Start-Job([hashtable]$Job) {$script:StartedJobs+=,$Job.Clone()}
    $agent.SelectedIndex=1; $project.Text='D:\합성 대상'; $desktopHome.Text='D:\합성 데이터'
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    Assert ($projectOnly.Visible -and $projectOnly.Checked -and $bulkButton.Visible -and -not $openButton.Visible) 'Codex mode shows This project only (on by default) and bulk backup in place of Open'
    # 아래 합성 행의 원본 폴더는 프로젝트 밖이므로 기존 검사는 프로젝트 필터를 끄고 한다.
    $projectOnly.Checked=$false
    $id='11111111-1111-4111-8111-111111111111'; $a='peer-a/'+('a'*32); $b='peer-b/'+('b'*32)
    $sessions=@(
        [pscustomobject]@{agent='codex-desktop';nativeId=$id;remoteId='';title='로컬';updatedAt='2026-09-26T01:00:00Z';local=$true;recordCount=0;sourceCwd='D:\other';historyMode='paginated';archived=$true;children=2},
        [pscustomobject]@{agent='codex-desktop';nativeId=$id;remoteId=$a;title='다른 PC 갈래 A';updatedAt='2099-09-26T01:00:00Z';local=$false;recordCount=3;sourceCwd='D:\source-A';historyMode='paginated;family=1';archived=$false;children=1},
        [pscustomobject]@{agent='codex-desktop';nativeId=$id;remoteId=$b;title='다른 PC 갈래 B';updatedAt='1990-09-26T01:00:00Z';local=$false;recordCount=3;sourceCwd='D:\source-B';historyMode='paginated';archived=$false},
        [pscustomobject]@{agent='codex-desktop';nativeId='';remoteId='invalid';title='미확인 공유 백업';updatedAt='';local=$false;recordCount=0;blockedReason='metadata invalid'}
    )
    Fill-Sessions $sessions
    Assert ($grid.MultiSelect -and $grid.Rows.Count -eq 4) 'Desktop allows multiple explicit rows; identical UUID branches stay separate'
    Assert (@($grid.Rows | Where-Object {$_.Cells['context'].Value -like '*보관됨*'}).Count -eq 1) 'archived metadata must appear'
    $contexts=@{}; foreach ($row in $grid.Rows) { $contexts[[string]$row.Tag.title]=[string]$row.Cells['context'].Value }
    Assert ($contexts['로컬'] -like '*paginated · 하위 2*' -and $contexts['다른 PC 갈래 A'] -like '*paginated · 하위 1' -and $contexts['다른 PC 갈래 B'] -like '*paginated · 이전 형식' -and $contexts['미확인 공유 백업'] -notlike '*형식*') "subagent counts and older backups are shown: $($contexts.Values -join ' | ')"
    Assert ($grid.SelectedRows.Count -eq 0 -and -not $restoreButton.Enabled) 'list cannot automatically select a row'
    $localRow=@($grid.Rows | Where-Object {$_.Tag.local})[0]
    $blockedRow=@($grid.Rows | Where-Object {$_.Tag.blockedReason})[0]
    $remoteRows=@($grid.Rows | Where-Object {$_.Tag.remoteId -in @($a,$b)})
    $localRow.Selected=$true
    Assert ($backupButton.Enabled -and -not $openButton.Enabled -and -not $restoreButton.Enabled) 'local Desktop row exports but never starts native CLI'
    $grid.ClearSelection(); $blockedRow.Selected=$true
    Assert (-not $backupButton.Enabled -and -not $restoreButton.Enabled) 'invalid metadata row is visible with actions blocked'
    $grid.ClearSelection(); foreach($row in $remoteRows){$row.Selected=$true}
    Assert ($restoreButton.Enabled -and -not $backupButton.Enabled) 'selected shared backups allow multi-preview only'
    Start-DesktopPreview
    Assert ($script:StartedJobs.Count -eq 1 -and $script:StartedJobs[0].action -eq 'Preview' -and $script:DesktopPreviewQueue.Count -eq 1) 'batch starts inspections sequentially without applying'
    Assert ($script:StartedJobs[0].home -eq $desktopHome.Text -and $script:StartedJobs[0].projectPath -eq $project.Text) 'job pins selected home and target'
    $reviews=@()
    foreach($state in @('new','incoming_newer','local_newer','conflict','blocked','equal')) {
        $job=@{action='Preview';agent='codex-desktop';nativeId=$(if($state -eq 'conflict'){$id}else{[guid]::NewGuid().ToString()});remoteId=$a;title="합성 $state";sourceCwd='D:\원본';projectPath='D:\이 PC';home='D:\데이터'}
        $reviews+=[pscustomobject]@{job=$job;receipt='fixture-inspect.json';preview=[pscustomobject]@{status=$state;reason=$(if($state -eq 'blocked'){'archive_corrupt / schema_mismatch'}else{'fixture comparison'});token="pinned-$state";source=@{};target=@{}}}
    }
    $ui=New-DesktopReviewDialog $reviews
    Assert ($ui.table.Rows.Count -eq 6) 'one popup includes all statuses and abnormal items'
    Assert (@($ui.table.Rows | Where-Object {$_.Cells['choice'].Value -ne '건너뛰기'}).Count -eq 0) 'every row defaults to skip, including new and incoming newer'
    Assert (@(Get-DesktopDecisions $ui.table).Count -eq 0) 'default choices never apply'
    $blockedChoice=$ui.table.Rows[4].Cells['choice']
    Assert (-not $blockedChoice.Items.Contains('공유 백업 복원')) 'blocked archive has no incoming option'
    $ui.table.Rows[3].Cells['choice'].Value='공유 백업 복원'
    $selected=@(Get-DesktopDecisions $ui.table)
    Assert ($selected.Count -eq 1 -and $selected[0].token -ceq 'pinned-conflict' -and $selected[0].receipt -eq 'fixture-inspect.json') 'explicit incoming binds original inspection token and receipt'
    $ui.table.Rows[3].Cells['choice'].Value='로컬 유지'
    Assert (@(Get-DesktopDecisions $ui.table).Count -eq 0) 'local keep performs no write'
    Assert (@($ui.table.Columns | Where-Object {$_.Name -in @('updated','date','timestamp')}).Count -eq 0) 'comparison dialog must not choose based on timestamps'
    $ui.dialog.Show(); [Windows.Forms.Application]::DoEvents()
    $picture=[Drawing.Bitmap]::new($ui.dialog.Width,$ui.dialog.Height)
    try {$ui.dialog.DrawToBitmap($picture,[Drawing.Rectangle]::new(0,0,$ui.dialog.Width,$ui.dialog.Height));$picture.Save((Join-Path $PSScriptRoot 'gui-desktop-conflicts-preview.png'),[Drawing.Imaging.ImageFormat]::Png)} finally {$picture.Dispose()}
    $ui.dialog.Close(); $ui.dialog.Dispose()
    $same=@($reviews[3], [pscustomobject]@{job=$reviews[3].job.Clone();receipt='second-inspect.json';preview=[pscustomobject]@{status='conflict';reason='same UUID second branch';token='other-pinned-token';source=@{};target=@{}}})
    $same[1].job.remoteId=$b
    $duplicate=New-DesktopReviewDialog $same
    Assert (@(Get-DesktopDecisions $duplicate.table).Count -eq 0) 'both same-UUID branches begin skip'
    foreach($row in $duplicate.table.Rows){$row.Cells['choice'].Value='공유 백업 복원'}
    Throws {Get-DesktopDecisions $duplicate.table} '같은 UUID'
    $duplicate.table.Rows[0].Cells['choice'].Value='로컬 유지'
    $one=@(Get-DesktopDecisions $duplicate.table)
    Assert ($one.Count -eq 1 -and $one[0].remoteId -ceq $b -and $one[0].token -ceq 'other-pinned-token') 'user explicitly chooses one branch regardless of displayed dates'
    $duplicate.dialog.Dispose()
    $script:Pending=$null
    $request=Join-Path $testDirectory 'request.json'; $result=Join-Path $testDirectory 'result.json'
    [IO.File]::WriteAllText($request,'{}')
    @{ok=$false;error='app_running: Codex 앱을 직접 종료하세요';backendResult=@{journal='fixture/recovery/pending.json';recoveryRequired=$true}} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $result -Encoding UTF8
    $process=[pscustomobject]@{HasExited=$true}; $process|Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    $script:Pending=@{process=$process;request=$request;result=$result;job=@{agent='codex-desktop';action='Restore'}}
    $script:DesktopApplyQueue=@(@{action='Restore'})
    Finish-Job
    Assert ($script:Errors.Count -eq 1 -and $script:Errors[0] -like '*pending.json*') 'apply failure displays original backend recovery journal'
    Assert ($script:DesktopApplyQueue.Count -eq 0 -and $null -eq $script:Pending) 'failed apply stops all remaining writes'
    Assert (-not (Test-Path -LiteralPath $request)) 'job JSON is removed after handling'
    function Continue-DesktopPreview {$script:ContinueCalled=$true}
    [IO.File]::WriteAllText($request,'{}')
    @{ok=$false;error='schema mismatch'} | ConvertTo-Json | Set-Content -LiteralPath $result -Encoding UTF8
    $script:DesktopReviews=@(); $script:Pending=@{process=$process;request=$request;result=$result;job=@{agent='codex-desktop';action='Preview';nativeId=$id;remoteId=$a;title='손상 백업'}}
    Finish-Job
    Assert ($script:ContinueCalled -and $script:DesktopReviews.Count -eq 1 -and $script:DesktopReviews[0].preview.status -eq 'blocked') 'failed inspect joins abnormal-items table without aborting batch'
    # 이 프로젝트만: \\?\·대소문자·끝의 \는 무시하고 하위 폴더는 포함한다. 이름만 같은 폴더는 공유 백업일 때만 넣는다.
    function Row([string]$Id,[string]$Cwd,[bool]$Local,[string]$Updated,[string]$Remote='',[string]$Blocked='',[object]$Children=0) {
        [pscustomobject]@{agent='codex-desktop';nativeId=$Id;remoteId=$Remote;title="합성 $Id";updatedAt=$Updated;local=$Local;recordCount=$(if($Local){0}else{3});sourceCwd=$Cwd;historyMode='paginated';archived=$false;children=$Children;blockedReason=$(if($Blocked){$Blocked}else{$null})}
    }
    function Finish-Fake([hashtable]$Job,[object]$Outcome) {
        [IO.File]::WriteAllText($request,'{}')
        if ($null -ne $Outcome) { $Outcome | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $result -Encoding UTF8 } elseif (Test-Path -LiteralPath $result) { Remove-Item -LiteralPath $result }
        $script:Pending=@{process=$process;request=$request;result=$result;job=$Job}
        Finish-Job
    }
    $ids=@(1..9 | ForEach-Object { '{0}0000000-0000-4000-8000-000000000000' -f $_ })
    $t1='2026-09-26T01:00:00Z'; $t0='2026-09-20T01:00:00Z'
    $rows=@(
        (Row $ids[0] '\\?\D:\codex\AI논문' $true $t1), (Row $ids[0] 'D:\codex\AI논문' $false $t1 ('p/'+'1'*32)),
        (Row $ids[1] '\\?\d:\CODEX\ai논문\sub\' $true $t1), (Row $ids[1] 'C:\Users\me\codex\AI논문' $false $t0 ('p/'+'2'*32)),
        (Row $ids[2] 'D:\codex\AI논문2' $true $t1), (Row $ids[3] 'E:\AI논문' $true $t1),
        (Row $ids[4] 'D:\codex\AI논문' $true $t1 '' '합성 차단'), (Row $ids[5] 'D:\codex\AI논문' $true $t1),
        (Row $ids[5] 'D:\codex\AI논문' $false $t1 ('p/'+'6'*32) '' $null), (Row $ids[7] '' $true $t1),
        (Row $ids[6] 'C:\Users\me\codex\다른' $false $t1 ('p/'+'7'*32)),
        [pscustomobject]@{agent='codex-desktop';nativeId='';remoteId='bad';title='미확인';updatedAt='';local=$false;recordCount=0;blockedReason='metadata invalid'}
    )
    $project.Text='D:\codex\AI논문'; $projectOnly.Checked=$true
    Fill-Sessions $rows
    $shown=@($script:Filtered | ForEach-Object { if ($_.nativeId) { "$($_.nativeId.Substring(0,1))$(if($_.local){'L'}else{'R'})" } else { 'bad' } } | Sort-Object) -join ','
    Assert ($shown -eq '1L,1R,2L,2R,5L,6L,6R,bad') "project filter keeps the folder, its subfolders and same-name shared backups, and hides local rows without a folder: $shown"
    $projectOnly.Checked=$false
    Assert ($script:Filtered.Count -eq 12) 'clearing This project only shows every project'
    $projectOnly.Checked=$true
    # 전체 백업: 필터된 이 PC 대화 중 같은 UUID·같은 수정 시각의 묶음 형식 공유 백업이 없는 것만 차례로 올린다(6은 이전 형식 백업만 있음).
    $script:StartedJobs=@(); $script:Errors=@(); $script:Asked=''
    function Confirm([string]$Message) { $script:Asked=$Message; return $true }
    $bulkButton.PerformClick()
    $queued=@($script:Bulk.items | ForEach-Object { $_.nativeId.Substring(0,1) } | Sort-Object) -join ','
    Assert ($queued -eq '2,6' -and $script:StartedJobs.Count -eq 1 -and $script:StartedJobs[0].action -eq 'Backup' -and $script:StartedJobs[0].remoteId -eq '') "bulk skips up-to-date, blocked and out-of-project rows: $queued"
    Assert ($script:Asked -like '*대화 2개*' -and $script:Asked -like '*이미 있는 1개와 백업할 수 없는 1개*') "bulk asks with the counts first: $script:Asked"
    Assert ($script:StartedJobs[0].home -eq $desktopHome.Text) 'bulk jobs pin the Codex data folder'
    Finish-Fake $script:StartedJobs[0] @{ok=$true;data=@{message='합성 백업 완료'}}
    Assert ($script:StartedJobs.Count -eq 2 -and $script:StartedJobs[1].nativeId -ne $script:StartedJobs[0].nativeId) 'next conversation starts after one finishes'
    Finish-Fake $script:StartedJobs[1] @{ok=$false;error='합성 실패 이유'}
    Assert ($null -eq $script:Bulk -and $script:Errors.Count -eq 1 -and $script:Errors[0] -like '*성공 1 · 건너뜀 2 · 실패 1 · 하지 않음 0*' -and $script:Errors[0] -like '*합성 실패 이유*') "failures are summarized once at the end: $($script:Errors -join '|')"
    Assert ($script:StartedJobs.Count -eq 3 -and $script:StartedJobs[2].action -eq 'List') 'the list reloads so new backups count as up to date'
    Finish-Fake $script:StartedJobs[2] @{ok=$true;data=@{sessions=@();excluded=0;message='합성 목록'}}
    Assert ($status.Text -like '전체 백업 끝*' -and -not $script:BulkSummary) 'summary stays visible after the reload'
    # 같은 이유로 연속 3번 실패하면(예: 앱이 켜져 있음) 남은 대화를 시도하지 않는다. 성공이 없으면 목록도 다시 불러오지 않는다.
    Fill-Sessions @(foreach ($n in 0..4) { Row $ids[$n] 'D:\codex\AI논문' $true $t1 })
    $script:StartedJobs=@(); $script:Errors=@()
    Start-BulkBackup
    foreach ($n in 0..2) { Finish-Fake $script:StartedJobs[$n] @{ok=$false;error='Codex 앱을 종료하세요'} }
    Assert ($null -eq $script:Bulk -and $script:StartedJobs.Count -eq 3 -and $script:Errors.Count -eq 1 -and $script:Errors[0] -like '*실패 3 · 하지 않음 2*연속 3개*') "three failures in a row stop the run: $($script:Errors -join '|')"
    # 작업 창이 결과 없이 끝난 경우도 실패 한 건으로 세고 이어 간다.
    Fill-Sessions @(foreach ($n in 0..1) { Row $ids[$n] 'D:\codex\AI논문' $true $t1 })
    $script:StartedJobs=@(); $script:Errors=@()
    Start-BulkBackup
    Finish-Fake $script:StartedJobs[0] $null
    Assert ($script:StartedJobs.Count -eq 2 -and $script:Bulk.failed.Count -eq 1) 'a worker without a result counts as one failure and the run goes on'
    Finish-Fake $script:StartedJobs[1] @{ok=$true;data=@{message='합성 백업 완료'}}
    # 작업 취소를 처음 누르면 작업 창을 끝내지 않고 지금 대화를 마친 뒤 멈춘다.
    Fill-Sessions @(foreach ($n in 0..2) { Row $ids[$n] 'D:\codex\AI논문' $true $t1 })
    $script:StartedJobs=@(); $script:Errors=@(); $script:Killed=@()
    Start-BulkBackup
    & {
        function Stop-ProcessTree([int]$Id) { $script:Killed+=,$Id }
        # 없는 PID를 줘서 종료 경로로 잘못 들어가도 실제 프로세스를 건드리지 않게 한다.
        $script:Pending=@{process=[pscustomobject]@{HasExited=$false;Id=2147483000};request=$request;result=$result;job=$script:StartedJobs[0]}
        $cancelButton.Enabled=$true; $cancelButton.PerformClick()
    }
    Assert ($script:Bulk.stop -and -not $script:Killed.Count -and $status.Text -like '*지금 대화를 마친 뒤*') 'first cancel lets the current conversation finish'
    Finish-Fake $script:StartedJobs[0] @{ok=$true;data=@{message='합성 백업 완료'}}
    Assert ($null -eq $script:Bulk -and $script:StartedJobs.Count -eq 2 -and $script:StartedJobs[1].action -eq 'List' -and $status.Text -like '*성공 1 · 건너뜀 0 · 실패 0 · 하지 않음 2*취소해서*') "cancel stops before the next conversation: $($status.Text)"
    # 두 번째 취소는 확인 뒤 이 작업 창만 끝내고, 전체 백업은 목록을 다시 읽지 않고 요약만 남긴다(끊긴 대화는 하지 않음).
    Fill-Sessions @(foreach ($n in 0..2) { Row $ids[$n] 'D:\codex\AI논문' $true $t1 })
    $script:StartedJobs=@(); $script:Errors=@(); $script:Killed=@()
    Start-BulkBackup
    $worker=[pscustomobject]@{HasExited=$false;Id=2147483000}; $worker|Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    & {
        function Stop-ProcessTree([int]$Id) { $script:Killed+=,$Id }
        [IO.File]::WriteAllText($request,'{}')
        $script:Pending=@{process=$worker;request=$request;result=$result;job=$script:StartedJobs[0]}
        $cancelButton.Enabled=$true; $cancelButton.PerformClick()
        Assert ($script:Bulk.stop -and -not $script:Killed.Count -and -not $script:Pending.cancelled) 'first cancel only marks the run to stop'
        $cancelButton.Enabled=$true; $cancelButton.PerformClick()
    }
    Assert ($script:Killed -join ',' -eq '2147483000' -and $script:Pending.cancelled) 'second cancel stops only this worker after confirmation'
    $worker.HasExited=$true; Finish-Job
    Assert ($null -eq $script:Bulk -and $null -eq $script:Pending -and $script:StartedJobs.Count -eq 1 -and $status.Text -like '*성공 0 · 건너뜀 0 · 실패 0 · 하지 않음 3*취소해서*') "second cancel ends the run without a reload: $($status.Text)"
    # 전체 백업 뒤 목록 다시 읽기가 실패하거나 취소되면 요약을 지워 다음 목록에 남지 않게 한다.
    foreach ($outcome in @(@{ok=$false;error='합성 목록 실패'},'cancel')) {
        $script:BulkSummary='전체 백업 끝: 합성'
        if ($outcome -eq 'cancel') { [IO.File]::WriteAllText($request,'{}'); $script:Pending=@{process=$process;request=$request;result=$result;job=@{agent='codex-desktop';action='List'};cancelled=$true}; Finish-Job }
        else { Finish-Fake @{agent='codex-desktop';action='List'} $outcome }
        Assert (-not $script:BulkSummary -and $status.Text -notlike '전체 백업 끝*') "a failed or cancelled reload drops the bulk summary: $($status.Text)"
    }
    $script:Pending=$null
    # 작업 취소는 GUI가 띄운 작업 창과 그 하위 프로세스만 끝낸다. 이름으로 찾아 끄지 않으므로 Codex·Claude 앱은 건드리지 않는다.
    Assert ($source -notmatch 'Stop-Process\s+-Name|Get-Process|\.Kill\(|taskkill') 'GUI never kills processes by name, so the Codex and Claude apps are never force-closed'
    Assert ([regex]::Matches($source,'Stop-Process ').Count -eq 1 -and [regex]::Matches($source,'Stop-ProcessTree \$pending\.process\.Id').Count -eq 1 -and $source -match "action -in @\('Restore','Open'\)\) \{ return \}") 'GUI stops only the worker tree it started, and never during Restore or Open'
    # 부모보다 먼저 생긴 "자식"은 끝난 프로세스의 PID를 물려받은 다른 프로그램(예: 런처가 띄운 앱)이므로 끝내지 않는다. 부모부터 끝낸다.
    $stopped = & {
        function Get-CimInstance {
            $at={ param($second) [datetime]::new(2026,1,1,0,0,$second) }
            @([pscustomobject]@{ProcessId=10;ParentProcessId=1;CreationDate=(& $at 10)},
              [pscustomobject]@{ProcessId=11;ParentProcessId=10;CreationDate=(& $at 11)},
              [pscustomobject]@{ProcessId=12;ParentProcessId=11;CreationDate=(& $at 12)},
              [pscustomobject]@{ProcessId=13;ParentProcessId=11;CreationDate=(& $at 9)},
              [pscustomobject]@{ProcessId=5;ParentProcessId=10;CreationDate=(& $at 5)},
              [pscustomobject]@{ProcessId=6;ParentProcessId=5;CreationDate=(& $at 6)})
        }
        $calls=[Collections.Generic.List[int]]::new()
        function Stop-Process([int]$Id,[switch]$Force,$ErrorAction) { $calls.Add($Id) }
        Stop-ProcessTree 10
        $calls -join ','
    }
    Assert ($stopped -eq '10,11,12') "cancel stops the worker first, then only children created after their parent: $stopped"
    Assert (-not (Test-Path -LiteralPath (Join-Path $testDirectory 'CtxHopGUI\vnext-preferences.json'))) 'isolated GUI tests never save user preferences'
    Write-Output "PASS: $script:Checks isolated Desktop GUI assertions. No native apps or user stores invoked."
} finally {
    $script:SmokeTest=$true; $script:Pending=$null
    if($timer){$timer.Dispose()}; if($filterTimer){$filterTimer.Dispose()}; if($form){$form.Close();$form.Dispose()}
    $env:LOCALAPPDATA=$oldLocal; $env:CTXHOP_CONFIG_DIR=$oldConfig
    $resolved=[IO.Path]::GetFullPath($testDirectory); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^CtxHop-vnext-gui-[a-f0-9]{32}$') { throw 'Refusing cleanup outside fixture directory' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
