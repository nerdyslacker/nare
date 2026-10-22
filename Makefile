ODIN ?= odin
ODIN_FLAGS ?= -vet -strict-style
BUILD_DIR ?= build
ODIN_VERSION := dev-2026-10
SRC := $(shell find src -name '*.odin' -type f)

.PHONY: all check check-version clean

all: check-version $(BUILD_DIR)/nare

$(BUILD_DIR)/nare: $(SRC)
	mkdir -p $(BUILD_DIR)
	$(ODIN) build src $(ODIN_FLAGS) -out:$@

check-version:
	@test "$$($(ODIN) version)" = "odin version $(ODIN_VERSION)" || \
		{ echo "expected Odin $(ODIN_VERSION)" >&2; exit 1; }

check: check-version
	$(ODIN) check src $(ODIN_FLAGS)

clean:
	rm -f $(BUILD_DIR)/nare
