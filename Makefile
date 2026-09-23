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
# Getting vphone-vm past amfid is `make amfi_allow`, which runs
# vphone-amfi-allow for this build's cdhashes. It asks for root and it is a
# per-build step. `make amfi_off` puts the machine back.
BINARY      := .build/release/vphone-cli
VM_BINARY   := .build/release/vphone-vm
ARCHIVE_BINARY := .build/release/vphone-archive
ASKPASS_BINARY := .build/release/vphone-ask-for-permission
# Not a SwiftPM product: SwiftPM emits arm64 and this one must be arm64e to
# read amfid's ObjC runtime. Built by clang, below and in scripts/build.sh.
AMFI_BINARY := .build/release/vphone-amfi-allow
AMFI_SOURCE := sources/vphone-amfi-allow/vphone-amfi-allow.c
PATCHER_BINARY := .build/debug/vphone-cli
BUNDLE      := .build/vphone-cli.app
BUNDLE_BIN  := $(BUNDLE)/Contents/MacOS/vphone-cli
BUNDLE_VM   := $(BUNDLE)/Contents/MacOS/vphone-vm
BUNDLE_ARCHIVE := $(BUNDLE)/Contents/MacOS/vphone-archive
BUNDLE_ASKPASS := $(BUNDLE)/Contents/MacOS/vphone-ask-for-permission
BUNDLE_AMFI := $(BUNDLE)/Contents/MacOS/vphone-amfi-allow
INFO_PLIST  := sources/Info.plist
ENTITLEMENTS := sources/vphone.entitlements
# There is no interpreter here any more, and no variable naming one. The
# firmware and CFW patchers are Swift (FirmwarePatcher, reached through
# `vphone-cli cfw <verb>` and `patch-firmware`), and the restore targets below
# are `vphone-cli restore`, which carries libirecovery and idevicerestore in
# the binary. Anything that reintroduces a `python3` on PATH here is a
# regression — see the "Python" section in AGENTS.md.
TOOLS_PREFIX := .tools

SWIFT_SOURCES := $(shell find sources -name '*.swift')

# ─── Environment — prefer project-local binaries ────────────────
export PATH := $(CURDIR)/$(TOOLS_PREFIX)/bin:$(CURDIR)/.build/release:$(PATH)

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
	@echo "  make setup_tools             Build insert_dylib (a test reference; optional)"
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
	@echo "  make amfi_allow              Allow THIS build's vphone-vm past amfid (asks for root)"
	@echo "                               Re-run after every build — it allowlists cdhashes"
	@echo "  make amfi_status             Show the allowlist and whether this host can carry one"
	@echo "  make amfi_off                Remove the allowlist and restart amfid clean"
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
	@echo "  make restore                 Restore to device (in-process libirecovery + idevicerestore)"
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

.PHONY: setup_machine setup_tools

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

# ═══════════════════════════════════════════════════════════════════
# Clean — remove generated build/tooling files by default.
# Destructive VM/IPSW cleanup is opt-in and requires confirmation.
#
# `.venv` is named literally, and only so an old checkout can be swept: nothing
# creates one any more, and it is no longer in .gitignore, so a leftover shows
# up in `git status` until this removes it.
# ═══════════════════════════════════════════════════════════════════

.PHONY: clean
clean:
	@set -e; \
	echo "=== Cleaning build/tooling artifacts ==="; \
	echo "Removing: .build .swiftpm $(TOOLS_PREFIX) (and a leftover .venv, if one is still there)"; \
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
	rm -rf .build .swiftpm "$(TOOLS_PREFIX)" .venv; \
	if [ "$(CLEAN_VM)" = "1" ]; then rm -rf "$(VM_DIR)"; fi; \
	if [ "$(CLEAN_IPSW)" = "1" ]; then rm -rf ipsws; fi

# ═══════════════════════════════════════════════════════════════════
# Build
# ═══════════════════════════════════════════════════════════════════

