@echo off
rem Stop the HunyuanOCR llama-server started by start_server.bat
taskkill /IM llama-server.exe /F >nul 2>&1
echo llama-server stopped.
