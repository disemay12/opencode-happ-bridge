# bridge-port.ps1 - discovers the live opencode-happ-bridge endpoint.
# The bridge may move away from listen.port when that port is busy; it publishes
# the real port in bridge.port.json. Consumers must dot-source this file instead
# of reading bridge.settings.json directly.
#
#   . "$PSScriptRoot\bridge-port.ps1"
#   $endpoint = Find-BridgeEndpoint
#   $port     = Resolve-BridgePort

function Test-BridgeTcp {
    param(
        [string]$Ip = '127.0.0.1',
        [int]$Port,
        [int]$TimeoutMs = 300
    )
    if ($Port -le 0 -or $Port -gt 65535) { return $false }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Ip, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($iar)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Read-BridgeSettings {
    param([string]$Root = $PSScriptRoot)
    $path = Join-Path $Root 'bridge.settings.json'
    if (-not (Test-Path $path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
    return ConvertFrom-Json $raw
}

function Read-BridgeState {
    param([string]$Root = $PSScriptRoot)
    $path = Join-Path $Root 'bridge.port.json'
    if (-not (Test-Path $path)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
        $state = ConvertFrom-Json $raw
        if (-not $state.port) { return $null }
        return $state
    }
    catch { return $null }
}

function Get-BridgeListeningPorts {
    param(
        [int]$Base,
        [int]$Limit = 100
    )
    $max = [Math]::Min(65535, $Base + $Limit)
    $ports = New-Object System.Collections.Generic.List[int]
    foreach ($line in (netstat -ano -p TCP)) {
        if ($line -notmatch 'LISTENING') { continue }
        $parts = ($line.Trim() -split '\s+')
        if ($parts.Count -lt 5) { continue }
        $local = $parts[1]
        $sep = $local.LastIndexOf(':')
        if ($sep -lt 0) { continue }
        $port = 0
        if (-not [int]::TryParse($local.Substring($sep + 1), [ref]$port)) { continue }
        if ($port -ge $Base -and $port -le $max -and -not $ports.Contains($port)) {
            $ports.Add($port)
        }
    }
    return $ports
}

function Find-BridgeEndpoint {
    param(
        [string]$Root = $PSScriptRoot,
        [int]$FallbackPort = 0
    )

    $cfg = Read-BridgeSettings -Root $Root
    if ($FallbackPort -le 0) {
        $FallbackPort = 38409
        if ($cfg -and $cfg.listen -and $cfg.listen.port) { $FallbackPort = [int]$cfg.listen.port }
    }

    # 1) authoritative: the port the running bridge published
    $state = Read-BridgeState -Root $Root
    if ($state) {
        $hostName = if ($state.host) { [string]$state.host } else { '127.0.0.1' }
        if ($hostName -eq '0.0.0.0' -or $hostName -eq '::' -or $hostName -eq '[::]') { $hostName = '127.0.0.1' }
        if (Test-BridgeTcp -Ip $hostName -Port ([int]$state.port) -TimeoutMs 350) {
            return [pscustomobject]@{
                Host    = $hostName
                Port    = [int]$state.port
                Running = $true
                Pid     = $state.pid
                Source  = 'state'
            }
        }
    }

    # 2) bridge started before state files existed, or state was removed
    foreach ($port in (Get-BridgeListeningPorts -Base $FallbackPort -Limit 100)) {
        try {
            $st = Invoke-RestMethod -Uri "http://127.0.0.1:$port/__bridge/status" -TimeoutSec 1 -ErrorAction Stop
            if ($st.service -eq 'opencode-happ-bridge') {
                return [pscustomobject]@{
                    Host    = '127.0.0.1'
                    Port    = $port
                    Running = $true
                    Pid     = $st.pid
                    Source  = 'scan'
                }
            }
        }
        catch { }
    }

    # 3) nothing is running: report the preferred port so callers can start it
    $hostName = '127.0.0.1'
    if ($cfg -and $cfg.listen -and $cfg.listen.host) { $hostName = [string]$cfg.listen.host }
    return [pscustomobject]@{
        Host    = $hostName
        Port    = $FallbackPort
        Running = $false
        Pid     = 0
        Source  = 'fallback'
    }
}

function Resolve-BridgePort {
    param(
        [string]$Root = $PSScriptRoot,
        [int]$FallbackPort = 0
    )
    return (Find-BridgeEndpoint -Root $Root -FallbackPort $FallbackPort).Port
}
