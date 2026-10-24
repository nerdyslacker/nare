
ODIN ?= odin
BUILD_DIR := build
PREFIX ?= /usr
DESTDIR ?=
BINDIR := $(PREFIX)/bin
DATADIR := $(PREFIX)/share
ICONDIR := $(DATADIR)/icons/hicolor/256x256/apps
DESKTOPDIR := $(DATADIR)/applications
TERMINFO_DIR := $(DATADIR)/terminfo

APP := $(BUILD_DIR)/nare
APP_CPU := $(BUILD_DIR)/nare-cpu
ODIN_FLAGS := -vet -strict-style

.PHONY: build cpu release check run install uninstall clean

build:
	mkdir -p $(BUILD_DIR)
	$(ODIN) build src $(ODIN_FLAGS) -define:RENDERER_GPU=true -debug -out:$(APP)

cpu:
	mkdir -p $(BUILD_DIR)
	$(ODIN) build src $(ODIN_FLAGS) -debug -out:$(APP_CPU)

release:
	mkdir -p $(BUILD_DIR)
	$(ODIN) build src $(ODIN_FLAGS) -define:RENDERER_GPU=true -o:speed -out:$(APP)
	$(ODIN) build src $(ODIN_FLAGS) -o:speed -out:$(APP_CPU)

check:
	$(ODIN) check src $(ODIN_FLAGS) -define:RENDERER_GPU=true
	$(ODIN) check src $(ODIN_FLAGS)

run: build
	./$(APP)

install: release
	install -Dm755 $(APP) $(DESTDIR)$(BINDIR)/nare
	install -Dm755 $(APP_CPU) $(DESTDIR)$(BINDIR)/nare-cpu
	install -Dm644 assets/logo_256.png $(DESTDIR)$(ICONDIR)/nare.png
	install -Dm644 nare.desktop $(DESTDIR)$(DESKTOPDIR)/nare.desktop
	tic -x -o $(DESTDIR)$(TERMINFO_DIR) terminfo/nare.terminfo

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/nare
	rm -f $(DESTDIR)$(BINDIR)/nare-cpu
	rm -f $(DESTDIR)$(ICONDIR)/nare.png
	rm -f $(DESTDIR)$(DESKTOPDIR)/nare.desktop
	rm -f $(DESTDIR)$(TERMINFO_DIR)/n/nare

clean:
	rm -rf $(BUILD_DIR)
