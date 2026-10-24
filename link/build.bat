@echo off
rem Builds P2CoopLink.exe and the mock steam_api.dll (both 32 bit) with Visual Studio.
rem Usage: build.bat [<POSTAL 2 folder>]
rem   With a folder: installs <folder>\P2CoopLinkMock (exe + mock steam_api.dll, for tests) and,
rem   if link\redist\steam_api.dll exists, <folder>\P2CoopLink (exe + real steam_api.dll).
setlocal
set HERE=%~dp0
set OUT=%HERE%out
if not exist "%OUT%" mkdir "%OUT%"
rem Visual Studio: VCVARS (path to vcvars32.bat), else the newest install vswhere finds.
if defined VCVARS goto :have_vc
for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath`) do set "VCVARS=%%i\VC\Auxiliary\Build\vcvars32.bat"
:have_vc
if not defined VCVARS (echo Visual Studio not found: set VCVARS to vcvars32.bat & exit /b 1)
call "%VCVARS%" >nul 2>nul || exit /b 1

cl /nologo /std:c11 /O2 /W3 /MT /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\\" /Fe"%OUT%\P2CoopLink.exe" "%HERE%p2cooplink.c" || exit /b 1
cl /nologo /std:c11 /O2 /W3 /MT /LD /D_CRT_SECURE_NO_WARNINGS /Fo"%OUT%\\" /Fe"%OUT%\steam_api.dll" "%HERE%mock\mock_steam_api.c" ws2_32.lib || exit /b 1

if "%~1"=="" exit /b 0
set DEST=%~1
if not exist "%DEST%\System\Postal2.exe" (echo no System\Postal2.exe in %DEST% & exit /b 2)
if not exist "%DEST%\P2CoopLinkMock" mkdir "%DEST%\P2CoopLinkMock"
copy /y "%OUT%\P2CoopLink.exe" "%DEST%\P2CoopLinkMock\" >nul || exit /b 1
copy /y "%OUT%\steam_api.dll" "%DEST%\P2CoopLinkMock\" >nul || exit /b 1
echo 480> "%DEST%\P2CoopLinkMock\steam_appid.txt"
echo Installed %DEST%\P2CoopLinkMock
if not exist "%HERE%redist\steam_api.dll" exit /b 0
if not exist "%DEST%\P2CoopLink" mkdir "%DEST%\P2CoopLink"
copy /y "%OUT%\P2CoopLink.exe" "%DEST%\P2CoopLink\" >nul || exit /b 1
copy /y "%HERE%redist\steam_api.dll" "%DEST%\P2CoopLink\" >nul || exit /b 1
echo 480> "%DEST%\P2CoopLink\steam_appid.txt"
echo Installed %DEST%\P2CoopLink
