@echo off
rem ============================================================================
rem start_server.bat - HunyuanOCR llama-server one-click start (Windows).
rem   Double-click:       start_server.bat                 (default model Q8)
rem   Switch to Q4:       start_server.bat Q4
rem   Or preset env var:  set MODEL=Q4 ^& start_server.bat
rem
rem Model switch MODEL (default Q8, case-insensitive):
rem   Q8 = models\HunyuanOCR-Q8_0.gguf        accuracy first (default)
rem   Q4 = models\HunyuanOCR-Q4_K_M.gguf      ~2x faster generation, slightly
rem                                          lower accuracy on dense small text
rem Note: vision mmproj stays Q8_0 (used once for image encode, no gain to Q4).
rem ============================================================================
setlocal EnableExtensions
cd /d %~dp0

rem ---- resolve MODEL (command-line arg > env var MODEL > default Q8) ----
if /i "%~1"=="Q8" set MODEL=Q8
if /i "%~1"=="Q4" set MODEL=Q4
if "%MODEL%"=="" set MODEL=Q8

if /i "%MODEL%"=="Q8" (
  set LLM_GGUF=models\HunyuanOCR-Q8_0.gguf
) else if /i "%MODEL%"=="Q4" (
  set LLM_GGUF=models\HunyuanOCR-Q4_K_M.gguf
) else (
  echo [ERROR] Unknown MODEL=%MODEL%. Only Q8 or Q4 are supported.
  echo         Usage: start_server.bat Q4    or default Q8
  pause
  exit /b 1
)
set MMPROJ_GGUF=models\mmproj-HunyuanOCR-Q8_0.gguf

if not exist "%LLM_GGUF%" (
  echo [ERROR] Model file not found: %LLM_GGUF%
  echo         For Q4, quantize it first:
  echo         llama-quantize --allow-requantize HunyuanOCR-Q8_0.gguf HunyuanOCR-Q4_K_M.gguf Q4_K_M
  pause
  exit /b 1
)
if not exist "%MMPROJ_GGUF%" (
  echo [ERROR] Model file not found: %MMPROJ_GGUF%
  pause
  exit /b 1
)

echo Starting llama-server on port 8099 ...
echo   - MODEL:   %MODEL%
echo   - LLM:     %LLM_GGUF%
echo   - vision:  %MMPROJ_GGUF%
echo Logs: server.out / server.err   (Ctrl-C here stops it)

bin\llama-server.exe --host 0.0.0.0 --port 8099 ^
  -m "%LLM_GGUF%" ^
  --mmproj "%MMPROJ_GGUF%" ^
  -c 8192 --parallel 1 --alias hunyuanocr ^
  --path web
