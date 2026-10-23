# launch.opencode.ps1 - start OpenCode Desktop routed through the local happ-bridge
# usage:
#   .\launch.opencode.ps1                     (start bridge if needed + launch OpenCode with proxy env & --proxy-server)
#   .\launch.opencode.ps1 -Target direct      (also switch upstream first)
#   .\launch.opencode.ps1 -Restart            (kill running OpenCode/CLI first so new env applies)
#   .\launch.opencode.ps1 -DryRun             (show what would be done)
[CmdletBinding()]
param(
    [string]$Target,
    [switch]$Restart,
    [switch]$NoBridge,
    [switch]$NoServiceEnv,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---- config ---------------------------------------------------------------
$cfgPath = Join-Path $PSScriptRoot 'bridge.settings.json'
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'bridge-port.ps1')
$listenHost = $cfg.listen.host
$listenPort = [int]$cfg.listen.port

# ---- resolve node ---------------------------------------------------------
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) {
    foreach ($cand in @("$env:ProgramFiles\nodejs\node.exe", "$env:LOCALAPPDATA\Programs\nodejs\node.exe")) {
        if (Test-Path $cand) { $node = $cand; break }
    }
}
if (-not $node) { throw "node.exe not found (needed to run the bridge)" }

# ---- bridge ---------------------------------------------------------------
function Test-TcpListening([string]$Ip, [int]$Port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Ip, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(600)) { $client.EndConnect($iar); return $true }
        return $false
    }
    catch { return $false }
    finally { $client.Close() }
}

function Get-OpenCodeCliExe {
    $base = Join-Path $env:APPDATA 'ai.opencode.desktop\cli'
    if (-not (Test-Path $base)) { return $null }
    Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'opencode-cli.exe' } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
}

# The desktop spawns `opencode-cli serve --service` with its own proxy env.
# Keep that env on the live bridge port; stale ports are what breaks OpenCode
# after the bridge moves or Happ closes.
function Sync-ServiceProxy([string]$Url) {
    $cli = Get-OpenCodeCliExe
    if (-not $cli) {
        Write-Warning "opencode-cli not found; service proxy env left untouched"
        return
    }
    try {
        $current = (& $cli service get 2>$null | Out-String) | ConvertFrom-Json
        if ($current.env.HTTPS_PROXY -eq $Url -and $current.env.HTTP_PROXY -eq $Url) {
            Write-Host "service proxy env already points to $Url"
            return
        }
        & $cli service set env HTTPS_PROXY $Url 2>$null | Out-Null
        & $cli service set env HTTP_PROXY $Url 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "opencode-cli service set failed ($LASTEXITCODE)" }
        Write-Host "service proxy env -> $Url"
    }
    catch {
        Write-Warning "service proxy env update failed: $($_.Exception.Message)"
    }
}

if (-not $NoBridge) {
    $endpoint = Find-BridgeEndpoint -Root $PSScriptRoot
    if (-not $endpoint.Running) {
        Write-Host "starting bridge node bridge.js (preferred ${listenHost}:$listenPort, auto-fallback up to +100)"
        $log = Join-Path $PSScriptRoot 'bridge.log'
        $err = Join-Path $PSScriptRoot 'bridge.err.log'
        Start-Process -FilePath $node -ArgumentList 'bridge.js' -WorkingDirectory $PSScriptRoot `
            -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err | Out-Null
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            $endpoint = Find-BridgeEndpoint -Root $PSScriptRoot
            if ($endpoint.Running) { break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $endpoint.Running) {
            throw "bridge did not start; see $err"
        }
        Write-Host ("bridge is up on {0}:{1}" -f $endpoint.Host, $endpoint.Port)
        if ($endpoint.Port -ne $listenPort) {
            Write-Host ("preferred port {0} was busy - bridge moved to {1}" -f $listenPort, $endpoint.Port)
        }
    }
    else {
        Write-Host ("bridge already running on {0}:{1} ({2})" -f $endpoint.Host, $endpoint.Port, $endpoint.Source)
    }
}

# Resolve again: the bridge may have chosen a different port than configured.
$endpoint = Find-BridgeEndpoint -Root $PSScriptRoot
if (-not $endpoint.Running) {
    throw "bridge is not running; start it with launch.opencode.ps1 (without -NoBridge)"
}
$listenHost = $endpoint.Host
$listenPort = $endpoint.Port
$proxyUrl = "http://${listenHost}:${listenPort}"
Write-Host "bridge endpoint: $proxyUrl"

# ---- optional upstream switch --------------------------------------------
if ($Target) {
    & (Join-Path $PSScriptRoot 'switch.ps1') -Target $Target
}

# ---- OpenCode -------------------------------------------------------------
$ocExe = Join-Path $env:LOCALAPPDATA 'Programs\@opencodedesktop\OpenCode.exe'
if (-not (Test-Path $ocExe)) {
    $ocExe = (Get-Command OpenCode -ErrorAction SilentlyContinue).Source
}
if (-not $ocExe -or -not (Test-Path $ocExe)) { throw "OpenCode.exe not found" }

$ocRunning = Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue
if ($ocRunning) {
    if (-not $Restart) {
        Write-Warning "OpenCode is already running (pid $($ocRunning.Id -join ',')). Proxy env/switches are per-process,"
        Write-Warning "so the running instance keeps its old route. Re-run with -Restart to apply the bridge."
        exit 2
    }
    Write-Host "stopping running OpenCode + opencode-cli (to relay through bridge)"
    Get-Process -Name 'OpenCode', 'opencode-cli' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
}

$envManifest = @(
    "HTTP_PROXY=$proxyUrl",
    "HTTPS_PROXY=$proxyUrl",
    "ALL_PROXY=$proxyUrl",
    "NO_PROXY=127.0.0.1,localhost,::1"
)

if ($DryRun) {
    Write-Host "exe:  $ocExe"
    Write-Host "args: --proxy-server=$proxyUrl"
    Write-Host "env:  $($envManifest -join '; ')"
    if (-not $NoServiceEnv) { Write-Host "service env: HTTPS_PROXY/HTTP_PROXY -> $proxyUrl" }
    return
}

if (-not $NoServiceEnv) {
    Sync-ServiceProxy $proxyUrl
}

# Chromium stack (renderer fetch, electron-updater, net module) reads the
# --proxy-server switch; anything using node:http honors the env vars below
# (OpenCode main calls http.setGlobalProxyFromEnv() at startup).
$env:HTTP_PROXY = $proxyUrl
$env:HTTPS_PROXY = $proxyUrl
$env:ALL_PROXY = $proxyUrl
$env:NO_PROXY = '127.0.0.1,localhost,::1'

Start-Process -FilePath $ocExe -ArgumentList "--proxy-server=$proxyUrl"
Write-Host "OpenCode launched via bridge $proxyUrl (active: $($cfg.active))"
