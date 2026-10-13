function Get-BuildPins([string]$RepositoryRoot) {
    $providerPath=Join-Path $RepositoryRoot 'engine\provider.json'
    $provider=Get-Content -LiteralPath $providerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($provider.engineSha256 -cnotmatch '^[0-9a-f]{64}$' -or $provider.normalEngineSha256 -cnotmatch '^[0-9a-f]{64}$' -or $provider.loaderContractId -cnotmatch '^ctxhop-prestart-v2:[0-9a-f]{64}$') { throw 'protected provider pins are not finalized' }
    $goAdapter=Get-Content -LiteralPath (Join-Path $RepositoryRoot 'CodexDesktop.ps1') -Raw -Encoding UTF8
    $goPin=[regex]::Match($goAdapter, "DesktopGoSHA256='([A-Fa-f0-9]{64})'")
    if (-not $goPin.Success) { throw 'Codex Go adapter pin is not finalized' }
    return [pscustomobject]@{Provider=$provider;GoPin=$goPin}
}
