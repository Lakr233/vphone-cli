# Sibling guest components compile with the iPhoneOS SDK.
# The GPU driver comes from firmware; its compiler plugin is built here.

OUT := $(abspath ../.build/siblings)
STAGE := $(OUT)/stage
ARCHIVE := $(OUT)/siblings.tar
CLANG := xcrun --sdk iphoneos clang
GUEST_C_FLAGS := -arch arm64e -miphoneos-version-min=26.0 -Os
COMMON_FLAGS := $(GUEST_C_FLAGS) -fobjc-arc

CAMFIX := $(STAGE)/camfix/libcamfix.dylib
CAMFIX_SOURCES := $(wildcard CamFix/*.m)
CAMFIX_INCLUDES := $(wildcard CamFix/*.h CamFix/*.inc VCamCaptured/*.h)
VCAMCAPTURED := $(STAGE)/vcamcaptured/libvcamcaptured.dylib
VCAMCAPTURED_SOURCES := $(wildcard VCamCaptured/*.m)
VCAMCAPTURED_INCLUDES := $(wildcard VCamCaptured/*.h VCamCaptured/*.inc)
LAUNCHHOOK := $(STAGE)/launchhook/launchdhook-vphone.dylib
LAUNCHHOOK_SOURCES := $(wildcard LaunchHook/*.c) Shared/RootHideLoaderLinks.c
LAUNCHHOOK_INCLUDES := $(wildcard LaunchHook/*.h LaunchHook/*.inc Shared/*.h)
SYSTEMHOOK := $(STAGE)/systemhook/SystemHook-vphone.dylib
SYSTEMHOOK_SOURCES := $(wildcard SystemHook/*.c) Shared/RootHideLoaderLinks.c
SYSTEMHOOK_INCLUDES := $(wildcard SystemHook/*.h SystemHook/*.inc Shared/*.h)
GPU_PLUGIN := $(STAGE)/gpu/libAppleParavirtCompilerPluginIOGPUFamily.dylib
GPU_PLUGIN_SOURCES := $(wildcard GraphicLoader/*.mm)
GPU_PLUGIN_INCLUDES := $(wildcard GraphicLoader/*.h GraphicLoader/*.hpp GraphicLoader/*.inc)
# The compiler plugin resolves the guest's libLLVM.dylib and libGPUCompiler.dylib
# entry points at runtime; neither is in the iPhoneOS SDK, so those symbols are
# left for flat dynamic lookup. Naming them individually (`-U`) keeps the link
# import table identical to `-undefined dynamic_lookup` — the C++/libSystem
# symbols still bind two-level — without that flag's iOS deprecation warning.
GPU_DYNAMIC_LOOKUP_SYMS := \
	-Wl,-U,_LLVMDisposeMemoryBuffer \
	-Wl,-U,_LLVMGetBufferStart \
	-Wl,-U,_LLVMGetBufferSize \
	-Wl,-U,_LLVMGetTarget \
	-Wl,-U,_LLVMExtraMakeSharedModule \
	-Wl,-U,_LLVMExtraDisposeSharedModule \
	-Wl,-U,_LLVMGetNamedMetadataNumOperands \
	-Wl,-U,_LLVMGetNamedMetadataOperands \
	-Wl,-U,_LLVMGetMDNodeNumOperands \
	-Wl,-U,_LLVMGetMDNodeOperands \
	-Wl,-U,_LLVMGetValueName2 \
	-Wl,-U,_MTLGPUCompilerCreate \
	-Wl,-U,_MTLGPUCompilerDestroy \
	-Wl,-U,_MTLDowngradeAIRModule \
	-Wl,-U,_MTLMetalLibCreateExecutableWithTriple \
	-Wl,-U,_MTLMetalFunctionCreate \
	-Wl,-U,_MTLMetalLibInsertFunction \
	-Wl,-U,_MTLWriteMetalLibToMemoryBuffer
ARTIFACTS := $(CAMFIX) $(VCAMCAPTURED) $(LAUNCHHOOK) $(SYSTEMHOOK) $(GPU_PLUGIN)
PLISTS := $(STAGE)/camfix/libcamfix.plist $(STAGE)/vcamcaptured/libvcamcaptured.plist
GPU_PROVENANCE := $(STAGE)/gpu/README.md

# Directory timestamps also catch files removed from the wildcard inputs.

.PHONY: all gpu package test-loader-links test-vcam-dataplane clean

all: $(ARTIFACTS) $(PLISTS) $(GPU_PROVENANCE)

gpu: $(GPU_PLUGIN)

package: all
	@rm -f $(ARCHIVE)
	@/usr/bin/tar -cf $(ARCHIVE) -C $(STAGE) camfix vcamcaptured launchhook systemhook gpu
	@echo "Packaged $(ARCHIVE)"

test-loader-links:
	@mkdir -p $(OUT)
	/usr/bin/clang -Wall -Wextra -Werror -o $(OUT)/RootHideLoaderLinksTests \
		Tests/RootHideLoaderLinksTests.c Shared/RootHideLoaderLinks.c
	@$(OUT)/RootHideLoaderLinksTests

# Host proof harness for the camera data plane the guest hooks share.
test-vcam-dataplane:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
		-o $(OUT)/VCamDataPlaneTests \
		Tests/VCamDataPlaneTests.c VCamDataPlane/vcam_dataplane.c \
		-framework CoreMedia -framework CoreVideo -framework CoreFoundation \
		-framework CoreGraphics
	@$(OUT)/VCamDataPlaneTests

$(STAGE)/camfix $(STAGE)/vcamcaptured $(STAGE)/launchhook $(STAGE)/systemhook $(STAGE)/gpu:
	@mkdir -p $@

$(CAMFIX): $(CAMFIX_SOURCES) $(CAMFIX_INCLUDES) CamFix VCamCaptured | $(STAGE)/camfix
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name @rpath/libcamfix.dylib \
		-o $@ $(CAMFIX_SOURCES) \
		-framework Foundation -framework AVFoundation -framework ImageIO \
		-framework IOSurface -framework CoreMedia -framework CoreVideo \
		-framework CoreGraphics -framework QuartzCore
	@codesign --force --sign - $@

$(VCAMCAPTURED): $(VCAMCAPTURED_SOURCES) $(VCAMCAPTURED_INCLUDES) VCamCaptured | $(STAGE)/vcamcaptured
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name @rpath/libvcamcaptured.dylib \
		-o $@ $(VCAMCAPTURED_SOURCES) \
		-framework Foundation -framework CoreMedia -framework CoreVideo
	@codesign --force --sign - $@

$(LAUNCHHOOK): $(LAUNCHHOOK_SOURCES) $(LAUNCHHOOK_INCLUDES) LaunchHook Shared | $(STAGE)/launchhook
	$(CLANG) $(GUEST_C_FLAGS) -dynamiclib \
		-install_name /usr/lib/launchdhook-vphone.dylib \
		-o $@ $(LAUNCHHOOK_SOURCES) -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(SYSTEMHOOK): $(SYSTEMHOOK_SOURCES) $(SYSTEMHOOK_INCLUDES) SystemHook Shared | $(STAGE)/systemhook
	$(CLANG) $(GUEST_C_FLAGS) -dynamiclib \
		-install_name /usr/lib/SystemHook-vphone.dylib \
		-o $@ $(SYSTEMHOOK_SOURCES) -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(GPU_PLUGIN): $(GPU_PLUGIN_SOURCES) $(GPU_PLUGIN_INCLUDES) GraphicLoader | $(STAGE)/gpu
	xcrun --sdk iphoneos clang++ -arch arm64e -miphoneos-version-min=26.1 \
		-std=c++17 -O2 -dynamiclib $(GPU_DYNAMIC_LOOKUP_SYMS) \
		-Wl,-not_for_dyld_shared_cache \
		-install_name /System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle/libAppleParavirtCompilerPluginIOGPUFamily.dylib \
		-o $@ $(GPU_PLUGIN_SOURCES)
	@codesign --force --sign - $@

$(STAGE)/camfix/libcamfix.plist: CamFix/libcamfix.plist | $(STAGE)/camfix
	@cp $< $@

$(STAGE)/vcamcaptured/libvcamcaptured.plist: VCamCaptured/libvcamcaptured.plist | $(STAGE)/vcamcaptured
	@cp $< $@

$(GPU_PROVENANCE): GraphicLoader/README.md | $(STAGE)/gpu
	@cp $< $@

clean:
	@rm -rf $(OUT)
