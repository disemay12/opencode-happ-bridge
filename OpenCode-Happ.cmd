@echo off
rem Double-click launcher: bridge + OpenCode routed through the bridge
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch.opencode.ps1"
pause
