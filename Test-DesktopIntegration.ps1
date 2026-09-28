#requires -Version 5.1
# 고정한 실제 Python 백엔드를 Worker로 호출한다. 대화 fixture는 설치된 Codex Desktop 엔진이 격리 폴더에 새로 만들고,
# 암호화 bundle 전송만 mock이다. 실제 사용자 저장소와 공유 Drive는 읽거나 쓰지 않는다.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'CodexDesktop.ps1') -LibraryOnly
Enable-WorkerJob   # 복원 시험은 실제 Worker처럼 Job 객체 안에서 돈다.
$script:Checks=0
function Assert([bool]$Value,[string]$Message) { $script:Checks++; if (-not $Value) { throw "ASSERT: $Message" } }
# 벤더 계약 경계: Codex 구현의 처리기를 이 프로세스에서 부르되 요청·응답은 JSON을 거치고 Worker와 같은 응답 검사를 한다.
# 이 시험의 전송 mock과 백엔드 shim이 구현에도 적용되게 한다. 프로세스 경계는 Test-Contract.ps1이 확인한다.
function Invoke-VendorOp([string]$Vendor,[string]$Op,[Collections.IDictionary]$Request,[string]$JobDir) {
    Assert ($Vendor -ceq 'codex-desktop') 'only the Codex Desktop implementation is under test'
    $id=[guid]::NewGuid().ToString()
    $body=[ordered]@{protocolVersion=1;requestId=$id;op=$Op;language=$script:UiLanguage}
    foreach ($key in $Request.Keys) { $body[$key]=$Request[$key] }
    $response=ConvertTo-Json -InputObject (Invoke-ImplOp $script:CodexDesktopOps (ConvertTo-Json -InputObject $body -Depth 30 | ConvertFrom-Json)) -Depth 40 | ConvertFrom-Json
    Assert (Test-VendorResponse $response $id $Op) "contract response for $Op"
    return $response
}
function Throws([scriptblock]$Body,[string]$Pattern) {
    $errorRecord=$null; try { & $Body | Out-Null } catch { $errorRecord=$_ }
    Assert ($null -ne $errorRecord) 'operation must fail'
    Assert ($errorRecord.Exception.Message -match $Pattern) "expected $Pattern, got $($errorRecord.Exception.Message)"
}
$engine=Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\*\codex.exe') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $engine) { throw 'Codex Desktop 엔진이 없어 native fixture를 만들 수 없습니다.' }
$runtime=Get-DesktopRuntime
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('CtxHop-vnext-integration-'+[guid]::NewGuid().ToString('N'))
$oldLocal=$env:LOCALAPPDATA; $oldEncoding=[Console]::OutputEncoding; $oldCeiling=$env:GIT_CEILING_DIRECTORIES
try {
    $null=New-Item -ItemType Directory -Path $testDirectory
    [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
    $probe=& $runtime.python -X utf8 (Join-Path $PSScriptRoot 'backend\native_probe.py') --exe $engine.FullName --root $testDirectory --turns 1 | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $probe.ok) { throw "native fixture 생성 실패: $($probe.error)" }
    $fixtureHome=$probe.home
    $thread=(Get-Content -LiteralPath (Join-Path $fixtureHome 'probe.json') -Raw -Encoding UTF8 | ConvertFrom-Json).threadId
    # 이후 staging과 백엔드의 LOCALAPPDATA를 격리한다. 실제 백엔드는 엔진을 찾지 못하므로 앱 실행 여부와 관계없이
    # 엔진이 필요한 미리보기·백업·복원이 항상 쓰기 전에 차단된다.
    $env:LOCALAPPDATA=$testDirectory
    $remote=Join-Path $testDirectory 'remote'; $null=New-Item -ItemType Directory -Path $remote
    # 올린 bundle의 메타데이터. 목록은 프로젝트 파일 절에서만 돌려준다(앞 절의 목록 검사는 이 PC 대화만 본다).
    $script:Stored=[ordered]@{}; $script:ListStored=$false
    function Invoke-Bundle([string[]]$Arguments) {
        switch ($Arguments[0]) {
            list { return [pscustomobject]@{bundles=@(if ($script:ListStored) { $script:Stored.Values })} }
            put {
                $bytes=[IO.File]::ReadAllBytes($Arguments[[array]::IndexOf($Arguments,'--metadata')+1])
                Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'metadata is UTF-8 without BOM'
                $m=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
                Assert ((@($m.PSObject.Properties.Name) | Sort-Object) -join ',' -eq 'cliVersion,historyMode,recordCount,sessionId,sourceCwd,title,updatedAt') 'metadata has the exact seven fields'
                Assert (-not @($m.PSObject.Properties.Value | Where-Object { $_ -is [string] -and $_ -match "[`0`r`n]" })) 'metadata strings have no NUL or line breaks (bundle rule)'
                if ($m.historyMode -notlike 'project-*') { Assert ($m.historyMode -ceq 'paginated;family=0') 'backups mark the subagent family format (no subagents here)' }
                $id='peer-fixture/'+[guid]::NewGuid().ToString('N')
                $script:Stored[$id]=[pscustomobject]@{id=$id;metadata=$m}
                Copy-Item -LiteralPath $Arguments[[array]::IndexOf($Arguments,'--input')+1] -Destination (Join-Path $remote $id.Split('/')[1])
                return [pscustomobject]@{id=$id}
            }
            get {
                $file=$Arguments[[array]::IndexOf($Arguments,'--output')+1]
                $source=Join-Path $remote $Arguments[2].Split('/')[1]
                if (-not (Test-Path -LiteralPath $source)) { $source=Join-Path $fixtureHome 'first.zip' }
                Copy-Item -LiteralPath $source -Destination $file
                return [pscustomobject]@{id=$Arguments[2];sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash;bytes=(Get-Item -LiteralPath $file).Length}
            }
            default { throw 'unexpected bundle operation' }
        }
    }
    $target=Join-Path $testDirectory '가져올 작업 폴더'; $null=New-Item -ItemType Directory -Path $target
    $receiver=Join-Path $testDirectory 'receiver-home'; $null=New-Item -ItemType Directory -Path $receiver

    # 1) 실제 Worker 함수 + 고정 백엔드
    $list=Invoke-JobCore @{action='List';agent='codex-desktop';home=$fixtureHome;search=''}
    $row=@($list.sessions | Where-Object nativeId -eq $thread)
    Assert ($row.Count -eq 1 -and $row[0].local -and -not $row[0].blockedReason) 'fixture session is listed once as local and usable'
    Assert ($row[0].archived -is [bool]) 'archived must be bool'
    $date=[datetime]::MinValue
    Assert ([string]$row[0].updatedAt -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$' -and [datetime]::TryParse([string]$row[0].updatedAt,[ref]$date)) 'updatedAt must be RFC3339 that the GUI date filter parses'
    Assert ($row[0].historyMode -eq 'paginated' -and $row[0].children -eq 0) 'native fixture is paginated and has no subagents'
    $found=Invoke-JobCore @{action='List';agent='codex-desktop';home=$fixtureHome;search=$thread.Substring(0,13)}
    Assert (@($found.sessions).Count -eq 1) 'search is passed to backend'
    $dash=Invoke-JobCore @{action='List';agent='codex-desktop';home=$fixtureHome;search='-x'}
    Assert (@($dash.sessions).Count -eq 0) 'search starting with - is a value, not a backend option'

    $failure=$null; try { Invoke-JobCore @{action='Backup';agent='codex-desktop';home=$fixtureHome;nativeId=$thread} } catch { $failure=$_ }
    # 백업은 앱 종료를 보지 않는다. Codex 앱이 켜져 있어도 격리한 LOCALAPPDATA에 엔진이 없다는 이유로만 멈춰야 한다.
    Assert ($null -ne $failure -and $failure.Exception.Message -match '엔진' -and $failure.Exception.Message -notmatch '종료') "export stops only for the engine, never for a running app: $($failure.Exception.Message)"
    Assert (-not @(Get-ChildItem -LiteralPath (Join-Path $testDirectory 'CtxHopGUI\staging') -Recurse -Filter 'session.archive' -File)) 'blocked export writes no archive'
    Throws {Invoke-JobCore @{action='Preview';agent='codex-desktop';home=$receiver;projectPath=$target;nativeId=$thread;remoteId=('peer-fixture/'+('c'*32))}} '엔진'
    Assert (-not @(Get-ChildItem -LiteralPath $receiver -Force)) 'preview without a known engine never writes the receiver store'

    $pin=$script:DesktopBackendSHA256; $script:DesktopBackendSHA256='0'*64
    Throws {Invoke-JobCore @{action='List';agent='codex-desktop';home=$fixtureHome;search=''}} '다릅니다'
    $script:DesktopBackendSHA256=$pin

    # 2) 성공 경로: 앱 종료 검사와 엔진 조회만 시험 전용 진입점(backend\test_guard_shim.py)으로 바꾸고
    #    Worker의 백업 → 전송 → 미리보기 → 복원 → 재검사를 끝까지 실행한다. 전송은 격리 폴더 복사로 대신한다.
    $script:RealBackend=${function:Invoke-DesktopBackend}; $script:UseShim=$true
    $env:CTXHOP_TEST_ENGINE='0.158.0-alpha.2.1'
    $shim=Join-Path $PSScriptRoot 'backend\test_guard_shim.py'
    function Invoke-DesktopBackend([string[]]$Arguments) {
        if ($script:UseShim) { return (Invoke-JsonNative $runtime.python (@('-I','-B','-u',$shim) + $Arguments)) }
        & $script:RealBackend $Arguments
    }
    $staging=Join-Path $testDirectory 'CtxHopGUI\staging'
    $stages=@(Get-ChildItem -LiteralPath $staging -Directory).Count
    $backup=Invoke-JobCore @{action='Backup';agent='codex-desktop';home=$fixtureHome;nativeId=$thread}
    Assert ($backup.remoteId -like 'peer-fixture/*') 'backup exports and publishes one bundle'
    Assert (@(Get-ChildItem -LiteralPath $staging -Directory).Count -eq $stages) 'uploaded plaintext backup copy is removed'
    $restore=@{action='Preview';agent='codex-desktop';home=$receiver;projectPath=$target;nativeId=$thread;remoteId=$backup.remoteId}
    $p=Invoke-JobCore $restore
    Assert ($p.preview.status -eq 'new' -and $p.preview.source.sessionId -eq $thread) 'receiver previews the downloaded backup as new with the same UUID'
    Assert ($p.preview.source.cliVersion -eq $env:CTXHOP_TEST_ENGINE -and $p.preview.source.children -eq 0) 'backup records the engine version and its subagent count'
    Assert (-not @(Get-ChildItem -LiteralPath $receiver -Force)) 'preview never writes the receiver store'
    $restore.action='Restore'; $restore.receipt=$p.receipt; $restore.token=$p.preview.token; $restore.choice='incoming'

    $script:UseShim=$false
    $failure=$null; try { Invoke-JobCore $restore } catch { $failure=$_ }
    $backend=$failure.Exception.Data['backendResult']
    Assert ($null -ne $backend -and $backend.status -eq 'blocked' -and $backend.PSObject.Properties.Name -contains 'pending') 'real apply failure returns backend result with pending list'
    Assert (@($backend.pending).Count -eq 0 -and -not @(Get-ChildItem -LiteralPath $receiver -Force)) 'real writer/engine check blocks before any receiver write'

    $script:UseShim=$true
    $done=Invoke-JobCore $restore
    Assert ($done.restored.status -eq 'imported' -and $done.effect -eq 'restored' -and $done.message -match '복원 완료') 'restore imports and reports completion'
    Assert (-not (Test-Path -LiteralPath (Split-Path -Parent $restore.receipt))) 'successful restore removes its plaintext staging copy'
    $manual=& (Join-Path $PSScriptRoot 'backend\Invoke-Desktop.ps1') -Action pending -HomePath $receiver | Out-String | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0 -and @($manual.pending).Count -eq 0) 'manual entry point runs the pinned backend'
    $manual=& (Join-Path $PSScriptRoot 'backend\Invoke-Desktop.ps1') -Action pending -HomePath ($target+'\') | Out-String | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0 -and @($manual.pending).Count -eq 0) 'manual entry point passes a spaced path with a trailing backslash intact'
    $copy=Join-Path $testDirectory 'tampered-package'; $null=New-Item -ItemType Directory -Path (Join-Path $copy 'backend')
    foreach ($name in @('CodexDesktop.ps1','Worker.ps1','ClaudeWorker.ps1','Strings.ps1','ProjectFiles.ps1','backend\Invoke-Desktop.ps1','backend\desktop_sessions.py','backend\schema.json')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $copy $name) }
    [IO.File]::AppendAllText((Join-Path $copy 'backend\desktop_sessions.py'),"`n# tampered`n")
    $manual=& (Join-Path $copy 'backend\Invoke-Desktop.ps1') -Action pending -HomePath $receiver | Out-String | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 1 -and $manual.reason -match '다릅니다') 'manual entry point refuses a changed backend'
    $listed=@((Invoke-JobCore @{action='List';agent='codex-desktop';home=$receiver;search=''}).sessions | Where-Object nativeId -eq $thread)
    Assert ($listed.Count -eq 1 -and $listed[0].local) 'imported session is listed on the receiver'
    $again=@{action='Preview';agent='codex-desktop';home=$receiver;projectPath=$target;nativeId=$thread;remoteId=$backup.remoteId}
    $q=Invoke-JobCore $again
    Assert ($q.preview.status -eq 'equal') 'same backup is equal after restore'
    $again.action='Restore'; $again.receipt=$q.receipt; $again.token=$q.preview.token; $again.choice='incoming'
    $unchanged=Invoke-JobCore $again
    Assert ($unchanged.restored.status -eq 'equal' -and $unchanged.effect -eq 'equal' -and $unchanged.message -match '변경 없음') 'unchanged restore is not reported as completed'
    # 3) 프로젝트 파일: 실제 export가 돌려준 작업 폴더(이 fixture 대화는 CODEX_HOME에서 시작)로 폴더 백업과 연결 기록을 올리고,
    #    미리보기·복원으로 다른 폴더에 되돌린다. git이 임시 폴더 위쪽 저장소를 찾지 않게 한다.
    $env:GIT_CEILING_DIRECTORIES=$testDirectory; $script:ListStored=$true
    $withFiles=Invoke-JobCore @{action='Backup';agent='codex-desktop';home=$fixtureHome;nativeId=$thread;projectBackup=$true}
    $startFolder=@($withFiles.project.folders)[0]
    Assert ($startFolder.role -eq 'start' -and $startFolder.status -eq 'uploaded' -and $startFolder.files -gt 0 -and (ConvertTo-ProjectPath $startFolder.sourcePath) -eq (ConvertTo-ProjectPath $fixtureHome)) "the real export names the conversation folder and it is uploaded: $($withFiles.project.folders | ConvertTo-Json -Compress)"
    Assert (@($script:Stored.Values | Where-Object { $_.metadata.historyMode -ceq 'project-link;v1;codex-desktop' -and $_.metadata.title -ceq $withFiles.remoteId }).Count -eq 1) 'a link record names the conversation backup'
    $projectTarget=Join-Path $testDirectory '프로젝트 복원 폴더'; $null=New-Item -ItemType Directory -Path $projectTarget
    $withRestore=@{action='Preview';agent='codex-desktop';home=$receiver;projectPath=$projectTarget;nativeId=$thread;remoteId=$withFiles.remoteId;projectRestore=$true}
    $pp=Invoke-JobCore $withRestore
    Assert ($pp.project.state -eq 'found' -and $pp.project.folders[0].state -eq 'ready' -and $pp.project.folders[0].compare.new -eq $startFolder.files) "preview finds the linked folder backup: $($pp.project | ConvertTo-Json -Depth 4 -Compress)"
    $withRestore.action='Restore'; $withRestore.receipt=$pp.receipt; $withRestore.token=$pp.preview.token; $withRestore.choice='incoming'; $withRestore.projectReceipt=$pp.project.receipt
    $pr=Invoke-JobCore $withRestore
    Assert ($pr.project.folders[0].written -eq $startFolder.files -and [IO.File]::ReadAllText((Join-Path $projectTarget 'probe.json')) -eq [IO.File]::ReadAllText((Join-Path $fixtureHome 'probe.json'))) "project files are restored into the chosen folder: $($pr.message)"
    Assert (-not (Test-Path -LiteralPath (Split-Path -Parent $withRestore.receipt)) -and -not (Test-Path -LiteralPath (Split-Path -Parent $withRestore.projectReceipt))) 'the conversation and project preview staging copies are removed after restore'
    $env:GIT_CEILING_DIRECTORIES=$oldCeiling; $script:ListStored=$false
    $env:CTXHOP_TEST_ENGINE='0.158.0-alpha.2'
    Throws {Invoke-JobCore @{action='Preview';agent='codex-desktop';home=$receiver;projectPath=$target;nativeId=$thread;remoteId=$backup.remoteId}} '엔진'
    Write-Output "PASS: $script:Checks real-backend integration assertions. Engine $($engine.FullName); bundle transport mocked."
} finally {
    $env:LOCALAPPDATA=$oldLocal; [Console]::OutputEncoding=$oldEncoding; $env:GIT_CEILING_DIRECTORIES=$oldCeiling
    Remove-Item -LiteralPath Env:CTXHOP_TEST_ENGINE -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testDirectory); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^CtxHop-vnext-integration-[a-f0-9]{32}$') { throw 'Refusing cleanup outside fixture directory' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
