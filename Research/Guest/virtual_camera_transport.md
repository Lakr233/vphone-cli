# Virtual camera transport and capture hooks

## Runtime boundary

The host camera server sends BGRA frames over VSOCK port 1338. `vphoned`
receives them, writes a sequence guarded shared memory frame, and posts
`com.vphone.vcam.frame`. The optional `libvcamcaptured` hook reads that frame
and supplies it to camera clients. The host's **Camera server: connected**
status confirms the VSOCK connection only. It does not confirm that a camera
app or the capture hook is installed, loaded, or showing a preview.

The shared protocol and runtime paths are in
`VPhoneGuestComponents/VCamCaptured/VCamFrameProtocol.h`. All camera runtime
files live in `/var/mobile/Media/SimulatedCamera`: the shared frame
`vphone-vcam-frame.shm`, daemon log `vphone-vcam.log`, hook logs
`vcamcaptured.log` and `camfix.log`, and synthetic photo diagnostic
`vphone-synth-photo.bgra`. `vphoned` waits for the mobile home to be ready,
creates the directory with the mobile account as owner, and then opens the
shared file and binds port 1338. If setup fails during early boot, the
listener retries.

## Failure observed before the media path change

On 2026-09-24, the old daemon required a shared file and log under a directory
that this VM did not have. Shared memory initialization failed before the
VSOCK listener started. Its diagnostic went to the same nonexistent directory.
The host repeatedly logged POSIX error 54, `Connection reset by peer`. The
camera transport now uses the mobile media directory directly, without
installation-layout detection. A system log fallback retains diagnostics when
file logging fails.

At the 2026-09-24 transport test, the camera hook dylibs were not installed or
loaded. Since 2026-09-25, `cfw install` and the vphoned environment update
place both hooks in `/usr/lib`, and SystemHook loads them without a bootstrap;
see the camera hook note in `Research/0_binary_patch_comparison.md`. The
remainder of this section describes the earlier state. An initial check of fixed application directories also missed
Camera.app, but a later app registration query found
`com.apple.camera` in an application container under
`/private/var/containers/Bundle/Application`. The guest component archive
builds the camera hooks but does not install them; see
`VPhoneGuestComponents/README.md`. Camera.app preview and still/video capture
were therefore unverified.

## Transport acceptance on the media directory

On 2026-09-24, the integrated VM exposed `127.0.0.1:8765` for its guest API.
`/var/mobile/Media/SimulatedCamera/vphone-vcam.log` showed
`listening on vsock 1338`, `client connected`, and published frame counts.
The host Camera menu showed **Camera server: connected**. Shared memory was
read back through `GET /v1/files/content` with its `path` query set to
`/var/mobile/Media/SimulatedCamera/vphone-vcam-frame.shm`.

| Source and action | Shared memory observation |
| --- | --- |
| Test Pattern, streaming | Two samples were 8,388,672 bytes each. Frame index increased from 305 to 469 and the file hash changed. The header described 1280×720 BGRA, 5,120 bytes per row, and 3,686,400 pixel bytes. |
| Stop Streaming | Frame index remained 622 and the complete shared file hash stayed identical across two samples. |
| Video File, streaming | A generated 320×180 MOV was selected in the host menu. Frame index increased from 750 to 888 and the pixel payload hash changed. |
| Source: Off | Frame index remained 1,628 and the complete file hash stayed identical across two samples. The host menu returned to **Start Streaming**. |

This verifies the host-to-guest transport and shared frame publication,
including source selection and stopping. A full camera acceptance test still
needs a supported hook loading path: verify the hook is loaded, open
Camera.app's preview, compare visible frames against Test Pattern and Video
File, then test still and video capture separately. After the relocated path
passed its guest test, the stale
`/var/mobile/Library/vphone-vcam-frame.shm` and
`/var/mobile/Library/vphone-vcam.log` files from the earlier build were
removed through the guest API. A subsequent directory listing contained
neither file.
