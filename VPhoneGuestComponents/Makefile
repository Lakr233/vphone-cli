# Sibling guest components compile with the iPhoneOS SDK.
# The GPU driver comes from firmware; its compiler plugin is built here.

OUT := $(abspath ../.build/siblings)
STAGE := $(OUT)/stage
ARCHIVE := $(OUT)/siblings.tar
CLANG := xcrun --sdk iphoneos clang
GUEST_C_FLAGS := -arch arm64e -miphoneos-version-min=26.0 -Os
COMMON_FLAGS := $(GUEST_C_FLAGS) -fobjc-arc

# Sources and headers are discovered under a component's folders at any
# depth, so adding, splitting or nesting files needs no Makefile change.
# The folders themselves are prerequisites too: their timestamps catch
# files removed from the discovered inputs.
find_sources = $(sort $(shell find $(1) -type f \( -name '*.m' -o -name '*.mm' -o -name '*.c' \)))
find_headers = $(sort $(shell find $(1) -type f \( -name '*.h' -o -name '*.hpp' -o -name '*.inc' \)))
find_folders = $(sort $(shell find $(1) -type d))

# Both camera dylibs compile the shared data plane and read the frame
# protocol header, which lives with vcamcaptured. Headers resolve through
# -I, never through relative paths.
VCAM_SHARED_DIRS := VCamDataPlane
VCAM_HEADER_DIRS := VCamDataPlane VCamCaptured

CAMFIX := $(STAGE)/camfix/libcamfix.dylib
CAMFIX_DIRS := CamFix $(VCAM_SHARED_DIRS)
CAMFIX_SOURCES := $(call find_sources,$(CAMFIX_DIRS))
CAMFIX_INPUTS := $(call find_headers,CamFix $(VCAM_HEADER_DIRS)) \
	$(call find_folders,CamFix $(VCAM_HEADER_DIRS))
CAMFIX_INCLUDE_FLAGS := $(addprefix -I,$(call find_folders,CamFix) $(VCAM_HEADER_DIRS))
VCAMCAPTURED := $(STAGE)/vcamcaptured/libvcamcaptured.dylib
VCAMCAPTURED_DIRS := VCamCaptured $(VCAM_SHARED_DIRS)
VCAMCAPTURED_SOURCES := $(call find_sources,$(VCAMCAPTURED_DIRS))
VCAMCAPTURED_INPUTS := $(call find_headers,$(VCAM_HEADER_DIRS)) \
	$(call find_folders,$(VCAM_HEADER_DIRS))
VCAMCAPTURED_INCLUDE_FLAGS := $(addprefix -I,$(call find_folders,VCamCaptured) $(VCAM_SHARED_DIRS))
LAUNCHHOOK := $(STAGE)/launchhook/launchdhook-vphone.dylib
LAUNCHHOOK_SOURCES := $(wildcard LaunchHook/*.c) Shared/RootHideLoaderLinks.c
LAUNCHHOOK_INCLUDES := $(wildcard LaunchHook/*.h LaunchHook/*.inc Shared/*.h)
SYSTEMHOOK := $(STAGE)/systemhook/SystemHook-vphone.dylib
SYSTEMHOOK_SOURCES := $(wildcard SystemHook/*.c) Shared/RootHideLoaderLinks.c
SYSTEMHOOK_INCLUDES := $(wildcard SystemHook/*.h SystemHook/*.inc Shared/*.h)
# libmis is not a framework and has no header; the iPhoneOS SDK does ship
# libmis.tbd, so the interposed symbols bind two-level like any other import
# rather than through flat dynamic lookup.
MISFIX := $(STAGE)/misfix/libmisfix.dylib
MISFIX_SOURCES := $(wildcard MISFix/*.c)
MISFIX_INCLUDES := $(wildcard MISFix/*.h)
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
ARTIFACTS := $(CAMFIX) $(VCAMCAPTURED) $(LAUNCHHOOK) $(SYSTEMHOOK) $(MISFIX) $(GPU_PLUGIN)
PLISTS := $(STAGE)/camfix/libcamfix.plist $(STAGE)/vcamcaptured/libvcamcaptured.plist \
	$(STAGE)/misfix/libmisfix.plist
GPU_PROVENANCE := $(STAGE)/gpu/README.md

# Directory timestamps also catch files removed from the wildcard inputs.

.PHONY: all gpu package test-loader-links test-vcam-dataplane clean

all: $(ARTIFACTS) $(PLISTS) $(GPU_PROVENANCE)

gpu: $(GPU_PLUGIN)

package: all
	@rm -f $(ARCHIVE)
	@/usr/bin/tar -cf $(ARCHIVE) -C $(STAGE) camfix vcamcaptured launchhook systemhook misfix gpu
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
		$(addprefix -I,$(VCAM_SHARED_DIRS)) \
		-o $(OUT)/VCamDataPlaneTests \
		Tests/VCamDataPlaneTests.c $(call find_sources,$(VCAM_SHARED_DIRS)) \
		-framework CoreMedia -framework CoreVideo -framework CoreFoundation \
		-framework CoreGraphics
	@$(OUT)/VCamDataPlaneTests

$(STAGE)/camfix $(STAGE)/vcamcaptured $(STAGE)/launchhook $(STAGE)/systemhook $(STAGE)/misfix $(STAGE)/gpu:
	@mkdir -p $@

$(CAMFIX): $(CAMFIX_SOURCES) $(CAMFIX_INPUTS) | $(STAGE)/camfix
	$(CLANG) $(COMMON_FLAGS) $(CAMFIX_INCLUDE_FLAGS) -dynamiclib \
		-install_name @rpath/libcamfix.dylib \
		-o $@ $(CAMFIX_SOURCES) \
		-framework Foundation -framework AVFoundation -framework ImageIO \
		-framework IOSurface -framework CoreMedia -framework CoreVideo \
		-framework CoreGraphics -framework QuartzCore
	@codesign --force --sign - $@

$(VCAMCAPTURED): $(VCAMCAPTURED_SOURCES) $(VCAMCAPTURED_INPUTS) | $(STAGE)/vcamcaptured
	$(CLANG) $(COMMON_FLAGS) $(VCAMCAPTURED_INCLUDE_FLAGS) -dynamiclib \
		-install_name @rpath/libvcamcaptured.dylib \
		-o $@ $(VCAMCAPTURED_SOURCES) \
		-framework Foundation -framework CoreMedia -framework CoreVideo \
		-framework CoreGraphics
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

$(MISFIX): $(MISFIX_SOURCES) $(MISFIX_INCLUDES) MISFix | $(STAGE)/misfix
	$(CLANG) $(GUEST_C_FLAGS) -dynamiclib \
		-install_name /usr/lib/libmisfix.dylib \
		-o $@ $(MISFIX_SOURCES) \
		-framework CoreFoundation -lmis -lMobileGestalt \
		-Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(STAGE)/misfix/libmisfix.plist: MISFix/libmisfix.plist | $(STAGE)/misfix
	@cp $< $@

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
