# ═══════════════════════════════════════════════════════════════════
# vphone-cli — Virtual iPhone boot tool
# ═══════════════════════════════════════════════════════════════════

# ─── Configuration (override with make VAR=value) ─────────────────
VM_DIR      ?= vm
# Absolute VM path: handles both relative (default `vm`) and absolute
# (e.g. external SSD) VM_DIR values. `abspath` leaves absolute paths intact
# and joins relative ones against CURDIR — use this for the VM directory arg.
VM_DIR_ABS  := $(abspath $(VM_DIR))
# CPU cores, memory (MB), disk size (GB) — used only during vm_new.
# NB: no inline comments on these `?=` lines — make would fold the trailing
# whitespace into the value (e.g. CPU="8   ") and break numeric consumers.
CPU         ?= 8
MEMORY      ?= 8192
DISK_SIZE   ?= 64
BACKUPS_DIR ?= vm.backups
NAME        ?=
BACKUP_INCLUDE_IPSW ?= 0
FORCE       ?= 0
# UDID and ECID for restore operations
RESTORE_UDID ?=
RESTORE_ECID ?=

# Truth test for the boolean flags above and on the command line. One place
# owns the accepted spellings; use as $(call truthy,$(FLAG)) — it expands to
# non-empty when the flag is on. NB: this is not an emptiness test, so it is
# not a substitute for $(if $(RESTORE_UDID),…) and friends.
truthy = $(filter 1 true yes YES TRUE,$(1))

# ─── Build info ──────────────────────────────────────────────────
GIT_HASH    := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_INFO  := sources/VPhoneCore/VPhoneBuildInfo.swift

