@echo off
chcp 65001 >nul
title Export Config

echo ==================================================
echo   Excel - Lua Config Export
echo ==================================================
echo.

cd /d "%~dp0..\.."

python tools/export_config.py

echo.
if %errorlevel% equ 0 (
    echo ==================================================
    echo   Export Complete!
    echo ==================================================
) else (
    echo ==================================================
    echo   Export Failed - check errors above.
    echo ==================================================
)

echo.
pause
