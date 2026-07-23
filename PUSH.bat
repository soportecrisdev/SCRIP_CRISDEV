@echo off
chcp 65001 >nul 2>&1
title CRISDEV - Push a GitHub
color 0A

echo.
echo ╔══════════════════════════════════════════════════════════╗
echo ║     CRISDEV VPN Manager - Push a GitHub                ║
echo ║     @CRISIS1823                                         ║
echo ╚══════════════════════════════════════════════════════════╝
echo.

REM Ir al directorio del .bat
cd /d "%~dp0"

REM Verificar que es un repositorio git
if not exist ".git" (
    echo [ERROR] No se encontro repositorio Git aqui.
    echo         Asegurate de que este archivo esta en la carpeta SCRIP.
    pause
    exit /b 1
)

REM Verificar que hay cambios
git status --porcelain
if errorlevel 1 (
    echo.
    echo [INFO] No hay cambios para subir.
    pause
    exit /b 0
)

echo.
echo ════════════════════════════════════════════════════════
echo  ARCHIVOS MODIFICADOS:
echo ════════════════════════════════════════════════════════
git status --short
echo.

REM Pedir mensaje de commit
echo ════════════════════════════════════════════════════════
set /p MSG="Mensaje de commit: "

if "%MSG%"=="" (
    REM Auto-generar mensaje con fecha y hora
    for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value') do set dt=%%I
    set MSG=Actualizacion %dt:~0,4%-%dt:~4,2%-%dt:~6,2% %dt:~8,2%:%dt:~10,2%
)

echo.
echo [1/3] Agregando archivos...
git add -A

echo [2/3] Creando commit: %MSG%
git commit -m "%MSG%"

echo [3/3] Subiendo a GitHub...
git push origin main

if errorlevel 1 (
    echo.
    echo [ERROR] Fallo al subir. Verifica tu conexion y credenciales.
    echo         Si es la primera vez, ejecuta:
    echo         git remote add origin https://github.com/soportecrisdev/SCRIP_CRISDEV.git
    echo         git push -u origin main
    pause
    exit /b 1
)

echo.
echo ╔══════════════════════════════════════════════════════════╗
echo ║     CAMBIOS SUBIDOS EXITOSAMENTE A GITHUB              ║
echo ╚══════════════════════════════════════════════════════════╝
echo.
echo  Repo: https://github.com/soportecrisdev/SCRIP_CRISDEV
echo.
pause
