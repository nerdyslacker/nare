ODIN ?= odin
ODIN_FLAGS ?= -vet -strict-style
BUILD_DIR ?= build
TERMINFO_DIR ?= $(HOME)/.terminfo
ODIN_VERSION := dev-2026-10
SRC := $(shell find src -name '*.odin' -type f)

.PHONY: all gpu check check-gpu check-terminfo install-terminfo check-version clean

all: check-version $(BUILD_DIR)/nare

$(BUILD_DIR)/nare: $(SRC)
	mkdir -p $(BUILD_DIR)
	$(ODIN) build src $(ODIN_FLAGS) -out:$@

gpu: check-version $(BUILD_DIR)/nare-gpu

$(BUILD_DIR)/nare-gpu: $(SRC)
	mkdir -p $(BUILD_DIR)
	$(ODIN) build src $(ODIN_FLAGS) -define:RENDERER_GPU=true -out:$@

check-version:
	@test "$$($(ODIN) version)" = "odin version $(ODIN_VERSION)" || \
		{ echo "expected Odin $(ODIN_VERSION)" >&2; exit 1; }

check: check-version
	$(ODIN) check src $(ODIN_FLAGS)

check-gpu: check-version
	$(ODIN) check src $(ODIN_FLAGS) -define:RENDERER_GPU=true

check-terminfo:
	mkdir -p "$(BUILD_DIR)/terminfo"
	tic -x -o "$(BUILD_DIR)/terminfo" terminfo/nare.terminfo
	TERMINFO="$(CURDIR)/$(BUILD_DIR)/terminfo" infocmp -x nare >/dev/null

install-terminfo:
	mkdir -p "$(TERMINFO_DIR)"
	tic -x -o "$(TERMINFO_DIR)" terminfo/nare.terminfo

clean:
	rm -f $(BUILD_DIR)/nare $(BUILD_DIR)/nare-gpu
