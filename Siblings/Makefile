# Sibling guest components compile with the iPhoneOS SDK.
# The GPU driver comes from firmware; its compiler plugin is built here.

OUT := $(abspath ../.build/siblings)
STAGE := $(OUT)/stage
ARCHIVE := $(OUT)/siblings.tar
CLANG := xcrun --sdk iphoneos clang
COMMON_FLAGS := -arch arm64e -miphoneos-version-min=26.0 -Os -fobjc-arc

CAMFIX := $(STAGE)/camfix/libcamfix.dylib
VCAMCAPTURED := $(STAGE)/vcamcaptured/libvcamcaptured.dylib
TWEAKLOADER := $(STAGE)/tweakloader/TweakLoader.dylib
VPREGISTER := $(STAGE)/vpregister/vpregister
GPU_PLUGIN := $(STAGE)/gpu/libAppleParavirtCompilerPluginIOGPUFamily.dylib
ARTIFACTS := $(CAMFIX) $(VCAMCAPTURED) $(TWEAKLOADER) $(VPREGISTER) $(GPU_PLUGIN)
PLISTS := $(STAGE)/camfix/libcamfix.plist $(STAGE)/vcamcaptured/libvcamcaptured.plist
GPU_PROVENANCE := $(STAGE)/gpu/README.md

.PHONY: all gpu package clean

all: $(ARTIFACTS) $(PLISTS) $(GPU_PROVENANCE)

gpu: $(GPU_PLUGIN)

package: all
	@rm -f $(ARCHIVE)
	@/usr/bin/tar -cf $(ARCHIVE) -C $(STAGE) camfix vcamcaptured tweakloader vpregister gpu
	@echo "Packaged $(ARCHIVE)"

$(STAGE)/camfix $(STAGE)/vcamcaptured $(STAGE)/tweakloader $(STAGE)/vpregister $(STAGE)/gpu:
	@mkdir -p $@

$(CAMFIX): CamFix/libcamfix.m | $(STAGE)/camfix
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name /var/jb/usr/lib/libcamfix.dylib \
		-o $@ $< \
		-framework Foundation -framework AVFoundation -framework ImageIO \
		-framework IOSurface -framework CoreMedia -framework CoreVideo \
		-framework CoreGraphics -framework QuartzCore
	@codesign --force --sign - $@

$(VCAMCAPTURED): VCamCaptured/libvcamcaptured.m | $(STAGE)/vcamcaptured
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name /var/jb/usr/lib/libvcamcaptured.dylib \
		-o $@ $< \
		-framework Foundation -framework CoreMedia -framework CoreVideo
	@codesign --force --sign - $@

$(TWEAKLOADER): TweakLoader/TweakLoader.m | $(STAGE)/tweakloader
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name /var/jb/usr/lib/TweakLoader.dylib \
		-o $@ $< -framework Foundation
	@codesign --force --sign - $@

$(VPREGISTER): VPRegister/vpregister.m | $(STAGE)/vpregister
	$(CLANG) $(COMMON_FLAGS) -o $@ $< -framework Foundation
	@codesign --force --sign - $@

$(GPU_PLUGIN): gpu/main.mm | $(STAGE)/gpu
	xcrun --sdk iphoneos clang++ -arch arm64e -miphoneos-version-min=26.1 \
		-std=c++17 -O2 -dynamiclib -Wl,-undefined,dynamic_lookup \
		-Wl,-not_for_dyld_shared_cache \
		-install_name /System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle/libAppleParavirtCompilerPluginIOGPUFamily.dylib \
		-o $@ $<
	@codesign --force --sign - $@

$(STAGE)/camfix/libcamfix.plist: CamFix/libcamfix.plist | $(STAGE)/camfix
	@cp $< $@

$(STAGE)/vcamcaptured/libvcamcaptured.plist: VCamCaptured/libvcamcaptured.plist | $(STAGE)/vcamcaptured
	@cp $< $@

$(GPU_PROVENANCE): gpu/README.md | $(STAGE)/gpu
	@cp $< $@

clean:
	@rm -rf $(OUT)
