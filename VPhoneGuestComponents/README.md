# Sibling guest components

`make -C VPhoneGuestComponents package` cross-compiles guest components with
Xcode's iPhoneOS SDK (the HomePod adapter uses the tvOS SDK). The archive contains signed arm64e binaries, two camera
tweak filter plists, and the GPU provenance note:

| Component | Archive contents |
| --- | --- |
| Camera app hook | `camfix/libcamfix.dylib`, `camfix/libcamfix.plist` |
| Camera daemon hook | `vcamcaptured/libvcamcaptured.dylib`, `vcamcaptured/libvcamcaptured.plist` |
| Haptics fix | `hapticsfix/libhapticsfix.dylib` |
| Battery health fix | `batteryhealthfix/libbatteryhealthfix.dylib` |
| DeviceHub fix | `devicehubfix/libdevicehubfix.dylib` |
| Device name pin | `devicename/libdevicename.dylib` |
| Virtual gyroscope | `gyroscope/libvphonegyro.dylib` |
| Gravity accelerometer | `accelerometer/libvphoneaccelerometer.dylib` |
| Virtual hinge angle | `hinge/libvphonehinge.dylib` |
| Device attitude | `attitude/libvphoneattitude.dylib` |
| HomePod display identity | `homepoddisplay/libvphonehomepoddisplay.dylib` |
| HomePod setup maintenance | `homepodsetup/vphone-homepod-setup`, `homepodsetup/com.vphone.homepod-setup.plist` |
| Launchd hook | `launchhook/launchdhook-vphone.dylib` |
| Process injection bridge | `systemhook/SystemHook-vphone.dylib` |
| iOS 27 app registrar | `vpregister/vpregister` |
| PCC GPU driver | `gpu/README.md` (source and extraction flow; no Apple binary) |
| Virtio sound HAL plugin | `virtiosound/VPhoneVirtIOSound.driver` |

The archive is a local build artifact, not a VM bootstrap. `cfw install` places
the launchd hook, SystemHook, and camera hooks in `/usr/lib`, and the
vphoned environment update replaces changed copies in a running guest. SystemHook
loads `libvcamcaptured.dylib` into `/usr/libexec/cameracaptured` and
`libcamfix.dylib` into apps that have AVFoundation loaded; neither camera hook
needs ElleKit or a bootstrap. It loads `libhapticsfix.dylib` into SpringBoard,
where UIKit's feedback engine would otherwise die on the haptics hardware no
VM has. Both spawn hooks insert `libbatteryhealthfix.dylib` into Settings beside
SystemHook; it completes the internal battery's power source description with
the health keys a real battery has and answers the two questions only battery
hardware can, so Battery Health shows a healthy battery instead of loading
forever. Both also insert `libdevicename.dylib` into configd and lockdownd
(lockdownd takes it after `libmisfix.dylib`). It acts only when vphoned has
stored a name in `/var/db/vphone/devicename.plist` (the host sends the VM's
name after every connect): configd then publishes that name as the device name
and lockdownd refuses renames, while `preferences.plist` keeps the guest's own
name. See
`Research/Guest/device_name_pinning.md`.
After a bootstrap installs ElleKit, the launchd hook
inserts SystemHook into `xpcproxy`, bootstrap executables, and apps started
directly by launchd. Inside `xpcproxy`, SystemHook carries itself into the
final executable through `posix_spawnp`. Injected App and bootstrap processes
carry the hook to their child executables through `posix_spawn`, `posix_spawnp`,
and `execve`. SystemHook loads the selected bootstrap's
`usr/lib/TweakLoader.dylib` in App and bootstrap processes when it exists;
ElleKit owns tweak selection and loading. It logs PID and executable path to
`/var/mobile/Library/Caches/vphone-systemhook.log`, falling back to the app's
own `Library/Caches` when sandboxed.
`DISABLE_TWEAKS=1` and the safe-mode flags skip injection.
While a bootstrap is installed, both spawn hooks also triple the jetsam memory
limits a spawn carries, with Dopamine's exclusions, and restore the caller's
attributes afterwards (`Shared/JetsamLimits.h`).
Irisin installs ElleKit's own `TweakLoader.dylib` in the selected bootstrap.
The required GPU bundle is extracted from the selected PCC firmware by
`vphone-cli fw prepare` and copied into the VM during JB installation. No
Apple GPU binary is stored in this directory, the archive, or the shipped app.

