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

.PHONY: all build debug rebuild run clean install uninstall help

all: build

help:
	@echo "Targets:"
	@echo "  build     Release build (default; honors BUILD_MODE and WIDGETSET)"
	@echo "  debug     Debug build (range checks, heaptrc, DWARF)"
	@echo "  rebuild   Release build with every unit recompiled (-B)"
	@echo "  run       Build, then start it"
	@echo "  clean     Remove lib/ and bin/"
	@echo "  install   Copy the binary to \$$(PREFIX)/bin (default /usr/local)"
	@echo "Current: WIDGETSET=$(WIDGETSET) BUILD_MODE=$(BUILD_MODE)"

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

ifeq ($(shell uname -s),Haiku)
  PREFIX ?= /boot/home/config/non-packaged
else
  PREFIX ?= /usr/local
endif

install: build
	install -d $(DESTDIR)$(PREFIX)/bin
	install -m 755 $(BIN) $(DESTDIR)$(PREFIX)/bin/trndi-multi

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/trndi-multi
