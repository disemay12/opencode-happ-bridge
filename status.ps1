# status.ps1 - one glance: bridge, active upstream, Happ cores, OpenCode processes
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'
$cfgPath = Join-Path $PSScriptRoot 'bridge.settings.json'
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'bridge-port.ps1')
$endpoint = Find-BridgeEndpoint -Root $PSScriptRoot
$port = $endpoint.Port

Write-Host "== opencode-happ-bridge =="
Write-Host ("config: active={0} upstream={1}" -f $cfg.active, $cfg.upstreams.$($cfg.active))
foreach ($n in @($cfg.upstreams.PSObject.Properties.Name)) {
    $mark = if ($n -eq $cfg.active) { "->" } else { "  " }
    Write-Host ("  {0} {1,-12} {2}" -f $mark, $n, $cfg.upstreams.$n)
}

# bridge process + status.json
$bridgeProc = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -match 'bridge\.js' })
if ($bridgeProc.Count -gt 1) {
    Write-Host ("bridge: WARNING {0} bridge.js processes: pid {1}" -f $bridgeProc.Count, ($bridgeProc.ProcessId -join ','))
}
if ($endpoint.Running) {
    Write-Host ("bridge: RUNNING on {0}:{1} (port source: {2}, pid {3})" -f $endpoint.Host, $endpoint.Port, $endpoint.Source, $endpoint.Pid)
    if ($endpoint.Port -ne $cfg.listen.port) {
        Write-Host ("  preferred port {0} was busy - real port is {1} (see bridge.port.json)" -f $cfg.listen.port, $endpoint.Port)
    }
    try {
        $st = Invoke-RestMethod -Uri "http://127.0.0.1:$port/__bridge/status" -TimeoutSec 2
        Write-Host ("  uptime {0:n0} s | connections {1} | active {2} | errors {3} | up {4} kb | down {5} kb" -f `
                ($st.uptimeMs / 1000), $st.stats.connections, $st.stats.active, $st.stats.errors, `
                ($st.stats.bytesUp / 1kb), ($st.stats.bytesDown / 1kb))
    } catch {
        Write-Host "  status endpoint unreachable"
    }
}
else {
    Write-Host ("bridge: not running (preferred port {0}; launch.opencode.ps1 starts it)" -f $cfg.listen.port)
}

Write-Host "== Happ local proxies =="
function Test-Port([string]$label, [int]$p) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', $p, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(500) -and $c.Connected
        Write-Host ("  {0,-28} {1}" -f $label, $(if ($ok) { "listening :$p" } else { "not listening :$p" }))
    } catch {
        Write-Host ("  {0,-28} not listening :{1}" -f $label, $p)
    } finally { $c.Close() }
}
Test-Port 'Happ xray HTTP (happ-http)' 10809
Test-Port 'Happ xray SOCKS (happ-socks)' 10808

$xray = Get-Process -Name 'xray' -ErrorAction SilentlyContinue
$happd = Get-Process -Name 'happd' -ErrorAction SilentlyContinue
Write-Host ("  processes: xray{0} happd{1}" -f `
        $(if ($xray) { " $($xray.Id -join ',')" } else { " absent" }), `
        $(if ($happd) { " $($happd.Id -join ',')" } else { " absent" }))

Write-Host "== OpenCode =="
$oc = Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue
$cli = Get-Process -Name 'opencode-cli' -ErrorAction SilentlyContinue
Write-Host ("  OpenCode.exe: {0}" -f $(if ($oc) { "running pid $($oc.Id -join ',')" } else { "not running" }))
Write-Host ("  opencode-cli: {0}" -f $(if ($cli) { "running pid $($cli.Id -join ',')" } else { "not running" }))
if ($oc) {
    $main = Get-CimInstance Win32_Process -Filter "Name='OpenCode.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' } |
        Select-Object -First 1
    $cmdline = $main.CommandLine
    Write-Host ("  command line: {0}" -f $cmdline)
    if ($cmdline -notmatch 'proxy-server') {
        Write-Host "  NOTE: running instance was NOT launched with --proxy-server (use launch.opencode.ps1 / -Restart)"
    }
}
