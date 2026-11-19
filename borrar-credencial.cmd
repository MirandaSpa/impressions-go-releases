@echo off
rem Borrar la credencial guardada del agente de impresion
rem Doble clic con la sesion de Windows de la persona que usara el agente
rem (no "Ejecutar como administrador"). Descarga y corre install.ps1 de
rem https://github.com/MirandaSpa/impressions-go-releases.
title Borrar la credencial guardada del agente de impresion
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072; try { & ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/MirandaSpa/impressions-go-releases/main/install.ps1' -UseBasicParsing))) -BorrarCredencial } catch { Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }"
echo.
pause
