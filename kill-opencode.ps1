# kill-opencode.ps1 - закрыть OpenCode Desktop: сначала корректно, потом принудительно
# opencode-cli.exe добивается, только если он сирота или потомок OpenCode; чужой CLI не трогается
# КОДЫ ВЫХОДА: 0 - закрыт / нечего закрывать, 2 - ЗАПРЕЩЁН изнутри OpenCode (убил бы агент-сессию)
# ЗАПУСКАТЬ ТОЛЬКО ИЗ ОТДЕЛЬНОЙ КОНСОЛИ: двойной клик по Kill-OpenCode.cmd

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

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

if (Test-RunningInsideOpenCode) {
    Write-Host 'ОТКАЗ: скрипт запущен изнутри OpenCode Desktop — вместе с OpenCode умрёт и эта сессия.' -ForegroundColor Yellow
    Write-Host 'Закройте это окно и запустите закрытие из отдельной консоли (двойной клик по Kill-OpenCode.cmd).'
    exit 2
}

$oc = @(Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue)
$cli = @(Get-CimInstance Win32_Process -Filter "Name='opencode-cli.exe'" -ErrorAction SilentlyContinue)
if ($oc.Count -eq 0 -and $cli.Count -eq 0) {
    Write-Host 'OpenCode и opencode-cli не запущены — закрывать нечего.'
    exit 0
}

Write-Host ("[1/4] Найдено: OpenCode x{0}, opencode-cli x{1}. Корректное закрытие окон (CloseMainWindow)..." -f $oc.Count, $cli.Count)
foreach ($p in $oc) {
    try {
        if ($p.MainWindowHandle -ne 0) { [void]$p.CloseMainWindow() }
    } catch { }
}

$deadline = (Get-Date).AddSeconds(6)
do {
    Start-Sleep -Milliseconds 400
    $oc = @(Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue)
} while ($oc.Count -gt 0 -and (Get-Date) -lt $deadline)

if ($oc.Count -gt 0) {
    Write-Host ("[2/4] За 6 с закрылось не всё ({0} процессов) — принудительно завершаю (возможно, при закрытии окна приложение сворачивается в трей)." -f $oc.Count)
} else {
    Write-Host '[2/4] OpenCode завершился сам после закрытия окна.'
}

Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue | Stop-Process -Force

# CLI: убиваем только сирот (родитель умер вместе с OpenCode) или тех, чей родитель - OpenCode.
# Чужой отдельно запущенный CLI (родитель жив и не OpenCode) не трогаем.
$rest = @(Get-CimInstance Win32_Process -Filter "Name='opencode-cli.exe'" -ErrorAction SilentlyContinue)
$cliKilled = 0
$cliLeft = 0
foreach ($c in $rest) {
    $par = $null
    try { $par = Get-Process -Id $c.ParentProcessId -ErrorAction Stop } catch { $par = $null }
    if ($null -eq $par -or $par.Name -ieq 'OpenCode.exe') {
        try { Stop-Process -Id $c.ProcessId -Force -ErrorAction Stop; $cliKilled++ } catch { }
    } else {
        $cliLeft++
        Write-Host ("      opencode-cli pid {0}: родитель {1} жив и не OpenCode — оставлен" -f $c.ProcessId, $par.Name)
    }
}
Write-Host ("[3/4] opencode-cli: убито {0}, чужих оставлено {1}." -f $cliKilled, $cliLeft)

Start-Sleep -Milliseconds 500
$ocLeft = @(Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue)
$cliRest = @(Get-CimInstance Win32_Process -Filter "Name='opencode-cli.exe'" -ErrorAction SilentlyContinue)
if ($ocLeft.Count -gt 0 -or ($cliRest.Count - $cliLeft) -gt 0) {
    Write-Host 'ВНИМАНИЕ: что-то осталось живым — повторите запуск скрипта или проверьте диспетчер задач.' -ForegroundColor Yellow
    exit 1
}
Write-Host '[4/4] Готово: OpenCode Desktop закрыт.'
Write-Host 'Запуск через мост: .\launch.opencode.ps1  (или двойной клик OpenCode-Happ.cmd).'
exit 0
