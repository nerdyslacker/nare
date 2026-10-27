
ODIN ?= odin
BUILD_DIR := build
PREFIX ?= /usr
DESTDIR ?=
BINDIR := $(PREFIX)/bin
DATADIR := $(PREFIX)/share
ICONDIR := $(DATADIR)/icons/hicolor/256x256/apps
DESKTOPDIR := $(DATADIR)/applications
TERMINFO_DIR := $(DATADIR)/terminfo
SYSCONFDIR ?= /etc
NAREDIR := $(SYSCONFDIR)/nare
NARELITEDIR := $(SYSCONFDIR)/nare-lite

APP := $(BUILD_DIR)/nare
APP_LITE := $(BUILD_DIR)/nare-lite
ODIN_FLAGS := -vet -strict-style

.PHONY: build build-lite release check run install uninstall clean

build:
	mkdir -p $(BUILD_DIR)
	$(ODIN) build src $(ODIN_FLAGS) -define:RENDERER_GPU=true -debug -out:$(APP)

build-lite:
	mkdir -p $(BUILD_DIR)
	$(ODIN) build src $(ODIN_FLAGS) -define:NARE_LITE=true -debug -out:$(APP_LITE)

release:
	mkdir -p $(BUILD_DIR)
	$(ODIN) build src $(ODIN_FLAGS) -define:RENDERER_GPU=true -o:speed -out:$(APP)
	$(ODIN) build src $(ODIN_FLAGS) -define:NARE_LITE=true -o:speed -out:$(APP_LITE)

check:
	$(ODIN) check src $(ODIN_FLAGS) -define:RENDERER_GPU=true
	$(ODIN) check src $(ODIN_FLAGS)

run: build
	./$(APP)

install: release
	install -Dm755 $(APP) $(DESTDIR)$(BINDIR)/nare
	install -Dm644 assets/logo_256.png $(DESTDIR)$(ICONDIR)/nare.png
	install -Dm644 nare.conf $(DESTDIR)$(NAREDIR)/nare.conf
	install -Dm644 nare.desktop $(DESTDIR)$(DESKTOPDIR)/nare.desktop
	tic -x -o $(DESTDIR)$(TERMINFO_DIR) terminfo/nare.terminfo
	install -Dm755 $(APP_LITE) $(DESTDIR)$(BINDIR)/nare-lite
	install -Dm644 assets/lite_logo_256.png $(DESTDIR)$(ICONDIR)/nare-lite.png
	install -Dm644 nare.conf $(DESTDIR)$(NARELITEDIR)/nare.conf
	install -Dm644 nare-lite.desktop $(DESTDIR)$(DESKTOPDIR)/nare-lite.desktop
	@if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database $(DESTDIR)$(DESKTOPDIR); fi

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/nare
	rm -f $(DESTDIR)$(ICONDIR)/nare.png
	rm -f $(DESTDIR)$(DESKTOPDIR)/nare.desktop
	rm -f $(DESTDIR)$(NAREDIR)/nare.conf
	rm -f $(DESTDIR)$(TERMINFO_DIR)/n/nare
	rm -f $(DESTDIR)$(BINDIR)/nare-lite
	rm -f $(DESTDIR)$(ICONDIR)/nare-lite.png
	rm -f $(DESTDIR)$(DESKTOPDIR)/nare-lite.desktop
	rm -f $(DESTDIR)$(NARELITEDIR)/nare.conf
	@if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database $(DESTDIR)$(DESKTOPDIR); fi

clean:
	rm -rf $(BUILD_DIR)
