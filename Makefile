# ═══════════════════════════════════════════════════════════════════
# vphone-cli — Virtual iPhone boot tool
# ═══════════════════════════════════════════════════════════════════

# ─── Configuration (override with make VAR=value) ─────────────────
VM_DIR      ?= vm
CPU         ?= 8          # CPU cores (only used during vm_new)
MEMORY      ?= 8192       # Memory in MB (only used during vm_new)
DISK_SIZE   ?= 64         # Disk size in GB (only used during vm_new)
BACKUPS_DIR ?= vm.backups
NAME        ?=
BACKUP_INCLUDE_IPSW ?= 0
FORCE       ?= 0
RESTORE_UDID ?=           # UDID for restore operations
RESTORE_ECID ?=           # ECID for restore operations
IRECOVERY_ECID ?=         # ECID for ramdisk send operations

# ─── Build info ──────────────────────────────────────────────────
GIT_HASH    := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_INFO  := sources/vphone-cli/VPhoneBuildInfo.swift

# ─── Paths ────────────────────────────────────────────────────────
SCRIPTS     := scripts
BINARY      := .build/release/vphone-cli
PATCHER_BINARY := .build/debug/vphone-cli
BUNDLE      := .build/vphone-cli.app
BUNDLE_BIN  := $(BUNDLE)/Contents/MacOS/vphone-cli
INFO_PLIST  := sources/Info.plist
ENTITLEMENTS := sources/vphone.entitlements
VENV        := .venv
TOOLS_PREFIX := .tools
PMD3_BRIDGE := $(CURDIR)/$(SCRIPTS)/pymobiledevice3_bridge.py
PYTHON      := $(CURDIR)/$(VENV)/bin/python3

SWIFT_SOURCES := $(shell find sources -name '*.swift')

# ─── Environment — prefer project-local binaries ────────────────
export PATH := $(CURDIR)/$(TOOLS_PREFIX)/bin:$(CURDIR)/$(VENV)/bin:$(CURDIR)/.build/release:$(PATH)

