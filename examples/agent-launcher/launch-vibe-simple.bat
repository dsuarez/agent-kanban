@echo off
:: Simple launcher for Vibe
:: Usage: launch-vibe-simple.bat <task_id> <project_id>

:: Set UTF-8
chcp 65001 >nul 2>&1

:: Configure environment
set VIBE_BIN=C:\Users\dsuapers\.local\bin\vibe.exe
set VIBE_ACTIVE_MODEL=mistral-large

:: Change to project directory
cd /d C:\Users\dsuapers\Documents\devel\SP500_Signal_App_Python_React

:: Execute Vibe with simple prompt
%VIBE_BIN% -p "Process task %~1" --auto-approve
