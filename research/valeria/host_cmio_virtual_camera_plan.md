# Host CMIO Virtual Camera Plan

## Scope

This document defines the alternative capture backend for publishing a VM's
display as a normal macOS Core Media I/O (CMIO) virtual camera. It is separate
from the Apple-native USB Valeria/Nero research path.

The target flow is:

```text
VM display -> Host frame source -> CMIO camera extension -> QuickTime/AVFoundation
```

The backend must not modify or claim a physical iPhone's USB capture route.

## One combined view

The current panel, current recorder, proposed Host CMIO camera, and the native
Valeria layers share only the VM display as a possible frame source. L2-L4 are
native-capture control layers; L5-L7 are firmware/guest capability layers.

```text
                                        macOS Host
┌──────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│                         VZGraphicsDisplay                                   │
│                                │                                             │
│             ┌──────────────────┼──────────────────┐                          │
│             │                  │                  │                          │
│             v                  v                  v                          │
│   ┌─────────────────┐  ┌─────────────────┐  ┌──────────────────────────┐    │
│   │ Current panel    │  │ Current recorder │  │ New Host CMIO camera     │    │
│   │                 │  │                 │  │                          │    │
│   │ VZVirtual       │  │ private display  │  │ Host VM Frame Source     │    │
│   │ MachineView     │  │ screenshot       │  │                          │    │
│   │       │         │  │       │         │  │ IOSurface / CVPixelBuffer│    │
│   │       v         │  │       v         │  │ / shared-memory ring     │    │
│   │ vphone-cli       │  │ CGImage          │  │            │             │    │
│   │ window           │  │       │         │  │            v             │    │
│   └─────────────────┘  │       v         │  │ CMIO Camera System       │    │
│                        │ CVPixelBuffer   │  │ Extension                │    │
│                        │       │         │  │            │             │    │
│                        │       v         │  │            v             │    │
│                        │ AVAssetWriter   │  │ QuickTime / AVFoundation │    │
│                        │       │         │  │ / other camera clients   │    │
│                        │       v         │  └──────────────────────────┘    │
│                        │     .mov        │                                  │
│                        │   current 30fps │                                  │
│                        └─────────────────┘                                  │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
             ▲
             │ virtual graphics device
             │
┌────────────┴────────────┐
│ VM Guest                 │
│ iOS graphics/display     │
└─────────────────────────┘

Separate native USB route (not part of the Host CMIO route):

┌──────────────┐
│ VM / firmware │
└──────┬───────┘
       │ [L5-L7] firmware, Guest capability, device-shape work
       v
┌─────────────────────────┐
│ Apple USB / Valeria/Nero│
└──────────┬──────────────┘
           │ [L4] host admission/helper
           v
       [L3] daemon / lease
           │
           v
       [L2] capture/control
           │
           v
    QuickTime / PulsePhone native source
```

## Existing implementation boundaries

The panel attaches `VZVirtualMachineView` to the `VZVirtualMachine`. The
display object exposed by `VPhoneVirtualMachineView.recordingGraphicsDisplay`
is the common host-side source candidate.

The current recorder calls the private
`_takeScreenshotWithCompletionHandler:` selector, converts the result to a
`CVPixelBuffer`, and writes a `.mov` file with a fixed 30 FPS timer. This is a
useful first frame source for a prototype, but it is not a 60 FPS guarantee.

The existing `VPhoneCameraServer` has the opposite direction:

```text
Host test pattern/video -> vsock 1338 -> guest vphoned_vcam
    -> shared mmap/notify -> guest cameracaptured -> guest camera source
```

It does not publish the VM display as a macOS camera.

## Proposed Host CMIO backend

```text
VZGraphicsDisplay (in vphone-cli process)
        |
        v
Host VM Frame Source
  - initial prototype: reuse the existing display screenshot path
  - production direction: IOSurface/CVPixelBuffer ring with bounded copies
        |
        | XPC, IOSurface sharing, or a shared-memory ring
        v
CMIO Camera System Extension
  - one provider/device/stream per configured VM, or multiple VM streams
  - emits timestamped CVPixelBuffer/CMSampleBuffer frames
        |
        v
CoreMediaIO device registry
        |
        +--> QuickTime
        +--> AVFoundation clients
        `--> PulsePhone Live only if it accepts generic CMIO sources
