#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceCommit,
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$OutputRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($SourceCommit -notmatch '^[a-f0-9]{40}$') { throw 'Exact source commit required' }
$outputParent = 'D:\Go\codex-s4'
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if ([IO.Path]::GetDirectoryName($OutputRoot) -ne $outputParent -or
    [IO.Path]::GetFileName($OutputRoot) -notmatch '^helper3-r45-fixture-owned-debug-build-[a-f0-9]{32}$') {
    throw 'Output must be a fresh owned build directory'
}
function Assert-PlainPath([string]$Path) {
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
Assert-PlainPath $outputParent
Assert-PlainPath $ArchivePath
Assert-PlainPath $PSScriptRoot
if (Test-Path -LiteralPath $OutputRoot) { throw 'Output already exists' }
$walk = Get-Item -LiteralPath $PSScriptRoot
while ($null -ne $walk) {
    if (Test-Path -LiteralPath (Join-Path $walk.FullName '.git')) { throw 'Build from archive, not checkout' }
    $walk = $walk.Parent
}
$msvc = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207'
$sdk = 'C:\Program Files (x86)\Windows Kits\10'
$sdkVersion = '10.0.26100.0'
$toolBin = "$msvc\bin\Hostx64\x64"
$include = "$msvc\include;$sdk\Include\$sdkVersion\ucrt;$sdk\Include\$sdkVersion\shared;$sdk\Include\$sdkVersion\um"
$lib = "$msvc\lib\x64;$sdk\Lib\$sdkVersion\ucrt\x64;$sdk\Lib\$sdkVersion\um\x64"
$sourceFiles = @('observer.c','helper.c','Build-Probe.ps1','Invoke-Probe.ps1','README.md')
$source = @($sourceFiles | ForEach-Object { Descriptor (Join-Path $PSScriptRoot $_) })
$tools = @('cl.exe','link.exe','c1.dll','c2.dll','mspdb140.dll') | ForEach-Object { Descriptor "$toolBin\$_" }
$sdkInputs = @(
    "$sdk\Include\$sdkVersion\um\Windows.h", "$sdk\Include\$sdkVersion\um\debugapi.h",
    "$sdk\Include\$sdkVersion\um\jobapi2.h", "$sdk\Include\$sdkVersion\um\winbase.h",
    "$sdk\Include\$sdkVersion\um\winnt.h", "$sdk\Lib\$sdkVersion\um\x64\Kernel32.Lib",
    "$msvc\lib\x64\libcmt.lib", "$msvc\lib\x64\libvcruntime.lib",
    "$sdk\Lib\$sdkVersion\ucrt\x64\libucrt.lib"
) | ForEach-Object { Descriptor $_ }
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
    $process = [Diagnostics.Process]::Start($start)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (!$process.WaitForExit(60000)) { $process.Kill(); $process.WaitForExit(); throw 'Owned compiler timed out' }
    $process.WaitForExit()
    $record = @{name=$name; argv=$arguments; exitCode=$process.ExitCode; stdout=$stdout.GetAwaiter().GetResult();
        stderr=$stderr.GetAwaiter().GetResult(); environment=@{INCLUDE=$include;LIB=$lib;PATH=$start.Environment['PATH'];
            TEMP="$OutputRoot\temp";TMP="$OutputRoot\temp";SystemRoot=$env:SystemRoot;WINDIR=$env:SystemRoot}}
    $process.Dispose()
    $results += $record
    Write-NewJson "$OutputRoot\$name-build.json" $record
    if ($record.exitCode -ne 0) { throw "Compile failed: $name; output preserved at $OutputRoot" }
}
$manifest = @{
    schemaVersion=1; capabilityScope='ownedSyntheticDebugLifecycle'; sourceCommit=$SourceCommit
    archive=(Descriptor $ArchivePath); sources=$source; tools=@($tools); sdkInputs=@($sdkInputs)
    builds=$results; images=@((Descriptor "$OutputRoot\observer.exe"),(Descriptor "$OutputRoot\helper.exe"))
    limits=@{normalMs=15000;cleanupMs=5000;totalMs=20000;waitMs=250;helperWaitMs=5000;
        normalEvents=448;events=512;normalRawBytes=917504;rawBytes=1048576;receiptBytes=65536;processes=2;threadsPerProcess=64}
    fixturePlanSha256='7f549a220081dd27f6a06ac0342ef121b3fa1e9096e2f42b2f832647f4a00099'
    actualProbe=0; runtimeCompatibility='notTested'; engineAcceptance='notRun'
}
Write-NewJson "$OutputRoot\build-manifest.json" $manifest
Descriptor "$OutputRoot\build-manifest.json" | ConvertTo-Json -Depth 4