# ─── Default ──────────────────────────────────────────────────────
.PHONY: help
help:
	@echo "vphone-cli — Virtual iPhone boot tool"
	@echo ""
	@echo "LazyCat (AIO):"
	@echo "  make setup_machine                   Full setup through First Boot"
	@echo "    Options: JB=1                      Jailbreak firmware/CFW path"
	@echo "             DEV=1                     Dev firmware/CFW path (dev TXM + cfw_install_dev)"
	@echo "             LESS=1                    Build, keeping iOS security mitigations enabled."
	@echo "             SKIP_PROJECT_SETUP=1      Skip setup_tools/build"
	@echo "             NONE_INTERACTIVE=1        Auto-continue prompts + boot analysis"
	@echo "             SUDO_PASSWORD=...         Preload sudo credential for setup flow"
	@echo "             NO_BINPACK=1              Excludes the SSH, VNC, ... binaries from being installed (patchless-only, currently)"
	@echo "             NO_VPHONED=1              Excludes vphoned from being installed (patchless-only, currently)"
	@echo ""
	@echo "Setup (one-time):"
	@echo "  make setup_tools             Install all tools (brew, trustcache, insert_dylib, venv+pymobiledevice3)"
	@echo ""
	@echo "Build:"
	@echo "  make build                   Build + sign vphone-cli"
	@echo "  make vphoned                 Cross-compile + sign vphoned for iOS"
	@echo "  make clean                   Remove build/tooling artifacts only"
	@echo "    Options: CLEAN_VM=1        Also remove VM_DIR=$(VM_DIR) after confirmation"
	@echo "             CLEAN_IPSW=1      Also remove ipsws/ after confirmation"
	@echo ""
	@echo "VM management:"
	@echo "  make vm_new                  Create VM directory with manifest (config.plist)"
	@echo "    Options: VM_DIR=vm         VM directory name"
	@echo "             CPU=8             CPU cores (stored in manifest)"
	@echo "             MEMORY=8192       Memory in MB (stored in manifest)"
	@echo "             DISK_SIZE=64      Disk size in GB (stored in manifest)"
	@echo "  make vm_backup NAME=<name>   Save current VM as a named backup"
	@echo "  make vm_restore NAME=<name>  Restore a named backup into vm/"
	@echo "  make vm_switch NAME=<name>   Save current + restore target (one step)"
	@echo "  make vm_list                 List available backups"
	@echo "    Options: BACKUP_INCLUDE_IPSW=1  Include *_Restore* IPSW dirs in backup"
	@echo "             FORCE=1                Skip overwrite prompt on restore"
	@echo "  make amfidont_allow_vphone   Start amfidont for the signed vphone-cli binary"
	@echo "  make boot_host_preflight     Diagnose whether host can launch signed PV=3 binary"
	@echo "  make boot                    Boot VM (reads from config.plist)"
	@echo "  make boot_less               Boot VM in vphoned patchless compatibility"
	@echo "    Options: NO_VPHONED=1              Excludes vphoned from being installed"
	@echo "  make boot_dfu                Boot VM in DFU mode (reads from config.plist)"
	@echo ""
	@echo "Firmware pipeline:"
	@echo "  make fw_prepare              Download IPSWs, extract, merge"
	@echo "    Options: LIST_FIRMWARES=1  List downloadable iPhone IPSWs for IPHONE_DEVICE and exit"
	@echo "             IPHONE_DEVICE=    Device identifier for firmware lookup (default: iPhone17,3)"
	@echo "             IPHONE_VERSION=   Resolve a downloadable iPhone version to an IPSW URL"
	@echo "             IPHONE_BUILD=     Resolve a downloadable iPhone build to an IPSW URL"
	@echo "             IPHONE_SOURCE=    URL or local path to iPhone IPSW"
	@echo "             CLOUDOS_SOURCE=   URL or local path to cloudOS IPSW"
	@echo "  make fw_patch                Patch boot chain with Swift pipeline (regular variant)"
	@echo "  make fw_patch_less           Patch boot chain with Swift pipeline (less patches)"
	@echo "    Options: NO_BINPACK=1              Excludes the SSH, VNC, ... binaries from being installed"
	@echo "             NO_VPHONED=1              Excludes vphoned from being installed"
	@echo "  make fw_patch_dev            Patch boot chain with Swift pipeline (dev mode TXM patches)"
	@echo "  make fw_patch_jb             Patch boot chain with Swift pipeline (dev + JB extensions)"
	@echo ""
	@echo "Restore:"
	@echo "  make restore_get_shsh        Dump SHSH response from Apple"
	@echo "  make restore                 Restore to device (pymobiledevice3 backend)"
	@echo "  make restore_offline         Restore offline — decrypts AEA images in place, uses cached .shsh blob"
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
	@if count=0; \
	  [ -n "$(filter 1 true yes YES TRUE,$(JB))" ] && count=$$((count+1)); \
	  [ -n "$(filter 1 true yes YES TRUE,$(DEV))" ] && count=$$((count+1)); \
	  [ -n "$(filter 1 true yes YES TRUE,$(LESS))" ] && count=$$((count+1)); \
	  [ $$count -gt 1 ]; then \
		echo "Error: JB=1, DEV=1, and LESS=1 are mutually exclusive"; \
		exit 1; \
	fi
	SUDO_PASSWORD="$(SUDO_PASSWORD)" \
	NONE_INTERACTIVE="$(NONE_INTERACTIVE)" \
	NO_BINPACK="$(NO_BINPACK)" \
	NO_VPHONED="$(NO_VPHONED)" \
	zsh $(SCRIPTS)/setup_machine.sh \
		$(if $(filter 1 true yes YES TRUE,$(JB)),--jb,) \
		$(if $(filter 1 true yes YES TRUE,$(DEV)),--dev,) \
		$(if $(filter 1 true yes YES TRUE,$(LESS)),--less,) \
		$(if $(filter 1 true yes YES TRUE,$(SKIP_PROJECT_SETUP)),--skip-project-setup,)

setup_tools:
	VARIANT=$(VARIANT) zsh $(SCRIPTS)/setup_tools.sh

# ═══════════════════════════════════════════════════════════════════
# Clean — remove generated build/tooling files by default.
# Destructive VM/IPSW cleanup is opt-in and requires confirmation.
# ═══════════════════════════════════════════════════════════════════

