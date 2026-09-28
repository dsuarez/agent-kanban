@echo off
setlocal

echo Setting up agent-kanban for Windows...
echo ====================================

:: Copy example rules to kanban_data
if not exist "kanban_data" mkdir kanban_data
if not exist "kanban_data\rules.json" (
    copy rules.example.json kanban_data\rules.json > NUL
    echo Copied rules.example.json to kanban_data/rules.json
)

:: Copy MCP configuration
if not exist ".mcp.json" (
    echo Creating .mcp.json for Windows...
    echo {"mcpServers": {"agent-kanban": {"type": "stdio", "command": "%%CD%%\\.venv\\Scripts\\python.exe", "args": ["-m", "kanban_mcp"], "cwd": "%%CD%%", "env": {"PYTHONPATH": "%%CD%%", "KANBAN_DB": "%%CD%%\\tasks.db", "KANBAN_PROJECT_ID": "default", "KANBAN_ACTOR": "vibe"}}}} > .mcp.json
)

echo.
echo Setup complete!
echo.
echo To start the server, run:
echo   uv run python -m kanban_ui
endlocal