.PHONY: build patcher_build bundle sign

# `sign` is phony and runs every time, deliberately. It used to live inside the
# $(BINARY) recipe, which meant make skipped it whenever the binary was newer
# than its sources — and a bare `swift build -c release`, which anyone might run,
# leaves exactly that state: a rebuilt vphone-vm with its entitlements stripped
# and an mtime that makes `make build` say "Nothing to be done". The guard below
# was written to catch that case and could not, because it was in the recipe
# that got skipped. Ad-hoc signing is idempotent and takes under a second, so
# doing it unconditionally costs nothing and closes the hole.
build: $(BINARY) sign

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

sign: $(BINARY)
	@echo "=== Signing ==="
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(VM_BINARY)
	@codesign --force --sign - $(BINARY)
	@codesign --force --sign - $(ARCHIVE_BINARY)
	@codesign --force --sign - $(ASKPASS_BINARY)
	@echo "  signed: vphone-vm (entitled), vphone-cli, vphone-archive, vphone-ask-for-permission"
	@# An unentitled vphone-vm is worse than a broken one: it launches
	@# perfectly, which convinces vphone-cli's AMFI probe that nothing is
	@# wrong, and only fails later trying to create a PV=3 machine. A bare
	@# `swift build` leaves exactly that state behind — and leaves an mtime
	@# that used to make `make build` skip this whole block, guard included.
	@codesign -d --entitlements - --xml $(VM_BINARY) 2>/dev/null \
		| grep -q 'com.apple.private.virtualization' \
		|| (echo "Error: $(VM_BINARY) is not entitled after signing." >&2; exit 1)

$(VM_BINARY) $(ARCHIVE_BINARY) $(ASKPASS_BINARY): $(BINARY)

# arm64e, because it reads amfid's ObjC runtime and has to match amfid's slice.
# An arm64 build links and then fails at run time with nothing to say, so the
# slice is asserted rather than assumed.
$(AMFI_BINARY): $(AMFI_SOURCE)
	@echo "=== Building vphone-amfi-allow (arm64e) ==="
	@mkdir -p $(dir $(AMFI_BINARY))
	@clang -arch arm64e -O2 -framework CoreFoundation -framework Security \
		-o $(AMFI_BINARY) $(AMFI_SOURCE)
	@file $(AMFI_BINARY) | grep -q arm64e \
		|| (echo "Error: $(AMFI_BINARY) is not arm64e." >&2; exit 1)
	@codesign --force --sign - $(AMFI_BINARY)
	@echo "  signed: vphone-amfi-allow"

