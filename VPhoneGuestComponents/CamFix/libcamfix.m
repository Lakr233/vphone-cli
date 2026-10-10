/*
 * libcamfix — optional injection hook for Camera.app (com.apple.camera).
 *
 * Our virtual camera has no daemon-side still or preview pipeline behind it,
 * so AVFoundation's own paths crash, throw, or render black. The hooks
 * installed by cfx_install_all_hooks substitute our own:
 *
 * 1. -[AVCaptureFigVideoDevice _setActiveFormat:...]: suppress the crash
 *    when the device is our virtual camera and the format argument is nil.
 *    Camera.app's session-preset → format lookup returns nil for our synth
 *    because no preset matches our published formats exactly. Substitute
 *    the device's first supported format instead.
 *    (Device/CamFixActiveFormat.m)
 *
 * 2. -[AVCapturePhotoOutput capturePhotoWithSettings:delegate:]: when the
 *    photo output is bound to our virtual camera, read
 *    the vphoned shared frame file and fire the modern
 *    didFinishProcessingPhoto:error: delegate with an AVCapturePhoto built
 *    from that frame; JPEG encoding happens client-side via ImageIO. The
 *    deprecated CMSampleBuffer delegate is the fallback, taken only for a
 *    client that implements nothing else. If this hook fails, the capture
 *    path falls back to the original AVF code path (which would re-throw /
 *    error out).
 *    (Photo/CamFixCapturePhoto.m)
 *
 * 3. The moment-capture trio (begin / commit / cancelMomentCapture):
 *    Camera.app's shutter path. For our virtual camera the original is
 *    deliberately never called — it throws — so AVF's state stays clean and
 *    subsequent shutter taps don't compound corruption.
 *    (Photo/CamFixMomentCapture.m)
 *
 * 4. AVCaptureSession's _setRunning: / _setInterrupted: guards and its
 *    isRunning / isInterrupted getters: keep a vcam-bound session live
 *    although no sample buffers ever flow through it.
 *    (Session/CamFixSessionGuards.m)
 *
 * 5. The AVCaptureVideoPreviewLayer pump and its scan timer: push CGImage
 *    frames into CALayer.contents, since nothing feeds the layer otherwise.
 *    (Preview/CamFixPreviewLayers.m, fed by Preview/CamFixGraphTap.m)
 *
 * 6. AVCapturePhoto's -fileDataRepresentation / -CGImageRepresentation: hand
 *    back the bytes stamped onto the photos we synthesized.
 *    (Photo/CamFixPhotoSynthesis.m)
 *
 * 7. CAMStillImageCaptureRequest stubs for the accessors Camera.app's
 *    capture engine reads off a request.
 *    (Photo/CamFixMomentCapture.m)
 *
 * 8. AVCaptureVideoDataOutput delivery for vcam sessions whose capture graph
 *    never runs, at the size, orientation and pixel format the session and
 *    connection ask for. (Session/CamFixVideoDelivery.m,
 *    Frame/CamFixFrameGeometry.c)
 *
 * 9. Front-camera alias: an empty front or back device lookup gets the vcam
 *    device, whose position follows the side asked for.
 *    (Device/CamFixFrontCamera.m)
 *
 * 10. Exposure state: aperture, ISO, exposure and frame durations on the vcam
 *     device, and the same numbers in each delivered frame's {Exif}.
 *     (Device/CamFixExposure.m)
 *
 * 11. -[AVCaptureVideoDataOutput recommendedVideoSettingsForAssetWriterWithOutputFileType:]:
 *     H.264 at the delivered size instead of 0x0.
 *     (Session/CamFixAssetWriterSettings.m)
 *
 * Frames come from the vphoned shared frame file through the shared data
 * plane (Frame/CamFixFrameSource.m). Diagnostics go to the shared camera
 * media directory, written by cfxlog.
 */

#import "CamFixPrivate.h"
#include <mach-o/dyld.h>
#include <mach-o/loader.h>

// When libcamfix is loaded as an LC_LOAD_DYLIB dependency of AVFoundation
// (via the DSC patch cfw_patch_avf_load_dylib.py), our constructor fires
// during dyld's image-load phase — possibly BEFORE AVFCapture's classes
// are registered. Defer hook installation to a dyld add-image callback
// that fires once for every image. Install hooks the first time we see
// AVFCapture (the framework that actually defines AVCapture*),  which
// guarantees its classes are registered. Idempotent: install at most once.

static dispatch_once_t cfx_install_once_token;

static void cfx_install_all_hooks(void) {
  dispatch_once(&cfx_install_once_token, ^{
    cfxlog(@"installing hooks (process=%@, pid=%d)",
           NSProcessInfo.processInfo.processName ?: @"?", getpid());
    cfx_install_setActiveFormat_hook();
    cfx_install_front_camera_alias();
    cfx_install_exposure_hooks();
    cfx_install_asset_writer_settings();
    cfx_install_capturePhoto_hook();
    cfx_install_moment_capture_hooks();
    cfx_install_session_guards();
    cfx_install_input_diagnostics();
    cfx_install_session_state_lies();
    cfx_install_preview_layer_hooks();
    cfx_install_photo_representation_hooks();
    cfx_install_capturerequest_stubs();
    cfx_install_remote_queue_tap();
    // The 1 Hz preview layer scan starts with the first running vcam session
    // (Session/CamFixSessionGuards.m), not here: this hook also loads into
    // SpringBoard, PosterBoard and every widget extension that links
    // AVFoundation, and an always-on scan woke each of their main threads
    // once a second to walk its whole layer tree.
  });
}

static BOOL cfx_image_is_avfcapture(const struct mach_header *mh) {
  // dyld add-image callback gives us only the load address; recover the
  // install path via dyld_image_count + dyld_get_image_header iteration.
  uint32_t count = _dyld_image_count();
  for (uint32_t i = 0; i < count; i++) {
    if (_dyld_get_image_header(i) != mh) continue;
    const char *name = _dyld_get_image_name(i);
    if (!name) return NO;
    // AVFCapture lives at .../PrivateFrameworks/AVFCapture.framework/AVFCapture
    return strstr(name, "/AVFCapture.framework/AVFCapture") != NULL;
  }
  return NO;
}

static void cfx_on_add_image(const struct mach_header *mh, intptr_t slide) {
  (void)slide;
  if (cfx_image_is_avfcapture(mh)) cfx_install_all_hooks();
}

__attribute__((constructor))
static void cfx_init(void) {
  cfxlog(@"libcamfix loaded into %@ (pid=%d)",
         NSProcessInfo.processInfo.processName ?: @"?", getpid());
  // _dyld_register_func_for_add_image fires the callback synchronously
  // for every already-loaded image, then once per future image. So
  // whether AVFCapture loads before or after libcamfix, we catch it.
  _dyld_register_func_for_add_image(cfx_on_add_image);
}
