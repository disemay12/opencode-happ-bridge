# check-proxy.ps1 - подключен ли OpenCode к мосту ПРЯМО СЕЙЧАС?
# Две проверки: (1) конфигурация -- был ли флаг --proxy-server при запуске, (2) живой трафик -
# есть ли прямо сейчас ESTABLISHED-соединения OpenCode/opencode-cli с портом моста.
# Коды выхода: 0 - подключение есть, 1 - признаков нет / мост не запущен.
# Режим -Watch <сек>: замер дельты трафика за окно (ходи в OpenCode во время замера).

[CmdletBinding()]
param(
    [int]$Watch = 0
)

$ErrorActionPreference = 'SilentlyContinue'
$cfgPath = Join-Path $PSScriptRoot 'bridge.settings.json'
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'bridge-port.ps1')
$endpoint = Find-BridgeEndpoint -Root $PSScriptRoot
$port = $endpoint.Port
$logPath = Join-Path $PSScriptRoot 'bridge.log'

# --- мост жив и знает свой pid ---
$bridgePid = $null
$st = $null
try {
    $st = Invoke-RestMethod -Uri "http://127.0.0.1:$port/__bridge/status" -TimeoutSec 2
    $bridgePid = $st.pid
} catch { }
if (-not $bridgePid) {
    $bridgePid = (Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object { $_.CommandLine -match 'bridge\.js' }).ProcessId
}
if (-not $bridgePid) {
    Write-Host 'МОСТ НЕ ЗАПУЩЕН - про подключение OpenCode говорить нечего. Запусти: .\launch.opencode.ps1' -ForegroundColor Yellow
    exit 1
}
Write-Host ("[мост] работает, pid {0}, порт {1}; соединений всего: {2}" -f $bridgePid, $port, $st.stats.connections)

# --- уровень 1: конфигурация Chromium (флаг запуска) ---
$main = Get-CimInstance Win32_Process -Filter "Name='OpenCode.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' } |
    Select-Object -First 1
$proxyConf = $false
if ($main) {
    $cmdline = $main.CommandLine
    $target = "--proxy-server=http://127.0.0.1:$port"
    if ($cmdline -like "*$target*") {
        Write-Host ("[1] КОНФИГУРАЦИЯ: OpenCode запущен с {0} - Chromium-слой == через мост" -f $target)
        $proxyConf = $true
    } elseif ($cmdline -match 'proxy-server') {
        Write-Host '[1] КОНФИГУРАЦИЯ: --proxy-server ЕСТЬ, но НЕ на порт моста (см. status.ps1 command line)' -ForegroundColor Yellow
    } else {
        Write-Host '[1] КОНФИГУРАЦИЯ: запущен БЕЗ --proxy-server - Chromium-слой мимо моста' -ForegroundColor Yellow
    }
    # env-слой (HTTP_PROXY) снаружи не читается - о нем свидетельствует живой трафик (уровень 2)
} else {
    Write-Host '[1] OpenCode не запущен.'
}

# --- уровень 2: живые ESTABLISHED-соединения с портом моста ---
function Get-ClientPairs {
    # клиентские сокеты: строки, где УДАЛЁННЫЙ порт == порт моста; pid != pid моста
    $clients = @{}
    foreach ($line in (netstat -ano)) {
        if ($line -notmatch 'ESTABLISHED') { continue }
        $parts = ($line.Trim() -split '\s+')
        if ($parts.Count -lt 5) { continue }
        if ($parts[2] -notmatch ":$port\b") { continue }
        $cpid = 0
        if (-not [int]::TryParse($parts[4], [ref]$cpid)) { continue }
        if ($cpid -eq $bridgePid) { continue }
        $clients[$cpid] = 1 + $clients[$cpid]
    }
    return $clients
}

$clients = Get-ClientPairs
$live = $false
if ($clients.Count -gt 0) {
    Write-Host ('[2] ЖИВОЙ ТРАФИК: соединения с мостом прямо сейчас:')
    foreach ($cpid in ($clients.Keys | Sort-Object)) {
        $name = (Get-Process -Id $cpid -ErrorAction SilentlyContinue).ProcessName
        if (-not $name) { $name = "?pid $cpid" }
        Write-Host ("      pid {0,-6} {1,-16} x{2} соединен." -f $cpid, "$name.exe", $clients[$cpid])
        if ($name -match '^(OpenCode|opencode-cli)$') { $live = $true }
    }
} else {
    Write-Host '[2] ЖИВОЙ ТРАФИК: ни одного открытого соединения с мостом сейчас нет.'
}

# --- дельта-замер ---
if ($Watch -gt 0) {
    Write-Host ("[3] Окно замера {0} c - походи в OpenCode (открой сессию/отправь сообщение)..." -f $Watch)
    $startLen = (Get-Item $logPath -ErrorAction SilentlyContinue).Length
    $con0 = $st.stats.connections
    Start-Sleep -Seconds $Watch
    $st = $null
    try { $st = Invoke-RestMethod -Uri "http://127.0.0.1:$port/__bridge/status" -TimeoutSec 2 } catch { }
    $deltaCon = 0
    if ($st) { $deltaCon = $st.stats.connections - $con0 }
    Write-Host ("[3] Дельта: новых соединений через мост = {0}" -f $deltaCon)
    $curLen = (Get-Item $logPath).Length
    if ($startLen -gt 0 -and $curLen -gt $startLen) {
        $fs = [System.IO.File]::Open($logPath, 'Open', 'Read', 'ReadWrite')
        $null = $fs.Seek($startLen, 'Begin')
        $sr = New-Object System.IO.StreamReader($fs)
        $new = $sr.ReadToEnd()
        $sr.Close()
        Write-Host '    новые записи bridge.log:'
        ($new -split "`r?`n") | Where-Object { $_ } | Select-Object -First 8 | ForEach-Object { Write-Host "      $_" }
    }
    if ($deltaCon -gt 0) { $live = $true; $proxyConf = $true }
}

# --- вердикт ---
if ($live) {
    Write-Host 'ВЕРДИКТ: OpenCode идёт ЧЕРЕЗ мост (живой трафик подтверждён).' -ForegroundColor Green
    exit 0
}
if ($proxyConf) {
    Write-Host 'ВЕРДИКТ: флаг моста установлен, но активного трафика нет (приложение пока молчит - норма для простоя).' -ForegroundColor Green
    exit 0
}
Write-Host 'ВЕРДИКТ: OpenCode НЕ через мост. Перезапуск: закрой OpenCode (Kill-OpenCode.cmd) и запусти launch.opencode.ps1.' -ForegroundColor Yellow
exit 1
