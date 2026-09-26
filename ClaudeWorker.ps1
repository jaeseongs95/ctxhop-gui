#requires -Version 5.1
[CmdletBinding()]
param([string]$RequestFile, [string]$ResultFile, [switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Strings.ps1')
$script:RestoreBinarySHA256='A1702CE1839AF90C0DDB87E7C07F1BE7899BE8EBDD9117FE680D2EC9739C233D'
function Find-Executable([string]$Name) {
    $paths = if ($Name -eq 'ctxhop') {
        @((Join-Path $PSScriptRoot 'bin\ctxhop.exe'), (Join-Path $env:USERPROFILE '.ctxhop\bin\ctxhop.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\CtxHop\bin\ctxhop.exe'))
    } elseif ($Name -eq 'claude') { @((Join-Path $env:USERPROFILE '.local\bin\claude.exe')) } else { @() }
    foreach ($path in $paths) { if (Test-Path -LiteralPath $path -PathType Leaf) { return $path } }
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw (T 'CwExeMissing' $Name)
}
function Get-ConfigRoot {
    if ($env:CTXHOP_CONFIG_DIR) { return $env:CTXHOP_CONFIG_DIR }
    return (Join-Path $env:USERPROFILE '.ctxhop')
}
function Read-Config {
    $file = Join-Path (Get-ConfigRoot) 'config.json'
    if (-not (Test-Path -LiteralPath $file)) { throw (T 'CwSetupFirst') }
    Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Normalize-ProjectPath([string]$Value) {
    $full=[IO.Path]::GetFullPath($Value)
    if ($full.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)) { $full='\\'+$full.Substring(8) }
    elseif ($full.StartsWith('\\?\')) { $full=$full.Substring(4) }
    return $full.TrimEnd('\')
}
function Invoke-Ctx([string[]]$Arguments, [switch]$Json) {
    $exe = Find-Executable 'ctxhop'
    if ($Json) {
        $output = & $exe @Arguments
        if ($LASTEXITCODE -ne 0) { throw (T 'CwCtxFailed' $Arguments[0] $LASTEXITCODE) }
        return ($output -join "`n" | ConvertFrom-Json)
    }
    & $exe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw (T 'CwCtxFailed' $Arguments[0] $LASTEXITCODE) }
}
function Assert-Project([object]$Job) {
    if (-not $Job.projectPath -or -not (Test-Path -LiteralPath $Job.projectPath -PathType Container)) { throw (T 'CwSelectProjectFolder') }
    $path = Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path
    $config = Read-Config
    $binding = @($config.projects.bindings | Where-Object { (Normalize-ProjectPath $_.localRoot) -eq $path })
    if ($binding.Count -ne 1 -or $binding[0].identity -ne $Job.identity) { throw (T 'CwRegisterProjectFirst') }
}
function Assert-AgentClosed([string]$Agent) {
    # ponytail: 같은 에이전트의 모든 프로젝트를 차단한다. 프로젝트별 감지는 필요할 때 추가.
    $running = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
        if ($Agent -eq 'codex') {
            $_.Name -match '^(?i)(codex|codex-app|codex-code-mode-host|code-mode-host|Code|Cursor|Windsurf)\.exe$' -or
            ($_.Name -eq 'node.exe' -and $_.CommandLine -match '(?i)(@openai[\\/]codex|[\\/]codex[\\/]bin[\\/]|codex.*app-server)')
        } else {
            $_.Name -match '^(?i)(claude|claude-code|Code|Cursor|Windsurf)\.exe$' -or
            ($_.Name -eq 'node.exe' -and $_.CommandLine -match '(?i)(@anthropic-ai[\\/]claude-code|[\\/]claude-code[\\/])')
        }
    })
    if ($running.Count) { throw (T 'CwAgentRunning' $Agent ($running.ProcessId -join ', ')) }
}
function Assert-NativeId([string]$Id) {
    $guid = [guid]::Empty
    if (-not [guid]::TryParseExact($Id, 'D', [ref]$guid)) { throw (T 'CwNotNativeId') }
}
function Assert-RemoteId([string]$Id) {
    # v0.2.0: HMAC 16바이트의 lowercase Crockford base32 (26자).
    if ($Id -cnotmatch '^[0-9abcdefghjkmnpqrstvwxyz]{26}$') { throw (T 'CwNotRemoteId') }
}
function Get-NativeFiles([string]$Agent, [string]$Id) {
    Assert-NativeId $Id
    if ($Agent -eq 'codex') {
        $root = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
        $sessions = Join-Path $root 'sessions'
        if (Test-Path -LiteralPath $sessions) { return @(Get-ChildItem -LiteralPath $sessions -Filter "*$Id*.jsonl" -File -Recurse) }
    } else {
        $root = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
        $projects = Join-Path $root 'projects'
        if (Test-Path -LiteralPath $projects) {
            foreach ($folder in Get-ChildItem -LiteralPath $projects -Directory) {
                Get-ChildItem -LiteralPath $folder.FullName -Filter "$Id.jsonl" -File
            }
        }
    }
}
function Read-NativeMeta([string]$File, [string]$Agent) {
    $stream = [IO.File]::Open($File,'Open','Read','ReadWrite')
    $reader = [IO.StreamReader]::new($stream)
    try {
        for ($i=0; $i -lt 500 -and -not $reader.EndOfStream; $i++) {
            $line=$reader.ReadLine()
            if (-not $line.Trim()) { continue }
            $record=$line | ConvertFrom-Json
            if ($Agent -eq 'codex' -and $record.type -eq 'session_meta') {
                return @{ id=$record.payload.id; cwd=$record.payload.cwd; version=$record.payload.cli_version; mode=$record.payload.history_mode; originator=$record.payload.originator; source=$record.payload.source }
            }
            if ($Agent -eq 'claude-code' -and $record.sessionId -and $record.cwd) { return @{ id=$record.sessionId; cwd=$record.cwd; version=$record.version } }
        }
        throw (T 'CwNativeMetaUnreadable')
    } finally { $reader.Dispose() }
}
function Assert-NativeMapping([string]$Agent, [string]$Id, [string]$Path, [switch]$Required) {
    $files = @(Get-NativeFiles $Agent $Id)
    if (-not $files.Count) { if ($Required) { throw (T 'CwNativeFileMissing') }; return }
    if ($files.Count -ne 1) { throw (T 'CwNativeFileDuplicate') }
    $meta=Read-NativeMeta $files[0].FullName $Agent
    if ($meta.id -ne $Id -or -not $meta.cwd -or (Normalize-ProjectPath $meta.cwd) -ne (Normalize-ProjectPath $Path)) {
        throw (T 'CwNativeMappingMismatch')
    }
    return $meta
}
function Assert-CodexSession([string]$Id, [string]$Path) {
    $meta=Assert-NativeMapping 'codex' $Id $Path -Required
    if ($meta.mode -or $meta.originator -notin @('codex_cli_rs','codex_cli') -or $meta.source -ne 'cli' -or -not $meta.version) {
        throw (T 'CwCodexUnsupportedHistory')
    }
    $exe=Find-Executable 'codex'
    $version=(& $exe --version) -join ' '
    if ($LASTEXITCODE -ne 0 -or $version -notmatch ('^codex-cli\s+'+[regex]::Escape($meta.version)+'$')) { throw (T 'CwCodexVersionMismatch' $meta.version $version) }
}
function Get-JournalRoot {
    if ($script:TestJournalRoot) { return $script:TestJournalRoot }
    Join-Path $env:LOCALAPPDATA 'CtxHopGUI\recovery'
}
function Assert-NoPending {
    $root=Get-JournalRoot
    if (Test-Path -LiteralPath $root) {
        if (@(Get-ChildItem -LiteralPath $root -Filter '*.pending.json' -File).Count) { throw (T 'CwPendingRestore' $root) }
    }
}
function Begin-Restore([object]$Job) {
    $root=Get-JournalRoot
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $name=[guid]::NewGuid().ToString('N')
    $backups=@()
    foreach ($file in @(Get-NativeFiles $Job.agent $Job.nativeId)) {
        $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $backup=Join-Path $root "$name.original.jsonl"
        Copy-Item -LiteralPath $file.FullName -Destination $backup
        if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ne $hash -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $hash) { throw (T 'CwBackupIntegrityFailed') }
        $backups+=@{ original=$file.FullName; backup=$backup; sha256=$hash }
    }
    $journal=Join-Path $root "$name.pending.json"
    @{ agent=$Job.agent; nativeId=$Job.nativeId; remoteId=$Job.remoteId; projectPath=$Job.projectPath; originals=$backups; started=(Get-Date).ToString('o') } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $journal -Encoding UTF8
    return $journal
}
function Complete-Restore([string]$Journal, [object]$Job) {
    $null=Assert-NativeMapping $Job.agent $Job.nativeId $Job.projectPath -Required
    $record=Get-Content -LiteralPath $Journal -Raw -Encoding UTF8 | ConvertFrom-Json
    $file=@(Get-NativeFiles $Job.agent $Job.nativeId)[0]
    $record | Add-Member -NotePropertyName restoredSha256 -NotePropertyValue (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $completed=$Journal.Replace('.pending.json','.completed.json')
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $completed -Encoding UTF8
    Remove-Item -LiteralPath $Journal
}
function Get-CtxVersion {
    $exe=Find-Executable 'ctxhop'
    $version=(& $exe version) -join ' '
    if ($LASTEXITCODE -ne 0) { throw (T 'CwCtxVersionUnreadable') }
    return $version
}
function Assert-CtxVersion {
    $version=Get-CtxVersion
    if ($version -notin @('ctxhop 0.2.0','ctxhop 0.2.0-gui.1')) { throw (T 'CwCtxVersionUnsupported' $version) }
}
function Assert-RestoreRuntime {
    $exe=Find-Executable 'ctxhop'
    $bundled=Join-Path $PSScriptRoot 'bin\ctxhop.exe'
    if ([IO.Path]::GetFullPath($exe) -ne [IO.Path]::GetFullPath($bundled)) { throw (T 'CwRestoreNeedsBundled') }
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $script:RestoreBinarySHA256) { throw (T 'CwRestoreHashMismatch') }
    if ((Get-CtxVersion) -ne 'ctxhop 0.2.0-gui.1') { throw (T 'CwRestoreVersionUnverified') }
}
function Assert-ListSchema([object]$Report) {
    if ($Report.scope -ne 'project' -or -not ($Report.PSObject.Properties.Name -contains 'sessions') -or $null -eq $Report.sessions -or $Report.sessions -isnot [array]) { throw (T 'CwUnknownListResponse') }
}
function Test-SessionMetadata([object]$Item) {
    $guid=[guid]::Empty
    return ($Item -and $Item.agent -in @('claude-code','codex') -and $Item.local -is [bool] -and [guid]::TryParseExact([string]$Item.nativeId,'D',[ref]$guid) -and $Item.remoteId -cmatch '^[0-9abcdefghjkmnpqrstvwxyz]{26}$')
}
function Assert-Preview([object]$Preview, [string]$Agent, [string]$NativeId) {
    $required=@('preview','session','agent','workspace','differences','replaced','merged','contextInjected','sources','environmentSkipped')
    foreach ($field in $required) { if ($Preview.PSObject.Properties.Name -notcontains $field) { throw (T 'CwPreviewFieldMissing' $field) } }
    if ($Preview.preview -isnot [bool] -or $Preview.preview -ne $true -or $Preview.agent -ne $Agent -or $Preview.session -ne $NativeId) { throw (T 'CwPreviewMismatch') }
    Assert-NativeId $Preview.session
    if ($Preview.environmentSkipped -isnot [bool] -or $Preview.environmentSkipped -ne $true) { throw (T 'CwPreviewEnvNotSkipped') }
    if (($Preview.differences -isnot [long] -and $Preview.differences -isnot [int]) -or $Preview.differences -lt 0) { throw (T 'CwPreviewBadDifferences') }
    foreach ($flag in @('replaced','merged','contextInjected')) { if ($Preview.$flag -isnot [bool] -or $Preview.$flag) { throw (T 'CwPreviewBadFlag' $flag) } }
    # v0.2.0 preview가 sources:null을 반환하므로 null 또는 배열만 허용한다.
    if ($null -ne $Preview.sources -and $Preview.sources -isnot [array]) { throw (T 'CwPreviewBadSources') }
    if ($Preview.workspace -notin @('consistent','explainable','divergent','not-checked')) { throw (T 'CwPreviewBadWorkspace' $Preview.workspace) }
    if ($Preview.localState -in @('ahead','diverged','incompatible')) { throw (T 'CwLocalStateBlocked' $Preview.localState) }
    if ($Agent -eq 'codex' -and $Preview.localState -notin @('exact','behind')) { throw (T 'CwCodexRemoteNotExtension') }
    if ($Preview.environment) {
        if ($Preview.environment.status -ne 'observed-only') { throw (T 'CwEnvResponseUnknown') }
        foreach ($field in @('components','changes')) {
            if ($Preview.environment.PSObject.Properties.Name -contains $field) {
                if ($Preview.environment.$field -isnot [array] -or @($Preview.environment.$field).Count -gt 0) { throw (T 'CwEnvChangesIncluded') }
            }
        }
    }
}
function Get-AgentSessions([string]$Agent) {
    if ($Agent -notin @('codex','claude-code')) { throw (T 'CwUnsupportedAgent') }
    $report = Invoke-Ctx @('list','--json') -Json
    Assert-ListSchema $report
    $script:UnknownMetadata=@($report.sessions | Where-Object { -not (Test-SessionMetadata $_) }).Count
    @($report.sessions | Where-Object { (Test-SessionMetadata $_) -and $_.agent -eq $Agent })
}
function Select-Session([object]$Job, [string]$Mode) {
    Assert-NativeId $Job.nativeId
    Assert-RemoteId $Job.remoteId
    $sessions = @(Get-AgentSessions $Job.agent | Where-Object { $_.remoteId -eq $Job.remoteId -and $_.nativeId -eq $Job.nativeId })
    if ($sessions.Count -ne 1) { throw (T 'CwListChanged') }
    $session = $sessions[0]
    if ($Mode -in @('Backup','Open') -and -not $session.local) { throw (T 'CwSelectLocal') }
    if ($Mode -in @('Preview','Restore') -and $session.recordCount -le 0) { throw (T 'CwNotBackedUp') }
    if ($Job.agent -eq 'codex') {
        # 원격 전용은 history_mode를 검증할 수 없으므로 복원 전 차단한다.
        Assert-CodexSession $session.nativeId $Job.projectPath
    } else { $null=Assert-NativeMapping 'claude-code' $session.nativeId $Job.projectPath -Required:($Mode -in @('Backup','Open')) }
    return $session
}
function Start-Agent([string]$Agent, [string]$Id, [string]$Path) {
    Assert-NativeId $Id
    if ($Agent -eq 'codex') {
        Assert-CodexSession $Id $Path
        $exe = Find-Executable 'codex'
        & $exe resume $Id --cd $Path
    } else {
        $exe = Find-Executable 'claude'
        & $exe --resume $Id
    }
    if ($LASTEXITCODE -ne 0) { throw (T 'CwAgentFailed' $LASTEXITCODE) }
}
function Invoke-JobCore([object]$Job) {
    Assert-CtxVersion
    if ($Job.action -in @('Restore','Preview')) { Assert-RestoreRuntime }
    if ($Job.agent -notin @('codex','claude-code')) { throw (T 'CwUnsupportedAgent') }
    switch ($Job.action) {
        Setup {
            if (Test-Path -LiteralPath (Join-Path (Get-ConfigRoot) 'config.json')) { throw (T 'CwConfigExists') }
            Write-Host (T 'CwSetupPasswordHint')
            if ($Job.invite) {
                if (-not (Test-Path -LiteralPath $Job.invite -PathType Leaf)) { throw (T 'CwInviteFileMissing') }
                Invoke-Ctx @('init','--invite',$Job.invite,'--device-name',$Job.deviceName,'--no-hook')
            } else {
                if (-not (Test-Path -LiteralPath $Job.store -PathType Container)) { throw (T 'CwStoreFolderMissing') }
                if (@(Get-ChildItem -LiteralPath $Job.store -Force).Count) { throw (T 'CwStoreNotEmpty') }
                Invoke-Ctx @('init','--backend','dir','--path',$Job.store,'--device-name',$Job.deviceName,'--no-hook')
            }
            return @{ message=(T 'CwSetupDone') }
        }
        Status {
            Invoke-Ctx @('version')
            $config = Read-Config
            return @{ device=$config.device.name; backend=$config.remote.type; store=$config.remote.path; syncConfig=$config.syncConfig; message=(T 'CwStatusDone') }
        }
        Bind {
            $null = Read-Config
            if (-not (Test-Path -LiteralPath $Job.projectPath -PathType Container) -or -not $Job.identity) { throw (T 'CwBindInputRequired') }
            Invoke-Ctx @('project','bind','--path',$Job.projectPath,'--identity',$Job.identity)
            return @{ message=(T 'CwBindDone') }
        }
        Invite {
            $null = Read-Config
            if (Test-Path -LiteralPath $Job.output) { throw (T 'CwOutputExists') }
            Invoke-Ctx @('device','invite','--output',$Job.output)
            return @{ message=(T 'CwInviteDone' $Job.output) }
        }
    }
    if ($Job.action -notin @('List','Backup','Preview','Restore','Open')) { throw (T 'CwUnknownAction') }
    Assert-Project $Job
    Push-Location -LiteralPath $Job.projectPath
    try {
        if ($Job.action -eq 'List') {
            $sessions=@(Get-AgentSessions $Job.agent)
            return @{ sessions=$sessions; excluded=$script:UnknownMetadata; message=(T 'CwListDone' $script:UnknownMetadata) }
        }
        Assert-NoPending
        if ($Job.action -in @('Backup','Restore')) { Assert-AgentClosed $Job.agent }
        $session = Select-Session $Job $Job.action
        switch ($Job.action) {
            Backup {
                $config = Read-Config
                if ($config.syncConfig -ne 'disabled') { throw (T 'CwSyncConfigNotDisabled') }
                Assert-AgentClosed $Job.agent
                Invoke-Ctx @('push',$session.nativeId)
                return @{ message=(T 'CwBackupDone') }
            }
            Preview {
                $preview = Invoke-Ctx @('resume','--preview','--json','--agent',$Job.agent,'--no-workspace-context','--no-environment',$session.remoteId) -Json
                Assert-Preview $preview $Job.agent $session.nativeId
                return @{ preview=$preview; message=(T 'CwPreviewDone') }
            }
            Restore {
                # 실행 직전에도 미리보기를 다시 검사하여 과거 설정/로컬 충돌을 반영한다.
                $preview = Invoke-Ctx @('resume','--preview','--json','--agent',$Job.agent,'--no-workspace-context','--no-environment',$session.remoteId) -Json
                Assert-Preview $preview $Job.agent $session.nativeId
                Assert-AgentClosed $Job.agent
                $journal=Begin-Restore $Job
                $restored = Invoke-Ctx @('resume','--json','--agent',$Job.agent,'--no-workspace-context','--no-environment',$session.remoteId) -Json
                if ($restored.agent -ne $Job.agent -or $restored.session -ne $session.nativeId) { throw (T 'CwRestoredMismatch') }
                if ($restored.environmentSkipped -isnot [bool] -or $restored.environmentSkipped -ne $true) { throw (T 'CwRestoredEnvNotSkipped') }
                Assert-NativeId $restored.session
                Complete-Restore $journal $Job
                return @{ restored=$restored; message=(T 'CwRestoreDone') }
            }
            Open { Start-Agent $Job.agent $session.nativeId $Job.projectPath; return @{ message=(T 'CwAgentExited') } }
        }
    } finally { Pop-Location }
}
function Get-OperationMutexName { return 'Local\CtxHopGUI-operation' }
function Invoke-Job([object]$Job) {
    $mutex=[Threading.Mutex]::new($false,(Get-OperationMutexName))
    $held=$false
    try {
        try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
        if (-not $held) { throw (T 'CwOperationBusy') }
        Invoke-JobCore $Job
    } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
if ($LibraryOnly) { return }
try {
    $job = Get-Content -LiteralPath $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Set-Language ([string]$job.language)
    Write-Host "CtxHop: $($job.action) / $($job.agent)" -ForegroundColor Cyan
    Write-Host (T 'CwConsoleHint')
    $data = Invoke-Job $job
    @{ ok=$true; data=$data } | ConvertTo-Json -Depth 35 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
} catch {
    @{ ok=$false; error=$_.Exception.Message } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
    exit 1
}
