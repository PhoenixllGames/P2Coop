@echo off
rem Builds the patched copies of Postal2.exe into a game System folder:
rem   P2Ucc.exe      + P2UccHk.dll   commandlet runner (make, batchexport)
rem   P2CoopHost.exe + P2CoopHk.dll  co-op game exe with engine fixes (host and clients)
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

call :hook p2ucchk P2UccHk P2Ucc || exit /b 1
call :hook p2coophk P2CoopHk P2CoopHost || exit /b 1
rem The engine names the splash bitmap and localization file after the exe.
copy /y "%SYS%\Postal2Splash.bmp" "%SYS%\P2CoopHostSplash.bmp" >nul || exit /b 1
copy /y "%SYS%\Postal2.int" "%SYS%\P2CoopHost.int" >nul || exit /b 1
exit /b 0

:hook
rem %1 source basename, %2 DLL name, %3 exe name
cl /nologo /c /O1 /MT /W3 /Fo"%OUT%\%1.obj" "%HERE%%1.cpp" || exit /b 1
link /nologo /DLL /MACHINE:X86 /DEF:"%HERE%%1.def" /OUT:"%OUT%\%2.dll" "%OUT%\%1.obj" user32.lib kernel32.lib || exit /b 1
python -I "%HERE%patchexe.py" "%SYS%\Postal2.exe" "%OUT%\%3.exe" %2.dll || exit /b 1
copy /y "%OUT%\%2.dll" "%SYS%\%2.dll" >nul || exit /b 1
copy /y "%OUT%\%3.exe" "%SYS%\%3.exe" >nul || exit /b 1
echo Installed %2.dll and %3.exe into %SYS%
exit /b 0
