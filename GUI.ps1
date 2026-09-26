#requires -Version 5.1
[CmdletBinding()]
param([switch]$SmokeTest, [string]$ScreenshotPath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:PrefsPath = Join-Path $env:LOCALAPPDATA 'CtxHopGUI\vnext-preferences.json'
$script:Prefs = [pscustomobject]@{projectPath=''; identity=''; agent='claude-code'; store='G:\내 드라이브\세션연동'; invite=''; deviceName=$env:COMPUTERNAME; home=$(if ($env:CODEX_HOME) {$env:CODEX_HOME} else {Join-Path $env:USERPROFILE '.codex'})}
if (Test-Path -LiteralPath $script:PrefsPath) {
    try {
        $saved=Get-Content -LiteralPath $script:PrefsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $script:Prefs.PSObject.Properties) {
            if ($saved.PSObject.Properties.Name -contains $property.Name -and $saved.($property.Name) -is [string]) { $script:Prefs.($property.Name)=$saved.($property.Name) }
        }
    } catch {}
}
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
    $log.AppendText("`r`n오류: $Message`r`n")
    [Windows.Forms.MessageBox]::Show($form,$Message,'작업을 진행할 수 없습니다','OK','Warning') | Out-Null
}
function Confirm([string]$Message) { return [Windows.Forms.MessageBox]::Show($form,$Message,'확인','YesNo','Question') -eq 'Yes' }
function Save-Prefs {
    $script:Prefs.projectPath=$project.Text.Trim().Trim('"')
    $script:Prefs.identity=$identity.Text.Trim()
    $script:Prefs.agent=if ($agent.SelectedIndex -eq 1) {'codex-desktop'} else {'claude-code'}
    $script:Prefs.store=$store.Text.Trim().Trim('"')
    $script:Prefs.invite=$invite.Text.Trim().Trim('"')
    $script:Prefs.deviceName=$device.Text.Trim()
    $script:Prefs.home=$desktopHome.Text.Trim().Trim('"')
    if (-not $SmokeTest) {
        New-Item -ItemType Directory -Path (Split-Path $script:PrefsPath) -Force | Out-Null
        $script:Prefs | ConvertTo-Json | Set-Content -LiteralPath $script:PrefsPath -Encoding UTF8
    }
}
function Base-Job([string]$Action) {
    Save-Prefs
    return @{action=$Action; projectPath=$script:Prefs.projectPath; identity=$script:Prefs.identity; agent=$script:Prefs.agent; store=$script:Prefs.store; invite=$script:Prefs.invite; deviceName=$script:Prefs.deviceName;home=$script:Prefs.home;search=$search.Text.Trim()}
}
function Selected-Job([string]$Action) {
    $job = Base-Job $Action
    if (-not $grid.SelectedRows.Count) { throw '목록에서 대화 한 개를 선택하세요.' }
    if ($grid.SelectedRows.Count -ne 1) { throw '백업할 대화 한 개를 선택하세요. 복원 미리보기는 여러 항목을 선택할 수 있습니다.' }
    $session = $grid.SelectedRows[0].Tag
    if ($session.agent -ne $job.agent) { throw '에이전트를 바꿨습니다. 목록을 새로 불러오세요.' }
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
function Filter-Metadata([object[]]$Items, [string]$Query, [string]$Mode, [int]$Days) {
    $cutoff=if ($Days -gt 0) {(Get-Date).AddDays(-$Days)} else {[datetime]::MinValue}
    @($Items | Where-Object {
        $matches=(-not $Query -or ([string]$_.title).IndexOf($Query,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.nativeId).IndexOf($Query,[StringComparison]::OrdinalIgnoreCase) -ge 0 -or ([string]$_.sourceCwd).IndexOf($Query,[StringComparison]::OrdinalIgnoreCase) -ge 0)
        $date=[datetime]::MinValue
        $null=[datetime]::TryParse([string]$_.updatedAt,[ref]$date)
        $matches -and ($Mode -ne 'local' -or $_.local) -and ($Mode -ne 'remote' -or $_.recordCount -gt 0) -and $date -ge $cutoff
    } | Sort-Object updatedAt -Descending)
}
function Apply-Filter {
    $selected=if ($grid.SelectedRows.Count) {$grid.SelectedRows[0].Tag} else {$null}
    $mode=switch ($view.SelectedIndex) {1 {'local'} 2 {'remote'} default {'all'}}
    $days=switch ($dateFilter.SelectedIndex) {1 {7} 2 {30} default {0}}
    $script:Filtered=@(Filter-Metadata $script:Sessions $search.Text.Trim() $mode $days)
    $pages=[math]::Max(1,[math]::Ceiling($script:Filtered.Count/$script:PageSize))
    $script:Page=[math]::Max(0,[math]::Min($script:Page,$pages-1))
    $grid.SuspendLayout(); $grid.Rows.Clear()
    $visible=@($script:Filtered | Select-Object -Skip ($script:Page*$script:PageSize) -First $script:PageSize)
    foreach ($item in $visible) {
        $title = [regex]::Replace([string]$item.title, '[\x00-\x1f\x7f-\x9f]', ' ')
        $label = if ($item.agent -eq 'codex-desktop') {'Codex Desktop'} else {'Claude Code'}
        $local = if ($item.local) {'있음'} else {'없음'}
        $backup = if ($item.blockedReason) {'작업 불가'} elseif ($item.remoteId -and $item.agent -eq 'codex-desktop') {'공유 백업'} elseif ($item.recordCount -gt 0) {'있음'} else {'미백업'}
        $context=if ($item.agent -eq 'codex-desktop') {"$($item.sourceCwd) · $($item.historyMode)" + $(if ($item.archived) {' · 보관됨'} else {''})} else {''}
        $index = $grid.Rows.Add($title,$label,[string]$item.updatedAt,$local,$backup,[string]$item.nativeId,$context)
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
    $countLabel.Text="일치 $($script:Filtered.Count) / 전체 $($script:Sessions.Count) · 페이지 $($script:Page+1)/$pages"
    $status.Text = if ($agent.SelectedIndex -eq 1) {'Codex 전체 프로젝트·보관 목록입니다. 목록 조회는 읽기 전용이며 백업·복원 전에는 Codex 앱을 직접 종료하세요.'} else {'현재 Claude 프로젝트의 목록입니다. 대화를 직접 선택한 뒤 백업 또는 복원하세요.'}
}
function Update-Selection {
    if (-not $script:SessionButtons.Count) { return }
    $selected=if ($grid.SelectedRows.Count) { $grid.SelectedRows[0].Tag } else { $null }
    $script:SessionButtons[0].Enabled=($null -ne $selected -and $grid.SelectedRows.Count -eq 1 -and $selected.local -and -not $selected.blockedReason -and -not $script:Pending)
    $desktop=$agent.SelectedIndex -eq 1
    $script:SessionButtons[1].Enabled=($null -ne $selected -and -not $script:Pending -and $(if ($desktop) {@($grid.SelectedRows | Where-Object { -not $_.Tag.local -and $_.Tag.remoteId -and -not $_.Tag.blockedReason }).Count -eq $grid.SelectedRows.Count} else {$selected.recordCount -gt 0}))
    $script:SessionButtons[2].Enabled=($null -ne $selected -and $selected.local -and -not $desktop -and -not $script:Pending)
    if ($selected) { $selectionLabel.Text="선택: $($selected.title) · $($selected.nativeId)" + $(if ($selected.blockedReason) {" · 작업 불가: $($selected.blockedReason)"} else {''}) } else { $selectionLabel.Text='선택한 대화 없음 · 자동으로 최신 대화를 선택하지 않습니다.' }
}
function Start-Job([hashtable]$Job) {
    if ($script:Pending) { throw '현재 작업이 끝날 때까지 기다리세요.' }
    if ($SmokeTest) { throw '화면 검증 모드에서는 실제 작업을 실행하지 않습니다.' }
    $runtime = Join-Path $env:LOCALAPPDATA 'CtxHopGUI\jobs'
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $request = Join-Path $runtime "$id.request.json"
    $result = Join-Path $runtime "$id.result.json"
    $Job | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $request -Encoding UTF8
    # Windows 파일명에는 따옴표를 넣을 수 없으므로 각 검증된 절대경로만 인수로 인용한다.
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "{0}" -RequestFile "{1}" -ResultFile "{2}"' -f (Join-Path $PSScriptRoot 'Worker.ps1'),$request,$result
    $windowStyle=if ($Job.agent -eq 'codex-desktop' -and $Job.action -notin @('Setup','Invite')) {'Hidden'} else {'Normal'}
    # Claude and explicitly selected setup/invite operations retain their interactive native input window.
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -PassThru -WindowStyle $windowStyle
    $script:Pending = @{process=$process; job=$Job; request=$request; result=$result}
    foreach ($button in $script:Buttons) { $button.Enabled=$false }
    $cancelButton.Enabled=($Job.action -eq 'List')
    $agent.Enabled=$false; $project.ReadOnly=$true; $identity.ReadOnly=$true
    $projectPicker.Enabled=$false; $desktopHome.ReadOnly=$true
    $progress.Style='Marquee'
    $status.Text='처리 중 · Codex 앱을 강제로 종료하지 않습니다. 암호가 필요하면 작업 입력 창에서 입력하세요.'
    $log.AppendText("`r`n$($Job.action) 시작 · $($Job.agent)`r`n")
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
    try {
        if ($pending.cancelled) { $status.Text='목록 결과를 취소했습니다. 대화 파일은 변경하지 않았습니다.'; return }
        if (-not (Test-Path -LiteralPath $pending.result)) { throw '작업 창이 중단되었습니다. 복원 작업이었다면 복구 기록을 확인하세요.' }
        $result = Get-Content -LiteralPath $pending.result -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($pending.job.agent -eq 'codex-desktop' -and $pending.job.action -eq 'Preview') {
            if ($result.ok) { Add-DesktopReview $pending.job $result.data.preview $result.data.receipt } else { Add-DesktopReview $pending.job ([pscustomobject]@{status='blocked';reason=[string]$result.error;token='';source=$null;target=$null}) '' }
            Continue-DesktopPreview
            return
        }
        if (-not $result.ok) {
            $script:DesktopApplyQueue=@()
            $errorMessage=[string]$result.error
            if ($result.backendResult) { $errorMessage+="`r`n복구 기록: " + ($result.backendResult | ConvertTo-Json -Depth 15 -Compress) }
            throw $errorMessage
        }
        $status.Text=$result.data.message
        $log.AppendText("$($result.data.message)`r`n")
        switch ($pending.job.action) {
            List { Fill-Sessions @($result.data.sessions); if ($result.data.excluded -gt 0) { $status.Text += " · 메타데이터 미확인 $($result.data.excluded)개는 작업 불가" } }
            Status {
                $log.AppendText("장치: $($result.data.device) · 저장소: $($result.data.store) · 설정 동기화: $($result.data.syncConfig)`r`n")
            }
            Preview {
                $p=$result.data.preview
                $summary="선택한 대화: $($pending.job.title)`r`n대화 ID: $($p.session)`r`n에이전트: $($p.agent)`r`n프로젝트: $($pending.job.identity)`r`n작업 폴더: $($p.workspace)`r`n차이: $($p.differences)`r`n`r`n원본 PC의 에이전트 종료와 Drive 다운로드 완료를 확인했나요? 복원할까요?"
                if (Confirm $summary) {
                    $job=$pending.job; $job.action='Restore'
                    Start-Job $job
                }
            }
            Restore {
                if ($pending.job.agent -eq 'codex-desktop') { Continue-DesktopApply; break }
                $id=$result.data.restored.session
                if (Confirm "복원했습니다. $id 대화를 지금 열까요?") {
                    $job=$pending.job; $job.action='Open'; $job.nativeId=$id
                    Start-Job $job
                }
            }
        }
    } catch { Show-Error $_.Exception.Message }
    finally {
        foreach ($file in @($pending.request,$pending.result)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } }
        $pending.process.Dispose()
    }
}
function Add-DesktopReview([hashtable]$Job,[object]$Preview,[string]$Receipt) {
    if ($Preview.status -notin @('new','equal','incoming_newer','local_newer','conflict','blocked')) { $Preview=[pscustomobject]@{status='blocked';reason='알 수 없는 검사 상태';token='';source=$null;target=$null} }
    $script:DesktopReviews += [pscustomobject]@{job=$Job;preview=$Preview;receipt=$Receipt}
}
function Start-DesktopPreview {
    $script:DesktopReviews=@(); $script:DesktopPreviewQueue=@()
    foreach ($row in @($grid.SelectedRows | Sort-Object Index)) {
        $item=$row.Tag
        if ($item.agent -ne 'codex-desktop' -or $item.local -or -not $item.remoteId -or $item.blockedReason) { throw '복원할 Codex 공유 백업 행만 선택하세요.' }
        $job=Base-Job 'Preview'; $job.nativeId=$item.nativeId; $job.remoteId=$item.remoteId; $job.title=$item.title; $job.sourceCwd=$item.sourceCwd
        $script:DesktopPreviewQueue+=,$job
    }
    if (-not $script:DesktopPreviewQueue.Count) { throw '복원할 공유 백업을 선택하세요.' }
    Continue-DesktopPreview
}
function Get-DesktopDecisions([object]$Table) {
    $decisions=@()
    foreach ($row in $Table.Rows) {
        $review=$row.Tag; $choice=[string]$row.Cells['choice'].Value
        if ($choice -eq '공유 백업 복원') {
            if ($review.preview.status -eq 'blocked' -or -not $review.receipt -or -not $review.preview.token) { throw '손상·호환 불가 항목은 복원할 수 없습니다.' }
            $job=$review.job.Clone(); $job.action='Restore'; $job.receipt=$review.receipt; $job.token=$review.preview.token; $job.choice='incoming'
            $decisions+=,$job
        } elseif ($choice -notin @('건너뛰기','로컬 유지')) { throw '항목마다 선택을 확인하세요.' }
    }
    $duplicates=@($decisions | Group-Object nativeId | Where-Object Count -gt 1)
    if ($duplicates.Count) { throw '같은 UUID의 공유 백업 여러 개를 동시에 복원할 수 없습니다. 해당 대화에서 복원할 백업 한 개를 직접 고르고 나머지는 유지·건너뛰기로 두세요.' }
    return $decisions
}
function New-DesktopReviewDialog([object[]]$Reviews) {
    $dialog=[Windows.Forms.Form]::new(); $dialog.Text='Codex 복원 전 항목별 확인'; $dialog.ClientSize=[Drawing.Size]::new(1180,480)
    $dialog.StartPosition='CenterParent'; $dialog.Font=[Drawing.Font]::new('맑은 고딕',10); $dialog.MinimumSize=[Drawing.Size]::new(1196,519)
    $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false
    $null=New-Control Label 16 12 1148 42 '모든 항목은 건너뛰기가 기본입니다. 서로 갈라진 기록은 항목마다 로컬 유지 또는 공유 백업 복원을 직접 선택하세요.' $dialog
    $table=New-Control DataGridView 16 58 1148 295 '' $dialog
    $table.AllowUserToAddRows=$false; $table.AllowUserToDeleteRows=$false; $table.RowHeadersVisible=$false; $table.AutoGenerateColumns=$false; $table.AutoSizeColumnsMode='Fill'
    $table.DefaultCellStyle.WrapMode='True'
    foreach ($column in @(@('title','대화 / 백업 ID',170),@('id','UUID',150),@('source','원본 작업 폴더',155),@('target','이 PC 작업 폴더',155),@('state','내용 검사',105),@('reason','검사 사유',170))) {
        $c=[Windows.Forms.DataGridViewTextBoxColumn]::new(); $c.Name=$column[0]; $c.HeaderText=$column[1]; $c.FillWeight=$column[2]; $c.ReadOnly=$true; $table.Columns.Add($c)|Out-Null
    }
    $choiceColumn=[Windows.Forms.DataGridViewComboBoxColumn]::new(); $choiceColumn.Name='choice'; $choiceColumn.HeaderText='직접 선택'; $choiceColumn.FillWeight=150; $choiceColumn.Items.AddRange(@('건너뛰기','로컬 유지','공유 백업 복원')); $table.Columns.Add($choiceColumn)|Out-Null
    $stateLabels=@{new='이 PC에 없음';equal='내용 같음';incoming_newer='공유 기록 연장';local_newer='로컬 기록 연장';conflict='기록 갈라짐';blocked='복원 불가'}
    foreach ($review in $Reviews) {
        $p=$review.preview; $j=$review.job
        $index=$table.Rows.Add(($j.title+"`r`n"+$j.remoteId),$j.nativeId,$j.sourceCwd,$j.projectPath,$stateLabels[$p.status],[string]$p.reason,'건너뛰기')
        $row=$table.Rows[$index]; $row.Tag=$review; $row.Height=52
        if ($p.status -eq 'blocked') {
            $cell=[Windows.Forms.DataGridViewComboBoxCell]::new(); $cell.Items.AddRange(@('건너뛰기','로컬 유지')); $cell.Value='건너뛰기'; $row.Cells['choice']=$cell
            $row.DefaultCellStyle.BackColor=[Drawing.Color]::MistyRose
        } elseif ($p.status -in @('conflict','local_newer')) { $row.DefaultCellStyle.BackColor=[Drawing.Color]::LightYellow }
    }
    $table.ClearSelection()
    $details=New-Control TextBox 16 363 1148 42 '' $dialog; $details.Multiline=$true; $details.ReadOnly=$true; $details.ScrollBars='Vertical'
    $table.Add_SelectionChanged({
        if ($table.SelectedRows.Count) { $review=$table.SelectedRows[0].Tag; $details.Text="UUID: $($review.job.nativeId) · 백업: $($review.job.remoteId)`r`n원본: $($review.job.sourceCwd) → 이 PC: $($review.job.projectPath) · $($review.preview.reason)" }
    }.GetNewClosure())
    $accept=New-Control Button 854 415 160 38 '선택 검토 후 계속' $dialog; $accept.DialogResult='OK'
    $cancel=New-Control Button 1028 415 136 38 '전체 취소' $dialog; $cancel.DialogResult='Cancel'
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
            if (-not $decisions.Count) { $status.Text='모든 항목을 유지·건너뛰기로 선택했습니다. 복원하지 않았습니다.'; return }
            $summary=($decisions | ForEach-Object {"$($_.title) · $($_.nativeId) · $($_.remoteId)`r`n복원 폴더: $($_.projectPath)"}) -join "`r`n`r`n"
            if (Confirm "선택한 $($decisions.Count)개 항목을 복원합니다.`r`n원본은 백엔드 복구 기록으로 보관합니다. Codex 앱을 직접 종료하고 Drive 다운로드 완료를 확인하세요.`r`n`r`n$summary") { $script:DesktopApplyQueue=$decisions; Continue-DesktopApply }
            return
        }
        $status.Text='복원 확인을 취소했습니다. 로컬 대화를 변경하지 않았습니다.'
    } finally { $reviewUI.dialog.Dispose() }
}
function Continue-DesktopApply {
    if ($script:DesktopApplyQueue.Count) {
        $next=$script:DesktopApplyQueue[0]; $script:DesktopApplyQueue=@($script:DesktopApplyQueue | Select-Object -Skip 1)
        Start-Job $next
    } else { $status.Text='선택한 Codex 항목 처리를 마쳤습니다. 항목별 결과(복원 완료/변경 없음)는 아래 기록에서 확인하세요.' }
}
function Browse-Folder([object]$Target) {
    $dialog=[Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description='폴더 선택'
    if (Test-Path -LiteralPath $Target.Text) { $dialog.SelectedPath=$Target.Text }
    if ($dialog.ShowDialog($form) -eq 'OK') { $Target.Text=$dialog.SelectedPath }
    $dialog.Dispose()
}
$form=[Windows.Forms.Form]::new()
$form.Text='CtxHop vNext 후보 · Claude Code & Codex Desktop'
$form.ClientSize=[Drawing.Size]::new(1080,730)
$form.MinimumSize=[Drawing.Size]::new(1096,769)
$form.FormBorderStyle='FixedSingle'; $form.MaximizeBox=$false
$form.StartPosition='CenterScreen'
$form.Font=[Drawing.Font]::new('맑은 고딕',10)
$form.BackColor=[Drawing.Color]::FromArgb(245,247,250)
$header=New-Control Label 24 18 1020 36 '대화를 옮기고, 그대로 이어가세요' $form
$header.Font=[Drawing.Font]::new('맑은 고딕',19,[Drawing.FontStyle]::Bold)
$null=New-Control Label 26 61 1010 26 'Claude Code · Codex Desktop 전체 프로젝트 / 보관 대화 · 프로젝트 파일은 별도로 준비하세요' $form
$tabs=New-Control TabControl 20 98 1040 486 '' $form
$tabs.Anchor='Top,Bottom,Left,Right'
$main=[Windows.Forms.TabPage]::new('대화 백업 · 복원'); $tabs.TabPages.Add($main)
$settings=[Windows.Forms.TabPage]::new('연결 설정 · 초대'); $tabs.TabPages.Add($settings)
$null=New-Control Label 16 17 74 25 '에이전트' $main
$agent=New-Control ComboBox 94 13 170 30 '' $main
$agent.DropDownStyle='DropDownList'; $agent.Items.AddRange(@('Claude Code','Codex Desktop'))
$agent.SelectedIndex=if ($script:Prefs.agent -eq 'codex-desktop') {1} else {0}
$null=New-Control Label 286 17 132 25 '등록된 프로젝트' $main
$projectPicker=New-Control ComboBox 420 13 564 30 '' $main
$projectPicker.DropDownStyle='DropDownList'
$script:Bindings=@()
$configRoot=if ($env:CTXHOP_CONFIG_DIR) {$env:CTXHOP_CONFIG_DIR} else {Join-Path $env:USERPROFILE '.ctxhop'}
$configFile=Join-Path $configRoot 'config.json'
if (Test-Path -LiteralPath $configFile) {
    try {
        $config=Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $script:Bindings=@($config.projects.bindings)
        foreach ($binding in $script:Bindings) { $projectPicker.Items.Add("$($binding.identity) · $($binding.localRoot)") | Out-Null }
    } catch {}
}
$null=New-Control Label 16 60 74 25 '프로젝트' $main
$project=New-Control TextBox 94 56 740 28 $script:Prefs.projectPath $main
$null=New-Button 844 51 140 '폴더 선택' $main { Browse-Folder $project }
$null=New-Control Label 16 102 74 25 '공통 이름' $main
$identity=New-Control TextBox 94 98 355 28 $script:Prefs.identity $main
$null=New-Button 466 92 146 '프로젝트 등록' $main { Start-Job (Base-Job 'Bind') }
$null=New-Button 630 92 175 '대화 목록 불러오기' $main { Start-Job (Base-Job 'List') }
$null=New-Control Label 16 140 74 25 '검색' $main
$search=New-Control TextBox 94 136 355 28 '' $main
$view=New-Control ComboBox 466 136 146 28 '' $main; $view.DropDownStyle='DropDownList'; $view.Items.AddRange(@('모든 대화','로컬 · 백업 대상','공유 · 복원 대상')); $view.SelectedIndex=0
$dateFilter=New-Control ComboBox 630 136 175 28 '' $main; $dateFilter.DropDownStyle='DropDownList'; $dateFilter.Items.AddRange(@('전체 날짜','최근 7일','최근 30일')); $dateFilter.SelectedIndex=0
$countLabel=New-Control Label 16 172 745 24 '목록을 불러오세요' $main
$null=New-Button 806 164 82 '이전' $main { if ($script:Page -gt 0) { $script:Page--; Apply-Filter } }
$null=New-Button 902 164 82 '다음' $main { $script:Page++; Apply-Filter }
$grid=New-Control DataGridView 16 205 988 174 '' $main
$grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false
$grid.RowHeadersVisible=$false; $grid.SelectionMode='FullRowSelect'; $grid.MultiSelect=$false
$grid.BackgroundColor=[Drawing.Color]::White
$grid.Anchor='Top,Left'; $grid.AutoGenerateColumns=$false
foreach ($column in @(@('title','대화',190),@('agent','에이전트',95),@('updated','최근 변경',105),@('local','로컬',50),@('backup','백업',70),@('id','세션 ID',180),@('context','원본 폴더 / 형식',185))) {
    $c=[Windows.Forms.DataGridViewTextBoxColumn]::new(); $c.Name=$column[0]; $c.HeaderText=$column[1]; $c.FillWeight=$column[2]; $grid.Columns.Add($c) | Out-Null
}
$grid.AutoSizeColumnsMode='Fill'
$selectionLabel=New-Control Label 16 384 988 24 '선택한 대화 없음' $main
$backupButton=New-Button 16 411 220 '선택한 대화 백업' $main {
    $job=Selected-Job 'Backup'
    if (Confirm "선택한 대화: $($job.title)`r`n에이전트: $($job.agent)`r`nID: $($job.nativeId)`r`n프로젝트: $($job.identity)`r`n`r`n해당 에이전트를 종료했나요? 이 대화 한 개를 백업합니다.") { Start-Job $job }
}
$restoreButton=New-Button 252 411 220 '미리보기 후 복원' $main { if ($agent.SelectedIndex -eq 1) { Start-DesktopPreview } else { Start-Job (Selected-Job 'Preview') } }
$openButton=New-Button 488 411 200 '선택한 대화 열기' $main { Start-Job (Selected-Job 'Open') }
$script:SessionButtons=@($backupButton,$restoreButton,$openButton)
$grid.Add_SelectionChanged({ Update-Selection })
Update-Selection
$null=New-Control Label 708 416 296 32 'Drive 완료는 Drive 앱에서 확인' $main
$null=New-Control Label 22 22 970 42 '처음 PC는 새 저장소, 다른 PC는 초대 파일로 연결합니다. 기존 ctxhop 설정은 그대로 사용합니다.' $settings
$null=New-Control Label 22 84 150 25 'Drive 저장소 경로' $settings
$store=New-Control TextBox 182 80 640 28 $script:Prefs.store $settings
$null=New-Button 834 74 142 '폴더 선택' $settings { Browse-Folder $store }
$null=New-Control Label 22 130 150 25 '초대 JSON (다른 PC)' $settings
$invite=New-Control TextBox 182 126 640 28 $script:Prefs.invite $settings
$null=New-Button 834 120 142 '파일 선택' $settings {
    $d=[Windows.Forms.OpenFileDialog]::new(); $d.Filter='초대 JSON|*.json'
    if ($d.ShowDialog($form) -eq 'OK') { $invite.Text=$d.FileName }; $d.Dispose()
}
$null=New-Control Label 22 176 150 25 '이 PC 이름' $settings
$device=New-Control TextBox 182 172 340 28 $script:Prefs.deviceName $settings
$null=New-Button 22 225 240 '초기 설정 / 초대로 연결' $settings { Start-Job (Base-Job 'Setup') }
$null=New-Button 278 225 200 '현재 연결 확인' $settings { Start-Job (Base-Job 'Status') }
$null=New-Button 494 225 238 '다른 PC용 초대 만들기' $settings {
    $d=[Windows.Forms.SaveFileDialog]::new(); $d.Filter='초대 JSON|*.json'; $d.FileName='ctxhop-invite.json'
    if (Test-Path -LiteralPath $store.Text) { $d.InitialDirectory=$store.Text }
    if ($d.ShowDialog($form) -eq 'OK') { $job=Base-Job 'Invite'; $job.output=$d.FileName; Start-Job $job }; $d.Dispose()
}
$null=New-Control Label 22 278 150 25 'Codex 데이터 폴더' $settings
$desktopHome=New-Control TextBox 182 274 640 28 $script:Prefs.home $settings
$null=New-Button 834 268 142 '폴더 선택' $settings { Browse-Folder $desktopHome }
$null=New-Control Label 22 325 956 94 "목록은 Codex 전체 프로젝트와 보관 대화를 포함합니다. 목록 조회·검사는 대화 파일과 DB를 바꾸지 않습니다.`r`nCodex 백업·복원 시 앱이 실행 중이면 중단하며 직접 종료 안내를 표시합니다. 강제 종료하지 않습니다.`r`n기록이 갈라진 경우 항목별로 유지·복원·건너뛰기를 선택합니다. 변경 시간으로 자동 선택하지 않습니다." $settings
$status=New-Control Label 24 595 860 38 '프로젝트를 등록하고 대화 목록을 불러오세요. 처음 사용하면 연결 설정부터 진행하세요.' $form
$cancelButton=New-Button 900 591 148 '목록 결과 취소' $form {
    if (-not $script:Pending -or $script:Pending.job.action -ne 'List') { return }
    $script:Pending.cancelled=$true
    $cancelButton.Enabled=$false
    $status.Text='목록 결과를 취소했습니다. 실행 중인 읽기 작업이 끝날 때까지 기다립니다.'
}
$cancelButton.Enabled=$false
$status.Anchor='Bottom,Left,Right'
$progress=New-Control ProgressBar 24 634 1025 8 '' $form; $progress.Anchor='Bottom,Left,Right'
$log=New-Control TextBox 24 651 1025 58 '' $form; $log.Multiline=$true; $log.ReadOnly=$true; $log.ScrollBars='Vertical'; $log.Anchor='Bottom,Left,Right'
$agent.Add_SelectedIndexChanged({ $grid.MultiSelect=($agent.SelectedIndex -eq 1); $projectPicker.Enabled=($agent.SelectedIndex -eq 0); Fill-Sessions @(); Save-Prefs })
$grid.MultiSelect=($agent.SelectedIndex -eq 1)
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
$timer=[Windows.Forms.Timer]::new(); $timer.Interval=350; $timer.Add_Tick({ Finish-Job }); $timer.Start()
$form.Add_FormClosing({
    if ($script:Pending) { $_.Cancel=$true; Show-Error '작업 창의 처리가 끝난 뒤 종료하세요. 복원 중 강제 종료는 피하세요.' }
    else { Save-Prefs }
})
if ($SmokeTest) {
    $project.Text='D:\projects\sample'; $identity.Text='sample-project'
    Fill-Sessions @(
        [pscustomobject]@{title='로그인 오류 수정과 다음 작업'; agent='claude-code'; updatedAt='2026-09-26 14:10'; local=$true; recordCount=24; nativeId='11111111-1111-4111-8111-111111111111';remoteId=('a'*25+'0')},
        [pscustomobject]@{title='API 응답 검증'; agent='claude-code'; updatedAt='2026-09-25 18:42'; local=$false; recordCount=18; nativeId='22222222-2222-4222-8222-222222222222';remoteId=('b'*25+'0')}
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
