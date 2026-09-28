#requires -Version 5.1
# 대화가 작업한 프로젝트 폴더: 폴더 고르기, 파일 목록, 스냅숏(zip) 만들기, 비교, 복원. Worker.ps1이 불러 쓴다.
# 표준 .NET과, 있으면 git만 쓴다. 복원은 파일을 지우지 않고, 바꾸는 파일의 원본을 복구 폴더에 먼저 복사한다.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$script:ProjectAskBytes=200MB          # 이보다 크면 백업 전에 묻는다(압축 전 크기)
$script:ProjectMaxArchiveBytes=1GB     # bundle 전송 한도
$script:ProjectMaxFiles=200000
$script:ProjectMaxBytes=16GB           # 받은 스냅숏을 풀 때의 전체 크기 한도
# Git 저장소가 아닐 때만 빼는 생성 폴더. Git 저장소는 .gitignore를 따른다.
$script:ProjectGeneratedDirs=@('node_modules','.venv','venv','__pycache__','dist','build','.next','target')
# 이름으로 알아보는 비밀 파일. 내용은 검사하지 않는다.
$script:ProjectSecretNames=@('.env','.env.*','*.pem','*.key','*.p12','*.pfx','*.jks','*.keystore','*.kdbx','id_rsa','id_rsa.*','id_dsa','id_dsa.*','id_ecdsa','id_ecdsa.*','id_ed25519','id_ed25519.*','.npmrc','.pypirc','.netrc','_netrc','.git-credentials','*.ppk','credentials.json','token.json','client_secret*.json')

