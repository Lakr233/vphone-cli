# guest_binaries.mk — the five iOS binaries the CFW installers put in the guest,
# cross-compiled HERE, at build time, instead of on the user's machine at install
# time.
#
# vphone-tier: build
#
# Every one of these used to be compiled by the installer itself, from a `.m`
# file shipped inside the .app, through `xcrun --sdk iphoneos -f clang`. That
# made a full Xcode install a runtime prerequisite for `cfw install` — on a
# machine whose only job is to run a VM. It is the plainest violation of the
# dist rule there was: the shipped product reaching for a toolchain that is not
# in the bundle and is not part of macOS.
#
# So the split is: THIS file needs Xcode and the iPhoneOS SDK, and runs on the
# machine that builds the .app. The installers get the finished Mach-Os and only
# sign them, because signing is the one step that genuinely cannot move here —
# it uses the signing certificate from the target VM's own cfw_input, which does
# not exist until a VM does.
#
# Included by the top-level Makefile; `scripts/build.sh` drives it directly with
# `make -f`. Both put the results in $(GUEST_DIR), and both stage that directory
# into the bundle as Contents/Resources/guest.

GUEST_DIR ?= .build/guest
GIT_HASH  ?= unknown

# Resolved once. `xcrun` is allowed here and nowhere downstream; if it is
# missing, this is the file that says so, with the reason.
IOS_SDK := $(shell xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
IOS_CC  := $(shell xcrun --sdk iphoneos -f clang 2>/dev/null)

# 15.0 on every one of them, matching what the installers passed. Raising it
# here silently drops support for the older guest bases the JB variant still
# installs onto.
IOS_MIN := -miphoneos-version-min=15.0
IOS_CFLAGS = -isysroot $(IOS_SDK) $(IOS_MIN) -fobjc-arc

GUEST_BINARIES := \
	$(GUEST_DIR)/TweakLoader.dylib \
	$(GUEST_DIR)/vpregister \
	$(GUEST_DIR)/libvcamcaptured.dylib \
	$(GUEST_DIR)/libcamfix.dylib \
	$(GUEST_DIR)/vphoned

.PHONY: guest_binaries guest_binaries_clean

guest_binaries: $(GUEST_BINARIES)
	@echo "  guest binaries → $(GUEST_DIR)"

$(GUEST_DIR):
	@mkdir -p $(GUEST_DIR)

# A missing SDK has to be caught before the first rule runs a compiler with an
# empty -isysroot, which fails with a wall of missing-header errors that say
# nothing about the real cause.
$(GUEST_BINARIES): | sdk_check $(GUEST_DIR)

.PHONY: sdk_check
sdk_check:
	@test -n "$(IOS_SDK)" -a -n "$(IOS_CC)" || ( \
		echo "Error: no iPhoneOS SDK. These are the guest binaries that ship" >&2; \
		echo "       inside the .app, so they are cross-compiled at build time" >&2; \
		echo "       and the build machine needs Xcode. Install it, then:" >&2; \
		echo "         sudo xcode-select -s /Applications/Xcode.app" >&2; \
		exit 1)

# TweakLoader — the substrate-style loader injected into guest processes. Fat:
# arm64 for the older bases, arm64e for iOS 27. No -install_name; the installer
# places it at a path the injected LC_LOAD_DYLIB already names.
$(GUEST_DIR)/TweakLoader.dylib: scripts/tweakloader/TweakLoader.m
	@echo "=== Building TweakLoader.dylib (arm64 + arm64e, iphoneos) ==="
	@$(IOS_CC) $(IOS_CFLAGS) -arch arm64 -arch arm64e -O3 \
		-dynamiclib -framework Foundation \
		-o $@ $<

# vpregister — registers JB app bundles through the containerized LaunchServices
# API on iOS 27, where `uicache -a` is a deprecated no-op stub. arm64e only:
# it runs on 27 or not at all. `-undefined dynamic_lookup` because the private
# LaunchServices symbols it calls are resolved by the guest's dyld.
$(GUEST_DIR)/vpregister: scripts/vpregister/vpregister.m
	@echo "=== Building vpregister (arm64e, iphoneos) ==="
	@$(IOS_CC) $(IOS_CFLAGS) -arch arm64e -Os \
		-framework Foundation -Wl,-undefined,dynamic_lookup \
		-o $@ $<

# libvcamcaptured — loaded into /usr/libexec/cameracaptured via an injected
# LC_LOAD_DYLIB, so the -install_name has to be the guest path exactly.
$(GUEST_DIR)/libvcamcaptured.dylib: scripts/vcamcaptured/libvcamcaptured.m
	@echo "=== Building libvcamcaptured.dylib (arm64e, iphoneos) ==="
	@$(IOS_CC) $(IOS_CFLAGS) -arch arm64e -Os \
		-dynamiclib -install_name /var/jb/usr/lib/libvcamcaptured.dylib \
		-framework Foundation -framework CoreMedia -framework CoreVideo \
		-o $@ $<

# libcamfix — the substrate plugin TweakLoader loads into every AVFoundation
# client. Same rule about -install_name.
$(GUEST_DIR)/libcamfix.dylib: scripts/camfix/libcamfix.m
	@echo "=== Building libcamfix.dylib (arm64e, iphoneos) ==="
	@$(IOS_CC) $(IOS_CFLAGS) -arch arm64e -Os \
		-dynamiclib \
		-install_name /var/jb/Library/MobileSubstrate/DynamicLibraries/libcamfix.dylib \
		-framework AVFoundation -framework CoreImage -framework CoreGraphics \
		-framework CoreMedia -framework CoreVideo -framework Foundation \
		-framework ImageIO -framework IOSurface -framework MobileCoreServices \
		-framework Photos -framework QuartzCore -framework UIKit \
		-o $@ $<

# vphoned keeps its own Makefile — it is a multi-file target with a vendored
# libarchive and a commit hash stamped in, and duplicating that here would be
# two places to get it wrong. This rule only puts the result where the others
# are. It used to be compiled a THIRD time, by FirmwarePatcher's buildVphoned(),
# from sources shipped in the .app; that call is gone and the binary staged here
# is what `cfw install` now deploys.
$(GUEST_DIR)/vphoned: $(wildcard scripts/vphoned/*.m) $(wildcard scripts/vphoned/*.h)
	@$(MAKE) --no-print-directory -C scripts/vphoned GIT_HASH=$(GIT_HASH)
	@cp -f scripts/vphoned/vphoned $@

guest_binaries_clean:
	@rm -rf $(GUEST_DIR)
	@$(MAKE) --no-print-directory -C scripts/vphoned clean