.PHONY: clean
clean:
	@set -e; \
	echo "=== Cleaning build/tooling artifacts ==="; \
	echo "Removing: .build .swiftpm .vphoned.signed $(VENV) $(TOOLS_PREFIX)"; \
	if [ "$(CLEAN_VM)" = "1" ] || [ "$(CLEAN_IPSW)" = "1" ]; then \
		echo ""; \
		echo "WARNING: destructive clean requested."; \
		[ "$(CLEAN_VM)" = "1" ] && echo "  VM directory: $(VM_DIR)/"; \
		[ "$(CLEAN_IPSW)" = "1" ] && echo "  IPSW cache:   ipsws/"; \
		printf "Also remove destructive targets above? [y/N] "; \
		read answer; \
		case "$$answer" in y|Y|yes|YES) ;; *) \
			echo "[-] Destructive clean cancelled; no files removed."; \
			exit 0; \
		esac; \
	fi; \
	rm -rf .build .swiftpm .vphoned.signed "$(VENV)" "$(TOOLS_PREFIX)"; \
	if [ "$(CLEAN_VM)" = "1" ] || [ "$(CLEAN_IPSW)" = "1" ]; then \
		if [ "$(CLEAN_VM)" = "1" ]; then rm -rf "$(VM_DIR)"; fi; \
		if [ "$(CLEAN_IPSW)" = "1" ]; then rm -rf ipsws; fi; \
	fi

# ═══════════════════════════════════════════════════════════════════
# Build
# ═══════════════════════════════════════════════════════════════════

.PHONY: build patcher_build bundle

build: $(BINARY)

patcher_build: $(PATCHER_BINARY)

$(PATCHER_BINARY): $(SWIFT_SOURCES) Package.swift
	@echo "=== Building vphone-cli patcher ($(GIT_HASH)) ==="
	@echo '// Auto-generated — do not edit' > $(BUILD_INFO)
	@echo 'enum VPhoneBuildInfo { static let commitHash = "$(GIT_HASH)" }' >> $(BUILD_INFO)
	@set -o pipefail; swift build 2>&1 | tail -5

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
	@codesign --force --sign - $(BUNDLE)/Contents/MacOS/ldid
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

.PHONY: vm_new vm_backup vm_restore vm_switch vm_list amfidont_allow_vphone boot_host_preflight boot boot_less boot_dfu boot_binary_check

vm_new:
	CPU="$(CPU)" MEMORY="$(MEMORY)" \
	zsh $(SCRIPTS)/vm_create.sh --dir $(VM_DIR) --disk-size $(DISK_SIZE)

vm_backup:
	VM_DIR="$(VM_DIR)" BACKUPS_DIR="$(BACKUPS_DIR)" NAME="$(NAME)" BACKUP_INCLUDE_IPSW="$(BACKUP_INCLUDE_IPSW)" \
	zsh $(SCRIPTS)/vm_backup.sh

vm_restore:
	VM_DIR="$(VM_DIR)" BACKUPS_DIR="$(BACKUPS_DIR)" NAME="$(NAME)" FORCE="$(FORCE)" \
	zsh $(SCRIPTS)/vm_restore.sh

vm_switch:
	VM_DIR="$(VM_DIR)" BACKUPS_DIR="$(BACKUPS_DIR)" NAME="$(NAME)" BACKUP_INCLUDE_IPSW="$(BACKUP_INCLUDE_IPSW)" \
	zsh $(SCRIPTS)/vm_switch.sh

