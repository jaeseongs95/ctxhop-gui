#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('list','export','inspect','inspect-many','apply','recover','pending')][string]$Action,
    [string]$HomePath,
    [string]$Id,
    [string]$Archive,
    [string]$Cwd,
    [string]$Output,
    [string]$Request,
    [string]$Run,
    [string]$Token,
    [ValidateSet('skip','incoming')][string]$Choice='skip',
    [string]$Search='',
    [int]$Offset=0,
    [int]$Limit=200
)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
if (-not $HomePath) {
    $HomePath = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
}
# Same pinned backend SHA256, Python selection (backend\runtime.json), isolated mode (-I) and
# argument quoting as the Codex Desktop implementation (CodexDesktop.ps1).
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'CodexDesktop.ps1') -LibraryOnly
$nativeArgs = @($Action,'--home',$HomePath)
foreach ($pair in @(@('--id',$Id),@('--archive',$Archive),@('--cwd',$Cwd),@('--output',$Output),@('--request',$Request),@('--run',$Run),@('--token',$Token))) {
    if ($pair[1]) { $nativeArgs += [string]$pair[0],[string]$pair[1] }
}
if ($Action -eq 'list') {
    $nativeArgs += '--offset',[string]$Offset,'--limit',[string]$Limit
    if ($Search) { $nativeArgs += "--search=$Search" }
}
if ($Action -eq 'apply') { $nativeArgs += '--choice',$Choice }
try {
    Invoke-DesktopBackend $nativeArgs | ConvertTo-Json -Depth 30
} catch {
    $report = $_.Exception.Data['backendResult']
    if (-not $report) { $report = [pscustomobject]@{status='blocked'; reason=$_.Exception.Message} }
    $report | ConvertTo-Json -Depth 30
    exit 1
}
exit 0
