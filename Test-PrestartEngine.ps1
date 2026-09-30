#requires -Version 5.1
<#
S4 fixture preparation and runner checks. No engine process is started here.
Use committed LF git archive bytes. Engine acceptance remains notRun until the
source/provider pin, effect boundary and scenarios are sealed by the coordinator.
File snapshots detect final differences; they do not prove absence of transient
writes or networking. Engine effects require independent complete observation.
#>
param(
    [ValidateSet('Prepare','SelfTest','ConnectionPlan','SchemaExport','SchemaCompare','MigrationCheck','Engine')][string]$Mode='SelfTest',
    [string]$OutRoot,
    [string]$SourceArchive,
    [string]$SourceCommit,
    [string]$SchemaReceipt,
    [string]$StateMigrations,
    [string]$BuilderScript,
    [string]$MigrationArchive,
    [switch]$LibraryOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$script:FixtureChecks=0
$script:Utf8=[Text.UTF8Encoding]::new($false)
function Assert-Fixture([bool]$Value,[string]$Message) {
    $script:FixtureChecks++
    if (-not $Value) { throw "fixtureAssertion:$Message" }
}
function Assert-FixtureThrows([scriptblock]$Body,[string]$Reason) {
    $found=$false
    try { & $Body | Out-Null } catch { $found=$_.Exception.Message -match [regex]::Escape($Reason) }
    Assert-Fixture $found $Reason
}
function Assert-OwnedFixturePath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'fixturePathNotAbsolute' }
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notmatch '^D:\\Go\\codex-s4\\helper3-r45-fixture-[A-Za-z0-9_-]+(?:\\|$)') { throw 'fixturePathOutsideOwnership' }
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
function Write-FixtureText([string]$Path,[string]$Text) {
    $full=Assert-OwnedFixturePath $Path
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
    if (Test-Path -LiteralPath $providerFile) { $provider=Get-Content -LiteralPath $providerFile -Raw | ConvertFrom-Json }
    $plan=Get-PrestartConnectionPlan $provider
    [IO.Directory]::CreateDirectory($path) | Out-Null
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
    $root=Assert-OwnedFixturePath $Directory
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
        $Receipt.source -cne 'D:\Go\codex-s4\run-helper2-v2-63fc48d2e59e48ef88ea7ef193662432\source-v2\state_5.sqlite' -or
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
    $archivePath=Assert-OwnedFixturePath $Archive
    if ($Commit -cnotmatch '^[0-9a-f]{40}$') { throw 'schemaSourceCommitRequired' }
    if (Test-Path -LiteralPath $path) { throw 'fixtureOutputExists' }
    if (-not [IO.File]::Exists($archivePath) -or -not [string]::Equals($PSScriptRoot,(Join-Path (Split-Path $archivePath) 'source'),[StringComparison]::OrdinalIgnoreCase)) { throw 'schemaFixedArchiveRequired' }
    $repo='D:\claude\세션인계\ctxhop-work-20260927\ctxhop-gui'
    $stateRepo='D:\claude\세션인계\ctxhop-work-20260927\codex-prestart-r45'
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $receipt=[ordered]@{schemaVersion=1;purpose='synthetic schema observation only';sourceCommit=$Commit;engineExecuted=$false;traceStarted=$false;debugLaunches=0;engineAcceptance='notRun';runnerStatus='failed';step='archive'}
    try {
        $reference=Join-Path $path 'source-reference.tar'
        Invoke-SchemaCommand 'git' @('-C',$repo,'-c','core.autocrlf=false','archive','--format=tar',('--output='+$reference),$Commit) (Join-Path $path 'archive.log')
        $receipt.sourceArchiveSha256=(Get-FileHash -LiteralPath $archivePath).Hash.ToLowerInvariant()
        if ((Get-FileHash -LiteralPath $reference).Hash.ToLowerInvariant() -cne $receipt.sourceArchiveSha256) { throw 'schemaArchiveCommitMismatch' }
        $receipt.runnerSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant()
        $receipt.step='build'
        . 'D:\Go\ctxhop-s4-toolchain-r45\Enter-R45Toolchain.ps1'
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
        $originReport='D:\Go\codex-s4\run-helper2-v2-63fc48d2e59e48ef88ea7ef193662432\report-helper2-v2.json'
        $receipt.seedOriginReportSha256=(Get-FileHash -LiteralPath $originReport).Hash.ToLowerInvariant()
        if ($receipt.seedOriginReportSha256 -cne '5a63f8b9f5a287fe4814d3797d6f175de1519d9e01519b8749665f8887c22007') { throw 'schemaSeedProvenanceChanged' }
        $receipt.step='private-schema-query'
        $exportRoot=Join-Path $path 'schema-export'
        Invoke-SchemaCommand $testExe @('-test.run','^TestExportCanonicalSyntheticSchema$','-test.count=1','-test.v',('-ctxhop-schema-export-output='+$exportRoot)) (Join-Path $path 'export.log')
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
    $inputPath=Assert-OwnedFixturePath $ReceiptFile
    $migrationPath=Assert-OwnedFixturePath $MigrationsDirectory
    if (Test-Path -LiteralPath $path) { throw 'fixtureOutputExists' }
    $export=Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json
    Assert-SyntheticSchemaReceipt $export
    $comparison=Get-SchemaMigrationComparison @($export.migrations) $migrationPath
    [IO.Directory]::CreateDirectory($path) | Out-Null
    Write-FixtureJson (Join-Path $path 'migration-comparison.json') $comparison
    return [ordered]@{schemaVersion=1;purpose='postprocess existing synthetic schema receipt';runnerStatus='passed';engineExecuted=$false;traceStarted=$false;engineAcceptance='notRun';sourceSQLiteOpens=0;privateSQLiteOpens=0;exportReused=$true;exportSha256=(Get-FileHash -LiteralPath $inputPath).Hash.ToLowerInvariant();runnerSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant();objectCount=@($export.objects).Count;migrationCount=58;allMigrationsMatchLf=$comparison.allMatchLf;allMigrationsMatchCrlf=$comparison.allMatchCrlf;productionGuardObservation=$export.productionGuardObservation;absoluteWriterExclusion=$export.absoluteWriterExclusion;dll=$export.dll;runtimeCompatibility='notTested'}
}
function Invoke-EngineMigrationChecks([string]$Root,[string]$Archive,[string]$Commit,[string]$Builder,[string]$MigrationsArchive,[string]$ReceiptFile) {
    $path=Assert-OwnedFixturePath $Root
    $archivePath=Assert-OwnedFixturePath $Archive
    $builderPath=Assert-OwnedFixturePath $Builder
    $migrationTar=Assert-OwnedFixturePath $MigrationsArchive
    $inputPath=Assert-OwnedFixturePath $ReceiptFile
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
    $receipt=[ordered]@{schemaVersion=1;purpose='fixed builder migration byte checks';runnerStatus='failed';sourceCommit=$Commit;builderCommit='21e120fa17d5e291965b1e18c20df269a57b327f';vendorCommit='ff6aec96948b70d94983af2641a6b67c94faeff5';builderSha256=$builderHash;migrationArchiveSha256=$migrationHash;exportSha256=$exportHash;exportReused=$true;exportRepeats=0;sourceSQLiteOpens=0;privateSQLiteOpens=0;engineExecuted=$false;engineAcceptance='notRun';compileExecuted=$false;runtimeCompatibility='notTested';productionAtomicity='notEstablished'}
    try {
        $reference=Join-Path $path 'runner-reference.tar'
        Invoke-SchemaCommand 'git' @('-C','D:\claude\세션인계\ctxhop-work-20260927\ctxhop-gui','-c','core.autocrlf=false','archive','--format=tar',('--output='+$reference),$Commit) (Join-Path $path 'runner-archive.log')
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

function New-PrestartFixtures([string]$Root) {
    $path=Assert-OwnedFixturePath $Root
    if (Test-Path -LiteralPath $path) { throw 'fixtureOutputExists' }
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $fixtureHome=Join-Path $path 'home'; $cwd=Join-Path $path 'project'; $childCwd=Join-Path $path 'child-project'
    foreach ($directory in @($fixtureHome,$cwd,$childCwd)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
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
    Assert-FixtureThrows { Assert-OwnedFixturePath 'D:\outside\home' } 'fixturePathOutsideOwnership'
    Assert-FixtureThrows { Assert-OwnedFixturePath 'D:\Go\codex-s4\helper3-r45-fixture-test\..\outside' } 'fixturePathOutsideOwnership'
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
if ($LibraryOnly) { return }
if ($Mode -ceq 'Engine') {
    # Fail closed before touching fixtures or accepting any arbitrary engine.
    [ordered]@{runnerStatus='blocked';reasonCode='engineExecutionNotApproved';engineExecuted=$false;engineAcceptance='notRun'} | ConvertTo-Json -Compress
    exit 2
}
if (-not $OutRoot) { throw 'fixtureOutputRequired' }
$result=if ($Mode -ceq 'SelfTest') { Invoke-PrestartRunnerChecks $OutRoot } elseif ($Mode -ceq 'ConnectionPlan') { New-PrestartConnectionPlan $OutRoot } elseif ($Mode -ceq 'SchemaExport') { Invoke-SyntheticSchemaExport $OutRoot $SourceArchive $SourceCommit } elseif ($Mode -ceq 'SchemaCompare') { Invoke-SyntheticSchemaComparison $OutRoot $SchemaReceipt $StateMigrations } elseif ($Mode -ceq 'MigrationCheck') { Invoke-EngineMigrationChecks $OutRoot $SourceArchive $SourceCommit $BuilderScript $MigrationArchive $SchemaReceipt } else { New-PrestartFixtures $OutRoot }
Write-FixtureJson (Join-Path $OutRoot 'runner-result.json') $result
$result | ConvertTo-Json -Depth 15
