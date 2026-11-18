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
    echo [INFO] Inicializando repositorio Git para SCRIP_CRISDEV...
    git init -b main
    git remote add origin https://github.com/soportecrisdev/SCRIP_CRISDEV.git
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
    echo [ERROR] Permiso denegado por GitHub (Error 403).
    echo ======================================================
    echo Tu PC tiene activa la cuenta de 'CristianBatero', pero el
    echo repositorio pertenece a 'soportecrisdev'.
    echo.
    echo Tienes 2 formas faciles de solucionarlo:
    echo 1. Invitar a 'CristianBatero' como Colaborador con permisos
    echo    de escritura en https://github.com/soportecrisdev/SCRIP_CRISDEV/settings/access
    echo.
    echo 2. O ingresar tu Token de GitHub (ghp_...) de la cuenta soportecrisdev.
    echo ======================================================
    echo.
    set TOKEN=
    set /p TOKEN="Pega aqui tu Personal Access Token (o presiona ENTER para salir): "
    if not "!TOKEN!"=="" (
        echo.
        echo [INFO] Configurando Token en el repositorio...
        git remote set-url origin https://!TOKEN!@github.com/soportecrisdev/SCRIP_CRISDEV.git
        echo [INFO] Reintentando push con el Token...
        git push origin main
        if !ERRORLEVEL! EQU 0 (
            echo.
            echo ======================================================
            echo    ✔ CAMBIOS SUBIDOS EXITOSAMENTE A GITHUB ✔
            echo ======================================================
            pause
            exit /b 0
        )
    )
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
