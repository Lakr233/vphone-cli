# ═══════════════════════════════════════════════════════════════════
# vphone-cli — Virtual iPhone boot tool
# ═══════════════════════════════════════════════════════════════════

# ─── Configuration (override with make VAR=value) ─────────────────
VM_DIR      ?= vm
CPU         ?= 8          # CPU cores (only used during vm_new)
MEMORY      ?= 8192       # Memory in MB (only used during vm_new)
DISK_SIZE   ?= 64         # Disk size in GB (only used during vm_new)
RESTORE_UDID ?=           # UDID for restore operations
RESTORE_ECID ?=           # ECID for restore operations
IRECOVERY_ECID ?=         # ECID for irecovery operations

# ─── Build info ──────────────────────────────────────────────────
GIT_HASH    := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_INFO  := sources/vphone-cli/VPhoneBuildInfo.swift

# ─── Paths ────────────────────────────────────────────────────────
SCRIPTS     := scripts
BINARY      := .build/release/vphone-cli
BUNDLE      := .build/vphone-cli.app
BUNDLE_BIN  := $(BUNDLE)/Contents/MacOS/vphone-cli
INFO_PLIST  := sources/Info.plist
ENTITLEMENTS := sources/vphone.entitlements
VENV        := .venv
LIMD_PREFIX := .limd
TOOLS_PREFIX := .tools
IRECOVERY   := $(LIMD_PREFIX)/bin/irecovery
IDEVICERESTORE := $(LIMD_PREFIX)/bin/idevicerestore
PYTHON      := $(CURDIR)/$(VENV)/bin/python3

SWIFT_SOURCES := $(shell find sources -name '*.swift')

# ─── Environment — prefer project-local binaries ────────────────
export PATH := $(CURDIR)/$(TOOLS_PREFIX)/bin:$(CURDIR)/$(LIMD_PREFIX)/bin:$(CURDIR)/$(VENV)/bin:$(CURDIR)/.build/release:$(PATH)

# ─── Default ──────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "vphone-cli — Virtual iPhone boot tool"
	@echo ""
	@echo "LazyCat (AIO):"
	@echo "  make setup_machine                   Full setup through First Boot"
	@echo "    Options: JB=1                      Jailbreak firmware/CFW path"
	@echo "             DEV=1                     Dev firmware/CFW path (dev TXM + cfw_install_dev)"
	@echo "             SKIP_PROJECT_SETUP=1      Skip setup_tools/build"
	@echo "             NONE_INTERACTIVE=1        Auto-continue prompts + boot analysis"
	@echo "             SUDO_PASSWORD=...         Preload sudo credential for setup flow"
	@echo ""
	@echo "Setup (one-time):"
	@echo "  make setup_tools             Install all tools (brew, trustcache, insert_dylib, libimobiledevice, venv)"
	@echo ""
	@echo "Build:"
	@echo "  make build                   Build + sign vphone-cli"
	@echo "  make vphoned                 Cross-compile + sign vphoned for iOS"
	@echo "  make clean                   Remove all build artifacts (keeps IPSWs)"
	@echo ""
	@echo "VM management:"
	@echo "  make vm_new                  Create VM directory with manifest (config.plist)"
	@echo "    Options: VM_DIR=vm         VM directory name"
	@echo "             CPU=8             CPU cores (stored in manifest)"
	@echo "             MEMORY=8192       Memory in MB (stored in manifest)"
	@echo "             DISK_SIZE=64      Disk size in GB (stored in manifest)"
	@echo "  make boot                    Boot VM (reads from config.plist)"
	@echo "  make boot_dfu                Boot VM in DFU mode (reads from config.plist)"
	@echo ""
	@echo "Firmware pipeline:"
	@echo "  make fw_prepare              Download IPSWs, extract, merge"
	@echo "    Options: IPHONE_SOURCE=    URL or local path to iPhone IPSW"
	@echo "             CLOUDOS_SOURCE=   URL or local path to cloudOS IPSW"
	@echo "  make fw_patch                Patch boot chain (regular variant)"
	@echo "  make fw_patch_dev            Patch boot chain (dev mode TXM patches)"
	@echo "  make fw_patch_jb             Patch boot chain (dev + JB extensions)"
	@echo ""
	@echo "Restore:"
	@echo "  make restore_get_shsh        Dump SHSH response from Apple"
	@echo "  make restore                 idevicerestore to device"
	@echo ""
	@echo "Ramdisk:"
	@echo "  make ramdisk_build           Build signed SSH ramdisk"
	@echo "  make ramdisk_send            Send ramdisk to device"
	@echo ""
	@echo "CFW:"
	@echo "  make cfw_install             Install CFW mods via SSH"
	@echo "  make cfw_install_dev         Install CFW mods via SSH (dev mode)"
	@echo "  make cfw_install_jb          Install CFW + JB extensions (jetsam/procursus/basebin)"
	@echo ""
	@echo "Variables: VM_DIR=$(VM_DIR) CPU=$(CPU) MEMORY=$(MEMORY) DISK_SIZE=$(DISK_SIZE)"

