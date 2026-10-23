# build-exe.ps1 - пересборка единого лаунчера OpenCode-Happ.exe из src\OpenCodeHapp.cs
# Требуется только .NET Framework 4.x (csc.exe есть в Windows по умолчанию).
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe не найден (.NET Framework 4.x)' }

$src = Join-Path $root 'src\OpenCodeHapp.cs'
$out = Join-Path $root 'OpenCode-Happ.exe'
if (-not (Test-Path $src)) { throw "нет исходника: $src" }

& $csc /nologo /target:exe /platform:anycpu /optimize+ /codepage:65001 `
    /r:System.Management.dll /r:System.Web.Extensions.dll `
    "/out:$out" $src
if ($LASTEXITCODE -ne 0) { throw "csc завершился с кодом $LASTEXITCODE" }

$f = Get-Item $out
Write-Host ("собрано: {0} ({1:N0} байт)" -f $f.FullName, $f.Length)
