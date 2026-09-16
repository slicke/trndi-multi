# trndi-multi — every Trndi account in one window.
# A thin wrapper around lazbuild; builds against the vendored trndi submodule.

LAZBUILD ?= lazbuild
BUILD_MODE ?= Release

# Widgetset per OS, as Trndi's own Makefile picks it. Override on the command
# line, e.g. `make WIDGETSET=gtk2`.
ifeq ($(OS),Windows_NT)
  WIDGETSET ?= win32
  BIN := bin/trndi-multi.exe
else ifeq ($(shell uname -s),Darwin)
  WIDGETSET ?= cocoa
  BIN := bin/trndi-multi
else
  WIDGETSET ?= qt6
  BIN := bin/trndi-multi
endif

LAZFLAGS = --widgetset=$(WIDGETSET) --build-mode="$(BUILD_MODE)"

# Artwork. LOGO is the master; TrndiMulti.png is the square app icon it is
# normalised into (for the macOS bundle and the Linux hicolor icon) and
# TrndiMulti.ico the Windows form of it, which lazbuild embeds as MAINICON
# and the LCL loads into Application.Icon on every platform. Both derived
# files are committed, so a build never needs ImageMagick — only 'make icon'
# does, after the artwork changes. Another master: make icon LOGO=other.png
LOGO ?= trndi-multi.png
MAGICK ?= $(shell command -v magick 2>/dev/null || command -v convert 2>/dev/null)

.PHONY: all build debug rebuild run clean icon install uninstall help

all: build

help:
	@echo "Targets:"
	@echo "  build     Release build (default; honors BUILD_MODE and WIDGETSET)"
	@echo "  debug     Debug build (range checks, heaptrc, DWARF)"
	@echo "  rebuild   Release build with every unit recompiled (-B)"
	@echo "  run       Build, then start it"
	@echo "  clean     Remove lib/, bin/ and the generated project resource"
	@echo "  icon      Rebuild TrndiMulti.png/.ico from \$$(LOGO) (needs ImageMagick)"
	@echo "  install   Copy the binary to \$$(PREFIX)/bin (default /usr/local); on Linux/BSD also the desktop entry and icon"
	@echo "Current: WIDGETSET=$(WIDGETSET) BUILD_MODE=$(BUILD_MODE) LOGO=$(LOGO)"

build:
	$(LAZBUILD) $(LAZFLAGS) TrndiMulti.lpi

debug:
	$(LAZBUILD) --widgetset=$(WIDGETSET) --build-mode=Debug TrndiMulti.lpi

rebuild:
	$(LAZBUILD) -B $(LAZFLAGS) TrndiMulti.lpi

run: build
	./$(BIN)

clean:
	rm -rf lib bin
	@# lazbuild writes these beside the main source from TrndiMulti.ico.
	rm -f src/trndimulti.res src/trndimulti.ico

# Regenerate the icons from the master artwork and commit the result. The mark is
# trimmed out of the master's wide transparent margin and re-centred on a
# square canvas at 88% — artwork that keeps its own padding reads as a
# stamp-sized blob in a 32px taskbar. 256 is the largest classic ICO size,
# so that is where the .ico stops.
icon:
	@if [ -z "$(MAGICK)" ]; then echo "ImageMagick not found; install 'magick' (or 'convert') to rebuild the icons"; exit 1; fi
	@# -strip: ImageMagick stamps a PNG with the time it wrote it, and these
	@# two files are committed — without it every run is a diff.
	$(MAGICK) $(LOGO) -trim +repage -resize 452x452 -background none \
	  -gravity center -extent 512x512 -strip TrndiMulti.png
	$(MAGICK) TrndiMulti.png -background none \
	  -define icon:auto-resize=256,128,64,48,32,16 TrndiMulti.ico
	@echo "Rebuilt TrndiMulti.png and TrndiMulti.ico; rebuild to embed them."

ifeq ($(shell uname -s),Haiku)
  PREFIX ?= /boot/home/config/non-packaged
else
  PREFIX ?= /usr/local
endif

install: build
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(BIN) $(DESTDIR)$(PREFIX)/bin/trndi-multi
	@# The window icon travels inside the binary; a launcher and a taskbar
	@# want it on disk as well, under the name the desktop entry gives.
	@case "$$(uname -s)" in \
	Linux|*BSD|DragonFly) \
	  echo "Installing desktop entry and icon"; \
	  install -d $(DESTDIR)$(PREFIX)/share/applications \
	    $(DESTDIR)$(PREFIX)/share/icons/hicolor/256x256/apps; \
	  install -m 644 dist/linux/trndi-multi.desktop \
	    $(DESTDIR)$(PREFIX)/share/applications/trndi-multi.desktop; \
	  if [ -n "$(MAGICK)" ]; then \
	    $(MAGICK) TrndiMulti.png -resize 256x256 \
	      $(DESTDIR)$(PREFIX)/share/icons/hicolor/256x256/apps/trndi-multi.png; \
	  else \
	    install -m 644 TrndiMulti.png \
	      $(DESTDIR)$(PREFIX)/share/icons/hicolor/256x256/apps/trndi-multi.png; \
	  fi; \
	  if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q "$(DESTDIR)$(PREFIX)/share/icons/hicolor" || true; fi; \
	  if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q "$(DESTDIR)$(PREFIX)/share/applications" || true; fi; \
	  ;; \
	esac

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/trndi-multi
	rm -f $(DESTDIR)$(PREFIX)/share/applications/trndi-multi.desktop
	rm -f $(DESTDIR)$(PREFIX)/share/icons/hicolor/256x256/apps/trndi-multi.png
	@if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q "$(DESTDIR)$(PREFIX)/share/icons/hicolor" || true; fi
	@if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q "$(DESTDIR)$(PREFIX)/share/applications" || true; fi
