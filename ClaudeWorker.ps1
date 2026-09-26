#requires -Version 5.1
[CmdletBinding()]
param([string]$RequestFile, [string]$ResultFile, [switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'
$script:RestoreBinarySHA256='A1702CE1839AF90C0DDB87E7C07F1BE7899BE8EBDD9117FE680D2EC9739C233D'
function Find-Executable([string]$Name) {
    $paths = if ($Name -eq 'ctxhop') {
        @((Join-Path $PSScriptRoot 'bin\ctxhop.exe'), (Join-Path $env:USERPROFILE '.ctxhop\bin\ctxhop.exe'), (Join-Path $env:LOCALAPPDATA 'Programs\CtxHop\bin\ctxhop.exe'))
    } elseif ($Name -eq 'claude') { @((Join-Path $env:USERPROFILE '.local\bin\claude.exe')) } else { @() }
    foreach ($path in $paths) { if (Test-Path -LiteralPath $path -PathType Leaf) { return $path } }
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    throw "$Name 실행 파일이 없습니다. 설치 후 다시 실행하세요."
}
function Get-ConfigRoot {
    if ($env:CTXHOP_CONFIG_DIR) { return $env:CTXHOP_CONFIG_DIR }
    return (Join-Path $env:USERPROFILE '.ctxhop')
}
function Read-Config {
    $file = Join-Path (Get-ConfigRoot) 'config.json'
    if (-not (Test-Path -LiteralPath $file)) { throw '연결 설정 탭에서 먼저 초기 설정을 진행하세요.' }
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
        if ($LASTEXITCODE -ne 0) { throw "ctxhop $($Arguments[0]) 실패 (종료 코드 $LASTEXITCODE)" }
        return ($output -join "`n" | ConvertFrom-Json)
    }
    & $exe @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "ctxhop $($Arguments[0]) 실패 (종료 코드 $LASTEXITCODE)" }
}
function Assert-Project([object]$Job) {
    if (-not $Job.projectPath -or -not (Test-Path -LiteralPath $Job.projectPath -PathType Container)) { throw '실제 프로젝트 폴더를 선택하세요.' }
    $path = Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path
    $config = Read-Config
    $binding = @($config.projects.bindings | Where-Object { (Normalize-ProjectPath $_.localRoot) -eq $path })
    if ($binding.Count -ne 1 -or $binding[0].identity -ne $Job.identity) { throw '프로젝트 등록 버튼으로 폴더와 공통 이름을 먼저 등록하세요.' }
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
    if ($running.Count) { throw "$Agent 실행 중입니다. 앱/CLI를 종료한 뒤 다시 시도하세요. PID: $($running.ProcessId -join ', ')" }
}
function Assert-NativeId([string]$Id) {
    $guid = [guid]::Empty
    if (-not [guid]::TryParseExact($Id, 'D', [ref]$guid)) { throw '올바른 네이티브 세션 UUID가 아닙니다.' }
}
function Assert-RemoteId([string]$Id) {
    # v0.2.0: HMAC 16바이트의 lowercase Crockford base32 (26자).
    if ($Id -cnotmatch '^[0-9abcdefghjkmnpqrstvwxyz]{26}$') { throw '올바른 ctxhop 저장소 세션 ID가 아닙니다.' }
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
        throw '대화 파일의 ID와 프로젝트 메타데이터를 확인하지 못했습니다.'
    } finally { $reader.Dispose() }
}
function Assert-NativeMapping([string]$Agent, [string]$Id, [string]$Path, [switch]$Required) {
    $files = @(Get-NativeFiles $Agent $Id)
    if (-not $files.Count) { if ($Required) { throw '원본 대화 파일을 확인하지 못했습니다.' }; return }
    if ($files.Count -ne 1) { throw '같은 ID의 대화 파일이 여러 개입니다. 원본을 확인하세요.' }
    $meta=Read-NativeMeta $files[0].FullName $Agent
    if ($meta.id -ne $Id -or -not $meta.cwd -or (Normalize-ProjectPath $meta.cwd) -ne (Normalize-ProjectPath $Path)) {
        throw '대화 파일의 실제 ID 또는 프로젝트 경로가 선택과 다릅니다.'
    }
    return $meta
}
function Assert-CodexSession([string]$Id, [string]$Path) {
    $meta=Assert-NativeMapping 'codex' $Id $Path -Required
    if ($meta.mode -or $meta.originator -notin @('codex_cli_rs','codex_cli') -or $meta.source -ne 'cli' -or -not $meta.version) {
        throw 'Codex 데스크톱 paginated/미확인 대화는 전체 기록 왕복이 검증되지 않았습니다. 이 GUI에서는 CLI legacy 대화만 허용합니다.'
    }
    $exe=Find-Executable 'codex'
    $version=(& $exe --version) -join ' '
    if ($LASTEXITCODE -ne 0 -or $version -notmatch ('^codex-cli\s+'+[regex]::Escape($meta.version)+'$')) { throw "Codex 원본 버전($($meta.version))과 실행 버전($version)이 다릅니다. 자동 재개하지 않습니다." }
}
function Get-JournalRoot {
    if ($script:TestJournalRoot) { return $script:TestJournalRoot }
    Join-Path $env:LOCALAPPDATA 'CtxHopGUI\recovery'
}
function Assert-NoPending {
    $root=Get-JournalRoot
    if (Test-Path -LiteralPath $root) {
        if (@(Get-ChildItem -LiteralPath $root -Filter '*.pending.json' -File).Count) { throw "이전 복원이 중단되었습니다. 원본 백업과 pending 기록을 확인하세요: $root (README 복구 안내)" }
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
        if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ne $hash -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $hash) { throw '원본 백업 무결성 확인에 실패했습니다. 복원하지 않았습니다.' }
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
    if ($LASTEXITCODE -ne 0) { throw 'ctxhop 버전을 확인하지 못했습니다.' }
    return $version
}
function Assert-CtxVersion {
    $version=Get-CtxVersion
    if ($version -notin @('ctxhop 0.2.0','ctxhop 0.2.0-gui.1')) { throw "이 GUI는 ctxhop 0.2.0 계열 응답을 검증합니다. 현재 버전: $version" }
}
function Assert-RestoreRuntime {
    $exe=Find-Executable 'ctxhop'
    $bundled=Join-Path $PSScriptRoot 'bin\ctxhop.exe'
    if ([IO.Path]::GetFullPath($exe) -ne [IO.Path]::GetFullPath($bundled)) { throw '복원에는 이 GUI에 포함된 안전 수정 실행 파일이 필요합니다.' }
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $script:RestoreBinarySHA256) { throw '복원 실행 파일의 SHA256이 검증한 수정본과 다릅니다.' }
    if ((Get-CtxVersion) -ne 'ctxhop 0.2.0-gui.1') { throw '복원 실행 파일의 안전 수정 버전을 확인하지 못했습니다.' }
}
function Assert-ListSchema([object]$Report) {
    if ($Report.scope -ne 'project' -or -not ($Report.PSObject.Properties.Name -contains 'sessions') -or $null -eq $Report.sessions -or $Report.sessions -isnot [array]) { throw '알 수 없는 목록 응답입니다.' }
}
function Test-SessionMetadata([object]$Item) {
    $guid=[guid]::Empty
    return ($Item -and $Item.agent -in @('claude-code','codex') -and $Item.local -is [bool] -and [guid]::TryParseExact([string]$Item.nativeId,'D',[ref]$guid) -and $Item.remoteId -cmatch '^[0-9abcdefghjkmnpqrstvwxyz]{26}$')
}
function Assert-Preview([object]$Preview, [string]$Agent, [string]$NativeId) {
    $required=@('preview','session','agent','workspace','differences','replaced','merged','contextInjected','sources','environmentSkipped')
    foreach ($field in $required) { if ($Preview.PSObject.Properties.Name -notcontains $field) { throw "미리보기 필드가 없습니다: $field" } }
    if ($Preview.preview -isnot [bool] -or $Preview.preview -ne $true -or $Preview.agent -ne $Agent -or $Preview.session -ne $NativeId) { throw '미리보기 유형/세션 ID/에이전트가 선택과 다릅니다.' }
    Assert-NativeId $Preview.session
    if ($Preview.environmentSkipped -isnot [bool] -or $Preview.environmentSkipped -ne $true) { throw '미리보기의 환경 설정 적용 차단을 확인하지 못했습니다.' }
    if (($Preview.differences -isnot [long] -and $Preview.differences -isnot [int]) -or $Preview.differences -lt 0) { throw '미리보기 차이 정보가 잘못되었습니다.' }
    foreach ($flag in @('replaced','merged','contextInjected')) { if ($Preview.$flag -isnot [bool] -or $Preview.$flag) { throw "미리보기 상태가 잘못되었습니다: $flag" } }
    # v0.2.0 preview가 sources:null을 반환하므로 null 또는 배열만 허용한다.
    if ($null -ne $Preview.sources -and $Preview.sources -isnot [array]) { throw '미리보기 source 형식이 잘못되었습니다.' }
    if ($Preview.workspace -notin @('consistent','explainable','divergent','not-checked')) { throw "미리보기 작업 폴더 상태를 확인할 수 없습니다: $($Preview.workspace)" }
    if ($Preview.localState -in @('ahead','diverged','incompatible')) { throw "로컬 대화 상태: $($Preview.localState). 강제 덮어쓰지 않았습니다." }
    if ($Agent -eq 'codex' -and $Preview.localState -notin @('exact','behind')) { throw 'Codex 원격 기록이 검증된 로컬 원본과 같거나 그 연장인지 확인할 수 없습니다. 이 복원은 지원하지 않습니다.' }
    if ($Preview.environment) {
        if ($Preview.environment.status -ne 'observed-only') { throw '환경 설정 응답 형식을 확인할 수 없습니다.' }
        foreach ($field in @('components','changes')) {
            if ($Preview.environment.PSObject.Properties.Name -contains $field) {
                if ($Preview.environment.$field -isnot [array] -or @($Preview.environment.$field).Count -gt 0) { throw '백업에 환경 설정 또는 미확인 변경이 포함되어 있습니다. 대화만 복원하기 위해 적용을 중단했습니다.' }
            }
        }
    }
}
function Get-AgentSessions([string]$Agent) {
    if ($Agent -notin @('codex','claude-code')) { throw '지원하지 않는 에이전트입니다.' }
    $report = Invoke-Ctx @('list','--json') -Json
    Assert-ListSchema $report
    $script:UnknownMetadata=@($report.sessions | Where-Object { -not (Test-SessionMetadata $_) }).Count
    @($report.sessions | Where-Object { (Test-SessionMetadata $_) -and $_.agent -eq $Agent })
}
function Select-Session([object]$Job, [string]$Mode) {
    Assert-NativeId $Job.nativeId
    Assert-RemoteId $Job.remoteId
    $sessions = @(Get-AgentSessions $Job.agent | Where-Object { $_.remoteId -eq $Job.remoteId -and $_.nativeId -eq $Job.nativeId })
    if ($sessions.Count -ne 1) { throw '목록이 바뀌었습니다. 목록 새로고침 후 다시 선택하세요.' }
    $session = $sessions[0]
    if ($Mode -in @('Backup','Open') -and -not $session.local) { throw '이 PC의 로컬 대화를 선택하세요.' }
    if ($Mode -in @('Preview','Restore') -and $session.recordCount -le 0) { throw '아직 백업되지 않은 대화입니다.' }
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
    if ($LASTEXITCODE -ne 0) { throw "에이전트 실행 실패 (종료 코드 $LASTEXITCODE)" }
}
function Invoke-JobCore([object]$Job) {
    Assert-CtxVersion
    if ($Job.action -in @('Restore','Preview')) { Assert-RestoreRuntime }
    if ($Job.agent -notin @('codex','claude-code')) { throw '지원하지 않는 에이전트입니다.' }
    switch ($Job.action) {
        Setup {
            if (Test-Path -LiteralPath (Join-Path (Get-ConfigRoot) 'config.json')) { throw '기존 연결 설정을 유지했습니다. 재초기화하지 않습니다.' }
            Write-Host '암호는 여기서 직접 입력하세요. 대화만 옮기려면 설정 동기화 질문에 n을 입력하세요.'
            if ($Job.invite) {
                if (-not (Test-Path -LiteralPath $Job.invite -PathType Leaf)) { throw '초대 파일이 없습니다.' }
                Invoke-Ctx @('init','--invite',$Job.invite,'--device-name',$Job.deviceName,'--no-hook')
            } else {
                if (-not (Test-Path -LiteralPath $Job.store -PathType Container)) { throw '저장소 폴더가 없습니다.' }
                if (@(Get-ChildItem -LiteralPath $Job.store -Force).Count) { throw '기존 저장소입니다. 원본 PC에서 만든 초대로 연결하세요.' }
                Invoke-Ctx @('init','--backend','dir','--path',$Job.store,'--device-name',$Job.deviceName,'--no-hook')
            }
            return @{ message='연결 설정 완료' }
        }
        Status {
            Invoke-Ctx @('version')
            $config = Read-Config
            return @{ device=$config.device.name; backend=$config.remote.type; store=$config.remote.path; syncConfig=$config.syncConfig; message='설정 확인 완료' }
        }
        Bind {
            $null = Read-Config
            if (-not (Test-Path -LiteralPath $Job.projectPath -PathType Container) -or -not $Job.identity) { throw '프로젝트 폴더와 공통 이름을 입력하세요.' }
            Invoke-Ctx @('project','bind','--path',$Job.projectPath,'--identity',$Job.identity)
            return @{ message='프로젝트 등록 완료' }
        }
        Invite {
            $null = Read-Config
            if (Test-Path -LiteralPath $Job.output) { throw '동일한 파일이 있습니다. 새 이름을 선택하세요.' }
            Invoke-Ctx @('device','invite','--output',$Job.output)
            return @{ message="초대 생성 완료: $($Job.output)" }
        }
    }
    if ($Job.action -notin @('List','Backup','Preview','Restore','Open')) { throw '알 수 없는 작업입니다.' }
    Assert-Project $Job
    Push-Location -LiteralPath $Job.projectPath
    try {
        if ($Job.action -eq 'List') {
            $sessions=@(Get-AgentSessions $Job.agent)
            return @{ sessions=$sessions; excluded=$script:UnknownMetadata; message="목록 갱신 완료 · 미확인 메타데이터 제외 $script:UnknownMetadata 개" }
        }
        Assert-NoPending
        if ($Job.action -in @('Backup','Restore')) { Assert-AgentClosed $Job.agent }
        $session = Select-Session $Job $Job.action
        switch ($Job.action) {
            Backup {
                $config = Read-Config
                if ($config.syncConfig -ne 'disabled') { throw '대화만 백업하려면 ctxhop config.json의 syncConfig가 disabled여야 합니다. 현재 설정은 유지했습니다.' }
                Assert-AgentClosed $Job.agent
                Invoke-Ctx @('push',$session.nativeId)
                return @{ message='백업 완료. Google Drive 업로드 완료를 직접 확인하세요.' }
            }
            Preview {
                $preview = Invoke-Ctx @('resume','--preview','--json','--agent',$Job.agent,'--no-workspace-context','--no-environment',$session.remoteId) -Json
                Assert-Preview $preview $Job.agent $session.nativeId
                return @{ preview=$preview; message='미리보기 완료. 확인 후 복원할 수 있습니다.' }
            }
            Restore {
                # 실행 직전에도 미리보기를 다시 검사하여 과거 설정/로컬 충돌을 반영한다.
                $preview = Invoke-Ctx @('resume','--preview','--json','--agent',$Job.agent,'--no-workspace-context','--no-environment',$session.remoteId) -Json
                Assert-Preview $preview $Job.agent $session.nativeId
                Assert-AgentClosed $Job.agent
                $journal=Begin-Restore $Job
                $restored = Invoke-Ctx @('resume','--json','--agent',$Job.agent,'--no-workspace-context','--no-environment',$session.remoteId) -Json
                if ($restored.agent -ne $Job.agent -or $restored.session -ne $session.nativeId) { throw '복원 결과의 에이전트 또는 세션 ID가 선택과 다릅니다. pending 복구 기록을 유지했습니다.' }
                if ($restored.environmentSkipped -isnot [bool] -or $restored.environmentSkipped -ne $true) { throw '환경 설정 적용 차단을 확인하지 못했습니다. pending 복구 기록을 유지했습니다.' }
                Assert-NativeId $restored.session
                Complete-Restore $journal $Job
                return @{ restored=$restored; message='복원 완료. 대화 열기를 누르면 이어갈 수 있습니다.' }
            }
            Open { Start-Agent $Job.agent $session.nativeId $Job.projectPath; return @{ message='에이전트 대화 종료' } }
        }
    } finally { Pop-Location }
}
function Get-OperationMutexName { return 'Local\CtxHopGUI-operation' }
function Invoke-Job([object]$Job) {
    $mutex=[Threading.Mutex]::new($false,(Get-OperationMutexName))
    $held=$false
    try {
        try { $held=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held=$true }
        if (-not $held) { throw '다른 CtxHop GUI가 작업 중입니다. 해당 작업이 끝나면 다시 실행하세요.' }
        Invoke-JobCore $Job
    } finally { if ($held) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}
if ($LibraryOnly) { return }
try {
    $job = Get-Content -LiteralPath $RequestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "CtxHop: $($job.action) / $($job.agent)" -ForegroundColor Cyan
    Write-Host '암호 입력이 필요하면 이 창에서 입력하세요. 완료 결과는 GUI에 표시됩니다.'
    $data = Invoke-Job $job
    @{ ok=$true; data=$data } | ConvertTo-Json -Depth 35 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
} catch {
    @{ ok=$false; error=$_.Exception.Message } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultFile -Encoding UTF8
    exit 1
}
