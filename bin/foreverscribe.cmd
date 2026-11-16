@echo off
rem ForeverScribe CLI for Windows. Needs Python 3.8+ (py launcher or python on PATH).
set "FS_HERE=%~dp0.."
set "PYTHONPATH=%FS_HERE%;%PYTHONPATH%"
where py >nul 2>nul && (py -3 -m foreverscribe %*) || (python -m foreverscribe %*)