```

The extension must bind every device or stream to a stable VM UUID. It must
not use camera enumeration order as VM identity. VM stop/disconnect must stop
the stream and release its route. A single fixed pair of Bundle IDs can serve
all VMs.

Suggested identifiers:

```text
com.vphone.cli                         # VM host app
com.vphone.cli.camera-installer        # separate System Extension host
com.vphone.cli.camera                  # Camera System Extension
```

The build does not require changing these source defaults. A registered team's
identifiers can be injected at build time:

```bash
APP_BUNDLE_ID=com.vp.vphone \
HOST_PROVISIONING_PROFILE=/absolute/path/vphoneDev.provisionprofile \
CAMERA_INSTALLER_PROVISIONING_PROFILE=/absolute/path/vphoneCameraInstallerDev.provisionprofile \
EXTENSION_PROVISIONING_PROFILE=/absolute/path/vphoneCameraDev.provisionprofile \
CODESIGN_IDENTITY='Apple Development: ...' \
./scripts/build.sh --no-vphoned
```

The derived identifiers are `${APP_BUNDLE_ID}.camera` and
`${APP_BUNDLE_ID}.camera-installer`. If `APP_BUNDLE_ID` is omitted, the
original `com.vphone.cli*` defaults remain in effect.

## L2-L7 applicability

For the Host-pull design:

```text
VM display -> Host frame source -> CMIO extension
```

L2-L4 are not used to carry pixels, and L5-L7 are not a prerequisite for the
camera transport. They may remain in the VM image for the native Valeria
backend or for unrelated boot/device-shape behavior, but the virtual-camera
backend must not depend on them.

L5-L7 become potentially necessary only for a different Guest-push design:

```text
Guest framebuffer -> privileged Guest producer -> vsock/shared memory
    -> Host CMIO extension