# ─── Paths ────────────────────────────────────────────────────────
SCRIPTS     := scripts
# Three host binaries, and only ONE of them is entitled. vphone-cli is the
# user-facing entry point and carries nothing, so it always launches; vphone-vm
# holds the private virtualization keys and is what amfid can refuse;
# vphone-archive unpacks and packs. See sources/vphone.entitlements.
#
# Opening an AMFI window for vphone-vm is the USER's job — this project no
# longer ships a tool for it. `make amfi_command` prints the command line.
BINARY      := .build/release/vphone-cli
VM_BINARY   := .build/release/vphone-vm
ARCHIVE_BINARY := .build/release/vphone-archive
PATCHER_BINARY := .build/debug/vphone-cli
BUNDLE      := .build/vphone-cli.app
BUNDLE_BIN  := $(BUNDLE)/Contents/MacOS/vphone-cli
BUNDLE_VM   := $(BUNDLE)/Contents/MacOS/vphone-vm
BUNDLE_ARCHIVE := $(BUNDLE)/Contents/MacOS/vphone-archive
INFO_PLIST  := sources/Info.plist
ENTITLEMENTS := sources/vphone.entitlements
# The venv exists for exactly one program now — the pymobiledevice3 restore
# bridge below. The firmware and CFW patchers it used to serve are Swift
# (FirmwarePatcher, reached through `vphone-cli cfw <verb>` and `patch-firmware`),
# so nothing in the patch pipeline touches $(PYTHON) any more.
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
	@echo "             EXP=1                     Experimental firmware/CFW path (JB + EXP-only patches:"
	@echo "                                       kernel hv_vmm rename, DSC byte-5 mangle, surgical watchdogd patch,"
	@echo "                                       DT identity properties, post-restore DT rewrite, opt-in build spoof)"
	@echo "             LESS=1                    Build, keeping iOS security mitigations enabled."
	@echo "             SKIP_PROJECT_SETUP=1      Skip setup_tools/build"
	@echo "             INTERACTIVE=1             Prompt at first-boot stages (default: non-interactive)"
	@echo "             SUDO_PASSWORD=...         Preload sudo credential for setup flow"
	@echo "             NO_BINPACK=1              Skip installing the SSH, VNC and other bundled binaries (patchless only)"
	@echo "             NO_VPHONED=1              Skip installing vphoned (patchless only)"
	@echo "             SPOOF_BUILD=<id>          (EXP only) Rewrite ProductBuildVersion in SystemVersion.plist to <id>"
	@echo "                                       e.g. SPOOF_BUILD=23F77 makes Settings → About show that build."
	@echo "                                       Unset or empty keeps the build version that ships in the IPSW."
	@echo ""
	@echo "Setup (one-time):"
	@echo "  make setup_tools             Install all tools (brew, trustcache, insert_dylib, venv+pymobiledevice3)"
	@echo "  make setup_venv              The venv alone — needed only for 'make restore*' (pymobiledevice3)"
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
	@echo "    Options: BACKUP_INCLUDE_IPSW=1  Include *_Restore* IPSW directories in the backup"
	@echo "             FORCE=1                Skip overwrite prompt on restore"
	@echo "  make check-aux               Run the self-containment admission gates"
	@echo "  make amfi_command            Print the 'sudo amfidont daemon …' line for this build"
	@echo "                               (prints only — installs nothing, runs nothing, needs no sudo)"
	@echo "  make boot_host_preflight     Diagnose whether host can launch signed PV=3 binary"
	@echo "  make boot                    Boot VM (reads from config.plist)"
	@echo "  make boot_less               Boot VM in vphoned patchless compatibility mode"
	@echo "    Options: NO_VPHONED=1              Skip installing vphoned"
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
	@echo "    Options: FORCE_EXC_GUARD=1        Force the EXC_GUARD Mach-port-guard disable patch even on bases"
	@echo "                                      that don't strictly need it to boot (e.g. a 3rd-party app's"
	@echo "                                      crash-reporting SDK trips a fatal GUARD_TYPE_MACH_PORT violation)"
	@echo "  make fw_patch_less           Patch boot chain with Swift pipeline (less patches)"
	@echo "    Options: NO_BINPACK=1              Skip installing the SSH, VNC and other bundled binaries"
	@echo "             NO_VPHONED=1              Skip installing vphoned"
	@echo "  make fw_patch_dev            Patch boot chain with Swift pipeline (dev mode TXM patches)"
	@echo "  make fw_patch_jb             Patch boot chain with Swift pipeline (dev + JB extensions)"
	@echo "    Options: FORCE_EXC_GUARD=1        (see fw_patch above)"
	@echo "             FRIDA=1                  Opt in to the Frida Stalker kernel relaxations"
	@echo "  make fw_patch_exp            Patch boot chain with Swift pipeline (JB + EXP experimental)"
	@echo "    Options: FORCE_EXC_GUARD=1        (see fw_patch above)"
	@echo "             FRIDA=1                  Opt in to the Frida Stalker kernel relaxations"
	@echo ""
	@echo "Testing:"
	@echo "  make test_jb_patches         Run all JB kernel patches (incl. Sandbox) over every supported cloudOS kernel"
	@echo "    Options: QUICK=1           Only the local/newest kernel (fast dev loop)"
	@echo "  make test_fw_patches         Run the FULL patch-firmware pipeline (boot chain + base kernel + JB + EXP) over"
	@echo "                               each local cloudOS firmware; fails if any sub-patch is skipped"
	@echo "    Options: QUICK=1           Only the newest local cloudOS firmware"
	@echo "             VARIANTS=\"exp\"     Limit to specific variants (default: jb exp)"
	@echo ""
	@echo "Restore:"
	@echo "  make restore_get_shsh        Dump SHSH response from Apple"
	@echo "  make restore                 Restore to device (pymobiledevice3 backend)"
	@echo "  make restore_offline         Restore offline from the cached .shsh file (decrypts AEA images in place)"
	@echo ""
	@echo "CFW (host-mount install; VM must be off, re-execs sudo):"
	@echo "  make cfw_install             Install base CFW mods"
	@echo "  make cfw_install_dev         Install CFW mods (dev mode)"
	@echo "  make cfw_install_jb          Install CFW + JB extensions (jetsam/procursus/basebin)"
	@echo "  make cfw_install_exp         Install CFW + JB + EXP experimental (hv_vmm rename, post-restore DT, build spoof)"
	@echo "  make cfw_install_host        Select variant: VARIANT=regular|dev|jb|exp (default exp)  SPOOF_BUILD=<id> (exp)"
	@echo ""
	@echo "Variables: VM_DIR=$(VM_DIR) CPU=$(CPU) MEMORY=$(MEMORY) DISK_SIZE=$(DISK_SIZE)"

