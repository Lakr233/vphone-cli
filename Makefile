# ═══════════════════════════════════════════════════════════════════
# vphone-cli — Virtual iPhone boot tool
# ═══════════════════════════════════════════════════════════════════

# ─── Configuration (override with make VAR=value) ─────────────────
VM_DIR      ?= vm
CPU         ?= 4
MEMORY      ?= 4096
DISK_SIZE   ?= 64

# ─── Paths ────────────────────────────────────────────────────────
SCRIPTS     := scripts
BINARY      := .build/release/vphone-cli
ENTITLEMENTS := sources/vphone.entitlements
VENV        := .venv
LIMD_PREFIX := .limd
IRECOVERY   := $(LIMD_PREFIX)/bin/irecovery
IDEVICERESTORE := $(LIMD_PREFIX)/bin/idevicerestore
PYTHON      := $(CURDIR)/$(VENV)/bin/python3

SWIFT_SOURCES := $(shell find sources -name '*.swift')

# ─── Environment — prefer project-local binaries ────────────────
export PATH := $(CURDIR)/$(LIMD_PREFIX)/bin:$(CURDIR)/$(VENV)/bin:$(CURDIR)/.build/release:$(PATH)

# ─── Default ──────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "vphone-cli — Virtual iPhone boot tool"
	@echo ""
	@echo "Setup (one-time):"
	@echo "  make setup_venv              Create Python .venv"
	@echo "  make setup_libimobiledevice  Build libimobiledevice toolchain"
	@echo ""
	@echo "Build:"
	@echo "  make build                   Build + sign vphone-cli"
	@echo "  make install                 Build + copy to ./bin/"
	@echo "  make clean                   Remove .build/"
	@echo ""
	@echo "VM management:"
	@echo "  make vm_new                  Create VM directory"
	@echo "  make boot                    Boot VM (GUI)"
	@echo "  make boot_dfu                Boot VM in DFU mode"
	@echo ""
	@echo "Firmware pipeline:"
	@echo "  make fw_prepare              Download IPSWs, extract, merge"
	@echo "  make fw_patch                Patch boot chain (6 components)"
	@echo ""
	@echo "Restore:"
	@echo "  make restore_get_shsh        Fetch SHSH blob from device"
	@echo "  make restore                 idevicerestore to device"
	@echo ""
	@echo "Ramdisk:"
	@echo "  make ramdisk_build           Build signed SSH ramdisk"
	@echo "  make ramdisk_send            Send ramdisk to device"
	@echo ""
	@echo "CFW:"
	@echo "  make cfw_install             Install CFW mods via SSH"
	@echo ""
	@echo "Variables: VM_DIR=$(VM_DIR) CPU=$(CPU) MEMORY=$(MEMORY) DISK_SIZE=$(DISK_SIZE)"

# ═══════════════════════════════════════════════════════════════════
# Setup
# ═══════════════════════════════════════════════════════════════════

.PHONY: setup_venv setup_libimobiledevice

setup_venv:
	zsh $(SCRIPTS)/setup_venv.sh

setup_libimobiledevice:
	bash $(SCRIPTS)/setup_libimobiledevice.sh

# ═══════════════════════════════════════════════════════════════════
# Build
# ═══════════════════════════════════════════════════════════════════

.PHONY: build install clean

build: $(BINARY)

$(BINARY): $(SWIFT_SOURCES) Package.swift $(ENTITLEMENTS)
	@echo "=== Building vphone-cli ==="
	swift build -c release 2>&1 | tail -5
	@echo ""
	@echo "=== Signing with entitlements ==="
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $@
	@echo "  signed OK"

install: build
	mkdir -p ./bin
	cp -f $(BINARY) ./bin/vphone-cli
	@echo "Installed to ./bin/vphone-cli"

clean:
	swift package clean
	rm -rf .build

# ═══════════════════════════════════════════════════════════════════
# VM management
# ═══════════════════════════════════════════════════════════════════

.PHONY: vm_new boot boot_dfu

vm_new:
	zsh $(SCRIPTS)/vm_create.sh --dir $(VM_DIR) --disk-size $(DISK_SIZE)

boot: build
	cd $(VM_DIR) && "$(CURDIR)/$(BINARY)" \
		--rom ./AVPBooter.vresearch1.bin \
		--disk ./Disk.img \
		--nvram ./nvram.bin \
		--cpu $(CPU) --memory $(MEMORY) \
		--sep-rom ./AVPSEPBooter.vresearch1.bin \
		--sep-storage ./SEPStorage

boot_dfu: build
	cd $(VM_DIR) && "$(CURDIR)/$(BINARY)" \
		--rom ./AVPBooter.vresearch1.bin \
		--disk ./Disk.img \
		--nvram ./nvram.bin \
		--cpu $(CPU) --memory $(MEMORY) \
		--sep-rom ./AVPSEPBooter.vresearch1.bin \
		--sep-storage ./SEPStorage \
		--no-graphics --dfu

# ═══════════════════════════════════════════════════════════════════
# Firmware pipeline
# ═══════════════════════════════════════════════════════════════════

.PHONY: fw_prepare fw_patch

fw_prepare:
	cd $(VM_DIR) && bash "$(CURDIR)/$(SCRIPTS)/fw_prepare.sh"

fw_patch:
	cd $(VM_DIR) && $(PYTHON) "$(CURDIR)/$(SCRIPTS)/fw_patch.py" .

# ═══════════════════════════════════════════════════════════════════
# Restore
# ═══════════════════════════════════════════════════════════════════

.PHONY: restore_get_shsh restore

restore_get_shsh:
	cd $(VM_DIR) && "$(CURDIR)/$(IDEVICERESTORE)" -e -y ./iPhone*_Restore -t

restore:
	cd $(VM_DIR) && "$(CURDIR)/$(IDEVICERESTORE)" -e -y ./iPhone*_Restore

# ═══════════════════════════════════════════════════════════════════
# Ramdisk
# ═══════════════════════════════════════════════════════════════════

.PHONY: ramdisk_build ramdisk_send

ramdisk_build:
	cd $(VM_DIR) && $(PYTHON) "$(CURDIR)/$(SCRIPTS)/ramdisk_build.py" .

ramdisk_send:
	cd $(VM_DIR) && IRECOVERY="$(CURDIR)/$(IRECOVERY)" zsh "$(CURDIR)/$(SCRIPTS)/ramdisk_send.sh"

# ═══════════════════════════════════════════════════════════════════
# CFW
# ═══════════════════════════════════════════════════════════════════

.PHONY: cfw_install

cfw_install:
	cd $(VM_DIR) && zsh "$(CURDIR)/$(SCRIPTS)/cfw_install.sh" .
