#requires -Version 5.1
# 벤더 계약 v1 클라이언트(Worker.ps1 Invoke-VendorOp)를 임시 폴더의 가짜 impl로 확인한다. 실제 impl·네이티브 도구·사용자 폴더는 쓰지 않는다.
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
    # 가짜 impl: 요청의 mode대로 정상·비정상 응답을 낸다.
    $fake=@'
$op=$args[0]; $requestFile=$args[2]; $responseFile=$args[4]
$r=[IO.File]::ReadAllText($requestFile,[Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
[IO.File]::WriteAllText("$requestFile.pid",[string]$PID)
$out=[ordered]@{protocolVersion=1;requestId=$r.requestId;op=$r.op;status='ok';reason='';echo=$r.title;argOp=$op;argSwitches=($args[1]+' '+$args[3])}
function Save([string]$Text) { [IO.File]::WriteAllText("$responseFile.tmp",$Text,[Text.UTF8Encoding]::new($false)); Move-Item -LiteralPath "$responseFile.tmp" -Destination $responseFile }
switch ($r.mode) {
    'none' { exit 0 }
    'badjson' { Save '{"protocolVersion":1,'; exit 0 }
    'wrongid' { $out.requestId=[guid]::NewGuid().ToString() }
    'wrongop' { $out.op=if ($r.op -eq 'list') {'probe'} else {'list'} }
    'badstatus' { $out.status='weird' }
    'stringversion' { $out.protocolVersion='1' }
    'failed' { $out.status='failed'; $out.reason='impl reason' }
    'exit1' { $out.status='failed'; $out.reason='impl said no'; Save ($out | ConvertTo-Json); exit 1 }
    'exit1none' { exit 1 }
    'exit2' { exit 2 }
    'sleep' { Start-Sleep -Seconds 60 }
    'big' { Save ('{"protocolVersion":1,"pad":"'+('x'*(16MB))+'"}'); exit 0 }
}
Save ($out | ConvertTo-Json)
'@
    [IO.File]::WriteAllText((Join-Path $root 'fake.ps1'),$fake,[Text.UTF8Encoding]::new($true))
    $impls=@{fake=@('powershell.exe','-NoProfile','-ExecutionPolicy','RemoteSigned','-File','fake.ps1');missing=@('nope.exe');empty=@();bad=@('powershell.exe',5)}
    [IO.File]::WriteAllText((Join-Path $root 'impls.json'),($impls | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $script:ImplsFile=Join-Path $root 'impls.json'
    $jobs=Join-Path $root 'jobs'; $null=New-Item -ItemType Directory -Path $jobs

    # 정상 응답: 요청 짝·op·허용 status, 인수 순서, 한글 왕복, 호출마다 새 폴더
    $title='한글 제목 ✓ "따옴표" \끝\'
    $ok=Invoke-VendorOp 'fake' 'list' @{mode='ok';title=$title} $jobs
    Assert ($ok.status -eq 'ok') 'valid response is returned'
    Assert ($ok.echo -ceq $title) 'Korean and quoted request text survives the round trip'
    Assert ($ok.argOp -ceq 'list' -and $ok.argSwitches -ceq '--request --response') 'impl receives <op> --request <file> --response <file>'
    $null=Invoke-VendorOp 'fake' 'list' @{mode='ok'} $jobs
    Assert (@(Get-ChildItem -LiteralPath $jobs -Directory).Count -eq 2) 'each call gets its own job folder'
    $failed=Invoke-VendorOp 'fake' 'backup' @{mode='failed'} $jobs
    Assert ($failed.status -eq 'failed' -and $failed.reason -eq 'impl reason') 'status failed with exit 0 is a valid response for the caller to handle'

    # 응답이 어긋나면 exit 0이어도 실패
    foreach ($mode in 'none','badjson','wrongid','wrongop','badstatus','stringversion','big') {
        $null=Throws { Invoke-VendorOp 'fake' 'list' @{mode=$mode} $jobs } 'no valid response|응답이 없거나'
    }
    # 종료 코드
    $e=Throws { Invoke-VendorOp 'fake' 'restore' @{mode='exit1'} $jobs } 'impl said no'
    Assert ($e.Exception.Data['vendorResult'].status -eq 'failed') 'exit 1 keeps a valid response for the caller'
    $null=Throws { Invoke-VendorOp 'fake' 'restore' @{mode='exit1none'} $jobs } 'exit code 1|종료 코드 1'
    $null=Throws { Invoke-VendorOp 'fake' 'restore' @{mode='exit2'} $jobs } 'invalid|잘못된 요청'
    # 입력 검증
    $null=Throws { Invoke-VendorOp 'fake' 'format' @{} $jobs } 'Unknown vendor operation|알 수 없는 벤더 작업'
    foreach ($vendor in 'missing','empty','bad','absent') { $null=Throws { Invoke-VendorOp $vendor 'list' @{} $jobs } 'impls.json' }

    # 시간 초과: impl 프로세스를 끝내고 실패한다.
    $script:ContractTimeoutSec['probe']=3
    $before=@(Get-ChildItem -LiteralPath $jobs -Directory | ForEach-Object Name)
    $null=Throws { Invoke-VendorOp 'fake' 'probe' @{mode='sleep'} $jobs } 'within 3 seconds|3초 안에'
    $dir=Get-ChildItem -LiteralPath $jobs -Directory | Where-Object { $_.Name -notin $before } | Select-Object -First 1
    $fakePid=[int][IO.File]::ReadAllText((Join-Path $dir.FullName 'request.json.pid'))
    Start-Sleep -Milliseconds 500
    Assert ($null -eq (Get-Process -Id $fakePid -ErrorAction SilentlyContinue)) 'timed-out impl process is stopped'
    Write-Host "PASS: $script:Checks contract client assertions. Fake implementations only; no real implementation, native tool or user folder touched."
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
