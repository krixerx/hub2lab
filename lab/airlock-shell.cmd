@echo off
REM Opens the shell the lab expects, in the lab directory, with the credentials
REM already loaded. Double-click it in Explorer, or run it from cmd.
REM
REM The airlock scripts are bash scripts. PowerShell and cmd cannot run them, so
REM everything in RUNBOOK.md and docs/airlock-proof-run.md is typed here.

setlocal
cd /d "%~dp0"

set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%BASH%" set "BASH=%ProgramW6432%\Git\bin\bash.exe"
if not exist "%BASH%" (
  echo.
  echo   Git for Windows is not installed, or not where this expects it.
  echo   Get it from https://git-scm.com/download/win and run this again.
  echo.
  pause
  exit /b 1
)

REM No --login: it would move to the home directory and lose the lab as the
REM working directory. A plain interactive bash inherits the Windows PATH, which
REM is where git, docker and python already are.
start "Airlock lab" "%BASH%" -i -c "if [ -f ./.secrets ]; then source ./.secrets; echo '  loaded .secrets'; else echo '  no .secrets yet - run scripts/gitlab-bootstrap.sh'; fi; if [ -f ./demo.env ]; then source ./demo.env; echo '  loaded demo.env'; fi; echo; echo '  Lab shell. See RUNBOOK.md for what to type.'; echo; exec bash -i"
endlocal
