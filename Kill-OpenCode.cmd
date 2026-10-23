@echo off
rem Gracefully close OpenCode Desktop (+ orphan CLI). External console ONLY - refuses when run from inside OpenCode.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kill-opencode.ps1"
pause
