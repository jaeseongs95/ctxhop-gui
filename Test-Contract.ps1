#requires -Version 5.1
# 벤더 계약 v1(docs\contract-v1.md)의 프로세스 경계를 확인한다.
# 1) Worker 쪽 클라이언트(Invoke-VendorOp)를 임시 폴더의 가짜 구현으로, 2) 실제 구현 진입점(CodexDesktop.ps1, ClaudeCode.ps1)을
# 네이티브 도구를 부르기 전에 끝나는 요청(probe·recover·Codex open·잘못된 요청)으로 확인한다. 사용자 폴더와 네이티브 도구는 쓰지 않는다.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Worker.ps1') -LibraryOnly
$script:Checks=0
function Assert([bool]$Value,[string]$Message) { $script:Checks++; if (-not $Value) { throw "ASSERT: $Message" } }
function Throws([scriptblock]$Body,[string]$Pattern) {
    $errorRecord=$null; try { & $Body | Out-Null } catch { $errorRecord=$_ }
    Assert ($null -ne $errorRecord) "operation must fail: $Body"
    Assert ($errorRecord.Exception.Message -match $Pattern) "expected $Pattern, got $($errorRecord.Exception.Message)"
    return $errorRecord
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ctxhop-contract-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
try {
    # 가짜 구현: 요청의 mode대로 정상·비정상 응답을 낸다.
    $fake=@'
$op=$args[0]; $requestFile=$args[2]; $responseFile=$args[4]
$r=[IO.File]::ReadAllText($requestFile,[Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'calls.txt'),"$requestFile`n")
$out=[ordered]@{protocolVersion=1;requestId=$r.requestId;op=$r.op;status='ok';reasonCode='';reason='';echo=$r.title;argOp=$op;argSwitches=($args[1]+' '+$args[3]);sessions=@()}
function Save([string]$Text) { [IO.File]::WriteAllText("$responseFile.tmp",$Text,[Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath "$responseFile.tmp" -Destination $responseFile }
switch ($r.mode) {
    'none' { exit 0 }
    'badjson' { Save '{"protocolVersion":1,'; exit 0 }
    'wrongid' { $out.requestId=[guid]::NewGuid().ToString() }
    'wrongop' { $out.op=if ($r.op -eq 'list') {'probe'} else {'list'} }
    'badstatus' { $out.status='weird' }
    'stringversion' { $out.protocolVersion='1' }
    'nofields' { $out.Remove('sessions') }
    'badfields' { $out.sessions='not a list' }
    'badrow' { $out.sessions=@([ordered]@{nativeId='11111111-1111-4111-8111-111111111111';remoteId='';title='t';local='yes';recordCount=0}) }
    'unverified' { $out.sessions=@([ordered]@{nativeId='';remoteId='peer/x';title='';local=$false;recordCount=0;blockedReason='bad metadata'}) }
    'noreason' { $out.sessions=@([ordered]@{nativeId='';remoteId='peer/x';title='';local=$false;recordCount=0}) }
    'numberreason' { $out.status='failed'; $out.reason=5 }
    'failed' { $out.status='failed'; $out.reason='impl reason' }
    'busy' { $out.status='busy'; $out.reason='in progress' }
    'exit1' { $out.status='failed'; $out.reason='impl said no'; Save ($out | ConvertTo-Json); exit 1 }
    'exit1none' { exit 1 }
    'exit2' { exit 2 }
    'sleep' { [IO.File]::WriteAllText("$requestFile.pid",[string]$PID); Start-Sleep -Seconds 60 }
    'big' { Save ('{"protocolVersion":1,"pad":"'+('x'*(16MB))+'"}'); exit 0 }
}
Save ($out | ConvertTo-Json -Depth 5)
'@
    [IO.File]::WriteAllText((Join-Path $root 'fake.ps1'),$fake,[Text.UTF8Encoding]::new($true))
    $impls=@{fake=@('powershell.exe','-NoProfile','-ExecutionPolicy','RemoteSigned','-File','fake.ps1');missing=@('nope.exe');empty=@();bad=@('powershell.exe',5)}
    [IO.File]::WriteAllText((Join-Path $root 'impls.json'),($impls | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $script:ImplsFile=Join-Path $root 'impls.json'
    $jobs=Join-Path $root 'jobs'; $null=New-Item -ItemType Directory -Path $jobs

    # 정상 응답: 요청 짝·op·허용 status, 인수 순서, 한글 왕복, 호출마다 새 폴더, 호출이 끝나면 요청·응답 파일을 지운다.
    $title='한글 제목 ✓ "따옴표" \끝\'
    $ok=Invoke-VendorOp 'fake' 'list' @{mode='ok';title=$title} $jobs
    Assert ($ok.status -eq 'ok') 'valid response is returned'
    Assert ($ok.echo -ceq $title) 'Korean and quoted request text survives the round trip'
    Assert ($ok.argOp -ceq 'list' -and $ok.argSwitches -ceq '--request --response') 'impl receives <op> --request <file> --response <file>'
    $null=Invoke-VendorOp 'fake' 'list' @{mode='ok'} $jobs
    $calls=@([IO.File]::ReadAllLines((Join-Path $root 'calls.txt')))
    Assert ($calls.Count -eq 2 -and (Split-Path -Parent $calls[0]) -ne (Split-Path -Parent $calls[1])) 'each call gets its own job folder'
    Assert (-not @(Get-ChildItem -LiteralPath $jobs -Force).Count) 'request and response files are removed after each call'
    $row=Invoke-VendorOp 'fake' 'list' @{mode='unverified'} $jobs
    Assert ($row.sessions.Count -eq 1 -and $row.sessions[0].blockedReason) 'a row without a native ID is valid when it says why it is blocked'
    foreach ($mode in 'failed','busy') {
        $r=Invoke-VendorOp 'fake' 'backup' @{mode=$mode} $jobs
        Assert ($r.status -eq $mode) "status $mode with exit 0 is a valid response for the caller to handle"
    }
    Assert ((Invoke-VendorOp 'fake' 'describe' @{mode='busy'} $jobs).status -eq 'busy') 'describe may be busy'

    # 응답이 어긋나면 exit 0이어도 실패이고, 구현이 어디까지 했는지 모른다고 알린다.
    foreach ($mode in 'none','badjson','wrongid','wrongop','badstatus','stringversion','nofields','badfields','badrow','noreason','numberreason','big') {
        $e=Throws { Invoke-VendorOp 'fake' 'list' @{mode=$mode} $jobs } 'no valid response|응답이 없거나'
        Assert ($e.Exception.Data['vendorOutcome'] -eq 'unknown') "$mode leaves the outcome unknown"
    }
    # op마다 허용된 status만 받는다: 목록에는 busy가, 미리보기에는 changed가 없다.
    $null=Throws { Invoke-VendorOp 'fake' 'list' @{mode='busy'} $jobs } 'no valid response|응답이 없거나'
    # 종료 코드
    $e=Throws { Invoke-VendorOp 'fake' 'restore' @{mode='exit1'} $jobs } 'impl said no'
    Assert ($e.Exception.Data['vendorResult'].status -eq 'failed' -and -not $e.Exception.Data.Contains('vendorOutcome')) 'exit 1 keeps a valid response for the caller'
    $e=Throws { Invoke-VendorOp 'fake' 'restore' @{mode='exit1none'} $jobs } 'exit code 1|종료 코드 1'
    Assert ($e.Exception.Data['vendorOutcome'] -eq 'unknown') 'exit 1 without a response leaves the outcome unknown'
    $e=Throws { Invoke-VendorOp 'fake' 'restore' @{mode='exit2'} $jobs } 'invalid|잘못된 요청'
    Assert (-not $e.Exception.Data.Contains('vendorOutcome')) 'exit 2 means the request was refused before anything ran'
    # 입력 검증
    $null=Throws { Invoke-VendorOp 'fake' 'format' @{} $jobs } 'Unknown vendor operation|알 수 없는 벤더 작업'
    foreach ($vendor in 'missing','empty','bad','absent') { $null=Throws { Invoke-VendorOp $vendor 'list' @{} $jobs } 'impls.json' }
    Assert (-not @(Get-ChildItem -LiteralPath $jobs -Force).Count) 'no call folder is left behind'

    # 시간 초과: 구현 프로세스를 끝내고 실패한다. 구현이 남긴 모르는 파일이 있으면 그 폴더는 지우지 않는다.
    $script:ContractTimeoutSec['probe']=3
    $e=Throws { Invoke-VendorOp 'fake' 'probe' @{mode='sleep'} $jobs } 'within 3 seconds|3초 안에'
    Assert ($e.Exception.Data['vendorOutcome'] -eq 'unknown') 'a timeout leaves the outcome unknown'
    $dir=@(Get-ChildItem -LiteralPath $jobs -Directory)
    Assert ($dir.Count -eq 1 -and ((@(Get-ChildItem -LiteralPath $dir[0].FullName -Force | ForEach-Object Name)) -join '|') -eq 'request.json.pid') 'only the unknown file keeps its call folder'
    $fakePid=[int][IO.File]::ReadAllText((Join-Path $dir[0].FullName 'request.json.pid'))
    Start-Sleep -Milliseconds 500
    Assert ($null -eq (Get-Process -Id $fakePid -ErrorAction SilentlyContinue)) 'timed-out impl process is stopped'
    $script:ContractTimeoutSec['probe']=120

    # 실제 구현 진입점: CLI 해석·처리기 연결·응답 포장. 네이티브 도구를 부르기 전에 끝나는 요청만 보낸다.
    $script:ImplsFile=Join-Path $PSScriptRoot 'impls.json'
    $real=Join-Path $root 'real'; $null=New-Item -ItemType Directory -Path $real
    foreach ($vendor in 'codex-desktop','claude-code') {
        $probe=Invoke-VendorOp $vendor 'probe' @{} $real
        Assert ((@($probe.capabilities) -join ',') -ceq 'probe,backup,describe,guard,list,open,preview,recover,restore') "$vendor declares the operations it handles"
        # recover는 모드를 먼저 확인한다. 모르는 모드는 기록을 읽기 전에 failed다.
        $recover=Invoke-VendorOp $vendor 'recover' @{mode='bogus'} $real
        Assert ($recover.status -eq 'failed' -and $recover.reason -match 'bogus') "$vendor refuses an unknown recover mode before reading any record"
        $null=Throws { Invoke-VendorOp $vendor 'probe' @{protocolVersion='1'} $real } 'invalid|잘못된 요청'
        $null=Throws { Invoke-VendorOp $vendor 'probe' @{protocolVersion=2} $real } 'invalid|잘못된 요청'
        $null=Throws { Invoke-VendorOp $vendor 'probe' @{op='list'} $real } 'invalid|잘못된 요청'
        $null=Throws { Invoke-VendorOp $vendor 'probe' @{requestId='not-a-guid'} $real } 'invalid|잘못된 요청'
    }
    # 구현이 처리하지 않는 op는 unsupported(op_unsupported)로 답한다.
    $unhandled=Invoke-ImplOp @{} ([pscustomobject]@{op='list';requestId=[guid]::NewGuid().ToString()})
    Assert ($unhandled.status -eq 'unsupported' -and $unhandled.reasonCode -eq 'op_unsupported' -and $unhandled.reason) 'an implementation answers an operation it does not handle as unsupported'
    Set-Language 'en'
    $open=Invoke-VendorOp 'codex-desktop' 'open' @{} $real
    Assert ($open.status -eq 'unsupported' -and $open.reasonCode -eq 'open_manually' -and $open.reason -match '^Open Codex Desktop yourself') 'Codex open is reported as manual, in the requested language'
    Set-Language 'ko'
    Assert (-not @(Get-ChildItem -LiteralPath $real -Force).Count) 'real implementation calls leave no files behind'
    Write-Host "PASS: $script:Checks contract assertions. Fake implementations and real entry points only; no native tool or user folder touched."
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
