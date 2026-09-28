#requires -Version 5.1
# 프로젝트 폴더 백업 라이브러리(ProjectFiles.ps1)를 임시 폴더의 합성 프로젝트로 확인한다. 실제 사용자 폴더와 저장소는 읽거나 쓰지 않는다.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Strings.ps1')
. (Join-Path $PSScriptRoot 'ProjectFiles.ps1')
$script:Checks=0
function Assert([bool]$Value,[string]$Message) { $script:Checks++; if (-not $Value) { throw "ASSERT: $Message" } }
function Throws([scriptblock]$Body,[string]$Pattern) {
    $errorRecord=$null; try { & $Body | Out-Null } catch { $errorRecord=$_ }
    Assert ($null -ne $errorRecord) "operation must fail: $Body"
    Assert ($errorRecord.Exception.Message -match $Pattern) "expected $Pattern, got $($errorRecord.Exception.Message)"
}
function Write-Fixture([string]$Root,[hashtable]$Files) {
    foreach ($name in $Files.Keys) {
        $path=Join-Path $Root $name
        $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        [IO.File]::WriteAllText($path,$Files[$name],[Text.UTF8Encoding]::new($false))
    }
}
function Get-Sha([string]$Text) { $sha=[Security.Cryptography.SHA256]::Create(); try { Get-ProjectHex ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) } finally { $sha.Dispose() } }
function New-TestZip([string]$Path,[hashtable]$Files,[scriptblock]$Tamper) {
    # 합성 스냅숏. $Tamper가 manifest를 고친 뒤 hash를 다시 계산하지 않으면 hash 불일치가 된다.
    $entries=@($Files.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{path=$_;size=[Text.Encoding]::UTF8.GetByteCount($Files[$_]);sha256=(Get-Sha $Files[$_])} })
    $manifest=[pscustomobject]@{version=1;hash=(Get-ProjectContentHash $entries);files=$entries}
    $extra=@{}
    if ($Tamper) { & $Tamper $manifest $extra }
    $zip=[IO.Compression.ZipFile]::Open($Path,'Create')
    try {
        foreach ($name in $Files.Keys) {
            $writer=[IO.StreamWriter]::new($zip.CreateEntry('files/'+$name.Replace('\','/')).Open(),[Text.UTF8Encoding]::new($false))
            try { $writer.Write($(if ($extra.ContainsKey($name)) {$extra[$name]} else {$Files[$name]})) } finally { $writer.Dispose() }
        }
        foreach ($name in @($extra.Keys | Where-Object { -not $Files.ContainsKey($_) })) {
            $writer=[IO.StreamWriter]::new($zip.CreateEntry($name).Open()); try { $writer.Write($extra[$name]) } finally { $writer.Dispose() }
        }
        $writer=[IO.StreamWriter]::new($zip.CreateEntry('manifest.json').Open(),[Text.UTF8Encoding]::new($false))
        try { $writer.Write((ConvertTo-Json -InputObject $manifest -Depth 5 -Compress)) } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    return $Path
}
function Read-Text([string]$Path) { if ([IO.File]::Exists($Path)) { [IO.File]::ReadAllText($Path) } }   # 없는 파일은 $null(검사가 예외 대신 ASSERT로 실패하도록)
function Get-TreeText([string]$Root) {
    # 폴더 안 모든 파일의 상대 경로와 내용(비교용).
    (@(Get-ChildItem -LiteralPath $Root -Recurse -Force -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($Root.Length)+'='+[IO.File]::ReadAllText($_.FullName) })) -join "`n"
}

$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('CtxHop-vnext-project-'+[guid]::NewGuid().ToString('N'))
$oldProfile=$env:USERPROFILE; $oldLocal=$env:LOCALAPPDATA; $oldCeiling=$env:GIT_CEILING_DIRECTORIES
try {
    $null=New-Item -ItemType Directory -Path $testDirectory
    $testDirectory=(Resolve-Path -LiteralPath $testDirectory).ProviderPath
    # 임시 폴더 위쪽의 저장소를 git이 찾지 않게 한다.
    $env:GIT_CEILING_DIRECTORIES=$testDirectory

    # 1) 경로 정리: \\?\, /, 겹친 \, 끝 \를 정리하고 상대 경로는 버린다.
    Assert ((ConvertTo-ProjectPath '\\?\D:\codex\\보고서\') -eq 'D:\codex\보고서') '\\?\ prefix and doubled backslashes are normalized'
    Assert ((ConvertTo-ProjectPath '\\?\UNC\server\share\x') -eq '\\server\share\x') 'long UNC prefix becomes a UNC path'
    Assert ((ConvertTo-ProjectPath 'D:/a/b/') -eq 'D:\a\b') 'forward slashes are normalized'
    Assert ((ConvertTo-ProjectPath 'D:\') -eq 'D:\') 'drive root keeps its backslash'
    Assert ($null -eq (ConvertTo-ProjectPath 'relative\x') -and $null -eq (ConvertTo-ProjectPath '\rooted') -and $null -eq (ConvertTo-ProjectPath '')) 'relative and drive-relative paths are rejected'
    Assert ($null -eq (ConvertTo-ProjectPath 'C:relative-folder') -and $null -eq (ConvertTo-ProjectPath 'C:') -and $null -eq (ConvertTo-ProjectPath '\\server')) 'drive-relative paths and a UNC path without a share are rejected'
    Assert ((ConvertTo-ProjectPath '\\server\share') -eq '\\server\share') 'a UNC share path is kept'

    # 2) 폴더 고르기: 안의 폴더는 합치고, 넓은 폴더·시작 폴더의 부모·임시·설정 폴더는 뺀다. 폴더 밖 편집은 목록만.
    $env:USERPROFILE='C:\Users\fixture'; $env:LOCALAPPDATA='C:\Users\fixture\AppData\Local'
    $picked=Get-ProjectFolders 'D:\work\proj' @('\\?\D:\work\proj\sub','E:\other\child','e:\OTHER','D:\','D:\','D:\work','C:\Users\fixture','C:\Users\fixture\.claude\projects\x','C:\Users\fixture\AppData\Local\Temp\t','F:\tools\a','F:\tools\b') @('D:\work\proj\a.txt','G:\notes\n.md','g:\NOTES\n.md','C:\Users\fixture\.codex\config.toml','C:\Users\fixture\AppData\Local\Temp\x.txt','E:\other\child\y.txt','H:\\double\\z.txt')
    Assert ((@($picked.folders | ForEach-Object { "$($_.role):$($_.path)" }) -join '|') -eq 'start:D:\work\proj|extra:e:\OTHER|extra:F:\tools\a|extra:F:\tools\b') "folders: $(@($picked.folders | ForEach-Object path) -join '|')"
    Assert ((@($picked.skipped | ForEach-Object { "$($_.reason):$($_.path)" }) -join '|') -eq 'tooBroad:D:\|parentOfStart:D:\work|tooBroad:C:\Users\fixture') "skipped: $(@($picked.skipped | ForEach-Object path) -join '|')"
    Assert (($picked.outside -join '|') -eq 'G:\notes\n.md|H:\double\z.txt') "outside edits: $($picked.outside -join '|')"
    $settings=Get-ProjectFolders 'C:\Users\fixture\.claude' @() @()
    Assert ($settings.folders.Count -eq 0 -and $settings.skipped[0].reason -eq 'agentSettings') 'an agent settings folder is never a project even as the start folder'
    $broad=Get-ProjectFolders 'C:\Users\fixture' @() @()
    Assert ($broad.folders.Count -eq 0 -and $broad.skipped[0].reason -eq 'tooBroad') 'the user profile itself is too broad'
    $env:USERPROFILE=$oldProfile; $env:LOCALAPPDATA=$oldLocal
    $tempRoot=Get-ProjectFolders ([IO.Path]::GetTempPath()) @() @()
    Assert ($tempRoot.folders.Count -eq 0 -and $tempRoot.skipped[0].reason -eq 'tooBroad') 'the temp folder itself is too broad even as the start folder'
    $inTemp=Get-ProjectFolders $testDirectory @() @()
    Assert ($inTemp.folders.Count -eq 1 -and $inTemp.folders[0].path -eq $testDirectory -and $inTemp.folders[0].role -eq 'start') 'a project folder inside temp is kept as the start folder'

    # 3) Claude Code 대화 파일: cwd와 편집 도구의 절대 경로만 모은다.
    $jsonl=Join-Path $testDirectory 'session.jsonl'
    [IO.File]::WriteAllLines($jsonl,[string[]]@(
        '{"type":"user","cwd":"D:\\codex\\\ubcf4\uace0\uc11c","message":{"content":"hi"}}',
        '{"type":"assistant","cwd":"D:\\codex\\보고서","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"D:\\codex\\보고서\\a.md"}},{"type":"tool_use","name":"Read","input":{"file_path":"C:\\read-only.txt"}}]}}',
        '{"type":"assistant","cwd":"E:\\side","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"relative.txt"}},{"type":"tool_use","name":"NotebookEdit","input":{"notebook_path":"F:\\nb\\x.ipynb"}}]}}',
        'not json {"cwd":"broken',
        '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"MultiEdit","input":{"file_path":"\\\\server\\share\\m.txt"}}]}}'
    ),[Text.UTF8Encoding]::new($false))
    $work=Read-ClaudeWorkData @($jsonl)
    Assert (($work.cwds -join '|') -eq 'D:\codex\보고서|E:\side') "claude cwds: $($work.cwds -join '|')"
    Assert (($work.edits -join '|') -eq 'D:\codex\보고서\a.md|F:\nb\x.ipynb|\\server\share\m.txt') "claude edits: $($work.edits -join '|')"
    $work=Read-ClaudeWorkData @((Join-Path $testDirectory 'missing.jsonl'),$jsonl)
    Assert (($work.cwds -join '|') -eq 'D:\codex\보고서|E:\side') 'a session file that cannot be opened is skipped, not fatal'

    # 4) 백업 안 경로 검사.
    foreach ($good in @('src\a.txt','한글 폴더\메모.txt','.gitignore','a.b\c','메일\보고(7_25~7_27).eml','2026~2027.txt','a~1.json')) { Assert (Test-ProjectEntryPath $good) "safe path accepted: $good" }
    foreach ($bad in @('','..\x','a\..\b','.\a','C:\x','a:b','\x','a/b','a\\b','.git\config','A\.GIT\hooks\x','GIT~1\config','AB~1.txt','README~1.MD','PROGRA~1\x','CON','nul.txt','a\com1','a.','a \b','.env','sub\.env.local','sub\id_rsa','x.pem','k.KEY','credentials.json','token.json','client_secret_1.json','putty.ppk',('a'*1100))) {
        Assert (-not (Test-ProjectEntryPath $bad)) "unsafe path rejected: $bad"
    }

    # 5) Git이 아닌 폴더: 생성 폴더·.git·비밀 파일·정션을 뺀다.
    $walk=Join-Path $testDirectory 'walk'; $outsideDir=Join-Path $testDirectory 'outside'
    Write-Fixture $walk @{'src\main.py'='print(1)';'한글 폴더\메모.txt'='메모';'README.md'='# r';'.env'='SECRET=1';'config\.env.local'='S=2';'keys\server.pem'='pem';'id_ed25519'='key';'node_modules\x\index.js'='x';'sub\build\out.bin'='b';'sub\.git\config'='[core]'}
    Write-Fixture $outsideDir @{'secret.txt'='outside'}
    $null=New-Item -ItemType Junction -Path (Join-Path $walk 'linked') -Target $outsideDir
    $list=Get-ProjectFileList $walk
    Assert ($list.method -eq 'walk') "non-git folder is walked, got $($list.method)"
    Assert ((@($list.files | ForEach-Object path) -join '|') -eq 'README.md|src\main.py|한글 폴더\메모.txt') "walk files: $(@($list.files | ForEach-Object path) -join '|')"
    # .git 안의 파일은 조용히 빼며 "복원할 수 없는 이름" 수에 넣지 않는다.
    Assert ($list.excluded.secret -eq 4 -and $list.excluded.generated -eq 2 -and $list.excluded.link -eq 1 -and $list.excluded.unsafe -eq 0) "walk exclusions: $($list.excluded | ConvertTo-Json -Compress)"
    Assert ($list.bytes -eq (($list.files | Measure-Object size -Sum).Sum)) 'walk byte total'
    $names=Join-Path $testDirectory 'names'
    Write-Fixture $names @{'메일\보고(7_25~7_27).eml'='mail';'2026~2027.txt'='y';'AB~1.txt'='short';'a.txt'='a'}
    $list=Get-ProjectFileList $names
    Assert ((@($list.files | ForEach-Object path) -join '|') -eq '2026~2027.txt|a.txt|메일\보고(7_25~7_27).eml' -and $list.excluded.unsafe -eq 1) "names that cannot be restored are left out and counted: $(@($list.files | ForEach-Object path) -join '|') $($list.excluded | ConvertTo-Json -Compress)"
    $zipN=Join-Path $testDirectory 'names.zip'; $null=New-ProjectSnapshot $list $zipN
    $restored=Restore-ProjectSnapshot $zipN (Join-Path $testDirectory 'names-restored') (Join-Path $testDirectory 'rec-names')
    Assert ($restored.written -eq 3 -and $restored.failed.Count -eq 0 -and [IO.File]::ReadAllText((Join-Path $testDirectory 'names-restored\메일\보고(7_25~7_27).eml')) -eq 'mail') "every backed-up name restores: $($restored | ConvertTo-Json -Compress)"

    # 6) Git 저장소: .gitignore를 따르고, 생성 폴더 규칙은 쓰지 않으며, 지워진 추적 파일과 비밀 파일은 뺀다. 하위 폴더는 그 폴더 기준.
    $repo=Join-Path $testDirectory 'repo'
    Write-Fixture $repo @{'.gitignore'="ignored.log`nout/`n";'a.txt'='a';'ignored.log'='x';'out\x.bin'='x';'.env'='S=1';'node_modules\keep.js'='k';'sub\s.txt'='s';'한글.txt'='한';'deleted.txt'='d';'AB~1.txt'='short';'보고(7_25~7_27).eml'='mail';'nested\n.txt'='n'}
    $git=(Get-Command git -CommandType Application | Select-Object -First 1).Source
    & $git -C $repo init -q; Assert ($LASTEXITCODE -eq 0) 'git init'
    & $git -C $repo add deleted.txt; Assert ($LASTEXITCODE -eq 0) 'git add'
    # 안의 저장소는 git이 'nested/'로 보여 준다. 내용은 옮기지 않고 이름 규칙 수에도 넣지 않는다.
    & $git -C (Join-Path $repo 'nested') init -q; Assert ($LASTEXITCODE -eq 0) 'nested git init'
    Remove-Item -LiteralPath (Join-Path $repo 'deleted.txt')
    $list=Get-ProjectFileList $repo
    Assert ($list.method -eq 'git') 'git repository uses git ls-files'
    Assert ((@($list.files | ForEach-Object path) -join '|') -eq '.gitignore|a.txt|node_modules\keep.js|sub\s.txt|보고(7_25~7_27).eml|한글.txt' -and $list.excluded.unsafe -eq 1) "git files: $(@($list.files | ForEach-Object path) -join '|')"
    Assert ($list.excluded.secret -eq 1) 'secret file excluded even when git would add it'
    $oldPath=$env:PATH; $env:PATH=''
    try {
        Throws { Get-ProjectFileList $repo } 'Git 저장소'
        Assert ((Get-ProjectFileList $names).method -eq 'walk') 'a folder outside any repository is still walked without git'
    } finally { $env:PATH=$oldPath }
    $broken=Join-Path $testDirectory 'broken'; Write-Fixture $broken @{'.git\HEAD'='nonsense';'a.txt'='a'}
    Throws { Get-ProjectFileList $broken } 'Git 저장소'
    $leftover=Join-Path $testDirectory 'leftover'; Write-Fixture $leftover @{'.git\objects\x'='o';'a.txt'='a'}
    $list=Get-ProjectFileList $leftover
    Assert ($list.method -eq 'walk' -and (@($list.files | ForEach-Object path) -join '|') -eq 'a.txt') 'a .git folder without HEAD is not a repository to git either, so the folder is walked'
    # 충돌이 남은 저장소: git은 충돌 중인 파일을 단계마다 한 줄씩 보여 준다. 한 번만 넣어야 받는 쪽이 복원한다.
    $conflict=Join-Path $testDirectory 'conflict'; Write-Fixture $conflict @{'f.txt'='base';'other.txt'='o'}
    $gitArgs=@('-C',$conflict,'-c','user.name=t','-c','user.email=t@example.invalid','-c','commit.gpgsign=false','-c',"core.hooksPath=$(Join-Path $testDirectory 'no-hooks')")
    & $git -C $conflict init -q; & $git -C $conflict add -A; & $git @gitArgs commit -qm base | Out-Null
    & $git -C $conflict checkout -qb side; [IO.File]::WriteAllText((Join-Path $conflict 'f.txt'),'side'); & $git @gitArgs commit -qam side | Out-Null
    & $git -C $conflict checkout -q -; [IO.File]::WriteAllText((Join-Path $conflict 'f.txt'),'main'); & $git @gitArgs commit -qam main | Out-Null
    & $git @gitArgs merge -q side | Out-Null
    $list=Get-ProjectFileList $conflict
    Assert (@(& $git -C $conflict ls-files -u).Count -ge 2 -and (@($list.files | ForEach-Object path) -join '|') -eq 'f.txt|other.txt' -and $list.excluded.unsafe -eq 0) "a file in a merge conflict is listed once: $(@($list.files | ForEach-Object path) -join '|') $($list.excluded | ConvertTo-Json -Compress)"
    $zipC=Join-Path $testDirectory 'conflict.zip'; $null=New-ProjectSnapshot $list $zipC
    Assert ((Read-ProjectSnapshot $zipC).files.Count -eq 2) 'the snapshot of a repository in a merge conflict can be read back'
    # 대소문자만 다른 이름이 인덱스에 함께 있으면 Windows에서는 한 파일이다. 하나만 넣고 나머지는 복원할 수 없는 이름으로 센다.
    $blob=& $git -C $conflict hash-object -w other.txt; & $git -C $conflict update-index --add --cacheinfo "100644,$blob,OTHER.txt"
    $list=Get-ProjectFileList $conflict
    $zipD=Join-Path $testDirectory 'case.zip'; $null=New-ProjectSnapshot $list $zipD
    Assert ($list.files.Count -eq 2 -and $list.excluded.unsafe -eq 1 -and (Read-ProjectSnapshot $zipD).files.Count -eq 2) "names that differ only in case are kept once: $(@($list.files | ForEach-Object path) -join '|') $($list.excluded | ConvertTo-Json -Compress)"
    $sub=Get-ProjectFileList (Join-Path $repo 'sub')
    Assert ($sub.method -eq 'git' -and (@($sub.files | ForEach-Object path) -join '|') -eq 's.txt') 'a subfolder of a repository lists paths relative to itself'
    # 260자가 넘는 경로는 .NET이 열지 못하므로 조용히 빼지 않고 읽지 못한 파일로 센다.
    $realGit=${function:Invoke-ProjectGit}
    function Invoke-ProjectGit([string]$Root) { return ,[string[]]@('a.txt',(('x'*120)+'\'+('y'*120)+'\long.txt')) }
    try { $long=Get-ProjectFileList $repo } finally { ${function:Invoke-ProjectGit}=$realGit }
    Assert ((@($long.files | ForEach-Object path) -join '|') -eq 'a.txt' -and $long.excluded.unreadable -eq 1) "a path over 260 characters is counted as unreadable: $($long.excluded | ConvertTo-Json -Compress)"

    # 7) 스냅숏: 만들고 읽으면 같은 내용 해시, 미리 구한 해시와 같고, 내용이 바뀌면 해시가 바뀐다.
    $list=Get-ProjectFileList $walk
    $zipA=Join-Path $testDirectory 'a.zip'; $zipB=Join-Path $testDirectory 'b.zip'
    $snapA=New-ProjectSnapshot $list $zipA
    $read=Read-ProjectSnapshot $zipA
    Assert ($snapA.files -eq 3 -and $snapA.hash -match '^[0-9a-f]{64}$' -and $read.hash -eq $snapA.hash -and $read.files.Count -eq 3) 'snapshot round trip keeps the content hash'
    Assert ((Get-ProjectManifest $list).hash -eq $snapA.hash) 'hash-only pass matches the snapshot hash'
    Assert ((New-ProjectSnapshot $list $zipB).hash -eq $snapA.hash) 'same content gives the same hash'
    $files=@($read.files); [array]::Reverse($files)
    Assert ((Get-ProjectContentHash $files) -eq $snapA.hash) 'content hash does not depend on order'
    $empty=Join-Path $testDirectory 'empty'; $null=New-Item -ItemType Directory -Path $empty
    $zipE=Join-Path $testDirectory 'e.zip'
    $null=New-ProjectSnapshot (Get-ProjectFileList $empty) $zipE
    Assert ((Read-ProjectSnapshot $zipE).files.Count -eq 0) 'an empty folder makes a readable empty snapshot'
    [IO.File]::WriteAllText((Join-Path $walk 'README.md'),'# changed')
    Assert ((Get-ProjectManifest (Get-ProjectFileList $walk)).hash -ne $snapA.hash) 'changed content changes the hash'
    # 해시하는 도중 커지는 파일도 실제로 읽은 양으로 센다. 읽기 시작할 때 커지게 한다.
    $grow=Join-Path $testDirectory 'grow'; $null=New-Item -ItemType Directory -Path $grow
    [IO.File]::WriteAllText((Join-Path $grow 'a.txt'),('g'*100))
    $growList=Get-ProjectFileList $grow
    $copyStream=${function:Copy-ProjectStream}
    ${function:Copy-ProjectStream}={ param([IO.Stream]$From,[IO.Stream]$To,[long]$Limit) [IO.File]::AppendAllText($From.Name,('h'*400)); & $copyStream $From $To $Limit }
    try { $grown=Get-ProjectManifest $growList 150 } finally { ${function:Copy-ProjectStream}=$copyStream }
    Assert ($grown.overLimit -and $grown.bytes -gt 150) 'a file that grows while it is hashed is counted by the bytes actually read'
    Assert (-not (Get-ProjectManifest (Get-ProjectFileList $grow) 1000).overLimit) 'the grown file fits a larger limit'
    [IO.File]::WriteAllText((Join-Path $walk 'README.md'),'# r')
    $locked=[IO.FileStream]::new((Join-Path $walk 'src\main.py'),'Open','ReadWrite','None')
    try { $partial=New-ProjectSnapshot (Get-ProjectFileList $walk) (Join-Path $testDirectory 'locked.zip') } finally { $locked.Dispose() }
    Assert ($partial.files -eq 2 -and ($partial.unreadable -join '|') -eq 'src\main.py') 'a locked file is left out and listed'

    # 8) 비교와 복원: 새 파일은 쓰고, 바뀐 파일은 원본을 복구 폴더에 남기고, 같은 파일과 이 PC에만 있는 파일은 그대로 둔다.
    $target=Join-Path $testDirectory 'target'; $recovery=Join-Path $testDirectory 'recovery'
    Write-Fixture $target @{'README.md'='# r';'src\main.py'='print(2)';'local-only.txt'='keep';'.env'='LOCAL=1'}
    $compare=Compare-ProjectSnapshot $read $target
    Assert ($compare.new -eq 1 -and $compare.changed -eq 1 -and $compare.same -eq 1 -and $compare.localOnly -eq 1 -and ($compare.changedPaths -join '|') -eq 'src\main.py') "compare counts: $($compare | ConvertTo-Json -Compress)"
    $restored=Restore-ProjectSnapshot $zipA $target $recovery
    Assert ($restored.written -eq 2 -and $restored.backedUp -eq 1 -and $restored.same -eq 1 -and $restored.failed.Count -eq 0) "restore counts: $($restored | ConvertTo-Json -Compress)"
    Assert ([IO.File]::ReadAllText((Join-Path $target 'src\main.py')) -eq 'print(1)' -and [IO.File]::ReadAllText((Join-Path $target '한글 폴더\메모.txt')) -eq '메모') 'restored content matches the backup'
    Assert ((Read-Text (Join-Path $recovery 'src\main.py')) -eq 'print(2)') 'the replaced original is in the recovery folder'
    Assert ((Read-Text (Join-Path $target 'local-only.txt')) -eq 'keep' -and (Read-Text (Join-Path $target '.env')) -eq 'LOCAL=1') 'files only on this PC are kept'
    Assert (-not @(Get-ChildItem -LiteralPath $target -Recurse -Force -Filter '*.part').Count) 'no temporary part files remain'
    $again=Compare-ProjectSnapshot $read $target
    Assert ($again.new -eq 0 -and $again.changed -eq 0 -and $again.same -eq 3) 'a second compare finds everything the same'
    $fresh=Join-Path $testDirectory 'fresh\deep'
    Assert ((Compare-ProjectSnapshot $read $fresh).new -eq 3) 'a missing target counts every file as new'
    $restored=Restore-ProjectSnapshot $zipA $fresh (Join-Path $testDirectory 'recovery2')
    Assert ($restored.written -eq 3 -and -not (Test-Path -LiteralPath (Join-Path $testDirectory 'recovery2'))) 'a missing target is created and nothing is backed up'

    # 9) 위험한 스냅숏: 쓰기 전에 거부하고 대상 폴더는 그대로다.
    $victim=Join-Path $testDirectory 'victim'; Write-Fixture $victim @{'keep.txt'='keep'}
    $before=Get-TreeText $testDirectory
    $hostile=[ordered]@{
        traversal={ New-TestZip (Join-Path $testDirectory 'h1.zip') @{'..\escaped.txt'='x'} }
        gitHook={ New-TestZip (Join-Path $testDirectory 'h2.zip') @{'.git\hooks\pre-commit'='x'} }
        shortName={ New-TestZip (Join-Path $testDirectory 'h3.zip') @{'GIT~1\config'='x'} }
        secret={ New-TestZip (Join-Path $testDirectory 'h4.zip') @{'.env'='x'} }
        badHash={ New-TestZip (Join-Path $testDirectory 'h5.zip') @{'a.txt'='x'} { param($m,$e) $m.hash='0'*64 } }
        extraEntry={ New-TestZip (Join-Path $testDirectory 'h6.zip') @{'a.txt'='x'} { param($m,$e) $e['files/b.txt']='hidden' } }
        sizeMismatch={ New-TestZip (Join-Path $testDirectory 'h7.zip') @{'a.txt'='x'} { param($m,$e) $e['a.txt']='longer' } }
        duplicateCase={ New-TestZip (Join-Path $testDirectory 'h8.zip') @{'a.txt'='x'} { param($m,$e) $m.files=@($m.files)+[pscustomobject]@{path='A.txt';size=1;sha256=(Get-Sha 'x')}; $m.hash=Get-ProjectContentHash $m.files } }
        badVersion={ New-TestZip (Join-Path $testDirectory 'h9.zip') @{'a.txt'='x'} { param($m,$e) $m.version=2 } }
    }
    foreach ($name in $hostile.Keys) {
        $zip=& $hostile[$name]
        Throws { Restore-ProjectSnapshot $zip $victim (Join-Path $testDirectory "rec-$name") } '프로젝트 백업'
        Assert (-not (Test-Path -LiteralPath (Join-Path $testDirectory "rec-$name"))) "$name leaves no recovery folder"
    }
    Remove-Item -LiteralPath @(Get-ChildItem -LiteralPath $testDirectory -Filter 'h*.zip' | ForEach-Object FullName)
    Assert ((Get-TreeText $testDirectory) -eq $before) 'hostile snapshots change no file'
    # 내용이 기록된 해시와 다르면(크기는 같음) 그 파일에서 멈추고 남은 파일은 쓰지 않는다(S3 명세 3.2절).
    $tampered=New-TestZip (Join-Path $testDirectory 'tampered.zip') @{'a.txt'='abc';'keep.txt'='same';'z.txt'='z'} { param($m,$e) $e['keep.txt']='SAME' }
    $restored=Restore-ProjectSnapshot $tampered $victim (Join-Path $testDirectory 'rec-tampered')
    Assert ($restored.written -eq 1 -and $restored.failed.Count -eq 1 -and $restored.failed[0].path -eq 'keep.txt' -and $restored.backedUp -eq 1 -and (@($restored.files | ForEach-Object state) -join '|') -eq 'written|failed|skipped') "tampered content stops the restore: $($restored | ConvertTo-Json -Compress)"
    Assert ([IO.File]::ReadAllText((Join-Path $victim 'keep.txt')) -eq 'keep' -and -not (Test-Path -LiteralPath (Join-Path $victim 'z.txt')) -and -not @(Get-ChildItem -LiteralPath $victim -Force -Filter '.ctxhop-*').Count) 'the original stays, later files are not written and no temporary file remains'
    Remove-Item -LiteralPath (Join-Path $victim 'a.txt')
    # 계획: 파일마다 before·after·action을 정하고, 바꿀 파일의 원본은 먼저 복사해 해시를 before로 적는다. 활성 파일은 그대로다.
    $planDir=Join-Path $testDirectory 'plan'; Write-Fixture $planDir @{'a.txt'='old';'same.txt'='same'}
    $planZip=New-TestZip (Join-Path $testDirectory 'plan.zip') @{'a.txt'='new';'same.txt'='same';'b.txt'='b'}
    $plan=New-ProjectRestorePlan $planZip $planDir (Join-Path $testDirectory 'plan-copies')
    $byPath=@{}; foreach ($file in $plan.files) { $byPath[$file.path]=$file }
    Assert ($byPath['a.txt'].action -eq 'write' -and $byPath['a.txt'].before -eq (Get-Sha 'old') -and $byPath['a.txt'].after -eq (Get-Sha 'new') -and (Read-Text $byPath['a.txt'].beforeCopy) -eq 'old') "a changed file is copied first: $($byPath['a.txt'] | ConvertTo-Json -Compress)"
    Assert ($byPath['same.txt'].action -eq 'same' -and -not $byPath['same.txt'].beforeCopy -and $byPath['b.txt'].before -eq 'absent' -and -not $byPath['b.txt'].beforeCopy) 'a same file and a new file are not copied'
    Assert ((Read-Text (Join-Path $planDir 'a.txt')) -eq 'old' -and -not (Test-Path -LiteralPath (Join-Path $planDir 'b.txt'))) 'making a plan writes no project file'
    # 계획 뒤에 바뀐 파일은 쓰지 않고, 그 뒤 파일도 쓰지 않는다.
    [IO.File]::WriteAllText((Join-Path $planDir 'a.txt'),'edited')
    $restored=Invoke-ProjectRestorePlan $planZip $plan.files (Join-Path $testDirectory 'plan-copies')
    Assert ($restored.failed.Count -eq 1 -and $restored.failed[0].reason -like '*a.txt*' -and (@($restored.files | ForEach-Object state) -join '|') -eq 'failed|skipped|skipped') "a file changed after the plan stops the restore: $($restored | ConvertTo-Json -Compress)"
    Assert ((Read-Text (Join-Path $planDir 'a.txt')) -eq 'edited' -and -not (Test-Path -LiteralPath (Join-Path $planDir 'b.txt'))) 'the edited file is kept and nothing else is written'
    # 다시 본 뒤 바꾸기 전 사이에 파일이 바뀌면, 치운 내용을 지우지 않고 남긴다.
    [IO.File]::WriteAllText((Join-Path $planDir 'a.txt'),'old')
    $copyStream=${function:Copy-ProjectStream}
    ${function:Copy-ProjectStream}={ param([IO.Stream]$From,[IO.Stream]$To,[long]$Limit) [IO.File]::WriteAllText((Join-Path $planDir 'a.txt'),'racing'); & $copyStream $From $To $Limit }
    try { $restored=Invoke-ProjectRestorePlan $planZip $plan.files (Join-Path $testDirectory 'plan-copies') } finally { ${function:Copy-ProjectStream}=$copyStream }
    $kept=@(Get-ChildItem -LiteralPath $planDir -Force -Filter '.ctxhop-*.prev')
    Assert ($restored.failed.Count -eq 1 -and $kept.Count -eq 1 -and (Read-Text $kept[0].FullName) -eq 'racing' -and $restored.failed[0].reason -like "*$($kept[0].Name)*") "content changed just before the swap is kept: $($restored | ConvertTo-Json -Compress)"
    Assert ((Read-Text (Join-Path $planDir 'a.txt')) -eq 'new' -and -not (Test-Path -LiteralPath (Join-Path $planDir 'b.txt'))) 'the restore stops after the displaced file'
    # 되돌리기(S3 명세 3.3절): a.txt는 원본이 있던 파일, b.txt는 새로 생긴 파일이다.
    $op='c'*32
    function New-UndoCase([string]$Name) {
        $dir=Join-Path $testDirectory "undo-$Name"; Write-Fixture $dir @{'a.txt'='old'}
        $zip=New-TestZip (Join-Path $testDirectory "undo-$Name.zip") @{'a.txt'='new';'b.txt'='b'}
        $record=Join-Path $testDirectory "undo-$Name-rec"
        $plan=New-ProjectRestorePlan $zip $dir $record 3
        $null=Invoke-ProjectRestorePlan $zip $plan.files $record
        return @{dir=$dir;record=$record;files=$plan.files;a=(Join-Path $dir 'a.txt');b=(Join-Path $dir 'b.txt')}
    }
    function Get-UndoLeft([string]$Dir) { return @(Get-ChildItem -LiteralPath $Dir -Force -Filter '.ctxhop-rb-*').Count }
    function Get-UndoSteps([string]$Record) { return (@((Get-Content -LiteralPath (Join-Path $Record 'rollback.json') -Raw | ConvertFrom-Json).files | ForEach-Object { "$($_.index):$($_.step)" }) -join '|') }
    $saveJson=${function:Save-ProjectJson}
    function Invoke-UndoFault([hashtable]$Case,[scriptblock]$When,[object[]]$Confirmed=@()) {
        # $When이 참인 기록을 저장하려는 순간 멈춘다(강제 종료 흉내). 그 파일의 남은 단계는 실행되지 않는다.
        $script:undoFault=$When
        ${function:Save-ProjectJson}={ param($Path,$Value) if (& $script:undoFault $Value) { throw 'fault' }; & $saveJson $Path $Value }
        try { return (Undo-ProjectRestorePlan $Case.files $Case.record $op $Confirmed) } finally { ${function:Save-ProjectJson}=$saveJson }
    }
    function Test-Step($Value,[int]$Index,[string]$Step) { return [bool]@($Value.files | Where-Object { $_.index -eq $Index -and $_.step -eq $Step }).Count }
    # 기본: 이 작업이 쓴 파일만 되돌리고, 치운 파일은 기록 폴더에 남긴다.
    $case=New-UndoCase 'basic'
    Assert ((@($case.files | ForEach-Object index) -join ',') -eq '3,4') 'plan indexes start at the given number'
    $view=Get-ProjectUndoView $case.files
    Assert ((@($view | ForEach-Object class) -join '|') -eq 'owned|owned') "files this restore wrote are owned: $($view | ConvertTo-Json -Compress)"
    $undo=Undo-ProjectRestorePlan $case.files $case.record $op
    Assert ($undo.complete -and (Read-Text $case.a) -eq 'old' -and -not (Test-Path -LiteralPath $case.b)) "rollback restores the files: $($undo | ConvertTo-Json -Compress -Depth 4)"
    Assert ((Read-Text (Join-Path $case.record 'rollback\3')) -eq 'new' -and (Read-Text (Join-Path $case.record 'rollback\4')) -eq 'b' -and -not (Get-UndoLeft $case.dir)) 'replaced files are kept in the record folder and no temporary file remains'
    Assert ((Get-UndoSteps $case.record) -eq '3:done|4:done') 'every step is done'
    Assert ((Undo-ProjectRestorePlan $case.files $case.record $op).complete) 'running the rollback again stays complete'
    # 알 수 없는 파일은 그대로 두고, 사용자가 본 스냅숏과 같을 때만 되돌린다.
    $case=New-UndoCase 'unknown'
    [IO.File]::WriteAllText($case.a,'user')
    $undo=Undo-ProjectRestorePlan $case.files $case.record $op
    Assert (-not $undo.complete -and $undo.files[0].state -eq 'unknown' -and $undo.files[1].state -eq 'done' -and (Read-Text $case.a) -eq 'user') 'an unknown file is left by the default rollback'
    $undo=Undo-ProjectRestorePlan $case.files $case.record $op @([pscustomobject]@{target=$case.a;current=(Get-Sha 'other')})
    Assert (-not $undo.complete -and (Read-Text $case.a) -eq 'user') 'a confirmation for other content is not used'
    $undo=Undo-ProjectRestorePlan $case.files $case.record $op @([pscustomobject]@{target=$case.a;current=(Get-Sha 'user')})
    Assert ($undo.complete -and (Read-Text $case.a) -eq 'old' -and (Read-Text (Join-Path $case.record 'rollback\3')) -eq 'user') 'a confirmed unknown file is rolled back and its content kept'
    # 원본이 있던 파일을 사용자가 지웠으면(prev=none) 치울 파일 없이 되돌린다. 정상 실행과 Move 직후 중단·재실행이 같은 결과다(R37-N2).
    $case=New-UndoCase 'none'; Remove-Item -LiteralPath $case.a
    $confirmAbsent=@([pscustomobject]@{target=$case.a;current='absent'})
    $undo=Undo-ProjectRestorePlan $case.files $case.record $op $confirmAbsent
    Assert ($undo.complete -and (Read-Text $case.a) -eq 'old' -and -not (Test-Path -LiteralPath (Join-Path $case.record 'rollback\3'))) "a deleted original comes back with nothing to keep: $($undo | ConvertTo-Json -Compress -Depth 4)"
    $case=New-UndoCase 'none-crash'; Remove-Item -LiteralPath $case.a; $confirmAbsent=@([pscustomobject]@{target=$case.a;current='absent'})
    $undo=Invoke-UndoFault $case { param($v) Test-Step $v 3 'done' } $confirmAbsent
    Assert (-not $undo.complete -and (Read-Text $case.a) -eq 'old' -and (Get-UndoSteps $case.record) -like '3:swapped*') 'a stop right after the move is not complete yet'
    $undo=Undo-ProjectRestorePlan $case.files $case.record $op
    Assert ($undo.complete -and (Get-UndoSteps $case.record) -eq '3:done|4:done') 'the rerun reaches the same result as the uninterrupted run'
    # 교체 전에 멈추면(start·prepared·swapped) 남은 .part를 버리고 처음부터 다시 한다.
    foreach ($step in @('start','prepared','swapped')) {
        $case=New-UndoCase "before-$step"
        $undo=Invoke-UndoFault $case ([scriptblock]::Create("param(`$v) Test-Step `$v 3 '$step'"))
        Assert (-not $undo.complete -and (Read-Text $case.a) -eq 'new') "a stop at $step leaves the file as it was"
        $undo=Undo-ProjectRestorePlan $case.files $case.record $op
        Assert ($undo.complete -and (Read-Text $case.a) -eq 'old' -and -not (Get-UndoLeft $case.dir)) "the rerun after $step completes: $($undo | ConvertTo-Json -Compress -Depth 4)"
    }
    # 교체 전에 멈춘 뒤 파일이 판단 때와 달라졌으면, 확인을 받아도 다시 시작하지 않고 멈춘다.
    $case=New-UndoCase 'changed-after-stop'
    $null=Invoke-UndoFault $case { param($v) Test-Step $v 3 'swapped' }
    [IO.File]::WriteAllText($case.a,'user2')
    $undo=Undo-ProjectRestorePlan $case.files $case.record $op @([pscustomobject]@{target=$case.a;current=(Get-Sha 'user2')})
    Assert (-not $undo.complete -and $undo.files[0].state -eq 'attention' -and (Read-Text $case.a) -eq 'user2') 'a file that changed after a stop is not rolled back'
    # 교체 직후(mismatch를 적기 전)와 .prev를 지운 뒤(done을 적기 전)에 멈춰도 이어서 끝난다.
    $case=New-UndoCase 'after-replace'
    $undo=Invoke-UndoFault $case { param($v) [bool]@($v.files | Where-Object { $_.index -eq 3 -and $_.prev -and $_.prev -ne 'none' }).Count }
    Assert (-not $undo.complete -and (Get-UndoLeft $case.dir) -eq 1) 'a stop right after the swap leaves the displaced file'
    $undo=Undo-ProjectRestorePlan $case.files $case.record $op
    Assert ($undo.complete -and (Read-Text (Join-Path $case.record 'rollback\3')) -eq 'new' -and -not (Get-UndoLeft $case.dir)) 'the rerun keeps the displaced file first and completes'
    $case=New-UndoCase 'after-delete'
    $undo=Invoke-UndoFault $case { param($v) Test-Step $v 3 'done' }
    Assert (-not $undo.complete -and -not (Get-UndoLeft $case.dir) -and (Get-UndoSteps $case.record) -like '3:kept*') 'a stop after deleting the displaced file is not complete yet'
    Assert ((Undo-ProjectRestorePlan $case.files $case.record $op).complete) 'the rerun proves the kept copy and completes'
    Remove-Item -LiteralPath (Join-Path $case.record 'rollback\3')
    Assert (-not (Undo-ProjectRestorePlan $case.files $case.record $op).complete) 'a missing kept copy is never complete'
    # 판단 뒤 교체 전에 파일이 바뀌면 치운 내용을 남기고 mismatch로 둔다. 다시 실행해도 성공으로 바뀌지 않는다.
    $case=New-UndoCase 'mismatch'
    $script:raced=$false
    $undo=Invoke-UndoFault $case { param($v) if (-not $script:raced -and (Test-Step $v 3 'swapped')) { $script:raced=$true; [IO.File]::WriteAllText($case.a,'racing') }; $false }
    Assert (-not $undo.complete -and $undo.files[0].state -eq 'mismatch' -and (Read-Text $case.a) -eq 'old' -and (Read-Text (Join-Path $case.record 'rollback\3')) -eq 'racing') "content changed just before the swap is kept as a mismatch: $($undo | ConvertTo-Json -Compress -Depth 4)"
    Assert (-not (Undo-ProjectRestorePlan $case.files $case.record $op).complete) 'a mismatch stays unresolved on the next run'
    # 다른 내용의 보존 사본이 이미 있으면 덮어쓰지 않고, 치운 파일도 지우지 않는다.
    $case=New-UndoCase 'kept-conflict'
    Write-Fixture $case.record @{'rollback\3'='other'}
    $undo=Undo-ProjectRestorePlan $case.files $case.record $op
    $prevFile=@(Get-ChildItem -LiteralPath $case.dir -Force -Filter '.ctxhop-rb-*.prev')
    Assert (-not $undo.complete -and (Read-Text (Join-Path $case.record 'rollback\3')) -eq 'other' -and $prevFile.Count -eq 1 -and (Read-Text $prevFile[0].FullName) -eq 'new') 'a conflicting kept copy stops the rollback and nothing is lost'
    # 원본 사본과 다른 .part가 남아 있으면 지우지 않고 멈춘다.
    $case=New-UndoCase 'bad-part'
    Write-Fixture $case.dir @{".ctxhop-rb-$op-3.part"='tampered'}
    $undo=Undo-ProjectRestorePlan $case.files $case.record $op
    Assert (-not $undo.complete -and (Read-Text $case.a) -eq 'new' -and (Read-Text (Join-Path $case.dir ".ctxhop-rb-$op-3.part")) -eq 'tampered') 'a tampered part file is kept and the file is not touched'
    # 원본 사본이 없으면 되돌리지 못함으로 남기고, 나머지 파일은 되돌린다.
    $case=New-UndoCase 'no-copy'
    Remove-Item -LiteralPath $case.files[0].beforeCopy
    $undo=Undo-ProjectRestorePlan $case.files $case.record $op
    Assert (-not $undo.complete -and $undo.files[0].state -eq 'unrestorable' -and $undo.files[1].state -eq 'done' -and (Read-Text $case.a) -eq 'new') 'a missing original copy cannot be rolled back'
    # 기록 없이 남은 .prev는 mismatch로 보존한다.
    $case=New-UndoCase 'orphan-prev'
    Write-Fixture $case.dir @{".ctxhop-rb-$op-3.prev"='orphan'}
    $undo=Undo-ProjectRestorePlan $case.files $case.record $op
    $entry=@((Get-Content -LiteralPath (Join-Path $case.record 'rollback.json') -Raw | ConvertFrom-Json).files)[0]
    Assert (-not $undo.complete -and $undo.files[0].state -ne 'done' -and $entry.mismatch -and (Read-Text (Join-Path $case.record 'rollback\3')) -eq 'orphan' -and (Read-Text $case.a) -eq 'new') 'a displaced file without a record is kept as a mismatch and nothing else changes'
    # 계획을 세운 뒤 복원 폴더·하위 폴더·상위 폴더가 정션으로 바뀌면(R38-03), 바깥 파일이 after와 같아도 분류·되돌리기가 건드리지 않는다.
    foreach ($shape in 'sub','root','parent') {
        $base=Join-Path $testDirectory "jn-$shape"; $dir=Join-Path $base 'proj'
        Write-Fixture $dir @{'sub\a.txt'='old'}
        $zip=New-TestZip (Join-Path $testDirectory "jn-$shape.zip") @{'sub\a.txt'='new'}
        $record=Join-Path $testDirectory "jn-$shape-rec"
        $plan=New-ProjectRestorePlan $zip $dir $record
        $null=Invoke-ProjectRestorePlan $zip $plan.files $record
        $outsideBase=Join-Path $testDirectory "jn-$shape-outside"
        Write-Fixture $outsideBase @{'proj\sub\a.txt'='new';'sub\a.txt'='new'}
        $junction=switch ($shape) { sub { Join-Path $dir 'sub' } root { $dir } parent { $base } }
        $pointsTo=switch ($shape) { sub { Join-Path $outsideBase 'sub' } root { Join-Path $outsideBase 'proj' } parent { $outsideBase } }
        Rename-Item -LiteralPath $junction -NewName ([IO.Path]::GetFileName($junction)+'-moved')
        $null=New-Item -ItemType Junction -Path $junction -Target $pointsTo
        try {
            $outsideFile=if ($shape -eq 'sub') { Join-Path $outsideBase 'sub\a.txt' } else { Join-Path $outsideBase 'proj\sub\a.txt' }
            $view=Get-ProjectUndoView $plan.files
            Assert ($view[0].class -eq 'unrestorable') "a planned file behind a new junction ($shape) cannot be rolled back: $($view | ConvertTo-Json -Compress)"
            $undo=Undo-ProjectRestorePlan $plan.files $record $op
            $undoConfirmed=Undo-ProjectRestorePlan $plan.files $record $op @([pscustomobject]@{target=$plan.files[0].target;current=(Get-Sha 'new')})
            Assert (-not $undo.complete -and -not $undoConfirmed.complete -and (Read-Text $outsideFile) -eq 'new' -and -not @(Get-ChildItem -LiteralPath $outsideBase -Recurse -Force -Filter '.ctxhop-rb-*').Count -and -not (Test-Path -LiteralPath (Join-Path $record 'rollback'))) "neither rollback touches the outside file ($shape)"
        } finally { [IO.Directory]::Delete($junction) }
    }
    # 대상 안의 정션을 거쳐 쓰지 않는다.
    $null=New-Item -ItemType Junction -Path (Join-Path $victim 'link') -Target $outsideDir
    $viaLink=New-TestZip (Join-Path $testDirectory 'link.zip') @{'link\secret.txt'='overwritten'}
    Throws { Restore-ProjectSnapshot $viaLink $victim (Join-Path $testDirectory 'rec-link') } '링크나 정션'
    Assert ([IO.File]::ReadAllText((Join-Path $outsideDir 'secret.txt')) -eq 'outside') 'a junction inside the target is not written through'
    Throws { Restore-ProjectSnapshot $zipA ([IO.Path]::GetPathRoot($testDirectory)) (Join-Path $testDirectory 'rec-root') } '링크나 정션'
    # 프로젝트 폴더 자체나 위 폴더가 정션이면 실제 위치를 믿을 수 없으므로 백업하지도, 그곳에 복원하지도 않는다.
    $realDir=Join-Path $testDirectory 'real'; Write-Fixture $realDir @{'r.txt'='real';'child\c.txt'='child'}
    $alias=Join-Path $testDirectory 'alias'; $null=New-Item -ItemType Junction -Path $alias -Target $realDir
    Throws { Get-ProjectFileList $alias } '링크나 정션'
    Throws { Get-ProjectFileList (Join-Path $alias 'child') } '링크나 정션'
    $realBefore=Get-TreeText $realDir
    Throws { Restore-ProjectSnapshot $zipA $alias (Join-Path $testDirectory 'rec-alias') } '링크나 정션'
    Throws { Restore-ProjectSnapshot $zipA (Join-Path $alias 'child\new') (Join-Path $testDirectory 'rec-alias-child') } '링크나 정션'
    Assert ((Get-TreeText $realDir) -eq $realBefore -and -not (Test-Path -LiteralPath (Join-Path $testDirectory 'rec-alias')) -and -not (Test-Path -LiteralPath (Join-Path $testDirectory 'rec-alias-child'))) 'nothing is read or written through a junction at or above the project folder'
    $env:USERPROFILE=Join-Path $testDirectory 'home'
    try {
        Throws { Restore-ProjectSnapshot $zipA (Join-Path $env:USERPROFILE '.claude\projects\x') (Join-Path $testDirectory 'rec-settings') } '링크나 정션'
        Assert (-not (Test-Path -LiteralPath $env:USERPROFILE) -and -not (Test-Path -LiteralPath (Join-Path $testDirectory 'rec-settings'))) 'an agent settings folder is never a restore target'
        # 설정 폴더를 가리키는 별칭도 폴더 이름 검사를 피하지 못한다.
        $settingsDir=Join-Path $env:USERPROFILE '.claude'; Write-Fixture $settingsDir @{'settings.json'='{}'}
        $settingsAlias=Join-Path $testDirectory 'settings-alias'; $null=New-Item -ItemType Junction -Path $settingsAlias -Target $settingsDir
        $settingsBefore=Get-TreeText $settingsDir
        Throws { Get-ProjectFileList $settingsAlias } '링크나 정션'
        Throws { Restore-ProjectSnapshot $zipA $settingsAlias (Join-Path $testDirectory 'rec-settings-alias') } '링크나 정션'
        Assert ((Get-TreeText $settingsDir) -eq $settingsBefore) 'an alias of an agent settings folder is neither backed up nor written'
    } finally { $env:USERPROFILE=$oldProfile }

    # 10) 영어 문장.
    Set-Language 'en'
    Throws { Restore-ProjectSnapshot $viaLink $victim (Join-Path $testDirectory 'rec-en') } 'link or junction'
    Set-Language 'ko'

    Write-Output "PASS: $script:Checks isolated project file assertions. Fixtures only; no user folders or stores touched."
} finally {
    $env:USERPROFILE=$oldProfile; $env:LOCALAPPDATA=$oldLocal; $env:GIT_CEILING_DIRECTORIES=$oldCeiling
    $resolved=[IO.Path]::GetFullPath($testDirectory); $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^CtxHop-vnext-project-[a-f0-9]{32}$') { throw 'Refusing cleanup outside fixture directory' }
    # 정션은 대상까지 지우지 않도록 먼저 링크만 없앤다.
    if (Test-Path -LiteralPath $resolved) {
        Get-ChildItem -LiteralPath $resolved -Recurse -Force -Attributes ReparsePoint | ForEach-Object { [IO.Directory]::Delete($_.FullName) }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
