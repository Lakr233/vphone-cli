# Sibling guest components compile with the iPhoneOS SDK.
# The GPU driver comes from firmware; its compiler plugin is built here.

OUT := $(abspath ../.build/siblings)
STAGE := $(OUT)/stage
ARCHIVE := $(OUT)/siblings.tar
CLANG := xcrun --sdk iphoneos clang
GUEST_C_FLAGS := -arch arm64e -miphoneos-version-min=26.0 -Os
COMMON_FLAGS := $(GUEST_C_FLAGS) -fobjc-arc

CAMFIX := $(STAGE)/camfix/libcamfix.dylib
VCAMCAPTURED := $(STAGE)/vcamcaptured/libvcamcaptured.dylib
VCAMCAPTURED_SOURCES := VCamCaptured/libvcamcaptured.m \
	VCamCaptured/VCamImageResolution.inc \
	VCamCaptured/VCamSourceInstallation.inc \
	VCamCaptured/VCamCaptureObservation.inc \
	VCamCaptured/VCamSyntheticDevice.inc \
	VCamCaptured/VCamSyntheticStreams.inc \
	VCamCaptured/VCamViewfinderHooks.inc \
	VCamCaptured/VCamSessionHooks.inc \
	VCamCaptured/VCamStillSink.inc \
	VCamCaptured/VCamFrameReceiver.inc \
	VCamCaptured/VCamFrameProtocol.h
LAUNCHHOOK := $(STAGE)/launchhook/launchdhook-vphone.dylib
SYSTEMHOOK := $(STAGE)/systemhook/SystemHook-vphone.dylib
GPU_PLUGIN := $(STAGE)/gpu/libAppleParavirtCompilerPluginIOGPUFamily.dylib
ARTIFACTS := $(CAMFIX) $(VCAMCAPTURED) $(LAUNCHHOOK) $(SYSTEMHOOK) $(GPU_PLUGIN)
PLISTS := $(STAGE)/camfix/libcamfix.plist $(STAGE)/vcamcaptured/libvcamcaptured.plist
GPU_PROVENANCE := $(STAGE)/gpu/README.md

.PHONY: all gpu package clean

all: $(ARTIFACTS) $(PLISTS) $(GPU_PROVENANCE)

gpu: $(GPU_PLUGIN)

package: all
	@rm -f $(ARCHIVE)
	@/usr/bin/tar -cf $(ARCHIVE) -C $(STAGE) camfix vcamcaptured launchhook systemhook gpu
	@echo "Packaged $(ARCHIVE)"

$(STAGE)/camfix $(STAGE)/vcamcaptured $(STAGE)/launchhook $(STAGE)/systemhook $(STAGE)/gpu:
	@mkdir -p $@

$(CAMFIX): CamFix/libcamfix.m VCamCaptured/VCamFrameProtocol.h | $(STAGE)/camfix
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name @rpath/libcamfix.dylib \
		-o $@ $< \
		-framework Foundation -framework AVFoundation -framework ImageIO \
		-framework IOSurface -framework CoreMedia -framework CoreVideo \
		-framework CoreGraphics -framework QuartzCore
	@codesign --force --sign - $@

$(VCAMCAPTURED): $(VCAMCAPTURED_SOURCES) | $(STAGE)/vcamcaptured
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name @rpath/libvcamcaptured.dylib \
		-o $@ $< \
		-framework Foundation -framework CoreMedia -framework CoreVideo
	@codesign --force --sign - $@

$(LAUNCHHOOK): LaunchHook/launchdhook-vphone.c | $(STAGE)/launchhook
	$(CLANG) $(GUEST_C_FLAGS) -dynamiclib \
		-install_name /usr/lib/launchdhook-vphone.dylib \
		-o $@ $< -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(SYSTEMHOOK): SystemHook/SystemHook-vphone.c | $(STAGE)/systemhook
	$(CLANG) $(GUEST_C_FLAGS) -dynamiclib \
		-install_name /usr/lib/SystemHook-vphone.dylib \
		-o $@ $<
	@codesign --force --sign - $@

$(GPU_PLUGIN): GraphicLoader/main.mm | $(STAGE)/gpu
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

$(GPU_PROVENANCE): GraphicLoader/README.md | $(STAGE)/gpu
	@cp $< $@

clean:
	@rm -rf $(OUT)
