#requires -Version 5.1
[CmdletBinding()]
param([string]$ScreenshotPath)
$ErrorActionPreference = 'Stop'
$testRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ScreenshotPath) { $ScreenshotPath = Join-Path $testRoot 'gui-settings-preview.png' }
$script:FixtureScreenshotPath = $ScreenshotPath
$source = [IO.File]::ReadAllText((Join-Path $testRoot 'GUI.ps1'), [Text.Encoding]::UTF8)
$tail = $source.LastIndexOf('if ($SmokeTest) {')
if ($tail -lt 0) { throw 'GUI smoke-test entry point is missing.' }
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('CtxHop GUI 한글 fixture ' + [guid]::NewGuid().ToString('N'))
$previousLocalAppData = $env:LOCALAPPDATA
$previousConfigDir = $env:CTXHOP_CONFIG_DIR
$script:OriginalSavePrefs = $null
$script:Errors = @()
$script:Answers = @()
$script:Launches = @()
$script:Checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:Checks++
}
function Set-Fixtures {
    Fill-Sessions @(
        [pscustomobject]@{title="로그인 오류`n수정"; agent='claude-code'; updatedAt='2026-09-26 14:10'; local=$true; recordCount=24; nativeId='11111111-1111-4111-8111-111111111111';remoteId=('a'*64)},
        [pscustomobject]@{title='API 응답 검증'; agent='claude-code'; updatedAt='2026-09-25 18:42'; local=$false; recordCount=18; nativeId='22222222-2222-4222-8222-222222222222';remoteId=('b'*64)}
    )
    $grid.ClearSelection()
    $grid.Rows[0].Selected = $true
}
function Finish-Fixture {
    Assert ($null -ne $script:Pending) 'Fixture worker should have started.'
    Assert ($script:Pending.process.WaitForExit(10000)) 'Fixture worker timed out.'
    Finish-Job
}
function Wait-Filter {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($filterTimer.Enabled -and $watch.ElapsedMilliseconds -lt 1500) {
        [Windows.Forms.Application]::DoEvents()
        [Threading.Thread]::Sleep(10)
    }
    Assert (-not $filterTimer.Enabled) 'Search debounce should finish.'
}
try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $env:LOCALAPPDATA = $fixtureRoot
    $env:CTXHOP_CONFIG_DIR = $fixtureRoot
    @{projects=@{bindings=@(@{identity='fixture-one';localRoot='D:\fixture one'},@{identity='fixture-two';localRoot='D:\fixture two'})}} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $fixtureRoot 'config.json') -Encoding UTF8
    $fixturePrefsDir = Join-Path $fixtureRoot 'CtxHopGUI'
    New-Item -ItemType Directory -Path $fixturePrefsDir | Out-Null
    $fixturePrefsFile = Join-Path $fixturePrefsDir 'vnext-preferences.json'
    [IO.File]::WriteAllText($fixturePrefsFile,'{"agent":"codex-desktop","store":17}',[Text.UTF8Encoding]::new($true))
    $fixturePrefsBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixturePrefsFile))
    $fixtureGuiPath = Join-Path $fixtureRoot 'GUI fixture.ps1'
    [IO.File]::WriteAllText($fixtureGuiPath,$source.Substring(0,$tail),[Text.UTF8Encoding]::new($true))
    Copy-Item -LiteralPath (Join-Path $testRoot 'Strings.ps1') -Destination $fixtureRoot
    . $fixtureGuiPath -SmokeTest
    $timer.Stop()
    Assert ($agent.SelectedIndex -eq 1 -and $script:Prefs.PSObject.Properties.Name -contains 'identity' -and $script:Prefs.store -eq 'G:\내 드라이브\세션연동') 'Partial preferences should preserve defaults and reject non-string fields.'
    $script:OriginalSavePrefs = ${function:Save-Prefs}
    function Save-Prefs {
        $before = $script:SmokeTest
        $script:SmokeTest = $true
        try { & $script:OriginalSavePrefs } finally { $script:SmokeTest = $before }
    }
    function Show-Error([string]$Message) {
        $script:Errors += $Message
        $status.Text = $Message
        $log.AppendText("`r`n오류: $Message`r`n")
    }
    function Confirm([string]$Message) {
        Assert ($script:Answers.Count -gt 0) 'Unexpected confirmation dialog.'
        $script:LastConfirm = $Message
        $answer = $script:Answers[0]
        $script:Answers = @($script:Answers | Select-Object -Skip 1)
        # 확인 창이 떠 있는 동안 일어나는 일은 스크립트 블록 답으로 흉내 낸다.
        if ($answer -is [scriptblock]) { return (& $answer) }
        return $answer
    }
    $stubPath = Join-Path $fixtureRoot 'Worker.ps1'
    $stub = @'
