# stop.ps1 - stop the running opencode-happ-bridge
[CmdletBinding()]
param()

# The desktop persists proxy env for its background CLI server. Pointing that at a
# stopped bridge leaves the service without internet, so drop it together with the bridge.
function Get-OpenCodeCliExe {
    $base = Join-Path $env:APPDATA 'ai.opencode.desktop\cli'
    if (-not (Test-Path $base)) { return $null }
    Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'opencode-cli.exe' } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
}

$procs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -match 'bridge\.js' }
if (-not $procs) {
    Write-Host "bridge is not running"
}
else {
    foreach ($p in $procs) {
        Stop-Process -Id $p.ProcessId -Force
        Write-Host "stopped bridge pid $($p.ProcessId)"
    }
}

$cli = Get-OpenCodeCliExe
if ($cli) {
    $svc = $null
    try { $svc = (& $cli service get 2>$null | Out-String) | ConvertFrom-Json } catch { }
    $proxyEnv = @()
    if ($svc -and $svc.env) {
        foreach ($name in 'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY') {
            $value = $svc.env.$name
            if ($value -and $value -match '^https?://127\.0\.0\.1:\d+$') { $proxyEnv += $name }
        }
    }
    foreach ($name in $proxyEnv) {
        & $cli service unset env $name 2>$null | Out-Null
        Write-Host "service env: $name cleared"
    }
}
