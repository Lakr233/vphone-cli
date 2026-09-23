# ═══════════════════════════════════════════════════════════════════
# vphone-cli — Virtual iPhone boot tool
# ═══════════════════════════════════════════════════════════════════

# ─── Configuration (override with make VAR=value) ─────────────────
VM_DIR      ?= vm
# Absolute VM path: handles both relative (default `vm`) and absolute
# (e.g. external SSD) VM_DIR values. `abspath` leaves absolute paths intact
# and joins relative ones against CURDIR — use this for the VM directory arg.
VM_DIR_ABS  := $(abspath $(VM_DIR))
SWIFT_JOBS  ?= 4
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
	@echo "  vphone-cli vm new <name>      Create a VM bundle"
	@echo "  vphone-cli vm list            List VM bundles"
	@echo "  vphone-cli vm export <name> --out <archive>  Back up a VM"
	@echo "  vphone-cli vm import <archive> --name <name> Restore into a new VM"
	@echo "  make check-aux               Run the self-containment admission gates"
	@echo "  make amfi_allow              Allow THIS build's vphone-vm past amfid (asks for root)"
	@echo "                               Re-run after every build — it allowlists cdhashes"
	@echo "  make amfi_status             Show the allowlist and whether this host can carry one"
	@echo "  make amfi_off                Remove the allowlist and restart amfid clean"
	@echo "  make boot_host_preflight     Diagnose whether host can launch signed PV=3 binary"
	@echo "  make boot                    Boot VM (reads from config.plist)"
	@echo "  make boot_dfu                Boot VM in DFU mode (reads from config.plist)"
	@echo ""
	@echo "Firmware pipeline:"
	@echo "  vphone-cli fw prepare <name> --iphone-source IPSW --cloudos-source IPSW"
	@echo "                               Prepare a VM's restore tree from two IPSWs"
	@echo "  make fw_patch                Patch boot chain with the JB Swift pipeline"
	@echo "    Options: FORCE_EXC_GUARD=1        Force the EXC_GUARD Mach-port-guard disable patch even on bases"
	@echo "                                      that don't strictly need it to boot (e.g. a 3rd-party app's"
	@echo "                                      crash-reporting SDK trips a fatal GUARD_TYPE_MACH_PORT violation)"
	@echo "             FRIDA=1                  Opt in to the Frida Stalker kernel relaxations"
	@echo ""
	@echo "Restore:"
	@echo "  make restore_get_shsh        Dump SHSH response from Apple"
	@echo "  make restore                 Restore to device (in-process libirecovery + idevicerestore)"
	@echo "  make restore_offline         Restore offline from the cached .shsh file (decrypts AEA images in place)"
	@echo ""
	@echo "CFW (host-mount install; VM must be off, re-execs sudo):"
	@echo "  make cfw_install             Install JB CFW via host mount"
	@echo ""
	@echo "Variables: VM_DIR=$(VM_DIR) SWIFT_JOBS=$(SWIFT_JOBS)"

# ═══════════════════════════════════════════════════════════════════
# Setup
# ═══════════════════════════════════════════════════════════════════

.PHONY: setup_tools

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
	@set -o pipefail; swift build --jobs $(SWIFT_JOBS) 2>&1 | tail -5

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
	@set -o pipefail; swift build -c release --jobs $(SWIFT_JOBS) 2>&1 | tail -5

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

# One packaging implementation: direct builds and `make bundle` stage the same resources.
bundle:
	@zsh $(SCRIPTS)/build.sh

# The five iOS binaries the guest runs. Compiled here, on the build machine,
# because compiling them at CFW-install time is what made Xcode a prerequisite
# for running a VM. See scripts/guest_binaries.mk.
include $(SCRIPTS)/guest_binaries.mk

# vphoned for a live guest. This target only prepares the build artifact;
# `boot` stages it into its VM after `bundle` has completed.
.PHONY: vphoned
vphoned: $(GUEST_DIR)/vphoned $(BINARY)
	@cp -f $(GUEST_DIR)/vphoned .build/vphoned.signed
	@$(BINARY) sign --entitlements $(SCRIPTS)/vphoned/entitlements.plist --merge \
		.build/vphoned.signed
	@echo "  signed → .build/vphoned.signed"

# ═══════════════════════════════════════════════════════════════════
# VM management
# ═══════════════════════════════════════════════════════════════════

.PHONY: amfi_allow amfi_status amfi_off boot_host_preflight boot boot_dfu boot_binary_check

# Self-containment checks over the complete application bundle.
# CHECK_AUX_FAST=1 skips smoke checks for local source checks only.
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

boot_binary_check: $(BINARY)
	$(call BOOT_BINARY_CHECK,--assert-bootable)

boot: bundle boot_binary_check
	@cp -f "$(BUNDLE)/Contents/Resources/vphoned.signed" "$(VM_DIR_ABS)/.vphoned.signed"
	cd "$(VM_DIR)" && "$(CURDIR)/$(BUNDLE_BIN)" \
		--config ./config.plist

boot_dfu: build boot_binary_check
	cd "$(VM_DIR)" && "$(CURDIR)/$(BINARY)" \
		--config ./config.plist \
		--dfu

# ═══════════════════════════════════════════════════════════════════
# Firmware pipeline
# ═══════════════════════════════════════════════════════════════════

.PHONY: fw_patch

fw_patch: patcher_build
	"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" \
	$(if $(call truthy,$(FORCE_EXC_GUARD)),--force-exc-guard,) \
	$(if $(call truthy,$(FRIDA)),--frida,)

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

.PHONY: cfw_install

cfw_install:
	$(if $(call truthy,$(FRIDA)),VPHONE_FRIDA=1) zsh "$(CURDIR)/$(SCRIPTS)/cfw_install_host.sh" "$(VM_DIR_ABS)"