# ═══════════════════════════════════════════════════════════════════
# Setup
# ═══════════════════════════════════════════════════════════════════

.PHONY: setup_machine setup_tools

setup_machine:
	@if [ "$(filter 1 true yes YES TRUE,$(JB))" != "" ] && [ "$(filter 1 true yes YES TRUE,$(DEV))" != "" ]; then \
		echo "Error: JB=1 and DEV=1 are mutually exclusive"; \
		exit 1; \
	fi
	SUDO_PASSWORD="$(SUDO_PASSWORD)" \
	NONE_INTERACTIVE="$(NONE_INTERACTIVE)" \
	zsh $(SCRIPTS)/setup_machine.sh \
		$(if $(filter 1 true yes YES TRUE,$(JB)),--jb,) \
		$(if $(filter 1 true yes YES TRUE,$(DEV)),--dev,) \
		$(if $(filter 1 true yes YES TRUE,$(SKIP_PROJECT_SETUP)),--skip-project-setup,)

setup_tools:
	zsh $(SCRIPTS)/setup_tools.sh

# ═══════════════════════════════════════════════════════════════════
# Clean — remove all untracked/ignored files (preserves IPSWs only)
# ═══════════════════════════════════════════════════════════════════

.PHONY: clean
clean:
	@echo "=== Cleaning all untracked files (preserving IPSWs) ==="
	git clean -fdx -e '*.ipsw' -e '*_Restore*'

# ═══════════════════════════════════════════════════════════════════
# Build
# ═══════════════════════════════════════════════════════════════════

.PHONY: build bundle

build: $(BINARY)

$(BINARY): $(SWIFT_SOURCES) Package.swift $(ENTITLEMENTS)
	@echo "=== Building vphone-cli ($(GIT_HASH)) ==="
	@echo '// Auto-generated — do not edit' > $(BUILD_INFO)
	@echo 'enum VPhoneBuildInfo { static let commitHash = "$(GIT_HASH)" }' >> $(BUILD_INFO)
	@set -o pipefail; swift build -c release 2>&1 | tail -5
	@echo ""
	@echo "=== Signing with entitlements ==="
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $@
	@echo "  signed OK"

bundle: build $(INFO_PLIST)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp -f $(BINARY) $(BUNDLE_BIN)
	@cp -f $(INFO_PLIST) $(BUNDLE)/Contents/Info.plist
	@cp -f sources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@cp -f $(SCRIPTS)/vphoned/signcert.p12 $(BUNDLE)/Contents/Resources/signcert.p12
	@cp -f $$(command -v ldid) $(BUNDLE)/Contents/MacOS/ldid
	@cp -f $$(command -v ideviceinstaller) $(BUNDLE)/Contents/MacOS/ideviceinstaller
	@cp -f $$(command -v idevice_id) $(BUNDLE)/Contents/MacOS/idevice_id
	@codesign --force --sign - $(BUNDLE)/Contents/MacOS/ldid
	@codesign --force --sign - $(BUNDLE)/Contents/MacOS/ideviceinstaller
	@codesign --force --sign - $(BUNDLE)/Contents/MacOS/idevice_id
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUNDLE_BIN)
	@echo "  bundled → $(BUNDLE)"

# Cross-compile + sign vphoned daemon for iOS arm64 (requires ldid)
.PHONY: vphoned
vphoned:
	@command -v ldid >/dev/null 2>&1 \
		|| (echo "Error: ldid not found. Run: brew install ldid-procursus" && exit 1)
	$(MAKE) -C $(SCRIPTS)/vphoned GIT_HASH=$(GIT_HASH)
	@echo "=== Signing vphoned ==="
	cp $(SCRIPTS)/vphoned/vphoned $(VM_DIR)/.vphoned.signed
	ldid \
		-S$(SCRIPTS)/vphoned/entitlements.plist \
		-M "-K$(SCRIPTS)/vphoned/signcert.p12" \
		$(VM_DIR)/.vphoned.signed
	@echo "  signed → $(VM_DIR)/.vphoned.signed"

