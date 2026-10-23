# test-connection.ps1 - probe the bridge with real requests
# usage: .\test-connection.ps1 [-Path https://api.github.com/zen] [-Https]
[CmdletBinding()]
param(
    [string]$Path = 'https://api.github.com/zen'
)

$ErrorActionPreference = 'Stop'
$cfg = Get-Content (Join-Path $PSScriptRoot 'bridge.settings.json') -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'bridge-port.ps1')
$endpoint = Find-BridgeEndpoint -Root $PSScriptRoot
if (-not $endpoint.Running) {
    Write-Host ("bridge is not running (preferred port {0}); start it with launch.opencode.ps1" -f $cfg.listen.port)
    exit 1
}
$proxy = "http://$($endpoint.Host):$($endpoint.Port)"
Write-Host "proxy: $proxy (source: $($endpoint.Source))"
$pass = 0; $fail = 0

function Check([string]$name, [string[]]$curlArgs, [scriptblock]$condition, [string]$desc) {
    Write-Host "- $name : $desc"
    $out = & curl.exe @curlArgs 2>$null
    $code = $LASTEXITCODE
    if ($code -eq 0 -and (& $condition $out)) {
        Write-Host ("  PASS  " + (($out | Select-Object -First 1) + '').Trim())
        $script:pass++
    }
    else {
        Write-Host "  FAIL  curl exit=$code"
        if ($out) { $out | Select-Object -First 3 | ForEach-Object { Write-Host "        $_" } }
        $script:fail++
    }
}

# 1) internal status endpoint (origin-form, loopback)
Check 'bridge status' @('--noproxy', '*', '-s', '-m', '5', "$proxy/__bridge/status") `
    { param($o) $o -match 'opencode-happ-bridge' } 'GET /__bridge/status'

# 2) CONNECT tunnel through active upstream
Check 'CONNECT https' @('--proxy', $proxy, '-s', '-m', '30', '-w', '\nHTTP:%{http_code}', $Path) `
    { param($o) $o -match 'HTTP:200' } "curl via bridge -> $Path"

# 3) plain absolute-form http through bridge (no CONNECT)
Check 'absolute-form http' @('--proxy', $proxy, '-s', '-m', '30', 'http://example.com/') `
    { param($o) $o -match 'Example Domain' } 'curl via bridge -> http://example.com/'

# 4) the same target bypassing the bridge (sanity baseline)
Check 'direct baseline' @('--noproxy', '*', '-s', '-m', '30', '-w', '\nHTTP:%{http_code}', $Path) `
    { param($o) $o -match 'HTTP:' } "curl direct (no proxy) -> $Path"

Write-Host ""
Write-Host "result: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