# ═══════════════════════════════════════════════════════════════════
# Setup
# ═══════════════════════════════════════════════════════════════════

.PHONY: setup_machine setup_tools setup_venv

setup_machine:
	@if count=0; \
	  [ -n "$(call truthy,$(JB))" ] && count=$$((count+1)); \
	  [ -n "$(call truthy,$(DEV))" ] && count=$$((count+1)); \
	  [ -n "$(call truthy,$(EXP))" ] && count=$$((count+1)); \
	  [ -n "$(call truthy,$(LESS))" ] && count=$$((count+1)); \
	  [ $$count -gt 1 ]; then \
		echo "Error: use only one of JB=1, DEV=1, EXP=1 or LESS=1."; \
		exit 1; \
	fi
	SUDO_PASSWORD="$(SUDO_PASSWORD)" \
	INTERACTIVE="$(INTERACTIVE)" \
	NO_BINPACK="$(NO_BINPACK)" \
	NO_VPHONED="$(NO_VPHONED)" \
	SPOOF_BUILD="$(SPOOF_BUILD)" \
	zsh $(SCRIPTS)/setup_machine.sh \
		$(if $(call truthy,$(JB)),--jb,) \
		$(if $(call truthy,$(DEV)),--dev,) \
		$(if $(call truthy,$(EXP)),--exp,) \
		$(if $(call truthy,$(LESS)),--less,) \
		$(if $(call truthy,$(SKIP_PROJECT_SETUP)),--skip-project-setup,)

setup_tools:
	VARIANT=$(VARIANT) zsh $(SCRIPTS)/setup_tools.sh

# The venv alone, without the brew packages and the toolchain builds that
# setup_tools also does. Documented in AGENTS.md and in setup_venv.sh's own
# header, both of which named a target that did not exist.
setup_venv:
	zsh $(SCRIPTS)/setup_venv.sh

# ═══════════════════════════════════════════════════════════════════
# Clean — remove generated build/tooling files by default.
# Destructive VM/IPSW cleanup is opt-in and requires confirmation.
# ═══════════════════════════════════════════════════════════════════

.PHONY: clean
clean:
	@set -e; \
	echo "=== Cleaning build/tooling artifacts ==="; \
	echo "Removing: .build .swiftpm $(VENV) $(TOOLS_PREFIX)"; \
	if [ "$(CLEAN_VM)" = "1" ] || [ "$(CLEAN_IPSW)" = "1" ]; then \
		echo ""; \
		echo "WARNING: destructive clean requested."; \
		[ "$(CLEAN_VM)" = "1" ] && echo "  VM directory: $(VM_DIR)/"; \
		[ "$(CLEAN_IPSW)" = "1" ] && echo "  IPSW cache:   ipsws/"; \
		printf "Also permanently delete the data listed above? [y/N] "; \
		read answer; \
		case "$$answer" in y|Y|yes|YES) ;; *) \
			echo "[-] Destructive clean cancelled; no files removed."; \
			exit 0; \
		esac; \
	fi; \
	rm -rf .build .swiftpm "$(VENV)" "$(TOOLS_PREFIX)"; \
	if [ "$(CLEAN_VM)" = "1" ]; then rm -rf "$(VM_DIR)"; fi; \
	if [ "$(CLEAN_IPSW)" = "1" ]; then rm -rf ipsws; fi

# ═══════════════════════════════════════════════════════════════════
# Build
# ═══════════════════════════════════════════════════════════════════

.PHONY: build patcher_build bundle

build: $(BINARY)

patcher_build: $(PATCHER_BINARY)

