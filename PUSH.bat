@echo off
setlocal EnableDelayedExpansion
title CRISDEV - Push a GitHub
color 0A

echo.
echo ======================================================
echo       CRISDEV VPN Manager - Push a GitHub
echo       @CRISIS1823
echo ======================================================
echo.

cd /d "%~dp0"

if not exist ".git" (
    echo [ERROR] No se encontro repositorio Git aqui.
    echo Asegurate de que este archivo esta en la carpeta SCRIP.
    pause
    exit /b 1
)

echo.
echo ======================================================
echo  ARCHIVOS MODIFICADOS Y NUEVOS:
echo ======================================================
git status --short
echo.

set MSG=
set /p MSG="Mensaje de commit (Presiona ENTER para mensaje automatico): "

if "%MSG%"=="" (
    set MSG=Actualizacion SSH-CRIS y BHTTP %DATE% %TIME%
)

echo.
echo [1/3] Agregando todos los archivos...
git add -A

echo.
echo [2/3] Creando commit: %MSG%
git commit -m "%MSG%"

echo.
echo [3/3] Subiendo cambios a GitHub (origin/main)...
git push origin main

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ======================================================
    echo [ERROR] Fallo al subir a GitHub.
    echo ======================================================
    echo Posibles causas:
    echo 1. Conflicto con commits remotos. Intenta: git pull --rebase origin main
    echo 2. Credenciales o Token de GitHub expirado.
    echo 3. Permisos de escritura en el repositorio.
    echo.
    pause
    exit /b 1
)

echo.
echo ======================================================
echo      CAMBIOS SUBIDOS EXITOSAMENTE A GITHUB
echo ======================================================
echo.
echo Repositorio: https://github.com/soportecrisdev/SCRIP_CRISDEV
echo.
pause
