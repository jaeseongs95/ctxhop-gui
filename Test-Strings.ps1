#requires -Version 5.1
# 언어 문자열 표와 영어 화면·작업 메시지를 격리 환경에서 확인한다. 실제 사용자 저장소는 읽거나 쓰지 않는다.
$ErrorActionPreference='Stop'
$script:Checks=0
function Assert([bool]$Value,[string]$Message) { $script:Checks++; if (-not $Value) { throw "ASSERT: $Message" } }
function Get-ThrownMessage([scriptblock]$Body) { try { & $Body | Out-Null } catch { return $_.Exception.Message }; throw 'operation must fail' }
$hangul='[\u1100-\u11FF\u3130-\u318F\uAC00-\uD7A3]'
# 번역하지 않는 한글: 글꼴 이름, 기본 Drive 경로, 두 언어로 쓴 언어 선택 표시.
$allowed=@('맑은 고딕','G:\내 드라이브\세션연동','Language / 언어','한국어')
$sources=@('GUI.ps1','Worker.ps1','ClaudeWorker.ps1','ProjectFiles.ps1','CodexDesktop.ps1','ClaudeCode.ps1')
. (Join-Path $PSScriptRoot 'Strings.ps1')

# 1) 표 형식: 두 언어가 모두 있고 자리표시자가 같으며 영어에 한글이 없다.
foreach ($key in $script:StringTable.Keys) {
    $pair=$script:StringTable[$key]
    Assert ($pair -is [array] -and $pair.Count -eq 2 -and $pair[0] -is [string] -and $pair[1] -is [string] -and $pair[0].Trim() -and $pair[1].Trim()) "$key must have Korean and English text"
    $holes=foreach ($text in $pair) { ([regex]::Matches($text,'\{(\d+)\}') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) -join ',' }
    Assert ($holes[0] -eq $holes[1]) "$key placeholders differ: ko {$($holes[0])} en {$($holes[1])}"
    Assert ($pair[1] -notmatch $hangul) "$key English text contains Hangul"
}

# 2) 코드의 한글은 주석과 허용 목록뿐이고, 쓰는 키는 모두 표에 있으며 표의 키는 모두 쓰인다.
$used=@{}
foreach ($name in $sources) {
    $text=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $name),[Text.Encoding]::UTF8)
    $parseErrors=$null
    $tokens=[Management.Automation.PSParser]::Tokenize($text,[ref]$parseErrors)
    Assert (-not $parseErrors.Count) "$name must parse"
    foreach ($token in $tokens) {
        if ($token.Type -ne 'Comment' -and $token.Content -match $hangul) { Assert ($token.Content -in $allowed) "$name line $($token.StartLine) has an untranslated literal: $($token.Content)" }
    }
    foreach ($match in [regex]::Matches($text,"(?<![\w-])T '(\w+)'|StringTable\.(\w+)")) { $used[$match.Groups[1].Value+$match.Groups[2].Value]=$true }
}
foreach ($key in $used.Keys) { Assert ($script:StringTable.ContainsKey($key)) "missing string key: $key" }
foreach ($key in $script:StringTable.Keys) { Assert ($used.ContainsKey($key)) "unused string key: $key" }

# 3) 작업 메시지: 선택한 언어로 오류를 돌려준다(Worker와 벤더 구현).
. (Join-Path $PSScriptRoot 'CodexDesktop.ps1') -LibraryOnly
Set-Language 'en'
foreach ($body in @({Assert-BundleId 'x'},{Assert-NativeId 'x'},{Assert-RemoteId 'x'},{& $script:CodexDesktopOps.restore ([pscustomobject]@{receipt=''})})) {
    $message=Get-ThrownMessage $body
    Assert ($message -and $message -notmatch $hangul) "English worker message expected, got $message"
}
Set-Language 'ko'
Assert ((Get-ThrownMessage {Assert-BundleId 'x'}) -match $hangul) 'Korean remains the default worker language'

