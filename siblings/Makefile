# Sibling guest components. The four source components compile with the iPhoneOS SDK.
# The GPU item is provenance only: fw prepare extracts the actual Apple bundle.

OUT := $(abspath ../.build/siblings)
STAGE := $(OUT)/stage
ARCHIVE := $(OUT)/siblings.tar
CLANG := xcrun --sdk iphoneos clang
COMMON_FLAGS := -arch arm64e -miphoneos-version-min=26.0 -Os -fobjc-arc

CAMFIX := $(STAGE)/camfix/libcamfix.dylib
VCAMCAPTURED := $(STAGE)/vcamcaptured/libvcamcaptured.dylib
TWEAKLOADER := $(STAGE)/tweakloader/TweakLoader.dylib
VPREGISTER := $(STAGE)/vpregister/vpregister
ARTIFACTS := $(CAMFIX) $(VCAMCAPTURED) $(TWEAKLOADER) $(VPREGISTER)
PLISTS := $(STAGE)/camfix/libcamfix.plist $(STAGE)/vcamcaptured/libvcamcaptured.plist
GPU_PROVENANCE := $(STAGE)/gpu/README.md

.PHONY: all package clean

all: $(ARTIFACTS) $(PLISTS) $(GPU_PROVENANCE)

package: all
	@rm -f $(ARCHIVE)
	@/usr/bin/tar -cf $(ARCHIVE) -C $(STAGE) camfix vcamcaptured tweakloader vpregister gpu
	@echo "Packaged $(ARCHIVE)"

$(STAGE)/camfix $(STAGE)/vcamcaptured $(STAGE)/tweakloader $(STAGE)/vpregister $(STAGE)/gpu:
	@mkdir -p $@

$(CAMFIX): camfix/libcamfix.m | $(STAGE)/camfix
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name /var/jb/usr/lib/libcamfix.dylib \
		-o $@ $< \
		-framework Foundation -framework AVFoundation -framework ImageIO \
		-framework IOSurface -framework CoreMedia -framework CoreVideo \
		-framework CoreGraphics -framework QuartzCore
	@codesign --force --sign - $@

$(VCAMCAPTURED): vcamcaptured/libvcamcaptured.m | $(STAGE)/vcamcaptured
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name /var/jb/usr/lib/libvcamcaptured.dylib \
		-o $@ $< \
		-framework Foundation -framework CoreMedia -framework CoreVideo
	@codesign --force --sign - $@

$(TWEAKLOADER): tweakloader/TweakLoader.m | $(STAGE)/tweakloader
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name /var/jb/usr/lib/TweakLoader.dylib \
		-o $@ $< -framework Foundation
	@codesign --force --sign - $@

$(VPREGISTER): vpregister/vpregister.m | $(STAGE)/vpregister
	$(CLANG) $(COMMON_FLAGS) -o $@ $< -framework Foundation
	@codesign --force --sign - $@

$(STAGE)/camfix/libcamfix.plist: camfix/libcamfix.plist | $(STAGE)/camfix
	@cp $< $@

$(STAGE)/vcamcaptured/libvcamcaptured.plist: vcamcaptured/libvcamcaptured.plist | $(STAGE)/vcamcaptured
	@cp $< $@

$(GPU_PROVENANCE): gpu/README.md | $(STAGE)/gpu
	@cp $< $@

clean:
	@rm -rf $(OUT)