param([string]$RequestFile,[string]$ResultFile)
$ErrorActionPreference='Stop'
$job=Get-Content -LiteralPath $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($job.fixtureDelay) { Start-Sleep -Milliseconds $job.fixtureDelay }
$data=@{message=('fixture: ' + $job.action)}
if ($job.action -eq 'List') {
    $data.sessions=@([pscustomobject]@{title='fixture';agent=$job.agent;updatedAt='fixture';local=$true;recordCount=1;nativeId='33333333-3333-4333-8333-333333333333';remoteId=('c'*64)})
}
if ($job.action -eq 'Preview') {
    $data.preview=@{session=$job.nativeId;agent=$job.agent;workspace=$job.projectPath;differences='fixture'}
}
if ($job.action -eq 'Restore') { $data.restored=@{session=$job.nativeId;agent=$job.agent} }
@{ok=$true;data=$data}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $ResultFile -Encoding UTF8
'@
    [IO.File]::WriteAllText($stubPath,$stub,[Text.UTF8Encoding]::new($true))
    function Start-Process {
        param([string]$FilePath,[string]$ArgumentList,[switch]$PassThru,[string]$WindowStyle)
        Assert ($ArgumentList -match '-File "[^"]+Worker\.ps1" -RequestFile "[^"]+" -ResultFile "[^"]+"') 'Worker paths must be quoted.'
        Assert ($ArgumentList -like '*-ExecutionPolicy RemoteSigned*') 'Worker policy must be limited to the process and match the launcher.'
        $script:Launches += $ArgumentList
        Assert ($ArgumentList.Contains($stubPath)) 'Only the fixture Worker may be launched.'
        Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden
    }
    $agent.SelectedIndex = 0
    $project.Text = 'D:\fixture 한글 프로젝트'
    $identity.Text = 'fixture-shared-name'
    Set-Fixtures
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    Assert ($grid.Rows.Count -eq 2) 'Two fixture session rows should render.'
    Assert ($grid.Rows[0].Cells[0].Value -eq '로그인 오류 수정') 'Control characters should be removed from the title.'
    Assert ($projectPicker.Items.Count -eq 2) 'Registered projects should load from the isolated fixture configuration.'
    $job = Selected-Job 'Backup'
    Assert ($job.nativeId -eq '11111111-1111-4111-8111-111111111111' -and $job.remoteId -eq ('a'*64)) 'Selected row must preserve both session identifiers.'
    Assert ($job.projectPath -eq $project.Text -and $job.identity -eq $identity.Text) 'Selected job should preserve project fields.'
    Apply-Filter
    Assert ($grid.SelectedRows.Count -eq 1 -and $grid.SelectedRows[0].Tag.nativeId -eq $job.nativeId) 'Filtering should preserve an explicitly selected visible session.'
    # Claude Code 백업은 Codex Desktop과 달리 계속 에이전트 종료를 확인한다(취소로 답해 작업은 띄우지 않는다).
    $script:Answers = @($false); $launchesBefore = @($script:Launches).Count
    $script:SessionButtons[0].PerformClick()
    Assert ($script:LastConfirm -like '*종료했나요*' -and $script:Answers.Count -eq 0 -and @($script:Launches).Count -eq $launchesBefore) "A Claude Code backup still asks whether the agent was quit: $script:LastConfirm"
    $grid.ClearSelection()
    $grid.Rows[1].Selected = $true
    Assert (-not $script:SessionButtons[0].Enabled -and $script:SessionButtons[1].Enabled -and -not $script:SessionButtons[2].Enabled) 'A remote-only session should allow restore but disable local backup and open.'
    $grid.ClearSelection()
    $selectionFailed = $false
    try { $null = Selected-Job 'Backup' } catch { $selectionFailed = $_.Exception.Message -like '*선택*' }
    Assert $selectionFailed 'No selection must be rejected before launching.'
    Set-Fixtures
    $agent.SelectedIndex = 1
    Assert ($grid.Rows.Count -eq 0) 'Agent change should clear stale rows.'
    $agent.SelectedIndex = 0
    Set-Fixtures
    $project.Text += ' changed'
    Assert ($grid.Rows.Count -eq 0) 'Project change should clear stale rows.'
    Set-Fixtures
    $identity.Text += '-changed'
    Assert ($grid.Rows.Count -eq 0) 'Identity change should clear stale rows.'
    Set-Fixtures
    Write-Output ('Columns: ' + (($grid.Columns | ForEach-Object { '{0}={1}px/weight{2}' -f $_.HeaderText,$_.Width,$_.FillWeight }) -join '; '))
    Write-Output "Layout: form=$($form.ClientSize); tabs=$($tabs.Size); main=$($main.ClientSize); grid=$($grid.Size); autoscale=$($form.AutoScaleMode)/$($form.AutoScaleDimensions)"
    $initialClientSize = $form.ClientSize
    $initialGridHeight = $grid.Height
    $backupButton = $script:Buttons | Where-Object Text -eq '선택한 대화 백업'
    Assert ($grid.Right -le $main.ClientSize.Width -and $grid.Bottom -lt $backupButton.Top) 'Grid must fit inside the tab without covering the actions.'
    $form.ClientSize = [Drawing.Size]::new(1280,930)
    [Windows.Forms.Application]::DoEvents()
    Write-Output "Resize: gridBottom=$($grid.Bottom); actionTop=$($backupButton.Top); gridInsideTab=$($grid.Right -le $main.ClientSize.Width); overlap=$($grid.Bottom -gt $backupButton.Top)"
    Assert ($grid.Height -gt $initialGridHeight -and $grid.Right -le $main.ClientSize.Width -and $grid.Bottom -lt $backupButton.Top) 'A larger window must enlarge the grid inside the tab without covering the actions.'
    $form.Size = $form.MinimumSize
    [Windows.Forms.Application]::DoEvents()
    Write-Output "Minimum: form=$($form.Size); gridHeight=$($grid.Height); actionBottom=$($backupButton.Bottom); tabHeight=$($main.ClientSize.Height)"
    Assert ($grid.Height -ge 60 -and $grid.Bottom -lt $backupButton.Top -and $backupButton.Bottom -le $main.ClientSize.Height) 'The minimum window must keep the grid and actions visible.'
    $form.ClientSize = $initialClientSize
    [Windows.Forms.Application]::DoEvents()
    Assert ($grid.Height -eq $initialGridHeight -and $grid.Bottom -lt $backupButton.Top) 'Restoring the size must restore the layout.'
    Assert ($form.FormBorderStyle -eq 'Sizable' -and $form.MinimumSize.Height -le 675) 'The window must be resizable down to small laptop work areas.'
    $fixtureNow = Get-Date
    $large = @(for ($i=1; $i -le 5000; $i++) {
        [pscustomobject]@{
            title=if ($i%10 -eq 0) {"로그인 오류 $i"} else {"task $i"}
            agent='claude-code';updatedAt=$fixtureNow.AddDays(-($i%60)).AddHours(-1).ToString('o')
            local=($i%2 -eq 0);recordCount=if ($i%3 -eq 0) {1} else {0}
            nativeId=('00000000-0000-4000-8000-{0:d12}' -f $i);remoteId=('{0:x64}' -f $i)
        }
    })
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Fill-Sessions $large
    $watch.Stop()
    Write-Output "5000-session initial filter/render: $($watch.ElapsedMilliseconds)ms"
    Assert ($script:Sessions.Count -eq 5000 -and $script:Filtered.Count -eq 5000 -and $grid.Rows.Count -eq 200) '5000 sessions must keep the full cache and render only 200 rows.'
    Assert ($script:Page -eq 0 -and $countLabel.Text -like '*1/25') 'Initial pagination should show page 1 of 25.'
    Assert (-not $prevButton.Enabled -and $nextButton.Enabled) 'The first of several pages must allow only Next.'
    Assert ($grid.SelectedRows.Count -eq 0 -and -not ($script:SessionButtons | Where-Object Enabled)) 'Loading must require explicit selection.'
    ($script:Buttons | Where-Object Text -eq '다음').PerformClick()
    Assert ($script:Page -eq 1 -and $grid.Rows[0].Tag.nativeId -eq $script:Filtered[200].nativeId) 'Next page must render the next 200 metadata records.'
    ($script:Buttons | Where-Object Text -eq '이전').PerformClick()
    Assert ($script:Page -eq 0) 'Previous page should return to the first page.'
    $script:Page = 24
    Apply-Filter
    Assert ($prevButton.Enabled -and -not $nextButton.Enabled) 'The last page must allow only Previous.'
    ($script:Buttons | Where-Object Text -eq '다음').PerformClick()
    Assert ($script:Page -eq 24 -and $grid.Rows.Count -eq 200) 'Next at the final page must stay within bounds.'
    $search.Text = '로그인'
    Wait-Filter
    Assert ($script:Filtered.Count -eq 500 -and $script:Page -eq 0) 'Debounced title search should find 500 records and reset the page.'
    $search.Text = 'TASK'
    Wait-Filter
    Assert ($script:Filtered.Count -eq 4500) 'Search should ignore title casing.'
    $search.Text = '000000004321'
    Wait-Filter
    Assert ($script:Filtered.Count -eq 1 -and $grid.Rows[0].Tag.nativeId -like '*000000004321') 'Native session ID search must find the exact fixture.'
    Assert (-not $prevButton.Enabled -and -not $nextButton.Enabled) 'A single page must disable both page buttons.'
    $search.Text = ''
    Wait-Filter
    $view.SelectedIndex = 1
    Assert ($script:Filtered.Count -eq 2500) 'Local filter should find 2500 local records.'
    $view.SelectedIndex = 2
    Assert ($script:Filtered.Count -eq 1666) 'Shared filter should find 1666 backed-up records.'
    $view.SelectedIndex = 0
    $dateFilter.SelectedIndex = 1
    Assert ($script:Filtered.Count -eq 587) 'Recent seven days should exclude sessions older than seven days.'
    $dateFilter.SelectedIndex = 2
    Assert ($script:Filtered.Count -eq 2510) 'Recent thirty days should find the expected fixture age groups.'
    $dateFilter.SelectedIndex = 0
    $search.Text = 'no matching fixture'
    Wait-Filter
    Assert ($grid.Rows.Count -eq 0 -and $script:Sessions.Count -eq 5000) 'Empty search results must retain the full metadata cache.'
    $projectPicker.SelectedIndex = 1
    Assert ($project.Text -eq 'D:\fixture two' -and $identity.Text -eq 'fixture-two') 'Project picker must apply the registered local path and common identity.'
    Assert ($script:Sessions.Count -eq 0) 'Project changes must clear cached sessions even when no rows are visible.'
    $search.Text = ''
    Wait-Filter
    Assert ($grid.Rows.Count -eq 0) 'Clearing search after a project change must not reveal the old project sessions.'
    Set-Fixtures
    # 저장소에 올리는 미리보기에 실제 PC 이름과 사용자 폴더가 찍히지 않게 한다.
    $device.Text = 'PC-A'; $desktopHome.Text = 'C:\Users\me\.codex'
    $tabs.SelectedTab = $settings
    [Windows.Forms.Application]::DoEvents()
    $bitmap = [Drawing.Bitmap]::new($form.Width,$form.Height)
    try {
        $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height))
        $bitmap.Save($script:FixtureScreenshotPath,[Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }
    $tabs.SelectedTab = $main
    $script:SmokeTest = $false
    ($script:Buttons | Where-Object Text -eq '대화 목록 불러오기').PerformClick()
    Assert ($null -ne $script:Pending -and -not $agent.Enabled -and $project.ReadOnly) 'List click must launch a worker and lock the form.'
    Assert (-not $projectPicker.Enabled) 'The project picker must be locked while a worker is pending.'
    Assert (-not ($script:Buttons | Where-Object { $_.Enabled -and $_ -ne $cancelButton }) -and $cancelButton.Enabled) 'Only the List cancel button may be enabled while listing.'
    $requestPath = $script:Pending.request
    $request = Get-Content -LiteralPath $requestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($request.action -eq 'List' -and $request.projectPath -eq $project.Text) 'Request JSON must match the clicked action and project.'
    $form.Close()
    Assert (-not $form.IsDisposed -and $script:Errors.Count -eq 1 -and $script:Errors[0] -like '*끝난 뒤*') 'Closing during a pending job must be cancelled.'
    $script:Errors = @()
    Finish-Fixture
    Assert ($grid.Rows.Count -eq 1 -and $grid.Rows[0].Cells[0].Value -eq 'fixture') 'Result JSON should populate the session grid.'
    Assert ($agent.Enabled -and -not $project.ReadOnly -and -not (Test-Path -LiteralPath $requestPath)) 'Completion must unlock fields and clean up request JSON.'
    Set-Fixtures
    $cancelJob = Base-Job 'List'
    $cancelJob.fixtureDelay = 500
    Start-Job $cancelJob
    $cancelRequest = $script:Pending.request
    $cancelProcess = $script:Pending.process
    $cancelButton.PerformClick()
    Assert ($script:Pending.cancelled -and $cancelProcess.WaitForExit(10000)) 'List cancellation must discard results after the isolated helper finishes.'
    Finish-Job
    Assert ($null -eq $script:Pending -and $status.Text -like '*취소했습니다*' -and $script:Errors.Count -eq 0) 'Cancelled List should return to idle without an error dialog.'
    Assert ($grid.Rows.Count -eq 2 -and -not $cancelButton.Enabled -and $projectPicker.Enabled -and -not (Test-Path -LiteralPath $cancelRequest)) 'List cancellation must preserve rows, restore controls, and remove fixture request files.'
    Assert (-not $prevButton.Enabled -and -not $nextButton.Enabled) 'Finishing a task must not re-enable page buttons on a single page.'
    $statusJob = Base-Job 'Status'
    $statusJob.fixtureDelay = 20000
    Start-Job $statusJob
    $statusProcess = $script:Pending.process
    Assert ($cancelButton.Enabled) 'Non-restore tasks must be cancellable.'
    $script:Answers = @($false)
    $cancelButton.PerformClick()
    Assert (-not $script:Pending.cancelled -and -not $statusProcess.HasExited) 'Declining the cancel confirmation must keep the task running.'
    $running = $script:Pending
    $script:Answers = @({ $script:Pending = $running.Clone(); $true })
    $cancelButton.PerformClick()
    Assert (-not $running.cancelled -and -not $script:Pending.cancelled -and -not $statusProcess.HasExited) 'A task that finished while the cancel confirmation was open, and the task after it, must not be stopped.'
    $script:Pending = $running
    $script:Answers = @($true)
    $cancelButton.PerformClick()
    Assert ($script:Pending.cancelled -and $statusProcess.WaitForExit(5000)) 'Cancelling a task must stop the worker process it started.'
    Finish-Job
    Assert ($null -eq $script:Pending -and $status.Text -eq (T 'GuiJobCancelled') -and $script:Errors.Count -eq 0) 'A cancelled task should return to idle with the cancel message.'
    $script:Answers = @($true)
    ($script:Buttons | Where-Object Text -eq '등록 해제').PerformClick()
    Assert ($script:Pending.job.action -eq 'Unbind' -and $script:Pending.job.identity -eq $identity.Text -and $script:Pending.job.projectPath -eq $project.Text) 'Unregister must send the project fields after confirmation.'
    Finish-Fixture
    Assert ($projectPicker.Items.Count -eq 2 -and $script:Errors.Count -eq 0) 'Registered projects must reload after unregistering.'
    Set-Fixtures
    $script:Answers = @($false)
    ($script:Buttons | Where-Object Text -eq '선택한 대화 백업').PerformClick()
    Assert ($null -eq $script:Pending) 'Declined backup confirmation must leave the form idle.'
    $script:Answers = @($true,$false)
    ($script:Buttons | Where-Object Text -eq '미리보기 후 복원').PerformClick()
    Assert ($cancelButton.Enabled) 'A restore preview can be cancelled.'
    Finish-Fixture
    Assert ($script:Pending.job.action -eq 'Restore' -and -not $cancelButton.Enabled) 'Accepted preview should start Restore, which cannot be cancelled.'
    Finish-Fixture
    Assert ($null -eq $script:Pending) 'Declined open should complete without another process.'
    Set-Fixtures
    $script:Answers = @($true,$true)
    ($script:Buttons | Where-Object Text -eq '미리보기 후 복원').PerformClick()
    Finish-Fixture
    Finish-Fixture
    Assert ($script:Pending.job.action -eq 'Open') 'Accepted restore completion should start Open.'
    Finish-Fixture
    Assert ($null -eq $script:Pending) 'Open completion should return to idle.'
    # 빈 칸·공백·잘못된 경로에서 폴더 선택과 초대 만들기를 눌러도 오류 없이 대화 상자를 연다.
    $script:Dialogs = @()
    function Show-Dialog([object]$Dialog) {
        $script:Dialogs += [pscustomobject]@{start=$(if ($Dialog -is [Windows.Forms.FolderBrowserDialog]) {$Dialog.SelectedPath} else {$Dialog.InitialDirectory})}
        return 'Cancel'
    }
    $browseButtons = @($script:Buttons | Where-Object Text -eq '폴더 선택')
    $inviteButton = $script:Buttons | Where-Object Text -eq '다른 PC용 초대 만들기'
    Assert ($browseButtons.Count -eq 3 -and $null -ne $inviteButton) 'Three folder buttons and the invite button should exist.'
    foreach ($value in @('', '   ', 'a|b')) {
        $project.Text = $value; $store.Text = $value; $desktopHome.Text = $value
        $tabs.SelectedTab = $main; [Windows.Forms.Application]::DoEvents()
        $browseButtons[0].PerformClick()
        $tabs.SelectedTab = $settings; [Windows.Forms.Application]::DoEvents()
        $browseButtons[1].PerformClick(); $browseButtons[2].PerformClick(); $inviteButton.PerformClick()
    }
    Assert ($script:Dialogs.Count -eq 12 -and -not ($script:Dialogs | Where-Object start)) ("Empty, blank and invalid paths must open every dialog without a start folder: $($script:Dialogs.Count) dialogs [" + (($script:Dialogs | ForEach-Object start) -join '|') + '] errors: ' + ($script:Errors -join ', '))
    $project.Text = $fixtureRoot; $store.Text = $fixtureRoot
    $tabs.SelectedTab = $main; [Windows.Forms.Application]::DoEvents(); $browseButtons[0].PerformClick()
    $tabs.SelectedTab = $settings; [Windows.Forms.Application]::DoEvents(); $inviteButton.PerformClick()
    $tabs.SelectedTab = $main
    Assert ($script:Dialogs.Count -eq 14 -and $script:Dialogs[12].start -eq $fixtureRoot -and $script:Dialogs[13].start -eq $fixtureRoot) 'An existing folder should become the dialog start folder.'
    Assert ($project.Text -eq $fixtureRoot) 'A cancelled folder dialog must keep the box text.'
    Assert ($script:Errors.Count -eq 0) ('Unexpected UI errors: ' + ($script:Errors -join ', '))
    Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixturePrefsFile)) -eq $fixturePrefsBytes) 'Preferences must never be saved during fixture tests.'
    Write-Output "PASS: $script:Checks GUI assertions; $($script:Launches.Count) isolated fixture worker processes; screenshot $script:FixtureScreenshotPath"
} finally {
    $script:SmokeTest = $true
    if ($script:Pending) {
        if (-not $script:Pending.process.HasExited) { $script:Pending.process.Kill(); $script:Pending.process.WaitForExit() }
        $script:Pending.process.Dispose()
        $script:Pending = $null
    }
    if ($timer) { $timer.Dispose() }
    if ($filterTimer) { $filterTimer.Dispose() }
    if ($form) { $form.Close(); $form.Dispose() }
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:CTXHOP_CONFIG_DIR = $previousConfigDir
    $resolvedFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $resolvedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedFixtureRoot.StartsWith($resolvedTempRoot,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedFixtureRoot)) {
        Remove-Item -LiteralPath $resolvedFixtureRoot -Recurse -Force
    }
}
