# happ-nodes.ps1 - настоящий переключатель узлов из подписки Happ (компаньон-xray + горячая смена моста)
# usage:
#   .\happ-nodes.ps1                          # список узлов + текущий выход
#   .\happ-nodes.ps1 -Action Use -Name 2      # переключить мост на узел #2 (проверка egress IP)
#   .\happ-nodes.ps1 -Action Status           # что активно сейчас (+ egress IP)
#   .\happ-nodes.ps1 -Action Ensure           # поднять компаньон-xray, если не запущен
#   .\happ-nodes.ps1 -Action Stop             # остановить компаньон-xray
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('List', 'Use', 'Status', 'Ensure', 'Stop')]
    [string]$Action = 'List',
    [string]$Name = ''
)

$ErrorActionPreference = 'Stop'
$proj = $PSScriptRoot
$indexPath = Join-Path $proj 'nodes-index.json'
. (Join-Path $proj 'bridge-port.ps1')
$bridgePort = Resolve-BridgePort -Root $proj

function Read-Index {
    $raw = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8)
    (ConvertFrom-Json $raw).nodes
}

function Test-PortListening([int]$port) {
    $hits = netstat -ano | Select-String -SimpleMatch ":$port " | Where-Object { $_.Line -match 'LISTENING' }
    [bool]$hits
}

function Get-Egress([string]$proxy) {
    # $proxy: "http://127.0.0.1:<bridge-port>" или "none"
    $args2 = @('-s', '-m', '25', 'https://api.ipify.org')
    if ($proxy -ne 'none') { $args2 = @('-x', $proxy) + $args2 } else { $args2 = @('--noproxy', '*') + $args2 }
    $out = & curl.exe @args2 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) { $out } else { $null }
}

# --- Ensure / Stop ---
if ($Action -in @('Ensure', 'Stop', 'Use', 'List')) {
    $listening = Test-PortListening 10901
    if ($Action -eq 'Stop') {
        $procs = Get-CimInstance Win32_Process -Filter "name='xray.exe'" | Where-Object { $_.CommandLine -like '*companion-xray.json*' }
        foreach ($pr in $procs) { Stop-Process -Id $pr.ProcessId -Force }
        Write-Host ("компаньон-xray остановлен: {0} процесс(ов)" -f $procs.Count)
        exit 0
    }
    if (-not $listening -and $Action -in @('Ensure', 'List', 'Use')) {
        Write-Host 'компаньон-xray не запущен - стартую...'
        $xray = 'C:\Program Files\FlyFrogLLC\Happ\core\xray.exe'
        $cfg = Join-Path $proj 'companion-xray.json'
        $null = Start-Process -FilePath $xray -ArgumentList @('-c', $cfg) -WorkingDirectory $proj -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $proj 'companion-xray.out.log') `
            -RedirectStandardError (Join-Path $proj 'companion-xray.err.log') -PassThru
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 300
            if (Test-PortListening 10901) { break }
        }
        $listening = Test-PortListening 10901
        if (-not $listening) { Write-Host 'ОШИБКА: компаньон-xray не поднялся (см. companion-xray.err.log)'; exit 1 }
        $cnt = (Read-Index).Count
        Write-Host ("компаньон-xray работает (порты 10901-{0})" -f (10900 + $cnt))
    }
}

# --- List / Status ---
if ($Action -in @('List', 'Status')) {
    $nodes = Read-Index
    $bridgeStatus = $null
    try { $bridgeStatus = Invoke-RestMethod -Uri "http://127.0.0.1:$bridgePort/__bridge/status" -TimeoutSec 2 } catch { }

    if ($Action -eq 'Status') {
        $egress = Get-Egress "http://127.0.0.1:$bridgePort"
        Write-Host ("мост: active={0} ({1})" -f $bridgeStatus.active, $bridgeStatus.upstream)
        Write-Host ("выходной IP через мост: {0}" -f $(if ($egress) { $egress } else { '(нет ответа)' }))
        exit 0
    }

    Write-Host ('узлы подписки Happ (компаньон-xray):')
    foreach ($n in $nodes) {
        $country = if ($n.country) { $n.country } else { '?' }
        Write-Host ("  [{0}] порт {1}  {2}  {3}/{4}  {5}:{6}" -f $n.n, $n.port, $country, $n.proto, $n.net, $n.addr, $n.port0)
    }
    Write-Host ''
    if ($bridgeStatus) {
        Write-Host ("мост сейчас: {0} ({1})" -f $bridgeStatus.active, $bridgeStatus.upstream)
        $egress = Get-Egress "http://127.0.0.1:$bridgePort"
        Write-Host ("выходной IP: {0}" -f $(if ($egress) { $egress } else { '(нет ответа)' }))
    }
    else { Write-Host 'мост не запущен - переключение всё равно запомнится в конфиге.' }
    exit 0
}

# --- Use N ---
if ($Action -eq 'Use') {
    if ($Name -notmatch '^\d+$') { Write-Host "usage: .\happ-nodes.ps1 -Action Use -Name <номер узла>"; exit 1 }
    $idx = [int]$Name
    $nodes = Read-Index
    $node = $nodes | Where-Object { [int]$_.n -eq $idx } | Select-Object -First 1
    if (-not $node) { Write-Host "узел #$idx не найден (1..$($nodes.Count))"; exit 1 }

    $before = Get-Egress "http://127.0.0.1:$bridgePort"
    Write-Host ("переключаю мост: {0} -> happ-node-{1}  [{2}/{3}] {4}:{5} ..." -f `
        $(if ($before) { $before } else { '?' }), $node.n, $node.proto, $node.net, $node.addr, $node.port0)

    & (Join-Path $proj 'switch.ps1') -Target "happ-node-$idx"

    Start-Sleep -Milliseconds 700
    $after = Get-Egress "http://127.0.0.1:$bridgePort"
    if (-not $after) {
        Write-Host 'ОШИБКА: нет ответа через мост после переключения (exit 1)'
        exit 1
    }
    Write-Host ("выходной IP теперь: {0}" -f $after)
    if ($before -and ($after -ne $before)) {
        Write-Host "  (был $before -> сменился. переключение РЕАЛЬНОЕ)"
    }
    elseif ($before -eq $after) {
        Write-Host "  ! IP не изменился - возможно, оба узла выходят с одного IP, или узел не принял соединение"
    }
    exit 0
}
