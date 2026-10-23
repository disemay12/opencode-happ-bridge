# switch.ps1 - change the opencode-happ-bridge upstream (hot: applies within ~100ms)
# usage: .\switch.ps1 -Target happ-http            (named upstream from bridge.settings.json)
#        .\switch.ps1 -Target direct
#        .\switch.ps1 -Target "http://127.0.0.1:10809"
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Target,
    # keep existing CONNECT tunnels on the old node (they would otherwise keep
    # using its egress IP until the client closes them)
    [switch]$KeepTunnels
)

$ErrorActionPreference = 'Stop'
$cfgPath = Join-Path $PSScriptRoot 'bridge.settings.json'
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json

$names = @($cfg.upstreams.PSObject.Properties.Name)
$activeName = $null
$eff = $null

if ($names -contains $Target) {
    $activeName = $Target
    $eff = $cfg.upstreams.$Target
}
else {
    # treat input as a URL or 'direct' -> stored in the 'custom' slot
    if ($Target -ne 'direct') {
        try { $parser = New-Object System.Uri($Target) } catch { throw "Cannot parse target '$Target' as a URI." }
        if ($parser.Scheme -notin @('http', 'socks5', 'socks')) {
            throw "Unknown target '$Target'. Use a name from upstreams ($($names -join ', ')), 'direct', or an http:// | socks5:// URL."
        }
    }
    if ($names -contains 'custom') {
        $cfg.upstreams.custom = $Target
    }
    else {
        Add-Member -InputObject $cfg.upstreams -MemberType NoteProperty -Name custom -Value $Target
    }
    $activeName = 'custom'
    $eff = $Target
}

$cfg.active = $activeName

# если мост уже работает на этом апстриме — ничего не пишем и не дёргаем соединения
. (Join-Path $PSScriptRoot 'bridge-port.ps1')
$listenPort = Resolve-BridgePort -Root $PSScriptRoot
$live = $null
if ($listenPort) {
    try { $live = Invoke-RestMethod -Uri "http://127.0.0.1:$listenPort/__bridge/status" -TimeoutSec 2 } catch { $live = $null }
}
if ($live -and $live.active -eq $activeName -and $live.upstream -eq $eff) {
    Write-Host "active upstream -> $activeName ($eff)"
    Write-Host "bridge already on this upstream - no switch (connections kept)"
    exit 0
}

# atomic, BOM-free write (PS 5.1 -Encoding UTF8 writes a BOM; Node JSON.parse rejects it)
$json = $cfg | ConvertTo-Json -Depth 10
$tmpPath = "$cfgPath.new"
[System.IO.File]::WriteAllText($tmpPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -Path $tmpPath -Destination $cfgPath -Force

Write-Host "active upstream -> $activeName ($eff)"

# if the bridge is running it hot-reloads via fs.watch; verify briefly
$probe = $null
for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 150
    try {
        $probe = Invoke-RestMethod -Uri "http://127.0.0.1:$listenPort/__bridge/status" -TimeoutSec 2
        if ($probe.active -eq $activeName) { break }
    }
    catch { }
}
if ($probe -and $probe.active -eq $activeName) {
    Write-Host "bridge confirmed: active=$($probe.active) upstream=$($probe.upstream)"
    if (-not $KeepTunnels) {
        # established tunnels stay pinned to the node they were dialed through:
        # the client would keep egressing from the old IP (same limit counter)
        try {
            $reset = Invoke-RestMethod -Uri "http://127.0.0.1:$listenPort/__bridge/reset" -TimeoutSec 3
            Write-Host "tunnels closed: $($reset.reset) (client reconnects through $activeName)"
        }
        catch { Write-Host "tunnel reset skipped: $($_.Exception.Message)" }
    }
}
else {
    Write-Host "bridge not running or reload pending - setting applies on next launch"
}