See `Research/Guest/virtual_camera_transport.md` for the camera transport
validation and the hook installation prerequisites.

`system-backboardd-cfw-gyroscope` installs the optional gyro provider into
`/usr/lib`. SystemHook loads it only in backboardd; it publishes a HID service
using vphoned's `motion.gyroscope.set/get/clear` configuration. A live update
replaces installed copies only and requests a reboot without restarting the
UI daemon. `make test-gyroscope` checks its configuration transport. Guest
CoreMotion acceptance is still pending; see `Research/Guest/virtual_gyroscope.md`.

`system-backboardd-cfw-accelerometer` installs a stationary gravity HID service
in backboardd, selected independently of the gyro and app attitude providers.
It matches the built-in accelerometer usage (`0xff00`, `3`), emits real
accelerometer events on the requested report interval, and retains the device
pose selected by `display.rotation` across SpringBoard relaunches. A native
queue bridge supplies classified device orientation where the virtual board's
motion stack never subscribes to raw HID samples. The same library recomputes
SpringBoard's orientation gates after seeding the real backlight state. The read
form of `display.rotation` includes its configuration and provider status.
`make test-accelerometer` exercises gravity axes, the real HID event factory,
subscription changes and stale service callbacks without registering a host
sensor. See `Research/Guest/springboard_orientation_stuck.md` for evidence and
the language-change regression boundary.

`system-backboardd-cfw-hinge` installs `libvphonehinge.dylib`, also selected
independently and loaded only in backboardd. It publishes Apple's VM host
controls (primary usage page 0xFF61, usage 0x5B) and sends the angle and
device orientation configured by `display.posture` and `display.rotation` as
vendor-defined events carrying `IOCFSerialize`d `hinge-slider-control` and
`orientation-picker-control` dictionaries. locationd's device-state relay
turns them into the hinge-angle and device-state services CoreMotion reads
(`CoreMotion_DeviceStateRelay_Crane` 0xFF0C/0x21 and `_DeviceState`
0xFF0C/0x22), and SpringBoard and CoreDevice's hingeAngle stream read
CoreMotion. The relay only runs when the device tree carries the foldable
board's own product-id (`preboot-cfw-devicetree_foldable_product_id`), so on
any other guest the service sits unread. Foldable guests only; `make
test-hinge` checks the configuration transport and, on a Mac, the
dictionaries' serialization round trip, size and vendor-defined event.

`system-apps-cfw-attitude` installs `libvphoneattitude.dylib`, loaded by
SystemHook into apps. It supplies a stationary Core Motion pose through
`motion.attitude.set/get/clear`, independently of gyro angular velocity.
System UI services under `/System/Library/` and SpringBoard copies are excluded
by both SystemHook and the attitude dylib itself. Purely simulated subscriptions
never call native Core Motion stop before native start.
Removing the selected library and relaunching apps reverts the hook.
`make test-attitude` checks samples and the actual host Core Motion subscription
runtime. Guest validation is manual; see `Research/Guest/virtual_attitude.md`.

The virtio sound plugin is the CoreAudio half of the VM's virtio-snd device,
which iOS ships no driver for. audiomxd loads it when the kernel publishes
`AppleVirtIOSound`, and it publishes a speaker and a microphone device.
`make test-virtiosound` checks its format choice, its rings and how captured
frames are served, on the host. See `Research/Guest/virtio_sound.md` and
`Research/Guest/virtio_sound_microphone.md`.

`FlutterRemapFix` is linked into SystemHook for early handling of a specific
Flutter AOT callback remap permission mismatch. It checks canonical same-bundle
images, native parameters and actual permissions before making a private copy
and transitioning RW to RX. It does not alter kernel policy. Tests and coverage
limits are in `Research/Guest/flutter_aot_remap_compatibility.md`.