# 4) 영어 화면: 저장된 설정의 언어로 만들고, 복원 선택 값도 영어로 동작한다.
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('CtxHop-vnext-strings-'+[guid]::NewGuid().ToString('N'))
$oldLocal=$env:LOCALAPPDATA; $oldConfig=$env:CTXHOP_CONFIG_DIR
try {
    $null=New-Item -ItemType Directory -Path (Join-Path $testDirectory 'CtxHopGUI')
    $env:LOCALAPPDATA=$testDirectory; $env:CTXHOP_CONFIG_DIR=$testDirectory
    [IO.File]::WriteAllText((Join-Path $testDirectory 'CtxHopGUI\vnext-preferences.json'),'{"language":"en"}')
    $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'GUI.ps1'),[Text.Encoding]::UTF8)
    $fixture=Join-Path $testDirectory 'GUI.ps1'
    [IO.File]::WriteAllText($fixture,$source.Substring(0,$source.LastIndexOf('if ($SmokeTest) {')),[Text.UTF8Encoding]::new($true))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Strings.ps1') -Destination $testDirectory
    . $fixture -SmokeTest
    $timer.Stop(); $filterTimer.Stop()
    Assert ($script:UiLanguage -eq 'en' -and $languagePicker.SelectedIndex -eq 1) 'saved English preference selects English'
    $controls=[Collections.Generic.List[object]]::new(); $pending=[Collections.Generic.Stack[object]]::new(); $pending.Push($form)
    while ($pending.Count) { $control=$pending.Pop(); $controls.Add($control); foreach ($child in $control.Controls) { $pending.Push($child) } }
    foreach ($control in $controls) {
        if ($control -is [Windows.Forms.TextBox]) { continue }
        Assert ($control.Text -notmatch $hangul -or $control.Text -in $allowed) "English GUI control text: $($control.Text)"
    }
    foreach ($column in $grid.Columns) { Assert ($column.HeaderText -notmatch $hangul) "English grid header: $($column.HeaderText)" }
    Assert ((Base-Job 'List').language -eq 'en' -and $script:Prefs.language -eq 'en') 'jobs and preferences carry the selected language'
    # GUI처럼 작업 창을 별도 프로세스로 띄우면 요청의 언어로 결과를 쓴다.
    $request=Join-Path $testDirectory 'request.json'; $result=Join-Path $testDirectory 'result.json'
    @{action='Open';agent='codex-desktop';home=$testDirectory;language='en'} | ConvertTo-Json | Set-Content -LiteralPath $request -Encoding UTF8
    $null=& (Join-Path $PSHOME 'powershell.exe') -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File (Join-Path $PSScriptRoot 'Worker.ps1') -RequestFile $request -ResultFile $result
    $exitCode=$LASTEXITCODE
    $answer=Get-Content -LiteralPath $result -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert ($exitCode -eq 1 -and $answer.error -and $answer.error -notmatch $hangul) 'worker process answers in the language sent by the GUI'
    $review=[pscustomobject]@{job=@{action='Preview';agent='codex-desktop';nativeId='11111111-1111-4111-8111-111111111111';remoteId='peer-a/'+('a'*32);title='fixture';sourceCwd='D:\source';projectPath='D:\target';home='D:\home'};receipt='fixture-inspect.json';preview=[pscustomobject]@{status='conflict';reason='fixture';token='pinned';source=@{};target=@{}}}
    $ui=New-DesktopReviewDialog @($review)
    try {
        $choices=$ui.table.Columns['choice'].Items
        Assert ($choices.Count -eq 3 -and -not @($choices | Where-Object { $_ -match $hangul }).Count) 'English restore choices'
        Assert (@(Get-DesktopDecisions $ui.table).Count -eq 0) 'English default choice skips'
        $ui.table.Rows[0].Cells['choice'].Value=$choices[2]
        $decisions=@(Get-DesktopDecisions $ui.table)
        Assert ($decisions.Count -eq 1 -and $decisions[0].token -ceq 'pinned') 'English restore choice applies the inspected backup'
    } finally { $ui.dialog.Dispose() }
    $languagePicker.SelectedIndex=0
    Assert ($script:Prefs.language -eq 'ko' -and $status.Text -match $hangul) 'switching to Korean saves the preference and explains the restart in Korean'
    Write-Output "PASS: $script:Checks string table and English UI assertions."
} finally {
    $script:SmokeTest=$true
    if ($timer) { $timer.Dispose() }; if ($filterTimer) { $filterTimer.Dispose() }; if ($form) { $form.Close(); $form.Dispose() }
    $env:LOCALAPPDATA=$oldLocal; $env:CTXHOP_CONFIG_DIR=$oldConfig
    $resolved=[IO.Path]::GetFullPath($testDirectory); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^CtxHop-vnext-strings-[a-f0-9]{32}$') { throw 'Refusing cleanup outside fixture directory' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
