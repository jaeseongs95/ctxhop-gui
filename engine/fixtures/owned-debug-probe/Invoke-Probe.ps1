#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Execute')][string]$Mode,
    [Parameter(Mandatory)][string]$BuildManifest,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ApprovedBuildManifestSha256,
    [string]$LaunchManifest,
    [string]$ApprovedLaunchManifestSha256,
    [switch]$ExecuteReviewedProbe
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$pins = [Collections.Generic.List[IDisposable]]::new()
$runtimeLaunches = 0
function Assert-PlainPath([string]$Path) {
    if (![IO.Path]::IsPathFullyQualified($Path)) { throw 'Absolute path required' }
    $item = Get-Item -LiteralPath $Path -Force
    while ($null -ne $item) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse: $Path" }
        if ($item -is [IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
    }
}
function Pin([string]$Path,[string]$Expected) {
    Assert-PlainPath $Path
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $pins.Add($stream)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $actual = [Convert]::ToHexString($hash.ComputeHash($stream)).ToLowerInvariant() }
    finally { $hash.Dispose(); $stream.Position=0 }
    if ($actual -cne $Expected) { throw "SHA256 mismatch: $Path" }
    $actual
}
function Write-NewJson([string]$Path,$Value) {
    $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $data = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 20)+[char]10)
        $stream.Write($data,0,$data.Length)
    } finally { $stream.Dispose() }
}
function New-Recipe([string]$RunId,[string]$Observer,[string]$Helper,[string]$ManifestHash,[string]$ObserverHash,[string]$HelperHash) {
    $root = "D:\Go\codex-s4\helper3-r45-fixture-owned-debug-run-$RunId"
    @{
        schemaVersion=1; runId=$RunId; root=$root; cwd="$root\cwd"
        environment=@{SystemRoot=$env:SystemRoot;WINDIR=$env:SystemRoot;HOME="$root\home";USERPROFILE="$root\home";
            CODEX_HOME="$root\home";TEMP="$root\temp";TMP="$root\temp";OWNED_DEBUG_RUN=$RunId}
        observer=$Observer; helper=$Helper; buildManifest=$BuildManifest; buildManifestSha256=$ManifestHash
        observerSha256=$ObserverHash; helperSha256=$HelperHash
        parentArgv=@($Helper,'--role','parent','--run',$RunId); childArgv=@($Helper,'--role','child','--run',$RunId)
        argv=@('--helper',$Helper,'--run',$RunId,'--root',$root,'--manifest','LAUNCH_MANIFEST_SHA256',
            '--helper-sha',$HelperHash,'--observer-sha',$ObserverHash)
        normalMs=15000;cleanupMs=5000;totalMs=20000;outerMs=30000;events=512;rawBytes=1048576;receiptBytes=65536
        capabilityScope='ownedSyntheticDebugLifecycle';fileEffects='NOT_OBSERVABLE';networkEffects='NOT_OBSERVABLE'
    }
}
try {
    $BuildManifest = [IO.Path]::GetFullPath($BuildManifest)
    $buildRoot = [IO.Path]::GetDirectoryName($BuildManifest)
    if ([IO.Path]::GetDirectoryName($buildRoot) -ne 'D:\Go\codex-s4' -or
        [IO.Path]::GetFileName($buildRoot) -notmatch '^helper3-r45-fixture-owned-debug-build-[a-f0-9]{32}$' -or
        [IO.Path]::GetFileName($BuildManifest) -ne 'build-manifest.json') { throw 'Foreign build manifest path' }
    $null = Pin $BuildManifest $ApprovedBuildManifestSha256
    $manifest = Get-Content -LiteralPath $BuildManifest -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.schemaVersion -ne 1 -or $manifest.actualProbe -ne 0 -or
        $manifest.sourceCommit -notmatch '^[a-f0-9]{40}$' -or
        $manifest.capabilityScope -ne 'ownedSyntheticDebugLifecycle' -or $manifest.images.Count -ne 2 -or
        $manifest.sources.Count -ne 5) { throw 'Invalid build manifest' }
    foreach ($limit in @{normalMs=15000;cleanupMs=5000;totalMs=20000;waitMs=250;helperWaitMs=5000;normalEvents=448;
        events=512;normalRawBytes=917504;rawBytes=1048576;receiptBytes=65536;processes=2;threadsPerProcess=64}.GetEnumerator()) {
        if ($manifest.limits[$limit.Key] -ne $limit.Value) { throw "Changed limit: $($limit.Key)" }
    }
    $sourceNames = @('observer.c','helper.c','Build-Probe.ps1','Invoke-Probe.ps1','README.md')
    foreach ($name in $sourceNames) {
        $matches = @($manifest.sources | Where-Object { [IO.Path]::GetFileName($_.path) -eq $name })
        if ($matches.Count -ne 1 -or [IO.Path]::GetFullPath($matches[0].path) -ne (Join-Path $PSScriptRoot $name)) {
            throw "Wrong archived source: $name"
        }
        $null = Pin $matches[0].path $matches[0].sha256
    }
    $observer = "$buildRoot\observer.exe"; $helper = "$buildRoot\helper.exe"
    $observerDescriptor = @($manifest.images | Where-Object { $_.path -eq $observer })
    $helperDescriptor = @($manifest.images | Where-Object { $_.path -eq $helper })
    if ($observerDescriptor.Count -ne 1 -or $helperDescriptor.Count -ne 1) { throw 'Wrong images' }
    $null = Pin $observer $observerDescriptor[0].sha256
    $null = Pin $helper $helperDescriptor[0].sha256
    if ($Mode -eq 'Prepare') {
        if ($ExecuteReviewedProbe -or $LaunchManifest -or $ApprovedLaunchManifestSha256) { throw 'Prepare cannot execute' }
        $run = [Guid]::NewGuid().ToString('N')
        $recipe = New-Recipe $run $observer $helper $ApprovedBuildManifestSha256 $observerDescriptor[0].sha256 $helperDescriptor[0].sha256
        $prepareRoot = 'D:\Go\codex-s4\helper3-r45-fixture-owned-debug-launch-' + [Guid]::NewGuid().ToString('N')
        Assert-PlainPath 'D:\Go\codex-s4'
        if (Test-Path -LiteralPath $prepareRoot) { throw 'Prepare output already exists' }
        New-Item -ItemType Directory -Path $prepareRoot | Out-Null
        Write-NewJson "$prepareRoot\launch-manifest.json" $recipe
        @{launchManifest="$prepareRoot\launch-manifest.json";sha256=(Get-FileHash -LiteralPath "$prepareRoot\launch-manifest.json").Hash.ToLowerInvariant();
            actualProbe=0;runRootCreated=$false} | ConvertTo-Json
        return
    }
    if (!$ExecuteReviewedProbe -or $ApprovedLaunchManifestSha256 -notmatch '^[a-f0-9]{64}$' -or !$LaunchManifest) {
        throw 'Execute requires separately reviewed launch manifest and explicit switch'
    }
    $LaunchManifest = [IO.Path]::GetFullPath($LaunchManifest)
    $launchParent = [IO.Path]::GetDirectoryName($LaunchManifest)
    if ([IO.Path]::GetDirectoryName($launchParent) -ne 'D:\Go\codex-s4' -or
        [IO.Path]::GetFileName($launchParent) -notmatch '^helper3-r45-fixture-owned-debug-launch-[a-f0-9]{32}$' -or
        [IO.Path]::GetFileName($LaunchManifest) -ne 'launch-manifest.json') { throw 'Foreign launch manifest' }
    $null = Pin $LaunchManifest $ApprovedLaunchManifestSha256
    $recipe = Get-Content -LiteralPath $LaunchManifest -Raw | ConvertFrom-Json -AsHashtable
    if ($recipe.runId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid run ID' }
    $expected = New-Recipe $recipe.runId $observer $helper $ApprovedBuildManifestSha256 $observerDescriptor[0].sha256 $helperDescriptor[0].sha256
    function Same-Tree($A,$B) {
        if ($A -is [Collections.IDictionary] -and $B -is [Collections.IDictionary]) {
            if ($A.Count -ne $B.Count) { return $false }
            foreach ($key in $A.Keys) { if (!$B.Contains($key) -or !(Same-Tree $A[$key] $B[$key])) { return $false } }
            return $true
        }
        if ($A -is [Array] -and $B -is [Array]) {
            if ($A.Count -ne $B.Count) { return $false }
            for ($i=0;$i -lt $A.Count;$i++) { if (!(Same-Tree $A[$i] $B[$i])) { return $false } }
            return $true
        }
        return "$A" -ceq "$B"
    }
    if (!(Same-Tree $recipe $expected)) { throw 'Launch recipe differs from fixed contract' }
    Assert-PlainPath 'D:\Go\codex-s4'
    if (Test-Path -LiteralPath $recipe.root) { throw 'Run root already exists; never reuse' }
    New-Item -ItemType Directory -Path $recipe.root | Out-Null
    foreach ($name in @('cwd','home','temp','out')) { New-Item -ItemType Directory -Path "$($recipe.root)\$name" | Out-Null }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$observer; $start.WorkingDirectory=$recipe.cwd
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.Environment.Clear()
    foreach ($entry in $recipe.environment.GetEnumerator()) { $start.Environment[$entry.Key]=$entry.Value }
    foreach ($argument in $recipe.argv) {
        $start.ArgumentList.Add(($argument -ceq 'LAUNCH_MANIFEST_SHA256' ? $ApprovedLaunchManifestSha256 : $argument))
    }
    $process = [Diagnostics.Process]::Start($start)
    $runtimeLaunches++
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $completed=$process.WaitForExit(30000)
        if (!$completed) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
        if (!$process.HasExited) { throw 'Owned observer cleanup failed' }
        $process.WaitForExit()
        $exitCode=$process.ExitCode
        $pidValue=$process.Id
        $outText=$stdout.GetAwaiter().GetResult(); $errText=$stderr.GetAwaiter().GetResult()
        if ($outText.Length -gt 8192 -or $errText.Length -gt 8192) { throw 'Observer output bound exceeded' }
        $receiptPath="$($recipe.root)\out\receipt.json"; $rawPath="$($recipe.root)\out\events.ndjson"
        Assert-PlainPath $receiptPath; Assert-PlainPath $rawPath
        if ((Get-Item -LiteralPath $receiptPath).Length -gt 65536 -or (Get-Item -LiteralPath $rawPath).Length -gt 1048576) {
            throw 'Native output bounds exceeded'
        }
        $receipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        $records=@(Get-Content -LiteralPath $rawPath | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        if (!$completed -or $exitCode -ne 0 -or !$receipt.lifecycleSupported -or $receipt.runId -cne $recipe.runId -or
            $receipt.manifestSha256 -cne $ApprovedLaunchManifestSha256 -or $receipt.observerPid -ne $pidValue -or
            $receipt.observerSha256 -cne $observerDescriptor[0].sha256 -or $receipt.helperSha256 -cne $helperDescriptor[0].sha256 -or
            $receipt.events -ne $records.Count -or $receipt.continued -ne $records.Count -or $records.Count -gt 512 -or
            $receipt.activeProcesses -ne 0 -or $receipt.totalProcesses -ne 2 -or $receipt.failure -ne 0 -or
            $receipt.cleanupError -ne 0 -or $receipt.evidenceIncomplete -or !$receipt.ledgerClosed -or
            !$receipt.assignedBeforeContinue -or !$receipt.killOnExit -or
            $receipt.fileEffects -ne 'NOT_OBSERVABLE' -or $receipt.networkEffects -ne 'NOT_OBSERVABLE') { throw 'Receipt rejected' }
        $creates=@($records | Where-Object event -eq 3); $exits=@($records | Where-Object event -eq 5)
        if ($creates.Count -ne 2 -or $exits.Count -ne 2 -or $creates[0].slot -ne 0 -or $creates[1].slot -ne 1 -or
            $exits[0].slot -ne 1 -or $exits[1].slot -ne 0 -or $receipt.parent.pid -eq $receipt.child.pid) { throw 'Lifecycle sequence rejected' }
        foreach ($role in @('parent','child')) {
            $life=$receipt[$role]
            if ($life.birth -le 0 -or $life.pid -le 0 -or !$life.member -or $life.exit -ne 0 -or
                !$life.exitContinue -or !$life.signaled -or !$life.referenceClosed) { throw "Incarnation incomplete: $role" }
        }
        for ($i=0;$i -lt $records.Count;$i++) {
            $record=$records[$i]
            if ($record.seq -ne $i+1 -or !$record.continued -or $record.thread -ne $receipt.observerThread -or
                $record.failure -ne 0 -or $record.slot -notin @(0,1) -or $record.ms -gt 15000 -or
                $record.pid -ne ($record.slot -eq 0 ? $receipt.parent.pid : $receipt.child.pid)) { throw 'Raw event binding rejected' }
        }
        Write-NewJson "$($recipe.root)\out\runner-receipt.json" @{
            schemaVersion=1;actualProbe=$runtimeLaunches;buildManifestSha256=$ApprovedBuildManifestSha256;
            launchManifestSha256=$ApprovedLaunchManifestSha256;runId=$recipe.runId;sourceCommit=$manifest.sourceCommit;
            observerExit=$exitCode;stdout=$outText;stderr=$errText;nativeReceiptSha256=(Get-FileHash -LiteralPath $receiptPath).Hash.ToLowerInvariant();
            rawSha256=(Get-FileHash -LiteralPath $rawPath).Hash.ToLowerInvariant();lifecycleSupported=$true;
            fileEffects='NOT_OBSERVABLE';networkEffects='NOT_OBSERVABLE';engineAcceptance='notRun'
        }
    } finally { $process.Dispose() }
} finally {
    for ($pinIndex=$pins.Count-1;$pinIndex -ge 0;$pinIndex--) { $pins[$pinIndex].Dispose() }
}
