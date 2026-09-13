# trndi-multi Windows build script (mirror of the Makefile).
#   .\make.ps1           release build
#   .\make.ps1 debug     debug build
#   .\make.ps1 clean     remove build artifacts
#
# The settings/HTTP layer is Trndi's Windows native (registry + WinHTTP), so
# bin\trndi-multi.exe runs on its own; no libcurl.dll needed.

param([string]$Target = 'release')

$ErrorActionPreference = 'Stop'

# Locate lazbuild: PATH first, then the standard Lazarus install.
$lazbuild = (Get-Command lazbuild.exe -ErrorAction SilentlyContinue).Source
if (-not $lazbuild -and (Test-Path 'C:\lazarus\lazbuild.exe')) {
    $lazbuild = 'C:\lazarus\lazbuild.exe'
}
if (-not $lazbuild) {
    throw 'lazbuild.exe not found on PATH or at C:\lazarus'
}

switch ($Target) {
    'release' { & $lazbuild --widgetset=win32 --build-mode=Release TrndiMulti.lpi }
    'debug'   { & $lazbuild --widgetset=win32 --build-mode=Debug TrndiMulti.lpi }
    'clean'   { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue lib, bin }
    default   { throw "Unknown target '$Target' (release, debug, clean)" }
}
if ($LASTEXITCODE) { exit $LASTEXITCODE }
