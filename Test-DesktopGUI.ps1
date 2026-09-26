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
    . $fixture -SmokeTest
    $timer.Stop(); $filterTimer.Stop()
    function Show-Error([string]$Message) {$script:Errors+=,$Message; $status.Text=$Message}
    function Start-Job([hashtable]$Job) {$script:StartedJobs+=,$Job.Clone()}
    $agent.SelectedIndex=1; $project.Text='D:\합성 대상'; $desktopHome.Text='D:\합성 데이터'
    $id='11111111-1111-4111-8111-111111111111'; $a='peer-a/'+('a'*32); $b='peer-b/'+('b'*32)
    $sessions=@(
        [pscustomobject]@{agent='codex-desktop';nativeId=$id;remoteId='';title='로컬';updatedAt='2026-09-26T01:00:00Z';local=$true;recordCount=0;sourceCwd='D:\other';historyMode='paginated';archived=$true},
        [pscustomobject]@{agent='codex-desktop';nativeId=$id;remoteId=$a;title='다른 PC 갈래 A';updatedAt='2099-09-26T01:00:00Z';local=$false;recordCount=3;sourceCwd='D:\source-A';historyMode='paginated';archived=$false},
        [pscustomobject]@{agent='codex-desktop';nativeId=$id;remoteId=$b;title='다른 PC 갈래 B';updatedAt='1990-09-26T01:00:00Z';local=$false;recordCount=3;sourceCwd='D:\source-B';historyMode='paginated';archived=$false},
        [pscustomobject]@{agent='codex-desktop';nativeId='';remoteId='invalid';title='미확인 공유 백업';updatedAt='';local=$false;recordCount=0;blockedReason='metadata invalid'}
    )
    Fill-Sessions $sessions
    Assert ($grid.MultiSelect -and $grid.Rows.Count -eq 4) 'Desktop allows multiple explicit rows; identical UUID branches stay separate'
    Assert (@($grid.Rows | Where-Object {$_.Cells['context'].Value -like '*보관됨*'}).Count -eq 1) 'archived metadata must appear'
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
    Assert ($source -notmatch 'Stop-Process|\.Kill\(') 'GUI never forcibly kills Codex or helper processes'
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
