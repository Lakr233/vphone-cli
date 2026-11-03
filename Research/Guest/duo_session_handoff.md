# Duo fixes and optional host peripherals: review handoff

This is a collection of changes developed together on an existing iPhone19,4
guest: iOS 27.1 (24A94425), cloudOS 26.4 (23E5207q). The tested source baseline
was release 2.14.0, commit c503e1c51be0f2249bf4b5b19628cf8e33c00001.
The collection is intended for review and separation into suitable upstream
changes. It is not a claim of support across every product, firmware or host.

The local main-based review candidate uses upstream commit
0499378c7c46b1bfab5f1d9c3ffdb158e24bb083. It preserves the upstream digital-mode
120 Hz setup, stale digitizer UUID recovery and tap-to-wake declarations.
The original tested release-based patch is retained separately. This adapted
candidate has not been installed into the guest; do not attribute the original
runtime acceptance results to the adapted combination without retesting.
The adapted Release VPhone build passed (295.706 seconds), its diff passes
`git diff --check`, and the native-PAC reference comparison passed again.
The CarPlay request-generation example was checked with an isolated fixture
to retain existing groups/exceptions; it was not reapplied to the running VM.

## Source changes and evidence

| Area | Implementation | Observed validation | Limits / review focus |
| --- | --- | --- | --- |
| Native X1 detours | MISFixDetour.c relocates a first-instruction PACIBSPPC with the original PC and SP; refuses later occurrences | 4,096 native signing comparisons and 64 guest MIS validations; user subsequently installed their app through Xcode | Audit scratch registers, instruction encoding and relocation coverage on other CPUs |
| Store downloads | Exact six-job Store/account allow list and profile-preserving reproduction workflow in installd_and_store_download_repair.md | Maps downloaded, registered and launched; Freeform downloaded and registered | Per-guest configuration; third-party FairPlay, account login and Configurator's App Store-list workflow remain separate |
| Resized-window touch | VPhoneDisplayGeometry and VMView account for the active viewport at the current backing size | 14 DisplayGeometryTests passed; user confirmed touch fix | Retest cover/inner, rotation, fullscreen and Retina scaling together |
| Inner refresh rate | Historical local experiment changes the virtual display update rate from 60 to 120 | Window counter exceeded 60, with samples up to 111 fps | Upstream main already has an explicit digital-mode implementation; preserve it when integrating |
| Siri / CarPlay services | Recorded opt-in service allow list and profile-preserving reproduction commands in carplay_connection_diagnosis.md | User confirmed CarPlay connection and UI after restoring CarKit/Siri and restarting Mac clients | Per-guest configuration; default trimming-policy change remains an explicit upstream decision; the list is not proven minimal |
| CarPlay touch | FoldDisplayBackboard rotates only the built-in digitizer, preserving nonempty external display UUIDs | User confirmed CarPlay works with Duo open | Retain upstream stale-digitizer UUID recovery; retest after backboardd restart |
| Expanded activity corners | FoldDisplayAdapter fills zero inner UIScreen corner radius from the main screen's original value | SpringBoard native/main/effective values 0/59/59; Broadcasts panel visually fixed | Guarded private-API experiment; validate cover metric suitability and avoid masking future native geometry |
| iPhone pointer opt-in | Boolean mobile preference advertises pointer buttons/scroll; host capture is explicit and initially off | Guest pointer RPC accepted; user confirmed capture/release | Advertising input does not promise an iOS cursor or establish all inner-display mappings |
| Optional mouse capture | Device menu; Control–Option–M releases; focus loss/window close also release | User confirmed capture and release; clicking does not enable it | Check relative motion, held buttons, scroll and accessibility interactions |
| External monitor | Stable disabled 1080p/4K render slots before SpringBoard discovery; tag selected slot as AirPlay; refresh existing CADisplay objects | Broadcasts native external scene at both resolutions, live switch, disconnect/reconnect; default off | Duo only, private APIs, software JPEG preview rather than hardware scanout; app policy controls output |
| Live host camera | AVFoundation video source feeds existing BGRA/VSOCK transport; Launchpad camera privacy metadata and entitlement | Default Elgato feed visible in Camera.app; stopped frame counter held, resumed counter advanced | No active HDMI picture was available; photo/video capture with this source not revalidated |
| Camera picker | Native picker discovers camera names, stores unique IDs, supports System Default and preserves streaming state | Picker sheet deployed; user confirmed camera feed works after clicking Start Streaming | Full multiple-camera switching and physical unplug/replug remain to test; selection is per-window |