# Stamp the current commit into $(BUILD_INFO). Both build recipes use this, so
# the generated file's shape has one owner.
define WRITE_BUILD_INFO
	@echo '// Auto-generated — do not edit' > $(BUILD_INFO)
	@echo 'enum VPhoneBuildInfo { static let commitHash = "$(GIT_HASH)" }' >> $(BUILD_INFO)
endef

$(PATCHER_BINARY): $(SWIFT_SOURCES) Package.swift
	@echo "=== Building vphone-cli patcher ($(GIT_HASH)) ==="
	$(WRITE_BUILD_INFO)
	@set -o pipefail; swift build 2>&1 | tail -5

# One recipe produces all three host binaries — `swift build` builds every
# target anyway. Grouped targets (`&:`) would say this more precisely but need
# GNU Make 4.3, and macOS still ships 3.81, so the other two just depend on
# this one.
#
# Only vphone-vm gets the entitlements. Signing vphone-cli with them too would
# put us straight back where we started: the entry point itself unable to
# launch without an AMFI bypass already in place.
$(BINARY): $(SWIFT_SOURCES) Package.swift $(ENTITLEMENTS)
	@echo "=== Building vphone-cli ($(GIT_HASH)) ==="
	$(WRITE_BUILD_INFO)
	@set -o pipefail; swift build -c release 2>&1 | tail -5
	@echo ""
	@echo "=== Signing ==="
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(VM_BINARY)
	@codesign --force --sign - $(BINARY)
	@codesign --force --sign - $(ARCHIVE_BINARY)
	@echo "  signed: vphone-vm (entitled), vphone-cli, vphone-archive"
	@# An unentitled vphone-vm is worse than a broken one: it launches
	@# perfectly, which convinces vphone-cli's AMFI probe that nothing is
	@# wrong, and only fails later trying to create a PV=3 machine. A bare
	@# `swift build` leaves exactly that state behind.
	@codesign -d --entitlements - --xml $(VM_BINARY) 2>/dev/null \
		| grep -q 'com.apple.private.virtualization' \
		|| (echo "Error: $(VM_BINARY) is not entitled after signing." >&2; exit 1)

$(VM_BINARY) $(ARCHIVE_BINARY): $(BINARY)

bundle: build $(INFO_PLIST)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp -f $(BINARY) $(BUNDLE_BIN)
	@cp -f $(VM_BINARY) $(BUNDLE_VM)
	@cp -f $(ARCHIVE_BINARY) $(BUNDLE_ARCHIVE)
	@cp -f $(INFO_PLIST) $(BUNDLE)/Contents/Info.plist
	@cp -f sources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@cp -f $(SCRIPTS)/vphoned/signcert.p12 $(BUNDLE)/Contents/Resources/signcert.p12
	@# The bundle is built over whatever is already there, so these two are removed
	@# although nothing copies either one any more: bundles built before VPhoneSign
	@# replaced ldid carry the Homebrew ldid, the only thing in here linking
	@# libcrypto.3 and libplist-2.0.4 and so the only thing failing gate 1; bundles
	@# built before the AMFI bypass became the user's own business carry
	@# vphone-letmein, which patched amfid's __TEXT — a write the kernel kills
	@# amfid for wherever vm.cs_system_enforcement is 1. Both have to go
	@# before the seal below, not after — removing nested code from a sealed bundle
	@# is what makes `codesign -v` report it modified.
	@rm -f $(BUNDLE)/Contents/MacOS/ldid $(BUNDLE)/Contents/MacOS/vphone-letmein
	@# Order matters: vphone-vm is CFBundleExecutable, so signing it seals the
	@# whole bundle and everything beside it counts as nested code. Sign the
	@# nested binaries FIRST, or `codesign -v` reports "nested code is modified".
	@codesign --force --sign - $(BUNDLE_BIN)
	@codesign --force --sign - $(BUNDLE_ARCHIVE)
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUNDLE_VM)
	@codesign -v $(BUNDLE_VM) \
		|| (echo "Error: the bundle seal did not verify after signing." >&2; exit 1)
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

.PHONY: vm_new vm_backup vm_restore vm_switch vm_list amfi_command boot_host_preflight boot boot_less boot_dfu boot_binary_check boot_binary_check_less

