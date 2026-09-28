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
    [IO.File]::WriteAllText($receipt,(ConvertTo-Json -InputObject ([ordered]@{agent=$Agent;sessionId=$SessionId;conversation=$Conversation;home=[string]$Pair.home;target=$Target;receipt=[string]$Pair.receipt;token=[string]$Pair.token;linkId=$links[0].id;folders=$folders}) -Depth 8),[Text.UTF8Encoding]::new($false))
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
}
function Restore-ProjectFolders([object]$Job,[string]$Receipt,[string]$Agent,[string]$SessionId,[string]$Conversation,[string]$StartTarget) {
    # 미리보기에서 받은 프로젝트 파일을 복원한다. 시작 폴더는 이번 복원 폴더에, 추가 폴더는 원래 경로나 GUI가 고른 폴더에 쓴다. 빈 값은 건너뜀.
    if (-not $Job.projectRestore -or -not $Receipt) { return $null }
    try {
        $record=Read-ProjectReceipt $Receipt $Agent $SessionId $Conversation
        $recovery=$null; $results=@()
        foreach ($folder in $record.folders) {
            if ($folder.state -notin @('ready','needsFolder')) { continue }
            # 미리보기 뒤에 고르는 폴더는 이 PC에 원래 경로가 없던 추가 폴더(needsFolder)만 받는다. 절대 경로가 아니면 건너뛴다.
            $override=if ($Job.projectTargets -and $folder.state -eq 'needsFolder') { $Job.projectTargets.PSObject.Properties[[string]$folder.index] } else { $null }
            $target=if ($folder.role -eq 'start') {$StartTarget} elseif ($override) {[string](ConvertTo-ProjectPath ([string]$override.Value))} else {[string]$folder.target}
            $entry=[ordered]@{index=$folder.index;role=$folder.role;sourcePath=$folder.sourcePath;target=$target;state='skipped';written=0;backedUp=0;same=0;failed=@();error=''}
            if ($target) {
                # 한 폴더가 실패해도(받은 파일이 바뀜, 쓸 수 없는 위치) 다른 폴더는 복원하고 기록을 남긴다. 실패한 폴더에는 쓰기 전에 멈춘다.
                try {
                    if ((Get-FileHash -LiteralPath $folder.zip -Algorithm SHA256).Hash -ne $folder.sha256) { throw (T 'WkArchiveChanged') }
                    if (-not $recovery) { $recovery=New-DesktopStage 'project-recovery' }
                    $restored=Restore-ProjectSnapshot $folder.zip $target (Join-Path $recovery ([string]$folder.index))
                    $entry.state='restored'; $entry.written=$restored.written; $entry.backedUp=$restored.backedUp; $entry.same=$restored.same; $entry.failed=@($restored.failed)
                } catch { $entry.state='failed'; $entry.error=$_.Exception.Message }
            }
            $results+=,$entry
        }
        if ($recovery) { [IO.File]::WriteAllText((Join-Path $recovery 'restore-log.json'),(ConvertTo-Json -InputObject ([ordered]@{agent=$Agent;sessionId=$SessionId;conversation=$Conversation;restoredAt=(Get-ProjectStamp);folders=$results}) -Depth 6),[Text.UTF8Encoding]::new($false)) }
        $restoredCount=0; $written=0; $backedUp=0; $failed=0
        foreach ($entry in $results) { if ($entry.state -eq 'restored') { $restoredCount++ }; $written+=$entry.written; $backedUp+=$entry.backedUp; $failed+=@($entry.failed).Count }
        $message=T 'WkProjectRestored' $restoredCount $written $backedUp $failed $(if ($recovery) {$recovery} else {'-'})
        foreach ($entry in @($results | Where-Object { $_.state -eq 'failed' })) { $message+=T 'WkProjectFolderRestoreFailed' $entry.sourcePath $entry.error }
        return @{message=$message;folders=$results;recovery=$recovery}
    } catch { return @{message=(T 'WkProjectRestoreFailed' $_.Exception.Message);folders=@();recovery=$null} }
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
            # 복원을 고를 수 있는 대화만 프로젝트 파일을 받아 비교한다. 프로젝트 파일을 읽지 못해도 대화 미리보기는 그대로 보인다.
            if ($Job.projectRestore -and @($preview.choices) -ccontains 'incoming') {
                $stage=New-DesktopStage
                $pair=@{home=[string]$Job.home;receipt=[string]$preview.receipt;token=[string]$preview.token}
                $result.project=Get-ProjectPreviewSafe $Job.agent $ids.nativeId $ids.remoteId (Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path) $stage $pair
                if ($result.project.state -ne 'found') { $null=Remove-DesktopStage $stage }
            }
            return $result
        }
        Restore {
            # GUI는 복원(incoming)만 작업으로 보낸다. 건너뛰기·유지는 작업을 만들지 않는다.
            $choice=if ($Job.choice) {[string]$Job.choice} else {'incoming'}
            if ($Job.projectReceipt) { Assert-ProjectPairing $Job }
            # 작업 ID: 벤더는 이 이름으로 첫 쓰기 전에 복구 기록을 만든다(S3 명세 2.1절).
            $operationId=[guid]::NewGuid().ToString('N')
            $restored=Invoke-Vendor $Job 'restore' ($ids+@{receipt=[string]$Job.receipt;token=[string]$Job.token;choice=$choice;operationId=$operationId})
            $result=@{message=[string]$restored.message;effect=$restored.effect;nativeId=$restored.nativeId;restored=$restored.view;project=$null}
            if ($Job.projectReceipt) {
                # 대화를 가져왔거나 이미 같을 때만 프로젝트 파일도 복원한다. 이 PC 대화가 더 새로우면 파일도 그대로 둔다.
                if ($restored.effect -cin @('restored','equal')) {
                    $project=Restore-ProjectFolders $Job $Job.projectReceipt $Job.agent $ids.nativeId $ids.remoteId (Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path)
                    if ($project) { $result.project=$project; $result.message+=$project.message }
                }
                # 복원하지 않았어도 미리보기에서 받은 평문 사본은 지운다.
                $result.message+=Remove-DesktopStage ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Job.projectReceipt)))
            }
            return $result
        }
        Open { return @{message=[string](Invoke-Vendor $Job 'open' $ids).message} }
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
        if (Marshal.GetLastWin32Error() == 183) { CloseHandle(job); throw new Win32Exception(183); } // 같은 이름이 이미 있음
        Extended info = new Extended(); info.BasicLimits.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        int length = Marshal.SizeOf(typeof(Extended)); IntPtr buffer = Marshal.AllocHGlobal(length);
        try { Marshal.StructureToPtr(info, buffer, false); if (!SetInformationJobObject(job, 9, buffer, (uint)length)) { CloseHandle(job); throw new Win32Exception(); } }
        finally { Marshal.FreeHGlobal(buffer); }
        if (!AssignProcessToJobObject(job, GetCurrentProcess())) { CloseHandle(job); throw new Win32Exception(); }
        handle = job; Name = name;
    }
    // 이름으로 연다(조회·종료 권한). 없으면(ERROR_FILE_NOT_FOUND) Zero, 그 밖의 실패는 예외.
    public static IntPtr Open(string name) {
        IntPtr job = OpenJobObject(0x0004 | 0x0008, false, name);
        if (job != IntPtr.Zero) return job;
        int error = Marshal.GetLastWin32Error();
        if (error == 2) return IntPtr.Zero;
        throw new Win32Exception(error);
    }
    public static void Close(IntPtr job) { if (job != IntPtr.Zero) CloseHandle(job); }
    // JobObjectBasicProcessIdList. 할당 수가 목록 수보다 크면 버퍼를 늘려 전부 받을 때까지 다시 받는다.
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
    // 목록의 PID가 그사이 다른 프로세스에 재사용됐을 수 있으므로, 이 Job 소속을 확인한 것만 끝낸다.
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
    # PID 재사용을 가리려고 시작 시각을 함께 본다. 끝났거나 볼 수 없으면 빈 값.
    try { $process=[Diagnostics.Process]::GetProcessById($ProcessId); try { return [string]$process.StartTime.ToFileTimeUtc() } finally { $process.Dispose() } } catch { return '' }
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
    if ($Job.action -ceq 'Restore') { Assert-WorkerJob }
    if ($Job.action -in @('List','Backup','Preview','Restore','Open')) { return (Invoke-ConversationJob $Job) }
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
    $result | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
    exit 1
}
