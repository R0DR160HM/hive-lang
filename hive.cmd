@echo off
rem The Hive command line, on Windows.
rem
rem   hive check     <entrypoint.hive>       Report any errors, build nothing
rem   hive emit      <entrypoint.hive>       Print the generated Go source
rem   hive build     <entrypoint.hive>       Compile to a native executable
rem   hive run       <entrypoint.hive> [..]  Compile and run
rem   hive test      <entrypoint.hive>       Run the program's tests, with coverage
rem   hive container <entrypoint.hive>       Write a Dockerfile that builds and runs it
rem
rem A batch file rather than a PowerShell one, for one reason: this runs from
rem cmd.exe and from PowerShell alike, and no execution policy has a say in it.
rem Like its Unix twin it is two lines of work, because the compiler does
rem everything itself — it writes the Go module and runs the Go toolchain over
rem it. All that is left here is finding the binary.
rem
rem The line endings here are CRLF on purpose: cmd.exe is the one interpreter in
rem this repository that has ever cared.
setlocal
set "hivec=%~dp0src\hivec.exe"
if not exist "%hivec%" goto missing
"%hivec%" %*
exit /b %errorlevel%

:missing
echo hive: the compiler has not been built yet. See "Installing it" in README.md. 1>&2
exit /b 1
