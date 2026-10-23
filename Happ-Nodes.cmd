@echo off
rem Happ node switcher (real, non-stub): companion-xray ports -> bridge hot-swap. External console.
setlocal
:menu
cls
echo ============================================
echo   Переключение узлов Happ (реальный egress)
echo ============================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0happ-nodes.ps1" -Action List
echo.
echo   [S] статус (что активно + выходной IP)
echo   [R] обновить пул узлов из памяти Happ
echo   [1] [2] [3] [4] ... - переключить на узел N
echo   [Q] выход
echo.
set /p ch=ваш выбор:
if /i "%ch%"=="S" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0happ-nodes.ps1" -Action Status
if /i "%ch%"=="R" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0refresh-nodes.ps1"
if /i "%ch%"=="Q" exit /b 0
if not "%ch%"=="" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0happ-nodes.ps1" -Action Use -Name %ch%
echo.
pause
goto menu
