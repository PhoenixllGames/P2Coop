@echo off
rem Builds into a game System folder:
rem   P2Ucc.exe + P2UccHk.dll  commandlet runner (make, batchexport): a patched copy of Postal2.exe
rem   dinput8.dll              P2CoopHk: the co-op engine fixes, loaded by the stock Postal2.exe
rem Usage: build.bat <game System folder>   (the test copy, never the Steam install)
setlocal
set SYS=%~1
if "%SYS%"=="" (echo usage: build.bat ^<game System folder^> & exit /b 2)
if not exist "%SYS%\Postal2.exe" (echo no Postal2.exe in %SYS% & exit /b 2)
set HERE=%~dp0
set OUT=%HERE%out
if not exist "%OUT%" mkdir "%OUT%"

rem Visual Studio: VCVARS (path to vcvars32.bat), else the newest install vswhere finds.
if defined VCVARS goto :have_vc
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath`) do set "VCVARS=%%i\VC\Auxiliary\Build\vcvars32.bat"
:have_vc
if not defined VCVARS (echo Visual Studio not found: set VCVARS to vcvars32.bat & exit /b 1)
call "%VCVARS%" >nul 2>nul || exit /b 1

call :dll p2ucchk P2UccHk || exit /b 1
python -I "%HERE%patchexe.py" "%SYS%\Postal2.exe" "%OUT%\P2Ucc.exe" P2UccHk.dll || exit /b 1
copy /y "%OUT%\P2UccHk.dll" "%SYS%\P2UccHk.dll" >nul || exit /b 1
copy /y "%OUT%\P2Ucc.exe" "%SYS%\P2Ucc.exe" >nul || exit /b 1
echo Installed P2UccHk.dll and P2Ucc.exe into %SYS%

call :dll p2coophk dinput8 || exit /b 1
copy /y "%OUT%\dinput8.dll" "%SYS%\dinput8.dll" >nul || exit /b 1
echo Installed dinput8.dll (P2CoopHk) into %SYS%
rem The co-op exe of earlier versions: the stock Postal2.exe runs the fixes now.
for %%f in (P2CoopHost.exe P2CoopHk.dll P2CoopHostSplash.bmp P2CoopHost.int) do if exist "%SYS%\%%f" del /q "%SYS%\%%f"
exit /b 0

:dll
rem %1 source basename, %2 DLL name
cl /nologo /c /O1 /MT /W3 /Fo"%OUT%\%1.obj" "%HERE%%1.cpp" || exit /b 1
link /nologo /DLL /MACHINE:X86 /DEF:"%HERE%%1.def" /OUT:"%OUT%\%2.dll" "%OUT%\%1.obj" user32.lib kernel32.lib || exit /b 1
exit /b 0
