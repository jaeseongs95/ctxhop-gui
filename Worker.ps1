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
$script:DesktopBackendSHA256='FB1BB0160AEE8606A7D4057FE6BD2416801DAED3F85B3B48320D54FFB612DA1B'
$script:DesktopTransportSHA256='9B14CCD3B33C75EDFD9D424D76FBAF17092364C58721C1BB9C0FD6BA73C7C006'
function Find-Executable([string]$Name) {
    if ($Name -eq 'ctxhop') { return (Join-Path $PSScriptRoot 'bin\ctxhop-claude.exe') }
    & $script:ClaudeFindExecutable $Name
}
function Assert-RestoreRuntime {
    $exe=Find-Executable 'ctxhop'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $script:RestoreBinarySHA256) { throw (T 'WkRestoreBinaryHash') }
    if ((Get-CtxVersion) -ne 'ctxhop 0.2.0-gui.2') { throw (T 'WkRestoreBinaryVersion') }
}
function Assert-FrozenFile([string]$Path,[string]$Pin) {
    if ($Pin -notmatch '^[a-fA-F0-9]{64}$' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw (T 'WkComponentMissing' $Path) }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Pin) { throw (T 'WkComponentHash' $Path) }
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
        if ($runtime.pythonPath -isnot [string] -or -not [IO.Path]::IsPathRooted($runtime.pythonPath)) { throw (T 'WkPythonPathNotAbsolute') }
        $python=$runtime.pythonPath
    }
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw (T 'WkPythonMissing' $python) }
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
    if (-not [IO.Path]::IsPathRooted($path) -or -not (Test-Path -LiteralPath $path -PathType Container)) { throw (T 'WkDesktopHomeMissing') }
    Normalize-ProjectPath (Resolve-Path -LiteralPath $path).Path
}
function Assert-DesktopTarget([object]$Job) {
    if (-not $Job.projectPath -or -not (Test-Path -LiteralPath $Job.projectPath -PathType Container)) { throw (T 'WkTargetFolderRequired') }
    Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path
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
    } catch { return (T 'WkStageCleanupFailed' $Stage) }
}
function Assert-DesktopInspect([object]$Report) {
    if ($Report.status -notin @('new','equal','incoming_newer','local_newer','conflict','blocked') -or $Report.reason -isnot [string]) { throw (T 'WkInspectStatusInvalid') }
    if ($Report.status -ne 'blocked' -and ($Report.token -isnot [string] -or -not $Report.token)) { throw (T 'WkInspectTokenMissing') }
    foreach ($field in @('source','target')) { if ($Report.PSObject.Properties.Name -notcontains $field) { throw (T 'WkInspectFieldMissing' $field) } }
}
function Get-DesktopSessions([object]$Job,[string]$DesktopRoot) {
    $offset=0; $items=@()
    do {
        $page=Invoke-DesktopBackend @('list','--home',$DesktopRoot,'--search',[string]$Job.search,'--offset',[string]$offset,'--limit','200')
        if (($page.total -isnot [int] -and $page.total -isnot [long]) -or $page.total -lt 0 -or $page.sessions -isnot [array] -or $page.sessions.Count -gt 200) { throw (T 'WkListResponseInvalid') }
        foreach ($row in $page.sessions) {
            Assert-NativeId $row.id
            if ($row.cwd -isnot [string] -or $row.title -isnot [string] -or $row.historyMode -isnot [string] -or $row.archived -isnot [bool] -or ($row.children -isnot [int] -and $row.children -isnot [long]) -or $row.children -lt 0) { throw (T 'WkListMetadataInvalid') }
            # 하위 에이전트 대화는 백엔드가 목록에서 빼고 부모 대화와 한 묶음으로 옮긴다. children은 그 묶음의 하위 대화 수다.
            $items += [pscustomobject]@{agent='codex-desktop';nativeId=$row.id;remoteId='';title=$row.title;updatedAt=$row.updatedAt;local=$true;recordCount=0;sourceCwd=$row.cwd;historyMode=$row.historyMode;archived=$row.archived;children=[int]$row.children;blockedReason=$null}
        }
        $offset+=$page.sessions.Count
        if ($page.sessions.Count -eq 0 -and $offset -lt $page.total) { throw (T 'WkListPageStalled') }
    } while ($offset -lt $page.total)
    $remote=Invoke-Bundle @('list','--json')
    if ($remote.bundles -isnot [array]) { throw (T 'WkBundleListInvalid') }
    foreach ($bundle in $remote.bundles) {
        try {
            Assert-BundleId $bundle.id; Assert-BundleMetadata $bundle.metadata
            $m=$bundle.metadata
            if ($Job.search -and ($m.title+' '+$m.sessionId+' '+$m.sourceCwd).IndexOf([string]$Job.search,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            # 묶음 형식 백업은 historyMode 끝에 ;family=하위 대화 수가 있다. 없으면 하위 대화가 빠졌을 수 있는 이전 형식이다($null).
            $children=if ($m.historyMode -match ';family=(\d{1,4})$') {[int]$Matches[1]} else {$null}
            $items += [pscustomobject]@{agent='codex-desktop';nativeId=$m.sessionId;remoteId=$bundle.id;title=$m.title;updatedAt=$m.updatedAt;local=$false;recordCount=$m.recordCount;sourceCwd=$m.sourceCwd;historyMode=$m.historyMode;archived=$false;children=$children}
        } catch {
            $items += [pscustomobject]@{agent='codex-desktop';nativeId='';remoteId=[string]$bundle.id;title=(T 'WkUnverifiedBundleTitle');updatedAt='';local=$false;recordCount=0;blockedReason=$_.Exception.Message}
        }
    }
    return @{sessions=@($items);message=(T 'WkListLoaded')}
}
function Read-DesktopReceipt([object]$Job) {
    if ($Job.receipt -isnot [string] -or -not $Job.receipt) { throw (T 'WkReceiptMissing') }
    $root=[IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CtxHopGUI\staging')).TrimEnd('\')+'\'
    $receipt=[IO.Path]::GetFullPath($Job.receipt)
    if (-not $receipt.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($receipt) -ne 'inspect.json') { throw (T 'WkReceiptPathInvalid') }
    $record=Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
    $archive=Join-Path (Split-Path -Parent $receipt) 'session.archive'
    if ($record.archive -ne $archive -or $record.bundleId -cne $Job.remoteId -or $record.nativeId -cne $Job.nativeId -or $record.home -ne (Get-DesktopHome $Job) -or $record.cwd -ne (Assert-DesktopTarget $Job) -or $record.token -cne $Job.token) { throw (T 'WkReceiptMismatch') }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $record.sha256) { throw (T 'WkArchiveChanged') }
    Assert-DesktopInspect $record.preview
    if ($record.token -cne $record.preview.token) { throw (T 'WkReceiptTokenMismatch') }
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
            if ($export.metadata.sessionId -cne $Job.nativeId -or -not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw (T 'WkExportResultInvalid') }
            $metadata=Join-Path $stage 'metadata.json'
            $metadataJson=$export.metadata | Select-Object sessionId,title,sourceCwd,updatedAt,historyMode,cliVersion,recordCount | ConvertTo-Json
            [IO.File]::WriteAllText($metadata,$metadataJson,[Text.UTF8Encoding]::new($false))
            $bundle=Invoke-Bundle @('put','--input',$archive,'--metadata',$metadata,'--json')
            Assert-BundleId $bundle.id
            # 원본은 Codex에, 백업은 암호화 bundle로 남았으므로 평문 사본은 지운다. 실패하면 위에서 중단돼 남는다.
            $warning=Remove-DesktopStage $stage
            return @{message=(T 'WkBackupDone' $bundle.id $warning);bundle=$bundle}
        }
        Preview {
            Assert-NativeId $Job.nativeId; Assert-BundleId $Job.remoteId
            $cwd=Assert-DesktopTarget $Job; $stage=New-DesktopStage; $archive=Join-Path $stage 'session.archive'
            $download=Invoke-Bundle @('get','--id',$Job.remoteId,'--output',$archive,'--json')
            if ($download.id -cne $Job.remoteId -or $download.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $download.sha256 -or (Get-Item -LiteralPath $archive).Length -ne $download.bytes) { throw (T 'WkDownloadIntegrity') }
            $preview=Invoke-DesktopBackend @('inspect','--home',$desktopRoot,'--archive',$archive,'--cwd',$cwd)
            Assert-DesktopInspect $preview
            if ($preview.status -ne 'blocked' -and $preview.source.sessionId -cne $Job.nativeId) { throw (T 'WkArchiveIdMismatch') }
            $receipt=Join-Path $stage 'inspect.json'
            @{home=$desktopRoot;cwd=$cwd;archive=$archive;bundleId=$Job.remoteId;nativeId=$Job.nativeId;token=$preview.token;sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash;preview=$preview} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receipt -Encoding UTF8
            return @{message=(T 'WkPreviewDone');preview=$preview;receipt=$receipt}
        }
        Restore {
            $record=Read-DesktopReceipt $Job
            if ($Job.choice -notin @('skip','incoming')) { throw (T 'WkChoiceRequired') }
            if ($record.preview.status -eq 'blocked' -and $Job.choice -eq 'incoming') { throw (T 'WkBlockedRestore') }
            if ($Job.choice -eq 'skip') { return @{message=(T 'WkSkipped')} }
            $applied=Invoke-DesktopBackend @('apply','--home',$desktopRoot,'--archive',$record.archive,'--cwd',$record.cwd,'--token',$record.token,'--choice',$Job.choice)
            $message=switch ([string]$applied.status) {
                'imported' {T 'WkRestoreImported' $Job.nativeId}
                'equal' {T 'WkRestoreEqual' $Job.nativeId}
                'local_newer' {T 'WkRestoreLocalNewer' $Job.nativeId}
                default { throw (T 'WkRestoreStatusUnknown' $applied.status) }
            }
            # 성공하면 교체 전·후 원본은 백엔드 복구 폴더에 있으므로 내려받은 평문 사본을 지운다. 실패하면 증거로 남긴다.
            $message+=Remove-DesktopStage (Split-Path -Parent $record.archive)
            return @{message=$message;applied=$applied}
        }
        Open { throw (T 'WkOpenManually') }
        default { throw (T 'WkUnsupportedAction') }
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
    Set-Language ([string]$job.language)
    Write-Host "CtxHop vNext: $($job.action) / $($job.agent)" -ForegroundColor Cyan
    Write-Host (T 'WkConsolePasswordHint')
    $data=Invoke-Job $job
    @{ok=$true;data=$data} | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
} catch {
    $result=@{ok=$false;error=$_.Exception.Message}
    if ($_.Exception.Data.Contains('backendResult')) { $result.backendResult=$_.Exception.Data['backendResult'] }
    $result | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
    exit 1
}
