#requires -Version 5.1
# 고정한 실제 Python 백엔드를 Worker로 호출한다. 대화 fixture는 설치된 Codex Desktop 엔진이 격리 폴더에 새로 만들고,
# 암호화 bundle 전송만 mock이다. 실제 사용자 저장소와 공유 Drive는 읽거나 쓰지 않는다.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Worker.ps1') -LibraryOnly
$script:Checks=0
function Assert([bool]$Value,[string]$Message) { $script:Checks++; if (-not $Value) { throw "ASSERT: $Message" } }
function Throws([scriptblock]$Body,[string]$Pattern) {
    $errorRecord=$null; try { & $Body | Out-Null } catch { $errorRecord=$_ }
    Assert ($null -ne $errorRecord) 'operation must fail'
    Assert ($errorRecord.Exception.Message -match $Pattern) "expected $Pattern, got $($errorRecord.Exception.Message)"
}
$engine=Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\*\codex.exe') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $engine) { throw 'Codex Desktop 엔진이 없어 native fixture를 만들 수 없습니다.' }
$runtime=Get-DesktopRuntime
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('CtxHop-vnext-integration-'+[guid]::NewGuid().ToString('N'))
$oldLocal=$env:LOCALAPPDATA; $oldEncoding=[Console]::OutputEncoding
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
    function Invoke-Bundle([string[]]$Arguments) {
        switch ($Arguments[0]) {
            list { return [pscustomobject]@{bundles=@()} }
            put {
                $bytes=[IO.File]::ReadAllBytes($Arguments[[array]::IndexOf($Arguments,'--metadata')+1])
                Assert (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'metadata is UTF-8 without BOM'
                $m=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
                Assert ((@($m.PSObject.Properties.Name) | Sort-Object) -join ',' -eq 'cliVersion,historyMode,recordCount,sessionId,sourceCwd,title,updatedAt') 'metadata has the exact seven fields'
                Assert (-not @($m.PSObject.Properties.Value | Where-Object { $_ -is [string] -and $_ -match "[`0`r`n]" })) 'metadata strings have no NUL or line breaks (bundle rule)'
                $id='peer-fixture/'+[guid]::NewGuid().ToString('N')
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
    Assert ($row[0].historyMode -eq 'paginated') 'native fixture is paginated'
    $found=Invoke-JobCore @{action='List';agent='codex-desktop';home=$fixtureHome;search=$thread.Substring(0,13)}
    Assert (@($found.sessions).Count -eq 1) 'search is passed to backend'

    $failure=$null; try { Invoke-JobCore @{action='Backup';agent='codex-desktop';home=$fixtureHome;nativeId=$thread} } catch { $failure=$_ }
    Assert ($null -ne $failure -and $failure.Exception.Message -match '종료|엔진' -and $failure.Exception.Message -notmatch '종료 코드') 'export block reason must reach the GUI'
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
    Assert ($backup.bundle.id -like 'peer-fixture/*') 'backup exports and publishes one bundle'
    Assert (@(Get-ChildItem -LiteralPath $staging -Directory).Count -eq $stages) 'uploaded plaintext backup copy is removed'
    $restore=@{action='Preview';agent='codex-desktop';home=$receiver;projectPath=$target;nativeId=$thread;remoteId=$backup.bundle.id}
    $p=Invoke-JobCore $restore
    Assert ($p.preview.status -eq 'new' -and $p.preview.source.sessionId -eq $thread) 'receiver previews the downloaded backup as new with the same UUID'
    Assert ($p.preview.source.cliVersion -eq $env:CTXHOP_TEST_ENGINE) 'backup records the engine version'
    Assert (-not @(Get-ChildItem -LiteralPath $receiver -Force)) 'preview never writes the receiver store'
    $restore.action='Restore'; $restore.receipt=$p.receipt; $restore.token=$p.preview.token; $restore.choice='incoming'

    $script:UseShim=$false
    $failure=$null; try { Invoke-JobCore $restore } catch { $failure=$_ }
    $backend=$failure.Exception.Data['backendResult']
    Assert ($null -ne $backend -and $backend.status -eq 'blocked' -and $backend.PSObject.Properties.Name -contains 'pending') 'real apply failure returns backend result with pending list'
    Assert (@($backend.pending).Count -eq 0 -and -not @(Get-ChildItem -LiteralPath $receiver -Force)) 'real writer/engine check blocks before any receiver write'

    $script:UseShim=$true
    $done=Invoke-JobCore $restore
    Assert ($done.applied.status -eq 'imported' -and $done.message -match '복원 완료') 'restore imports and reports completion'
    Assert (-not (Test-Path -LiteralPath (Split-Path -Parent $restore.receipt))) 'successful restore removes its plaintext staging copy'
    $manual=& (Join-Path $PSScriptRoot 'backend\Invoke-Desktop.ps1') -Action pending -HomePath $receiver | Out-String | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0 -and @($manual.pending).Count -eq 0) 'manual entry point runs the pinned backend'
    $manual=& (Join-Path $PSScriptRoot 'backend\Invoke-Desktop.ps1') -Action pending -HomePath ($target+'\') | Out-String | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0 -and @($manual.pending).Count -eq 0) 'manual entry point passes a spaced path with a trailing backslash intact'
    $copy=Join-Path $testDirectory 'tampered-package'; $null=New-Item -ItemType Directory -Path (Join-Path $copy 'backend')
    foreach ($name in @('Worker.ps1','ClaudeWorker.ps1','backend\Invoke-Desktop.ps1','backend\desktop_sessions.py','backend\schema.json')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $copy $name) }
    [IO.File]::AppendAllText((Join-Path $copy 'backend\desktop_sessions.py'),"`n# tampered`n")
    $manual=& (Join-Path $copy 'backend\Invoke-Desktop.ps1') -Action pending -HomePath $receiver | Out-String | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 1 -and $manual.reason -match '다릅니다') 'manual entry point refuses a changed backend'
    $listed=@((Invoke-JobCore @{action='List';agent='codex-desktop';home=$receiver;search=''}).sessions | Where-Object nativeId -eq $thread)
    Assert ($listed.Count -eq 1 -and $listed[0].local) 'imported session is listed on the receiver'
    $again=@{action='Preview';agent='codex-desktop';home=$receiver;projectPath=$target;nativeId=$thread;remoteId=$backup.bundle.id}
    $q=Invoke-JobCore $again
    Assert ($q.preview.status -eq 'equal') 'same backup is equal after restore'
    $again.action='Restore'; $again.receipt=$q.receipt; $again.token=$q.preview.token; $again.choice='incoming'
    $unchanged=Invoke-JobCore $again
    Assert ($unchanged.applied.status -eq 'equal' -and $unchanged.message -match '변경 없음') 'unchanged restore is not reported as completed'
    $env:CTXHOP_TEST_ENGINE='0.158.0-alpha.2'
    Throws {Invoke-JobCore @{action='Preview';agent='codex-desktop';home=$receiver;projectPath=$target;nativeId=$thread;remoteId=$backup.bundle.id}} '엔진'
    Write-Output "PASS: $script:Checks real-backend integration assertions. Engine $($engine.FullName); bundle transport mocked."
} finally {
    $env:LOCALAPPDATA=$oldLocal; [Console]::OutputEncoding=$oldEncoding
    Remove-Item -LiteralPath Env:CTXHOP_TEST_ENGINE -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testDirectory); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^CtxHop-vnext-integration-[a-f0-9]{32}$') { throw 'Refusing cleanup outside fixture directory' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