vm_new:
	CPU="$(CPU)" MEMORY="$(MEMORY)" \
	zsh $(SCRIPTS)/vm_create.sh --dir "$(VM_DIR)" --disk-size $(DISK_SIZE)

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
	@found=0; \
	if [ -d "$(BACKUPS_DIR)" ]; then \
		current=""; \
		[ -f "$(VM_DIR)/.vm_name" ] && current="$$(cat "$(VM_DIR)/.vm_name")"; \
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
	fi; \
	if [ "$$found" = "0" ]; then echo "  (no backups yet — run: make vm_backup NAME=<name>)"; fi

# The self-containment admission gates. Expected to FAIL today: the bundled
# ldid is Homebrew's and links /opt/homebrew. That is the gate working, and it
# clears when VPhoneSign replaces ldid. CHECK_AUX_FAST=1 skips the smoke test.
.PHONY: check-aux
check-aux: bundle
	@zsh $(SCRIPTS)/check_aux.sh

# vphone-vm carries the private virtualization entitlements, so amfid is the one
# thing that can refuse it. Opening a window for it is the user's own business:
# this project ships no bypass and depends on none. What it can do is save the
# cdhash from being copied out of `codesign -dv` by hand, so this target prints
# the exact command line for the binaries THIS build produced — and prints only.
# It installs nothing, runs nothing, needs no sudo, and does not care whether
# amfidont is on the machine at all.
#
# It depends on `bundle` because `make boot` needs BOTH copies of vphone-vm let
# through: boot_binary_check runs .build/release/vphone-vm, and the boot itself
# runs the one inside the .app. Their cdhashes differ — different signing
# identifier (`vphone-vm-<hash>` vs `com.vphone.cli`), sealed bundle resources
# on one and none on the other, and they are not even the same length — so an
# allowlist given one cdhash covers exactly half the flow.
#
# The paths are printed resolved (`pwd -P`). .build/release is a symlink to
# .build/out/Products/Release, and amfid judges the vnode path it is handed,
# not the symlink the user typed — a `--path` entry naming the symlink matches
# nothing, silently.
amfi_command: bundle
	@set -e; \
	paths=""; hashes=""; \
	for b in "$(CURDIR)/$(VM_BINARY)" "$(CURDIR)/$(BUNDLE_VM)"; do \
		[ -f "$$b" ] || continue; \
		h="$$(codesign -dv --verbose=4 "$$b" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"; \
		[ -n "$$h" ] || continue; \
		d="$$(cd "$$(dirname "$$b")" && pwd -P)"; \
		case " $$paths " in *" $$d "*) ;; *) paths="$$paths $$d";; esac; \
		case " $$hashes " in *" $$h "*) ;; *) hashes="$$hashes $$h";; esac; \
	done; \
	if [ -z "$$hashes" ]; then \
		echo "Error: no CDHash on $(VM_BINARY) — run 'make build' first." >&2; \
		exit 1; \
	fi; \
	echo "vphone-vm is the only entitled binary, so it is the only one amfid can"; \
	echo "refuse. Allow it with an AMFI bypass of your choosing — the project does"; \
	echo "not install, start or require one. With amfidont, for this build:"; \
	echo ""; \
	printf '  sudo amfidont daemon'; \
	for d in $$paths; do printf " \\\\\n    --path '%s'" "$$d"; done; \
	for h in $$hashes; do printf " \\\\\n    --cdhash %s" "$$h"; done; \
	printf " \\\\\n    --spoof-apple --verbose\n"; \
	echo ""; \
	echo "It is an allowlist: only the paths and cdhashes above are let through."; \
	echo "Re-run this target after every build — the cdhash changes with the binary."; \
	echo "Leave the daemon running in its own terminal, then 'make boot' in another."; \
	echo ""; \
	echo "amfidont is not part of this project and is not built here."; \
	echo "It installs with the SYSTEM python (Homebrew's refuses, PEP 668):"; \
	echo "  xcrun python3 -m pip install --user amfidont    # needs Xcode"; \
	echo "  ~/Library/Python/3.9/bin/amfidont"

