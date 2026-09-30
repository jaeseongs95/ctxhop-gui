#requires -Version 5.1
<#
S4 fixture preparation and runner checks. No engine process is started here.
Use committed LF git archive bytes. Engine acceptance remains notRun until the
source/provider pin, effect boundary and scenarios are sealed by the coordinator.
File snapshots detect final differences; they do not prove absence of transient
writes or networking. Engine effects require independent complete observation.
#>
param(
    [ValidateSet('Prepare','SelfTest','Engine')][string]$Mode='SelfTest',
    [string]$OutRoot,
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
        @{id='readonly-shm';sequence=@('prepare','U-a','complete');expected='main/WAL0; exact observed stateDb-shm only';seed='canonical WAL fixture'},
        @{id='prepare-shm-write';sequence=@('prepare');expected='no DB open and no SHM exception';seed='startup'},
        @{id='activation-job-close';sequence=@('activate','initialize','EOF/timeout','Job close','final guard');expected='whole own Job active0 incl nested children';seed='canonical bootstrap'},
        @{id='ambiguous-activation';sequence=@('activate','drop ACK','close Job','inspect actual journal');expected='no activate replay; placing+ remains pending';seed='journal fault injection'},
        @{id='rollback-admission';sequence=@('fresh prepare','U-a','complete','explicit recover');expected='prefix/settings/foreign refs/attachments verified; no automatic delete';seed='canonical pending recovery'},
        @{id='protected-whitelist';sequence=@('initialize','thread/start','turn/start','config/auth/tool','unapproved resume');expected='reject every forbidden method/context';seed='existing synthetic seed only'}
    ) | ForEach-Object { [pscustomobject]@{id=$_.id;sequence=$_.sequence;expected=$_.expected;seed=$_.seed;engineStatus='notRun';needs=@('sealed source/provider/build pin','coordinator scenario agreement','complete effect observer')} }
}
function New-PrestartFixtures([string]$Root) {
    $path=Assert-OwnedFixturePath $Root
    if (Test-Path -LiteralPath $path) { throw 'fixtureOutputExists' }
    [IO.Directory]::CreateDirectory($path) | Out-Null
    $home=Join-Path $path 'home'; $cwd=Join-Path $path 'project'; $childCwd=Join-Path $path 'child-project'
    foreach ($directory in @($home,$cwd,$childCwd)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }
    Write-FixtureText (Join-Path $home 'config.toml') "# synthetic fixture; vendor policy flags remain unchanged`n"
    Write-FixtureText (Join-Path $path 'malformed-config.toml') "[unterminated`n"
    Write-FixtureText (Join-Path $path 'redirect-config.toml') ('sqlite_home = '+(ConvertTo-Json -InputObject $home -Compress)+"`n")
    # An intentionally malformed database is valid only for rejection and
    # observer sensitivity tests. It is never labelled a canonical cold seed.
    Write-FixtureText (Join-Path $home 'state_5.sqlite') "SYNTHETIC_INVALID_DB_FOR_REJECTION_ONLY`n"
    Write-FixtureText (Join-Path $home 'state_5.sqlite-wal') "SYNTHETIC_INVALID_WAL_FOR_REJECTION_ONLY`n"
    $members=@(
        @{id='11111111-1111-4111-8111-111111111111';parentId=$null;role='root';rolloutPath=(Join-Path $home 'root.jsonl');rolloutSha256=('1'*64)},
        @{id='22222222-2222-4222-8222-222222222222';parentId='11111111-1111-4111-8111-111111111111';role='child';rolloutPath=(Join-Path $home 'child.jsonl');rolloutSha256=('2'*64)}
    )
    $startup=[ordered]@{contractVersion=1;requestNonce=('a'*32);operation='plan';home=$home;cwd=$cwd;offline=$true;members=@()}
    $cold=[ordered]@{contractVersion=1;requestNonce=('b'*32);operation='cold';home=$home;cwd=$cwd;offline=$true;members=$members}
    Write-FixtureJson (Join-Path $path 'prepare-startup.json') @{id=1;method='ctxhop/prepare';params=$startup}
    Write-FixtureJson (Join-Path $path 'prepare-cold-template.json') @{id=1;method='ctxhop/prepare';params=$cold;fixtureStatus='templateOnly';missing='canonical rollout bytes/digests/settings and DB schema'}
    $manifest=[ordered]@{schemaVersion=1;purpose='runner preparation only';home=$home;cwd=$cwd;childCwd=$childCwd;engineExecuted=$false;engineAcceptance='notRun';canonicalColdSeed=$false;protectedForbidden=@('thread/start','turn/start','config/account/auth/tool changes');cases=@(Get-PrestartCasePlan)}
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
$result=if ($Mode -ceq 'SelfTest') { Invoke-PrestartRunnerChecks $OutRoot } else { New-PrestartFixtures $OutRoot }
Write-FixtureJson (Join-Path $OutRoot 'runner-result.json') $result
$result | ConvertTo-Json -Depth 15
