#requires -Version 5.1
[CmdletBinding()]
param([string]$RequestFile, [string]$ResultFile, [switch]$LibraryOnly)
$ErrorActionPreference='Stop'
$script:VNextLibraryOnly=[bool]$LibraryOnly
# ClaudeWorker.ps1의 param 블록이 dot-source될 때 이 스코프의 요청·결과 경로를 빈 값으로 다시 묶으므로 보관했다가 되돌린다.
$script:VNextRequestFile=$RequestFile; $script:VNextResultFile=$ResultFile
. (Join-Path $PSScriptRoot 'ClaudeWorker.ps1') -LibraryOnly
$RequestFile=$script:VNextRequestFile; $ResultFile=$script:VNextResultFile
$script:ClaudeJobCore=${function:Invoke-JobCore}
$script:ClaudeFindExecutable=${function:Find-Executable}
. (Join-Path $PSScriptRoot 'ProjectFiles.ps1')
# Release integration replaces this pin only after reviewing the final candidate.
$script:DesktopTransportSHA256='9B14CCD3B33C75EDFD9D424D76FBAF17092364C58721C1BB9C0FD6BA73C7C006'
function Find-Executable([string]$Name) {
    if ($Name -eq 'ctxhop') { return (Join-Path $PSScriptRoot 'bin\ctxhop-claude.exe') }
    & $script:ClaudeFindExecutable $Name
}
function Assert-RestoreRuntime {
    $exe=Find-Executable 'ctxhop'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $script:RestoreBinarySHA256) { throw (T 'WkRestoreBinaryHash') }
    if ((Get-CtxVersion) -ne 'ctxhop 0.2.0-gui.3') { throw (T 'WkRestoreBinaryVersion') }
}
function Assert-FrozenFile([string]$Path,[string]$Pin) {
    if ($Pin -notmatch '^[a-fA-F0-9]{64}$' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw (T 'WkComponentMissing' $Path) }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Pin) { throw (T 'WkComponentHash' $Path) }
}
function Quote-NativeArgument([string]$Value) {
    # Windows CreateProcess quoting: doubles backslashes only before quotes and the final quote.
    return '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function Invoke-JsonNative([string]$Executable,[string[]]$Arguments) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$Executable; $start.Arguments=(@($Arguments | ForEach-Object {Quote-NativeArgument $_}) -join ' ')
    $start.UseShellExecute=$false; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true; $start.RedirectStandardInput=$true
    $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false); $start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    try {
        $null=$process.Start()
        # Desktop transport uses existing local device authorization. Missing grants fail closed on EOF.
        $process.StandardInput.Close()
        $output=$process.StandardOutput.ReadToEndAsync(); $errorOutput=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit(); $stdout=$output.Result; $stderr=$errorOutput.Result
        $report=$null
        try { $report=$stdout | ConvertFrom-Json } catch { if ($process.ExitCode -eq 0) { throw (T 'WkResultJsonInvalid') } }
        if ($process.ExitCode -ne 0) {
            # Python 백엔드는 stdout JSON의 reason, bundle CLI는 stderr로 실패 이유를 낸다.
            $message=if ($report.reason) {[string]$report.reason} elseif ($report.error) {[string]$report.error} elseif ($stderr.Trim()) {$stderr.Trim()} else {T 'WkJobFailedExitCode' $process.ExitCode}
            $exception=[InvalidOperationException]::new($message)
            if ($report) { $exception.Data['backendResult']=$report }
            throw $exception
        }
        if ($null -eq $report) { throw (T 'WkResultEmpty') }
        return $report
    } finally { $process.Dispose() }
}
function Invoke-Bundle([string[]]$Arguments) {
    $exe=Join-Path $PSScriptRoot 'bin\ctxhop.exe'
    Assert-FrozenFile $exe $script:DesktopTransportSHA256
    Invoke-JsonNative $exe (@('bundle') + $Arguments)
}
# 벤더 계약 v1(docs\contract-v1.md). Worker는 impls.json의 명령 배열 뒤에 <op> --request <파일> --response <파일>을 붙여 벤더 구현을 실행한다.
# 구현(CodexDesktop.ps1, ClaudeCode.ps1)은 이 파일을 라이브러리로 불러 Invoke-Impl로 요청을 읽고 op 처리기를 부른다.
# 구현은 콘솔을 물려받는다(ctxhop 암호 입력, 대화 열기). 결과는 응답 파일 하나로만 받는다.
$script:ImplsFile=Join-Path $PSScriptRoot 'impls.json'
# 자손이 스스로 끝나기를 기다리는 시간과, 그 뒤 Job 소속을 끝내며 기다리는 시간(초, S3 명세 2.2절).
$script:WorkerWaitSec=60; $script:WorkerKillSec=30
$script:ContractStatus=@{
    probe=@('ok','failed'); list=@('ok','unsupported','failed'); open=@('ok','unsupported','failed'); recover=@('ok','unsupported','failed')
    describe=@('ok','busy','unsupported','failed'); backup=@('ok','busy','changed','unsupported','failed')
    preview=@('ok','unsupported','failed'); restore=@('ok','unsupported','failed'); guard=@('ok','busy','unsupported','failed')
}
# status가 ok일 때 있어야 하는 필드와 형식. 그 밖의 필드는 선택이고 Worker는 해석하지 않고 넘긴다.
$script:ContractFields=@{
    probe=@{capabilities='array'}; list=@{sessions='array'}; open=@{}; recover=@{}
    describe=@{sourceCwd='string';cwds='array';edits='array';sourceStamp='string'}; backup=@{remoteId='string'}
    preview=@{state='string';choices='array';receipt='string';token='string'}; restore=@{effect='string';nativeId='string'}; guard=@{}
}
# ponytail: 암호 입력·대화 열기를 기다릴 수 있는 op(backup·preview·restore·open·recover)는 시간 제한 없이 GUI 취소(프로세스 트리 종료)에 맡긴다.
$script:ContractTimeoutSec=@{probe=120;list=1800;describe=1800;guard=120}
$script:ContractMaxBytes=16MB
function Test-VendorRow([object]$Row) {
    # 목록 행의 공통 필드. nativeId가 GUID가 아니면 blockedReason이 있어야 한다(확인하지 못한 백업).
    $count=$Row.recordCount
    if ($Row.nativeId -isnot [string] -or $Row.remoteId -isnot [string] -or $Row.title -isnot [string] -or $Row.local -isnot [bool] -or ($count -isnot [int] -and $count -isnot [long]) -or $count -lt 0) { return $false }
    if ($null -ne $Row.blockedReason) { return ($Row.blockedReason -is [string]) }
    $guid=[guid]::Empty
    return [guid]::TryParseExact($Row.nativeId,'D',[ref]$guid)
}
function Test-VendorResponse([object]$Response,[string]$Id,[string]$Op) {
    # 요청 짝(requestId·op), 프로토콜 판, 그 op에 허용된 status가 맞고, ok면 op별 필드 형식까지 맞아야 쓴다.
    if ($null -eq $Response -or $Response.protocolVersion -isnot [int] -or $Response.protocolVersion -ne 1 -or $Response.requestId -cne $Id -or $Response.op -cne $Op -or [string]$Response.status -cnotin $script:ContractStatus[$Op]) { return $false }
    foreach ($name in 'reasonCode','reason','message') { if ($null -ne $Response.$name -and $Response.$name -isnot [string]) { return $false } }
    if ($Response.status -cne 'ok') { return $true }
    $fields=$script:ContractFields[$Op]
    foreach ($name in $fields.Keys) {
        $value=$Response.$name
        if (($fields[$name] -eq 'string' -and $value -isnot [string]) -or ($fields[$name] -eq 'array' -and $value -isnot [array])) { return $false }
    }
    $strings={ param($Items) -not @($Items | Where-Object { $_ -isnot [string] }).Count }
    switch ($Op) {
        probe { return (& $strings $Response.capabilities) }
        list { return (-not @($Response.sessions | Where-Object { -not (Test-VendorRow $_) }).Count) }
        describe { return ((& $strings $Response.cwds) -and (& $strings $Response.edits)) }
        backup { return [bool]$Response.remoteId }
        preview { return (-not @($Response.choices | Where-Object { $_ -cne 'incoming' }).Count) }
        restore { return ($Response.effect -cin @('restored','equal','local_newer')) }
    }
    return $true
}
function New-VendorError([string]$Message,[object]$Response) {
    # 유효한 응답이 없으면 구현이 어디까지 했는지 모른다(이미 올렸거나 썼을 수 있다).
    $exception=[InvalidOperationException]::new($Message)
    if ($Response) { $exception.Data['vendorResult']=$Response } else { $exception.Data['vendorOutcome']='unknown' }
    return $exception
}
function Invoke-VendorOp([string]$Vendor,[string]$Op,[Collections.IDictionary]$Request,[string]$JobDir) {
    if (-not $script:ContractStatus[$Op]) { throw (T 'WkImplBadOp' $Op) }
    $map=Get-Content -LiteralPath $script:ImplsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $command=@($map.$Vendor)
    if (-not $command.Count -or @($command | Where-Object { $_ -isnot [string] -or -not $_ }).Count) { throw (T 'WkImplUnknown' $Vendor) }
    # 실행 파일은 PATH에서 찾지 않는다. powershell.exe는 System32 것을, 나머지는 impls.json 폴더 기준 경로를 쓴다.
    $base=Split-Path -Parent $script:ImplsFile
    $program=if ($command[0] -eq 'powershell.exe') { Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { Join-Path $base $command[0] }
    if (-not (Test-Path -LiteralPath $program -PathType Leaf)) { throw (T 'WkImplUnknown' $Vendor) }
    $id=[guid]::NewGuid().ToString()
    $dir=Join-Path $JobDir "$Op-$id"
    $null=New-Item -ItemType Directory -Path $dir
    $requestFile=Join-Path $dir 'request.json'; $responseFile=Join-Path $dir 'response.json'
    try {
        $body=[ordered]@{protocolVersion=1;requestId=$id;op=$Op;language=$script:UiLanguage}
        foreach ($key in $Request.Keys) { $body[$key]=$Request[$key] }
        [IO.File]::WriteAllText($requestFile,($body | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
        $start=[Diagnostics.ProcessStartInfo]::new()
        $start.FileName=$program; $start.WorkingDirectory=$base; $start.UseShellExecute=$false
        $start.Arguments=(@(@($command | Select-Object -Skip 1) + @($Op,'--request',$requestFile,'--response',$responseFile) | ForEach-Object {Quote-NativeArgument $_}) -join ' ')
        $process=[Diagnostics.Process]::Start($start)
        try {
            $limit=$script:ContractTimeoutSec[$Op]
            if ($limit -and -not $process.WaitForExit($limit*1000)) {
                # 구현과 그 자식(엔진·전송)을 부모-자식 관계로만 끝낸다. 이름으로 찾아 끝내지 않는다.
                $null=& (Join-Path $env:WINDIR 'System32\taskkill.exe') /T /F /PID $process.Id 2>&1
                throw (New-VendorError (T 'WkImplTimeout' $Vendor $Op $limit) $null)
            }
            $process.WaitForExit(); $code=$process.ExitCode
        } finally { $process.Dispose() }
        $response=$null
        if ((Test-Path -LiteralPath $responseFile -PathType Leaf) -and (Get-Item -LiteralPath $responseFile).Length -le $script:ContractMaxBytes) {
            try { $response=[IO.File]::ReadAllText($responseFile,[Text.UTF8Encoding]::new($false)) | ConvertFrom-Json } catch { $response=$null }
            if (-not (Test-VendorResponse $response $id $Op)) { $response=$null }
        }
    } finally {
        # 요청·응답에는 제목·경로가 들어 있으므로 이 호출의 파일을 지운다. 모르는 파일이 있으면 폴더는 남는다.
        foreach ($name in 'request.json','response.json','response.json.tmp') { $file=Join-Path $dir $name; if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
        try { [IO.Directory]::Delete($dir,$false) } catch { }
    }
    # 종료 코드 2는 구현이 요청을 읽기 전에 거절했다는 뜻이라 아무것도 하지 않았다.
    if ($code -eq 2) { throw (T 'WkImplRequestInvalid' $Vendor $Op) }
    if ($code -ne 0) { throw (New-VendorError $(if ($response.reason) {[string]$response.reason} else {T 'WkImplFailed' $Vendor $Op $code}) $response) }
    if (-not $response) { throw (New-VendorError (T 'WkImplBadResponse' $Vendor $Op) $null) }
    return $response
}
function Invoke-ImplOp([hashtable]$Ops,[object]$Request) {
    # 구현 쪽: 요청 하나를 op 처리기에 넘겨 응답을 만든다. 처리기가 status를 돌려주면 그 값을 쓰고, 던진 오류는 failed가 된다.
    # 예외의 backendResult는 detail로, reasonCode·recovery는 같은 이름으로 옮긴다.
    $op=[string]$Request.op
    $response=[ordered]@{protocolVersion=1;requestId=[string]$Request.requestId;op=$op;status='ok';reasonCode='';reason=''}
    if ($op -eq 'probe') { $response.capabilities=@(@('probe')+@($Ops.Keys | Sort-Object)); return $response }
    if (-not $Ops.ContainsKey($op)) { $response.status='unsupported'; $response.reasonCode='op_unsupported'; $response.reason=(T 'WkImplOpUnsupported' $op); return $response }
    try {
        $result=& $Ops[$op] $Request
        foreach ($key in $result.Keys) { $response[$key]=$result[$key] }
    } catch {
        $response.status='failed'; $response.reason=$_.Exception.Message
        foreach ($key in 'reasonCode','recovery') { if ($_.Exception.Data.Contains($key)) { $response[$key]=[string]$_.Exception.Data[$key] } }
        if ($_.Exception.Data.Contains('backendResult')) { $response.detail=$_.Exception.Data['backendResult'] }
    }
    return $response
}
function Invoke-Impl([hashtable]$Ops,[object[]]$Arguments) {
    # 구현 진입점: <op> --request <파일> --response <파일>. 요청을 읽거나 검사하지 못하면 아무것도 하지 않고 종료 코드 2로 끝낸다.
    try {
        if ($Arguments.Count -ne 5 -or $Arguments[1] -cne '--request' -or $Arguments[3] -cne '--response' -or -not $script:ContractStatus[[string]$Arguments[0]] -or (Get-Item -LiteralPath $Arguments[2]).Length -gt $script:ContractMaxBytes) { throw 'usage' }
        $request=[IO.File]::ReadAllText($Arguments[2],[Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        $guid=[guid]::Empty
        if ($request.protocolVersion -isnot [int] -or $request.protocolVersion -ne 1 -or $request.op -cne $Arguments[0] -or -not [guid]::TryParseExact([string]$request.requestId,'D',[ref]$guid)) { throw 'request' }
    } catch { exit 2 }
    Set-Language ([string]$request.language)
    $response=Invoke-ImplOp $Ops $request
    $json=ConvertTo-Json -InputObject $response -Depth 40
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:ContractMaxBytes) {
        # 잘라서 보내지 않고 실패로 알린다.
        $json=ConvertTo-Json -InputObject ([ordered]@{protocolVersion=1;requestId=$response.requestId;op=$response.op;status='failed';reasonCode='response_too_large';reason=(T 'WkImplResponseTooLarge' $response.op)})
    }
    $file=[string]$Arguments[4]
    [IO.File]::WriteAllText("$file.tmp",$json,[Text.UTF8Encoding]::new($false))
    [IO.File]::Move("$file.tmp",$file)
    exit 0
}
function Assert-OperationId([object]$Id) {
    # Worker가 복원마다 만드는 작업 ID(GUID N 형식). 벤더는 이 이름으로 첫 쓰기 전에 복구 기록을 만든다.
    if ($Id -isnot [string] -or $Id -cnotmatch '^[0-9a-f]{32}$') { throw (T 'WkOperationIdInvalid') }
    return $Id
}
function Get-SourceStamp([string]$SourceCwd,[string[]]$Cwds,[string[]]$Edits) {
    # 백업할 작업 폴더를 정하는 입력(시작 폴더·작업 폴더·고친 파일)의 SHA-256. describe와 backup 사이에 바뀌었는지 비교한다.
    $text=ConvertTo-Json -InputObject ([ordered]@{sourceCwd=$SourceCwd;cwds=@($Cwds | Sort-Object);edits=@($Edits | Sort-Object)}) -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return (Get-ProjectHex ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))) } finally { $sha.Dispose() }
}
function Assert-BundleId([string]$Id) {
    if ($Id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}/[a-f0-9]{32}$' -or $Id.Split('/')[0] -in @('.','..')) { throw (T 'WkBadBundleId') }
}
function Assert-BundleMetadata([object]$Metadata) {
    $fields=@('sessionId','title','sourceCwd','updatedAt','historyMode','cliVersion','recordCount')
    foreach ($field in $fields) { if ($Metadata.PSObject.Properties.Name -notcontains $field) { throw (T 'WkMetadataFieldMissing' $field) } }
    Assert-NativeId $Metadata.sessionId
    foreach ($field in @('title','sourceCwd','updatedAt','historyMode','cliVersion')) { if ($Metadata.$field -isnot [string]) { throw (T 'WkMetadataFieldInvalid' $field) } }
    $stamp=[datetimeoffset]::MinValue
    if ($Metadata.updatedAt -notmatch '^\d{4}-\d{2}-\d{2}T.+(Z|[+-]\d{2}:\d{2})$' -or -not [datetimeoffset]::TryParse($Metadata.updatedAt,[ref]$stamp)) { throw (T 'WkMetadataBadDate') }
    if (($Metadata.recordCount -isnot [int] -and $Metadata.recordCount -isnot [long]) -or $Metadata.recordCount -lt 0) { throw (T 'WkMetadataBadCount') }
}
function New-DesktopStage([string]$Name='staging') {
    $root=Join-Path $env:LOCALAPPDATA "CtxHopGUI\$Name"
    $null=New-Item -ItemType Directory -Path $root -Force
    $path=Join-Path $root ([guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $path
    # Plaintext archives remain local, with the same private boundary as recovery originals.
    $acl=[Security.AccessControl.DirectorySecurity]::new(); $acl.SetAccessRuleProtection($true,$false)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule); Set-Acl -LiteralPath $path -AclObject $acl
    return $path
}
function Remove-DesktopStage([string]$Stage) {
    # 이 작업이 만든 staging\<GUID> 폴더의 알려진 파일만 지운다(재귀 삭제·링크 추적 없음). 이미 끝난 작업이므로 실패해도 경고만 돌려준다.
    try {
        $root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CtxHopGUI\staging'))
        $path=[IO.Path]::GetFullPath($Stage)
        if ([IO.Path]::GetDirectoryName($path) -ne $root -or [IO.Path]::GetFileName($path) -notmatch '^[a-f0-9]{32}$' -or ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint)) { throw 'unexpected staging folder' }
        foreach ($file in [IO.Directory]::GetFiles($path)) {
            $name=[IO.Path]::GetFileName($file)
            if ($name -in @('session.archive','metadata.json','inspect.json') -or $name -match '^project-[a-z0-9-]+\.(zip|json)$') { [IO.File]::Delete($file) }
        }
        [IO.Directory]::Delete($path,$false)
        return ''
    } catch { return (T 'WkStageCleanupFailed' $Stage) }
}
function Get-BundleFile([string]$Id,[string]$Output) {
    Assert-BundleId $Id
    $download=Invoke-Bundle @('get','--id',$Id,'--output',$Output,'--json')
    if ($download.id -cne $Id -or $download.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash -ne $download.sha256 -or (Get-Item -LiteralPath $Output).Length -ne $download.bytes) { throw (T 'WkDownloadIntegrity') }
    return $download
}
function Save-Bundle([string]$File,[string]$MetadataFile,[Collections.IDictionary]$Metadata) {
    [IO.File]::WriteAllText($MetadataFile,(ConvertTo-Json -InputObject $Metadata),[Text.UTF8Encoding]::new($false))
    $bundle=Invoke-Bundle @('put','--input',$File,'--metadata',$MetadataFile,'--json')
    Assert-BundleId $bundle.id
    return $bundle.id
}
function Get-ProjectStamp { return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'") }
function Get-ProjectBundles {
    # 프로젝트 파일(project-files)과 대화 백업과의 연결 기록(project-link) bundle.
    $remote=Invoke-Bundle @('list','--json')
    if ($remote.bundles -isnot [array]) { throw (T 'WkBundleListInvalid') }
    foreach ($bundle in $remote.bundles) {
        try { Assert-BundleId $bundle.id; Assert-BundleMetadata $bundle.metadata } catch { continue }
        if ($bundle.metadata.historyMode -like 'project-*') { $bundle }
    }
}
function Get-ProjectPlan([object]$Job,[string]$Start,[string[]]$Cwds,[string[]]$Edits) {
    # 백업할 작업 폴더와 파일 목록. 커서 아직 허락받지 않은 폴더는 ask에 모은다(그러면 GUI가 대화째 보류한다).
    $picked=Get-ProjectFolders $Start $Cwds $Edits
    $approved=@(@($Job.projectApproved) | ForEach-Object { ConvertTo-ProjectPath $_ })
    $folders=@(); $ask=@()
    foreach ($folder in $picked.folders) {
        $entry=[ordered]@{role=$folder.role;sourcePath=$folder.path;bundleId='';contentHash='';files=0;bytes=[long]0;status='skipped';reason='';list=$null}
        if (-not [IO.Directory]::Exists($folder.path)) { $entry.reason='missing' }
        else {
            try {
                $entry.list=Get-ProjectFileList $folder.path; $entry.files=$entry.list.files.Count; $entry.bytes=$entry.list.bytes; $entry.status='pending'
                # 200MB 이상은 먼저 대화째 보류해 묻는다. 고른 뒤에도 압축 전 16GiB가 넘으면 받는 쪽이 풀지 않으므로 그 폴더만 뺀다.
                if ($entry.bytes -ge $script:ProjectAskBytes -and $approved -inotcontains $folder.path) { $ask+=[pscustomobject]@{path=$folder.path;files=$entry.files;bytes=$entry.bytes} }
                elseif ($entry.bytes -gt $script:ProjectMaxBytes) { $entry.status='skipped'; $entry.reason='tooLarge' }
            } catch { $entry.reason=$_.Exception.Message }
        }
        $folders+=,$entry
    }
    return @{folders=$folders;skipped=@($picked.skipped);outside=@($picked.outside);ask=$ask;approved=$approved}
}
function New-ProjectQuestion([hashtable]$Plan) {
    # 대화도 올리지 않고 돌려준다. GUI가 보류했다가 사용자가 고르면 projectApproved를 넣어 다시 실행한다.
    return @{needsProjectConfirm=$true;folders=@($Plan.ask);message=(T 'WkProjectAskSize' @($Plan.ask).Count)}
}
function Save-ProjectBackup([hashtable]$Plan,[string]$Agent,[string]$SessionId,[string]$Conversation,[string]$Stage) {
    # 폴더마다 같은 내용의 백업이 이미 있으면 연결만 하고 없으면 올린다. 마지막에 이 대화 백업과 폴더 백업을 잇는 기록을 올린다.
    $bundles=[Collections.Generic.List[object]]::new(); foreach ($bundle in @(Get-ProjectBundles)) { $bundles.Add($bundle) }
    $unreadable=0; $unsafe=0
    for ($i=0; $i -lt $Plan.folders.Count; $i++) {
        $entry=$Plan.folders[$i]
        if ($entry.status -ne 'pending') { continue }
        $zip=Join-Path $Stage "project-$i.zip"
        # 계획을 세운 뒤에도 파일이 커질 수 있으므로 실제로 읽는 압축 전 총량을 제한한다. 허락받은 폴더는 받는 쪽 한도(16GiB)까지,
        # 묻지 않은 폴더는 묻는 기준(200MB) 아래까지만 읽고, 넘으면 그 폴더는 올리지 않는다(대화 백업은 그대로).
        $approved=@($Plan.approved) -icontains $entry.sourcePath
        $limit=if ($approved) {$script:ProjectMaxBytes} else {$script:ProjectAskBytes-1}
        $overReason=if ($approved) {'tooLarge'} else {T 'WkProjectGrewUnapproved'}
        try {
            $manifest=Get-ProjectManifest $entry.list $limit
            if ($manifest.overLimit) { $entry.status='skipped'; $entry.reason=$overReason; continue }
            $hash=$manifest.hash; $missed=$manifest.unreadable.Count
            $found=@($bundles | Where-Object { $_.metadata.historyMode -ceq "project-files;v1;$hash" })
            $snapshot=$null
            if (-not $found.Count) {
                # 해시를 구한 뒤 바뀐 파일이 있을 수 있으므로 실제로 넣은 내용의 해시로 다시 찾는다.
                $snapshot=New-ProjectSnapshot $entry.list $zip $limit
                if ($snapshot.overLimit) { $entry.status='skipped'; $entry.reason=$overReason; continue }
                $hash=$snapshot.hash; $missed=$snapshot.unreadable.Count; $entry.files=$snapshot.files; $entry.bytes=$snapshot.bytes
                $found=@($bundles | Where-Object { $_.metadata.historyMode -ceq "project-files;v1;$hash" })
            }
            $entry.contentHash=$hash; $unreadable+=$missed+[int]$entry.list.excluded.unreadable; $unsafe+=[int]$entry.list.excluded.unsafe
            if ($found.Count) { $entry.bundleId=$found[0].id; $entry.status='reused' }
            elseif ($snapshot.archiveBytes -gt $script:ProjectMaxArchiveBytes) { $entry.status='skipped'; $entry.reason='tooLarge' }
            else {
                $metadata=[ordered]@{sessionId=('{0}-{1}-{2}-{3}-{4}' -f $hash.Substring(0,8),$hash.Substring(8,4),$hash.Substring(12,4),$hash.Substring(16,4),$hash.Substring(20,12));title=[IO.Path]::GetFileName($entry.sourcePath);sourceCwd=$entry.sourcePath;updatedAt=(Get-ProjectStamp);historyMode="project-files;v1;$hash";cliVersion='ctxhop-gui-vnext';recordCount=$entry.files}
                $entry.bundleId=Save-Bundle $zip (Join-Path $Stage "project-$i.json") $metadata; $entry.status='uploaded'
                $bundles.Add([pscustomobject]@{id=$entry.bundleId;metadata=[pscustomobject]$metadata})
            }
        } catch { $entry.status='skipped'; $entry.reason=$_.Exception.Message }
        finally { if ([IO.File]::Exists($zip)) { [IO.File]::Delete($zip) } }
    }
    $folders=@($Plan.folders | ForEach-Object { [ordered]@{role=$_.role;sourcePath=$_.sourcePath;bundleId=$_.bundleId;contentHash=$_.contentHash;files=$_.files;bytes=$_.bytes;status=$_.status;reason=$_.reason} })
    $link=[ordered]@{version=1;agent=$Agent;sessionId=$SessionId;conversation=$Conversation;createdAt=(Get-ProjectStamp);folders=$folders;skipped=@($Plan.skipped);outside=@($Plan.outside)}
    $linkFile=Join-Path $Stage 'project-link.json'
    [IO.File]::WriteAllText($linkFile,(ConvertTo-Json -InputObject $link -Depth 6),[Text.UTF8Encoding]::new($false))
    $start=@($folders | Where-Object { $_.role -eq 'start' } | ForEach-Object { $_.sourcePath })
    $metadata=[ordered]@{sessionId=$SessionId;title=$Conversation;sourceCwd=[string]($start | Select-Object -First 1);updatedAt=$link.createdAt;historyMode="project-link;v1;$Agent";cliVersion='ctxhop-gui-vnext';recordCount=$folders.Count}
    $linkId=Save-Bundle $linkFile (Join-Path $Stage 'project-link-metadata.json') $metadata
    $uploaded=@($folders | Where-Object { $_.status -eq 'uploaded' }).Count; $reused=@($folders | Where-Object { $_.status -eq 'reused' }).Count
    $message=T 'WkProjectBackedUp' $folders.Count $uploaded $reused ($folders.Count-$uploaded-$reused)
    if ($Plan.outside.Count) { $message+=T 'WkProjectOutside' $Plan.outside.Count }
    if ($unreadable) { $message+=T 'WkProjectUnreadable' $unreadable }
    if ($unsafe) { $message+=T 'WkProjectUnsafeNames' $unsafe }
    return @{linkId=$linkId;folders=$folders;skipped=@($Plan.skipped);outside=@($Plan.outside);message=$message}
}
function Read-ProjectLink([string]$File,[string]$Agent,[string]$SessionId,[string]$Conversation) {
    $link=try { Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw (T 'WkProjectLinkInvalid') }
    if ($link.version -ne 1 -or $link.agent -cne $Agent -or $link.sessionId -ne $SessionId -or $link.conversation -cne $Conversation -or $link.folders -isnot [array] -or $link.folders.Count -gt 64) { throw (T 'WkProjectLinkInvalid') }
    foreach ($folder in $link.folders) {
        if ($folder.role -notin @('start','extra') -or $folder.sourcePath -isnot [string] -or -not (ConvertTo-ProjectPath $folder.sourcePath) -or $folder.status -notin @('uploaded','reused','skipped')) { throw (T 'WkProjectLinkInvalid') }
        if ($folder.status -ne 'skipped') { Assert-BundleId $folder.bundleId; if ($folder.contentHash -cnotmatch '^[0-9a-f]{64}$') { throw (T 'WkProjectLinkInvalid') } }
    }
    return $link
}
function Get-ProjectPreview([string]$Agent,[string]$SessionId,[string]$Conversation,[string]$Target,[string]$Stage,[hashtable]$Pair) {
    # 이 대화 백업에 이어진 프로젝트 파일을 받아 복원할 폴더와 비교한다. 이 PC에 없는 추가 폴더는 GUI가 고르도록 needsFolder로 둔다.
    # $Pair는 같은 미리보기의 대화 쪽 값(대상 홈, 벤더 receipt·token)이다. 복원할 때 이 기록과 짝이 맞아야 한다(Assert-ProjectPairing).
    $links=@(Get-ProjectBundles | Where-Object { $_.metadata.historyMode -ceq "project-link;v1;$Agent" -and $_.metadata.sessionId -eq $SessionId -and $_.metadata.title -ceq $Conversation } | Sort-Object { [datetimeoffset]::Parse($_.metadata.updatedAt) } -Descending)
    if (-not $links.Count) { return @{state='none'} }
    $linkFile=Join-Path $Stage 'project-link.json'
    $null=Get-BundleFile $links[0].id $linkFile
    $link=Read-ProjectLink $linkFile $Agent $SessionId $Conversation
    $folders=@(); $ignored=(Get-ProjectIgnoredRoots).all
    for ($i=0; $i -lt $link.folders.Count; $i++) {
        $folder=$link.folders[$i]
        $entry=[ordered]@{index=$i;role=$folder.role;sourcePath=(ConvertTo-ProjectPath $folder.sourcePath);status=$folder.status;reason=[string]$folder.reason;files=$folder.files;bytes=$folder.bytes;bundleId=[string]$folder.bundleId;contentHash=[string]$folder.contentHash;target='';zip='';sha256='';compare=$null;state='skipped'}
        if ($folder.status -ne 'skipped') {
            # 한 폴더를 받거나 읽지 못해도 다른 폴더와 대화 미리보기는 그대로 둔다. 그 폴더만 error로 두고 복원하지 않는다.
            try {
                $autoTarget=[IO.Directory]::Exists($entry.sourcePath) -and -not (Test-ProjectTooBroad $entry.sourcePath) -and -not (Test-ProjectUnder $entry.sourcePath $ignored)
                $entry.target=if ($folder.role -eq 'start') {$Target} elseif ($autoTarget) {$entry.sourcePath} else {''}
                $entry.zip=Join-Path $Stage "project-$i.zip"
                $entry.sha256=(Get-BundleFile $folder.bundleId $entry.zip).sha256
                $snapshot=Read-ProjectSnapshot $entry.zip
                if ($snapshot.hash -cne $folder.contentHash) { throw (T 'WkProjectContentMismatch' $entry.sourcePath) }
                if ($entry.target) { $entry.compare=Compare-ProjectSnapshot $snapshot $entry.target; $entry.state='ready' } else { $entry.state='needsFolder' }
            } catch { $entry.state='error'; $entry.reason=$_.Exception.Message; $entry.target=''; $entry.compare=$null }
        }
        $folders+=,$entry
    }
    $receipt=Join-Path $Stage 'project-receipt.json'
    [IO.File]::WriteAllText($receipt,(ConvertTo-Json -InputObject ([ordered]@{agent=$Agent;sessionId=$SessionId;conversation=$Conversation;home=[string]$Pair.home;target=$Target;receipt=[string]$Pair.receipt;token=[string]$Pair.token;previewState=[string]$Pair.state;linkId=$links[0].id;folders=$folders}) -Depth 8),[Text.UTF8Encoding]::new($false))
    return @{state='found';receipt=$receipt;createdAt=[string]$link.createdAt;folders=$folders;skipped=@($link.skipped);outside=@($link.outside)}
}
function Get-ProjectPreviewSafe([string]$Agent,[string]$SessionId,[string]$Conversation,[string]$Target,[string]$Stage,[hashtable]$Pair) {
    # 프로젝트 파일을 읽지 못해도 대화 미리보기는 그대로 보인다.
    try { return (Get-ProjectPreview $Agent $SessionId $Conversation $Target $Stage $Pair) } catch { return @{state='error';reason=$_.Exception.Message} }
}
function Read-ProjectReceipt([string]$Path,[string]$Agent,[string]$SessionId,[string]$Conversation) {
    $root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CtxHopGUI\staging')).TrimEnd('\')
    $file=[IO.Path]::GetFullPath($Path); $stage=[IO.Path]::GetDirectoryName($file)
    if ([IO.Path]::GetDirectoryName($stage) -ne $root -or [IO.Path]::GetFileName($stage) -notmatch '^[a-f0-9]{32}$' -or [IO.Path]::GetFileName($file) -ne 'project-receipt.json') { throw (T 'WkProjectReceiptInvalid') }
    $record=try { Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw (T 'WkProjectReceiptInvalid') }
    if ($record.agent -cne $Agent -or $record.sessionId -ne $SessionId -or $record.conversation -cne $Conversation -or $record.folders -isnot [array]) { throw (T 'WkProjectReceiptInvalid') }
    foreach ($folder in $record.folders) {
        if ($folder.state -notin @('ready','needsFolder')) { continue }
        if ($folder.index -isnot [int] -or $folder.role -notin @('start','extra') -or $folder.zip -ne (Join-Path $stage "project-$($folder.index).zip") -or $folder.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw (T 'WkProjectReceiptInvalid') }
    }
    return $record
}
function Assert-ProjectPairing([object]$Job) {
    # 프로젝트 미리보기가 이번 복원과 같은 미리보기에서 나왔는지 대화를 쓰기 전에 확인한다: 벤더·대화 ID, 대상 홈, 복원 폴더,
    # 벤더 receipt·token이 모두 같아야 한다. 틀리면 아무것도 쓰거나 지우지 않고 멈춘다.
    $record=Read-ProjectReceipt $Job.projectReceipt ([string]$Job.agent) ([string]$Job.nativeId) ([string]$Job.remoteId)
    $target=Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path
    if ($record.home -isnot [string] -or $record.home -cne [string]$Job.home -or $record.target -ne $target -or $record.receipt -cne [string]$Job.receipt -or $record.token -cne [string]$Job.token) { throw (T 'WkProjectReceiptInvalid') }
    return $record
}
function Invoke-Vendor([object]$Job,[string]$Op,[hashtable]$Request) {
    # 작업의 벤더 구현을 계약으로 부른다. ok가 아니면 그 이유로 실패시킨다.
    # 공통 문맥: 대상 홈(Codex), GUI의 프로젝트 폴더, Claude 등록 이름. 비밀정보는 넣지 않는다.
    $body=@{home=[string]$Job.home;projectPath=[string]$Job.projectPath;identity=[string]$Job.identity}
    foreach ($key in $Request.Keys) { $body[$key]=$Request[$key] }
    $jobs=Join-Path $env:LOCALAPPDATA 'CtxHopGUI\jobs'
    $null=New-Item -ItemType Directory -Path $jobs -Force
    $response=Invoke-VendorOp ([string]$Job.agent) $Op $body $jobs
    if ($response.status -ceq 'ok') { return $response }
    $exception=[InvalidOperationException]::new($(if ($response.reason) {[string]$response.reason} else {T 'WkImplStatus' $Job.agent $Op $response.status}))
    $exception.Data['vendorResult']=$response
    # GUI는 backendResult.status가 busy면 건너뜀으로 세고, 그 밖에는 복구 기록으로 보여 준다.
    if ($response.detail) { $exception.Data['backendResult']=$response.detail }
    elseif ($response.status -ceq 'busy') { $exception.Data['backendResult']=[pscustomobject]@{status='busy';reason=[string]$response.reason} }
    throw $exception
}
function Get-JournalDir { return (Join-Path $env:LOCALAPPDATA 'CtxHopGUI\journal') }
function Get-RecoveryRoot { return (Join-Path $env:LOCALAPPDATA 'CtxHopGUI\project-recovery') }
function New-PrivateFolder([string]$Path) {
    # 원본 사본이 들어가는 폴더는 이 사용자만 읽는다(New-DesktopStage와 같은 경계). 이미 있으면 쓰지 않고 멈춘다.
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    if ([IO.Directory]::Exists($Path)) { throw (T 'WkJournalExists' $Path) }
    $null=New-Item -ItemType Directory -Path $Path
    $acl=[Security.AccessControl.DirectorySecurity]::new(); $acl.SetAccessRuleProtection($true,$false)
    $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule); Set-Acl -LiteralPath $Path -AclObject $acl
    return $Path
}
function Save-Marker([Collections.IDictionary]$Marker) {
    # 공통 표지(S3 명세 2.4절). 임시 파일에 쓰고 비운 뒤 Move/Replace로 바꾼다.
    $Marker.updated=Get-ProjectStamp
    $null=[IO.Directory]::CreateDirectory((Get-JournalDir))
    Save-ProjectJson (Join-Path (Get-JournalDir) "$($Marker.operationId).json") $Marker
}
function New-Marker([object]$Job,[string]$Operation,[string[]]$Targets,[string]$Recovery,[string]$Phase,[string]$RecordRef,[string]$RecordKind) {
    # 표지 없는 기록을 되돌리거나 닫을 때는 recordRef에 원래 기록(벤더 recordId 또는 프로젝트 기록 폴더)을 적는다(S3 명세 2.2절, R37-N1).
    $marker=[ordered]@{version=1;operationId=$Operation;agent=[string]$Job.agent;nativeId=[string]$Job.nativeId;remoteId=[string]$Job.remoteId;home=[string]$Job.home;targets=@($Targets);projectRecovery=$Recovery;recordRef=$RecordRef;recordKind=$RecordKind;phase=$Phase;phaseBefore=$null;started=(Get-ProjectStamp);updated='';error=''}
    foreach ($field in (Get-WorkerFields).GetEnumerator()) { $marker[$field.Key]=$field.Value }
    Save-Marker $marker
    return $marker
}
function Read-Markers {
    # 표지 파일마다 {path, name, marker}. 읽지 못하거나 이름과 맞지 않으면 marker는 $null이다.
    $dir=Get-JournalDir
    if (-not [IO.Directory]::Exists($dir)) { return }
    foreach ($file in [IO.Directory]::GetFiles($dir,'*.json')) {
        $name=[IO.Path]::GetFileNameWithoutExtension($file)
        $marker=try {
            $record=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($record.version -eq 1 -and [string]$record.operationId -ceq $name -and $name -cmatch '^[0-9a-f]{32}$') { $table=[ordered]@{}; foreach ($p in $record.PSObject.Properties) { $table[$p.Name]=$p.Value }; $table } else { $null }
        } catch { $null }
        [pscustomobject]@{path=$file;name=$name;marker=$marker}
    }
}
function Get-MarkerJob([Collections.IDictionary]$Marker) { return [pscustomobject]@{agent=[string]$Marker.agent;home=[string]$Marker.home} }
function Get-MarkerRef([Collections.IDictionary]$Marker) { if ($Marker.recordRef) { return [string]$Marker.recordRef }; return [string]$Marker.operationId }
function Enter-Marker([Collections.IDictionary]$Marker) {
    # 앞 writer가 모두 끝났음을 확인한 뒤에만 이 Worker로 넘겨받는다(S3 명세 2.2절). 쓰기·자식 생성보다 먼저 한다.
    if ((Test-WorkerWritersGone $Marker) -ne 'gone') { throw (T 'WkJournalBusy') }
    foreach ($field in (Get-WorkerFields).GetEnumerator()) { $Marker[$field.Key]=$field.Value }
    Save-Marker $Marker
}
function Get-CodexRetainedKinds([object]$Record) {
    # 이 필드는 증명 결과의 표시일 뿐 원본 삭제·쓰기 권한이 아니다. 순서는 v2 store catalog와 같다.
    $allowed=@('state.migrationCursor','queue.revision','agentMessageBoard.deletedBoard')
    $kind=$Record.absenceKind; $kinds=$Record.retainedKinds
    if ($null -ne $kind -and $kind -isnot [string]) { throw (T 'WkRetainedProofUnknown') }
    if ($null -ne $kinds -and $kinds -isnot [array]) { throw (T 'WkRetainedProofUnknown') }
    if ($null -eq $kind -or $kind -ceq 'absent') {
        if ($null -ne $kinds -and $kinds.Count) { throw (T 'WkRetainedProofUnknown') }
        return
    }
    if ($kind -isnot [string] -or $kind -cne 'retained' -or $kinds -isnot [array] -or -not $kinds.Count) { throw (T 'WkRetainedProofUnknown') }
    $last=-1
    foreach ($entry in $kinds) {
        if ($entry -isnot [string]) { throw (T 'WkRetainedProofUnknown') }
        $index=-1
        for ($i=0; $i -lt $allowed.Count; $i++) { if ($entry -ceq $allowed[$i]) { $index=$i; break } }
        if ($index -le $last) { throw (T 'WkRetainedProofUnknown') }
        $last=$index
        $entry
    }
}
function Set-MarkerVendorAbsence([Collections.IDictionary]$Marker,[object]$Report,[string]$State) {
    # 재시도 중 기존 증명을 누락·불일치 응답으로 없애지 않는다. 잘못된 표지도 먼저 거절한다.
    $previous=@(Get-CodexRetainedKinds $Marker)
    $kinds=@(Get-CodexRetainedKinds $Report)
    if ($previous.Count -and ($Marker.agent -cne 'codex-desktop' -or $State -cne 'rolled_back' -or ($previous -join '|') -cne ($kinds -join '|'))) { throw (T 'WkRetainedProofUnknown') }
    if ($kinds.Count) {
        if ($Marker.agent -cne 'codex-desktop' -or $State -cne 'rolled_back') { throw (T 'WkRetainedProofUnknown') }
        $Marker.absenceKind='retained'; $Marker.retainedKinds=[string[]]$kinds
    } else {
        $null=$Marker.Remove('absenceKind'); $null=$Marker.Remove('retainedKinds')
    }
}
function Get-VendorState([Collections.IDictionary]$Marker) {
    # 벤더 기록 상태(S3 명세 2.3절). 최소 표지는 새 operationId가 아니라 원래 기록(recordRef)을 조회한다(R37-N1).
    # 조회 자체가 실패하면 failed(unreadable처럼 다루지만 닫지는 않는다). 프로젝트 기록 표지는 벤더가 없다(none).
    if ($Marker.recordKind -eq 'project') { return 'none' }
    try {
        $report=Invoke-Vendor (Get-MarkerJob $Marker) 'recover' @{mode='status';operationId=(Get-MarkerRef $Marker)}
        $state=[string]$report.state
        if ($state -cnotin @('absent','pending','complete','rolled_back','resolved','unreadable')) { return 'failed' }
        Set-MarkerVendorAbsence $Marker $report $state
    } catch { return 'failed' }
    return $state
}
function Read-ProjectPlan([string]$Recovery) {
    # restore-plan.json. 없으면 $null(프로젝트에 아직 쓰지 않음). 읽지 못하면 예외.
    if (-not $Recovery) { return $null }
    $file=Join-Path $Recovery 'restore-plan.json'
    if (-not [IO.File]::Exists($file)) { return $null }
    $plan=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($plan.version -ne 1) { throw (T 'WkProjectPlanInvalid' $file) }
    return $plan
}
function Test-ProjectSuccess([Collections.IDictionary]$Marker) {
    # 프로젝트 성공 증거(S3 명세 2.5절): 계획의 write는 모두 written, same은 모두 same으로 restore-log.json에 있다. 폴더가 없던 작업은 성공이다.
    try {
        $plan=Read-ProjectPlan ([string]$Marker.projectRecovery)
        if (-not $plan) { return (-not @($Marker.targets | Where-Object { $_ }).Count) }
        $log=Get-Content -LiteralPath (Join-Path $Marker.projectRecovery 'restore-log.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$log.operationId -cne [string]$Marker.operationId) { return $false }
        $states=@{}; foreach ($file in @($log.files)) { $states[[int]$file.index]=[string]$file.state }
        foreach ($file in @($plan.files)) { if ($states[[int]$file.index] -cne $(if ($file.action -eq 'same') {'same'} else {'written'})) { return $false } }
        return $true
    } catch { return $false }
}
function Undo-MarkerProject([Collections.IDictionary]$Marker,[object[]]$Confirmed) {
    # 계획이 없으면 쓴 파일이 없으므로 끝난 것이다. 파일 이름은 원래 작업 ID(기록 폴더 이름)로 정한다.
    $plan=Read-ProjectPlan ([string]$Marker.projectRecovery)
    if (-not $plan) { return [pscustomobject]@{complete=$true;files=@()} }
    return (Undo-ProjectRestorePlan @($plan.files) ([string]$Marker.projectRecovery) ([IO.Path]::GetFileName([string]$Marker.projectRecovery)) $Confirmed)
}
function Set-MarkerAttention([Collections.IDictionary]$Marker,[string]$Reason) {
    $Marker.error=$Reason; Save-Marker $Marker
    return 'attention'
}
function Test-DoneRecord([Collections.IDictionary]$Marker) {
    # 종료 기록이 이 표지의 것이고 결과와 상태가 맞는지(S3 명세 2.5절). 맞을 때만 표지를 지운다.
    $file=Join-Path (Get-JournalDir) "done\$($Marker.operationId).json"
    if (-not [IO.File]::Exists($file)) { return $false }
    try { $done=Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $false }
    if ($done.version -ne 1 -or [string]$done.operationId -cne [string]$Marker.operationId -or [string]$done.agent -cne [string]$Marker.agent -or [string]$done.home -cne [string]$Marker.home) { return $false }
    try {
        $retained=@(Get-CodexRetainedKinds $done)
        $null=@(Get-CodexRetainedKinds $Marker)
        if ($retained.Count) {
            if ($Marker.agent -cne 'codex-desktop' -or $done.outcome -cne 'rolled_back' -or $done.vendorState -cne 'rolled_back' -or $Marker.absenceKind -cne 'retained' -or (@($Marker.retainedKinds) -join '|') -cne ($retained -join '|')) { return $false }
        } elseif ($Marker.absenceKind -ceq 'retained') { return $false }
    } catch { return $false }
    switch -CaseSensitive ([string]$done.outcome) {
        completed { return ([string]$done.vendorState -cin @('complete','equal') -and $done.project.success -eq $true) }
        rolled_back { return ([string]$done.vendorState -cin @('absent','rolled_back','none') -and $done.project.complete -eq $true) }
        resolved { return ([string]$done.vendorState -cin @('resolved','absent','complete','rolled_back','none')) }
    }
    return $false
}
function Close-Marker([Collections.IDictionary]$Marker,[string]$Outcome,[string]$VendorState,[hashtable]$Project) {
    # 자손이 모두 끝난 뒤, 종료 기록을 먼저 쓰고 확인한 다음 표지를 지운다(S3 명세 2.2·2.4절).
    if ((Wait-WorkerJobAlone $script:WorkerWaitSec $script:WorkerKillSec) -ne 'alone') { return (Set-MarkerAttention $Marker (T 'WkWorkerHelpersLeft')) }
    # 표지 없던 프로젝트 기록은 그 폴더에 resolved.json(기록 해시)을 남겨 목록에서 뺀다.
    if ($Marker.recordKind -eq 'project' -and -not (Test-ProjectRecordResolved ([string]$Marker.recordRef))) { Save-ProjectJson (Join-Path $Marker.recordRef 'resolved.json') ([ordered]@{version=1;operationId=$Marker.operationId;outcome=$Outcome;sha256=(Get-ProjectRecordSha ([string]$Marker.recordRef));at=(Get-ProjectStamp)}) }
    $dir=Join-Path (Get-JournalDir) 'done'; $null=[IO.Directory]::CreateDirectory($dir)
    $done=[ordered]@{version=1;operationId=$Marker.operationId;agent=$Marker.agent;home=$Marker.home;recordRef=$Marker.recordRef;outcome=$Outcome;vendorState=$VendorState;project=$Project;at=(Get-ProjectStamp)}
    if ($Marker.absenceKind -ceq 'retained') {
        $done.absenceKind='retained'; $done.retainedKinds=@(Get-CodexRetainedKinds $Marker)
        Save-Marker $Marker
    }
    Save-ProjectJson (Join-Path $dir "$($Marker.operationId).json") $done
    if (-not (Test-DoneRecord $Marker)) { return (Set-MarkerAttention $Marker (T 'WkJournalDoneMismatch')) }
    [IO.File]::Delete((Join-Path (Get-JournalDir) "$($Marker.operationId).json"))
    return $Outcome
}
function Test-MarkerEngineClosed([Collections.IDictionary]$Marker) {
    # 되돌릴 프로젝트 계획이 있으면 그 기록의 엔진 guard를 부른다. 벤더를 모르는 기록(예전 판 프로젝트 기록)은 모든 벤더를 본다.
    # 모두 ok면 빈 값, 아니면 이유를 돌려준다.
    try { if (-not (Read-ProjectPlan ([string]$Marker.projectRecovery))) { return '' } } catch { return '' }
    $agents=if ($Marker.agent) { @([string]$Marker.agent) } else { @((Get-Content -LiteralPath $script:ImplsFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties.Name) }
    foreach ($agent in $agents) {
        try { $null=Invoke-Vendor ([pscustomobject]@{agent=$agent;home=[string]$Marker.home}) 'guard' @{} } catch { return (T 'WkRollbackEngineOpen' $agent $_.Exception.Message) }
    }
    return ''
}
function Resolve-Marker([Collections.IDictionary]$Marker,[string]$Mode,[object[]]$Confirmed,[string]$VendorState,[bool]$OkEqual) {
    # 상태 결정표(S3 명세 2.5절). 앞 writer 확인(Enter-Marker)을 통과한 뒤에만 부른다.
    # $Mode: restore(복원 작업 안의 자동 처리) | journal(목록의 자동 정리) | rollback(사용자가 누름).
    # 돌려주는 값: completed | rolled_back | resolved | attention | waiting(사용자 결정을 기다림)
    $phase=if ($Marker.phase -eq 'rollback') {[string]$Marker.phaseBefore} else {[string]$Marker.phase}
    if ($VendorState -eq 'complete' -or $OkEqual) {
        # 대화가 끝났으면 프로젝트는 되돌리지 않는다. 증거가 모자라면 확인이 필요하다.
        if ($phase -eq 'conversation' -and (Test-ProjectSuccess $Marker)) { return (Close-Marker $Marker 'completed' $(if ($OkEqual) {'equal'} else {'complete'}) @{success=$true}) }
        return (Set-MarkerAttention $Marker (T 'WkJournalCompleteMismatch'))
    }
    if ($VendorState -in @('unreadable','failed')) { return (Set-MarkerAttention $Marker (T 'WkJournalVendorUnreadable' $VendorState)) }
    $auto=$VendorState -in @('absent','rolled_back','none') -and $Mode -in @('restore','rollback')
    $user=$VendorState -in @('pending','resolved') -and $Mode -eq 'rollback'
    if (-not ($auto -or $user)) { return 'waiting' }
    if ($VendorState -ceq 'pending' -and $Marker.agent -ceq 'codex-desktop') {
        try { $cap=Invoke-Vendor (Get-MarkerJob $Marker) 'recover' @{mode='status';operationId=(Get-MarkerRef $Marker)} }
        catch { return (Set-MarkerAttention $Marker (T 'WkRecoveryActionUnavailable')) }
        if ($cap.canRollback -ne $true) { return (Set-MarkerAttention $Marker (T 'WkRecoveryActionUnavailable')) }
    }
    # 프로젝트 파일을 처음 되돌리기 전에 엔진이 모두 닫혔는지 본다(R38-02). 닫혀 있지 않거나 확인하지 못하면 아무것도 바꾸지 않는다.
    $guard=Test-MarkerEngineClosed $Marker
    if ($guard) { return (Set-MarkerAttention $Marker $guard) }
    if ($Marker.phase -ne 'rollback') { $Marker.phaseBefore=$Marker.phase; $Marker.phase='rollback'; Save-Marker $Marker }
    try { $project=Undo-MarkerProject $Marker $Confirmed } catch { return (Set-MarkerAttention $Marker $_.Exception.Message) }
    if (-not $project.complete) { return (Set-MarkerAttention $Marker (T 'WkRollbackIncomplete')) }
    if ($VendorState -eq 'pending') {
        # 프로젝트를 먼저 되돌린 뒤 대화를 되돌린다. 벤더가 멈추면 기록은 pending으로 남고 확인이 필요하다.
        try {
            $report=Invoke-Vendor (Get-MarkerJob $Marker) 'recover' @{mode='rollback';recordId=(Get-MarkerRef $Marker);confirmedUnknown=@($Confirmed)}
            Set-MarkerVendorAbsence $Marker $report 'rolled_back'
        }
        catch { return (Set-MarkerAttention $Marker $_.Exception.Message) }
        $VendorState='rolled_back'
    }
    $outcome=if ($VendorState -eq 'resolved') {'resolved'} else {'rolled_back'}
    return (Close-Marker $Marker $outcome $VendorState @{complete=$true})
}
function Get-ProjectRecordSha([string]$Folder) {
    # 프로젝트 기록을 닫을 때 사용자가 본 내용: 새 판은 restore-plan.json, 예전 판은 restore-log.json의 SHA-256.
    foreach ($name in 'restore-plan.json','restore-log.json') { $file=Join-Path $Folder $name; if ([IO.File]::Exists($file)) { return (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash } }
    return ''
}
function Test-ProjectRecordResolved([string]$Folder) {
    # resolved.json이 있고, 적힌 SHA-256이 지금 기록과 같을 때만 해결됨이다.
    $file=Join-Path $Folder 'resolved.json'
    if (-not [IO.File]::Exists($file)) { return $false }
    try { return ([string](Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json).sha256 -ceq (Get-ProjectRecordSha $Folder)) } catch { return $false }
}
function Get-ProjectRecordRows([hashtable]$Referenced) {
    # 표지 없는 프로젝트 기록(S3 명세 4.3절). 새 판은 종료 기록이 없는 restore-plan.json, 예전 판은 restore-log.json만 있는 폴더다.
    $root=Get-RecoveryRoot
    if (-not [IO.Directory]::Exists($root)) { return }
    foreach ($folder in [IO.Directory]::GetDirectories($root)) {
        $name=[IO.Path]::GetFileName($folder)
        if ($Referenced.ContainsKey($name) -or $Referenced.ContainsKey($folder.ToLowerInvariant()) -or (Test-ProjectRecordResolved $folder)) { continue }
        $row=[ordered]@{kind='project';operationId=$null;recordRef=$folder;agent='';nativeId='';state='';error='';canRollback=$false;canResolve=[bool](Get-ProjectRecordSha $folder);canFinalizeLocal=$false;blocksImport=$true;reasonCode='';sha256=(Get-ProjectRecordSha $folder);files=@();path=$folder}
        if ([IO.File]::Exists((Join-Path $folder 'restore-plan.json'))) {
            if ($name -cmatch '^[0-9a-f]{32}$' -and [IO.File]::Exists((Join-Path (Get-JournalDir) "done\$name.json"))) { continue }
            try { $row.files=@(Get-ProjectUndoView @((Read-ProjectPlan $folder).files)); $row.state='pending'; $row.canRollback=$true } catch { $row.state='unreadable' }
        } elseif ([IO.File]::Exists((Join-Path $folder 'restore-log.json'))) {
            # 예전 판(대화 먼저, 프로젝트 나중): 모든 폴더가 실패 없이 끝났으면 성공이라 넣지 않는다. 실패·읽을 수 없음은 닫기만 된다.
            try {
                $log=Get-Content -LiteralPath (Join-Path $folder 'restore-log.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($log.folders -isnot [array] -and $null -ne $log.folders) { throw 'format' }
                if (-not @($log.folders | Where-Object { $_.state -notin @('restored','skipped') -or @($_.failed | Where-Object { $_ }).Count }).Count) { continue }
                $row.state='failed'; $row.agent=[string]$log.agent; $row.nativeId=[string]$log.sessionId
            } catch { $row.state='unreadable' }
        } else { continue }
        [pscustomobject]$row
    }
}
function Get-JournalRows([object]$Job,[switch]$Auto) {
    # 공통 표지, 두 벤더의 recover list, 표지 없는 프로젝트 기록을 합친다(S3 명세 4.3절). $Auto면 결정표의 자동 정리만 한다.
    $rows=[Collections.Generic.List[object]]::new(); $failed=[Collections.Generic.List[string]]::new(); $byRef=@{}; $referenced=@{}
    foreach ($entry in @(Read-Markers)) {
        if (-not $entry.marker) { $rows.Add([pscustomobject]@{kind='marker';operationId=$entry.name;recordRef=$null;agent='';nativeId='';state='unreadable';error=(T 'WkJournalMarkerUnreadable');canRollback=$false;canResolve=$false;canFinalizeLocal=$false;blocksImport=$true;reasonCode='unreadable_marker';sha256='';files=@();path=$entry.path}); continue }
        $marker=$entry.marker
        if ($marker.projectRecovery) { $referenced[[IO.Path]::GetFileName([string]$marker.projectRecovery)]=$true; $referenced[([string]$marker.projectRecovery).ToLowerInvariant()]=$true }
        if ($marker.recordRef) { $referenced[([string]$marker.recordRef).ToLowerInvariant()]=$true }
        $writers=Test-WorkerWritersGone $marker
        if ($Auto -and $writers -eq 'gone' -and (Test-DoneRecord $marker)) { [IO.File]::Delete($entry.path); continue }
        $state=if ($writers -ne 'gone') {'busy'} else {Get-VendorState $marker}
        if ($Auto -and $state -eq 'complete') {
            try { Enter-Marker $marker; if ((Resolve-Marker $marker 'journal' @() $state $false) -eq 'completed') { continue } } catch { }
        }
        $files=@(); $canRollback=$state -in @('absent','rolled_back','pending','resolved','none') -and ($marker.recordKind -ne 'project' -or [IO.File]::Exists((Join-Path $marker.recordRef 'restore-plan.json')))
        try { $plan=Read-ProjectPlan ([string]$marker.projectRecovery); if ($plan) { $files=@(Get-ProjectUndoView @($plan.files)) } } catch { $canRollback=$false }
        $row=[pscustomobject]@{kind='marker';operationId=$marker.operationId;recordRef=$marker.recordRef;agent=$marker.agent;nativeId=$marker.nativeId;state=$state;error=[string]$marker.error;canRollback=$canRollback;canResolve=($state -cnotin @('busy','failed'));canFinalizeLocal=$false;blocksImport=$true;reasonCode='';sha256='';files=$files;path=[string]$marker.projectRecovery;targets=@($marker.targets);phase=$marker.phase}
        $rows.Add($row); $byRef["$($marker.agent)/$(Get-MarkerRef $marker)"]=$row
    }
    $map=Get-Content -LiteralPath $script:ImplsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($agent in @($map.PSObject.Properties.Name)) {
        try { $records=@((Invoke-Vendor ([pscustomobject]@{agent=$agent;home=[string]$Job.home}) 'recover' @{mode='list'}).records) }
        catch { $failed.Add($agent); continue }
        foreach ($record in $records) {
            $row=$byRef["$agent/$($record.recordId)"]
            # 표지가 있는 기록은 표지 행에 벤더 파일 목록과 해시를 붙인다. 없는 기록은 따로 보인다.
            if ($row) {
                $row.sha256=[string]$record.sha256; $row.files=@($row.files)+@($record.files | Where-Object { $_ })
                if ($null -ne $record.canResolve) {
                    $row.canResolve=$record.canResolve -and $row.state -cne 'busy'; $row.canFinalizeLocal=$record.canFinalizeLocal -and $row.state -cne 'busy'
                    $row.canRollback=$row.canRollback -and $record.canRollback; $row.blocksImport=$record.blocksImport; $row.reasonCode=[string]$record.reasonCode
                    if ($row.state -cne 'busy') { $row.state=[string]$record.state }
                    if (-not $row.path) { $row.path=[string]$record.path }
                }
                continue
            }
            $rows.Add([pscustomobject]@{kind='vendor';operationId=$record.operationId;recordRef=$record.recordId;agent=$agent;nativeId=$record.nativeId;state=[string]$record.state;error='';canRollback=[bool]$record.canRollback;canResolve=$(if ($null -ne $record.canResolve) {[bool]$record.canResolve} else {[bool]$record.sha256});canFinalizeLocal=[bool]$record.canFinalizeLocal;blocksImport=$(if ($null -ne $record.blocksImport) {[bool]$record.blocksImport} else {$true});reasonCode=[string]$record.reasonCode;sha256=[string]$record.sha256;files=@($record.files | Where-Object { $_ });path=[string]$record.path})
        }
    }
    foreach ($row in @(Get-ProjectRecordRows $referenced)) { $rows.Add($row) }
    return [pscustomobject]@{rows=$rows.ToArray();failed=$failed.ToArray()}
}
function Invoke-JournalFinalize([object]$Job) {
    # Local vendor cleanup only. Do not create a marker or undo project files here.
    $agent=[string]$Job.agent; $home=[string]$Job.home; $recordId=[string]$Job.recordId
    if ($Job.operationId) {
        $null=Assert-OperationId $Job.operationId
        $entry=@(Read-Markers | Where-Object { $_.name -ceq [string]$Job.operationId })
        if ($entry.Count -ne 1 -or -not $entry[0].marker) { throw (T 'WkJournalMissing' $Job.operationId) }
        $marker=$entry[0].marker
        if ($marker.recordKind -ceq 'project' -or (Test-WorkerWritersGone $marker) -cne 'gone') { throw (T 'WkRecoveryActionUnavailable') }
        $agent=[string]$marker.agent; $home=[string]$marker.home; $recordId=Get-MarkerRef $marker
    }
    if ($agent -cne 'codex-desktop') { throw (T 'WkRecoveryActionUnavailable') }
    $null=Assert-OperationId $recordId
    $report=Invoke-Vendor ([pscustomobject]@{agent=$agent;home=$home}) 'recover' @{mode='finalize';recordId=$recordId}
    if ($report.effect -cne 'finalized' -or $report.terminalStatus -cnotin @('complete','rolled_back')) { throw (T 'WkRecoveryActionUnavailable') }
    return @{outcome='finalized';terminalStatus=$report.terminalStatus;message=(T 'WkRecoveryFinalized')}
}
function Assert-JournalClear([object]$Job) {
    # 미해결 항목이 있거나 조회가 실패하면 복원·백업·열기를 모두 막는다(S3 명세 4.3절). 목록·미리보기와 되돌리기·닫기는 막지 않는다.
    # ponytail: 무관한 대화까지 막는 전체 차단. 겹침을 증명하는 검사는 필요해지면 더한다.
    $journal=Get-JournalRows $Job -Auto
    if ($journal.rows.Count -or $journal.failed.Count) { $exception=[InvalidOperationException]::new((T 'WkJournalOpen' ($journal.rows.Count+$journal.failed.Count))); $exception.Data['journalOpen']=$true; throw $exception }
}
function Get-TargetMarker([object]$Job) {
    # Rollback·CloseJournal의 대상: 공통 표지(operationId), 표지 없는 벤더 기록(agent+recordId), 표지 없는 프로젝트 기록(projectRecord).
    # 표지가 없으면 시작하기 전에 원래 기록을 가리키는 최소 표지를 만든다(S3 명세 2.2절).
    if ($Job.operationId) {
        $null=Assert-OperationId $Job.operationId
        $entry=@(Read-Markers | Where-Object { $_.name -ceq [string]$Job.operationId })
        if (-not $entry.Count -or -not $entry[0].marker) { throw (T 'WkJournalMissing' $Job.operationId) }
        return $entry[0].marker
    }
    if ($Job.projectRecord) {
        $folder=[IO.Path]::GetFullPath([string]$Job.projectRecord)
        if ([IO.Path]::GetDirectoryName($folder) -ine [IO.Path]::GetFullPath((Get-RecoveryRoot)) -or -not [IO.Directory]::Exists($folder) -or ([IO.File]::GetAttributes($folder) -band [IO.FileAttributes]::ReparsePoint)) { throw (T 'WkJournalMissing' $Job.projectRecord) }
        $existing=@(Read-Markers | Where-Object { $_.marker -and ([string]$_.marker.recordRef) -ieq $folder })
        if ($existing.Count) { return $existing[0].marker }
        return (New-Marker ([pscustomobject]@{agent='';home=''}) ([guid]::NewGuid().ToString('N')) @() $folder 'rollback' $folder 'project')
    }
    $null=Assert-OperationId $Job.recordId
    $existing=@(Read-Markers | Where-Object { $_.marker -and [string]$_.marker.agent -ceq [string]$Job.agent -and ((Get-MarkerRef $_.marker) -ceq [string]$Job.recordId) })
    if ($existing.Count) { return $existing[0].marker }
    return (New-Marker ([pscustomobject]@{agent=[string]$Job.agent;home=[string]$Job.home;nativeId=[string]$Job.nativeId}) ([guid]::NewGuid().ToString('N')) @() $null 'rollback' ([string]$Job.recordId) 'vendor')
}
function Invoke-JournalRollback([object]$Job) {
    # 사용자가 되돌리기를 누름(S3 명세 4.3절). 결정표의 되돌리기 행만 한다.
    $marker=Get-TargetMarker $Job
    # 예전 판 프로젝트 기록에는 계획이 없어 되돌릴 수 없다. 닫기만 된다.
    if ($marker.recordKind -eq 'project' -and -not [IO.File]::Exists((Join-Path $marker.recordRef 'restore-plan.json'))) { throw (T 'WkRecordNotPending' 'failed') }
    Enter-Marker $marker
    $outcome=Resolve-Marker $marker 'rollback' @($Job.confirmedUnknown | Where-Object { $_ }) (Get-VendorState $marker) $false
    if ($outcome -ceq 'waiting') { $outcome=Set-MarkerAttention $marker (T 'WkJournalVendorUnreadable' 'complete') }
    $message=switch ($outcome) { rolled_back {if ($marker.absenceKind -ceq 'retained') {T 'WkJournalRolledBackRetained'} else {T 'WkJournalRolledBack'}} resolved {T 'WkJournalRolledBackProject'} completed {T 'WkJournalCompleted'} default {T 'WkJournalAttention' $marker.error} }
    $result=@{outcome=$outcome;operationId=$marker.operationId;message=$message}
    if ($outcome -ceq 'rolled_back' -and $marker.absenceKind -ceq 'retained') { $result.absenceKind='retained'; $result.retainedKinds=@($marker.retainedKinds) }
    return $result
}
function Invoke-JournalClose([object]$Job) {
    # 사용자가 "해결했음"으로 닫음(S3 명세 3.5·4.3절). 벤더 기록이 남았으면 벤더 resolve를 먼저 부른다. 조회가 실패하면 닫지 않는다.
    $marker=Get-TargetMarker $Job
    Enter-Marker $marker
    $state=Get-VendorState $marker
    if ($state -eq 'failed') { throw (T 'WkJournalVendorUnreadable' $state) }
    if ($marker.recordKind -eq 'project') {
        $folder=[string]$marker.recordRef; $sha=Get-ProjectRecordSha $folder
        if (-not $sha -or $sha -cne [string]$Job.sha256) { throw (T 'WkRecordChanged') }
    } elseif ($state -in @('pending','unreadable')) {
        if ($marker.agent -ceq 'codex-desktop') {
            $cap=Invoke-Vendor (Get-MarkerJob $marker) 'recover' @{mode='status';operationId=(Get-MarkerRef $marker)}
            if ($cap.canResolve -ne $true) { throw (T 'WkRecoveryActionUnavailable') }
        }
        $null=Invoke-Vendor (Get-MarkerJob $marker) 'recover' @{mode='resolve';recordId=(Get-MarkerRef $marker);sha256=[string]$Job.sha256}
        $state='resolved'
    }
    # 종료 기록에는 아직 원래대로가 아닌 프로젝트 파일 목록을 남긴다.
    $remaining=@(); try { $plan=Read-ProjectPlan ([string]$marker.projectRecovery); if ($plan) { $remaining=@(Get-ProjectUndoView @($plan.files) | Where-Object { $_.class -ne 'original' } | ForEach-Object target) } } catch { $remaining=@('?') }
    $outcome=Close-Marker $marker 'resolved' $state @{remaining=$remaining}
    return @{outcome=$outcome;operationId=$marker.operationId;message=$(if ($outcome -ceq 'resolved') {T 'WkJournalClosed'} else {T 'WkJournalAttention' $marker.error})}
}
function Assert-ProjectTargetsSeparate([string[]]$Targets,[string]$DesktopHome) {
    # 한 복원 안의 폴더끼리, 그리고 대상 홈·에이전트 설정·CtxHopGUI 폴더와 겹치면 쓰기 전에 거부한다(S3 명세 4.1절 b).
    $reserved=@(@((Get-ProjectIgnoredRoots).settings)+@(ConvertTo-ProjectPath (Join-Path $env:LOCALAPPDATA 'CtxHopGUI')))
    if ($DesktopHome) { $reserved+=ConvertTo-ProjectPath $DesktopHome }
    $list=@($Targets | ForEach-Object { ConvertTo-ProjectPath $_ })
    for ($i=0; $i -lt $list.Count; $i++) {
        if (-not $list[$i]) { throw (T 'PfTargetUnsafe' $Targets[$i]) }
        for ($j=$i+1; $j -lt $list.Count; $j++) { if ((Test-ProjectInside $list[$i] $list[$j]) -or (Test-ProjectInside $list[$j] $list[$i])) { throw (T 'WkProjectTargetsOverlap' $list[$i] $list[$j]) } }
        foreach ($root in @($reserved | Where-Object { $_ })) { if ((Test-ProjectInside $list[$i] $root) -or (Test-ProjectInside $root $list[$i])) { throw (T 'WkProjectTargetsOverlap' $list[$i] $root) } }
    }
}
function Get-ProjectRestoreFolders([object]$Job,[object]$Record,[string]$StartTarget) {
    # 미리보기에서 받은 폴더 중 이번에 쓸 폴더. 시작 폴더는 이번 복원 폴더에, 추가 폴더는 원래 경로나 GUI가 고른 폴더에 쓴다. 빈 값은 건너뛴다.
    foreach ($folder in @($Record.folders)) {
        if ($folder.state -notin @('ready','needsFolder')) { continue }
        # 미리보기 뒤에 고르는 폴더는 이 PC에 원래 경로가 없던 추가 폴더(needsFolder)만 받는다. 절대 경로가 아니면 건너뛴다.
        $override=if ($Job.projectTargets -and $folder.state -eq 'needsFolder') { $Job.projectTargets.PSObject.Properties[[string]$folder.index] } else { $null }
        $target=if ($folder.role -eq 'start') {$StartTarget} elseif ($override) {[string](ConvertTo-ProjectPath ([string]$override.Value))} else {[string]$folder.target}
        if ($target) { [pscustomobject]@{index=[int]$folder.index;role=[string]$folder.role;sourcePath=[string]$folder.sourcePath;target=$target;zip=[string]$folder.zip;sha256=[string]$folder.sha256} }
    }
}
function Invoke-ProjectFolders([Collections.IDictionary]$Marker,[object[]]$Folders) {
    # 모든 폴더의 계획을 세우고 저장한 뒤에 쓴다(S3 명세 3.1·3.2절). 파일 하나라도 실패하면 남은 파일은 쓰지 않는다.
    $recovery=[string]$Marker.projectRecovery; $files=[Collections.Generic.List[object]]::new(); $plans=@()
    foreach ($folder in $Folders) {
        if ((Get-FileHash -LiteralPath $folder.zip -Algorithm SHA256).Hash -ne $folder.sha256) { throw (T 'WkArchiveChanged') }
        $plan=New-ProjectRestorePlan $folder.zip $folder.target (Join-Path $recovery ([string]$folder.index)) $files.Count
        foreach ($file in $plan.files) { $file | Add-Member -NotePropertyName folder -NotePropertyValue $folder.index; $files.Add($file) }
        $plans+=,[pscustomobject]@{folder=$folder;files=@($plan.files)}
    }
    Save-ProjectJson (Join-Path $recovery 'restore-plan.json') ([ordered]@{version=1;operationId=$Marker.operationId;folders=@($Folders | Select-Object index,role,sourcePath,target);files=$files.ToArray()})
    $states=[Collections.Generic.List[object]]::new(); $summary=@(); $failure=$null
    foreach ($item in $plans) {
        $entry=[ordered]@{index=$item.folder.index;role=$item.folder.role;sourcePath=$item.folder.sourcePath;target=$item.folder.target;state='skipped';written=0;backedUp=0;same=0;failed=@();error=''}
        if (-not $failure) {
            $done=Invoke-ProjectRestorePlan $item.folder.zip $item.files $recovery
            foreach ($file in $done.files) { $states.Add([ordered]@{index=$file.index;state=$file.state}) }
            $entry.state=if ($done.failed.Count) {'failed'} else {'restored'}; $entry.written=$done.written; $entry.backedUp=$done.backedUp; $entry.same=$done.same; $entry.failed=@($done.failed)
            if ($done.failed.Count) { $failure=$done.failed[0] }
        } else { foreach ($file in $item.files) { $states.Add([ordered]@{index=$file.index;state='skipped'}) } }
        $summary+=,$entry
    }
    Save-ProjectJson (Join-Path $recovery 'restore-log.json') ([ordered]@{version=1;operationId=$Marker.operationId;agent=$Marker.agent;sessionId=$Marker.nativeId;conversation=$Marker.remoteId;restoredAt=(Get-ProjectStamp);files=$states.ToArray();folders=$summary})
    $written=0; $backedUp=0; foreach ($entry in $summary) { $written+=$entry.written; $backedUp+=$entry.backedUp }
    return @{folders=$summary;recovery=$recovery;failure=$failure;message=(T 'WkProjectRestored' @($summary | Where-Object { $_.state -eq 'restored' }).Count $written $backedUp @($summary | ForEach-Object { @($_.failed) } | Where-Object { $_ }).Count $recovery)}
}
function Complete-RestoreMarker([Collections.IDictionary]$Marker,[bool]$VendorSkipped,[bool]$OkEqual) {
    # 복원 작업 안의 마무리(S3 명세 2.2·2.5절, R38-01). 벤더 구현이 끝나도 그 자식(백엔드·엔진)은 아직 쓰고 있을 수 있다.
    # 그래서 이 Worker의 Job에 자신만 남은 것을 먼저 확인하고, 그다음에 벤더 상태를 새로 읽어 결정표로 간다.
    # 자손을 끝내야 했거나 끝내지 못했으면 결정표에 들어가지 않고 attention으로 남긴다(프로젝트를 되돌리지 않음).
    if (-not $VendorSkipped) {
        $alone=Wait-WorkerJobAlone $script:WorkerWaitSec $script:WorkerKillSec
        if ($alone -ne 'alone') { return (Set-MarkerAttention $Marker (T 'WkWorkerHelpersLeft')) }
    }
    # 벤더를 부르지 않았으면 대화에는 쓰지 않았다. 불렀으면 결과와 상관없이 벤더 기록을 새로 본다.
    $state=if ($VendorSkipped) {'absent'} elseif ($OkEqual) {'complete'} else {Get-VendorState $Marker}
    try { return (Resolve-Marker $Marker 'restore' @() $state $OkEqual) } catch { return (Set-MarkerAttention $Marker $_.Exception.Message) }
}
function Invoke-RestoreOperation([object]$Job,[hashtable]$Ids,[string]$Choice) {
    # 복원(S3 명세 4.1절): 차단 검사 → 짝·대상 확정 → 엔진 사전 검사 → 표지 → 프로젝트 파일 → 대화 → 결정표.
    if ($Choice -cne 'incoming') { throw (T 'WkChoiceRequired') }
    Assert-JournalClear $Job
    $record=if ($Job.projectReceipt) { Assert-ProjectPairing $Job } else { $null }
    $operationId=[guid]::NewGuid().ToString('N')
    $folders=@(if ($record -and $Job.projectRestore) { Get-ProjectRestoreFolders $Job $record (Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path) })
    # 미리보기가 이 PC 대화가 더 새롭다고 했으면 대화가 쓰지 않을 복원이므로 프로젝트 파일도 쓰지 않는다(S3 명세 1절).
    if ($record -and [string]$record.previewState -ceq 'local_newer') { $folders=@() }
    Assert-ProjectTargetsSeparate @($folders | ForEach-Object target) $(if ($Job.agent -eq 'codex-desktop') {[string]$Job.home} else {''})
    # 엔진 사전 검사(S3 명세 4.1절 b2)는 프로젝트에 처음 쓰기 전에 한다. 대화만 쓰는 복원은 벤더 restore가 쓰기 직전에 검사한다.
    if ($folders.Count) { $null=Invoke-Vendor $Job 'guard' @{} }
    $recovery=if ($folders.Count) { New-PrivateFolder (Join-Path (Get-RecoveryRoot) $operationId) } else { $null }
    $marker=New-Marker $Job $operationId @($folders | ForEach-Object target) $recovery 'project' $null ''
    $project=$null; $failure=''
    if ($folders.Count) {
        try { $project=Invoke-ProjectFolders $marker $folders; if ($project.failure) { $failure="$($project.failure.path): $($project.failure.reason)" } } catch { $failure=$_.Exception.Message }
    }
    $restored=$null; $vendorError=$null
    if (-not $failure) {
        $marker.phase='conversation'; Save-Marker $marker
        try { $restored=Invoke-Vendor $Job 'restore' ($Ids+@{receipt=[string]$Job.receipt;token=[string]$Job.token;choice=$Choice;operationId=$operationId}) } catch { $vendorError=$_ }
    }
    $outcome=Complete-RestoreMarker $marker ([bool]$failure) ($restored -and $restored.effect -ceq 'equal')
    if ($Job.projectReceipt) { $cleanup=Remove-DesktopStage ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Job.projectReceipt))) } else { $cleanup='' }
    # 대화를 부르지 않았으면 벤더 미리보기의 평문 사본도 쓸 일이 없으므로 지운다. 불렀다가 실패하면 벤더가 증거로 남긴다.
    if ($failure -and [string]$Job.receipt) { $cleanup+=Remove-DesktopStage ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$Job.receipt))) }
    if ($outcome -ceq 'completed') {
        $result=@{message=[string]$restored.message+$cleanup;effect=$restored.effect;nativeId=$restored.nativeId;restored=$restored.view;project=$project;operationId=$operationId}
        if ($project) { $result.message+=$project.message }
        return $result
    }
    if ($outcome -ceq 'rolled_back' -and $restored -and -not $vendorError) {
        # 이 PC 대화가 더 새로워 대화를 쓰지 않은 복원: 쓴 프로젝트 파일은 되돌렸다.
        $message=[string]$restored.message+$cleanup; if ($project) { $message+=T 'WkRestoreFilesRolledBack' }
        return @{message=$message;effect=$restored.effect;nativeId=$restored.nativeId;restored=$restored.view;project=$null;operationId=$operationId}
    }
    $reason=if ($failure) { if ($outcome -ceq 'rolled_back') {T 'WkRestoreProjectRolledBack' $failure} else {T 'WkRestoreProjectFailed' $failure} }
        elseif ($outcome -ceq 'rolled_back') { T 'WkRestoreConversationRolledBack' $vendorError.Exception.Message }
        else { T 'WkRestoreNeedsAttention' $(if ($vendorError) {$vendorError.Exception.Message} else {[string]$marker.error}) }
    $exception=[InvalidOperationException]::new($reason+$cleanup)
    if ($vendorError) { foreach ($key in $vendorError.Exception.Data.Keys) { $exception.Data[$key]=$vendorError.Exception.Data[$key] } }
    $exception.Data['journal']=[pscustomobject]@{operationId=$operationId;outcome=$outcome}
    throw $exception
}
function Invoke-ConversationJob([object]$Job) {
    # 대화 목록·백업·미리보기·복원·열기는 벤더 구현이 하고, 프로젝트 파일은 Worker가 벤더와 상관없이 덧붙인다.
    $ids=@{nativeId=[string]$Job.nativeId;remoteId=[string]$Job.remoteId}
    switch ($Job.action) {
        List {
            $listed=Invoke-Vendor $Job 'list' @{search=[string]$Job.search}
            # 행의 벤더는 구현이 아니라 부른 쪽이 정한다(다른 벤더의 같은 UUID를 섞지 않는다).
            $rows=@($listed.sessions | ForEach-Object { $_ | Add-Member -NotePropertyName agent -NotePropertyValue ([string]$Job.agent) -Force -PassThru })
            return @{sessions=$rows;excluded=[int]$listed.excluded;message=[string]$listed.message}
        }
        Backup {
            Assert-JournalClear $Job
            # 프로젝트 파일을 함께 올리면 먼저 작업 폴더를 받아 큰 폴더를 묻는다. 그사이 작업 폴더가 바뀌면 backup이 changed로 멈춘다.
            $plan=$null; $planError=''; $stamp=''
            if ($Job.projectBackup) {
                try {
                    $described=Invoke-Vendor $Job 'describe' @{nativeId=$ids.nativeId}
                    $plan=Get-ProjectPlan $Job $described.sourceCwd @($described.cwds) @($described.edits); $stamp=$described.sourceStamp
                } catch {
                    # 진행 중인 대화는 대화 백업도 건너뛴다. 다른 실패는 대화 백업을 막지 않고 이유만 덧붙인다.
                    if ($_.Exception.Data['vendorResult'].status -ceq 'busy') { throw }
                    $planError=$_.Exception.Message
                }
                if ($plan.ask.Count) { return (New-ProjectQuestion $plan) }
            }
            $backup=Invoke-Vendor $Job 'backup' ($ids+@{sourceStamp=$stamp})
            $result=@{message=[string]$backup.message;remoteId=$backup.remoteId;project=$null}
            if ($planError) { $result.message+=T 'WkProjectFailed' $planError }
            if ($plan) {
                # 대화 백업이 끝난 뒤 올린다. 실패해도 대화 백업(remoteId)은 그대로이고 이유만 덧붙인다.
                $stage=New-DesktopStage
                try { $result.project=Save-ProjectBackup $plan $Job.agent $ids.nativeId $backup.remoteId $stage; $result.message+=$result.project.message }
                catch { $result.message+=T 'WkProjectFailed' $_.Exception.Message }
                $result.message+=Remove-DesktopStage $stage
            }
            return $result
        }
        Preview {
            $preview=Invoke-Vendor $Job 'preview' $ids
            $result=@{message=[string]$preview.message;preview=$preview.view;receipt=$preview.receipt;token=$preview.token;project=@{state='off'}}
            if ($Job.agent -ceq 'codex-desktop') {
                foreach ($config in @($preview.view.projectConfig)) {
                    if ($config.path -is [string] -and ($config.applied -eq $true -or $config.warning)) { $result.message+=T 'WkCodexProjectConfig' $config.path }
                }
            }
            # 복원을 고를 수 있는 대화만 프로젝트 파일을 받아 비교한다. 프로젝트 파일을 읽지 못해도 대화 미리보기는 그대로 보인다.
            if ($Job.projectRestore -and @($preview.choices) -ccontains 'incoming') {
                $stage=New-DesktopStage
                # 미리보기 state를 함께 적는다. 복원할 때 local_newer면 프로젝트 파일을 쓰지 않는다(S3 명세 1절).
                $pair=@{home=[string]$Job.home;receipt=[string]$preview.receipt;token=[string]$preview.token;state=[string]$preview.state}
                $result.project=Get-ProjectPreviewSafe $Job.agent $ids.nativeId $ids.remoteId (Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path) $stage $pair
                if ($result.project.state -ne 'found') { $null=Remove-DesktopStage $stage }
            }
            return $result
        }
        Restore {
            # GUI는 복원(incoming)만 작업으로 보낸다. 건너뛰기·유지는 작업을 만들지 않는다.
            $choice=if ($Job.choice) {[string]$Job.choice} else {'incoming'}
            return (Invoke-RestoreOperation $Job $ids $choice)
        }
        Journal { return (Get-JournalRows $Job -Auto) }
        Rollback { return (Invoke-JournalRollback $Job) }
        CloseJournal { return (Invoke-JournalClose $Job) }
        FinalizeJournal { return (Invoke-JournalFinalize $Job) }
        Open { Assert-JournalClear $Job; return @{message=[string](Invoke-Vendor $Job 'open' $ids).message} }
    }
}
function Enable-WorkerJob {
    # 이 Worker를 이름 있는 KILL_ON_JOB_CLOSE Job 객체에 넣는다(S3 명세 2.2절). 벤더 구현·백엔드·엔진 같은 자손은 이 Job을 물려받아,
    # Worker가 어떻게 끝나든 함께 끝난다. 다음 Worker는 표지에 적힌 이름으로 Job을 열어 앞 writer가 끝났는지 확인한다.
    # 핸들은 상속되지 않고(보안 속성 null) 일부러 닫지 않는다(프로세스가 끝날 때 닫힘). breakaway는 켜지 않는다.
    if (-not ('CtxHopWorkerJob' -as [type])) {
        Add-Type -TypeDefinition @"
using System; using System.ComponentModel; using System.Runtime.InteropServices;
public static class CtxHopWorkerJob {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr OpenJobObject(uint access, bool inherit, string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [StructLayout(LayoutKind.Sequential)] struct Basic { public long PerProcessUserTimeLimit, PerJobUserTimeLimit; public uint LimitFlags; public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize; public uint ActiveProcessLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] struct Extended { public Basic BasicLimits; public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
    static IntPtr handle = IntPtr.Zero;
    public static string Name;
    public static bool Enabled { get { return handle != IntPtr.Zero; } }
    public static IntPtr Handle { get { return handle; } }
    public static void Enable(string name) {
        if (handle != IntPtr.Zero) return;
        IntPtr job = CreateJobObject(IntPtr.Zero, name);
        if (job == IntPtr.Zero) throw new Win32Exception();
        if (Marshal.GetLastWin32Error() == 183) { CloseHandle(job); throw new Win32Exception(183); } // the name already exists
        Extended info = new Extended(); info.BasicLimits.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        int length = Marshal.SizeOf(typeof(Extended)); IntPtr buffer = Marshal.AllocHGlobal(length);
        try { Marshal.StructureToPtr(info, buffer, false); if (!SetInformationJobObject(job, 9, buffer, (uint)length)) { CloseHandle(job); throw new Win32Exception(); } }
        finally { Marshal.FreeHGlobal(buffer); }
        if (!AssignProcessToJobObject(job, GetCurrentProcess())) { CloseHandle(job); throw new Win32Exception(); }
        handle = job; Name = name;
    }
    // Opens by name with query and terminate rights. Zero when it does not exist (ERROR_FILE_NOT_FOUND); other failures throw.
    public static IntPtr Open(string name) {
        IntPtr job = OpenJobObject(0x0004 | 0x0008, false, name);
        if (job != IntPtr.Zero) return job;
        int error = Marshal.GetLastWin32Error();
        if (error == 2) return IntPtr.Zero;
        throw new Win32Exception(error);
    }
    public static void Close(IntPtr job) { if (job != IntPtr.Zero) CloseHandle(job); }
    // JobObjectBasicProcessIdList. Grows the buffer and asks again until every assigned process is listed.
    public static int[] List(IntPtr job) {
        for (int size = 64; size <= 65536; size *= 4) {
            int bytes = 8 + size * IntPtr.Size; IntPtr buffer = Marshal.AllocHGlobal(bytes);
            try {
                if (!QueryInformationJobObject(job, 3, buffer, (uint)bytes, IntPtr.Zero)) { if (Marshal.GetLastWin32Error() == 234) continue; throw new Win32Exception(); }
                int assigned = Marshal.ReadInt32(buffer, 0), listed = Marshal.ReadInt32(buffer, 4);
                if (assigned > listed) continue;
                int[] ids = new int[listed];
                for (int i = 0; i < listed; i++) ids[i] = (int)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64();
                return ids;
            } finally { Marshal.FreeHGlobal(buffer); }
        }
        throw new Win32Exception(234);
    }
    // A listed PID may have been reused since, so only processes confirmed to be in this Job are ended.
    public static void KillMembers(IntPtr job, int self) {
        foreach (int id in List(job)) {
            if (id == self) continue;
            IntPtr process = OpenProcess(0x0001 | 0x1000, false, id);
            if (process == IntPtr.Zero) continue;
            try { bool member; if (IsProcessInJob(process, job, out member) && member) TerminateProcess(process, 1); } finally { CloseHandle(process); }
        }
    }
    public static void Terminate(IntPtr job) { if (!TerminateJobObject(job, 1)) throw new Win32Exception(); }
}
"@
    }
    [CtxHopWorkerJob]::Enable("Local\CtxHopGUI-worker-$([guid]::NewGuid().ToString('N'))")
}
function Assert-WorkerJob {
    # 쓰기 작업(복원·되돌리기·닫기)은 Job 객체가 켜져 있어야 한다. 목록·미리보기는 막지 않는다.
    if (-not ('CtxHopWorkerJob' -as [type]) -or -not [CtxHopWorkerJob]::Enabled) { throw (T 'WkJobObjectFailed') }
}
function Get-WorkerStarted([int]$ProcessId) {
    # PID 재사용을 가리려고 시작 시각을 함께 본다. 그 PID가 없으면 빈 값이고, 있는데 읽지 못하면 예외다(끝났다고 보지 않는다).
    try { $process=[Diagnostics.Process]::GetProcessById($ProcessId) } catch [ArgumentException] { return '' }
    try { return [string]$process.StartTime.ToFileTimeUtc() } finally { $process.Dispose() }
}
function Get-WorkerFields {
    # 표지에 적는 지금 Worker의 값(S3 명세 2.4절).
    return [ordered]@{workerJob=[CtxHopWorkerJob]::Name;workerPid=$PID;workerStarted=(Get-WorkerStarted $PID)}
}
function Wait-WorkerJobAlone([int]$WaitSec=60,[int]$KillSec=30) {
    # 정상 경로(S3 명세 2.2절): Job에 이 Worker만 남을 때까지 기다린다. 넘으면 이 Job 소속만 끝내고 목록을 다시 전부 받는다.
    # alone: 자손이 모두 스스로 끝남. killed: 남은 자손을 끝냄(attention). stuck: 끝내지 못했거나 목록을 받지 못함(attention).
    # 부르는 쪽은 alone이 아니면 종료 기록 대신 attention을 남기고, mutex는 그 뒤에 풀린다.
    if (-not ('CtxHopWorkerJob' -as [type]) -or -not [CtxHopWorkerJob]::Enabled) { return 'stuck' }
    $job=[CtxHopWorkerJob]::Handle
    try {
        $deadline=[DateTime]::UtcNow.AddSeconds($WaitSec)
        while (@([CtxHopWorkerJob]::List($job) | Where-Object { $_ -ne $PID }).Count) {
            if ([DateTime]::UtcNow -gt $deadline) {
                $deadline=[DateTime]::UtcNow.AddSeconds($KillSec)
                do {
                    [CtxHopWorkerJob]::KillMembers($job,$PID)
                    Start-Sleep -Milliseconds 200
                    if (-not @([CtxHopWorkerJob]::List($job) | Where-Object { $_ -ne $PID }).Count) { return 'killed' }
                } while ([DateTime]::UtcNow -lt $deadline)
                return 'stuck'
            }
            Start-Sleep -Milliseconds 100
        }
        return 'alone'
    } catch { return 'stuck' }
}
function Test-WorkerWritersGone([object]$Marker,[int]$KillSec=30) {
    # 다음 Worker가 표지를 볼 때(S3 명세 2.2절). gone: 앞 writer가 모두 끝남. busy: 끝났다는 증거가 없음. 아무것도 바꾸지 않는다.
    # 표지를 쓴 Worker가 자기 자신이면 gone이다(넘겨받은 뒤).
    if ([int]$Marker.workerPid -eq $PID -and [string]$Marker.workerJob -ceq [CtxHopWorkerJob]::Name) { return 'gone' }
    if ([string]$Marker.workerJob -notmatch '^Local\\CtxHopGUI-worker-[0-9a-f]{32}$') { return 'busy' }
    try { $job=[CtxHopWorkerJob]::Open([string]$Marker.workerJob) } catch { return 'busy' }
    # Job이 없으면 핸들이 모두 닫혀 소속 프로세스 종료가 시작된 것이다(KILL_ON_JOB_CLOSE).
    if ($job -eq [IntPtr]::Zero) { return 'gone' }
    try {
        $members=@([CtxHopWorkerJob]::List($job))
        # 그 Worker가 살아 있으면(같은 PID·시작 시각) Job 목록과 상관없이 busy다. mutex를 가진 스레드만 끝났을 수 있다.
        $started=Get-WorkerStarted ([int]$Marker.workerPid)
        if ($started -and $started -ceq [string]$Marker.workerStarted) { return 'busy' }
        if (-not $members.Count) { return 'gone' }
        # Worker 없이 남은 프로세스는 주인 없는 writer다. Job째 끝내고 소속이 0이 될 때까지 기다린다.
        [CtxHopWorkerJob]::Terminate($job)
        $deadline=[DateTime]::UtcNow.AddSeconds($KillSec)
        while (@([CtxHopWorkerJob]::List($job)).Count) { if ([DateTime]::UtcNow -gt $deadline) { return 'busy' }; Start-Sleep -Milliseconds 100 }
        return 'gone'
    } catch { return 'busy' } finally { [CtxHopWorkerJob]::Close($job) }
}
function Invoke-JobCore([object]$Job) {
    # 쓰기 작업(복원·되돌리기·닫기)은 Job 객체 안에서만 한다. 끝나기 전에 자손이 모두 끝나기를 기다려, mutex를 풀 때 writer가 남지 않게 한다.
    if ($Job.action -cin @('Restore','Rollback','CloseJournal','FinalizeJournal')) {
        Assert-WorkerJob
        try { return (Invoke-ConversationJob $Job) } finally { $null=Wait-WorkerJobAlone }
    }
    if ($Job.action -cin @('List','Backup','Preview','Open','Journal')) { return (Invoke-ConversationJob $Job) }
    # 설정·저장소 작업은 벤더와 무관한 ctxhop 설정 작업이라 ClaudeWorker가 그대로 한다.
    if ($Job.agent -eq 'codex-desktop') { $Job.agent='claude-code' }
    & $script:ClaudeJobCore $Job
}
if ($script:VNextLibraryOnly) { return }
try {
    $job=Get-Content -LiteralPath $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Set-Language ([string]$job.language)
    Write-Host "CtxHop vNext: $($job.action) / $($job.agent)" -ForegroundColor Cyan
    Write-Host (T 'WkConsolePasswordHint')
    try { Enable-WorkerJob } catch { Write-Host (T 'WkJobObjectFailed') }
    $data=Invoke-Job $job
    @{ok=$true;data=$data} | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
} catch {
    $result=@{ok=$false;error=$_.Exception.Message}
    if ($_.Exception.Data.Contains('backendResult')) { $result.backendResult=$_.Exception.Data['backendResult'] }
    # 벤더 계약의 실패 정보: 구현이 답한 status·reasonCode·recovery와, 응답이 없어 결과를 알 수 없는지.
    $vendor=$_.Exception.Data['vendorResult']
    if ($vendor) { $result.vendor=[ordered]@{status=[string]$vendor.status;reasonCode=[string]$vendor.reasonCode;recovery=[string]$vendor.recovery} }
    if ($_.Exception.Data.Contains('vendorOutcome')) { $result.vendorOutcome=[string]$_.Exception.Data['vendorOutcome'] }
    # GUI는 이 표시를 보고 중단된 복원 창을 연다.
    if ($_.Exception.Data['journalOpen']) { $result.journalOpen=$true }
    $result | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
    exit 1
}
