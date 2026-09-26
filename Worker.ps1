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
# Release integration replaces these pins only after reviewing the final candidate.
$script:DesktopBackendSHA256='C47841453AFB902CE9C409062C5F645359BD26654186F292D182BDD1E53115BE'
$script:DesktopTransportSHA256='9B14CCD3B33C75EDFD9D424D76FBAF17092364C58721C1BB9C0FD6BA73C7C006'
function Find-Executable([string]$Name) {
    if ($Name -eq 'ctxhop') { return (Join-Path $PSScriptRoot 'bin\ctxhop-claude.exe') }
    & $script:ClaudeFindExecutable $Name
}
function Assert-RestoreRuntime {
    $exe=Find-Executable 'ctxhop'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $script:RestoreBinarySHA256) { throw 'Claude 복원 실행 파일의 SHA256이 검증한 수정본과 다릅니다.' }
    if ((Get-CtxVersion) -ne 'ctxhop 0.2.0-gui.1') { throw 'Claude 복원 실행 파일의 안전 수정 버전을 확인하지 못했습니다.' }
}
function Assert-FrozenFile([string]$Path,[string]$Pin) {
    if ($Pin -notmatch '^[a-fA-F0-9]{64}$' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "검증한 Codex 실행 구성요소가 준비되지 않았습니다: $Path" }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Pin) { throw "Codex 실행 구성요소가 검증한 SHA256과 다릅니다: $Path" }
}
function Get-DesktopRuntime {
    $backend=Join-Path $PSScriptRoot 'backend\desktop_sessions.py'
    Assert-FrozenFile $backend $script:DesktopBackendSHA256
    # Python은 Codex Desktop이 설치·갱신하는 런타임이라 PC마다 SHA가 달라 고정하지 않는다(claude/codex 실행 파일과 같은 취급).
    # PATH는 쓰지 않는다. 다른 위치는 이 PC의 backend\runtime.json {"pythonPath":"절대경로"}로만 지정한다.
    $python=Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    $settings=Join-Path $PSScriptRoot 'backend\runtime.json'
    if (Test-Path -LiteralPath $settings -PathType Leaf) {
        $runtime=Get-Content -LiteralPath $settings -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($runtime.pythonPath -isnot [string] -or -not [IO.Path]::IsPathRooted($runtime.pythonPath)) { throw 'backend\runtime.json의 pythonPath는 절대경로여야 합니다.' }
        $python=$runtime.pythonPath
    }
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw "Python 3.10 이상 실행 파일이 없습니다: $python. Codex Desktop을 설치하거나 backend\runtime.json에 pythonPath를 지정하세요." }
    return @{backend=$backend;python=$python}
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
        try { $report=$stdout | ConvertFrom-Json } catch { if ($process.ExitCode -eq 0) { throw '작업 결과 JSON 형식이 잘못되었습니다.' } }
        if ($process.ExitCode -ne 0) {
            # Python 백엔드는 stdout JSON의 reason, bundle CLI는 stderr로 실패 이유를 낸다.
            $message=if ($report.reason) {[string]$report.reason} elseif ($report.error) {[string]$report.error} elseif ($stderr.Trim()) {$stderr.Trim()} else {"작업 실패 (종료 코드 $($process.ExitCode))"}
            $exception=[InvalidOperationException]::new($message)
            if ($report) { $exception.Data['backendResult']=$report }
            throw $exception
        }
        if ($null -eq $report) { throw '작업 결과가 비어 있습니다.' }
        return $report
    } finally { $process.Dispose() }
}
function Invoke-DesktopBackend([string[]]$Arguments) {
    $runtime=Get-DesktopRuntime
    Invoke-JsonNative $runtime.python (@('-I','-B','-u',$runtime.backend) + $Arguments)
}
function Invoke-Bundle([string[]]$Arguments) {
    $exe=Join-Path $PSScriptRoot 'bin\ctxhop.exe'
    Assert-FrozenFile $exe $script:DesktopTransportSHA256
    Invoke-JsonNative $exe (@('bundle') + $Arguments)
}
function Get-DesktopHome([object]$Job) {
    $path=if ($Job.home) {[string]$Job.home} elseif ($env:CODEX_HOME) {$env:CODEX_HOME} else {Join-Path $env:USERPROFILE '.codex'}
    if (-not [IO.Path]::IsPathRooted($path) -or -not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Codex 데이터 폴더가 없습니다. 실제 폴더를 선택하세요.' }
    Normalize-ProjectPath (Resolve-Path -LiteralPath $path).Path
}
function Assert-DesktopTarget([object]$Job) {
    if (-not $Job.projectPath -or -not (Test-Path -LiteralPath $Job.projectPath -PathType Container)) { throw '복원할 실제 작업 폴더를 선택하세요.' }
    Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path
}
function Assert-BundleId([string]$Id) {
    if ($Id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}/[a-f0-9]{32}$' -or $Id.Split('/')[0] -in @('.','..')) { throw '잘못된 공유 백업 ID입니다.' }
}
function Assert-BundleMetadata([object]$Metadata) {
    $fields=@('sessionId','title','sourceCwd','updatedAt','historyMode','cliVersion','recordCount')
    foreach ($field in $fields) { if ($Metadata.PSObject.Properties.Name -notcontains $field) { throw "백업 메타데이터가 없습니다: $field" } }
    Assert-NativeId $Metadata.sessionId
    foreach ($field in @('title','sourceCwd','updatedAt','historyMode','cliVersion')) { if ($Metadata.$field -isnot [string]) { throw "잘못된 백업 메타데이터: $field" } }
    $stamp=[datetimeoffset]::MinValue
    if ($Metadata.updatedAt -notmatch '^\d{4}-\d{2}-\d{2}T.+(Z|[+-]\d{2}:\d{2})$' -or -not [datetimeoffset]::TryParse($Metadata.updatedAt,[ref]$stamp)) { throw '백업의 변경 날짜 형식이 잘못되었습니다.' }
    if (($Metadata.recordCount -isnot [int] -and $Metadata.recordCount -isnot [long]) -or $Metadata.recordCount -lt 0) { throw '백업의 기록 개수가 잘못되었습니다.' }
}
function New-DesktopStage {
    $root=Join-Path $env:LOCALAPPDATA 'CtxHopGUI\staging'
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
        foreach ($name in @('session.archive','metadata.json','inspect.json')) { $file=Join-Path $path $name; if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) } }
        [IO.Directory]::Delete($path,$false)
        return ''
    } catch { return " 평문 임시 사본을 지우지 못했습니다: $Stage" }
}
function Assert-DesktopInspect([object]$Report) {
    if ($Report.status -notin @('new','equal','incoming_newer','local_newer','conflict','blocked') -or $Report.reason -isnot [string]) { throw 'Codex 검사 상태를 확인하지 못했습니다.' }
    if ($Report.status -ne 'blocked' -and ($Report.token -isnot [string] -or -not $Report.token)) { throw 'Codex 검사 토큰이 없습니다.' }
    foreach ($field in @('source','target')) { if ($Report.PSObject.Properties.Name -notcontains $field) { throw "Codex 검사 필드가 없습니다: $field" } }
}
function Get-DesktopSessions([object]$Job,[string]$DesktopRoot) {
    $offset=0; $items=@()
    do {
        $page=Invoke-DesktopBackend @('list','--home',$DesktopRoot,'--search',[string]$Job.search,'--offset',[string]$offset,'--limit','200')
        if (($page.total -isnot [int] -and $page.total -isnot [long]) -or $page.total -lt 0 -or $page.sessions -isnot [array] -or $page.sessions.Count -gt 200) { throw 'Codex 목록 응답 형식이 잘못되었습니다.' }
        foreach ($row in $page.sessions) {
            Assert-NativeId $row.id
            if ($row.cwd -isnot [string] -or $row.title -isnot [string] -or $row.historyMode -isnot [string] -or $row.archived -isnot [bool] -or $row.subagent -isnot [bool]) { throw 'Codex 목록 메타데이터를 확인하지 못했습니다.' }
            $blocked=if ($row.subagent) {'하위 에이전트 대화는 따로 백업할 수 없습니다. 부모 대화를 선택하세요.'} else {$null}
            $items += [pscustomobject]@{agent='codex-desktop';nativeId=$row.id;remoteId='';title=$row.title;updatedAt=$row.updatedAt;local=$true;recordCount=0;sourceCwd=$row.cwd;historyMode=$row.historyMode;archived=$row.archived;blockedReason=$blocked}
        }
        $offset+=$page.sessions.Count
        if ($page.sessions.Count -eq 0 -and $offset -lt $page.total) { throw 'Codex 목록 페이지가 중단되었습니다. 새로 불러오세요.' }
    } while ($offset -lt $page.total)
    $remote=Invoke-Bundle @('list','--json')
    if ($remote.bundles -isnot [array]) { throw '공유 백업 목록 형식이 잘못되었습니다.' }
    foreach ($bundle in $remote.bundles) {
        try {
            Assert-BundleId $bundle.id; Assert-BundleMetadata $bundle.metadata
            $m=$bundle.metadata
            if ($Job.search -and ($m.title+' '+$m.sessionId+' '+$m.sourceCwd).IndexOf([string]$Job.search,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $items += [pscustomobject]@{agent='codex-desktop';nativeId=$m.sessionId;remoteId=$bundle.id;title=$m.title;updatedAt=$m.updatedAt;local=$false;recordCount=$m.recordCount;sourceCwd=$m.sourceCwd;historyMode=$m.historyMode;archived=$false}
        } catch {
            $items += [pscustomobject]@{agent='codex-desktop';nativeId='';remoteId=[string]$bundle.id;title='미확인 공유 백업';updatedAt='';local=$false;recordCount=0;blockedReason=$_.Exception.Message}
        }
    }
    return @{sessions=@($items);message='Codex 전체 프로젝트·보관 대화와 공유 백업 목록을 불러왔습니다. 같은 UUID의 각 백업은 별도 행입니다.'}
}
function Read-DesktopReceipt([object]$Job) {
    if ($Job.receipt -isnot [string] -or -not $Job.receipt) { throw '미리보기 기록이 없습니다. 다시 검사하세요.' }
    $root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CtxHopGUI\staging')).TrimEnd('\')+'\'
    $receipt=[IO.Path]::GetFullPath($Job.receipt)
    if (-not $receipt.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($receipt) -ne 'inspect.json') { throw '미리보기 기록 경로가 잘못되었습니다.' }
    $record=Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
    $archive=Join-Path (Split-Path -Parent $receipt) 'session.archive'
    if ($record.archive -ne $archive -or $record.bundleId -cne $Job.remoteId -or $record.nativeId -cne $Job.nativeId -or $record.home -ne (Get-DesktopHome $Job) -or $record.cwd -ne (Assert-DesktopTarget $Job) -or $record.token -cne $Job.token) { throw '미리보기의 백업·ID·폴더·토큰이 선택과 다릅니다. 다시 검사하세요.' }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $record.sha256) { throw '미리보기 이후 백업 파일이 바뀌었습니다. 다시 검사하세요.' }
    Assert-DesktopInspect $record.preview
    if ($record.token -cne $record.preview.token) { throw '저장한 검사 토큰이 다릅니다.' }
    return $record
}
function Invoke-DesktopJob([object]$Job) {
    $desktopRoot=Get-DesktopHome $Job
    switch ($Job.action) {
        List { return (Get-DesktopSessions $Job $desktopRoot) }
        Backup {
            Assert-NativeId $Job.nativeId
            $stage=New-DesktopStage; $archive=Join-Path $stage 'session.archive'
            $export=Invoke-DesktopBackend @('export','--home',$desktopRoot,'--id',$Job.nativeId,'--output',$archive)
            # The backend owns archive semantics; never infer historyMode or recordCount from the list.
            Assert-BundleMetadata $export.metadata
            if ($export.metadata.sessionId -cne $Job.nativeId -or -not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw 'Codex 백업 결과의 ID 또는 파일을 확인하지 못했습니다.' }
            $metadata=Join-Path $stage 'metadata.json'
            $metadataJson=$export.metadata | Select-Object sessionId,title,sourceCwd,updatedAt,historyMode,cliVersion,recordCount | ConvertTo-Json
            [IO.File]::WriteAllText($metadata,$metadataJson,[Text.UTF8Encoding]::new($false))
            $bundle=Invoke-Bundle @('put','--input',$archive,'--metadata',$metadata,'--json')
            Assert-BundleId $bundle.id
            # 원본은 Codex에, 백업은 암호화 bundle로 남았으므로 평문 사본은 지운다. 실패하면 위에서 중단돼 남는다.
            $warning=Remove-DesktopStage $stage
            return @{message="백업 완료: $($bundle.id). Drive 업로드 완료를 확인하세요.$warning";bundle=$bundle}
        }
        Preview {
            Assert-NativeId $Job.nativeId; Assert-BundleId $Job.remoteId
            $cwd=Assert-DesktopTarget $Job; $stage=New-DesktopStage; $archive=Join-Path $stage 'session.archive'
            $download=Invoke-Bundle @('get','--id',$Job.remoteId,'--output',$archive,'--json')
            if ($download.id -cne $Job.remoteId -or $download.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $download.sha256 -or (Get-Item -LiteralPath $archive).Length -ne $download.bytes) { throw '다운로드한 백업 무결성을 확인하지 못했습니다.' }
            $preview=Invoke-DesktopBackend @('inspect','--home',$desktopRoot,'--archive',$archive,'--cwd',$cwd)
            Assert-DesktopInspect $preview
            if ($preview.status -ne 'blocked' -and $preview.source.sessionId -cne $Job.nativeId) { throw '백업 내부 UUID가 목록 선택과 다릅니다.' }
            $receipt=Join-Path $stage 'inspect.json'
            @{home=$desktopRoot;cwd=$cwd;archive=$archive;bundleId=$Job.remoteId;nativeId=$Job.nativeId;token=$preview.token;sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash;preview=$preview} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receipt -Encoding UTF8
            return @{message='내용 검사 완료. 각 항목의 선택을 확인하고 승인하세요.';preview=$preview;receipt=$receipt}
        }
        Restore {
            $record=Read-DesktopReceipt $Job
            if ($Job.choice -notin @('skip','incoming')) { throw '각 항목에서 유지·복원·건너뛰기를 직접 선택하세요.' }
            if ($record.preview.status -eq 'blocked' -and $Job.choice -eq 'incoming') { throw '손상·호환 불가 백업은 복원할 수 없습니다.' }
            if ($Job.choice -eq 'skip') { return @{message='이 항목은 건너뛰었습니다. 로컬 대화를 유지했습니다.'} }
            $applied=Invoke-DesktopBackend @('apply','--home',$desktopRoot,'--archive',$record.archive,'--cwd',$record.cwd,'--token',$record.token,'--choice',$Job.choice)
            $message=switch ([string]$applied.status) {
                'imported' {"Codex 복원 완료: $($Job.nativeId). 앱을 다시 열어 해당 UUID와 작업 폴더를 확인하세요."}
                'equal' {"변경 없음: $($Job.nativeId) 대화가 백업과 같습니다."}
                'local_newer' {"변경 없음: 이 PC의 $($Job.nativeId) 대화가 더 이어져 있어 유지했습니다."}
                default { throw "Codex 복원 결과를 확인하지 못했습니다: $($applied.status)" }
            }
            # 성공하면 교체 전·후 원본은 백엔드 복구 폴더에 있으므로 내려받은 평문 사본을 지운다. 실패하면 증거로 남긴다.
            $message+=Remove-DesktopStage (Split-Path -Parent $record.archive)
            return @{message=$message;applied=$applied}
        }
        Open { throw 'Codex Desktop을 직접 열고 대화 UUID와 작업 폴더를 확인하세요. 자동 입력은 보내지 않습니다.' }
        default { throw '지원하지 않는 Codex Desktop 작업입니다.' }
    }
}
function Invoke-JobCore([object]$Job) {
    if ($Job.agent -eq 'codex-desktop' -and $Job.action -in @('List','Backup','Preview','Restore','Open')) { return (Invoke-DesktopJob $Job) }
    if ($Job.agent -eq 'codex-desktop') { $Job.agent='claude-code' }
    & $script:ClaudeJobCore $Job
}
if ($script:VNextLibraryOnly) { return }
try {
    $job=Get-Content -LiteralPath $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "CtxHop vNext: $($job.action) / $($job.agent)" -ForegroundColor Cyan
    Write-Host '암호가 필요하면 이 창에 입력하세요. Codex 앱을 강제로 종료하지 않습니다.'
    $data=Invoke-Job $job
    @{ok=$true;data=$data} | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
} catch {
    $result=@{ok=$false;error=$_.Exception.Message}
    if ($_.Exception.Data.Contains('backendResult')) { $result.backendResult=$_.Exception.Data['backendResult'] }
    $result | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
    exit 1
}
