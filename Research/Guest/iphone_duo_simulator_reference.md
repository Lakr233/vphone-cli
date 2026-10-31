# iPhone Duo: reference values from Apple's simulator

Values from Apple's iPhone Duo simulator (iPhone19,4, V68, iOS 27.1 24A94425,
Xcode 27.1 27A9275) that are worth keeping beside the vphone-duo work. They were
taken out of the baseline records before those records were deleted on
2026-10-30.

- Comparison table, sim against VM, row by row: `Evidence/duo-sim-baseline/BASELINE.md`.
- Per-domain findings: `Evidence/duo-sim-baseline/{display,springboard,sensors,appkit,chrome}.md`.
- Harness, probes and the drivers that made the records:
  `Evidence/duo-sim-baseline/{tools,probes,src}/` (README there).
- What the alignment changed and how to check it: `iphone_duo_bringup.md`, "2026-10-30".

The VM column below is `duobase-01` running bundle 2.14.0-local.9064efca
(branch duo-sim-align, with CoreMotion's VM relay and the panel nodes).

## What was deleted, and how to get it back

The records were about 240,000 calls across five domains. They sat in
`<domain>.json` and `vm-<domain>.json`, 2–63 MB each. Transcripts, posture
JSON and screenshots sat under `raw/`, about 1 GB. None of it was committed.

To regenerate:

1. Clone the harness simulator: `tools/sim.zsh clone`.
2. Run each domain's runner from `probes/` or `src/` (each domain doc names its
   runner).
3. For the VM, run `tools/vm-probe.zsh` with the `src/vm/run-*.zsh` drivers.

Values to ignore when comparing: UUIDs, pointers and seeds change on every boot
(`display.md`, "Volatile fields").

## SpringBoard fold tuning (sim = VM)

All 116 numeric and boolean settings below read the same on the VM as on the
simulator. They are SpringBoard's built-in defaults, so the device type does not
change them. Use them to check behaviour against SpringBoard's own thresholds;
there is nothing to align.

`SBFDevicePoseProvider->_settings` (`SBFDevicePosePTSettings`):

| setting | value |
| --- | --- |
| `openTransitionBeginBoundary` | 5° |
| `closeTransitionBeginBoundary` | 175° |
| `partiallyOpenToOpenFlatBoundary` | 175° |
| `swapDegreesForContinuousLiveStyle` | 85° |
| `swapDegreesForFadeInFadeOutStyle` | 85° |
| `swapDegreesForContinuousSnapshotStyleWhenClosing` | 85° |
| `swapDegreesForContinuousSnapshotStyleWhenOpening` | 20° |
| `likelyToOpenVelocityDegreesPerSecond` | 40 |
| `velocitySmoothingFactor` | 0.15 |
| `transitionAutoCompleteDuration` | 0.35 s |
| `autocompleteMinDelay` / `autocompleteMaxDelay` | 0.15 / 0.75 s |
| `enterFoldAvoidancePredictionWindow` / `sustainFoldAvoidancePredictionWindow` | 0.35 / 0.2625 s |
| `displayPrewarmDuration` | 3 s |
| `continuousFoldTransitionEnabled` | YES |

`[SBDisplayYoinkingPTSettingsDomain rootSettings]`:

- **Thresholds:** `swapThreshold` 0.2, `touchBlockingThreshold` 0.1, `requiresActiveCameraSession` YES, `revealLingerDuration` 6 s.
- **Dimming:** `showsDimmingBackdrop` YES, `dimmingBlurRadius` 200, `dimmingSaturation` 2, `dimmingTintAlphaAtRest` 0.74, `dimmingTintAlphaAtFullTravel` 0.6.
- **Slider:** `sliderTrackWidth` 290, `sliderHeight` 66.67, `sliderCenterBottomInset` 55, `sliderThumbInset` 3.5, `sliderFontSize` 18.25, `sliderSymbolSizeRatio` 0.369, `sliderTitleLeadingAir` 19.7, `sliderTitleTrailingAir` 40.7, `sliderTrackOpacity` 0.1.

`[SBDeviceContinuousFoldInteractionDomain rootSettings]`, without the debug switches and the spring animation objects:

- **Transition:** `appTransitionStyle` 1, `alwaysUsesDirectTracking` YES, `directTrackingThreshold` 0.15, `continuousSnapshotTransitionAvailable` YES, `displayTarget` 0, `maximumFrameRate` 80, `foldWidth` 80, `cylinderWidthRatio` 0.245.
- **Inner:** `innerTiltAmount` 40, `innerPivotOffset` 10, `innerStretchAmount` 1.1, `innerStretchRampExponent` 1, `innerNonlinearScaleExponent` 4, `innerNonlinearScaleIntensity` 0.5, `innerConeTopMaxScale` 1.2, `innerConeBottomMaxScale` 0.4, `innerConeOpacity` 1, `innerCylinderOpacity` 0.644, `innerBlurMaxRadius` 120, `innerCloakFadeThresholdAngle` 15°, `innerDimRampStart` 0.5, `innerFadeToBlackStart` 0.167, `innerFadeToBlackEnd` 0.
- **Outer:** `outerTiltAmount` 20, `outerStretchAmount` 1.1, `outerStretchRampExponent` 1, `outerNonlinearScaleExponent` 4, `outerNonlinearScaleIntensity` 1, `outerConeTopMaxScale` 0.5, `outerConeBottomMaxScale` 0.2, `outerConeOpacity` 1, `outerCylinderOpacity` 0.644, `outerBlurMaxRadius` 50, `outerCloakFadeThresholdAngle` 90°, `outerDimRampEnd` 0.444, `outerFadeToBlackStart` 0.2, `outerFadeToBlackEnd` 0.5.
- **Prolonged dim:** inner active 45°→15°, outer active 90°→120°.
- **Seam dim:** `seamDimThresholdAngle` 135°, `seamDimWidth` 50.45, `seamDimBlurRadius` 6.56, `seamDimMaxOpacity` 0.35, `seamDimLinearMax` 0.3, `seamDimLinearIntensity` 1, `seamDimNonlinearExponent` 2.078, `seamDimNonlinearIntensity` 0.52, `isSeamDimHiddenOnVirtualDevices` YES, `isSeamDimExcludedFromCaptures` YES.
- **Backdrop and morph:** `backdropMinScale` 0.3, `backdropMaxScale` 1, `backdropScaleRadiusLow` 3.333, `backdropScaleRadiusHigh` 16.667, `isAdjustBackdropScaleEnabled` NO, `dimScale` 0.95, `morphMaxBlurRadius` 10, `morphUsesSharedAnimationSettings` YES.
- **Z-stack fades:** in 0.6→0.8, out 0.2→0.4.
- **Orientation lock:** `isOrientationLockSettleEnabled` YES, `orientationLockSettleDuration` 0.35 s.
- **Substitute content:** `substituteContentFillMode` 2, `substituteContentStaticFillColor` 1, `isInstantAppContentHidden` NO.
- **Effect switches:** `isBlurEffectEnabled`, `isConeDimEnabled`, `isCornerMaskEnabled`, `isCylinderDimEnabled`, `isDimmingEnabled`, `isFadeToBlackEnabled`, `isMorphBlurEnabled` and `isPerspectiveTransformEnabled` are all YES.

`isSeamDimHiddenOnVirtualDevices` YES is one of the places where SpringBoard
checks for a virtual device. On the VM, MobileGestalt `IsVirtualDevice` is YES,
so the seam dim stays hidden there.

## MobileGestalt: where the sim answers and the VM differs

SpringBoard asked for 557 keys while open. Compared with the VM, 233 differ:

- **143:** the simulator answers nil, while the VM answers from the real V68
  device tree. Most are camera, AOP, haptics, ALS, AOD vibrancy and display
  rotation keys. These are not alignment targets: the simulator has no such
  hardware.
- **34:** answered from the simulator's device-type plist, or synthetic. The
  baseline marks them with `sim_note` (table below).
- **56:** real disagreements, in the next table.