function ConvertTo-ProjectPath([string]$Value) {
    # \\?\ 접두사, / 구분자, 겹친 \를 정리한 전체 경로. 쓸 수 없는 경로면 $null.
    if (-not $Value) { return $null }
    $path=$Value.Replace('/','\')
    if ($path.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)) { $path='\\'+$path.Substring(8) }
    elseif ($path.StartsWith('\\?\')) { $path=$path.Substring(4) }
    $head=if ($path.StartsWith('\\')) {'\\'} else {''}
    $path=$head+[regex]::Replace($path.Substring($head.Length),'\\{2,}','\')
    # 드라이브 전체 경로(X:\…)와 UNC(\\server\share…)만 받는다. C:folder·\folder는 현재 폴더에 따라 뜻이 바뀐다.
    if ($path -notmatch '^([A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)') { return $null }
    try { $full=[IO.Path]::GetFullPath($path) } catch { return $null }
    if ($full.Length -gt 3) { $full=$full.TrimEnd('\') }
    return $full
}
function Test-ProjectInside([string]$Path, [string]$Root) {
    return ($Path -ieq $Root -or $Path.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase))
}
function Get-ProjectIgnoredRoots {
    # 임시 폴더와 에이전트 설정 폴더. 추가 작업 폴더와 폴더 밖 편집에서 뺀다. 설정 폴더는 시작 폴더여도 뺀다(로그인 정보가 있다).
    $settings=@('.claude','.codex','.agents','.ctxhop') | ForEach-Object { ConvertTo-ProjectPath (Join-Path $env:USERPROFILE $_) }
    $temp=@([IO.Path]::GetTempPath(), (Join-Path $env:LOCALAPPDATA 'Temp')) | ForEach-Object { ConvertTo-ProjectPath $_ }
    return [pscustomobject]@{settings=@($settings);temp=@($temp | Select-Object -Unique);all=@(@($settings)+@($temp) | Select-Object -Unique)}
}
function Test-ProjectTooBroad([string]$Path) {
    # 드라이브·공유 루트, 사용자 폴더 자체와 그 위는 프로젝트가 아니다.
    $userRoot=ConvertTo-ProjectPath $env:USERPROFILE
    return ([IO.Path]::GetPathRoot($Path).TrimEnd('\') -ieq $Path.TrimEnd('\') -or (Test-ProjectInside $userRoot $Path))
}
function Test-ProjectUnder([string]$Path, [object[]]$Roots) { return [bool]@($Roots | Where-Object { $_ -and (Test-ProjectInside $Path $_) }).Count }
function Get-ProjectFolders([string]$Start, [string[]]$Cwds, [string[]]$Edits) {
    # 시작 폴더와, 그 밖에서 작업한 폴더(하위 대화·턴마다 바뀐 cwd). 안에 든 폴더는 합치고, 폴더 밖 편집은 목록만 돌려준다.
    $ignored=Get-ProjectIgnoredRoots
    $folders=[Collections.Generic.List[object]]::new(); $skipped=[Collections.Generic.List[object]]::new()
    $first=ConvertTo-ProjectPath $Start
    if ($first) {
        # 임시 폴더 자체도 너무 넓다. 임시 폴더 안의 작업 폴더는 시작 폴더일 때만 올린다.
        $reason=if ((Test-ProjectTooBroad $first) -or $ignored.temp -icontains $first) {'tooBroad'} elseif (Test-ProjectUnder $first $ignored.settings) {'agentSettings'}
        if ($reason) { $skipped.Add([pscustomobject]@{path=$first;reason=$reason}) } else { $folders.Add([pscustomobject]@{path=$first;role='start'}) }
    }
    foreach ($value in @($Cwds)) {
        $path=ConvertTo-ProjectPath $value
        if (-not $path -or (Test-ProjectUnder $path @($folders | ForEach-Object path)) -or (Test-ProjectUnder $path $ignored.all)) { continue }
        if (@($skipped | Where-Object { $_.path -ieq $path }).Count) { continue }
        $reason=if (Test-ProjectTooBroad $path) {'tooBroad'} elseif ($first -and (Test-ProjectInside $first $path)) {'parentOfStart'}
        if ($reason) { $skipped.Add([pscustomobject]@{path=$path;reason=$reason}); continue }
        # 먼저 넣은 추가 폴더가 이 폴더 안이면 이 폴더로 바꾼다.
        $null=$folders.RemoveAll({ param($folder) $folder.role -eq 'extra' -and (Test-ProjectInside $folder.path $path) })
        $folders.Add([pscustomobject]@{path=$path;role='extra'})
    }
    $outside=[Collections.Generic.List[string]]::new()
    foreach ($value in @($Edits)) {
        $path=ConvertTo-ProjectPath $value
        if (-not $path -or $outside -icontains $path -or (Test-ProjectUnder $path @($folders | ForEach-Object path)) -or (Test-ProjectUnder $path $ignored.all)) { continue }
        $outside.Add($path)
    }
    return [pscustomobject]@{folders=$folders.ToArray();skipped=$skipped.ToArray();outside=$outside.ToArray()}
}
function Read-ClaudeWorkData([string[]]$Files) {
    # Claude Code 대화 파일(과 하위 에이전트 파일)의 cwd와, 편집 도구가 절대 경로로 고친 파일. 줄마다 JSON을 풀면 느려서 필요한 줄만 푼다.
    $cwds=[Collections.Generic.List[string]]::new(); $edits=[Collections.Generic.List[string]]::new()
    foreach ($file in $Files) {
        # Claude Code가 쓰는 중일 수 있으므로 쓰기를 막지 않고 읽는다.
        # 열지 못하는 파일(경로가 260자를 넘는 하위 에이전트 파일 등)은 건너뛴다. 백업할 폴더를 덜 찾을 뿐 대화 백업은 막지 않는다.
        try { $reader=[IO.StreamReader]::new((Open-ProjectSource $file),[Text.Encoding]::UTF8) } catch { continue }
        try { while ($null -ne ($line=$reader.ReadLine())) {
            $match=[regex]::Match($line,'"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"')
            if ($match.Success) { $cwd=[regex]::Unescape($match.Groups[1].Value); if (-not $cwds.Contains($cwd)) { $cwds.Add($cwd) } }
            if ($line -notmatch '"name"\s*:\s*"(Edit|Write|MultiEdit|NotebookEdit)"') { continue }
            try { $record=$line | ConvertFrom-Json } catch { continue }
            foreach ($block in @($record.message.content)) {
                if ($block.type -ne 'tool_use' -or $block.name -notin @('Edit','Write','MultiEdit','NotebookEdit')) { continue }
                $path=if ($block.input.file_path) {$block.input.file_path} else {$block.input.notebook_path}
                if ($path -is [string] -and $path -match '^([A-Za-z]:[\\/]|\\\\)' -and -not $edits.Contains($path)) { $edits.Add($path) }
            }
        } } finally { $reader.Dispose() }
    }
    return [pscustomobject]@{cwds=$cwds.ToArray();edits=$edits.ToArray()}
}
$script:ProjectSecretPattern=[regex]::new('^(?:'+(($script:ProjectSecretNames | ForEach-Object { [regex]::Escape($_).Replace('\*','.*') }) -join '|')+')$','IgnoreCase')
function Test-ProjectSecretName([string]$Name) { return $script:ProjectSecretPattern.IsMatch($Name) }
function Test-ProjectEntryPath([string]$Path) {
    # 백업 안의 상대 경로. 드라이브·절대 경로·..·.git·짧은 이름(GIT~1)·장치 이름·Windows가 줄이는 끝 점과 공백·비밀 파일은 거부한다.
    # 백업할 때도 같은 규칙으로 걸러, 올린 파일은 모두 다른 PC에 복원할 수 있게 한다.
    if (-not $Path -or $Path.Length -gt 1024 -or $Path.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0 -or $Path.Contains(':') -or $Path.Contains('/') -or $Path.StartsWith('\')) { return $false }
    foreach ($part in $Path.Split('\')) {
        if (-not $part -or $part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $false }
        # 짧은 이름은 8.3 형태(이름 8자 이하가 ~숫자로 끝나고 확장자 3자 이하)만 막는다. '보고(7_25~7_27).eml' 같은 긴 이름은 통과.
        if ($part -ieq '.git' -or $part -match '^(?=[^.]{1,8}(\.[^.]{0,3})?$)[^.]*~[0-9]+(\.[^.]{0,3})?$' -or $part -match '^(?i)(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9]|CONIN\$|CONOUT\$)(\..*)?$') { return $false }
    }
    return -not (Test-ProjectSecretName ([IO.Path]::GetFileName($Path)))
}
function Test-ProjectLinkFree([string]$Path, [string]$Root, [hashtable]$Cache) {
    # $Root 아래에서 $Path까지의 폴더·파일 중 링크나 정션이 없는지. $Root 자체와 아직 없는 부분은 통과.
    # ponytail: OneDrive 필요 시 다운로드 파일도 재분석 지점이라 여기서 빠진다. 종류(tag)를 가려야 하면 FindFirstFile로 읽는다.
    $current=$Path
    while ($current -and $current -ine $Root -and (Test-ProjectInside $current $Root)) {
        if (-not $Cache.ContainsKey($current)) {
            $Cache[$current]=if ([IO.File]::Exists($current) -or [IO.Directory]::Exists($current)) { [bool]([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) } else { $false }
        }
        if ($Cache[$current]) { return $false }
        $current=[IO.Path]::GetDirectoryName($current)
    }
    return $true
}
function Test-ProjectInRepo([string]$Root) {
    # 이 폴더나 위 폴더에 .git(HEAD가 있는 폴더 또는 worktree·하위 모듈의 파일)이 있으면 Git 저장소 안이다.
    # HEAD가 없는 .git 폴더(지우다 만 시험 저장소 등)는 git도 저장소로 보지 않으므로 폴더를 그냥 돈다.
    for ($dir=$Root; $dir; $dir=[IO.Path]::GetDirectoryName($dir)) { $mark=[IO.Path]::Combine($dir,'.git'); if ([IO.File]::Exists($mark) -or [IO.File]::Exists([IO.Path]::Combine($mark,'HEAD'))) { return $true } }
    return $false
}
function Invoke-ProjectGit([string]$Root) {
    # 저장소 안이면 이 폴더 아래의 추적 파일과 .gitignore에 걸리지 않은 새 파일(폴더 기준 상대 경로), 아니면 $null. 출력은 UTF-8로 읽는다.
    # 저장소인데 git이 없거나 실패하면(소유자 검사 등) 폴더를 그냥 돌면 .gitignore에 걸린 파일까지 올라가므로 멈춘다.
    if (-not (Test-ProjectInRepo $Root)) { return $null }
    $git=Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) { throw (T 'PfGitFailed' $Root 'git') }
    $start=[Diagnostics.ProcessStartInfo]::new($git.Source,'ls-files -z --cached --others --exclude-standard')
    $start.WorkingDirectory=$Root; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true; $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
    $process=[Diagnostics.Process]::Start($start)
    try {
        $output=$process.StandardOutput.ReadToEndAsync(); $errors=$process.StandardError.ReadToEnd(); $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw (T 'PfGitFailed' $Root ((@($errors -split "`r?`n" | Where-Object { $_ }) | Select-Object -First 1) -join '')) }
        return ,[string[]]@($output.Result.Split([char]0) | Where-Object { $_ } | ForEach-Object { $_.Replace('/','\') })
    } finally { $process.Dispose() }
}
function Get-ProjectFileList([string]$Root) {
    # 백업할 파일(상대 경로, 크기). Git 저장소면 git 목록, 아니면 폴더를 직접 돌며 생성 폴더를 뺀다. .git·비밀 파일·링크는 늘 뺀다.
    $cache=@{}; $files=[Collections.Generic.List[object]]::new(); $excluded=[ordered]@{secret=0;generated=0;link=0;unreadable=0;unsafe=0}
    # 폴더 자체나 위 폴더가 링크·정션이면 실제로 읽는 곳을 알 수 없으므로(설정 폴더 별칭 등) 폴더째 뺀다.
    if (-not (Test-ProjectLinkFree $Root ([IO.Path]::GetPathRoot($Root)) $cache)) { throw (T 'PfRootLinked' $Root) }
    $once=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); $kept=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $listed=Invoke-ProjectGit $Root
    $method=if ($null -ne $listed) {'git'} else {'walk'}
    if ($null -eq $listed) {
        $listed=[Collections.Generic.List[string]]::new()
        $stack=[Collections.Generic.Stack[string]]::new(); $stack.Push($Root)
        while ($stack.Count) {
            $dir=$stack.Pop()
            try { $entries=@([IO.DirectoryInfo]::new($dir).GetFileSystemInfos()) } catch { $excluded.unreadable++; continue }
            foreach ($entry in $entries) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { $excluded.link++; continue }
                if ($entry -is [IO.DirectoryInfo]) {
                    if ($entry.Name -ieq '.git') { continue }
                    if ($script:ProjectGeneratedDirs -icontains $entry.Name) { $excluded.generated++; continue }
                    $stack.Push($entry.FullName)
                } else { $listed.Add($entry.FullName.Substring($Root.TrimEnd('\').Length+1)) }
                if ($listed.Count -gt $script:ProjectMaxFiles) { throw (T 'PfTooManyFiles' $Root $script:ProjectMaxFiles) }
            }
        }
    }
    if ($listed.Count -gt $script:ProjectMaxFiles) { throw (T 'PfTooManyFiles' $Root $script:ProjectMaxFiles) }
    [long]$bytes=0
    foreach ($relative in $listed) {
        if ($relative.EndsWith('\')) { continue }   # git이 폴더로 보여 주는 안의 저장소. 하위 모듈처럼 내용은 옮기지 않는다.
        if (-not $once.Add($relative)) { continue }   # 충돌 중인 파일은 git이 단계마다 한 줄씩 보여 준다
        if ($relative.Split('\') -icontains '.git') { continue }
        if (Test-ProjectSecretName ([IO.Path]::GetFileName($relative))) { $excluded.secret++; continue }
        if (-not (Test-ProjectEntryPath $relative)) { $excluded.unsafe++; continue }   # 복원할 때 거부될 이름은 올리지 않는다
        $full=[IO.Path]::Combine($Root,$relative)
        # Windows PowerShell 5.1의 .NET은 260자가 넘는 경로를 열지 못한다. 조용히 빠지지 않게 읽지 못한 파일로 센다.
        if ($full.Length -ge 260) { $excluded.unreadable++; continue }
        if (-not [IO.File]::Exists($full)) { continue }   # git이 추적하지만 지워진 파일, 하위 모듈 폴더
        if (-not (Test-ProjectLinkFree $full $Root $cache)) { $excluded.link++; continue }
        if (-not $kept.Add($relative)) { $excluded.unsafe++; continue }   # 대소문자만 다른 이름은 Windows에서 한 파일이고 복원에서 거부된다
        $size=([IO.FileInfo]::new($full)).Length; $bytes+=$size
        $files.Add([pscustomobject]@{path=$relative;full=$full;size=$size})
    }
    $files.Sort([Comparison[object]]{ param($a,$b) [string]::CompareOrdinal($a.path,$b.path) })
    return [pscustomobject]@{root=$Root;method=$method;files=$files.ToArray();bytes=$bytes;excluded=[pscustomobject]$excluded}
}
function Get-ProjectHex([byte[]]$Bytes) { return [BitConverter]::ToString($Bytes).Replace('-','').ToLowerInvariant() }
function Get-ProjectContentHash([object[]]$Entries) {
    # 파일 경로·크기·SHA-256으로 정한 내용 해시. zip 바이트가 달라도 같은 내용이면 같다. 정렬은 문화권과 무관한 서수 순서.
    $lines=[string[]]@($Entries | ForEach-Object { "$($_.path)`0$($_.size)`0$($_.sha256)`n" })
    [Array]::Sort($lines,[StringComparer]::Ordinal)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return Get-ProjectHex ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lines -join ''))) } finally { $sha.Dispose() }
}
$script:ProjectShare=[IO.FileShare]'ReadWrite, Delete'
function Open-ProjectSource([string]$Path) { return [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$script:ProjectShare) }
function Get-ProjectFileHash([string]$Path, [Security.Cryptography.HashAlgorithm]$Sha) {
    # 파일이 많으면 함수 호출이 해시보다 오래 걸리므로 부르는 쪽이 SHA-256 객체를 넘겨 다시 쓴다.
    $own=-not $Sha; if ($own) { $Sha=[Security.Cryptography.SHA256]::Create() }
    $stream=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$script:ProjectShare)
    try { return [BitConverter]::ToString($Sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() } finally { $stream.Dispose(); if ($own) { $Sha.Dispose() } }
}
function Get-ProjectManifest([object]$List, [long]$Limit=[long]::MaxValue) {
    # 올리기 전에 같은 내용이 이미 백업돼 있는지 보려고 내용 해시만 먼저 구한다. 읽지 못한 파일은 빼고 목록으로 돌려준다.
    # 실제로 읽은 총량이 $Limit를 넘으면 더 읽지 않고 overLimit으로 돌려준다(해시하는 도중 커지는 파일 포함).
    $entries=[Collections.Generic.List[object]]::new(); $unreadable=[Collections.Generic.List[string]]::new(); [long]$total=0
    foreach ($file in $List.files) {
        try { $stream=[IO.FileStream]::new($file.full,[IO.FileMode]::Open,[IO.FileAccess]::Read,$script:ProjectShare) } catch { $unreadable.Add($file.path); continue }
        $sha=[Security.Cryptography.SHA256]::Create()
        try {
            $crypto=[Security.Cryptography.CryptoStream]::new([IO.Stream]::Null,$sha,[Security.Cryptography.CryptoStreamMode]::Write)
            try { $size=Copy-ProjectStream $stream $crypto ($Limit-$total); if ($size -le $Limit-$total) { $crypto.FlushFinalBlock() } } finally { $crypto.Dispose() }
            $total+=$size
            if ($total -gt $Limit) { return [pscustomobject]@{overLimit=$true;bytes=$total} }
            $entries.Add([pscustomobject]@{path=$file.path;size=$size;sha256=(Get-ProjectHex $sha.Hash)})
        } catch { $unreadable.Add($file.path) } finally { $sha.Dispose(); $stream.Dispose() }
    }
    return [pscustomobject]@{hash=(Get-ProjectContentHash $entries.ToArray());files=$entries.Count;unreadable=$unreadable.ToArray()}
}
function Copy-ProjectStream([IO.Stream]$From, [IO.Stream]$To, [long]$Limit) {
    # $Limit 바이트를 넘으면 멈춘다(압축 폭탄·manifest와 다른 항목).
    $buffer=[byte[]]::new(81920); [long]$total=0
    while (($read=$From.Read($buffer,0,$buffer.Length)) -gt 0) {
        $total+=$read
        if ($total -gt $Limit) { return $total }
        $To.Write($buffer,0,$read)
    }
    return $total
}
function New-ProjectSnapshot([object]$List, [string]$ZipPath, [long]$Limit=[long]::MaxValue) {
    # files/<상대 경로>와 manifest.json을 담은 zip. 파일을 넣으면서 해시를 구하므로 manifest는 실제로 넣은 내용과 같다.
    # 실제로 읽은 압축 전 총량이 $Limit를 넘으면 멈추고 overLimit으로 돌려준다. 만들다 만 zip은 부르는 쪽이 지운다.
    $entries=[Collections.Generic.List[object]]::new(); $unreadable=[Collections.Generic.List[string]]::new(); [long]$total=0
    $zip=[IO.Compression.ZipFile]::Open($ZipPath,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $List.files) {
            try { $source=Open-ProjectSource $file.full } catch { $unreadable.Add($file.path); continue }
            $sha=[Security.Cryptography.SHA256]::Create()
            try {
                $entry=$zip.CreateEntry('files/'+$file.path.Replace('\','/'),[IO.Compression.CompressionLevel]::Optimal)
                $crypto=[Security.Cryptography.CryptoStream]::new($entry.Open(),$sha,[Security.Cryptography.CryptoStreamMode]::Write)
                try { $size=Copy-ProjectStream $source $crypto ($Limit-$total); if ($size -le $Limit-$total) { $crypto.FlushFinalBlock() } } finally { $crypto.Dispose() }
                $total+=$size
                if ($total -gt $Limit) { return [pscustomobject]@{overLimit=$true;bytes=$total} }
                $entries.Add([pscustomobject]@{path=$file.path;size=$size;sha256=(Get-ProjectHex $sha.Hash)})
            } finally { $sha.Dispose(); $source.Dispose() }
        }
        $manifest=[ordered]@{version=1;hash=(Get-ProjectContentHash $entries.ToArray());files=$entries.ToArray()}
        $writer=[IO.StreamWriter]::new($zip.CreateEntry('manifest.json').Open(),[Text.UTF8Encoding]::new($false))
        try { $writer.Write((ConvertTo-Json -InputObject $manifest -Depth 5 -Compress)) } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    [long]$bytes=0; foreach ($entry in $entries) { $bytes+=$entry.size }
    return [pscustomobject]@{hash=$manifest.hash;files=$entries.Count;bytes=$bytes;unreadable=$unreadable.ToArray();archiveBytes=([IO.FileInfo]::new($ZipPath)).Length}
}
function Read-ProjectSnapshot([string]$ZipPath) {
    # 받은 스냅숏의 manifest를 검사한다. 항목은 manifest와 정확히 같아야 하고 경로는 모두 안전해야 한다.
    $zip=[IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $item=$zip.GetEntry('manifest.json')
        if (-not $item -or $item.Length -gt 64MB) { throw (T 'PfArchiveInvalid' 'manifest.json') }
        $reader=[IO.StreamReader]::new($item.Open(),[Text.Encoding]::UTF8)
        try { $manifest=$reader.ReadToEnd() | ConvertFrom-Json } catch { throw (T 'PfArchiveInvalid' 'manifest.json') } finally { $reader.Dispose() }
        if ($manifest.version -ne 1 -or $manifest.hash -isnot [string] -or $manifest.files -isnot [array] -or $manifest.files.Count -gt $script:ProjectMaxFiles) { throw (T 'PfArchiveInvalid' 'manifest.json') }
        $files=$manifest.files; $seen=@{}; [long]$bytes=0
        foreach ($file in $files) {
            if ($file.path -isnot [string] -or -not (Test-ProjectEntryPath $file.path)) { throw (T 'PfEntryUnsafe' $file.path) }
            $key=$file.path.ToLowerInvariant()
            if ($seen.ContainsKey($key) -or $file.sha256 -notmatch '^[0-9a-f]{64}$' -or ($file.size -isnot [int] -and $file.size -isnot [long]) -or $file.size -lt 0) { throw (T 'PfArchiveInvalid' $file.path) }
            $seen[$key]=$true; $bytes+=$file.size
            $entry=$zip.GetEntry('files/'+$file.path.Replace('\','/'))
            if (-not $entry -or $entry.Length -ne [long]$file.size) { throw (T 'PfArchiveInvalid' $file.path) }
        }
        if ($bytes -gt $script:ProjectMaxBytes -or $zip.Entries.Count -ne $files.Count+1 -or $manifest.hash -cne (Get-ProjectContentHash $files)) { throw (T 'PfArchiveInvalid' 'manifest.json') }
        return [pscustomobject]@{hash=$manifest.hash;files=$files;bytes=$bytes}
    } finally { $zip.Dispose() }
}
function Compare-ProjectSnapshot([object]$Snapshot, [string]$Target) {
    # 복원하면 새로 생길 파일, 바뀔 파일(원본 보관), 같은 파일, 이 PC에만 있어 그대로 둘 파일의 수.
    $result=[ordered]@{new=0;changed=0;same=0;localOnly=0;changedPaths=[Collections.Generic.List[string]]::new()}
    $known=@{}; $sha=[Security.Cryptography.SHA256]::Create()
    foreach ($file in $Snapshot.files) {
        $known[$file.path.ToLowerInvariant()]=$true
        $full=[IO.Path]::Combine($Target,$file.path)
        if (-not [IO.File]::Exists($full)) { $result.new++ }
        elseif ((Get-ProjectFileHash $full $sha) -eq $file.sha256) { $result.same++ }
        else { $result.changed++; if ($result.changedPaths.Count -lt 20) { $result.changedPaths.Add($file.path) } }
    }
    $sha.Dispose()
    if ([IO.Directory]::Exists($Target)) {
        # 이 PC에만 있는 파일 수는 참고용이라, 세지 못해도(파일이 너무 많음·git 실패) 비교와 복원은 막지 않는다.
        try { foreach ($file in (Get-ProjectFileList $Target).files) { if (-not $known.ContainsKey($file.path.ToLowerInvariant())) { $result.localOnly++ } } } catch { $result.localOnly='?' }
    }
    $result.changedPaths=$result.changedPaths.ToArray()
    return [pscustomobject]$result
}
function Restore-ProjectSnapshot([string]$ZipPath, [string]$Target, [string]$Recovery) {
    # 새 파일은 쓰고, 바뀐 파일은 원본을 $Recovery에 복사한 뒤 덮어쓴다. 지우는 파일은 없다. 쓰기 전에 모든 경로를 검사한다.
    $snapshot=Read-ProjectSnapshot $ZipPath
    $root=ConvertTo-ProjectPath $Target
    $cache=@{}
    if (-not $root -or (Test-ProjectTooBroad $root) -or (Test-ProjectUnder $root (Get-ProjectIgnoredRoots).settings)) { throw (T 'PfTargetUnsafe' $Target) }
    # 복원 폴더 자체나 위 폴더가 링크·정션이면 문자열로 본 경계 밖에 쓸 수 있으므로 거부한다.
    if (-not (Test-ProjectLinkFree $root ([IO.Path]::GetPathRoot($root)) $cache)) { throw (T 'PfTargetUnsafe' $Target) }
    foreach ($file in $snapshot.files) {
        $full=[IO.Path]::GetFullPath((Join-Path $root $file.path))
        if (-not (Test-ProjectInside $full $root) -or $full -ieq $root -or -not (Test-ProjectLinkFree $full $root $cache)) { throw (T 'PfTargetUnsafe' $full) }
    }
    $result=[ordered]@{written=0;backedUp=0;same=0;failed=[Collections.Generic.List[object]]::new();recovery=$Recovery}
    $zip=[IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($file in $snapshot.files) {
            $full=Join-Path $root $file.path
            try {
                $exists=[IO.File]::Exists($full)
                if ($exists -and (Get-ProjectFileHash $full) -eq $file.sha256) { $result.same++; continue }
                # 옆의 임시 파일에 먼저 쓰고 해시가 맞을 때만 원본을 복구 폴더에 복사한 뒤 제자리로 옮긴다.
                $folder=[IO.Path]::GetDirectoryName($full)
                $null=[IO.Directory]::CreateDirectory($folder)
                $part=Join-Path $folder ('.ctxhop-'+[guid]::NewGuid().ToString('N')+'.part')
                $sha=[Security.Cryptography.SHA256]::Create()
                $source=$zip.GetEntry('files/'+$file.path.Replace('\','/')).Open()
                try {
                    $crypto=[Security.Cryptography.CryptoStream]::new([IO.FileStream]::new($part,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None),$sha,[Security.Cryptography.CryptoStreamMode]::Write)
                    try { $size=Copy-ProjectStream $source $crypto ([long]$file.size); $crypto.FlushFinalBlock() } finally { $crypto.Dispose() }
                    if ($size -ne [long]$file.size -or (Get-ProjectHex $sha.Hash) -ne $file.sha256) { throw (T 'PfHashMismatch' $file.path) }
                    if ($exists) {
                        $copy=Join-Path $Recovery $file.path
                        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($copy))
                        [IO.File]::Copy($full,$copy,$false); $result.backedUp++
                        [IO.File]::Replace($part,$full,[NullString]::Value)   # $null은 빈 문자열로 넘어가 실패한다
                    } else { [IO.File]::Move($part,$full) }
                } finally { $source.Dispose(); $sha.Dispose(); if ([IO.File]::Exists($part)) { [IO.File]::Delete($part) } }
                $result.written++
            } catch { $result.failed.Add([pscustomobject]@{path=$file.path;reason=$_.Exception.Message}) }
        }
    } finally { $zip.Dispose() }
    $result.failed=$result.failed.ToArray()
    return [pscustomobject]$result
}