boot_host_preflight: build
	zsh $(SCRIPTS)/boot_host_preflight.sh

# Checks the ENTITLED binary, because that is the one amfid can refuse.
# Running `vphone-cli --help` here would prove nothing: it carries no
# entitlements and launches on any host.
define BOOT_BINARY_CHECK
	@zsh $(SCRIPTS)/boot_host_preflight.sh $(1)
	@tmp_log="$$(mktemp -t vphone-boot-preflight.XXXXXX)"; \
	set +e; \
	"$(CURDIR)/$(VM_BINARY)" --help >"$$tmp_log" 2>&1; \
	rc=$$?; \
	set -e; \
	if [ $$rc -ne 0 ]; then \
		echo "Error: signed vphone-vm failed to launch (exit $$rc)." >&2; \
		echo "Check private virtualization entitlement support and ensure SIP/AMFI are disabled on the host." >&2; \
		echo "If it was SIGKILLed, amfid refused the entitlements and an AMFI bypass has to allow" >&2; \
		echo "vphone-vm first. That is yours to run; for the command line, with this build's cdhash:" >&2; \
		echo "  make amfi_command" >&2; \
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
	cd "$(VM_DIR)" && "$(CURDIR)/$(BUNDLE_BIN)" \
		--config ./config.plist

boot_less: bundle boot_binary_check_less
	cd "$(VM_DIR)" && "$(CURDIR)/$(BUNDLE_BIN)" \
		--config ./config.plist \
		--variant less \
		$(if $(call truthy,$(NO_VPHONED)),--no-vphoned,)

boot_dfu: build boot_binary_check
	cd "$(VM_DIR)" && "$(CURDIR)/$(BINARY)" \
		--config ./config.plist \
		--dfu

# ═══════════════════════════════════════════════════════════════════
# Firmware pipeline
# ═══════════════════════════════════════════════════════════════════

.PHONY: fw_prepare fw_patch fw_patch_less fw_patch_dev fw_patch_jb fw_patch_exp

fw_prepare:
	cd "$(VM_DIR)" && bash "$(CURDIR)/$(SCRIPTS)/fw_prepare.sh"

fw_patch: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant regular \
	$(if $(call truthy,$(FORCE_EXC_GUARD)),--force-exc-guard,)

UID := $(shell id -u)
ifeq ($(UID),0)
fw_patch_less: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" \
	--variant less \
	$(if $(call truthy,$(NO_BINPACK)),--no-binpack,) \
	$(if $(call truthy,$(NO_VPHONED)),--no-vphoned,)
else
fw_patch_less:
	@echo "Error: fw_patch_less needs root. Run: sudo make fw_patch_less"
	@exit 1
endif

fw_patch_dev: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant dev

fw_patch_jb: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant jb \
	$(if $(call truthy,$(FORCE_EXC_GUARD)),--force-exc-guard,) \
	$(if $(call truthy,$(FRIDA)),--frida,)

fw_patch_exp: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant exp \
	$(if $(call truthy,$(FORCE_EXC_GUARD)),--force-exc-guard,) \
	$(if $(call truthy,$(FRIDA)),--frida,)

.PHONY: test_jb_patches

# Run the full JB kernel patch layer (every hook, incl. all Sandbox ops hooks)
# over EVERY cloudOS kernel the README supports — correctness + backward-compat.
# Downloads each version's kernelcache on demand (cached under /tmp/vphone_kjb_versions).
#   Options: QUICK=1   Only the local/newest kernel (fast dev loop)
test_jb_patches: patcher_build
	zsh "$(CURDIR)/tests/test_jb_kernel_patches.sh" --no-build \
		$(if $(call truthy,$(QUICK)),--quick,)

.PHONY: test_fw_patches

