# menu.ps1 - единая панель управления opencode-happ-bridge
# Запуск: двойной клик по Happ-Bridge.cmd, либо: .\menu.ps1

[CmdletBinding()]
param(
    # скриптовое управление: "4,0" выполняет пункты 4 затем 0 без Read-Host
    [string]$Choices
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$cfgPath = Join-Path $root 'bridge.settings.json'
. (Join-Path $root 'bridge-port.ps1')

$script:menuChoices = @()
$script:menuCursor = 0
if ($Choices) { $script:menuChoices = @($Choices -split ',') }

# Read-Host-обёртка: в интерактиве спрашивает, при -Choices берёт по порядку
# (по исчерпанию массива возвращает '0' — не зависает в автоматизации)
function Get-MenuChoice([string]$prompt) {
    if ($script:menuChoices.Count -gt $script:menuCursor) {
        $v = $script:menuChoices[$script:menuCursor]
        $script:menuCursor++
        Write-Host "[$prompt] -> $v"
        return $v
    }
    if ($script:menuChoices.Count -gt 0) {
        # авто-режим (-Choices) и массив исчерпан: авто-выход вместо зависшего Read-Host
        Write-Host "[$prompt] -> (Choices исчерпаны) авто-0"
        return '0'
    }
    return Read-Host $prompt
}

function Read-Settings {
    [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Test-Port([string]$ip, [int]$port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($ip, $port, $null, $null)
        return ($iar.AsyncWaitHandle.WaitOne(500) -and $c.Connected)
    } catch { return $false }
    finally { $c.Close() }
}

# эта консоль живёт внутри OpenCode Desktop? (цепочка родителей до explorer)
# строка OpenCode.exe -> opencode-cli.exe serve -> powershell => перезапуск отсюда убьёт сессию
function Test-RunningInsideOpenCode {
    $cur = $PID
    for ($i = 0; $i -lt 15; $i++) {
        try {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction Stop
            if (-not $p) { return $false }
            if ($p.Name -ieq 'OpenCode.exe') { return $true }
            $cur = $p.ParentProcessId
            if (-not $cur) { return $false }
        } catch { return $false }
    }
    return $false
}

function Show-Header {
    $cfg = Read-Settings
    $endpoint = Find-BridgeEndpoint -Root $root
    $bridgeUp = $endpoint.Running
    $portNote = if ($endpoint.Port -ne [int]$cfg.listen.port) { " (порт $($endpoint.Port), нестандартный)" } else { "" }
    $bridgeState = if ($bridgeUp) { "работает ($($endpoint.Host):$($endpoint.Port))$portNote" } else { "остановлен" }
    $eff = $cfg.upstreams.$($cfg.active)
    $oc = @(Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue)
    $ocState = if ($oc.Count -gt 0) { "запущен" } else { "не запущен" }
    ""
    ('==== opencode-happ-bridge ====')
    ('Мост:      {0}' -f $bridgeState)
    ('Апстрим:   {0}  ({1})' -f $cfg.active, $eff)
    ('OpenCode:  {0}' -f $ocState)
    ('==============================')
}

function Wait-Return {
    if ($script:menuChoices.Count -gt 0) { return }  # авто-режим: без пауз, чтобы не смещать курсор Choices
    [void](Get-MenuChoice 'Enter — вернуться в меню')
}

function Do-Launch {
    $oc = Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue
    if ($oc) {
        Write-Host 'OpenCode уже запущен — просто запуск нового окна прокси не изменит.'
        Write-Host 'Чтобы трафик пошёл через мост: пункт 2 (перезапуск) или закройте OpenCode вручную и снова пункт 1.'
        return
    }
    & (Join-Path $root 'launch.opencode.ps1')
}

function Do-Restart {
    if (Test-RunningInsideOpenCode) {
        Write-Host 'ОТМЕНА: эта консоль запущена ВНУТРИ OpenCode Desktop — перезапуск отсюда убьёт агент-сессию.' -ForegroundColor Yellow
        Write-Host 'Закройте OpenCode вручную, затем выполните пункт 1 (запуск).'
        Write-Host 'Готовый закрыщик: kill-opencode.ps1 (двойной клик Kill-OpenCode.cmd) — тоже только из отдельной консоли.'
        return
    }
    & (Join-Path $root 'launch.opencode.ps1') -Restart
}

function Do-Switch {
    while ($true) {
        $cfg = Read-Settings
        $names = @($cfg.upstreams.PSObject.Properties.Name)
        $countries = @{}
        $idxPath = Join-Path $root 'nodes-index.json'
        if (Test-Path $idxPath) {
            try {
                $idxRaw = [System.IO.File]::ReadAllText($idxPath, [System.Text.Encoding]::UTF8)
                ($idxRaw | ConvertFrom-Json).nodes | ForEach-Object {
                    if ($_.country -and $_.country -ne '?') { $countries["happ-node-$($_.n)"] = $_.country }
                }
            } catch { }
        }
        ''
        'Смена апстрима (текущий): {0}' -f $cfg.active
        'Дальше все НОВЫЕ соединения OpenCode пойдут через выбранный апстрим — без перезапуска приложения.'
        ''
        # пункты 1..N — именованные апстримы
        $names | ForEach-Object -Begin { $i = 0 } -Process {
            $i++
            $label = ''
            if ($countries.ContainsKey($_)) { $label = '   (' + $countries[$_] + ')' }
            if ($i -le $names.Count -and $names[$i - 1] -eq $cfg.active) {
                ('  [{0}] {1,-12} {2}{3}   <- активен' -f $i, $_, $cfg.upstreams.$_, $label)
            } else {
                ('  [{0}] {1,-12} {2}{3}' -f $i, $_, $cfg.upstreams.$_, $label)
            }
        }
        '  [u] свой URL (http://... или socks5://...)'
        '  [0] назад'
        $choice = Get-MenuChoice 'апстрим'
        if ($choice -eq '0' -or $choice -eq '') { return }
        if ($choice -eq 'u') {
            $url = Get-MenuChoice 'URL (например socks5://127.0.0.1:10808 или direct)'
            if ($url) {
                try { & (Join-Path $root 'switch.ps1') -Target $url } catch { Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red }
                Wait-Return
                return
            }
            continue
        }
        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $names.Count) {
            try { & (Join-Path $root 'switch.ps1') -Target $names[$idx - 1] } catch { Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red }
            Wait-Return
            return
        }
        Write-Host 'не понял выбор — попробуйте ещё раз' -ForegroundColor Yellow
    }
}

# Узлы Happ: список со странами + переключение + обновление пула из памяти Happ
function Do-Nodes {
    $hn = Join-Path $root 'happ-nodes.ps1'
    while ($true) {
        ''
        & $hn -Action List
        ''
        '  [номер] переключить мост на этот узел (страна указана в списке)'
        '  [r]     обновить пул узлов из памяти Happ (скан + гео-проверка)'
        '  [0]     назад'
        $c = Get-MenuChoice 'узел'
        if ($c -eq '0' -or $c -eq '') { return }
        if ($c -ieq 'r') {
            & (Join-Path $root 'refresh-nodes.ps1')
            Wait-Return
            continue
        }
        $n = 0
        if ([int]::TryParse($c, [ref]$n)) {
            try { & $hn -Action Use -Name $n } catch { Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red }
            Wait-Return
            return
        }
        Write-Host 'не понял выбор — введите номер узла, r или 0' -ForegroundColor Yellow
    }
}

function Do-Stop {
    $oc = Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue
    if ($oc) {
        $ans = Get-MenuChoice 'OpenCode запущен и ходит через мост — после остановки моста его сеть оборвётся. Точно остановить? (y/N)'
        if ($ans -ine 'y') { return }
    }
    & (Join-Path $root 'stop.ps1')
}

    $exit = $false
    while ($true) {
        try { Show-Header } catch { Write-Host "Сбой чтения конфигурации: $($_.Exception.Message)" -ForegroundColor Red }
        ''
        '  [1] Запустить OpenCode через мост (мост поднимется сам)'
        '  [2] Перезапустить OpenCode с мостом (закроет текущий OpenCode)'
        '  [3] Сменить апстрим  (happ-http / happ-socks / direct / свой URL)'
        '  [4] Статус (мост / Happ-cores / OpenCode)'
        '  [5] Тест связи через мост'
        '  [6] Остановить мост'
        '  [7] Узлы Happ: список по странам / переключение'
        '  [0] Выход'
        ''
        $choice = Get-MenuChoice 'выбор'
        try {
            switch ($choice) {
                '1' { Do-Launch; Wait-Return }
                '2' { Do-Restart; Wait-Return }
                '3' { Do-Switch }
                '4' { & (Join-Path $root 'status.ps1'); Wait-Return }
                '5' { & (Join-Path $root 'test-connection.ps1'); Wait-Return }
                '6' { Do-Stop; Wait-Return }
                '7' { Do-Nodes }
                '0' { Write-Host 'bye'; $exit = $true }
                default { }
            }
        } catch {
            Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
            Wait-Return
        }
        if ($exit) { break }
    }
