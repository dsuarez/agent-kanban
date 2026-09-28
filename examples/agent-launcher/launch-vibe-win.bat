@echo off
setlocal enabledelayedexpansion

:: ============================================================================
:: launch-vibe-win.bat - Agent launcher for agent-kanban + Mistral Vibe on Windows
:: ============================================================================

:: Argumentos
if "%~1"=="" (
    echo Error: Se requiere task_id
    exit /b 1
)
set TASK_ID=%~1
set PROJECT_ID=%~2

:: Configuracion por defecto
set KANBAN_URL=http://localhost:7777
set ACTOR=agent:launcher
set TIMEOUT=1800
set MODEL=%VIBE_MODEL%
if "%MODEL%"=="" set MODEL=mistral-large

:: Ruta al directorio del proyecto
set KANBAN_ROOT=C:\Users\dsuapers\Documents\devel\agent-kanban
set SCRIPT_DIR=%KANBAN_ROOT%\examples\agent-launcher

:: Rutas
set PY=%KANBAN_ROOT%\.venv\Scripts\python.exe
set VIBE_BIN=%VIBE_BIN%
if "%VIBE_BIN%"=="" set VIBE_BIN=C:\Users\dsuapers\.local\bin\vibe.exe
set RUNS_DIR=%KANBAN_RUNS_DIR%
if "%RUNS_DIR%"=="" set RUNS_DIR=%KANBAN_ROOT%\kanban_data\logs\runs
set RUN_DIR=%RUNS_DIR%\%TASK_ID%
set LOG=%RUN_DIR%\launcher.log

:: Crear directorios
mkdir "%RUN_DIR%" 2>nul

:: Funcion para log
goto :log_func
echo Error: Function not supported in batch
:log_func

:: Obtener estado de la tarjeta
for /f "usebackq delims=" %%a in (`curl -fsS -m 20 "%KANBAN_URL%/api/tasks/%TASK_ID%?history_limit=0" ^| findstr /c:"\"status\""`) do set STATUS_LINE=%%a

:: Extraer el valor de status
for /f "tokens=2 delims=:," %%s in ('echo %STATUS_LINE%') do set STATUS=%%~s
:: Eliminar comillas
set STATUS=%STATUS:"=%

:: Verificar si la tarjeta esta en approved o analyst
echo STATUS=%STATUS%
if not "%STATUS%"=="approved" if not "%STATUS%"=="analyst" (
    echo [%DATE% %TIME%] %TASK_ID%: card is in '%STATUS%' now, not approved — nothing to do
    exit /b 0
)

:: Obtener informacion de la tarjeta
for /f "usebackq" %%t in (`curl -fsS -m 20 "%KANBAN_URL%/api/tasks/%TASK_ID%?history_limit=0"`) do (
    set TASK_JSON=%%t
)

:: TODO: Parse JSON and extract fields (this is complex in batch)
:: For now, we'll use a simpler approach

:: Resolver la ruta del proyecto
for /f "usebackq" %%p in (`curl -fsS -m 20 "%KANBAN_URL%/api/projects" ^| findstr /c:"\"path\""`) do set PROJ_PATH=%%p

:: Si no se pudo obtener la ruta, usar el directorio del proyecto por defecto
if "%PROJ_PATH%"=="" set PROJ_PATH=%KANBAN_ROOT%\SP500_Signal_App_Python_React

:: Verificar que el directorio del proyecto existe
if not exist "%PROJ_PATH%" (
    echo [%DATE% %TIME%] %TASK_ID%: project '%PROJECT_ID%' has no directory
    exit /b 0
)

:: Verificar que Vibe CLI existe
if not exist "%VIBE_BIN%" (
    echo [%DATE% %TIME%] %TASK_ID%: vibe CLI not found at %VIBE_BIN%. Set VIBE_BIN in the rule's env.
    exit /b 0
)

:: Crear archivo de prompt
set PROMPT=%RUN_DIR%\prompt.md
echo You are connected to agent-kanban via MCP. Use kanban_* tools to interact with the board. > "%PROMPT%"
echo. >> "%PROMPT%"
echo Workflow: >> "%PROMPT%"
echo 1. kanban_pull(task_id="%TASK_ID%") — claim the task (approved -> analyst) >> "%PROMPT%"
echo 2. Plan, write plan as comment via kanban_comment >> "%PROMPT%"
echo 3. kanban_move(task_id="%TASK_ID%", to_status="in_progress") before editing files >> "%PROMPT%"
echo 4. Implement. Use kanban_comment for progress, kanban_link for files/PRs >> "%PROMPT%"
echo 5. Verify. Claims must be backed by command output. >> "%PROMPT%"
echo 6. kanban_move(task_id="%TASK_ID%", to_status="testing", comment="what was done") >> "%PROMPT%"
echo 7. Stop. Do NOT move to uat/done — human decides. >> "%PROMPT%"
echo. >> "%PROMPT%"
echo If blocked: kanban_move to "blocked" with kanban_comment explaining why. >> "%PROMPT%"
echo. >> "%PROMPT%"
echo === Task === >> "%PROMPT%"
echo ID: %TASK_ID% >> "%PROMPT%"
echo Title: TODO >> "%PROMPT%"
echo Description: TODO >> "%PROMPT%"
echo === End === >> "%PROMPT%"

:: Configurar MCP servers para Vibe
set VIBE_MCP_SERVERS=[{"transport": "http", "name": "agent-kanban", "url": "%KANBAN_URL%/mcp"}]

:: Ejecutar Vibe
cd /d "%PROJ_PATH%"
echo [%DATE% %TIME%] %TASK_ID%: starting vibe in %PROJ_PATH% (timeout %TIMEOUT%s); run dir %RUN_DIR%

:: Ejecutar Vibe con el prompt
%VIBE_BIN% -p "%PROMPT%" --auto-approve --model %MODEL% > "%RUN_DIR%\result.json" 2> "%RUN_DIR%\agent.log" &
set AGENT_PID=%ERRORLEVEL%

:: TODO: Implement timeout handling (complex in batch)
echo [%DATE% %TIME%] %TASK_ID%: Vibe started with PID %AGENT_PID%
echo [%DATE% %TIME%] %TASK_ID%: Run directory: %RUN_DIR%

endlocal
