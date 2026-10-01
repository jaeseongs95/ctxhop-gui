#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceCommit,
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$FixtureWorkspace,
    [Parameter(Mandatory)][string]$MsvcRoot,
    [Parameter(Mandatory)][string]$WindowsSdkRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+(\.[0-9]+){3}$')][string]$WindowsSdkVersion
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($SourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Exact source commit required' }
foreach ($inputPath in @($FixtureWorkspace,$MsvcRoot,$WindowsSdkRoot,$ArchivePath)) {
    if (![IO.Path]::IsPathFullyQualified($inputPath)) { throw 'Absolute input required' }
}
$FixtureWorkspace = [IO.Path]::GetFullPath($FixtureWorkspace).TrimEnd('\')
if (![IO.Path]::IsPathFullyQualified($FixtureWorkspace) -or $FixtureWorkspace.StartsWith('\\') -or
    $FixtureWorkspace.Length -gt 180 -or
    [IO.Path]::GetFileName($FixtureWorkspace) -cnotmatch '^ctxhop-owned-debug-[a-f0-9]{32}$') { throw 'Invalid owned workspace' }
function Assert-PlainPath([string]$Path) {
    if (![IO.Path]::IsPathFullyQualified($Path) -or $Path.StartsWith('\\')) { throw 'Local absolute input required' }
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse: $Path" }
        if ($item -is [IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
    }
}
function Descriptor([string]$Path) {
    Assert-PlainPath $Path
    $file = Get-Item -LiteralPath $Path
    @{ path=$file.FullName; bytes=$file.Length; sha256=(Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant();
       version=$file.VersionInfo.FileVersion }
}
function Write-NewJson([string]$Path, $Value) {
    $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $data = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 20)+[char]10)
        $stream.Write($data,0,$data.Length)
    } finally { $stream.Dispose() }
}
function Invoke-BoundedProcess([Diagnostics.ProcessStartInfo]$Start,[int]$NormalMs) {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $deadline=$NormalMs+10000
    $cancel=[Threading.CancellationTokenSource]::new()
    $cancel.CancelAfter($deadline)
    $process=$null; $stdout=$null; $stderr=$null
    $result=@{pid=$null;birth=$null;exitCode=$null;parentExited=$false;stdoutDrained=$false;stderrDrained=$false;
        stdout='';stderr='';reason=$null;cleanup='unproven';wholeJobExit='notMeasured';elapsedMs=0}
    try {
        $process=[Diagnostics.Process]::Start($Start)
        $result.pid=$process.Id; $result.birth=$process.StartTime.ToUniversalTime().ToFileTimeUtc()
        $stdout=$process.StandardOutput.ReadToEndAsync($cancel.Token)
        $stderr=$process.StandardError.ReadToEndAsync($cancel.Token)
        $remaining=[Math]::Max(0,$NormalMs-[int]$clock.ElapsedMilliseconds)
        if (!$process.WaitForExit($remaining)) { $result.reason='ownedProcessTimeout'; $process.Kill() }
        if (!$process.HasExited) {
            $remaining=[Math]::Max(0,[Math]::Min(5000,$deadline-[int]$clock.ElapsedMilliseconds))
            if (!$process.WaitForExit($remaining)) { $result.reason='ownedProcessStillActive' }
        }
        $result.parentExited=$process.HasExited
        if ($result.parentExited) { $result.exitCode=$process.ExitCode }
        $remaining=[Math]::Max(0,[Math]::Min(5000,$deadline-[int]$clock.ElapsedMilliseconds))
        try { $null=[Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),$remaining) }
        catch { if (!$result.reason) { $result.reason='ownedOutputReadFailed' } }
        $result.stdoutDrained=$stdout.IsCompletedSuccessfully; $result.stderrDrained=$stderr.IsCompletedSuccessfully
        # Result is consumed only after success-completion, never as a wait.
        if ($result.stdoutDrained) { $result.stdout=$stdout.GetAwaiter().GetResult() }
        if ($result.stderrDrained) { $result.stderr=$stderr.GetAwaiter().GetResult() }
        if (!$result.stdoutDrained -or !$result.stderrDrained) { if (!$result.reason) { $result.reason='ownedOutputNotDrained' } }
        if ($result.parentExited -and $result.stdoutDrained -and $result.stderrDrained) { $result.cleanup='parentAndPipesClosed' }
    } catch { if (!$result.reason) { $result.reason=$_.Exception.Message } }
    finally {
        $cancel.Cancel()
        if ($null -ne $process) {
            if (!$process.HasExited) {
                try {
                    $process.Kill()
                    $remaining=[Math]::Max(0,[Math]::Min(5000,$deadline-[int]$clock.ElapsedMilliseconds))
                    $null=$process.WaitForExit($remaining)
                } catch { $result.cleanup='unproven' }
            }
            $result.parentExited=$process.HasExited
            if (!$result.parentExited) { $result.cleanup='unproven' }
            $process.Dispose()
        }
        $cancel.Dispose(); $result.elapsedMs=$clock.ElapsedMilliseconds
    }
    if ([Text.Encoding]::UTF8.GetByteCount($result.stdout+$result.stderr) -gt 65536) {
        $result.reason='ownedOutputBoundExceeded'; $result.stdout=''; $result.stderr=''
    }
    return $result
}
Assert-PlainPath ([IO.Path]::GetDirectoryName($FixtureWorkspace))
Assert-PlainPath $ArchivePath
Assert-PlainPath $PSScriptRoot
if (Test-Path -LiteralPath $FixtureWorkspace) { throw 'Workspace already exists' }
$walk = Get-Item -LiteralPath $PSScriptRoot
while ($null -ne $walk) {
    if (Test-Path -LiteralPath (Join-Path $walk.FullName '.git')) { throw 'Build from archive, not checkout' }
    $walk = $walk.Parent
}
$msvc = [IO.Path]::GetFullPath($MsvcRoot)
$sdk = [IO.Path]::GetFullPath($WindowsSdkRoot)
$sdkVersion = $WindowsSdkVersion
Assert-PlainPath $msvc
Assert-PlainPath $sdk
$toolBin = "$msvc\bin\Hostx64\x64"
$include = "$msvc\include;$sdk\Include\$sdkVersion\ucrt;$sdk\Include\$sdkVersion\shared;$sdk\Include\$sdkVersion\um"
$lib = "$msvc\lib\x64;$sdk\Lib\$sdkVersion\ucrt\x64;$sdk\Lib\$sdkVersion\um\x64"
$sourceFiles = @('observer.c','helper.c','continue-policy.h','continue-policy-test.c','Build-Probe.ps1','Invoke-Probe.ps1','README.md')
$source = @($sourceFiles | ForEach-Object { Descriptor (Join-Path $PSScriptRoot $_) })
$tools = @('cl.exe','link.exe','c1.dll','c2.dll','mspdb140.dll') | ForEach-Object { Descriptor "$toolBin\$_" }
$sdkInputs = @(
    "$sdk\Include\$sdkVersion\um\Windows.h", "$sdk\Include\$sdkVersion\um\debugapi.h",
    "$sdk\Include\$sdkVersion\um\jobapi2.h", "$sdk\Include\$sdkVersion\um\winbase.h",
    "$sdk\Include\$sdkVersion\um\winnt.h", "$sdk\Lib\$sdkVersion\um\x64\Kernel32.Lib",
    "$msvc\lib\x64\libcmt.lib", "$msvc\lib\x64\libvcruntime.lib",
    "$sdk\Lib\$sdkVersion\ucrt\x64\libucrt.lib"
) | ForEach-Object { Descriptor $_ }
New-Item -ItemType Directory -Path $FixtureWorkspace | Out-Null
Write-NewJson "$FixtureWorkspace\fixture-owner.json" @{schemaVersion=1;workspace=$FixtureWorkspace;
    nonce=[IO.Path]::GetFileName($FixtureWorkspace).Substring(19);sourceCommit=$SourceCommit}
