# Sibling guest components compile with the iPhoneOS SDK.
# The GPU driver comes from firmware; its compiler plugin is built here.

OUT := $(abspath ../.build/siblings)
STAGE := $(OUT)/stage
ARCHIVE := $(OUT)/siblings.tar
CLANG := xcrun --sdk iphoneos clang
MACOS_SDK := $(shell xcrun --sdk macosx --show-sdk-path)
MACH_EXC_DEFS := $(MACOS_SDK)/usr/include/mach/mach_exc.defs
LAUNCHHOOK_GENERATED := $(OUT)/generated/launchhook
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
LAUNCHHOOK_SOURCES := $(wildcard LaunchHook/*.c) Shared/RootHideLoaderLinks.c Shared/VPhoneX1Spawn.c
LAUNCHHOOK_INCLUDES := $(wildcard LaunchHook/*.h LaunchHook/*.inc Shared/*.h)
SYSTEMHOOK := $(STAGE)/systemhook/SystemHook-vphone.dylib
SYSTEMHOOK_SOURCES := $(wildcard SystemHook/*.c) $(wildcard FlutterRemapFix/*.c) Shared/RootHideLoaderLinks.c Shared/VPhoneX1Spawn.c
SYSTEMHOOK_INCLUDES := $(wildcard SystemHook/*.h SystemHook/*.inc FlutterRemapFix/*.h Shared/*.h)
# libmis is not a framework and has no header; the iPhoneOS SDK does ship
# libmis.tbd, so the interposed symbols bind two-level like any other import
# rather than through flat dynamic lookup.
MISFIX := $(STAGE)/misfix/libmisfix.dylib
MISFIX_SOURCES := $(wildcard MISFix/*.c)
MISFIX_INCLUDES := $(wildcard MISFix/*.h)
# CoreHaptics is reached through the ObjC runtime at runtime, so this needs
# nothing but libobjc at link time.
HAPTICSFIX := $(STAGE)/hapticsfix/libhapticsfix.dylib
HAPTICSFIX_SOURCES := $(wildcard HapticsFix/*.c)
HAPTICSFIX_INCLUDES := $(wildcard HapticsFix/*.h)
# IOKit and MobileGestalt for the calls it interposes (notify is in libSystem),
# CoreFoundation for the descriptions it builds.
BATTERYHEALTHFIX := $(STAGE)/batteryhealthfix/libbatteryhealthfix.dylib
BATTERYHEALTHFIX_SOURCES := $(wildcard BatteryHealthFix/*.c)
BATTERYHEALTHFIX_INCLUDES := $(wildcard BatteryHealthFix/*.h)
# CoreDeviceUtilities lives on the developer disk image, not in the SDK, and
# the image is mounted only after the host enables developer services. The two
# interposed Swift getters are weak flat-namespace imports. CoreVideo, IOSurface
# and libobjc are for the avconferenced band reads it waits on the scaler for;
# Foundation and the ObjC runtime are for the CMAngleManager and
# CMDeviceStateManager stand-ins (VPCMAngleManager.m) dtdeviceinfod answers
# the hinge and device motion state streams from.
DEVICEHUBFIX := $(STAGE)/devicehubfix/libdevicehubfix.dylib
DEVICEHUBFIX_SOURCES := $(sort $(wildcard DeviceHubFix/*.c) $(wildcard DeviceHubFix/*.m))
DEVICEHUBFIX_INCLUDES := $(wildcard DeviceHubFix/*.h)
DEVICEHUBFIX_DYNAMIC_LOOKUP_SYMS := \
	'-Wl,-U,_$$s19CoreDeviceUtilities28MediaStreamSupportedFeaturesV7currentACvgZ' \
	'-Wl,-U,_$$s19CoreDeviceUtilities07CurrentB0V20isCustomerRestrictedSbvg'
# SystemConfiguration for the imports it interposes in configd and lockdownd
# (its iOS headers mark them unavailable, so the source declares them), IOKit
# for the NVRAM read. The policy beside it is pure CoreFoundation, so the host
# tests build it too.
DEVICENAME := $(STAGE)/devicename/libdevicename.dylib
DEVICENAME_SOURCES := $(wildcard DeviceName/*.c)
DEVICENAME_INCLUDES := $(wildcard DeviceName/*.h)
# Foundation and the ObjC runtime for the Settings follow-up swizzle; CoreFollowUp
# is reached through the runtime at runtime, so it needs nothing at link time.
PREFSFIX := $(STAGE)/prefsfix/libprefsfix.dylib
PREFSFIX_SOURCES := $(wildcard PrefsFix/*.m PrefsFix/*.c)
PREFSFIX_INCLUDES := $(wildcard PrefsFix/*.h)
# Foundation + ObjC runtime for the sign-in presentation swizzles; AppleAccountUI
# etc. are reached through the runtime at runtime, so nothing is needed at link.
SIGNINFIX := $(STAGE)/signinfix/libsigninfix.dylib
SIGNINFIX_SOURCES := $(wildcard SignInFix/*.m SignInFix/*.c)
SIGNINFIX_INCLUDES := $(wildcard SignInFix/*.h)
GYROSCOPE := $(STAGE)/gyroscope/libvphonegyro.dylib
GYROSCOPE_SOURCES := $(call find_sources,Gyroscope)
GYROSCOPE_INPUTS := $(call find_headers,Gyroscope) $(call find_folders,Gyroscope)
ACCELEROMETER := $(STAGE)/accelerometer/libvphoneaccelerometer.dylib
ACCELEROMETER_SOURCES := $(call find_sources,Accelerometer)
ACCELEROMETER_INPUTS := $(call find_headers,Accelerometer) $(call find_folders,Accelerometer)
HINGE := $(STAGE)/hinge/libvphonehinge.dylib
HINGE_SOURCES := $(call find_sources,Hinge)
HINGE_INPUTS := $(call find_headers,Hinge) $(call find_folders,Hinge)
# The SpringBoard guard that lets the foldable product identity survive on a
# single-display guest. See FoldGuard/libvphonefoldguard.m.
FOLDGUARD := $(STAGE)/foldguard/libvphonefoldguard.dylib
FOLDGUARD_SOURCES := $(call find_sources,FoldGuard)
FOLDGUARD_INPUTS := $(call find_headers,FoldGuard) $(call find_folders,FoldGuard)
FOLDDISPLAY := $(STAGE)/folddisplay/libvphonefolddisplay.dylib
FOLDDISPLAY_SOURCES := $(call find_sources,FoldDisplay)
FOLDDISPLAY_INPUTS := $(call find_headers,FoldDisplay) $(call find_folders,FoldDisplay) MISFix/MISFixDetour.h
ATTITUDE := $(STAGE)/attitude/libvphoneattitude.dylib
ATTITUDE_SOURCES := $(call find_sources,Attitude)
ATTITUDE_INPUTS := $(call find_headers,Attitude) $(call find_folders,Attitude) Shared/AttitudeProcess.h
HOMEPODDISPLAY := $(STAGE)/homepoddisplay/libvphonehomepoddisplay.dylib
HOMEPODDISPLAY_SOURCES := $(call find_sources,HomePodDisplay)
HOMEPODDISPLAY_INPUTS := $(call find_headers,HomePodDisplay) $(call find_folders,HomePodDisplay)
CRYPTEXSTAGING := $(STAGE)/cryptexstaging/libvphonecryptexstaging.dylib
CRYPTEXSTAGING_SOURCE := CryptexStagingFix/libvphonecryptexstaging.c
HOMEPODPERSONA := $(STAGE)/homepodpersona/libvphoneinstallpersona.dylib
HOMEPODPERSONA_INPUTS := HomePodInstallPersona/libvphoneinstallpersona.c LaunchHook/InstallCoordinationPersona.h
HOMEPODMISFIX := $(STAGE)/homepodmisfix/libvphonehomepodmisfix.dylib
HOMEPODMISFIX_SOURCES := MISFix/MISFixSignature.c MISFix/MISFixDetour.c MISFix/MISFixConfig.c MISFix/MISFixInstallPolicy.c
HOMEPODMISFIX_INPUTS := $(HOMEPODMISFIX_SOURCES) MISFix/MISFixDetour.h MISFix/MISFixConditionalBranch.h MISFix/MISFixConfig.h
HOMEPODSETUP := $(STAGE)/homepodsetup/vphone-homepod-setup
HOMEPODSETUP_SOURCES := $(call find_sources,HomePodSetup)
HOMEPODSETUP_INPUTS := $(call find_headers,HomePodSetup) HomePodSetup/com.vphone.homepod-setup.plist
TVSETUPFOCUS := $(STAGE)/tvsetupfocus/libvphonetvsetupfocus.dylib
TVSETUPFOCUS_SOURCES := $(call find_sources,TVSetupFocus)
TVSETUPFOCUS_INPUTS := $(call find_headers,TVSetupFocus) $(call find_folders,TVSetupFocus)
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
# The HAL plugin audiomxd loads for the virtio-snd device. AudioServerDriver
# is private and not in the SDK, so its classes link against the stub beside
# the sources. The bundle is flat, as iOS HAL plugins are, and signed whole.
VIRTIOSOUND := $(STAGE)/virtiosound/VPhoneVirtIOSound.driver
VIRTIOSOUND_SOURCES := $(wildcard VirtIOSound/*.m VirtIOSound/*.c)
VIRTIOSOUND_INCLUDES := $(wildcard VirtIOSound/*.h) VirtIOSound/Info.plist VirtIOSound/AudioServerDriver.tbd
ARTIFACTS := $(CAMFIX) $(VCAMCAPTURED) $(LAUNCHHOOK) $(SYSTEMHOOK) $(MISFIX) $(HAPTICSFIX) $(BATTERYHEALTHFIX) $(DEVICEHUBFIX) $(DEVICENAME) $(PREFSFIX) $(SIGNINFIX) $(GYROSCOPE) $(ACCELEROMETER) $(HINGE) $(FOLDGUARD) $(FOLDDISPLAY) $(ATTITUDE) $(HOMEPODDISPLAY) $(CRYPTEXSTAGING) $(HOMEPODPERSONA) $(HOMEPODMISFIX) $(HOMEPODSETUP) $(TVSETUPFOCUS) $(GPU_PLUGIN) $(VIRTIOSOUND)
PLISTS := $(STAGE)/camfix/libcamfix.plist $(STAGE)/vcamcaptured/libvcamcaptured.plist \
	$(STAGE)/misfix/libmisfix.plist
GPU_PROVENANCE := $(STAGE)/gpu/README.md

# Directory timestamps also catch files removed from the wildcard inputs.

.PHONY: all gpu package test-loader-links test-injection-environment test-devicename test-vcam-dataplane test-virtiosound test-x1-lowering clean

all: $(ARTIFACTS) $(PLISTS) $(GPU_PROVENANCE)

.PHONY: test-homepod-display
test-homepod-display:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -DVP_HOMEPOD_DISPLAY_TESTING \
		-o $(OUT)/HomePodDisplayIdentityTests Tests/HomePodDisplayIdentityTests.m $(HOMEPODDISPLAY_SOURCES) -framework Foundation
	@$(OUT)/HomePodDisplayIdentityTests

.PHONY: test-homepod-welcome
test-homepod-welcome:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -IHomePodDisplay \
		-o $(OUT)/HomePodWelcomeStateTests Tests/HomePodWelcomeStateTests.m HomePodDisplay/VPHomePodWelcomeState.m -framework Foundation
	@$(OUT)/HomePodWelcomeStateTests
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -IHomePodDisplay \
		-o $(OUT)/HomePodWelcomeTests Tests/HomePodWelcomeTests.m HomePodDisplay/VPHomePodWelcomeState.m -framework Foundation
	@$(OUT)/HomePodWelcomeTests

.PHONY: test-homepod-siri-speech
test-homepod-siri-speech:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
		-o $(OUT)/HomePodSiriSpeechTests Tests/HomePodSiriSpeechTests.m -framework Foundation
	@$(OUT)/HomePodSiriSpeechTests

.PHONY: test-homepod-sound-glow
test-homepod-sound-glow:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror \
		-o $(OUT)/HomePodSoundGlowTests Tests/HomePodSoundGlowTests.m -framework Foundation
	@$(OUT)/HomePodSoundGlowTests

gpu: $(GPU_PLUGIN)

package: all
	@rm -f $(ARCHIVE)
	@/usr/bin/tar -cf $(ARCHIVE) -C $(STAGE) camfix vcamcaptured launchhook systemhook misfix hapticsfix batteryhealthfix devicehubfix devicename prefsfix signinfix gyroscope accelerometer hinge foldguard attitude homepoddisplay cryptexstaging homepodpersona homepodmisfix homepodsetup tvsetupfocus gpu virtiosound folddisplay
	@echo "Packaged $(ARCHIVE)"

test-loader-links:
	@mkdir -p $(OUT)
	/usr/bin/clang -Wall -Wextra -Werror -o $(OUT)/RootHideLoaderLinksTests \
		Tests/RootHideLoaderLinksTests.c Shared/RootHideLoaderLinks.c
	@$(OUT)/RootHideLoaderLinksTests

test-injection-environment:
	@mkdir -p $(OUT)
	/usr/bin/clang -Wall -Wextra -Werror -Wno-unused-function -Wno-write-strings \
		-DVP_TEST_LIBRARY_DIR='"$(OUT)/injection-libraries"' \
		-o $(OUT)/InjectionEnvironmentTests Tests/InjectionEnvironmentTests.c
	@$(OUT)/InjectionEnvironmentTests

test-x1-lowering:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -Wall -Wextra -Werror -ILaunchHook \
		-o $(OUT)/X1LoweringTests Tests/X1LoweringTests.c LaunchHook/VPhoneX1Lowering.c
	@$(OUT)/X1LoweringTests

# Host proof harness for libdevicename's name decoding, configd publication
# rewrite and lockdownd rename decision.
test-devicename:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -O1 -Wall -Wextra -Werror -IDeviceName \
		-o $(OUT)/DeviceNameTests \
		Tests/DeviceNameTests.c DeviceName/DeviceNamePolicy.c \
		-framework CoreFoundation
	@$(OUT)/DeviceNameTests

# Host proof harness for the virtio-snd format choice, the rings, the input
# reader, the capture's low cut, the clock, the capture rate converter and the
# speaker's reported latency.
test-virtiosound:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -O1 -Wall -Wextra -Werror -IVirtIOSound \
		-o $(OUT)/VirtIOSoundTests \
		Tests/VirtIOSoundTests.c VirtIOSound/VPVirtIOSoundProtocol.c VirtIOSound/VPVirtIOSoundRing.c \
		VirtIOSound/VPVirtIOSoundFilter.c
	@$(OUT)/VirtIOSoundTests
	xcrun --sdk macosx clang -O1 -Wall -Wextra -Werror -IVirtIOSound \
		-o $(OUT)/VirtIOSoundClockTests \
		Tests/VirtIOSoundClockTests.c VirtIOSound/VPVirtIOSoundClock.c
	@$(OUT)/VirtIOSoundClockTests
	xcrun --sdk macosx clang -O1 -Wall -Wextra -Werror -IVirtIOSound \
		-o $(OUT)/VirtIOSoundConverterTests \
		Tests/VirtIOSoundConverterTests.c VirtIOSound/VPVirtIOSoundConverter.c
	@$(OUT)/VirtIOSoundConverterTests
	xcrun --sdk macosx clang -O1 -Wall -Wextra -Werror -IVirtIOSound \
		-o $(OUT)/VirtIOSoundLatencyTests \
		Tests/VirtIOSoundLatencyTests.c VirtIOSound/VPVirtIOSoundLatency.c
	@$(OUT)/VirtIOSoundLatencyTests

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

$(STAGE)/camfix $(STAGE)/vcamcaptured $(STAGE)/launchhook $(STAGE)/systemhook $(STAGE)/misfix $(STAGE)/hapticsfix $(STAGE)/batteryhealthfix $(STAGE)/devicehubfix $(STAGE)/devicename $(STAGE)/prefsfix $(STAGE)/signinfix $(STAGE)/gyroscope $(STAGE)/accelerometer $(STAGE)/hinge $(STAGE)/foldguard $(STAGE)/folddisplay $(STAGE)/attitude $(STAGE)/gpu $(STAGE)/virtiosound:
	@mkdir -p $@

$(CAMFIX): $(CAMFIX_SOURCES) $(CAMFIX_INPUTS) | $(STAGE)/camfix
	$(CLANG) $(COMMON_FLAGS) $(CAMFIX_INCLUDE_FLAGS) -dynamiclib \
		-install_name @rpath/libcamfix.dylib \
		-o $@ $(CAMFIX_SOURCES) \
		-framework Foundation -framework AVFoundation -framework ImageIO \
		-framework IOSurface -framework CoreMedia -framework CoreVideo \
		-framework CoreGraphics -framework QuartzCore -framework Accelerate
	@codesign --force --sign - $@

$(VCAMCAPTURED): $(VCAMCAPTURED_SOURCES) $(VCAMCAPTURED_INPUTS) | $(STAGE)/vcamcaptured
	$(CLANG) $(COMMON_FLAGS) $(VCAMCAPTURED_INCLUDE_FLAGS) -dynamiclib \
		-install_name @rpath/libvcamcaptured.dylib \
		-o $@ $(VCAMCAPTURED_SOURCES) \
		-framework Foundation -framework CoreMedia -framework CoreVideo \
		-framework CoreGraphics
	@codesign --force --sign - $@

$(LAUNCHHOOK): $(LAUNCHHOOK_SOURCES) $(LAUNCHHOOK_INCLUDES) LaunchHook Shared $(MACH_EXC_DEFS) | $(STAGE)/launchhook
	@mkdir -p $(LAUNCHHOOK_GENERATED)
	xcrun --sdk macosx mig -arch arm64 -isysroot $(MACOS_SDK) \
		-server $(LAUNCHHOOK_GENERATED)/mach_excServer.c \
		-sheader $(LAUNCHHOOK_GENERATED)/mach_excServer.h \
		-user $(LAUNCHHOOK_GENERATED)/mach_excUser.c \
		-header $(LAUNCHHOOK_GENERATED)/mach_exc.h $(MACH_EXC_DEFS)
	/usr/bin/sed -i '' 's/msg_result = mach_msg(/msg_result = vp_mach_msg_kobject(/g' \
		$(LAUNCHHOOK_GENERATED)/mach_excUser.c
	@/usr/bin/grep -q 'msg_result = vp_mach_msg_kobject(' $(LAUNCHHOOK_GENERATED)/mach_excUser.c
	@! /usr/bin/grep -q 'msg_result = mach_msg(' $(LAUNCHHOOK_GENERATED)/mach_excUser.c
	$(CLANG) $(GUEST_C_FLAGS) -dynamiclib \
		-I$(LAUNCHHOOK_GENERATED) -ILaunchHook -include VPhoneMachMessage.h \
		-install_name /usr/lib/launchdhook-vphone.dylib \
		-o $@ $(LAUNCHHOOK_SOURCES) $(LAUNCHHOOK_GENERATED)/mach_excServer.c \
		$(LAUNCHHOOK_GENERATED)/mach_excUser.c -Wl,-not_for_dyld_shared_cache
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
		-framework CoreFoundation -lmis -lMobileGestalt -lobjc \
		-Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(HAPTICSFIX): $(HAPTICSFIX_SOURCES) $(HAPTICSFIX_INCLUDES) HapticsFix | $(STAGE)/hapticsfix
	$(CLANG) $(GUEST_C_FLAGS) -dynamiclib \
		-install_name /usr/lib/libhapticsfix.dylib \
		-o $@ $(HAPTICSFIX_SOURCES) -lobjc \
		-Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(BATTERYHEALTHFIX): $(BATTERYHEALTHFIX_SOURCES) $(BATTERYHEALTHFIX_INCLUDES) BatteryHealthFix | $(STAGE)/batteryhealthfix
	$(CLANG) $(GUEST_C_FLAGS) -dynamiclib \
		-install_name /usr/lib/libbatteryhealthfix.dylib \
		-o $@ $(BATTERYHEALTHFIX_SOURCES) \
		-framework CoreFoundation -framework IOKit -lMobileGestalt \
		-Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(DEVICEHUBFIX): $(DEVICEHUBFIX_SOURCES) $(DEVICEHUBFIX_INCLUDES) DeviceHubFix | $(STAGE)/devicehubfix
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name /usr/lib/libdevicehubfix.dylib \
		-o $@ $(DEVICEHUBFIX_SOURCES) $(DEVICEHUBFIX_DYNAMIC_LOOKUP_SYMS) \
		-framework Foundation -framework CoreVideo -framework IOSurface -lMobileGestalt \
		-Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(DEVICENAME): $(DEVICENAME_SOURCES) $(DEVICENAME_INCLUDES) DeviceName | $(STAGE)/devicename
	$(CLANG) $(GUEST_C_FLAGS) -Wall -Wextra -Werror -dynamiclib \
		-install_name /usr/lib/libdevicename.dylib \
		-o $@ $(DEVICENAME_SOURCES) \
		-framework CoreFoundation -framework SystemConfiguration \
		-Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(PREFSFIX): $(PREFSFIX_SOURCES) $(PREFSFIX_INCLUDES) PrefsFix | $(STAGE)/prefsfix
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name /usr/lib/libprefsfix.dylib \
		-o $@ $(PREFSFIX_SOURCES) \
		-framework Foundation -lobjc \
		-Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(SIGNINFIX): $(SIGNINFIX_SOURCES) $(SIGNINFIX_INCLUDES) SignInFix | $(STAGE)/signinfix
	$(CLANG) $(COMMON_FLAGS) -dynamiclib \
		-install_name /usr/lib/libsigninfix.dylib \
		-o $@ $(SIGNINFIX_SOURCES) \
		-framework Foundation -lobjc \
		-Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(GYROSCOPE): $(GYROSCOPE_SOURCES) $(GYROSCOPE_INPUTS) | $(STAGE)/gyroscope
	$(CLANG) -arch arm64e -miphoneos-version-min=18.0 -Os -fobjc-arc \
		-Wall -Wextra -Werror -Wno-unused-parameter -dynamiclib \
		-install_name /usr/lib/libvphonegyro.dylib -o $@ $(GYROSCOPE_SOURCES) \
		-framework Foundation -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(ACCELEROMETER): $(ACCELEROMETER_SOURCES) $(ACCELEROMETER_INPUTS) | $(STAGE)/accelerometer
	$(CLANG) -arch arm64e -miphoneos-version-min=18.0 -Os -fobjc-arc \
		-Wall -Wextra -Werror -Wno-unused-parameter -dynamiclib \
		-install_name /usr/lib/libvphoneaccelerometer.dylib -o $@ $(ACCELEROMETER_SOURCES) \
		-framework Foundation -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(HINGE): $(HINGE_SOURCES) $(HINGE_INPUTS) | $(STAGE)/hinge
	$(CLANG) -arch arm64e -miphoneos-version-min=18.0 -Os -fobjc-arc \
		-Wall -Wextra -Werror -Wno-unused-parameter -dynamiclib \
		-install_name /usr/lib/libvphonehinge.dylib -o $@ $(HINGE_SOURCES) \
		-framework Foundation -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(FOLDGUARD): $(FOLDGUARD_SOURCES) $(FOLDGUARD_INPUTS) | $(STAGE)/foldguard
	$(CLANG) $(COMMON_FLAGS) -Wall -Wextra -Werror -Wno-unused-parameter -dynamiclib \
		-install_name /usr/lib/libvphonefoldguard.dylib -o $@ $(FOLDGUARD_SOURCES) \
		-framework Foundation -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(FOLDDISPLAY): $(FOLDDISPLAY_SOURCES) $(FOLDDISPLAY_INPUTS) | $(STAGE)/folddisplay
	$(CLANG) $(COMMON_FLAGS) -Wall -Wextra -Werror -Wno-unused-parameter -dynamiclib \
		-install_name /usr/lib/libvphonefolddisplay.dylib -o $@ $(FOLDDISPLAY_SOURCES) \
		-framework Foundation -framework CoreGraphics -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

.PHONY: test-gyroscope test-accelerometer test-hinge
test-accelerometer:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -IAccelerometer \
		-o $(OUT)/AccelerometerTests Tests/AccelerometerTests.m Accelerometer/VPhoneOrientationSink.m -framework Foundation
	@$(OUT)/AccelerometerTests

# The hinge's transport and, on a Mac whose IOKit has them, the host-control
# dictionaries serialized, read back and wrapped in a vendor-defined event as
# the guest library does.
test-hinge:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -IHinge \
		-o $(OUT)/HingeTests Tests/HingeTests.m -framework Foundation
	@$(OUT)/HingeTests

$(ATTITUDE): $(ATTITUDE_SOURCES) $(ATTITUDE_INPUTS) | $(STAGE)/attitude
	$(CLANG) -arch arm64e -miphoneos-version-min=18.0 -Os -fobjc-arc \
		-Wall -Wextra -Werror -Wno-unused-parameter -dynamiclib \
		-install_name /usr/lib/libvphoneattitude.dylib -o $@ $(ATTITUDE_SOURCES) \
		-framework Foundation -framework CoreMotion -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(HOMEPODDISPLAY): $(HOMEPODDISPLAY_SOURCES) $(HOMEPODDISPLAY_INPUTS)
	@mkdir -p $(STAGE)/homepoddisplay
	xcrun --sdk appletvos clang -arch arm64e -mtvos-version-min=27.0 -Os -fobjc-arc \
		-Wall -Wextra -Werror -dynamiclib -install_name /usr/lib/libvphonehomepoddisplay.dylib \
		-o $@ $(HOMEPODDISPLAY_SOURCES) -framework Foundation -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(HOMEPODMISFIX): $(HOMEPODMISFIX_INPUTS)
	@mkdir -p $(STAGE)/homepodmisfix
	xcrun --sdk appletvos clang -arch arm64e -mtvos-version-min=27.0 -Os -dynamiclib \
		-install_name /usr/lib/libvphonehomepodmisfix.dylib \
		-DVPHONE_MIS_SIGNATURE_ONLY=1 -o $@ $(HOMEPODMISFIX_SOURCES) -framework CoreFoundation -lmis -lobjc \
		-Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(HOMEPODPERSONA): $(HOMEPODPERSONA_INPUTS)
	@mkdir -p $(STAGE)/homepodpersona
	xcrun --sdk appletvos clang -arch arm64e -mtvos-version-min=27.0 -Os \
		-Wall -Wextra -Werror -Wno-unused-parameter -dynamiclib \
		-install_name /usr/lib/libvphoneinstallpersona.dylib \
		-o $@ $< -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(CRYPTEXSTAGING): $(CRYPTEXSTAGING_SOURCE)
	@mkdir -p $(STAGE)/cryptexstaging
	xcrun --sdk appletvos clang -arch arm64e -mtvos-version-min=27.0 -Os \
		-Wall -Wextra -Werror -Wno-unused-parameter -dynamiclib \
		-install_name /usr/lib/libvphonecryptexstaging.dylib \
		-o $@ $< -framework CoreFoundation -lcryptex_core -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

.PHONY: test-cryptex-staging
test-cryptex-staging:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -arch arm64 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
		-o $(OUT)/CryptexStagingTests Tests/CryptexStagingTests.c -framework CoreFoundation
	@$(OUT)/CryptexStagingTests

$(TVSETUPFOCUS): $(TVSETUPFOCUS_SOURCES) $(TVSETUPFOCUS_INPUTS)
	@mkdir -p $(STAGE)/tvsetupfocus
	xcrun --sdk appletvos clang -arch arm64e -mtvos-version-min=27.2 -Os -fobjc-arc \
		-Wall -Wextra -Werror -dynamiclib -install_name /usr/lib/libvphonetvsetupfocus.dylib \
		-o $@ $(TVSETUPFOCUS_SOURCES) -framework UIKit -framework Foundation -Wl,-not_for_dyld_shared_cache
	@codesign --force --sign - $@

$(HOMEPODSETUP): $(HOMEPODSETUP_SOURCES) $(HOMEPODSETUP_INPUTS)
	@mkdir -p $(STAGE)/homepodsetup
	xcrun --sdk appletvos clang -arch arm64e -mtvos-version-min=27.0 -Os -fobjc-arc \
		-Wall -Wextra -Werror -o $@ $(HOMEPODSETUP_SOURCES) -framework Foundation
	@cp HomePodSetup/com.vphone.homepod-setup.plist $(STAGE)/homepodsetup/
	@codesign --force --sign - $@

.PHONY: test-homepod-setup
test-homepod-setup:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -IHomePodSetup \
		-o $(OUT)/HomePodSetupTests Tests/HomePodSetupTests.m HomePodSetup/HomePodSetupState.m -framework Foundation
	@$(OUT)/HomePodSetupTests
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -IHomePodSetup \
		-o $(OUT)/HomePodSetupProcessTests Tests/HomePodSetupProcessTests.m HomePodSetup/HomePodSetupProcesses.m -framework Foundation
	@$(OUT)/HomePodSetupProcessTests
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -IHomePodSetup \
		-o $(OUT)/HomePodAirPlayTests Tests/HomePodAirPlayTests.m HomePodSetup/HomePodSetupState.m HomePodSetup/HomePodSetupProcesses.m -framework Foundation
	@$(OUT)/HomePodAirPlayTests

.PHONY: test-attitude
test-attitude:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -IAttitude \
		-o $(OUT)/AttitudeTests Tests/AttitudeTests.m Attitude/VPhoneAttitudeSample.m \
		-framework Foundation -framework CoreMotion
	@$(OUT)/AttitudeTests
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -IAttitude \
		-DVP_ATTITUDE_NOTIFICATION='"com.vphone.motion.attitude.host-test"' \
		-o $(OUT)/AttitudeHookTests Tests/AttitudeHookTests.m $(ATTITUDE_SOURCES) \
		-framework Foundation -framework CoreMotion
	@$(OUT)/AttitudeHookTests
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -IAttitude \
		-DVP_ATTITUDE_NOTIFICATION='"com.vphone.motion.attitude.lock-order-test"' \
		-o $(OUT)/AttitudeLockOrderTests Tests/AttitudeLockOrderTests.m $(ATTITUDE_SOURCES) \
		-framework Foundation -framework CoreMotion
	@$(OUT)/AttitudeLockOrderTests
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -IAttitude \
		-DVP_ATTITUDE_NOTIFICATION='"com.vphone.motion.attitude.lifecycle-test"' \
		-DVP_ATTITUDE_MANAGER_CLASS='"VPhoneTestMotionManager"' \
		-o $(OUT)/AttitudeLifecycleTests Tests/AttitudeLifecycleTests.m $(ATTITUDE_SOURCES) \
		-framework Foundation -framework CoreMotion
	@$(OUT)/AttitudeLifecycleTests
	@mkdir -p $(OUT)/attitude-scope/System/Library/CoreServices/SpringBoard.app
	@cp $(OUT)/AttitudeLifecycleTests $(OUT)/attitude-scope/System/Library/CoreServices/SpringBoard.app/SpringBoard
	@$(OUT)/attitude-scope/System/Library/CoreServices/SpringBoard.app/SpringBoard

test-gyroscope:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -fobjc-arc -Wall -Wextra -Werror -IGyroscope \
		-o $(OUT)/GyroscopeTests Tests/GyroscopeTests.m -framework Foundation
	@$(OUT)/GyroscopeTests

$(STAGE)/misfix/libmisfix.plist: MISFix/libmisfix.plist | $(STAGE)/misfix
	@cp $< $@

$(GPU_PLUGIN): $(GPU_PLUGIN_SOURCES) $(GPU_PLUGIN_INCLUDES) GraphicLoader | $(STAGE)/gpu
	xcrun --sdk iphoneos clang++ -arch arm64e -miphoneos-version-min=26.1 \
		-std=c++17 -O2 -dynamiclib $(GPU_DYNAMIC_LOOKUP_SYMS) \
		-Wl,-not_for_dyld_shared_cache \
		-install_name /System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle/libAppleParavirtCompilerPluginIOGPUFamily.dylib \
		-o $@ $(GPU_PLUGIN_SOURCES)
	@codesign --force --sign - $@

$(VIRTIOSOUND): $(VIRTIOSOUND_SOURCES) $(VIRTIOSOUND_INCLUDES) VirtIOSound | $(STAGE)/virtiosound
	@rm -rf $@
	@mkdir -p $@
	$(CLANG) $(COMMON_FLAGS) -Wall -Wextra -Werror -fvisibility=hidden -bundle \
		-o $@/VPhoneVirtIOSound $(VIRTIOSOUND_SOURCES) \
		-framework Foundation -framework IOKit \
		VirtIOSound/AudioServerDriver.tbd -Wl,-not_for_dyld_shared_cache
	@cp VirtIOSound/Info.plist $@/Info.plist
	@codesign --force --sign - $@

$(STAGE)/camfix/libcamfix.plist: CamFix/libcamfix.plist | $(STAGE)/camfix
	@cp $< $@

$(STAGE)/vcamcaptured/libvcamcaptured.plist: VCamCaptured/libvcamcaptured.plist | $(STAGE)/vcamcaptured
	@cp $< $@

$(GPU_PROVENANCE): GraphicLoader/README.md | $(STAGE)/gpu
	@cp $< $@

clean:
	@rm -rf $(OUT)

# Host proof harness for the scan that finds cameracaptured's GPU prewarm call.
.PHONY: test-vcam-prewarm
test-vcam-prewarm:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -O1 -Wall -Wextra -Werror -IVCamCaptured/Prewarm \
		-o $(OUT)/VCamPrewarmScanTests \
		Tests/VCamPrewarmScanTests.c VCamCaptured/Prewarm/VCamPrewarmScan.c
	@$(OUT)/VCamPrewarmScanTests

# Host proof harness for the gate that runs cameracaptured's frame drive only
# while a camera client exists.
.PHONY: test-vcam-drive-gate
test-vcam-drive-gate:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -O1 -Wall -Wextra -Werror -IVCamCaptured/Frames \
		-o $(OUT)/VCamDriveGateTests \
		Tests/VCamDriveGateTests.c VCamCaptured/Frames/VCamDriveGate.c
	@$(OUT)/VCamDriveGateTests

# Host proof harness for camera-session weak registration during teardown.
.PHONY: test-camfix-session-reference
test-camfix-session-reference:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -fobjc-arc -O1 -Wall -Wextra -Werror \
		-ICamFix/Session -framework Foundation \
		-o $(OUT)/CamFixSessionReferenceTests Tests/CamFixSessionReferenceTests.m
	@$(OUT)/CamFixSessionReferenceTests

.PHONY: build-camfix-session-reproducer
build-camfix-session-reproducer:
	zsh Tests/CameraSessionReproducer/build.zsh "$(OUT)/camera-session-reproducer"

# Host proof harness for the crop, size and turn plan libcamfix uses for
# AVCaptureVideoDataOutput frames.
.PHONY: test-camfix-geometry
test-camfix-geometry:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -O1 -Wall -Wextra -Werror -ICamFix/Frame \
		-o $(OUT)/CamFixFrameGeometryTests \
		Tests/CamFixFrameGeometryTests.c CamFix/Frame/CamFixFrameGeometry.c
	@$(OUT)/CamFixFrameGeometryTests

.PHONY: test-installcoordination-persona
test-installcoordination-persona:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -arch arm64 -O1 -Wall -Wextra -Werror -Wno-unused-parameter \
		-o $(OUT)/InstallCoordinationPersonaTests Tests/InstallCoordinationPersonaTests.c
	@$(OUT)/InstallCoordinationPersonaTests

.PHONY: test-flutter-remap test-flutter-remap-repair
test-flutter-remap:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -Wall -Wextra -Werror -o $(OUT)/FlutterRemapPolicyTests Tests/FlutterRemapPolicyTests.c
	@$(OUT)/FlutterRemapPolicyTests

test-flutter-remap-repair:
	@mkdir -p $(OUT)
	xcrun --sdk macosx clang -Wall -Wextra -Werror -Wno-unused-function -o $(OUT)/FlutterRemapRepairTests Tests/FlutterRemapRepairTests.c
	@$(OUT)/FlutterRemapRepairTests

.PHONY: build-executable-remap-probe
build-executable-remap-probe:
	@mkdir -p $(OUT)
	xcrun --sdk iphoneos swiftc -target arm64-apple-ios26.0 -O Tests/ExecutableRemapProbe.swift -module-cache-path $(OUT)/probe-module-cache -o $(OUT)/ExecutableRemapProbe
	codesign --force --sign - --timestamp=none $(OUT)/ExecutableRemapProbe
