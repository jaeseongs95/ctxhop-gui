#requires -Version 5.1
[CmdletBinding()]
param([string]$RequestFile, [string]$ResultFile, [switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Strings.ps1')
$script:RestoreBinarySHA256='45186B1017A0F8969DFC27D248351C275ACB0DFEBF21276AD968E03DC84E650B'
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
function Get-Bindings {
    # 등록이 하나도 없으면 ctxhop은 bindings를 빼고 저장하므로 빈 값은 건너뛴다.
    @((Read-Config).projects.bindings | Where-Object { $_ -and $_.localRoot })
}
function Normalize-ProjectPath([string]$Value) {
    $full=[IO.Path]::GetFullPath($Value)
    if ($full.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)) { $full='\\'+$full.Substring(8) }
    elseif ($full.StartsWith('\\?\')) { $full=$full.Substring(4) }
    return $full.TrimEnd('\')
}
function Get-StoreRealPath([string]$Path) {
    # 정션·심볼릭 링크·subst 드라이브를 모두 따라간 실제 위치. 같은 폴더를 다른 이름으로 가리키는지 확인할 때 쓴다.
    # Resolve는 읽기 권한 없이 폴더도 열 수 있게 연다(FILE_FLAG_BACKUP_SEMANTICS).
    # IsLink는 다른 곳을 가리키는 재분석 지점(정션, 심볼릭 링크)만 링크로 본다. OneDrive 자리표시자 같은 다른 재분석 지점은 링크가 아니다.
    if (-not ('CtxHopStorePath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class CtxHopStorePath {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder buffer, uint size, uint flags);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct FindData {
        public uint Attributes, Created1, Created2, Accessed1, Accessed2, Written1, Written2, SizeHigh, SizeLow, Tag, Reserved;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string ShortName;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr FindFirstFileW(string name, out FindData data);
    [DllImport("kernel32.dll")]
    static extern bool FindClose(IntPtr handle);
    public static string Resolve(string path) {
        using (SafeFileHandle handle = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception();
            StringBuilder buffer = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0 || length >= buffer.Capacity) throw new Win32Exception();
            return buffer.ToString();
        }
    }
    public static bool IsLink(string path) {
        FindData data;
        IntPtr handle = FindFirstFileW(path, out data);
        if (handle == new IntPtr(-1)) throw new Win32Exception();
        FindClose(handle);
        return (data.Attributes & 0x400) != 0 && (data.Tag & 0x20000000) != 0;
    }
}
'@
    }
    try { return Normalize-ProjectPath ([CtxHopStorePath]::Resolve($Path)) }
    catch { throw (T 'CwMoveStoreResolve' $Path $_.Exception.GetBaseException().Message) }
}
function Test-StoreOverlap([string]$Left, [string]$Right) {
    # 같은 폴더이거나 한쪽이 다른 쪽 안에 있는지. 두 값 모두 실제 위치여야 한다.
    $l = $Left.TrimEnd('\') + '\'; $r = $Right.TrimEnd('\') + '\'
    return $l.StartsWith($r, [StringComparison]::OrdinalIgnoreCase) -or $r.StartsWith($l, [StringComparison]::OrdinalIgnoreCase)
}
function Assert-StoreLinkFree([string]$Root) {
    # 복사는 저장소 안의 파일만 다뤄야 하므로 폴더 자체나 그 안에 링크·정션이 있으면 아무것도 복사하지 않는다.
    # ponytail: 검사한 뒤 복사가 끝나기 전에 누군가 링크를 새로 만드는 경우는 막지 않는다.
    $stack = [Collections.Generic.Stack[IO.FileSystemInfo]]::new()
    $top = [IO.DirectoryInfo]::new($Root)
    if ([int]$top.Attributes -ne -1) { $stack.Push($top) }
    while ($stack.Count) {
        $item = $stack.Pop()
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and [CtxHopStorePath]::IsLink($item.FullName)) { throw (T 'CwMoveStoreLinked' $item.FullName) }
        if ($item.Attributes -band [IO.FileAttributes]::Directory) { foreach ($child in ([IO.DirectoryInfo]$item).EnumerateFileSystemInfos()) { $stack.Push($child) } }
    }
}
function Get-CtxFailureReason([string]$Command, [datetimeoffset]$Since) {
    # ctxhop은 실패 이유를 작업 창에만 쓰고 창은 바로 닫히므로, 같은 명령이 남긴 로그 줄에서 이유를 읽는다.
    # ponytail: 오늘 날짜 로그만 본다. 자정을 넘긴 작업은 종료 코드만 보인다.
    # ponytail: 같은 시각에 다른 ctxhop(예: hook의 push)이 같은 명령으로 실패하면 그 이유가 붙을 수 있다.
    $file = Join-Path (Get-ConfigRoot) ('logs\ctxhop-{0}.log' -f $Since.LocalDateTime.ToString('yyyy-MM-dd'))
    # 이유는 덧붙이는 정보일 뿐이므로, 로그가 없거나 다른 ctxhop이 쓰는 중이라 못 읽으면 종료 코드만 보인다.
    try { $lines = @(Get-Content -LiteralPath $file -Encoding UTF8 -ErrorAction Stop) } catch { return '' }
    $reason = ''
    foreach ($line in $lines) {
        # 공백이 없는 오류 값은 따옴표 없이 적힌다.
        $match = [regex]::Match($line, '^time=(\S+) level=ERROR msg=command_finished command=(\S+) result=failed .*? error=(?:"(.*)"|(\S+))$')
        $at = [datetimeoffset]::MinValue
        if ($match.Success -and $match.Groups[2].Value -eq $Command -and [datetimeoffset]::TryParse($match.Groups[1].Value, [ref]$at) -and $at -ge $Since) {
            $reason = if (-not $match.Groups[3].Success) { $match.Groups[4].Value } else { try { [regex]::Unescape($match.Groups[3].Value) } catch { $match.Groups[3].Value } }
        }
    }
    return $reason
}
function Invoke-Ctx([string[]]$Arguments, [switch]$Json) {
    $exe = Find-Executable 'ctxhop'
    # 로그 시각은 밀리초까지만 적히므로 시작 시각도 밀리초로 자른다.
    $since = [datetimeoffset]::FromUnixTimeMilliseconds([datetimeoffset]::Now.ToUnixTimeMilliseconds())
    # ctxhop은 UTF-8로 출력한다. PowerShell 5.1은 콘솔 코드 페이지(한국어 Windows의 새 창은 949)로 읽어 한글이 깨지므로 호출하는 동안만 UTF-8로 읽는다.
    $encoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    try { if ($Json) { $output = & $exe @Arguments } else { & $exe @Arguments | Out-Host } }
    finally { [Console]::OutputEncoding = $encoding }
    if ($LASTEXITCODE -ne 0) {
        $message = T 'CwCtxFailed' $Arguments[0] $LASTEXITCODE
        $reason = Get-CtxFailureReason $Arguments[0] $since
        if ($reason) { $message += "`r`n" + $reason }
        throw $message
    }
    if ($Json) { return ($output -join "`n" | ConvertFrom-Json) }
}
function Copy-StoreFiles([string]$From, [string]$To) {
    # 옛 저장소 파일 중 새 폴더에 없는 것만 복사한다(다른 PC가 먼저 옮겼거나 Drive가 일부만 받았을 때도 같은 동작).
    # 같은 이름인데 내용이 다른 파일이 하나라도 있으면 아무것도 복사하지 않는다. 파일마다 옆의 임시 파일에 복사하고 해시가 같을 때만 제자리로 옮긴다.
    $plan=@(); $same=0; $conflicts=@()
    if ([IO.Directory]::Exists($From)) {
        foreach ($file in [IO.Directory]::EnumerateFiles($From,'*','AllDirectories')) {
            $relative=$file.Substring($From.Length).TrimStart('\')
            $target=Join-Path $To $relative
            if (-not [IO.File]::Exists($target)) { $plan+=,@($file,$target,$relative); continue }
            if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) { $same++ } else { $conflicts+=$relative }
        }
    }
    if ($conflicts.Count) { throw (T 'CwMoveStoreConflict' $conflicts.Count (@($conflicts | Select-Object -First 5) -join ', ')) }
    foreach ($item in $plan) {
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($item[1]))
        $part="$($item[1]).ctxhop-$([guid]::NewGuid().ToString('N')).part"
        try {
            [IO.File]::Copy($item[0],$part,$false)
            if ((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $item[0] -Algorithm SHA256).Hash) { throw (T 'CwMoveStoreCopyMismatch' $item[2]) }
            [IO.File]::Move($part,$item[1])
        } finally { if ([IO.File]::Exists($part)) { [IO.File]::Delete($part) } }
    }
    return @{copied=$plan.Count; same=$same}
}
function Assert-Project([object]$Job) {
    if (-not $Job.projectPath -or -not (Test-Path -LiteralPath $Job.projectPath -PathType Container)) { throw (T 'CwSelectProjectFolder') }
    $path = Normalize-ProjectPath (Resolve-Path -LiteralPath $Job.projectPath).Path
    $binding = @(Get-Bindings | Where-Object { (Normalize-ProjectPath $_.localRoot) -eq $path })
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
    if ($running.Count) { throw (T 'CwAgentRunning' $Agent (($running | ForEach-Object { "$($_.Name) (PID $($_.ProcessId))" }) -join ', ')) }
}
function Assert-NoBindingOverlap([string]$Path, [string]$Identity) {
    # ctxhop은 상위·하위 폴더가 서로 다른 공통 이름으로 등록되면 그 안의 목록·등록을 모두 거부하므로 등록 전에 막는다.
    # 같은 폴더를 다른 이름으로 다시 등록하는 경우는 ctxhop이 직접 거부한다.
    $path = Normalize-ProjectPath $Path
    foreach ($binding in @(Get-Bindings)) {
        $root = Normalize-ProjectPath $binding.localRoot
        if ($binding.identity -cne $Identity -and ($path.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase) -or $root.StartsWith("$path\", [StringComparison]::OrdinalIgnoreCase))) {
            throw (T 'CwBindingOverlap' $binding.localRoot $binding.identity)
        }
    }
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
function Test-CompletedTwin([string]$Pending) {
    # Complete-Restore는 completed를 먼저 옮기고 pending을 지운다. 둘이 함께 있으면 pending을 지우기 직전에 멈춘 것이다.
    # completed를 읽을 수 있고 같은 작업(operationId·대화·시작 시각)일 때만 참이다.
    $completed=$Pending.Replace('.pending.json','.completed.json')
    if (-not [IO.File]::Exists($completed)) { return $false }
    try { $a=Get-Content -LiteralPath $Pending -Raw -Encoding UTF8 | ConvertFrom-Json; $b=Get-Content -LiteralPath $completed -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $false }
    return ([string]$a.operationId -ceq [string]$b.operationId -and [string]$a.nativeId -ceq [string]$b.nativeId -and [string]$a.started -ceq [string]$b.started -and [bool]$b.restoredSha256)
}
function Assert-NoPending {
    $root=Get-JournalRoot
    if (Test-Path -LiteralPath $root) {
        foreach ($pending in @(Get-ChildItem -LiteralPath $root -Filter '*.pending.json' -File)) {
            # 완료 기록이 이미 있는 pending은 지우기만 남은 것이므로 마무리한다. 그 밖의 pending은 백업·복원을 막는다.
            if (Test-CompletedTwin $pending.FullName) { Remove-Item -LiteralPath $pending.FullName; continue }
            throw (T 'CwPendingRestore' $root)
        }
    }
}
function Begin-Restore([object]$Job) {
    $root=Get-JournalRoot
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    # Worker가 준 작업 ID로 기록 이름을 정한다(S3 명세 2.1절). 같은 이름의 기록이 있으면 아무것도 쓰지 않고 멈춘다.
    $name=if ($Job.operationId) { [string]$Job.operationId } else { [guid]::NewGuid().ToString('N') }
    if ($name -cnotmatch '^[0-9a-f]{32}$') { throw (T 'WkOperationIdInvalid') }
    if (@(Get-ChildItem -LiteralPath $root -Filter "$name.*").Count) { throw (T 'CwJournalExists' $name) }
    $backups=@()
    foreach ($file in @(Get-NativeFiles $Job.agent $Job.nativeId)) {
        $hash=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $backup=Join-Path $root "$name.original.jsonl"
        Copy-Item -LiteralPath $file.FullName -Destination $backup
        if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ne $hash -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $hash) { throw (T 'CwBackupIntegrityFailed') }
        $backups+=@{ original=$file.FullName; backup=$backup; sha256=$hash }
    }
    $journal=Join-Path $root "$name.pending.json"
    # Claude 세션 옆 폴더(subagents·tool-results)에서 복원이 바꾸는 파일의 원본은 ctxhop이 이 폴더에 남긴다(바뀐 파일이 있을 때만 생김).
    $companion=if ($Job.agent -eq 'claude-code') {Join-Path $root "$name.companion"} else {$null}
    $record=[ordered]@{ agent=$Job.agent; nativeId=$Job.nativeId; remoteId=$Job.remoteId; projectPath=$Job.projectPath; originals=$backups; companionBackup=$companion; started=(Get-Date).ToString('o'); operationId=$name }
    # 되돌리기에 쓸 쓰기 전 상태(S3 명세 3.4절): 대화 파일 하나의 원본 사본과 해시, 옆 폴더 파일 목록과 해시. 옆 폴더 사본은 ctxhop이 companion에 남긴다.
    if ($Job.agent -eq 'claude-code' -and $backups.Count -le 1) {
        $conversation=if ($backups.Count) { [ordered]@{target=$backups[0].original;before=$backups[0].sha256.ToLowerInvariant();beforeCopy=$backups[0].backup} } else { [ordered]@{target=$null;before='absent';beforeCopy=$null} }
        $sideRoot=if ($backups.Count) { Join-Path ([IO.Path]::GetDirectoryName($backups[0].original)) $Job.nativeId } else { $null }
        $sideFiles=@(if ($sideRoot -and [IO.Directory]::Exists($sideRoot)) { foreach ($file in [IO.Directory]::GetFiles($sideRoot,'*','AllDirectories')) { [ordered]@{path=$file.Substring($sideRoot.Length+1);sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()} } })
        $record.prepared=[ordered]@{conversation=$conversation;sidecar=[ordered]@{root=$sideRoot;files=$sideFiles};sidecarBackup=$companion}
    }
    $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record | ConvertTo-Json -Depth 8))
    $stream=[IO.FileStream]::new($journal,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    return $journal
}
function Assert-Sidecar([object]$Sidecar) {
    if (-not $Sidecar -or $Sidecar.state -notin @('restored','absent')) { throw (T 'CwSidecarInvalid') }
    foreach ($field in @('files','written','unchanged','backedUp')) { if (($Sidecar.$field -isnot [int] -and $Sidecar.$field -isnot [long]) -or $Sidecar.$field -lt 0) { throw (T 'CwSidecarInvalid') } }
}
function Complete-Restore([string]$Journal, [object]$Job, [object]$Sidecar=$null) {
    $null=Assert-NativeMapping $Job.agent $Job.nativeId $Job.projectPath -Required
    $record=Get-Content -LiteralPath $Journal -Raw -Encoding UTF8 | ConvertFrom-Json
    $file=@(Get-NativeFiles $Job.agent $Job.nativeId)[0]
    $record | Add-Member -NotePropertyName restoredSha256 -NotePropertyValue (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    if ($Sidecar) { $record | Add-Member -NotePropertyName sidecar -NotePropertyValue $Sidecar }
    # completed는 임시 파일에 쓴 뒤 옮긴다(이미 있으면 실패). 그다음 pending을 지운다. 사이에서 멈추면 Assert-NoPending이 마무리한다.
    $completed=$Journal.Replace('.pending.json','.completed.json')
    $temp="$completed.tmp"
    $record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temp -Encoding UTF8
    [IO.File]::Move($temp,$completed)
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
    if ($version -notin @('ctxhop 0.2.0','ctxhop 0.2.0-gui.1','ctxhop 0.2.0-gui.2','ctxhop 0.2.0-gui.3')) { throw (T 'CwCtxVersionUnsupported' $version) }
}
function Assert-RestoreRuntime {
    $exe=Find-Executable 'ctxhop'
    $bundled=Join-Path $PSScriptRoot 'bin\ctxhop.exe'
    if ([IO.Path]::GetFullPath($exe) -ne [IO.Path]::GetFullPath($bundled)) { throw (T 'CwRestoreNeedsBundled') }
    if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -ne $script:RestoreBinarySHA256) { throw (T 'CwRestoreHashMismatch') }
    if ((Get-CtxVersion) -ne 'ctxhop 0.2.0-gui.3') { throw (T 'CwRestoreVersionUnverified') }
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
        MoveStore {
            # 저장소 폴더를 바꾼다. 옛 저장소를 새 폴더로 복사한 뒤, ctxhop이 새 폴더에서 같은 연결과 이 PC의 권한을 확인해야만 연결이 바뀐다.
            $config = Read-Config
            if ($config.remote.type -ne 'dir') { throw (T 'CwMoveStoreNotDir') }
            if (-not $Job.store -or -not (Test-Path -LiteralPath $Job.store -PathType Container)) { throw (T 'CwStoreFolderMissing') }
            $old = Normalize-ProjectPath ([string]$config.remote.path)
            $new = Normalize-ProjectPath ([string]$Job.store)
            # 정션이나 드라이브 별칭으로 같은 폴더를 다른 이름으로 고를 수 있으므로, 복사하기 전에 실제 위치끼리 비교하고 링크가 없는지 확인한다.
            $newReal = Get-StoreRealPath $new
            $oldReal = if ([IO.Directory]::Exists($old)) { Get-StoreRealPath $old } else { $old }
            if ($newReal -ieq $oldReal) { throw (T 'CwMoveStoreSame' $old) }
            if (Test-StoreOverlap $newReal $oldReal) { throw (T 'CwMoveStoreNested') }
            if (Test-StoreOverlap $newReal (Get-StoreRealPath (Get-ConfigRoot))) { throw (T 'CwMoveStoreConfig' (Get-ConfigRoot)) }
            Assert-StoreLinkFree (Join-Path $oldReal 'v1'); Assert-StoreLinkFree (Join-Path $newReal 'v1')
            $copy = Copy-StoreFiles (Join-Path $oldReal 'v1') (Join-Path $newReal 'v1')
            Invoke-Ctx @('remote','relocate','--path',$new)
            $moved = [string](Read-Config).remote.path
            if ((Normalize-ProjectPath $moved) -ine $new) { throw (T 'CwMoveStoreNotApplied') }
            return @{ store=$moved; copied=$copy.copied; same=$copy.same; message=(T 'CwMoveStoreDone' $moved $copy.copied $copy.same) }
        }
        Bind {
            $null = Read-Config
            if (-not (Test-Path -LiteralPath $Job.projectPath -PathType Container) -or -not $Job.identity) { throw (T 'CwBindInputRequired') }
            Assert-NoBindingOverlap $Job.projectPath $Job.identity
            Invoke-Ctx @('project','bind','--path',$Job.projectPath,'--identity',$Job.identity)
            return @{ message=(T 'CwBindDone') }
        }
        Unbind {
            $null = Read-Config
            if (-not $Job.projectPath -or -not $Job.identity) { throw (T 'CwBindInputRequired') }
            $arguments = @('project','unbind','--identity',$Job.identity)
            # ctxhop은 --path의 폴더를 직접 확인하므로, 지워진 폴더는 이름만으로 해제한다.
            # 이름만 주면 그 이름의 등록이 모두 풀리므로, 이 경로의 등록 하나뿐일 때만 허용한다.
            if (Test-Path -LiteralPath $Job.projectPath -PathType Container) { $arguments += @('--path',$Job.projectPath) }
            else {
                $same = @(Get-Bindings | Where-Object { $_.identity -ceq $Job.identity })
                if ($same.Count -ne 1 -or (Normalize-ProjectPath $same[0].localRoot) -ne (Normalize-ProjectPath $Job.projectPath)) { throw (T 'CwUnbindMissingFolder') }
            }
            Invoke-Ctx $arguments
            return @{ message=(T 'CwUnbindDone') }
        }
        PassphraseChange {
            $null = Read-Config
            Write-Host (T 'CwPassphraseChangeHint')
            Invoke-Ctx @('passphrase','change')
            return @{ message=(T 'CwPassphraseChanged') }
        }
        PassphraseReset {
            $null = Read-Config
            Write-Host (T 'CwPassphraseResetHint')
            Invoke-Ctx @('passphrase','reset')
            return @{ message=(T 'CwPassphraseResetDone') }
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
                if ($config.syncConfig -ne 'disabled') { throw (T 'CwSyncConfigNotDisabled' (Join-Path (Get-ConfigRoot) 'config.json')) }
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
                $arguments=@('resume','--json','--agent',$Job.agent,'--no-workspace-context','--no-environment')
                if ($Job.agent -eq 'claude-code') { $arguments+=@('--sidecar-backup',$journal.Replace('.pending.json','.companion')) }
                $restored = Invoke-Ctx ($arguments+@($session.remoteId)) -Json
                if ($restored.agent -ne $Job.agent -or $restored.session -ne $session.nativeId) { throw (T 'CwRestoredMismatch') }
                if ($restored.environmentSkipped -isnot [bool] -or $restored.environmentSkipped -ne $true) { throw (T 'CwRestoredEnvNotSkipped') }
                Assert-NativeId $restored.session
                $message=T 'CwRestoreDone'
                if ($Job.agent -eq 'claude-code') {
                    # 하위 에이전트 대화·도구 결과 폴더도 함께 돌아왔는지 확인한다. 이전 판으로 올린 백업에는 없다.
                    Assert-Sidecar $restored.sidecar
                    $message+=if ($restored.sidecar.state -eq 'absent') {T 'CwSidecarAbsent'} else {T 'CwSidecarRestored' $restored.sidecar.files $restored.sidecar.written $restored.sidecar.backedUp}
                }
                Complete-Restore $journal $Job $restored.sidecar
                return @{ restored=$restored; message=$message }
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
