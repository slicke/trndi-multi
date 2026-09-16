# trndi-multi Windows build script (mirror of the Makefile).
#   .\make.ps1           release build
#   .\make.ps1 debug     debug build
#   .\make.ps1 clean     remove build artifacts
#   .\make.ps1 icon      rebuild the icons from the master artwork (ImageMagick)
#
# The settings/HTTP layer is Trndi's Windows native (registry + WinHTTP), so
# bin\trndi-multi.exe runs on its own; no libcurl.dll needed. The exe carries
# TrndiMulti.ico as its MAINICON resource, which is what Explorer, the task
# bar and the window frame show; lazbuild embeds it, so nothing to do here.

param([string]$Target = 'release', [string]$Logo = 'trndi-multi.png')

$ErrorActionPreference = 'Stop'

# Locate lazbuild: PATH first, then the standard Lazarus install.
$lazbuild = (Get-Command lazbuild.exe -ErrorAction SilentlyContinue).Source
if (-not $lazbuild -and (Test-Path 'C:\lazarus\lazbuild.exe')) {
    $lazbuild = 'C:\lazarus\lazbuild.exe'
}
if (-not $lazbuild) {
    throw 'lazbuild.exe not found on PATH or at C:\lazarus'
}

# Regenerate the committed artwork, as 'make icon' does: the mark trimmed out
# of the master's wide transparent margin and re-centred on a square canvas
# at 88%, then the multi-size .ico lazbuild embeds as MAINICON. -strip keeps
# the output byte-identical between runs, which a committed file wants.
function Invoke-Icon {
    $magick = (Get-Command magick.exe -ErrorAction SilentlyContinue).Source
    if (-not $magick) {
        throw 'magick.exe not found on PATH; install ImageMagick to rebuild the icons'
    }
    & $magick $Logo -trim +repage -resize 452x452 -background none `
        -gravity center -extent 512x512 -strip TrndiMulti.png
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    & $magick TrndiMulti.png -background none `
        -define icon:auto-resize=256,128,64,48,32,16 TrndiMulti.ico
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    Write-Host 'Rebuilt TrndiMulti.png and TrndiMulti.ico; rebuild to embed them.'
}

switch ($Target) {
    'release' { & $lazbuild --widgetset=win32 --build-mode=Release TrndiMulti.lpi }
    'debug'   { & $lazbuild --widgetset=win32 --build-mode=Debug TrndiMulti.lpi }
    'icon'    { Invoke-Icon }
    'clean'   {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue lib, bin
        # lazbuild writes these beside the main source from TrndiMulti.ico.
        Remove-Item -Force -ErrorAction SilentlyContinue src\trndimulti.res, src\trndimulti.ico
    }
    default   { throw "Unknown target '$Target' (release, debug, icon, clean)" }
}
if ($LASTEXITCODE) { exit $LASTEXITCODE }