```

That design requires a Guest component capable of reading the framebuffer and
continuously producing frames. It is not required for Host-pull.

Keep the native backend and the virtual-camera backend as explicit modes:

```text
nativeValeria: L2-L7 as applicable
virtualCamera: skip L2-L7; use Host display frame source + CMIO
```

Do not delete the native research code until the new backend has passed its own
acceptance tests.

## Validation probes

Two checked-in probe scripts support this plan's acceptance flow. They are
diagnostics only and are not runtime dependencies of the CMIO extension:

- `research/valeria/host_cmio_avfoundation_probe.swift` checks that a published
  VPhone CMIO device is visible to AVFoundation and can deliver a sample frame.
- `research/valeria/host_cmio_multivm_probe.py` checks per-VM registration,
  loopback isolation, and the expected handshake/frame header for multiple
  simultaneous VM-labelled devices.

Use them when verifying that a build still exposes the right camera devices,
but keep them out of the product runtime path.

## Apple account, signing, and SIP

The Bundle ID strings themselves can be chosen without creating one ID per VM.
For a maintainable Camera System Extension that installs and is recognized by
QuickTime, plan on a paid Apple Developer Program account for:

1. explicit App IDs for the Camera Installer app and extension;
2. provisioning profiles and the required System Extension signing capability;
3. stable local installation and eventual Developer ID/notarized distribution.

Most host-side frame-source, IPC, test-pattern, and performance work can be
done before paying for the account. A free Personal Team may be useful for a
temporary local experiment, but its ability to sign and install this specific
Camera System Extension is not a supported assumption. SIP changes cannot
grant missing entitlements.

The current machine state has filesystem protection, kernel integrity, and
authenticated root enabled, with debugging restrictions disabled. That is
adequate from the SIP perspective for a normal CMIO extension; the custom SIP
state is relevant to the previous LLDB research hooks, not to camera-extension
entitlements.

### Developer Portal setup

This is the complete setup recipe for a new development team. The values below
are examples: choose one reverse-DNS prefix that you control and keep it
stable. Do not create an App ID per VM.

```text
APP_BUNDLE_ID=com.example.vphone
CAMERA_BUNDLE_ID=com.example.vphone.camera
CAMERA_INSTALLER_BUNDLE_ID=com.example.vphone.camera-installer
CAMERA_APP_GROUP=group.com.example.vphone.shared
```

In **Certificates, Identifiers & Profiles**, complete these steps in order:

1. Under **Identifiers**, create an **App Group** named
   `group.com.example.vphone.shared`.
2. Create three **explicit App IDs** (not wildcard IDs): the VPhone host app,
   the Camera Installer app, and the Camera Extension listed above.
3. Edit the VPhone host App ID and the Camera Extension App ID. Enable **App
   Groups** for each and assign the exact group created in step 1.
4. Edit the Camera Installer App ID and enable **System Extension**. Do not
   enable Camera for this software-generated provider.
5. Create one **Mac App Development** provisioning profile for each App ID.
   Select the same team's Apple Development certificate for all three, then
   download the profiles. Regenerate a profile whenever its App ID's
   capabilities change.

The Portal names are **App Groups** and **System Extension**. There is no
Portal capability named “CMIO Extension”, “`cmio.extension`”, “Virtualization”,
or “Network Client” for this setup. `com.apple.cmio.extension` belongs only in
the extension `Info.plist`; App Sandbox and Network Client are signed target
entitlements, not Portal checkboxes.

The current VPhone host uses private virtualization entitlements for the
research VM stack. An ordinary Apple Developer profile cannot grant those
private entitlements; their local execution-policy requirements remain separate
from this Camera Extension setup. Do not try to add them as invented Portal
capabilities. The ordinary CMIO signing path itself requires an enrolled Apple
Developer Program team; a free Personal Team is not a supported configuration
for this project.

Build with the downloaded profiles explicitly injected, leaving checked-in
bundle identifiers unchanged:

```bash
APP_BUNDLE_ID=com.example.vphone \
CAMERA_BUNDLE_ID=com.example.vphone.camera \
CAMERA_INSTALLER_BUNDLE_ID=com.example.vphone.camera-installer \
CAMERA_APP_GROUP=group.com.example.vphone.shared \
CODESIGN_IDENTITY='Apple Development: Your Name (TEAMID)' \
HOST_PROVISIONING_PROFILE=/absolute/path/vphone-host.provisionprofile \
CAMERA_INSTALLER_PROVISIONING_PROFILE=/absolute/path/vphone-camera-installer.provisionprofile \
EXTENSION_PROVISIONING_PROFILE=/absolute/path/vphone-camera.provisionprofile \
./scripts/build.sh
```

The build fails closed when the extension profile does not contain the exact
`CAMERA_APP_GROUP`. The host, extension, and installer must all be signed by
the same Team ID. Install both resulting apps in `/Applications` before
requesting activation.

### CMIO identifier versus entitlement

`com.apple.cmio.extension` is the `NSExtensionPointIdentifier` in the
extension's `Info.plist`. It is not a Developer Portal capability and should
not be added to an entitlements plist.

The similarly named
`com.apple.developer.cmio.extension = camera` entry is not used by this
software-generated VM-frame provider and is intentionally absent from
`sources/vphone-camera-extension.entitlements`. The extension does not open a
physical camera, so it also does not need
`com.apple.security.device.camera`. The Camera Extension profile must still
match the extension's App ID; the installer app is the target that needs
`com.apple.developer.system-extension.install`.

### Complete Bundle ID entitlement matrix

For the current host-pull implementation, use the following minimum sets.
These are target entitlements, not per-VM permissions:

| Bundle ID | Minimum entitlements in the signed target | Do not add for this design |
|---|---|---|
| `com.vp.vphone` | Existing VPhone host entitlements; the provisioned `com.apple.security.application-groups` value used for the registration directory | `com.apple.developer.system-extension.install`, Camera access, CMIO extension entitlement |
| `com.vp.vphone.camera-installer` | `com.apple.developer.system-extension.install = true` | Camera access, `com.apple.developer.cmio.extension` |
| `com.vp.vphone.camera` | `com.apple.security.app-sandbox = true`; `com.apple.security.network.client = true` for the loopback frame socket; one provisioned `com.apple.security.application-groups` value used as the Mach-service prefix | `com.apple.developer.cmio.extension`; `com.apple.security.device.camera` |

The extension point remains in `VPhoneCameraExtension-Info.plist`:

```xml
<key>NSExtensionPointIdentifier</key>
<string>com.apple.cmio.extension</string>
```

The provisioning profile for each target must have the matching App ID. A
profile may contain no special CMIO capability for the software-generated
frame provider. If physical-camera capture is added later, that is a separate
design change and may require the Camera capability
(`com.apple.security.device.camera`).

#### App Groups

Frame bytes remain on loopback TCP, but the host uses the App Group container
for its per-VM registration directory and macOS CMIO validation requires the
`CMIOExtensionMachServiceName` value to be prefixed by an App Group present in
the extension's signed entitlements and provisioning profile. The Xcode Camera
Extension template carries this entitlement, and `sysextd` rejects an extension
without it with `OSStatus -50` / `OSSystemExtensionErrorDomain:9`.

Use one stable, provisioned group for the host and extension, for example:

```text
group.com.example.vphone.shared
```

The generated service name is that group plus the extension suffix:

```text
group.com.example.vphone.shared.camera
```

The build accepts `CAMERA_APP_GROUP` for another exact, provisioned group and
fails closed when the downloaded extension profile does not list it. The
installer itself has no App Group entitlement in this implementation; assigning
the group to its Portal App ID is harmless but unnecessary.

## Delivery and acceptance order

1. Add a separate `virtual-camera` mode. It must skip native L2/L3/L4 setup.
2. Build the smallest signed CMIO extension and publish a moving test pattern.
3. Confirm QuickTime enumerates the source and receives timestamped frames.
4. Replace the test pattern with VM-A's Host-side display frame source.
5. Verify frame count, dropped frames, duplicate frames, timestamps, and stop/restart.
6. Add VM-B and verify VM-A/VM-B isolation while a physical iPhone remains unchanged.
7. Test PulsePhone Live independently; generic CMIO support must not be assumed.
8. Optimize toward 60 FPS only after the 30 FPS end-to-end path is stable.

The current 30 FPS recorder is a baseline only. Near-60 FPS operation requires
bounded buffering, low-copy pixel transport, non-main-thread work, and measured
delivered/dropped-frame statistics.

## Implementation milestone (feature/host-cmio-virtual-camera)

The first implementation milestone now lives in the main SwiftPM project:

* `VPhoneCameraShared` owns the versioned little-endian BGRA frame protocol.
* `vphone-camera-extension` publishes one CMIO camera device and pulls frames
  from the host over loopback TCP.
* `VPhoneVirtualCameraServer` reuses the existing `VZGraphicsDisplay` private
  screenshot accessor and only captures while the extension is connected.
* `vphone-camera-installer` is a small companion app with the only
  `com.apple.developer.system-extension.install` entitlement. It embeds the
  extension and is installed beside the VM app in `/Applications`.
* The extension's `CMIOExtensionMachServiceName` is generated as
  `<ProvisionedAppGroup>.<extension-suffix>`, and the exact App Group is
  injected into both the signed entitlements and the Info.plist.
* `vphone-cli boot --virtual-camera` (and `vm launch --virtual-camera`)
  automatically invokes that companion before VM boot, then deliberately skips
  the guest `VPhoneCameraServer` (the old vsock camera route).
* `scripts/build_camera_extension.sh` builds the separate
  `vphone-cli-camera-installer.app`, embedding and signing
  `Contents/Library/SystemExtensions/com.vphone.cli.camera.systemextension`.

The split is intentional: the VM host retains its existing Virtualization
signing boundary, while the companion uses the ordinary Camera/System Extension
profile. This prevents one provisioning profile from needing to combine
unrelated private-virtualization and System Extension permissions.

### First-run Camera Extension approval

The first `--virtual-camera` launch asks the companion installer to submit the
Camera System Extension activation request before VM boot. If macOS returns
`requestNeedsUserApproval`, this is a recoverable state rather than a failed VM
launch:

* the installer uses the same `AppIcon.icns` as `vphone-cli`; the only
  permission dialog is the macOS-owned system-extension dialog;
* the user selects that dialog's **Go to System Settings** action, then enables
  `VPhone Display` under **General → Login Items & Extensions → Camera
  Extensions**;
* it returns the explicit `awaiting approval` status; `vphone-cli` then starts
  the VM and keeps the per-VM frame endpoint ready;
* after the user enables the extension, CMIO clients can rediscover the source
  without booting the VM a second time. Later launches see the normal completed
  activation result and show no approval guidance.

This deliberately does not attempt to imitate the drag-and-drop flow used by
some TCC permissions such as Accessibility. A Camera System Extension has its
own macOS approval boundary; the user must still make that confirmation. The
implementation does not add a second app-owned dialog or rely on an
undocumented, version-specific Settings deep link. Activation errors other
than the approval callback remain fail-closed.

For repeatable first-run testing, the same installer also accepts
`--deactivate`. It submits the standard System Extension deactivation request
for only `com.vp.vphone.camera`; it does not touch VMs, USB devices, or other
extensions. macOS may report the extension as `terminated waiting to uninstall
on reboot`, which is the expected clean pre-approval state after the VMs have
been stopped and before restarting macOS.

The current implementation uses a per-VM registration keyed by the stable
`machineIdentifier`, with an ephemeral loopback TCP port and a generation
token. The CMIO provider refreshes this registry and publishes one device per
fresh VM registration, using the VM bundle name as the localized device name.
This prevents a second VM from binding or stealing the first VM's endpoint;
stale registrations are removed after the heartbeat expires. Full frame
isolation still requires each VM to expose a live `VZGraphicsDisplay`; a VM
left in DFU can register a camera device but cannot produce normal display
frames.

### CMIO-only display-off behavior

The host does not infer sleep state from a black `VZGraphicsDisplay` frame.
On this VM stack, the host can continue to receive a valid lock-screen image
after the iOS display has blanked, so treating a dark image as a disconnect
would be both inaccurate and unsafe for dark applications.

Instead, the virtual-camera host asks the guest `vphoned` control daemon for
the dynamic Darwin-notification state
`com.apple.springboard.hasBlankedScreen`. The guest query has these rules:

* it is runtime-only and does not link to a version-specific SpringBoard
  framework;
* only Boolean values are accepted; an unavailable registration or an
  unrecognized future value is reported as unknown;
* unknown means **continue CMIO frame delivery** — the implementation never
  invents `Video disconnected` from an unsupported OS state.

`VPhoneVirtualCameraServer` starts this query only while at least one CMIO
consumer is connected, at 4 Hz rather than once per video frame. When the
state becomes blanked it keeps the loopback socket and CMIO device registered
but stops emitting new sample packets. A CMIO client therefore retains the
last lock-screen sample and can report its normal no-sample state (PulsePhone
Live shows `Video disconnected` after its own liveness timeout). When the
display wakes, packet delivery resumes immediately. This code exists only
inside the `--virtual-camera` Host route: it does not change the normal
VPhone window, recorder, USB enumeration, PulsePhone, or L2-L7 research
paths.

On August 31, 2026 this was verified with two VMs: after VM-A blanked, reads
from `VPhone — iPhone26_5_2` timed out while VM-B remained independently
registered; waking VM-B restored its own 720x1560 BGRA frames without waking
or altering VM-A.

### Current signing gate

The original `OSSystemExtensionErrorDomain:9` investigation is resolved for
the active development build. The Camera Extension profile now contains the
provisioned App Group and the installed extension is active as
`GZC4TSS5TG com.vp.vphone.camera`. The host, installer, and extension are
signed with matching development profiles; the host's separate private
virtualization execution policy is handled by the existing local research
environment. This does not make ad-hoc signing a supported distribution path:
future distribution still requires correctly provisioned identifiers and a
normal Apple signing/notarization workflow.