Detailed findings are in display_refresh_rate.md, trackpad_gesture_mapping.md,
iphone_duo_bringup.md, carplay_connection_diagnosis.md,
virtual_external_display.md, virtual_camera_transport.md and
apple_intelligence_eligibility.md. New external-display RPCs and pointer opt-in
are documented in ../vphoned_http_api.md. Full Release VPhone builds passed
through the final camera-picker version. The separate Release Launchpad build
and development signing checks also passed. These are historical test results
for the local 2.14.0-based builds, not CI results for a future upstream merge.

## Guest configuration that is not an upstream source change

The guest was booted using a local Standard-derived selection that additionally
blocked these ARM64E_X1 lowering patches:

- dyld-boot-arm64e_x1_bootstrap
- dyld-cfw-arm64e_x1_cache
- system-cibarcode-cfw-arm64e_x1
- system-dyld-boot-arm64e_x1_bootstrap
- system-fsck-boot-arm64e_x1_bootstrap
- system-launchd-boot-arm64e_x1_bootstrap
- system-mount-boot-arm64e_x1_bootstrap

This is reproduction context, not a proposed default preset. The early recovery
temporarily disabled MISFix and FoldDisplay hooks; both were restored after
the native detour fix. The disabled-hook workaround is not the final state.
Cached firmware was reused. No new firmware image is included in this change.

The existing service profile kept its groups and added exceptions for CarKit,
Siri and model/intelligence support. CarPlay depended on restoring carkitd and
Siri jobs. App Store/account service restoration repaired built-in app downloads
(Maps and Freeform), but did not establish functioning Apple Account
authentication or FairPlay. These per-machine changes should not
silently become global trimming defaults. Inspect the profile and preserve
existing exceptions before reproducing any service changes.

The mobile-user preference com.vphone.vphoned/iPhonePointerEnabled was set to
boolean true explicitly. The source default remains off on iPhones. Mouse
capture also remains off for new windows and is not enabled by clicking.

## Investigations with no retained fix

Apple Intelligence eligibility overrides exposed more UI but did not produce
working inference: the guest selected a missing com.apple.modelmanager.remote
host backend. MobileGestalt, eligibility and ModelManager experiments were
rolled back. No host AppleInternal entitlement, inference service, security
policy or region spoofing change is included.

Multitasking thumbnails remain unresolved. Compressed snapshot files returned
EIO; an experimental compression-rule exclusion was rolled back. App Store
installation through Configurator and online attestation also remain unresolved.
Do not confuse those with the repaired built-in app placeholder downloads.

## Integration priorities

1. Preserve upstream changes since the tested release, especially inner-panel
   digital modes, stale digitizer UUID recovery and tap-to-wake declarations.
2. Review the native detour and touch fixes independently from optional features.
3. Audit private display API ABIs and native capture/transport error handling.
   The external-display diagnostics RPC is read-only but potentially verbose.
4. For camera acceptance, choose a camera and explicitly Start Streaming.
   Verify actual moving imagery, switching while streaming, cancellation,
   disconnection, stop/release and permission denial. Inspect runtime failure
   reporting as well as successful preview delivery.
5. Run the project builds/tests and repeat guest acceptance after integration.
   No new VM, firmware download or host security change is necessary merely
   to review this collection.

Only source and research notes are supplied. Local build products, firmware,
VM disks, certificates, signing team configuration, account data, diagnostic
dumps, screenshots and recorded camera imagery are excluded.
