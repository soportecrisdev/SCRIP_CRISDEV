@echo off
setlocal EnableDelayedExpansion
title CRISDEV - Push a GitHub
color 0A

echo.
echo ======================================================
echo       ⚡ CRISDEV VPN Manager - Subir Cambios ⚡
echo                  @soportecrisdev
echo ======================================================
echo.

cd /d "%~dp0"

if not exist ".git" (
    echo [ERROR] No se encontro repositorio Git aqui.
    echo Asegurate de que este archivo esta en la carpeta SCRIP.
    pause
    exit /b 1
)

:: Configurar almacenamiento permanente de credenciales para no pedir usuario cada vez
git config credential.helper store
git config user.name "soportecrisdev" >nul 2>&1
git config user.email "soportecrisdev@gmail.com" >nul 2>&1

echo [INFO] Credenciales configuradas con memoria permanente (credential.helper store).
echo.

echo ======================================================
echo  ARCHIVOS MODIFICADOS Y NUEVOS:
echo ======================================================
git status --short
echo ======================================================
echo.

set MSG=
set /p MSG="Mensaje de commit (Presiona ENTER para automatico): "

if "%MSG%"=="" (
    set MSG=Update Suite CRISDEV %DATE% %TIME%
)

echo.
echo [1/3] Preparando archivos...
git add -A

echo.
echo [2/3] Creando commit: "%MSG%"...
git commit -m "%MSG%"

echo.
echo [3/3] Subiendo cambios a GitHub (origin/main)...
git push origin main

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo ======================================================
    echo [ERROR] Fallo al subir a GitHub.
    echo ======================================================
    echo Si es la primera vez que te pide el Token de GitHub,
    echo ingresalo UNA SOLA VEZ y quedara guardado para siempre.
    echo.
    pause
    exit /b 1
)

echo.
echo ======================================================
echo    ✔ CAMBIOS SUBIDOS EXITOSAMENTE A GITHUB ✔
echo ======================================================
echo.
echo Repositorio: https://github.com/soportecrisdev/SCRIP_CRISDEV
echo.
pause
