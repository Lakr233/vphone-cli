# Patch Comparison: Regular / Development / Jailbreak / Experimental

> **HomeView distance simulation (2026-10-30, runtime validation pending).**
> `dyld-exp-homeview_environment_service` opens only BreadBoardServices'
> environment-service internal-install branch on the reviewed 27.2 userland.
> The preceding client entitlement check remains intact; no global internal
> build identity is changed. The reveal follows the native Platform getter's
> call and validates the service's separate rejection paths with Capstone.
> Writes use cache-page re-attestation and the existing undo log. The patch is
> off in every shipped preset and is admitted only for HomeView installs.
> The guest RPC uses the native environment request, near/increased detail and
> far/decreased detail. Native reset clears all environment overrides and
> requires explicit acknowledgement. Retail runtime probes confirmed the
> internal-build gate; no live distance override or patch deployment has been
> performed. See [distance investigation](Firmware/homeview_distance.md).
> Offline validation passes against an APFS cache clone: unique reviewed gate,
> one instruction and one page hash changed, repeat is a no-op, and undo restores
> every cache file byte-identically. Finished bundle build/admission and 94
> focused Xcode tests pass; the live Near/Far UI effect is still unverified.
> After user authorization, HomeView received this patch and guest environment
> `2.15.0-local.b1ed0817`. Native ABI validation was corrected to accept the
> protocol's `Vv` (oneway void) qualifier, with a focused regression test. The
> installed daemon now activates the service and fetches native detail as root.
> No distance override was written by the agent; the user will test Near/Far/reset.

> **HomeView guest-profile backend lookup (2026-10-30).** The BreadBoard
> display exception clears its first assertion, but its native guest-profile
> fetch still fails with an NSError chain ending in sandbox restriction 159
> for `com.apple.mobile.keybagd.UserManager.xpc`. A mobile native probe with
> BreadBoard's relevant client entitlements reproduces it. Userprofilesd's
> donor sandbox lacks that lookup. New `system-userprofilesd-exp-keybag_lookup`
> adds exactly that one exception to userprofilesd, preserving the native
> profile/persona APIs and authorizations; it never fabricates a profile.
> Selected only in `homeview`, gated to 27.2, reversible from executable backup.
> Native setup bypass verification passed independently (`NeedsSetup=false`,
> `CompletedInitialRun=true`, with `SetupDone` untouched). Validated on the
> clean HomeView VM: native guest-profile retrieval succeeds, BreadBoard
> stays up, and Setup.app renders. Touch navigation works from the bypassed
> dashboard into World Clock and its city chooser.

> **HomeView native shell display startup (2026-10-30).** The clean guest
> reaches vphoned and backboardd, but BreadBoard traps in
> `BKSDisplayServicesStart+436`, at the nonzero display-service query status
> assertion, before drawing its UI. Its donor entitlements use
> `temporary-sandbox` and lack `com.apple.backboard.display.services` and the
> backboard HID/render lookups already repaired for Campo on the 26.4 kernel.
> New `system-breadboard-exp-mach_lookup` reuses that scoped exception merger,
> preserves the rest of BreadBoard's entitlements, and keeps an executable
> backup for deselection. On only in `homeview`, gated to 27.2; native setup
> still stays on. Validated: the display-service assertion is gone. Native
> startup also needs the userprofilesd lookup repair above. No new kernel or
> instruction patch.

> **HomeView bringup (2026-10-30).** Adds the opt-in
> `system-homeview-exp-setup_bypass`, off in every shipped preset, including
> the new `homeview` preset. The existing mobile setup helper runs in an
> isolated HomeView mode, journals only `com.apple.purplebuddy/ForceNoBuddy`,
> verifies the native SetupAssistant gates, and restores the exact original
> key on deselection. No completion, activation or HomeKit state is fabricated.
> `devicetree-cfw-homeview_touch` enables DriverKit for the VM's USB HID touch
> screen on J490/J491 installed trees only. The existing
> `devicetree-cfw-tv_app_architecture` also copies the `home` donor's app
> architecture. `system-tv-exp-ota_userland` is reused for HomeView's own
> arm64e full OTA over the HD restore base; Apple TV remote/setup adapters
> remain off. No new instruction replacement or kernel patch. Restore,
> native setup, bypass enable/disable, framebuffer and touch are now tested; see
> [HomeView bringup](Firmware/homeview_bringup.md).

> **Apple TV RootHide bootstrap and environment hooks (2026-10-26).** No new
> declaration or instruction patch. An arm64e Apple TV now admits
> `system-launchdaemons-boot-environment` and
> `system-launchd-boot-jetsam_panic_guard_bypass`
> (`FirmwareGuestPatchResolution.tvArm64eGuestPatches`); both stay blocked in
> `tvos` and `tvos-4k` and on the plain-arm64 HD. On TV the environment is
> `launchdhook-vphone.dylib` and `SystemHook-vphone.dylib` alone, their
> `LC_BUILD_VERSION` rewritten to tvOS (`MachOBuildPlatform`) and re-signed at
> install, with `/vh`; turning it off removes them. The launchd patch is
> unchanged: on `tv4k`'s tvOS 26.6 arm64e launchd it rewrote `tbnz w0, #0,
> 0xdac4` at `0xDA68` to `b 0xdac4` (anchor `jetsam property category`) and
> `/vh` went in as `LC_LOAD_WEAK_DYLIB`. With both on, `tv4k` booted to the
> home screen with SystemHook in every process and the vphoned RootHide root
> as `VPHONE_JB_ROOT`; with both off again launchd came back from its backup
> and the libraries and `/vh` were removed. vphoned installs Irisin's
> `appletvos-arm64e` package as the RootHide bootstrap on any tvOS guest and
> refuses rootless there; both were validated live on `tv4k`. See
> [tvOS support](Firmware/tvos_support.md#roothide-bootstrap).

> **Apple TV remote and native Setup (2026-10-24).** The current
> `tvos-4k` preset selects `system-setupbackground-exp-pineboard_lookup` on
> 27.2 and blocks `system-tv-exp-legacy_setup`. The environment update
> restores the original CompanionServices flags from their backup, returning
> to the new Setup app. Live debugger inspection localized Select's failure:
> Hello's native focus target exists but is deferred; a directional press
> commits it, after which Select executes the ordinary Hello callback and
> opens Language. `system-setup-exp-deferred_focus` installs a tvOS dylib into
> Setup via `/tf`, preserving its original entitlements and a reversible backup.
> Its adapter uses native TV button-focus policy (`0`) only for an active key
> Setup window whose WaffleIron system has default deferral (`3`) and no explicit
> override. It observes scene/key/focus updates, preserves other overrides, and
> uses UIKit's own preferred-focus machinery and eligibility checks. Earlier
> focus-initialization prototypes expired after the native 60-second idle timer.
> A live policy-0 test retained focus past 80 seconds and Select entered the
> native country picker. The adapter changes no
> pairing, drawing, ScenePhase, window suppression or setup-completion state.
> This patch is selected only by `tvos-4k` on 27.2; legacy setup remains off.
> Installed cold-boot testing passes the first Select after more than 65 seconds
> idle at Hello, without directional priming or a debugger. Completed
> AX/button taps now survive panel focus loss; pending holds are cancelled and
> neither may cross a guest reconnection. The actual AX-button/queue harness
> covers this live-discovered delivery failure. See the
> [input investigation](Firmware/tvos_27_setup_input.md). Remote clicks, holds,
> Home/Settings navigation and Control Center have passed live testing.
>
> Native Setup then reached manual activation and failed with -71136. The
> matching tvOS mobileactivationd retains the existing `should_hactivate`
> local-state path, but the TV preset had excluded it. The new declaration
> `system-mobileactivationd-exp-tv_activation` reuses that unchanged patcher
> with an exact 27.2 applicability gate, selected only by `tvos-4k` and admitted
> only for arm64e Apple TV. The installer uses one activation declaration per
> device, retaining the existing backup/revert path. Installed native Manual
> setup now advances past activation to room choice and Terms & Conditions.
> Cold boot of `a4b9ffc4` exposed a packaging failure: the final Setup bundle
> seal discarded the entitlements preserved by `patchMachO`, causing native
> TCC Bluetooth usage-description crashes. Both applying the focus adapter
> and restoring its backup now preserve original entitlements through bundle
> sealing. Corrected bundle `da14d7a4` retains the full pristine entitlement set
> byte-identically and passes the idle/AX input test. After user-confirmed Terms,
> native Setup completes to Home with its own SetupDone/TVBuddy completion
> flags true and TVSetupVersion=15. The original VM is also updated, with its
> prior setup and data preserved. Navigation, Control Center, Siri search,
> Power sleep and TV wake pass; audio effects without active media remain
> unverified. A final read-only daemon correction uses TV version/completion
> policy instead of the iOS setup version; 376 logic checks pass. Its bundle
> `9ffd2d6e` is installed on both machines. Final cold boots report TV setup
> and current versions 15, pending=false, and no Setup process. The clone
> returns directly to Home; the original remains running with its data intact.
> Both receipts have zero pending changes and legacy setup off.

> **The iPhone17,3 presents its board (2026-10-25).**
> `VPhoneGuestDevice.presentsBoard` no longer excludes the iPhone17,3; only the
> XS Max keeps the shared tree. An iPhone17,3 guest now gets the separate
> installed tree and the `devicetree-cfw-ipad_*` presentation from
> `DeviceTree.d47ap.im4p`, as every other iPhone does, and skips
> `preboot-exp-devicetree_identity`. No patch is new. `ipad_identity` is on in
> `standard`, so a `standard` iPhone17,3 guest now reports `iPhone17,3` instead
> of `iPhone99,11`. The catalog's release list keeps its iPhone17,3 check
> explicit (`VPhoneFirmwareCatalog.pairings`), so its pairings do not change. Checked on
> a new `iPhone17,3 27.0.1 (24A446)` guest, cloudOS 26.4 (23E5207q), plain
> `standard`: the restore tree split off `DeviceTree.vphone600ap.guest.im4p`;
> the receipt records the `ipad_*` patches and
> `preboot-cfw-devicetree_board_audio`; `device.info` reports `iPhone17,3` at
> 430x932 @3x; Settings > About shows Model Name iPhone 16 and an Action
> Button row; the Camera app shows the .5/1x/2 lenses and the test pattern;
> with Location Services on, `location.set` reads back a fresh simulated fix
> and `bluetoothd`/`locationd` keep their boot PIDs (no #438). Crash reports
> held only the documented restore-reboot panic and `duetexpertd` datavault
> crashes, plus one `NANDTaskScheduler` PAC kill in its Core Data failure
> logging (no ANS NAND on a VM), not on a device tree path.

> **Account prompt hooks are selectable (2026-10-25).**
> `system-preferences-cfw-followup_groups` (`libprefsfix.dylib`, Settings'
> CoreFollowUp groups) and `system-apps-cfw-signin_sheets`
> (`libsigninfix.dylib`, in-app sign-in sheets) were installed with the guest
> environment and could not be turned off. Both are now declarations, on in
> `standard` and `experimental`, blocked in the TV and HomePod presets, which
> already block the environment. `cfw install` and `cfw update-environment`
> install or remove each library per the plan, a VM with no plan keeps both,
> and the live environment sync no longer reinstalls one that was turned off.
> SystemHook skips a missing library, so removal takes effect on the next
> launch of Settings or the app. No binary or loader changes. Account daemons
> stay running either way; update and account daemons are disabled only by
> vphoned's service profile ([service trimming](Guest/service_trimming.md)).

> **CSSC kernel compatibility experiment (2026-10-25).**
> `kernel-boot-cssc_emulation` targets iOS 27 with cloudOS 26.4. It reuses the
> kernel's undefined-instruction copyin, PAC-safe interrupt helpers and
> signed-state check/sign ABI. Only known EL0 scalar CSSC words are evaluated;
> unknown faults retain native triage. The single baseline-A64 payload occupies
> persistent kernel text; no userland/cache CSSC trampolines or writable code
> pages are introduced. Existing X1 PAuth/CPA lowering remains unchanged.
> Selected X1 boot patch failures abort installation, and an unresolved CSSC
> kernel handler aborts kernel preparation. TV and HomePod presets exclude
> this operation. See `Research/Guest/iphone_duo_bringup.md` for the reveal
> procedure and signed-state handling.

> **HomePod local app installation (2026-10-23).**
> `system-installd-exp-homepod_adhoc` is selected only by `homepod-mini` on
> HomePod 27. It loads a dedicated TVOS arm64e build of the existing MIS
> signature-option and MobileInstallation ad-hoc adapters into installd via
> `/hm`. Native MIS still validates the signature and produces its metadata;
> the verifier's `allowAdhocSigning` switch accepts the missing certificate.
> No embedded-profile bypass, device identity, profile scope or spawn hooks
> are compiled into this library. Opt-out restores installd's original backup
> before removing the alias and library. HomePod lacks misagent, so the test
> app uses the research tvOS SDK and a local signature with no profile.
> See `Research/Guest/xcode_install_signature_gate.md` for validation.
> TempPod passes real Xcode installation, headless execution, source breakpoint,
> stepping, variable inspection and Objective-C expression evaluation. Live
> opt-out restores installd and launchd byte-identically to their original
> backups and removes the owned aliases/marker/libraries; the default preset
> has been restored. Full bundle admission, 77 selected Swift tests and the
> persona ABI/policy harness pass.

> **HomePod Xcode installation persona (2026-10-23).**
> The existing `system-installcoordination_proxy-cfw-persona_lookup` now has a
> HomePod 27 deployment, selected by `homepod-mini`. TempPod reproduced the
> iPhone's Protobox denial of the installation proxy's UserManager lookup.
> HomePod loads a dedicated TVOS arm64e `libvphoneinstallpersona.dylib` in
> launchd via the short `/vp` alias. It reuses the existing root-owned marker,
> exact service/path/signing-identity and kernel-validated audit-token checks.
> Other sandbox calls retain their arguments and native result. No spawn,
> jetsam or iPhone environment hooks are included. Opt-out restores launchd
> from its original backup before removing the marker, alias and library.
> Xcode installation, process launch and LLDB stack inspection pass; see
> `Research/Guest/ios27_xcode_persona_lookup.md`.

> **HomePod cryptex DDI staging (2026-10-23).**
> `system-cryptexd-exp-homepod_staging` is a selectable HomePod 27 guest patch,
> enabled by `homepod-mini` and excluded from the iOS/Apple TV presets. It
> injects the TVOS arm64e `libvphonecryptexstaging.dylib` into cryptexd through
> a load command, preserving the daemon's entitlements and an original `.bak`.
> Deselecting restores the daemon before removing the library. Only failed
> `F_SETPROTECTIONCLASS` calls returning `EPERM` become `ENOTSUP`, the daemon's
> existing unsupported-filesystem fallback. Other fcntl calls tail-forward
> their complete ABI arguments. Apple ticket/signature/trust-cache/graft checks
> remain on the native path. DDI persistence and nonce persistence use Apple's
> until-reboot mode. The research SEP's digest-storage failure is tolerated only
> for error 104 in the cryptex POSIX domain and an info plist naming Apple's DDI,
> `/System/Developer`, and DeveloperModeRequired true; the preceding native
> signature lock is unchanged. This does not enable the broad iPhone environment or its
> display hooks. Validation and deployment results are recorded in
> `Research/Guest/developer_disk_images.md`.
> TempPod confirmed the staging errno, then exposed an authenticated APFS
> `clas` mismatch (tvOS ticket `0xf4`, research kernel `0xf2`). The independent
> `preboot-homepod-exp-cryptex_class` repair sets or adds only the concrete uint32
> `/product/cryptex1-product-class` to `0xf4`, which the kernel's native Image4
> runtime reads. It preserves equality verification and global product-id;
> Preboot backup composition makes it reversible. No kernel instruction is
> patched. Reveal/validation procedure is in the same research document.
> TempPod now reports `connected` with a compatible, usable 27B48 tvOS cryptex
> DDI. Device/process/app/file queries and Xcode Device Hub DDI readiness pass.
> HomePod has no display, so Device Hub live preview is unsupported as expected;
> Xcode app installation, launch and LLDB stack inspection now pass. The
> initial UIKit template asserts when it requests a display-backed window
> scene; application UI support is separate from DDI readiness.
> Live opt-out restores cryptexd and the whole personalized DeviceTree to their
> pre-patch bytes, removing the injected library. Full bundle admission, 76
> selected Swift tests, and the scoped native adapter harness pass.

> **vphoned on iOS 18 (2026-10-23):** the daemon strongly imports Span types
> from `@rpath/libswiftCompatibilitySpan.dylib`, but the guest payload omitted
> the back-deployment library. The bundle now carries the signed iPhoneOS
> library, and the existing vphoned installation steps (both restore-image
> injection and full/environment-only CFW install) copy it to
> `/usr/lib/vphone/libswiftCompatibilitySpan.dylib`. The iOS daemon gains that
> fallback rpath after `/usr/lib/swift`, preserving the system implementation
> on iOS 26+. The restore-image trust-cache scan includes the added file.
> Bundle admission checks its signature/platform and the daemon's search path.
> No new patch, preset, instruction replacement, or version change is needed;
> TV/watch daemon payloads are unchanged. This fixes a confirmed missing
> dependency; an iOS 18 guest boot still needs runtime validation.

> **HomePod integration with upstream main (2026-10-23).**
> Merged upstream `d14231a4` into the HomePod branch, retaining upstream's
> 2.12 compatibility contract, Apple Watch, research-board and sealed restore
> image workflows alongside HomePod's donor inference, OTA userland and audio
> routing. The `homepod-mini` shipped preset now names the research-board set
> and blocks the new manual Frida relaxations and iOS Bluetooth-controller
> patch, matching its built-in definition. HomePod's original global product
> token, 48 kHz audio-only routing and Sound Glow policies are unchanged.
> Validation: full VPhone bundle (including admission checks) and Launchpad
> builds passed; 683 CoreKit, 170 selected patch/pipeline and 105 archive tests
> passed. The CoreKit throughput threshold needed one isolated retry after
> failing during the full parallel run. Two research-board firmware comparison
> tests skipped without their optional fixtures. HomePod display, setup,
> welcome, Siri and Sound Glow native harnesses and Launchpad machine/cache,
> compatibility, template and control harnesses passed. No bundle was installed
> and no live VM behavior was retested for this merge.

> **HomePod 27.2 OTA and native Sound Glow (2026-10-23, live verified).**
> The 27.0 donor lacks the artwork/color extraction and native media animation
> cases introduced in 27.2. `system-homepod-exp-ota_userland` stages the full
> Apple HomePod mini OTA over the same device's 27.0 IPSW, retaining its restore
> identity and cloudOS boot chain, as the Apple TV OTA pairing does.
> `system-homepod-exp-sound_glow` injects the existing guest adapter into
> NowPlayingCap and generates `/usr/share/vphone/HomePodSoundGlow.plist`.
> Its narrow native `AccessorySettingProvider.mediaUI` getter selects value 1;
> Apple's artwork service, color extractor and CAPAnimationEffect.media remain
> responsible for rendering. Opt-out restores the original app and removes the
> policy. Both declarations are HomePod-only, require 27.2 or later, and are
> selected by default only by `homepod-mini`. Original product identity and
> existing audio/Siri behavior are retained. Local validation and native
> evidence are recorded in [Sound Glow](Firmware/homepod_sound_glow.md).
> Live 27.2 boot and clear Music/AirPlay audio are verified. Initial playback
> exposed an unresolved own-device endpoint in the native artwork request.
> A scoped request adapter selects MediaRemote's local destination only for
> that own-device UID; native request/response and artwork processing remain
> intact. Remote requests and opt-out pass through. The routing correction,
> artwork processing succeed live in 24K120. Purple and yellow album artwork
> produce distinct native animated colors; pause fades to idle and resume works.
> A follow-up to the existing Siri speech patch uses a mixable, ducking auxiliary
> session with notify-on-deactivation after the live interruption test made
> Music abandon the receiver. The owner confirmed full speech while Music stayed
> on HomePod; native frames handed off to Siri and returned to colored music.
> Successful installation now records the actual mounted HomePod SystemVersion
> after disk commit, preserving cloudOS and variant. Preparing an OTA alone does
> not promote the host label; full-install command/creator variant recording
> retains HomePod identity. Restore-info tests cover this merge.
> Opt-out removes the policy and injected load command and restores white native
> playback. Re-enable plus cold boot restores audible music and colored native
> animation, confirmed by the owner and changing valid RGB reports. Final live
> bundle: `2.11.0-local.8e60e757`; original 27.0 VM and default bundle preserved.

> **HomePod Siri speech policy (2026-10-23, live speech verified).**
> New optional `system-homepod-exp-siri_speech` generates
> `/usr/share/vphone/HomePodSiriSpeech.plist` with `Enabled=true`, restricted to
> 27.x HomePod guests and selected by default only in `homepod-mini`. Installation
> requires vphoned, the top-cap adapter and virtio sound; welcome additionally
> requires this speech policy. Opt-out removes only the selected policy.
> The native branch supports an output-only auxiliary AVAudioSession ID carried
> on a normal type 13 SVXSystemEvent, allowing SoundBoard's existing Siri lifecycle
> and completion to handle speech without entering physical recording setup.
> The candidate repair is scoped to the existing SoundBoard adapter; global
> product identity, audio route and microphone capability flags remain intact.
> Live `siriSay:` speaks the full exact welcome sentence. SiriHeadlessService
> reports synthesis success, sirittsd records playback start/finish, SoundBoard
> returns to idle and deactivates the auxiliary session. Colorful native frames
> advance during speech and return to black afterward.
> See [welcome and speech policy](Firmware/homepod_welcome.md).

> **HomePod welcome policy (2026-10-23, live sequence verified).**
> New optional `system-homepod-exp-welcome` is restricted to 27.x and admitted
> only for HomePod guests. Only `homepod-mini` selects it by default. The guest
> installer checks that vphoned, the HomePod top cap, local setup completion and
> virtio sound and native Siri speech are selected, then generates
> `/usr/share/vphone/HomePodWelcome.plist` with `Enabled=true`. Opt-out removes
> only that policy; once-only Data state remains owned by the guest runtime.
> The coordinator runs in SoundBoard's existing injected HomePod adapter, using
> native tone completion, a coordinated Identify activity and Siri finalization
> after boot readiness. A durable guest-identity claim prevents replay across
> restarts and updates while allowing each template clone its own welcome.
> The owner confirms tone, exact speech and both animations on automatic boot.
> Logs establish TonePlaying, ToneFinished, SpeechRequested and SpeechFinalized.
> Live inspection caught Identify remaining active: cleanup must call the
> coordinated `setLocalSessionActive:NO`, which invokes the subclass cleanup;
> calling `endLocalSessionActivity` alone does not relinquish ownership. The
> regression mock now preserves that native distinction. Final installed bundle
> `2.11.0-local.3f1d474e` passes the complete sequence on a fresh-identity clone,
> returning to an empty activity stack. The original claim/status stay byte
> identical after update, cold boot and SoundBoard restart with no replay.
> Direct Siri speech, native animated frames and ordinary tone 1 still pass
> afterward, including the owner's audible and return-to-idle confirmation.
> See [welcome policy and native behavior](Firmware/homepod_welcome.md).

> **HomePod welcome pre-live ABI audit (2026-10-23).**
> Direct 24J361 donor-cache metadata establishes UInt32 tone playback
> (`SBUITonePlaybackManager play:completion:`, `v28@0:8I16@?20`). The candidate's
> initial UInt64 mock and guard agreed with each other but would reject the real
> guest method. Both are corrected, with an independent donor-signature fixture
> and rejection coverage for the old shape. Native Siri state/selector analysis
> also confirms a presenting-state activity path separate from microphone audio
> activation; live animation, metering and audibility remain pending.

> **HomePod audio-only identity correction (2026-10-22, live validation).**
> An A/B boot of the same installed bundle, changing only the validated donor
> product token back to its prior virtual value, restores the native red replay;
> restoring the donor token blacks the same fixture. The donor identity enables
> HomePodDisplayService's physical gamma path, which requires absent brightness
> hardware. Audio now selects native B520 route **4** through VirtualAudio's own
> `ProductIDOverride`, stored by vphoned and set in-process by the HAL plugin.
> The boot-tree HomePod capability patch retains the original VM product token.
> `preboot-homepod-exp-audio_product` is now blocked in every preset; its existing
> inverse restores previously installed guests from the shared Preboot backup.
> The old repair remains declared for explicit research and reversible migration.
> No display workaround or new instruction patch. All 88 focused Xcode firmware
> tests, four audio transport harnesses, the unchanged display adapter harness,
> the full bundle build and strict signature verification pass. Installed
> `2.11.0-local.40cd1d45` restores the exact original Preboot tree; MobileGestalt
> retains the virtual product enum while VirtualAudio uses route 4. The owner
> confirms clear tones. LED replay and native identify output work across two
> cold boots; the second playback run has zero starvation/drops in all cycles.

> **HomePod audio port (2026-10-22, live routing validation).**
> New `preboot-homepod-exp-audio_product` restores the donor's exact 20-byte
> `/product/product-id` in Preboot through the existing reversible repair
> composition; new HomePod boot trees receive it too. MobileGestalt then resolves
> HomePod mini's native VirtualAudio product 4 instead of the VM's unknown 0.
> `homepod-mini` selects the shared virtio-snd HAL driver, retargeted/resealed
> for tvOS, publishing its output as the native `PuffinOutput` endpoint. It does
> not apply the iPhone 8010 override or VirtualAudio instruction/tuning patches.
> Other presets keep the new identity repair off and TV excludes the driver.
> First live run proves native product 4, B520 tuning selection and driver load;
> routing requires the HomePod-only raw UInt32 `mode/glob/0` custom property.
> The driver advertises this through `cust`, retains the native `defa`/`raww`/
> `tphn`/`meas` mode and reports changes. Corrected build `61d08ba5` routes to
> `PuffinOutput`; six playback cycles have zero starvation/drop counters.
> Final build `b284734a` plays ordinary-session test tones on the Mac's selected
> Studio Display speakers; the owner confirms clear tones.
> Live silence traced to B520 speaker DSP buffer overruns at 44.1 kHz.
> HomePod output now advertises only its 48 kHz wire rate; forcing a 48 kHz
> session removes the errors and produces nonzero PCM in a scoped host tap.
> iPhone/iPad retain their alternate-rate support.
> No new instruction patch. See [native evidence and validation](Guest/homepod_audio.md).

> **HomePod setup completion and controls (2026-10-22, live validation).**
> New `system-homepod-exp-setup_bypass` is HomePod-only, restricted to 27.x,
> and selected only by `homepod-mini`. It installs the System marker
> `/usr/share/vphone/HomePodSetup.plist`. A short-lived mobile helper journals
> `SetupDone` and `SetupFinishedAllSteps` in `com.apple.purplebuddy`, synchronizes
> them, and calls the donor's `BYSetupAssistantPrepareLaunchSentinel` before
> checking the native needs-setup and initial-run APIs. The sentinel is a
> per-user POSIX semaphore, not a filesystem flag. Removing the marker restores
> exactly the original two keys, including absent values; the inverse survives
> until native restoration succeeds. The helper remains installed for rollback
> even if vphoned is deselected. This completes local setup state; it does not
> provision an Apple Account or HomeKit home. **Live late-start correction:**
> an already-running HPSetup retains assistant/voice-trigger assertions even
> after SoundBoard receives completion and runs post-setup initialization.
> Native preparation publishes fresh completion; after verification, the helper
> replays the donor's exported notification only for an existing sentinel and
> gracefully stops only mobile's exact
> `/Applications/HPSetup.app/HPSetup`, rechecking identity immediately before
> SIGTERM. It observes disappearance before reporting success; failures retain
> the inverse for retry. No SIGKILL, arbitrary process verb or new entitlement.
> Opt-out does not terminate processes. No new instruction patch.
> vphoned also exposes all 29 `SBSDebugInterface` methods through a fixed,
> ABI-checked catalog using `com.apple.debuginfo.soundboard`; the HomePod-only
> Controls section includes native animation/phase choices and typed button and
> LED replay adapters. The host top cap now uses runtime-compiled Metal 4 optics
> with a macOS 15 Metal compatibility path. GPU tests and 35 Xcode catalog and
> selection tests pass. Final bundle `2.11.0-local.26745ac8` passed live late
> completion (one native init), fresh/repeated boot, and native Metal display
> presentation/reconnection. Opt-out restored absent keys and setup behavior.
> See [implementation, live evidence, and service boundaries](Firmware/homepod_soundboard_controls.md).

> **HomePod top cap (2026-10-22).** `system-homepod-exp-top_cap` installs
> `/usr/share/vphone/HomePodDisplay.plist`, extracted from the selected board's
> `/arm-io/dockchannel-rtp/rtp-transport/display` node. It preserves the donor's
> `MDXCoords`, `MDYCoords`, `MDRingCoords`, `MDBitDepth` and `MDHWVersion` payloads
> for vphoned's virtual MiniDisplay HID device. Only `homepod-mini` selects it
> by default; the installer rejects other guest families and missing or invalid
> donor metadata. Both full installation and environment updates stage it through
> confined descriptors; deselecting removes this added configuration and its
> receipt entry. It also installs `libvphonehomepoddisplay.dylib` only into
> SoundBoard through an `LC_LOAD_WEAK_DYLIB` in its backed-up executable, preserving
> its entitlements and resealing its app bundle. launchd strips `DYLD_*`
> environment variables from this platform process, so both the standalone
> daemon plist and launchd cache are cleaned of the earlier environment route
> while preserving their other keys and inserted libraries.
> `IOHIDUserDevice` reserves `IOClass`;
> the shim adapts MiniDisplay's discovery callback and class-identity query only
> for the exact virtual display ID. On a failed submission it can replace that
> virtual handle after vphoned restarts, retrying the same native frame and
> throttling device enumeration to once per second. Other devices retain their
> original failure behavior. LED reports still traverse the native HID device. Deselecting
> restores the original SoundBoard executable from `.bak`, reseals the app,
> and deletes the library. The VM retains its virtual hardware tree.
> No instruction patch is added.

> **HomePod mini (2026-10-22).** `AudioAccessory5,1` / B520 uses its own
> HomePod Software 27.0 (24J361) monolithic arm64e TVOS IPSW with the cloudOS
> 26.4 boot chain. The dedicated `homepod-mini` preset retains 27 compatibility
> and vphoned, blocks the Apple TV OTA swap, HD TPRO workaround and iPhone
> GPU/audio/environment hooks. New `devicetree-cfw-homepod_product` copies
> concrete `horseman`, `siri-hub` and app architecture capabilities from B520's
> donor tree only into its installed identity. No new kernel instruction patch.
> See [HomePod mini support](Firmware/homepod_mini_support.md) for evidence,
> validation status and limitations.

> **VirtualAudio device-state null gate (2026-10-24):**
> `system-virtualaudio-cfw-device_state_null_gate` (guest system set,
> iOS 27, on in `standard`, blocked in `tvos` and `tvos-4k`; verb `cfw
> patch-virtualaudio-device-state-null-gate`, riding the shared staged
> copy with the other four VirtualAudio verbs) makes
> VirtualAudio_Device's two device-state updates wait for the
> DeviceStateManager singleton instead of dereferencing it when it does
> not exist. Live evidence on the iPhone Duo guest: deferred
> initialization is dispatched at plugin init but on a machine with no
> haptic hardware it exits without constructing the manager — no
> "Ending Deferred Initialization" is ever logged, no thread is parked
> inside it at crash time — so TheInstance() returns null forever and a
> route push that arrives once the gates answer true reads it: audiomxd
> dies, anywhere from ~10 s to ~130 s into its life. The patch redirects
> each update's gate-check call to TheInstance, so the `cbz w0, <skip>`
> the function already carries now tests the singleton: no manager, the
> update is skipped through the function's own path; manager present,
> the fall-through re-calls TheInstance and the whole update runs
> untouched, as designed. The plugin header gates the patch to arm64e.x1
> (cpusubtype 12, iOS 27.1's iPhone19,4): the 26.6.2 and 27.0 plugins
> are plain arm64e and are left byte-identical. Two earlier variants were
> replaced after live runs taught better: a `…-device_state_guard` that
> permanently skipped both updates (stopped the crash, but wins by
> discarding the channel a foldable's audio graph learns the posture
> from) and a `…-device_state_early_publish` that left the deferred-init
> actuator wait at once (a no-op on this guest — the wait loop is never
> reached, because the manager's construction needs haptics hardware a
> VM does not have). See the full section below.

> **CIBarcode standalone X1 lowering (2026-10-29, local validation):**
> `system-cibarcode-cfw-arm64e_x1` applies the existing static X1 planner to
> `/System/Library/CoreImage/CIBarcode.cifilter/CIBarcode`, outside the shared
> cache. It is gated to iOS 27.1, enabled in `standard`, and blocked in the TV
> and HomePod presets. The measured 24A94425 image UUID is
> `807AC7DC-7FE2-3E60-BA1B-0E879FF70012`. After whole-cache lowering, an app
> reached its normal main run loop but faulted on a utility queue in this
> image at relative address 5960 with `EXC_BAD_INSTRUCTION` / `0xDAC1A7FE`,
> called by `+[CIFilter(CIFilterRegistryPrivate) filterWithName:setDefaults:]`.
> This offset is evidence only; the patch discovers reachable instructions
> through the existing planner, not a fixed offset. The installer stages from
> `.bak`, re-attests/signs and seals the filter bundle, and restores the backup
> when deselected. On the pulled stock image, the planner lowered 425
> instructions, re-attested 19 slots, and left zero unvisited candidates;
> the recorded fault site was lowered and a second pass was byte-identical.
> The X1 and catalogue suites passed (39 tests). An environment update on an
> existing M3 Max Duo preserved a byte-identical original `.bak` and recorded
> the new patch in its Guest receipt. The previously crashing app reached its
> home screen in both open and closed postures without a new CIBarcode crash.
> App-specific environment-risk checks remain active; login and transactions
> were not tested. The build used local Xcode 26 compatibility adjustments
> outside this patch. A full multi-firmware golden corpus was not available.

> **ARM64E_X1 whole-cache lowering (2026-10-23):** `dyld-cfw-arm64e_x1_cache`
> (guest system set, iOS 27, on in `standard`, blocked in `tvos` and
> `tvos-4k`; verb `cfw patch-arm64e-x1-cache`) lowers the X1 instructions of
> every shared-cache image outside `dyld-boot-arm64e_x1_bootstrap`'s 38-image
> closure, with the same planner and replacement table, and re-attests each
> modified page. Without it every other image faults into launchd's
> single-threaded on-demand handler once per site per process; on iPhone19,4
> 27.1 (24A94425) that left launchd at 685 CPU-seconds 18 minutes after boot
> and FrontBoard killing SwiftUI-heavy extensions at the 10-second scene
> watchdog. On that cache it writes 24,606,083 instructions in 212,573 page
> runs across 4,508 images, skips none, and leaves 250,443 unvisited
> candidates to the on-demand handler; a full pass takes about 95 s on an
> M5 Pro. The planner's speedups (parallel images, thread-local locale,
> word-keyed decode cache, verified PC-relative moves, bitmap sets) were each
> checked to produce byte-identical caches, including the bootstrap patch's
> output against HEAD. The 27.1 VirtualAudio reveal now accepts
> `PACIBSPPC`/`RETABSPPC` prologues and returns; the audiomxd crash those
> four patches triggered on 27.1 is root-caused as the pre-init
> DeviceStateManager read and fixed by
> `system-virtualaudio-cfw-device_state_null_gate` above.
> See [Duo bring-up](Guest/iphone_duo_bringup.md).

> **Foldable VM sub-type (2026-10-23):** `preboot-cfw-devicetree_foldable_vm_subtype`
> (guest system set, Preboot device-tree repair, on in `standard`, blocked in
> `tvos` and `tvos-4k`, not applicable to boards without an entry; verb
> `cfw patch-dt-foldable-vm-subtype`) rewrites the installed tree's root
> `target-sub-type` from `V68AP` to Apple's `V68VM2025` during `cfw install`
> and `cfw update-environment`, never during restore. SpringBoardFoundation
> then takes its VM path for the fold pose (restore at launch, persist after
> transitions). vphoned's new `display.posture` drives the pose through the
> test-automation override (`com.apple.springboard.testautomation` added to
> `VPhoneDaemon.entitlements`). See [Duo bring-up](Guest/iphone_duo_bringup.md#fold-posture-2026-10-23).

> **Foldable product identity and virtual hinge (2026-10-24):** the pose
> override above reaches SpringBoard only; CoreMotion's angle manager — and
> through it CoreDevice's `hingeAngle` capability and stream — reads a virtual
> hinge HID service instead, which a single-display guest never had.
> `preboot-exp-devicetree_foldable_product_id` (guest system set, Preboot
> device-tree repair, off in every preset after live measurement, foldable
> boards only; verb `cfw patch-dt-foldable-product-id`) replaces the installed
> tree's `/product/product-id` with the foldable board's own 20-byte token,
> taken from the donor `DeviceTree.v68ap.im4p` in the VM's FirmwareOriginals
> (never a synthesized value). Measured on duotest-m5: with the Duo token and
> one display SpringBoard crashed on its first CA commit — root-caused to a
> `CASecureIndicatorLayerInvalidName` exception ("Invalid indicator name
> Camera", the Duo camera-indicator lookup that one panel cannot satisfy) —
> which `system-springboard-cfw-fold_guard` below now swallows; the token
> stays off in every preset because the visual fold still needs the second
> panel (Apple's Duo simulator registers two displays in its device type):
> with the guard the guest boots under the Duo identity, the hinge chain
> runs end to end, but a measured book sweep (100°) leaves the screen
> pixels unchanged — no letterbox, split, or seam — so the patch remains
> research-only until a dual-display guest exists.
> `system-backboardd-cfw-hinge` (guest
> system set, on in `standard`, foldable guests only) installs
> `libvphonehinge.dylib`, which SystemHook loads into backboardd: it
> publishes a `HIDVirtualEventService` with usage page `0xFF0C`, usage `0x21`
> and reports angles built with HID.framework's
> `IOHIDEventCreateHingeAngleEvent(allocator, timeStamp, angleDegrees,
> mechanicalAngleDegrees, velocityDegreesPerSecond, options)` — the signature
> verified against macOS 27.0.1's HID.framework by reading the created
> event's own field description back, and checked in
> `make test-hinge`. vphoned's `display.posture` follows Apple's sweep model
> (suiatool's positions closed / book ~100° / open, per-direction duration,
> continuous and fade profiles, instant swap), publishing the sweep beside the
> pose override through the same preference-and-notification transport the
> accelerometer uses; every dispatch also publishes the newest sample
> (`VPhoneHingeLatest`) for the CMAngleManager stand-in in
> `libdevicehubfix` (v6) that answers DeviceHub's hinge stream in
> dtdeviceinfod — CoreMotion's own machinery is never started there, which
> the gate-only v4 (MotionThread assert), v5's first build (`dispatch_async`
> on the bridge's NSOperationQueue, `EXC_ARM_PAC_FAIL`) and v5's liveness
> test (kill EPERM on root's backboardd read as dead, `hingeAngle: false`)
> each crashed or closed the chain on. See
> [Duo bring-up](Guest/iphone_duo_bringup.md#virtual-hinge-2026-10-24).

> **SpringBoard fold-guard (2026-10-25):** `system-springboard-cfw-fold_guard`
> (guest system set, on in `standard`, blocked in `tvos`, `tvos-4k` and
> `homepod-mini`, foldable guests only, iOS 27+; installs
> `/usr/lib/libvphonefoldguard.dylib`) is the companion that makes the Duo
> product token bootable at all. With the token active and one panel,
> SpringBoard dies during its first CA transaction commit: the Duo
> branches build a secure status indicator for the camera, and
> `-[CASecureIndicatorLayer _copyRenderLayer:layerFlags:commitFlags:]`
> raises `CASecureIndicatorLayerInvalidName` ("Invalid indicator name
> Camera") — an NSException on the main thread, SIGABRT, twice per boot
> (measured on duotest-m5, iOS 27.1 24A94425; crash reports in the guest's
> osanalytics DiagnosticReports). The guard — SystemHook loads it into
> SpringBoard only — method-swizzles that one QuartzCore method with an
> `@try`/`@catch` that logs (first five exceptions to
> `/var/mobile/Library/Caches/vphone-foldguard.log`) and returns nil, so
> the commit proceeds without the camera indicator. Measured: with the
> guard, a boot that crash-looped twice before reaches the home screen and
> stays up; the guard log shows the install line and exactly the two
> swallowed exceptions. The camera status dot is the casualty, and the
> casualty is now fully explained: the guest's QuartzCore statically
> accepts the name ("Camera" sits beside "Microphone" and
> "MicrophoneAccessibility" in the static table), but the validator first
> consults a runtime registry the window server fills per display, the
> virtual panel registers no indicator slots, and the registry rejects
> every name — measured by aliasing Camera→Microphone, which still raised.
> Filling that registry is backboardd's job (the
> `CAWindowServerDisplay` registration surface), the same missing
> display-topology family as the fold layout; no client-side repair
> exists, so the lean catch stands. See
> [Duo bring-up](Guest/iphone_duo_bringup.md#springboard-fold-guard-2026-10-25).

> **iPhone Duo bring-up (2026-10-23, first boot fails):**
> `iPhone19,4` / V68AP, iOS 27.1 (24A94425), is registered with one outer
> display and paired with cloudOS 26.4 (23E5207q). Its device tree reports
> `arm64e.x1`. This exercises the existing standard iOS 27 / ARM64E_X1 patch
> selection on a new userland; it introduces no new instruction patch or
> preset. Restore and CFW install completed, but setup and a windowed boot
> panic with PID 1 SIGILL. Installed dyld still uses CSSC instructions that
> this Mac lacks and current X1 lowering does not cover; exact fault-site
> attribution remains unverified. Four optional VirtualAudio patches also
> failed. Neither successful boot nor dual-display/hinge support is established. See
> [inputs, evidence and boot results](Guest/iphone_duo_bringup.md).

> **Experimental full OTA System update (2026-10-20):**
> `system-exp-ota_userland` is off in Standard and the TV presets. For a stopped
> iPhone/iPad guest with a snapshot and prepared target firmware, it replaces
> System from a matching full OTA and reapplies the target Guest patches from
> a fresh receipt state. Data/User volumes and SEPStorage are retained. The same
> private disk clone receives the target kernelcache and TXM payloads under their existing IMG4
> manifest; this reuses the existing declared TXM patches, adding no instruction
> patch or fixed offset. The whole System/kernel/TXM transaction aborts on compatibility
> patch failure. This is host-driven payload installation; Apple's UpdateBrain
> protocol and application migration are not implied. See
> [the implementation and validation record](Restore/data_preserving_full_ota.md).

> **OTA removed-app state (2026-10-25):** capture preserves the guest's removed
> system-app IDs, and complete/commit/verify include LaunchServices placeholders
> in their absence checks. Reconciliation retains the original removal backups
> and independent app data. No instruction patch or preset changes; see the
> [removed-app regression](Restore/data_preserving_full_ota.md#preserve-removed-system-apps-2026-10-25).
> **2026-10-21 correction:** full updates also stage, validate and install
> `payloadv2/links.txt`. The 24A446 iPad OTA omits 24,835 duplicate paths from
> its numbered chunks. Missing J410 media resources made audiomxd trap in
> CFRetain(NULL), blocking migration through liveactivitiesd and locationd.
> No new binary patch is used; the installer restores the OTA's own hard links
> through confined parent descriptors and checks the resulting inode.
> Corrected migration and the reference-machine clone subsequently booted with
> retained data. The clone's protected app reopened its existing data offline
> at 4/3/2 GB with service profile none. Separate explicit compatibility steps
> preserved a legacy re-signed app container and synchronized 38 retained Apple
> app programs from the target IPSW; these are not new binary patches.
> **2026-10-21 orchestration:** `fw ota` now captures guest policies, takes one
> disk/SEP/NVRAM checkpoint with separate host configuration/firmware backups,
> prepares a pinned target, verifies real target migration, restores Auto-Lock
> through Settings with effective-policy readback, and reapplies the saved service
> profile. The installer stages target removable-app programs on System;
> `ota.apps.apply` updates matching, already-installed Apple app programs at their
> original container paths and quarantines old serialized placeholders. Legacy
> third-party container signing is a preflight refusal, never an implicit repair.
> This adds no instruction patches. Full application and performance equivalence
> remain outside this result; see the runbook for current verification scope.

> **iPhone19,2 / ARM64E_X1 compatibility (validated 2026-10-17):** the tested
> pairing is iPhone 18 Pro 27.0.1 (24A446), V63AP, with cloudOS 26.4
> (23E5207q). Cache discovery selects `dyld_shared_cache_arm64e_x1` and its
> matching subcaches; ordinary arm64e caches remain on their existing path.
> MachOKit 0.54.1 supplies the X1 cache format support. The `standard` preset
> selects the following boot-essential patches when their iOS 27 applicability
> matches; non-X1 Mach-O inputs are unchanged.
>
> | Patch | Target | Final role |
> | --- | --- | --- |
> | `kernel-boot-arm64e_x1` | vphone600 kernel | Admit subtype 12 at grading, exec-PAC and authenticated shared-region gates |
> | `system-dyld-boot-arm64e_x1_bootstrap` | `/usr/lib/dyld` | Reach PID 1 before runtime handling exists |
> | `system-launchd-boot-arm64e_x1_bootstrap` | `/sbin/launchd` | Reach exception-service installation |
> | `system-fsck-boot-arm64e_x1_bootstrap` | `/sbin/fsck` | Keep the forked checker off runtime-modified signed pages |
> | `system-mount-boot-arm64e_x1_bootstrap` | `/sbin/mount` | Keep forked mount helpers off runtime-modified signed pages |
> | `dyld-boot-arm64e_x1_bootstrap` | 38 shared-cache images | Lower the measured pre-handler and pre-fork closure; re-attest pages and refresh corecrypto's FIPS HMAC |
> | `restoreramdisk-boot-apfs_sha3_hash` | RestoreRamDisk and RestoreTrustCache | Select the iOS 27 root-hash algorithm and admit the re-attested sealing tool |
>
> **Kernel reveal.** The analyzed image is `kernelcache.research.vphone600`,
> XNU `12377.100.591.502.1`, UUID
> `784F88D3-2AF5-3D4A-AB00-365607646E44`. Its symbol JSON is absent from this
> checkout, so the `ml_grade_binary` and `exec_mach_imgact` names are XNU and
> control-flow correlations rather than recovered symbols. The measured subtype
> comparisons are `0xfffffe000933ceb4`, `0xfffffe00091bad94` and
> `0xfffffe00091bb088`. Runtime patching does not embed those addresses: it
> finds the unique subtype-2 grading tail, follows real BL callers to the
> IMGPF_NOJOP/EBADARCH gate, then finds the shared-region gate and its subtype-2
> success assignment. All three must resolve uniquely. Each site branches to an
> allocated cave containing `cmp Wn,#12; ccmp Wn,#2,#6,ne; b resume`, preserving
> subtype 2 and making subtype 12 take the same authenticated paths.
>
> **Instruction path.** `VPhoneArm64eX1Lowering` converts the supported
> PAuth_LR return/authentication forms to their SP-only forms and scalar
> ADDPT/SUBPT/MADDPT/MSUBPT to existing arithmetic encodings. This removes PC
> binding and CPA overflow poisoning; it provides instruction compatibility,
> not hardware-equivalent X1 security. Before installing the exception service,
> launchd forks an isolated child that executes `PACIBSPPC` and `ADDPT`. Native
> success leaves compatibility disabled. A trap or probe failure installs the
> service and propagates its port through spawn before child execution.
> Supported faults suspend the target, validate the faulting word, create a
> private writable copy of that process's page, write one lowered instruction,
> restore RX, flush the instruction cache and retry the same PC. PID 1 uses the
> per-thread fallback because it hosts the service; other tasks use
> `task_suspend` to close the thread-creation race. Unknown or unsupported
> instructions are forwarded to the captured kernel exception destination.
>
> **Restore seal.** For iOS 27 with cloudOS 26.4, the restore patch resolves the
> manifest-selected `SystemVolume` `isys` root-hash payload first. Only hash type
> `0x106` (`sha3_256_4k`) needs a changed restore tool. For that image, the
> patch resolves the manifest-selected ramdisk, locates `apfs_sealvolume`'s
> options template from its unique getopt xref and decoded copy sequence,
> changes hash type `1` (`sha256`) to `0x106`, and re-attests the modified
> CodeDirectory page. The ordered trust-cache pass replaces exactly that
> executable's cdhash, preserves the two metadata bytes and restores v1 sort
> order. The 27.0.1 (24A446) IPSWs for iPhone17,1–5 and iPhone18,1–5 all
> have root-hash type `1` in both SystemVolume entries; iPhone19,2 has `0x106`.
> SHA-256 images leave both cloudOS restore files pristine. The logical plan
> and template key keep the user's selection stable; `PatchPlan.plist` records
> the patch as not applicable and omits it from the effective plan and restore
> receipt. Unknown
> hash types or malformed metadata abort before patching; discovery,
> signature coverage or uniqueness failures also abort the SHA3 patch.
>
> **Validation and limits.** On an M5 Max guest, the unsupported-feature path
> completed a clean offline restore, logged `Sealing System Volume`, and the
> first disk boot logged successful on-disk root-hash authentication. Settings,
> Safari and Calculator launched; the instruction probe completed 20,000 calls
> without a repeat fault or file change, the unknown-opcode case retained
> SIGILL, and the task-suspension fix passed 240 concurrent vphoned snapshot
> requests across ten restarts. Focused Swift/C tests, strict arm64e compilation
> and analysis, the signer suite, the complete Debug bundle build and bundle
> admission pass. The native fast path still requires validation on a host whose
> virtual CPU exposes both probed X1 features. The tvOS presets block all seven
> iPhone-specific X1 and restore patches, including for a tvOS 27 userland.
>
> **tvOS 26.4 support (2026-10-15).** AppleTV5,3 / J42d uses a
> monolithic arm64 TVOS userland with the cloudOS 26.4 vphone600ap kernel.
> `devicetree-cfw-tv_app_architecture` copies the donor's concrete app architecture.
> `system-dyld-exp-tv_tpro` reversibly disables the two hardware-TPRO parameter
> lookups in standalone and cached dyld, preserving native page-in linking.
> `kernel-exp-tv_tpro_pagers` changes the native tunable's four-byte default
> through validated name/descriptor/startup-registration discovery. Both TPRO
> operations are opt-in, off in Standard. The persistent kernel fix allowed a
> normal four-CPU boot into TVSetup and Settings, with arrow/Return/Escape input.
> Activation remains Failed; audio and third-party apps are unverified.
> Diagnostic helpers and unused approaches are excluded from this PR;
> a normal boot and Escape navigation were confirmed after their removal.
> TV dyld installation requires a private APFS disk clone and validates its original
> standalone backup and cache undo before modifying an existing patch. Paired
> errors abort the install before disk replacement; rollback retires the undo
> record only after cache re-attestation and standalone restoration succeed.
> Details and evidence: [tvOS support](Firmware/tvos_support.md).
>
> **tvOS follow-up (2026-10-15).** Apple TV guests run vphoned. tvOS dyld
> refused the iOS-platform daemon (`wrong platform to load into process`), so the
> bundle also ships `vphoned-tvos`, the same arm64 binary with `LC_BUILD_VERSION`
> platform tvOS, chosen by guest family at install and launch.
> `system-vphoned-boot-install` and `system-launchd_cache_loader-boot-unsecure_cache_gate`
> are admitted for TV; the cache-gate patcher NOPs the same branch in the
> plain-arm64 loader unchanged. `system-dyld-exp-tv_tpro` and
> `kernel-exp-tv_tpro_pagers` now apply to every tvOS 26 userland on cloudOS 26.4
> rather than 26.4 alone: the tunable is the cloudOS kernel's, and tvOS 26.6
> (23L773) needed and booted with both. The new `tvos` preset is Standard with
> both on and the iOS display, camera, audio, sensor, GPU and shared-cache
> patches off. vphoned's consumer `0x0C/0x40` is the TV button (press type
> 17): Home on a press, Control Center when held.
>
> **Apple TV 4K (2026-10-15).** New research patch
> `system-tv-exp-ota_userland` (manual-only; on only in the `tvos-4k` preset) empties
> the restored System volume and `aa extract`s the AppleTV14,1 OTA's
> `payloadv2` chunks staged in `<vm>/OTAUserland`, over an Apple TV HD 26.6
> restore with the J255 identity. On an arm64e TV guest the installer also admits
> `system-extensions-boot-gpu_bundle` and rewrites the paravirtual GPU driver's
> and compiler plugin's `LC_BUILD_VERSION` to tvOS (`MachOBuildPlatform`) before
> re-signing; the guest then renders through the paravirtual GPU at 2160p.
> `fw prepare --device AppleTV14,1` stages the OTA natively (system
> AppleArchive: AEA decryption, segmented archive) and the `tvos-4k` preset is
> `tvos` with the GPU bundle and the userland swap on and both TV TPRO patches
> off. See
> [tvOS support](Firmware/tvos_support.md#apple-tv-4k-from-its-ota).

> **Apple TV 4K, 4th generation (2026-10-23).** `AppleTV18,1` / `J265AP`
> reuses `tvos-4k`, the Apple TV HD 26.6 restore base, and cloudOS 26.4 beta
> (`23E5207q`). Its only catalog release is the supplied Pallas tvOS 27.2 beta
> OTA (`24K120`; asset alias `24K6120` shares the archive). OTA manifest
> validation refuses other OS versions for this board. Patch discovery preserves
> the recorded J265 identity over the HD manifest, and Launchpad selects the 4K
> preset. The real OTA staged its
> J265 tree and all 42 chunks; `fw patch` processed all 11 components with 239
> patches, and the selected cache patchers passed dry runs against its userland.
> Launchpad and the bundle move to series 2.13 so earlier Launchpad builds cannot
> choose the HD preset for the new device. Restore and full CFW installation
> completed on 2026-10-24. The guest daemon reports AppleTV18,1 / 27.2.0;
> rendering initially stalled in SetupBackground and then reached the animated
> 4K Hello screen after repairing its service lookup. Select did not advance
> the new Setup scene; no Hello-handler entry appeared in a live log capture.
> Live validation exposed a missing sandbox lookup in the new SetupBackground
> app: a native probe with its original three entitlements took 15.049 seconds
> to initialize PBSDisplayManager; adding only
> `com.apple.security.exception.mach-lookup.global-name = [com.apple.PineBoardServices]`
> reduced that to 0.005 seconds. The 10-second scene watchdog kills the original
> before initialization returns. New declaration
> `system-setupbackground-exp-pineboard_lookup` targets that app's entitlements,
> applies only to 27.2, and remains opt-in; the installer also
> requires an Apple TV identity. It preserves all existing entitlements and
> backs up the executable for reversal through `cfw update-environment`.
> The supported `tvos-4k` preset instead selects `system-tv-exp-legacy_setup`
> for 27.2: `TVSetupV2.Enabled = false` and `TVSetupV2HW.Enabled = false` in
> `System/Library/FeatureFlags/Domain/CompanionServices.plist`. PineBoard then
> selects the native TVSetup retained in this OTA. A cold-boot experiment
> reached its 4K Language screen; consumer HID and native keyboard Down/Up
> moved focus to Simplified Chinese and restored English. This does not
> complete setup or select a language. Both feature dictionaries are required;
> metadata, unrelated flags and encoding are preserved, and a `.bak` supports
> reversal through the normal guest patch selection. All 59 focused tests
> passed. The installed final bundle `2.13.0-local.aaf2152c` cold-boots to
> Language on two cold boots (vphoned in six and five seconds) with the
> temporary override removed and no crash reports. Its System `.bak` matches the
> original plist and SetupBackground is restored byte-identically. Native
> Return advances to Region; Escape returns to Language, without completing
> setup. No instruction patch or new preset is introduced. The installer promotes the
> installed TV OTA's SystemVersion after committing its private disk clone,
> fixing the host's stale 26.6 restore-base label. See
> [bring-up notes](Firmware/tvos_support.md#apple-tv-4k-4th-generation).

> **tvOS 27 on the Apple TV 4K (2026-10-16).** No new patch. The 4K's tvOS 27.0
> (24J361) OTA goes over the HD's 26.6 IPSW, and the plan resolves for the OTA's
> version. `system-tv-exp-ota_userland` now applies from 26.0 on (it was gated on
> 26, so a 27 plan dropped it and the HD userland booted and panicked). The
> `tvos-4k` preset and arm64e TV admission add the iOS 27 shared-cache patches
> `dyld-boot-iomfb_force_kern`, `dyld-boot-lockdown_mode`,
> `dyld-boot-lsd_embedded_reg`, `dyld-boot-maxslide` and `dyld-boot-xpc_lwcr`,
> all gated on 27. Validated on `tv27-4k`: TVSetup at 2160p in the host window,
> input, GPU time, vphoned. See
> [tvOS support](Firmware/tvos_support.md#tvos-27-on-the-apple-tv-4k).

> **iOS 27 disabled services (2026-10-13):**
> `system-jetsamproperties-cfw-disable_allowed` removes every
> `DisableAllowed = false` from
> `System/Library/LaunchDaemons/com.apple.jetsamproperties.*.plist`. The guest
> system set selects it for iOS 27 only; `cfw install` and environment updates
> back each file up and restore it when deselected. iOS 27 marks 19 daemons
> this way, and launchd loads a marked job whatever its disabled override says
> (`force-enabled` in `launchctl print`). launchd reads the file the device
> tree's `target-type` names, so every guest but the iPhone17,3 was affected:
> the trimmed service profile left five jobs running and a slimmed template's
> setup boot failed its check, and the OTA block could not stop
> `mobile.softwareupdated`. No executable is patched. On an iPad16,1 24A446
> guest the patch took 19 marks out of each of J410 and J411; after it no job
> was force-enabled, none of the profile's 144 was loaded, and a slimmed
> template built from nothing passed its setup boot. See
> [evidence and verification](Guest/service_trimming.md#ios-27-and-disableallowed).

> **iOS 27 locationd startup (2026-10-08):**
> `system-locationd-cfw-disable_auto_cohort` disables only `CLAutoCohort` in
> `System/Library/FeatureFlags/Domain/CoreLocation.plist`. The guest system set
> selects it for iOS 27 only; `cfw install` and environment updates back up the
> original plist and restore it when deselected. Independent location silos
> avoid the startup queue hangs/PAC failures seen with automatic cohorts on
> the cloudOS 26.4 research kernel. No executable or PAC instruction is patched.
> On `loc27-iphone` (24A435), 20 locationd restarts and 5 cold boots answered
> before watchdog recovery; restoring the original flag brought back repeated
> launches and a watchdog kill. A fresh iPad16,1 24A446 guest reproduced the
> same PAC failure with stock cohorts; with this change, another 20 restarts
> and 5 cold boots passed, with no new crash reports or watchdog actions. See
> [evidence and verification](Guest/locationd_27_0_1_startup_race.md).

> **Patch sets and presets (2026-09-28):** every patch is now *declared*, and
> selection happens before any byte is written. The declarations live in nine
> bundled patch sets under `VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/`
> (`bootchain`, `kernel.base`, `kernel.cfw`, `kernel.hypervisor`,
> `kernel.frida`, `devicetree`, `guest.system`, `guest.display`,
> `guest.identity`), listed by `FirmwarePatchSetCatalog`. A declaration's
> identifier is the record identifier the patcher already emits, or the common
> prefix when one patch writes several sites — so `jb.kcall10` is one selectable
> patch covering its four records, and `sandbox_ext` covers every
> `sandbox_ext_<index>`. 122 patches are declared in total. `vphone-cli fw patches`
> prints them; `--json` is what the Launchpad patch editor reads.
>
> Two presets ship, prewritten, in
> `VPhone.bundle/Contents/Resources/patches_presets/`. Both name all nine sets and
> differ only in their selection: `standard` (the default, and what a VM gets
> unless `--preset` says otherwise) blocks the four Frida relaxations, the
> three `hv_vmm_present` concealment patches, and the iPhone17,3 identity rewrites;
> `extended` blocks nothing.
>
> **iPad guests (2026-10-01; every current iPad 2026-10-02):** five DeviceTree
> patches, on in `standard`, exist only for a VM whose userland comes from an
> iPad restore IPSW (iPad mini A17 Pro, iPad A16, iPad Air M3 11/13, iPad Pro
> M4 and M5 11/13 — see `VPhoneGuestDevice.known`). Since 2026-10-02 their
> values are read at `fw patch` time from the board's own
> `DeviceTree.<board>.im4p` in the restore tree rather than a table, so an
> M-series board keeps Stage Manager (no `disable-chamois`) and the iPad (A16)
> has no `medusa-overlay-app-capability`: `devicetree-cfw-ipad_artwork`,
> `devicetree-cfw-ipad_product`, `devicetree-cfw-ipad_buttons`,
> `devicetree-cfw-ipad_identity` and (2026-10-02) `devicetree-cfw-ipad_audio`,
> which takes the board's `/product/audio` node. (`/product/haptics`, which no
> iPad tree has, is not one of them: since 2026-10-03
> `devicetree-cfw-product_haptics_node` removes it from every guest's tree,
> iPhone and iPad alike — see "Why the haptics node goes" below.) They are
> written to a second device tree,
> `Firmware/all_flash/DeviceTree.vphone600ap.guest.im4p`, which `fw prepare`
> copies from the vphone600 one and the hybrid manifest names as `DeviceTree`;
> `RestoreDeviceTree` keeps pointing at the original, so restore still boots
> the `iPhone99,11` identity `restored_external` checks. On that copy the
> iPhone-shaped base properties (`artwork_device_subtype`,
> `island_notch_location`, camera offsets) and the `-exp-` identity rewrites
> are not applied; the iPad edits set the root `model` / `target-type` /
> `target-sub-type` / `compatible` to iPad16,1 / J410 / J410AP /
> `J410AP, VPHONE600AP, AppleVirtualPlatformARM`, `/product`
> `artwork-device-idiom` to `pad` (subtype 2266, scale 2), fill the `syscfg`
> placeholders J410AP carries with its values, add the iPad multitasking
> capabilities, and remove the phone-only placeholders and the ringer switch.
> GPU, framebuffer and boot properties stay vphone600's. `cfw install` skips
> `preboot-exp-devicetree_identity` on an iPad guest. Values were copied from
> `DeviceTree.j410ap.im4p` in `iPad16,1,iPad16,2_26.6.2_23G90_Restore.ipsw`.
>
> A fifth, `llb-cfw-display_scale`, fixes the screen scale. UIScreen's scale is
> MobileGestalt's `main-screen-scale`, and libMobileGestalt — the only reader
> of the property in the 26.6.2 userland — takes it from
> `IODeviceTree:/chosen/display-scale`. LLB (single-stage boot) writes that
> property as `((v_depth >> 16) & 0xff) + 1` from the boot video word, which
> the paravirtual display always reports as 3x, whatever the panel's size or
> the `pixelsPerInch` VZ is given (264 and 326 were tried). At 3x the iPad
> mini's 1488x2266 panel is 496x755 points and iPadOS lays its home screen
> out over itself. The patch, anchored on the ADRP+ADD of the `display-scale`
> literal and the following `ubfx wN, wM, #16, #8 ; add wN, wN, #1 ;
> str wN, [x0]`, replaces the `add` with `mov wN, #<artwork scale>`
> (`ARM64Encoder.encodeMovzW`). Found at `LLB.vresearch101.RELEASE` 0xB9CC in
> cloudOS 26.4 (23E5207q). Editing the MobileGestalt cache's cached screen
> struct (`oBbtJ8x+s1q0OkaiocPuog`, `{1488, 2266, 326, 3.0f}`) does not change
> the live scale. Emitted only for an iPad guest.
>
> See `Documents/Guides/ipados.md`.
>
> **Other iPhone models (2026-10-05, issue #576):** the four
> `devicetree-cfw-ipad_*` presentation patches and `devicetree-cfw-ipad_audio`
> now apply to every guest device except the iPhone17,3
> (`VPhoneGuestDevice.presentsBoard`): the iPhone 16 Plus, 16 Pro, 16 Pro Max
> and 16e (iPhone17,4/1/2/5) and the iPhone 17, Air, 17 Pro, 17 Pro Max and 17e
> (iPhone18,3/4/1/2/5). No patch is new and the IDs keep their `ipad_` names,
> which presets list. Such a guest gets the separate installed tree, the board's
> identity, `/product` and audio node, and skips
> `preboot-exp-devicetree_identity`, as an iPad does. The phone properties
> (`island-notch-location`, `ui-reachability`, `oled-display`, volume-button
> geometry, `watch-companion`, `carplay-2`) take the board's values instead of
> being removed. `llb-cfw-display_scale` is emitted only when the guest's scale
> is not 3x, so it stays iPad-only. Checked on iPhone18,1 (V53AP) 26.6.2
> (23G90) with cloudOS 26.4 (23E5207q): installed tree `model` iPhone18,1,
> artwork subtype 2622 at 3x, `/product/audio` acoustic ID 8021 from the board;
> the guest booted to the home screen at 402x874 points. See
> `Documents/Guides/iphone-models.md`.
>
> **Only the camera remains of EXP by default (2026-09-28).** `standard` is now the
> JB baseline plus the virtual camera. Off by default, besides the concealment
> below: `watchdogd.hv_vmm_cache` (moved into
> `FirmwarePatchSetCatalog.hypervisorConcealmentPatches`, and no longer
> `bootEssential` — watchdogd only panics once the OID is renamed), the eight
> DeviceTree identity rewrites (`devicetree.target_sub_type`,
> `compatible_secondary`, `product.fdr_product_type`, `product.sub_product_type`,
> `product.unique_model`, `product.gestalt_variants_rename`,
> `arm_io.device_type`, `arm_io.soc_generation`), and the post-restore Preboot
> DeviceTree rewrite, now declared as `preboot_devicetree.identity`
> (`.prebootDeviceTree`, Guest Identity set). Until now that rewrite was undeclared
> and `cfw install` ran it on every VM; it now asks the plan first, and a VM with
> no plan still gets it. The last two groups are
> `FirmwarePatchSetCatalog.experimentalIdentityPatches`. Still on: the four board
> presentation properties, camera offsets, the camera / FaceTime / audio / IOPM /
> SMC / ISP nodes, and `camera_dsc`. Camera support reads `/product/camera`
> through MobileGestalt and does not depend on the identity rewrites. Issue #438
> (no location with EXP) is the reason. The `libvlocation.dylib` app hook that
> worked around it is removed, and `location.*` is back on IcliKit's locationd
> simulation with read-back. The Preboot DeviceTree comes from restore, so a VM
> restored with the identity on keeps it until it is restored again.
>
> **`hv_vmm_present` concealment is opt-in as of 2026-09-28, and it is not a
> preference.** `kernelcache_exp.hv_vmm` (the kernel OID rename plus the
> kernel-internal cstring mangle) and `hv_vmm_dsc` (the shared-cache mangle the JB
> system installer runs) were made default-on by commit 228326d; on a freshly
> restored 26.4 guest they are a brick. `bluetoothd` on 23E246 caches its
> `sysctlbyname("kern.hv_vmm_present")` answer in a `dispatch_once`, gets ENOENT and
> caches 0, and its chip-selection singleton then picks a transport from
> `MGIsDeviceOneOfType` — nothing matches a virtual iPhone, the singleton stays
> NULL, and it faults and crash-loops until launchd throttles it. `locationd` blocks
> on a synchronous call to the throttled Bluetooth XPC service, the
> `com.apple.locationd.migrator` datamigrator plugin hangs, and SpringBoard waits on
> migration: black screen, no panic. The addresses and the full chain are in
> `Research/Patches/hv_vmm_present_usermode_xrefs.md` (B.3 correction).
>
> Neither half is useful alone — the rename without the cache mangle breaks the
> graphics and ML paths, the mangle without the rename does nothing — so they are
> declared as a pair, `FirmwarePatchSetCatalog.hypervisorConcealmentPatches`, and a
> catalogue test refuses a shipped preset that enables one without the other. Both
> lost `bootEssential`, which they never were: a shipped preset that drops a
> boot-essential patch warns on every run. (The other former EXP patches stayed on
> in this first change; the note above turns everything but the camera off.) A VM
> records only the boxes its owner changed, in
> `<vm>/PatchSelection.plist`, and `fw patch` writes what it resolved to
> `<vm>/PatchPlan.plist` for `cfw install` to reuse.
>
> **Patch sets also load from outside the bundle.** A `.vphonepatchset` is a macOS
> loadable bundle whose `Contents/Resources/Manifest.plist` is read before any of
> its code is mapped, and whose executable exports one symbol,
> `vphone_patch_set_principal`, returning a `VPhonePatchSetPrincipal` that hands the
> pipeline one `BufferedPatcher` per component the plan enabled. Not
> `NSPrincipalClass`: PatchKit is built for library evolution, so a subclass of a
> PatchKit class is registered with the ObjC runtime only when its metadata is first
> realized, and `Bundle.principalClass` therefore resolves to the wrong class
> entirely. `VPhoneExecutable/VPhoneCommand/VPhonePatchSetExample` is the template
> and is what the loader tests load.
>
> An external set can patch the boot chain only, and reaches a run through a preset
> in `~/.vphone/patches_presets/` naming it by identifier *and* path — the manifest
> at that path has to declare that identifier. `vphone-cli patchset import` copies a
> set into `~/.vphone/patchsets` and ad hoc signs it, which is what makes a bundle
> straight out of Xcode loadable at all: the linker signs the Mach-O but seals no
> resources, so `codesign --verify` rejects it until one `codesign --force --sign -`
> pass over the bundle fixes it. The signature is re-verified from disk at every
> load. Root `cfw install` loads no external set, so nothing here is on a privileged
> path.
>
> **Version gates replaced three flags.** The patches `--frida`,
> `--force-exc-guard` and `--force-dsc-maxslide` controlled now carry a structured
> `VPhonePatchApplicability`: `kernel-boot-thread_guard_violation` is pinned to
> `iOSBase: .major(18)` (whose runningboardd trips a flavor-10 Mach port guard and
> crash-loops the UI), `dyld-boot-maxslide` to `.major(27)`, and the two
> `kernel-exp-frida_*` patches to `cloudOS: .atLeast(26, 4)`. A preset can turn a
> patch off, and a VM can turn one on that its preset leaves off, but neither can
> widen a version gate — so forcing the guard or the slide onto a 26.x base is no
> longer possible. That capability was opt-in for third-party RASP SDKs and was
> never required to boot.
>
> Two of the three flags are gone from the surface as well: `--force-exc-guard` no
> longer exists, and `--frida` survives only on the `patch-component` developer
> subcommand, not on `vm create` or `fw patch`. `--force-dsc-maxslide` is gone too
> (2026-09-30): it was removed from `vm create`, `restore`, `cfw install`,
> `VPhoneVirtualMachineCreateOptions`, the Launchpad new-machine sheet, the
> Launchpad control verbs and the helper's `installCustomFirmware` XPC signature.
> On a 27 base it never reached the patcher at all: the installer passed `--force`
> only in a branch below the `27.` and `26.0`/`18.` cases, which the plan had
> already closed. A helper built before this change has a different hash and shows
> as outdated, so Launchpad reinstalls it before it is called with the new signature.
>
> The `iosBaseIs18` / `iosBaseIs27` booleans are gone from the pipeline too: it now
> carries a parsed `VPhoneVersion` (major, minor, patch). Two things still branch
> on the release rather than on a selection, because they change *which shapes a
> patch looks for* rather than whether it runs: the 18.x skywalk-netagent
> boot-arg, and `KernelJailbreakPatcher.applyIOS27`.
>
> **Byte-identity check (2026-09-28):** the golden corpus was re-run over cloudOS
> 26.4 with iOS 26.1, 26.4 and 27.0 bases. `--preset standard` reproduced the
> pre-patch-set output for all three, digest for digest, and `--preset extended`
> reproduced the old `--frida` case exactly. No run emitted the
> `declared by no patch set` warning, so every record the boot chain emits is
> covered by a declaration. The one case that no longer exists is
> `--force-exc-guard` on a 26.1 base, for the reason above.

> **Current product scope (September 2026):** the tables below preserve the
> historical patch comparison. The public runtime now exposes only JB. Guest
> package managers, Procursus, and first-boot package setup are outside this
> repository. The native Swift JB install retains the base system patches,
> launchd jetsam guard, debugserver entitlement edit, iOS 27 Campo entitlement
> edit, GPU driver, mandatory vphoned, and the small vphone launchd hook described
> below. The JB firmware pipeline also runs the former EXP DeviceTree
> identity/camera patches. The JB system installer runs the former EXP DSC camera
> patch, watchdogd patch, and post-restore Preboot DeviceTree rewrite. The former
> EXP kernel OID rename and its DSC half are the exception: declared, but off in
> `standard` since 2026-09-28 for the reason in the note above. `SPOOF_BUILD` remains opt-in and updates the
> rootfs and installed SystemOS SystemVersion.plist copies, plus the Preboot
> Cryptex copy when present. These are install-time integrations;
> successful patch dry-runs do not establish guest boot or Camera.app behavior.
> Old variant rows are research history,
> not available install modes.

> **Integration check (2026-09-25):** A clean `/tmp` restore tree assembled
> from cloudOS 26.4 (23E5207q) and iPhone17,3 iOS 27.0 (24A435) completed
> the public `fw patch` command with 191 records: 7 former EXP kernel records
> and 23 DeviceTree records. The unchanged BuildManifest retained its input
> SHA-256. Against the existing iOS 27 VM's read-only system image,
> `patch-hv-vmm-dsc --dry-run` found 29 writable cstrings and 15 blacklist
> entries; `patch-camera-dsc --dry-run` found six methods. A copy of that
> VM's watchdogd was patched, passed `codesign -v`, and was unchanged on a
> second run. The Preboot DT rewrite succeeded on a copy and was likewise
> unchanged on a second run. The original VM disk was not modified or booted.

> **Camera hooks and environment update (2026-09-25; not yet verified in a
> guest):** `cfw install` also places `libvcamcaptured.dylib` and
> `libcamfix.dylib` in `/usr/lib`. SystemHook treats
> `/usr/libexec/cameracaptured` as an injection target and loads
> `/usr/lib/libvcamcaptured.dylib` there, and loads `/usr/lib/libcamfix.dylib`
> into app processes that already have AVFoundation loaded. Neither needs
> ElleKit or a bootstrap: both hooks install their own Objective-C method
> replacements. A missing library is skipped silently; other load failures are
> logged to `vphone-systemhook.log`. A running guest receives changed copies of
> all four `/usr/lib` libraries through the vphoned environment update
> (`Research/vphoned_http_api.md`). Validation: `processes.list` shows
> `cameracaptured`, `vphone-systemhook.log` records `camera-hook=... result=loaded`
> for its PID, and `vcamcaptured.log` shows the hook installing its source.

> **Camera hook: front lookups and data-output frames (2026-10-10):** no new
> patch and no new library; `libcamfix.dylib` changes behaviour only. It
> answers front-camera lookups with the single vcam device and delivers
> data-output frames at the session preset's size, orientation and pixel
> format with device exposure values. Details and validation:
> [`Guest/virtual_camera_transport.md`](Guest/virtual_camera_transport.md#front-camera-clients-and-data-output-frames-2026-10-10).

> **Camera hook: the virtual camera on iOS 27 (2026-10-22):** no new patch
> and no new library; `libvcamcaptured.dylib` and `libcamfix.dylib` change
> behaviour only. iOS 27 has no `_sSourceList`, so `libvcamcaptured` adds
> the synthetic backing to the `FigCaptureSourceBackingsProvider` its
> microphone hook builds, which `FigCaptureSourceManager` publishes from.
> `libcamfix` gives Camera.app's `-capturePhotoWithSettings:delegate:` the
> full callback sequence it waits for before saving, and starts the preview
> scan for a client that skips `-startRunning`. Camera.app's shutter saves
> photos again on 27 (issue #707) and on 26.6.2, which shoots the same way.
> Camera.app video recording followed (see the next note). Details and validation:
> [`Guest/virtual_camera_transport.md`](Guest/virtual_camera_transport.md#ios-27-the-camera-through-the-backings-provider-2026-10-22).

> **Camera hook: Camera.app video recording (2026-10-22):** no new patch and
> no new library; `libcamfix.dylib` changes behaviour only. For a vcam-bound
> `AVCaptureMovieFileOutput` it writes the shm frames (and, when the session
> has a microphone input, an AVAudioEngine microphone track) to the
> requested movie with AVAssetWriter and sends the recording delegate its
> start and finish callbacks, so Camera.app's VIDEO mode saves movies on 27.0
> and 26.6.2. On 26.x it also sets `CAMCaptureCapabilities._videoSupported`,
> which comes from `AVGQVideoCameraCapability` and is NO on a guest, so the
> VIDEO tab appears. Details and validation:
> [`Guest/virtual_camera_transport.md`](Guest/virtual_camera_transport.md#cameraapp-video-recording-2026-10-22).

> **3D gyroscope core (2026-10-08; guest acceptance pending):**
> `system-backboardd-cfw-gyroscope`, declared in the Guest System set and
> selected by both presets on iOS 18+, installs `/usr/lib/libvphonegyro.dylib`.
> SystemHook loads it into backboardd through the same no-bootstrap daemon
> route as the camera hook. It publishes a virtual HID gyro (page `0xff00`,
> usage `9`); vphoned's `motion.gyroscope.set/get/clear` sends an atomic
> three-axis rad/s configuration through mobile's backboardd preferences and
> a Darwin notification. There is no system executable, kernel or DSC byte
> change. Disabling the patch removes the added library; live environment
> sync cannot reinstall an absent selected library. A provider/library update
> needs a reboot, without silently restarting backboardd. The VM display app's
> Features → Motion Sensors → 3D Gyroscope panel sends valid three-axis edits immediately,
> with a simulation checkbox that retains values and a reset that zeros all
> axes. `motion.gyroscope.set` accepts an optional Boolean `enabled` (default
> true); the panel checks `motion_gyroscope_toggle` support. Writes serialize
> and coalesce, preserve the latest values across old acknowledgements, and
> retry pending state after reconnect. HID enumeration
> and dispatch are observable separately from CoreMotion app acceptance; the
> platform capability gate and optional IMU match still require guest proof.
> Reveal evidence and manual acceptance: `Research/Guest/virtual_gyroscope.md`.

> **Gravity accelerometer (2026-10-20; iPadOS 26.6.2 guest verified):**
> `system-backboardd-cfw-accelerometer` in Guest System, selected by both
> presets on iOS 18+, installs `/usr/lib/libvphoneaccelerometer.dylib`.
> SystemHook loads it into backboardd and SpringBoard. A built-in HID accelerometer
> (page `0xff00`, usage `3`) supplies stationary gravity in g, with a monotonic
> timestamp and sequence. `display.rotation` publishes the matching physical
> pose through mobile preferences and a Darwin notification before its existing
> orientation request. The provider keeps that pose across SpringBoard
> relaunches; it streams while HID clients request a report interval and emits
> one sample on enumeration/configuration changes. Raw HID alone was verified
> insufficient on iPadOS 26.6.2: it enumerated but never gained a subscription,
> and the language-change wedge remained. The provider also classifies its
> stationary HID sample and posts it on BKOrientationManager's native queue,
> replacing the missing hardware classification stage. SpringBoard recomputes
> delivery and deferral after setup seeds the actual backlight state.
> No kernel, DSC or system executable bytes change. Disabling the patch removes
> its library; live environment synchronization never reinstalls an absent copy.
> Replacing the library requires a reboot, without restarting backboardd during
> environment installation. HID enumeration/dispatch alone do not establish
> SpringBoard recovery; native sink delivery and interface readback are
> separately observable. The isolated `gyro-regress` clone passed gravity-only
> four-direction rotation, rotation lock/unlock and same-pose language-change
> relaunch on `2.10.1-local.a8c22dce`, without a recovery respring/lock cycle.
> Evidence and regression procedure:
> `Research/Guest/springboard_orientation_stuck.md`.

> **Device attitude (2026-10-08; guest acceptance pending):**
> `system-apps-cfw-attitude` in Guest System is selected by both presets on
> iOS 18+. It adds `/usr/lib/libvphoneattitude.dylib`, loaded by SystemHook
> into apps, with no system executable, kernel or DSC byte change. Public
> CMMotionManager methods supply a stationary XArbitraryZVertical pose through
> polling/callbacks. vphoned persists degrees and publishes one packed Darwin
> notify state; apps receive radians, quaternion, matrix and matching gravity.
> Disabling restores the native path; removing the library and relaunching apps
> reverts injection. Live sync cannot reinstall an absent selected library.
> Features → Motion Sensors → Device Attitude provides live angle editing,
> a simulation checkbox and zero reset. Native host subscription tests and
> guest cross-compilation passed; manual guest acceptance remains.
> Contract and validation: `Research/Guest/virtual_attitude.md`.

> **Device attitude respring fix (2026-10-09; guest acceptance pending):**
> Two iOS 27.0.1 SpringBoard reports (19:41:21 and 19:42:51) show a
> Core Motion thread `SIGSEGV` at `0x10`, while the main thread calls native
> stop through `VPhoneAttitudeSession` during UIKit motion-effect subscription.
> The app-path loader had admitted SpringBoard; a fresh simulated session also
> stopped native updates without a preceding native start. SystemHook and the
> attitude dylib now exclude `/System/Library/` services and SpringBoard copies;
> native stop runs only for a previously forwarded native subscription.
> `system-apps-cfw-attitude` keeps its identifier, selection and iOS 18+ gate;
> no kernel, DSC or system executable patch is added. The new sensorless
> lifecycle regression fails before the stop guard and passes after it;
> sample, real host hook and injection-scope tests also pass. All 51 catalogue/
> model tests in six suites passed, and the full VPhone Debug bundle built,
> passed admission and strict deep signature verification. Updating the
> guest environment and rebooting is required for deployment verification.

> **Current launchd hook (2026-09-25; isolated VM verification):**
> `cfw install` now places `launchdhook-vphone.dylib` and a diagnostic
> `SystemHook-vphone.dylib` in `/usr/lib`, links `/vh` to the launchd hook,
> inserts a weak `/vh` load command for the
> launchd hook after `patch-launchd-jetsam`, and re-signs launchd. Until
> 2026-09-29 the hook also extended launchd's `Paths` and `LaunchDaemons`
> cache values with the bootstrap's `Library/LaunchDaemons`, under distinct
> `/System/Library/LaunchDaemons/vphone.*.plist` keys (the tested iOS 26.6.2
> cache loader ignored `/var/jb/...` and `/Library/...` keys). Those jobs did
> not match the plist path a package script boots out, so the hook no longer
> touches `xpc_dictionary_get_value`: vphoned loads the bootstrap's daemons
> after boot, as RootHide's `jbctl startup` does (`Research/roothide_loader_links.md`).
> The old binary in `zqxwce/vphone-cli-storage` at `2ef6b06` uses the real
> `/var/jb` key and `MSHookFunction` to intercept `xpc_dictionary_get_value`;
> it also requires `/cores/systemhook.dylib` and `/cores/libellekit.dylib` at
> startup. The bootstrap root is `/var/jb` or the one RootHide root vphoned
> installs, `.jbroot-000114514191980C`; spawns look for it until it appears.
> The hook also tries to remove PID 1's existing
> jetsam limit and suppresses future fatal task-limit assignments for PID 1.
> The launchd hook interposes PID 1's `posix_spawn` without loading ElleKit,
> so process injection remains available before a package manager installs it. It adds
> `DYLD_INSERT_LIBRARIES=/usr/lib/SystemHook-vphone.dylib` to `xpcproxy`,
> directly spawned bootstrap programs, and app executables under the system
> or application bundle paths. `SystemHook-vphone.dylib` interposes
> `posix_spawnp` inside `xpcproxy` to carry that environment into the final
> executable. Both stages preserve an existing `DYLD_INSERT_LIBRARIES`, avoid
> duplicate insertion, and honor `DISABLE_TWEAKS`, `_SafeMode`, and
> `_MSSafeMode` in the target environment. PID 1 logs child PID, executable
> path, and spawn status under `/var/mobile/Library/Caches`. SystemHook logs
> there when permitted and falls back to the app's own `Library/Caches` under
> its sandboxed home directory.
> SystemHook now carries the selected physical bootstrap path in
> `VPHONE_JB_ROOT` and loads that root's `usr/lib/TweakLoader.dylib` for App
> and bootstrap executables when it exists. ElleKit owns individual tweak
> selection and loading. `xpcproxy` only propagates the hook; unrelated
> system daemons do not load TweakLoader. Injected App and bootstrap processes
> also propagate to targeted `posix_spawn`, `posix_spawnp`, and `execve` calls.
> RootHide sandbox behavior and real ElleKit tweak loading still require
> runtime validation.
> On the rootless iOS 26.6.2 clone, `xpcproxy` called `posix_spawnp` for the
> package probe, and the final daemon reported
> `DYLD_INSERT_LIBRARIES=/usr/lib/SystemHook-vphone.dylib` and
> `systemhook_loaded=1`, including after its timed restart. Hooking only PID 1
> reached `xpcproxy` but did not reach the final daemon; the `posix_spawnp`
> bridge closes that observed gap. With `DISABLE_TWEAKS=1` in that same daemon
> plist, the final process instead reported `DYLD_INSERT_LIBRARIES=<absent>`
> and `systemhook_loaded=0`; the bridge logged `decision=disabled`. This
> chain was also tested with a RootHide-shaped `.jbroot-<16 hex>` fixture on the
> cloned VM: launchd imported its plist, translated `/usr/bin/...` to the
> physical randomized root, loaded ElleKit from that root, and the final
> daemon reported `systemhook_loaded=1` both at load and after its timed
> restart. This validates path handling and injection through the randomized
> root, not a complete RootHide bootstrap or a real tweak package.
> Apps use a separate direct launchd spawn path on this iOS 26.6.2 VM. On the
> rootless clone, launchd logged the Calculator app spawn with PID 454 and
> injection enabled; the app's own
> `Library/Caches/vphone-systemhook.log` recorded the same PID and Calculator
> executable path. The app reached the foreground and rendered normally.
> In the subsequent chain-load test, a signed diagnostic `TweakLoader.dylib`
> under the rootless bootstrap ran its constructor in the final daemon and in
> Calculator PID 403. Calculator's sandboxed container recorded the physical
> bootstrap path and a successful `dlopen`; the App stayed frontmost. Three
> separate RunAtLoad daemon probes with `DISABLE_TWEAKS=1`, `_SafeMode=1`, and
> `_MSSafeMode=1` each reported no `DYLD_INSERT_LIBRARIES` and
> `systemhook_loaded=0` after reboot. This diagnostic library proves the
> loading path, not real ElleKit or a tweak package.
> On 2026-09-25, the launchd and SystemHook spawn bridges gained a shared
> RootHide loader-link helper. Before a bootstrap executable is spawned, it
> creates or validates the `.jbroot` link beside that executable, accepting
> `/var` and `/private/var` spellings of the same root. On an isolated clone
> of `vphone-27.0-cloudos-26.4`, Xrash and Irisin App launches each created a
> missing link and reached the foreground. A dynamically loaded LaunchDaemon
> did not traverse the observed interposers; it still needed its link before
> service load. vphoned's initial fixed-directory link seeding remains in place.
> A bootstrap CLI probe then spawned itself with explicit stripped
> environments. Its `posix_spawn`, `posix_spawnp` (absolute program path), and
> `execve` children all reported `systemhook_loaded=1`,
> `VPHONE_JB_ROOT=/private/var/jb`, and the expected DYLD insertion. The first
> attempt exposed an alias gap: a `/var/jb/...` path was not recognized as
> the physical `/private/var/jb/...` root; both forms are now accepted.
> The previous central-log-only probe could not observe sandboxed apps even
> when SystemHook was loaded.
> The cloned `vphone-launchdhook-lab-26.6.2` booted with the weak dylib and
> retained a healthy vphoned API. Rootless and RootHide probes, each tested
> after reboot, were imported and spawned by launchd. The RootHide probe's
> plist named `/usr/bin/vphone-hook-daemon-probe`, which does not exist outside
> its randomized root; successful spawn confirms the in-memory physical-path
> translation. A read-only `MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES` probe
> returned active/inactive `-1/-1` for PID 1 with this hook. With `/vh`
> removed but the existing `patch-launchd-jetsam` left in place, the same
> probe returned `50/50` MB with fatal attributes. These tests used a cloned
> VM disk and separate host API port; the original VM was not modified.
> On 2026-09-25, the new interposed spawn hook was installed on the existing
> `vphone-launchdhook-lab-26.6.2` rootless VM and read back byte-for-byte.
> After a cold boot, launchd imported `wiki.qaq.ighostvtd.plist`; the service
> and its `wiki.qaq.ighostvt.service` Mach endpoint were running. The daemon's
> `DISABLE_TWEAKS=1` kept TweakLoader out of that process. Launchd logged a
> successful Calculator spawn; Calculator reached the foreground and its own
> sandbox log recorded `SystemHook-vphone.dylib` and a successful load of the
> installed ElleKit `TweakLoader.dylib`. This checks the injection chain, but
> does not prove that a particular tweak took effect.

> **`scripts/patchers/*.py` no longer exists.** The tables below cite those
> filenames throughout, because that is where each patch was first written and
> where its on-device validation notes were recorded. Every one is now a Swift
> patcher reached through `vphone-cli cfw <verb>` — read a citation as "the
> patch this became", and recover the Python itself from git history at
> `78cbeea` if you need to run it. The port is documented in the three
> "Swift port status" sections further down.

> **EXP is a JB superset.** Everything in the baseline tables below that is `Y`
> for JB is also `Y` for EXP. The columns are kept at three variants to avoid
> noise — the only place EXP and JB diverge is the **Experimental additions**
> below, all of which are EXP-only (JB and the other variants are deliberately
> unaffected). The EXP-only items, taken together:
>
> - **Kernel** — `KernelEXPPatcher` runs the `hv_vmm_present` sysctl OID rename
>   plus kernel-internal caller cstring/sandbox-profile-token mangle (formerly
>   wired into JB Group B as JB-26 — moved out).
> - **DeviceTree at fw_patch time** — 8 identity-rewrite property patches
>   (Tier 1b + 1c) flipping userland-visible identity surfaces toward
>   D47AP / iPhone17,3.
> - **DSC user-mode** — byte-5 cstring mangle of `kern.hv_vmm_present` with a
>   sign-in blacklist + per-page slot re-attestation (`cfw_patch_hv_vmm_dsc.py`),
>   companion to the kernel rename.
> - **watchdogd (EXP-JB-3.5)** — surgical 2-instruction patch + slot re-attest;
>   forces the cached "am I a VM?" byte to `1` so watchdogd's clean-exit branch
>   runs.
> - **Post-restore DT rewrite (EXP-JB-6)** — host-side rewrite of `devicetree.img4`
>   on the ramdisk's mounted rootfs for the three restore-fatal identity
>   properties (root `model`, `target-type`, `compatible[0]`) that broke
>   restore when applied at fw_patch time.
> - **SystemVersion.plist `ProductBuildVersion` (EXP-JB-7, opt-in)** — gated on
>   `SPOOF_BUILD=<id>`. Rewrites the build identifier in the rootfs and
>   cryptex copies of `SystemVersion.plist`.
> - **Camera.app accessibility** — at fw_patch time: the `/product/camera`
>   node, two `/product` cam-offset rewrites (Tier B), three new
>   `/product` child nodes `facetime` / `audio` / `iopm` (Tier C), and
>   five minimal `/arm-io` stubs `isp` / `ispRtb` /
>   `smc/iop-smc-nub/smc-ext-charger` carrying camera-front, camera-rear
>   and camera-driver (Tier F). At install time: the 5
>   `+[_NUStyleTransfer*Processor processWithInputs:...]` DSC
>   short-circuits in NeutrinoCore plus a 1-instruction
>   `+[AVCaptureDevice authorizationStatusForMediaType:]` rewrite in
>   AVFCapture that returns `Authorized` for any media type
>   (Stage 0 of the vcam stack — auth gate only; downstream
>   cameracaptured/vcamd plumbing for actual frame delivery is open
>   work). Together these make Camera.app's icon show on the home
>   screen and in Spotlight, the viewfinder render, and arbitrary apps
>   stop bailing on the camera permission check. The NeutrinoCore patch
>   stops the viewfinder's CIImageProcessorKernel chain from asserting
>   on a nil descriptor when ANE detection comes back NO on the VM.

## Boot Chain Patches

### Restore environment (iOS 27 + cloudOS 26.4)

| # | Patch | Component | Purpose | Regular | Dev | JB |
| --- | --- | --- | --- | :---: | :---: | :---: |
| 1 | `restoreramdisk-boot-apfs_sha3_hash.hash_type` | `RestoreRamDisk` / `apfs_sealvolume` | When the manifest-selected SystemVolume root hash names `0x106`, select `sha3_256_4k` and re-attest the modified Mach-O page; SHA-256 images remain unchanged | Y | Y | Y |
| 2 | `restoreramdisk-boot-apfs_sha3_hash.trustcache` | `RestoreTrustCache` | Replace the old sealing-tool cdhash with the re-attested cdhash and restore v1 entry order | Y | Y | Y |

The patch is gated to an iOS 27 base paired with cloudOS 26.4. Both paths are
resolved from `BuildManifest.plist`; discovery requires one semantic match and
the trust-cache update requires exactly one old cdhash, so an unknown restore
environment fails before publishing a partially patched tree.

### AVPBooter

| #   | Patch        | Purpose                          | Regular | Dev | JB  |
| --- | ------------ | -------------------------------- | :-----: | :-: | :-: |
| 1   | `mov x0, #0` | DGST signature validation bypass |    Y    |  Y  |  Y  |

New machines boot OpenAVB instead of AVPBooter, and OpenAVB checks no image
digest: `fw patch` skips this component on them (the patch stays selected and
planned, which is what the machine behaves as). Machines created before keep
Apple's ROM and this patch. See `Firmware/openavb_boot_rom.md`.

### iBSS

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded iBSS" in serial log                                                                                        |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass (`b.ne` -> NOP, `mov x0,x22` -> `mov x0,#0`)                                                      |    Y    |  Y  |  Y  |
| 3   | Skip `generate_nonce`               | Keep apnonce stable for SHSH (`tbz` -> unconditional `b`)                                                          |    -    |  -  |  Y  |

### iBEC

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded iBEC" in serial log                                                                                        |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass                                                                                                   |    Y    |  Y  |  Y  |
| 3   | Boot-args redirect                  | ADRP+ADD -> `serial=3 -v debug=0x2014e %s`; iOS 18 base adds `if_attach_nx=0x3` (skywalk BSD_ONLY: disables fsw netagents so Network.framework uses BSD sockets, fixes mDNSResponder skywalk-channel crash-loop / DNS) |    Y    |  Y  |  Y  |
| 4   | Modern bootx-handoff panic bypass   | `IBootPatcher.patchBootxPrecondition` NOPs gate TBZ via structural anchor (no hash/line tied); no-op pre-26.4      |    Y    |  Y  |  Y  |
| 5   | Ramdisk boot-args overwrite         | `ramdisk_build.py:patch_ibec_bootargs` rewrites string to `... rd=md0 ... wdt=-1 ...` (ramdisk-send iBEC only)     |    Y    |  Y  |  Y  |

### LLB

| #   | Patch                               | Purpose                                                                                                            | Regular | Dev | JB  |
| --- | ----------------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Serial labels (2x)                  | "Loaded LLB" in serial log                                                                                         |    Y    |  Y  |  Y  |
| 2   | `image4_validate_property_callback` | Signature bypass                                                                                                   |    Y    |  Y  |  Y  |
| 3   | Boot-args redirect                  | ADRP+ADD -> `serial=3 -v debug=0x2014e %s`; iOS 18 base adds `if_attach_nx=0x3` (skywalk BSD_ONLY: disables fsw netagents so Network.framework uses BSD sockets, fixes mDNSResponder skywalk-channel crash-loop / DNS) |    Y    |  Y  |  Y  |
| 4   | Rootfs bypass (5 patches)           | Allow edited rootfs loading                                                                                        |    Y    |  Y  |  Y  |
| 5   | Panic bypass                        | NOP `cbnz` after `mov w8,#0x328` check                                                                             |    Y    |  Y  |  Y  |

### TXM

| #   | Patch                                             | Purpose                                   | Regular | Dev | JB  |
| --- | ------------------------------------------------- | ----------------------------------------- | :-----: | :-: | :-: |
| 1   | Trustcache binary-search bypass                   | `bl hash_cmp` -> `mov x0, #0`             |    Y    |  Y  |  Y  |
| 2   | Selector24 bypass: `mov w0, #0xa1`                | Return PASS (byte 1 = 0) after prologue   |    -    |  Y  |  Y  |
| 3   | Selector24 bypass: `b <epilogue>`                 | Skip validation, jump to register restore |    -    |  Y  |  Y  |
| 4   | get-task-allow (selector 41\|29)                  | `bl` -> `mov x0, #1`                      |    -    |  Y  |  Y  |
| 5   | Selector42\|29 shellcode: branch to cave          | Redirect dispatch stub to shellcode       |    -    |  Y  |  Y  |
| 6   | Selector42\|29 shellcode: NOP pad                 | UDF -> NOP in code cave                   |    -    |  Y  |  Y  |
| 7   | Selector42\|29 shellcode: `mov x0, #1`            | Set return value to true                  |    -    |  Y  |  Y  |
| 8   | Selector42\|29 shellcode: `strb w0, [x20, #0x30]` | Set manifest flag                         |    -    |  Y  |  Y  |
| 9   | Selector42\|29 shellcode: `mov x0, x20`           | Restore context pointer                   |    -    |  Y  |  Y  |
| 10  | Selector42\|29 shellcode: branch back             | Return from shellcode to stub+4           |    -    |  Y  |  Y  |
| 11  | Debugger entitlement (selector 42\|37)            | `bl` -> `mov w0, #1`                      |    -    |  Y  |  Y  |
| 12  | Developer mode bypass                             | NOP conditional guard before deny path    |    -    |  Y  |  Y  |
| 13  | Pre-check admission: `mov w8, #0xa`               | Tolerated validation-type byte (iOS 27+)  |    -    |  Y  |  Y  |
| 14  | Pre-check admission: `strb w8, [x19]`             | Write the type byte to the out param      |    -    |  Y  |  Y  |
| 15  | Pre-check admission: `mov w0, #0x90`              | The policy walk's PASS status             |    -    |  Y  |  Y  |
| 16  | Pre-check admission: `b <epilogue>`               | Skip the policy callback walk             |    -    |  Y  |  Y  |

> **Pre-check admission (2026-10-04):** rows 13–16 (`txm-boot-precheck_admission`,
> iOS 27+ only) force the selector-24 pre-check policy walk in TXM 187.100.3
> (cloudOS 26.4) to its PASS exit. On an iOS 27.0.1 iPhone guest that walk
> rejects every manifest — Apple's own launchd included, re-signed or pristine —
> because the trust state it consults never loads from a 27.0.1 restore; the
> selector-24 caller then exhausts its ad-hoc / CMS / third fallback ladder and
> kills init (`0x32202`, previously misread as `0x12491`). The anchor is the
> walk's unique `mov x17, #0x7e51 ; blraa x8, x17` policy-callback invocation
> combined with its post-indexed `ldr x22, [x20], #0x40` table walk; on
> 187.100.3 that pair resolves to exactly one function. Full analysis and the
> experiment trail: `Research/Firmware/txm_selector24_cms_gate.md`.

## Kernelcache

### Base Patches (All Variants)

| #     | Patch                      | Function                         | Purpose                                            | Regular | Dev | JB  |
| ----- | -------------------------- | -------------------------------- | -------------------------------------------------- | :-----: | :-: | :-: |
| 1     | NOP `tbnz w8,#5`           | `_apfs_vfsop_mount`              | Skip root snapshot sealed-volume check             |    Y    |  Y  |  Y  |
| 2     | NOP conditional            | `_authapfs_seal_is_broken`       | Skip root volume seal panic                        |    Y    |  Y  |  Y  |
| 3     | NOP conditional            | `_bsd_init`                      | Skip rootvp not-authenticated panic                |    Y    |  Y  |  Y  |
| 4-5   | `mov w0,#0; ret`           | `_proc_check_launch_constraints` | Bypass launch constraints                          |    Y    |  Y  |  Y  |
| 6-7   | `mov x0,#1` (2x)           | `PE_i_can_has_debugger`          | Enable kernel debugger                             |    Y    |  Y  |  Y  |
| 8     | NOP                        | `_postValidation`                | Skip AMFI post-validation                          |    Y    |  Y  |  Y  |
| 9     | `cmp w0,w0`                | `_postValidation`                | Force comparison true                              |    Y    |  Y  |  Y  |
| 10-11 | `mov w0,#1` (2x)           | `_check_dyld_policy_internal`    | Allow dyld loading                                 |    Y    |  Y  |  Y  |
| 12    | `mov w0,#0`                | `_apfs_graft`                    | Allow APFS graft                                   |    Y    |  Y  |  Y  |
| 13    | `cmp x0,x0`                | `_apfs_vfsop_mount`              | Skip mount check                                   |    Y    |  Y  |  Y  |
| 14    | `mov w0,#0`                | `_apfs_mount_upgrade_checks`     | Allow mount upgrade                                |    Y    |  Y  |  Y  |
| 15    | `mov w0,#0`                | `_handle_fsioc_graft`            | Allow fsioc graft                                  |    Y    |  Y  |  Y  |
| 16    | NOP (3x)                   | `handle_get_dev_by_role`         | Bypass APFS role-lookup deny gates for boot mounts |    Y    |  Y  |  Y  |
| 17-26 | `mov x0,#0; ret` (5 hooks) | Sandbox MACF ops table           | Stub 5 sandbox hooks                               |    Y    |  Y  |  Y  |
| 27    | `PACIBSP→RET`              | `_thread_guard_violation`        | Disable fatal EXC_GUARD (Mach port guard) delivery. Dev variant + iOS 18 bases always. The old `--force-exc-guard` opt-in for other bases is gone; `kernel-boot-thread_guard_violation` is pinned to `iOSBase: .major(18)` (see note below). | Y* | Y | Y* |

† Always required on iOS 18 bases (18.6.2's runningboardd/SpringBoard trip `GUARD_TYPE_MACH_PORT` "flavor 10", crash-looping the UI — the VM won't boot without it there). On other bases this is opt-in, not always-on: some third-party apps shipping crash-reporting/RASP SDKs (Bugly, Crashlytics, KSCrash, ...) call `task_swap_exception_ports()`, which the research kernel can enforce as a fatal `GUARD_TYPE_MACH_PORT`/`KOBJECT_REPLY_PORT_SEMANTICS` violation (see [upstream issue #291](https://github.com/Lakr233/vphone-cli/issues/291), reproduced and confirmed via crash logs against a `kernelcache.research.vphone600 (26.1/23B85)` build) — but it's not required for the VM itself to boot on 26.x, so it stays opt-in rather than always-on for regular/jb/exp. `applyExcGuard` in `FirmwarePipeline`/`KernelPatcher` is `iosBaseIs18 || forceExcGuard`; pass `--force-exc-guard` to `patch-firmware` (or `FORCE_EXC_GUARD=1` to the relevant `make fw_patch*` target) to enable it on a base that needs it. `iosBaseIs18` (from `iPhone-BuildManifest.plist`'s `ProductVersion`) also still gates the unrelated 18.x skywalk-netagent boot-arg workaround. **Superseded:** the `--force-exc-guard` / `FORCE_EXC_GUARD=1` opt-in and the `iosBaseIs18` boolean no longer exist. The patch is declared with `iOSBase: .major(18)`, and no preset or VM selection can widen that gate, so it cannot be applied on 26.x.

### JB-Only Kernel Methods (Reference List)

> **⚠ iOS-27 hard-gate (2026-07-20).** Every patch below whose Purpose cites "iOS 27" / "27.0 on the 26.4 kernel" is **hard-gated to a 27.x base** via `KernelJBPatcher.applyIOS27` — set by `FirmwarePipeline` from the iPhone base `ProductVersion` (mirroring the `applyExcGuard`/iOS-18 mechanism at patch 27 above; standalone `patch-component` defaults it true, override with `--target-os`). Gated set: **JB-02b, JB-02d, JB-09 (the `ops[124]` add, plus on 27 the `ops[267]` removal — handed to JB-29; the other 201..316 hooks stay), JB-10b, JB-26, JB-27, JB-28, JB-29**. On an 18.x/26.x base **none** of them run. This supersedes the per-row "No-op-in-effect for version-matched userlands" notes: those describe the effect *if applied*, but **JB-27 is NOT a no-op on 26.x** — its `cmp 0x588→0x6e0` retarget makes the 26.x userclient reject its own native 0x588 SwapEnd → dead display (the 26.5 regression that motivated the hard-gate). **Verified 2026-07-20 (JB-29 addendum 2026-07-23):** a 26.5 base produces a **byte-identical** kernelcache to pre-branch `main` (`patch-component --component kernel-jb --target-os 26.5` vs main's output — `cmp` clean, 83 records each; re-confirmed unchanged after JB-29 by `sha256`, since `ops[267]` stays blanket-neutered on 26.5), and a 27.0 base emits **95** records on the `c0ecdb4b` deployment kernel: the 11 gated records above **plus JB-29's 2** (`jb.fpfs_scoped_open.{ops_retarget,cave}`), with `sandbox_ext_267` suppressed (JB-29 owns `ops[267]` on 27 → the FileProvider-scoped trampoline instead of the blanket allow-stub).

> **Frida Stalker support is opt-in (`--frida`).** JB-23b and JB-25c run only when firmware patching is invoked with `--frida` (`vphone-cli vm create … --frida`, `vphone-cli fw patch <vm> -V jb --frida`, `patch-firmware … --frida`, `patch-component --component kernel-jb --frida`, or `make fw_patch_jb FRIDA=1`), gated by `KernelJBPatcher.applyFrida` (set by `FirmwarePipeline` from `enableFrida`). Baseline JB/EXP output is **byte-identical** when off (26.4 emits 83 records without `--frida`, 87 with — the 4 being JB-23b's 2 thread_set_state setters and JB-25c's 2 vm_map_delete gates). **2026-10-22:** the Frida set also carries JB-33 (`kernel-exp-frida_tpro_off`, spawn) and JB-34 (`kernel-exp-frida_syscall_filter_off`, syscall-filtered daemons), ported from mowisec/frida_patches_srd; `standard` blocks all four. Frida itself is installed through the existing extra-debs mechanism: on a `--frida` create the orchestrator sets `VPHONE_FRIDA=1`, `fetch_debs.sh` resolves the latest `frida_<ver>_iphoneos-arm64.deb` (== `re.frida.server`: no `Depends`, rootless `/var/jb` layout) from the Frida GitHub releases into the debs cache, `cfw_install_{jb,exp}.sh` stage it, and the first-boot "5b/8 INSTALL EXTRA DEBS" step `dpkg -i`'s it — no APT source, marker, or dependency resolution.

| #     | Group | Method                                | Function                                                                                             | Purpose                                                                                                                                                                              | JB Enabled |
| ----- | ----- | ------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | :--------: |
| JB-01 | A     | `patch_amfi_cdhash_in_trustcache`     | `AMFIIsCDHashInTrustCache`                                                                           | Always return true + store hash                                                                                                                                                      |     Y      |
| JB-02 | A     | `patch_amfi_execve_kill_path`         | AMFI execve kill return site                                                                         | Convert shared kill return from deny to allow (superseded by C21; standalone only)                                                                                                   |     N      |
| JB-02b| C     | `patch_exec_security_policy_kill`     | XNU exec `imgp->ip_mac_return` gate (kern_exec, `os_reason_create(OS_REASON_EXEC, EXEC_EXIT_REASON_SECURITY_POLICY)` site) | Flip `cbz wN, <skip>` → unconditional `b <skip>` so the exec-time MAC-verdict `SECURITY_POLICY` kill is unreachable. **Needed to run a userland NEWER than the kernel (iOS 27.0 on the 26.4 kernel):** AMFI's exec hooks reject the newer binaries' code-sign validation category, setting `ip_mac_return != 0` → core daemons (backboardd/cfprefsd/containermanagerd/…) die at exec (`namespace 9 / code 0x8`) → boot deadlock. Validated on 27.0/26.4: 0 SECURITY_POLICY kills, daemons launch, networking + SSH come up. No-op-in-effect for version-matched userlands (ip_mac_return == 0 there, so the original cbz already skips). |     Y      |
| JB-02d| C     | `patch_container_manager_upcall`      | sandbox `_hook_cred_label_update_execve` container-manager upcall guard: the `cbz w0,<success>` after `bl <container_manager_get_process_containers>`, on the `"failed to upcall to containermanagerd for a platform app"` fall-through | Flip `cbz w0,<success>` → unconditional `b <success>` so a FAILED exec-time container-manager upcall takes the success path instead of autobox/kill. **Needed to run iOS 27.0 on the 26.4 kernel:** iOS 27 DELETED the kernel-side containermanagerd upcall — the stock 27 kernel has no `HOST_CONTAINERD_PORT` / `CM_KERN_*` protocol (container resolution moved out of the kernel), so 27's containermanagerd no longer implements the reply server. On the 26.4 kernel the exec upcall therefore fails (`MACH_SEND_INVALID_DEST`) for every 27 platform app → they are autoboxed into the restrictive `temporary-sandbox` profile, which denies e.g. `mach-lookup com.apple.backboard.display.services` → Campo (the wallpaper renderer) crash-loops (no wallpaper) + intelligencetasksd/feedbackd. Re-registering the container-manager host special port is NOT viable: the 26.4 kernel then SENDS the synchronous `CM_KERN` MIG request and BLOCKS for a reply 27 cannot produce → early-boot deadlock (verified: boot hangs, never reaches SpringBoard). Anchor is structural (string xref to `"failed to upcall to containermanagerd"` → the `cbz w0` immediately preceding the string-load `adrp`, itself immediately preceded by the upcall `bl`; backward branch to the success continuation; unique). Replacement `b` from the Keystone-backed `ARM64Encoder`. **VALIDATED on-device (2026-07-15, `17,3_27.0_24A5380h` + cloudOS 26.4 `c0ecdb4b…`, JB): iOS 27 wallpaper renders, Campo/SpringBoard/backboardd stable, boot clean (no freeze, no panic).** No-op-in-effect for version-matched userlands (there the upcall succeeds → the original cbz already branches to `<success>`). |     Y      |
| JB-03 | C     | `patch_cred_label_update_execve`      | `_cred_label_update_execve`                                                                          | Reworked C21-v3: C21-v1 already boots; v3 keeps split late exits and additionally ORs success-only helper bits `0xC` after clearing `0x3F00`; still disabled pending boot validation |     N      |
| JB-04 | C     | `patch_hook_cred_label_update_execve` | sandbox `mpo_cred_label_update_execve` wrapper (`ops[18]` -> `sub_FFFFFE00093BDB64`)                 | Faithful upstream C23 trampoline: copy `VSUID`/`VSGID` owner state into pending cred, set `P_SUGID`, then branch back to wrapper                                                     |     Y      |
| JB-05 | C     | `patch_kcall10`                       | `sysent[439]` (`SYS_kas_info` replacement)                                                           | Rebuilt ABI-correct kcall cave: `target + 7 args -> uint64 x0`; re-enabled after focused dry-run validation                                                                          |     Y      |
| JB-06 | B     | `patch_post_validation_additional`    | `_postValidation` (additional)                                                                       | Disable SHA256-only hash-type reject. **FIX (2026-09-22):** logged `[-] expected 1 postValidation compare site, found 0` on every run, which `make test_fw_patches` is built to fail on. Cause: this patch and base-layer item 9 (`KernelPatchPostValidation`) reveal the *same* site the *same* way — same `"AMFI: code signature validation failed"` string anchor, same caller walk, same `cmp w0,#imm ; b.ne` preceded by a BL (item 9 searches a 2-instruction BL window, this one a wider 3) — and both rewrite it to `cmp w0,w0`. Item 9 runs first and takes the site (observed at file offset `0xDE8360`, `cmp w0,#2` → `cmp w0,w0`), so by the time this runs the only candidate no longer has an immediate operand and a search for one finds nothing. The `[-]` was therefore a redundant no-op, not a missed patch. `patchPostValidationAdditional` now also recognizes `cmp w0,w0` in that slot (same BL-precedence anchor) and reports `[=] already cmp w0,w0 ... (base postValidation patch owns this site)` returning success; the failure message additionally reports how many already-patched sites it saw, so a genuine miss is still distinguishable from this case. |     Y      |
| JB-07 | C     | `patch_syscallmask_apply_to_proc`     | syscallmask apply wrapper (`_proc_apply_syscall_masks` path)                                         | Faithful upstream C22: mutate installed Unix/Mach/KOBJ masks to all-ones via structural cave, then continue into setter; distinct from `NULL`-mask alternative                       |     Y      |
| JB-08 | A     | `patch_task_conversion_eval_internal` | `_task_conversion_eval_internal`                                                                     | Allow task conversion                                                                                                                                                                |     Y      |
| JB-09 | A     | `patch_sandbox_hooks_extended`        | Sandbox MACF ops (extended)                                                                          | Stub remaining 30+ sandbox hooks (incl. IOKit 201..210) + `mpo_proc_check_syscall_unix` (`ops[124]`) → allow. **The ops[124] hook is the iOS-27 DDI-mount syscall fix:** MobileStorageMounter's `mount_apfs` needs the `mount(2)` syscall (unix 167) to mount the personalized DDI at `/System/Developer`; on the 26.4-kernel / 27-userland hybrid the kernel Sandbox otherwise denies it (`Protobox: mount_apfs deny(1) syscall-unix 167`). Index calibrated against the reference-XNU `mac_policy_ops` struct order (co-verified: mpo_vnode_check_open=267, mpo_vnode_check_fsgetpath=316). Validated live on `c0ecdb4b` 26.4 (DDI auto-mounts). |     Y      |
| JB-10 | A     | `patch_iouc_failed_macf`              | IOUC MACF shared gate                                                                                | A5-v2: patch only the post-`mac_iokit_check_open` deny gate (`CBZ W0, allow` -> `B allow`) and keep the rest of the IOUserClient open path intact                                    |     Y      |
| JB-10b| A     | `patch_iouc_failed_sandbox`           | IOUC *sandbox* shared gate (string `"IOUC %s failed sandbox in process %s"`)                          | **THE iOS-27 display fix (CONFIRMED 2026-07-15).** Sibling to JB-10: the IOUserClient open path has a SEPARATE Sandbox gate beyond the MACF one. On 27 userland / 26.4 kernel it spuriously DENIES the render server (backboardd) its IOMobileFramebuffer/IOSurface/HID userclient opens (27-specific: ABSENT on native 26.4; backboardd absent from every `IOUserClientCreator`) → no present (no Apple logo) + `mainDisplay=nil` → SpringBoard FBSDisplayMonitor crash-loop. Gate shape (same fn as JB-10): `blraa` sandbox check (PAC-indirect) → `cmp w0,#0xe00002c7` (kIOReturnNotPermitted) `b.eq <ALLOW>`; `ldr w8,[sp,#x]; cbnz w8,<DENY>` (other error → deny block w/ fail-log ADRP → returns error); w0==0 path → `b <ALLOW>`. Patch rewrites `<DENY>`'s first insn → `b <ALLOW>` (deny → allow-proceed), leaving the w0==0 path intact. Anchor is structural (fail-log string xref → the CBNZ whose target encloses it → the preceding `b.eq` allow target). Verified: backboardd then holds an IOMFB userclient, `[CADisplay mainDisplay]` resolves to `LCD/primary`, SpringBoard runs with 0 crashes. |     Y      |
| JB-11 | B     | `patch_proc_security_policy`          | `_proc_security_policy`                                                                              | Bypass security policy                                                                                                                                                               |     Y      |
| JB-12 | B     | `patch_proc_pidinfo`                  | `_proc_pidinfo`                                                                                      | Allow pid 0 info                                                                                                                                                                     |     Y      |
| JB-13 | B     | `patch_convert_port_to_map`           | `_convert_port_to_map_with_flavor`                                                                   | Skip kernel map panic                                                                                                                                                                |     Y      |
| JB-14 | B     | `patch_bsd_init_auth`                 | `_bsd_init` rootauth-failure branch                                                                  | Ignore `FSIOC_KERNEL_ROOTAUTH` failure in `bsd_init`; same gate as base patch #3 when layered                                                                                        |     Y      |
| JB-15 | B     | `patch_dounmount`                     | `_dounmount`                                                                                         | Allow unmount via upstream coveredvp cleanup-call NOP                                                                                                                                |     Y      |
| JB-16 | B     | `patch_io_secure_bsd_root`            | `AppleARMPE::callPlatformFunction` (`"SecureRootName"` return select), called from `IOSecureBSDRoot` | Force `"SecureRootName"` policy return to success without altering callback flow; implementation retargeted 2026-03-06                                                               |     Y      |
| JB-17 | B     | `patch_load_dylinker`                 | `_load_dylinker`                                                                                     | Skip strict `LC_LOAD_DYLINKER == "/usr/lib/dyld"` gate                                                                                                                               |     Y      |
| JB-18 | B     | `patch_mac_mount`                     | `___mac_mount`                                                                                       | Upstream mount-role wrapper bypass (`tbnz` NOP + role-byte zeroing)                                                                                                                  |     Y      |
| JB-19 | B     | `patch_nvram_verify_permission`       | `_verifyPermission` (NVRAM)                                                                          | Allow NVRAM writes                                                                                                                                                                   |     Y      |
| JB-20 | B     | `patch_shared_region_map`             | `_shared_region_map_and_slide_setup`                                                                 | Force root-vs-process-root mount compare to succeed before Cryptex fallback                                                                                                          |     Y      |
| JB-20b| B     | `patch_shared_region_size`            | `vm_shared_region_create` arm64 case                                                                 | **Widen the shared region 6→7 GiB for an iOS 27 userland (2026-10-06, issue #596).** `kernel-boot-shared_region_size`, applicability `iOSBase: .major(27)`, runs under the existing `applyIOS27` gate so a 26.x/18.x base keeps a stock kernel. The 26.4 kernel bakes `SHARED_REGION_BASE_ARM64 == SHARED_REGION_SIZE_ARM64 == 0x180000000`; a 27.0.1 iPhone18,x cache spans `0x185804000`, over the region even at slide 0, so `_shared_region_map_and_slide` ENOMEMs and launchd dies on libSystem — zeroing `maxSlide` (row 10) is not enough. Because base == size, the compiler issued one register for both and `dup v0.2d`-splatted it into the nesting pair, so the arm64 case is rewritten as a 4-instruction block (anchor: the `dup Vd.2d, Xn` between two `#0x180000000` materialisations; window confirmed with Capstone; exactly one hit required; branch preserved): `movz/movk x22` build size `0x1C0000000`, the kernel's own single-instruction base word (`mov x26, #0x180000000`, an ORR logical-immediate alias — one `movz` cannot spell `0x180000000`, bits 31+32 straddle lanes) is reused verbatim, and `stp x26, x22, [sp, #0x70]` replaces the dup/str nesting pair. Replacement words keystone 0.9.2 via `ARM64Encoder.encodeMovzX/encodeMovkX/encodeStpX`; downstream `csm_setup_nested_address_space`, `pmap_set_shared_region` and both `vm_map_create_options` calls take x26/x22 as base/size (verified register-for-register against `vm_shared_region.c` on both variants — research `0x1E0F4E8` / release `0x1D074E8`, byte-identical). Size choice: Apple's iOS 27 value `0x380000000` cannot be copied — the 26.4 kernel's task-map ceilings (`ARM64_MAX_OFFSET_DEVICE_SMALL 0x358000000`, `LARGE 0x458000000`) are compiled from the stock region and iOS 27 raised its own; `0x1C0000000` tops the region at `0x340000000`, under every tier, while covering the worst known cache + full 512 MiB slide (`0x1A5804000`). `cfw install` mirrors this: the region check uses `DyldSharedCacheMaxSlidePatcher.patchedKernelSharedRegionSize` when the VM's kernelcache receipt lists the patch (a VM with no receipt falls back to a `27.*` base), so iPhone18,x installs proceed instead of refusing; `patch-dsc-maxslide` still zeroes the slide (conservative slide-0 first boot). Full analysis: `Research/KernelCustomFirmwarePatches/patch_shared_region_size.md`. **Boot validated 2026-10-06** on iPhone18,2 27.0.1 + cloudOS 26.4 (bundle 2.6.0-local.0d5e6f90, `cfw update-kernel` + `cfw install` over the #596 repro machine): `dyld cache mapped system-wide`, 0 panics, vphoned answers as 27.0.1, home screen at 440x956 @3x — SPTM and TXM accept the `0x1C0000000` nesting range. | `27.*` |
| JB-21 | B     | `patch_spawn_validate_persona`        | `_spawn_validate_persona`                                                                            | Upstream dual-`cbz` persona helper bypass                                                                                                                                            |     Y      |
| JB-22 | B     | `patch_task_for_pid`                  | `_task_for_pid`                                                                                      | Allow task_for_pid via upstream early `pid == 0` gate NOP                                                                                                                            |     Y      |
| JB-23 | B     | `patch_thid_should_crash`             | `_thid_should_crash`                                                                                 | Prevent GUARD_TYPE_MACH_PORT crash                                                                                                                                                   |     Y      |
| JB-23b| B     | `patchThreadSetStateEntitlementFlag`  | `thread_set_state_from_user` / inlined `act_set_state_from_user` flags materialization               | **Frida Stalker existing-thread support (opt-in `--frida`).** Stalker updates an existing thread's core registers via `thread_set_state_from_user`, which passes `flags = TSSF_TRANSLATE_TO_USER \| TSSF_CHECK_ENTITLEMENT` (0x201) into `thread_set_state_internal`; the inlined `thread_set_state_allowed()` then demands `com.apple.private.thread-set-state` (which the target lacks) → `GUARD_TYPE_MACH_PORT / THREAD_SET_STATE`. Rather than NOP the entitlement check, clear TSSF_CHECK_ENTITLEMENT (bit 9) in the flags the user setters pass: rewrite `mov w6, #0x201` → `mov w6, #0x1`. This preserves TSSF_TRANSLATE_TO_USER (user-pointer translation) and leaves the independent `TH_IN_MACH_EXCEPTION` guard enforced — it only stops user-initiated `thread_set_state` from being entitlement-gated. Anchor: entitlement-string xref cluster → the single containing function (thread_set_state_internal); then its direct `b`/`bl` callers that set `w6` (the 7th-arg = flags, a calling-convention anchor, not an allocation guess) to 0x201. Both setters (`thread_set_state_from_user` + inlined `act_set_state_from_user`) are patched. No offsets/VAs/registers/bytes hardcoded; replacement from the Keystone-backed `ARM64Encoder.encodeMovzW`, Capstone-verified. Kernels without the shape are skipped (fail-open no-op). Verified on the `c0ecdb4b` 26.4 kernel (UUID `BCD06230-CCBE-8E48-50FF-D9C166D83CD5`): exactly two records at file-off `0x1D95720`/`0x1D9594C`. | `--frida` |
| JB-24 | B     | `patch_vm_fault_enter_prepare`        | `_vm_fault_enter_prepare`                                                                            | Force `cs_bypass` fast path in runtime fault validation                                                                                                                              |     Y      |
| JB-25 | B     | `patch_vm_map_protect`                | `_vm_map_protect`                                                                                    | Skip upstream write-downgrade gate. Shape A (26.1–26.4) active; **Shape B (26.5) disabled 2026-07-05** — widened the `~VM_PROT_WRITE` COW strip (vm_map.c:6202) instead of the RWX gate (vm_map.c:5997), breaking COW and crashing the debugger (SPTM `VIOLATION_ILLEGAL_MAP`). Retired on 26.5+: SPTM code-mod (debugger + Substrate tweaks) uses write-then-flip via `vm_protect(VM_PROT_COPY)` → `XNU_USER_DEBUG`, so no RWX patch is needed. **SHAPE C ADDED (2026-09-22, cloudOS 26.4 `c0ecdb4b…`, jb):** the patch logged `[-] vm_map_protect write-downgrade gate not found` on this base, which `make test_fw_patches` is built to fail on. Two independent causes, both confirmed by disassembling the 26.4 research kernelcache. **(1) The gate is compiled differently.** Where 26.1/26.3 emit a flag-setting `bics` plus a separate `tbnz wFlags,#22,skip`, 26.4 folds the two conditions into a conditional compare and leaves one branch: `and wFlags,wFlags,#0x400000` / `mov wMask,#6` / `bic wMask,wMask,wProt` / `cmp wMask,#0` / `ccmp wFlags,#0,#0,eq` / `b.ne skip`, with `and wProt,wProt,#0xfffffffb` (clear `VM_PROT_EXECUTE`, keep R|W) inside the guarded block. Same mask `#6`, same entry bit 22, same downgrade — rewriting that single `b.ne` to an unconditional `b` bypasses both conditions at once, exactly as Shape A's rewrite does (there the `tbnz` becomes dead). Observed at VA `0xFFFFFE0008DCAEA0` → `0xFFFFFE0008DCAED0` (file `0x1DC6EA0`). **(2) The search window stopped short.** `findFuncEnd` ends at the next `pacibsp`; on 26.4 the block holding the `"vm_map_protect("` panic string ends at its own prologue `0x6B8` bytes *before* the gate, so the window derived from the string anchor never reached it. **Reveal procedure for Shape C:** the signature is its own anchor rather than a byte window — across the whole `com.apple.kernel __TEXT_EXEC` (8.4 MB) even the bare `mov wMask,#6 ; bic wMask,wMask,wProt` prefix occurs **exactly once**, and the matcher additionally requires the bit-22 mask before it and the execute-clearing `and` inside the guarded block, then demands a unique hit across all code ranges. Widening by an offset was rejected as an offset-shaped anchor. **Backward compatibility:** Shape A is untouched and still tried first, so 26.1/26.3 take precisely the path they always took and Shape C is unreachable there. **VALIDATED on-device (2026-09-23, `17,3_26.4_23E246` + cloudOS 26.4 `23E5207q`, JB, `vm create` host-mount deploy):** the deployed `kernelcache.research.vphone600` carries the rewritten gate — `0xFFFFFE0008DCAEA0` disassembles as unconditional `b #0xfffffe0008dcaed0` with `and w8,w8,#0x400000 / mov w9,#6 / bic w9,w9,w20 / cmp w9,#0 / ccmp w8,#0,#0,eq` intact above it — and the VM boots clean: zero `panic(` / `stackshot` markers across the whole boot log, SpringBoard up, Safari and Sileo both running, so the JB userland and TweakLoader come up with the patch live. The gate is the same one on a 26.4 base whichever userland rides on top, since `fw_patch_jb` patches the cloudOS kernelcache, not the iOS one. Matching was separately checked on `17,3_27.0_24A435` + the same base. **Still not exercised:** a debugger attach or a tweak RWX write specifically — that is the failure mode Shape B produced (broken COW, SPTM `VIOLATION_ILLEGAL_MAP`), and a clean boot with Sileo running is good evidence but not that test. Note the source also disagreed with itself about the covered range — headers said "Shape A (26.1 / 26.3)", line 69 said "26.1-26.4"; on 26.4 the answer is neither, it is Shape C. **PREFILTERED (2026-09-28, no change to the gate or the patch):** because the Shape C scan is deliberately unscoped it walks all 8.4 MB of kernel text, and it was decoding five instructions at every one of the ~2.1M offsets only to reject almost all of them on the first one. Sampling a Release `fw patch` (8623 samples, `sample`) put 93% of the whole run in `scanRange` → `ARM64Disassembler.disassemble`, and 72% of that inside `cs_disasm` — not in the decoder but in Capstone's *printer*: `printInst` / `printAliasInstr` / `matchAliasPatterns`, `vsnprintf` / `SStream_concat`, and `map_set_alias_id` → `name2id`'s `strcmp` chain. `AArch64_LLVM_getInstruction`, the actual decode, was 6%. A rejection-only raw-word gate now runs first (`ARM64Inst.isMOVZW` + `movImm16 == 6`, or `isORRImmW` + `rn == 31`), so Capstone is only asked about offsets that could open with `mov wMask,#6`. **Nothing is decided by the prefilter** — survivors take exactly the decode and the checks they always did, and every positive determination is still Capstone's. Both encodings of `mov wD,#6` are accepted although only MOVZ can reach the existing `mnemonic == "mov"` check (the MOV-bitmask alias applies only when the immediate is *not* MOVZ-encodable, so `orr w9,wzr,#6` = `0x321F07E9` prints as `orr`), which keeps the gate independent of that aliasing rule; `ARM64InstTests` pins both words and the printer's answer for each. The same treatment was applied to the one other full-text scan, `patchThreadSetStateEntitlementFlag` (`isBorBL`, extended-only). Measured on `17,3_26.4` + cloudOS 26.4, Release: the patch step 28.81 s → 1.28 s, whole `fw patch` 48.98 s → 21.68 s standard and ~61 s → ~28 s extended, instructions retired 1.006e12 → 5.38e11. **Verified byte-identical:** all four bases (26.1 / 26.4 / 26.6.2 / 27.0) × both presets, HEAD vs HEAD+prefilter, every file in each restore tree hashed — 12/12 identical (196/186/186/185 files), same 172 standard / 183 extended patch counts, same `0x1DC6EA0` rewrite, no undeclared-patch warnings. |    Y/N     |
| JB-25c| B     | `patchVmMapDeleteImmutableCode`       | `_vm_map_delete` permanent-entry immutable-code exception (vm_map.c:8855)                            | **Frida Stalker repeated-`VM_PROT_COPY` fix (opt-in `--frida`).** Stalker's write-then-flip leaves a CSM-associated permanent entry at current `RW` / max `RWX`; XNU's "debugger may undo executable mappings" exception tests `entry->protection & VM_PROT_EXECUTE` (current, bit 9), which is clear, so the entry stays permanent and the next fixed overwrite returns `KERN_PROTECTION_FAILURE`. Retarget the execute test to the packed `max_protection` bit (bit 9 → bit 13; `protection:3`@7..9, `max_protection:4`@11..14 in the `[entry,#0x38]` flags word). Semantic matcher: packed-flags load + `vme_permanent` (bit 19) + the inlined `developer_mode_state()` byte-bit-0 read + the current-X test bound to the immutable-code cluster (Shape A: shares the remove-flags fallback target; Shape B: branches to the permanent-continuation target). The remove-flags bit is matched structurally (a test of a non-entry register), not by source constant (VM_MAP_REMOVE_* bit numbers drift across XNU versions). The later CSM current-X `#9` test in the same window is deliberately excluded (different branch target). Exactly two gates or fail closed; branch bytes from the Keystone-backed `ARM64Encoder.encodeTestBitBranch`, Capstone round-trip verified (sense/bit/target). Verified on the `c0ecdb4b` 26.4 kernel: two records at file-off `0x1DBE14C` (`tbz w8,#9→#0xd`) and `0x1DBE828` (`tbnz w8,#9→#0xd`). | `--frida` |
| JB-26 | B     | `patch_iomfb_swapend_variable_size`   | IOMFB userclient method-5 (SwapEnd) `__DATA_CONST` dispatch entry (`checkStructureInputSize`)        | **iOS-27 VZ-view fix, kernel half — paired with DSC force-kern (DSC-patch item 11).** The 26.4 userclient's method-5 dispatch entry hard-checks `checkStructureInputSize == 0x588`; forced-kern iOS 27 sends its native `0x6e0`. Rewrite the size field to `kIOUCVariableStructureSize (0xFFFFFFFF)` so `IOUserClient::externalMethod` accepts 27's struct and reaches the handler. Anchor (structural): the sole `__DATA_CONST` entry `{ptr(ptrauth, top-byte≥0x80), scalarIn=0, structIn=0x588, scalarOut=0, structOut=0}` (verified unique; decompressed file-off 0x9c7228). No-op-in-effect for version-matched 26.x (sends 0x588). Re-enabled 2026-07-15 (was disabled when 27 present-path was still unknown). |     Y      |
| JB-27 | B     | `patch_iomfb_swapend_handler_size`    | method-5 handler internal size gate (`cmp w2,#0x588 ; b.ne <err>`)                                   | Companion to JB-26: beyond the dispatch-table check the handler re-checks the struct size (`cmp w2,#0x588 ; b.ne <kIOReturnBadArgument>`; verified unique at decompressed file-off 0x16ae22c; success path forwards the raw struct ptr to a `vtable+0x590` paravirt swap method). Retarget the `cmp` immediate to `0x6e0` so forced-kern iOS 27's native SwapEnd reaches real swap processing (27's IOMFBSwapRec prefix matches 26.x → handler reads valid fields). Semantic anchor (`cmp w2,#imm` word + following `b.ne` decode). Enabled together with JB-26 + DSC force-kern for iOS 27. |     Y      |
| JB-28 | A     | `patch_disk_images2_client_abi`       | `com.apple.driver.AppleDiskImages2` kext: `DIDeviceCreatorUserClient::CreateDevice` + `DIDeviceIOUserClient::Connect` ABI-version gates, and the `AllocPortsArray`/`RegisterNotificationPort` notif-port sizing | **iOS-27 DDI (`/System/Developer`) auto-mount — attach layer.** `pymobiledevice3 mounter auto-mount` on the 26.4-kernel / 27-userland hybrid fails at attach: the kernel DiskImages2 driver is ABI v9, the 27 userland's DiskImages2 controller/daemon is ABI v11 (`DIDeviceCreatorUserClient::CreateDevice: Incompatible client: expected ABI version 9 actual 11`). Three layers: **GATE1** NOPs the CreateDevice controller-ABI `cmp #9 ; b.ne` reject; **GATE2b** NOPs the Connect daemon-ABI `cmp #9 ; b.ne` reject (both anchored on the C++ signature cstring → unique `cmp #9`/`b.ne`; version-robust; no-op-in-effect on version-matched userlands where ABI 9==9). **GATE2** (array + 2 bound checks) fixes a RegisterNotificationPort off-by-one (userland registers at index==maxPorts, one past the array) by widening the AllocPortsArray allocation (`lsl x1,xN,#3` → `mov x1,#0x4000`) AND both bound-check field loads (`ldrh [.,#0xd8]`/`ldr [.,#0xe8]` → `mov wD,#0x800`); applied **all-or-nothing** (widening the bound checks without the backing array would let RegisterNotificationPort write past it → corruption) and skipped/logged on builds whose notif-port codegen differs (the off-by-one is 26.4-hybrid-specific). Pairs with the sandbox ops[124] allow (JB-09) and the diskimagesiod userland patch (CFW binary-patch #13). Anchors structural (Capstone decode of the pinned function's instructions); replacement bytes from the Keystone-backed `ARM64Encoder`. **GATE2a anchor note:** the AllocPortsArray size-shift is matched on `lsl` mnemonic + destination `x1` (the unique size-writing lsl in the function) — NOT a 3-operand `lsl xd,xn,#imm` shape, because Capstone on this toolchain decodes the lsl-immediate (a UBFM alias) as **2 operands**; requiring 3 operands makes GATE2 silently skip (the all-or-nothing returns a harmless no-op). Verified on the `c0ecdb4b` 26.4 deployment kernel via `patch-component --component kernel-jb --records-out`: all five di2 records emit (`di2_createdevice_abi`, `di2_connect_abi`, `di2_allocports_size`, `di2_notif_boundcheck_d8`, `di2_notif_boundcheck_e8`) — always verify the di2 records EMIT, not merely that the JB suite reports "no failures". No-op-in-effect for version-matched userlands. |     Y      |
| JB-29 | C     | `patch_fpfs_scoped_vnode_open`        | Sandbox MACF `mpo_vnode_check_open` (`ops[267]`) → per-process trampoline code cave                  | **iOS-27 random-respring fix (fpfs balloon).** JB-09 blanket-neuters `mpo_vnode_check_open` (`ops[267]` → allow) so processes can read `/var/jb`. But FileProvider's fpfs parent-walk (`fpfs_pkg_fd_lookup` → `openbyid` climbing via `getattrlistat(ATTR_CMN_PAROBJID)`) uses the stock check's EACCES at the domain-container boundary as its terminus; neutered, the walk climbs unbounded → `ResolverService` (FileProviderResolver) balloons to ~12 GB → `vm-compressor-space-shortage` jetsam → backboardd killed → **respring** (seen on 27b4/24A5390f). Fix keeps the global bypass and enforces the real check for the FileProvider daemons only: on 27, `ops[267]` is left un-neutered (removed from JB-09's blanket list — conditional `if !applyIOS27` in `patchSandboxHooksExtended`), then retargeted to a 20-insn code-cave trampoline that inlines `current_proc` (`mrs tpidr_el1` → `ldr [+0x3F0]` uthread → `ldr [+0x18]` proc), loads `p_comm` (`+0x56C`), compares the first 8 bytes to `"Resolver"`/`"fileprov"`, and on match `b`s to the real `vnode_check_open` (restores the terminus) else returns allow (`mov x0,#0 ; ret` → `/var/jb` reads + Sileo/TrollStore icons unaffected). Register-only (x8–x10), no frame/call (~18 insns/open). Struct offsets recovered via the VZ gdb stub on vphone600; cave bytes from the Keystone-backed `ARM64Encoder`, verified by Capstone round-trip; the `ops[267]` retarget preserves the auth-rebase high bits (same encoder family as JB-09). **VALIDATED on-device (2026-07-23, `17,3_27.0_24A5390f` + cloudOS 26.4, JB, `setup_machine` deploy): resprings stop; Sileo/TrollStoreLite icons render.** Backward-compat: a 26.5 base is unaffected (`ops[267]` still blanket-neutered there) — verified byte-identical kernelcache pre-vs-post (`cmp` clean, `sha256` unchanged). See `KernelJBPatchFpfsScopedOpen.swift`. |     Y      |
| JB-30 | B     | `patchParavirtDisplayRefreshRate` (record `kernel-cfw-display_promotion`; introduced as `kernel-exp-display_refresh_120hz`, renamed when `standard` turned it on) | `AppleParavirtDisplay::createDisplayAttributes` (AppleParavirtGPUIOGPUFamily), the per-mode timing element call | **ProMotion: 120 Hz display timing (on in `standard` since 2026-10-09; it shipped opt-in from 2.4.2).** The host VM service builds its one `PGDisplayMode` with a constant 60.0 Hz and writes it into the display shared state page as a 16-byte entry (u16 width, u16 height, u32 refresh in 16.16 Hz, flags); the guest turns each entry into an IOAV timing element with `ldurh w1,[xN,#-8]; ldurh w2,[xN,#-6]; ldur w3,[xN,#-4]; bl`. The `ldur w3` becomes `movz w3,#120,lsl #16`. Anchor: the `createDisplayAttributes` logger cstring (all refs in one function) + the only w1/w2/w3 load triple off one base at -8/-6/-4 ahead of a call. Gated by `KernelCustomFirmwarePatcher.applyProMotion`, set from the plan. See `Research/Guest/display_refresh_rate.md`. |     Y      |
| JB-31 | C     | `patchParavirtUserClientsNarrow` (records `kernel-cfw-paravirt_user_clients.redirect` / `.cave`; introduced as `kernel-exp-paravirt_user_clients`, renamed when `standard` turned it on) | Same IOUserClient Sandbox gate; the deny block's `ldr Xt,[sp,#imm]` eight bytes before the fail-log `adrp` | **Paravirtual device access on a 26.x / 18.x base (on in `standard` since 2026-10-04; it shipped opt-in).** Narrow replacement for the broad gate-off: at the deny point the class-name C string is already in x0, so a code-cave trampoline reads its first eight bytes and branches to the gate's NotPermitted allow target only for `ApplePar` / `AppleVid` / `AppleVir` / `IOSurfac` (AppleParavirt\*, AppleVideoToolboxParavirt\*, AppleVirtIO\*, IOSurfaceAcceleratorParavirtClient); every other denial runs the displaced `ldr` and falls through to the real deny. Fixes `MTLCreateSystemDefaultDevice()` nil in daemons/CLI and the VideoToolbox/ANE/IOSurface denials (upstream issue #22) without opening the rest. Cave words verified by clang/as + capstone round-trip; the two `b` words via `ARM64Encoder`. Gated by `KernelCustomFirmwarePatcher.applyParavirtUserClients`, set from the plan when `applyIOS27` is false. See `Research/Guest/gpu_acceleration.md`. |     Y      |
| JB-32 | B/C | `patchParavirtTask3Version` (`kernel-cfw-paravirt_gpu_task3.request`, `.features`, `.features_code`, `.identity_hook`, `.identity_code`) | `setupVersion`; task initializer's `Failed to create Page Table Lock`; superclass task retain/store; XNU flow-divert CDHASH log and proc/task inverse getter | **Persistent per-executable host shader caches through Task3, enabled in Standard.** Phase 1 (2026-10-19) requests binary version 252 while computing guest features from the lower of the granted version and the original 245 (`.features` branches to `.features_code`, a five-instruction clamp after the identity trampoline in the same cave; a refusal passes through). Phase 2 (2026-10-20) writes the owning executable's 20-byte code-signing cdhash at TaskRoot+0x28 before descriptor preparation and task registration. The host uses `task-<40 hex>` and retains that directory. A missing proc/hash leaves twenty zero bytes and preserves the ephemeral fallback. The owning task field is recovered from the superclass initializer, not guessed or taken from current_proc. Kernel helpers are found through source-backed semantic call flow (`cs_get_cdhash`) and the dynamically recovered proc_struct_size global (`get_bsdtask_info`); no task/proc layout offsets or kernel VAs are hardcoded. The trampoline preserves x0–x18, LR and SP, copies exactly 20 bytes and replays the displaced descriptor load. All four sites must resolve before any is emitted; failure aborts a selected install. Replacements use ARM64Encoder; new encoders have Keystone 0.9.2 parity tests. Gated by applyParavirtTask3 and declared for cloudOS 26.4 only; Standard enables it there and tvOS presets block it. Static fixture, missing-anchor and register-clobber execution tests pass. Lychee on macOS 27.0.1 / cloudOS 26.4 / iOS 27.0.1 negotiated 252 across three full boots, retained the same nine executable keys, and passed Camera with zero GPU resets. Host GPU compilation events fell 631 → 17 → 12; the Settings windows fell 121 → 5 → 0. Frame-counter gaps do not establish visible animation stutter; the user reports smooth warmed animations. Measurements, cdhash checks and crash analysis are in `Research/Guest/gpu_acceleration.md`. Older hosts remain untested. | Y |
| JB-33 | B     | `patchTproOff` (record `kernel-exp-frida_tpro_off`) | `_xprr_tpro_enabled` (`__DATA_CONST`), found via the `if (xprr_tpro_enabled)` guard of the VM_REGION_FLAG_TPRO_ENABLED store | **Frida spawn support (opt-in, Frida set; port of mowisec/frida_patches_srd `tpro-off`).** libdyld asserts on every API entry that TPRO pages are read-only and aborts (`TPRO regions should not be writable on entry to dyld`); Frida's spawn handshake re-enters libdyld inside dyld's own TPRO window, so `frida -f` and spawn-gated apps abort. Clearing the flag takes the kernel's existing no-TPRO path for every process (global). Anchor: unique `adrp/ldr/cbz/ldr/cmp/b.lo/ldrh/orr #2/strh` window, decoded with Capstone; the flag must resolve into `__DATA_CONST` and hold 1, else fail closed. 26.4 `c0ecdb4b`: flag at file-off `0x7526D4` (1 → 0). See `Research/KernelCustomFirmwarePatches/patch_tpro_off.md`. | Frida set |
| JB-34 | B     | `patchSyscallFilterOff` (record `kernel-exp-frida_syscall_filter_off`) | `_task_get_mach_trap_filter_mask`, `_task_get_mach_kobj_filter_mask`, `_mac_proc_check_syscall_unix` | **Frida in syscall-filtered processes (opt-in, Frida set; port of mowisec/frida_patches_srd `syscall-filter-off`).** Sandbox syscall filters (`syscall-unix/-mach/-mig`) deny the agent's own calls inside the target: attaching to trustd, apsd, cfprefsd, backboardd or runningboardd kills them, and in locationd `thread_get_state` returns `KERN_DENIED` (no threads for Stalker). The two mask accessors return NULL ("no filter", XNU `bsd_arm64.c:249`, `ipc_kobject.c:563`) and the MACF BSD check returns 0 (`systemcalls.c:162`); the rest of the sandbox is untouched. JB-07 (`kernel-boot-syscallmask`, which rewrites the masks as they are installed) does not reach these processes; this is the NULL-mask alternative that row mentions. Anchors: the inlined `bitstr_test` of each check (kobject one behind `cmn #1 ; b.eq`), and `and w1,#0xffff ; mov x0 ; bl ; mov ; cbnz w0` in unix_syscall; each must match once and the three functions must open `pacibsp ; stp`, else fail closed. 26.4 `c0ecdb4b`: file-off `0x1D43090`, `0x1D43120`, `0x24CCAE8` (2 words each). See `Research/KernelCustomFirmwarePatches/patch_syscall_filter_off.md`. | Frida set |
| JB-35 | C     | `patchAksUnlockBagCount5` (records `kernel-cfw-aks_unlock_bag.redirect` / `.cave`) | AppleSEPKeyStore keybag-unlock external-method handler (the one whose `IOExternalMethodArguments` count check is `cmp w8,#3 ; b.eq ; cmp w8,#4 ; b.ne BadArg`) | **Escrow-bag unlock / encrypted backups for an iOS 26.6-or-newer userland on the 26.4 kernel (`iOSBase: .atLeast(26, 6)`; pipeline `applyAksUnlockBag5`, not `applyIOS27`).** From iOS 26.6 on, the userland keybag unlock sends `inputScalarCount == 5` (scalars[3]=flags&1, scalars[4]=flags); the 26.4 AppleSEPKeyStore handler accepts only 3 or 4 and rejects 5 with `kIOReturnBadArgument`, so every escrow-bag unlock fails and `backup2 encryption` returns EscrowFailure. The count-4 path reads only scalars[3] (the same flag bit), so a count-5 call is handled correctly by it unchanged. Redirect the `cmp w8,#4` into a 6-word cave that accepts 4 or 5 (both → the original count-4 path) else takes the handler's own BadArgument branch. Anchor (structural): the 13-word count-dispatch block matched by its fixed words with the four branch words masked (opcode+condition kept, imm19/imm26 wildcarded); BadArgument/count-4 targets decoded from the anchor's own branches, no absolute offset. The `cset w25,ne` word is part of the fixed match and is what makes the block unique among the five keystore handlers that share this 3/4-count preamble — see caveat (2). **Self-guarding:** the anchor requires `cmp w8,#4 ; b.ne` (the 3/4-only reject shape), so on a kernel that already accepts 5 (Apple-native 26.6+, or this patch's own output) it finds no match and no-ops — hence no cloudOS bound is needed. Replacement bytes from the keystone-verified `ARM64Encoder.encodeCmpWImmediate`/`encodeBCond`/`encodeB`. Kernelcache is SPTM-content-measured, so apply at create time (not hot-swappable). **Version floor empirically pinned (2026-10-26)** by scanning native iPhone17,3 kernelcaches: the keybag handler is `cmp#3;b.eq ; cmp#4;b.ne` (3/4 only) on 18.6.2 / 26.1 / 26.4 / **26.5 (23F77)**, and becomes `cmp#3;b.eq ; cmp#4;b.eq ; cmp#5;b.ne` (accepts 5) on **26.6 (23G71)** / 26.6.1 / 27.0.1 — Apple's own 26.6+ handler is byte-identical to the shape this patch synthesizes. **Review caveats (not yet on-device validated):** (1) the dispatch-table index of the patched handler is 13, not the "selector 12" the introducing commit's comment states — cosmetic (the block, not the label, is patched), but the comment should be corrected; (2) uniqueness rests on the arbitrary `cset w25` register allocation, so a kernel rebuild that reallocates it would drop the match (fail-closed) — the robust key would be the IOExternalMethod dispatch-table entry for the real keybag-unlock selector, needing on-device confirmation of that selector number before retargeting. See `KernelCustomFirmwarePatchAksUnlockBag.swift`. | `26.6+` |

### EXP-Only Kernel Methods (Reference List)

Runs in `KernelEXPPatcher.findAll()` (chained after `KernelPatcher` +
`KernelJBPatcher` for the `.exp` variant only — JB and other variants
do NOT execute these).

| #      | Group | Method                | Function                                                              | Purpose                                                                                                                                                                                                                                                                                                                                                                       | EXP Enabled |
| ------ | ----- | --------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :---------: |
| EXP-01 | B     | `patch_hv_vmm_rename` | sysctl OID name cstring `"hv_vmm_present"` → `"Xv_vmm_present"` (Part A) + every kernel-internal occurrence of `kern.hv_vmm_present` cstring/sandbox-profile token mangled at byte 5 (Part B) | Rename the `kern.hv_vmm_present` OID's name in place (`'h' → 'X'` at offset 0 of the 14-byte cstring). After this: `sysctlbyname("kern.hv_vmm_present")` returns ENOENT; `sysctlbyname("kern.Xv_vmm_present")` returns the original int value (1). Part B mangles every kernel-internal caller — AMFI, IOCryptoAcceleratorFamily, sandbox-profile token, apfs — so they keep hitting the renamed OID. Companion to the user-mode blacklist-flip mangle in `cfw_patch_hv_vmm_dsc.py`. |      Y      |

## CFW Installation Patches

### Binary Patches Applied Over SSH Ramdisk

| #   | Patch                     | Binary                 | Purpose                                                       | Regular | Dev | JB  |
| --- | ------------------------- | ---------------------- | ------------------------------------------------------------- | :-----: | :-: | :-: |
| 1   | `/%s.gl` -> `/AA.gl`      | `seputil`              | Gigalocker UUID fix                                           |    Y    |  Y  |  Y  |
| 2   | NOP cache validation      | `launchd_cache_loader` | Allow modified `launchd.plist`                                |    Y    |  Y  |  Y  |
| 3   | `mov x0,#1; ret`          | `mobileactivationd`    | Activation bypass                                             |    Y    |  Y  |  Y  |
| 4   | Plist injection           | `launchd.plist`        | bash/dropbear/trollvnc/vphoned daemons                        |    Y    |  Y  |  Y  |
| 5   | `b` (skip jetsam guard)   | `launchd`              | Prevent jetsam panic on boot                                  |    -    |  Y  |  Y  |
| 6   | Weak dylib load injection | `launchd`              | Load short alias `/b` (copy of `launchdhook.dylib`) at launch. On by default; set `DISABLE_LAUNCHD_HOOK=1` to skip because this pid-1 hook path is boot-critical and has produced boot-analysis failures |    -    |  Y  |  Y  |
| 7   | cstring byte 5 mangle `'h' → 'X'` (`"kern.hv_vmm_present"` → `"kern.Xv_vmm_present"`) + per-page slot-hash re-attestation, BLACKLIST semantics — **EXP only** | DSC dylibs        | Companion to EXP kernel rename (`KernelEXPPatcher.patchHvVmmRename`). The mangle is applied to every DSC dylib EXCEPT those in `DONT_PATCH_INSTALL_NAMES` (sign-in / device-likeness consumers, ~15 entries). Patched dylibs query `kern.Xv_vmm_present` and get the truthful 1 (graphics / accel passthrough). Blacklisted dylibs keep the original cstring, hit ENOENT on the renamed kernel, cache 0, lie about VM presence. On `codeSigningMonitor == 2` hardware the byte-mangle alone causes `CODESIGNING/Invalid Page` SIGKILL because TXM enforces per-page hashes; the re-attestation pass recomputes the SHA-256 slot in the chunk's `CS_CodeDirectory` for every modified 16 KiB page. See `scripts/patchers/cfw_dsc_codesign.py` and `cfw_patch_hv_vmm_dsc.py`. |    -    |  -  |  -  |
| 8   | (removed — was: standalone-binary mangle in 6 rootfs Mach-Os via SSH) | n/a               | Removed in the blacklist-flip redesign. With the EXP kernel rename in place, the 6 rootfs binaries (MobileActivationMigrator, CheckerBoard, StoreKitUISceneService, storekitd, appstored, CorePrescriptionService) get the desired "cache 0 / not in a VM" behavior for free: they keep their original cstring, hit ENOENT on the renamed kernel sysctl, defensive `cbnz w0, skip` leaves the cached byte at BSS-zero. No SSH-time standalone patch needed. |    -    |  -  |  -  |
| 9   | `mov w3,#<size>` -> `mov w3,#<base-size>` in `_kern_SwapEnd` — **26.0/26.0.1 and 18.x** | DSC `IOMobileFramebuffer` | Fixes host VZ GUI black-screen with the available PCC vphone600 userclient: the userclient does an exact `checkStructureInputSize` check on external-method-5 (SwapEnd) input, so a userland whose `_kern_SwapEnd` sends a different-sized state gets `kIOReturnBadArgument` and the host display stays black (guest still renders — the Apple logo is visible over VNC, just not in the vphone-cli view). **The accepted size is a property of the base kernel, not the userland**: 26.1 base -> **0x560**, 26.4 base (xnu-12377) -> **0x588**. The 0x588 value is confirmed two ways: the sole dispatch-shaped entry in `kernelcache.*.vphone600` with `checkStructureInputSize==0x588` (scalarIn=0, scalarOut=0, structOut=0, preceded by a ptrauth code ptr, at decompressed file offset 0x9c7228), and empirically — native 26.5 userland sends 0x588 and displays correctly on this stack. Source (userland-sent) sizes observed: 18.6.2 = 0x514, 26.0/26.0.1 = 0x548, 27.0 (24A5380h) = 0x6e0. The patcher is semantic (anchors on `mov w1,#5` -> `mov w3,#imm` -> `mov x4,#0`/`mov x5,#0` -> `bl` inside `_kern_SwapEnd`) and idempotent — rewrites the size to `--target-size` regardless of source and re-attests the modified DSC page. Install gate: `26.0*` / `18.*` -> 0x560 (26.1 base). Validated after host install on `17,3_26.0_23A341`, `17,3_26.0.1_23A355`, and `17,3_18.6.2_22G100` (Apple logo renders) against the 26.1 base. **CORRECTION (2026-07-15): iOS 27.0 is NO LONGER handled here.** 27 presents the paravirt display via IOMFB's `_virt_*` callback path — external method 5 is NEVER called — so no SwapEnd *size* change can help 27 (confirmed by kernel trace + live AppleParavirtGPU idle scheduler). iOS 27 now uses **force-kern (item 11)** to route present back onto method 5; this row applies to 26.0/26.0.1/18.x only. |    Y    |  Y  |  Y  |
| 10  | Zero `maxSlide` in `dyld_cache_header` (`@0xF0`) — **iOS 27.0 / any userland whose cache overflows the 6 GiB region** | DSC `dyld_shared_cache_arm64e` header | Fixes pid-1 `launchd` panic at boot on the vphone600 26.x kernel. The kernel reserves `SHARED_REGION_SIZE_ARM64 = 0x180000000` (6 GiB) and, at map time, needs room for the cache's mapped span **plus** the header `maxSlide` (ASLR range). iOS 27.0's cache (span `0x17c830000` ≈ 5.95 GiB) + `maxSlide 0x20000000` = `0x19c830000` > 6 GiB, so `_shared_region_map_and_slide` returns `ENOMEM`, dyld cannot map `libSystem.B.dylib`, and `launchd` panics (`initproc failed to start`). Zeroing `maxSlide` (LE u64) in the main chunk maps the cache at slide 0 (fits with ~58 MiB spare). Install gate: **`27.*`** (hard-gated in `cfw_install.sh` as of 2026-07-20 — an 18.x/26.x base skips it entirely). The patcher additionally self-gates (`patch-dsc-maxslide`): no-op unless span + maxSlide > `0x180000000`, kept as defense-in-depth so 26.x / 18.x are untouched even if the install gate were removed. **The non-27 opt-in is gone** (2026-09-30): `FORCE_DSC_MAXSLIDE=1`, later `--force-dsc-maxslide`, no longer exists on any command or in Launchpad. `dyld-boot-maxslide` is declared `iOSBase: .major(27)`, so non-27 bases keep their native slide. `patch-dsc-maxslide --force` remains on the standalone verb for hand use; `cfw install` never passes it. **24A435 (27.0 RC) checked 2026-09-30** for issue #531: the pristine SystemOS cryptex header reads `sharedRegionStart 0x180000000`, `sharedRegionSize 0x17D504000`, `maxSlide 0x20000000`, so span + slide is `0x19D504000`. `vphone-cli cfw patch-dsc-maxslide --dry-run` (2.1.6) reports `overflow` and would zero it; an installed 24A435 guest reads `maxSlide 0x0` and boots. The self-gate therefore patches 24A435 without force. The 512 MiB slide is the cache builder's fixed iOS arm64 value, so every 27 cache overflows this region. Source check (xnu-12377, `shared_region_map_and_slide_2_np`, `vm_shared_region_map_file_setup`, `vm_map_locate_space_fixed`): the kernel picks a 16 KiB-aligned slide strictly below `maxSlide` and maps each range FIXED inside the `0x180000000` submap. With no twig rounding and no reserved area, `size + maxSlide <= 0x180000000` is a sufficient test, one 16 KiB page stricter than needed. The #531 panic therefore came from a guest whose cache was never patched. Most likely its CFW install had not completed, because `cfw install` swaps in its clone only on success. It did not come from the gate. Page 0 of the main chunk is re-attested (since 2026-10-13). The kernel does not need it: a cache left with page 0's original slot boots, as validated below. Xcode does: `xcodebuild -prepareDeviceSupport` copies the guest's cache and its `dsc_extractor` stops on `dyld shared cache code signature for page 0 is incorrect`, yet marks the copy done, so Device Support holds only the DriverKit cache and LLDB reads every system library from guest memory (minutes of black screen for any app launched under the debugger, e.g. a Flutter debug run). Seen on `iPhone17,3 27.0.1 (24A446)`: the stored slot matched the header with `maxSlide 0x20000000`, not the patched one. A run over a header already at `maxSlide 0` re-attests page 0 too, and `cfw install`/`update-environment` re-run this verb whenever it is live (`dyldPatchesRerunWhenLive`), because its undo record cannot tell the old implementation from the new. Validated on `17,3_27.0_24A5380h` + cloudOS 26.4 (`c0ecdb4b…`): `dyld cache mapped system-wide`, launchd reaches first unlock, vphoned connects as iOS 27.0.0, 0 panics. See `scripts/patchers/cfw_patch_dsc_maxslide.py`. |    Y    |  Y  |  Y  |
| 11  | Retarget public `_IOMobileFramebufferSwap*` trampolines -> `b _kern_Swap*` (force-kern) — **iOS 27.0** | DSC `IOMobileFramebuffer` | **iOS-27 VZ-view (host paravirt-GPU scanout) fix, userland half.** The host `VZVirtualMachineView` is fed by the guest `AppleParavirtGPU` scanout, which the 26.4 kernel drives ONLY from the IOMFB userclient SwapEnd (external method 5) — the `_kern_Swap*` path. iOS 27 defaults the paravirt display's present to IOMFB's parallel `_virt_Swap*` path (`_virt_SwapEnd` does no userclient call — it invokes an in-process callback `blraaz [conn+0xe68]` and hands the IOSurface to a virtual-display consumer), so the paravirt GPU never scans out → host VZ window black (guest still composites; GUI visible over in-guest TrollVNC; AppleParavirtGPU `SchedulerState` idle). The public `_IOMobileFramebufferSwap*` entrypoints are thin trampolines (`cbz x0; ldr xN,[x0,#slot]; cbz xN; braaz xN`) that tail-call the per-connection swap fp (kern or virt impl). This patch rewrites each trampoline's first insn to `b _kern_Swap<Name>`, forcing present onto method 5 regardless of how 27 classified the display (tail-call, args intact → behaviourally identical to selecting the kern fp). Fully dynamic: public + `_kern_` addrs resolved by name via `ipsw dyld symaddr`, trampoline shape verified by Capstone, branch bytes from Keystone `asm_at()`, modified DSC code pages re-attested. Requires ≥{SwapBegin,SwapEnd,SwapSetLayer} or raises (dry-run retargets 31 entrypoints on 24A5380h, skips 4 non-trampolines). **Pairs with the JB kernel patches (`patchIomfbSwapEndVariableSize` + `patchIomfbSwapEndHandlerSize`)** which relax the 26.4 userclient's two exact `0x588` size gates to accept 27's native `0x6e0` IOMFBSwapRec (prefix matches 26.x, so the paravirt swap handler reads valid fields). Install gate: `27.*`. See `scripts/patchers/cfw_patch_iomfb_force_kern.py`. **VALIDATED on-device (2026-07-15, `17,3_27.0_24A5380h` + cloudOS 26.4 `c0ecdb4b…`, JB): iOS 27 userland renders AND is interactive in the native VZ view (not just TrollVNC); clean boot — no `kIOReturnBadArgument`/SwapEnd rejection/panic.** Runtime confirmed 31 entrypoints retargeted (4 non-trampoline setters left on virt). **Conditional since 2026-10-07 (DeviceHub):** forcing every trampoline also sent the capture display that Xcode's DeviceHub stream adds to the kernel; it has no userclient port, so backboardd logged `display 2 swap_end returned error 10000003` (`MACH_SEND_INVALID_DEST`) and the stream was black. Each trampoline is now `cbz x0, <fail>` / `ldr w16, [x0, #0x14]` / `cbnz w16, _kern_Swap<Name>` / `b _virt_Swap<Name>`: a connection with an IOConnect port (the paravirtual main display) still presents through method 5, a virtual display keeps its in-process path. Only operations with public, `_kern_` and `_virt_` siblings take part (ten on 24A446; `SwapSignal` is not a trampoline). The `0x14` port offset is the one every `_kern_Swap*` passes to the external method, verified on 24A446. The identifier is unchanged; the installer recognizes the old 4-byte undo records (`DyldSharedCacheUndoLog.outdatedImplementations`), reverts them and applies the conditional form in the same `cfw install` or environment update, so an installed guest upgrades without manual steps. Validated on `iPhone17,3 27.0.1 (24A446)`: VZ scanout unchanged, DeviceHub live. See `Research/Guest/devicehub_screen_viewing.md`. |    Y    |  Y  |  Y  |
| 12  | NOP `-[_LSDModifyClient clientIsEntitledForEmbeddedRegistrationOperations]` entitlement gate + per-page re-attest — **iOS 27.0** | DSC `CoreServices` (LaunchServices) | **iOS-27 app-registration fix.** lsd gates `-[_LSDModifyClient performPostInstallationRegistration:operationUUID:reply:]` (and the containerized/rebuild registration paths) behind `clientIsEntitledForEmbeddedRegistrationOperations`, which does `xpc_connection_copy_entitlement_value` on the XPC peer for any of `com.apple.private.coreservices.lsaw` / `com.apple.private.installcoordinationd.daemon` / `com.apple.private.coreservices.can-register-install-results`. A client without one gets `NSOSStatusErrorDomain -54` (permErr, `LSDModifyService.mm:1639`), so `registerApplicationDictionary:` / `registerContainerizedApplicationWithInfoDictionaries:` fail and no app can (re)register — blocking vphoned's installer, TrollStore, and uicache/Sileo alike. The entitlement route is a dead end even for a launchd platform daemon (vphoned) whose validated csblob (`csops CS_OPS_ENTITLEMENTS_BLOB`) contains all three: LS registration is proxied, so the XPC peer lsd inspects is not the registering process. Fix: NOP the final `cbz w0, <not_entitled>` (the conditional branch whose fall-through sets the `mov w<reg>,#1` result) so the method always returns YES. Fully dynamic: method resolved via the DSC's own `.symbols` in-image local-symbol table (ipsw `symaddr -a`/`a2s` time out on this cache), gate located by control-flow shape in Capstone, NOP from Keystone `asm("nop")`, modified 16 KiB page re-attested (`cfw_dsc_codesign.py`; TXM enforces per-page). The resulting CDHash change is accepted by the JB always-true AMFI cdhash-trust patch. Install gate: **`27.*`** (hard-gated in `cfw_install.sh` as of 2026-07-20 — an 18.x/26.x base does not apply it). The patcher additionally self-gates (`patch-lsd-embedded-reg`): no-op on pre-iOS-27 userlands where the method is absent. **Pairs with vphoned's `vp_register_path` containerized-registration fallback** (`registerContainerizedApplicationWithInfoDictionaries:...:registrationError:`, treating a nil `registrationError` as success since it returns NO even when it registers). Also paired with **`/cores/vpregister`** (built + deployed by `cfw_install_jb.sh` / `cfw_install_exp.sh`, invoked by `vphone_jb_setup.sh` at first boot — 27-gated by DEPLOYMENT: `cfw_install_jb.sh`/`cfw_install_exp.sh` copy `/cores/vpregister` only when the mounted rootfs `SystemVersion.plist` is `27.*`, and the setup script's `[ -x /cores/vpregister ]` presence check is the runtime gate. Do NOT gate the invocation on a guest `sw_vers` check — the hybrid guest does not reliably report the 27 userland version at first boot, which silently skipped registration): it registers JB app bundles (Sileo) via the same containerized API, because `uicache -a`'s `registerApplicationDictionary:` is a deprecated no-op on iOS 27 (lsd logs *"you cannot use ... to register applications anymore. These interfaces have been deprecated for years."*). **VALIDATED (2026-07-17, `17,3_27.0_24A5380h` + cloudOS 26.4, JB): -54 gone; Sileo registers (`uicache -l` 0→1) via `vpregister`; vphoned installs+registers a test IPA (`com.vphone.vptest`) to `/var/containers/Bundle/Application/` end-to-end. Clean boot (re-attest correct; no CoreServices page rejection).** See `scripts/patchers/cfw_patch_lsd_embedded_reg.py` and `Siblings/VPRegister/vpregister.m`. **FIX (2026-08-10):** `_find_gate` only matched the live `cbz`/`cbnz` branch shape, so re-running `cfw install` (host-mount flow, `myphone` VM, `17,3_27.0_24A5390f`) against a cache where this gate was already NOP'd from a prior pass raised `ValueError: ... entitled-result gate ... not found` instead of recognizing the idempotent state (unlike the Cryptex/IOMFB steps, which log `already ... idempotent` and skip cleanly). Confirmed live via host-mount disassembly: the third check's `bl <check3>` is followed by a bare `nop` at the gate site (exact match against `asm("nop")` bytes) immediately before `mov w20, #1` — i.e. already patched. `_find_gate` now also matches `nop` immediately preceding `mov w<reg>,#1` as an already-patched gate, so a re-run just re-attests the page instead of erroring. |    Y    |  Y  |  Y  |
| 13  | `mov x0,#1; ret` on `-[DIDiskArb isMountCompleteWithExpectedCount:diskTracker:]` — **iOS 27.0** | `diskimagesiod` | **iOS-27 DDI (`/System/Developer`) auto-mount — mount-gate.** After the personalized DDI attaches (kernel side: JB-28 + JB-09), MobileStorageMounter waits on diskimagesiod's `-[DIDiskArb waitForDAMountWithExpectedCount:diskTracker:]` before it does the real (nobrowse) mount at `/System/Developer`. That wait loops until `isMountComplete` (= `callbackReached \|\| (appearedDiskCount>=expectedCount && mountedDiskCount>=mountableDiskCount)`) is YES; on the 26.4-kernel / 27-userland hybrid it never becomes true (not all of the DMG's IOMedia "appear" to diskimagesiod's DiskArbitration session, and diskarbitrationd never auto-mounts the volume), so the wait hangs and pmd3 times out. diskimagesiod itself does NOT mount the DDI (its `-[DIDiskArb mountWithDeviceName:...]` is dead code) — it only gates MobileStorageMounter. Forcing `isMountComplete` → YES lets the wait return so MobileStorageMounter proceeds. IMP resolved via LC_SYMTAB or ObjC metadata (selector → `__objc_selrefs` → `__TEXT,__objc_methlist` relative method list → IMP); prologue overwritten `mov x0,#1 ; ret` (safe — the method returns to the caller's unsigned LR without pushing a frame). **Gated to 27.\*** in `cfw_install.sh` (same `$IOS_VERSION` as the DSC patches): on a version-matched userland the native wait completes correctly and forcing it early could race the real mount, so it is NOT applied there. Embedded sandbox profile + private DA/apfs entitlements preserved on re-sign (`ldid_sign_ent`). **Validated on `c0ecdb4b` 26.4 + 27.0 userland: `pmd3 mounter auto-mount` → rc=0, DDI at `/System/Developer`, idempotent across fresh boots.** See `scripts/patchers/cfw_patch_diskimagesiod.py`. |    Y    |  Y  |  Y  |
| 14  | Merge backboard/frontboard launch mach-services into `com.apple.security.exception.mach-lookup.global-name` + `ldid_sign_ent` re-sign — **iOS 27.0** | `/Applications/Campo.app/Campo` | **iOS-27 Campo (wallpaper renderer) crash-loop fix — sandbox half.** Campo declares `com.apple.private.sandbox.profile:embedded = temporary-sandbox` + `no-container`, so it runs under the `temporary-sandbox` profile. On the 26.4 vphone600 kernel that builtin profile predates iOS 27 and DENIES the `mach-lookup` of the backboard/frontboard launch services, so `BKSDisplayServicesStart` (looks up `com.apple.backboard.display.services`) and then `+[BKSHIDEventDeliveryManager sharedInstance]` (HID) fail, log *"backboardd isn't running -- or we couldn't talk to it"*, and `brk #0` ~34 ms after launch → continuous crash-loop, no wallpaper (launchd eventually throttles it off). **JB-02d is NOT sufficient here:** it stops the exec-time container-manager-upcall autobox *KILL*, but Campo is still placed in `temporary-sandbox` (its own declared profile — confirmed the JB-02d `b`-flip is present in the running kernel yet Campo still traps), and that profile still denies the lookups. Fix: append the needed services to Campo's OWN `com.apple.security.exception.mach-lookup.global-name` array — the Apple-sanctioned escape hatch, which `temporary-sandbox` honors (Campo already ships ~20 such exceptions; these launch services simply aren't among them because 27's profile allows them directly). Services added (backboard names exact, from `com.apple.backboardd.plist` MachServices): `com.apple.backboard.display.services`, `com.apple.iohideventsystem`, `com.apple.CARenderServer`, `com.apple.backboard.hid.services`, `com.apple.backboard.hid-services.xpc`, `com.apple.backboard.TouchDeliveryPolicyServer`, `com.apple.backboard.system-app-server`, `com.apple.backboard.watchdog`, `com.apple.backboard.oswatchdog`, `com.apple.backboard.altsysapp`, `com.apple.AttentionAwareness`, `PurpleSystemEventPort`, `PurpleWorkspacePort`, `com.apple.frontboard.systemappservices`, `com.apple.frontboard.workspace`, `com.apple.frontboardservices.systemappmanager`, `com.apple.frontboard.watchdog`. Merge is done by the external helper `scripts/patchers/campo_mach_lookup_exceptions.py` (Python `plistlib`, not `plutil` — the entitlement key contains dots that `plutil` keypaths would mis-split; idempotent, preserves the existing array); re-signed with the JB `signcert.p12` via `ldid_sign_ent` (AMFI enforcement is relaxed on the research VM, so the re-signed cdhash loads and the entitlements are honored). Applied at host-mount build time in `cfw_install_jb.sh` / `cfw_install_exp.sh` step **[JB-3b]**, **hard-gated to `27.*`** via the mounted rootfs `SystemVersion.plist` `ProductVersion` (same gate as the vpregister/DSC patches) — skipped entirely on 26.x/18.x, which don't need it and where `Campo.app` also exists. **VALIDATED on-device (2026-07-21, `17,3_27.0_24A5390f` + cloudOS 26.4, JB): Campo launches and stays up (stable pid, no BKSDisplayServicesStart/BKSHIDEventDeliveryManager trap, no crash-loop); first-cut display-only exception advanced the trap from display→HID, confirming the mechanism, then the full service set cleared it.** See `scripts/cfw_install_jb.sh` / `scripts/cfw_install_exp.sh` step JB-3b and the merge helper `scripts/patchers/campo_mach_lookup_exceptions.py`. |    -    |  -  |  Y  |
| 15  | Derive `matched` from `error_code` + drop the `brk #1` in libxpc `_xpc_token_satisfies_lwcr` (`cset w8,ne; eor w8,w0,w8; tbz w8,#0` → `cset w0,eq; nop; nop`) + per-page re-attest — **iOS 27.0** | DSC `libxpc.dylib` | **iOS-27 daemon crash-loop fix (Lightweight Code Requirement).** iOS 27 lets an XPC server pin a "lightweight code requirement" (LWCR) on its listener — `xpc_connection_set_peer_lightweight_code_requirement`, or the Swift `XPCPeerRequirement.hasEntitlement(_:)` wrapper (→ `xpc_peer_requirement_create_entitlement_exists` → `_xpc_peer_requirement_create_lwcr_entitlement_requirement` → `xpc_peer_requirement_create_lwcr`). Creating the requirement runs a self-check, `_xpc_token_satisfies_lwcr`, which calls an internal matcher returning a `matched` bool (w0) plus a `match_result.error_code` (`AICMR_MATCH == 0`), then hard-asserts they agree (`matched == (error_code == 0)`) via `_os_crash_msg` → `brk #1`. On stock iOS the two always agree; under our JB code-signing environment the matcher's query writes `error_code = MATCH(0)` yet returns a failure status, so the matcher yields the forbidden `(matched=0, error_code=0)` pair and libxpc aborts. Because EVERY daemon that pins an entitlement peer-requirement at startup hits it, `intelligencetasksd` / `searchpartyd` / `transparencyd` / `bluetoothd` (and others) crash-loop continuously from boot (launchd re-spawn + ReportCrash churn). Fix: recompute `matched` from `error_code` and make the abort unreachable — `cset w8,ne; eor w8,w0,w8; tbz w8,#0,<abort>` → `cset w0,eq; nop; nop`; the function now returns `(error_code == 0)`, which reproduces stock's verdict when the two agree and resolves the contradiction toward "satisfied" when error_code says MATCH (real allow/deny for genuinely (un)satisfied peers is unchanged, since those set `error_code` != 0). Fully dynamic: resolved via the DSC's own `.symbols` in-image local-symbol table as `__xpc_token_satisfies_lwcr` (the double-underscore mangled name; a single-underscore lookup silently skipped every iOS-27 build until fixed 2026-08-11), the check located by control-flow shape in Capstone (`cset wC,ne; eor wE,w0,wC; tbz wE,#0`), replacements from Keystone, modified 16 KiB page re-attested (`cfw_dsc_codesign.py`; TXM enforces per-page; CDHash change accepted by the JB always-true AMFI cdhash-trust patch). Install gate: **`27.*`** (in `cfw_install.sh`, same block as maxSlide/lsd). Patcher additionally self-gates (`patch-xpc-lwcr`): no-op on pre-iOS-27 userlands where the symbol is absent. **VALIDATED on-device (2026-07-22, `17,3_27.0_24A5390f` + cloudOS 26.4, JB, host-mount deploy): patched bytes live (`e0179f1a 1f2003d5 1f2003d5`); the four LWCR crash-loopers disappear from the crash census after boot; launchd itself (which links libxpc) boots clean past first unlock — patch does not brick boot. NOTE: does NOT stop the resprings — those are a separate `FileProviderResolver` ResolverService memory-balloon → jetsam → backboardd kill (see investigation notes).** See `scripts/patchers/cfw_patch_xpc_lwcr.py`. **FIX (2026-09-22):** same idempotence gap as row 12, and for the same structural reason: `_find_consistency_check` searches for `cset wC,ne; eor wE,w0,wC; tbz wE,#0`, which is precisely the idiom this patch replaces, so on a cache it had already patched the search returned `None` and raised `ValueError: LWCR consistency idiom ... not found`. The per-edit `already patched` byte comparison further down could never run, because it needs the addresses that search has to supply first. Hit live on `17,3_27.0_24A435` (RC) + cloudOS 26.4, JB, host-mount flow, when a first `cfw_install_host` pass completed phase 1/7 and then failed later at JB-1 (missing `insert_dylib`); the retry died here. Confirmed by read-only host-mount disassembly of `__xpc_token_satisfies_lwcr` @ `0x1805DD5BC`: `cmp w8,#0; cset w0,eq; nop; nop` — already patched. A new `_find_patched_shape` now recognizes that post-patch shape (`cset w0,eq` + two `nop`s, anchored on the `cmp wX,#0` that feeds it) and returns a no-op instead of raising. Checked against the live cache (dry run returns rather than raises) and with negative controls: fed the pre-patch stream the detector stays silent and the normal idiom search still matches, so the patching path is intact on a pristine cache. |    Y    |  Y  |  Y  |
| 16  | NOP the sysctl-error `b.eq <os_crash>` in libSystem `___os_lockdown_mode_enabled_block_invoke` (`cmn w0,#1; b.eq <crash>` → `nop`) + per-page re-attest — **iOS 27.0** | DSC `libSystem` (`lockdown_mode.c`) | **iOS-27 launchd (pid 1) boot-panic fix.** iOS 27's `os_lockdown_mode_enabled()` resolves Lockdown Mode once via `sysctlbyname("security.mac.lockdown_mode_state_public", &out, &len, 0, 0)`; on a -1 return it `os_crash`es (`lockdown_mode.c:os_lockdown_mode_enabled_block_invoke:47`). The vphone base kernel (cloudOS 26.x) does not implement that MAC sysctl, so the call returns -1/ENOENT and the first process to query Lockdown Mode after "Continuing system boot" aborts — that process is launchd (pid 1), so the kernel panics `initproc exited -- exit reason namespace 2 subcode 0x6 description: none`. b4 (24A5390f) boots on the same kernel; the sysctl query is new in b5 (24A5408d). The block pre-zeroes its output buffer (`stp x8, xzr, [sp]`), so NOPping the error branch falls through to the normal path, reads 0, records "Lockdown Mode disabled", and returns cleanly; on a kernel that implements the sysctl the branch is never taken (w0==0), so the patch is behavior-neutral. Dynamic: `___os_lockdown_mode_enabled_block_invoke` resolved via the DSC's own `.symbols` local-symbol table; the `cmn wR,#1; b.eq` sysctl-error idiom located by control-flow shape in Capstone; NOP from Keystone; modified 16 KiB page re-attested (`cfw_dsc_codesign.py`). Install gate: **`27.*`** (same block as maxSlide/lsd/lwcr). Self-gates: no-op where the symbol is absent (pre-iOS-27 userlands). **Root-caused + verified on-device 2026-08-11** (`17,3_27.0_24A5408d` + cloudOS 26.4, JB): abort message read live via the kernel GDB stub (patched `_abort`→`b .` to freeze launchd's spinning vCPU, then read its registers + the libSystem crash-info global) = `lockdown_mode.c:os_lockdown_mode_enabled_block_invoke:47: No such file or directory`; with the NOP applied the panic is gone and boot continues past "Got first unlock" into normal daemon startup. See `scripts/patchers/cfw_patch_lockdown_mode.py`. **FIX (2026-09-22):** third instance of the row-12 idempotence gap, found immediately after the row-15 one on the same `17,3_27.0_24A435` (RC) + cloudOS 26.4 JB host-mount re-run. `_find_error_gate` required the slot after `cmn wR,#1` to be a `b.eq`; once patched it holds the `nop` this patch writes, so the search returned `None` and raised `ValueError: ... sysctl-error gate not found` — again before the `cur == nop` byte comparison below it could ever be reached. Confirmed by read-only host-mount disassembly of `___os_lockdown_mode_enabled_block_invoke` @ `0x237EF2260`: `bl <sysctlbyname>; cmn w0,#1; nop` at `0x237EF2298`. The gate slot now also matches `nop`, which lets the existing byte comparison report the already-patched state; the `bl` + `cmn wR,#1` anchor is unchanged, and re-writing a NOP over a NOP is inert. Negative controls checked: an unrelated instruction in the slot, a `cmn` with no preceding `bl`, and a `cmn` with the wrong immediate are all still rejected, and the pre-patch stream still resolves to the `b.eq`. |    Y    |  Y  |  Y  |
| 17  | `mov x0,#0 ; retab` over the two instructions after the prologue `pacibsp` of `checkTrustAndAuthorization` — **all bases** | DSC `libmis.dylib` | **Free-certificate app-launch fix (online authorization).** A guest restored by this project is hacktivated — `mobileactivationd.should_hactivate` forces `-[DeviceType should_hactivate]` to YES so the VM never contacts Apple's activation service. The consequence nobody had traced until now is that it also never receives an **activation record**: `/private/var/root/Library/Lockdown/` holds `data_ark.plist`, `escrow_records` and `pair_records` but no `activation_records/`, while `data_ark.plist` still says `-ActivationStateAcknowledged = true`. With no activation record there is no device identity to sign an authorization request with, so the chain is `online-auth-agent: Failed to copy activation record.` (MobileActivation `-1`) → `Couldn't get device identity … "online-auth-agent is not allowed to use this API."` (MobileActivation `-25`) → `Could not perform authorization attempt`, and `Preferences: MDMProvisioningProfileTrust failed to verify provisioning profile <uuid> with error 4`. libmis's `checkTrustAndAuthorization` therefore returns `0xE8008026`, which SpringBoard reports as `validation failed because of missing trust and/or authorization (0xe8008026)` followed by `signature state: Profile Needs Network Validation, reason: Requires Network Validation`, and FrontBoard refuses the launch (`FBSOpenApplicationErrorDomain 3`, *"…or its profile has not been explicitly trusted by the user"*). **This only bites free personal-team profiles**; a paid team's profile is not marked as needing online authorization, and Settings' "Verify App" can never clear the free one because the network step it offers is exactly the step that cannot complete. **Not to be confused with `0xE8008012`** (`misagent: attempt to install invalid profile`), which is the ordinary "this UDID is not in the profile's `ProvisionedDevices`" refusal and is correct behaviour — installation itself needs no patch. Fix: short-circuit `checkTrustAndAuthorization` to return success. Its prologue seeds the failure code into the register it returns (`mov w21,#0x8026 ; movk w21,#0xe800,lsl #16`) and the body subtracts its way to the neighbouring MIS errors (`sub w21,w21,#0x2` → `0xE8008024`, `#0x25` → `0xE8008001`, `#0x9` → `0xE800801D`) or replaces it with 0; both call sites inside `MISValidateSignatureAndCopyInfoWithProgress` treat 0 as success. The two instructions after the prologue's `pacibsp` (`sub sp,sp,#0xa0` and `stp x28,x27,[sp,#0x40]`) become `mov x0,#0 ; retab`. **`pacibsp` is deliberately kept** rather than overwritten: it signs LR with SP as the modifier and `retab` authenticates against the SP it sees, so returning before the frame is built leaves the pair balanced — a plain `ret` over `pacibsp` would also work but makes the larger claim. The optional out-parameter is safe to leave unwritten: one caller passes NULL for it outright (`mov x5,#0`), the other pre-zeroes the slot (`str xzr,[sp,#0x68]`) and skips the merge while it is still NULL (`cbz x8`). Fully dynamic, and the function is **static — it carries no symbol**, so neither the cache's `.symbols` table nor `ipsw symaddr` can name it: it is anchored instead on the log string that names it outright, `"cdHash (%p) or matchedProfileIDs (%p) NULL in checkTrustAndAuthorization"` (one of four `checkTrustAndAuthorization` / `checking trust and authorization` literals, all four of which xref inside this one function), whose containing image is confirmed to be `/usr/lib/libmis.dylib` via `findMachOHeaderBefore` + `readInstallName`; the ADRP+ADD pair that materialises the literal is matched on Capstone operand semantics, the nearest preceding `pacibsp` gives the function start, and that prologue is then **required** to seed `0xE8008026` within 48 instructions before anything is written — two independent routes that must agree, in the manner of `CustomFirmwareMobileActivation.locateIMP`. Replacement bytes are `ARM64.movX0_0` + `ARM64.retab`, both existing keystone-checked constants (no new encoder, no keystone trip). Modified 16 KiB page re-attested. **Install gate: none, but OFF in `standard` since 2026-09-30** — the guest is hacktivated on every base, so the failure exists on every base; the declaration (`dyld-exp-mis_trust_auth`, in `com.vphone.patchset.guest.system`, renamed from `dyld-cfw-` when it left `standard`) carries no `applicability` and is not `bootEssential`. See "The MIS online-authorization patch leaves `standard`" at the end of this document for why it is now opt-in and what replaced it. Self-gating: a cache whose libmis lacks the naming literal reports absent and exits 0, an already-patched cache is a no-op (the byte comparison is against this patch's own output), and a cache with the literal but **neither** the seeding prologue **nor this patch's own `pacibsp ; mov x0, #0 ; retab`** is an **error** rather than a guess. **The second half of that sentence is a fix, made 2026-09-30 for issue #532, and it matters:** `locateSite` originally *required* the seed, and the seed is not guaranteed to outlive the write. On the 26.6.2 cache the compiler puts it at `functionVMA + 0x4C` (`checkTrustAndAuthorization @ 0x1BC6AE364`, seed at `0x1BC6AE3B0`), well clear of the two words at `+4`, so the byte comparison saw its own output and a second `cfw install` was already a no-op. On the 27.0 guest in the report the seed *was* the two words this patch overwrites (`checkTrustAndAuthorization @ 0x22406F814`), the first run destroyed it, and every later run died with `Patch site not found: … does not seed 0xE8008026 — MIS has been rewritten`, taking the whole install down after `dsc_maxslide` and before everything that follows. `DyldSharedCacheMISTrustAuthPatcher.isShortCircuited` now recognises the patch's own three words off the Capstone decode (`pacibsp`, `mov` with decoded destination `x0` and decoded immediate 0, `retab`) — the same "recognise your own output" fix `DyldSharedCacheXPCLWCRPatcher.findPatchedShape` and `DyldSharedCacheLockdownModePatcher.findErrorGate` got on 2026-09-22 — and `Site.shape` now carries `.seedsFailure(seedVMA:resultRegister:)` or `.alreadyShortCircuited` instead of a non-optional seed address. The genuine "MIS has been rewritten" hard failure is unchanged for a prologue that is neither shape. Covered by `DyldSharedCacheMISTrustAuthPatcherTests`, which builds a synthetic one-chunk cache (mapping table, `LC_ID_DYLIB` = `/usr/lib/libmis.dylib`, the naming literal, an ADRP+ADD that materialises it, and a real `CS_CodeDirectory` with SHA-256 page slots) in **both** seed layouts, because the 24A435 fixture can only exhibit the one that already worked. **VALIDATED on-device (2026-09-30, `iPhone17,3 26.6.2 (23G90)` + cloudOS 26.4 (23E5207q), JB, fresh `vm new` → `fw patch` → `restore` → `cfw install` into a new VM `05-mis-test`): an app signed with a free personal-team certificate now installs, verifies, launches, and Xcode `attach` to it succeeds.** The shape was first derived statically, from the `libmis.dylib` Xcode extracted from the live guest `01-use-me-rh` (`iPhone99,11 26.6.2 (23G90)` + cloudOS 26.4) into `iOS DeviceSupport/…/Symbols/usr/lib/`, where the two `#0x8026` immediates in the entire library are both inside this function; the patcher then reached exactly that site through the DSC chunk path, with both routes agreeing — `checkTrustAndAuthorization @ 0x1BC6AE364 in /usr/lib/libmis.dylib`, named by the literal referenced at `0x1BC6AE6B4`, prologue seeding `w21=0xE8008026` at `0x1BC6AE3B0`, written at `0x1BC6AE368` — and one 16 KiB page re-attested (slot 3260 of `dyld_shared_cache_arm64e.19`). The guest then booted normally through Setup Assistant to the home screen, so TXM accepts the re-attested page: the patch does not brick boot **on 26.6.2**. **It does on 27.0** (issue #532, `17,3_27.0_24A435` + cloudOS `26.4-23E5207q`): `TXM [Error]: Errno: selector: 45 | 78`, then `dyld[1]: Library not loaded: /usr/lib/libSystem.B.dylib … (no such file, no dyld cache)`, then `initproc failed to start`. Excluding only `mis_trust_auth` boots. That is not reproducible here — no 27.0 guest exists on this machine — so it is reported, not measured. **The direction taken is to stop editing the cache for this and express the same behaviour as a userspace hook instead**, and the disassembly says that is possible *without* rewriting any return value, because the whole branch is reachable from the caller's options dictionary. Read off libmis on `01-use-me-rh` (`iPhone99,11 26.6.2 (23G90)`, `MISValidateSignatureAndCopyInfoWithProgress @ 0x1BC6ABA4C`): the options are parsed into stack bytes by a `getBoolOption(dict, CFStringRef, char *out)` helper (`0x1BC674C60`) that **writes only when the key is present**, so every flag defaults to 0; `UnauthoritativeLaunch` or `AuthoritativeLaunch` then force `RespectUppTrustAndAuthorization = 1`, `HonorBlocklist = 1`, `ValidateSignatureOnly = 1`, `OnlineAuthorization = 0` as a *default set* that an explicit key still overrides; the explicit `RespectUppTrustAndAuthorization` read lands in `[sp+0x97]`, and `checkTrustAndAuthorization` is **only called at all** when the word derived from it (`[sp+0x2C]`) is nonzero — `ldr w8,[sp,#0x2c] ; cbz w8, <skip>` immediately before the call at `0x1BC6ACCE8`. Passing `RespectUppTrustAndAuthorization = kCFBooleanFalse` therefore skips the call, and `0xE8008026` cannot be produced on this path. Inside the callee the same flag arrives twice — `w4` gates the trust/authorization tests that re-seed `0xE8008026`, `w3` (`respectUpp && !predicate`) gates the second test whose failure yields `0xE8008025` — and `w2` is `HonorBlocklist`, forwarded to `appApprovalState`, whose states map to `0xE8008024` (2), `0xE800801D` (4) and `0xE8008001` (unknown). One route already exists in stock code: at `0x1BC6ABEE4` libmis asks MobileGestalt `IsVirtualDevice` and, when that is true **and** a second answer compares equal to `CFSTR("Internal")`, forces `RespectUppTrustAndAuthorization = 0` and `OnlineAuthorization = 0` outright — worth probing before any hook is written. **A hook must steer the call, not the return:** on the `0xE8008026` path the function logs `validation failed because of missing trust and/or authorization (0x%x)` and branches straight to the shared cleanup at `0x1BC6ABB48`, which releases and returns the status **without ever writing the `info` out-parameter** — the dictionary carrying `CdHash`, `Entitlements`, `SignerType`, `TeamID`, `SigningID`, `ProfileUUID` and the rest is built only on the success path at `0x1BC6ACF74`. Rewriting the return code to 0 would hand the caller success with an untouched `info`. **That hook now exists and ships** — `libmisfix.dylib` (`VPhoneGuestComponents/MISFix/MISFixSignature.c`) passes `RespectUppTrustAndAuthorization = kCFBooleanFalse` alongside `AllowAdHocSigning`, and `cfw install` injects it into `installd` and `misagent` — which is why this patch left `standard`. See `DyldSharedCacheMISTrustAuthPatcher` and the `cfw patch-mis-trust-auth` verb. |    Y    |  Y  |  Y  |
| 18  | **Superseded 2026-09-30 — no load command any more; the spawn hooks insert libmisfix, see "One route for libmisfix, SpringBoard included".** `LC_LOAD_WEAK_DYLIB /usr/lib/libmisfix.dylib` injected into `installd`, which interposes `MISValidateSignatureAndCopyInfo` and `MISValidateSignatureAndCopyInfoWithProgress` — **all bases** | `/usr/libexec/installd` (+ new guest dylib `libmisfix.dylib`) | **Xcode-install fix: let the guest install an app it did not get from Apple.** `xcrun devicectl device install app` with a bundle that is ad-hoc signed, fake-signed or signed by anything other than an Apple leaf fails at `0xE8008014`. Measured, not inferred: a probe app linked against `libmis` on `05-mis-test` (`iPhone99,11 26.6.2 (23G90)` + cloudOS 26.4) walked the option matrix over a real `.app` and found that **the whole gate is this one call** — no options → `0xE8008014`; `AllowAdHocSigning = kCFBooleanTrue` → **`0x0` with a complete `info` dictionary** (`CdHash`, `SignerType`, `SigningID`, `TeamID`, `SignatureVersion`, `IsNativeForPlatform`), so the hook has to synthesise nothing and the `info`-out-parameter hazard that rules out rewriting row 17's return value does not arise here; and stripping the signature off entirely is *not* a way through — that stays `0xE800801C` even with the option. Everything behind the call already accepts uncertificated code on a CFW guest (kernel AMFI, `lsd`, SpringBoard), so nothing else needs patching. Two findings cost real time and are recorded so nobody repeats them: **the first argument is a path `CFStringRef`, not a `CFURLRef`** — passing a URL crashes the caller with `-[NSURL length]: unrecognized selector`; and **the option keys are plain `CFString`s, not exported symbols** — `kMISValidationOptionAllowAdHocSigning` is absent from the cache's export trie, so grepping for the symbol says "this option does not exist on 26.6.2", which is wrong. The keys `libmis` parses are `UnauthoritativeLaunch`, `AuthoritativeLaunch`, `ExpectedHash`, `AllowAdHocSigning`, `ValidateSignatureOnly`, `LogResourceErrors`, `UniversalFileOffset`, `UseSoftwareSigningCert`, `OnlineAuthorization`, `OnlineCheckType`, `RespectUppTrustAndAuthorization`, `HonorBlocklist`, `DetachedSignature`, `TrustCacheOnly`, `SkipProfileIdentifierPolicy`, `AllowLaunchWarnings`, `GetLocalLaunchWarningData`, `MainExecutablePath` and `OnlineAuthorizationOnAllMatchingProfiles`. Fix: `vpWidenedOptions` copies the caller's dictionary (or creates one when it is NULL), sets `AllowAdHocSigning = true` and `RespectUppTrustAndAuthorization = false`, and forwards. The second key is row 17's behaviour expressed from the caller's side — same outcome, **no cache page written and no re-attestation**, which is the whole point given that row 17 is what bricks a 27.0 boot (issue #532). Delivery is `dyld` interposition: `__DATA,__interpose` lands in `__AUTH_CONST` on arm64e (signed pointers) and dyld honours it anyway, including for the shared cache's own uses of the interposed symbol — measured on `05-mis-test`, a linked call with no options returns `0x0` hooked against `0xE8008014` unhooked. The dylib is built by `VPhoneGuestComponents/Makefile` against `libmis.tbd` and `libMobileGestalt`, with `-Wl,-not_for_dyld_shared_cache`, and installed as `/usr/lib/libmisfix.dylib`; injection goes through the existing `patchMachO(… injectedDylibPath:)` path, which captures entitlements before the edit and re-signs with `VPhoneSigner` afterwards — verified to preserve `com.apple.installd` and all 31 of installd's entitlements. **Not applied to SpringBoard**, which would close the free-personal-team *launch* gate the same way: SpringBoard's Mach-O has no free header space (`load-command padding at 0x548 is not empty; inserting would overwrite 56 bytes of the first section`), so that path needs the `SystemHook` `posix_spawn` route instead and row 17 remains the only fix for it today. Declared `system-installd-cfw-adhoc_signature` in `com.vphone.patchset.guest.system`; no `applicability`, not `bootEssential`, on in `standard`. **Partially validated (2026-09-30, `06-xcode-27`, `17,3 27.0 (24A435)` + cloudOS 26.4 (23E5207q)):** `cfw install` reports `[+] LC_LOAD_WEAK_DYLIB /usr/lib/libmisfix.dylib -> installd`, the guest boots through Setup Assistant to the home screen, and `installd` is running with the dylib loaded — so the injection breaks neither the daemon nor the boot. The end-to-end install has **not** been demonstrated on that guest: `devicectl` will not complete a session against it on this host (`device info details` hangs with nothing reaching `lockdownd`), which is a host-side CoreDevice problem unrelated to this patch. See `VPhoneGuestComponents/MISFix/MISFixSignature.c` and `Research/Guest/xcode_install_signature_gate.md`. |    Y    |  Y  |  Y  |
| 19  | **Superseded 2026-09-30, as row 18.** The same `libmisfix.dylib` injected into `misagent`, where it interposes `MGCopyAnswer` / `MGCopyAnswerWithError` and answers `UniqueDeviceID` from a config file — **all bases** | `/usr/libexec/misagent` (+ `/usr/lib/libmisfix.plist`) | **Let a provisioning profile written for a device you already own install on the guest.** `0xE8008012` (`misagent: attempt to install invalid profile`) is the ordinary refusal when the profile's `ProvisionedDevices` does not list this device — correct behaviour, and distinct from row 17's `0xE8008026`. It blocks the case the user actually wants: reusing a paid team's already-registered device rather than burning a registration slot on every VM. The UDID being compared comes from `MGCopyAnswer(kMGUniqueDeviceID)`, and three cheaper routes were ruled out by measurement before any hook was written. (1) **AMFI cannot supply it**: `security.codesigning.config` is a 4-byte flags word (read back as `0x000000CC`), not a string, so `amfi_emulate_device_udid` is dead on this board. (2) **No daemon can write it**: `/private/var/root/Library/Lockdown/data_ark.plist` carries no `UniqueDeviceID` — lockdown derives it each boot. (3) **The real source is out of reach**: TXM composes `UniqueDeviceID` from the device tree's `/chosen/chip-id`, `/chosen/unique-chip-id` and `/product/udid-version` *before the kernel runs*, and `chip-id` is fixed at `0x0000FE01` while `unique-chip-id` is the ECID the SHSH blob is bound to — changing it means the VM no longer restores. So `MGCopyAnswer` is necessarily where this is done. Fix: interpose it in `misagent` only, return a `+1` copy (matching `MGCopyAnswer`'s contract) of the configured string for `UniqueDeviceID`, and fall through untouched for every other property. Configuration is `/var/db/vphone/misfix.plist`, falling back to `/usr/lib/libmisfix.plist`, cached against mtime and size so editing the file takes effect on the next query with no restart — that is the "put it in the plist and it applies" entry point. The shipped plist is **empty**: with no `UniqueDeviceID` key the interpose returns NULL and the patch is inert, so it changes nothing until someone deliberately pastes a real device's UDID in. `installMISFixDefaults` writes the fallback plist **only when it is absent**, so re-running `cfw install` never clobbers a configured value. **Accepted inconsistency, agreed with the user rather than hidden:** only `misagent`'s profile matching sees the borrowed UDID. Xcode, lockdown and `devicectl` keep reporting the VM's own (`0000FE01-…`), because those come from a different process that is not hooked. The two therefore disagree, which is exactly what makes the profile match while the device stays identifiable as itself. Declared `system-misagent-cfw-device_identity` in `com.vphone.patchset.guest.system`; no `applicability`, not `bootEssential`, on in `standard` but inert without a configured UDID. **Partially validated (2026-09-30, `06-xcode-27`):** `cfw install` reports `[+] LC_LOAD_WEAK_DYLIB /usr/lib/libmisfix.dylib -> misagent` and `misagent` runs normally on the booted guest. Installing a real paid-team IPA against a borrowed UDID is **not** yet demonstrated, for the same host-side `devicectl` reason as row 18. See `VPhoneGuestComponents/MISFix/MISFixDeviceIdentity.c`, `MISFixConfig.c` and `Research/Guest/xcode_install_signature_gate.md`. |    Y    |  Y  |  Y  |
| 20  | No binary change: the launchd hook inserts `libmisfix.dylib` into `SpringBoard` at spawn, beside SystemHook, and both spawn hooks do the same for `installd`, `misagent`, `lockdownd` and `remoted` (the last two for the UDID override only) — **all bases** | none (the guest environment's `launchdhook-vphone.dylib` and `SystemHook-vphone.dylib`) | **Let an installed developer-signed app launch.** SpringBoard validates the app with MIS again before launch and, on a hacktivated guest, fails row 17's `checkTrustAndAuthorization` with `0xE8008026` ("Unable to Verify App"). The hook's `MISValidateSignatureAndCopyInfoWithProgress` detour passes `RespectUppTrustAndAuthorization = false`, so the check is never called — row 17's effect with no shared-cache write, which is what makes it usable on 27.0. launchd starts SpringBoard itself rather than through xpcproxy, so the libraries it gets are the launchd hook's choice; that hook now asks the same `vpIsMISFixTarget` SystemHook does. `MISFixInstallPolicy` stays out of it. No declaration of its own: it ships with `system-launchdaemons-boot-environment`. A load-command version (`/mf` alias, `LC_SOURCE_VERSION` dropped) was committed and reverted the same day. See "One route for libmisfix, SpringBoard included (2026-09-30)" below. |    Y    |  Y  |  Y  |
| 21  | No binary change: SystemHook `dlopen`s `libhapticsfix.dylib` into `SpringBoard` at startup, where it replaces every `CHHapticEngine` initialiser's IMP so the initialiser returns nil — **all bases** | none (new guest dylib `VPhoneGuestComponents/HapticsFix/libhapticsfix.c`, installed at `/usr/lib/libhapticsfix.dylib`) | **Stop SpringBoard dying the first time UIKit plays a haptic.** The VM has no haptic device — Virtualization.framework exposes none on any base — and a real device without one gets nil from `CHHapticEngine`'s initialisers, so UIKit runs with no feedback, as on every non-Pro iPad. A guest reporting an iPad Pro model instead has an OS that *expects* the haptic stack, and CoreHaptics treats its absence as an internal error: measured on `iPad16,1 26.6.2 (23G90)`, 4h14m after launch, the first feedback event ran `-[_UIFeedbackCoreHapticsIgnoreCaptureHapticsOnlyEngine _internal_createCoreHapticsEngine]` → `-[CHHapticEngine initWithAudioSession:sessionIsShared:options:error:]` → `createHapticPlayerWithOptions:` → `Haptic_RaiseException` → `objc_exception_throw`, and the unwind resumed at an address inside a `---/---` Memory Tag 255 COW region next to the commpage — `EXC_BAD_ACCESS (SIGBUS)`, `KERN_PROTECTION_FAILURE`, a dead SpringBoard. The hook restores the no-hardware answer before UIKit can reach an initialiser: the constructor `dlopen`s CoreHaptics (it is not loaded that early, and the class must be in the runtime before UIKit asks), then `method_setImplementation` on every selector that is `init` or `init` + uppercase part — covering `initWithAudioSession:sessionIsShared:options:error:` today and any renamed sibling on other bases — with one IMP that ignores its arguments and returns nil, the framework's own answer on haptic-less hardware. Scope is SpringBoard only (`vpIsSpringBoard` in SystemHook, loaded before the app/bootstrap gate that would otherwise return first): it is the one UIKit process measured creating the haptics-only engine without asking CoreHaptics first, and apps that follow the documented `capabilitiesForHardware` path already answer no on the guest. Loaded like the camera hooks rather than inserted like libmisfix because interposing must be in place at launch while a method swizzle just has to run before first use; `DISABLE_TWEAKS` and safe mode skip it with everything else SystemHook loads. Ships with `system-launchdaemons-boot-environment`; existing guests receive it through the vphoned environment update (a missing file reports no hash, which is what triggers the push) and need a respring, which is deliberately the caller's call. See `VPhoneGuestComponents/HapticsFix/libhapticsfix.c`. |    Y    |  Y  |  Y  |
| 22  | No binary change: `libvcamcaptured.dylib` (already loaded into `cameracaptured` by SystemHook) wraps `+[FigCaptureSourceBackingsProvider sharedCaptureSourceBackingsProvider]` from its constructor; when the original returns nil it returns a microphone-only provider instead — **iOS 26.6+ layout, measured on iOS 27.0** | none (`VPhoneGuestComponents/VCamCaptured/Microphone/VCamMicrophoneSource.m`) | **Give an audio-only `AVCaptureSession` its microphone on a guest with no camera.** The built-in sources come from one provider that CMCapture builds only after `BWFigCaptureDeviceVendor` creates the `Default` camera device; a VM has no ISP plugin, so `Cannot create device without create function!`, -12786, `Wiping com.apple.cameracapture.volatile`, and no provider — the microphone, described by the same `AVCaptureSession.plist` call, is lost with the camera, and iOS 27 Voice Memos fails with `CaptureSessionRecorderError` 1 (`failedToCreateAudioDevice`). The wrapper feeds the exported `FigCaptureCreateSourceInfoArrayFromDeviceAndModelSpecificPlist` a NULL device and the shipped product plist (the guest's own `VPHONE600` has none; `D47` on the iPhone17,3 image) reduced to its `"soun"` entries, without persisting, and builds the provider with `-initWithSourceInfoDictionaries:commonSettings:`. A provider the daemon built itself passes through untouched. While that provider is in use, the same dylib also makes `-[AudioRemixSessionManager startNewSessionBlocking]` report success (0) without building the SoundAnalysis Audio Mix session, whose neural net faults cameracaptured 2 s into every spatial recording on the guest (`BNNSGraphContextMakeStreaming`, `KERN_INVALID_ADDRESS 0x300`). Success, not an error: `BWAudioRemixAnalysisMetadataNode` forwards a Stop marker on its metadata output only when the next session starts, and an error there left the movie-file sink waiting forever (measured with the first version, which returned -16992). With no session the node passes audio through and the Audio Mix metadata track is written without samples. It also logs the level of the audio passing the node. `VCamCaptured/Microphone/VCamMicrophoneRemix.m`. See `Research/Guest/ios27_capture_microphone_source.md`. |    Y    |  Y  |  Y  |
| 23  | No binary change: `libvcamcaptured.dylib`, which SystemHook already loads into `cameracaptured`, rewrites the `bl PrewarmThreadSafeSBPs` in `__FigCapturePreloadShadersInternal_block_invoke_2` to `nop` in the daemon's own memory. This runs from the dylib's constructor and only when the paravirtual Metal driver is installed — **all bases** | none (guest dylib `VPhoneGuestComponents/VCamCaptured/Prewarm/`, installed at `/usr/lib/libvcamcaptured.dylib`) | **Stop `cameracaptured` crashing at every boot, and the SpringBoard freeze that follows.** At launch the daemon preloads its shaders. `PrewarmThreadSafeSBPs` runs each video processor's `-prewarm`, and NRFV3's reaches `-[ToneMappingCurves initWithWithContext:]`, which fills textures made from a shared `MTLHeap` with `-replaceRegion:…`. The cloudOS 26.4 `AppleParavirtGPUMetalIOGPUFamily` never sets `_dimension` (a texture's CPU layout) in `-initWithHeap:resource:offset:length:descriptor:`, and `-replaceRegion:` loads it unchecked, so the daemon faults with `KERN_INVALID_ADDRESS` at `0xc` (measured on `iPad16,1 26.6.2 (23G90)`, `standard`: launchd at `successive crashes = 6`). While the daemon crash-loops, SpringBoard's main thread blocked in a synchronous XPC to it as soon as an app started recording. The daemon does have a Metal device, so `kernel-exp-paravirt_user_clients` does not help. Prewarming is only an optimisation, and nothing waits on that function: no return value, no global, no signal. The rest of the preload (processor flags, data migration, and the deferred shader cache copy, whose semaphore deferred processing waits on) is kept. The call site is found from the exported `FigCapturePreloadShaders`: its `b` to the internal function, that function's one `adrp/add/pacia x16` block invoke, then the block's one `ldr x0, [xN, #0x20]; bl` into CMCapture's `__text`. That gives `0x1aeb2fd68` on 23G90 and `0x1b0759d10` on 24A435. Any mismatch leaves the prewarm in place and logs the step that failed. Host test: `make -C VPhoneGuestComponents test-vcam-prewarm`. Validation: `vcamcaptured.log` has `gpu prewarm: … skipped`, no new `cameracaptured` crash report, and `successive crashes = 0`. See `Research/Guest/gpu_acceleration.md` ("Heap Textures Have No CPU Layout"). |    Y    |  Y  |  Y  |
| 24  | No binary change: both spawn hooks insert `libbatteryhealthfix.dylib` into `Settings` (`/Applications/Preferences.app/Preferences`) beside SystemHook, where it interposes `IOPSCopyPowerSourcesInfo`, `IOPSCopyPowerSourcesByType`, `IOPSCopyPowerSourcesByTypePrecise`, `notify_register_check` / `notify_get_state` / `notify_cancel` and `MGGetBoolAnswer` — **all bases** | none (new guest dylib `VPhoneGuestComponents/BatteryHealthFix/libbatteryhealthfix.c`, installed at `/usr/lib/libbatteryhealthfix.dylib`) | **Stop Settings → Battery → Battery Health & Charging loading forever.** The VM's battery is Virtualization.framework's synthetic power source (charge and connectivity only), and the health half of a real battery's description comes from AppleSmartBattery, which no VM has. Measured on `iPhone17,3 27.0 (24A435)`: powerd's internal battery description has one `BatteryPacks` entry holding only `PackID`, `Cycle count` and `Transport Type`, no `Battery Service State`/`Flags` or `Maximum Capacity Percent` anywhere, and `com.apple.thermalmonitor.ageAwareMitigationState` stays 0. `-[BatteryHealthUIController specifiers]` asks `-[BatteryHealthUIInformation batteryDataUnavailable]`, which answers YES while `+getManagementState` is 0, while no pack parses (`-[BatteryHealthUIPackInformation initWithPowerSourceInformation:]` drops a pack without service flags and state), or while the overall genuine status is -1 — and it is -1 because `MGGetBoolAnswer("D6/BMDrlb8V3WSiqL8gL+w")` (HasBatteryModuleAuth, `+[PLGestaltUtilities hasBatteryModuleAuth]`) answers 1 on the guest, sending `+genuineBatteryStatusForPackIndex:` to an `AppleBatteryAuth`/`AppleAuthCPRelay` service that does not exist. The controller then shows its global spinner and re-asks on a timer. iPadOS 26.6.2 (23G90) has the same gate in `+[BatteryUIResourceClass batteryDataUnavailable]`, reading the flat keys of `IOPSCopyPowerSourcesByType`'s array, the same notify name and the same MobileGestalt key. The hook answers as a new battery without battery authentication: each internal-battery description is copied with `Battery Service State` 0, `Battery Service Flags` 0, `Maximum Capacity Percent` 100 and `Cycle count` 0 at the top level, and each of powerd's packs (or one new pack) completed with a `BatteryHealth` dictionary of the same three numbers plus `Date of manufacture`/`Date of first use` (the birth time of `/private/var/mobile`, i.e. the restore); keys already present are never replaced, and a description that already has them is passed through. A mitigation state of 0 on a token registered for the age-aware name reads as 2 ("supporting normal peak performance"). HasBatteryModuleAuth reads as no only while `IOServiceGetMatchingService("AppleBatteryAuth")` finds nothing. Interposing reaches the callers because `BatteryUsageUI.bundle` is a standalone Mach-O bound through dyld's interposing table (cache-to-cache calls are not; see `MISFix/MISFixSignature.c`), and inserting it — rather than SystemHook `dlopen`ing it like row 21 — is what puts the table in place before the bundle loads. `vpInsertedLibraryFor` in `Shared/InjectionEnvironment.h` picks it or libmisfix for a path; the two target sets do not overlap. Ships with `system-launchdaemons-boot-environment`; existing guests get it from the vphoned environment update on their next start with the new bundle (offline `cfw update-environment` only replaces libraries a VM already has). launchd starts Settings itself, so it is the launchd hook that inserts it: a guest updated only by that online sync needs one more reboot before launchd runs the new hook, which the update already reports as `reboot_required`; an offline environment update replaces the hook before boot. **Validated (2026-10-04, `bhtest-iphone`, `iPhone17,3 27.0 (24A435)` + cloudOS 26.4):** before, the page showed only the spinner and the two charging switches; after, Maximum Capacity 100%, Peak Performance Capability "Your battery is currently supporting normal peak performance", the two switches, no spinner; the hook's log shows all three answers taken once per process. Re-checked on the final bundle after a reboot of the same guest, with the launchd hook logging `inserted+batteryhealthfix` for each Settings launch. **iPad16,1 26.6.2 (23G90), `bhtest-ipad`, created with the new bundle:** the hook is inserted and stays inert, and Settings runs without a crash; that iPad has no Battery Health page at all, because `-[BatteryUIController setUpBatteryHealthGroup]` offers the row only on an iPhone or, through `+[PLBatteryUIBackendModel shouldShowModifiedHealthController]`, on an iPad that supports the fixed charge limit with the `PerfPowerServices/battery_health_details` feature on — the model decides, as on hardware. The 26.x gate inside the page is from static analysis; no 26.x iPhone image was at hand to run it. |    Y    |  Y  |  Y  |
| 25  | No binary change: `libvcamcaptured.dylib` stops every other thread in `cameracaptured` (`task_threads` + `thread_suspend`, self excluded, one patcher at a time) around each `vcc_patch_word` / `vcc_patch_two_nops` text rewrite — **all bases** | none (guest dylib `VPhoneGuestComponents/VCamCaptured/Image/VCamCodePatch.m`, installed at `/usr/lib/libvcamcaptured.dylib`) | **Stop the hook's own runtime patching from crashing `cameracaptured`, which froze the whole VM when the camera was opened.** The hook rewrites CMCapture shared-cache `__text` through `vm_protect(RW|COPY)` → write → `vm_protect(RX)`; for the whole flip the 16K page carries no execute permission, and the pages it touches (the `-12783` error-code sites, the master-clock gate, the prewarm call) are live XPC server code. Two crash reports caught a thread fetching an instruction in a page mid-flip while the patching thread was in `vcc_patch_word` on the same boot: `ipad-mini-01` `cameracaptured-2026-10-03-045638.ips` died in `__FigFlashlightGetClassID_block_invoke` on `com.apple.coremedia.flashlight(34)-messages`, and `ipad-pro-13` `cameracaptured-2026-10-04-225558.ips` died in `captureSourceServer_handleRegisterNotificationForProprietaryDefaultChangesMessage` on `com.apple.coremedia.capturesource(523)-messages` — the register-for-source-changes XPC that camera enumeration itself sends. Both are `EXC_BAD_ACCESS (SIGBUS)`, `KERN_PROTECTION_FAILURE` on an instruction fetch, in a region snapshotted `r-x/rwx`, `SM=COW` (the rwx max-protection is the flip's fingerprint). The card: with row 23 removing the boot crash, any later `cameracaptured` restart (jetsam, another crash) while a camera client reconnects sends its first XPCs straight into the +3 s reinstall window; one SIGBUS → launchd throttles → every AVCapture client, SpringBoard's main thread included, blocks forever in a synchronous XPC — the "VM 卡死" report of 2026-10-05. The stopped section is exactly two `vm_protect` calls, the word write and `sys_icache_invalidate`: no locks, no allocation, no logging, so a frozen thread holding any userspace lock cannot deadlock the patcher; every `vcc_log` moved after the resume, and a mutex serialises patchers (constructor prewarm patch vs the +3 s install block). All five runtime text-patching call sites (`vcc_scan_and_patch` ×2, the prewarm NOP, the session-hook pair, the source-installation NOPs) funnel through the two fixed functions. Validation: kill-and-relaunch stress with Camera.app auto-reconnecting (the same collision that produced both crashes) produces no new `cameracaptured` crash report, and the boot log's `patch_word OK` lines are unchanged. See `Research/Guest/virtual_camera_transport.md` ("The patch race that froze the whole VM"). |    Y    |  Y  |  Y  |
| 26  | No binary change: both spawn hooks insert `libdevicehubfix.dylib` into `cryptexd`, the DDI's `dtremotedisplayd` and `dtdeviceinfod`, and `avconferenced`. In `cryptexd` it interposes `fcntl` and reports an `EPERM` from `F_SETPROTECTIONCLASS` as `ENOTSUP`; in `dtremotedisplayd` it interposes `MediaStreamSupportedFeatures.current` (answers `0x8c`) and `CurrentDevice.isCustomerRestricted` (answers false) from the DDI's `CoreDeviceUtilities`; in `dtdeviceinfod` it interposes `MGCopyAnswer` and fills a missing `FramebufferIdentifier` for `phone11` chrome; in `avconferenced` it replaces `VCPSideCarMetal`'s two band reads through the Objective-C runtime and runs one synchronous scaler transform before the first read of each frame — **all bases** | none (new guest dylib `VPhoneGuestComponents/DeviceHubFix/libdevicehubfix.c`, installed at `/usr/lib/libdevicehubfix.dylib`) | **Let Xcode 27's DeviceHub show the guest's screen.** On iOS 27 `cryptexd` stages each DDI asset with `open(O_RDWR)` + `fcntl(F_SETPROTECTIONCLASS, 4)` and accepts only `ENOTSUP` as a failure; a guest answers `EPERM` (`set protection class: [1: Operation not permitted]`, `staging failed`), so CoreDevice shows the device as "connected (no DDI)" for good. With the DDI mounted, DeviceHub asks `dtremotedisplayd` for its media stream features and gets 0 from CoreDeviceUtilities' policy: `isCustomerRestricted` (`isProductionFused && !hasInternalOSBuild && hasInternalDDI == false`) refuses every pre-27.0 device, and remote control is limited to iPhone, Apple Watch and Apple TV, which refuses every iPad. `0x8c` is what a Mac host reports for itself (mirrored primary display 0x4, system audio 0x8, display information 0x80). The 27.x iPhone guest reports `phone11` chrome with no `FramebufferIdentifier`, so DeviceHub drew the screen over the bezel corners; the hook answers only that missing key with Xcode's matching mask `4E5532ED-1470-47D1-BDF4-7AA90C26957A` from `/Library/Developer/DeviceKit/chrome_map.plist`. Interposing reaches all of them because `cryptexd`, `dtremotedisplayd`, `dtdeviceinfod` and `CoreDeviceUtilities` are standalone images; the two Swift symbols are weak flat-namespace imports, resolving to nothing outside `dtremotedisplayd`. On 27.x the view also needs row 11's conditional dispatch, or the capture display stays black. A stream that splits each frame into four bands (`tilesPerFrame` 4) deadlocked the host GPU within 16–35 s of screen activity: `VCPSideCarMetal` reads every frame once per band while the paravirtual scaler's write of that frame can still be unregistered on the host, and a band read that registers the first of the frame's two planes before the write and the second after it waits on the write, which waits on it (`Timeout in timestamp wait`, the guest loses its GPU). Waiting for one synchronous transform puts the band reads behind the frame's write. `VideoProcessing` is in the shared cache, so this part is a method replacement, not an interpose. Ships with `system-launchdaemons-boot-environment`; an existing guest gets it from the environment update. Details: `Research/Guest/devicehub_screen_viewing.md`. **Validated (2026-10-06/07):** `iPad16,1 26.6.2 (23G90)`: DeviceHub receives `supportedFeatures: 140`, `MediaStreamStart` succeeds and the view shows the live home screen. `iPhone17,3 27.0.1 (24A446)`: the DDI mounts (`F_SETPROTECTIONCLASS EPERM, reported as ENOTSUP`), and with row 11's conditional dispatch DeviceHub shows the home screen and Settings live, clipped inside the chrome (`Found FramebufferMaskIdentifier from displayInfo`). **Band reads validated (2026-10-07/08, `iPhone17,3 27.0.1 (24A446)`):** a four-band stream with screen activity deadlocked after 18 s without the barrier and ran 60, 180 and 300 s with it without a GPU error; in the host trace of the 180 s run no IOSurface access waited, and every band read of 6258 frames registered after the frame's write was released, a median 0.76 ms after it. Open: latency that grows over a long session and occasional stalls after a cold start, both upstream of the Mac receiver. |    Y    |  Y  |  Y  |
| 27  | No binary change: both spawn hooks insert `libdevicename.dylib` into `configd` and `lockdownd` (after `libmisfix.dylib`, the first process to take two inserted libraries). In `configd` it interposes `SCDynamicStoreSetMultiple` and `SCDynamicStoreSetValue` and pins `Setup:/System`'s `ComputerName`; in `lockdownd` it interposes `SCPreferencesSetComputerName`, `SCPreferencesSetHostName` and `SCPreferencesSetLocalHostName` and refuses every rename with `kSCStatusAccessError`. Inert unless `/var/db/vphone/devicename.plist` holds a valid `DeviceName` — **all bases** | none (new guest dylib `VPhoneGuestComponents/DeviceName/libdevicename.c`, installed at `/usr/lib/libdevicename.dylib`; vphoned `device.name.get`/`device.name.set`) | **Pin the guest's device name to the VM's name.** The name is `System/System/ComputerName` in `preferences.plist`; configd's PreferencesMonitor (`updateConfiguration`, 24A435 `0x100062098`) flattens it into `Setup:/System` with one `SCDynamicStoreSetMultiple`, and every reader (`SCDynamicStoreCopyComputerName` in lockdownd's `copy_device_name`, MobileGestalt `UserAssignedDeviceName`, `UIDevice.name`) reads the store. The hook rewrites that publication, not the preferences read: the monitor's model-change path (`sub_10006155c`) writes the `kSCPrefSystem` value it reads back to disk, and the publication route leaves `preferences.plist` with the guest's own name. A publication that leaves `Setup:/System` out as unchanged gets the store's value pinned; one that removes it gets the pinned name instead. `vphone-vm` sends the VM's name to vphoned's `device.name.set` after every connect; vphoned writes the file (one rename, 0644) and applies the preferences unchanged, so configd publishes again and the new pin, or the guest's own name when the file is removed, is live within a second. The file outlives a reboot, so configd's first publication at boot carries it. The library re-reads the file when its inode, size or mtime change. lockdownd's `set_device_name` (`0x1000073b0`) is the only caller of the three setters; it logs their failure and still commits, and the `SetValue DeviceName` handler ignores the result, so a host rename reports success and the name stays. The pinned name itself is refused too: lockdownd runs `set_device_name(copy_device_name())` whenever it starts, and a lockdownd restarted after configd published would otherwise write the pinned name and derived host names into `preferences.plist` (seen once). An NVRAM variable was the first channel and never reached the guest: iBoot keeps only the variables it knows (even `vphone-vm`'s `boot-args` write is replaced). Interposing works because both daemons are standalone images. Ships with `system-launchdaemons-boot-environment` and the environment update; takes effect at the next boot. Verified on iOS 27.0 (24A435) on 2026-10-07: pin at boot and live, host rename refused, `vm rename` followed, preferences untouched. CoreDevice (`devicectl`, DeviceHub) reads the name when the device appears and can lag one boot after a rename. Details: `Research/Guest/device_name_pinning.md`. |    Y    |  Y  |  Y  |
| 28  | `cbz`/`cbnz` -> `b` at the four compact-command choices in `-[PGSerializerRenderCommandEncoder drawIndexedPrimitives:…]` (`0x140b0`, `0x1421c`, `0x143b4`, `0x143c4` in 23E5207q) — **cloudOS 26.4** | `AppleParavirtGPUMetalIOGPUFamily` (`/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle`) | **Heap index buffer fix.** The compact command stores `parentResourceOffset + indexBufferOffset` in 16 bits but is chosen by testing `indexBufferOffset` alone, so an index buffer 64 KiB or more into an `MTLHeap` is read from the wrong address and meshes (Unity games) draw with another mesh's indices. Every indexed draw takes the 64-bit command instead. `system-paravirt_gpu-cfw-heap_index_offset`; see "Heap index buffers reach the host whole (2026-10-14)" and `Research/Guest/gpu_acceleration.md` |    Y    |  Y  |  Y  |
| 29  | No binary change: SystemHook calls `setenv("FS_CACHE_REUSE_ON_REBOOT", "1", 0)` first thing in its constructor, in every process it is inserted into, while `/usr/lib/vphone-metal-cache-reuse` exists — **all bases** | none (`VPhoneGuestComponents/SystemHook/SystemHook-vphone.c`; marker written by `cfw install` / `cfw update-environment`) | **Keep the guest's Metal shader caches across a reboot.** `libCoreFSCache` stamps each cache with `kern.bootsessionuuid` and resets it at the next boot unless the variable is set; on the paravirtual GPU CoreAnimation's precompiled pipelines are disabled, so backboardd rebuilt every pipeline after every boot. `system-systemhook-cfw-metal_cache_reuse`; see "Guest Metal caches survive a reboot (2026-10-19)" |    Y    |  Y  |  Y  |


### Swift port status — the eight DSC patchers (2026-09-23)

The rows above describe the patches, which have not changed. What is new is that
each now has an in-process Swift implementation on the validated DSC foundation
(`DSCChunkSet`, `DSCCodeSignature`, `DSCLocalSymbolTable`, `DSCSymbolResolver`).
Every one was proven on the real 24A435 arm64e cache — `ipsws/ref_extract/dsc_pristine`,
79 chunks + `.symbols` = 80 files, 6.7 GB — by running the Python on one `cp -c`
clone and the Swift on another and comparing all 80 files. Every `cfw.py` call
site is now a `vphone-cli cfw` verb — see "the CFW verbs" below.

| Python | Swift | Sites | Parity on the real cache |
| --- | --- | --- | --- |
| `cfw_patch_dsc_maxslide.py` | `DSCMaxSlidePatcher` | 1 (header `@0xF0`) | 80/80 identical. vs pristine exactly 1 byte differs (`0xF3`, `0x20`→`0x00`). Logs character-identical. No re-attestation on either side (header, not a code page) — confirmed by hashing the CD blob. |
| `cfw_patch_lockdown_mode.py` | `DSCLockdownModePatcher` | 1 + 1 slot | Same gate `b.eq @0x237EF2298` (`20010054`→`1f2003d5`), same slot 7868 of `.40`, same hash. `diff -rq` clean over 80 files; second pass a no-op both sides. |
| `cfw_patch_lsd_embedded_reg.py` | `DSCLSDEmbeddedRegPatcher` | 1 + 1 slot | Same gate `cbz w0 @0x186EEA024`, same slot 6842 of `.01`. 0 differing files. Cross-run both ways: each re-run over the other's output is a no-op. |
| `cfw_patch_xpc_lwcr.py` | `DSCXPCLWCRPatcher` | 3 + 1 slot | Same three addresses `0x1805DD644/8/C`, same slot 119 of `.01`. `diff -rq` clean. |
| `cfw_patch_camera_dsc.py` | `DSCCameraPatcher` | 6 + 5 slots | Both families. 0 differing files; exactly 2 chunks differ from pristine. |
| `cfw_patch_iomfb_force_kern.py` | `DSCIOMFBForceKernPatcher` | 31 retargeted | Trampoline shape verified by Capstone, branch bytes from Keystone. |
| `cfw_patch_iomfb_swapend.py` | `DSCIOMFBSwapEndPatcher` | 1 | Size **discovered, never matched**; anchored on the method-5 call set-up. |
| `cfw_patch_hv_vmm_dsc.py` **+** `cfw_patch_hv_vmm.py` | `DSCHVVMMPatcher` | blacklist-flip mangle | Both halves in one type. The migration plan called `cfw_patch_hv_vmm.py` dead code; **it is not** — the DSC module live-imports `NEEDLE` / `MANGLED_NEEDLE` / `MANGLE_OFFSET` / `ORIGINAL_BYTE` / `MANGLED_BYTE` from it. |

Each port was checked by a second agent that rebuilt the evidence rather than
reading it: own drivers linked against the module, whole-cache byte comparison,
and for `lsdreg` a differential sweep of both gate-finders over 33,000 function
addresses (49 gates each, zero verdict differences).

**Two defects that review found and this branch fixed:**

* `DSCCameraPatcher` wrote each site as it classified it and re-attested once at
  the end, so a throw in the second family left the first family's five writes on
  disk with stale signature slots — half-patched *and* SIGKILL-on-page-in under
  `codeSigningMonitor == 2`. `apply` now plans every family before writing any of
  them, so a failure writes nothing. Pinned by
  `DSCCameraPatcherTests.failureWritesNothing`, which fails and names
  `dyld_shared_cache_arm64e.15` if the old shape is restored.
* `DSCLockdownModePatcher.disassembleBlock` did not stop at an undecodable word.
  `ARM64Disassembler` sets `cs.skipData = true` and the reference's `_cs`
  (`cfw_asm.py:14`) does not, so where the Python's stream ends this one walked
  past the data to its 60-instruction ceiling. On a userland with an inline
  literal before the gate that inverts the failure mode: the Python stops the
  install loudly, this would decode into unrelated code and could NOP a branch
  there *and re-attest that page*. It now breaks on `insn.id == 0`, as
  `DSCLSDEmbeddedRegPatcher.disassembleFunction` already did.

**Known, not fixed** (all LOW, none changes a byte on this cache):

* `DSCIOMFBSwapEndPatcher` — on the already-correct path it clears recorded
  writes and re-attests nothing, so the returned `DSCReattestation` has empty
  arrays and `isFullyAttested` is **vacuously true**. The Python re-hashes the
  page and compares. Unreachable through today's shell graph; a footgun for the
  Swift driver that is meant to replace it.
* `DSCXPCLWCRPatcher` — a dry run returns `status == .patched, siteCount == 3`
  although nothing was written; `DSCIOMFBSwapEndPatcher` takes the opposite
  convention (`0`). A driver summing these for a preview gets a wrong total.
* `DSCLSDEmbeddedRegPatcher` — record text says `cbz w0, 0x186eea048` where the
  captured Python reference says `cbz w0, #0x186eea048`. libcapstone-spm
  (Capstone 6) omits the `#` the Python patchers' Capstone 5.0.7 emitted. Bytes are
  identical; a field-level diff against `reference_patches/` will flag it.
* `DSCHVVMMPatcher.findStringSites(inMachO:)` skips a string section whose
  declared extent overruns EOF, where the Python truncates and scans what is
  there — a malformed binary reads as a clean no-op. No caller in the repo today.
* `DSCMaxSlidePatcher` — the `sharedRegionSize >= mapped span` corroboration
  couples the patch to `DSCChunkSet`'s file-exclusion policy, so a stray
  cache-shaped file in the chunks directory turns a working patch into a hard
  abort. Fail-closed, and left alone deliberately.

### Swift port status — the six independent Mach-O patchers (2026-09-23)

Rows 1, 2, 3, 5 and 13 above, plus the EXP `watchdogd` patch, now have Swift
implementations under `Sources/FirmwarePatcher/CustomFirmware/ExecutablePatches/`. The patches did not
change. Each was run against its Python on two `cp -c` clones of the real 24A435
binary in `ipsws/ref_extract/macho_pristine/`, both with re-attestation off (what
the Python emits) and on (against `cfw_macho_codesign.reattest_modified_offsets`).

| Python | Swift | Sites | Parity on the real binary |
| --- | --- | --- | --- |
| `cfw_patch_seputil.py` | `CFWSeputil` | 1 (+1 slot) | `%s`→`AA` at `0x1BDD2`; sha256 `75dc86f8…` both sides. Re-attested: slot 27 identical. Anchored on the whole `__cstring` literal plus the `adrp`+`add` that builds it, not the Python's file-wide `find`. |
| `cfw_patch_cache_loader.py` | `CFWCacheLoaderPatcher` | 1 (+1 slot, opt-in) | `cbz x0 @0xC7C` → `nop`; sha256 `17c5b00c…` both sides, 4 bytes differ from pristine. |
| `cfw_patch_mobileactivationd.py` | `CFWMobileactivationd` | 1 (+1 slot) | `-[DeviceType should_hactivate]` at `0x2EC368`; sha256 `9f26bf92…` both sides. Re-attested: slot 748 identical. The Python's symbol match is a substring search that sees four candidates on this image; the Swift matches the exact selector and cross-checks ObjC metadata. |
| `cfw_patch_jetsam.py` | `CFWJetsamPatcher` | 1 | `cbz w0 @0xFA98` → `b` (`launchd`); sha256 `cae806f5…` both sides. |
| `cfw_patch_watchdogd.py` | `CFWWatchdogd` | 2 × 2 insns + 2 slots | Sites at `0x100004754` and `0x10000AB30`, slots 4 and 10; sha256 `963cd445…` both sides, `codesign -v` passes. |
| `cfw_patch_diskimagesiod.py` | `CFWDiskimagesiod` | 1 (+1 slot) | `isMountComplete…` IMP at `0x320C0`, found through the relative method list; sha256 `41daf01d…` both sides. Re-attested: slot 50 identical. |

**Every port is idempotent, and three of the Pythons are not.** A second Python
run over its own output walks past the first patch and changes something else:
`cache_loader` NOPs the `cbnz x0 @0xC84` log-file guard, `jetsam` rewrites the
`b.ne @0xFAB0` in the same return block, and `seputil` exits 1. The shell never
hit this because it always copies from the `.bak` first. The Swift reports
`already patched` and writes nothing, which is what the in-place call site in
`CryptexFilesystemPatcherGuestPayload` needs.

**Wired in.** `CryptexFilesystemPatcherGuestPayload` calls
`CFWCacheLoaderPatcher` and `CFWMobileactivationd` in process. Every shell call
site (`cfw_install*.sh`, `cfw-kit`, `patch_{camera,hv_vmm}_userland.sh`) now runs
`vphone-cli cfw <verb>` — see the next section.

**A defect that review found and this branch fixed:** `CFWCacheLoaderPatcher`
trapped on every patch with logging on, which is the default. The before/after
window starts two instructions ahead of the gate, and it converted that negative
delta with `UInt64(Int)`, which traps even under `-O`. Every test passed
`log: nil`, so none reached it. Now covered by `loggingPathDoesNotTrap`.

**A second defect, found when the CLI verbs landed and fixed here:** a Mach-O
whose load-command table runs past EOF — a 64-byte truncation is enough — made
*all six* patchers die with SIGTRAP (`BinaryBuffer.swift:9` precondition, exit
133), not a catchable error. `MachOParser` walked the table checking only that
each command's 8-byte header fit, then read fields up to `+0x38` inside it.
`MachOParser.forEachLoadCommand` now bounds every command by `cmdsize` and by
the file, and each branch checks its own minimum command size; a truncated file
yields no segments and the patcher throws `invalidFormat` like any other bad
input.

**Known, not fixed** (all LOW, none changes a byte on these binaries):

* `CFWCacheLoaderPatcher.flagSetterOnResult` accepts a flag-setting instruction
  with `x0`/`w0` in any operand, including as the destination.
* `CFWMobileactivationd`'s ObjC cross-check is scoped to the selector, not the
  class: it takes the first relative-method-list entry with that name.
* `CFWJetsamPatcher`'s `.alreadyPatched` is silent. If a later firmware emits an
  unconditional `b` into the return block ahead of the real gate, it would read
  as already patched.
* `CFWWatchdogdTests.swift` converts a VA to a file offset by subtracting the
  arm64 image base as a constant, in a test only.

### The CFW verbs, and the end of `scripts/patchers` (2026-09-23)

The fourteen ports above had no caller outside the two in-process call sites, so
the installers still ran `cfw.py`. They no longer do. Every patch is a
`vphone-cli cfw <verb>` with the Python's exact verb name, positional arguments
and flags, so the shell diff is a prefix swap:

```
-  "$PYTHON3" "$SCRIPT_DIR/patchers/cfw.py" patch-seputil "$bin"
+  "$VPHONE_CLI" cfw patch-seputil "$bin"
```

26 call sites across `cfw_install{,_dev,_jb,_exp,_host}.sh`,
`patch_{camera,hv_vmm}_userland.sh` and `cfw-kit`, whose `cfw_py` seam became
`cfw_cli`. Each verb was proven through the built binary against its Python on
`cp -c` clones of the real 24A435 references: the six Mach-O verbs byte-identical
(`cmp` + matching sha256, both exit 0), the eight DSC verbs `diff -rq` clean over
all 80 cache files on first run, second run and dry run.

**Parity evidence is now frozen, not re-measured.** The CFW test suites used to
spawn `.venv/bin/python3 scripts/patchers/…` and compare live. They now compare
against constants recorded from that same Python at commit `78cbeea`, each with a
provenance comment naming the command and the input digest, and each suite checks
the fixture is the one the goldens were taken over — so a different firmware fails
on that line instead of looking like a patcher bug. Two structural fixes were
needed for the freeze to mean anything: the re-attester parity test was reading a
**build product**, whose bytes change every build, and the device-tree golden is a
digest map keyed by input digest, because that input exists in two cloudOS IPSWs.

The build product in question was `.build/release/vphone-letmein`, picked as the
nearest real ad-hoc-signed thin arm64 Mach-O with a non-page-aligned `codeLimit`.
The tests asserting a frozen digest moved off it first, onto the real 24A435
`seputil`; the rest of `CFWMachOTests` — structural cases that only needed *some*
signed Mach-O — kept pointing at the build product, and that stopped being viable
when `vphone-letmein` was deleted from the tree (see
`Research/Host/host_binary_split.md`). All of `CFWMachOTests` now takes its fixture
the way the sibling CFW parity suites do: `macho_pristine/seputil`, resolved
through `VPHONE_MACHO_PRISTINE` with `ipsws/ref_extract/macho_pristine` as the
default, **failing** rather than skipping when it is absent, since a skipped test
reads like a passing one. `VPHONE_MACHO_FIXTURE_OPTIONAL=1` turns that back into
a skip for a machine that cannot carry the extracted IPSW.

**The lesson generalises past this one binary: a test fixture must never be
something the build produces**, whether or not the assertion is a frozen digest.
It was luck, not design, that the old fixture had the properties these tests
exercise — a non-page-aligned `codeLimit` and zero padding behind the load
commands — and a fixture that is rebuilt is also a fixture that can vanish.

Re-deriving any of these constants means re-extracting the reference Python from
git history — `scripts/patchers/` is gone from the working tree.

**One Python bug the port deliberately does not reproduce.** A write that
straddles a code-signature page boundary — eight bytes at `0x280FFFC..0x2810004`,
which is what `cfw_patch_camera_dsc.py` emits when its six entry points land on
both sides of the 2563/2564 line — re-attested only the page containing the
address. Page 2564 kept its original slot hash (`7ccd65fa…`) while its bytes
hashed to `dfe38096…`, and the guest dies on the first demand-page-in of it.
`DSCCodeSignature.reattestRecordedWrites` covers every dirtied page;
`DSCFoundationTests.pageStraddlingWriteAttestsEveryDirtiedPage` pins both the fix
and the reference's value, so the divergence stays on the record.

**One verb is semantically, not byte, identical.** `cfw inject-daemons` writes a
plist, and the two XML writers disagree on one thing: Python's `plistlib`
serialises an integral double as `<real>1.0</real>` where Foundation emits
`<real>1</real>`. Both parse back to the same value, and matching the Python
byte for byte would mean reimplementing `plistlib`'s writer — which is why the
plan set the bar for plists at semantic equivalence (type, order, key set,
`Data` bytes) rather than bytes. Recorded here so "byte-identical" is not read
as covering the plist verbs.

**Two behavioural differences kept on purpose**, both on the already-patched path
and neither changing a byte:

* `patch-camera-dsc` over an already-patched cache exits 0 where the Python
  raised and exited 1. `cfw_install_exp.sh:126` tests that exit status and its
  failure branch prints "likely build-version mismatch" — a *wrong* diagnosis for
  a re-install. Exit 0 with "chunks patched" is the true one.
* The three idempotence divergences in the section above stand: the Swift
  recognises its own output where the Python double-applies or exits 1.

**Final submodule removed:** `Scripts/Repos/InsertDylib` was retained only for
a byte-parity test after `CustomFirmwareInjectDylib` took over the injection.
That test is replaced with two checked-in Objective-C source fixtures: a
`hello world` executable and a swizzle dylib. The test compiles them, checks the
plain output, injects the dylib with the Swift patcher, re-signs the executable,
and checks that it prints `world hello`. This exercises the actual dyld load
and swizzle without an external test reference or an optional skip.

**P1 dropped `capstone`, `keystone-engine` and `pyimg4` from the dependency
list; P2 then deleted the list.** `requirements.txt`, `scripts/setup_venv.sh`,
`scripts/setup_venv_linux.sh`, the `make setup_venv` target and
`scripts/pymobiledevice3_bridge.py` are all gone — the restore backend was the
last program holding any of them up, and it is `Sources/VPhoneRestore` over
vendored libirecovery and idevicerestore now
(`Research/Restore/native_restore_architecture.md`). No Python is tracked in this repository
and nothing resolves a `python3` at runtime.

### Installed Components

| #   | Component                  | Description                                                                                                        | Regular | Dev | JB  |
| --- | -------------------------- | ------------------------------------------------------------------------------------------------------------------ | :-----: | :-: | :-: |
| 1   | Cryptex SystemOS + AppOS   | Decrypt AEA + mount + copy to device                                                                               |    Y    |  Y  |  Y  |
| 2   | GPU driver                 | AppleParavirtGPUMetalIOGPUFamily bundle, extracted from the selected PCC OS image during `fw prepare`, or supplied from the same cloudOS build with `--gpu-driver-bundle` if Apple's AEA key is unavailable |    Y    |  Y  |  Y  |
| 3   | `iosbinpack64`             | Jailbreak tools (base set)                                                                                         |    Y    |  Y  |  Y  |
| 4   | `iosbinpack64` dev overlay | Replace `rpcserver_ios` with dev build                                                                             |    -    |  Y  |  -  |
| 5   | `vphoned`                  | vsock HID/control daemon (built + signed)                                                                          |    Y    |  Y  |  Y  |
| 6   | LaunchDaemons              | bash/dropbear/trollvnc/rpcserver_ios/vphoned plists                                                                |    Y    |  Y  |  Y  |
| 7   | Procursus bootstrap        | Bootstrap filesystem + optional Sileo deb                                                                          |    -    |  -  |  Y  |
| 8   | BaseBin hooks              | `systemhook.dylib` / `launchdhook.dylib` / `libellekit.dylib` -> `/cores/` plus `/b` alias for `launchdhook.dylib` |    -    |  -  |  Y  |
| 9   | `TweakLoader.dylib`        | Lean user-tweak loader built from source and installed to `/var/jb/usr/lib/TweakLoader.dylib`                      |    -    |  -  |  Y  |

### `kern.hv_vmm_present` user-mode patcher (EXP only)

Companion to the EXP kernel patcher (`KernelEXPPatcher.patchHvVmmRename`).
Mangles byte 5 of every `kern.hv_vmm_present` cstring inside DSC dylibs
EXCEPT those in `DONT_PATCH_INSTALL_NAMES` (sign-in / device-likeness
consumers, ~15 entries). Patched dylibs query the renamed OID and get the
truthful 1 (graphics + accel passthrough); blacklisted dylibs keep the
original cstring, hit ENOENT on the renamed kernel, and defensively cache 0
("not running on a VM") for sign-in / device-attestation surfaces.
Source-of-truth research: `Research/Patches/hv_vmm_present_usermode_xrefs.md`.

JB and other variants are NOT affected by this patcher.

**Patch shape (every site)** — cstring mangle:

```
Before (cstring section bytes, 20 bytes total):
    "kern.hv_vmm_present\0"
    6B 65 72 6E 2E 68 76 5F 76 6D 6D 5F 70 72 65 73 65 6E 74 00

After (1 byte change at offset 5):
    "kern.Xv_vmm_present\0"
    6B 65 72 6E 2E 58 76 5F 76 6D 6D 5F 70 72 65 73 65 6E 74 00
                ^^
```

**Byte 5, not byte 0.** The mangle has to keep the `kern.` top-level
namespace intact or the kernel's name-to-MIB resolver routes the call to
nothing at all. Byte 0 would give `Xern.hv_vmm_present`, and `Xern` is not
a registered top-level sysctl namespace, so it could never resolve — see
the comment at `scripts/patchers/cfw_patch_hv_vmm.py:40-47`.

**Which way the lie runs.** This is the part that reads backwards if you
have the pre-blacklist-flip design in mind. The companion kernel patch
(`KernelEXPPatcher.patchHvVmmRename`) renames the OID itself, so after
both halves are installed:

* a **mangled** dylib asks for `kern.Xv_vmm_present`, which **resolves**
  to the renamed OID and returns the truthful `1` — that is what keeps
  graphics and accel passthrough working;
* a **blacklisted** dylib keeps `kern.hv_vmm_present`, which now hits
  `ENOENT`. Its post-call check (`cbnz w0, skip` or
  `cmp w0,#0 ; b.ne skip`) takes the skip-cache path, the cached "is_vmm"
  byte stays at BSS-zero, and that dylib believes it is not in a VM.

So mangling is what tells a dylib the truth, and *not* mangling is what
makes it lie. The blacklist is therefore the list of consumers that must
be deceived (sign-in, device likeness), not the list of ones to fix.

We don't modify executable code at all — only one byte of read-only
string data. The kernel call still happens, so any sysctl-tracing
infrastructure can still see activity.

Idempotent: the patcher scans for `MANGLED_NEEDLE` first
(`cfw_patch_hv_vmm_dsc.py:133`) and each site re-checks byte 5 before
writing, so a re-run does no work.

**DSC-side patches** — driven by an explicit **blacklist**
(`DONT_PATCH_INSTALL_NAMES` in `scripts/patchers/cfw_patch_hv_vmm_dsc.py`,
~15 entries) applied to chunks under
`SystemOS/System/Library/Caches/com.apple.dyld/`. Every dylib that is not
named there gets mangled. Add a line to the blacklist to stop patching
that dylib on the next install — useful for bisecting which consumer is
responsible for an observable change.

> The table below lists dylibs that ARE mangled, i.e. ones absent from the
> blacklist. It used to be introduced as a `PATCH_INSTALL_NAMES` whitelist;
> that name no longer exists in the module.

| Dylib                                                     | Component role (paraphrased)                                  |
| --------------------------------------------------------- | ------------------------------------------------------------- |
| `usr/lib/libMobileGestalt.dylib`                          | Backs `MGCopyAnswer("hv-vmm-present")` — highest fan-in       |
| `PrivateFrameworks/AAAFoundation.framework/AAAFoundation` | Apple ID anti-abuse plumbing                                  |
| `PrivateFrameworks/AuthKit.framework/AuthKit`             | Sign-in-with-Apple-ID / iCloud auth                           |
| `PrivateFrameworks/IDSFoundation.framework/IDSFoundation` | Apple Identity Service core (iMessage / FaceTime backbone)    |
| `PrivateFrameworks/DeviceIdentity.framework/DeviceIdentity` | Device-binding / device class identity                     |
| `PrivateFrameworks/DeviceCheckInternal.framework/...`     | DeviceCheck attestation                                       |
| `PrivateFrameworks/MobileActivation.framework/...`        | Activation flow                                               |
| `PrivateFrameworks/ApplePushService.framework/...`        | APNS client (claims device characteristics on connect)        |
| `PrivateFrameworks/AppStoreUtilities.framework/...`       | Store / IAP support                                           |
| `PrivateFrameworks/CorePrescription.framework/...`        | Health prescription store sync gate                           |
| `PrivateFrameworks/CoreCDP.framework/CoreCDP`             | CDP (cloud key-vault / iCloud Drive plumbing)                 |
| `PrivateFrameworks/EmailFoundation.framework/...`         | Mail account heuristics                                       |
| `PrivateFrameworks/PhotoFoundation.framework/...`         | Photos asset visibility heuristics                            |
| `PrivateFrameworks/FindMyBase.framework/FindMyBase`       | Find My anti-spoof                                            |
| `PrivateFrameworks/AirPlaySupport.framework/...`          | AirPlay receiver gate                                         |
| `PrivateFrameworks/TrialServer.framework/TrialServer`     | A/B / trial-rollout exclude-VM gate                           |
| `PrivateFrameworks/VisionKitCore.framework/VisionKitCore` | VisionKit                                                     |
| `PrivateFrameworks/DVTInstrumentsUtilities.framework/...` | Xcode Instruments support                                     |
| `PrivateFrameworks/WatchdogServiceManagement.framework/...` | Watchdog manager                                            |
| `Frameworks/CoreVideo.framework/CoreVideo`                | CoreVideo pipeline                                            |

**Standalone-binary patches (6 files, applied to the device rootfs
over SSH)**

| Path                                                                                              | Role                                                          |
| ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `/System/Library/DataClassMigrators/MobileActivationMigrator.migrator/MobileActivationMigrator`   | Activation migration helper                                   |
| `/Applications/CheckerBoard.app/CheckerBoard`                                                     | Apple internal accessibility test app                         |
| `/Applications/StoreKitUISceneService.app/StoreKitUISceneService`                                 | StoreKit UI host                                              |
| `/System/Library/Frameworks/StoreKit.framework/Support/storekitd`                                 | StoreKit / IAP daemon                                         |
| `/System/Library/PrivateFrameworks/AppStoreDaemon.framework/Support/appstored`                    | App Store daemon                                              |
| `/System/Library/PrivateFrameworks/CorePrescription.framework/XPCServices/CorePrescriptionService.xpc/CorePrescriptionService` | CorePrescription XPC service       |

**Explicitly NOT patched (compute / accel — patching here turns off
VM fast-paths that exist so the lib doesn't try to touch real silicon
ANE / AGX / hardware codecs):**

```
System/Library/Frameworks/CoreML.framework/CoreML
System/Library/PrivateFrameworks/Espresso.framework/Espresso
System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine
System/Library/PrivateFrameworks/CoreRE.framework/CoreRE
System/Library/PrivateFrameworks/RenderBox.framework/RenderBox
System/Library/PrivateFrameworks/WebGPU.framework/WebGPU
System/Library/PrivateFrameworks/caulk.framework/caulk
System/Library/PrivateFrameworks/IOSurfaceAccelerator.framework/IOSurfaceAccelerator
System/Library/ExtensionKit/Extensions/HostInferenceProviderService.appex/HostInferenceProviderService
```

**Wiring**

* `scripts/patchers/cfw_patch_hv_vmm.py` — standalone cstring patcher
  (used for the on-device files): finds the `"kern.hv_vmm_present\0"`
  cstring in the Mach-O's __cstring section and rewrites its first
  byte (`'k'` → `'X'`).
* `scripts/patchers/cfw_dsc_chunks.py` — chunked-DSC byte-level helper
  (`DSCChunks(chunks_dir)`): vmaddr↔chunk-fileoff mapping, cstring
  scan over executable mappings, byte read/write at a vmaddr, and
  Mach-O header walk-back to resolve a vmaddr to the dylib install
  name (LC_ID_DYLIB).
* `scripts/patchers/cfw_patch_hv_vmm_dsc.py` — DSC-native orchestrator.
  No external `ipsw` dependency. For every `"kern.hv_vmm_present\0"`
  occurrence in any executable mapping, walks back to the containing
  dylib's Mach-O header, reads `LC_ID_DYLIB`, and — unless the install
  name is in the `DONT_PATCH_INSTALL_NAMES` blacklist — rewrites byte 5
  of the cstring through `DSCChunks.write_at_vma`. Pure Python.
  Blacklist-based by design so an operator can add an entry to take one
  dylib out of the patch set and bisect.
* ~~`scripts/patchers/cfw.py patch-hv-vmm <binary>`~~ — **gone.** The
  standalone-Mach-O subcommand and its backing patcher
  (`cfw_patch_hv_vmm_rootfs.py`) were removed with item 8 in the
  blacklist-flip redesign; the 6 on-device files no longer need an
  SSH-time patch. `scripts/patch_hv_vmm_userland.sh:65-73` documents
  why the wrapper's standalone branch has no honest substitute.
* `scripts/patchers/cfw.py patch-hv-vmm-dsc <chunks_dir>` —
  DSC subcommand (used while the SystemOS Cryptex DMG is still
  mounted on the host, before the device copy).
* `scripts/patch_hv_vmm_userland.sh` — thin wrapper used by the
  install scripts.
* `scripts/cfw_install_exp.sh` — EXP install script. Pre-step before
  invoking `cfw_install.sh`: decrypts the SysOS Cryptex into the cache
  location `cfw_install.sh` already uses, mounts it, applies the
  DSC patch, unmounts. The unmodified `cfw_install.sh` then sees the
  cached (already-patched) DMG. Standalone watchdogd is patched later
  via SSH at step `[EXP-JB-3.5]`.
* `scripts/cfw_install_jb.sh` and `scripts/cfw_install_dev.sh` —
  unchanged from pre-experimental baseline. Neither runs the DSC
  patcher.

### `kern.hv_vmm_present` kernel patcher — Part A + Part B (EXP only)

The `KernelEXPPatchHvVmmRename` Swift patcher (in `KernelEXPPatcher.findAll()`,
chained after `KernelPatcher` and `KernelJBPatcher` for the `.exp` variant only)
renames the sysctl OID and rewrites every kernel-internal occurrence of the
old name so kexts continue to find it under the new name. Two parts. JB and
other variants do NOT run this patcher.

**Part A — OID name rename.** Finds the OID's `oid_name` cstring as
the NUL-delimited bytes `\0hv_vmm_present\0` (exactly one match
required in the kernelcache; on iPhone17,3 / iOS 26.1 this lives at
file offset `0x964e0` inside `com.apple.kernel`). Flips byte 0 of the
cstring `'h'` (0x68) → `'X'` (0x58). After the patch, the kernel's
`sysctl_register_oid` keeps the OID's MIB and value (1) intact but
the name resolver returns `ENOENT` for `kern.hv_vmm_present` and
returns 1 for `kern.Xv_vmm_present`.

**Part B — kernel-internal caller mangle.** After Part A, any
kernel-side `sysctlbyname("kern.hv_vmm_present", …)` call gets
ENOENT and falls into the caller's "not in a VM" branch — which on
the bring-up build caused AMFI to panic with `AMFI: No PMGR?
(ConfigurationSettings.cpp:388)` during ramdisk boot. Part B mangles
every kernel-internal occurrence of the `kern.hv_vmm_present` name
so callers continue to find the renamed OID. The mangle flips byte
5 of the inner cstring (`'h'` after `kern.`) → `'X'`, producing
`kern.Xv_vmm_present`.

Two byte-aligned forms are searched, both anchored at the
`kern.hv_vmm_present` substring:

| Form | Needle | Where it lives | Mangle delta within needle |
|------|--------|----------------|----------------------------|
| (i) NUL-delimited cstring | `\0kern.hv_vmm_present\0` | `__TEXT,__cstring` of any kext that calls sysctlbyname by full name | +6 (skip leading NUL + 5) |
| (ii) Sandbox-profile name token | `kern.hv_vmm_present\x0f` | Inside a compiled sandbox-profile blob within `com.apple.security.sandbox`. The `\x0f` byte is the sandbox-profile end-of-name marker; the token has no leading NUL. | +5 |

On iPhone17,3 / iOS 26.1 / 23B85 the universe is 5 occurrences
(verified by raw substring scan over the kernelcache buffer):

| File offset | Fileset entry | Form |
|-------------|---------------|------|
| `0x541d56` | `com.apple.driver.AppleMobileFileIntegrity` | (i) cstring |
| `0x81bdc3` | `com.apple.iokit.IOCryptoAcceleratorFamily` | (i) cstring |
| `0xa6618b` | `com.apple.security.sandbox` | (ii) sandbox-profile name token |
| `0xbb0d55` | `com.apple.security.sandbox` | (i) cstring |
| `0xbce1f9` | `com.apple.filesystems.apfs` | (i) cstring |

Part B emits one patch record per match (5 total, plus Part A's 1)
under patch IDs `kernelcache_exp.hv_vmm_internal_caller_mangle` and
`kernelcache_exp.hv_vmm_oid_rename`. Idempotent: a re-run detects
already-mangled bytes (`kern.Xv_vmm_present` instead of
`kern.hv_vmm_present`) and reports the patch as already applied.

**Note on the sandbox-profile occurrence.** This was missed by the
original Part B because its needle required NUL on both sides. The
sandbox-profile blob stores OID names as TLV-framed tokens where the
trailing byte is `\x0f` (sandbox EOT) rather than a NUL. Without the
second needle, sandboxed callers that interpret the profile's
`kern.hv_vmm_present`-matching rule would still match against the
OLD name, while the OID itself has been renamed — so the rule's
ALLOW/DENY/audit action would never fire. With the second needle,
the rule's name token is rewritten to `kern.Xv_vmm_present` and
sandboxed callers that hit the renamed OID match the (rewritten)
rule as intended. Covered occurrence verified on
iPhone17,3 / iOS 26.1 / 23B85 at file offset `0xa6618b`.

### `watchdogd` surgical hv_vmm_present cache patch (EXP only)

**Why a dedicated patch.** After the EXP kernel-side OID rename
(`KernelEXPPatchHvVmmRename`), `sysctlbyname("kern.hv_vmm_present", ...)`
returns `ENOENT` on this image. `/usr/libexec/watchdogd` caches that
answer at startup. On `ENOENT` the cached byte stays at its BSS-zero
default (`0`) and the downstream `cbz w0, ...` at the IOWatchdog-lookup
site (`+0x58e0`) takes a branch into a `_os_crash` wrapper that does
`brk #1`. launchd's `_PanicOnCrash → PanicOnConsecutiveCrash = true`
flag in `com.apple.watchdogd.plist` escalates the SIGTRAP to a kernel
panic. The cstring-mangle approach used elsewhere doesn't apply here
because we want this binary to behave as if the sysctl returned `1`,
not as if it returned `ENOENT`.

**Patch shape.** Two-instruction surgical edit at every site in
watchdogd that has the canonical caching shape:

```
adrp x0, <page>
add  x0, x0, #<off>          ; "kern.hv_vmm_present"
...arg setup...
bl   _sysctlbyname
cbnz w0, <skip>              ; <-- patched: NOP
ldur w8, [x29, #-4]
cmp  w8, #0
cset wN, ne                  ; <-- patched: mov wN, #1
adrp xM, <page>
strb wN, [xM, #<imm>]        ; cached "am I a VM?" byte
```

Net effect: the cached byte is forced to `1` regardless of the sysctl
result, and watchdogd's pre-existing "detected virtual machine
environment, exiting..." clean-exit branch runs instead of the trap
path. Two functions in watchdogd match this shape on
`iPhone17,3 / iOS 26.1`; both are patched.

**Code signing.** The byte edit invalidates the SHA-256 slot hashes
for the 4 KiB pages containing the modifications in watchdogd's own
`CS_CodeDirectory`. The patcher recomputes those slot hashes in place
via `cfw_macho_codesign.reattest_modified_offsets` (4 KiB page size
read from the CD, correct tail-slot length, all present CDs). The
resulting CD mutation also changes the cdHash, but the existing JB
kernel patch `patch_amfi_cdhash_in_trustcache` accepts any cdHash, so
AMFI's trust-cache check still passes at execve. The patcher does NOT
re-sign with `ldid` — preserving the original Apple-issued code-signing
identifier (`com.apple.watchdogd`) is required for launchd's boot-task
identity validation; an earlier attempt to re-sign other rootfs
binaries with `ldid_sign` tripped this check on `mobile_obliterator`.

**Wiring.**

* `scripts/patchers/cfw_macho_codesign.py` — standalone-Mach-O
  page-hash re-attestation (parallel to `cfw_dsc_codesign.py` but
  parses `LC_CODE_SIGNATURE` directly, uses page size from the CD
  header, handles short tail slot, updates every present CD).
* `scripts/patchers/cfw_patch_watchdogd.py` — capstone-anchored
  pattern matcher + Keystone-assembled 2-insn patch + slot reattest.
  Idempotent.
* `scripts/patchers/cfw.py patch-watchdogd <binary>` — CLI subcommand.
* `scripts/patch_hv_vmm_userland.sh watchdogd <binary>` — thin shim
  used by the install script.
* `scripts/cfw_install_exp.sh` — invokes the patcher at step `[EXP-JB-3.5]`
  on the live `/mnt1/usr/libexec/watchdogd` (scp-down, patch, scp-up,
  chmod 0755). JB and DEV install scripts do NOT run this step.

### DeviceTree `/product/camera` node addition at fw_patch time (EXP only)

`DeviceTreePatcher` carries an `experimentalNodeAdditions` list with one
entry — a `/device-tree/product/camera` child node. Applied only when
`includeIdentityPatches` is true (i.e. variant `.exp`); other variants
leave the product subtree unchanged.

| Property                            | Type          | Value | Purpose                                                 |
|-------------------------------------|---------------|-------|---------------------------------------------------------|
| `name`                              | cstring       | `camera` | DT node name (auto-added from `nodeName`).           |
| `aggregate-camera`                  | uint32        | `1`   | Backs MG `aggregateCameraCapability` getter.            |
| `auto-focus`                        | uint32        | `1`   | Backs MG `autoFocusCameraCapability` getter.            |
| `flash`                             | uint32        | `1`   | Backs MG `cameraFlashCapability` getter.                |
| `pearl-camera`                      | uint32        | `1`   | Backs MG `pearlCameraCapability` getter.                |
| `panorama`                          | uint32        | `1`   | Backs MG `panoramaCameraCapability` getter.             |
| `pipelined-stillimage-capability`   | uint32        | `1`   | Backs MG `pipelinedStillImageCaptureCapability`.        |
| `rear-burst`, `front-burst`         | uint32        | `1`   | Backs MG burst-capability getters.                      |
| `video-cap`                         | uint32        | `2`   | Video capture level (real D47AP value).                 |
| `camera-hdr-version`                | uint32        | `3`   | HDR version (real D47AP value).                         |
| `camera-ui-version`                 | uint32        | `2`   | UI version selector (real D47AP value).                 |

Why this is necessary: `libMobileGestalt.dylib` resolves
`MGGetBoolAnswer("still-camera")` (cstring at vmaddr `0x1b1c5fedd`) via a
chain that reads `IODeviceTree:/product/camera` (cstring at vmaddr
`0x1b1c5832a`, **65 ADRP+ADD xrefs in the same dylib's `__text`**). The
canonical iPhone17,3 D47AP DT carries this node with 64 capability
properties; the vphone600AP DT ships **zero** `camera`, `audio`,
`facetime`, or `back-camera` references under `/product`. Without
the node, SpringBoard's `SBAppTags = ["still-camera"]` filter hides
Camera.app's icon and refuses to launch the bundle.

The node alone is not enough: the SBAppTags resolver also chains
through `/product` direct properties (`assistant`, `dictation`,
`compatible-device-fallback`, `chrome-identifier`, …), most of which
ship as 12-byte `'syscfg/XXXX'` cstring placeholders on vphone600 and
read back as NO. Tier 1d (below) rewrites those.

Idempotent: re-running against an already-patched DT detects the
existing child and skips.

### Camera DSC patch (EXP only)

`apply_all_camera_patches` in `scripts/patchers/cfw_patch_camera_dsc.py`
runs two patch families. Symbols are resolved per-build via
`ipsw dyld symaddr` against the cryptex's `dyld_shared_cache_arm64e`
header.

| # | Target | Framework | Effect |
|---|---|---|---|
| 1 | `+[_NUStyleTransfer{,Apply,Thumbnail,Learn,Interpolate}Processor processWithInputs:arguments:output:error:]` (5 entry points) | NeutrinoCore | Each replaced with `mov w0, #0; ret`. Camera's CIImageProcessorKernel chain that drives the style preview thumbnails short-circuits before reaching `+[_NUStyleEngine usingSharedStyleEngineForUsage:...]` → `_NUStyleEngineMemoryResource initWithDevice:descriptor:` which would otherwise assert on a nil descriptor (root cause is an upstream ANE-detection gate in `CMIStyleEngineCommonSettings`; we workaround at the consumer instead of unblocking it). |
| 2 | `+[AVCaptureDevice authorizationStatusForMediaType:]` | AVFCapture | Replaced with `mov w0, #3; ret` (AVAuthorizationStatusAuthorized = 3). Any process probing camera/audio/etc. media-type authorization gets "Authorized" without going through TCC. Stage 0 of the vcam stack — makes apps stop bailing on the auth check. Audio capture still does not work on the VM (the virtio sound driver added 2026-10-02 is output only), so the broader scope is harmless (audio-capture consumers fail downstream regardless). Downstream pipeline (cameracaptured rewrite, vcamd daemon) still owed for actual frame delivery. |

Wired into `cfw_install_exp.sh` immediately after the hv_vmm DSC step,
inside the same `hdiutil attach` block (one mount/unmount per install).
Page-hash re-attestation keeps the cryptex's CodeDirectory slots
consistent with the modified pages so `amfid` / TXM accepts the DSC at
next boot.

### DeviceTree identity properties at fw_patch time (EXP only)

`DeviceTreePatcher` carries two property-patch lists: `basePropertyPatches`
(4 entries — `serial-number`, `home-button-type`, `artwork-device-subtype`,
`island-notch-location`) applied for every variant, and
`identityPropertyPatches` (8 entries) applied **only when `includeIdentityPatches`
is true**, which `FirmwarePipeline` sets exactly when `variant == .exp`.

The 8 EXP-only identity properties (no restore-fatal ones — those go through
EXP-JB-6 post-restore):

| # | Node path                                          | Property              | Old → New                     | Risk    |
|---|----------------------------------------------------|-----------------------|-------------------------------|---------|
| 1 | `device-tree`                                      | `target-sub-type`     | `VPHONE600AP` → `D47AP`       | HIGHER  |
| 2 | `device-tree`                                      | `compatible[1]`       | `iPhone99,11` → `iPhone17,3` (slot-preserving) | LOW |
| 3 | `device-tree/product`                              | `fdr-product-type`    | `iPhone99,11` → `iPhone17,3`  | HIGHER  |
| 4 | `device-tree/product`                              | `sub-product-type`    | `iPhone99,11` → `iPhone17,3`  | LOW     |
| 5 | `device-tree/product`                              | `unique-model`        | `VPHONE600AP` → `D47AP`       | LOW     |
| 6 | `device-tree/arm-io`                               | `device_type`         | `vresearch1-io` → `t8140-io`  | MEDIUM  |
| 7 | `device-tree/arm-io`                               | `soc-generation`      | `VResearch1` → `H17`          | MEDIUM-LOW |
| 8 | `device-tree/product/vphone600-gestalt-variants`   | `name` (node rename)  | `vphone600-gestalt-variants` → `d47-gestalt-variants` | LOW-MEDIUM |

Root `model` and root `target-type` are deliberately NOT in this list —
both have been empirically shown to break restore. Those edits run
post-restore as EXP-JB-6.

Bulk `/product` direct-property completion (rewriting the ~30
`'syscfg/XXXX'` placeholders to D47AP integer/string values) was
attempted to make `MGGetBoolAnswer("still-camera")` answer YES via the
DT path alone. It broke screen rendering on the VM (the display
pipeline / framebuffer pulls one or more `/product` capability props
during init and chooses a render path the VM can't service). Reverted.
A narrower set targeted at the Camera-icon resolver chain (Tier B + C
+ F, below) does work without breaking display.

### DeviceTree Camera-icon completion (Tier B + C + F, EXP only)

Two `PropertyPatch` entries in `identityPropertyPatches`, three
`AddChildNodePatch` entries appended to `experimentalNodeAdditions`
for `/product/*` children, and five more for `/arm-io/*` stubs.
Empirically: this is the set that makes Camera.app's icon visible on
the home screen and in Spotlight without breaking screen rendering.

**Tier B — `/product` cam-offset rewrites.** vphone600 ships these
as 12-byte `'syscfg/{fcof,rcof}'` cstring placeholders. d47ap carries
20-byte little-endian geometry blobs. Consumed by Camera.app / ARKit
/ FaceTime for image-centering math.

| Property | Old length | New length | New value (hex) |
|----------|:----------:|:----------:|------------------|
| `/product::front-cam-offset-from-center` | 12 | 20 | `61000100921c0000d8130000e803000000000000` |
| `/product::rear-cam-offset-from-center`  | 12 | 20 | `eda50000b256000059080000e803000000000000` |

**Tier C — new `/product/*` child nodes.** d47ap carries three
sibling nodes to `/product/camera`. vphone600 has none of them.

| Node | Props | Camera relevance |
|------|:-----:|------------------|
| `/product/facetime` | 9 (excl. AAPL,phandle) | Front-camera video-call config — bitrates, codec encoding/decoding, tnr-mode-back/front. |
| `/product/audio` | 31 (excl. AAPL,phandle; an iPad guest takes its board's node instead, see "Guest audio" 2026-10-02) | Carries `supports-spatial-audio-capture=1` + `supports-spatial-facetime=1` (camera-joint). Rest is audio config. |
| `/product/iopm` | 2 (excl. AAPL,phandle) | `aot-mode=13` + `aot-linger-time-ms=0`. Always-On Technology mode. |

All property values copied byte-for-byte from
`ipsws/iPhone17,3_26.5_23F77_Restore_extracted/Firmware/all_flash/DeviceTree.d47ap.im4p`.

**Tier F — `/arm-io/*` minimal camera-flag stubs.** d47ap carries
`/arm-io/isp` (65 props), `/arm-io/ispRtb` (53 props), and a deep
`/arm-io/smc/iop-smc-nub/smc-ext-charger` chain (3 levels of node).
vphone600 has none of these paths. We add minimal stub nodes carrying
ONLY the camera-* properties and the mandatory auto-`name`,
deliberately omitting `compatible`/`device_type`/`reg`/`interrupts`,
so no IOKit kext finds a matching `compatible=` and tries to probe
non-existent ISP / SMC hardware.

| Path | Property | Value |
|------|----------|-------|
| `/arm-io/smc` | (stub — parent for chain) | — |
| `/arm-io/smc/iop-smc-nub` | (stub — parent for charger) | — |
| `/arm-io/smc/iop-smc-nub/smc-ext-charger` | `camera-driver` | str `'AppleH16CamIn'` |
| `/arm-io/isp` | `camera-front`, `camera-rear` | int32:1, int32:1 |
| `/arm-io/ispRtb` | `camera-front`, `camera-rear` | int32:1, int32:1 |

Dependency order: the patcher walks `experimentalNodeAdditions` in
array order against the in-memory tree, so each entry that resolves
to a parent added by an earlier entry resolves correctly.

Idempotent: re-running the patcher against an already-modified DT
detects the existing child by name and skips. The DT IM4P that ships
on subsequent boots is signed by Apple but the existing iBSS/iBEC/LLB
`image4_validate_property_callback` bypass accepts arbitrary payloads.

### Post-restore DT identity rewrite (EXP-JB-6, EXP only)

After the restore daemon's BuildManifest identity check has passed,
`cfw_install_exp.sh` step `[EXP-JB-6]` scp's `devicetree.img4` down from the
mounted rootfs (`/mnt5/<boot-hash>/usr/standalone/firmware/`), runs
`scripts/patchers/cfw_patch_post_restore_dt.py`, and scp's the rewritten
img4 back. The Python patcher unwraps the IM4P via `pyimg4`, parses the
DT flat-binary, rewrites three restore-fatal root properties, and repacks
preserving the IMG4's original IM4M ticket. The iBSS/iBEC/LLB
`image4_validate_property_callback` bypass (existing JB patch) accepts
the modified payload at next boot.

| # | Property         | Old → New                                                              |
|---|------------------|------------------------------------------------------------------------|
| 1 | root `model`       | `iPhone99,11` → `iPhone17,3`                                          |
| 2 | root `target-type` | `VPHONE600` → `D47`                                                   |
| 3 | root `compatible`  | reorder `["VPHONE600AP", "iPhone99,11", "AVP-ARM"]` → `["D47AP", "VPHONE600AP", "AVP-ARM"]` (keeps `VPHONE600AP` in second slot so IOKit's `AppleVMApple1IO` kext binding still resolves; userland reads only the first entry for `hw.model`) |

Idempotent. Skipped if already-rewritten DT is detected.

### SystemVersion.plist `ProductBuildVersion` rewrite (EXP-JB-7, EXP only, opt-in)

Gated on the `SPOOF_BUILD` env var. When `cfw_install_exp.sh` is invoked
with e.g. `SPOOF_BUILD=23F77`, step `[EXP-JB-7]` runs
`scripts/patchers/cfw_patch_build_version.py` (plistlib-based,
format-preserving) on both the rootfs and cryptex copies of
`SystemVersion.plist` to rewrite the `ProductBuildVersion` key to the
specified id. Without `SPOOF_BUILD`, the step is skipped and the build
version stays at the original IPSW value.

| File                                                                              | Touched if `SPOOF_BUILD=<id>` |
|-----------------------------------------------------------------------------------|:------------------------------:|
| `/mnt1/System/Library/CoreServices/SystemVersion.plist` (rootfs)                  | Y                              |
| `/mnt5/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist` (cryptex)    | Y                              |

`kern.osversion` is unaffected — that comes from a kernel global
initialized from boot args, not from this plist. Userland MG cache
picks up the new build identifier on first boot after the gestalt
cache rebuild.

### CFW Installer Flow Matrix (Script-Level)

| Flow Item                                     | Regular (`cfw_install.sh`)      | Dev (`cfw_install_dev.sh`) | JB (`cfw_install_jb.sh`)                      | EXP (`cfw_install_exp.sh`)                            |
| --------------------------------------------- | ------------------------------- | -------------------------- | --------------------------------------------- | ----------------------------------------------------- |
| Base CFW phases (1/7 -> 7/7)                  | Runs directly                   | Runs directly              | Runs via `CFW_SKIP_HALT=1 zsh cfw_install.sh` | Runs via `CFW_SKIP_HALT=1 zsh cfw_install.sh`         |
| Dev overlay (`rpcserver_ios` replacement)     | -                               | Y (`apply_dev_overlay`)    | -                                             | -                                                     |
| SSH readiness wait before install             | Y (`wait_for_device_ssh_ready`) | -                          | Y (inherited from base run)                   | Y (inherited from base run)                           |
| launchd jetsam patch (`patch-launchd-jetsam`) | -                               | Y (base-flow injection)    | Y (JB-1)                                      | Y (JB-1)                                              |
| launchd dylib injection (`inject-dylib /b`)   | -                               | -                          | Y (JB-1, opt-out via `DISABLE_LAUNCHD_HOOK=1`) | Y (JB-1, opt-out via `DISABLE_LAUNCHD_HOOK=1`)        |
| Procursus bootstrap deployment                | -                               | -                          | Y (JB-2)                                      | Y (JB-2)                                              |
| BaseBin hook deployment (`*.dylib` -> `/mnt1/cores`) | -                        | -                          | Y (JB-3)                                      | Y (JB-3)                                              |
| First-boot JB finalization (`vphone_jb_setup.sh`) | -                           | -                          | Y (post-boot)                                 | Y (post-boot)                                         |
| IOMobileFramebuffer SwapEnd payload-size patch (install-gated `26.0*`/`18.*` -> 0x560 / 26.1 base; **27.0 does NOT use this — it uses force-kern, next section**) | Y              | Y                          | Y (inherited from base run)                   | Y (inherited from base run)                           |
| dyld cache `maxSlide` zero (`patch-dsc-maxslide`; **install-gated `27.*`** as of 2026-07-20 — iOS 27's cache overflows the 6 GiB region; 18.x/26.x skip it; the old `FORCE_DSC_MAXSLIDE=1` / `--force-dsc-maxslide` opt-in was removed 2026-09-30) | Y | Y                     | Y (inherited from base run)                   | Y (inherited from base run)                           |
| DSC pre-patch (`kern.hv_vmm_present` byte-5 mangle + slot reattest) | -         | -                          | -                                             | Y (pre-step, before base CFW)                         |
| DSC camera patches (12 patches across CMCapture / CoreMediaIO / AVFCapture / libMobileGestalt) | - | -                  | -                                             | Y (pre-step, same cryptex mount as hv_vmm)            |
| `watchdogd` surgical 2-insn patch + slot reattest | -                           | -                          | -                                             | Y (EXP-JB-3.5)                                        |
| Post-restore DT identity rewrite (`devicetree.img4`)| -                         | -                          | -                                             | Y (EXP-JB-6)                                          |
| `SystemVersion.plist` `ProductBuildVersion` rewrite | -                         | -                          | -                                             | Y (EXP-JB-7, opt-in via `SPOOF_BUILD`)                |
| Additional input resources                    | `cfw_input`                     | `cfw_input` + `resources/cfw_dev/rpcserver_ios` | `cfw_input` + `cfw_jb_input` | `cfw_input` + `cfw_jb_input`        |
| Extra tool requirement beyond base            | -                               | -                          | `zstd`                                        | `zstd`                                                |
| Halt behavior                                 | Halts unless `CFW_SKIP_HALT=1`  | Halts unless `CFW_SKIP_HALT=1` | Always halts after JB phases              | Always halts after EXP phases                         |

## Summary

| Component                          | Regular | Dev |  JB | EXP |
| ---------------------------------- | ------: | --: | --: | --: |
| AVPBooter                          |       1 |   1 |   1 |   1 |
| iBSS                               |       2 |   2 |   3 |   3 |
| iBEC                               |       4 |   4 |   4 |   4 |
| LLB                                |       6 |   6 |   6 |   6 |
| TXM                                |       1 |  12 |  12 |  12 |
| Kernel (base)                      |      28 |  29 |  28 |  28 |
| Kernel (JB methods)                |       - |   - |  59 |  59 |
| Kernel (EXP methods, `hv_vmm`)     |       - |   - |   - |   6 |
| DeviceTree base properties         |       4 |   4 |   4 |   4 |
| DeviceTree EXP identity properties |       - |   - |   - |   8 |
| DeviceTree EXP node additions      |       - |   - |   - |   1 (`/product/camera`) |
| Restore environment                |       2 |   2 |   2 |   2 |
| Boot chain total                   |      48 |  60 | 119 | 134 |
| CFW binary patches (base)          |       4 |   5 |   6 |   6 |
| CFW EXP-only steps                 |       - |   - |   - |   5 (hv_vmm DSC, camera DSC ×12, watchdogd EXP-JB-3.5, post-restore DT EXP-JB-6, build-version EXP-JB-7 opt-in) |
| CFW installed components           |       6 |   7 |   9 |   9 |
| CFW total                          |      10 |  12 |  15 |  31 |
| Grand total                        |      56 |  70 | 132 | 163 |

## Ramdisk Variant Matrix

| Variant        | Pre-step             | `Ramdisk/txm.img4`               | `Ramdisk/krnl.ramdisk.img4`                                                      | `Ramdisk/krnl.img4`                            | Effective kernel used by `ramdisk_send.sh`          |
| -------------- | -------------------- | -------------------------------- | -------------------------------------------------------------------------------- | ---------------------------------------------- | --------------------------------------------------- |
| `RAMDISK`      | `make fw_patch`      | release TXM + base TXM patch (1) | base kernel (28), legacy `*.ramdisk` preferred else derive from pristine CloudOS | restore kernel from `fw_patch` (28)            | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |
| `DEV+RAMDISK`  | `make fw_patch_dev`  | release TXM + base TXM patch (1) | base kernel (28), same derivation rule                                           | restore kernel from `fw_patch_dev` (29)        | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |
| `JB+RAMDISK`   | `make fw_patch_jb`   | release TXM + base TXM patch (1) | base kernel (28), same derivation rule                                           | restore kernel from `fw_patch_jb` (28+59)      | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |
| `EXP+RAMDISK`  | `make fw_patch_exp`  | release TXM + base TXM patch (1) | base kernel (28), same derivation rule                                           | restore kernel from `fw_patch_exp` (28+59+6)   | `krnl.ramdisk.img4` preferred, fallback `krnl.img4` |

## Cross-Version Dynamic Snapshot

| Case                | TXM_JB_PATCHES | KERNEL_JB_PATCHES |
| ------------------- | -------------: | ----------------: |
| PCC 26.1 (`23B85`)  |             14 |                59 |
| PCC 26.3 (`23D128`) |             14 |                59 |
| iOS 26.1 (`23B85`)  |             14 |                59 |
| iOS 26.3 (`23D127`) |             14 |                59 |

## Swift Migration Notes (2026-03-10)

- Swift `FirmwarePatcher` now matches the Python reference patch output across all checked components:
  - `avpbooter` 1/1
  - `ibss` 4/4
  - `ibec` 7/7
  - `llb` 13/13
  - `txm` 1/1
  - `txm_dev` 12/12
  - `kernelcache` 28/28
  - `ibss_jb` 1/1
  - `kernelcache_jb` 84/84
- JB parity fixes completed in Swift:
  - C23 `vnode_getattr` resolution now follows the Python backward BL scan and resolves `0x00CD44F8`.
  - C22 syscallmask cave encodings were corrected and centralized in `ARM64Constants.swift`.
  - Task-conversion matcher masks and kernel-text scan range were corrected, restoring the patch at `0x00B0C400`.
  - `jbDecodeBranchTarget()` now correctly decodes `cbz/cbnz`, restoring the real `_bsd_init` rootauth gate at `0x00F7798C`.
  - IOUC MACF matching now uses Python-equivalent disassembly semantics for the aggregator shape, restoring the deny-to-allow patch at `0x01260644`.
- C24 `kcall10` cave instruction bytes were re-verified against macOS `clang`/`as`; no Swift byte changes were needed.
- The Swift pipeline is now directly invokable from the product binary:
  - `vphone-cli patch-firmware --vm-directory <dir> --variant {regular|dev|jb}`
  - `vphone-cli patch-component --component {txm|kernel-base} --input <file> --output <raw>` is available for non-firmware tooling that still needs a single patched payload during ramdisk packaging
  - default loader now preserves IM4P containers via `IM4PHandler`
  - DeviceTree patching now uses the real Swift `DeviceTreePatcher` in the pipeline
  - project `make fw_patch`, `make fw_patch_dev`, and `make fw_patch_jb` targets now invoke this Swift pipeline via the unsigned debug `vphone-cli` build, while the signed release build remains reserved for VM boot/DFU paths
  - on 2026-03-11, the legacy Python firmware patcher entrypoints and patch modules were temporarily restored from pre-removal history for parity/debug work.
  - after byte-for-byte parity was revalidated against Python on `26.1` and `26.3` for `regular`, `dev`, and `jb`, those legacy firmware-patcher Python sources and transient comparison/export helpers were removed again so the repo keeps Swift as the single firmware-patching implementation.
- Swift pipeline follow-up fixes completed after CLI bring-up:
  - `findFile()` now supports glob patterns such as `AVPBooter*.bin` instead of treating them as literal paths.
  - JB variant sequencing now runs base iBSS/kernel patchers first, then the JB extension patchers.
  - Sequential pipeline application now merges each patcher's `PatchRecord` writes onto the shared output buffer while keeping later patcher searches anchored to the original payload, matching the standalone Swift/Python validation model.
  - `apply()` now reuses an already-populated `patches` array instead of re-running `findAll()`, so `patch-firmware` / `patch-component` no longer double-scan or double-print the same component diagnostics on a single invocation.
  - unaligned integer reads across the firmware patcher now go through a shared safe `Data.loadLE(...)` helper, fixing the JB IM4P crash (`Swift/UnsafeRawPointer.swift:449` misaligned raw pointer load).
  - `TXMPatcher` now preserves pristine Python parity by preferring the legacy trustcache binary-search site when present, and only falls back to the selector24 hash-flags call chain (`ldr x1, [x20,#0x38]` -> `add x2, sp, #4` -> `bl` -> `ldp x0, x1, [x20,#0x30]` -> `add x2, sp, #8` -> `bl`) when rerunning on a VM tree that already carries the dev/JB selector24 early-return patch.
  - `scripts/fw_prepare.sh` now deletes stale sibling `*Restore*` directories in the working VM directory before patching continues, so a fresh `make fw_prepare && make fw_patch` cannot accidentally select an older prepared firmware tree (for example `26.1`) when a newer one (for example `26.3`) was just generated.
  - 26.0 and 26.0.1 GUI bring-up now patches installed DSC `IOMobileFramebuffer` only when `ProductVersion` starts with `26.0`: `_kern_SwapEnd` passes a 0x560-byte state to the 26.1 PCC userclient instead of the 26.0/26.0.1 0x548-byte state. JB host installs were validated on `17,3_26.0_23A341`, `17,3_26.0.1_23A355`, and unchanged `17,3_26.1_23B85`.
- IM4P/output parity fixes completed after synthetic full-pipeline comparison:
  - `IM4PHandler.save()` no longer forces a generic LZFSE re-encode.
  - Swift now rebuilds IM4Ps in the same effective shape as the Python patch flow and only preserves trailing `PAYP` metadata for `TXM` (`trxm`) and `kernelcache` (`krnl`).
  - `IBootPatcher` serial labels now match Python casing exactly (`Loaded iBSS`, `Loaded iBEC`, `Loaded LLB`).
  - `DeviceTreePatcher` now serializes the full patched flat tree, matching Python `dtree.py`, instead of relying on in-place property writes alone.
- Synthetic CLI dry-run status on 2026-03-10 using IM4P-backed inputs under `ipsws/patch_refactor_input`:
  - regular: 58 patch records
  - dev: 69 patch records
  - jb: 154 patch records
- Full synthetic Python-vs-Swift pipeline comparison status on 2026-03-10 using `scripts/compare_swift_python_pipeline.py`:
  - regular: all 7 component payloads match
  - dev: all 7 component payloads match
  - jb: all 7 component payloads match
- Real prepared-firmware Python-vs-Swift pipeline comparison status on 2026-03-10 using `vm/` after `make fw_prepare`:
  - historical note: the now-removed `scripts/compare_swift_python_pipeline.py` cloned only the prepared `*Restore*` tree plus `AVPBooter*.bin`, `AVPSEPBooter*.bin`, and `config.plist`, avoiding `No space left on device` failures from copying `Disk.img` after `make vm_new`.
  - regular: all 7 component payloads match
  - dev: all 7 component payloads match
  - jb: all 7 component payloads match
- Runtime validation blocker observed on 2026-03-10:
  - `NON_INTERACTIVE=1 SKIP_PROJECT_SETUP=1 make setup_machine JB=1` reaches the Swift patch stage and reports `[patch-firmware] applied 154 patches for jb`, then fails when the flow transitions into `make boot_dfu`.
  - `make boot_dfu` originally failed at launch-policy time with exit `137` / signal `9` because the release `vphone-cli` could not launch on this host.
  - `amfidont` was then validated on-host:
    - it can attach to `/usr/libexec/amfid`
    - the initial path allow rule failed because `AMFIPathValidator` reports URL-encoded paths (`/Volumes/My%20Shared%20Files/...`)
    - rerunning `amfidont` with the encoded project path and the release-binary CDHash allows the signed release `vphone-cli` to launch
    - this workflow was packaged as `make amfidont_allow_vphone` / `scripts/start_amfidont_for_vphone.sh`
    - ~~**superseded 2026-09-23.** `amfidont` is gone, and so is the path/CDHash allowlist it provided — on macOS 26 amfid carries `com.apple.developer.hardened-process`, which gates the debugger operations a per-validation decision needs. `vphone-letmein` replaces it with a global switch held open only for the length of one launch, and `vphone-cli` (now unentitled, so it always starts) drives that itself. The URL-encoding detail above no longer applies: nothing matches on paths any more.~~
    - **That correction was itself wrong, and is reversed (2026-09-23, later the same day).** `amfidont` is the supported route again and `vphone-letmein` is deleted. Two things were measured:
      - `vphone-letmein` opened its window by writing amfid's `__TEXT`. Where the host enforces code signing system-wide the kernel validates that page on the next fault, finds no signature, and kills amfid — `EXC_BAD_ACCESS` / `SIGKILL` (Code Signature Invalid), termination namespace `CODESIGNING`, indicator "Invalid Page" — and the guest is `SIGKILL`ed too because amfid never answered. Measured twice on macOS 27.0 (26A428) arm64e: the patch lands, the read-back verifies, and the child still dies. The gate is `sysctl vm.cs_system_enforcement`, which reads **1** there and is read-only.
      - The claim that a per-validation decision is impossible was reasoning from that tool's own position. `amfidont` drives amfid through LLDB, and `debugserver` holds the Apple-private debugger entitlements; arm64 breakpoints live in the CPU's debug registers, so no page is ever dirtied. That is why it works under enforcement *and* why it can scope to one binary. **`amfidont` is an allowlist, not a global switch** — the "global switch" wording belonged to `vphone-letmein` and must not be carried onto it.
    - The URL-encoding detail above is therefore live again for `--path`, and is sidestepped entirely by allowing the **CDHash** instead, which is what the project documents. Allow `vphone-vm`, never `vphone-cli`: the entry point carries no entitlements and amfid never objects to it.
      - install (measured on this machine, 2026-09-23): `xcrun python3 -m pip install --user amfidont` → `~/Library/Python/3.9/bin/amfidont`. Apple's `/usr/bin/python3` is 3.9 and the tool re-execs Xcode's python3, so Xcode is required; Homebrew's python refuses under PEP 668.
      - run: `sudo amfidont daemon --cdhash "$(codesign -dv --verbose=4 <path>/vphone-vm 2>&1 | sed -n 's/^CDHash=//p' | head -1)" --spoof-apple --verbose`. With it running, `vphone-vm --help` exits 0 instead of being `SIGKILL`ed, and amfid stays alive.
      - it is **not** a dependency of this repo. Nothing here installs, spawns or supervises it, no Makefile target wraps it, and no Python is added to the tree for it — `vphone-cli` only detects the refusal and prints the command.
  - With launch policy bypassed, `make boot_dfu` advances into VM setup, emits `vm/udid-prediction.txt`, and then fails with `VZErrorDomain Code=2 "Virtualization is not available on this hardware."`
  - `VPhoneAppDelegate` startup failure handling was tightened so these fatal boot/DFU startup errors now exit non-zero; `make boot_dfu` now reports `make: *** [boot_dfu] Error 1` for the nested-virtualization failure instead of incorrectly returning success.
  - The host itself is a nested Apple VM (`Model Name: Apple Virtual Machine 1`, `kern.hv_vmm_present=1`), so the remaining blocker is lack of nested Virtualization.framework availability rather than firmware patching or AMFI bypass.
  - `boot_binary_check` now uses strict host preflight and fails earlier on this class of host with `make: *** [boot_binary_check] Error 3`, avoiding a wasted VM-start attempt once the nested-virtualization condition is already known.
  - Added `make boot_host_preflight` / `scripts/boot_host_preflight.sh` to capture this state in one command:
    - model: `Apple Virtual Machine 1`
    - `kern.hv_vmm_present`: `1`
    - SIP: disabled
    - `allow-research-guests`: disabled
    - current `kern.bootargs`: empty
    - next-boot `nvram boot-args`: `amfi_get_out_of_my_way=1 -v` (staged on 2026-03-10; requires reboot before it affects launch policy)
    - `spctl --status`: assessments enabled
    - `spctl --assess` rejects the signed release binary
    - unsigned debug `vphone-cli --help`: exit `0`
    - signed release `vphone-cli --help`: exit `137`
    - freshly signed debug control binary `--help`: exit `137`

## Automation Notes (2026-03-06)

- `scripts/setup_machine.sh` non-interactive flow fix: renamed local variable `status` to `boot_state` in first-boot log wait and boot-analysis wait helpers to avoid zsh `status` read-only special parameter collision.
- `scripts/setup_machine.sh` non-interactive first-boot wait fix: replaced `(( waited++ ))` with `(( ++waited ))` in `monitor_boot_log_until` to avoid `set -e` abort when arithmetic expression evaluates to `0`.
- `scripts/jb_patch_autotest.sh` loop fix for sweep stability under `set -e`: replaced `((idx++))` with `(( ++idx ))`.
- `scripts/jb_patch_autotest.sh` zsh compatibility fix: renamed per-case result variable `status` to `case_status` to avoid `status` read-only special parameter collision.
- `scripts/jb_patch_autotest.sh` selection logic update:
  - default run now excludes methods listed in `KernelJBPatcher._DEV_SINGLE_WORKING_METHODS` (pending-only sweep).
  - set `JB_AUTOTEST_INCLUDE_WORKING=1` to include already-working methods and run the full list.
- Sweep run record:
  - `setup_logs/jb_patch_tests_20260306_114417` (2026-03-06): aborted at `[1/20]` with `read-only variable: status` in `jb_patch_autotest.sh`.
  - `setup_logs/jb_patch_tests_20260306_115027` (2026-03-06): rerun after `status` fix, pending-only mode (`Total methods: 19`).
- Final run result from `jb_patch_tests_20260306_115027` at `2026-03-06 13:17`:
  - Finished: 19/19 (`PASS=15`, `FAIL=4`, all fails `rc=2`).
  - Failing methods at that time: `patch_bsd_init_auth`, `patch_io_secure_bsd_root`, `patch_vm_fault_enter_prepare`, `patch_cred_label_update_execve`.
  - 2026-03-06 follow-up: `patch_io_secure_bsd_root` failure is now attributed to a wrong-site patch in `AppleARMPE::callPlatformFunction` (`"SecureRoot"` gate at `0xFFFFFE000836E1F0`), not the intended `"SecureRootName"` deny-return path. The code was retargeted the same day to `0xFFFFFE000836E464` and re-enabled for the next restore/boot check.
  - 2026-03-06 follow-up: `patch_bsd_init_auth` was retargeted after confirming the old matcher was hitting unrelated code; keep disabled in default schedule until a fresh clean-baseline boot test passes.
  - Final case: `[19/19] patch_syscallmask_apply_to_proc` (`PASS`).
  - 2026-03-06 re-analysis: that historical `PASS` is now treated as a false positive for functionality, because the recorded bytes landed at `0xfffffe00093ae6e4`/`0xfffffe00093ae6e8` inside `_profile_syscallmask_destroy` underflow handling, not in `_proc_apply_syscall_masks`.
  - 2026-03-06 code update: `scripts/patchers/kernel_jb_patch_syscallmask.py` was rebuilt to target the real syscallmask apply wrapper structurally and now dry-runs on `PCC-CloudOS-26.1-23B85 kernelcache.research.vphone600` with 3 writes: `0x02395530`, `0x023955E8`, and cave `0x00AB1720`. User-side boot validation succeeded the same day.
- 2026-03-06 follow-up: `patch_kcall10` was rebuilt from the old ABI-unsafe pseudo-10-arg design into an ABI-correct `sysent[439]` cave. Focused dry-run on `PCC-CloudOS-26.1-23B85 kernelcache.research.vphone600` now emits 4 writes: cave `0x00AB1720`, `sy_call` `0x0073E180`, `sy_arg_munge32` `0x0073E188`, and metadata `0x0073E190`; the method was re-enabled in `_GROUP_C_METHODS`.
  - Observed failure symptom in current failing set: first boot panic before command injection (or boot process early exit).
- Post-run schedule change (per user request):
  - commented out failing methods from default `KernelJBPatcher._PATCH_METHODS` schedule in `scripts/patchers/kernel_jb.py`:
    - `patch_bsd_init_auth`
    - `patch_io_secure_bsd_root`
    - `patch_vm_fault_enter_prepare`
    - `patch_cred_label_update_execve`
- 2026-03-06 re-research note for `patch_cred_label_update_execve`:
  - old entry-time early-return strategy was identified as boot-unsafe because it skipped AMFI exec-time `csflags` and entitlement propagation entirely.
  - implementation was reworked to a success-tail trampoline that preserves normal AMFI processing and only clears restrictive `csflags` bits on the success path.
  - default JB schedule still keeps the method disabled until the reworked strategy is boot-validated.
- Manual DEV+single (`setup_machine` + `PATCH=<method>`) working set now includes:
  - `patch_amfi_cdhash_in_trustcache`
  - `patch_amfi_execve_kill_path`
  - `patch_task_conversion_eval_internal`
  - `patch_sandbox_hooks_extended`
  - `patch_post_validation_additional`
- 2026-03-07 host-side note:
  - reviewed private Virtualization.framework display APIs against the recorder pipeline in `Sources/VPhoneVirtualMachineKit/HostDevices/VPhoneScreenRecorder.swift`.
  - replaced the old AppKit-first recorder path with a private-display-only implementation built around hidden `VZGraphicsDisplay._takeScreenshotWithCompletionHandler:` capture.
  - added still screenshot actions that can copy the captured image to the pasteboard or save a PNG to disk using the same private capture path.
  - `make build` is used as the sanity check path; live VM validation is still needed to confirm the exact screenshot object type returned on macOS 15.
- 2026-03-15 tooling source sync update:
  - removed ad-hoc `git clone` source fetching from `Scripts/setup_tools.sh` and `scripts/setup_libimobiledevice.sh`.
  - added pinned git-submodule sources under `scripts/repos/` for: `trustcache`, `insert_dylib`, `libplist`, `libimobiledevice-glue`, `libusbmuxd`, `libtatsu`, `libimobiledevice`, `libirecovery`, `idevicerestore`.
  - setup scripts now initialize required submodules via `git submodule update --init --recursive <path>` and stage build copies under local tool build directories.
- 2026-06-15 cloudOS 26.5 (23F77) JB retargeting — P0 (sudo/setuid):
  - **JB-04 `patch_hook_cred_label_update_execve` (P0, sudo/setuid) — FIXED.**
    Root cause: `findVfsContextCurrentByShape()` pinned a 5-word prologue ending
    in `ldr x1, [x0, #0x3E0]`; the uthread offset drifted to `#0x3F0` on 26.5
    (`0x3E8` on macOS 26.5.1 KDK), so the exact match returned 0 hits.
    Fix: resolve `vfs_context_current` generically — symbol first, else the stable
    4-word prologue prefix (`pacibsp; stp x29,x30,[sp,#-0x10]!; mov x29,sp;
    mrs x0,tpidr_el1`) followed by *any* `ldr x1,[x0,#imm]` (imm left unpinned);
    uniqueness still required. Reveal: on the decompressed kernelcache the prefix
    matches 5 sites, exactly one followed by an `ldr x1,[x0,#imm]` →
    `vfs_context_current` @ va `0x8D7F39C` (foff `0x1D7B39C`). Validated via
    `make test_jb_patches`: both `jb.hook_cred_label.{ops_retarget,c23_cave}` emit.
  - Symbol oracle for the above: macOS 26.5.1 KDK (`KDK_26.5.1_25F80`) —
    `kernel.release.vmapple` + `Sandbox.kext`/`AMFI.kext` (arm64e) carry full nlist
    symbol tables for the XNU/Sandbox functions stripped from the vphone600 cache.
  - Remaining 26.5 JB failures (8) still open: `task_conversion_eval` (inlined),
    `proc_security_policy` + `proc_pidinfo` (shared `_proc_info` switch refactored,
    `cmp #0x21` bound gone), `io_secure_bsd_root` (iOS-only, absent from KDK),
    `mac_mount`, `spawn_validate_persona` (iOS-only), `vm_map_protect`,
    `kcall10`/`sysent`.
- 2026-06-16 cloudOS 26.5 (23F77) JB retargeting — the 8 remaining P1 failures, all FIXED.
  Ground truth: IDA (idasql) on the decompressed `kernelcache.research.vphone600`,
  symbolicated via the macOS KDK oracle; XNU source cross-check. Validation:
  `make test_jb_patches` → every supported cloudOS kernel applies with **0** `[-]`
  failures (84 patches each). All anchors are version-independent
  (semantic/Capstone/call-graph), no pinned offsets/indices.
  - **JB-11 `proc_security_policy` + JB-12 `proc_pidinfo` (shared root cause).**
    The `sub wN,wM,#1 ; cmp wN,#0x21` switch anchor matched TWO sites on 26.5; the
    naive first-match grabbed the wrong one (`decodeWakeReason`, lower address).
    Replaced the whole `findProcInfoAnchor` with two source-backed finders in
    `KernelJBPatcherBase.swift`: `findProcSecurityPolicy()` locates the unique
    function that loads `PRIV_GLOBAL_PROC_INFO` (1002 = `0x3EA`, a stable
    `bsd/sys/priv.h` ABI value) into `w1` ahead of `priv_check_cred` →
    `_proc_security_policy` @ va `0x927E330` (stub entry `mov x0,#0; ret`);
    `findProcInfoInternal()` = its sole caller via `blIndex` → `_proc_info_internal`
    @ `0x927B38C` (proc_pidinfo is now inlined there). proc_pidinfo NOPs the unique
    `ldr x0,[x0,#0x18]; cbz x0; bl; cbz/cbnz wN; mov w0,#0x16(EINVAL); sub wN,wM,#1`
    guard pair → `0x927BDA8` / `0x927BDB0`.
  - **JB-08 `task_conversion_eval_internal`.** Inlined; recovered via the unique
    `"…pineapple on pizza…"` panic-string function (`task_get_special_port_from_user`).
    The 26.1 matcher failed only because the compare operands swapped
    (`cmp x0,x9` vs `cmp x9,x0`). Rewrote `collectTaskConversionCandidates` to accept
    the kernel_task-vs-{X0,X1} compare in EITHER operand order. Unique hit
    `cmp x0,x9 → cmp xzr,xzr` @ va `0x8D087A8`.
  - **JB-?? `io_secure_bsd_root`.** `AppleARMPE::callPlatformFunction` (refs both
    `"SecureRoot"`+`"SecureRootName"`). The match-bit compare-context moved >0xA0 back
    (sync code inserted), breaking the old lookback. Re-anchored on the unique
    `csel Wd,wzr,Wn,<cond>` whose `Wn` is built as `kIOReturnNotPrivileged`
    (`movk Wn,#0xE000,lsl#16` — IOKit error high half). `csel w22,wzr,w9,ne →
    mov w22,#0` @ va `0x7B30E10`. Dropped the pinned `[x19,#0x11A]` field offset.
  - **JB-?? `mac_mount`.** Wrapper still uniquely identified by the twin gates among
    `mount_common` callers (`__mac_mount` @ `0x8EC04F0`). Site 1 (`tbnz wFlags,#5 →
    mov w?,#1` preboot reject) unchanged → NOP @ `0x8EC06FC`. Site 2 folded on 26.5:
    `add x?,#0x70 ; ldrb w8,[x?,#1] ; tbz w8,#6` → `ldrb w8,[x16,#0x71] ; tbnz w8,#6`.
    Re-anchored `findStateGate` on the `ldrb wN,[x,#imm] ; tbz/tbnz wN,#6` pair (the
    `#6` role bit is the stable semantic) and clear the loaded reg → `mov x8,xzr`
    @ `0x8EC072C`.
  - **JB-?? `spawn_validate_persona`** @ `0x91C0D4C` (reached from the spawn
    entitlement wrapper, intact). The trailing `mov x?,#0 ; ldr x?,[x?,#0x490] ; casa`
    corroboration lowered differently on 26.5; re-anchored `matchPersonaHelper` on the
    dual sibling reject `ldr [base,#8];cbz / ldr [base,#0xc];cbz` (same base + same
    deny target + deny `mov w?,#1`), preceded by the `[_,#0x18]` sibling guard. NOP
    both cbz → `0x91C0DF8` / `0x91C0E00`.
  - **JB-25 `vm_map_protect`** @ `0x8DCA0A8`. The 26.1 `mov #6;bics;b.ne;tbnz#22;and
    #~X` block was recompiled; the per-entry apply path now narrows protection with a
    runtime W^X mask register before `pmap_protect_options`
    (`lsr wT,wFlags,#7 ; and w3,wT,wMask`, `mov wMask,#5`). Widening the mask `#5 → #7`
    makes the AND a pass-through so the requested protection (incl. the stripped bit)
    reaches the pmap — strictly permissive (`prot&7 ⊇ prot&5`). `mov w27,#5 → mov
    w27,#7` @ `0x8DCA30C`.
  - **JB-?? `kcall10` / sysent.** `findNosys()` matched an unrelated tiny
    `mov w0,#0x4e; ret` stub; the real `_nosys` is a large handler the sysent rows
    actually point to (112/558 entries). Rewrote `findSysentTable()` to find the table
    STRUCTURALLY (no `_nosys` dependency): the longest run of valid 24-byte `sysent`
    rows (chained auth-rebase `sy_call` into __TEXT_EXEC + sane
    `sy_return_type/sy_narg/sy_arg_bytes`). Base @ foff `0x7693B0` (558 rows);
    `sysent[439]` (`SYS_kas_info`) @ foff `0x76BCD8`; cave + 3 entry writes emit.

## The cryptex merge stops shelling out (2026-09-23)

Eleven subprocess call sites in `CryptexFilesystemPatcher*` were doing work this
process can do directly. Two of them changed what lands on the volume, so they are
recorded here rather than only in the commit.

**`tar` → `VPhoneArchive`.** The last three `runProcess("/usr/bin/tar", …)` calls in
the package are gone: `cfw_input.tar.zst` into the scratch directory, `iosbinpack64.tar`
and the former `AppleParavirtGPUMetalIOGPUFamily.tar` onto the mounted volume. Those three used
`VPhoneArchiveExtractor` with the `.ontoGuestVolume` preset, so `--zstd` was no longer
passed (the filter is detected, and libzstd is static in the xcframework).

- **Behaviour change:** `.ontoGuestVolume` includes `--no-overwrite-dir`, which the two
  guest-volume `tar` calls did *not* pass — they passed only `--preserve-permissions`.
  Directories that iosbinpack64 and the GPU bundle shared with the system volume kept
  their own mode, owner and mtime instead of taking the archive's. That is what
  `cfw_install.sh` had always passed GNU tar (`--preserve-permissions --no-overwrite-dir`);
  the Swift port dropped the second flag, and that restored shell parity at the time.
- Ownership and exact modes are unchanged: the step runs as root, where `/usr/bin/tar -xf`
  already implied `-p` and restored numeric owners. That is why the scratch-directory
  extraction also used `.ontoGuestVolume` despite the name — the preset is what bsdtar
  did as root, and several of those members were copied onto the volume verbatim.

## GPU bundle now comes from the selected PCC image (2026-09-24)

The application no longer ships `AppleParavirtGPUMetalIOGPUFamily.tar`. During
`fw prepare`, `vphone-cli` creates a temporary PV=3 VM, boots it in DFU, and
restores the selected cloudOS IPSW through its own `VPhoneRestoreBridge`. The
preparer copies `AppleParavirtGPUMetalIOGPUFamily.bundle` from the sealed System
volume into the VM restore tree and removes the temporary VM. This is the
default path; `--gpu-driver-bundle` reuses a validated bundle instead. Both
cloudOS 26.1 and 26.4 PCC AEA key URLs returned HTTP 403 on 2026-09-24, so
the preparer no longer requests those keys before the temporary restore.
The temporary VM has no network device (2026-10-13): the restore runs over
the virtual USB device, and with the default `nat` NIC the Mac's shared vmnet
network and DHCP service came up for some seconds after the restore.
Both the JB host-mount installer and the filesystem merge copy this staged
bundle into the iPhone guest. The 26.4 `23E5207q` restored bundle has
`DTPlatformVersion=26.4`, `CFBundleVersion=64.4.4`, and binary SHA-256
`29ba36c7bc87d82c40fa1cecdf357e7a383fa70eb46df0d75869f5ac562aedbc`.
It lacks the compiler-plugin dylib present in the 26.1 bundle. A first boot
without it connected vphoned but left the VM window black: `MTLCompilerService`
repeatedly aborted in `messageHandler`, and `backboardd` reported
`XPC_ERROR_CONNECTION_INTERRUPTED` after repeated Metal compilation attempts.
The repository now builds `Siblings/GraphicLoader/main.mm` (the 0xjohnnydev compiler
plugin reimplementation) into an arm64e iPhoneOS dylib. `build.sh` signs and
compresses it into `vphone-cli.app/Contents/Resources/gpu/compiler-plugin.tar.zst`.
`fw prepare` decompresses and merges that dylib into the firmware-sourced GPU
bundle, and both JB installation paths require it. This adds a guest payload;
it does not patch the Apple GPU driver binary.

**`find -name '._*' -delete` → `deleteAppleDoubleFiles`,** and this one was nearly a
silent regression worth writing down. On a volume with native extended attributes,
**Foundation does not show `._*` entries at all**: `FileManager.contentsOfDirectory` and
`enumerator(at:)` both omit them, because Foundation reads such a name as the partner
file's metadata rather than as a file. `fileExists(atPath:)` compounds it by answering
*true* for a `._x` that is not in the directory. Measured on APFS:

| how the file was made | in `readdir` | in `contentsOfDirectory` |
|---|---|---|
| `open(2)` (what tar and libarchive do) | yes | **no** |
| `Data.write(to:)` / `FileManager.createFile` | **no** — folded into the partner's xattrs | no |

So the first port of this sweep — a `FileManager.enumerator` walk — found nothing,
deleted nothing and reported success, on exactly the files it exists to remove. The
shipped version walks with `opendir`/`readdir` and removes with `unlink(2)`, which is
what `find` did. `chownRecursively` shares that walk for the same reason. Both are
covered by `Tests/FirmwarePatcherTests/CryptexFileOpsTests.swift`, whose fixtures are
made with `open(2)` and asserted with `readdir` — a Foundation-built fixture would make
the test pass by having nothing to find.

**The rest are like-for-like:** `chmod` → `FileManager.setAttributes`, `chown -R 0:0` →
`lchown` over that walk (BSD `chown -R` defaults to `-P`, so symlinks are not followed),
`ln -sf` → `createSymbolicLink` after removing what was there, with the one deliberate
difference that a real directory in the link's place is now an error instead of ln(1)'s
silent nested link. `diskutil image resize --plist | plutil -extract max raw` loses the
shell and `plutil`: the plist is parsed in-process, starting at `<?xml` so that a warning
on diskutil's merged stderr can no longer be handed back as the `--size` argument.

## iOS 26.4 location delivery uses an app hook (2026-09-25)

The guest's locationd accepts simulation requests but did not deliver a usable
fused fix to Maps. This change adds no Apple binary patch. SystemHook loads
`libvlocation.dylib` into app processes, where it supplies the vphoned-published
coordinate through `CLLocationManager` for authorized clients. The location
state is an atomically replaced JSON file, and removal restores the native
path. Maps showed the Tokyo and Apple Park coordinates in the running 26.4 VM;
the automatic SystemHook injection path was verified after relaunching Maps.

**Removed (2026-09-28).** The hook worked around a symptom of the former EXP
patches (issue #438), which `standard` now leaves off; see the note at the top.
SystemHook no longer loads `libvlocation.dylib`, the bundle no longer ships it,
and vphoned's `location.*` methods call IcliKit directly again. A guest that
already has `/usr/lib/libvlocation.dylib` keeps the file, but nothing loads it.

## `fw patch` re-patches the originals, not its own output (2026-09-30)

No new Apple binary patch. This changes how every boot-chain patch in this
document is applied, so it is recorded here.

**The defect.** `FirmwarePipeline` patched each component in place: load the
file, run the patchers, save over the same path. Run `fw patch` a second time on
the same VM and the patchers were handed the first run's output, found none of
the shapes they had already replaced, and the component failed —
`Patch site not found: iBSS`, taking the whole run down at the second component.
`fw prepare` refuses to re-extract over an existing restore tree
("A restore tree already exists at …. Remove it, then prepare the firmware
again."), so there was no recovery path either: a VM could be patched exactly
once, for its whole life. Editing a VM's `PatchSelection.plist` to turn a patch
off and re-running was therefore impossible, which is why the only way to test a
preset change was to build a new machine, and why hand-editing the recorded
`PatchPlan.plist` was being used to get around it.

**Not the same defect as issue #532's second failure.** That one was a single
patcher, `DyldSharedCacheMISTrustAuthPatcher`, not recognising its own post-patch
shape on 27.0 — a DSC patcher, over a cache `cfw install` handles, fixed on
2026-09-30 by teaching `locateSite` the `pacibsp ; mov x0,#0 ; retab` form (see
row 17). This one is structural and sits above every boot-chain patcher: it
would bite even if each patcher were perfectly self-recognising, because nothing
kept the bytes they were meant to match against.

**The fix.** `FirmwarePipelineOriginals.swift`. The first run copies each
boot-chain file into `<vmDirectory>/FirmwareOriginals/`, mirroring its path
under the VM bundle, before anything is written; every later run loads from that
copy. `fw patch` is idempotent by construction — same VM, same plan, same bytes
on disk however many times it runs — and the pristine container is also put back
immediately before `loader.save`, because `ContainerFirmwareLoader.save`
repackages the IM4P it finds at the destination and would otherwise wrap the
second run's payload in the first run's container.

The stash is a direct child of the VM directory and never of the restore tree,
so `findRestoreDirectory` (which matches a directory *name* containing
"Restore") and the component globs (rooted at the restore tree, or
non-recursive in the VM root) cannot resolve a component to its own copy.

**Turning a patch off now reverts it.** When the resolved plan selects nothing
for a component — either every patch blocked, or the whole patch set dropped so
no patcher is built at all — the unpatched image is copied back. A component
nobody has ever patched is not rewritten, so its modification date stays where
the restore left it.

**Two components opt out** (`restorable: false`): `Filesystem`
(`CryptexFilesystemPatcher`) and `Manifest` (`ManifestHashPatcher`). Both name
`BuildManifest.plist`, but neither is a patcher over that one file — the first
rewrites cryptex images across the restore tree, the second rewrites hashes that
describe files other steps produced. Restoring the manifest alone would describe
a tree that no longer exists. Both run only for the `minimal` preset (see "The `minimal`
preset" below), which names no boot chain, kernel or TXM set: a `minimal` run over
a CFW-patched VM puts that boot chain back, which is what the restore image
expects.

**Existing VMs.** A machine patched by an earlier build has no stash, so the
first run under the new code would adopt its already-patched bytes as the
"original". That case is detected rather than accepted: if the component then
fails to patch, the copy is deleted — so it never becomes the baseline — and the
error says the VM was patched by a build that kept no originals and that the
restore tree must be removed and `fw prepare` re-run. Only `patchSiteNotFound` is
rewritten this way; every other failure means what it says and passes through.

Covered by `FirmwarePatcherTests/Pipeline/FirmwarePipelineOriginalsTests.swift`
(7 tests), which drives `patchComponents` over a synthetic component whose
patcher flips one byte and — like every real patcher — reports no site once that
byte is flipped. The real boot chain needs firmware fixtures that are not in the
repository. The same harness with `restorable: false` reproduces the old
failure, so the test for the fix and the test for the defect differ only in the
descriptor.

## The MIS online-authorization patch leaves `standard` (2026-09-30)

No new Apple binary patch. Row 17 (`mis_trust_auth`) is now **off by default**
and renamed `dyld-cfw-mis_trust_auth` → **`dyld-exp-mis_trust_auth`**, which the
naming rule requires: `effect` is `exp` for a patch `standard` leaves off.
Renamed with it: `DyldSharedCacheMISTrustAuthPatcher.patchID` and the
`on(...)` gate in `VPhoneCustomFirmwareInstaller`. The `cfw patch-mis-trust-auth`
verb and the patcher itself are unchanged and still work when the patch is
ticked on.

**What forced it.** On a *pristine* 24A435 cache — `iPhone17,3_27.0_24A435` +
cloudOS `26.4-23E5207q`, first `cfw install` on a fresh VM — the patcher cannot
find its site at all:

    Error: Patch site not found: checkTrustAndAuthorization: the prologue at
    0x22406F814 neither seeds 0xE8008026 nor already reads
    `pacibsp ; mov x0, #0 ; retab` — MIS has been rewritten

and `cfw install` dies there, after the lockdown-mode patch and before
everything that follows. The cache really was pristine: the same log shows a
first-time `maxSlide 0x20000000 -> 0x0` and fresh writes from the lsd, libxpc
and lockdown-mode patchers. So this is **not** the already-patched-anchor case
fixed earlier the same day for 26.x — 24A435's `checkTrustAndAuthorization`
genuinely matches neither shape `locateSite` accepts.

**And the message was wrong.** MIS has *not* been rewritten. Measured on the
pristine 24A435 SystemOS cryptex (`043-70113-702.dmg.aea`, decrypted with
`fw aea-key` + `/usr/bin/aea` and mounted read-only; `cfw patch-mis-trust-auth
--dry-run` against it reproduces the failure verbatim, same VMA):

| | 26.6.2 | 24A435 |
|---|---|---|
| function | `0x1BC6AE364` | `0x22406F814` |
| seed | `mov w21, #0x8026 ; movk w21, #0xe800, lsl #16` @ `+0x4C` | `mov w23, #0x8001 ; movk w23, #0xe800, lsl #16` @ `+0x34` |
| reaches `0xE8008026` | seeded directly, **subtracts** down (`sub w21, w21, #0x2` → `…8024`) | **adds** up, `add w26, w23, #0x25` @ `+0x124` |
| return register | `w21` (the seeded one) | `w26` (derived) |

A whole-image decode of `libmis` (94,984 instructions, `0x224060000`–`0x2240BCC23`)
finds **zero** mov-family instructions with immediate `0x8026` and **zero** raw
`0xE8008026` words: on 24A435 the constant is never written literally at all.
Everything else is as the patcher expects — the naming literal at `0x2240BCC23`
occurs once, has exactly one adrp+add reference (`0x22406FB1C`) and that
reference is inside the function; the nearest preceding `pacibsp` is the
function start itself, and the instruction before it is an unconditional `b`.
So the location routes were right and only `findSeededError` missed.

`findSeededError` now accepts both, and the two are not interchangeable. The
`0x8026` low half stands on its own. The `0x8001` low half is only the bottom of
the MIS error range and proves nothing by itself, so it is accepted only when
the same function also contains an `add w<result>, w<seed>, #imm` that
arithmetically equals `0xE8008026`; the scan stops at the next function's
`pacibsp`. That corroboration is not decoration: the function *preceding*
`checkTrustAndAuthorization` on 24A435 carries the identical
`mov w8, #0x8001 ; movk w8, #0xe800` idiom 18 instructions earlier, which is
also why the seed window stays forward-only from the function start. Matching is
on Capstone-decoded immediates and registers throughout, and nothing new is
written, so no new encoder and no keystone trip.

**A version gate went on the declaration with it.** `experimental` is
`Kind = All`, so without one it would still turn this patch on for a 27 guest
and produce an unbootable VM — and after the matcher fix it would now succeed in
doing so. `applicability` is `iOSBase: .oneOf([.major(18), .major(26)])`. That
is not a preference (a preference belongs in a preset's block list, and
`standard` blocks it too) but the statement `applicability` exists for: applying
it on 27 breaks the guest. An unreadable base satisfies only `.any`, so an
unknown release skips the patch, which is the safe direction.

**Why teaching the patcher the new shape is not, by itself, the answer.** Even
when it applies, this patch stops an iOS 27 guest booting (issue #532:
`TXM [Error]: Errno: selector: 45 | 78` → `dyld[1]: Library not loaded:
/usr/lib/libSystem.B.dylib … (no such file, no dyld cache)` → `initproc failed
to start`). Making it apply on 24A435 without also taking it out of `standard`
would have converted a failed install into a guest that installs and then does
not boot. Both were done, in that order.

**VERIFIED (2026-09-30):** with the patch out of `standard`, `cfw install
test-27.0` completes, and `iPhone17,3_27.0_24A435` + cloudOS `26.4-23E5207q`
**boots clean** — `panicked: false`, vphoned answering 6s after launch,
SpringBoard running (pid 36), `apps.list` returning 264 apps. **Issue #532 is
closed**, and its cause is confirmed to have been this patch rather than
anything else in the 27 install.

**What replaced it.** `libmisfix.dylib` already reaches the same outcome from
userspace, and by the better route — it steers the call rather than forging the
return. `vpWidenedOptions` in `VPhoneGuestComponents/MISFix/MISFixSignature.c`
sets `RespectUppTrustAndAuthorization = kCFBooleanFalse` in the options
dictionary; libmis calls `checkTrustAndAuthorization` only when that flag is
set, so `0xE8008026` is never produced, and because the ordinary success path
still runs, the `info` dictionary (`CdHash`, `Entitlements`, `SignerType`,
`TeamID`, `SigningID`, `ProfileUUID`) is filled for real. No cache page is
written and nothing is re-attested, so there is nothing for TXM to reject.

**The gap this leaves, stated plainly.** `cfw install` injects `libmisfix.dylib`
into `installd` and `misagent` only, so the hook covers *installation*. An app
signed with a **free personal-team** certificate is launched by SpringBoard,
which asks MIS itself and is not hooked, so on a 26.x base that launch can still
hit `0xE8008026` — a regression against the 2026-09-30 on-device validation of
row 17 on 26.6.2. Ad-hoc / `ldid`-signed apps are unaffected either way: they
carry no provisioning profile, so the online-authorization branch is not
reached, and `AllowAdHocSigning` is what they need. Paid-team profiles were
never affected. Closing the SpringBoard gap means injecting the same hook there,
which cannot be done with a load command (SpringBoard's load-command padding at
`0x548` is not free — inserting would overwrite 56 bytes of the first section)
and so has to go through SystemHook's `posix_spawn` interposition.

**Effect on the shipped presets.** `standard` adds `dyld-exp-mis_trust_auth` to
its block list, mirrored in `FirmwarePatchSetCatalog.manualOnlyPatches` via the
new `FirmwarePatchSetCatalog.misTrustAuthPatch`; `The shipped preset plists match
the built-in copies` checks the two agree. `experimental` is `Kind = All` and so
still turns it on, which is correct: that preset is documented as everything the
bundle declares, including patches a 26.4 guest does not survive.

## An interpose does not cross the shared cache (2026-09-30)

**This supersedes the paragraph above that says the hook "covers
*installation*".** It does not. `libmisfix.dylib` reaches misagent and nothing
else that matters, and no version of it can reach installd, because
`__DATA,__interpose` replaces **call sites** in the images dyld links and every
call site on installd's path is inside the cache:

```
MobileInstallation.framework  →  libmis.dylib        (cache to cache)
libmis.dylib                  →  libMobileGestalt    (cache to cache)
```

Measured on test-26.4, `libmisfix[726]`, with `LogQueries` on, the query log
carrying each caller's image (`MISFixCallerImage`, `dladdr` on the return
address) and the validation log made unconditional. One
`devicectl device install app` of a paid-team-signed AirBuild.app produced
exactly one line from installd:

```
libmisfix[726]: MGCopyAnswer(BuildVersion) from installd passed through
```

`from installd` is the finding: the only call the hook catches is the one the
**main executable** makes itself. misagent works for that reason and no other —
its own binary calls `MGCopyAnswer`, three times per install, each answered
`-> override`.

What installd did instead, in the same capture:

```
amfi_interface_query_bootarg_state returned error Function not implemented
cdhash: <private> is trusted
Trust evaluate failure: [leaf IssuerCommonName LeafMarkerOid SubjectCommonName]
Skipping a profile because of error 0xe8008012.
+[MICodeSigningVerifier _validateSignatureAndCopyInfoForURL:withOptions:error:]:
    80: Failed to verify code signature of …/AirBuild.app : 0xe8008015
```

Three things follow, and each corrects something previously written here:

1. **The signature was never the problem.** `cdhash … is trusted`. The failure
   is the profile: libmis walked the installed profiles and skipped every one
   with `0xE8008012` — this device is not in `ProvisionedDevices` — leaving
   `0xE8008015`, "a valid provisioning profile for this executable was not
   found".
2. **libmis resolved a UDID without going through the interpose.** No
   `MGCopyAnswer(UniqueDeviceID)` line exists from installd, yet the comparison
   plainly happened. Its other route is closed —
   `amfi_interface_query_bootarg_state` returns `ENOSYS`, so the
   `amfi_emulate_device_udid` path libmis prefers is dead on this guest and the
   MobileGestalt fallback is what ran.
3. **`AllowAdHocSigning` has never taken effect in installd.** No
   `MISValidateSignatureAndCopyInfo` line appears either, from a log that no
   longer returns early on an unconvertible path argument. `MICodeSigningVerifier`
   lives in MobileInstallation, not in installd, so that call is cache-to-cache
   too. The measured table at the top of `MISFixSignature.c` was taken by
   calling libmis directly; it is still true of libmis and was never reached
   through installd.

`DYLD_INSERT_LIBRARIES` does not change this. Commit `d44a0e9` had already
moved libmisfix from a `LC_LOAD_WEAK_DYLIB` of installd to SystemHook's insert
list, which is the strongest position an interpose can hold, and the capture
above is from that arrangement.

**What can still work.** Three routes, in the order they were judged:

- **Rewrite the callee, not the call sites.** A detour at the top of
  `MGCopyAnswer` and `MISValidateSignatureAndCopyInfo` is reached by every
  caller, cache-internal or not. It stays a guest dylib, so
  `cfw update-environment` deploys it to an existing VM and no cache page is
  written — nothing for TXM to reject, which is what makes it preferable to a
  new libmis patch after #532. It needs the process to make a cache text page
  writable (copy-on-write) and to obtain executable memory for the trampoline;
  `MISFixCacheWriteProbe.c` measures both behind `ProbeCacheWrite`, in installd
  only.
- **A shared-cache patch on libmis**, forcing the `ProvisionedDevices` check to
  pass and the ad-hoc option on. Same family as row 17, so the same risk: row 17
  is the patch that stopped a 27.0 guest booting.
- **Give the VM the right UDID instead of lying about it.** A modern UDID is
  `<chip-id>-<ECID>`; `chip-id` is fixed at `0x0000FE01` by the virtual SoC but
  the ECID is chosen at `vm create`, and the SHSH blob is personalised against
  it either way. A VM created with the ECID of a device the team has already
  registered needs no hook at all. It does not help an ad-hoc IPA, which has no
  profile to match.

**A mistake in the first probe, recorded because it is easy to repeat.** dyld
applies interposing to `dlsym` as well as to call sites, so
`dlsym(RTLD_DEFAULT, "MGCopyAnswer")` returns *libmisfix's own replacement* —
the probe measured its own text and never touched the cache. It then asked for
`VM_PROT_WRITE` in place of `VM_PROT_EXECUTE` on the page it was executing
from, which faults on the next instruction fetch and crash-looped installd
until the flag was cleared.

A handle-scoped `dlsym` is interposed too — measured, on a handle to
libMobileGestalt itself — so there is no spelling of `dlsym` that answers this.
What dyld leaves alone is the interposing image's own imports, which is why
`MISFixDetour` takes an address that libmisfix obtained with `&`, and refuses
to take a name at all.

## An Xcode install works, and what it took (2026-09-30)

Measured on test-26.4, `xcrun devicectl device install app` with
`AirBuild-Debug.ipa` — a paid team's app (`QDJ93ZUQ9B`), signed
`Apple Development`, whose embedded profile provisions eight real devices and
no VM:

```
App installed:
• bundleID: plus.yellow.AirBuild
• installationURL: file:///private/var/containers/Bundle/Application/9A626C1C-…/AirBuild.app/
```

and it launches. So does a `codesign --sign -` bundle with no certificate and
no profile at all. Four separate refusals had to go, in this order, and each
one was only visible once the one before it was gone.

1. **The interpose never ran.** Replaced by `MISFixDetour`: a four-word
   absolute jump at the top of the callee, the displaced instructions
   relocated onto an `mmap`ed trampoline, the target page taken
   copy-on-write. Installed in installd's own address space, so nothing on
   disk and no other process changes — which is the whole difference between
   this and row 17, the libmis cache patch that stopped a 27.0 guest booting.
   Measured: `detour: MISValidateSignatureAndCopyInfoWithProgress at
   0x1bf41c830 in libmis.dylib`.

   `MISValidateSignatureAndCopyInfo` itself is a thunk in front of the
   `…WithProgress` body, shorter than the jump, and `MISFixDetour` refuses it
   with `MISFixDetourTooShort` rather than write over whatever follows. Its
   callers are covered anyway, because it branches into the hooked function.

2. **`0xE8008015`, no valid profile.** Widening the options does not help a
   CMS-signed app: `AllowAdHocSigning` is about ad-hoc signatures, and this one
   is real. The profile has to actually install, and misagent refuses it
   because a VM's UDID is in no `ProvisionedDevices`. misagent asks
   `MISProfileGetValue(profile, "ProvisionsAllDevices")` *first* and only
   consults the device list when that is false — so `MISFixProfileScope.c`
   detours `MISProfileGetValue` and answers that one key `true`. The profile
   then installs for real and MIS validates the app against it:

   ```
   misagent: Installing provisioning profile: 50806e9b-…
   MISValidateSignature(…/extracted/Payload/AirBuild.app) -> 0x0
     info[SigningID] = plus.yellow.AirBuild   info[TeamID] = QDJ93ZUQ9B
     info[SignerCertificate] = <1484 bytes>   info[Entitlements] = <7 entries>
     info[ValidatedByProfile] = true          info[SignerType] = 3
   ```

   Nothing is faked: the signature, the certificate, the entitlements and the
   cdhash are the ones Apple issued. The only claim widened is which devices
   the profile covers.

3. **`0xE8008012` from `-[MIInstallableBundle _installEmbeddedProfilesWithError:]`.**
   Kept as a backstop for a profile that still cannot install, in
   `MISFixInstallPolicy.c`: the real implementation runs, and a refusal is
   logged and turned into "there is no profile" rather than a failed install.

4. **`-[MICodeSigningVerifier performValidationWithError:]`, line 424, "Failed
   to extract signer identity".** The gate behind the gate, and the one that
   stops an ad-hoc signature: MIS accepts the bundle and MobileInstallation
   then wants a CMS leaf certificate out of it, which `codesign --sign -`
   does not produce.

   The verifier already knows what to do. It carries `allowAdhocSigning` as a
   settable property — the same shape as the MIS option — and installd never
   turns it on, so `MISFixInstallPolicy.c` forces the getter. The real
   validation then succeeds and fills `signingInfo` for real.

Both Objective-C hooks are swizzles, not detours. A method list is data, so
replacing an implementation reaches every caller without making any cache text
writable; where that is available it is strictly better.

### The dead end that proved the shape of the fix

Before `allowAdhocSigning` was found, `performValidationWithError:` was forced
to return `YES` after it had failed. That got no further:

```
-[MIExecutableBundle codeSigningInfoByValidatingResources:…]: 1306:
    Code signing identifier ((null)) does not match bundle identifier (wiki.qaq.vphone.signtest)
```

The verifier had bailed before storing anything, so its caller read a nil
signing identifier. A refusal can be allowed through; an answer that was never
computed cannot be invented. The override was removed once the property made
it unnecessary, and the rule generalises to every gate above MIS.

The class's interface came from the runtime, not from a disassembly:
`class_copyMethodList` and `class_copyIvarList` printed into the note log.
`MISFixInstallPolicy.c` still does that, but only when a selector it expects
has gone, which is the one moment the list earns its few hundred lines.

### Still refused, deliberately

A bundle with no signature at all (`0xE800801C`) and an app with no
`application-identifier` entitlement (`MIInstallerErrorDomain` 63). Both are
real absences rather than policy, and everything downstream needs what they
are missing. Unsigned bundles reach the guest through vphoned's
`apps.install`, which re-signs in the container and never involves installd.

### A trap in the measurement, not in the guest

Two runs failed with `0xE8008017` on a bundle whose signature was fine. The
IPA had been repacked on the host with `zip -r`, which writes AppleDouble
`._*` files next to every resource; they break the sealed resource envelope.
`COPYFILE_DISABLE=1 zip -X` after deleting them, and the same bundle installs.
Worth remembering before reading `0xE8008017` as a guest-side gate.

## One route for libmisfix, SpringBoard included (2026-09-30)

Row 20. On test-27.0 (`iPhone17,3 27.0 (24A435)`) a paid team's IPA installed
through installd — `ValidatedByProfile = true` — and was then refused at
launch with "Unable to Verify App":

```
SpringBoard[36]: Trust evaluate failure: [leaf IssuerCommonName LeafMarkerOid SubjectCommonName]
SpringBoard[36]: validation failed because of missing trust and/or authorization (0xe8008026)
```

That is row 17's failure, raised by SpringBoard's own launch-time call into
libmis. libmisfix already declines that check — `RespectUppTrustAndAuthorization
= false` in `MISFixSignature.c` — but SpringBoard never carried it.

**Why 26.4 looked fine.** test-26.4's `PatchPlan.plist` was written before
`dyld-exp-mis_trust_auth` left `standard`, so that guest's cache still carried
row 17 and SpringBoard's check was short-circuited there. 24A435 is outside
row 17's gate, so 27.0 was the first guest where the launch depended on the
hook. SpringBoard is started the same way on both, below.

### The first fix was a load command, and it was built on a misreading

The first commit (7a41371) linked libmisfix into SpringBoard with
`LC_LOAD_WEAK_DYLIB`, as installd and misagent then were. SpringBoard's header
has 16 spare bytes on both 23E246 and 24A435 (`sizeofcmds` 1336, first section
at 1384), so that needed a `/mf` root alias and an `inject-dylib
--reclaim-source-version` that dropped `LC_SOURCE_VERSION` to leave the signer
room. It worked — AirBuild launched on test-27.0 after a cold boot — and it
was reverted the same day, because the reason given for it was wrong.

It rested on "SpringBoard does not carry SystemHook", read off
`vphone-systemhook.log`: SystemHook's constructor writes a line for any
`.app/` executable and SpringBoard's never appeared. That log cannot show it.
The first writer is always a root xpcproxy, which creates the file 0644, and
every later line from a mobile process is dropped silently. The only `.app/`
lines in it came from DeviceOMatic, which runs as root. SignTest, a sandboxed
mobile app with no line either, has `/usr/lib/SystemHook-vphone.dylib` in the
`usedImages` of its own crash report.

### What SpringBoard actually carries

A temporary probe in libmisfix read each process's `KERN_PROCARGS2` — the
environment the kernel copied at exec, which survives dyld pruning a variable
it refuses — alongside `environ`, `dlopen(RTLD_NOLOAD)` of SystemHook and
`amfi_check_dyld_policy_self`. On test-27.0:

| Process | `DYLD_INSERT_LIBRARIES` at exec | SystemHook | dyld policy |
| --- | --- | --- | --- |
| SpringBoard, boot (pid 36) and respawned | `SystemHook-vphone.dylib` | present | `0x17f` |
| installd, misagent | `SystemHook-vphone.dylib:libmisfix.dylib` | present | `0x17f` |

So the chain works in SpringBoard; what it lacked was the second entry. Which
libraries to insert is decided in the **parent**, at the spawn. installd and
misagent are started through xpcproxy, whose SystemHook asks
`vpIsMISFixTarget`. SpringBoard's job is `POSIXSpawnType` App and launchd
starts it itself — the launchd hook's spawn log has every neighbouring
xpcproxy child but not SpringBoard's pid — and the launchd hook inserted
SystemHook alone. SystemHook's list naming SpringBoard was never consulted for
it. The `_Conclave` key on SpringBoard's job turned out to be irrelevant.

### One route for libmisfix

- `vpIsMISFixTarget` and `vpMISFixFor` moved to
  `Shared/InjectionEnvironment.h`, and the launchd hook asks them as
  SystemHook does. A target gets `VP_MIS_FIX` inserted beside SystemHook
  whichever process starts it, and only when `/usr/lib/libmisfix.dylib`
  exists, so a guest without it never names a missing library.
- `vpInsertHooks` had a latent bug on that path: with SystemHook already in
  the environment and only the extra library to add, it built the new
  `DYLD_INSERT_LIBRARIES` and then discarded it, because substitution was
  keyed on `addHook` alone. xpcproxy rebuilds its child's environment, so it
  never showed. `make test-injection-environment` covers it.
- No guest binary carries a load command for libmisfix. The declarations
  `system-installd-cfw-adhoc_signature`, `system-misagent-cfw-device_identity`
  and `system-springboard-cfw-launch_authorization` are gone — rows 18–20
  below describe what they were — and `cfw install` renames each `.bak` an
  earlier install left back over the patched binary and removes `/mf`. The
  SystemHook route inserted libmisfix into installd and misagent regardless of
  those declarations, so unticking one never turned the hook off; libmisfix now
  ships with `system-launchdaemons-boot-environment` like the other hooks.
- `inject-dylib --reclaim-source-version` and its test were removed with the
  only caller that needed them.
- SystemHook's logs are opened 0666 and `fchmod`ed on each open, so the owner
  widens a file an earlier root writer created. Sandboxed processes still
  cannot reach `/var/mobile/Library/Caches`; their absence from the log means
  nothing, and a crash report's `usedImages` is the check.

Inside SpringBoard libmisfix installs the MIS detours only:
`MISFixInstallPolicy.c` returns at once outside installd, so MobileInstallation
is never loaded into SpringBoard or misagent to be swizzled. SpringBoard is
not in vphoned's `udidHookedDaemons`: it never asks for the UDID, and stopping
it restarts the home screen.

**Validated with the insertion, on fresh VMs (2026-09-30).** test-26.4
(`iPhone17,3 26.4 (23E246)`) and test-27.0 (`27.0 (24A435)`), both on cloudOS
26.4 (23E5207q), deleted and recreated from local IPSWs with `vm create` and
this `cfw install`, so no binary on either ever carried a libmisfix load
command. On both, from the first boot:

```
launchdhook: event=inserted+misfix child=36 path=/System/Library/CoreServices/SpringBoard.app/SpringBoard
libmisfix[36]:  env at exec has DYLD_INSERT_LIBRARIES=/usr/lib/SystemHook-vphone.dylib:/usr/lib/libmisfix.dylib
libmisfix[253]: (misagent) the same; installd the same, with its MISValidate… detour in place
```

SpringBoard's lines now appear in `vphone-systemhook.log` too. No new `.ips`
from SpringBoard, installd or misagent. AirBuild installed through installd
(`ideviceinstaller`) opens on both. The one `panic-full` on each guest is the
post-restore reboot `vm create` makes before `cfw install` has put the dyld
cache in place (`initproc failed to start … libSystem.B.dylib`), not a boot of
the installed guest.

**Validated first with the load command, on test-27.0 (2026-09-30).**

```
libmisfix[36]: loaded into /System/Library/CoreServices/SpringBoard.app/SpringBoard
libmisfix[36]: detour: MISValidateSignatureAndCopyInfoWithProgress at 0x22406d13c in libmis.dylib
libmisfix[36]: MISValidateSignature(…/AirBuild.app) -> 0x0
apps.launch plus.yellow.AirBuild -> {"frontmost_verified":true,"pid":375}
```

after a cold `vm stop` / `vm start`: SpringBoard reaches the home screen,
carries libmisfix from boot, no new `.ips` from SpringBoard, installd or
misagent, and AirBuild — a paid team's dev-signed IPA installed through
installd — opens to its own sign-in screen instead of "Unable to Verify App".
trustd still logs `Trust evaluate failure: [leaf IssuerCommonName LeafMarkerOid
SubjectCommonName]`; that evaluation is what `checkTrustAndAuthorization`
consumes, and it is no longer asked.

## The host is told the configured UDID (2026-09-30)

No binary change. `vpIsMISFixTarget` (`VPhoneGuestComponents/Shared/InjectionEnvironment.h`)
adds `lockdownd` and `remoted`, so both spawn hooks insert `libmisfix.dylib`
into them. There only the MobileGestalt interpose acts:
`MISFixProcessOnlyNeedsIdentity` keeps the two MIS detours out of their copy of
libmis. lockdownd then answers `GetValue UniqueDeviceID`, and remoted puts in
the RSD handshake, the UDID set through `udid.set`. The hook now also matches
the obfuscated key remoted asks with (`re6Zb+zwFKJNlkQTUeT+/w`), and declares
`MGCopyAnswerWithError` with its real three arguments; the two-argument
prototype crashed remoted.

The third place the host reads the UDID, the USB serial string, is set by
vphoned (`VPhoneDaemon/Native/vphoned_usb.m`, entitlement
`com.apple.private.usbdevice.setdescription`), not by a patch.

Validated on test-27.0: `idevice_id`, lockdown and `remotectl show` report the
override after `udid.set` and after a reboot, and the guest's own after
`udid.clear`. Details and the measurements are in
`Research/Guest/xcode_install_signature_gate.md`, "The host sees it too".

## vphoned launchd service entitlements (2026-10-20)

`VPhoneDaemon.entitlements` adds `com.apple.private.xpc.service-configure`
and `com.apple.private.xpc.service-attach` (true) for `services.kickstart`.
icli 0.9.1's device regression on iOS 27.0.1 guests found that launchd
refuses kickstart with status 144 unless the caller holds both; icli's own
binary carries them, and a library consumer such as vphoned has to sign
with them itself. Not yet observed on a guest with vphoned:
`services.stop` and `unload` were answered 144 without service-configure,
so whether they now succeed is unverified, and the notes that say so
(`Research/Guest/service_trimming.md`, `GuestServiceProfile`) are left as
they are until a guest shows otherwise.

## vphoned accessibility client entitlements (2026-09-30)

`VPhoneDaemon.entitlements` adds three true booleans:
`com.apple.private.accessibility.inspection`, `com.apple.accessibility.api`,
and `com.apple.private.accessibility.look-me-up-setup`. All 258 existing
upstream 2.2.3 keys and values are preserved, including the USB entitlement
and keychain access groups. No daemon or AX bootstrap code changes.

**Live evidence is from release 2.1.5, not 2.2.3.** Its actual daemon was
re-signed with only these three additions: all 257 original entitlement
values and all 51 file-backed Mach-O sections were unchanged. Strict code
signature verification, bundle validation, and preflight passed.

With identical fresh application lifecycles, the original daemon's tree
query and its alias failed with `-25215`. The re-signed daemon returned
12 nodes for Settings, 23 for Calculator, and 9 for Clock through both tree
routes, with non-null hit-test results. These results repeated after a
second full host-assisted VM boot.

Warm queries can work after another client initializes AX, so they alone
do not establish fresh-client readiness. The three keys were tested
together; each key's individual necessity was not isolated. Upstream
2.2.3 has passed the profile-preservation assertion but has not been
live-tested with this change.

## Opt-in native accessibility hierarchy (2026-09-30)

The opt-in native bridge behind ui.tree with nested:true follows private iOS
attribute 5001 (immediate children) and checks each edge against attribute 5002
(parent) using CFEqual identity. The existing flat interface continues to use
icli's visible-element query; this bridge does not infer ancestry from frames,
labels, identifiers, or the visible-element array. Primary attribute mappings
are in [MCPAXNodeSource.m](https://github.com/witchan/ios-mcp/blob/8f46b68/MCPAXNodeSource.m)
and [MCPAXAttributeBridge.m](https://github.com/witchan/ios-mcp/blob/8f46b68/MCPAXAttributeBridge.m).

An isolated entitled helper on an iOS 27 research VM returned 176 Settings
nodes with 173 matching parent back-references and 3 mismatches, 44 Calculator
nodes with 42 matches and 1 mismatch, and 66 Clock nodes with 65 matches and
no mismatch. Settings and Calculator are explicitly partial. Tests cover
unnamed, offscreen, zero-frame, and frameless structure; live snapshots preserve
unnamed containers and repeated objects through snapshot-local references.
Node, depth, query, and deadline limits
are explicit, and a missing or failed messaging timeout blocks the AX query.
Foreground PID stayed unchanged and accessibility switches were restored for
each helper run. Temporary services were unloaded and their directories removed.
Helper evidence is not an integrated daemon
release or cold-start readiness claim.

Installed-daemon cold-read testing subsequently exposed an initial Settings
snapshot containing only its unavailable root. The native walker now retries
only the first root label copy with error -25215 when this invocation actually
enabled accessibility, after one 400 ms readiness wait. It shares the original
deadline and query budget, preserves the initial error in readiness metadata,
and retains unresolved errors. No child error or action is retried.

After a supported bundle installation and VM restart, the first Settings
CLI read recovered and returned 220 nodes with 217 matching parent checks and
3 disagreements; subsequent reads returned 176. Fresh Calculator returned
44 partial nodes and Clock 66 complete nodes. Flat queries and the nested
alias also worked. These are diagnostic inspection results on that VM,
not full action-cycle performance acceptance or repeat cold-start reliability.

The Release build also reproduced SIGPIPE failures in bundle validation:
early-exiting grep and awk closed their file/vtool producers under pipefail.
Those probes now drain producer output while keeping matching, first-platform
selection, failure propagation, and all signature checks. The full workspace
build and strict signatures then passed.

## Guest audio: a HAL plugin, and an iPad's own audio node (2026-10-02)

The guest never produced sound, although `vphone-vm` has always attached a
virtio sound device with a host output sink. Two faults; the full reveal is
`Research/Guest/virtio_sound.md`.

| Patch | Component | Effect |
| --- | --- | --- |
| `system-virtiosound-cfw-hal_plugin` (new) | `/System/Library/Audio/Plug-Ins/HAL/VPhoneVirtIOSound.driver`, `cfw install` and `cfw update-environment` | Installs the CoreAudio HAL plugin for `AppleVirtIOSound`, built from `VPhoneGuestComponents/VirtIOSound`. |
| `devicetree-cfw-ipad_audio` (new) | An iPad guest's installed DeviceTree, `fw patch` | Replaces `/product/audio` with the board tree's node (`DeviceTreePatcher.presentBoardAudio`), all properties as the board has them except its `AAPL,phandle`. |
| `preboot-cfw-devicetree_board_audio` (new) | Restored Preboot `devicetree.img4`, `cfw install` and `cfw update-environment` | The same replacement for an iPad VM patched before it (`vphone-cli cfw patch-dt-board-audio`), from the board tree in `FirmwareOriginals`. When that has none (a VM patched before `fw patch` kept it), the tree is first recovered from the VM's IPSW in `~/.vphone/ipsws`, matched by BuildManifest version, build, product type and board, and kept in `FirmwareOriginals`; with no matching IPSW the repair is skipped with one `[!]` line naming the fix. |
| `devicetree-cfw-product_haptics_node` (new, 2026-10-03) | Every guest's DeviceTree, `fw patch`: an iPhone guest's one tree, an iPad guest's installed tree and its `RestoreDeviceTree` | Removes `/product/haptics` (`DeviceTreePatcher.removeHaptics(from:)`), whatever the variant and the board. |
| `preboot-cfw-devicetree_haptics` (new, 2026-10-03) | Restored Preboot `devicetree.img4`, `cfw install` and `cfw update-environment`, every guest | The same removal for a VM patched before it (`vphone-cli cfw patch-dt-haptics`); it needs no board tree. A guest that booted before it keeps cached MobileGestalt answers, which vphoned drops at its next startup, see below. |

`fw patch` now reads an iPad's board tree through the `FirmwareOriginals` stash,
so `DeviceTree.<board>.im4p` stays in the VM folder after the restore tree goes.

**Why the haptics node goes.** vphone600 carries `/product/haptics`
(`closed-loop`, `supports-3rd-party-haptics`). With it MobileGestalt answers
yes to `DeviceSupportsHaptics` and `DeviceSupportsClosedLoopHaptics`,
ToneLibrary sets `playHapticTracks` on every tone, and mediaplaybackd builds a
`CHHapticEngine` whose server, `com.apple.audio.hapticd` in audiomxd, never
answers on a VM: six one-second XPC timeouts, `FigHapticEngineCreate` fails
4099, and `itemfig_rebuildRenderPipelinesAndBoss` fails the item — the
ringtone never starts although its route and audio queue are built. It was
first seen on iPad guests, whose own trees (`DeviceTree.j410ap`, `.j820ap`)
have no such node, and fixed there by making the node follow the board. An
iPhone guest (iPhone99,11, iOS 27.0) then failed the same way — the same
hapticd timeouts, the same 4099, the tone dropped — and a real iPhone's tree
does have the node, so following the board cannot fix it. What is missing is
the actuator and the haptic server, and no VM has either; every guest's tree
loses the node, and the board-following patch and its Preboot repair were
replaced by these two. The restore tree loses it as well: an iPad guest's
`RestoreDeviceTree` is patched exactly as an iPhone guest's tree is, and
restore reads nothing from the node. Without it the guest answers as a device
with no Taptic Engine does and tones play. The answers are cached in
`/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist`,
written at first boot, so a guest that has already booted keeps the old ones
until that file is removed and the guest restarted; a guest created with the
patch never has them. The host cannot remove it: the file is on the guest's
Data volume, a FileVault volume whose keys are in the guest's SEP, which the
host sees locked and cannot mount (the volume the installer mounts beside
System, s3, is xART). vphoned removes it at startup instead, when it is older
than the Preboot `devicetree.img4` the guest booted
(`VPhoneDaemon/Daemon/GuestMobileGestaltCache.swift`): the host rewrites that
tree only with the VM stopped and only when a repair changed it, so an older
cache was worked out from an older tree. It logs `vphoned: MobileGestalt
cache predates the device tree, removed it; …`, and `/v1/health` reports
`mobilegestalt_restart_pending` until the guest restarts, since running
processes keep the answers they read. An existing guest therefore needs `cfw
update-environment`, one boot, and one restart. This is no patch declaration
of its own: it writes nothing to the tree, and with the repairs off the tree
is not rewritten and the cache stays. Removing the file by hand (`files.remove`, then
`system.reboot`) is what vphoned does, less the reboot. Detail and the
measurements: `Research/Guest/virtio_sound.md` §7.

**Why a plugin.** The cloudOS kernel has `AppleVirtIOSound` and its user client,
but only macOS ships the HAL plugin that drives it; neither cloudOS nor any iOS
image has one. `VPhoneVirtIOSound.driver` speaks the same user-client selectors
as the macOS `AppleVirtIOSound.driver`, on AudioServerDriver as Apple's own
plugins are. It is output only. Its host checks are `make -C VPhoneGuestComponents
test-virtiosound`; `Build/ValidateBundle.sh` checks the staged bundle's signature
and factory.

**Why the audio node.** On an iPad guest VirtualAudio never initialized
(`RoutingSettings_J98.cpp:805`, then `:856`, `PRECONDITION FAILURE`), so audiomxd
had no device at all and Safari video would not start. J820's routing code builds
its stereo and webcam microphone sub-ports from the tuning directory the device
tree's `acoustic-id` names. `devicetree-cfw-product_audio_node` gives every guest
the D47 iPhone's node, `acoustic-id = 8018`; the iPhone image ships `AID8018`, the
iPad image ships `AID2028`/`AID2029` (J820's is 2029). Removing the
`stereo-sound-recording` flag was tried first and only moved the failure to the
webcam sub-port, whose flag comes from AVFCapture's per-board table; that attempt
is not in the tree. iPhone guests are unchanged.

**system-virtualaudio-cfw-speaker_route_throws.** The counterweight to the
virtio plugin's `PuffinOutput` masquerade. iOS's speaker-route walker treats
the synthetic speaker's missing protection metadata as fatal six different
ways — five C++ throws out of an AudioServerPlugIn callback (terminate) and
one direct `bl std::terminate` after a fault log — and MediaExperience's
serialization replay hits the first of them on every launch. The patcher
(`FirmwarePatcher/CustomFirmware/ExecutablePatches/VirtualAudio/`) branches
each site to the function's own epilogue: anchored on the exception strings,
shape-matched through Capstone (allocation call, x1 message load, constructor
call, `brk` or branch terminator; the terminate as the last call of the fault
logger's back-to-back `bl` run), never an offset. The installer stage re-seals
the `.plugin` bundle after `patchMachO` re-signs the binary — the outer
CodeResources still named the old bytes, and the code-signing monitor killed
audiomxd on load. Research detail: `Research/Guest/virtualaudio_speaker_route_throws.md`.

## VirtualAudio's mute-set throw — the chime's last blocker (2026-10-03)

`system-virtualaudio-cfw-mute_set_throw` (new), same
`VirtualAudio.plugin` binary, verb `cfw patch-virtualaudio-mute`, applied by
`cfw install` and `cfw update-environment` riding the same `patchMachO`
staged copy as `patch-virtualaudio` — staging restarts from the pristine
`.bak`, so the two verbs must share one call.

**Fault.** Establishing the speaker route asks the HAL device itself to
unmute: `Device_HAL_Common`'s set wrapper pushes `kAudioDevicePropertyMute`
('mute'/'outp'/0) and reads it back. The HAL *server* pre-validates the
device-level set at `HALS_UCPlugIn.cpp:1190` and rejects it 'what'
(2003329396) without ever forwarding the selector to the plugin — proven by a
guest probe whose `hasProperty:` override saw 60 selectors and never 'mute',
while the control-level 'bcvl' set on the same device succeeds (so no
plugin-side fix exists on iOS). The wrapper answers the failure by throwing
`CAException("Unable to set property data.")` out of the callback;
`RoutingManager.cpp:3515` catches it and abandons the route — the aggregate's
master stays `Null_Device`, no `PVMSetCurrentState`, and the boot charge chime
is silent. Every caller ignores the wrapper's return value, so the fix is the
same shape as the walker patch: branch the throw to the wrapper's own
epilogue. The FAIL/EXCEPTION diagnostics still log; the route proceeds.

**Reveal** (all Capstone-decoded, no literal address): anchor on the cstring
containing `Set mute value of %u on HAL device`, referenced exactly once in
`__text`; the wrapper is the enclosing pacibsp-to-pacibsp function. The site
is the wrapper's CAException block — allocation call, vtable/status stores
into `[x0]`/`[x0, #8]`, throw call, `brk` terminator; a CAException carries no
message string, so the walker patch's runtime_error shape does not match, and
the block runs 17 instructions where that scan budgeted 16 (the new scan
budgets 32). Discriminated from iOS 27's second, unrelated CAException (the
deactivated-device throw) by requiring an adrp+add forming a cstring
containing `Unable to set property data.` within 0x40 bytes above the site —
the EXCEPTION log that always precedes this throw. The epilogue is the
wrapper's single `retab` walked back through the shared guarded-canary chain;
it cannot be searched forwards from the throw because the throw sits below
the epilogue, so the retab is enumerated within the wrapper's bounds.
Verified on the real iPadOS 26.6.2 and iOS 27 binaries: exactly one site and
epilogue each (0xee224 → 0xedfcc; 0x111ac8 → 0x11179c), byte-identical
re-runs, and both verbs composing on one copy. Research detail:
`Research/Guest/virtualaudio_speaker_route_throws.md`.

## VirtualAudio's SpeakerProtection chain — the speaker route's last blocker (2026-10-03)

`system-virtualaudio-cfw-speaker_graph_chains` (new), *not* a binary patch:
it rewrites the tuning set's `graph_configurations.plist` on the guest system
volume (`/Library/Audio/Tunings/<acoustic ID>/VAD/`, e.g. `AID2029` for an
iPad Pro 13; the ID varies by board, so `cfw install` and
`cfw update-environment` walk the `Tunings` directory instead of naming one).
Verb `cfw patch-virtualaudio-graph-configurations` on a staged copy, format
preserved (binary in, binary out), idempotent. An image with no tuning sets —
iOS 27's VirtualAudio carries no `graph_configurations.plist` reference at
all — is skipped quietly. Patcher:
`FirmwarePatcher/CustomFirmware/CustomFirmwareVirtualAudioGraphConfigurations.swift`.

**Fault.** With the walker and mute-set throws quieted and
`ProductIDOverride=8010` (the only accepted ProductID whose VAD map covers
`'crnp'`, the RingtonePreview category), the ringtone route change runs its
full pipeline — route list built, aggregate master `PuffinOutput` — and then
dies building the route's DSP chain. `graph_configurations.plist` gives every
`speaker_*` configuration `chainType "clhs"`, and the DSP chain factory
(0x117628, iPadOS 26.6.2) switches on it: `clhs` builds the HAL
SpeakerProtection chain, whose config constructor (0x3dcccc) calls
`findDevice("Speaker")` (0x3dc460) → registry lookup →
`LockWeakPtrOrThrow` throws `Could not lock weak ptr (:60)` — a VM's device
registry has no physical Speaker. The chain is destroyed,
`RoutingManager.cpp:1774` logs `Failed to activate a route list`, the route
change fails `nort` (1852797556), and the guest stays silent with no
fallback. `dflt` — the chainType every `beam_mic_*`/`omni_mic_*`
configuration already ships — takes the generic graph chain instead: no
device lookup, the configuration's `graph` DSP file (which the tuning set
ships for every speaker configuration) is loaded directly. The patch flips
every `speaker_*` entry's `chainType` from `clhs` to `dflt` and touches
nothing else. Static analysis ruled out every null-tolerant patch of
`findDevice` itself: `buildParams` (0x3dc518) dereferences the returned
`Device*` immediately at two call sites (0x3dcda4, 0x1182a4), so a null
return would crash instead of degrade. Research detail:
`Research/Guest/virtualaudio_speaker_route_throws.md`.

## VirtualAudio's speaker-protection gate — the decline after the build (2026-10-03)

`system-virtualaudio-cfw-speaker_protection_gate` (new), same
`VirtualAudio.plugin` binary, verb `cfw patch-virtualaudio-sp-gate`, riding
the same `patchMachO` staged copy as the other two VirtualAudio verbs
(`patch-virtualaudio`, `patch-virtualaudio-mute`) in both `cfw install` and
`cfw update-environment`. Patcher:
`FirmwarePatcher/CustomFirmware/ExecutablePatches/VirtualAudio/CustomFirmwareVirtualAudio.swift`.

**Fault.** With layers 1–3a quieted (walker throws, mute-set throw, plist
chains), the ringtone route change still declines at its last step:
`RoutingHandler_Playback_GenericConfig1.cpp:223` — "HAL Speaker Protection is
missing. Failing route %s" — because the route's device list calls for HAL
Speaker Protection, a capability only a physical codec reports. The route is
*finished* when the decline lands: virtual stream on `pspk` at the matched
rate, the `dflt` DSP chain built, IOProc cache warm. The capability query
never leaves VirtualAudio — the ASD plugin's file logs show 0 'caps'
selectors reaching it — so no plugin-side fix exists. The handler's failure
path puts the vdef's output stream on `Null_Device`: a StartIO "Running"
signature still appears (on `Null_Device`, `VAD [vdef] AggDev 8`), which is
how an earlier validation was fooled; the audible era's signature is StartIO
on the `PuffinOutput` aggregate (`AggDev 2`). The guest is completely silent
and the volume is dead.

**Reveal** (all Capstone-decoded, no literal address): anchored on the
cstring containing `HAL Speaker Protection is missing. Failing route` — a
format three routing handlers share — and discriminated by requiring the
enclosing pacibsp-to-pacibsp function to also reference
`RoutingHandler_Playback_GenericConfig1.cpp`. Within that one handler, the
gate is the branch whose forward target heads the log block: a target at or
above which, within 0x100, the format's adrp+add sits, and the file name's
adrp+add too (both builds hold them 0x34 apart, 0x84 above the block's
entry), and whose target opens the os_log allocation itself (`mov w0,
#<size>` followed by the allocation call). That last shape check is what
kills the near miss: iOS 27 holds a `cbz x0, 0x146360` whose target lands
0xC4 below the format ref, inside the string window but on a `sub`, not a
block head. The scan decodes each word rather than trusting Capstone's jump
group — the gate is a `tbz` (`tbz w21, #0` on 26.6.2, `tbz w19, #0` on
iOS 27), which the group tagging misses — through
`decodeConditionalBranchTarget`, which reads the 19-bit immediates of
`b.cond`/`cbz`/`cbnz` and the 14-bit one of `tbz`/`tbnz`, sign-extended.

**The write.** The gate's branch is left untouched — that is what lets the
anchor resolve the site again on an already-patched binary. What changes is
the log block's own entry: the `mov w0, #0x14` opening the os_log becomes a
`b` back to the gate's fall-through, so a taken gate lands directly on the
success continuation the handler already built. Verified on both builds
that the fall-through never re-reads the register the gate tested (w21 /
w19), so no stale verdict flows on. The block is entered only by the gate's
jump — the instruction above the head is an unconditional branch on both
builds (`b 0x136d28` at 0x136874; `b 0x1467a0` at 0x14639c), checked before
anything is written, so rewriting the head orphans no fall-through.
Idempotency is exact, not marker-based: a re-run finds the head holding an
unconditional branch, decodes it, and requires its target to be the gate
site's own successor — a shape no compiler emits — before reporting
already-patched; a foreign branch at the head is an error, never
overwritten. Verified on the real iPadOS 26.6.2 and iOS 27 binaries: the
expected sites on both (gate 0x136620 → head 0x136878, fall-through
0x136624; gate 0x1460b4 → head 0x1463a0, fall-through 0x1460b8), writes
byte-identical on re-run, and all three VirtualAudio verbs composing on one
staged copy with a clean second pass. Research detail:
`Research/Guest/virtualaudio_speaker_route_throws.md`.

## VirtualAudio's volume-mode precondition — the decline after the gate (2026-10-03)

`system-virtualaudio-cfw-volume_mode_precondition` (new), same
`VirtualAudio.plugin` binary, verb `cfw patch-virtualaudio-volume-gate`,
riding the same `patchMachO` staged copy as the other three VirtualAudio
verbs in both `cfw install` and `cfw update-environment`. Patcher:
`FirmwarePatcher/CustomFirmware/ExecutablePatches/VirtualAudio/CustomFirmwareVirtualAudio.swift`
(the handler is resolved once for both gates, in `locatePlaybackHandler`).

**Fault.** With layers 1–3 quieted (walker throws, mute-set throw, plist
chains, speaker-protection gate), the same ringtone handler declines the
same finished route one step later, at
`RoutingHandler_Playback_GenericConfig1.cpp:252`: the route's
software-volume mode must be the packed pair
`(present, kHardwareOnlyReadOnly)` — present-flag in bit 32 over the
mode's low 32 bits, expected value `0x1_00000003`. The virtio plugin's
device reports `SoftwareHardwareMix`, so the precondition fails and the
handler *throws* a `std::logic_error` — unlike the SP gate's quiet
decline — which unwinds past the route's own teardown into
`RoutingManager.cpp:3520`: the route change fails `nort`, the session is
torn down onto `Null_Device`, and the guest is silent with the volume
dead. iPadOS 26.6.2 logs this as a bare "Precondition failure."; iOS 27
still carries the assert text
`softwareVolumeModeForPerDefaultScope.has_value() && softwareVolumeModeForPerDefaultScope.value() == VolumeControl::SoftwareVolumeMode::kHardwareOnlyReadOnly`,
which is what named the fault.

**Reveal** (all Capstone-decoded, no literal address). The handler is the
one `locatePlaybackHandler` already resolves for the SP gate — the
function holding both the `HAL Speaker Protection is missing. Failing
route` format and the `RoutingHandler_Playback_GenericConfig1.cpp` file
name. Within it, the guard chain reads: `bl` a wrapper (ActivationParams
check, else logs `Aspen.cpp:1428` and returns 0; on hit it calls a map
getter that logs `Aspen.cpp:1445/1451` and returns the packed 64-bit
map entry), then `and xN, xRet, #0x1ffffffff` — the 33-bit packing mask
— then `add x9, xBase, #1` building the expected pair, `cmp`, and a
`b.ne` to the decline. The decline's discriminator among the handler's
three `PRECONDITION FAILURE (std::logic_error)` blocks (`:142`, `:252`,
`:270`) plus the `Aspen.cpp:729` one is `isVolumeModeComparison`: within
six instructions below a non-call branch, a `cmp` seen, then an `and`
whose immediate operand is exactly `0x1ffffffff` and whose preceding
word is a call. The inner exception-allocation labels (`cbz x19` to a
`mov w0, #0x10` sizing) pass every block-shape check; it is the mask
window that rejects them. Block layout matches the SP gate's: the
format's adrp+add 0x58 above the head, the file name's 0x2c above, the
sole entry the guard's branch, and an unconditional branch at the
pre-head — checked before anything is written.

**The write.** The comparison and its `b.ne` are left untouched; the
decline's log-block head — the `mov w0, #0xe` sizing the os_log —
becomes a `b` back to the comparison's own fall-through, so a failed
precondition lands on the continuation the handler already built. The
fall-through reloads its inputs from memory and never re-reads the
tested value, on either build. Idempotency is the SP gate's exact scheme:
a re-run finds an unconditional branch at the head and requires it to
decode to the comparison site's own successor. Verified on the real
iPadOS 26.6.2 and iOS 27 binaries: the expected sites on both
(comparison `b.ne` 0x1369c4 → head 0x138124, fall-through 0x1369c8;
comparison 0x1464e0 → head 0x1475d0, fall-through 0x1464e4), byte-
identical re-runs, and all four VirtualAudio verbs composing on one
staged copy with a clean second pass. Research detail:
`Research/Guest/virtualaudio_speaker_route_throws.md`.

## VirtualAudio's speaker-protection gate, second site — the play-and-record handler (2026-10-04)

`system-virtualaudio-cfw-speaker_protection_gate` (changed: one more site,
record `system-virtualaudio-cfw-speaker_protection_gate.playback_and_record`),
same binary, same verb `cfw patch-virtualaudio-sp-gate`, which now runs the
patch once per handler in `CustomFirmwareVirtualAudio.SPGateHandler`.

**Fault.** The guest's virtio sound plugin now publishes a microphone
(`Digital Mic`, port `pmbi`; `Research/Guest/virtio_sound_microphone.md`).
A recording app asks for a route that plays and records (`cpar`), which
`RoutingHandler_PlaybackAndRecord_GenericConfig1` builds in full —
aggregate of `Digital Mic` and `PuffinOutput`, a virtual stream on each
port — and then declines at `:368` with the same "HAL Speaker Protection is
missing. Failing route %s" the playback handler declined the ringtone route
with. Before the microphone existed the route never got that far.

**The site.** The decline's format is shared by three handlers; this one
is the handler whose function also references
`RoutingHandler_PlaybackAndRecord_GenericConfig1.cpp`
(`locatePlaybackHandler(in:file:)`, the same resolution with the other file
name; neither file name contains the other). The gate and its block have
the playback handler's shape on both builds: a `tbz w9, #0x0` into a log
block that opens `mov w0, #0x14; bl`, with an unconditional branch above
the block's head, and a fall-through that reloads what it reads from the
stack and is also the join of the handler's raw-mode log path.

**The write.** As for the first site: the log block's head becomes a `b`
to the gate's fall-through; the gate's own branch stays. Verified on the
real iPadOS 26.6.2 and iOS 27 binaries: gate 0xea274 → head 0xea588,
fall-through 0xea278; gate 0x10e468 → head 0x10e6f0, fall-through 0x10e46c;
both sites written in one run, a second run reporting both already patched.
The handler's volume-mode test (`and x28, x0, #0x1ffffffff` at 0xea3fc) is
a branch between two builds of the route, not a precondition, and is not
touched.

## Guest audio through a Mac's microphone and speakers (2026-10-04)

An iPhone guest's audio node and tuning set are the D47's. Four changes take
out what they assume about its hardware; the measurements are in
`Research/Guest/virtio_sound_microphone.md` §7 and
`Research/Guest/virtio_sound.md` §9.

| Patch | Component | Effect |
| --- | --- | --- |
| `devicetree-cfw-product_audio_microphone_array` (new) | Every guest's DeviceTree, `fw patch` | Removes `supports-spatial-audio-capture` and `supports-audio-mix` from `/product/audio` (`DeviceTreePatcher.removeMicrophoneArrayClaims(from:)`). With them iOS 27's Voice Memos records through the four-microphone spatial route and the recording is silent. |
| `preboot-cfw-devicetree_microphone_array` (new) | Restored Preboot `devicetree.img4`, `cfw install` and `cfw update-environment`, every guest | The same removal for a VM patched before it (`vphone-cli cfw patch-dt-microphone-array`). |
| `system-virtualaudio-cfw-microphone_graph_chains` (new) | `/Library/Audio/Tunings/<AID>/VAD/graph_configurations.plist` and each `*_mic*_measurement.austrip` beside it | Every `<mic>_general` configuration with a `<mic>_measurement` sibling takes the sibling's `graph`, `austrip` and `propstrip` (`patch-virtualaudio-microphone-chains`), and every AUNBandEQ in those strips has its global gain set to 0 dB (`patch-virtualaudio-microphone-gain`; +18 dB on `bottom_mic_measurement`). A set with no such pair is left alone. |
| `system-virtualaudio-cfw-speaker_raw_chains` (new) | `/Library/Audio/Tunings/<AID>/VAD/graph_configurations.plist` | Every `speaker_*` configuration other than `speaker_raw` and `speaker_measurement` takes `speaker_raw`'s `graph`, `austrip`, `propstrip` and `volumeCommands` (`patch-virtualaudio-speaker-raw`). A set with no `speaker_raw` is left alone. |

All four are on in `standard`, need no firmware change, and are in the
installer's late list, so `cfw update-environment` brings them to a VM whose
plan predates them. The tuning files themselves are untouched except for the
one parameter word in each measurement strip; a strip whose saved state is
not whole parameter records is refused rather than rewritten.

Validation on `mictest-iphone` (iPhone99,11, iOS 27.0, cloudOS 26.4):
`vphone-cli cfw patch-virtualaudio-microphone-chains` on the guest's own
plist reported `back_mic_general`, `beamformed_mic_general`,
`bottom_mic2_general`, `bottom_mic_general` and `front_mic_general`, and a
second run none; `patch-virtualaudio-microphone-gain` on its
`bottom_mic_measurement.austrip` reported `AUNBEQ_2 global gain 18.0 dB -> 0
dB`, changing one word of the saved state; `patch-virtualaudio-speaker-raw`
reported eight speaker configurations. After `cfw update-environment` and a
boot, audiomxd built the recording route with `DSP chain
'bottom_mic_measurement'` and the guest's plist read back `speaker_general:
graph=speaker_raw austrip=speaker_measurement vol=["vugd"]`.

## The paravirtual user-client allowlist joins `standard` (2026-10-04)

No new Apple binary patch and no new bytes. JB-31
(`kernel-cfw-paravirt_user_clients`, formerly `kernel-exp-`; see "Renamed" below) leaves
`standard`'s block list and `FirmwarePatchSetCatalog.manualOnlyPatches`, so a
26.x or 18.x guest made with `standard` now gets the narrow IOUserClient
sandbox allowlist for classes beginning `ApplePar`, `AppleVid`, `AppleVir` and
`IOSurfac`. On 27 nothing changes: the declaration's `iOSBase` gate is
`.oneOf([.major(26), .major(18)])`, so the patch skips by version there, and the
boot-essential `kernel-boot-iouc_sandbox_gate` (JB-10b) already opens every user
client. The pipeline's no-plan fallback in `buildComponentList` follows the same
rule (on for an 18.x or 26.x base, off for 27 and for an unreadable base), so a
pipeline built without a preset agrees with `standard`. The patcher's own default
stays false, so `KernelcacheCustomFirmwareComparisonTests` still compares against
the records the reference was taken from.

**Why.** On an iPadOS 26.6.2 guest with the old `standard`, `cameracaptured`
crash-loops at every boot: its shader prewarm (`FigCapturePreloadShadersInternal`
→ CMCapture `PrewarmThreadSafeSBPs` → NRFV3 `-[NRFProcessorV3 prewarm]`)
dies with SIGSEGV at `0xc` inside
`AppleParavirtGPUMetalIOGPUFamily`. While it crash-loops, the first process to
touch the AVCapture defaults blocks on a synchronous XPC to it; when a guest app
starts recording that is SpringBoard's main thread (Control Center's sensor
indicator → `AVCaptureDeviceDiscoverySession` →
`AVCaptureProprietaryDefaultsSingleton` → `csr_ensureClientEstablished`), so the
UI freezes, `audiomxd`'s recording `StartIO` waits 18 s, and the first recording
after boot fails.

**Corrected the same day:** this gate was not the cause. `cameracaptured`
already has a Metal device; it dies on a bug in the paravirtual driver's heap
textures, and row 23 of the CFW table (`libvcamcaptured` skipping the
prewarm) is what stops it. The allowlist stays on for daemons and tools that
want the GPU (#22).

**What it widens, and why that is acceptable.** Every process whose sandbox
refuses one of those classes at this gate — daemons, command-line tools and
system XPC services such as `cameracaptured`, WebKit, `spotlightknowledged`,
`callservicesd` and `vphoned` — now passes it; apps gain nothing, because their
container profile already opens these devices. The prefix match admits every
class with those first eight bytes, which on this board means the paravirtual
GPU and device clients, the paravirtual VideoToolbox decoder, the VirtIO drivers
(the Neural Engine among them) and IOSurface's clients. Every other class is
still refused, which is why the narrow patch rather than the broad gate-off is
the shape on 26.x. For a research VM whose sandbox hooks are already stubbed
(JB-09) and whose IOUC MACF gate is already open (JB-10), this was the last thing
stopping a daemon reaching a device every app reaches. See
`Research/Guest/gpu_acceleration.md`, "On in `standard`".

**Renamed.** The patch was introduced the same day (37ed2e6) as
`kernel-exp-paravirt_user_clients`, opt-in. The `{component}-{effect}-{name}`
rule derives `exp` for a patch `standard` leaves off and `cfw` otherwise, so it
is renamed **`kernel-cfw-paravirt_user_clients`** (records `.redirect` and
`.cave`), as `dyld-cfw-mis_trust_auth` was renamed the other way on 2026-09-30.
`fw patch` resolves a VM's `PatchSelection.plist` against the catalogue and
throws `unknownPatch` for an identifier nothing declares, so a VM whose record
still names `kernel-exp-paravirt_user_clients` fails there until that entry is
removed. There is no migration.

**Opting out.** `vphone-cli fw set-patches <vm> --block
kernel-cfw-paravirt_user_clients`, then re-patch.

## Guest patches follow the selection, both ways (2026-10-04)

No new Apple binary patch. This changes how every guest-side patch in this
document (the dyld shared cache rows, the guest Mach-O and file patches, the
Preboot device-tree repairs) is applied after a VM exists, so it is recorded
here. Full write-up and live validation:
`Research/Firmware/post_creation_patch_changes.md`.

**Before.** `cfw install` applied the guest half from `PatchPlan.plist`, and
turning a guest patch off on an installed VM did nothing: the step was skipped
and the patched bytes stayed. The dyld cache patches were applied in place with
no record of what they replaced.

**Now.** `cfw install` and `cfw update-environment` resolve the guest half from
the VM's current `PatchSelection.plist`, apply what is on and revert what is
off. Mach-O, entitlement and guest-file patches revert from the `.bak` beside
the file; the Preboot device tree from `devicetree.img4.bak`; the dyld cache
from `.vphone-dsc-undo.json` in the cache directory, which holds the original
bytes of every content write a cache verb makes (slot hashes are re-derived by
re-attesting, not logged). Each cache verb takes `--undo-log`/`--undo-id`, and
the hidden `cfw patch-dsc-revert` verb applies the log. What is live is recorded
in the `Guest` part of `<vm>/PatchReceipt.plist`.

**Existing VMs.** A guest installed before this change has no undo log and no
backup for the files several patches share, so those patches are reported "not
revertible" when turned off and stay recorded as live; nothing is guessed. Every
dyld row above that a cache verb idempotently re-runs keeps its undo records, so
a revert works however many installs later it happens.

**Boot chain unchanged.** Boot-chain patches still reach a guest only through a
restore (AVPBooter through `fw patch`); `fw set-patches` and `fw patches <vm>`
say so per patch.

## An iPhone guest's product description from D47AP (2026-10-04)

An iPhone17,3 guest had no Siri page, no Camera Control, no Action Button and no
Model Name, whatever its identity patches. Most of vphone600's `/product` is
`syscfg/xxxx` placeholders (flag `0x8000`) that no syscfg fills on a VM, and
MobileGestalt reads a placeholder as absent. An iPad guest already takes these
from its board tree (`devicetree-cfw-ipad_*`); an iPhone guest did not, although
its IPSW carries the iPhone's own tree, `Firmware/all_flash/DeviceTree.d47ap.im4p`.

| Patch | Component | Effect |
| --- | --- | --- |
| `preboot-cfw-devicetree_iphone_product` (new) | Restored Preboot `devicetree.img4`, `cfw install` and `cfw update-environment`, iPhone17,3 guests (a board-presenting guest already boots its own board's description) | `DeviceTreePatcher.presentPhoneProduct` (`vphone-cli cfw patch-dt-iphone-product <dt> <board>`): fills the `iPhoneProductProperties` placeholders in `/product` from D47AP, adds `iPhoneAddedProductProperties`, and fills `/buttons/function-button_ringeren`. Only a placeholder is overwritten, only with a real board value. The board tree comes from `FirmwareOriginals`, or is recovered there from the VM's IPSW in `~/.vphone/ipsws` (`VPhoneBoardDeviceTree.need` now answers for the iPhone17,3 too). |

What is copied, and why:

| Group | Properties | What it turns on |
| --- | --- | --- |
| Name | `product-name`, `product-description` | About › Model Name |
| Siri | `assistant`, `siri-gesture`, `dictation`, `offline-dictation`, `builtin-mics` | Settings › Siri, side-button Siri, dictation |
| Buttons | `side-button-location`, `volume-up-button-location`, `volume-down-button-location`; added `ringer-button-location`, `camera-button-location`, `supports-camera-button`; `/buttons/function-button_ringeren` | Settings › Action Button and Camera Control (with Accessibility pages) |
| Display, UI | `artwork-scale-factor`, `chrome-identifier`, `compatible-device-fallback`, `display-corner-radius`, `display-mirroring`, `oled-display`, `thin-bezel`, `large-format-phone`, `ui-pip`, `ui-reachability`, `ui-background-quality`, `ui-weather-quality`, `hme-in-arkit`, `carplay-2`, `location-reminders`, `watch-companion` | the rest of D47AP's description |

Deliberately left as vphone600 has them: anything that promises hardware the VM
does not have — `bluetooth-*`, `baseband-chipset`, `nfc-express`, `exclaves-enabled`,
`has-*`, `graphics-featureset-*`, `framebuffer-identifier`, `wifi-chipset`, the
display calibration placeholders — and the vphone600-only placeholders
(`gestalt-variant-id`, `variant-name`, `thinning-product-type`,
`jetsam-properties-product-type`, `vm-supports-generative-models`).
`/buttons` keeps no `compatible`, so no button driver binds to it and the
board's function reference in `function-button_ringeren` is never followed.

Measured on iOS 26.6.2 (23G90) + cloudOS 26.4 (23E5207q), preset `standard` plus
the nine identity patches, by applying the same edit to the installed tree by
hand: Settings shows Siri, Camera Control (Camera and Accessibility pages) and
the Action Button; Siri opens from a long side-button press (HID 0x0C/0x30); the
Action Button's long press (HID 0x0B/0x2D) runs Flashlight and Camera with the
Dynamic Island, with no tweak; the search field gains dictation. The guest boots
normally. Not yet measured: the change on a VM without the identity patches, on
iOS 18.x, and a Camera Control press.

## The kernelcache reaches an installed guest without a restore (2026-10-05)

No new Apple binary patch. This adds a way to deliver the existing kernelcache
patches to a VM that is already installed, so it is recorded here.

A kernel patch toggled with `fw set-patches` could only reach an installed guest
through a restore, and a restore erases it (restored in the cloudOS ramdisk
repartitions whatever the host asks — `restore --no-erase` refuses; see
`Research/Restore/native_restore_architecture.md`). But the booting kernel lives
in Preboot as an IMG4, and iBoot accepts a modified IM4P under the original
signed IM4M — the same image4 bypass that lets `cfw install` rewrite
`devicetree.img4` there. `cfw update-kernel` (`VPhoneCustomFirmwareInstaller`
mode `.kernelUpdate`) host-mounts Preboot on a clone and swaps in a re-patched
kernelcache, keeping every volume. It re-patches the pristine kernelcache kept in
`FirmwareOriginals` with the VM's current selection
(`FirmwarePipeline.patchKernelcacheFile`, in the `.jb` variant — `.regular`
omits the AMFI/JB kernel patches and CS_KILLs launchd), so it needs no restore
tree and no prior `fw patch`. The splice is
`CustomFirmwarePostRestoreDeviceTree.kernelcacheReplacingPayload`, which carries
the whole IM4P (compression and any PAYP tail) verbatim and keeps the IMG4's
manifest.

Proven on test VMs (iPhone 27.0 24A435 + cloudOS 26.4) 2026-10-05, including a VM
with no restore tree, through the Launchpad helper: a marker in
`/var/mobile/Documents`, `kernel-exp-display_refresh_120hz` toggled with
`fw set-patches`, `cfw update-kernel`, then boot — the guest booted the
re-patched kernelcache and the marker survived. Flow: `fw set-patches` →
`cfw update-kernel`. `fw set-patches`, `fw patches` and the Launchpad inspector
route a kernel patch through `cfw update-kernel` and the rest of the boot chain
(TXM, DeviceTree, LLB, iBSS, iBEC) through the erasing restore. TXM and
DeviceTree are also in Preboot and could follow the same path later.

## Optional Settings row hiding (WIP, 2026-10-07)

Two standard-blocked declarations hide Apple Account, Game Center, iCloud and Wallet in Preferences (`system-preferences-exp-root_rows`) and Software Update in GeneralSettingsUI (`dyld-exp-settings_software_update_row`). Native discovery is restricted to reviewed 24A435 inputs. The installer uses pristine executable backups and cache undo records with page re-attestation. All five rows passed guest rollback, reapplication and reboot checks. See [research report](Guest/2026-10-07_reverse-settings-rows-report.md). Broader firmware coverage and bundled deployment remain WIP; no kernel/SEP or runtime hook changes are included.

## Pinned guest device name (2026-10-07)

Row 27. `libdevicename.dylib` makes configd publish the VM's name, which `vphone-vm` hands to vphoned after every connect and vphoned keeps in `/var/db/vphone/devicename.plist`, as the device name, and makes lockdownd refuse every rename; without the file it passes everything through. NVRAM was tried first and does not reach the guest: iBoot drops variables it does not know. It is the first library a process receives beside another: lockdownd already took `libmisfix.dylib`, so `vpInsertedLibrariesFor` in `Shared/InjectionEnvironment.h` now returns every installed library for a path and `vpInsertHookLibraries` adds each one an environment lacks. Single-library targets and their spawn log lines are unchanged. `preferences.plist` is never written: the pin is applied to configd's `SCDynamicStoreSetMultiple` publication, because the `SCPreferencesGetValue(kSCPrefSystem)` it flattens is also read and written back on configd's model-change path. Verified on iOS 27.0 (24A435) on 2026-10-07; iOS 26.x not run yet. See `Research/Guest/device_name_pinning.md` for the flow, the measurements and the verification.

## CoreDevice install proxy persona lookup (2026-10-07)

`system-installcoordination_proxy-cfw-persona_lookup` is an iOS-27 guest
compatibility patch, enabled in standard. Its root-owned marker
`/usr/lib/vphone-installcoordination-persona-lookup` enables the existing
launchd hook to allow only the system `installcoordination_proxy`, verified by
executable path, signing identifier and kernel-validated audit token, to look
up `com.apple.mobile.usermanagerd.xpc`. Other requests retain their original
sandbox check. Disabling the patch removes the marker. Both CFW install and
environment update reconcile its receipt. No kernel or proxy binary patch is
needed; an experimental entitlement-only version is restored from backup.

The original failure is a Protobox mach-lookup denial before UserManager's
persona-fetch authorization. Adding a temporary exception entitlement was
verified ineffective on the running guest and has been removed. IDA analysis
of this guest's launchd confirms the bootstrap lookup gate and name filters
2, 3 and 12. See [evidence, implementation and validation](Guest/ios27_xcode_persona_lookup.md).

## Host disk-image command migration (2026-10-08)

The migration replaces `hdiutil` because macOS 27 marks it as deprecated.
The system's `hdiutil(1)` manual recommends `diskutil image`, and command help
prints deprecation warnings directing attach, detach and convert operations
to `diskutil image attach`, `diskutil eject` and `diskutil image create from`.

No guest binary patch or preset change. On macOS 15+, CFW install and kernel
update, PCC GPU recovery, seal-tool extraction and Cryptex filesystem attachment
use `diskutil image attach`. Writable conversion uses `diskutil image create
from -format RAW`, which `diskutil(8)` identifies as the former UDRW format.
There is no hdiutil fallback or new disk-image tool abstraction: calls stay in
their existing functions. The macOS 15 `diskutil(8)` system manual already
documents image attach, create and resize. Single-hyphen options
preserve compatibility with older diskutil versions; conversion supplies
`-source` on macOS 15 and a positional source on macOS 26+. Existing function
names and CLI arguments are preserved. Eject uses `diskutil eject`; a busy image is
retried after `diskutil unmountDisk force`, avoiding the newer `eject force`
syntax on older systems. Attachment parsing retains the physical APFS store's
parent disk even when a synthesized container is reported first, and keeps
mount points containing spaces intact. PCC recovery tracks successful eject
before deleting its temporary library instead of querying `hdiutil info`.

`CryptexFileOpsTests`: all 12 existing tests pass. The
`VPhone` bundle build and bundle admission pass on macOS 27.0.1 / Xcode 27.1.
Real image attachment and execution on macOS 15 still require live validation;
no VM disk is modified by the validation tests.

## Flutter AOT executable-remap compatibility

The existing guest SystemHook component has a guarded `vm_remap` fallback for
an observed Flutter AOT callback layout whose returned RX permission disagrees
with the actual read-only destination. The fallback creates a private RW copy,
then changes it to RX; other calls pass through. No kernel patch or protection
policy change is added. See `Research/Guest/flutter_aot_remap_compatibility.md`
for exact guards, failure semantics, reproduction and validation limits.

## ProMotion joins `standard` (2026-10-09)

No new Apple binary patch and no new bytes. JB-30, the 120 Hz timing element,
leaves `standard`'s block list and `FirmwarePatchSetCatalog.manualOnlyPatches`,
so every new VM's paravirtual display advertises 120 Hz. It has no version gate,
so it lands on every base. The pipeline's no-plan fallback in
`buildComponentList` is on too, so a pipeline built without a preset agrees with
`standard`; the patcher's own `applyProMotion` default stays false, so
`KernelcacheCustomFirmwareComparisonTests` still compares against the records the
reference was taken from.

**Why.** Measured since 2026-10-04 (`Research/Guest/display_refresh_rate.md`): the
host scans out every frame the guest presents up to 120, the userland renders at
the advertised rate with no change of its own, a static screen costs what it did
at 60 Hz, and a guest with the patch booted on iPadOS 26.6.2 and iOS 27.0. The cost
is unchanged: up to twice the host CPU and GPU while the guest animates.

**Depends on Lakr233/vphone-cli#643 for iOS 26.** On an iPhone17,3 26.6.2 guest
with the 2.9.0 guest components, SpringBoard deadlocked in three of three 120 Hz
boots. Its main thread held `libvphoneattitude`'s `@synchronized` lock in the
`setDeviceMotionUpdateInterval:` hook while waiting for Core Motion's MotionThread,
which was waiting for that lock in the `isDeviceMotionActive` hook (guest spindump,
symbolicated against 23G90). #643 fixes that lock order. With its fix cherry-picked,
the same guest booted at 120 Hz and scrolled Settings at 119.3 frames per second.
Details: `Research/Guest/display_refresh_rate.md`, "iPhone 26.6.2, and the attitude
hook deadlock".

**Renamed, with a migration.** The editor titles it ProMotion and the naming rule
gives `cfw` to a patch `standard` turns on, so the record is
**`kernel-cfw-display_promotion`**. The old `kernel-exp-display_refresh_120hz`
shipped from 2.4.2, unlike the same-day `kernel-exp-paravirt_user_clients`, so a
VM may have it checked. `FirmwarePatchSetCatalog.renamedPatches` maps old to new,
and `VPhonePatchPresetStore` reads `PatchSelection.plist`, `PatchPlan.plist` and
`PatchReceipt.plist` through it: such a VM resolves instead of failing `fw patch`
with `unknownPatch`, and its kernelcache counts as already carrying the patch.

**Existing `standard` VMs** now read as wanting it in the kernelcache part and
keep 60 Hz until `cfw update-kernel` or a restore writes it.

**Opting out.** `vphone-cli fw set-patches <vm> --block
kernel-cfw-display_promotion`, then `cfw update-kernel`.

## Heap index buffers reach the host whole (2026-10-14)

New guest patch **`system-paravirt_gpu-cfw-heap_index_offset`**, on in
`standard`, gated to cloudOS 26.4: four words in the paravirtual GPU driver.

**Symptom.** Unity games (Wing Fighter on iOS 27.0.1, Subway Surfers on iPadOS
26.6.2) drew meshes with the right vertices and the wrong triangles. A probe
from a launchd job showed every plain-buffer path correct and every index
buffer sub-allocated 64 KiB or more into an `MTLHeap` wrong, unless the draw's
own `indexBufferOffset` forced the 64-bit command.

**Cause.** `-[PGSerializerRenderCommandEncoder drawIndexedPrimitives:…]` picks
a compact command with 16-bit fields when the draw's arguments fit in 16 bits,
then stores `[indexBuffer parentResourceOffset] + indexBufferOffset` in one of
those fields (`strh`). The heap offset is never part of the test, so it wraps.

**Patch.** The selecting `cbz`/`cbnz` in each of the three methods (two in the
`baseVertex:baseInstance:` one) becomes a `b` to the full command:

| Offset (23E5207q) | Before | After |
| --- | --- | --- |
| `0x140b0` | `dc0000b5` `cbnz x28, +0x18` | `06000014` `b +0x18` |
| `0x1421c` | `db0000b5` `cbnz x27, +0x18` | `06000014` `b +0x18` |
| `0x143b4` | `540100b5` `cbnz x20, +0x28` | `0a000014` `b +0x28` |
| `0x143c4` | `78010034` `cbz w24, +0x2c` | `0b000014` `b +0x2c` |

The sites are found by content, not offset: the compact command's `mov w2,
#size ; mov w3, #command` pair is unique in `__text`, the word before it must
be the `cbz`/`cbnz`, and its target must hold the full command's pair. The
patched 23E5207q driver hashes to
`5c172ab9ff049e7107ea9e4bd276c6b024f6b31e4556f9a847e5be5e6692cf2d` before
signing (pristine `29ba36c7…aedbc`); `CustomFirmwareParavirtGPUIndexOffsetTests`
checks it against `VPHONE_MACHO_PRISTINE`.

**Where.** `cfw install`, right after the GPU bundle step, through the
`patch-paravirt-gpu-index-offset` verb, from a `.bak` beside the driver, then
`codesign` over the bundle as for `VirtualAudio.plugin`. Off restores the `.bak`.
A bundle the same run reinstalled from the restore tree is already pristine, so
off then needs nothing and the receipt does not keep the patch live. An existing
VM gets it from `cfw update-environment` on the stopped machine: the guest patch
steps run there too, without the restore tree, over the driver already in place.

**Not covered.** `drawPatches:…`, `drawIndexedPatches:…` and
`-[PGSerializerBlitCommandEncoder copyFromTexture:…toBuffer:…]` store
`parentResourceOffset` in 16 bits too. They were not measured and are left as
they are.

## OpenAVB replaces AVPBooter on new machines (2026-10-18)

New machines boot OpenAVB (`Resources/OpenAVB/OpenAVB.bin`, built from
`owngoal-dev/OpenAVB` at `3c7e7f6`, with no carried patches; upstream
includes vphone's six Virtualization.framework fixes, the last of which lets a
guest reboot: the ROM waits for a SEP restarted by the reset) instead of
Virtualization.framework's `AVPBooter.vresearch1.bin`. OpenAVB checks no image
digest, so `avpbooter-boot-dgst_bypass` has nothing to patch on such a machine:
`fw patch` drops the AVPBooter component when `romImages.avpBooter` names an
OpenAVB image and logs `Boot ROM: OpenAVB, which needs no ROM patch`. The patch
stays in presets and plans, so `fw patches` reports no drift. Machines created
before keep Apple's ROM and the patch; `vm config --rom openavb|apple` switches
one without a restore.

Two boot-chain files change form, not content:

| Component | Before | Now | Why |
| --- | --- | --- | --- |
| iBSS IM4P | patched payload written back uncompressed | written back LZFSE-compressed, as Apple ships it | OpenAVB decodes only LZFSE; Apple's ROM takes either |
| iBSS over DFU | sent as is | preceded by a 112-byte stage-0 identity (payload and image sizes and SHA-256, load base `0x7006c000`, EL2) when the ROM answers OpenAVB's patch-store report | OpenAVB refuses an iBSS nobody described |

No patch site moved and no patch was added or removed. The OpenAVB-side
changes (read-only ROM aperture, chip ID 0, DFU suffix CRC, remote-boot bit,
USB device left running, SEP not ready after a warm reset) were carried as
patches at first and are now upstream (owngoal-dev/OpenAVB#1 and #2).
`Firmware/openavb_boot_rom.md` describes
each one and how it was found.

## OpenSEP replaces AVPSEPBooter on new machines (2026-10-18)

New machines start the SEP from OpenSEP (`Resources/OpenSEP/OpenSEP.bin`,
built from `owngoal-dev/OpenSEP` at `39ff3d7` for its `vresearch1` platform,
with no carried patches) instead of Virtualization.framework's
`AVPSEPBooter.vresearch1.bin`. Apple's SEP ROM was never patched and OpenSEP is
not either, so no patch, preset or plan changes: there is no SEP ROM component
in `fw patch`. The SEP firmware (`sep-firmware.vphone600.RELEASE.im4p`, sent as
`RestoreSEP` and loaded by iBoot) is unchanged and unpatched. Machines created
before keep Apple's SEP ROM; `vm config --seprom opensep|apple` switches one
without a restore. `Firmware/opensep_sep_rom.md` has the contract and the
validation.

## Guest Metal caches survive a reboot (2026-10-19)

Row 29. `system-systemhook-cfw-metal_cache_reuse`, declared in the Guest
System set, is on in `standard` and `experimental` and blocked in both Apple TV
presets (they carry no SystemHook). Its target is the marker
`/usr/lib/vphone-metal-cache-reuse`: `cfw install` and `cfw update-environment`
write it when the patch is selected and remove it when it is not, so it is
revertible. While the marker exists, SystemHook's constructor sets
`FS_CACHE_REUSE_ON_REBOOT=1` before anything else unless the variable already
has an explicit value, so `libCoreFSCache` can keep
each Metal cache stamped by an earlier boot instead of resetting it. No system
binary, shared cache or kernel byte changes.

Verified on `Lychee` (iPhone, iOS 27.0.1, cloudOS 26.4) with real reboots:
backboardd's `functions.list` keeps its boot UUID header and size across three
boots, guest compiles for backboardd during five Settings rounds fall from
about 145 to 0, no GPU restart, and the first go-home goes from about 31% to
37–44% on time. Numbers and method: `Guest/gpu_acceleration.md`, "Real reboots
with the patch (2026-10-19)".

Host cache storage (2026-10-20): the launcher keeps a durable whole-directory
snapshot in `<machine>/ShaderCache`, seeds Apple's normal ECID working cache
before boot, and checkpoints after guest shutdown and again in the parent CLI
after vphone-vm exits. A symlink experiment was rejected after sandbox denials
and repeated compilation; the working root remains a real directory. This adds
no binary patch and changes no Task3 key bytes. Index/data pairs stay together;
copies are staged before whole-directory replacement and never merged across
independent trees. Permissions use the shared symlink-safe host-file walker.
The final bundle passed two Settings/Camera boot cycles with zero host GPU task
compiles and zero GPU resets, including restoration after moving aside Apple's
working directory. All 14 cache file checksums matched after each shutdown.
Migration checks and runtime evidence are in `Guest/gpu_acceleration.md`,
"Cache location and migration".

Deletion correction: a missing machine snapshot now clears an already managed
host working copy on the next boot, instead of importing it again. A shutdown
checkpoint does not recreate a deleted snapshot. The working copy's existing
`.host-ecid` marker distinguishes this reset from the first-use import. This
resets host caches only; guest caches inside `Disk.img` remain. Frame-counter
gaps in the earlier measurements do not independently demonstrate visible
animation stutter; the user reports smooth warmed animations.
The corrected bundle's reset/reboot test recorded 607 then seven host GPU task
compilation events (129 then one during Settings), with zero GPU resets on both
boots. Fourteen cache/permission tests and the complete bundle build pass.

Standard promotion (2026-10-20): JB-32 is now enabled by Standard as
`kernel-cfw-paravirt_gpu_task3`; all four record suffixes and kernel writes are
unchanged. The shipped plist and catalog fallback agree. tvOS presets retain
an explicit block. The old `kernel-exp-paravirt_gpu_task3` identifier migrates
in VM selections, plans and receipts, including explicit opt-outs. New template
keys include the enabled kernel patch, so a pre-Task3 template cannot satisfy
the new Standard plan. Existing VMs bind the new bundle and run
`cfw update-environment` and `cfw update-kernel` while stopped, keeping data.
See `Documents/Guides/shader-cache.md` and the Standard promotion section in
`Guest/gpu_acceleration.md`. The previous opt-in notes describe development
validation; older host compatibility remains untested.
Promotion validation: 62 focused tests passed, as did the full `VPhone` bundle
build and admission check. The built CLI recognized Lychee's old Task3 receipt
under the new name as applied, enabled by its preset and not pending.

Review fixes (2026-10-21): JB-32 is declared for cloudOS 26.4 only. On the
cloudOS 26.1, 26.2 and 26.3 research kernels the owning-task anchor in the
superclass initializer does not resolve, and an ungated Standard patch made
`fw patch` and `cfw update-kernel` abort for every iOS 18.6.2–26.3.1 machine.
The `.features` site no longer loads a fixed 245: it branches to
`.features_code` (`sub x0,xV,#246; tbnz x0,#63; tbnz wV,#31; mov w0,#245`,
else `mov x0,xV`), which passes the granted version through when it is the
kext's own or lower, and a refusal unchanged. A host that does not know the
requested version grants its own maximum without the refusal bit
(`-[_PGDevice setBinaryVersion:]`: macOS 15.6.1 → 209, 26.0 → 233,
26.4 → 245, 27.0.1 → 252), so the fixed 245 had claimed 8 feature flags on a
15.6.1 host and 4 on 26.0 that the host never enabled. The clamp uses only
existing Keystone-checked encoders; the Task3 fixture test executes it for
252, 246, 245, 233, 209 and a refusal. The persistent host shader cache is no
longer required to launch: a VM that cannot prepare one logs a warning and
boots without it.
## Apply selected Preboot identity during guest updates (2026-10-21)

`preboot-exp-devicetree_identity` was advertised as an `update-environment`
guest patch but its installer call enabled identity only for full installs.
Launchpad's Apply to Guest therefore completed with the identity still pending.
Environment updates now run the existing identity rewrite when the current
resolved plan selects it, using the installed tree without a restore directory.
The patch bytes, presets, board-presenting guest guard, post-identity repair
backup and existing off-state behavior are unchanged. This fixes the same
delivery path for CLI updates, bundle changes and template guest-patch steps;
other Preboot repairs already used it. It does not enable the eight firmware
DeviceTree identity edits or establish that Apple will deliver Photos models.

Validation on `upstream/main` `047642f8` (2.10.1): 77 existing tests in eight
suites pass, covering guest device trees, patch resolution/catalogue/drift,
board audio, microphone-array removal, iPhone product properties and haptics.
The complete `VPhone` Debug build and bundle admission also pass.

## The `minimal` preset: a restore image instead of patches (2026-10-19)

The patchless variant (`FirmwarePipeline.Variant.less`) was unreachable: every
caller passed `.jb`. It is a preset now, `minimal`, and the variant is
gone. The preset names three sets:

- `com.vphone.patchset.bootchain`, allowing only iBEC's and LLB's patches,
  which the old `.less` variant applied too ("for the serial logs"). AVPBooter,
  iBSS, TXM and the restore ramdisk stay stock, and the pipeline builds no
  patcher for a boot chain component none of whose patches is on. A stock LLB
  does not get the restored guest to its kernel: on 26.6 with cloudOS
  23E5207q it restarts right after its banner, with Apple's ROMs as with
  OpenAVB and OpenSEP (2026-10-19). Which of LLB's patches it needs is open.
- `com.vphone.patchset.devicetree`, allowing only the board presentation
  (`devicetree-cfw-serial_number`, `-home_button_type`,
  `-artwork_device_subtype`, `-island_notch_location`) and the haptics and
  microphone-array removals. They change no code.
- `com.vphone.patchset.restore.image` (`FirmwareRestoreImagePatchSet`), new,
  named by no other preset:

| Identifier | What `fw patch` does |
| --- | --- |
| `filesystem-boot-cryptex_merge` | Merges the AppOS and SystemOS cryptexes into the OS image, adds the dyld symlinks, then rebuilds the static trust cache, the mtree and the digest database and root hash (`apfs_sealvolume`) |
| `filesystem-boot-gpu_driver` | Installs the PCC paravirtual GPU driver `fw prepare` staged |
| `filesystem-boot-mobileactivationd_should_hactivate` | The `should_hactivate` patch, in the image |
| `filesystem-boot-vphoned` | vphoned and its launch daemon, in the image |
| `filesystem-boot-launchd_cache_loader_unsecure_cache_gate` | Lets launchd read the launch daemons from the volume |
| `manifest-boot-digest_rehash` | Rewrites every BuildManifest digest to the files the restore now sends; for an AEA archive, the digest of its decrypted image, which is what Apple's manifests hold and what an 18.x restore checks the written image against |

The kernel and TXM stay stock, and the restore installs a system whose seal
the stock kernel verifies. `CryptexFilesystemPatcher` and `ManifestHashPatcher` used
to emit `filesystem.cryptex.merge` and `manifest.hash`, which no set declared;
they emit the identifiers above, and the pipeline builds each patcher only when
its patch is enabled.

Nothing may write the System volume after the restore, because that breaks the
seal. So for a VM whose plan enables `filesystem-boot-cryptex_merge`:

- `cfw install` touches no disk: it records an empty `Guest` receipt part and
  the install, so the boot gate (`restore-info.json`) passes as for any VM.
  `cfw update-environment` and `cfw update-kernel` refuse.
- `vm create` builds without a template (the offline trim and setup boot write
  the system) and refuses `--template` and the slimming switches, as for an
  Apple TV.
- `fw patch` needs root for the merge (owner-preserving copies on a mounted
  image) and says so. Launchpad runs it through its helper's new
  `patchRestoreImage` verb, which runs `fw patch <vm> --restore-image-only`
  from the receipt-checked store bundle; that flag refuses any selection that
  does not merge the restore image.
- `fw prepare` stages `apfs_sealvolume_<iOS version>` into `<restore>/.tools`
  (the `fw seal-tool` fetch; iOS 18.x.y takes macOS 15.x.y, or without a twin
  the newest macOS 15 below it) and the GPU driver for
  `filesystem-boot-gpu_driver` as for `system-extensions-boot-gpu_bundle`.
  `vm create` and Launchpad now record the preset before `fw prepare`, which
  read `standard` before: the GPU staging followed the wrong selection for any
  other preset as well.

The merged image must not carry the host's `.fseventsd`. `diskutil image
attach` mounts it browsable, so fseventsd starts a log on every writable
mount, and Apple's system volumes have none. With the log in the image, the
mtree listed `.fseventsd`, the restore wrote `.fseventsd/.ramdisk-boot-done`
into the restored volume, and `seal_system_volume` failed ("mtree: cannot
generate the XML dictionary", 26.6 on cloudOS 23E5207q, 2026-10-19). Each
writable mount now deletes the directory before it unmounts, which also stops
fseventsd writing it again for that mount.

The root hash `fw patch` computes has to be the one the restore computes, and
it was not ("Invalid root hash", `apfs_sealvolume` exit 65 in
`seal_system_volume`):

- The remap's `MODIFICATION` was the time of `/private/var` in the mtree,
  on the assumption that `removeSpecificSystemFiles` changes it last. The
  restore's own `mtree -m` sets it from the root entry (`.`), not from the
  newest one: run on 2026-10-19, the device took the root's
  `1792405582.069334279` while `/private/var` said `…582.936736187`. The
  remap takes the root's time now. Corrected 2026-10-23: `mtree -m` takes
  the time of the *first entry in walk order whose time differs* (checked
  with the host's `mtree -m` on a small tree). The restore gets the image as
  it was encrypted, before `removeSpecificSystemFiles`, so that entry is the
  first one edited afterwards. The root was that entry only because the
  browsable mount had created `.fseventsd` and removing it edited the root.
  Since the mounts are `-nobrowse` (6dcc3f2c) there is no `.fseventsd`, the
  root keeps the IPSW's time, and sealing with it failed again ("Invalid
  root hash"; seen on 18.6 22G86 on cloudOS 22G86, where the device took
  `/private/var`'s time). The remap now takes the first mtree entry edited
  since `removeSpecificSystemFiles` started.
- `createDigestAndHash` mounted the image writable only to unmount it again
  for `apfs_sealvolume`, which needs the device; the mount changed the volume
  after the mtree described it. It attaches the image with `-noMount` now.

On macOS 26.6.2 two more steps failed (2026-10-23, Mac mini M4):

- `diskutil image attach -mountPoint` refuses a folder that does not exist
  ("Mount point … doesn't exist", exit 64), and the merge attached at a fresh
  `<tmp>/volume` it had not created. Every preset that merges the restore
  image (watchos, minimal) stopped there. The folder is created first now.
- The watchOS 26.4 system image has no partition map: its APFS container
  spans the whole file, and `diskutil image resize` grows it no further than
  that ("Requested size exceeds maximum size"; min 11.05 GB, max = current =
  11.26 GB once merged). Left at that size, `apfs_sealvolume` ran out of space
  remapping the fsroot tree with 541 MB free (ENOSPC, exit 65). `growImage`
  now extends the file and runs `diskutil apfs resizeContainer <container> 0`,
  which gave the same image 2.7 GB free. The iOS images, which diskutil can
  grow, are resized as before.

Corrected 2026-10-24 (macOS 26.5.1, Minimal preset): the iOS OS images have
no partition map either. iPhone17,3 26.5 23F77's `094-54920-099` converts to a
9.31 GB RAW image with 537 MB free, and `diskutil image resize -plist` reports
max = current for it, so `convertToRawImage`'s resize to max left it as it
was. Merging the System OS cryptex (5.2 GB) then ran out of space in the image
("dyld_shared_cache_arm64e.09: No space left on device"), for iOS 18.6 22G86
as well; a 2.12.0 bundle that had built both a day earlier failed the same
way on the same host. `convertToRawImage` keeps the resize to max where it
grows the image and otherwise grows it as `growImage` does, by 16 GiB
(`mergeHeadroom`): the room is sparse, and `shrinkImage` gives it back after
the merge.

The binaries the merge patches (`launchd_cache_loader`, `mobileactivationd`)
are re-signed in Apple's ad-hoc shape (`VPhoneSignOptions.Style.appleAdHoc`),
like the stock binaries around them. The guest's TXM is stock here: it takes
an ad-hoc binary from the static trust cache the merge rebuilds, but rejected
ldid's signature (no ad-hoc flag, empty CMS blob), and launchd panicked at its
first boot task ("launchd_cache_loader - posix_spawn: 85: Bad executable").
vphoned, its launch daemon plist and the rewritten `launchd.plist` belong to
root:wheel, as the system's own; they kept the host user's owner and group.

## The research board stands in for vphone600 (2026-10-19)

Only the 26.1–26.4 beta cloudOS releases (up to 23E5207q) carry a vphone600ap
build identity. The 26.4 release and every one up to 26.7, and the 18.x
releases, have the research board alone (vresearch101ap). `FirmwareManifest`
now takes the research identities for the vphone600 components when there is
no vphone600ap, and leaves `RecoveryMode` out when the identity has none.
The new set `com.vphone.patchset.research.board` turns those components into
vphone600's. Every shipped preset names it. When the restore tree's
`RestoreDeviceTree` is not the research board's, `fw patch` records its patches
as not applicable (`FirmwarePipeline.resolveFirmwareApplicability`), so a
cloudOS with vphone600 components builds no SEP component, converts nothing
and stays byte-identical, and receipts do not claim the patches.

**`devicetree-boot-vresearch101_conversion`**
(`DeviceTreeResearchBoardConversion.swift`) rewrites the research tree before
any other device tree patch runs, whatever the selection, because those are
written against vphone600 paths and values. It finds the research tree by its
root `target-type` (`VRESEARCH101`) and then:

- sets the root identity (`VPHONE600AP`, `iPhone99,11`);
- adds the seven nodes the research board lacks: `/buttons`,
  `/arm-io/multi-touch`, `/arm-io/bluetooth`,
  `/product/vphone600-gestalt-variants` with its `d47vm2025vre-variant`,
  `/product/maps` and `/product/haptics`. Each goes where vphone600 has it and
  gets an unused `AAPL,phandle`;
- sets the phone's `/product`, `/defaults`, `/filesystems` and gestalt
  variant properties, most of them `syscfg/` placeholders (flag 0x8000);
- removes `/defaults/pmap-max-asids` and `/product/kernel-core-dump-location`.

Existing phandles are kept, so `interrupt-parent`, `device-interrupt-parent`
and `serial-device` keep naming the nodes they named. The earlier port
renumbered every node and repaired those three references by hand, which
would have broken any other reference.

Checked against Apple: converting the vresearch101 tree of cloudOS 26.1
(`399b664d`) and of the 26.4 beta (`c0ecdb4b`) gives their vphone600 tree
property for property. The only differences are the build `time-stamp`, the
order properties are stored in, and the phandle numbers, which are compared
through the node each reference names. `DeviceTreeResearchBoardTests` runs
that comparison whenever an IPSW in `ipsws/` carries both trees.

**`sep-boot-vresearch101_sepd_dispatch`** (`SEPResearchBoardPatcher.swift`)
patches SEPD in the research board's SEP firmware. On the 26.4 beta, which
carries both, vphone600's SEPD sends operation 0x31 to the handler it shares
with 0x12 and others, which zeroes the reply; vresearch101's gives 0x31 a
handler of its own, which replies with a constant from `__const`. The patch
copies 0x12's switch table entry into 0x31's. The table is found on decoded
operands, as the bounds-checked switch (`cmp`, `csel ls`, `adrp` + `add` or
`adr` + `nop`, `ldrsw … lsl #2`, `adr`, `add`, `br`) whose bound covers 0x31,
and must be the only one. SEPD is found through the root argument object after
the "Built by legion2P" banner. The table lies in `__text`, and from 26.4 on SEPD
carries `__TEXT,__fipspost_hmac`, an HMAC-SHA256 of `__text` with an all-zero
key (both stock 26.4 SEPDs match it), which is recomputed. 26.1's SEPD has no
such section. A rebuilt `sepi` container keeps its `PAYP` load properties
(`arms`, `tz0s`): `IM4PHandler` now finds the `PAYP` element by its DER length,
which gives the same 10-byte header for TXM and the kernel as before and 6
bytes for the SEP image. `SEPResearchBoardTests` checks all of this against
Apple's 26.1 and 26.4 beta images when an IPSW in `ipsws/` carries both.

### The research board's kernelcache

**`kernel-boot-vresearch101_kext_mix`** (`KernelCacheMixer`) gives the research
board's kernelcache the iPhone virtualisation kexts it lacks (paravirtual GPU,
touch, audio, FairPlay, ...). For the cloudOS's `kernelcache.release.vresearch101`
it finds the recipe in `Contents/Resources/kernelcache_recipes` by SHA-256, then:

1. extracts the donor, the vphone600 kernelcache of the 26.4 beta (23E5207q,
   read once from its cloudOS IPSW), and the base into KDKs with
   the native `KDKExtraction` pipeline, naming the stripped symbols from the
   recipe's maps;
2. keeps the recipe's bundle list: the base without its research-board-only
   kexts, plus the donor kexts that link against the base kernel;
3. stages the bundles as a root-owned volume (kmutil reads no other kexts and
   takes the host's own in their place without a word) and links it with
   `kmutil create -a arm64e -n boot -s all -z -x --compress --img4-encode
   --split-ro-rx-tags`;
4. puts back Apple's CPU subtype if the builder wrote another, makes calls
   through the auth stubs the macOS 27 builder keeps direct again
   (`KernelCollectionStubCalls`, below), and checks that every requested bundle
   was linked.

The mix replaces both `KernelCache` and `RestoreKernelCache`, so restore boots
it too. The pipeline keeps kmutil's container (its `PAYP` properties describe
the new layout) and saves the preset's kernel patches into it
(`ComponentDescriptor.replacement`); `minimal` adds none. The shipped kernels stay
in `FirmwareOriginals`. Mixes are cached in `~/.vphone/kernelcache/mix`, keyed
by the kernelcaches, the maps and bundle list and the builder layout.

Only the link needs root; native extraction runs as the invoking user. `fw kernelcache <vm>` stages
the mix as the user (both extractions and the volume) and links it under sudo:
root copies the staged volume into a fresh root-only directory, walking it by
descriptor, refusing every symbolic link but the KDK's pointer to the volume's
extensions and normalising modes (kmutil skips a kext with a group- or
world-writable file as silently as one root does not own), and runs kmutil on
the copy. The Launchpad helper's link runs with `--link-only`, which never
stages. kmutil records the absolute path of every codeless kext, which moves
the end of `__PRELINK_INFO`: the volume path takes the length of the build root
Apple linked the base in, read from the base's own prelink info, so a mix no
longer depends on where it is built. The 26.6 mix then has the segment layout
of the hand-built research mix that booted.

Requirements: root for linking; and for every base here (26.4–26.7, all
`kernel-last`) the kmutil of macOS 26.4 or later. `fw prepare` now pairs a
cloudOS without vphone600ap and refuses one whose kernelcache no recipe covers.
`cfw update-kernel` refuses on a mixed kernel, whose originals are the research
board's.

Native extraction checked on 2026-10-23: all 264 fileset images of the 26.4
beta vphone600 and vresearch101 collections match the pinned reference in
recovered references, synthesized symbols and exported bytes. The full KDK
trees match 313/263 files, with plist values compared semantically. See
[native KDK extraction](Kernel/native_kdk_export.md). On the 26.6 base
(23G71), the volume it stages for kmutil matches what the reference extractor
gives: all 151 executables byte for byte, all 160 Info.plists in value.

**macOS 27's kmutil keeps auth stubs.** The kmutil of macOS 27.0.1 (26A434)
links the same volume with every kext's `__TEXT_EXEC,__auth_stubs` left in place
(apfs: 0x2340 bytes), and a call to another image goes `BL stub` → `ADRP/ADD
x17` (the `__auth_got` slot) → `LDR x16, [x17]` → `BRAA x16, x17`. Apple's own
iOS 27 kernelcaches keep them as well (iPhone17,3 27.0 apfs: 0x2360 bytes), so
this is the new toolchain's layout, not a flag: `kmutil create` has none for it.
Apple's 26.6 `vresearch101` kernelcache has them at size 0, every call direct,
and the kernel patches look for those direct calls. On the stub-kept mix,
`kernel-boot-apfs_seal_broken`, `kernel-boot-apfs_mount_upgrade_checks.mov_w0_0`,
the three `kernel-boot-syscallmask` sites and both `kernel-cfw-debugger` sites
missed (24 base patches instead of 28), and the guest panicked at its first boot
after `cfw install` disabled the root snapshot: `"root volume seal is broken"
@authapfs.c:698`. Trimming is not the cause; `--slim off` panics the same way.

`KernelCollectionStubCalls` runs after the link. For each stub it checks the
four-instruction shape and reads the target from the `__auth_got` slot, a
`DYLD_CHAINED_PTR_64_KERNEL_CACHE` pointer into this collection's code (any
other format, cache level or target is refused). Every `B`/`BL` in a kext's
code sections that lands on a stub is re-encoded with `ARM64Encoder` to land on
the target. That is what the macOS 26 builder emits, and the stubs are left
unreferenced. Rewriting corecrypto's code breaks its FIPS power-on self test
(`"FIPS Kernel POST Failed (-2074)!" @corecrypto_kext.c:356`, in the restore
ramdisk), so an image with `__TEXT,__fips_hmacs` is sealed again: HMAC-SHA256,
keyed with the byte 0, of its `__text`. The existing seal must equal that HMAC
of the code as linked, or the step refuses. A collection that calls directly
is left alone. When anything changes, the container is rewritten uncompressed,
as patched components are.

Checked on 2026-10-23 on macOS 27.0.1: the 26.6 mix has 12,096 stubs and
131,560 calls retargeted. The seven call-site patches above are found again,
and none that was found before is lost: 28 kernelcache patches applied. The
template of iPhone17,3 26.6.2 (23G90) on cloudOS 26.6 (23G71), standard preset,
restored, took the CFW install and the trim, and its setup boot connected.
Booted again on its own, it reported Darwin 25.6.0 with iOS 26.6.2, no panic
in its log, and vphoned answered `device.info`. The setup's first-boot step,
the template adoption and the clone were not finished: Launchpad restarted at
that point, which ends a creation in progress.

Checked on 2026-10-19: a `minimal` VM of iOS 26.6 on cloudOS 26.6 (23G71) restores
and boots, and vphoned answers. Checked on 2026-10-20 with the standard preset:
iOS 26.5 (23F77) on cloudOS 26.5 (23F75) and iOS 26.4 (23E246) on cloudOS 26.4
(23E244) restore and boot the same way, their GPU driver taken from a temporary
cloudOS restore. The 26.7 recipe is one the research workflow built and
validated statically; it has not run through this pipeline yet (26.7 has no
iPhone release to pair it with).

## Apple Watch guests (2026-10-20)

A Watch7,18 (Apple Watch Series 11, N227b) IPSW restores as a guest of its own
family (`VPhoneGuestDevice.watch7_18`, 416x496 at 330 ppi, scale 2). No
cloudOS ships a kernel for a watch VM, and the vphone600 kexts are iOS builds,
so the watch boots the 26.4 research board kernel (23E244) rebuilt with the
watchOS kexts of its own IPSW. It takes the `watchos` preset: `minimal` with the
watch board's device tree in place of the iPhone17,3 identity, and activation
stock (`filesystem-boot-mobileactivationd_should_hactivate` is off; pairing
needs it).

### The watch kernelcache

`kernel-boot-vresearch101_kext_mix` with the recipe `watch_26.4_23T240`. A
recipe now names the guest family it is for (`guest`) and its kext sources in
order (`sources`); each kext comes from the first source that has it, the KPI
bundles (System.kext) always from the base, so the base kernel resolves them.
A donor without a cloudOS URL is read from the guest's own restore tree.

| Source | Kexts |
| --- | --- |
| `watch7c_26.4_23T240`: `kernelcache.release.watch7c` of the Watch7,18 IPSW | 105: the watchOS families and drivers a vphone600 target built with `OSPRODUCT=WatchOS` takes, per the KDK's KernelCacheBuilder makefiles |
| base: 23E244 `kernelcache.release.vresearch101` | 11: ARMGIC, PVPanic, ParavirtGPU, VPIOP, VirtIO, VirtualPlatform, usb.cdc, ParavirtIOSurface, VirtIOStorage, and AppleUSBXHCI/XHCIPCI for the VM's USB touch screen; plus the 7 KPI bundles |
| `vphone600_26.4_23E5207q` | 6: VideoToolboxParavirtualization, AvpFairPlayDriver, driverkit.serial, usb.cdc.acm, usb.serial, VirtIONeuralEngineDevice |

The 23E244 kernel was chosen because its KPI symbol sets, C++ class sizes and
syscall, Mach trap and MIG tables equal the watch kernel's. Both maps are the
research results: the watch kernelcache symbolicated with BinDiff against the
23E5207i KDK, and the 23E244 map of the iPhone recipe with about 2,400 fixes the
watch kexts' imports need (70 kernel-import binds resolved by three-way
alignment against the macOS 26.5.1 vmapple kernel, every `__ZTV`/MetaClass
label from `ipsw kernel cpp`, and IOSurface getters labelled 0x14 before their
entry, which failed PAC on `retab`). On 2026-10-20 the staged volume's kernel
and all 124 kext executables were byte-identical to the research mix that
booted to Setup with working touch.

### Device tree

The installed tree presents N227b through the board copy iPad and Apple TV
guests use (`devicetree-cfw-ipad_*`). A watch needs two more:

| Patch | Change |
| --- | --- |
| `devicetree-cfw-watch_presentation` | `/product` `artwork-display-gamut`, `artwork-dynamic-displaymode` and `framebuffer-identifier` from N227b; the `vphone600-gestalt-variants/d47vm2025vre-variant` tags MobileGestalt reads in place of syscfg on the VM (`tag-ards`, `-arsf`, `-codf`, `-tprt`, `-crid`, `-dcrd`, `-fbid`, `-prde` from the matching N227b properties, `-isnl` and `-waco` 0). With the D47's values the watch UI finds no screen class ("unsupported screen class, no apple logo found") and stays black. |
| `devicetree-cfw-watch_driverkit` | `/product/supports-driverkit = 1`. The VM's touch screen is a USB device behind XHCI whose HID driver is the dext `com.apple.AppleUserHIDDrivers`; launchd starts driverkitd only on a tree that says so, and N227b's does not (a watch has no USB touch screen). |

### Restore image

A watchOS image has no cryptexes: its dyld caches (arm64_32 and arm64e) are in
the OS image. For a watch `filesystem-boot-cryptex_merge` skips the cryptex
copies and dyld symlinks and only reseals the image with the guest payload.
`filesystem-boot-gpu_driver` marks the iOS driver and its compiler plugin
watchOS (`MachOBuildPlatform.watchOS`, re-signed, bundle resealed), as the
tvOS installer does; all its imports are in the watchOS 26.4 arm64e cache.
`filesystem-boot-launchd_cache_loader_unsecure_cache_gate` thins the universal
binary to its arm64e slice first (`MachOFatSlice`). vphoned is the arm64 daemon
marked watchOS (`vphoned-watchos`); its HID presses reach the crown as Home
(consumer 0x40). The side button is consumer Help (0x0C/0x95), not Power:
N227b's `/buttons` node names two buttons, `help` and `menu`, and Carousel's
`-[CSLHIDEventStreamWriter _eventForUsagePage:usage:down:]` maps 0x0C/0x40 to
the crown, 0x0C/0x95 to the side button (to the Action button only when
`shouldSimulateSting`) and vendor 0xFF01/0x200 to the Action button, which a
Series 11 lacks. `-[CSLUIHIDHandler init]` reads consumer Power (0x30) as the
separate `power` mask, which only sleeps or wakes the display. The VM window's
Device › Side Button (watch guests only) and the host automation key `side`
send 0x95; on 2026-10-20 it woke the `pair-watch` guest and opened Control
Center from the watch face, where 0x30 turned the display off.

vphoned links Vision (IcliKit's OCR) weakly: watchOS ships no Vision, and dyld
refused the daemon. Every other library it links strongly, and every symbol it
imports from them, is in the watchOS 26.4 arm64e cache; `ui.ocr` and
`ui.describe` report that the guest has no text recognition.

Checked on 2026-10-20: `vm create --device Watch7,18` with the Watch7,18 26.4
(23T240) IPSW and cloudOS 26.4 (23E244) links the mix, restores, boots, and
vphoned answers the first-boot ping.

### Pairing with a phone

See `Research/Guest/watch_pairing.md`. The watch preset now patches activation
(`filesystem-boot-mobileactivationd_should_hactivate`, on the arm64e slice of
the universal binary), and three patches are new:

| Patch | Target | Change |
| --- | --- | --- |
| `devicetree-cfw-watch_companion` | an iPhone guest's tree | `/product/watch-companion = 1`, added where the board copy removed a placeholder. vphone600's `syscfg/waco` has no syscfg value on a VM, so iBoot drops it and the phone pairs with no watch. |
| `system-bluetoothd-cfw-btvc_le_connection` | `/System/Library/FeatureFlags/Domain/BluetoothFeatures.plist`, `cfw install` / `cfw update-environment`, guest OS 26+ | `EnableBTVCLeConnection.Enabled = true`: bluetoothd's virtual LE controller may connect. Reverted from the `.bak` when turned off; enabled for iPhone, Apple TV HD, Apple TV 4K and HomePod guests. |
| `filesystem-exp-btvc_le_connection` | the same file in the restore image (`minimal`, `watchos`) | The same flag, written before the seal. |

On 2026-10-26 the Apple TV and HomePod presets also enable the guest BTVC
patch, and their installer admission includes it for both plain-arm64 and
arm64e userlands. The existing OS 26+ applicability and opt-out restoration
remain in place. HomePod mini 27.0 (24J361) and tvOS 27.2 (24K120) ship the
BTVC Bonjour, advertisement and LE connection implementation; the HomePod
connection manager still queries `EnableBTVCLeConnection`. Their original
feature plists omit the entry, which the existing plist patcher can add.
This enables transport testing; HomePod onboarding, Apple TV companion setup
and Home/AirPlay pairing have not been validated. Existing machines need the
updated Core Bundle and `cfw update-environment` while stopped, then a boot.

## iOS 18 guests on the research board (2026-10-21)

iOS 18.1 to 18.7.2 run on their own release's research board kernel, rebuilt
with the vphone600 kexts of the public cloudOS 26.1 (23B78), which still ships
vphone600 components. The userland comes from the iPhone XS family's IPSWs
(iPhone11,2/4/6), the only ones carrying every 18.x release, 18.7.x included.
Only `minimal` boots these kernels: `standard`'s kernel patches panic them early
in `kmem_init` (not investigated).

### The kernelcache

`kernel-boot-vresearch101_kext_mix` with the bases `18.1_22B83` to
`18.7.2_22H124` and the donor `vphone600_26.1_23B78`. Across versions an
import cannot be bound by name, so every donor import was resolved by code
identity, from 26.1 to 18.7.2 and from 18.7.2 to each release, checked against
the Apple-symbolicated macOS 26.1 (25B5062e) and 15.7.3 (24G419) KDKs; both
maps carry the names those targets have. The 26.1 map and the 18.x maps had
given 60 donor imports a neighbour's name, consistently on both sides, so the
research builds bound them correctly: the `IORegistryEntry` twins below, and
54 `OSMetaClass`, `IORegistryEntry`, `IOService`, `IOUserClient`,
`IOHIDDevice`, `IOHIDEventService` and `IOSCSIProtocolServices` virtuals
(the SCSI task management run was three slots off). The recipes give them
their real names. Every virtual one is proven by its vtable slot: the PAC
discriminator a donor kext signs the slot with is the
`ptrauth_string_discriminator` of the method's mangled name, the same slot in
both KDKs carries it, and each of the eight kernelcaches holds a signed
pointer with it to the renamed address. The `IORegistryEntry` twins also
have code markers:

| Function | Marker |
| --- | --- |
| `setLocation(const char *, plane)` | `OSSymbol::withCString`, then a virtual call with PAC diversifier 0x3025 |
| `setName(const char *, plane)` | the same, diversifier 0x848a |
| `setLocation(const OSSymbol *, plane)` | `plane + 0x30` (pathLocationKey), else `gIOLocationKey` |
| `setName(const OSSymbol *, plane)` | `plane + 0x28` (pathNameKey), else `gIONameKey`, and a `kernel_debug_string` call |
| `applyToChildren` / `applyToParents` | the same code but `ldr x1, [plane, #0x20]` (childKey) or `#0x18` (parentKey) |

`setName(const OSSymbol *)` had carried an extraction placeholder
(`_IOFreeDataSharable`, an unused KPI name of the 26.1 kernel) that no 18.x
symbol set lists; with the real names every donor import is a name the base's
own `com.apple.kpi.iokit` lists, and the symbol sets stay as Apple built them.
One import had been bound wrongly in every 18.x map: the donor's
`AppleEmbeddedHIDEventService::dispatchBiometricEvent` went to the base's
`IOHIDEventService` version (15 vtable slots in AppleEmbeddedLightSensor and
AppleSPU); in 18.7.2 the two are instruction-identical, and the recipes bind it
to the base's own `AppleEmbeddedHIDEventService` override.
18.5 to 18.7.2 take 18 donor kexts (the 16 of the 26.x recipes plus
IISAudioIsolatedStreamECProxy and ExclavesAudioKext, which the 26.1
AppleARMIISAudio needs); 18.1 to 18.3.1 take 15, without those three: 18.1
lacks the tightbeam API they import, and its addresses in 18.2.1 and 18.3.1
are not mapped reliably.

The 18.x kernels are kernel-first. On macOS 26.4 and later the mix is linked
on another Mac or macOS VM with an older kmutil over ssh (`VPHONE_KMUTIL_SSH`,
`RemoteKernelCollectionBuilder`): the staged volume goes into a fresh
directory of the remote `/private/var/tmp`, at a path as long as the base's
build root, root links it there, and the result comes back. Linked with the
kmutil of macOS 15.6.1, the 18.7.2 mix differs from the research build that
booted only in the 15 rebound pointers and the symbol sets that build had
extended.

### The iPhone XS Max guest

`VPhoneGuestDevice.iPhone11_6` (1242x2688 at 458 ppi, scale 3; iPhone11,4
maps onto it) keeps the iPhone17,3 presentation of the converted tree, with
two changes its userland needs. Its asset catalogs only carry 2436 and 2688
artwork and its SpringBoard has no Dynamic Island, so
`devicetree-cfw-artwork_device_subtype` writes 2688 and
`devicetree-cfw-island_notch_location` removes `island-notch-location`
instead of setting it; without them Hello and the wallpaper stay empty and the
home gesture breaks.

### Restore image

| Patch | Target | Change |
| --- | --- | --- |
| `filesystem-boot-ios18_surface_compression` | the image's `/private/var/preferences/.GlobalPreferences.plist`, iOS 18 only | `CAEnableIOSurfaceCompression`, `CAEnableFramebufferCompression` and `CAEnableDeepFramebuffer` = false. iOS 18's AppleParavirtIOSurface maps only address format 0 and rejects the compressed surfaces CoreAnimation asks for ("invalid address format (3)"); backboardd retries its framebuffer allocation forever and the screen stays black. A backboardd restart comes up without the keys too; only a reboot shows the fix. |

The GPU driver is the cloudOS's own, as for 26.x: 26.x drivers do not load on
iOS 18 (`_OBJC_IVAR_$_IOGPUMetalHeap._device` is missing). cloudOS 18.7.2
ships the 18.7 driver, so a driver now has to be of the cloudOS's release
(major and minor version), not its exact version. The compiler plugin is the
bundle's own, as for every guest.

Touch: iOS 18 guests take every touch through vphoned; a touch that starts at
an edge carries the digitizer edge flags (the edge swipe fix), so SpringBoard's
home gesture works there too.

Checked on 2026-10-21: `vm create --device iPhone11,6` with the XS family's
18.7.2 (22H124) IPSW and cloudOS 18.7.2 (22H43) recovered the GPU driver in a
temporary cloudOS restore, linked the mix over ssh with the kmutil of macOS
15.6.1, restored, booted, and vphoned answered. Setup's Hello screen and the
lock screen show their artwork, the bottom-edge swipe unlocks, and from
Settings it returns to the home screen. 18.1 (22B83) on cloudOS 18.1, the
oldest base and one of the three with 15 donor kexts, and 18.5 (22F76) on
cloudOS 18.5 passed the same checks. The other four recipes resolve every
donor import but have not been booted yet.

### 2026-10-23 — Integrating the minimal, research-board, watch and iOS 18 presets

The combined PR stack retains its declared patch sets and version gates. The
integration adds host-side confinement without changing instruction matching or
replacement bytes. Privileged `fw patch` clones only firmware inputs into a
private directory, rejects links and foreign-owned inputs, and publishes regular
files back through the pinned machine directory. Disk.img is never copied or
rewritten by this step. Guest image mounts also live below the private work tree;
guest file edits use descriptor-relative reads and atomic replacement.

External patch sets are refused before any native plugin is loaded as root.
Kernel extraction runs as the invoking user; root only links a staged private
copy. The root restore-image step ignores user seal-tool overrides and downloads
the matching tool again from an Apple HTTPS restore CDN into its private tree,
rather than executing the user-writable staged copy. This requires network access
for privileged resealing. The advanced kernel extraction tool remains a firmware
preparation/build tool, not a dependency for starting an already prepared guest.

Validation covers malicious input/guest symlinks, snapshot publication, large SSH
stderr/stdin streams, legacy fixed-address NAT reporting, patch catalog and recipe
consistency, plus full bundle/Launchpad builds. Firmware fixture tests still
require the separately held reference IPSWs; a build or synthetic test is not a
claim that every newly supported OS has been restored and booted on this host.

## VirtualAudio's device-state null gate — the singleton a guest never gets (2026-10-24)

`system-virtualaudio-cfw-device_state_null_gate` (new), same
`VirtualAudio.plugin` binary, verb `cfw
patch-virtualaudio-device-state-null-gate`, riding the same
`patchMachO` staged copy as the other four VirtualAudio verbs in both
`cfw install` and `cfw update-environment`. Patcher:
`FirmwarePatcher/CustomFirmware/ExecutablePatches/VirtualAudio/CustomFirmwareVirtualAudio.swift`
(`patchDeviceStateNullGate`, anchoring in `locateDeviceStateNullGate`
and `gatedDeviceStateSite`).

**Fault.** With the four speaker-route patches live on iPhone19,4 27.1
(24A94425, arm64e.x1), audiomxd segfaults (EXC_BAD_ACCESS far=0) on
queue AudioControl, in the plugin at 0xa16b0 reached
`HALS_AHPPlugIn::ObjectSetPropertyData` ←
`__vaemVADSerializationListener_block_invoke`. Publishing the route wakes
`VirtualAudio_Device`'s update (function at 0xa08bc), which pushes the
route's state at `DeviceStateManager` twice, each push behind its own
capability gate (checks at 0xfe810 and 0x225b88): gate `bl`, `cbz w0,
<skip>`, `bl` TheInstance (0x2b2988), `mov x20, x0`, `ldr x21, [x0]` —
the faulting unchecked read. The singleton's global (0x74ff28) is stored
only at 0x3ad0a8, deep in "Deferred Initialization" (0x3ab344, a
dispatch block whose only caller, 0x39924c, has no direct `bl`).

**Why no patch can publish the manager on a guest.** Deferred
initialization runs at plugin init — its "Beginning" log appears within a
second of launch — but on a machine with no haptic hardware it exits
without reaching SetInstance: the whole-life syslog of an audiomxd run
never logs "Ending Deferred Initialization", and when the fault lands no
thread is parked anywhere inside 0x3ab344…0x3ae2cc. It is not blocked;
it bails. The manager is a haptics-domain object (its accessor's own
assertion names DeviceStateManager; the actuator-port wait at 0x3ac024 —
100 ms polls against an 8-second deadline composed by the
`movz`/`movk`/`movk` triple at 0x3abed8 — is the same dependency in
another form) and a VM has no actuator to construct it around. So
TheInstance() logs "TheInstance() called before SetInstance()" and
returns null for the process's whole life, and any push that arrives
once the gates answer true faults. Observed crash times ran from ~10 s
to ~130 s into a life — the push timing varies with what triggers route
events; the first variant of this story ("0.6 s after every launch")
was the crash *loop's* cadence, not a fixed race window.

**Reveal** (all Capstone-decoded, no literal address). TheInstance is
found from its own diagnostic: the "TheInstance() called before
SetInstance()" cstring, referenced exactly once in `__text`; the
prologue above the reference is its entry. Every direct `bl` to that
entry — six on 27.1 — is filtered to the gated shape both device-state
updates share: a call at −8, the `cbz w0` at −4 skipping forward past
the whole update (target beyond the `ldr` at +8), the return moved aside
at +4 (`mov xN, x0`), and the unchecked dereference at +8 (`ldr xM,
[x0]`). Exactly two callers carry the shape; a build with a different
count is refused rather than half-patched. The plugin header gates
everything first: cputype arm64 and cpusubtype (masked of the LIB64
bit) 12 — arm64e.x1. Any other subtype reports "nothing to do" and
writes nothing, which is what keeps 26.6.2 and 27.0 byte-identical; a
file that is not a thin arm64 image falls through to the anchor's own
refusal.

**The write.** Each gate-check `bl` is redirected to TheInstance —
0xa16a0 `bl 0xfe810` → `bl 0x2b2988` (0x9401745c → 0x940844ba) and
0xa16dc `bl 0x225b88` → `bl 0x2b2988` (0x9406112b → 0x940844ab), from
`ARM64Encoder.encodeBL`. The `cbz w0, <skip>` below each now tests the
singleton: null, the update is skipped through the function's own path —
exactly what every build does when its gate answers false; present, the
fall-through re-calls TheInstance and the whole update (the save, the
dereference, the lock, the push) runs untouched. Nothing is deleted and
nothing is permanently disabled: the update happens whenever there is a
manager to receive it, which is everything this code can do on a guest
whose manager cannot be constructed and everything it does on one whose
manager can. The gate-check calls themselves are queries whose results
only fed those branches; their loss is the check, which the singleton's
existence now subsumes. Idempotent: a re-run finds the gate slot already
calling TheInstance and writes nothing.

**The two variants this replaces, and what each taught.** The first cut
(`…-device_state_guard`, 2026-10-23) made each gate's `cbz w0` branch
unconditional, permanently skipping both pushes. Live-validated: five
minutes of stable audiomxd, crash reports frozen, the system-sound
stream routed on `PuffinOutput` with its DSP chain running. Rejected on
review: it wins by discarding the feature — on a foldable those pushes
are how the audio graph learns the posture. The second cut
(`…-device_state_early_publish`, same night) left the deferred-init
actuator wait at once (`b.ls` → `b` at 0x3ac044) so construction and
SetInstance would run immediately. Offline it resolved cleanly; live it
was a no-op — the wait loop's "Beginning loop to wait for actuator port"
log never appears on this guest, because the product-flag routing at
0x3abf28 branches around the loop, and deferred init bails before
SetInstance regardless. That run produced the construction evidence
above (no "Ending", no parked thread) and one more crash at 31 s of
process life. The null gate is the third and honest cut: it does not
pretend the manager can exist; it makes the update wait for one.

**The other callers, examined and left alone.** The remaining
HapticAttenuationIODelegate callers (0x4f7dec dereferences unguarded
behind a capability flag that reads false without a Taptic Engine;
0x4f7b94/0x4f9114/0x5013ac pass the singleton into 0x2b30b4, reached
only through the coordinator's activation, which needs an actuator
port) never faulted across every observed run. With the null gate they
keep their existing behavior: on a guest they are never reached, and if
a future build ever reaches them pre-construction the gate's matcher
refuses (it requires the gate shape) and the site gets its own patch.

**Status.** Patcher, declaration, verb, installer wiring, tvOS block
lists and unit tests are in; on the real 27.1 binary the verb resolves
TheInstance at 0x2b2988 and redirects exactly the two gate-check calls
(six bytes), a second run is byte-identical, and the 27.0 and 26.6.2
plugins keep their SHA-256s. `FirmwarePatcherTests` shows no new
failures against a HEAD baseline. Verified in the guest (2026-10-24
morning, bundle `2.12.0-local.6a386de6`): the update log records both
redirects (0xa16a0, 0xa16dc -> bl 0x2b2988), audiomxd holds one pid
from t+30 s past t+5 min — the very window (10-130 s) the early-publish
run died in — the audiomxd crash count stays at the 30 the earlier
variants left, and RTAID telemetry still shows the SystemSounds stream
routed on `PuffinOutput` with its DSP chain running.

> **Foldable second-display identity (2026-10-25):**
> `system-springboard-cfw-fold_display` (guest system set, declared but in
> no preset yet — experimental, foldable guests only, iOS 27+; installs
> `/usr/lib/libvphonefolddisplay.dylib`) answers the display-topology gate
> the fold layouts key on. SpringBoard sizes its home grid from
> `+[FBDisplayManager alwaysConnectedIdentities].count >= 2` (confirmed on
> the host 2026-10-25: one `FBSDisplayIdentity "Main"`, NSCopying-capable),
> and the guest's paravirt GPU binds a single connector
> (`DisplayPortCount = 1` with two host displays configured), so the count
> gate can never pass on hardware facts alone. The dylib — SystemHook
> loads it into SpringBoard only — swizzles that metaclass method and pads
> a single-identity answer with a copy of the real identity; it is
> inert whenever the answer already has two or none, and logs to
> `/var/mobile/Library/Caches/vphone-folddisplay.log`. Not yet delivered:
> `cfw update-environment` cannot turn on a patch the machine's patch plan
> never had (`effectiveEnabled` intersects with the plan), and /usr/lib is
> sealed against runtime writes — see the bring-up doc for the delivery
> blocker and the observation target once it boots.

> **Follow-up (2026-10-25):** The delivery blocker above was the installer's
> hard-coded guest library table, now extended; installation is verified.
> The count accessors were never called in SpringBoard, so the claimed
> causal gate above remains unproven. Its main configuration already reports
> 678×951 points while the grid stays narrow. The subsequent backboardd
> runtime-wide probe coincided with persistent RPC unavailability on
> `2.12.1-local.8a55d450`: USB still sees both vphoned processes, SpringBoard
> and backboardd, with no vphoned crash report retrieved. A build with only
> the backboardd probe disabled (`2.12.1-local.ad5f3ecd`) restores RPC in
> 5 seconds. Replacing it with a delayed, named-class-only inspection
> (`2.12.1-local.42c33f10`) also boots in 5 seconds and completes its
> 23-method dump. The owner is `BKDisplayCloneMirroringManager`, whose
> interface concerns clone mirroring; it is not established as the home
> grid's topology source. Neither wide layout nor runtime switching has
> been demonstrated. See the bring-up document's ninth round.
> Tenth-round static analysis adds a concrete size mismatch: SpringBoardHome's
> D77 metric table is 669×951 while the guest reports 678×951. Configuration
> transformation and cached screen-type probes are in progress; the actual
> selected enum is not yet measured. No geometry override has been applied.
> The combined runtime probe subsequently measured D74 (23), not D76, for
> both the global and UIScreen lookup. The transformer preserves 678×951.
> A follow-up experiment remaps that D74 fallback to D77 at
> `SBHDefaultIconListLayoutProvider`'s typed initializer/current-device
> accessor, resolving both enum values through `SBHScreenTypeForShortString`.
> This changes derived grid generation without changing framebuffer size;
> visual acceptance and runtime switching remain pending.
> Both D74-only and D74/D76-to-D77 provider substitutions booted but left a
> narrow grid. A scoped live experiment now uses the runtime-verified
> `SBHIconManager setScreenType:listLayoutProviderLayoutOptions:animated:`
> selector, with diagnostic Darwin notifications for inner/cover/inspect.
> This is an unaccepted experiment, not a completed display switch.
> **Rejected:** the D77 provider's own 145.5-point horizontal root insets and
> inset Dock still give a narrow layout. Provider substitutions and the
> experimental switch notifications have been removed from source. The
> acceptance scope now explicitly includes status bar, Dock and rotation;
> follow the shared display/scene configuration boundary rather than
> accumulating application-level geometry overrides.
> The next system-boundary experiment uses CADisplay mode requests through
> vphoned. Read-only guest evidence confirms one primary 2034×2853@120 mode
> and virtual-mode setter availability; actual switching is unproven. All
> identity-padding hooks now pass the original collections through unchanged.
> The tested arbitrary mode failed: deprecated virtual-mode accessors are
> no-ops, and the modern display-properties request reached IOMFB but caused
> backboardd to abort. The write experiment was removed and recovery build
> `862de5d7` verified. Keep the native framebuffer intact for subsequent
> logical-display investigation; do not suppress this failure with a patch.
> A reversible software-render-display experiment now registers an actual
> CAWindowServer virtual display without replacing the physical mode. It is
> manually triggered, not created on boot. CADisplay sees id 7/type 3 at
> 1398×2034, but SpringBoard still has only SB-main; FrontBoard identity
> propagation and removal-cache verification are pending. Separately, the
> shared posture restore ladder now cancels on user requests and stops on
> confirmed restore; an early close remained closed beyond 121 seconds.
> `6004bbe4` verifies both software-display creation and removal in the render
> server and cache-refreshed CADisplay inventory, without restarting the
> display service. FrontBoard still exposes only Main in both connected and
> always-connected identity sets. The software probe was removed; display
> identity/scene publication remains the missing system integration.
> `86558897` establishes native connection publication: the system-defined
> unknown tag makes the real software display become `Unknown[7-1]` without
> restarting SpringBoard during that transition. Its connection remains
> virtual, non-main-like and non-always-connected, so it is not yet a Duo
> panel. The experiment was removed and stale frontend identity state cleaned;
> stable built-in role modeling and proper disconnect ordering remain open.
> A default-off, one-shot experiment now adapts only the owned virtual panel's
> CADisplay type/pointScale at the central SpringBoard display-source boundary.
> It preserves native IDs and uses the original FBS identity factory; runtime
> always-connected/scene acceptance is pending. No widget, status-bar or Dock
> layout override is added.
> The one-shot adapter reached count 2 and correct 3x cover bounds, but trapped
> in a managed-display cloning invariant and automatically reverted. A new,
> default-off experiment uses the native FBS builder's root-derived identity
> support and transform-set updates on Main, preserving the original renderer
> and hardware mode. It validates a preview before publishing; acceptance is
> pending.
> `4efbeb4b` validated the preview, but startup publication asserted in the
> outer SBFBSDisplayTransformer's exactly-one-result invariant. That enable
> path is now disabled, with baseline recovery verified. `83435b6f` exposes
> the more specific mismatch: native FoldingDual policy already requests
> primary content on .inner, while the sole scene proxy is legacyMain with
> .default surface. Cover transform mode/insets are inactive; UIScreen and
> regular scene size classes are already correct. Continue at the common
> display-profile/scene surface boundary; layout, live switching, status bar,
> Dock and rotation acceptance remain outstanding.
> The surface source is now traced to BKSDisplayService traits, populated
> from backboardd's CAWindowServerDisplay extendedProperties DeviceSurfaceType
> value. A default-off, 30-second primary-only metadata probe tests native
> inner classification without extra identities or framebuffer mutation;
> runtime acceptance is pending.
> `0932888f` confirms that this single shared metadata change reaches the
> native .inner scene surface, but the resolver waits for a matching .cover.
> Static native readiness logic corroborates the required pair. Baseline
> readiness and SB-main were restored; backboardd never restarted. A bounded
> software-cover/native-inner metadata test is next, without type/count hacks.
> `47b16e3f` keeps SpringBoard alive but the software Unknown display still
> gets no cover window scene. Recovery to Main/default and the visible home
> screen is verified. The built-in-adapter follow-up was rejected by automatic
> approval review and awaits explicit user permission; it has not executed.
> Read-only analysis identifies the earlier managed-display failure as
> "Cloning source already exists", rather than a missing optional.
> Static managed-profile admission is now resolved as `.main` kind OR
> `.integrated` connection; surface metadata alone does not meet it for the
> Unknown software source. A read-only per-UUID BKS trait query is added so
> intended cover metadata can be checked independently of scene admission.
> The first readback exposed stale CADisplay client inventory, with guest
> SpringBoard continuity verified. A local inventory refresh and observational
> public-monitor initialization trace are prepared; the native invalidation
> path's per-source updatable gate is now explicitly distinguished from
> successful transform delivery.
> `baa0b497` independently reads native primary=inner and owned software
> UUID=cover metadata, preserving SpringBoard PID/start time and default scene.
> Main invalidation is source-derived to depend on the isExternal trigger
> mask. A separate reversible, default-off refresh pulse is prepared with
> unchanged original configuration output; runtime delivery is pending.
> `087cc63d` verifies Main updatable=0 and native transform calls 1 -> 2
> under a reversible refresh pulse, with flags restored and both system
> process PID/start times unchanged. A default-off single-Main effective-
> bounds experiment now tests live cover/native-inner selection through that
> path, preserving the singleton invariant and physical mode; UI acceptance
> remains pending.
> `db4f509e` reaches live UIScreen bounds 466x678 and restores 678x951 with
> unchanged SpringBoard/backboardd processes, but the visible home is clipped
> because the effective mode remains native-sized. Bounds-only publication
> is not acceptance. The next revision uses native FBS effective-mode copies
> to update the full frontend geometry descriptor, leaving CADisplay's
> hardware mode alone, and adds scene/window frame readback.
> `c915dfd5` updates effective mode to 1398x2034 and UIScreen bounds to
> 466x678 while physical CADisplay stays 2034x2853. The root scene and every
> visible system window remain 678x951; screenshots are still clipped.
> Explicit return to inner and process continuity pass. A guarded, default-off
> native SB-main scene-settings geometry update is prepared to connect this
> missing common coordinator, without per-window edits.
> `fe02bc25` only inspected the root baseline; generic displayConfiguration
> KVC is unavailable on UIApplicationSceneSettings. The next build uses
> SpringBoard's native hosted-display FBS settings extension and adds pure
> UIS device/display context copies for artwork-family classification.
> `6eca5020` updates SB-main server frame and scene coordinate bounds through
> the native hosted configuration extension, but all visible windows retain
> 678x951. No per-window fix is used. Artwork-only classification copies all
> remain D74. The next guarded common-context probe replaces Main's cached
> default-context selection with a configuration-based copy and coordinates
> every root profile scene by display identity; visible reflow is pending.
> `bf39730c` rejects the stale-context hypothesis: cached/current contexts
> already agree at 466x678 while windows retain 678x951. That adapter is
> removed. Native pure geometry classification confirms 678x951 -> D74,
> 669x951 -> D77 and 466x678 -> D76; the requested size stays 678x951.
> Static SBWindow policy disables ordinary scene resize for Main. A guarded
> native pipeline refresh plus read-only window-policy/reference-bounds
> inspection is prepared; no per-window frame edit is used.
> `2061f359` confirms the native pipeline refresh fires but does not resize.
> Status/home windows are scene-sized/non-hosted and have correct scene-derived
> target bounds; Home's Main-display predicate disables resize. A scoped
> SBWindow base capability extension plus the common native scene-bounds
> notification is prepared. It handles only preexisting scene-sized windows,
> supplies no window rectangle and uses no per-component class list.
> `ab83c88e` and sizing-only `3e74efa3` both propagate native scene resize to
> 16 windows (13 changed frames), with coherent 466x678 window/root geometry
> and unchanged SB/backboardd process starts. Both still render a clipped
> home and vertical/overlapping Dock. The sizing-only version confirms
> portrait orientation and identity affine transforms, excluding the full
> callback's transform-layer update as the cause. Explicit inner restoration
> visibly recovers 678x951. This remains default-off diagnostic behavior;
> usable switching and the requested inner home layout are not accepted.
> `ce4ec5ed` native TRA readback receives landscape device inputs but keeps
> portrait interface output/home mask 2. Native home rotation capability is
> initialized from idiom or scene.surfaceType==inner, not just pixel size.
> A consumed-once single-real-Main/one-inner-proxy readiness experiment is
> prepared for native content resolution at 678x951; it does not create a
> virtual display, change CADisplay type/count or expand transform results.
> Runtime validation remains pending; the built-in panel retest stays off.
> `75951707` confirms single-real-Main inner readiness yields native primary
> content and home rotation mask 30 rather than baseline 2. The 678x951
> manager remains D74 and interface rotation still refuses 90 degrees, so
> neither inner layout nor rotation is accepted. Both bounded tests restored
> native role 0 and a fresh unarmed SB; no SB crash report was returned.
> Additional changes only inspect native pipeline/arbiter policy state.
> Full second-test evidence corrects the RPC-only interpretation: Home and
> its content do rotate natively to 951x678/orientation 4, and the screenshot
> is 2853x2034, while StatusBarWindow stays portrait and layout is clipped.
> The RPC still refuses, so its global orientation readback also disagrees.
> This is partial native rotation, with usable whole-system rotation pending.
> `0bdf35ef` adds read-only actual-scene/native orientation-state inspection.
> A pose-only sample also shows interface output lagging/disagreeing with
> device inputs across two 3-second observations, without AX rotate/rollback.
> Default role/portrait UI is restored through a fresh unarmed SB. Causality
> and settled, coherent rotation remain unproven; no per-app fix is added.
> The next read-only preview builds coherent inner/cover mode copies with
> native derived identities, retaining the same CADisplay. It inspects
> identity capabilities and native arbiter/stage descriptions. Neither is
> published; the obsolete two-result expansion code is removed entirely.
> `42ab7eb3` verifies coherent mode/identity previews, but both children lose
> isMainRootDisplay. Native mainConfiguration searches for that exact flag,
> so singleton replacement is excluded without a runtime publication.
> Native StatusBar arbitration supports all orientations. A default-off,
> ten-second root-scene orientation pulse and pure-copy ABI preview are
> prepared to test scene settings versus the native arbitration result.
> `b3747114` verifies an independent mutable settings copy changes direction
> 1->4 without changing the original or frame. Before runtime publication,
> detailed main-queue inspection was observed taking four seconds. Automatic
> heavy diagnostics are removed and ordinary inspection becomes a bounded,
> timed JSON snapshot. Short-wait negative UI conclusions require quiet
> revalidation; the root-orientation pulse remains default-off.
> `a30e60db` quiet snapshots measure 0.59-2.30ms. The awake six-second
> cover/inner test preserves SB/backboardd starts and coherent geometry in
> both directions, but confirms the same unusable clipped/overlapping cover
> layout. D77's independent native profile is itself centered 4x6. Automatic
> approval rejects the next single-Main role/force-SB-recreation trial before
> execution; the once marker is verified absent. Explicit approval is pending,
> with no root-orientation publication or role probe left active.
> Source-only recovery review adds exact weak scene scope, atomic generation
> cancellation, current-value checks and verified/retryable restoration to
> the default-off orientation pulse. It is built but not deployed/tested;
> the rejected role/restart operation still awaits explicit authorization.
> The user subsequently authorizes the single-Main retest. `4bdf2d54` is
> deployed with verified dylib hash. Actual root settings direction 1->4->1
> and readback-verified recovery leave StatusBarWindow/scene at direction 1
> while Home stays 4; the setting is not the shared rotation driver. System
> process starts remain unchanged within each trial, and default portrait
> recovery is verified afterward. The next default-off probe uses UIKit's
> scene geometry request plus native settled-pose/input refresh controls;
> no type promotion, extra display or app-mask override is included.
> `a9fd2032` native geometry requests return UISceneErrorDomain 101 for this
> system windowing mode. Validated pose/input refresh calls also do not fix
> the result. Provider directions [3,4,3] are correct and measured deferral,
> coversheet/fold holds are inactive; system process starts remain stable.
> Default surface-0 portrait recovery is verified. The next analysis targets
> the native system arbitration policy extension point; no policy is applied.
> Standard lock/app events and paired SBS/gravity publication do not establish
> correct rotation. The bridge's delivery record is not native effective-state
> readback. Explicit BBD native getter snapshots, a scoped/restoring orientation
> event-enable probe and native forceOrientationResolution update-context
> control are prepared, without installing policies or altering app masks.
> `ffe8184d` proves native raw/effective direction is 0 after virtual nonzero
> publication while event delivery is enabled, unlocked and rotation-capable.
> The high-level virtual accelerometer sink's extra hardware refresh is traced
> to CMDeviceOrientationManager.deviceOrientationBlocking and re-publication.
> Remove that poll: the native update already recomputes effective state.
> Existing accelerometer regression suites and full bundle admission pass;
> guest endpoint/UI acceptance is still pending. No enum/mask change is made.
> `63af20bd` runtime validates that removal: native BBD raw/effective values
> persist at 4 for landscape and return to 1 for portrait. SB/BBD process
> lifetimes stay unchanged during the trial. The inner surface still maps
> pose device 3 to interface 1 and device 1 to interface 4; Home follows that
> result while status stays portrait. Usable rotation/layout still fails;
> the unarmed default portrait baseline is restored after the experiment.
> Native resolver tracing locates the inner-panel conversion table
> [4,3,1,2] in SBWindowScene (inverse [3,4,2,1]), exactly matching that
> measured offset. Prepare a default-off, ten-second, exact-Main-scene
> native toll-free conversion probe with paired automatic restoration;
> no per-window angles, masks, new display or policy are supplied.
> `ac5e5f4d` validates paired-map correction: native device/interface/root
> scene/Home agree at 1 -> 3 -> 1 without process restart. Status remains
> portrait and widgets/Dock still fail visual acceptance. Native status
> rotation also requires scene.sbhScreenType == D77 (32), while 678x951
> classifies as D74. Prepare a separate consumed-once shared-scene-family
> probe using a native-classified reference copy; no reference geometry is
> published, no status-specific method or mask is changed. Validation pending.
> `dfbcdc9c` safely declines family selection because the scene has no
> displayConfiguration; type remains 23. The correction resolves configuration
> through FBDisplayManager Main with the same identity guard. Post-deadline
> runtime snapshot confirms automatic restoration of the direction map.
> `04596e28` guest hash matches build; scene type and actual icon provider
> both become D77 at unchanged 678x951. Status/page/Dock acceptance still
> fails. Native inverse-mapped physical pose also produces UI 1 -> 3 -> 1
> without any conversion override, showing the original table is the native
> inner mounting convention. Root server settings remain 1 while client UI
> follows 3; prepare combined existing root-pulse verification.
> Combined D77-scene/native-pose/root-server pulse still fails status/page/
> Dock acceptance. UIScreen bypasses the exported context classifier wrapper;
> both paths share exported _SBHScreenTypeLookupCommon. Prepare a separate
> consumed-once constructor probe at that common helper, using existing
> process-private MISFixDetour mechanics, native reference classification
> and all-argument passthrough. No on-disk cache is changed. Snapshot all
> three family paths and native status rotation permission. Runtime pending.
> `652fa4fc` validates all three families 32 and native status permission
> YES/mask 30. Landscape pages and Dock visibly separate correctly compared
> with the scene-only probe, but status native orientation remains 1 while
> scene/effectiveGeometry/Home are 3. This is partial shared-policy progress.
> Unarmed SB restores families 23 and native status NO/2. Prepare the shared
> native application actuation callback refresh and global-direction/setup
> readback; no individual window setter or mask is used.
> `3efe7381` proves pipeline setup is finished and global active direction is
> already 3; replaying native actuation leaves the embedded-display/status
> slot at 1. Prepare a separate ten-second native embedded-slot sync with
> exact scope/original-value guards and verified restoration. No individual
> window setter or mask is used; runtime acceptance remains pending.
> `dee331c8` native embedded setter does not apply 3 (readback stays 1).
> Static manager tracing identifies Main's legacy application route; the
> native per-scene route already exists. Prepare a consumed-once exact-Main-
> inner construction/manager policy adapter to select that native path,
> with thread-local construction scope and fresh-SB restoration. No identity,
> display type/count, window angle or mask is replaced. Runtime pending.
> `6581d4c8` installs hooks but does not enter the guarded native construction
> branch. Correct the manager's actual _windowScene ivar/native scene identity,
> and bound construction to SB-main/Main-root/678x951 with explicit startup
> surface 0-or-2 admission; runtime remains inner-only. Log scope inputs and
> retain fresh-unarmed-SB restoration. No route effect is yet accepted.
> `896e6d1e` confirms native per-scene construction: status and Home now
> follow 1 -> 3 -> 1 with matching frames and stable processes. Battery is
> visible, but time is missing and the overlay overlaps unmodified Safari's
> toolbar; full status/safe-area acceptance still fails. Prepare a separate
> root UI-role probe, preserving original isMainRootDisplay discovery while
> letting native Main roots select nonlegacy per-scene UI consistently.
> No type/root/identity fields or display counts change. The per-manager
> adapter is not armed in this new test. Runtime validation pending.
> `8ae865f9` root-role startup traps in FBSDisplayMonitor mainConfiguration
> initialization; unmarked automatic relaunch is not experiment acceptance.
> Baseline is restored. The revision preserves original Main semantics for
> both native monitor initializer scopes (finally-restored thread-local),
> retaining native validation rather than disabling it. Add startup guards
> for Main NO/MainRoot YES and all three families 32. Runtime pending.
> `0613339d` native monitor initialization succeeds, then physical default
> orientation lookup returns nil and traps in FBInterfaceOrientationService.
> Startup guards reject the unmarked recovery and cleanup restores baseline.
> Extend the original-Main hardware scope around default orientation lookup/
> submission and identity-based submission, passing all arguments through
> and preserving native assertions. No on-disk cache/identity fields change.
> Runtime outcome pending.
> `49fcc209` passes monitor/physical-orientation scopes but aborts at native
> XBApplicationController bootstrap. Reject global Main-predicate conversion;
> remove its implementation and discard stale markers. Prepare a read-only
> native UI configuration object (valid type 7, UIKitMainLike, same Main root/
> backing) and copied settings only. Check physical/connected counts and
> non-nil render equality. No live scene or display inventory is modified.
> `116c3c42` read-only native UI candidate builds with exact Main parent and
> identical non-nil backing. Connected identities remain 1 -> 1 and CA objects
> 6 -> 6. Only a distinct settings copy changes. The user explicitly permits
> UI-derived identities with one physical Main. Prepare a ten-second exact-
> scene hosted lease, optional native client update and verified rollback;
> runtime publication remains pending. Hardware Main predicates stay native.
> `fc9aa0d0` pulse does not publish: it used a read-only FBS client rather
> than the writable FBScene server. Activation safely refuses; counts/PIDs
> remain unchanged. Resolve the real SB-main server and keep a separate exact
> client binding. UIScene's native update registers a UIScreen configuration
> then reads scene displayIdentity; distinguish hosted/server/client fields
> and inspect mutable setters read-only. Corrected runtime remains pending.
> `249a5f50` verifies hosted publication and rollback but not identity adoption:
> server/client type stays 0. Native setDisplayConfiguration: is available with
> a typed object ABI, and displayIdentity derives from that actual setting.
> Prepare a guarded two-field transaction and original-value rollback, keeping
> hardware Main unchanged. Native actual-identity adoption remains pending.
> `ed2bf017` validates real UI identity 0 -> 7 -> 0, legacy/embedded flags
> YES -> NO -> YES, stable SB/BBD and unchanged connected/CA counts 1/6.
> Hardware Main stays native. The preexisting legacy status component remains
> cached; prepare native component unregister/recreate/register lifecycle
> under the derived identity with original component/identity restoration.
> Chrome/data acceptance remains pending; no window angle/frame is supplied.
> User's native reference establishes Duo's top-right time/ring status module.
> Generic per-scene bar visibility from 3128f885 is not the target; rotation
> still disagrees at scene/server actuation. Stop generic bar tuning and trace
> native SBDuoDisplaySystemUISceneController / SBSUIDuoDisplaySceneSpecification.

Duo native-status follow-up (2026-10-26): native dynamic Duo session admission
is enabled although no Duo controller is in the 18 startup controllers.
SystemStatusUI's AxisAlignableSplit2007 factory matches native display width
and scaled camera exclusion geometry; do not infer that 2034->2007 width alone
fixes it. Added manifest-gated, default-off read-only status_provider.inspect
(native factory previews only; no screen/provider publication). Corrected
Duo inventory Class comparison and controller setup lookup. Runtime results
pending; generic status component visibility remains outside native acceptance.

Native status readback (3c7497fe): actual exclusion is a 125.333x36.667-point
pill; native factory selects DynamicSplitSmallIsland at both 2034 and 2007
reference widths. Width-only explanation rejected. Added isolated native
notch-size factory preview (no publication). Extended ten-second root-scene
orientation pulse to the exact approved UI alias only, requiring original
Main root and unchanged CADisplay backing. Native server actuation/rollback
under that alias remains pending runtime validation.

ca903010 runtime: isolated 2007-width + native notch-size (37x37) factory
argument selects AxisAlignableSplit2007, without publication. On the approved
UI alias the root server orientation updates 1->3 to match native arbitration;
landscape Home/Dock is visible. Explicit direction and identity restoration
verified, SB/BBD process start times stable, counts 1/6 unchanged. Persistent
rotation, correct native status rendering, and runtime inner/outer switching
remain unimplemented. JSON evidence recorded in Research/Guest/Evidence.

Status renderer verification: +[SpringBoard _statusBarClass] conditionally
selects STUIStatusBar_Wrapper using Speakeasy feature flags. Added only class
readback to the existing status inventory; no flag override, class selection
hook or live renderer replacement. Runtime class inventory pending.

ed4011db readback confirms live STUIStatusBar_Wrapper -> STUIStatusBar ->
DynamicSplitSmallIsland; feature-flag forcing is unnecessary. Added default-off
eight-second inner reference-metric lookup scoped to the exact owned UI alias
and screen. Original native factory must accept its 2007 profile. Real-screen
construction, hardware and window geometry are retained; original factory
restores before identity/component rollback. Visible native status result
pending; this remains a bounded experiment.

1ca946c8 live lookup did not reach accepted-reference selection; provider and
screenshot stay generic. Direction round trip and complete rollback verify
without process restart. Extend bounded classmethod inventory to the four
native factory levels and exact owned component construction/mounted reset,
with thread-local recursion/scope guards and conditional IMP restoration.
No C detour or physical/global Main override is added. Outcome pending.

Native status cache trace: UIKitMainLike, nonexternal screens use an embedded
_referenceBounds-keyed provider cache before factory entry. Add a native
non-MainLike UI-derived identity preview, using only an exact unpublished
configuration's thread-local identity substitution during native building.
Physical Main remains untouched; verify Main parent/CADisplay/geometry before
any separate explicit ten-second publication. Add actual target-screen cache
predicate readback. CoverSheet button geometry is included in common display
acceptance; no button-specific patch. Runtime preview pending.

User now explicitly authorizes true-device dimensions: acceptance becomes
2007x2853@3 (669x951pt), superseding custom678. Correct the shared Duo inner
boot profile from2034 to2007 pixels. Native-size tests must use native Home
classification, without the custom678 classifier adapter. The independent
non-MainLike native UI identity preview passes with original Main parent and
same CADisplay; physical Main remains unchanged. Control Center and CoverSheet
join unified layout acceptance; no independent UI scaling is added.

71240384 native-size boot verifies2007x2853@3, FBS/UIScreen669x951 and native
D77 classification without custom678 mapping. Nonembedded UI migration reaches
native factory but selects Fallback, not Duo; rollback/process stability pass.
Wallpaper remains portrait-only; status/glyph/Control Center acceptance open.
Touch now takes priority: right/center/bottom input attempts did not launch
visible targets, including a clean rot0 boot. Added read-only HID geometry
inventory and default-off15-second UIKit touch observation (unchanged event
forwarding, bounded logs, restored original IMP). Both panels' actual hit ranges
remain unverified. No controller/button scaling patch is introduced.

Native input trace e237688b proves expected pixel/3 coordinates across inner
right/bottom regions; all are intercepted by STUIStatusBarForegroundView.
HID touchscreen is present/integrated with four contacts and0..32767 X/Y.
Correct read-only registryID ABI to SDK CFTypeRef/CFNumber (initial IDs invalid;
input untouched). Add owned-alias native phone-idiom inheritance/trait
propagation with verified restoration, plus foreground/status frame readback.
Actual Duo rendering, normal Home hit delivery and both-panel acceptance
remain pending; no coordinate/button/window scaling workaround is added.

2dc1eacf shows idiom field0 but trait collection remains-1 and Fallback persists.
Use native _updateTraits before trait propagation. Complete reversible native
component-window handoff: deactivate distinct old-profile window after new
component connects; hide own replacement before disconnect and restore/verify
old visibility. Native default bar frame is54x951 atx615; actual foreground
still covers entire669x951 and intercepts touches. Added window-role tracing;
no frame/hitTest/input remap. Runtime result pending.

bf9002f1 verifies published phone traits0, real native AxisAlignableSplit2007,
compact right-top foreground bounds and restored SBIconView hit delivery.
Visibility/component/idiom rollback pass, but logical-screen status data is
empty. Add constructor-armed, default-pass COW lookup adapter on exported
STUIStatusBarGetVisualProviderClassForScreen; an explicit8s reference-metadata
pulse retains original Main/UI identity/wrapper/data channel and native
selection, bypassing embedded cache only on an isolated lookup argument.
No fabricated values/classes or geometry changes. Runtime result pending.

f3d69e48 native lookup succeeds but renderer remains cachedDynamic; resetVisualProvider
only clears region/item/alpha dictionaries. Correctly clear class cache toNil
and call native reinitializeStatusBar; preserve original actual provider for
verified rollback. No explicit chosen-class assignment. Add read-only host
socket display.geometry and richer touch orientation/type/coordinate traces
for user's post-rotation offset report. Portrait mapping alone is not full
panel/rotation acceptance; no unmeasured input remap is introduced.

64a73aa0 ordinary rotation90 is refused while SBS pose3 remains pinned; no
actual landscape was reached. Host/VZ/capture remain2007x2853; both touch paths
agree in portrait. Add fresh native SB inverse-map bridge and iPhone19,4-only
synchronized SBS pose/gravity rotation, preserving hinge/tabletop and existing
logical AX request; owned-state rollback and old-model behavior retained.
Cover/inner regression matrix added. No generic gravity mapping or host input
transform changed. Rotated acceptance remains pending.

FoldGuard crash correction: real21:06:04 startup IPS PID294 is PAC_EXCEPTION261
in objc_msgSend(retain) from vpGuardedCopyRender+84 during native render commit.
The id-return guard ARC-retained an unmanaged C++ render-layer pointer. Change
return/original-call types tovoid*, validate native pointer/GPR ABI, retainNULL
exception behavior, add non-ObjC pointer regression fixture and bounded actual
nonnull forwarding log. Native deployment/startup acceptance pending; new
geometry experiments paused. Sanitized crash evidence saved.

76b6ff90 FoldGuard validation:7 host fixture checks and full build/admission
pass. Real guest ABI ^v36@0:8^v16I24^I28 accepted. Boot plus two controlled
SpringBoard first-commit reconstructions show no new IPS; existing invalid-name
exception fallback remains operational. Non-null path regression is proven
in host fixture, not yet observed in these guest launches.

Crash-fixed native pose isolation reaches90 degrees (scene4, host-90) before
AX is called; subsequent same rotation succeeds. Avoid racing fold transition:
Duo waits for native UI receipt after pose/gravity and uses native rollback;
ordinary-device AX behavior retained. Logical reply fields stay consistent
with the verified receipt. Multi-angle/runtime hit verification pending.

86eea0ac achieves true90-degree UI and host-90 with mapped pose1/gravity0;
raw host/guest injection points agree. Fix confirmed socket contract mismatch:
full screenshots are upright JPEGs but tap/swipe used fixed portrait pixels.
Shared inverse transform now covers windowed/headless input and both Duo sizes,
with current guest orientation/live VZ dimensions. Native-settle-first AX
reassertion refreshes screenshot/pointer caches. Focused four-direction tests
added; full live screenshot-coordinate acceptance pending.

Remove unconditional near-edge coordinate snapping from host touch dispatch:
ordinary clicks must preserve their requested point. Native edge flags and
explicit snappedScrollStart home gestures remain. Full-screenshot inverse
mapping plus near-edge runtime matrix will verify the combined correction.

Same default-off original-Main lookup now accepts only the two canonical Duo
panel bounds and verifies native AxisAlignableSplitV68Cover selection on outer
466x678, alongside proven inner2007 profile. Outer live acceptance pending.

Duo db26a8cc inner input runtime checkpoint: four orientations now deliver
upright screenshot pixel(60,1050) to Home point(20,350) through both host and
native fixed-panel input paths, with unchanged SpringBoard process. Evidence:
Guest/Evidence/iphone_duo_inner_four_direction_touch_20261026.json. Initial
rotation settle timeout still requires investigation; outer panel/full-area
coverage and persistent native status remain unaccepted. No new binary patch
was introduced for this checkpoint.

Duo cleanup: removed the rejected virtual-panel-to-builtin CADisplay type and
scale override; constructor now only discards its stale marker. Outer baseline
has correct1398x2034 pixels but surfaceType0 and failed visual status/Dock
acceptance. Native cover role1 remains the next verification target.

Bounded cover-role verification: extend the existing backboardd primary-only
DeviceSurfaceType probe to native cover1 via surface.cover. Retain30-second
rollback, original identity/mode/count, and guard older rollback timers by
lease generation. Orientation-events probe remains inner2-only. No secondary
CADisplay or runtime mode mutation. Runtime acceptance pending.

c6f0cdbe runtime: primary cover1 reaches SB-main at native466x678, but native
outer UI remains incorrect (side Dock, invisible status, auxiliary window
receiving lower-right touch). Role-only hypothesis is insufficient. Keep the
cover probe default-off; no new always-on behavior is accepted from this test.

Cover acceptance correction: explicit closed pose after SB reconstruction
makes native FullyClosed policy ready and primaryContent without a readiness
patch. Main cover status is visibly rendered after1-second settling (earlier
instant screenshot was premature). Keep native cover layout distinct from
inner; side Dock lacks a true-cover comparison. Status remains pulse-only.

Duo lifecycle: vphoned captures actual completed pose readback and replays it
on SpringBoard finishedstartup with generation cancellation. This addresses
observed unknown pose after SB-only relaunch; no new binary patch or geometry
override. Built, not yet guest-validated.

290da141 pose lifecycle runtime: closed/device1 and closed/device3 survive
separate SB-only reconstructions with identical SBS readback. Final closed/
device1 restored. Evidence in Guest/Evidence/iphone_duo_pose_replay_20261026.json.
This acceptance is pose lifecycle only, not the remaining live display switch.

Duo same-Main viewport: pair root scene displayConfiguration with
sb_hostedDisplayConfiguration and frame, validating both native setter ABIs
before mutation. Derived from the already verified UI migration path; no new
identity or CADisplay mode. Runtime acceptance pending.

cf557df1 paired-update test was blocked by an overly strict generated-object
ABI check, not a native setter failure. Correct to semantic object-argument
validation. Same-process dimension roundtrip verified, rendered cover still
clipped; rerun required before evaluating the paired-update implementation.

0cd9e242 live paired-configuration acceptance: root/Home bounds switch both
ways,15 window frames update natively, SB PID unchanged. Rendering not accepted:
scene family31 versus cached UIScreen/global32 during cover. Native family
cache/re-evaluation and backing/capture/input viewport remain unresolved.

Duo default-off viewport-family experiment: native context reclassification
at exported SBH screen/global lookup boundaries, scoped to active same-Main
cover lease. Preserves original paths otherwise, with recursion guard; no
cache memory edits or hardcoded component layout. Runtime pending.

0d172c0d runtime: screen lookup adapter accepted, global adapter safely
refused Unrelocatable. Cover screen/scene31 versus global32; rendered layout
still invalid. Same-process return to inner32 verified. Default-off experiment
only, no global relocation guard bypass.

MISFixDetour bounded B.cond support for the revealed global-family prologue:
ordinary conditional branch relocates through inverse condition + absolute
jump; overwritten-range destinations and AL/NV/BC.cond remain rejected.
Native host taken/fallthrough and condition/destination tests passed. Shared
helper affects future admitted detours; complete build/runtime checks pending.

c75a6a9a global adapter experiment failed runtime acceptance: both hooks
installed but pre-transition diagnostics/RPCs stalled. No new SB crash report.
VM recovered after restart without the consumed experiment marker. Host
relocation tests remain limited evidence; global experiment stays default-off
pending hang diagnosis. Goal not achieved.

Global-family hang diagnostic adds bounded raw entry/return/stack records to
the existing default-off experiment; no behavioral bypass. Static slow path
confirmed dispatch_once; actual blocking location remains unproven.

7afd766f runtime: both global/per-screen native reclassification work; all
families32->31->32 with unchanged SB PID293. Raw trace shows first24 calls
return normally depth1. Prior hang not reproduced, cause unresolved. Visual
layout still invalid, so family-query coherence alone is not sufficient.

Duo controlled viewport now invokes the revealed native SBHIconManager
screen-type/options setter after scene sizing, updating its retained layout
provider and native downstream consumers. Scoped SB-main only, unchanged
layout options, scene-derived family31/32, no icon-model reset. Runtime pending.

afa31362 runtime: native SBHIconManager family32->31->32 and matching native
providers, same SB PID292. Cover widgets/grid reflow, Dock no longer overlaps.
Remaining physical-canvas black area/status/host viewport-input integration;
not end-to-end panel switching acceptance. Inner restored.

Duo geometry diagnostics: expose fresh SB main-queue configuration/coordinate
bounds, scale, orientation and viewport generation through display.geometry.
Avoid stale device.screen extent for forthcoming host viewport/input work.
No rendering or input behavior changed by this diagnostic addition.

Duo host automation viewport geometry separates active extent from physical
HID backing; cropped screenshots and inverse input use the same four-angle
transform. Two focused geometry tests pass. Native GUI integration and guest
runtime acceptance pending; no new binary patch.

ae8d0e56 live automation: cover screenshot1398x2034, inner restored2007x2853;
four edge screenshot points map exactly to expected UIKit points. Native
status pulse removes full-screen interception (three Home hits, one actual
status-region hit). GUI/rotation/persistent status acceptance still pending.

Duo persistent native Main status: actual GUI click confirms full-screen old
status intercepts correct coordinates. Enable verified native profile at SB
startup only for iPhone19,4, with bounded readiness retries and native refresh
after logical viewport sizing. No hitTest override or arbitrary view frames.
Build/runtime validation pending; this promotes the existing gated patch.

2f446502 persistent status runtime: no pulse, real GUI Settings icon click
hits SBIconView and opens verified Settings; further GUI About navigation
works. Native ring/time visible. Inner portrait GUI interception fixed;
outer/rotation/viewport integration still pending.

Duo native window integration: clipped active viewport around fixed physical
VM view, fresh logical-size polling and enclosing-rotation input mapping.
Host-only change, pending live GUI acceptance. No physical VZ resize.

22357146 native GUI viewport: cropped cover Home and real mouse Settings click
accepted, plus Settings General navigation. Timed inner restore leaves existing
app scene at cover size; app-scene transition propagation still required.
Not complete runtime inner/outer usability. Explicit inner Home restored.

Duo read-only workspace request preview added to investigate system-level
foreground app resizing. Native factory + context/entity readback only; no
transaction execution, no per-app frame patch. Runtime preview pending.

Workspace preview correction: fresh unfinalized request has empty entities;
no transaction run. Current layout must be read from scene.layoutStateProvider,
not transition coordinator. Diagnostic corrected; runtime readback pending.

c1ff6b18 live layout provider identifies the single primary Preferences scene.
Unsubmitted preview now populates identical native previous/target entities
and locally finalizes to verify preservation. No transaction submission.

Native app-scene refresh experiment preserves current entity/role and native
layout attributes, validates from/to identity and unchanged state, then uses
executeTransitionRequest under explicit workspace.refresh notification only.
Finalized preview identity preservation verified; submission runtime pending.

a81fcd09 live workspace refresh: same Settings PID317/scene ID retained through
cover narrow -> inner dual-column layouts; both native transactions accepted.
Prior stale app size on return resolved in controlled trial. Persistent switch
integration and rotation acceptance remain outstanding.

Persistent Duo fold integration: native family/status default initialization,
nonexpiring apply viewport controls, automatic guarded app transaction refresh,
pose RPC fresh-bounds acknowledgement and boot/relaunch replay. Host always
uses inner-sized physical backing and crops cover; old blackout chrome disabled.
Build passed before UI-copy cleanup; full runtime acceptance pending.

e4c3c421 formal Fold Posture GUI drives persistent cover/inner/Book without
VM/SB/app restart: SB37, Settings306 stable; correct native dimensions and
visible app layouts. Cover holds beyond45s. Open restored. Broader acceptance
and research-path cleanup pending.

Default Duo rotation still refuses with logical scene surface0. Added default-
off one-shot native-size SB-main surface role adapter (inner2/cover1), preserving
physical CADisplay/resolver identity and all unrelated scenes. Runtime pending.

604ff90e role experiment not accepted: native mapping and masks update, but
scene4 disagrees with legacy orientation and wallpaper/status transforms.
Exited one-shot experiment and restored default inner. Keep default-off.

Rotation diagnostic: retarget existing default-off native per-scene status
policy to native669x951 for combination with now-verified native Axis profile.
No default enablement or per-window angle assignment. Runtime pending.

Combined rotation trial revealed scene.inner versus resolver default/unknown
content mismatch. Default-off logical-role probe now updates the existing
single Main proxy via native setter/resolution with matching size-derived role.
No auxiliary-window hiding or touch interception override. Runtime pending.

985fa8f7: coherent logical role restores primaryContent; landscape GUI Settings
launch and rotation90 RPC succeed. Home wallpaper/time still missing, so no
default promotion. Point trace expired and is not touch-coordinate acceptance.
Recovered default persistent inner afterward.

Read-only presentation diagnostic compares scene/embedded status data providers
and native cloak flags plus wallpaper activation/window state. Targets remaining
rotation time/wallpaper issue without forcing visibility or data. Pending live.

Native presentation comparison finds separate servers for scene versus embedded
bar, not an in-process cloak flag. Added bounded original-Main server binding
probe with native setters and restoration, only within logical-role experiment.
No default behavior change; build/runtime validation pending.

f0609c2b data lease was refused before mutation, not a negative data-channel
result. Add precise preflight reasons and semantic object-setter ABI checks;
verify restore readback. No default enablement.

c2f9d947 proves old embedded server has nil client, so proposed active-server
handoff precondition is false. Removed that unused pulse path, retained richer
read-only item/registration diagnostics. No default behavior change.

4ce7a072 rules out homeItemsDisabled: visible scene client registered with
normal flags; old embedded client hidden/unregistered. Add default-off native
registration refresh plus data/parts diagnostic, no fabricated values.

419bdab4 native re-registration did not restore missing time data. Added source
aggregator/provider diagnostics and scoped native time subscription refresh.
No fabricated clock value or visibility override; default path unchanged.

750ccd86 upstream time differs normal versus experiment despite false cloak
flags; native timer refresh ineffective. Add formatter/date observation and
narrow constructor-only Main override to one query. No default enablement.

Time diagnostic: identical normal/experimental date formats did not explain
empty cache. Add bounded pass-through native update trace and formatter-output
readback under existing one-shot role experiment. Default path unchanged.

Native callback trace narrows time failure to empty callback input despite
valid getter/formatter output. Add input type versus provider-current-date
observation. No data substitution or callback behavior change.

457e820d native minute callback carries NSDate with empty description versus
valid current getter; type mismatch hypothesis excluded. Add numeric interval
and underlying provider observation only. No date replacement.

Native minute date +inf traced to detached reference view -> nil screen ->
1/0 FPS. Scoped experiment selects existing native nil-reference scheduling
branch during registration/tick, preserving weak-slot semantics/restoration.
No timestamp substitution, cadence guess or default enablement. Pending live.

4e40b3b6 actual installed clock fallback verified: detached wrapper/nil screen/
FPS0 takes native nil-reference path, finite date notifications and visible
minute time restored. Fixed missing constructor installation discovered via
unchanged hash/unused warnings. Initial renderer data timing and wallpaper
remain incomplete; no default role/scene-policy promotion.

Native status initialization now requests existing native data as well as
layout refresh; bounded retry for empty initial renderer data. Separate default-
off wallpaper controller rotation pulse uses scene direction and native restore.
No timestamp, wallpaper image or manual window-frame replacement.

Wallpaper pulse exposed stale direction, not valid fix. Native legacy landscape
gate is PF_IS_PAD_DEVICE; default-off Main-inner container scope now asks existing
per-display capability API, preserving native result. No image/frame override.
Runtime pending; production default restored.

69f677e2 global/per-display wallpaper support bothfalse; removed ineffective
adapter. Added one-process exact TraitsArbiterWallpaperTokyoDrift flag probe
under separate once marker, leaving all other queries native. Default-off,
no on-disk feature override. Runtime pending.

7eda0424 feature override activates native traits path but wallpaper still
fails, including bounded real-Main inner metadata comparison. Add read-only
participant/delegate/remote-view evidence; no further default enablement.

Wallpaper managed-role gap verified: allowed delegate, no participant. One-shot
probe supplies the same native wallpaper role hint before visibility on exact
Main-inner wallpaper subclass, leaving native registration/geometry in charge.
No default enablement or manual wallpaper frame. Pending live.

### 2026-10-27 Duo active-viewport input mapping

The host VM view now derives its input geometry from the active Duo viewport (`activePanelPixels / screenScale`) and the bottom-left clipped viewport origin. Mouse, trackpad, and synthetic touch events therefore use the same visible outer/inner rectangle while the fixed backing framebuffer remains available for rendering and screenshot crop. This closes the path where outer-screen touches were normalized against the hidden 2007x2853 backing surface.

> **Duo landscape integration (2026-10-27):** The previously one-shot logical-role and per-scene status policies are now enabled for the exact `iPhone19,4` Duo default path. They retain one physical Main and native framebuffer modes while allowing the native scene orientation/status arbitration to see the active inner role. Build/admission passed; runtime rotation and wallpaper acceptance remain under validation.

> **Duo rotation arbitration refresh (2026-10-27):** `display.rotation` now publishes the native pose and immediately emits the existing mapping, input, arbitration, and actuation refresh notifications before waiting for SpringBoard's scene receipt. Without this sequence, the pose changed but `display.orientation` stayed portrait; with it, the running scene read back landscape bounds `951×669` and orientation 90 without restarting SpringBoard.

> **Landscape presentation follow-up (2026-10-27):** The live rotation path exposed a delayed wallpaper rollback: `vpPulseNativeWallpaperOrientation` restored portrait after eight seconds, recreating the black landscape band. The rollback was removed for the normal Duo path; wallpaper now follows SpringBoard's current native arbitration, while clock refresh remains tied to the same orientation sequence.

> **Duo Fold Posture titlebar control (2026-10-27):** Foldable VM windows now expose a Duo-only circular control beside Home. It cycles `closed → book → open → closed` through the existing `VPhoneGuestControl.setFoldPosition` / `display.posture` path, mirrors the same fold-position callback used by the Fold Posture panel, and updates its accessibility value/tool tip after each accepted reply.

> **CoverSheet lock glyph scale (2026-10-27):** Runtime class enumeration identified `UICoverSheetButton` as the shared lock-screen action button class. The Duo path now wraps its native `layoutSubviews` and applies a 0.82 transform only to child `UIImageView` glyphs; the circular button container and action handling are unchanged. The hook installed successfully on `duotest-m5` (`cover sheet glyph scale: UICoverSheetButton UIImageView scale=0.82`).

> **Host rotation authority correction (2026-10-27):** Duo `display.geometry.interfaceOrientation` can remain portrait while the authoritative `display.orientation` endpoint is already landscape because the inner panel uses an inverse native mounting map. The host orientation poll now prefers `display.orientation` and uses geometry only for active bounds, preventing a portrait host window with sideways notifications/status content.

> **Glyph sizing correction (2026-10-27):** The initial `UICoverSheetButton` transform experiment did not produce a reliable layout callback/readback, so the guessed scale was removed. The current source retains only a recursive native layout probe; no arbitrary glyph scale is accepted until Duo's actual constraint/bounds metrics are observed.

> **FoldDisplay source split (2026-10-27):** `libvphonefolddisplay.m` was reduced from the monolithic implementation by extracting the status-bar provider/profile section into `FoldDisplay/StatusProfile.inc` and the wallpaper traits section into `FoldDisplay/WallpaperTraitsExperiment.inc`. The files are include-only implementation fragments copied from the original source; no new runtime target or duplicate dylib is introduced. A full VPhone bundle build passed after restoring declaration-order bridges for the existing monitor/diagnostic helpers.

> **Split recovery (2026-10-27):** After an interrupted edit temporarily left declaration-order bridges incomplete, the status and wallpaper include fragments were restored with explicit shared helper declarations. The source now builds cleanly again; the split remains source-only and the existing runtime bundle was not replaced by this maintenance pass.

> **FoldDisplay module split (2026-10-28):** The two include fragments are gone. `libvphonefolddisplay.dylib` now builds from thirteen `FoldDisplay<Section>.m` translation units plus `libvphonefolddisplay.m`, which keeps only the constructor (backboardd probes, SpringBoard hooks, the `com.vphone.display.*` notification registry, then the display pipeline observation). State shared across files is declared in `FoldDisplayPrivate.h` under `#pragma GCC visibility push(hidden)`; everything else stays `static`. The export table is unchanged (only `VPhoneStatusScreenPreview`), no patch or hook changed, and on duotest-m5 the split and pre-split builds gave the same install log and the same rotation/fold results.

> **QuickAction glyph scale made layout-proof (2026-10-28):** The button lays out its glyph with `setFrame:`, which undid the glyph transform whenever a layout pass followed the walk. Each `CSQuickActionImageGlyphView` now moves to a runtime subclass (`VPhoneQuickActionGlyphView`) whose `setFrame:` keeps the transform, and both glyphs take one factor, 0.70 of their native layout size (flashlight 14.2x25.7pt, camera 24.3x18.4pt, matching a real iPhone Duo screenshot), replacing the 16pt-long-side and 0.82 targets. The glyph class itself is still not modified.

> **Duo inner display spike, Stage 0 (2026-10-28, branch spike/duo-virtual-inner, opt-in marker):** `libvphonefolddisplay.dylib` adds a 2853x2007 `CAWindowServerVirtualDisplay` in backboardd, tagged `unknown` (65536), and in SpringBoard reports it as CADisplay type 0 everywhere except inside `-[FBSDisplayConfiguration _initWithImmutableDisplay:originalDisplay:isMainDisplay:assertIfInvalid:]`, where it is type 4 (always-connected, not UIKit-main-like). BacklightServices and SpringBoard's embedded-scene gate both require type 0; FrontBoard's cloning source requires that only Main be main-like. Result on duospike-inner: always-connected `{Main, Unknown[7]}`, inner scenes on `Unknown[7]`, PosterKit `DISPLAY_TYPE_AUX` with dynamic rotation, SpringBoard stable. Details in `Research/Guest/iphone_duo_bringup.md`.

> **CoverSheet native metrics probe (2026-10-27):** Static UIKit analysis of `UICoverSheetButton` identifies `_contentView` (`UIImageView`), `_image`, `_selectedImage`, `imageContentMode`, and `edgeInsets` as the real glyph layout inputs. Runtime inspection of `UIApplication.windows` while locked found no live `UICoverSheetButton` instances, so no scale was applied. The source now records the native metrics entry points and live hierarchy count; a guessed transform remains disabled.

> **Native Duo quick-action metrics (2026-10-27):** The real lock-screen classes are `CSQuickActionImageGlyphView` and `CSQuickActionsButton`, not `UICoverSheetButton`. Runtime SpringBoard evidence captured native initializer values: button diameter 58pt; camera symbol scale 0.31648; flashlight symbol scale 0.368; button frame 84pt with icon image frame 48pt. Temporary lifecycle/metrics probes were removed from the source after capture; no guessed scale or transform is shipped.

> **Duo quick-action profile evidence (2026-10-27):** The real initializer path supplies button diameter 58pt and per-symbol scales (questionmark 0.368, camera 0.31648, flashlight 0.368). `CSQuickActionsButton` reports iconContentScale=1, iconImageSize=48pt, and native iconImageFrame 48pt inside the 84pt button. These values are now the authoritative runtime baseline; all temporary probes were removed and no guessed scaling is shipped.

> **QuickAction profile resolution (2026-10-27):** The native `CSQuickActionsButton` class method and glyph initializers were traced at runtime. The active Duo scene resolves `buttonDiameter=58`, `iconContentScale=1`, `iconImageSize=48`, camera `symbolScaleValue=0.31648`, and flashlight `symbolScaleValue=0.368`. These values originate in SpringBoard's profile path; no transform or replacement image was installed. The remaining icon-size discrepancy therefore belongs to profile selection/trait inputs, not a missing host scale conversion.

> **QuickAction profile investigation (2026-10-27):** The live Duo profile path was confirmed to construct `CSQuickActionImageGlyphView` with native scales and button diameter, while `CSQuickActionsButton` computes a 48pt icon frame inside an 84pt button. Runtime source/profile searches found no external QuickActions plist override; the remaining discrepancy is the SpringBoard profile/trait selection that supplies those native values. No arbitrary scale has been added.

> **Duo wallpaper admission startup correction (2026-10-27):** The round-16
> caller-scoped `PF_IS_PAD_DEVICE` landscape wallpaper gate and traits
> admission were previously armed only by a one-shot cache marker. Fresh boots
> could therefore return to the two-band path. For `iPhone19,4`, startup now
> installs the same gate unconditionally; the marker remains accepted for
> older guests. This changes admission only for the known Duo model and keeps
> the lock-screen wallpaper path unchanged.

> **Poster compositor follower (2026-10-28):** `libvphoneposterprobe.dylib`
> now coalesces orientation requests for hosted poster renderer processes and
> leaves the PosterBoard wallpaper editor untouched. It reads the settled
> daemon orientation notification before falling back to the map file and
> asks SpringBoard to reconcile newly-created floating poster hosts. The
> SpringBoard-side adapter preserves the editor's portrait bounds and centers
> it inside the landscape presenter, avoiding the repeated-request loading
> loop and the off-center sheet.

> **Duo display: two displays only (2026-10-29):** `system-springboard-cfw-fold_display` (now titled "Foldable inner display") keeps only the two-display path, and it is always on for iPhone19,4: `libvphonefolddisplay.dylib` checks `hw.machine` in backboardd and SpringBoard instead of the `vphone-duo-inner-display` marker. backboardd: the 2853x2007 `CAWindowServerVirtualDisplay` added from `-[CAWindowServer _detectDisplays]` (server-ready fallback), tagged `unknown`; `DeviceSurfaceType` 1 for the primary and 2 for the inner display through `-[CAWindowServerDisplay extendedProperties]`; `BKHIDDirectTouchEventProcessor` digitizer routing and the 270° position turn while the inner display is lit. SpringBoard: the CADisplay type/pointScale/isExternal adapter with the FrontBoard classification scope, `mainLike` in the inner identity's XPC encoding, the inner screen's idiom, the shared scanout (`-[CADisplayStateControl transitionToDisplayState:withCompletion:]`), the compositor, the content mode resolver hand-over (the resolver is now recorded by a pass-through `-[SBFDisplayContentModeResolver _startResolvingContentModeOfDisplay:]`), and the per-screen `STUIStatusBarGetVisualProviderClassForScreen` detour. Removed hooks: the Main configuration transformer, monitor and identity observers, `SBWindowScene surfaceType`/`sbhScreenType`, `SBWindow _shouldResizeWithScene`, the scene geometry callback, the clock and time-item adapters, the scene status policy, the Main status lookup and status profile factories, `SBHScreenTypeFor*`, `_os_feature_enabled_impl` (`TraitsArbiterWallpaperTokyoDrift`), `PF_IS_PAD_DEVICE`, `_SBWallpaperSecureWindow setHidden:`, the quick-action glyph subclass, the `UIWindow` target-window fallback, the `SBSDeviceDeterminedConfiguration`/`CSProminentLayoutController` loggers, and every `com.vphone.display.*` notification. `libvphoneposterprobe.dylib` (the poster orientation follower) is no longer built, staged, listed in the guest environment, or loaded by SystemHook. Details in `Research/Guest/iphone_duo_bringup.md`.

> **Duo display: flicker, capture and rotation (2026-10-29):** in `system-springboard-cfw-fold_display`, the compositor is now a layer at the top of Main's `UIRootSceneWindow` (points) instead of a display-level `CAContext` (pixels), its hosts sync from a main run loop observer before Core Animation's commit and change only when a value changes, and its per-frame damage alternates two clear colors. New SpringBoard hook: `+[CMMagicPoseManager orientationForMagicPose:deviceSurface:]` answers with `+[CMDeviceStateEvent propertyAForConfigType:propertyA:propertyB:propertyC:]` directly, because the guest has no `CMMagicPoseManager` shared manager and every panel read ambiguous, so neither panel rotated. vphoned's `display.rotation` on a foldable sets the pose orientation for the lit panel. Details in `Research/Guest/iphone_duo_bringup.md`.
