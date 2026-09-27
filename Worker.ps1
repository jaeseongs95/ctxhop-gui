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
# Release integration replaces these pins only after reviewing the final candidate.
$script:DesktopBackendSHA256='C1775722000097548E0B6C72BB000D6552F151E17A232BC1FBEA687A2D74881A'
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
function Assert-DesktopInspect([object]$Report) {
    if ($Report.status -notin @('new','equal','incoming_newer','local_newer','conflict','blocked') -or $Report.reason -isnot [string]) { throw (T 'WkInspectStatusInvalid') }
    if ($Report.status -ne 'blocked' -and ($Report.token -isnot [string] -or -not $Report.token)) { throw (T 'WkInspectTokenMissing') }
    foreach ($field in @('source','target')) { if ($Report.PSObject.Properties.Name -notcontains $field) { throw (T 'WkInspectFieldMissing' $field) } }
}
function Get-DesktopSessions([object]$Job,[string]$DesktopRoot) {
    $offset=0; $items=@()
    do {
        $page=Invoke-DesktopBackend @('list','--home',$DesktopRoot,"--search=$($Job.search)",'--offset',[string]$offset,'--limit','200')
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
            # 프로젝트 파일과 그 연결 기록은 대화가 아니므로 목록에 넣지 않는다.
            if ($m.historyMode -like 'project-*') { continue }
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
    return @{folders=$folders;skipped=@($picked.skipped);outside=@($picked.outside);ask=$ask}
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
        try {
            $manifest=Get-ProjectManifest $entry.list; $hash=$manifest.hash; $missed=$manifest.unreadable.Count
            $found=@($bundles | Where-Object { $_.metadata.historyMode -ceq "project-files;v1;$hash" })
            $snapshot=$null
            if (-not $found.Count) {
                # 해시를 구한 뒤 바뀐 파일이 있을 수 있으므로 실제로 넣은 내용의 해시로 다시 찾는다.
                $snapshot=New-ProjectSnapshot $entry.list $zip
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
function Get-ProjectPreview([string]$Agent,[string]$SessionId,[string]$Conversation,[string]$Target,[string]$Stage) {
    # 이 대화 백업에 이어진 프로젝트 파일을 받아 복원할 폴더와 비교한다. 이 PC에 없는 추가 폴더는 GUI가 고르도록 needsFolder로 둔다.
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
    [IO.File]::WriteAllText($receipt,(ConvertTo-Json -InputObject ([ordered]@{agent=$Agent;sessionId=$SessionId;conversation=$Conversation;linkId=$links[0].id;folders=$folders}) -Depth 8),[Text.UTF8Encoding]::new($false))
    return @{state='found';receipt=$receipt;createdAt=[string]$link.createdAt;folders=$folders;skipped=@($link.skipped);outside=@($link.outside)}
}
function Get-ProjectPreviewSafe([string]$Agent,[string]$SessionId,[string]$Conversation,[string]$Target,[string]$Stage) {
    # 프로젝트 파일을 읽지 못해도 대화 미리보기는 그대로 보인다.
    try { return (Get-ProjectPreview $Agent $SessionId $Conversation $Target $Stage) } catch { return @{state='error';reason=$_.Exception.Message} }
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
function Restore-ProjectFolders([object]$Job,[string]$Receipt,[string]$Agent,[string]$SessionId,[string]$Conversation,[string]$StartTarget) {
    # 미리보기에서 받은 프로젝트 파일을 복원한다. 시작 폴더는 이번 복원 폴더에, 추가 폴더는 원래 경로나 GUI가 고른 폴더에 쓴다. 빈 값은 건너뜀.
    if (-not $Job.projectRestore -or -not $Receipt) { return $null }
    try {
        $record=Read-ProjectReceipt $Receipt $Agent $SessionId $Conversation
        $recovery=$null; $results=@()
        foreach ($folder in $record.folders) {
            if ($folder.state -notin @('ready','needsFolder')) { continue }
            $override=if ($Job.projectTargets) { $Job.projectTargets.PSObject.Properties[[string]$folder.index] } else { $null }
            $target=if ($folder.role -eq 'start') {$StartTarget} elseif ($override) {[string]$override.Value} else {[string]$folder.target}
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
function Get-ClaudeSessionFiles([string]$Id) {
    # Claude Code 대화 파일과, 있으면 그 옆 폴더의 하위 에이전트 대화 파일.
    foreach ($file in @(Get-NativeFiles 'claude-code' $Id)) {
        $file.FullName
        $subagents=Join-Path $file.DirectoryName "$Id\subagents"
        if (Test-Path -LiteralPath $subagents -PathType Container) { Get-ChildItem -LiteralPath $subagents -Filter '*.jsonl' -File | ForEach-Object FullName }
    }
}
function Invoke-ClaudeProjectJob([object]$Job) {
    # Claude Code 대화의 백업·미리보기·복원에 프로젝트 파일을 덧붙인다. 대화 작업은 ClaudeWorker가 그대로 한다.
    switch ($Job.action) {
        Backup {
            $plan=$null; $planError=''
            if ($Job.projectBackup -and $Job.projectPath -and (Test-Path -LiteralPath $Job.projectPath -PathType Container)) {
                Assert-NativeId $Job.nativeId
                # 폴더를 고르다 실패해도 대화 백업은 막지 않고 이유만 덧붙인다.
                try {
                    $work=Read-ClaudeWorkData @(Get-ClaudeSessionFiles $Job.nativeId)
                    $plan=Get-ProjectPlan $Job (Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path) $work.cwds $work.edits
                } catch { $planError=$_.Exception.Message }
                if ($plan.ask.Count) { return (New-ProjectQuestion $plan) }
            }
            $result=& $script:ClaudeJobCore $Job
            if ($planError) { $result.message+=T 'WkProjectFailed' $planError }
            if ($plan) {
                $stage=New-DesktopStage
                try { $result.project=Save-ProjectBackup $plan 'claude-code' $Job.nativeId $Job.remoteId $stage; $result.message+=$result.project.message }
                catch { $result.message+=T 'WkProjectFailed' $_.Exception.Message }
                $result.message+=Remove-DesktopStage $stage
            }
            return $result
        }
        Preview {
            $result=& $script:ClaudeJobCore $Job
            if (-not $Job.projectRestore) { return $result }
            $stage=New-DesktopStage
            $result.project=Get-ProjectPreviewSafe 'claude-code' $Job.nativeId $Job.remoteId (Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path) $stage
            if ($result.project.state -ne 'found') { $null=Remove-DesktopStage $stage }
            return $result
        }
        Restore {
            $result=& $script:ClaudeJobCore $Job
            if ($Job.projectReceipt) {
                $project=Restore-ProjectFolders $Job $Job.projectReceipt 'claude-code' $Job.nativeId $Job.remoteId (Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path)
                if ($project) { $result.project=$project; $result.message+=$project.message }
                # 복원하지 않았어도 미리보기에서 받은 평문 사본은 지운다.
                $result.message+=Remove-DesktopStage ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Job.projectReceipt)))
            }
            return $result
        }
    }
}
function Invoke-DesktopJob([object]$Job) {
    $desktopRoot=Get-DesktopHome $Job
    switch ($Job.action) {
        List { return (Get-DesktopSessions $Job $desktopRoot) }
        Backup {
            Assert-NativeId $Job.nativeId
            $stage=New-DesktopStage; $archive=Join-Path $stage 'session.archive'
            try { $export=Invoke-DesktopBackend @('export','--home',$desktopRoot,'--id',$Job.nativeId,'--output',$archive) }
            catch {
                # 실패한 내보내기는 쓸 파일이 없거나 버려야 하는 파일뿐이라 평문 staging을 남기지 않는다. 진행 중(busy)이면 결과의 backendResult로 GUI가 건너뜀으로 센다.
                $null=Remove-DesktopStage $stage
                throw
            }
            # The backend owns archive semantics; never infer historyMode or recordCount from the list.
            Assert-BundleMetadata $export.metadata
            if ($export.metadata.sessionId -cne $Job.nativeId -or -not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw (T 'WkExportResultInvalid') }
            # 프로젝트 폴더가 커서 물어야 하면 대화도 올리지 않고 돌려준다.
            $plan=$null; $planError=''
            if ($Job.projectBackup) {
                try { $plan=Get-ProjectPlan $Job $export.metadata.sourceCwd @($export.folders.cwds) @($export.folders.edits) } catch { $planError=$_.Exception.Message }
                if ($plan.ask.Count) { $null=Remove-DesktopStage $stage; return (New-ProjectQuestion $plan) }
            }
            $metadata=Join-Path $stage 'metadata.json'
            $metadataJson=$export.metadata | Select-Object sessionId,title,sourceCwd,updatedAt,historyMode,cliVersion,recordCount | ConvertTo-Json
            [IO.File]::WriteAllText($metadata,$metadataJson,[Text.UTF8Encoding]::new($false))
            $bundle=Invoke-Bundle @('put','--input',$archive,'--metadata',$metadata,'--json')
            Assert-BundleId $bundle.id
            # 프로젝트 파일은 대화 백업이 끝난 뒤 올린다. 실패해도 대화 백업은 그대로이고 이유만 덧붙인다.
            $project=$null; $projectMessage=if ($planError) {T 'WkProjectFailed' $planError} else {''}
            if ($plan) {
                try { $project=Save-ProjectBackup $plan 'codex-desktop' $Job.nativeId $bundle.id $stage; $projectMessage=$project.message }
                catch { $projectMessage=T 'WkProjectFailed' $_.Exception.Message }
            }
            # 원본은 Codex에, 백업은 암호화 bundle로 남았으므로 평문 사본은 지운다. 실패하면 위에서 중단돼 남는다.
            $warning=Remove-DesktopStage $stage
            return @{message=(T 'WkBackupDone' $bundle.id ($projectMessage+$warning));bundle=$bundle;project=$project}
        }
        Preview {
            Assert-NativeId $Job.nativeId; Assert-BundleId $Job.remoteId
            $cwd=Assert-DesktopTarget $Job; $stage=New-DesktopStage; $archive=Join-Path $stage 'session.archive'
            $null=Get-BundleFile $Job.remoteId $archive
            $preview=Invoke-DesktopBackend @('inspect','--home',$desktopRoot,'--archive',$archive,'--cwd',$cwd)
            Assert-DesktopInspect $preview
            if ($preview.status -ne 'blocked' -and $preview.source.sessionId -cne $Job.nativeId) { throw (T 'WkArchiveIdMismatch') }
            $receipt=Join-Path $stage 'inspect.json'
            @{home=$desktopRoot;cwd=$cwd;archive=$archive;bundleId=$Job.remoteId;nativeId=$Job.nativeId;token=$preview.token;sha256=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash;preview=$preview} | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $receipt -Encoding UTF8
            $project=if ($Job.projectRestore -and $preview.status -ne 'blocked') { Get-ProjectPreviewSafe 'codex-desktop' $Job.nativeId $Job.remoteId $cwd $stage } else { @{state='off'} }
            return @{message=(T 'WkPreviewDone');preview=$preview;receipt=$receipt;project=$project}
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
            # 대화를 가져왔거나 이미 같을 때만 프로젝트 파일도 복원한다. 이 PC 대화가 더 새로우면 파일도 그대로 둔다.
            $project=$null
            $projectReceipt=Join-Path (Split-Path -Parent $record.archive) 'project-receipt.json'
            if ($applied.status -in @('imported','equal') -and (Test-Path -LiteralPath $projectReceipt -PathType Leaf)) {
                $project=Restore-ProjectFolders $Job $projectReceipt 'codex-desktop' $Job.nativeId $Job.remoteId $record.cwd
                if ($project) { $message+=$project.message }
            }
            # 성공하면 교체 전·후 원본은 백엔드 복구 폴더에 있으므로 내려받은 평문 사본을 지운다. 실패하면 증거로 남긴다.
            $message+=Remove-DesktopStage (Split-Path -Parent $record.archive)
            return @{message=$message;applied=$applied;project=$project}
        }
        Open { throw (T 'WkOpenManually') }
        default { throw (T 'WkUnsupportedAction') }
    }
}
function Invoke-JobCore([object]$Job) {
    if ($Job.agent -eq 'codex-desktop' -and $Job.action -in @('List','Backup','Preview','Restore','Open')) { return (Invoke-DesktopJob $Job) }
    if ($Job.agent -eq 'codex-desktop') { $Job.agent='claude-code' }
    if ($Job.agent -eq 'claude-code' -and $Job.action -in @('Backup','Preview','Restore')) { return (Invoke-ClaudeProjectJob $Job) }
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
