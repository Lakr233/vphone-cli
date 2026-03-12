# ═══════════════════════════════════════════════════════════════════
# vphone-cli — Virtual iPhone boot tool
# ═══════════════════════════════════════════════════════════════════

# ─── Configuration (override with make VAR=value) ─────────────────
VM_DIR      ?= vm
CPU         ?= 8
MEMORY      ?= 8192
DISK_SIZE   ?= 64
RESTORE_UDID ?=
RESTORE_ECID ?=
RAMDISK_ECID ?=
SETUP_VARIANT := $(if $(filter 1 true yes YES TRUE,$(JB)),$(if $(filter 1 true yes YES TRUE,$(DEV)),invalid,jb),$(if $(filter 1 true yes YES TRUE,$(DEV)),dev,regular))

ifneq ($(filter 1 true yes YES TRUE,$(JB)),)
ifneq ($(filter 1 true yes YES TRUE,$(DEV)),)
$(error JB=1 and DEV=1 are mutually exclusive)
endif
endif

# ─── Paths ────────────────────────────────────────────────────────
SCRIPTS     := scripts
BINARY      := .build/release/vphone-cli
PATCHER_BINARY := .build/debug/vphone-cli
BUNDLE      := .build/vphone-cli.app
BUNDLE_BIN  := $(BUNDLE)/Contents/MacOS/vphone-cli
INFO_PLIST  := sources/Info.plist
ENTITLEMENTS := sources/vphone.entitlements
VM_DIR_ABS  := $(abspath $(VM_DIR))
TOOLS_PREFIX := .tools

SWIFT_SOURCES := $(shell find sources -name '*.swift')

# ─── Environment — prefer project-local binaries ────────────────
export PATH := $(CURDIR)/$(TOOLS_PREFIX)/bin:$(CURDIR)/.build/release:$(PATH)

# ─── Default ──────────────────────────────────────────────────────
.PHONY: help
help: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" workflow-help

# ═══════════════════════════════════════════════════════════════════
# Setup
# ═══════════════════════════════════════════════════════════════════

.PHONY: setup_machine setup_tools

setup_machine: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" setup-machine \
		--project-root "$(CURDIR)" \
		--vm-directory "$(VM_DIR)" \
		--cpu "$(CPU)" \
		--memory "$(MEMORY)" \
		--disk-size "$(DISK_SIZE)" \
		--variant "$(SETUP_VARIANT)" \
		$(if $(IPHONE_DEVICE),--iphone-device "$(IPHONE_DEVICE)") \
		$(if $(IPHONE_VERSION),--iphone-version "$(IPHONE_VERSION)") \
		$(if $(IPHONE_BUILD),--iphone-build "$(IPHONE_BUILD)") \
		$(if $(IPHONE_SOURCE),--iphone-source "$(IPHONE_SOURCE)") \
		$(if $(CLOUDOS_SOURCE),--cloudos-source "$(CLOUDOS_SOURCE)") \
		$(if $(IPSW_DIR),--ipsw-dir "$(IPSW_DIR)") \
		$(if $(filter 1 true yes YES TRUE,$(SKIP_PROJECT_SETUP)),--skip-project-setup) \
		$(if $(filter 1 true yes YES TRUE,$(NONE_INTERACTIVE)),--non-interactive)

setup_tools: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" setup-tools --project-root "$(CURDIR)"

# ═══════════════════════════════════════════════════════════════════
# Clean — remove all untracked/ignored files (preserves IPSWs only)
# ═══════════════════════════════════════════════════════════════════

.PHONY: clean
clean: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" clean-project --project-root "$(CURDIR)"

# ═══════════════════════════════════════════════════════════════════
# Build
# ═══════════════════════════════════════════════════════════════════

.PHONY: build patcher_build bundle

build: $(BINARY)

patcher_build: $(PATCHER_BINARY)

$(PATCHER_BINARY): $(SWIFT_SOURCES) Package.swift
	@swift build --quiet

$(BINARY): patcher_build $(ENTITLEMENTS)
	@"$(CURDIR)/$(PATCHER_BINARY)" build-host --project-root "$(CURDIR)" --configuration release

bundle: patcher_build setup_tools $(INFO_PLIST)
	@"$(CURDIR)/$(PATCHER_BINARY)" bundle-app --project-root "$(CURDIR)" --bundle-path "$(CURDIR)/$(BUNDLE)"

# Cross-compile + sign vphoned daemon for iOS arm64 via Swift CLI
.PHONY: vphoned
vphoned: patcher_build setup_tools
	@"$(CURDIR)/$(PATCHER_BINARY)" build-vphoned --project-root "$(CURDIR)" --vm-directory "$(VM_DIR_ABS)"