| key | sim | VM |
| --- | --- | --- |
| **Sim YES, VM NO** (candidates to align) | | |
| `DeviceSupportsAlwaysOnDisplay`, `…Flipbook`, `DeviceSupportsAlwaysOnTime` | YES | NO |
| `DeviceSupportsDCP` | YES | NO |
| `ambient-light-sensor` | YES | NO |
| `DeviceSupportsGenerativeModelSystems`, `generative-model-systems` | YES | NO |
| `DeviceSupportsHandwritingSynthesisModel`, `DeviceSupportsInstructionFollowingPruningModels`, `DeviceSupportsPhotosInpainting` | YES | NO |
| `ExclaveCapability`, `AudioExclaveMicInputCapability` | YES | NO |
| `DeviceSupportsFairPlaySecureVideoPath` | YES | NO |
| `AV1DecodingCapability` | YES | NO |
| `DevicePrefersProceduralAntiAliasing` | YES | NO |
| `ScreenRecorderCapability` | YES | NO |
| **Performance class** | | |
| `PerfLevelCapability` / `MetalPerfLevelCapability` / `ADSCapability` | 2 / 1 / 2 | 0 / 0 / 0 |
| `DeviceSupportsSiriUnderstandingOnDevice` | 3 | 4 |
| `DeviceLaunchTimeLimitScale` / `DeviceSceneUpdateTimeLimitScale` / `FirstPartyLaunchTimeLimitScale` | 0 / 0 / 0 | 1 / 1 / 1 |
| `LaunchTimeLimitScaleSupported` | NO | YES |
| **Identity and finish** | | |
| `HWModelStr`, `HWModelUniqueStr` | `iPhone19,4` | `V68AP` |
| `DeviceEnclosureColor` / `DeviceHousingColor` / `DeviceCoverGlassCoating` | `"1"` / 1 / 1 | `"unknown"` / 0 / 0 |
| `FrontCameraOffsetFromDisplayCenter` | [0, 109.77, 2.26] | [67.013, 7.341, 5.493] |
| **Display rendering** | | |
| `CoastlineGlowRenderingCapability`, `DeviceSupportsHDRPhotoDisplay`, `DeviceSupportsRGB10`, `DeviceSupportsToneMapping`, `RenderWideGamutImagesAtDisplayTime` | NO | YES |
| `IOSurfaceFormatDictionary`: the five `universal-*-buffer-compression` entries | differ | differ |
| **Sim NO, VM YES** (the simulator lacks the hardware) | | |
| Camera and media: `DeviceSupports4k`, `DeviceSupportsCameraHaptics`, `DeviceSupportsLiveVideoRendering`, `DeviceSupportsPortraitLightEffectFilters`, `H264EncoderCapability`, `PhotoCapability`, `ForwardCameraCapability`, `RearFacingCamera60fpsVideoCaptureCapability`, `MedusaPIPCapability` | NO | YES |
| Other hardware and services: `StarkCapability`, `WirelessChargingCapability`, `DeviceSupportsBatteryModuleAuthentication`, `DeviceSupportsCCK`, `DeviceSupportsCrudeProx`, `DeviceSupportsDoNotDisturbWhileDriving`, `DeviceSupportsELabel`, `DeviceSupportsFindApplePencil`, `DeviceSupportsLandscapeFaceID` | NO | YES |
| `WiFiCallingCapability`, `WifiCallingSecondaryDeviceCapability` | NO | nil |

Synthetic or device-type answers (sim → VM). Do not align to the sim side of these:

| key | sim | VM |
| --- | --- | --- |
| `ModelNumber` / `RegulatoryModelNumber` | `A3447` / `A3447` | `VM0001` / nil |
| `HWModelDescriptionFor{Analytics,Audio,AutomatedTesting,Camera,PowerPerf,UserVisibility}` | `J714sAP` | `V68AP` |
| `ProductTypeDescFor…` (same six) | `Mac17,9` (the host) | `iPhone19,4` |
| `HardwarePlatform` | `t6050` | `vresearch1` |
| `IsSimulator` / `IsVirtualDevice` | YES / NO | NO / YES |
| `DeviceMemorySize` | 64 GiB (the host) | 8 GiB |
| `ProductHash` | zeros | the V68 token |
| `device-name` | `iPhone Simulator` | `iPhone` |
| `main-screen-orientation` | nil | 0 |
| `HEVCDecoder{8,10,12}bitSupported`, `DeviceSupports3DImagery`, `DeviceSupports3DMaps` | YES | NO |
| `accelerometer`, `bluetooth-le`, `cellular-data`, `contains-cellular-radio`, `touch-id` | YES | NO |
| `ArtworkTraits`, `screen-dimensions`, `DisplayExtendedProperties` | differ in detail | see `BASELINE.md` |

Not checked here: which of the "Sim YES, VM NO" rows the VM turns off itself,
through `IsVirtualDevice`, `HardwarePlatform vresearch1` or missing hardware
nodes, and which a real V68 also answers NO. Look at the libMobileGestalt
answer function for each key before aligning one.

Also from the records: `MGCopyAnswerForDisplayAtIndex` returns nil in the
simulator for every camera and button rect query on all three display indexes.