# ═══════════════════════════════════════════════════════════════════
# VM management
# ═══════════════════════════════════════════════════════════════════

.PHONY: vm_new boot boot_dfu

vm_new:
	CPU="$(CPU)" MEMORY="$(MEMORY)" \
	zsh $(SCRIPTS)/vm_create.sh --dir $(VM_DIR) --disk-size $(DISK_SIZE)

boot: bundle vphoned
	cd $(VM_DIR) && "$(CURDIR)/$(BUNDLE_BIN)" \
		--config ./config.plist \
		--rom ./AVPBooter.vresearch1.bin \
		--disk ./Disk.img \
		--nvram ./nvram.bin \
		--sep-rom ./AVPSEPBooter.vresearch1.bin \
		--sep-storage ./SEPStorage

boot_dfu: build
	cd $(VM_DIR) && "$(CURDIR)/$(BINARY)" \
		--config ./config.plist \
		--rom ./AVPBooter.vresearch1.bin \
		--disk ./Disk.img \
		--nvram ./nvram.bin \
		--sep-rom ./AVPSEPBooter.vresearch1.bin \
		--sep-storage ./SEPStorage \
		--no-graphics --dfu

# ═══════════════════════════════════════════════════════════════════
# Firmware pipeline
# ═══════════════════════════════════════════════════════════════════

.PHONY: fw_prepare fw_patch fw_patch_dev fw_patch_jb

fw_prepare:
	cd $(VM_DIR) && bash "$(CURDIR)/$(SCRIPTS)/fw_prepare.sh"

fw_patch:
	cd $(VM_DIR) && $(PYTHON) "$(CURDIR)/$(SCRIPTS)/fw_patch.py" .

fw_patch_dev:
	cd $(VM_DIR) && $(PYTHON) "$(CURDIR)/$(SCRIPTS)/fw_patch_dev.py" .

fw_patch_jb:
	cd $(VM_DIR) && $(PYTHON) "$(CURDIR)/$(SCRIPTS)/fw_patch_jb.py" .

# ═══════════════════════════════════════════════════════════════════
# Restore
# ═══════════════════════════════════════════════════════════════════

.PHONY: restore_get_shsh restore

restore_get_shsh:
	cd $(VM_DIR) && "$(CURDIR)/$(IDEVICERESTORE)" \
		$(if $(RESTORE_UDID),-u $(RESTORE_UDID),) \
		$(if $(RESTORE_ECID),-i $(RESTORE_ECID),) \
		-e -y ./iPhone*_Restore -t

restore:
	cd $(VM_DIR) && "$(CURDIR)/$(IDEVICERESTORE)" \
		$(if $(RESTORE_UDID),-u $(RESTORE_UDID),) \
		$(if $(RESTORE_ECID),-i $(RESTORE_ECID),) \
		-e -y ./iPhone*_Restore

# ═══════════════════════════════════════════════════════════════════
# Ramdisk
# ═══════════════════════════════════════════════════════════════════

.PHONY: ramdisk_build ramdisk_send

ramdisk_build:
	cd $(VM_DIR) && RAMDISK_UDID="$(RAMDISK_UDID)" $(PYTHON) "$(CURDIR)/$(SCRIPTS)/ramdisk_build.py" .

ramdisk_send:
	cd $(VM_DIR) && IRECOVERY="$(CURDIR)/$(IRECOVERY)" IRECOVERY_ECID="$(IRECOVERY_ECID)" RAMDISK_UDID="$(RAMDISK_UDID)" RESTORE_UDID="$(RESTORE_UDID)" \
		zsh "$(CURDIR)/$(SCRIPTS)/ramdisk_send.sh"

# ═══════════════════════════════════════════════════════════════════
# CFW
# ═══════════════════════════════════════════════════════════════════

.PHONY: cfw_install cfw_install_dev cfw_install_jb

cfw_install:
	cd $(VM_DIR) && $(if $(SSH_PORT),SSH_PORT="$(SSH_PORT)") zsh "$(CURDIR)/$(SCRIPTS)/cfw_install.sh" .

cfw_install_dev:
	cd $(VM_DIR) && $(if $(SSH_PORT),SSH_PORT="$(SSH_PORT)") zsh "$(CURDIR)/$(SCRIPTS)/cfw_install_dev.sh" .

cfw_install_jb:
	cd $(VM_DIR) && $(if $(SSH_PORT),SSH_PORT="$(SSH_PORT)") zsh "$(CURDIR)/$(SCRIPTS)/cfw_install_jb.sh" .
