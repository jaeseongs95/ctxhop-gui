#requires -Version 5.1
<#
S4 fixture preparation and runner checks. No engine process is started here.
Use committed LF git archive bytes. Engine acceptance remains notRun until the
source/provider pin, effect boundary and scenarios are sealed by the coordinator.
File snapshots detect final differences; they do not prove absence of transient
writes or networking. Engine effects require independent complete observation.
Basic preparation uses an explicit fresh FixtureWorkspace. Historical modes
require RunnerMetadata plus its SHA256, explicit owned read/write roots and
mode-specific paths/pins; metadata never authorizes a new engine or seed run.
#>
param(
    [ValidateSet('Prepare','SelfTest','ConnectionPlan','SchemaExport','SchemaCompare','MigrationCheck','BackendCheck','AggregateSchemaSeed','AggregateSchemaSeedChecks','Engine')][string]$Mode='SelfTest',
    [string]$OutRoot,
    [string]$FixtureWorkspace,
    [string]$RunnerMetadata,
    [string]$RunnerMetadataSha256,
    [string]$SourceArchive,
    [string]$SourceCommit,
    [string]$SchemaReceipt,
    [string]$StateMigrations,
    [string]$BuilderScript,
    [string]$MigrationArchive,
    [string]$SourceRepository,
    [string]$GoArchive,
    [string]$GoCommit,
    [string]$BackendCases,
    [string]$SeedManifest,
    [string]$SeedManifestSha256,
    [string]$SeedSourceArchive,
    [string]$SeedCargoLock,
    [switch]$LibraryOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$script:FixtureChecks=0
$script:Utf8=[Text.UTF8Encoding]::new($false)
$script:PortableFixtureRoot=$null
$script:RunnerConfiguration=$null
$script:FixturePathComparison=if ([IO.Path]::DirectorySeparatorChar -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$script:PortableFiles=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$script:PortableDirectories=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
# Filled only in a new reviewed source commit after the coordinator reads the
# actual CRLF artifacts/provenance and freezes the full launch manifest bytes.
$script:ApprovedSeedManifestSha256='0a82dd4f7aeefaf9a1e043606ade5c789579d70e89b9dfae1a6d81410dad2429'
function Assert-Fixture([bool]$Value,[string]$Message) {
    $script:FixtureChecks++
    if (-not $Value) { throw "fixtureAssertion:$Message" }
}
function Assert-FixtureThrows([scriptblock]$Body,[string]$Reason) {
    $found=$false
    try { & $Body | Out-Null } catch { $found=$_.Exception.Message -match [regex]::Escape($Reason) }
    Assert-Fixture $found $Reason
}
function Assert-PlainFixturePath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'fixturePathNotAbsolute' }
    if ([IO.Path]::DirectorySeparatorChar -eq '\' -and $Path -notmatch '^[A-Za-z]:[\\/]') { throw 'fixturePathNotAbsolute' }
    $full=[IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\','/'))
    if ($full.StartsWith('\\',[StringComparison]::Ordinal)) { throw 'fixturePathNotLocal' }
    # Check every existing ancestor before creating or reading descendants.
    $scan=$full
    while ($scan) {
        if (Test-Path -LiteralPath $scan) {
            if ((Get-Item -LiteralPath $scan -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'fixtureReparsePath' }
        }
        $parent=[IO.Path]::GetDirectoryName($scan)
        if ($parent -eq $scan) { break }
        $scan=$parent
    }
    return $full
}
function Test-FixtureContainment([string]$Path,[string]$Root) {
    return [string]::Equals($Path,$Root,$script:FixturePathComparison) -or
        $Path.StartsWith($Root+[IO.Path]::DirectorySeparatorChar,$script:FixturePathComparison)
}
function Get-RunnerSetting([string]$Name) {
    if ($null -eq $script:RunnerConfiguration -or
        $script:RunnerConfiguration.PSObject.Properties.Name -cnotcontains $Name -or
        $script:RunnerConfiguration.$Name -isnot [string] -or -not $script:RunnerConfiguration.$Name) {
        throw ('runnerMetadataRequired:'+ $Name)
    }
    return $script:RunnerConfiguration.$Name
}
function Initialize-RunnerMetadata([string]$File,[string]$ExpectedHash) {
    if ($ExpectedHash -cnotmatch '^[0-9a-f]{64}$') { throw 'runnerMetadataHashRequired' }
    $filePath=Assert-PlainFixturePath $File
    $stream=[IO.File]::Open($filePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -gt 65536) { throw 'runnerMetadataTooLarge' }
        $hash=[Security.Cryptography.SHA256]::Create()
        try { $actual=([BitConverter]::ToString($hash.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $hash.Dispose(); $stream.Position=0 }
        if ($actual -cne $ExpectedHash) { throw 'runnerMetadataHashMismatch' }
        $bytes=New-Object byte[] ([int]$stream.Length)
        $offset=0
        while ($offset -lt $bytes.Length) {
            $read=$stream.Read($bytes,$offset,$bytes.Length-$offset)
            if (-not $read) { throw 'runnerMetadataTruncated' }; $offset+=$read
        }
        $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
        $propertyNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($token in [regex]::Matches($text,'"(?:\\.|[^"\\])*"')) {
            if ($text.Substring($token.Index+$token.Length).TrimStart().StartsWith(':',[StringComparison]::Ordinal)) {
                $name=ConvertFrom-Json -InputObject $token.Value
                if (-not $propertyNames.Add($name)) { throw 'runnerMetadataDuplicateKey' }
            }
        }
        $configuration=$text | ConvertFrom-Json
    } finally { $stream.Dispose() }
    $keys=@('schemaVersion','writeRoots','readRoots','sourceRepository','stateRepository','toolchainScript',
        'toolchainScriptSha256','schemaOriginReport','schemaOriginReportSha256','schemaOriginSource',
        'backendRustExecutable','backendRustExecutableSha256','backendRustArtifact','backendRustArtifactSha256','backendRustSourceCommit',
        'seedNamespaceParent','backendNamespaceParent')
    if ($configuration.PSObject.Properties.Name.Count -ne $keys.Count -or
        @($configuration.PSObject.Properties.Name | Where-Object { $_ -cnotin $keys }).Count -or
        ($configuration.schemaVersion -isnot [int] -and $configuration.schemaVersion -isnot [long]) -or
        $configuration.schemaVersion -ne 1) { throw 'runnerMetadataFields' }
    foreach ($key in @('writeRoots','readRoots')) {
        if ($configuration.$key -isnot [array] -or -not $configuration.$key.Count) { throw 'runnerMetadataRoots' }
        $rootNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($root in $configuration.$key) {
            if ($root -isnot [string] -or -not $root -or
                -not [string]::Equals((Assert-PlainFixturePath $root),$root.TrimEnd([char[]]@('\','/')),$script:FixturePathComparison) -or
                [string]::Equals($root.TrimEnd([char[]]@('\','/')),[IO.Path]::GetPathRoot($root).TrimEnd([char[]]@('\','/')),$script:FixturePathComparison)) {
                throw 'runnerMetadataRoots'
            }
            if (-not $rootNames.Add($root.TrimEnd([char[]]@('\','/')))) { throw 'runnerMetadataRootAlias' }
            if ($key -ceq 'writeRoots' -and [IO.Path]::GetFileName($root) -cnotmatch '^(helper3-r45-fixture-[A-Za-z0-9_-]+|ctxhop-prestart-[a-f0-9]{32})$') { throw 'runnerMetadataWriteOwnership' }
        }
    }
    foreach ($key in @($keys | Where-Object { $_ -cnotin @('schemaVersion','writeRoots','readRoots','toolchainScriptSha256',
        'schemaOriginReportSha256','backendRustExecutableSha256','backendRustArtifactSha256','backendRustSourceCommit') })) {
        if ($null -ne $configuration.$key -and ($configuration.$key -isnot [string] -or -not $configuration.$key)) { throw 'runnerMetadataPathType' }
    }
    foreach ($key in @('toolchainScriptSha256','schemaOriginReportSha256','backendRustExecutableSha256','backendRustArtifactSha256')) {
        if ($null -ne $configuration.$key -and ($configuration.$key -isnot [string] -or
            $configuration.$key -cnotmatch '^[0-9a-f]{64}$')) { throw 'runnerMetadataPin' }
    }
    if ($null -ne $configuration.backendRustSourceCommit -and ($configuration.backendRustSourceCommit -isnot [string] -or
        $configuration.backendRustSourceCommit -cnotmatch '^[0-9a-f]{40}$')) { throw 'runnerMetadataPin' }
    $script:RunnerConfiguration=$configuration
    $script:RunnerConfigurationHash=$actual
    $script:RunnerMetadataPath=$filePath
}
function Get-RunnerMetadataArguments {
    if ($null -eq $script:RunnerConfiguration) { throw 'runnerMetadataRequired' }
    return @(('-ctxhop-fixture-metadata='+$script:RunnerMetadataPath),
        ('-ctxhop-fixture-metadata-sha256='+$script:RunnerConfigurationHash))
}
function Assert-OwnedFixturePath([string]$Path) {
    $full=Assert-PlainFixturePath $Path
    if ($script:PortableFixtureRoot) {
        if (-not (Test-FixtureContainment $full $script:PortableFixtureRoot)) { throw 'fixturePathOutsideOwnership' }
    } else {
        if ($null -eq $script:RunnerConfiguration) { throw 'runnerMetadataRequired:writeRoots' }
        if (-not @($script:RunnerConfiguration.writeRoots | Where-Object { Test-FixtureContainment $full $_ }).Count) { throw 'fixturePathOutsideOwnership' }
    }
    return $full
}
function Assert-FixtureReadPath([string]$Path) {
    $full=Assert-PlainFixturePath $Path
    if ($script:PortableFixtureRoot -and (Test-FixtureContainment $full $script:PortableFixtureRoot)) { return $full }
    if ($null -eq $script:RunnerConfiguration -or
        -not @($script:RunnerConfiguration.readRoots | Where-Object { Test-FixtureContainment $full $_ }).Count) { throw 'fixtureReadOutsideOwnership' }
    return $full
}
function Invoke-ConfiguredToolchain {
    $tool=Assert-FixtureReadPath (Get-RunnerSetting 'toolchainScript')
    $pin=Get-RunnerSetting 'toolchainScriptSha256'
    if ((Get-FileHash -LiteralPath $tool).Hash.ToLowerInvariant() -cne $pin) { throw 'runnerToolchainPinMismatch' }
    # Only a explicitly configured, pinned script is sourced in this runner process.
    . $tool
}
function Initialize-FixtureWorkspace([string]$Workspace,[string]$Output) {
    if ($Mode -cnotin @('SelfTest','Prepare','ConnectionPlan')) { throw 'fixtureWorkspaceModeUnsupported' }
    if (-not [IO.Path]::IsPathRooted($Workspace)) { throw 'fixturePathNotAbsolute' }
    if ([IO.Path]::DirectorySeparatorChar -eq '\' -and $Workspace -notmatch '^[A-Za-z]:[\\/]') { throw 'fixturePathNotAbsolute' }
    $full=[IO.Path]::GetFullPath($Workspace).TrimEnd([char[]]@('\','/'))
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\','/'))
    if (-not $temp -or [string]::Equals($temp,[IO.Path]::GetPathRoot($temp).TrimEnd([char[]]@('\','/')),$script:FixturePathComparison) -or
        -not [string]::Equals([IO.Path]::GetDirectoryName($full),$temp,$script:FixturePathComparison) -or [IO.Path]::GetFileName($full) -cnotmatch '^ctxhop-prestart-[0-9a-f]{32}$') { throw 'fixtureWorkspaceOutsideTemp' }
    if ($Output -and (-not [IO.Path]::IsPathRooted($Output) -or -not [string]::Equals([IO.Path]::GetFullPath($Output).TrimEnd([char[]]@('\','/')),$full,$script:FixturePathComparison))) { throw 'fixtureWorkspaceOutputMismatch' }
    $script:PortableFixtureRoot=$full
    $checked=Assert-OwnedFixturePath $full
    if (Test-Path -LiteralPath $checked) { throw 'fixtureOutputExists' }
    return $checked
}
function New-FixtureDirectory([string]$Path) {
    $full=Assert-OwnedFixturePath $Path
    if ($script:PortableFixtureRoot -and (Test-Path -LiteralPath $full)) { throw 'fixtureUnknownDirectory' }
    [IO.Directory]::CreateDirectory($full) | Out-Null
    if ($script:PortableFixtureRoot) { $script:PortableDirectories.Add($full) | Out-Null }
}
function New-FixtureOutput([string]$Root) {
    $path=Assert-OwnedFixturePath $Root
    if (Test-Path -LiteralPath $path) { throw 'fixtureOutputExists' }
    New-FixtureDirectory $path
    if ($script:PortableFixtureRoot) {
        if (@(Get-ChildItem -LiteralPath $path -Force).Count) { throw 'fixtureUnknownOutput' }
        Write-FixtureJson (Join-Path $path 'fixture-owner.json') @{schemaVersion=1;workspaceId=[IO.Path]::GetFileName($path);mode=$Mode;purpose='fresh synthetic preparation only';engineExecuted=$false}
    }
    return $path
}
function Write-FixtureText([string]$Path,[string]$Text) {
    $full=Assert-OwnedFixturePath $Path
    if ($script:PortableFixtureRoot) {
        if (-not $script:PortableDirectories.Contains([IO.Path]::GetDirectoryName($full))) { throw 'fixtureUnknownDirectory' }
        $fileMode=[IO.FileMode]::CreateNew
        if (Test-Path -LiteralPath $full) {
            if (-not $script:PortableFiles.Contains($full) -or -not [IO.File]::Exists($full)) { throw 'fixtureUnknownFile' }
            $fileMode=[IO.FileMode]::Open
        }
        $stream=[IO.File]::Open($full,$fileMode,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $bytes=$script:Utf8.GetBytes(($Text -replace "`r`n","`n")); $stream.Write($bytes,0,$bytes.Length); $stream.SetLength($bytes.Length) } finally { $stream.Dispose() }
        $script:PortableFiles.Add($full) | Out-Null
        return
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full)) | Out-Null
    [IO.File]::WriteAllText($full,($Text -replace "`r`n","`n"),$script:Utf8)
}
function Write-FixtureJson([string]$Path,[object]$Value) {
    Write-FixtureText $Path ((ConvertTo-Json -InputObject $Value -Depth 30)+"`n")
}
function Get-FixtureTree([string]$Root) {
    $rootPath=Assert-OwnedFixturePath $Root
    if (-not [IO.Directory]::Exists($rootPath)) { throw 'fixtureRootAbsent' }
    $entries=@{}; $pending=[Collections.Generic.Stack[string]]::new(); $pending.Push($rootPath)
    while ($pending.Count) {
        $directory=$pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'fixtureReparsePath' }
            if ($script:PortableFixtureRoot -and (($item.PSIsContainer -and -not $script:PortableDirectories.Contains($item.FullName)) -or (-not $item.PSIsContainer -and -not $script:PortableFiles.Contains($item.FullName)))) { throw 'fixtureUnknownEntry' }
            $key=$item.FullName.Substring($rootPath.Length+1).Replace('\','/')
            if ($item.PSIsContainer) {
                $entries[$key]=[pscustomobject]@{kind='directory';sha256=$null;length=0;writeTicks=$item.LastWriteTimeUtc.Ticks}
                $pending.Push($item.FullName)
            } else {
                $entries[$key]=[pscustomobject]@{kind='file';sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant();length=$item.Length;writeTicks=$item.LastWriteTimeUtc.Ticks}
            }
        }
    }
    return $entries
}
function Compare-FixtureTree([Collections.IDictionary]$Before,[Collections.IDictionary]$After,[string[]]$AllowedShm=@()) {
    $changed=@(); $allowed=@()
    foreach ($key in @(@($Before.Keys)+@($After.Keys) | Sort-Object -Unique)) {
        $a=$Before[$key]; $b=$After[$key]
        $different=$null -eq $a -or $null -eq $b
        if (-not $different) { $different=$a.kind -cne $b.kind -or $a.sha256 -cne $b.sha256 -or $a.length -ne $b.length -or $a.writeTicks -ne $b.writeTicks }
        if (-not $different) { continue }
        # Directory timestamps accompany SHM creation; content paths are decisive.
        if ($null -ne $a -and $null -ne $b -and $a.kind -ceq 'directory' -and $b.kind -ceq 'directory') { continue }
        if ($key -cin $AllowedShm -and $key.EndsWith('-shm',[StringComparison]::Ordinal) -and
            ($null -eq $a -or $a.kind -ceq 'file') -and ($null -eq $b -or $b.kind -ceq 'file')) { $allowed+=$key }
        else { $changed+=$key }
    }
    return [pscustomobject]@{unchanged=($changed.Count -eq 0);changes=@($changed);allowedShmChanges=@($allowed);transientWrites='unverified';network='unverified'}
}
function Get-PrestartBinding([object]$Projection,[string]$Operation) {
    $binding=[ordered]@{}
    foreach ($key in @('requestNonce','processNonce','snapshotId','generation','projectionDigest')) {
        if ($Projection.PSObject.Properties.Name -notcontains $key) { throw 'incompleteBinding' }
        $binding[$key]=$Projection.$key
    }
    if ($binding.requestNonce -cnotmatch '^[0-9a-f]{32}$' -or $binding.projectionDigest -cnotmatch '^[0-9a-f]{64}$' -or
        $binding.processNonce -isnot [string] -or -not $binding.processNonce -or $binding.snapshotId -isnot [string] -or -not $binding.snapshotId -or
        ($binding.generation -isnot [int] -and $binding.generation -isnot [long]) -or $binding.generation -lt 1 -or
        $Operation -cnotin @('plan','import','reference','cold','bootstrap','rollback','rollback-check')) { throw 'invalidBinding' }
    $binding.operation=$Operation
    return $binding
}
function Assert-PrestartBinding([Collections.IDictionary]$Expected,[Collections.IDictionary]$Actual) {
    if ($Actual.Count -ne $Expected.Count) { throw 'bindingMismatch' }
    foreach ($key in $Expected.Keys) {
        if (-not $Actual.Contains($key) -or $Actual[$key] -cne $Expected[$key]) { throw 'bindingMismatch' }
    }
}
function Assert-EffectEvidence([object]$Evidence,[string]$Phase) {
    # Called on independently collected, source/build-bound evidence, never on
    # the engine's self-reported effects or arbitrary caller engine hashes.
    foreach ($key in @('phase','sourceBound','wholeJob','applicationWriteCoverage','networkCoverage','droppedEvents','applicationWrites','networkRequests','activeProcesses')) {
        if ($Evidence.PSObject.Properties.Name -notcontains $key) { throw 'effectEvidenceIncomplete' }
    }
    if ($Evidence.phase -cne $Phase -or $Evidence.sourceBound -cne $true -or $Evidence.wholeJob -cne $true -or
        $Evidence.applicationWriteCoverage -cne 'complete' -or $Evidence.networkCoverage -cne 'complete' -or
        $Evidence.droppedEvents -ne 0) { throw 'effectEvidenceIncomplete' }
    foreach ($key in @('droppedEvents','applicationWrites','networkRequests','activeProcesses')) {
        if (($Evidence.$key -isnot [int] -and $Evidence.$key -isnot [long]) -or $Evidence.$key -lt 0) { throw 'effectEvidenceIncomplete' }
    }
    if ($Phase -cin @('prepare','complete','accept','abort','eof') -and ($Evidence.applicationWrites -ne 0 -or $Evidence.networkRequests -ne 0)) { throw 'forbiddenEffectObserved' }
    if ($Phase -ceq 'jobClosed' -and $Evidence.activeProcesses -ne 0) { throw 'ownedJobStillActive' }
}
function Get-PrestartCasePlan {
    @(
        @{id='prepare-abort';sequence=@('prepare','abort');expected='applicationWrites0/network0';seed='startup'},
        @{id='prepare-eof';sequence=@('prepare','EOF');expected='applicationWrites0/network0/jobActive0';seed='startup'},
        @{id='accept-before-complete';sequence=@('prepare','accept(initialBinding)');expected='reject incomplete context';seed='cold'},
        @{id='accept-no-activation';sequence=@('prepare','U-a','complete','accept','abort');expected='applicationWrites0/network0';seed='cold'},
        @{id='replay-old-generation';sequence=@('prepare','U-a','complete','accept(initialBinding)');expected='reject old generation';seed='cold'},
        @{id='wrong-binding';sequence=@('prepare','accept(changedNonce/processNonce/digest/operation)');expected='reject every altered field';seed='startup'},
        @{id='wrong-prepared-identity';sequence=@('prepare','guard(wrongJob/image/incarnation/channel)');expected='reject foreign PID exemption';seed='Go native guard fixture'},
        @{id='invalid-config';sequence=@('prepare');expected='reject malformed TOML without effects';seed='malformed'},
        @{id='sqlite-redirect-env';sequence=@('prepare(CODEX_SQLITE_HOME=H)');expected='reject marker presence even when H equal';seed='startup'},
        @{id='sqlite-redirect-toml';sequence=@('prepare(root sqlite_home=H)');expected='reject semantic root marker';seed='redirect'},
        @{id='reparse-home';sequence=@('prepare(reparse path)');expected='reject unsafe resolved path';seed='junction required in isolated fixture'},
        @{id='auth-maintenance';sequence=@('prepare(mock PAT/WIF/refresh/missing key)');expected='specific denial; keyring save/delete/refresh0';seed='unit Mock only'},
        @{id='cloud-cache-expired';sequence=@('prepare(expired signed cache)');expected='remote-required denial without refresh';seed='canonical signed unit fixture required'},
        @{id='changed-source';sequence=@('prepare','mutate captured config/absence/rollout','accept/activate');expected='reject stale captured input';seed='startup'},
        @{id='multi-cwd-v2';sequence=@('prepare(members)','U-a','complete','accept','activate','first/cold resume');expected='approved parent settings/cwd only';seed='canonical legacy/full-turns/v2 required'},
        @{id='metadata-change';sequence=@('prepare','U-a','mutate main/WAL','complete');expected='reject DB observation mismatch';seed='canonical cold'},
        @{id='readonly-shm';sequence=@('prepare','U-a','complete');expected='original main/WAL/SHM unchanged; same private generation; bounded private sidecars only';seed='fresh synthetic WAL fixture'},
        @{id='prepare-shm-write';sequence=@('prepare');expected='no DB open and no SHM exception';seed='startup'},
        @{id='activation-job-close';sequence=@('activate','initialize','EOF/timeout','Job close','final guard');expected='whole own Job active0 incl nested children';seed='canonical bootstrap'},
        @{id='ambiguous-activation';sequence=@('activate','drop ACK','close Job','inspect actual journal');expected='no activate replay; placing+ remains pending';seed='journal fault injection'},
        @{id='rollback-admission';sequence=@('fresh prepare','U-a','complete','explicit recover');expected='prefix/settings/foreign refs/attachments verified; no automatic delete';seed='canonical pending recovery'},
        @{id='protected-whitelist';sequence=@('initialize','thread/start','turn/start','config/auth/tool','unapproved resume');expected='reject every forbidden method/context';seed='existing synthetic seed only'}
    ) | ForEach-Object { [pscustomobject]@{id=$_.id;sequence=$_.sequence;expected=$_.expected;seed=$_.seed;engineStatus='notRun';needs=@('sealed source/provider/build pin','coordinator scenario agreement','complete effect observer')} }
}
function Get-PrestartConnectionPlan([object]$Provider=$null) {
    # Metadata is diagnostic only. Even plausible pins cannot authorize a run.
    $missing=@()
    foreach ($field in @('baseCommit','loaderContractId','engineSha256','normalEngineSha256')) {
        if ($null -eq $Provider -or $Provider.PSObject.Properties.Name -notcontains $field -or -not $Provider.$field) { $missing+=$field }
    }
    $phases=@(
        @{id='standalone-prepare';source=@('config/auth/cloud denial before effects','no SQLite open','no background worker spawn');os=@('all application file writes including transient','process/thread/descendant creation','DNS/connect/send including denied attempts');allowed='applicationWrites0/network0; no SHM exception'},
        @{id='complete-after-U-a';source=@('source raw lease retained through both readers','Go U-a reader closed before Rust canonical pool','same private acquisition and generation binding','Rust pool.close awaited on success and error; revalidate then close','private cleanup before source lease release');os=@('original main/WAL/SHM write and mapping activity','bounded private SHM and new empty WAL only','network attempts');allowed='original namespace unchanged/network0; private sidecars only'},
        @{id='accept-abort-eof';source=@('all six binding fields','incomplete/old generation rejected','accept never activates','EOF/abort cleanup');os=@('application writes/network attempts','whole owned Job descendants through active0');allowed='applicationWrites0/network0; Job closes'},
        @{id='activate-initialize';source=@('single activation after final accept','MCP/plugin/OTEL/init workers','stable RPC whitelist');os=@('file/network activity by phase','children and grandchildren','timeouts and Job termination');allowed='coordinator must seal activation effect policy'},
        @{id='legacy-paginated-full-child';source=@('canonical legacy/paginated/full-turns reader','approved parent settings/cwd','child membership and rollout digest','first resume whitelist');os=@('DB/rollout and auxiliary writes','per-member network attempts','worker descendants');allowed='scenario-specific sealed resume policy'},
        @{id='archived-cold';source=@('archived membership','canonical cold export without new turn/start','DB/WAL/rollout consistency','fresh complete binding');os=@('archive/session file effects','main/WAL/SHM by exact phase','network and owned Job');allowed='scenario-specific sealed cold policy'},
        @{id='rollback-pending';source=@('fresh prepare/complete','prefix/settings/foreign refs/attachments','placing+ stays pending on ambiguous ACK','no activation replay or automatic deletion');os=@('permitted recovery writes only','network attempts','whole Job active0 before final observation');allowed='explicit sealed recovery policy'}
    ) | ForEach-Object { [pscustomobject]@{id=$_.id;sourceInstrumentation=$_.source;independentOsCoverage=$_.os;allowedEffects=$_.allowed;engineStatus='notRun';coverage='unverified'} }
    return [ordered]@{
        schemaVersion=1;purpose='connection preparation only';runnerStatus='blocked';engineExecuted=$false;engineAcceptance='notRun'
        providerMetadataMissing=@($missing);providerTrust='notValidated';productionGuard='notMeasured'
        lanes=@(
            @{id='production-guard-negative';entry='original guard(nil)';expected='record actual reason, including engine_open while Codex is open';engineLaunches=0;status='notRun'},
            @{id='pinned-provider-fixture';entry='serial Go TestPinnedProvider... in _test.go';status='notRun';guardAdapter=@('replace checkGuard only','p != nil must call p.provePrepared()','nil success restricted to owned fixture','save callback and restore with t.Cleanup');preserved=@('prepareEngine=openEngine','readState=checkDB','RPC and protected image handles/hash','native suspended launch and owned Job','SQL and projection binding');forbidden=@('runtime production bypass switch','test assignment of executable pins','mock provider substituted for actual provider')}
        )
        requiredSeals=@('source commit + archive digest + build receipt','compiled protected/normal image pins + loader contract','canonical synthetic seed provenance','coordinator phase/scenario agreement','activation runtime completeness','OS capture permissions and positive calibration','observer configuration + parser + loss statistics + whole Job correlation')
        observerContract=@{
            window='start before suspended provider resumes; end after whole Job active0'
            identity='PID + creation time + locked image identity + Job descendants + phase timestamps'
            loss='controller EventsLost/LogBuffersLost/RealTimeBuffersLost and decoded trace loss must be zero; EVENT_TRACE_LOGFILEW.EventsLost is not used'
            limits=@('file tree hash detects final state only','source counters and stderr are not independent OS coverage','registered providers do not prove capture permission','PID filters alone may miss service-mediated effects','zero events without positive calibration is not absence evidence')
        }
        backendFixture=@{
            purpose='fresh synthetic same-generation backend preparation';status='notRun';engineLaunches=0
            sourceSqliteOpens=0;historicalExportRepeats=0;runtimeCompatibility='notTested'
            schemaEvidence=@{
                kind='historical schema-only observation; never a fresh acquisition'
                exportSha256='d48353071f9d9e9f178a8cb836e2a72732a43cf666cf1b892972b9cba0be6032'
                comparisonSha256='2329654e2a14a7bf45bba726e249a3e3745e6fef708e6f78ff6c888b112f7f95'
                objectCount=60;migrationCount=58;checksumEncoding='CRLF SHA384';canonicalEngineSchemaSeal=$false
            }
            sequence=@('create fresh owned synthetic DB with source-bound schema and invented rows; close seed writer',
                'Go acquireSnapshot pins raw source and creates exactly one protected private main/existing WAL copy',
                'Go WinSQLite U-a reads private only; close statements/database/DLL before Rust reader',
                'retain Go source lease; Rust validate_acquisition opens the identical private path and identity',
                'one Rust bundledSQLite canonical pool decodes every member; no migrations/init/repair',
                'await pool.close on success/error; revalidate private/source and explicitly close validator',
                'Go verifies source/private; cleans registered private files; releases source handles',
                'source-only fresh raw identity/size/hash/absence revalidation; no provider activation')
            cases=@('missing WAL/SHM','existing empty WAL','WAL-only committed row absent from main',
                'existing stale source SHM never copied','multiple members share one canonical pool',
                'decoder/query error still closes every reader','different private copy/generation rejected',
                'changed original/copied main or existing WAL rejected','new nonempty private WAL rejected',
                'unknown private file/reparse/hardlink/unprotected ACL rejected','cleanup/close failure blocks success')
            requiredEvidence=@('fixed Go/Rust commit+archive+test executable hashes and exact selectors',
                'fresh synthetic seed recipe/rows/schema provenance; no historical DB bytes copied',
                'acquisitionId + source/private native identity/size/hash at every reader boundary',
                'system WinSQLite DLL identity/hash and actual bundled SQLite source/version',
                'same canonical member metadata before/after; WAL-only row decoded by both backends',
                'private sidecar inventory and close/cleanup/source-release outcome on success/error')
            unresolved=@('helper2 Go test-only cross-backend lifecycle hook',
                'helper1 canonical pool/decoder test-only hook and fixed artifact',
                'source/build schema byte normalization and lifecycle seal',
                'unknown schema/other stores remain needs_attention; no support PASS')
        }
        phases=@($phases)
    }
}
function New-PrestartConnectionPlan([string]$Root) {
    $path=Assert-OwnedFixturePath $Root
    if (Test-Path -LiteralPath $path) { throw 'fixtureOutputExists' }
    $provider=$null
    $providerFile=Join-Path $PSScriptRoot 'engine/provider.json'
    if (Test-Path -LiteralPath $providerFile) { $provider=Get-Content -LiteralPath $providerFile -Raw -Encoding UTF8 | ConvertFrom-Json }
    $plan=Get-PrestartConnectionPlan $provider
    $path=New-FixtureOutput $path
    Write-FixtureJson (Join-Path $path 'connection-plan.json') $plan
    return $plan
}
function Invoke-SchemaCommand([string]$Executable,[string[]]$Arguments,[string]$Log) {
    $ErrorActionPreference='Continue'
    $lines=@(& $Executable @Arguments 2>&1); $code=$LASTEXITCODE
    $ErrorActionPreference='Stop'
    Write-FixtureText $Log (($lines -join "`n")+"`n")
    if ($code -ne 0) { throw "schemaCommandFailed:${code}:$Executable" }
}
function Get-SchemaMigrationComparison([object[]]$Migrations,[string]$Directory) {
    $root=Assert-FixtureReadPath $Directory
    $files=@(Get-ChildItem -LiteralPath $root -File -Filter '*.sql' | Sort-Object Name)
    if ($files.Count -ne 58 -or $Migrations.Count -ne 58) { throw 'schemaMigrationSetIncomplete' }
    $seen=@{}; $comparison=@()
    $sha384=[Security.Cryptography.SHA384]::Create()
    try {
        foreach ($file in $files) {
            if ($file.Name -cnotmatch '^([0-9]{4})_.+\.sql$') { throw 'schemaMigrationName' }
            $version=[int]$Matches[1]
            $rows=@($Migrations | Where-Object version -eq $version)
            if ($version -lt 1 -or $version -gt 58 -or $seen.ContainsKey($version) -or $rows.Count -ne 1 -or
                $rows[0].checksum -cnotmatch '^[0-9A-Fa-f]{96}$' -or $rows[0].success -notin @($true,1)) { throw 'schemaMigrationSetIncomplete' }
            $seen[$version]=$true
            $bytes=[IO.File]::ReadAllBytes($file.FullName)
            $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
            if ($text.Contains("`r") -or $text.StartsWith([string][char]0xFEFF,[StringComparison]::Ordinal)) { throw 'schemaSourceNotLf' }
            $lf=([BitConverter]::ToString($sha384.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
            $crlfBytes=$script:Utf8.GetBytes($text.Replace("`n","`r`n"))
            $crlf=([BitConverter]::ToString($sha384.ComputeHash($crlfBytes))).Replace('-','').ToLowerInvariant()
            $observed=$rows[0].checksum.ToLowerInvariant()
            $comparison+=[pscustomobject]@{version=$version;file=$file.Name;sourceSha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant();lfSha384=$lf;crlfSha384=$crlf;observedChecksum=$observed;matchesLf=($observed -ceq $lf);matchesCrlf=($observed -ceq $crlf)}
        }
    } finally { $sha384.Dispose() }
    return [ordered]@{baseCommit='ff6aec96948b70d94983af2641a6b67c94faeff5';migrationCount=58;allMatchLf=(@($comparison|Where-Object { -not $_.matchesLf }).Count -eq 0);allMatchCrlf=(@($comparison|Where-Object { -not $_.matchesCrlf }).Count -eq 0);rows=$comparison;runtimeCompatibility='notTested'}
}
function Assert-SyntheticSchemaReceipt([object]$Receipt) {
    foreach ($field in @('engineExecutions','sourceSQLiteOpens','sqlDirectWrites','threadRowsExported')) {
        if ($Receipt.PSObject.Properties.Name -notcontains $field -or ($Receipt.$field -isnot [int] -and $Receipt.$field -isnot [long]) -or $Receipt.$field -ne 0) { throw 'schemaForbiddenExecutionOrExport' }
    }
    if ($Receipt.kind -cne 'observed-synthetic-state-schema' -or $Receipt.status -cne 'observed' -or
        $Receipt.source -cne (Get-RunnerSetting 'schemaOriginSource') -or
        $Receipt.sourceMainWALUnchanged -cne $true -or $Receipt.sourceSHMCopied -cne $false -or
        $Receipt.privateCopiesRemoved -cne $true -or $Receipt.sourceReadShareHandlesDrained -cne $true -or
        $Receipt.privateSQLiteReadersDrained -cne $true -or $Receipt.canonicalEngineSchemaSeal -cne $false -or
        $Receipt.dll.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $Receipt.migrationCount -ne 58) { throw 'schemaObservationIncomplete' }
    foreach ($object in @($Receipt.objects)) {
        if ($object.type -cin @('table','view') -and $Receipt.tableXinfo.PSObject.Properties.Name -cnotcontains $object.name) { throw 'schemaXinfoIncomplete' }
    }
}
function Invoke-SyntheticSchemaExport([string]$Root,[string]$Archive,[string]$Commit) {
    $path=Assert-OwnedFixturePath $Root
    $archivePath=Assert-FixtureReadPath $Archive
    if ($Commit -cnotmatch '^[0-9a-f]{40}$') { throw 'schemaSourceCommitRequired' }
    if (Test-Path -LiteralPath $path) { throw 'fixtureOutputExists' }
    if (-not [IO.File]::Exists($archivePath) -or -not [string]::Equals($PSScriptRoot,(Join-Path (Split-Path $archivePath) 'source'),[StringComparison]::OrdinalIgnoreCase)) { throw 'schemaFixedArchiveRequired' }
    $repo=Assert-FixtureReadPath (Get-RunnerSetting 'sourceRepository')
    $stateRepo=Assert-FixtureReadPath (Get-RunnerSetting 'stateRepository')
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $receipt=[ordered]@{schemaVersion=1;purpose='synthetic schema observation only';sourceCommit=$Commit;engineExecuted=$false;traceStarted=$false;debugLaunches=0;engineAcceptance='notRun';runnerStatus='failed';step='archive'}
    try {
        $reference=Join-Path $path 'source-reference.tar'
        Invoke-SchemaCommand 'git' @('-C',$repo,'-c','core.autocrlf=false','archive','--format=tar',('--output='+$reference),$Commit) (Join-Path $path 'archive.log')
        $receipt.sourceArchiveSha256=(Get-FileHash -LiteralPath $archivePath).Hash.ToLowerInvariant()
        if ((Get-FileHash -LiteralPath $reference).Hash.ToLowerInvariant() -cne $receipt.sourceArchiveSha256) { throw 'schemaArchiveCommitMismatch' }
        $receipt.runnerSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant()
        $receipt.step='build'
        Invoke-ConfiguredToolchain
        $env:CGO_ENABLED='0'; $env:GOWORK='off'; $env:GOPROXY='off'; $env:GOSUMDB='off'; $env:GOFLAGS=''; $env:GOEXPERIMENT=''
        $go=Join-Path $env:GOROOT 'bin/go.exe'
        $receipt.goSha256=(Get-FileHash -LiteralPath $go).Hash.ToLowerInvariant()
        $receipt.goVersion=(& $go version) -join ''
        if ($LASTEXITCODE -ne 0 -or $receipt.goVersion -cne 'go version go1.27.1 windows/amd64') { throw 'schemaGoVersion' }
        $testExe=Join-Path $path 'schema-export.test.exe'
        Push-Location -LiteralPath (Join-Path $PSScriptRoot 'impl/codex')
        try { Invoke-SchemaCommand $go @('test','-c','-tags','ctxhop_schema_export','-trimpath','-buildvcs=false','-o',$testExe,'.') (Join-Path $path 'build.log') } finally { Pop-Location }
        Invoke-SchemaCommand $testExe @('-test.list','^TestExportCanonicalSyntheticSchema$') (Join-Path $path 'test-list.log')
        if ((Get-Content -LiteralPath (Join-Path $path 'test-list.log') -Raw).Trim() -cne 'TestExportCanonicalSyntheticSchema') { throw 'schemaExporterMissing' }
        $receipt.testExeSha256=(Get-FileHash -LiteralPath $testExe).Hash.ToLowerInvariant()
        $originReport=Assert-FixtureReadPath (Get-RunnerSetting 'schemaOriginReport')
        $receipt.seedOriginReportSha256=(Get-FileHash -LiteralPath $originReport).Hash.ToLowerInvariant()
        if ($receipt.seedOriginReportSha256 -cne (Get-RunnerSetting 'schemaOriginReportSha256')) { throw 'schemaSeedProvenanceChanged' }
        $receipt.step='private-schema-query'
        $exportRoot=Join-Path $path 'schema-export'
        Invoke-SchemaCommand $testExe (@('-test.run','^TestExportCanonicalSyntheticSchema$','-test.count=1','-test.v',
            ('-ctxhop-schema-export-output='+$exportRoot))+@(Get-RunnerMetadataArguments)) (Join-Path $path 'export.log')
        $exportFile=Join-Path $exportRoot 'schema-export.json'
        $export=Get-Content -LiteralPath $exportFile -Raw | ConvertFrom-Json
        Assert-SyntheticSchemaReceipt $export
        $receipt.exportSha256=(Get-FileHash -LiteralPath $exportFile).Hash.ToLowerInvariant()
        $receipt.step='migration-comparison'
        $migrationTar=Join-Path $path 'state-migrations.tar'; $migrationRoot=Join-Path $path 'normal-source'
        Invoke-SchemaCommand 'git' @('-C',$stateRepo,'-c','core.autocrlf=false','archive','--format=tar',('--output='+$migrationTar),'ff6aec96948b70d94983af2641a6b67c94faeff5','codex-rs/state/migrations') (Join-Path $path 'migration-archive.log')
        [IO.Directory]::CreateDirectory($migrationRoot) | Out-Null
        Invoke-SchemaCommand 'tar' @('-xf',$migrationTar,'-C',$migrationRoot) (Join-Path $path 'migration-extract.log')
        $receipt.migrationArchiveSha256=(Get-FileHash -LiteralPath $migrationTar).Hash.ToLowerInvariant()
        $comparison=Get-SchemaMigrationComparison @($export.migrations) (Join-Path $migrationRoot 'codex-rs/state/migrations')
        Write-FixtureJson (Join-Path $path 'migration-comparison.json') $comparison
        $receipt.objectCount=@($export.objects).Count; $receipt.allMigrationsMatchLf=$comparison.allMatchLf; $receipt.allMigrationsMatchCrlf=$comparison.allMatchCrlf
        $receipt.productionGuardObservation=$export.productionGuardObservation; $receipt.absoluteWriterExclusion=$export.absoluteWriterExclusion; $receipt.dll=$export.dll
        $receipt.runnerStatus='passed'; $receipt.step='complete'; $receipt.schemaSeal='observed synthetic objects/checksums; runtime compatibility not tested'
    } catch { $receipt.error=$_.Exception.Message; throw } finally { Write-FixtureJson (Join-Path $path 'schema-runner-result.json') $receipt }
    return $receipt
}
function Invoke-SyntheticSchemaComparison([string]$Root,[string]$ReceiptFile,[string]$MigrationsDirectory) {
    # Resume only pure postprocessing of already exported, owned artifacts.
    # This path has no Go/native SQLite, source acquisition or engine call.
    $path=Assert-OwnedFixturePath $Root
    $inputPath=Assert-FixtureReadPath $ReceiptFile
    $migrationPath=Assert-FixtureReadPath $MigrationsDirectory
    if (Test-Path -LiteralPath $path) { throw 'fixtureOutputExists' }
    $export=Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json
    Assert-SyntheticSchemaReceipt $export
    $comparison=Get-SchemaMigrationComparison @($export.migrations) $migrationPath
    [IO.Directory]::CreateDirectory($path) | Out-Null
    Write-FixtureJson (Join-Path $path 'migration-comparison.json') $comparison
    return [ordered]@{schemaVersion=1;purpose='postprocess existing synthetic schema receipt';runnerStatus='passed';engineExecuted=$false;traceStarted=$false;engineAcceptance='notRun';sourceSQLiteOpens=0;privateSQLiteOpens=0;exportReused=$true;exportSha256=(Get-FileHash -LiteralPath $inputPath).Hash.ToLowerInvariant();runnerSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant();objectCount=@($export.objects).Count;migrationCount=58;allMigrationsMatchLf=$comparison.allMatchLf;allMigrationsMatchCrlf=$comparison.allMatchCrlf;productionGuardObservation=$export.productionGuardObservation;absoluteWriterExclusion=$export.absoluteWriterExclusion;dll=$export.dll;runtimeCompatibility='notTested'}
}
function Invoke-EngineMigrationChecks([string]$Root,[string]$Archive,[string]$Commit,[string]$Builder,[string]$MigrationsArchive,[string]$ReceiptFile,[string]$Repository) {
    $path=Assert-OwnedFixturePath $Root
    $archivePath=Assert-FixtureReadPath $Archive
    $builderPath=Assert-FixtureReadPath $Builder
    $migrationTar=Assert-FixtureReadPath $MigrationsArchive
    $repositoryPath=Assert-FixtureReadPath $Repository
    $inputPath=Assert-FixtureReadPath $ReceiptFile
    if ($Commit -cnotmatch '^[0-9a-f]{40}$' -or -not [string]::Equals($PSScriptRoot,(Join-Path (Split-Path $archivePath) 'source'),[StringComparison]::OrdinalIgnoreCase)) { throw 'migrationFixedRunnerRequired' }
    if (Test-Path -LiteralPath $path) { throw 'fixtureOutputExists' }
    $builderHash=(Get-FileHash -LiteralPath $builderPath).Hash.ToLowerInvariant()
    $migrationHash=(Get-FileHash -LiteralPath $migrationTar).Hash.ToLowerInvariant()
    $exportHash=(Get-FileHash -LiteralPath $inputPath).Hash.ToLowerInvariant()
    if ($builderHash -cne '2e3ef406f69088ea70fff5ebd3a7c374eff46568ce052cc7e6f95e8a50586ab8' -or
        $migrationHash -cne '72a21d180a090593d4cafdd4c982ed222a840f1245b2648592bbf232c8e181e9' -or
        $exportHash -cne 'd48353071f9d9e9f178a8cb836e2a72732a43cf666cf1b892972b9cba0be6032') { throw 'migrationPinnedInputMismatch' }
    $export=Get-Content -LiteralPath $inputPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-SyntheticSchemaReceipt $export
    $builderText=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($builderPath))
    if ($builderText.Contains("`r") -or $builderText.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal)) { throw 'migrationBuilderNotLf' }
    $tokens=$null; $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($builderText,[ref]$tokens,[ref]$parseErrors)
    $functions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Convert-EngineMigrationLineEndings'},$true))
    if ($parseErrors.Count -ne 0 -or $functions.Count -ne 1) { throw 'migrationBuilderFunctionInvalid' }
    # Execute only the reviewed function extent. Builder top-level build code is never invoked.
    . ([scriptblock]::Create($functions[0].Extent.Text))
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $receipt=[ordered]@{schemaVersion=1;purpose='fixed builder migration byte checks';runnerStatus='failed';sourceCommit=$Commit;sourceRepository=$repositoryPath;builderCommit='21e120fa17d5e291965b1e18c20df269a57b327f';vendorCommit='ff6aec96948b70d94983af2641a6b67c94faeff5';builderSha256=$builderHash;migrationArchiveSha256=$migrationHash;exportSha256=$exportHash;exportReused=$true;exportRepeats=0;sourceSQLiteOpens=0;privateSQLiteOpens=0;engineExecuted=$false;engineAcceptance='notRun';compileExecuted=$false;runtimeCompatibility='notTested';productionAtomicity='notEstablished'}
    try {
        $reference=Join-Path $path 'runner-reference.tar'
        Invoke-SchemaCommand 'git' @('-C',$repositoryPath,'-c','core.autocrlf=false','archive','--format=tar',('--output='+$reference),$Commit) (Join-Path $path 'runner-archive.log')
        $receipt.runnerArchiveSha256=(Get-FileHash -LiteralPath $archivePath).Hash.ToLowerInvariant()
        if ((Get-FileHash -LiteralPath $reference).Hash.ToLowerInvariant() -cne $receipt.runnerArchiveSha256) { throw 'migrationRunnerArchiveMismatch' }
        $receipt.runnerSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant()
        $pristine=Join-Path $path 'pristine'
        [IO.Directory]::CreateDirectory($pristine) | Out-Null
        # Archive digest is pinned before extraction; every extracted path is then inventoried.
        Invoke-SchemaCommand 'tar' @('-xf',$migrationTar,'-C',$pristine) (Join-Path $path 'state-extract.log')
        $before=Get-FixtureTree $pristine
        $comparison=Get-SchemaMigrationComparison @($export.migrations) (Join-Path $pristine 'codex-rs/state/migrations')
        Assert-Fixture ($comparison.allMatchCrlf -and -not $comparison.allMatchLf) '58 expected CRLF checksums'
        $groups=@('migrations','logs_migrations','goals_migrations','memory_migrations','queue_migrations','thread_history_migrations')
        $groupChecks=@(); $totalFiles=0
        foreach ($group in $groups) {
            $files=@(Get-ChildItem -LiteralPath (Join-Path $pristine "codex-rs/state/$group") -File)
            Assert-Fixture ($files.Count -gt 0) "migration group present: $group"
            foreach ($file in $files) {
                $text=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($file.FullName))
                Assert-Fixture (-not $text.Contains("`r") -and -not $text.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal)) "LF input: $($file.Name)"
            }
            $totalFiles+=$files.Count; $groupChecks+=[ordered]@{group=$group;fileCount=$files.Count;before='LF/noBOM';after='pending'}
        }
        $positive=Join-Path $path 'positive'
        Copy-Item -LiteralPath $pristine -Destination $positive -Recurse
        $actual=@(Convert-EngineMigrationLineEndings $positive)
        Assert-Fixture ($actual.Count -eq $totalFiles) 'all six groups returned'
        $stateCount=0
        foreach ($row in $actual) {
            $file=Join-Path $positive $row.path
            $text=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($file))
            Assert-Fixture ($text.Contains("`r`n") -and -not $text.Replace("`r`n",'').Contains("`r") -and -not $text.Replace("`r`n",'').Contains("`n") -and -not $text.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal)) "CRLF output: $($row.path)"
            Assert-Fixture ($row.lfSha256 -ceq $before[$row.path].sha256 -and $row.crlfSha256 -ceq (Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -and $row.sqlxSha384 -ceq (Get-FileHash -LiteralPath $file -Algorithm SHA384).Hash.ToLowerInvariant()) "builder receipt hashes: $($row.path)"
            if ($row.path.StartsWith('codex-rs/state/migrations/',[StringComparison]::Ordinal)) {
                $version=[int]([IO.Path]::GetFileName($file).Substring(0,4))
                $expected=@($export.migrations | Where-Object version -eq $version)
                Assert-Fixture ($expected.Count -eq 1 -and $row.sqlxSha384 -ceq $expected[0].checksum.ToLowerInvariant()) "actual state checksum: $version"
                $stateCount++
            }
        }
        Assert-Fixture ($stateCount -eq 58) '58 actual state checksums match'
        foreach ($group in $groupChecks) { $group.after='CRLF/noBOM' }
        Write-FixtureJson (Join-Path $path 'normalized-migrations.json') $actual
        $negative=@()
        foreach ($kind in @('directory','file','crlf','bom','second-pass')) {
            $caseRoot=Join-Path $path ('negative-'+$kind)
            $copyFrom=if ($kind -ceq 'second-pass') { $positive } else { $pristine }
            Copy-Item -LiteralPath $copyFrom -Destination $caseRoot -Recurse
            $first=(Get-ChildItem -LiteralPath (Join-Path $caseRoot 'codex-rs/state/migrations') -File | Sort-Object Name | Select-Object -First 1).FullName
            $reason='migration source must be committed LF without BOM'
            if ($kind -ceq 'directory') {
                $declaration=Join-Path $caseRoot 'codex-rs/state/src/migrations.rs'
                $text=[IO.File]::ReadAllText($declaration)
                Write-FixtureText $declaration ($text.Replace('migrate!("./logs_migrations")','migrate!("./unreviewed_migrations")'))
                $reason='unreviewed migration directory'
            } elseif ($kind -ceq 'file') {
                Write-FixtureText (Join-Path $caseRoot 'codex-rs/state/migrations/0000_unreviewed-file.sql') "SELECT 1;`n"
                $reason='unreviewed migration file'
            } elseif ($kind -ceq 'crlf') {
                [IO.File]::WriteAllText($first,[IO.File]::ReadAllText($first).Replace("`n","`r`n"),$script:Utf8)
            } elseif ($kind -ceq 'bom') {
                [IO.File]::WriteAllText($first,([string][char]0xfeff+[IO.File]::ReadAllText($first)),$script:Utf8)
            }
            $observed=$null
            try { Convert-EngineMigrationLineEndings $caseRoot | Out-Null } catch { $observed=$_.Exception.Message }
            Assert-Fixture ($observed -ceq $reason) "negative rejected: $kind"
            $negative+=[ordered]@{case=$kind;status='passed';reason=$observed;casePreserved=$true;atomicityClaim=$false}
        }
        $pristineComparison=Compare-FixtureTree $before (Get-FixtureTree $pristine)
        Assert-Fixture $pristineComparison.unchanged 'pristine archive bytes unchanged'
        $receipt.groups=$groupChecks; $receipt.normalizedCount=$actual.Count; $receipt.stateMigrationCount=$stateCount
        $receipt.negativeCases=$negative; $receipt.runnerChecks=$script:FixtureChecks; $receipt.runnerStatus='passed'
    } catch { $receipt.error=$_.Exception.Message; throw } finally { Write-FixtureJson (Join-Path $path 'migration-check-result.json') $receipt }
    return $receipt
}

function Invoke-BoundedBackendCommand([string]$Executable,[string[]]$Arguments,[string]$Directory,[string]$Log) {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'backendRunnerRequiresPs7' }
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$Executable; $start.WorkingDirectory=$Directory; $start.UseShellExecute=$false
    $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::Start($start)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(210000)) { $process.Kill($true); $process.WaitForExit(); throw 'backendOwnedProcessTimeout' }
        $code=$process.ExitCode
        Write-FixtureText $Log ($stdout.Result+"`n"+$stderr.Result)
        if ($code -ne 0) { throw "backendCommandFailed:$code" }
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
        $process.Dispose()
    }
}
function Assert-BackendReadPath([string]$Path,[string]$CaseId) {
    if ($CaseId -cnotmatch '^[0-9a-f]{32}$' -or -not [IO.Path]::IsPathRooted($Path)) { throw 'backendCaseBindingInvalid' }
    $full=[IO.Path]::GetFullPath($Path)
    $root=Join-Path (Assert-FixtureReadPath (Get-RunnerSetting 'backendNamespaceParent')) $CaseId
    if (-not $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'backendReadOutsideCase' }
    $scan=$full
    while ($scan) {
        if ((Test-Path -LiteralPath $scan) -and ((Get-Item -LiteralPath $scan -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'backendReadReparse' }
        $scan=[IO.Path]::GetDirectoryName($scan)
    }
    return $full
}
function ConvertFrom-SeedJson([string]$Text) {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'seedRunnerRequiresPs7' }
    if ($Text.Contains("`r") -or $Text.StartsWith([string][char]0xfeff,[StringComparison]::Ordinal)) { throw 'seedJsonNotLfUtf8' }
    $document=[System.Text.Json.JsonDocument]::Parse($Text)
    try {
        $pending=[Collections.Generic.Stack[object]]::new(); $pending.Push($document.RootElement)
        while ($pending.Count) {
            $element=$pending.Pop()
            if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                foreach ($property in $element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) { throw 'seedDuplicateJsonKey' }
                    $pending.Push($property.Value)
                }
            } elseif ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                foreach ($value in $element.EnumerateArray()) { $pending.Push($value) }
            }
        }
        return ConvertFrom-Json -InputObject $Text -AsHashtable -Depth 64
    } finally { $document.Dispose() }
}
function Assert-SeedKeys([object]$Value,[string[]]$Keys) {
    if ($Value -isnot [Collections.IDictionary] -or $Value.Count -ne $Keys.Count) { throw 'seedObjectFields' }
    foreach ($key in $Keys) { if ($key -cnotin @($Value.Keys)) { throw 'seedObjectFields' } }
}
function Assert-SeedInteger([object]$Value,[long]$Minimum=0) {
    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt $Minimum) { throw 'seedIntegerType' }
}
function Assert-SeedHex([object]$Value,[int]$Length) {
    if ($Value -isnot [string] -or $Value -cnotmatch ('^[0-9a-f]{'+$Length+'}$')) { throw 'seedPinFormat' }
}
function Assert-SeedReadPath([object]$Path) {
    if ($Path -isnot [string] -or -not [IO.Path]::IsPathRooted($Path)) { throw 'seedPathNotAbsolute' }
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    try { $full=Assert-FixtureReadPath $full } catch { throw 'seedPathOutsideScope' }
    $scan=$full
    while ($scan) {
        if ((Test-Path -LiteralPath $scan) -and ((Get-Item -LiteralPath $scan -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'seedReparsePath' }
        $scan=[IO.Path]::GetDirectoryName($scan)
    }
    return $full
}
function Assert-SeedBuild([object]$Build) {
    Assert-SeedKeys $Build @('sourceCommit','lfSourceArchiveSha256','migrationLineEndings','migrationInventorySha256','cargoLockSha256','builderSha256','normalEngineSha256','rustVersion','target')
    Assert-SeedHex $Build.sourceCommit 40
    foreach ($key in @('lfSourceArchiveSha256','migrationInventorySha256','cargoLockSha256','builderSha256','normalEngineSha256')) { Assert-SeedHex $Build[$key] 64 }
    foreach ($key in @('migrationLineEndings','rustVersion','target')) { if ($Build[$key] -isnot [string]) { throw 'seedBuildProfileMismatch' } }
    if ($Build.migrationLineEndings -cne 'CRLF' -or $Build.builderSha256 -cne '2e3ef406f69088ea70fff5ebd3a7c374eff46568ce052cc7e6f95e8a50586ab8' -or
        $Build.normalEngineSha256 -cne 'cbafb6422bca005b94c12d105b1a16a0474219e24ea4893f85846409c464f5a1' -or $Build.rustVersion -cne '1.95.0' -or $Build.target -cne 'x86_64-pc-windows-msvc') { throw 'seedBuildProfileMismatch' }
}
function Assert-SeedManifest([object]$Manifest) {
    Assert-SeedKeys $Manifest @('schemaVersion','seedId','seedRoot','sqliteHome','stateReceipt','boardReceipt','build','artifacts','expectedMigrations')
    Assert-SeedInteger $Manifest.schemaVersion
    Assert-SeedHex $Manifest.seedId 32
    if ($Manifest.schemaVersion -ne 2 -or $Manifest.seedId -cne '51c980db2f43438eb1a8ca838045fae2') { throw 'seedNamespaceBinding' }
    $root=Join-Path (Assert-FixtureReadPath (Get-RunnerSetting 'seedNamespaceParent')) $Manifest.seedId
    foreach ($pair in @(@('seedRoot',$root),@('sqliteHome',($root+'\sqlite')),@('stateReceipt',($root+'\receipts\state-seed.json')),@('boardReceipt',($root+'\receipts\board-seed.json')))) {
        if (-not [string]::Equals((Assert-SeedReadPath $Manifest[$pair[0]]),$pair[1],[StringComparison]::OrdinalIgnoreCase)) { throw 'seedNamespaceBinding' }
    }
    Assert-SeedBuild $Manifest.build
    Assert-SeedKeys $Manifest.artifacts @('state','agentMessageBoard')
    $artifactPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($kind in @('state','agentMessageBoard')) {
        $artifact=$Manifest.artifacts[$kind]
        Assert-SeedKeys $artifact @('path','sha256','receiptPath','receiptSha256')
        foreach ($key in @('sha256','receiptSha256')) { Assert-SeedHex $artifact[$key] 64 }
        foreach ($key in @('path','receiptPath')) {
            $p=Assert-SeedReadPath $artifact[$key]
            if ($p.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $artifactPaths.Add($p)) { throw 'seedArtifactPathAlias' }
        }
        if (-not $artifact.path.EndsWith('.exe',[StringComparison]::OrdinalIgnoreCase)) { throw 'seedArtifactExecutablePath' }
    }
    $kinds=@('state','logs','goals','memories','memoriesV2','queue','threadHistory'); $counts=@(58,2,2,2,2,2,7)
    if ($Manifest.expectedMigrations -isnot [array] -or $Manifest.expectedMigrations.Count -ne 7) { throw 'seedMigrationOrder' }
    for ($i=0;$i -lt 7;$i++) {
        $group=$Manifest.expectedMigrations[$i]; Assert-SeedKeys $group @('kind','versions')
        if ($group.kind -isnot [string] -or $group.kind -cne $kinds[$i] -or $group.versions -isnot [array] -or $group.versions.Count -ne $counts[$i]) { throw 'seedMigrationOrder' }
        for ($j=0;$j -lt $counts[$i];$j++) {
            $row=$group.versions[$j]; Assert-SeedKeys $row @('version','checksumHex'); Assert-SeedInteger $row.version 1
            if ($row.version -ne $j+1) { throw 'seedMigrationVersion' }; Assert-SeedHex $row.checksumHex 96
        }
    }
    for ($j=0;$j -lt 2;$j++) { if ($Manifest.expectedMigrations[3].versions[$j].checksumHex -cne $Manifest.expectedMigrations[4].versions[$j].checksumHex) { throw 'seedMemoryMigrationMismatch' } }
}
function Assert-SeedPragmaRows([object]$Rows,[string]$Pragma) {
    $columns=switch ($Pragma) {
        'xinfo' { @('cid','name','type','notnull','dflt_value','pk','hidden') }
        'foreignKeys' { @('id','seq','table','from','to','on_update','on_delete','match') }
        'listEntry' { @('seq','name','unique','origin','partial') }
        'indexXinfo' { @('seqno','cid','name','desc','coll','key') }
        default { throw 'seedPragmaUnknown' }
    }
    $integers=@('cid','notnull','pk','hidden','id','seq','unique','partial','seqno','desc','key')
    $nullable=@('dflt_value','to','coll'); if ($Pragma -ceq 'indexXinfo') { $nullable+='name' }
    if ($Rows -isnot [array]) { throw 'seedPragmaRowsType' }
    foreach ($row in $Rows) {
        Assert-SeedKeys $row $columns
        foreach ($column in $columns) {
            $value=$row[$column]
            if ($column -cin $integers) { Assert-SeedInteger $value ([long]::MinValue) }
            elseif ($null -eq $value) { if ($column -cnotin $nullable) { throw 'seedPragmaStorageType' } }
            elseif ($value -isnot [string]) { throw 'seedPragmaStorageType' }
        }
    }
}
function Assert-SeedStoreInventory([object]$Store,[object]$Manifest,[int]$Index) {
    $kinds=@('state','logs','goals','memories','memoriesV2','queue','threadHistory','agentMessageBoard')
    $names=@('state_5.sqlite','logs_2.sqlite','goals_1.sqlite','memories_1.sqlite','memories_v2_1.sqlite','queue_1.sqlite','thread_history_1.sqlite','agent_message_board_1.sqlite')
    Assert-SeedKeys $Store @('kind','path','objects','tables','migrations','files')
    if ($Store.kind -isnot [string] -or $Store.kind -cne $kinds[$Index] -or -not [string]::Equals((Assert-SeedReadPath $Store.path),(Join-Path (Assert-SeedReadPath $Manifest.sqliteHome) $names[$Index]),[StringComparison]::OrdinalIgnoreCase)) { throw 'seedStoreOrderOrPath' }
    if ($Store.objects -isnot [array] -or -not $Store.objects.Count -or $Store.tables -isnot [array] -or -not $Store.tables.Count) { throw 'seedInventoryMissing' }
    $objects=@{}; $tables=@(); $previous=$null
    foreach ($o in $Store.objects) {
        Assert-SeedKeys $o @('type','name','table','sql')
        if ($o.type -isnot [string] -or $o.type -cnotin @('table','index','trigger','view') -or $o.name -isnot [string] -or -not $o.name -or $o.table -isnot [string] -or -not $o.table -or ($null -ne $o.sql -and $o.sql -isnot [string])) { throw 'seedObjectStorageType' }
        $order=$o.type+[char]0+$o.name+[char]0+$o.table
        if ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous,$order) -ge 0) { throw 'seedObjectOrder' }; $previous=$order
        if ($objects.ContainsKey($o.name)) { throw 'seedObjectDuplicate' }; $objects[$o.name]=$o
        if ($o.type -ceq 'table') { $tables+=$o.name }
    }
    if ($Store.tables.Count -ne $tables.Count) { throw 'seedTableInventoryIncomplete' }
    $previous=$null; $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($table in $Store.tables) {
        Assert-SeedKeys $table @('name','xinfo','foreignKeys','indexes')
        if ($table.name -isnot [string] -or $table.name -cnotin $tables -or -not $seen.Add($table.name) -or ($null -ne $previous -and [StringComparer]::Ordinal.Compare($previous,$table.name) -ge 0)) { throw 'seedTableOrder' }; $previous=$table.name
        Assert-SeedPragmaRows $table.xinfo 'xinfo'; Assert-SeedPragmaRows $table.foreignKeys 'foreignKeys'
        if (-not $table.xinfo.Count -or $table.indexes -isnot [array]) { throw 'seedTableInventoryIncomplete' }
        $indexNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($indexEntry in $table.indexes) {
            Assert-SeedKeys $indexEntry @('name','listEntry','xinfo')
            Assert-SeedPragmaRows @($indexEntry.listEntry) 'listEntry'; Assert-SeedPragmaRows $indexEntry.xinfo 'indexXinfo'
            if ($indexEntry.name -isnot [string] -or $indexEntry.name -cne $indexEntry.listEntry.name -or -not $indexNames.Add($indexEntry.name) -or -not $objects.ContainsKey($indexEntry.name) -or $objects[$indexEntry.name].type -cne 'index' -or $objects[$indexEntry.name].table -cne $table.name) { throw 'seedIndexInventoryIncomplete' }
        }
        foreach ($o in $Store.objects) { if ($o.type -ceq 'index' -and $o.table -ceq $table.name -and -not $indexNames.Contains($o.name)) { throw 'seedIndexInventoryIncomplete' } }
    }
    if ($Index -eq 7) {
        if ($null -ne $Store.migrations -or '_sqlx_migrations' -cin $tables) { throw 'seedBoardMigrationTable' }
    } else {
        if ('_sqlx_migrations' -cnotin $tables -or $Store.migrations -isnot [array] -or $Store.migrations.Count -ne $Manifest.expectedMigrations[$Index].versions.Count) { throw 'seedMigrationReceiptMismatch' }
        for ($j=0;$j -lt $Store.migrations.Count;$j++) {
            $actual=$Store.migrations[$j]; $expected=$Manifest.expectedMigrations[$Index].versions[$j]
            Assert-SeedKeys $actual @('version','success','checksumHex'); Assert-SeedInteger $actual.version 1; Assert-SeedInteger $actual.success
            Assert-SeedHex $actual.checksumHex 96
            if ($actual.version -ne $expected.version -or $actual.success -ne 1 -or $actual.checksumHex -cne $expected.checksumHex) { throw 'seedMigrationReceiptMismatch' }
        }
    }
    if ($Store.files -isnot [array] -or $Store.files.Count -ne 4) { throw 'seedFileVectorOrder' }
    $fileKinds=@('main','WAL','SHM','rollbackJournal')
    for ($j=0;$j -lt 4;$j++) {
        $file=$Store.files[$j]; Assert-SeedKeys $file @('kind','present','identity','size','sha256')
        if ($file.kind -isnot [string] -or $file.kind -cne $fileKinds[$j] -or $file.present -isnot [bool]) { throw 'seedFileVectorOrder' }
        if ($file.present) { Assert-SeedHex $file.identity 24; Assert-SeedHex $file.sha256 64; Assert-SeedInteger $file.size }
        elseif ($null -ne $file.identity -or $null -ne $file.size -or $null -ne $file.sha256 -or $j -eq 0) { throw 'seedAbsentFileDescriptor' }
    }
}
function Assert-CanonicalSeedReceipt([object]$Receipt,[object]$Manifest,[string]$ManifestHash,[string]$Producer) {
    Assert-SeedKeys $Receipt @('schemaVersion','seedId','producer','manifestSha256','build','sqliteVersion','sqliteSourceId','allPoolsClosed','originalSQLiteOpens','engineExecutions','stores')
    Assert-SeedInteger $Receipt.schemaVersion; Assert-SeedInteger $Receipt.originalSQLiteOpens; Assert-SeedInteger $Receipt.engineExecutions
    Assert-SeedHex $Receipt.seedId 32; Assert-SeedHex $Receipt.manifestSha256 64
    if ($Receipt.producer -isnot [string]) { throw 'seedReceiptBinding' }
    if ($Receipt.schemaVersion -ne 2 -or $Receipt.seedId -cne $Manifest.seedId -or $Receipt.producer -cne $Producer -or $Receipt.manifestSha256 -cne $ManifestHash -or $Receipt.allPoolsClosed -isnot [bool] -or -not $Receipt.allPoolsClosed -or $Receipt.originalSQLiteOpens -ne 0 -or $Receipt.engineExecutions -ne 0) { throw 'seedReceiptBinding' }
    Assert-SeedBuild $Receipt.build
    foreach ($key in $Manifest.build.Keys) { if ($Receipt.build[$key] -cne $Manifest.build[$key]) { throw 'seedReceiptBuildMismatch' } }
    if ($Receipt.sqliteVersion -isnot [string] -or $Receipt.sqliteVersion -cnotmatch '^\d+\.\d+\.\d+$' -or $Receipt.sqliteSourceId -isnot [string] -or $Receipt.sqliteSourceId -cnotmatch '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d [0-9a-f]{64}$') { throw 'seedSqlitePinFormat' }
    $count=if ($Producer -ceq 'state') { 7 } elseif ($Producer -ceq 'agentMessageBoard') { 1 } else { throw 'seedReceiptProducer' }
    if ($Receipt.stores -isnot [array] -or $Receipt.stores.Count -ne $count) { throw 'seedReceiptStoreCount' }
    for ($i=0;$i -lt $count;$i++) { Assert-SeedStoreInventory $Receipt.stores[$i] $Manifest $(if ($Producer -ceq 'state') { $i } else { 7 }) }
}
function Assert-SeedArtifactReceipt([object]$Receipt,[object]$Manifest,[string]$Kind) {
    Assert-SeedKeys $Receipt @('schemaVersion','kind','build','executable','migrationInventory')
    Assert-SeedInteger $Receipt.schemaVersion; Assert-SeedBuild $Receipt.build
    if ($Receipt.schemaVersion -ne 2 -or $Receipt.kind -isnot [string] -or $Receipt.kind -cne $Kind) { throw 'seedArtifactReceiptBinding' }
    foreach ($key in $Manifest.build.Keys) { if ($Receipt.build[$key] -cne $Manifest.build[$key]) { throw 'seedArtifactReceiptBinding' } }
    Assert-SeedKeys $Receipt.executable @('path','sha256'); Assert-SeedKeys $Receipt.migrationInventory @('path','sha256')
    Assert-SeedHex $Receipt.executable.sha256 64; Assert-SeedHex $Receipt.migrationInventory.sha256 64
    if (-not [string]::Equals((Assert-SeedReadPath $Receipt.executable.path),(Assert-SeedReadPath $Manifest.artifacts[$Kind].path),[StringComparison]::OrdinalIgnoreCase) -or
        $Receipt.executable.sha256 -cne $Manifest.artifacts[$Kind].sha256 -or $Receipt.migrationInventory.sha256 -cne $Manifest.build.migrationInventorySha256) { throw 'seedArtifactReceiptBinding' }
    Assert-SeedReadPath $Receipt.migrationInventory.path | Out-Null
}
function Assert-SeedMigrationInventory([object]$Rows,[object]$Manifest) {
    if ($Rows -isnot [array] -or $Rows.Count -ne 73) { throw 'seedNormalizedInventoryCount' }
    $groups=@('migrations','logs_migrations','goals_migrations','memory_migrations','queue_migrations','thread_history_migrations')
    $indexes=@(0,1,2,3,5,6); $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $Rows) {
        Assert-SeedKeys $row @('path','lfSha256','crlfSha256','sqlxSha384')
        Assert-SeedHex $row.lfSha256 64; Assert-SeedHex $row.crlfSha256 64; Assert-SeedHex $row.sqlxSha384 96
        if ($row.path -isnot [string] -or $row.path -cnotmatch '^codex-rs/state/(migrations|logs_migrations|goals_migrations|memory_migrations|queue_migrations|thread_history_migrations)/([0-9]{4})_[A-Za-z0-9_-]+\.sql$' -or -not $seen.Add($row.path) -or $row.lfSha256 -ceq $row.crlfSha256) { throw 'seedNormalizedInventoryPath' }
        $group=$matches[1]; $version=[int]$matches[2]; $index=[array]::IndexOf($groups,$group)
        if ($index -lt 0 -or $version -lt 1 -or $version -gt $Manifest.expectedMigrations[$indexes[$index]].versions.Count -or
            $row.sqlxSha384 -cne $Manifest.expectedMigrations[$indexes[$index]].versions[$version-1].checksumHex) { throw 'seedNormalizedInventoryChecksum' }
    }
    for ($i=0;$i -lt $groups.Count;$i++) {
        $rowsForGroup=@($Rows | Where-Object { $_.path.StartsWith(('codex-rs/state/'+$groups[$i]+'/'),[StringComparison]::Ordinal) })
        if ($rowsForGroup.Count -ne $Manifest.expectedMigrations[$indexes[$i]].versions.Count) { throw 'seedNormalizedInventoryCount' }
        $versions=@($rowsForGroup | ForEach-Object { [int]([IO.Path]::GetFileName($_.path).Substring(0,4)) } | Sort-Object -Unique)
        if ($versions.Count -ne $rowsForGroup.Count) { throw 'seedNormalizedInventoryVersionDuplicate' }
    }
}
function Initialize-SeedNative {
    if ('CtxhopSeedNativeV2' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public sealed class CtxhopSeedFileInfoV2 {
    public string Identity;
    public string Path;
    public ulong Size;
    public uint Attributes;
    public uint Links;
}
public static class CtxhopSeedNativeV2 {
    [StructLayout(LayoutKind.Sequential)]
    private struct Info {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh,
            WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Info info);
    [DllImport("kernel32.dll", ExactSpelling=true, CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
    [DllImport("kernel32.dll", ExactSpelling=true, CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle CreateFileW(string path, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);
    public static SafeFileHandle OpenDirectory(string path) {
        var handle=CreateFileW(path, 0x80, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid) { int error=Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
        return handle;
    }
    public static CtxhopSeedFileInfoV2 Read(SafeFileHandle handle) {
        Info info;
        if (!GetFileInformationByHandle(handle,out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        var path=new StringBuilder(32768);
        uint length=GetFinalPathNameByHandleW(handle,path,(uint)path.Capacity,0);
        if (length==0) throw new Win32Exception(Marshal.GetLastWin32Error());
        if (length>=path.Capacity) throw new InvalidOperationException("seedFinalPathTooLong");
        string resolved=path.ToString();
        if (resolved.StartsWith(@"\\?\",StringComparison.Ordinal)) resolved=resolved.Substring(4);
        return new CtxhopSeedFileInfoV2 {
            Identity=String.Format("{0:x8}{1:x8}{2:x8}",info.Volume,info.IndexHigh,info.IndexLow),
            Path=resolved, Size=((ulong)info.SizeHigh<<32)|info.SizeLow,
            Attributes=info.Attributes, Links=info.Links
        };
    }
}
'@ | Out-Null
}
function Open-SeedFileLease([string]$Path,[string]$Hash=$null) {
    $full=Assert-SeedReadPath $Path; Initialize-SeedNative
    $stream=[IO.File]::Open($full,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $info=[CtxhopSeedNativeV2]::Read($stream.SafeFileHandle)
        if (($info.Attributes -band 0x410) -or $info.Links -ne 1 -or -not [string]::Equals($info.Path,$full,[StringComparison]::OrdinalIgnoreCase)) { throw 'seedRawFileAliasOrReparse' }
        if ($info.Size -gt [long]::MaxValue) { throw 'seedRawSizeOverflow' }
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $actual=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose(); $stream.Position=0 }
        $after=[CtxhopSeedNativeV2]::Read($stream.SafeFileHandle)
        if ($after.Identity -cne $info.Identity -or $after.Size -ne $info.Size -or ($Hash -and $actual -cne $Hash)) { throw 'seedRawFilePinMismatch' }
        return @{path=$full;stream=$stream;identity=$info.Identity;size=[long]$info.Size;sha256=$actual}
    } catch { $stream.Dispose(); throw }
}
function Read-SeedLeaseJson([object]$Lease) {
    if ($Lease.size -gt 16MB) { throw 'seedJsonTooLarge' }
    $Lease.stream.Position=0; $reader=[IO.BinaryReader]::new($Lease.stream,$script:Utf8,$true)
    try { $bytes=$reader.ReadBytes([int]$Lease.size) } finally { $reader.Dispose(); $Lease.stream.Position=0 }
    if ($bytes.Length -ne $Lease.size) { throw 'seedJsonReadIncomplete' }
    return ConvertFrom-SeedJson ([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
}
function Assert-SeedOwner([object]$Owner,[object]$Manifest,[string]$Hash) {
    Assert-SeedKeys $Owner @('schemaVersion','seedId','manifestSha256'); Assert-SeedInteger $Owner.schemaVersion
    Assert-SeedHex $Owner.seedId 32; Assert-SeedHex $Owner.manifestSha256 64
    if ($Owner.schemaVersion -ne 2 -or $Owner.seedId -cne $Manifest.seedId -or $Owner.manifestSha256 -cne $Hash) { throw 'seedOwnerBinding' }
}
function Get-SeedNamespaceVector([object]$Manifest,[string]$Stage,[Collections.Generic.List[object]]$DirectoryLeases) {
    $root=Assert-SeedReadPath $Manifest.seedRoot; $sqliteDirectory=Assert-SeedReadPath $Manifest.sqliteHome
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($directory in @($root,$sqliteDirectory,(Join-Path $root 'receipts'))) {
        $handle=[CtxhopSeedNativeV2]::OpenDirectory($directory); $DirectoryLeases.Add($handle)
        $info=[CtxhopSeedNativeV2]::Read($handle)
        if (-not ($info.Attributes -band 0x10) -or ($info.Attributes -band 0x400) -or -not $ids.Add($info.Identity) -or -not [string]::Equals($info.Path,$directory,[StringComparison]::OrdinalIgnoreCase)) { throw 'seedDirectoryIdentity' }
    }
    $expectedRoot=@('sqlite','receipts','seed-owner.json'); $expectedReceipts=@(if ($Stage -ceq 'state') { 'state-seed.json' } else { 'state-seed.json','board-seed.json' })
    foreach ($pair in @(@($root,$expectedRoot),@((Join-Path $root 'receipts'),$expectedReceipts))) {
        $entries=@(Get-ChildItem -LiteralPath $pair[0] -Force)
        if ($entries.Count -ne $pair[1].Count) { throw 'seedUnknownNamespace' }
        foreach ($entry in $entries) { if ($entry.Name -cnotin $pair[1] -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'seedUnknownNamespace' } }
    }
    return @($DirectoryLeases | Select-Object -Last 3 | ForEach-Object { ([CtxhopSeedNativeV2]::Read($_)).Identity })
}
function Assert-SeedRawVectors([object[]]$Stores,[object]$Manifest) {
    $allowed=@(); $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); [long]$total=0
    foreach ($store in $Stores) {
        for ($i=0;$i -lt 4;$i++) {
            $suffix=@('','-wal','-shm','-journal')[$i]; $path=Assert-SeedReadPath ($store.path+$suffix); $file=$store.files[$i]
            if (-not $file.present) { if (Test-Path -LiteralPath $path) { throw 'seedRawAbsenceMismatch' }; continue }
            $allowed+=[IO.Path]::GetFileName($path)
            if ($i -eq 3 -or ($i -eq 2 -and $file.size -gt 16MB)) { throw 'seedClosedSidecarUnexpected' }
            if ($i -lt 2) { if ($file.size -gt 1GB-$total) { throw 'seedRawSizeLimit' }; $total+=$file.size }
            $lease=Open-SeedFileLease $path $file.sha256
            try { if ($lease.identity -cne $file.identity -or $lease.size -ne $file.size -or -not $ids.Add($lease.identity)) { throw 'seedRawVectorMismatch' } } finally { $lease.stream.Dispose() }
        }
    }
    $entries=@(Get-ChildItem -LiteralPath (Assert-SeedReadPath $Manifest.sqliteHome) -Force)
    if ($entries.Count -ne $allowed.Count) { throw 'seedUnknownSqliteEntry' }
    foreach ($entry in $entries) { if ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $entry.Name -cnotin $allowed) { throw 'seedUnknownSqliteEntry' } }
}
function Invoke-SeedSelector([string]$Executable,[string]$Selector,[string]$ManifestFile,[string]$Hash,[string]$Directory,[string]$Log) {
    $start=[Diagnostics.ProcessStartInfo]::new(); $start.FileName=$Executable; $start.WorkingDirectory=$Directory
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($argument in @('--exact',$Selector,'--ignored','--nocapture','--test-threads=1')) { $start.ArgumentList.Add($argument) }
    $start.Environment['CTXHOP_R45_SEED_MANIFEST']=$ManifestFile; $start.Environment['CTXHOP_R45_SEED_MANIFEST_SHA256']=$Hash
    $process=[Diagnostics.Process]::Start($start)
    $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
    try {
        if (-not $process.WaitForExit(210000)) { $process.Kill($true); if (-not $process.WaitForExit(5000)) { throw 'seedOwnedProcessStillActive' }; throw 'seedOwnedProcessTimeout' }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),5000)) { throw 'seedChildOutputNotDrained' }
        Write-FixtureText $Log ($stdout.Result+"`n"+$stderr.Result)
        if ($process.ExitCode -ne 0) { throw "seedSelectorFailed:$($process.ExitCode)" }
        return @{selector=$Selector;pid=$process.Id;exitCode=$process.ExitCode;parentProcessExited=$process.HasExited;wholeJobExit='notMeasured'}
    } finally {
        if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit(5000) | Out-Null }
        if ($stdout.IsCompletedSuccessfully -and $stderr.IsCompletedSuccessfully -and -not (Test-Path -LiteralPath $Log)) { Write-FixtureText $Log ($stdout.Result+"`n"+$stderr.Result) }
        Write-FixtureJson ($Log+'.process.json') @{pid=$process.Id;parentProcessExited=$process.HasExited;exitCode=$(if ($process.HasExited) { $process.ExitCode } else { $null });stdoutDrained=$stdout.IsCompletedSuccessfully;stderrDrained=$stderr.IsCompletedSuccessfully;wholeJobExit='notMeasured'}
        $process.Dispose()
    }
}
function Invoke-AggregateSchemaSeed([string]$Root,[string]$ManifestFile,[string]$ManifestHash,[string]$Archive,[string]$Commit,[string]$Repository,[string]$SeedArchive,[string]$CargoLock,[string]$Builder) {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'seedRunnerRequiresPs7' }
    $path=Assert-OwnedFixturePath $Root; $input=Assert-FixtureReadPath $ManifestFile
    Assert-SeedHex $ManifestHash 64
    if (Test-Path -LiteralPath $path) { throw 'fixtureOutputExists' }
    if ((Get-Item -LiteralPath $input).Length -gt 16MB -or (Get-FileHash -LiteralPath $input).Hash.ToLowerInvariant() -cne $ManifestHash) { throw 'seedManifestHashMismatch' }
    $manifest=ConvertFrom-SeedJson ([Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($input)))
    Assert-SeedManifest $manifest
    if (Test-Path -LiteralPath (Assert-SeedReadPath $manifest.seedRoot)) { throw 'seedNamespaceAlreadyExists' }
    if (-not $script:ApprovedSeedManifestSha256 -or $ManifestHash -cne $script:ApprovedSeedManifestSha256) { throw 'seedArtifactPinsNotBound' }
    $archivePath=Assert-FixtureReadPath $Archive; $repo=Assert-FixtureReadPath $Repository
    if ($Commit -cnotmatch '^[0-9a-f]{40}$' -or -not [string]::Equals($PSScriptRoot,(Join-Path (Split-Path $archivePath) 'source'),[StringComparison]::OrdinalIgnoreCase)) { throw 'seedFixedRunnerRequired' }
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $leases=[Collections.Generic.List[object]]::new(); $directories=[Collections.Generic.List[object]]::new()
    $summary=[ordered]@{schemaVersion=2;runnerStatus='failed';seedId=$manifest.seedId;manifestSha256=$ManifestHash;sourceCommit=$Commit;selectors=@();stateSelectorAttempted=$false;boardSelectorAttempted=$false;canonicalSchemaSeal=$false;seedNamespaceWriter='Rust canonical-seed role only';originalSQLiteOpens=0;engineExecuted=$false;engineAcceptance='notRun';runtimeCompatibility='notTested';completeEffects='notMeasured'}
    try {
        # Reparse only the hash-verified leased bytes before consuming paths or
        # artifact pins; the earlier unlocked grammar check is not authoritative.
        $manifestLease=Open-SeedFileLease $input $ManifestHash; $leases.Add($manifestLease)
        $manifest=Read-SeedLeaseJson $manifestLease; Assert-SeedManifest $manifest
        foreach ($pair in @(@($SeedArchive,$manifest.build.lfSourceArchiveSha256),@($CargoLock,$manifest.build.cargoLockSha256),@($Builder,$manifest.build.builderSha256))) { $leases.Add((Open-SeedFileLease $pair[0] $pair[1])) }
        $artifactPins=@{}
        foreach ($kind in @('state','agentMessageBoard')) {
            $artifact=$manifest.artifacts[$kind]; $exe=Open-SeedFileLease $artifact.path $artifact.sha256; $leases.Add($exe)
            $receiptLease=Open-SeedFileLease $artifact.receiptPath $artifact.receiptSha256; $leases.Add($receiptLease)
            $receipt=Read-SeedLeaseJson $receiptLease; Assert-SeedArtifactReceipt $receipt $manifest $kind
            $inventoryLease=Open-SeedFileLease $receipt.migrationInventory.path $receipt.migrationInventory.sha256; $leases.Add($inventoryLease)
            Assert-SeedMigrationInventory (Read-SeedLeaseJson $inventoryLease) $manifest
            $artifactPins[$kind]=@{executable=$exe.sha256;receipt=$receiptLease.sha256;migrationInventory=$inventoryLease.sha256}
        }
        $reference=Join-Path $path 'runner-reference.tar'
        Invoke-SchemaCommand 'git' @('-C',$repo,'-c','core.autocrlf=false','archive','--format=tar',('--output='+$reference),$Commit) (Join-Path $path 'runner-archive.log')
        if ((Get-FileHash -LiteralPath $reference).Hash -cne (Get-FileHash -LiteralPath $archivePath).Hash) { throw 'seedRunnerArchiveMismatch' }
        $summary.runnerArchiveSha256=(Get-FileHash -LiteralPath $archivePath).Hash.ToLowerInvariant(); $summary.runnerSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant(); $summary.artifactPins=$artifactPins
        $launchManifest=Join-Path $path 'manifest.json'
        $manifestLease.stream.Position=0; $reader=[IO.BinaryReader]::new($manifestLease.stream,$script:Utf8,$true)
        try { $bytes=$reader.ReadBytes([int]$manifestLease.size) } finally { $reader.Dispose(); $manifestLease.stream.Position=0 }
        if ($bytes.Length -ne $manifestLease.size) { throw 'seedJsonReadIncomplete' }
        [IO.File]::WriteAllBytes($launchManifest,$bytes)
        $leases.Add((Open-SeedFileLease $launchManifest $ManifestHash))
        if (Test-Path -LiteralPath (Assert-SeedReadPath $manifest.seedRoot)) { throw 'seedNamespaceAlreadyExists' }
        $summary.stateSelectorAttempted=$true
        $summary.selectors+=Invoke-SeedSelector $manifest.artifacts.state.path 'sqlite::prestart_seed_tests::create_canonical_store_seed_from_manifest' $launchManifest $ManifestHash $path (Join-Path $path 'state-selector.log')
        $summary.directoryIdentities=Get-SeedNamespaceVector $manifest 'state' $directories
        $ownerLease=Open-SeedFileLease (Join-Path $manifest.seedRoot 'seed-owner.json'); $leases.Add($ownerLease); Assert-SeedOwner (Read-SeedLeaseJson $ownerLease) $manifest $ManifestHash
        $stateLease=Open-SeedFileLease $manifest.stateReceipt; $leases.Add($stateLease); $state=Read-SeedLeaseJson $stateLease
        Assert-CanonicalSeedReceipt $state $manifest $ManifestHash 'state'; Assert-SeedRawVectors @($state.stores) $manifest
        $summary.stateReceiptSha256=$stateLease.sha256; $summary.ownerSha256=$ownerLease.sha256
        $summary.boardSelectorAttempted=$true
        $summary.selectors+=Invoke-SeedSelector $manifest.artifacts.agentMessageBoard.path 'local::prestart_seed_tests::create_canonical_board_seed_from_manifest' $launchManifest $ManifestHash $path (Join-Path $path 'board-selector.log')
        $afterDirectories=Get-SeedNamespaceVector $manifest 'board' $directories
        if (($afterDirectories -join ',') -cne ($summary.directoryIdentities -join ',')) { throw 'seedDirectoryChanged' }
        $boardLease=Open-SeedFileLease $manifest.boardReceipt; $leases.Add($boardLease); $board=Read-SeedLeaseJson $boardLease
        Assert-CanonicalSeedReceipt $board $manifest $ManifestHash 'agentMessageBoard'
        if ($board.sqliteVersion -cne $state.sqliteVersion -or $board.sqliteSourceId -cne $state.sqliteSourceId) { throw 'seedSqliteBuildMismatch' }
        $stores=@($state.stores)+@($board.stores); Assert-SeedRawVectors $stores $manifest
        $summary.boardReceiptSha256=$boardLease.sha256; $summary.stores=$stores; $summary.sqliteVersion=$state.sqliteVersion; $summary.sqliteSourceId=$state.sqliteSourceId
        $summary.canonicalSchemaSeal=$true; $summary.runnerStatus='passed'; $summary.seedNamespacePreserved=$true
    } catch { $summary.error=$_.Exception.Message; throw } finally {
        $closeFailures=@()
        foreach ($lease in $leases) { try { $lease.stream.Dispose() } catch { $closeFailures+=$_.Exception.Message } }
        foreach ($directory in $directories) { try { $directory.Dispose() } catch { $closeFailures+=$_.Exception.Message } }
        $summary.readerLeasesClosed=($closeFailures.Count -eq 0)
        if ($closeFailures.Count) { $summary.runnerStatus='failed'; $summary.canonicalSchemaSeal=$false; $summary.closeErrors=$closeFailures }
        if (Test-Path -LiteralPath $path) { Write-FixtureJson (Join-Path $path 'aggregate-schema-seed-result.json') $summary }
        if ($closeFailures.Count) { throw 'seedReadLeaseCloseFailed' }
    }
    return $summary
}
function Invoke-AggregateSeedChecks([string]$Root) {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'seedRunnerRequiresPs7' }
    $path=Assert-OwnedFixturePath $Root
    if (Test-Path -LiteralPath $path) { throw 'fixtureOutputExists' }
    [IO.Directory]::CreateDirectory($path) | Out-Null
    # Synthetic JSON only: these format-valid hashes/inventories are never seed
    # provenance, actual SQLite schema, or eligible executable launch pins.
    $seedRoot=Join-Path (Assert-FixtureReadPath (Get-RunnerSetting 'seedNamespaceParent')) '51c980db2f43438eb1a8ca838045fae2'
    $syntheticArtifacts=Join-Path $path 'synthetic-contract-artifacts'
    $kinds=@('state','logs','goals','memories','memoriesV2','queue','threadHistory'); $counts=@(58,2,2,2,2,2,7)
    $expected=@()
    for ($i=0;$i -lt 7;$i++) { $versions=@(); for ($j=1;$j -le $counts[$i];$j++) { $versions+=@{version=$j;checksumHex=('1'*96)} }; $expected+=@{kind=$kinds[$i];versions=$versions} }
    $manifest=@{schemaVersion=2;seedId='51c980db2f43438eb1a8ca838045fae2';seedRoot=$seedRoot;sqliteHome=($seedRoot+'\sqlite');stateReceipt=($seedRoot+'\receipts\state-seed.json');boardReceipt=($seedRoot+'\receipts\board-seed.json');expectedMigrations=$expected
        build=@{sourceCommit=('a'*40);lfSourceArchiveSha256=('a'*64);migrationLineEndings='CRLF';migrationInventorySha256=('b'*64);cargoLockSha256=('c'*64);builderSha256='2e3ef406f69088ea70fff5ebd3a7c374eff46568ce052cc7e6f95e8a50586ab8';normalEngineSha256='cbafb6422bca005b94c12d105b1a16a0474219e24ea4893f85846409c464f5a1';rustVersion='1.95.0';target='x86_64-pc-windows-msvc'}
        artifacts=@{state=@{path=(Join-Path $syntheticArtifacts 'state.exe');sha256=('a'*64);receiptPath=(Join-Path $syntheticArtifacts 'state.json');receiptSha256=('b'*64)};agentMessageBoard=@{path=(Join-Path $syntheticArtifacts 'board.exe');sha256=('c'*64);receiptPath=(Join-Path $syntheticArtifacts 'board.json');receiptSha256=('d'*64)}}}
    Assert-SeedManifest (ConvertFrom-SeedJson (ConvertTo-Json $manifest -Depth 30 -Compress))
    $negative=@(
        @{name='null-pin';reason='seedPinFormat';change={param($m) $m.artifacts.state.sha256=$null}},
        @{name='description-pin';reason='seedPinFormat';change={param($m) $m.build.sourceCommit='fixed helper1 source commit, 40 lower hex'}},
        @{name='LF-profile';reason='seedBuildProfileMismatch';change={param($m) $m.build.migrationLineEndings='LF'}},
        @{name='profile-array';reason='seedBuildProfileMismatch';change={param($m) $m.build.rustVersion=@('1.95.0')}},
        @{name='unknown-field';reason='seedObjectFields';change={param($m) $m.extra=1}},
        @{name='missing-field';reason='seedObjectFields';change={param($m) $m.Remove('artifacts') | Out-Null}},
        @{name='wrong-seed-id';reason='seedNamespaceBinding';change={param($m) $m.seedId=('a'*32)}},
        @{name='receipt-inside-SQL';reason='seedNamespaceBinding';change={param($m) $m.stateReceipt=($m.sqliteHome+'\state-seed.json')}},
        @{name='artifact-alias';reason='seedArtifactPathAlias';change={param($m) $m.artifacts.agentMessageBoard.path=$m.artifacts.state.path}},
        @{name='missing-store';reason='seedMigrationOrder';change={param($m) $m.expectedMigrations=@($m.expectedMigrations | Select-Object -First 6)}},
        @{name='reordered-store';reason='seedMigrationOrder';change={param($m) $m.expectedMigrations[0].kind='logs'}},
        @{name='kind-array';reason='seedMigrationOrder';change={param($m) $m.expectedMigrations[0].kind=@('state')}},
        @{name='migration-version-string';reason='seedIntegerType';change={param($m) $m.expectedMigrations[0].versions[0].version='1'}},
        @{name='missing-migration';reason='seedMigrationOrder';change={param($m) $m.expectedMigrations[0].versions=@($m.expectedMigrations[0].versions | Select-Object -First 57)}},
        @{name='memory-v2-checksum';reason='seedMemoryMigrationMismatch';change={param($m) $m.expectedMigrations[4].versions[0].checksumHex=('2'*96)}}
    )
    foreach ($case in $negative) {
        $bad=ConvertFrom-SeedJson (ConvertTo-Json $manifest -Depth 30 -Compress); & $case.change $bad
        Assert-FixtureThrows { Assert-SeedManifest $bad } $case.reason
    }
    Assert-FixtureThrows { ConvertFrom-SeedJson '{"seedId":"one","seedId":"two"}' } 'seedDuplicateJsonKey'
    Assert-FixtureThrows { ConvertFrom-SeedJson '{"outer":{"pin":null,"pin":"two"}}' } 'seedDuplicateJsonKey'
    Assert-FixtureThrows { ConvertFrom-SeedJson ([string][char]0xfeff+'{}') } 'seedJsonNotLfUtf8'
    $pragma=@{cid=0;name='synthetic';type='INTEGER';notnull=1;dflt_value=$null;pk=1;hidden=0}
    Assert-SeedPragmaRows @($pragma) 'xinfo'
    $bad=ConvertFrom-SeedJson (ConvertTo-Json $pragma -Compress); $bad.notnull=$true
    Assert-FixtureThrows { Assert-SeedPragmaRows @($bad) 'xinfo' } 'seedIntegerType'
    $bad=ConvertFrom-SeedJson (ConvertTo-Json $pragma -Compress); $bad.dflt_value=0
    Assert-FixtureThrows { Assert-SeedPragmaRows @($bad) 'xinfo' } 'seedPragmaStorageType'
    $bad=ConvertFrom-SeedJson (ConvertTo-Json $pragma -Compress); $bad.notNull=$bad.notnull; $bad.Remove('notnull') | Out-Null
    Assert-FixtureThrows { Assert-SeedPragmaRows @($bad) 'xinfo' } 'seedObjectFields'
    $board=@{kind='agentMessageBoard';path=($manifest.sqliteHome+'\agent_message_board_1.sqlite');objects=@(@{type='table';name='synthetic';table='synthetic';sql='synthetic inventory only'});tables=@(@{name='synthetic';xinfo=@($pragma);foreignKeys=@();indexes=@()});migrations=$null;files=@(@{kind='main';present=$true;identity=('a'*24);size=4096;sha256=('b'*64)})+@(@('WAL','SHM','rollbackJournal') | ForEach-Object { @{kind=$_;present=$false;identity=$null;size=$null;sha256=$null} })}
    Assert-SeedStoreInventory $board $manifest 7
    $indexedBoard=ConvertFrom-SeedJson (ConvertTo-Json $board -Depth 30 -Compress)
    $indexedBoard.objects=@(@{type='index';name='synthetic_index';table='synthetic';sql='synthetic inventory only'})+@($indexedBoard.objects)
    $indexedBoard.tables[0].indexes=@(@{name='synthetic_index';listEntry=@{seq=0;name='synthetic_index';unique=0;origin='c';partial=0};xinfo=@(@{seqno=0;cid=0;name='synthetic';desc=0;coll='BINARY';key=1},@{seqno=1;cid=-1;name=$null;desc=0;coll='BINARY';key=0})})
    Assert-SeedStoreInventory $indexedBoard $manifest 7
    Assert-Fixture $true 'indexed inventory preserves integer store ordinal'
    $bad=ConvertFrom-SeedJson (ConvertTo-Json $indexedBoard -Depth 30 -Compress); $bad.tables[0].indexes=@()
    Assert-FixtureThrows { Assert-SeedStoreInventory $bad $manifest 7 } 'seedIndexInventoryIncomplete'
    $bad=ConvertFrom-SeedJson (ConvertTo-Json $board -Depth 30 -Compress); $bad.migrations=@()
    Assert-FixtureThrows { Assert-SeedStoreInventory $bad $manifest 7 } 'seedBoardMigrationTable'
    $bad=ConvertFrom-SeedJson (ConvertTo-Json $board -Depth 30 -Compress); $bad.files[1].size=0
    Assert-FixtureThrows { Assert-SeedStoreInventory $bad $manifest 7 } 'seedAbsentFileDescriptor'
    $bad=ConvertFrom-SeedJson (ConvertTo-Json $board -Depth 30 -Compress); $bad.files[0].present='true'
    Assert-FixtureThrows { Assert-SeedStoreInventory $bad $manifest 7 } 'seedFileVectorOrder'
    $stateStores=@(); $dbNames=@('state_5.sqlite','logs_2.sqlite','goals_1.sqlite','memories_1.sqlite','memories_v2_1.sqlite','queue_1.sqlite','thread_history_1.sqlite')
    for ($i=0;$i -lt 7;$i++) {
        $store=ConvertFrom-SeedJson (ConvertTo-Json $board -Depth 30 -Compress)
        $store.kind=$kinds[$i]; $store.path=($manifest.sqliteHome+'\'+$dbNames[$i]); $store.objects[0].name='_sqlx_migrations'; $store.objects[0].table='_sqlx_migrations'; $store.tables[0].name='_sqlx_migrations'
        $store.migrations=@($expected[$i].versions | ForEach-Object { @{version=$_.version;success=1;checksumHex=$_.checksumHex} }); $stateStores+=$store
    }
    $stateReceipt=@{schemaVersion=2;seedId=$manifest.seedId;producer='state';manifestSha256=('e'*64);build=$manifest.build;sqliteVersion='3.51.3';sqliteSourceId=('2026-03-13 10:38:09 '+('f'*64));allPoolsClosed=$true;originalSQLiteOpens=0;engineExecutions=0;stores=$stateStores}
    Assert-CanonicalSeedReceipt $stateReceipt $manifest ('e'*64) 'state'
    $receiptNegative=@(
        @{name='closed-string';reason='seedReceiptBinding';change={param($r) $r.allPoolsClosed='True'}},
        @{name='not-closed';reason='seedReceiptBinding';change={param($r) $r.allPoolsClosed=$false}},
        @{name='engine-executed';reason='seedReceiptBinding';change={param($r) $r.engineExecutions=1}},
        @{name='original-sqlite-open';reason='seedReceiptBinding';change={param($r) $r.originalSQLiteOpens=1}},
        @{name='manifest-hash';reason='seedReceiptBinding';change={param($r) $r.manifestSha256=('d'*64)}},
        @{name='producer-array';reason='seedReceiptBinding';change={param($r) $r.producer=@('state')}},
        @{name='file-kind-array';reason='seedFileVectorOrder';change={param($r) $r.stores[0].files[0].kind=@('main')}},
        @{name='build-mismatch';reason='seedReceiptBuildMismatch';change={param($r) $r.build.cargoLockSha256=('d'*64)}},
        @{name='success-bool';reason='seedIntegerType';change={param($r) $r.stores[0].migrations[0].success=$true}},
        @{name='checksum-mismatch';reason='seedMigrationReceiptMismatch';change={param($r) $r.stores[0].migrations[0].checksumHex=('2'*96)}},
        @{name='missing-table-xinfo';reason='seedTableInventoryIncomplete';change={param($r) $r.stores[0].tables[0].xinfo=@()}},
        @{name='omitted-table';reason='seedInventoryMissing';change={param($r) $r.stores[0].tables=@()}},
        @{name='master-object-order';reason='seedObjectOrder';change={param($r) $r.stores[0].objects+=@{type='index';name='idx';table='_sqlx_migrations';sql='synthetic inventory only'}}}
    )
    foreach ($case in $receiptNegative) {
        $bad=ConvertFrom-SeedJson (ConvertTo-Json $stateReceipt -Depth 30 -Compress); & $case.change $bad
        Assert-FixtureThrows { Assert-CanonicalSeedReceipt $bad $manifest ('e'*64) 'state' } $case.reason
    }
    $artifactReceipt=@{schemaVersion=2;kind='state';build=$manifest.build;executable=@{path=$manifest.artifacts.state.path;sha256=$manifest.artifacts.state.sha256};migrationInventory=@{path=(Join-Path $syntheticArtifacts 'inventory.json');sha256=$manifest.build.migrationInventorySha256}}
    Assert-SeedArtifactReceipt $artifactReceipt $manifest 'state'
    foreach ($case in @(
        @{reason='seedObjectFields';change={param($r) $r.extra=1}},
        @{reason='seedArtifactReceiptBinding';change={param($r) $r.kind='agentMessageBoard'}},
        @{reason='seedArtifactReceiptBinding';change={param($r) $r.executable.sha256=('f'*64)}},
        @{reason='seedArtifactReceiptBinding';change={param($r) $r.migrationInventory.sha256=('f'*64)}},
        @{reason='seedPinFormat';change={param($r) $r.executable.sha256=$null}}
    )) {
        $bad=ConvertFrom-SeedJson (ConvertTo-Json $artifactReceipt -Depth 30 -Compress); & $case.change $bad
        Assert-FixtureThrows { Assert-SeedArtifactReceipt $bad $manifest 'state' } $case.reason
    }
    $groups=@('migrations','logs_migrations','goals_migrations','memory_migrations','queue_migrations','thread_history_migrations'); $groupCounts=@(58,2,2,2,2,7)
    $inventory=@()
    for ($i=0;$i -lt 6;$i++) { for ($j=1;$j -le $groupCounts[$i];$j++) { $inventory+=@{path=('codex-rs/state/'+$groups[$i]+'/'+$j.ToString('D4')+'_synthetic.sql');lfSha256=('a'*64);crlfSha256=('b'*64);sqlxSha384=('1'*96)} } }
    Assert-SeedMigrationInventory $inventory $manifest
    Assert-FixtureThrows { Assert-SeedMigrationInventory @($inventory | Select-Object -First 72) $manifest } 'seedNormalizedInventoryCount'
    foreach ($case in @(
        @{reason='seedNormalizedInventoryPath';change={param($r) $r[0].path='codex-rs/state/unknown/0001_synthetic.sql'}},
        @{reason='seedNormalizedInventoryPath';change={param($r) $r[1].path=$r[0].path}},
        @{reason='seedNormalizedInventoryChecksum';change={param($r) $r[0].sqlxSha384=('2'*96)}},
        @{reason='seedNormalizedInventoryPath';change={param($r) $r[0].crlfSha256=$r[0].lfSha256}},
        @{reason='seedNormalizedInventoryVersionDuplicate';change={param($r) $r[1].path='codex-rs/state/migrations/0001_other.sql'}}
    )) {
        $bad=ConvertFrom-SeedJson (ConvertTo-Json $inventory -Depth 30 -Compress); & $case.change $bad
        Assert-FixtureThrows { Assert-SeedMigrationInventory $bad $manifest } $case.reason
    }
    $owner=@{schemaVersion=2;seedId=$manifest.seedId;manifestSha256=('e'*64)}; Assert-SeedOwner $owner $manifest ('e'*64)
    $owner.manifestSha256=('f'*64); Assert-FixtureThrows { Assert-SeedOwner $owner $manifest ('e'*64) } 'seedOwnerBinding'
    $owner.manifestSha256=('e'*64); $owner.extra=1; Assert-FixtureThrows { Assert-SeedOwner $owner $manifest ('e'*64) } 'seedObjectFields'
    # Compile and check struct layout only. No Win32 API or raw file read is
    # invoked until actual artifacts and the reviewed manifest are bound.
    Initialize-SeedNative
    $nativeInfo=[CtxhopSeedNativeV2].GetNestedType('Info',[Reflection.BindingFlags]::NonPublic)
    Assert-Fixture ([Runtime.InteropServices.Marshal]::SizeOf([type]$nativeInfo) -eq 52) 'Win32 information struct layout compiles'
    $manifestFile=Join-Path $path 'synthetic-manifest.json'; Write-FixtureJson $manifestFile $manifest
    $hash=(Get-FileHash -LiteralPath $manifestFile).Hash.ToLowerInvariant(); $blockedRoot=Join-Path $path 'must-not-be-created'
    Assert-FixtureThrows { Invoke-AggregateSchemaSeed $blockedRoot $manifestFile $hash } 'seedArtifactPinsNotBound'
    Assert-Fixture (-not (Test-Path -LiteralPath $blockedRoot) -and -not (Test-Path -LiteralPath $seedRoot)) 'pin gate precedes output or seed creation'
    return [ordered]@{schemaVersion=2;purpose='pure seed ABI checks using synthetic JSON, not a schema seal';runnerStatus='passed';runnerChecks=$script:FixtureChecks;manifestNegativeCases=$negative.Count;receiptNegativeCases=$receiptNegative.Count;nativeInteropCompiled=$true;nativeRawReads=0;seedNamespaceCreated=$false;seedSelectorsExecuted=0;SQLiteOpens=0;historicalExportRepeats=0;engineExecuted=$false;canonicalSchemaSeal=$false;runtimeCompatibility='notTested';engineAcceptance='notRun'}
}
function Invoke-BackendSequenceChecks([string]$Root,[string]$Archive,[string]$Commit,[string]$Repository,[string]$BackendArchive,[string]$BackendCommit,[string]$Requested) {
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'backendRunnerRequiresPs7' }
    $path=Assert-OwnedFixturePath $Root; $archivePath=Assert-FixtureReadPath $Archive
    $repo=Assert-FixtureReadPath $Repository; $goArchive=Assert-FixtureReadPath $BackendArchive
    if ($Commit -cnotmatch '^[0-9a-f]{40}$' -or $BackendCommit -cnotmatch '^[0-9a-f]{40}$' -or
        -not [string]::Equals($PSScriptRoot,(Join-Path (Split-Path $archivePath) 'source'),[StringComparison]::OrdinalIgnoreCase)) { throw 'backendFixedArchiveRequired' }
    if (Test-Path -LiteralPath $path) { throw 'fixtureOutputExists' }
    $rustExe=Assert-FixtureReadPath (Get-RunnerSetting 'backendRustExecutable')
    $rustArtifact=Assert-FixtureReadPath (Get-RunnerSetting 'backendRustArtifact')
    $rustExeHash=(Get-FileHash -LiteralPath $rustExe).Hash.ToLowerInvariant()
    $rustArtifactHash=(Get-FileHash -LiteralPath $rustArtifact).Hash.ToLowerInvariant()
    if ($rustExeHash -cne (Get-RunnerSetting 'backendRustExecutableSha256') -or
        $rustArtifactHash -cne (Get-RunnerSetting 'backendRustArtifactSha256')) { throw 'backendRustPinMismatch' }
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $allCases=@('checkpoint','empty-wal','wal-only','stale-shm','decoder-error','missing-private-copy','nonempty-new-wal','unknown-entry')
    $cases=if ($Requested) { @($Requested.Split(',')) } else { $allCases }
    if (@($cases | Where-Object { $_ -cnotin $allCases }).Count -or @($cases | Sort-Object -Unique).Count -ne $cases.Count) { throw 'backendCaseSelectionInvalid' }
    $caseResults=@($allCases | ForEach-Object { [ordered]@{case=$_;status='notRun';caseId=$null} })
    $summary=[ordered]@{schemaVersion=1;purpose='fresh state-only Go/Rust private acquisition helper compatibility';runnerStatus='failed';sourceCommit=$Commit;goSourceCommit=$BackendCommit;rustSourceCommit=(Get-RunnerSetting 'backendRustSourceCommit');rustTestExeSha256=$rustExeHash;rustArtifactSha256=$rustArtifactHash;engineExecuted=$false;engineAcceptance='notRun';runtimeAdmission='notTested';completeEffects='notMeasured';sourceSQLiteOpens=0;historicalExportRepeats=0;backendCasesExecuted=0;requestedCases=@($cases);creationWriter='checked-in Go test only';ownedTimeoutSeconds=210;goTestTimeout='3m';rustChildTimeout='2m';cases=$caseResults;connectionPlanAdditionalCases='notRun'}
    try {
        foreach ($lane in @(@{name='runner';archive=$archivePath;commit=$Commit},@{name='go';archive=$goArchive;commit=$BackendCommit})) {
            $reference=Join-Path $path ($lane.name+'-reference.tar')
            $archiveArguments=@('-C',$repo,'-c','core.autocrlf=false','archive','--format=tar',('--output='+$reference),$lane.commit)
            if ($lane.name -ceq 'go') { $archiveArguments+='impl/codex' }
            Invoke-SchemaCommand 'git' $archiveArguments (Join-Path $path ($lane.name+'-archive.log'))
            if ((Get-FileHash -LiteralPath $reference).Hash -cne (Get-FileHash -LiteralPath $lane.archive).Hash) { throw 'backendArchiveCommitMismatch' }
        }
        $summary.runnerArchiveSha256=(Get-FileHash -LiteralPath $archivePath).Hash.ToLowerInvariant()
        $summary.runnerSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant()
        $summary.goArchiveSha256=(Get-FileHash -LiteralPath $goArchive).Hash.ToLowerInvariant()
        $goSource=Join-Path $path 'go-source'; [IO.Directory]::CreateDirectory($goSource) | Out-Null
        Invoke-SchemaCommand 'tar' @('-xf',$goArchive,'-C',$goSource) (Join-Path $path 'go-extract.log')
        Get-FixtureTree $goSource | Out-Null
        Invoke-ConfiguredToolchain
        $env:CGO_ENABLED='0'; $env:GOWORK='off'; $env:GOPROXY='off'; $env:GOSUMDB='off'; $env:GOFLAGS=''; $env:GOEXPERIMENT=''
        $go=Join-Path $env:GOROOT 'bin/go.exe'; $testExe=Join-Path $path 'backend-sequence.test.exe'
        $summary.goToolSha256=(Get-FileHash -LiteralPath $go).Hash.ToLowerInvariant()
        $summary.goVersion=(& $go version) -join ''
        if ($LASTEXITCODE -ne 0 -or $summary.goVersion -cne 'go version go1.27.1 windows/amd64') { throw 'backendGoVersionMismatch' }
        $summary.winSqliteSha256=(Get-FileHash -LiteralPath (Join-Path ([Environment]::SystemDirectory) 'winsqlite3.dll')).Hash.ToLowerInvariant()
        $goDirectory=Join-Path $goSource 'impl/codex'
        Invoke-BoundedBackendCommand $go @('test','-c','-tags','ctxhop_schema_export,ctxhop_backend_sequence','-trimpath','-buildvcs=false','-o',$testExe,'.') $goDirectory (Join-Path $path 'go-build.log')
        $summary.goTestExeSha256=(Get-FileHash -LiteralPath $testExe).Hash.ToLowerInvariant()
        Invoke-BoundedBackendCommand $testExe @('-test.list','^TestBackendSequence$') $goDirectory (Join-Path $path 'test-list.log')
        if ((Get-Content -LiteralPath (Join-Path $path 'test-list.log') -Raw).Trim() -cne 'TestBackendSequence') { throw 'backendSelectorMissing' }
        foreach ($entry in @($caseResults | Where-Object { $_.case -cin $cases })) {
            $id=[guid]::NewGuid().ToString('N'); $entry.caseId=$id
            $caseRoot=Join-Path (Assert-FixtureReadPath (Get-RunnerSetting 'backendNamespaceParent')) $id
            if (Test-Path -LiteralPath $caseRoot) { throw 'backendCaseAlreadyExists' }
            $summary.backendCasesExecuted++; $entry.status='failed'
            Invoke-BoundedBackendCommand $testExe (@('-test.run','^TestBackendSequence$','-test.count=1','-test.timeout=3m','-test.v',
                ('-ctxhop-backend-case='+$entry.case),('-ctxhop-backend-case-id='+$id))+@(Get-RunnerMetadataArguments)) $goDirectory (Join-Path $path ($entry.case+'.log'))
            $manifestFile=Assert-BackendReadPath (Join-Path $caseRoot 'manifest.json') $id
            $goFile=Assert-BackendReadPath (Join-Path $caseRoot 'go-backend-receipt.json') $id
            $rustFile=Assert-BackendReadPath (Join-Path $caseRoot 'rust-backend-receipt.json') $id
            $manifest=Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $goReceipt=Get-Content -LiteralPath $goFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $rust=Get-Content -LiteralPath $rustFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $observation=$manifest.dbObservation; $acquisition=$observation.acquisition
            $sourceFile=Assert-BackendReadPath $observation.stateDb $id
            $privateFile=Assert-BackendReadPath (Join-Path $acquisition.private.directory 'state_5.sqlite') $id
            Assert-Fixture ($manifest.caseId -ceq $id -and $goReceipt.caseId -ceq $id -and $rust.caseId -ceq $id -and $goReceipt.case -ceq $entry.case) 'same backend case'
            Assert-Fixture ($goReceipt.acquisitionId -ceq $acquisition.acquisitionId -and $rust.acquisitionId -ceq $acquisition.acquisitionId -and $acquisition.schemaVersion -eq 1) 'same private acquisition'
            Assert-Fixture ([string]::Equals($sourceFile,(Join-Path $caseRoot 'source/state_5.sqlite'),[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($privateFile,(Join-Path $caseRoot 'private/state_5.sqlite'),[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($rust.sourceStateDb,$sourceFile,[StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($rust.privateStateDb,$privateFile,[StringComparison]::OrdinalIgnoreCase)) 'same source and private paths'
            Assert-Fixture ($goReceipt.manifestSha256 -ceq (Get-FileHash -LiteralPath $manifestFile).Hash.ToLowerInvariant() -and $goReceipt.rustReceiptSha256 -ceq (Get-FileHash -LiteralPath $rustFile).Hash.ToLowerInvariant() -and $goReceipt.rustTestExeSha256 -ceq $rustExeHash -and $goReceipt.rustArtifactSha256 -ceq $rustArtifactHash) 'backend receipt hash binding'
            $expected=if ($entry.case -ceq 'decoder-error') { 'stateMetadataUnknown' } elseif ($entry.case -cin @('missing-private-copy','nonempty-new-wal','unknown-entry')) { 'acquisitionUnknown' } else { $null }
            Assert-Fixture ($rust.reason -ceq $expected -and $manifest.expectedReason -ceq $expected) 'backend reason matches case'
            Assert-Fixture ($goReceipt.engineExecutions -eq 0 -and $goReceipt.sourceSQLiteOpens -eq 0 -and $goReceipt.sourceMainWALSHMPreserved -ceq $true -and $goReceipt.sourceHandlesDrained -ceq $true) 'source lease and engine boundary'
            foreach ($kind in @('main','wal','shm')) {
                $suffix=if ($kind -ceq 'main') { '' } else { '-'+$kind }
                $file=Assert-BackendReadPath ($sourceFile+$suffix) $id; $descriptor=$acquisition.source.$kind
                if ($null -eq $descriptor) { Assert-Fixture (-not (Test-Path -LiteralPath $file)) 'source sidecar absence' }
                else { Assert-Fixture ((Get-Item -LiteralPath $file).Length -eq $descriptor.size -and (Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant() -ceq $descriptor.sha256 -and $descriptor.identity -cmatch '^[0-9a-f]{24}$') 'raw final source bytes and descriptor' }
            }
            if ($entry.case -ceq 'unknown-entry') {
                Assert-Fixture ($goReceipt.privateRemoved -ceq $false -and (Test-Path -LiteralPath (Assert-BackendReadPath (Join-Path $acquisition.private.directory 'unknown-entry') $id))) 'unknown entry retained'
            } else { Assert-Fixture ($goReceipt.privateRemoved -ceq $true -and -not (Test-Path -LiteralPath $acquisition.private.directory)) 'private cleanup completed' }
            if ($null -eq $expected) { Assert-Fixture (@($rust.rows).Count -eq 2 -and $rust.rows[0].id -ceq $manifest.threadIds[0] -and $null -eq $rust.rows[1] -and $rust.rows[0].canonicalMetadataSha256 -cmatch '^[0-9a-f]{64}$') 'canonical present and missing member' }
            $entry.status='passed'; $entry.acquisitionId=$acquisition.acquisitionId; $entry.reason=$rust.reason
            $entry.manifestSha256=$goReceipt.manifestSha256; $entry.goReceiptSha256=(Get-FileHash -LiteralPath $goFile).Hash.ToLowerInvariant(); $entry.rustReceiptSha256=$goReceipt.rustReceiptSha256; $entry.goPrivateBackend=$goReceipt.goPrivateBackend; $entry.privateRemoved=$goReceipt.privateRemoved
        }
        $summary.runnerStatus='passed'; $summary.runnerChecks=$script:FixtureChecks
    } catch { $summary.error=$_.Exception.Message; throw } finally { Write-FixtureJson (Join-Path $path 'backend-sequence-result.json') $summary }
    return $summary
}

function New-PrestartFixtures([string]$Root) {
    $path=New-FixtureOutput $Root
    $fixtureHome=Join-Path $path 'home'; $cwd=Join-Path $path 'project'; $childCwd=Join-Path $path 'child-project'
    foreach ($directory in @($fixtureHome,$cwd,$childCwd)) { New-FixtureDirectory $directory }
    Write-FixtureText (Join-Path $fixtureHome 'config.toml') "# synthetic fixture; vendor policy flags remain unchanged`n"
    Write-FixtureText (Join-Path $path 'malformed-config.toml') "[unterminated`n"
    Write-FixtureText (Join-Path $path 'redirect-config.toml') ('sqlite_home = '+(ConvertTo-Json -InputObject $fixtureHome -Compress)+"`n")
    # An intentionally malformed database is valid only for rejection and
    # observer sensitivity tests. It is never labelled a canonical cold seed.
    Write-FixtureText (Join-Path $fixtureHome 'state_5.sqlite') "SYNTHETIC_INVALID_DB_FOR_REJECTION_ONLY`n"
    Write-FixtureText (Join-Path $fixtureHome 'state_5.sqlite-wal') "SYNTHETIC_INVALID_WAL_FOR_REJECTION_ONLY`n"
    $members=@(
        @{id='11111111-1111-4111-8111-111111111111';parentId=$null;role='root';rolloutPath=(Join-Path $fixtureHome 'root.jsonl');rolloutSha256=('1'*64)},
        @{id='22222222-2222-4222-8222-222222222222';parentId='11111111-1111-4111-8111-111111111111';role='child';rolloutPath=(Join-Path $fixtureHome 'child.jsonl');rolloutSha256=('2'*64)}
    )
    $startup=[ordered]@{contractVersion=1;requestNonce=('a'*32);operation='plan';home=$fixtureHome;cwd=$cwd;offline=$true;members=@()}
    $cold=[ordered]@{contractVersion=1;requestNonce=('b'*32);operation='cold';home=$fixtureHome;cwd=$cwd;offline=$true;members=$members}
    Write-FixtureJson (Join-Path $path 'prepare-startup.json') @{id=1;method='ctxhop/prepare';params=$startup}
    Write-FixtureJson (Join-Path $path 'prepare-cold-template.json') @{id=1;method='ctxhop/prepare';params=$cold;fixtureStatus='templateOnly';missing='canonical rollout bytes/digests/settings and DB schema'}
    $manifest=[ordered]@{schemaVersion=1;purpose='runner preparation only';home=$fixtureHome;cwd=$cwd;childCwd=$childCwd;engineExecuted=$false;engineAcceptance='notRun';canonicalColdSeed=$false;protectedForbidden=@('thread/start','turn/start','config/account/auth/tool changes');cases=@(Get-PrestartCasePlan)}
    Write-FixtureJson (Join-Path $path 'fixture-plan.json') $manifest
    return $manifest
}
function Invoke-PrestartRunnerChecks([string]$Root) {
    $manifest=New-PrestartFixtures $Root
    $before=Get-FixtureTree $manifest.home
    Assert-Fixture (Compare-FixtureTree $before (Get-FixtureTree $manifest.home)).unchanged 'unchanged files'
    $main=Join-Path $manifest.home 'state_5.sqlite'
    $original=[IO.File]::ReadAllText($main)
    Write-FixtureText $main ($original+'changed')
    Assert-Fixture (-not (Compare-FixtureTree $before (Get-FixtureTree $manifest.home)).unchanged) 'main DB mutation detected'
    Write-FixtureText $main $original
    $before=Get-FixtureTree $manifest.home
    $wal=Join-Path $manifest.home 'state_5.sqlite-wal'; $walOriginal=[IO.File]::ReadAllText($wal)
    Write-FixtureText $wal ($walOriginal+'changed')
    Assert-Fixture (-not (Compare-FixtureTree $before (Get-FixtureTree $manifest.home) @('state_5.sqlite-shm')).unchanged) 'WAL mutation never exempt'
    Write-FixtureText $wal $walOriginal
    $before=Get-FixtureTree $manifest.home
    $shm=Join-Path $manifest.home 'state_5.sqlite-shm'; Write-FixtureText $shm 'synthetic shm'
    Assert-Fixture (-not (Compare-FixtureTree $before (Get-FixtureTree $manifest.home)).unchanged) 'prepare SHM write rejected'
    $comparison=Compare-FixtureTree $before (Get-FixtureTree $manifest.home) @('state_5.sqlite-shm')
    Assert-Fixture ($comparison.unchanged -and $comparison.allowedShmChanges.Count -eq 1) 'exact complete SHM exception'
    Write-FixtureText (Join-Path $manifest.home 'unapproved-shm') 'not a DB descriptor'
    Assert-Fixture (-not (Compare-FixtureTree $before (Get-FixtureTree $manifest.home) @('state_5.sqlite-shm')).unchanged) 'other SHM not exempt'
    $outside=Join-Path ([IO.Path]::GetDirectoryName((Assert-OwnedFixturePath $Root))) 'outside'
    Assert-FixtureThrows { Assert-OwnedFixturePath $outside } 'fixturePathOutsideOwnership'
    Assert-FixtureThrows { Assert-OwnedFixturePath (Join-Path $Root '../outside') } 'fixturePathOutsideOwnership'
    $projection=[pscustomobject]@{requestNonce=('a'*32);processNonce='synthetic-process';snapshotId='synthetic-snapshot';generation=2;projectionDigest=('c'*64)}
    $binding=Get-PrestartBinding $projection 'cold'
    Assert-PrestartBinding $binding $binding
    foreach ($field in @('requestNonce','processNonce','snapshotId','generation','projectionDigest','operation')) {
        $bad=[ordered]@{}; foreach($key in $binding.Keys) { $bad[$key]=$binding[$key] }; $bad[$field]='changed'
        Assert-FixtureThrows { Assert-PrestartBinding $binding $bad } 'bindingMismatch'
    }
    $old=[ordered]@{}; foreach($key in $binding.Keys) { $old[$key]=$binding[$key] }; $old.generation=1
    Assert-FixtureThrows { Assert-PrestartBinding $binding $old } 'bindingMismatch'
    Assert-FixtureThrows { Get-PrestartBinding ([pscustomobject]@{requestNonce='bad'}) 'cold' } 'incompleteBinding'
    $evidence=[pscustomobject]@{phase='prepare';sourceBound=$true;wholeJob=$true;applicationWriteCoverage='complete';networkCoverage='complete';droppedEvents=0;applicationWrites=0;networkRequests=0;activeProcesses=1}
    Assert-EffectEvidence $evidence 'prepare'
    $evidence.networkRequests=1
    Assert-FixtureThrows { Assert-EffectEvidence $evidence 'prepare' } 'forbiddenEffectObserved'
    $evidence.networkRequests=0; $evidence.networkCoverage='stderrOnly'
    Assert-FixtureThrows { Assert-EffectEvidence $evidence 'prepare' } 'effectEvidenceIncomplete'
    $evidence.networkCoverage='complete'; $evidence.droppedEvents=1
    Assert-FixtureThrows { Assert-EffectEvidence $evidence 'prepare' } 'effectEvidenceIncomplete'
    $evidence.droppedEvents=0; $evidence.phase='jobClosed'
    Assert-FixtureThrows { Assert-EffectEvidence $evidence 'jobClosed' } 'ownedJobStillActive'
    $evidence.activeProcesses=0; Assert-EffectEvidence $evidence 'jobClosed'
    $evidence.networkRequests='0'
    Assert-FixtureThrows { Assert-EffectEvidence $evidence 'jobClosed' } 'effectEvidenceIncomplete'
    Assert-Fixture ($manifest.cases.Count -ge 20 -and @($manifest.cases | Where-Object engineStatus -cne 'notRun').Count -eq 0) 'engine checks remain notRun'
    return [ordered]@{schemaVersion=1;runnerStatus='passed';runnerChecks=$script:FixtureChecks;engineExecuted=$false;engineAcceptance='notRun';fixtureRoot=$Root;canonicalColdSeed=$false;effects=@{applicationWrites='notMeasured';network='notMeasured'};cases=$manifest.cases}
}
if ($RunnerMetadata) { Initialize-RunnerMetadata $RunnerMetadata $RunnerMetadataSha256 }
elseif ($RunnerMetadataSha256) { throw 'runnerMetadataFileRequired' }
if ($LibraryOnly) { return }
if ($Mode -ceq 'Engine') {
    # Fail closed before touching fixtures or accepting any arbitrary engine.
    [ordered]@{runnerStatus='blocked';reasonCode='engineExecutionNotApproved';engineExecuted=$false;engineAcceptance='notRun'} | ConvertTo-Json -Compress
    exit 2
}
if ($FixtureWorkspace) { $OutRoot=Initialize-FixtureWorkspace $FixtureWorkspace $OutRoot }
if (-not $OutRoot) { throw 'fixtureOutputRequired' }
$result=if ($Mode -ceq 'SelfTest') { Invoke-PrestartRunnerChecks $OutRoot } elseif ($Mode -ceq 'ConnectionPlan') { New-PrestartConnectionPlan $OutRoot } elseif ($Mode -ceq 'SchemaExport') { Invoke-SyntheticSchemaExport $OutRoot $SourceArchive $SourceCommit } elseif ($Mode -ceq 'SchemaCompare') { Invoke-SyntheticSchemaComparison $OutRoot $SchemaReceipt $StateMigrations } elseif ($Mode -ceq 'MigrationCheck') { Invoke-EngineMigrationChecks $OutRoot $SourceArchive $SourceCommit $BuilderScript $MigrationArchive $SchemaReceipt $SourceRepository } elseif ($Mode -ceq 'BackendCheck') { Invoke-BackendSequenceChecks $OutRoot $SourceArchive $SourceCommit $SourceRepository $GoArchive $GoCommit $BackendCases } elseif ($Mode -ceq 'AggregateSchemaSeed') { Invoke-AggregateSchemaSeed $OutRoot $SeedManifest $SeedManifestSha256 $SourceArchive $SourceCommit $SourceRepository $SeedSourceArchive $SeedCargoLock $BuilderScript } elseif ($Mode -ceq 'AggregateSchemaSeedChecks') { Invoke-AggregateSeedChecks $OutRoot } else { New-PrestartFixtures $OutRoot }
if ($script:PortableFixtureRoot) { $result.fixtureWorkspace=$script:PortableFixtureRoot; $result.fixtureProfile='portable synthetic preparation'; $result.powerShellVersion=$PSVersionTable.PSVersion.ToString() }
if ($script:RunnerConfiguration) { $result.runnerMetadataSha256=$script:RunnerConfigurationHash }
Write-FixtureJson (Join-Path $OutRoot 'runner-result.json') $result
$result | ConvertTo-Json -Depth 15