# `bundle` produces the SAME bundle scripts/build.sh does, Resources included.
#
# It did not, until now: build.sh staged Contents/Resources/scripts and this
# target did not, so `make check-aux` — which depends on this — was inspecting a
# five-binary bundle while the thing users actually get carried twenty scripts
# and a Homebrew-linked trustcache. The gate was green because it was looking at
# the wrong artifact. Both paths now read the same allowlist.
bundle: build $(AMFI_BINARY) guest_binaries $(INFO_PLIST)
	@# `build` re-signs unconditionally now, so the copies below are always
	@# made from a freshly entitled vphone-vm rather than from whatever a bare
	@# `swift build` last left in .build/release.
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp -f $(BINARY) $(BUNDLE_BIN)
	@cp -f $(VM_BINARY) $(BUNDLE_VM)
	@cp -f $(ARCHIVE_BINARY) $(BUNDLE_ARCHIVE)
	@cp -f $(ASKPASS_BINARY) $(BUNDLE_ASKPASS)
	@cp -f $(AMFI_BINARY) $(BUNDLE_AMFI)
	@cp -f $(INFO_PLIST) $(BUNDLE)/Contents/Info.plist
	@cp -f sources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@cp -f $(SCRIPTS)/vphoned/signcert.p12 $(BUNDLE)/Contents/Resources/signcert.p12
	@# The bundle is built over whatever is already there, so these are removed
	@# although nothing copies any of them any more: bundles built before
	@# VPhoneSign replaced ldid carry the Homebrew ldid; bundles built before the
	@# AMFI bypass became ours carry vphone-letmein, which patched amfid's __TEXT
	@# — a write the kernel kills amfid for wherever vm.cs_system_enforcement is
	@# 1; and .tools/bin/trustcache linked /opt/homebrew's libcrypto.3 while
	@# nothing ever invoked it. They have to go BEFORE the seal below, not after
	@# — removing nested code from a sealed bundle is what makes `codesign -v`
	@# report it modified.
	@rm -f $(BUNDLE)/Contents/MacOS/ldid $(BUNDLE)/Contents/MacOS/vphone-letmein
	@rm -rf $(BUNDLE)/Contents/Resources/scripts $(BUNDLE)/Contents/Resources/guest \
		$(BUNDLE)/Contents/Resources/.tools $(BUNDLE)/Contents/Resources/tools
	@mkdir -p $(BUNDLE)/Contents/Resources/scripts
	@zsh $(SCRIPTS)/dist_manifest.sh \
		| rsync -a --files-from=- $(SCRIPTS)/ $(BUNDLE)/Contents/Resources/scripts/
	@cp -R $(GUEST_DIR) $(BUNDLE)/Contents/Resources/guest
	@cp -f debs.list $(BUNDLE)/Contents/Resources/debs.list
	@cp -f README.md $(BUNDLE)/Contents/Resources/README.md
	@# Order matters: vphone-vm is CFBundleExecutable, so signing it seals the
	@# whole bundle and everything beside it counts as nested code. Sign the
	@# nested binaries FIRST, or `codesign -v` reports "nested code is modified".
	@codesign --force --sign - $(BUNDLE_BIN)
	@codesign --force --sign - $(BUNDLE_ARCHIVE)
	@codesign --force --sign - $(BUNDLE_ASKPASS)
	@codesign --force --sign - $(BUNDLE_AMFI)
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BUNDLE_VM)
	@codesign -v $(BUNDLE_VM) \
		|| (echo "Error: the bundle seal did not verify after signing." >&2; exit 1)
	@echo "  bundled → $(BUNDLE)"

# The five iOS binaries the guest runs. Compiled here, on the build machine,
# because compiling them at CFW-install time is what made Xcode a prerequisite
# for running a VM. See scripts/guest_binaries.mk.
include $(SCRIPTS)/guest_binaries.mk

# vphoned for a LIVE guest: the copy the host pushes over vsock, signed here
# because there is no VM cfw_input in that flow. `vphone-cli sign` replaces the
# `ldid` this used to need, so the build has no Homebrew dependency either.
.PHONY: vphoned
vphoned: $(GUEST_DIR)/vphoned $(BINARY)
	@cp -f $(GUEST_DIR)/vphoned .build/vphoned.signed
	@$(BINARY) sign --entitlements $(SCRIPTS)/vphoned/entitlements.plist --merge \
		--pkcs12 $(SCRIPTS)/vphoned/signcert.p12 .build/vphoned.signed
	@echo "  signed → .build/vphoned.signed"
	@# The VM-local copy the guest auto-update path reads. Same bytes, second
	@# location; the `ldid` invocation that used to be here is the same
	@# `vphone-cli sign` above.
	@if [ -d "$(VM_DIR_ABS)" ]; then \
		cp -f .build/vphoned.signed $(VM_DIR_ABS)/.vphoned.signed; \
		echo "  signed → $(VM_DIR)/.vphoned.signed"; \
	fi

# ═══════════════════════════════════════════════════════════════════
# VM management
# ═══════════════════════════════════════════════════════════════════

