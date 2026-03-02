# ═══════════════════════════════════════════════════════════════════
# vphone-cli — Virtual iPhone boot tool
# ═══════════════════════════════════════════════════════════════════

# ─── Configuration (override with make VAR=value) ─────────────────
VM_DIR      ?= vm
CPU         ?= 8
MEMORY      ?= 8192
DISK_SIZE   ?= 64
CFW_INPUT   ?= cfw_input

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
	@echo "  make setup_machine           Full setup through README First Boot"
	@echo "  make setup_venv              Create Python .venv"
	@echo "  make setup_libimobiledevice  Build libimobiledevice toolchain"
	@echo ""
	@echo "Build:"
	@echo "  make build                   Build + sign vphone-cli"
	@echo "  make vphoned                 Cross-compile vphoned for iOS"
	@echo "  make vphoned_sign            Sign vphoned (requires cfw_input)"
	@echo "  make install                 Build + copy to ./bin/"
	@echo "  make clean                   Remove .build/"
	@echo "VM management:"
	@echo "  make vm_new                  Create VM directory"
	@echo "  make boot                    Boot VM (GUI)"
	@echo "  make boot_dfu                Boot VM in DFU mode"
	@echo ""
	@echo "Firmware pipeline:"
	@echo "  make fw_prepare              Download IPSWs, extract, merge"
	@echo "  make fw_patch                Patch boot chain (6 components)"
	@echo "  make fw_patch_jb             Run fw_patch + JB extension patches (WIP)"
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
	@echo "  make cfw_install_jb          Install CFW + JB extensions (jetsam/procursus/basebin)"
	@echo ""
	@echo "Variables: VM_DIR=$(VM_DIR) CPU=$(CPU) MEMORY=$(MEMORY) DISK_SIZE=$(DISK_SIZE)"

# ═══════════════════════════════════════════════════════════════════
# Setup
# ═══════════════════════════════════════════════════════════════════

.PHONY: setup_machine setup_venv setup_libimobiledevice

setup_machine:
	zsh $(SCRIPTS)/setup_machine.sh

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
	rm -f $(SCRIPTS)/vphoned/vphoned

# Cross-compile vphoned daemon for iOS arm64 (installed into VM by cfw_install)
.PHONY: vphoned
vphoned: $(SCRIPTS)/vphoned/vphoned

$(SCRIPTS)/vphoned/vphoned: $(SCRIPTS)/vphoned/vphoned.m
	@echo "=== Building vphoned (arm64, iphoneos) ==="
	xcrun -sdk iphoneos clang -arch arm64 -Os -fobjc-arc \
		-o $@ $< -framework Foundation
	@echo "  built OK"

# Sign vphoned with entitlements using cfw_input tools (requires make cfw_install to have unpacked cfw_input)
.PHONY: vphoned_sign
vphoned_sign: $(SCRIPTS)/vphoned/vphoned
	@test -f "$(VM_DIR)/$(CFW_INPUT)/tools/ldid_macosx_arm64" \
		|| (echo "Error: ldid not found. Run 'make cfw_install' first to unpack cfw_input." && exit 1)
	@echo "=== Signing vphoned ==="
	cp $(SCRIPTS)/vphoned/vphoned $(VM_DIR)/.vphoned.signed
	$(VM_DIR)/$(CFW_INPUT)/tools/ldid_macosx_arm64 \
		-S$(SCRIPTS)/vphoned/entitlements.plist \
		-M "-K$(SCRIPTS)/vphoned/signcert.p12" \
		$(VM_DIR)/.vphoned.signed
	@echo "  signed → $(VM_DIR)/.vphoned.signed"

# ═══════════════════════════════════════════════════════════════════
# VM management
# ═══════════════════════════════════════════════════════════════════

.PHONY: vm_new boot boot_dfu

vm_new:
	zsh $(SCRIPTS)/vm_create.sh --dir $(VM_DIR) --disk-size $(DISK_SIZE)

boot: build vphoned_sign
	cd $(VM_DIR) && "$(CURDIR)/$(BINARY)" \
		--rom ./AVPBooter.vresearch1.bin \
		--disk ./Disk.img \
		--nvram ./nvram.bin \
		--machine-id ./machineIdentifier.bin \
		--cpu $(CPU) --memory $(MEMORY) \
		--sep-rom ./AVPSEPBooter.vresearch1.bin \
		--sep-storage ./SEPStorage

boot_dfu: build
	cd $(VM_DIR) && "$(CURDIR)/$(BINARY)" \
		--rom ./AVPBooter.vresearch1.bin \
		--disk ./Disk.img \
		--nvram ./nvram.bin \
		--machine-id ./machineIdentifier.bin \
		--cpu $(CPU) --memory $(MEMORY) \
		--sep-rom ./AVPSEPBooter.vresearch1.bin \
		--sep-storage ./SEPStorage \
		--no-graphics --dfu

# ═══════════════════════════════════════════════════════════════════
# Firmware pipeline
# ═══════════════════════════════════════════════════════════════════

.PHONY: fw_prepare fw_patch fw_patch_jb

fw_prepare:
	cd $(VM_DIR) && bash "$(CURDIR)/$(SCRIPTS)/fw_prepare.sh"

fw_patch:
	cd $(VM_DIR) && $(PYTHON) "$(CURDIR)/$(SCRIPTS)/fw_patch.py" .

fw_patch_jb:
	cd $(VM_DIR) && $(PYTHON) "$(CURDIR)/$(SCRIPTS)/fw_patch_jb.py" .

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

.PHONY: cfw_install cfw_install_jb

cfw_install:
	cd $(VM_DIR) && zsh "$(CURDIR)/$(SCRIPTS)/cfw_install.sh" .

cfw_install_jb:
	cd $(VM_DIR) && zsh "$(CURDIR)/$(SCRIPTS)/cfw_install_jb.sh" .
