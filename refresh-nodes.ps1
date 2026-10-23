# refresh-nodes.ps1 - обновить пул узлов из памяти Happ
# цикл: скан -> пул/конфиг -> рестарт компаньона -> гео-проверка -> отсев мёртвых -> рестарт -> список
#
# Когда запускать: после того как в Happ прогрел узлы («проверить задержку» всех серверов
# или по очереди переключил их). Пул накопительный: найденное не теряется.
[CmdletBinding()]
param(
    [string]$Needle = '"outbounds"',
    [string]$DumpFile = 'C:\Temp\opencode\happ-outbounds.bin',
    [switch]$NoPrune
)

$ErrorActionPreference = 'Stop'
$proj = $PSScriptRoot
$pipe = Join-Path $proj 'nodes-pipeline.js'
$hn = Join-Path $proj 'happ-nodes.ps1'

Write-Host '[1/6] скан памяти Happ.exe ...'
& (Join-Path $proj 'happ-scan.ps1') -Exe Happ -Needle $Needle -OutFile $DumpFile | Out-Host

Write-Host '[2/6] разбор регионов -> пул -> companion-xray.json ...'
& node $pipe $DumpFile | Out-Host

Write-Host '[3/6] рестарт компаньона-xray ...'
& $hn -Action Stop | Out-Host
& $hn -Action Ensure | Out-Host

Write-Host '[4/6] гео-проверка каждого узла (фактический выход) ...'
& node (Join-Path $proj 'nodes-geo.js') | Out-Host

if (-not $NoPrune) {
    Write-Host '[5/6] отсев мёртвых узлов (нет выхода) ...'
    $before = (Get-Content (Join-Path $proj 'nodes-index.json') -Raw | ConvertFrom-Json).nodes.Count
    & node $pipe $DumpFile | Out-Host
    $after = (Get-Content (Join-Path $proj 'nodes-index.json') -Raw | ConvertFrom-Json).nodes.Count
    if ($after -ne $before) {
        Write-Host ("  было узлов: {0}, осталось: {1} -> перезапускаю компаньон" -f $before, $after)
        & $hn -Action Stop | Out-Host
        & $hn -Action Ensure | Out-Host
    } else {
        Write-Host '  все узлы живые, рестарт не нужен'
    }
} else {
    Write-Host '[5/6] отсев мёртвых узлов пропущен (-NoPrune)'
}

Write-Host '[6/6] итог:'
& $hn -Action List | Out-Host
Write-Host ''
Write-Host 'Готово. Переключение: .\happ-nodes.ps1 -Action Use -Name N  (или Happ-Nodes.cmd)'