# Run the FULL patch-firmware pipeline (boot chain + base kernel + JB + EXP, every
# component) over each locally-prepared cloudOS firmware, for the jb and exp
# variants, and fail if ANY component skips a sub-patch (a `[-]` line). This is the
# broad gate that catches drift outside the JB kernel layer (iBSS/iBEC/LLB, base
# KernelPatcher, TXM, DeviceTree) — which test_jb_patches structurally cannot see.
#   Options: QUICK=1            Only the newest local cloudOS firmware
#            VARIANTS="exp"     Limit to specific variants (default: jb exp)
test_fw_patches: patcher_build
	zsh "$(CURDIR)/tests/test_firmware_patches.sh" --no-build \
		$(if $(call truthy,$(QUICK)),--quick,)

# ═══════════════════════════════════════════════════════════════════
# Restore
# ═══════════════════════════════════════════════════════════════════

.PHONY: restore_get_shsh restore restore_offline

# Resolve ECID from RESTORE_ECID or vm/udid-prediction.txt (written by boot_dfu).
define _resolve_ecid
	if [ -n "$(RESTORE_ECID)" ]; then \
		ECID="$(RESTORE_ECID)"; \
	elif [ -f "$(VM_DIR_ABS)/udid-prediction.txt" ]; then \
		ECID=$$(grep '^ECID=' "$(VM_DIR_ABS)/udid-prediction.txt" | head -1 | cut -d= -f2); \
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
	SHSH=$$(ls "$(VM_DIR_ABS)/"*.shsh 2>/dev/null | head -1); \
	if [ -z "$$SHSH" ]; then \
		echo "[-] No .shsh file in $(VM_DIR)/ — run 'make restore_get_shsh' first"; \
		exit 1; \
	fi; \
	RESTORE_SRC=$$(echo "$(VM_DIR_ABS)/iPhone"*_Restore); \
	if [ ! -d "$$RESTORE_SRC" ]; then \
		echo "[-] No iPhone*_Restore directory in $(VM_DIR)/"; \
		exit 1; \
	fi; \
	echo "[+] Decrypting AEA images in place…"; \
	for aea in "$$RESTORE_SRC"/*.dmg.aea; do \
		[ -f "$$aea" ] || continue; \
		[ "$$(xxd -l 4 -p "$$aea")" = "41454131" ] || continue; \
		base=$$(basename "$$aea"); \
		if ! ipsw fw aea -o "$$RESTORE_SRC" "$$aea"; then \
			echo "[-] Could not decrypt $$base with ipsw — restore stopped."; \
			exit 1; \
		fi; \
		if ! mv -f "$$RESTORE_SRC/$${base%.aea}" "$$aea"; then \
			echo "[-] Could not replace $$base with its decrypted image — restore stopped."; \
			exit 1; \
		fi; \
		if [ "$$(xxd -l 4 -p "$$aea")" = "41454131" ]; then \
			echo "[-] $$base is still encrypted after decryption — restore stopped."; \
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
# CFW
# ═══════════════════════════════════════════════════════════════════

.PHONY: cfw_install cfw_install_dev cfw_install_jb cfw_install_exp cfw_install_host

cfw_install:
	$(MAKE) cfw_install_host VARIANT=regular

cfw_install_dev:
	$(MAKE) cfw_install_host VARIANT=dev

cfw_install_jb:
	$(MAKE) cfw_install_host VARIANT=jb FRIDA="$(FRIDA)"

cfw_install_exp:
	$(MAKE) cfw_install_host VARIANT=exp SPOOF_BUILD="$(SPOOF_BUILD)" FRIDA="$(FRIDA)"

# CFW install: place files via host mount + flip the boot snapshot offline.
# VM must be off; re-execs under sudo.
#   Options: VARIANT=regular|dev|jb|exp (default exp)  SPOOF_BUILD=<id> (exp)
cfw_install_host:
	$(if $(SPOOF_BUILD),SPOOF_BUILD="$(SPOOF_BUILD)") $(if $(call truthy,$(FRIDA)),VPHONE_FRIDA=1) zsh "$(CURDIR)/$(SCRIPTS)/cfw_install_host.sh" --variant $(if $(VARIANT),$(VARIANT),exp) "$(VM_DIR_ABS)"