.PHONY: vm_new vm_backup vm_restore vm_switch vm_list amfi_allow amfi_status amfi_off boot_host_preflight boot boot_less boot_dfu boot_binary_check boot_binary_check_less

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
# thing that can refuse it. `vphone-amfi-allow` is how this project gets past
# that, and this target runs it for the binaries THIS build produced.
#
# It needs root, and it asks — it does not assume a passwordless sudo and it
# does not hold a password. It needs `Debugging Restrictions: disabled` in
# `csrutil status` as well, for task_for_pid; without it the tool says so and
# changes nothing.
#
# It depends on `bundle` because `make boot` needs BOTH copies of vphone-vm let
# through: boot_binary_check runs .build/release/vphone-vm, and the boot itself
# runs the one inside the .app. Their cdhashes differ — different signing
# identifier (`vphone-vm-<hash>` vs `com.vphone.cli`), sealed bundle resources
# on one and none on the other, and they are not even the same length — so an
# allowlist given one cdhash covers exactly half the flow. Both are passed.
#
# The paths are resolved (`pwd -P`). .build/release is a symlink to
# .build/out/Products/Release, and the requirement is evaluated against the
# vnode path, not the symlink that was typed.
amfi_allow: bundle
	@set -e; \
	binaries=""; \
	for b in "$(CURDIR)/$(VM_BINARY)" "$(CURDIR)/$(BUNDLE_VM)"; do \
		[ -f "$$b" ] || continue; \
		d="$$(cd "$$(dirname "$$b")" && pwd -P)"; \
		binaries="$$binaries $$d/$$(basename "$$b")"; \
	done; \
	if [ -z "$$binaries" ]; then \
		echo "Error: $(VM_BINARY) not built — run 'make build' first." >&2; \
		exit 1; \
	fi; \
	echo "Allowing this build past amfid (needs root):"; \
	for b in $$binaries; do echo "  $$b"; done; \
	echo ""; \
	sudo "$(CURDIR)/$(AMFI_BINARY)" allow $$binaries

# What the allowlist looks like right now, and whether the host can carry one.
# Reads only; no root.
amfi_status: $(AMFI_BINARY)
	@"$(CURDIR)/$(AMFI_BINARY)" status

# Put the machine back: drops the preference and restarts amfid clean.
amfi_off:
	@sudo "$(CURDIR)/$(AMFI_BINARY)" off

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
		echo "If it was SIGKILLed, amfid refused the entitlements and this build has to be" >&2; \
		echo "allowed past it first. That step needs root, so it is not run for you:" >&2; \
		echo "  make amfi_allow" >&2; \
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

# The restore backend is vphone-cli itself now — libirecovery and
# idevicerestore, linked in — so these targets need the binary built, the way
# boot_dfu does. The venv and the Python bridge they used to run are gone from
# this path entirely.
#
# `vphone-cli restore` names a VM the way the CLI does, as a library root plus
# a bundle name, while make has always taken a directory (VM_DIR=vm, or an
# absolute path on an external disk). Split VM_DIR_ABS rather than ask anyone
# to learn a second spelling.
RESTORE_VM_ARGS = --library-root "$(dir $(VM_DIR_ABS))" "$(notdir $(VM_DIR_ABS))"

restore_get_shsh: build
	@$(call _resolve_ecid); \
	"$(CURDIR)/$(BINARY)" restore $(RESTORE_VM_ARGS) --get-shsh \
		$(if $(RESTORE_UDID),--udid $(RESTORE_UDID),) \
		--ecid "$$ECID"

restore: build
	@$(call _resolve_ecid); \
	"$(CURDIR)/$(BINARY)" restore $(RESTORE_VM_ARGS) \
		$(if $(RESTORE_UDID),--udid $(RESTORE_UDID),) \
		--ecid "$$ECID"

# The `ipsw fw aea` loop below stays: decrypting the AEA images is not part of
# what moved in-process. `vphone-cli restore --offline` then picks the same
# first-sorted .shsh this recipe checks for, and its own AEA pass finds nothing
# left to do after the loop has run.
restore_offline: build
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
	"$(CURDIR)/$(BINARY)" restore $(RESTORE_VM_ARGS) --offline \
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
