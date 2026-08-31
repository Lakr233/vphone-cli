# Host CMIO Virtual Camera Plan

## Scope

This document defines the alternative capture backend for publishing a VM's
display as a normal macOS Core Media I/O (CMIO) virtual camera. It is separate
from the Apple-native USB Valeria/Nero research path.

The target flow is:

```text
VM display -> host frame source -> CMIO camera extension -> QuickTime/AVFoundation
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
com.vphone.cli
com.vphone.camera
group.com.vphone.shared   # only if an App Group is needed
```

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

## Apple account, signing, and SIP

The Bundle ID strings themselves can be chosen without creating one ID per VM.
For a maintainable Camera System Extension that installs and is recognized by
QuickTime, plan on a paid Apple Developer Program account for:

1. explicit App IDs for the host app and extension;
2. provisioning profiles and the required system-extension/camera entitlements;
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