$OutputRoot = Join-Path $FixtureWorkspace ('build-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
New-Item -ItemType Directory -Path "$OutputRoot\temp" | Out-Null
$results = @()
foreach ($name in @('observer','helper')) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = "$toolBin\cl.exe"
    $start.WorkingDirectory = $OutputRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.CreateNoWindow = $true
    $start.Environment.Clear()
    $start.Environment['SystemRoot'] = $env:SystemRoot
    $start.Environment['WINDIR'] = $env:SystemRoot
    $start.Environment['PATH'] = "$toolBin;$env:SystemRoot\System32"
    $start.Environment['INCLUDE'] = $include
    $start.Environment['LIB'] = $lib
    $start.Environment['TEMP'] = "$OutputRoot\temp"
    $start.Environment['TMP'] = "$OutputRoot\temp"
    $arguments = @('/nologo','/W4','/WX','/TC','/MT','/O1','/D_WIN32_WINNT=0x0602',
        "/Fo$OutputRoot\$name.obj", "/Fe$OutputRoot\$name.exe", "$PSScriptRoot\$name.c",
        '/link','/INCREMENTAL:NO','/Brepro','Kernel32.lib')
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $outcome = Invoke-BoundedProcess $start 60000
    $record = @{name=$name; argv=$arguments; outcome=$outcome; exitCode=$outcome.exitCode;
        stdout=$outcome.stdout;stderr=$outcome.stderr; environment=@{INCLUDE=$include;LIB=$lib;PATH=$start.Environment['PATH'];
            TEMP="$OutputRoot\temp";TMP="$OutputRoot\temp";SystemRoot=$env:SystemRoot;WINDIR=$env:SystemRoot}}
    $results += $record
    Write-NewJson "$OutputRoot\$name-build.json" $record
    if ($outcome.reason -or !$outcome.parentExited -or !$outcome.stdoutDrained -or !$outcome.stderrDrained -or
        $record.exitCode -ne 0) { throw "Compile failed or incomplete: $name; output preserved at $OutputRoot" }
}
$manifest = @{
    schemaVersion=1; capabilityScope='ownedSyntheticDebugLifecycle'; sourceCommit=$SourceCommit
    fixtureWorkspace=$FixtureWorkspace;workspaceNonce=[IO.Path]::GetFileName($FixtureWorkspace).Substring(19)
    workspaceOwner=(Descriptor "$FixtureWorkspace\fixture-owner.json")
    toolchain=@{msvcRoot=$msvc;windowsSdkRoot=$sdk;windowsSdkVersion=$sdkVersion}
    archive=(Descriptor $ArchivePath); sources=$source; tools=@($tools); sdkInputs=@($sdkInputs)
    builds=$results; images=@((Descriptor "$OutputRoot\observer.exe"),(Descriptor "$OutputRoot\helper.exe"))
    limits=@{normalMs=15000;cleanupMs=5000;totalMs=20000;waitMs=250;helperWaitMs=5000;
        normalEvents=448;events=512;normalRawBytes=917504;rawBytes=1048576;receiptBytes=65536;processes=2;threadsPerProcess=64}
    fixturePlanSha256='7f549a220081dd27f6a06ac0342ef121b3fa1e9096e2f42b2f832647f4a00099'
    actualProbe=0; runtimeCompatibility='notTested'; engineAcceptance='notRun'
    powerShellVersion=$PSVersionTable.PSVersion.ToString(); osVersion=[Environment]::OSVersion.VersionString
}
Write-NewJson "$OutputRoot\build-manifest.json" $manifest
Descriptor "$OutputRoot\build-manifest.json" | ConvertTo-Json -Depth 4
