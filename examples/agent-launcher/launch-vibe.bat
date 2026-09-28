@echo off
setlocal enabledelayedexpansion

:: Configuración del entorno
set KANBAN_URL=http://localhost:7777
set ACTOR=agent:launcher
set TIMEOUT=1800
set MODEL=mistral-large

:: Verificar que tenemos los argumentos
if "%~1"=="" (
    echo Error: Se requiere task_id
    exit /b 1
)

set TASK_ID=%~1
set PROJECT_ID=%~2

:: Resolver la ruta de bash
set BASH_PATH=C:\Apps\PortableGit\usr\bin\bash.exe

:: Ruta al script original
set SCRIPT_DIR=C:\Users\dsuapers\Documents\devel\agent-kanban\examples\agent-launcher

:: Ejecutar el script bash con los argumentos
"%BASH_PATH%" "%SCRIPT_DIR%\launch-vibe.sh" %TASK_ID% %PROJECT_ID%
