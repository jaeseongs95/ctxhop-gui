#requires -Version 5.1
[CmdletBinding()]
param([switch]$SmokeTest, [string]$ScreenshotPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Strings.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:PrefsPath = Join-Path $env:LOCALAPPDATA 'CtxHopGUI\vnext-preferences.json'
$script:Prefs = [pscustomobject]@{projectPath=''; identity=''; agent='claude-code'; store='G:\내 드라이브\세션연동'; invite=''; deviceName=$env:COMPUTERNAME; home=$(if ($env:CODEX_HOME) {$env:CODEX_HOME} else {Join-Path $env:USERPROFILE '.codex'}); language='ko'; projectFiles='on'}
if (Test-Path -LiteralPath $script:PrefsPath) {
    try {
        $saved=Get-Content -LiteralPath $script:PrefsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $script:Prefs.PSObject.Properties) {
            if ($saved.PSObject.Properties.Name -contains $property.Name -and $saved.($property.Name) -is [string]) { $script:Prefs.($property.Name)=$saved.($property.Name) }
        }
    } catch {}
}
Set-Language $script:Prefs.language
$script:Sessions = @()
$script:Pending = $null
$script:PreviewJob = $null
$script:Buttons = @()
$script:SessionButtons = @()
$script:Page=0
$script:PageSize=200
$script:Filtered=@()
$script:DesktopPreviewQueue=@()
$script:DesktopReviews=@()
$script:DesktopApplyQueue=@()
$script:Bulk=$null
$script:BulkSummary=''
function New-Control([string]$Type, [int]$X, [int]$Y, [int]$Width, [int]$Height, [string]$Text, [object]$Parent) {
    $control = New-Object "System.Windows.Forms.$Type"
    $control.SetBounds($X,$Y,$Width,$Height)
    $control.Text = $Text
    $Parent.Controls.Add($control)
    return $control
}
function New-Button([int]$X, [int]$Y, [int]$Width, [string]$Text, [object]$Parent, [scriptblock]$Handler) {
    $button = New-Control Button $X $Y $Width 36 $Text $Parent
    $button.FlatStyle = 'Flat'
    $button.Add_Click({ try { & $Handler } catch { Show-Error $_.Exception.Message } }.GetNewClosure())
    $script:Buttons += $button
    return $button
}
function Show-Error([string]$Message) {
    $status.Text = $Message
    $log.AppendText("`r`n$(T 'GuiErrorLog' $Message)`r`n")
    [Windows.Forms.MessageBox]::Show($form,$Message,(T 'GuiErrorTitle'),'OK','Warning') | Out-Null
}
function Confirm([string]$Message) { return [Windows.Forms.MessageBox]::Show($form,$Message,(T 'GuiConfirmTitle'),'YesNo','Question') -eq 'Yes' }
function Save-Prefs {
    $script:Prefs.projectPath=$project.Text.Trim().Trim('"')
    $script:Prefs.identity=$identity.Text.Trim()
    $script:Prefs.agent=if ($agent.SelectedIndex -eq 1) {'codex-desktop'} else {'claude-code'}
    $script:Prefs.store=$store.Text.Trim().Trim('"')
    $script:Prefs.invite=$invite.Text.Trim().Trim('"')
    $script:Prefs.deviceName=$device.Text.Trim()
    $script:Prefs.home=$desktopHome.Text.Trim().Trim('"')
    $script:Prefs.language=if ($languagePicker.SelectedIndex -eq 1) {'en'} else {'ko'}
    $script:Prefs.projectFiles=if ($projectFiles.Checked) {'on'} else {'off'}
    if (-not $SmokeTest) {
        New-Item -ItemType Directory -Path (Split-Path $script:PrefsPath) -Force | Out-Null
        $script:Prefs | ConvertTo-Json | Set-Content -LiteralPath $script:PrefsPath -Encoding UTF8
    }
}
function Base-Job([string]$Action) {
    Save-Prefs
    return @{action=$Action; projectPath=$script:Prefs.projectPath; identity=$script:Prefs.identity; agent=$script:Prefs.agent; store=$script:Prefs.store; invite=$script:Prefs.invite; deviceName=$script:Prefs.deviceName;home=$script:Prefs.home;search=$search.Text.Trim();language=$script:UiLanguage;projectBackup=$projectFiles.Checked;projectRestore=$projectFiles.Checked}
}
function Selected-Job([string]$Action) {
    $job = Base-Job $Action
    if (-not $grid.SelectedRows.Count) { throw (T 'GuiSelectOneSession') }
    if ($grid.SelectedRows.Count -ne 1) { throw (T 'GuiSelectOneForBackup') }
    $session = $grid.SelectedRows[0].Tag
    if ($session.agent -ne $job.agent) { throw (T 'GuiAgentChanged') }
    $job.nativeId=$session.nativeId
    $job.remoteId=$session.remoteId
    $job.title=$session.title
    return $job
}
function Fill-Sessions([object[]]$Items) {
    $grid.ClearSelection()
    $script:Sessions = @($Items)
    $script:Page=0
    Apply-Filter
}
# Codex는 작업 폴더를 \\?\ 붙은 확장 경로로 적기도 하므로 접두사·끝의 \를 떼고 비교한다(대소문자는 -eq·OrdinalIgnoreCase가 무시).
function Get-PathKey([string]$Path) {
    $p=$Path.Trim()
    if ($p.StartsWith('\\?\UNC\')) { $p='\\'+$p.Substring(8) } elseif ($p.StartsWith('\\?\')) { $p=$p.Substring(4) }
    return $p.TrimEnd('\')
}
# 이 PC 대화는 프로젝트 폴더와 그 하위에서 만든 것만 본다. 공유 백업은 다른 PC 경로일 수 있어 마지막 폴더 이름이 같아도 이 프로젝트로 본다.
# 원본 폴더를 모르는 공유 백업(확인하지 못한 백업)은 숨기지 않고, 원본 폴더를 모르는 이 PC 대화는 숨긴다.
function Test-InProject([object]$Item, [string]$Project) {
    if (-not $Project) { return $true }
    if (-not $Item.sourceCwd) { return (-not $Item.local) }
    $root=Get-PathKey $Project; $cwd=Get-PathKey ([string]$Item.sourceCwd)
    if ($cwd -eq $root -or $cwd.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { return $true }
    $name=$root.Substring($root.LastIndexOf('\')+1)
    return (-not $Item.local -and $name -and $cwd.Substring($cwd.LastIndexOf('\')+1) -eq $name)
}
function Filter-Metadata([object[]]$Items, [string]$Query, [string]$Mode, [int]$Days, [string]$Project='') {
    $cutoff=if ($Days -gt 0) {(Get-Date).AddDays(-$Days)} else {[datetime]::MinValue}
    @($Items | Where-Object {
        $matches=(-not $Query -or ([string]$_.title).IndexOf($Query,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.nativeId).IndexOf($Query,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.sourceCwd).IndexOf($Query,[StringComparison]::OrdinalIgnoreCase) -ge 0)
        $date=[datetime]::MinValue
        $null=[datetime]::TryParse([string]$_.updatedAt,[ref]$date)
        $matches -and ($Mode -ne 'local' -or $_.local) -and ($Mode -ne 'remote' -or $_.recordCount -gt 0) -and $date -ge $cutoff -and (Test-InProject $_ $Project)
    } | Sort-Object updatedAt -Descending)
}
function Apply-Filter {
    $selected=if ($grid.SelectedRows.Count) {$grid.SelectedRows[0].Tag} else {$null}
    $mode=switch ($view.SelectedIndex) {1 {'local'} 2 {'remote'} default {'all'}}
    $days=switch ($dateFilter.SelectedIndex) {1 {7} 2 {30} default {0}}
    $root=if ($agent.SelectedIndex -eq 1 -and $projectOnly.Checked) {$project.Text.Trim().Trim('"')} else {''}
    $script:Filtered=@(Filter-Metadata $script:Sessions $search.Text.Trim() $mode $days $root)
    $pages=[math]::Max(1,[math]::Ceiling($script:Filtered.Count/$script:PageSize))
    $script:Page=[math]::Max(0,[math]::Min($script:Page,$pages-1))
    $grid.SuspendLayout(); $grid.Rows.Clear()
    $visible=@($script:Filtered | Select-Object -Skip ($script:Page*$script:PageSize) -First $script:PageSize)
    $yes=T 'GuiYes'; $no=T 'GuiNo'; $blocked=T 'GuiBackupBlocked'; $shared=T 'GuiBackupShared'; $none=T 'GuiBackupNone'; $archived=T 'GuiArchivedSuffix'; $oldFormat=T 'GuiOldFormatSuffix'
    foreach ($item in $visible) {
        $title = [regex]::Replace([string]$item.title, '[\x00-\x1f\x7f-\x9f]', ' ')
        $label = if ($item.agent -eq 'codex-desktop') {'Codex Desktop'} else {'Claude Code'}
        $local = if ($item.local) {$yes} else {$no}
        $backup = if ($item.blockedReason) {$blocked} elseif ($item.remoteId -and $item.agent -eq 'codex-desktop') {$shared} elseif ($item.recordCount -gt 0) {$yes} else {$none}
        # 하위 에이전트 대화 수는 부모 행에 붙여 보여 준다. 묶음 표시가 없는 공유 백업은 하위 대화가 빠졌을 수 있는 이전 형식이다.
        $family=if ($item.blockedReason) {''} elseif ($null -eq $item.children) {$oldFormat} elseif ($item.children -gt 0) {T 'GuiChildrenSuffix' $item.children} else {''}
        $context=if ($item.agent -eq 'codex-desktop') {"$($item.sourceCwd) · $([string]$item.historyMode -replace ';family=\d+$','')" + $family + $(if ($item.archived) {$archived} else {''})} else {''}
        # Codex 백업은 UTC ISO 문자열이라 이 PC 시간으로 짧게 보여 준다. 정렬은 원래 값으로 한다.
        $updated=[datetime]::MinValue
        $shown=if ([datetime]::TryParse([string]$item.updatedAt,[ref]$updated)) {$updated.ToString('yyyy-MM-dd HH:mm')} else {[string]$item.updatedAt}
        $index = $grid.Rows.Add($title,$label,$shown,$local,$backup,[string]$item.nativeId,$context)
        $grid.Rows[$index].Tag = $item
    }
    $grid.ResumeLayout()
    $grid.ClearSelection()
    if ($selected) {
        foreach ($row in $grid.Rows) {
            if ($row.Tag.nativeId -eq $selected.nativeId -and $row.Tag.remoteId -eq $selected.remoteId -and $row.Tag.agent -eq $selected.agent) { $row.Selected=$true; break }
        }
    }
    Update-Selection
    $countLabel.Text=(T 'GuiCountLabel' $script:Filtered.Count $script:Sessions.Count ($script:Page+1) $pages)
    $status.Text = if ($agent.SelectedIndex -eq 1) {(T 'GuiStatusCodexList')} else {(T 'GuiStatusClaudeList')}
}
function Update-Selection {
    if (-not $script:SessionButtons.Count) { return }
    $selected=if ($grid.SelectedRows.Count) { $grid.SelectedRows[0].Tag } else { $null }
    $script:SessionButtons[0].Enabled=($null -ne $selected -and $grid.SelectedRows.Count -eq 1 -and $selected.local -and -not $selected.blockedReason -and -not $script:Pending)
    $desktop=$agent.SelectedIndex -eq 1
    $script:SessionButtons[1].Enabled=($null -ne $selected -and -not $script:Pending -and $(if ($desktop) {@($grid.SelectedRows | Where-Object { -not $_.Tag.local -and $_.Tag.remoteId -and -not $_.Tag.blockedReason }).Count -eq $grid.SelectedRows.Count} else {$selected.recordCount -gt 0}))
    $script:SessionButtons[2].Enabled=($null -ne $selected -and $selected.local -and -not $desktop -and -not $script:Pending)
    # 작업이 끝나면 모든 버튼을 다시 켜므로 페이지 버튼도 여기서 넘길 페이지가 있을 때만 켠다.
    $prevButton.Enabled=($script:Page -gt 0 -and -not $script:Pending)
    $nextButton.Enabled=(($script:Page+1)*$script:PageSize -lt $script:Filtered.Count -and -not $script:Pending)
    $selectionLabel.Text=if ($grid.SelectedRows.Count -gt 1) { T 'GuiSelectionMany' $grid.SelectedRows.Count }
        elseif ($selected) { (T 'GuiSelectionInfo' ((@($selected.title,$selected.nativeId) | Where-Object { $_ }) -join ' · ')) + $(if ($selected.blockedReason) {(T 'GuiSelectionBlocked' $selected.blockedReason)} else {''}) }
        else { (T 'GuiNoSelectionHint') + $(if ($desktop) {T 'GuiMultiSelectHint'} else {''}) }
}
function Start-Job([hashtable]$Job) {
    if ($script:Pending) { throw (T 'GuiWaitForJob') }
    if ($SmokeTest) { throw (T 'GuiSmokeNoJobs') }
    $runtime = Join-Path $env:LOCALAPPDATA 'CtxHopGUI\jobs'
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $request = Join-Path $runtime "$id.request.json"
    $result = Join-Path $runtime "$id.result.json"
    $Job | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $request -Encoding UTF8
    # Windows 파일명에는 따옴표를 넣을 수 없으므로 각 검증된 절대경로만 인수로 인용한다.
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "{0}" -RequestFile "{1}" -ResultFile "{2}"' -f (Join-Path $PSScriptRoot 'Worker.ps1'),$request,$result
    $windowStyle=if ($Job.agent -eq 'codex-desktop' -and $Job.action -notin @('Setup','Invite','PassphraseChange','PassphraseReset')) {'Hidden'} else {'Normal'}
    # Claude and explicitly selected setup/invite/password operations retain their interactive native input window.
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -PassThru -WindowStyle $windowStyle
    $script:Pending = @{process=$process; job=$Job; request=$request; result=$result}
    foreach ($button in $script:Buttons) { $button.Enabled=$false }
    # 복원은 중간에 끊으면 복구 기록이 남고, 열기는 사용자가 대화를 끝내야 하므로 취소하지 않는다.
    # 저장소 옮기기도 복사 도중 멈추면 새 폴더에 일부 파일만 남으므로 취소하지 않는다.
    $cancelButton.Enabled=($Job.action -notin @('Restore','Open','MoveStore','Rollback','CloseJournal'))
    $agent.Enabled=$false; $project.ReadOnly=$true; $identity.ReadOnly=$true
    $projectPicker.Enabled=$false; $desktopHome.ReadOnly=$true
    $progress.Style='Marquee'
    $status.Text=if ($windowStyle -eq 'Hidden') {T 'GuiStatusProcessingHidden'} else {T 'GuiStatusProcessingWindow'}
    $log.AppendText("`r`n$(T 'GuiLogJobStarted' $Job.action $Job.agent)`r`n")
}
# 큰 작업 폴더(200MB 이상)가 있는 대화는 대화도 올리지 않고 보류한다. 백업이 끝나면 한 창에 모아 체크한 대화만 대화와 파일을 함께 올린다.
# 항목은 @{job=백업 작업; folders=Worker가 돌려준 큰 폴더}. 기본은 모두 체크하지 않음.
function New-DeferredDialog([object[]]$Items) {
    $dialog=[Windows.Forms.Form]::new(); $dialog.Text=(T 'GuiDeferredTitle'); $dialog.ClientSize=[Drawing.Size]::new(900,400)
    $dialog.StartPosition='CenterParent'; $dialog.Font=[Drawing.Font]::new('맑은 고딕',10); $dialog.MinimumSize=[Drawing.Size]::new(700,300)
    $dialog.FormBorderStyle='Sizable'; $dialog.MinimizeBox=$false
    $intro=New-Control Label 16 12 868 46 (T 'GuiDeferredIntro' @($Items).Count) $dialog; $intro.Anchor='Top,Left,Right'
    $list=New-Control ListView 16 62 868 270 '' $dialog; $list.Anchor='Top,Bottom,Left,Right'
    $list.View='Details'; $list.CheckBoxes=$true; $list.FullRowSelect=$true
    $null=$list.Columns.Add((T 'GuiColConversation'),260); $null=$list.Columns.Add((T 'GuiDeferredColFolders'),580)
    foreach ($item in $Items) {
        $row=[Windows.Forms.ListViewItem]::new([string]$item.job.title)
        $null=$row.SubItems.Add((@($item.folders | ForEach-Object { T 'GuiProjectAskLine' $_.path $_.files ([math]::Ceiling([double]$_.bytes/1MB)) }) -join '; '))
        $row.Tag=$item; $null=$list.Items.Add($row)
    }
    $accept=New-Control Button 504 346 220 38 (T 'GuiDeferredUpload') $dialog; $accept.DialogResult='OK'; $accept.Anchor='Bottom,Right'
    $cancel=New-Control Button 734 346 150 38 (T 'GuiDeferredSkip') $dialog; $cancel.DialogResult='Cancel'; $cancel.Anchor='Bottom,Right'
    $dialog.CancelButton=$cancel
    return @{dialog=$dialog;list=$list}
}
# 체크한 항목만 돌려준다. 창을 닫거나 올리지 않음을 누르면 없음.
function Select-DeferredBackups([object[]]$Items) {
    $ui=New-DeferredDialog $Items
    try {
        if ((Show-Dialog $ui.dialog) -ne 'OK') { return @() }
        return @($ui.list.CheckedItems | ForEach-Object { $_.Tag })
    } finally { $ui.dialog.Dispose() }
}
# 고른 대화는 그 큰 폴더를 허락한 채 같은 백업을 다시 실행한다. 다시 물은 경우 앞서 허락한 폴더도 유지한다.
function Approve-Deferred([object]$Item) {
    $job=$Item.job.Clone(); $job.projectApproved=@(@($Item.job.projectApproved) + @($Item.folders | ForEach-Object { [string]$_.path }) | Where-Object { $_ } | Select-Object -Unique)
    return $job
}
function Get-ProjectReasonText([string]$Reason) {
    switch ($Reason) {
        'missing' { return (T 'GuiProjectReasonMissing') }
        'tooLarge' { return (T 'GuiProjectReasonTooLarge') }
        'tooBroad' { return (T 'GuiProjectReasonTooBroad') }
        'parentOfStart' { return (T 'GuiProjectReasonParentOfStart') }
        'agentSettings' { return (T 'GuiProjectReasonAgentSettings') }
        default { return $Reason }
    }
}
function Get-ProjectSum([object]$Project,[string]$Field) { return [int](@($Project.folders | ForEach-Object { $_.compare.$Field } | Where-Object { $null -ne $_ }) | Measure-Object -Sum).Sum }
# 미리보기의 프로젝트 파일 부분: 폴더마다 복원할 곳과 새·바뀔·같은·이 PC에만 있는 파일 수.
function Format-ProjectPreview([object]$Project) {
    switch ([string]$Project.state) {
        'found' {
            $lines=@(T 'GuiProjectHeader' $Project.createdAt)
            foreach ($folder in @($Project.folders)) {
                $lines+=switch ([string]$folder.state) {
                    'ready' { T 'GuiProjectFolderReady' $folder.sourcePath $folder.target $folder.compare.new $folder.compare.changed $folder.compare.same $folder.compare.localOnly }
                    'needsFolder' { T 'GuiProjectFolderNeeds' $folder.sourcePath }
                    'error' { T 'GuiProjectFolderError' $folder.sourcePath $folder.reason }
                    default { T 'GuiProjectFolderSkipped' $folder.sourcePath (Get-ProjectReasonText $folder.reason) }
                }
            }
            $outside=@($Project.outside | Where-Object { $_ })
            if ($outside.Count) { $lines+=T 'GuiProjectOutsidePreview' $outside.Count (@($outside | Select-Object -First 10) -join ', ') }
            return ($lines -join "`r`n")
        }
        'none' { return (T 'GuiProjectNone') }
        'error' { return (T 'GuiProjectError' $Project.reason) }
        default { return (T 'GuiProjectOff') }
    }
}
function Format-ProjectCell([object]$Project) {
    switch ([string]$Project.state) {
        'found' { return (T 'GuiProjectCell' @($Project.folders | Where-Object { $_.state -in @('ready','needsFolder') }).Count (Get-ProjectSum $Project 'new') (Get-ProjectSum $Project 'changed') @($Project.folders | Where-Object { $_.state -eq 'needsFolder' }).Count) }
        'none' { return (T 'GuiProjectCellNone') }
        'error' { return (T 'GuiProjectCellError') }
        default { return (T 'GuiProjectCellOff') }
    }
}
function Pick-ProjectFolder([string]$Source) {
    if (-not (Confirm (T 'GuiProjectPickFolder' $Source "`r`n"))) { return '' }
    $dialog=[Windows.Forms.FolderBrowserDialog]::new(); $dialog.Description=(T 'GuiProjectPickDescription' $Source)
    try { if ((Show-Dialog $dialog) -eq 'OK') { return $dialog.SelectedPath } else { return '' } } finally { $dialog.Dispose() }
}
# 이 PC에 없는 추가 작업 폴더는 복원할 폴더를 고르거나 건너뛴다(빈 값). 원래 경로가 있는 폴더는 묻지 않는다.
function Select-ProjectTargets([hashtable]$Job,[object]$Project) {
    if (-not $Job.projectRestore -or [string]$Project.state -ne 'found') { return }
    $Job.projectReceipt=[string]$Project.receipt
    $targets=@{}
    foreach ($folder in @($Project.folders | Where-Object { $_.state -eq 'needsFolder' })) { $targets[[string]$folder.index]=Pick-ProjectFolder $folder.sourcePath }
    if ($targets.Count) { $Job.projectTargets=$targets }
}
function Write-ProjectLog([object]$Project) {
    # 폴더 밖에서 고친 파일(백업하지 않음)과 복원하지 못한 파일을 기록 창에 남긴다.
    $outside=@($Project.outside | Where-Object { $_ })
    if ($outside.Count) { $log.AppendText((T 'GuiProjectOutsideList' (@($outside | Select-Object -First 20) -join ', '))+"`r`n") }
    $failed=@($Project.folders | ForEach-Object { @($_.failed) } | Where-Object { $_ })
    if ($failed.Count) { $log.AppendText((T 'GuiProjectRestoreFailures' (@($failed | Select-Object -First 10 | ForEach-Object { "$($_.path): $($_.reason)" }) -join '; '))+"`r`n") }
}
# 중단된 복원 창(S3 명세 4.4절). 행마다 대화·대상 폴더·상태·파일 분류 수·기록 폴더를 보이고, 고른 행과 할 일을 돌려준다.
function Get-JournalCounts([object]$Row) {
    $files=@($Row.files | Where-Object { $_ })
    $counts=[ordered]@{}; foreach ($class in 'original','owned','unknown','unrestorable') { $counts[$class]=@($files | Where-Object { $_.class -eq $class }).Count }
    return $counts
}
function New-JournalDialog([object]$Journal) {
    $dialog=[Windows.Forms.Form]::new(); $dialog.Text=(T 'GuiJournalTitle'); $dialog.ClientSize=[Drawing.Size]::new(1000,440)
    $dialog.StartPosition='CenterParent'; $dialog.Font=[Drawing.Font]::new('맑은 고딕',10); $dialog.MinimumSize=[Drawing.Size]::new(760,320)
    $dialog.FormBorderStyle='Sizable'; $dialog.MinimizeBox=$false
    $rows=@($Journal.rows | Where-Object { $_ }); $failed=@($Journal.failed | Where-Object { $_ })
    $text=T 'GuiJournalIntro' $rows.Count; if ($failed.Count) { $text+=' '+(T 'GuiJournalQueryFailed' ($failed -join ', ')) }
    $intro=New-Control Label 16 12 968 46 $text $dialog; $intro.Anchor='Top,Left,Right'
    $list=New-Control ListView 16 62 968 306 '' $dialog; $list.Anchor='Top,Bottom,Left,Right'
    $list.View='Details'; $list.FullRowSelect=$true; $list.MultiSelect=$false; $list.HideSelection=$false
    foreach ($column in @(@((T 'GuiColConversation'),200),@((T 'GuiColTargetFolder'),220),@((T 'GuiJournalColState'),170),@((T 'GuiJournalColFiles'),200),@((T 'GuiJournalColFolder'),160))) { $null=$list.Columns.Add($column[0],$column[1]) }
    foreach ($row in $rows) {
        $counts=Get-JournalCounts $row
        $item=[Windows.Forms.ListViewItem]::new($(if ($row.nativeId) {"$($row.agent) $($row.nativeId)"} else {T 'GuiJournalProjectRecord'}))
        $state=[string]$row.state; if ($row.error) { $state+=" - $($row.error)" }
        foreach ($value in @((@($row.targets | Where-Object { $_ }) -join '; '),$state,(T 'GuiJournalCounts' $counts.original $counts.owned $counts.unknown $counts.unrestorable),[string]$row.path)) { $null=$item.SubItems.Add([string]$value) }
        # 닫힌 스크립트 블록은 이 스크립트의 함수를 찾지 못하므로 버튼 조건에 쓸 값을 미리 계산해 둔다.
        $item.Tag=[pscustomobject]@{row=$row;unknown=$counts.unknown}; $null=$list.Items.Add($item)
    }
    $buttons=[ordered]@{}
    $x=16
    foreach ($spec in @(@('rollback',(T 'GuiJournalRollback'),170),@('unknown',(T 'GuiJournalRollbackUnknown'),250),@('open',(T 'GuiJournalOpenFolder'),140),@('resolve',(T 'GuiJournalResolve'),150))) {
        $button=New-Control Button $x 382 $spec[2] 38 $spec[1] $dialog; $button.Anchor='Bottom,Left'; $button.Enabled=$false
        $action=$spec[0]
        $button.Add_Click({ $dialog.Tag=@{action=$action;row=$list.SelectedItems[0].Tag.row}; $dialog.DialogResult='OK' }.GetNewClosure())
        $buttons[$action]=$button; $x+=$spec[2]+12
    }
    $close=New-Control Button 834 382 150 38 (T 'GuiJournalCloseWindow') $dialog; $close.DialogResult='Cancel'; $close.Anchor='Bottom,Right'
    $dialog.CancelButton=$close
    # 버튼은 고른 행에 맞춰 켠다: 되돌리기는 canRollback, 알 수 없는 파일은 그런 파일이 있을 때, 해결했음은 항상.
    $list.Add_SelectedIndexChanged({
        $tag=if ($list.SelectedItems.Count) { $list.SelectedItems[0].Tag } else { $null }
        $buttons.rollback.Enabled=$tag -and $tag.row.canRollback
        $buttons.unknown.Enabled=$tag -and $tag.row.canRollback -and $tag.unknown -gt 0
        $buttons.open.Enabled=$tag -and [bool]$tag.row.path
        $buttons.resolve.Enabled=[bool]$tag
    }.GetNewClosure())
    return @{dialog=$dialog;list=$list;buttons=$buttons}
}
function Show-JournalDialog([object]$Journal) {
    # 고른 할 일마다 확인을 한 번 더 받고 Worker 작업으로 보낸다. 창을 닫으면 아무것도 하지 않는다.
    $ui=New-JournalDialog $Journal
    try { if ((Show-Dialog $ui.dialog) -ne 'OK') { return }; $choice=$ui.dialog.Tag } finally { $ui.dialog.Dispose() }
    $row=$choice.row
    if ($choice.action -eq 'open') { if (Test-Folder $row.path) { $null=[Diagnostics.Process]::Start((Join-Path $env:WINDIR 'explorer.exe'),('"'+$row.path+'"')) }; return }
    $job=Base-Job 'Rollback'
    if ($row.agent) { $job.agent=[string]$row.agent }
    switch ($row.kind) { marker { $job.operationId=[string]$row.operationId } vendor { $job.recordId=[string]$row.recordRef } default { $job.projectRecord=[string]$row.recordRef } }
    switch ($choice.action) {
        rollback { if (-not (Confirm (T 'GuiJournalRollbackConfirm'))) { return } }
        unknown {
            $unknown=@($row.files | Where-Object { $_ -and $_.class -eq 'unknown' })
            $lines=@($unknown | Select-Object -First 20 | ForEach-Object { "$($_.target) ($($_.current))" }) -join "`r`n"
            if (-not (Confirm ((T 'GuiJournalUnknownConfirm' $unknown.Count)+"`r`n`r`n"+$lines))) { return }
            $job.confirmedUnknown=@($unknown | ForEach-Object { @{target=[string]$_.target;current=[string]$_.current} })
        }
        resolve {
            $remaining=@($row.files | Where-Object { $_ -and $_.class -ne 'original' }).Count
            if (-not (Confirm (T 'GuiJournalResolveConfirm' $remaining))) { return }
            $job.action='CloseJournal'; $job.sha256=[string]$row.sha256
        }
    }
    Start-Job $job
}
function Finish-Job {
    if (-not $script:Pending -or -not $script:Pending.process.HasExited) { return }
    $pending=$script:Pending; $script:Pending=$null
    foreach ($button in $script:Buttons) { $button.Enabled=$true }
    $cancelButton.Enabled=$false
    $agent.Enabled=$true; $project.ReadOnly=$false; $identity.ReadOnly=$false
    $projectPicker.Enabled=$true; $desktopHome.ReadOnly=$false
    $progress.Style='Blocks'
    Update-Selection
    # 전체 백업 요약은 바로 다음 목록 불러오기가 성공할 때만 보여 주고, 실패·취소돼도 남기지 않는다.
    $bulkSummary=''; if ($pending.job.action -eq 'List') { $bulkSummary=$script:BulkSummary; $script:BulkSummary='' }
    try {
        if ($pending.cancelled) { $script:DesktopPreviewQueue=@(); $status.Text=if ($pending.job.action -eq 'List') {T 'GuiListCancelled'} else {T 'GuiJobCancelled'}; if ($script:Bulk) { $script:Bulk.stop=$true; End-BulkBackup }; return }
        if ($script:Bulk -and $pending.job.action -eq 'Backup') {
            # 전체 백업 중에는 한 대화의 실패로 멈추지 않고 기록한 뒤 다음 대화로 넘어간다.
            $result=try { Get-Content -LiteralPath $pending.result -Raw -Encoding UTF8 | ConvertFrom-Json } catch { [pscustomobject]@{ok=$false;error=(T 'GuiWorkerAborted')} }
            Step-BulkBackup $pending.job $result
            return
        }
        if (-not (Test-Path -LiteralPath $pending.result)) { throw (T 'GuiWorkerAborted') }
        $result = Get-Content -LiteralPath $pending.result -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($pending.job.agent -eq 'codex-desktop' -and $pending.job.action -eq 'Preview') {
            if ($result.ok) { Add-DesktopReview $pending.job $result.data.preview $result.data.receipt $result.data.project } else { Add-DesktopReview $pending.job ([pscustomobject]@{status='blocked';reason=[string]$result.error;token='';source=$null;target=$null}) '' }
            Continue-DesktopPreview
            return
        }
        if (-not $result.ok) {
            $script:DesktopApplyQueue=@()
            $errorMessage=[string]$result.error
            # 진행 중(busy)은 복구할 것이 없으므로 이유만 보인다.
            if ($result.backendResult -and $result.backendResult.status -ne 'busy') { $errorMessage+="`r`n" + (T 'GuiRecoveryRecord' ($result.backendResult | ConvertTo-Json -Depth 15 -Compress)) }
            # 중단된 복원 때문에 막혔으면 이유를 보인 뒤 중단된 복원 창을 연다.
            if ($result.journalOpen) { Show-Error $errorMessage; Start-Job (Base-Job 'Journal'); return }
            throw $errorMessage
        }
        $status.Text=$result.data.message
        $log.AppendText("$($result.data.message)`r`n")
        switch ($pending.job.action) {
            List {
                Fill-Sessions @($result.data.sessions); if ($result.data.excluded -gt 0) { $status.Text += (T 'GuiExcludedSuffix' $result.data.excluded) }
                if ($bulkSummary) { $status.Text=$bulkSummary }
            }
            Bind { Load-Bindings }
            Journal { if (@($result.data.rows | Where-Object { $_ }).Count -or @($result.data.failed | Where-Object { $_ }).Count) { Show-JournalDialog $result.data } else { $status.Text=(T 'GuiJournalEmpty') } }
            Rollback { Start-Job (Base-Job 'Journal') }
            CloseJournal { Start-Job (Base-Job 'Journal') }
            Unbind { Load-Bindings }
            Status { $log.AppendText("$(T 'GuiStatusLog' $result.data.device $result.data.store $result.data.syncConfig)`r`n") }
            Backup {
                # 큰 작업 폴더가 있으면 아직 아무것도 올리지 않았다. 목록 창에서 고르면 대화와 파일을 함께 올린다.
                if ($result.data.needsProjectConfirm) {
                    $picked=@(Select-DeferredBackups @(@{job=$pending.job;folders=@($result.data.folders)}))
                    if ($picked.Count) { Start-Job (Approve-Deferred $picked[0]) } else { $status.Text=(T 'GuiDeferredNotUploaded'); $log.AppendText("$(T 'GuiDeferredNotUploaded')`r`n") }
                } else { Write-ProjectLog $result.data.project }
            }
            Preview {
                $p=$result.data.preview
                $summary="$(T 'GuiFieldSession' $pending.job.title)`r`n$(T 'GuiFieldSessionId' $p.session)`r`n$(T 'GuiFieldAgent' $p.agent)`r`n$(T 'GuiFieldProject' $pending.job.identity)`r`n$(T 'GuiFieldWorkspace' $p.workspace)`r`n$(T 'GuiFieldDifferences' $p.differences)`r`n$(Format-ProjectPreview $result.data.project)`r`n`r`n$(T 'GuiPreviewConfirm')"
                if (Confirm $summary) {
                    # 미리보기의 receipt·token을 그대로 돌려줘야 Worker가 프로젝트 미리보기와 짝을 확인한다.
                    $job=$pending.job; $job.action='Restore'; $job.receipt=[string]$result.data.receipt; $job.token=[string]$result.data.token
                    Select-ProjectTargets $job $result.data.project
                    Start-Job $job
                }
            }
            Restore {
                Write-ProjectLog $result.data.project
                if ($pending.job.agent -eq 'codex-desktop') { Continue-DesktopApply; break }
                $id=$result.data.restored.session
                if (Confirm (T 'GuiRestoredOpenNow' $id)) {
                    $job=$pending.job; $job.action='Open'; $job.nativeId=$id
                    Start-Job $job
                }
            }
        }
    } catch { Show-Error $_.Exception.Message }
    finally {
        foreach ($file in @($pending.request,$pending.result)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
        $pending.process.Dispose()
        # 성공·실패·취소 모두 칸을 실제 설정으로 돌린다. 결과를 못 받았어도 설정은 이미 바뀌었을 수 있다.
        if ($pending.job.action -in @('Status','Setup','MoveStore')) { Show-ConnectedStore }
    }
}
function Add-DesktopReview([hashtable]$Job,[object]$Preview,[string]$Receipt,[object]$Project=$null) {
    if ($Preview.status -notin @('new','equal','incoming_newer','local_newer','conflict','blocked')) { $Preview=[pscustomobject]@{status='blocked';reason=(T 'GuiUnknownInspectState');token='';source=$null;target=$null} }
    $script:DesktopReviews += [pscustomobject]@{job=$Job;preview=$Preview;receipt=$Receipt;project=$Project}
}
function Start-DesktopPreview {
    $script:DesktopReviews=@(); $script:DesktopPreviewQueue=@()
    foreach ($row in @($grid.SelectedRows | Sort-Object Index)) {
        $item=$row.Tag
        if ($item.agent -ne 'codex-desktop' -or $item.local -or -not $item.remoteId -or $item.blockedReason) { throw (T 'GuiSelectCodexSharedOnly') }
        $job=Base-Job 'Preview'; $job.nativeId=$item.nativeId; $job.remoteId=$item.remoteId; $job.title=$item.title; $job.sourceCwd=$item.sourceCwd
        $script:DesktopPreviewQueue+=,$job
    }
    if (-not $script:DesktopPreviewQueue.Count) { throw (T 'GuiSelectSharedBackup') }
    Continue-DesktopPreview
}
function Get-DesktopDecisions([object]$Table) {
    $decisions=@()
    foreach ($row in $Table.Rows) {
        $review=$row.Tag; $choice=[string]$row.Cells['choice'].Value
        if ($choice -eq (T 'GuiChoiceRestore')) {
            if ($review.preview.status -eq 'blocked' -or -not $review.receipt -or -not $review.preview.token) { throw (T 'GuiBlockedNotRestorable') }
            $job=$review.job.Clone(); $job.action='Restore'; $job.receipt=$review.receipt; $job.token=$review.preview.token; $job.choice='incoming'
            $decisions+=,$job
        } elseif ($choice -notin @((T 'GuiChoiceSkip'),(T 'GuiChoiceKeepLocal'))) { throw (T 'GuiCheckEachChoice') }
    }
    # 결정은 해시테이블이라 PowerShell 5.1의 Group-Object가 속성 이름으로는 키를 읽지 못한다(모두 한 묶음이 됨). 스크립트 블록으로 묶는다.
    $duplicates=@($decisions | Group-Object { $_.nativeId } | Where-Object Count -gt 1)
    if ($duplicates.Count) { throw (T 'GuiDuplicateUuid') }
    return $decisions
}
function New-DesktopReviewDialog([object[]]$Reviews) {
    $dialog=[Windows.Forms.Form]::new(); $dialog.Text=(T 'GuiReviewTitle'); $dialog.ClientSize=[Drawing.Size]::new(1180,480)
    $dialog.StartPosition='CenterParent'; $dialog.Font=[Drawing.Font]::new('맑은 고딕',10); $dialog.MinimumSize=[Drawing.Size]::new(1196,519)
    $dialog.FormBorderStyle='Sizable'; $dialog.MinimizeBox=$false
    $intro=New-Control Label 16 12 1148 42 (T 'GuiReviewIntro' @($Reviews).Count) $dialog; $intro.Anchor='Top,Left,Right'
    $table=New-Control DataGridView 16 58 1148 295 '' $dialog; $table.Anchor='Top,Bottom,Left,Right'
    $table.AllowUserToAddRows=$false; $table.AllowUserToDeleteRows=$false; $table.RowHeadersVisible=$false; $table.AutoGenerateColumns=$false; $table.AutoSizeColumnsMode='Fill'
    # 행 높이를 내용에 맞춰 긴 제목·경로도 잘리지 않게 한다.
    $table.DefaultCellStyle.WrapMode='True'; $table.AutoSizeRowsMode='AllCells'
    foreach ($column in @(@('title',(T 'GuiColConversation'),150),@('backup',(T 'GuiColBackupId'),150),@('id','UUID',150),@('source',(T 'GuiColSourceFolder'),150),@('target',(T 'GuiColTargetFolder'),150),@('state',(T 'GuiColInspection'),100),@('reason',(T 'GuiColReason'),150),@('project',(T 'GuiColProjectFiles'),150))) {
        $c=[Windows.Forms.DataGridViewTextBoxColumn]::new(); $c.Name=$column[0]; $c.HeaderText=$column[1]; $c.FillWeight=$column[2]; $c.ReadOnly=$true; $table.Columns.Add($c)|Out-Null
    }
    $choiceColumn=[Windows.Forms.DataGridViewComboBoxColumn]::new(); $choiceColumn.Name='choice'; $choiceColumn.HeaderText=(T 'GuiColChoice'); $choiceColumn.FillWeight=150; $choiceColumn.Items.AddRange(@((T 'GuiChoiceSkip'),(T 'GuiChoiceKeepLocal'),(T 'GuiChoiceRestore'))); $table.Columns.Add($choiceColumn)|Out-Null
    $stateLabels=@{new=(T 'GuiStateNew');equal=(T 'GuiStateEqual');incoming_newer=(T 'GuiStateIncomingNewer');local_newer=(T 'GuiStateLocalNewer');conflict=(T 'GuiStateConflict');blocked=(T 'GuiStateBlocked')}
    foreach ($review in $Reviews) {
        $p=$review.preview; $j=$review.job
        $index=$table.Rows.Add($j.title,$j.remoteId,$j.nativeId,$j.sourceCwd,$j.projectPath,$stateLabels[$p.status],[string]$p.reason,(Format-ProjectCell $review.project),(T 'GuiChoiceSkip'))
        $row=$table.Rows[$index]; $row.Tag=$review
        if ($p.status -eq 'blocked') {
            $cell=[Windows.Forms.DataGridViewComboBoxCell]::new(); $cell.Items.AddRange(@((T 'GuiChoiceSkip'),(T 'GuiChoiceKeepLocal'))); $cell.Value=(T 'GuiChoiceSkip'); $row.Cells['choice']=$cell
            $row.DefaultCellStyle.BackColor=[Drawing.Color]::MistyRose
        } elseif ($p.status -in @('conflict','local_newer')) { $row.DefaultCellStyle.BackColor=[Drawing.Color]::LightYellow }
    }
    $table.ClearSelection()
    $details=New-Control TextBox 16 363 1148 42 '' $dialog; $details.Multiline=$true; $details.ReadOnly=$true; $details.ScrollBars='Vertical'; $details.Anchor='Bottom,Left,Right'
    # 닫힌 스크립트 블록(GetNewClosure)은 이 스크립트의 함수를 찾지 못하므로 문장과 함수를 미리 잡아 둔다.
    $detailsIdsFormat=(T 'GuiReviewDetailsIds'); $detailsPathsFormat=(T 'GuiReviewDetailsPaths'); $formatProject=${function:Format-ProjectPreview}
    $table.Add_SelectionChanged({
        if ($table.SelectedRows.Count) { $review=$table.SelectedRows[0].Tag; $details.Text=($detailsIdsFormat -f $review.job.nativeId,$review.job.remoteId) + "`r`n" + ($detailsPathsFormat -f $review.job.sourceCwd,$review.job.projectPath,$review.preview.reason) + "`r`n" + (& $formatProject $review.project) }
    }.GetNewClosure())
    $accept=New-Control Button 854 415 160 38 (T 'GuiReviewAccept') $dialog; $accept.DialogResult='OK'; $accept.Anchor='Bottom,Right'
    $cancel=New-Control Button 1028 415 136 38 (T 'GuiReviewCancelAll') $dialog; $cancel.DialogResult='Cancel'; $cancel.Anchor='Bottom,Right'
    $dialog.CancelButton=$cancel
    return @{dialog=$dialog;table=$table;accept=$accept;details=$details}
}
function Continue-DesktopPreview {
    if ($script:DesktopPreviewQueue.Count) {
        $next=$script:DesktopPreviewQueue[0]; $script:DesktopPreviewQueue=@($script:DesktopPreviewQueue | Select-Object -Skip 1)
        Start-Job $next; return
    }
    $reviewUI=New-DesktopReviewDialog $script:DesktopReviews
    try {
        while ($reviewUI.dialog.ShowDialog($form) -eq 'OK') {
            try { $decisions=@(Get-DesktopDecisions $reviewUI.table) } catch { Show-Error $_.Exception.Message; continue }
            if (-not $decisions.Count) { $status.Text=(T 'GuiAllSkipped'); return }
            # 결정마다 검토한 프로젝트 파일. 같은 UUID는 하나만 고를 수 있으므로 백업 ID로 찾는다.
            $projects=@{}; foreach ($review in $script:DesktopReviews) { $projects[[string]$review.job.remoteId]=$review.project }
            $summary=($decisions | ForEach-Object {"$($_.title) · $($_.nativeId) · $($_.remoteId)`r`n$(T 'GuiRestoreFolder' $_.projectPath)`r`n$(Format-ProjectPreview $projects[[string]$_.remoteId])"}) -join "`r`n`r`n"
            if (Confirm "$(T 'GuiApplyCount' $decisions.Count)`r`n$(T 'GuiApplyWarning')`r`n`r`n$summary") {
                foreach ($decision in $decisions) { Select-ProjectTargets $decision $projects[[string]$decision.remoteId] }
                $script:DesktopApplyQueue=$decisions; Continue-DesktopApply
            }
            return
        }
        $status.Text=(T 'GuiReviewCancelled')
    } finally { $reviewUI.dialog.Dispose() }
}
function Continue-DesktopApply {
    if ($script:DesktopApplyQueue.Count) {
        $next=$script:DesktopApplyQueue[0]; $script:DesktopApplyQueue=@($script:DesktopApplyQueue | Select-Object -Skip 1)
        Start-Job $next
    } else { $status.Text=(T 'GuiApplyDone') }
}
# 필터에 맞는 이 PC의 Codex 대화를 모든 페이지에서 골라 기존 백업 작업을 하나씩 돌린다.
# 같은 UUID·같은 수정 시각의 묶음 형식 공유 백업이 이미 있으면 내용이 같으므로 다시 올리지 않는다.
# 이전 형식 백업은 하위 대화가 빠졌을 수 있으므로 최신으로 보지 않는다.
function Start-BulkBackup {
    $latest=@{}
    foreach ($item in $script:Sessions) { if (-not $item.local -and $item.remoteId -and -not $item.blockedReason -and $null -ne $item.children) { $latest["$($item.nativeId)|$($item.updatedAt)"]=$true } }
    $local=@($script:Filtered | Where-Object { $_.agent -eq 'codex-desktop' -and $_.local })
    $blocked=@($local | Where-Object { $_.blockedReason }).Count
    $ready=@($local | Where-Object { -not $_.blockedReason -and -not $latest.ContainsKey("$($_.nativeId)|$($_.updatedAt)") })
    $current=$local.Count-$blocked-$ready.Count
    if (-not $ready.Count) { throw (T 'GuiBulkNothing' $local.Count $current $blocked) }
    if (-not (Confirm (T 'GuiBulkConfirm' $ready.Count $current $blocked "`r`n"))) { return }
    # deferred: 큰 작업 폴더 때문에 보류한 대화, picked: 끝에 고른 대화 수(-1은 아직 묻지 않음).
    $script:Bulk=@{items=$ready;next=0;done=0;failed=@();busy=@();streak=0;stop=$false;skipped=$current+$blocked;deferred=@();picked=-1}
    Continue-BulkBackup
}
function Continue-BulkBackup {
    $bulk=$script:Bulk
    # 저장소에 쓸 수 없는 경우처럼 모든 대화가 같은 이유로 실패하면 연속 3번 실패한 뒤 멈춘다.
    if ($bulk.stop -or $bulk.streak -ge 3) { End-BulkBackup; return }
    if ($bulk.next -ge $bulk.items.Count) {
        # 모든 대화를 한 번 돈 뒤 보류한 대화를 한 번만 묻고, 고른 대화를 큰 폴더와 함께 이어서 올린다.
        if ($bulk.picked -ge 0 -or -not $bulk.deferred.Count) { End-BulkBackup; return }
        $picked=@(Select-DeferredBackups $bulk.deferred); $bulk.picked=$picked.Count
        if (-not $picked.Count) { End-BulkBackup; return }
        $bulk.items=@($bulk.items) + @($picked | ForEach-Object { [pscustomobject]@{nativeId=$_.job.nativeId;title=$_.job.title;approved=@($_.folders | ForEach-Object { [string]$_.path })} })
    }
    $item=$bulk.items[$bulk.next]; $bulk.next++
    $job=Base-Job 'Backup'; $job.nativeId=$item.nativeId; $job.remoteId=''; $job.title=$item.title
    if ($item.approved) { $job.projectApproved=@($item.approved) }
    try { Start-Job $job } catch { $script:Bulk=$null; throw }
    $status.Text=(T 'GuiBulkProgress' $bulk.next $bulk.items.Count $bulk.done $bulk.failed.Count)
}
function Step-BulkBackup([hashtable]$Job,[object]$Result) {
    $bulk=$script:Bulk
    if ($Result.ok -and $Result.data.needsProjectConfirm) {
        if ($bulk.picked -lt 0) {
            # 큰 작업 폴더가 있는 대화는 아무것도 올리지 않고 보류한다. 끝에 한 번에 묻는다.
            $bulk.deferred+=,@{job=$Job;folders=@($Result.data.folders)}
            $log.AppendText("$(T 'GuiBulkItemDeferred' $Job.title $Job.nativeId)`r`n")
        } else {
            # 고른 뒤 다시 실행하는 사이에 다른 폴더도 커졌다. 묻지 않은 폴더를 올리지 않고 실패로 남긴다.
            $bulk.failed+="$($Job.title) · $($Job.nativeId): $(T 'GuiDeferredChanged')"
            $log.AppendText("$(T 'GuiBulkItemFailed' $Job.title $Job.nativeId (T 'GuiDeferredChanged'))`r`n")
        }
        Continue-BulkBackup
        return
    }
    if ($Result.ok) { $bulk.done++; $bulk.streak=0; $log.AppendText("$($Result.data.message)`r`n"); Write-ProjectLog $Result.data.project }
    elseif ($Result.backendResult.status -eq 'busy') {
        # 지금 진행 중인 대화는 실패가 아니라 건너뜀이다. 연속 실패에도 넣지 않고, 턴이 끝난 뒤 다시 누르면 백업된다.
        $bulk.busy+="$($Job.title) · $($Job.nativeId)"
        $log.AppendText("$(T 'GuiBulkItemBusy' $Job.title $Job.nativeId)`r`n")
    }
    else {
        $reason=if ($Result.error) {[string]$Result.error} else {T 'GuiWorkerAborted'}
        $bulk.failed+="$($Job.title) · $($Job.nativeId): $reason"; $bulk.streak++
        $log.AppendText("$(T 'GuiBulkItemFailed' $Job.title $Job.nativeId $reason)`r`n")
    }
    Continue-BulkBackup
}
function End-BulkBackup {
    $bulk=$script:Bulk; $script:Bulk=$null
    # 하지 않음: 시작하지 못했거나 취소한 대화와, 보류했지만 고르지 않은(또는 묻기 전에 멈춘) 대화. 고른 대화는 목록 끝에 다시 들어가 있다.
    $unpicked=$bulk.deferred.Count-[math]::Max($bulk.picked,0)
    $summary=T 'GuiBulkSummary' $bulk.done $bulk.skipped $bulk.busy.Count $bulk.failed.Count ($bulk.items.Count-$bulk.done-$bulk.busy.Count-$bulk.failed.Count-$bulk.deferred.Count+$unpicked)
    if ($bulk.deferred.Count) { $summary+=(T 'GuiBulkDeferredSummary' $bulk.deferred.Count ([math]::Max($bulk.picked,0))) }
    if ($bulk.streak -ge 3) { $summary+=(T 'GuiBulkStreakStop') } elseif ($bulk.stop) { $summary+=(T 'GuiBulkStopped') }
    $status.Text=$summary; $log.AppendText("$summary`r`n")
    if ($bulk.failed.Count) { Show-Error ("$summary`r`n`r`n" + (@($bulk.failed | Select-Object -First 10) -join "`r`n")) }
    # 새 백업이 목록에 보여야 다음 전체 백업이 같은 대화를 다시 올리지 않는다.
    if ($bulk.done -and -not $script:Pending) { Start-Job (Base-Job 'List'); $script:BulkSummary=$summary }
}
# 빈 칸·공백·잘못된 문자는 Test-Path가 예외를 내거나 현재 폴더로 풀므로 폴더가 아닌 것으로 본다.
function Test-Folder([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return (Test-Path -LiteralPath $Path -PathType Container) } catch { return $false }
}
function Show-Dialog([object]$Dialog) { return $Dialog.ShowDialog($form) }
function Browse-Folder([object]$Target) {
    $dialog=[Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description=(T 'GuiFolderDialog')
    if (Test-Folder $Target.Text) { $dialog.SelectedPath=$Target.Text }
    if ((Show-Dialog $dialog) -eq 'OK') { $Target.Text=$dialog.SelectedPath }
    $dialog.Dispose()
}
$form=[Windows.Forms.Form]::new()
$form.Text=(T 'GuiFormTitle')
$form.ClientSize=[Drawing.Size]::new(1080,730)
# 대화 표가 줄어들어 세로를 약 95px 낮출 수 있다(1366×768·150% 배율 화면의 작업 영역).
$form.MinimumSize=[Drawing.Size]::new(1096,675)
$form.StartPosition='CenterScreen'
$workingArea=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($form.Height -gt $workingArea.Height) { $form.Height=[Math]::Max($form.MinimumSize.Height,$workingArea.Height) }
$form.Font=[Drawing.Font]::new('맑은 고딕',10)
$form.BackColor=[Drawing.Color]::FromArgb(245,247,250)
$header=New-Control Label 24 18 1020 36 (T 'GuiHeader') $form
$header.Font=[Drawing.Font]::new('맑은 고딕',19,[Drawing.FontStyle]::Bold)
$null=New-Control Label 26 61 1010 26 (T 'GuiSubheader') $form
$tabs=New-Control TabControl 20 98 1040 486 '' $form
$tabs.Anchor='Top,Bottom,Left,Right'
$main=[Windows.Forms.TabPage]::new((T 'GuiTabMain')); $tabs.TabPages.Add($main)
$settings=[Windows.Forms.TabPage]::new((T 'GuiTabSettings')); $tabs.TabPages.Add($settings)
# 탭 페이지는 핸들이 생겨야 실제 크기가 된다. 그 전에 Anchor를 걸면 표가 창 밖까지 늘어난다.
$null=$tabs.Handle
$null=New-Control Label 16 17 74 25 (T 'GuiAgentLabel') $main
$agent=New-Control ComboBox 94 13 170 30 '' $main
$agent.DropDownStyle='DropDownList'; $agent.Items.AddRange(@('Claude Code','Codex Desktop'))
$agent.SelectedIndex=if ($script:Prefs.agent -eq 'codex-desktop') {1} else {0}
$null=New-Control Label 286 17 132 25 (T 'GuiSavedProjects') $main
$projectPicker=New-Control ComboBox 420 13 564 30 '' $main
$projectPicker.DropDownStyle='DropDownList'
$script:Bindings=@()
function Get-CtxConfig {
    # 연결된 저장소와 프로젝트 등록은 ctxhop이 쓰는 설정 파일이 기준이다. 없거나 읽지 못하면 $null.
    $configRoot=if ($env:CTXHOP_CONFIG_DIR) {$env:CTXHOP_CONFIG_DIR} else {Join-Path $env:USERPROFILE '.ctxhop'}
    $configFile=Join-Path $configRoot 'config.json'
    if (-not (Test-Path -LiteralPath $configFile)) { return $null }
    try { return (Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Load-Bindings {
    $script:Bindings=@(); $projectPicker.Items.Clear()
    $config=Get-CtxConfig
    if (-not $config) { return }
    $script:Bindings=@($config.projects.bindings | Where-Object { $_ -and $_.localRoot })
    foreach ($binding in $script:Bindings) { $projectPicker.Items.Add("$($binding.identity) · $($binding.localRoot)") | Out-Null }
}
function Show-ConnectedStore {
    # 연결된 뒤에는 칸에 이 PC가 실제로 쓰는 저장소를 보인다. 칸만 바뀐 채 적용된 것처럼 보이지 않게 한다.
    $config=Get-CtxConfig
    if ($config -and $config.remote.type -eq 'dir' -and $config.remote.path) { $store.Text=[string]$config.remote.path }
}
function Start-StoreMove {
    $job=Base-Job 'MoveStore'
    $config=Get-CtxConfig
    if (-not $config -or -not $config.remote.path) { throw (T 'CwSetupFirst') }
    if (Confirm (T 'GuiMoveStoreConfirm' ([string]$config.remote.path) $job.store "`r`n")) { Start-Job $job } else { Show-ConnectedStore }
}
Load-Bindings
$null=New-Control Label 16 60 74 25 (T 'GuiProjectLabel') $main
$project=New-Control TextBox 94 56 740 28 $script:Prefs.projectPath $main
$null=New-Button 844 51 140 (T 'GuiBrowseFolder') $main { Browse-Folder $project }
$null=New-Control Label 16 102 74 25 (T 'GuiIdentityLabel') $main
$identity=New-Control TextBox 94 98 355 28 $script:Prefs.identity $main
$registerButton=New-Button 466 92 146 (T 'GuiRegisterProject') $main { Start-Job (Base-Job 'Bind') }
$null=New-Button 630 92 175 (T 'GuiLoadList') $main { Start-Job (Base-Job 'List') }
$unbindButton=New-Button 818 92 166 (T 'GuiUnbindProject') $main {
    $job=Base-Job 'Unbind'
    if (-not $job.projectPath -or -not $job.identity) { throw (T 'CwBindInputRequired') }
    if (Confirm (T 'GuiUnbindConfirm' $job.identity "`r`n" $job.projectPath)) { Start-Job $job }
}
$null=New-Control Label 16 140 74 25 (T 'GuiSearchLabel') $main
$search=New-Control TextBox 94 136 355 28 '' $main
$view=New-Control ComboBox 466 136 146 28 '' $main; $view.DropDownStyle='DropDownList'; $view.Items.AddRange(@((T 'GuiViewAll'),(T 'GuiViewLocal'),(T 'GuiViewShared'))); $view.SelectedIndex=0
$dateFilter=New-Control ComboBox 630 136 175 28 '' $main; $dateFilter.DropDownStyle='DropDownList'; $dateFilter.Items.AddRange(@((T 'GuiDateAll'),(T 'GuiDate7'),(T 'GuiDate30'))); $dateFilter.SelectedIndex=0
$countLabel=New-Control Label 16 172 440 24 (T 'GuiCountInitial') $main
$projectOnly=New-Control CheckBox 466 169 330 28 (T 'GuiProjectOnly') $main; $projectOnly.Checked=$true
$projectOnly.Add_CheckedChanged({ $script:Page=0; Apply-Filter })
$prevButton=New-Button 806 164 82 (T 'GuiPrevPage') $main { if ($script:Page -gt 0) { $script:Page--; Apply-Filter } }
$nextButton=New-Button 902 164 82 (T 'GuiNextPage') $main { $script:Page++; Apply-Filter }
$grid=New-Control DataGridView 16 205 988 174 '' $main
$grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false
$grid.RowHeadersVisible=$false; $grid.SelectionMode='FullRowSelect'; $grid.MultiSelect=$false
$grid.BackgroundColor=[Drawing.Color]::White
$grid.Anchor='Top,Bottom,Left,Right'; $grid.AutoGenerateColumns=$false
foreach ($column in @(@('title',(T 'GuiColConversation'),190),@('agent',(T 'GuiColAgent'),95),@('updated',(T 'GuiColUpdated'),105),@('local',(T 'GuiColLocal'),50),@('backup',(T 'GuiColBackup'),70),@('id',(T 'GuiColSessionId'),180),@('context',(T 'GuiColContext'),185))) {
    $c=[Windows.Forms.DataGridViewTextBoxColumn]::new(); $c.Name=$column[0]; $c.HeaderText=$column[1]; $c.FillWeight=$column[2]; $grid.Columns.Add($c) | Out-Null
}
$grid.AutoSizeColumnsMode='Fill'
# 세션 UUID와 날짜가 잘리지 않을 최소 너비(맑은 고딕 10pt 기준).
$grid.Columns['id'].MinimumWidth=300; $grid.Columns['updated'].MinimumWidth=135
$selectionLabel=New-Control Label 16 384 720 24 (T 'GuiNoSelection') $main; $selectionLabel.Anchor='Bottom,Left,Right'
$projectFiles=New-Control CheckBox 740 381 264 28 (T 'GuiProjectFiles') $main; $projectFiles.Checked=($script:Prefs.projectFiles -ne 'off'); $projectFiles.Anchor='Bottom,Right'
$backupButton=New-Button 16 411 220 (T 'GuiBackupSelected') $main {
    $job=Selected-Job 'Backup'
    $question=if ($job.agent -eq 'codex-desktop') { T 'GuiBackupConfirmDesktop' } else { T 'GuiBackupConfirm' }
    if (Confirm "$(T 'GuiFieldSession' $job.title)`r`n$(T 'GuiFieldAgent' $job.agent)`r`nID: $($job.nativeId)`r`n$(T 'GuiFieldProject' $job.identity)`r`n`r`n$question") { Start-Job $job }
}
$restoreButton=New-Button 252 411 220 (T 'GuiPreviewRestore') $main { if ($agent.SelectedIndex -eq 1) { Start-DesktopPreview } else { Start-Job (Selected-Job 'Preview') } }
$openButton=New-Button 488 411 200 (T 'GuiOpenSelected') $main { Start-Job (Selected-Job 'Open') }
$script:SessionButtons=@($backupButton,$restoreButton,$openButton)
foreach ($button in $script:SessionButtons) { $button.Anchor='Bottom,Left' }
# Codex 대화는 GUI가 열지 않으므로 Codex Desktop에서는 열기 버튼 자리에 전체 백업을 둔다.
$bulkButton=New-Button 488 411 200 (T 'GuiBackupFiltered') $main { Start-BulkBackup }; $bulkButton.Anchor='Bottom,Left'
$grid.Add_SelectionChanged({ Update-Selection })
Update-Selection
$driveHint=New-Control Label 708 416 296 32 (T 'GuiDriveHint') $main; $driveHint.Anchor='Bottom,Left'
$null=New-Control Label 22 22 970 42 (T 'GuiSettingsIntro') $settings
$null=New-Control Label 22 84 150 25 (T 'GuiStorePath') $settings
$store=New-Control TextBox 182 80 640 28 $script:Prefs.store $settings
Show-ConnectedStore
$null=New-Button 834 74 142 (T 'GuiBrowseFolder') $settings { Browse-Folder $store }
$null=New-Control Label 22 130 150 25 (T 'GuiInviteLabel') $settings
$invite=New-Control TextBox 182 126 640 28 $script:Prefs.invite $settings
$null=New-Button 834 120 142 (T 'GuiChooseFile') $settings {
    $d=[Windows.Forms.OpenFileDialog]::new(); $d.Filter=(T 'GuiInviteFilter')
    if ($d.ShowDialog($form) -eq 'OK') { $invite.Text=$d.FileName }; $d.Dispose()
}
$null=New-Control Label 22 176 150 25 (T 'GuiDeviceName') $settings
$device=New-Control TextBox 182 172 340 28 $script:Prefs.deviceName $settings
$null=New-Control Label 560 176 120 25 'Language / 언어' $settings
$languagePicker=New-Control ComboBox 684 172 138 28 '' $settings
$languagePicker.DropDownStyle='DropDownList'; $languagePicker.Items.AddRange(@('한국어','English'))
$languagePicker.SelectedIndex=if ($script:UiLanguage -eq 'en') {1} else {0}
$null=New-Button 22 225 240 (T 'GuiSetupJoin') $settings { Start-Job (Base-Job 'Setup') }
$null=New-Button 278 225 200 (T 'GuiCheckConnection') $settings { Start-Job (Base-Job 'Status') }
$null=New-Button 748 225 228 (T 'GuiMoveStore') $settings { Start-StoreMove }
$null=New-Button 494 225 238 (T 'GuiCreateInvite') $settings {
    $d=[Windows.Forms.SaveFileDialog]::new(); $d.Filter=(T 'GuiInviteFilter'); $d.FileName='ctxhop-invite.json'
    if (Test-Folder $store.Text) { $d.InitialDirectory=$store.Text }
    if ((Show-Dialog $d) -eq 'OK') { $job=Base-Job 'Invite'; $job.output=$d.FileName; Start-Job $job }; $d.Dispose()
}
$null=New-Control Label 22 278 150 25 (T 'GuiCodexDataFolder') $settings
$desktopHome=New-Control TextBox 182 274 640 28 $script:Prefs.home $settings
$null=New-Button 834 268 142 (T 'GuiBrowseFolder') $settings { Browse-Folder $desktopHome }
$null=New-Button 22 318 240 (T 'GuiPassphraseChange') $settings { if (Confirm (T 'GuiPassphraseChangeConfirm')) { Start-Job (Base-Job 'PassphraseChange') } }
$null=New-Button 278 318 300 (T 'GuiPassphraseReset') $settings { if (Confirm (T 'GuiPassphraseResetConfirm')) { Start-Job (Base-Job 'PassphraseReset') } }
$journalButton=New-Button 594 318 240 (T 'GuiJournalButton') $settings { Start-Job (Base-Job 'Journal') }
$null=New-Control Label 22 368 956 76 "$(T 'GuiSettingsNote1')`r`n$(T 'GuiSettingsNote2')`r`n$(T 'GuiSettingsNote3')" $settings
# 창을 줄이면 설정 탭 아래쪽은 스크롤로 본다.
$settings.AutoScroll=$true
$status=New-Control Label 24 595 860 38 (T 'GuiStatusInitial') $form
function Stop-ProcessTree([int]$Id) {
    # 프로세스 표를 한 번만 읽어 트리를 정하고, 부모부터 끝내 끝내는 사이 새 자식이 생기지 않게 한다.
    # Windows는 부모가 끝나도 ParentProcessId를 그대로 두고 PID를 재사용하므로, 부모보다 먼저 생긴 "자식"은 다른 프로그램의 것으로 보고 건드리지 않는다.
    $all=@(Get-CimInstance Win32_Process)
    $tree=@($all | Where-Object { $_.ProcessId -eq $Id })
    for ($i=0; $i -lt $tree.Count; $i++) {
        $parent=$tree[$i]
        $tree+=@($all | Where-Object { $_.ParentProcessId -eq $parent.ProcessId -and $_.CreationDate -gt $parent.CreationDate })
    }
    foreach ($process in $tree) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
}
$cancelButton=New-Button 900 591 148 (T 'GuiCancelJob') $form {
    $pending=$script:Pending
    if (-not $pending -or $pending.job.action -in @('Restore','Open','MoveStore','Rollback','CloseJournal')) { return }
    # 전체 백업은 처음 누르면 지금 대화를 마친 뒤 멈추고, 한 번 더 누르면 아래처럼 작업 창을 바로 끝낸다.
    if ($script:Bulk -and -not $script:Bulk.stop) { $script:Bulk.stop=$true; $status.Text=(T 'GuiBulkStopping'); return }
    if ($pending.job.action -ne 'List' -and -not (Confirm (T 'GuiCancelConfirm' $pending.job.action))) { return }
    # 확인 창이 떠 있는 동안 작업이 끝났으면 그 결과를 그대로 보여 주고, 이어서 시작된 작업도 건드리지 않는다.
    if (-not [object]::ReferenceEquals($pending,$script:Pending) -or $pending.process.HasExited) { return }
    $pending.cancelled=$true
    $cancelButton.Enabled=$false
    # 작업 창과 그 안의 ctxhop·Python까지 끝낸다. 결과는 Finish-Job이 버린다.
    if (-not $pending.process.HasExited) { Stop-ProcessTree $pending.process.Id }
    $status.Text=(T 'GuiCancelling')
}
$cancelButton.Enabled=$false; $cancelButton.Anchor='Bottom,Right'
$tips=[Windows.Forms.ToolTip]::new()
$tips.SetToolTip($backupButton,(T 'GuiTipBackup')); $tips.SetToolTip($restoreButton,(T 'GuiTipRestore')); $tips.SetToolTip($openButton,(T 'GuiTipOpen'))
$tips.SetToolTip($registerButton,(T 'GuiTipRegister')); $tips.SetToolTip($unbindButton,(T 'GuiTipUnbind')); $tips.SetToolTip($cancelButton,(T 'GuiTipCancel'))
$tips.SetToolTip($bulkButton,(T 'GuiTipBulkBackup')); $tips.SetToolTip($projectOnly,(T 'GuiTipProjectOnly')); $tips.SetToolTip($projectFiles,(T 'GuiTipProjectFiles'))
# 꺼진 버튼은 툴팁을 띄우지 않으므로, 마우스 아래의 꺼진 버튼 설명을 그 버튼이 놓인 탭·창의 툴팁으로 대신 띄운다.
foreach ($surface in @($main,$form)) {
    $surface.Add_MouseMove({
        param($sender,$e)
        $hit=$sender.GetChildAtPoint($e.Location)
        $text=if ($hit -and -not $hit.Enabled) {$tips.GetToolTip($hit)} else {''}
        if ($tips.GetToolTip($sender) -ne $text) { $tips.SetToolTip($sender,$text) }
    })
}
$status.Anchor='Bottom,Left,Right'
$progress=New-Control ProgressBar 24 634 1025 8 '' $form; $progress.Anchor='Bottom,Left,Right'
$log=New-Control TextBox 24 651 1025 58 '' $form; $log.Multiline=$true; $log.ReadOnly=$true; $log.ScrollBars='Vertical'; $log.Anchor='Bottom,Left,Right'
function Set-AgentMode {
    $desktop=$agent.SelectedIndex -eq 1
    $grid.MultiSelect=$desktop; $openButton.Visible=-not $desktop; $bulkButton.Visible=$desktop; $projectOnly.Visible=$desktop
}
$agent.Add_SelectedIndexChanged({ Set-AgentMode; $projectPicker.Enabled=($agent.SelectedIndex -eq 0); Fill-Sessions @(); Save-Prefs })
Set-AgentMode
$desktopHome.Add_TextChanged({ if ($script:Sessions.Count) { Fill-Sessions @() } })
$project.Add_TextChanged({ if ($script:Sessions.Count) { Fill-Sessions @() } })
$identity.Add_TextChanged({ if ($script:Sessions.Count) { Fill-Sessions @() } })
$projectPicker.Add_SelectedIndexChanged({
    if ($projectPicker.SelectedIndex -ge 0) { $b=$script:Bindings[$projectPicker.SelectedIndex]; $project.Text=$b.localRoot; $identity.Text=$b.identity }
})
$filterTimer=[Windows.Forms.Timer]::new(); $filterTimer.Interval=250
$filterTimer.Add_Tick({ $filterTimer.Stop(); $script:Page=0; Apply-Filter })
$search.Add_TextChanged({ $filterTimer.Stop(); $filterTimer.Start() })
$view.Add_SelectedIndexChanged({ $script:Page=0; Apply-Filter })
$dateFilter.Add_SelectedIndexChanged({ $script:Page=0; Apply-Filter })
$languagePicker.Add_SelectedIndexChanged({ Save-Prefs; $status.Text=$script:StringTable.GuiLanguageRestart[$languagePicker.SelectedIndex] })
$timer=[Windows.Forms.Timer]::new(); $timer.Interval=350; $timer.Add_Tick({ Finish-Job }); $timer.Start()
$form.Add_FormClosing({
    if ($script:Pending) { $_.Cancel=$true; Show-Error (T 'GuiCloseWhilePending') }
    else { Save-Prefs }
})
if ($SmokeTest) {
    $project.Text='D:\projects\sample'; $identity.Text='sample-project'
    Fill-Sessions @(
        [pscustomobject]@{title='Fix login error and plan next steps'; agent='claude-code'; updatedAt='2026-09-26 14:10'; local=$true; recordCount=24; nativeId='11111111-1111-4111-8111-111111111111';remoteId=('a'*25+'0')},
        [pscustomobject]@{title='Validate API responses'; agent='claude-code'; updatedAt='2026-09-25 18:42'; local=$false; recordCount=18; nativeId='22222222-2222-4222-8222-222222222222';remoteId=('b'*25+'0')}
    )
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    if ($grid.Rows.Count -ne 2 -or $script:Buttons.Count -lt 8) { throw 'GUI smoke test failed' }
    if ($ScreenshotPath) {
        $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
        $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height))
        $bitmap.Save($ScreenshotPath,[Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
    }
    $form.Close(); $timer.Dispose(); $filterTimer.Dispose(); $form.Dispose()
    Write-Output 'PASS: GUI constructed, session rows, actions, and bitmap rendering.'
    return
}
[Windows.Forms.Application]::Run($form)
$timer.Dispose(); $filterTimer.Dispose(); $form.Dispose()