vm_list:
	@if [ -d "$(BACKUPS_DIR)" ]; then \
		current=""; \
		[ -f "$(VM_DIR)/.vm_name" ] && current="$$(cat "$(VM_DIR)/.vm_name")"; \
		found=0; \
		for d in "$(BACKUPS_DIR)"/*/; do \
			[ -f "$${d}config.plist" ] || continue; \
			name="$$(basename "$$d")"; \
			size="$$(du -sh "$$d" 2>/dev/null | cut -f1)"; \
			if [ "$$name" = "$$current" ]; then \
				echo "  * $$name ($$size) [active]"; \
			else \
				echo "    $$name ($$size)"; \
			fi; \
			found=1; \
		done; \
		if [ "$$found" = "0" ]; then echo "  (no backups yet — run: make vm_backup NAME=<name>)"; fi; \
	else \
		echo "  (no backups yet — run: make vm_backup NAME=<name>)"; \
	fi

amfidont_allow_vphone: bundle
	zsh $(SCRIPTS)/start_amfidont_for_vphone.sh

boot_host_preflight: build
	zsh $(SCRIPTS)/boot_host_preflight.sh

define BOOT_BINARY_CHECK
	@zsh $(SCRIPTS)/boot_host_preflight.sh $(1)
	@tmp_log="$$(mktemp -t vphone-boot-preflight.XXXXXX)"; \
	set +e; \
	"$(CURDIR)/$(BINARY)" --help >"$$tmp_log" 2>&1; \
	rc=$$?; \
	set -e; \
	if [ $$rc -ne 0 ]; then \
		echo "Error: signed vphone-cli failed to launch (exit $$rc)." >&2; \
		echo "Check private virtualization entitlement support and ensure SIP/AMFI are disabled on the host." >&2; \
		echo "Repo workaround: start the AMFI bypass helper with 'make amfidont_allow_vphone' and retry." >&2; \
		if [ -s "$$tmp_log" ]; then \
			echo "--- vphone-cli preflight log ---" >&2; \
			tail -n 40 "$$tmp_log" >&2; \
		fi; \
		rm -f "$$tmp_log"; \
		exit $$rc; \
	fi; \
	rm -f "$$tmp_log"
endef

boot_binary_check_less: $(BINARY)
	$(call BOOT_BINARY_CHECK,--assert-bootable --less)

boot_binary_check: $(BINARY)
	$(call BOOT_BINARY_CHECK,--assert-bootable)

boot: bundle vphoned boot_binary_check
	cd $(VM_DIR) && "$(CURDIR)/$(BUNDLE_BIN)" \
		--config ./config.plist

boot_less: bundle vphoned boot_binary_check_less
	cd $(VM_DIR) && "$(CURDIR)/$(BUNDLE_BIN)" \
		--config ./config.plist \
		--variant less \
		$(if $(filter 1 true yes YES TRUE,$(NO_VPHONED)),--no-vphoned,)

boot_dfu: build boot_binary_check
	cd $(VM_DIR) && "$(CURDIR)/$(BINARY)" \
		--config ./config.plist \
		--dfu

# ═══════════════════════════════════════════════════════════════════
# Firmware pipeline
# ═══════════════════════════════════════════════════════════════════

.PHONY: fw_prepare fw_patch fw_patch_less fw_patch_dev fw_patch_jb

fw_prepare:
	cd $(VM_DIR) && bash "$(CURDIR)/$(SCRIPTS)/fw_prepare.sh"

fw_patch: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(CURDIR)/$(VM_DIR)" --variant regular

UID := $(shell id -u)
ifeq ($(UID),0)
fw_patch_less: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(CURDIR)/$(VM_DIR)" \
	--variant less \
	$(if $(filter 1 true yes YES TRUE,$(NO_BINPACK)),--no-binpack,)
	$(if $(filter 1 true yes YES TRUE,$(NO_VPHONED)),--no-vphoned,)
else
fw_patch_less:
	@echo "fw_patch_less must be run via sudo"
	@exit 1
endif

fw_patch_dev: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(CURDIR)/$(VM_DIR)" --variant dev

fw_patch_jb: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(CURDIR)/$(VM_DIR)" --variant jb

# ═══════════════════════════════════════════════════════════════════
# Restore
# ═══════════════════════════════════════════════════════════════════

.PHONY: restore_get_shsh restore restore_offline

# Resolve ECID from RESTORE_ECID or vm/udid-prediction.txt (written by boot_dfu).
define _resolve_ecid
	if [ -n "$(RESTORE_ECID)" ]; then \
		ECID="$(RESTORE_ECID)"; \
	elif [ -f "$(CURDIR)/$(VM_DIR)/udid-prediction.txt" ]; then \
		ECID=$$(grep '^ECID=' "$(CURDIR)/$(VM_DIR)/udid-prediction.txt" | head -1 | cut -d= -f2); \
	fi; \
	if [ -z "$$ECID" ]; then \
		echo "[-] Cannot resolve ECID — set RESTORE_ECID or run 'make boot_dfu' first"; \
		exit 1; \
	fi
endef

restore_get_shsh:
	@$(call _resolve_ecid); \
	cd "$(VM_DIR)" && "$(PYTHON)" "$(PMD3_BRIDGE)" restore-get-shsh \
		--vm-dir . \
		$(if $(RESTORE_UDID),--udid $(RESTORE_UDID),) \
		--ecid "$$ECID"

restore:
	@$(call _resolve_ecid); \
	cd "$(VM_DIR)" && "$(PYTHON)" "$(PMD3_BRIDGE)" restore-update \
		--vm-dir . \
		$(if $(RESTORE_UDID),--udid $(RESTORE_UDID),) \
		--ecid "$$ECID"

restore_offline:
	@$(call _resolve_ecid); \
	SHSH=$$(ls "$(CURDIR)/$(VM_DIR)/"*.shsh 2>/dev/null | head -1); \
	if [ -z "$$SHSH" ]; then \
		echo "[-] No .shsh file in $(VM_DIR)/ — run 'make restore_get_shsh' first"; \
		exit 1; \
	fi; \
	RESTORE_SRC=$$(echo "$(CURDIR)/$(VM_DIR)/iPhone"*_Restore); \
	if [ ! -d "$$RESTORE_SRC" ]; then \
		echo "[-] No iPhone*_Restore directory in $(VM_DIR)/"; \
		exit 1; \
	fi; \
	echo "[+] Decrypting AEA images in place..."; \
	for aea in "$$RESTORE_SRC"/*.dmg.aea; do \
		[ -f "$$aea" ] || continue; \
		[ "$$(xxd -l 4 -p "$$aea")" = "41454131" ] || continue; \
		base=$$(basename "$$aea"); \
		if ! ipsw fw aea -o "$$RESTORE_SRC" "$$aea"; then \
			echo "[-] ipsw fw aea failed for $$base — aborting"; \
			exit 1; \
		fi; \
		if ! mv -f "$$RESTORE_SRC/$${base%.aea}" "$$aea"; then \
			echo "[-] mv failed for $$base — aborting (decrypted file missing?)"; \
			exit 1; \
		fi; \
		if [ "$$(xxd -l 4 -p "$$aea")" = "41454131" ]; then \
			echo "[-] $$base still AEA1-encrypted after decrypt — aborting"; \
			exit 1; \
		fi; \
	done; \
	echo "[+] Restoring offline with SHSH: $$(basename $$SHSH)"; \
	cd "$(VM_DIR)" && "$(PYTHON)" "$(PMD3_BRIDGE)" restore-update \
		--vm-dir . \
		--tss "$$SHSH" \
		$(if $(RESTORE_UDID),--udid $(RESTORE_UDID),) \
		--ecid "$$ECID"

# ═══════════════════════════════════════════════════════════════════
# Ramdisk
# ═══════════════════════════════════════════════════════════════════

.PHONY: ramdisk_build ramdisk_send

ramdisk_build: patcher_build
	cd $(VM_DIR) && RAMDISK_UDID="$(RAMDISK_UDID)" $(PYTHON) "$(CURDIR)/$(SCRIPTS)/ramdisk_build.py" .

ramdisk_send:
	cd $(VM_DIR) && PMD3_BRIDGE="$(PMD3_BRIDGE)" PYTHON="$(PYTHON)" IRECOVERY_ECID="$(IRECOVERY_ECID)" RAMDISK_UDID="$(RAMDISK_UDID)" RESTORE_UDID="$(RESTORE_UDID)" \
		zsh "$(CURDIR)/$(SCRIPTS)/ramdisk_send.sh"

# ═══════════════════════════════════════════════════════════════════
# CFW
# ═══════════════════════════════════════════════════════════════════

.PHONY: cfw_install cfw_install_dev cfw_install_jb

cfw_install:
	cd $(VM_DIR) && $(if $(SSH_PORT),SSH_PORT="$(SSH_PORT)") _VPHONE_PATH="$$PATH" zsh "$(CURDIR)/$(SCRIPTS)/cfw_install.sh" .

cfw_install_dev:
	cd $(VM_DIR) && $(if $(SSH_PORT),SSH_PORT="$(SSH_PORT)") _VPHONE_PATH="$$PATH" zsh "$(CURDIR)/$(SCRIPTS)/cfw_install_dev.sh" .

cfw_install_jb:
	cd $(VM_DIR) && $(if $(SSH_PORT),SSH_PORT="$(SSH_PORT)") _VPHONE_PATH="$$PATH" zsh "$(CURDIR)/$(SCRIPTS)/cfw_install_jb.sh" .
