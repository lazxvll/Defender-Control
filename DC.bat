@echo off
setlocal enabledelayedexpansion
title Defender Control

>nul 2>&1 cacls "%SYSTEMROOT%\system32\config\system" || (
    powershell -Command "Start-Process '%~f0' -Verb runAs"
    exit /b
)

mode con: cols=52 lines=24

powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; $s=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds; $w=($s.Width-$Host.UI.RawUI.WindowSize.Width*8)/2; $h=($s.Height-$Host.UI.RawUI.WindowSize.Height*16)/2; Add-Type -Name W -Namespace W -MemberDefinition '[DllImport(\"user32.dll\")]public static extern bool SetWindowPos(IntPtr hWnd,IntPtr h,int X,int Y,int cX,int cY,uint f);'; [W.W]::SetWindowPos((Get-Process -Id $pid).MainWindowHandle,0,$w,$h,0,0,0x0001)"

cd /d "%~dp0"
set "PS_SCRIPT=%~dp0work\DefenderControl.ps1"

:MENU
mode con: cols=52 lines=24
cls
echo.
echo  Defender Control
echo  ----------------
echo  1 - Disable
echo  2 - Enable
echo  3 - Status
echo  0 - Exit
echo.

for /f "delims=" %%k in ('powershell -NoProfile -Command "[Console]::ReadKey($true).KeyChar"') do set "C=%%k"

if "%C%"=="1" goto DO_DISABLE
if "%C%"=="2" goto DO_ENABLE
if "%C%"=="3" goto DO_STATUS
if "%C%"=="0" exit /b
goto MENU

:DO_DISABLE
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Mode Disable
echo.
pause
goto MENU

:DO_ENABLE
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Mode Enable
echo.
pause
goto MENU

:DO_STATUS
mode con: cols=80 lines=60
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -Mode Status
echo.
pause
goto MENU