# ═══════════════════════════════════════════════════════════════════
# VM management
# ═══════════════════════════════════════════════════════════════════

.PHONY: vm_new boot_host_preflight boot boot_dfu boot_binary_check

vm_new: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" vm-create \
		--dir "$(VM_DIR_ABS)" \
		--disk-size "$(DISK_SIZE)" \
		--cpu "$(CPU)" \
		--memory "$(MEMORY)"

boot_host_preflight: build patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" boot-host-preflight --project-root "$(CURDIR)"

boot_binary_check: $(BINARY) patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" boot-host-preflight --project-root "$(CURDIR)" --assert-bootable

boot: bundle vphoned boot_binary_check
	@"$(CURDIR)/$(BUNDLE_BIN)" \
		--config "$(VM_DIR_ABS)/config.plist"

boot_dfu: build boot_binary_check
	@"$(CURDIR)/$(BINARY)" \
		--config "$(VM_DIR_ABS)/config.plist" \
		--dfu

# ═══════════════════════════════════════════════════════════════════
# Firmware pipeline
# ═══════════════════════════════════════════════════════════════════

.PHONY: fw_prepare fw_patch fw_patch_dev fw_patch_jb

fw_prepare: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" prepare-firmware \
		--project-root "$(CURDIR)" \
		--output-dir "$(VM_DIR_ABS)" \
		$(if $(filter 1 true yes YES TRUE,$(LIST_FIRMWARES)),--list) \
		$(if $(IPHONE_DEVICE),--device "$(IPHONE_DEVICE)") \
		$(if $(IPHONE_VERSION),--version "$(IPHONE_VERSION)") \
		$(if $(IPHONE_BUILD),--build "$(IPHONE_BUILD)") \
		$(if $(IPHONE_SOURCE),--iphone-source "$(IPHONE_SOURCE)") \
		$(if $(CLOUDOS_SOURCE),--cloudos-source "$(CLOUDOS_SOURCE)") \
		$(if $(IPSW_DIR),--ipsw-dir "$(IPSW_DIR)")

fw_patch: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant regular

fw_patch_dev: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant dev

fw_patch_jb: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" patch-firmware --vm-directory "$(VM_DIR_ABS)" --variant jb

# ═══════════════════════════════════════════════════════════════════
# Restore
# ═══════════════════════════════════════════════════════════════════

.PHONY: restore_get_shsh restore

restore_get_shsh: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" restore-get-shsh "$(VM_DIR_ABS)" \
		$(if $(RESTORE_UDID),--udid "$(RESTORE_UDID)") \
		$(if $(RESTORE_ECID),--ecid "$(RESTORE_ECID)")

restore: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" restore-device "$(VM_DIR_ABS)" \
		$(if $(RESTORE_UDID),--udid "$(RESTORE_UDID)") \
		$(if $(RESTORE_ECID),--ecid "$(RESTORE_ECID)")

# ═══════════════════════════════════════════════════════════════════
# Ramdisk
# ═══════════════════════════════════════════════════════════════════

.PHONY: ramdisk_build ramdisk_send

ramdisk_build: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" build-ramdisk "$(VM_DIR_ABS)"

ramdisk_send: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" send-ramdisk \
		--ramdisk-dir "$(VM_DIR_ABS)/Ramdisk" \
		$(if $(RAMDISK_UDID),--udid "$(RAMDISK_UDID)",$(if $(RESTORE_UDID),--udid "$(RESTORE_UDID)")) \
		$(if $(RAMDISK_ECID),--ecid "$(RAMDISK_ECID)")

# ═══════════════════════════════════════════════════════════════════
# CFW
# ═══════════════════════════════════════════════════════════════════

.PHONY: cfw_install cfw_install_dev cfw_install_jb

cfw_install: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" cfw-install "$(VM_DIR_ABS)" --project-root "$(CURDIR)" --variant regular $(if $(SSH_PORT),--ssh-port "$(SSH_PORT)")

cfw_install_dev: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" cfw-install "$(VM_DIR_ABS)" --project-root "$(CURDIR)" --variant dev $(if $(SSH_PORT),--ssh-port "$(SSH_PORT)")

cfw_install_jb: patcher_build
	@"$(CURDIR)/$(PATCHER_BINARY)" cfw-install "$(VM_DIR_ABS)" --project-root "$(CURDIR)" --variant jb $(if $(SSH_PORT),--ssh-port "$(SSH_PORT)")
