/*
 * libcamfix — substrate-injected into Camera.app (com.apple.camera).
 *
 * 1. Suppress the -[AVCaptureFigVideoDevice _setActiveFormat:...] crash
 *    when the device is our virtual camera and the format argument is nil.
 *    Camera.app's session-preset → format lookup returns nil for our synth
 *    because no preset matches our published formats exactly. Substitute
 *    the device's first supported format instead.
 *
 * 2. Same -[AVCapturePhotoOutput capturePhotoWithSettings:delegate:] swizzle
 *    as libcameratest: when the photo output is bound to our virtual camera,
 *    read /var/jb/var/mobile/Library/vphone-vcam-frame.shm, build a
 *    CMSampleBuffer, and async-fire the deprecated delegate method with the
 *    sample buffer. JPEG-encoded delivery happens client-side via ImageIO.
 *
 * Failure mode if either hook fails: capture path falls back to the original
 * AVF code path (which would re-throw / error out). All logging goes to
 * /var/mobile/Library/Logs/CrashReporter/camfix.log via NSLog (Camera.app
 * has Apple's TCC access to that area).
 */

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Photos/Photos.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <string.h>

#define LOG_PATH "/tmp/camfix.log"
#define SHM_PATH "/var/jb/var/mobile/Library/vphone-vcam-frame.shm"
#define VCAM_UID @"vphone:vcam:0"

#define CFX_SHM_HEADER_SIZE 64
typedef struct __attribute__((packed)) {
  uint64_t seq;
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;
  uint32_t pixel_format;
  uint32_t _reserved;
  uint64_t timestamp_ns;
  uint64_t frame_index;
  uint32_t pixels_length;
  uint32_t _pad;
} cfx_shm_header_t;

static void cfxlog(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  FILE *fp = fopen(LOG_PATH, "a");
  if (fp) {
    fprintf(fp, "[camfix:%d] %s\n", getpid(), line.UTF8String ?: "?");
    fclose(fp);
  }
}

// MARK: - shm reader

static int cfx_shm_fd = -1;
static const uint8_t *cfx_shm_base = NULL;
static size_t cfx_shm_size = 0;

static BOOL cfx_shm_open(void) {
  if (cfx_shm_base) return YES;
  cfx_shm_fd = open(SHM_PATH, O_RDONLY);
  if (cfx_shm_fd < 0) {
    cfxlog(@"shm open failed: %s (errno=%d)", SHM_PATH, errno);
    return NO;
  }
  struct stat st;
  if (fstat(cfx_shm_fd, &st) < 0) {
    close(cfx_shm_fd); cfx_shm_fd = -1; return NO;
  }
  cfx_shm_size = (size_t)st.st_size;
  void *p = mmap(NULL, cfx_shm_size, PROT_READ, MAP_SHARED, cfx_shm_fd, 0);
  if (p == MAP_FAILED) {
    close(cfx_shm_fd); cfx_shm_fd = -1; return NO;
  }
  cfx_shm_base = (const uint8_t *)p;
  cfxlog(@"shm mapped %s size=%zu", SHM_PATH, cfx_shm_size);
  return YES;
}

static void cfx_release_bytes(void *refcon, const void *base) {
  (void)refcon;
  free((void *)base);
}

static void cfx_cg_release_data(void *info, const void *data, size_t size) {
  (void)info; (void)size;
  free((void *)data);
}

static CMSampleBufferRef cfx_build_cmsb(void) {
  if (!cfx_shm_open()) return NULL;
  const cfx_shm_header_t *hdr = (const cfx_shm_header_t *)cfx_shm_base;
  uint32_t w = hdr->width, h = hdr->height, bpr = hdr->bytes_per_row;
  if (!w || !h || !bpr) { cfxlog(@"shm header zeros"); return NULL; }
  size_t len = (size_t)bpr * h;
  if ((size_t)CFX_SHM_HEADER_SIZE + len > cfx_shm_size) {
    cfxlog(@"shm: pixel range exceeds mapping"); return NULL;
  }
  void *pixels = malloc(len);
  if (!pixels) return NULL;
  memcpy(pixels, cfx_shm_base + CFX_SHM_HEADER_SIZE, len);

  CVPixelBufferRef pb = NULL;
  CVReturn cvr = CVPixelBufferCreateWithBytes(
      kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
      pixels, bpr, cfx_release_bytes, NULL, NULL, &pb);
  if (cvr != kCVReturnSuccess || !pb) { free(pixels); return NULL; }
  CMVideoFormatDescriptionRef desc = NULL;
  OSStatus s = CMVideoFormatDescriptionCreateForImageBuffer(
      kCFAllocatorDefault, pb, &desc);
  if (s != noErr || !desc) { CVPixelBufferRelease(pb); return NULL; }
  CMSampleTimingInfo timing = {
      .duration = CMTimeMake(1, 30),
      .presentationTimeStamp = CMTimeMake((int64_t)hdr->timestamp_ns, 1000000000),
      .decodeTimeStamp = kCMTimeInvalid,
  };
  CMSampleBufferRef cmsb = NULL;
  s = CMSampleBufferCreateForImageBuffer(
      kCFAllocatorDefault, pb, true, NULL, NULL, desc, &timing, &cmsb);
  CFRelease(desc);
  CVPixelBufferRelease(pb);
  return (s == noErr) ? cmsb : NULL;
}

// MARK: - _setActiveFormat: nil-format guard

static IMP cfx_orig_setActiveFormat = NULL;

// Signature: void(*)(id self, SEL _cmd, AVCaptureDeviceFormat *fmt,
//                    BOOL resetZoomAndFrameRates, NSString *preset)
static void cfx_setActiveFormat_hook(id self, SEL _cmd, id fmt,
                                       BOOL resetZoomAndFrameRates,
                                       NSString *preset) {
  if (!fmt) {
    NSString *uid = nil;
    @try { uid = [self valueForKey:@"uniqueID"]; } @catch (NSException *e) {}
    cfxlog(@"[setActiveFormat:nil] device.uid=%@ preset=%@", uid, preset);
    if ([uid isEqualToString:VCAM_UID]) {
      // Substitute the first available format from the device's -formats list.
      NSArray *fmts = nil;
      @try { fmts = [self valueForKey:@"formats"]; } @catch (NSException *e) {}
      if (fmts.count > 0) {
        fmt = fmts.firstObject;
        cfxlog(@"[setActiveFormat:] substituted first format: %@", fmt);
      } else {
        cfxlog(@"[setActiveFormat:] device.formats is empty — letting AVF throw");
      }
    }
  }
  typedef void (*OrigFn)(id, SEL, id, BOOL, NSString *);
  ((OrigFn)cfx_orig_setActiveFormat)(self, _cmd, fmt, resetZoomAndFrameRates, preset);
}

static void cfx_install_setActiveFormat_hook(void) {
  Class cls = NSClassFromString(@"AVCaptureFigVideoDevice");
  if (!cls) { cfxlog(@"AVCaptureFigVideoDevice missing"); return; }
  SEL sel = NSSelectorFromString(
      @"_setActiveFormat:resetVideoZoomFactorAndMinMaxFrameDurations:sessionPreset:");
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) {
    cfxlog(@"_setActiveFormat: method not in objc table");
    return;
  }
  cfx_orig_setActiveFormat =
      method_setImplementation(m, (IMP)cfx_setActiveFormat_hook);
  cfxlog(@"installed _setActiveFormat: hook (orig=%p)",
         cfx_orig_setActiveFormat);
}

// MARK: - capturePhoto swizzle (modern + deprecated delegate paths)

static IMP cfx_orig_capturePhoto = NULL;

// Forward decls: helpers defined further down — shared with the
// moment-capture (Camera.app) delivery path.
static IOSurfaceRef cfx_build_iosurface_from_shm(uint32_t *outW, uint32_t *outH) CF_RETURNS_RETAINED;
static CGImageRef cfx_build_cgimage_from_shm(uint32_t *outW, uint32_t *outH) CF_RETURNS_RETAINED;
static NSData *cfx_build_jpeg_from_shm(uint32_t *outW, uint32_t *outH);
static id cfx_build_avcapturephoto_with_request(IOSurfaceRef surf,
                                                uint32_t w, uint32_t h,
                                                id captureRequest);

// Associated-object keys (used by fileDataRepresentation /
// CGImageRepresentation hooks to recognize "our" photos). Defined here
// so cfx_deliver_capturePhoto can reference them before the hooks that
// also use them are declared further down.
static const void *CFX_ASSOC_JPEG_KEY = &CFX_ASSOC_JPEG_KEY;
static const void *CFX_ASSOC_CGIMG_KEY = &CFX_ASSOC_CGIMG_KEY;

static void cfx_deliver_capturePhoto(id output, id delegate, id settings) {
  // Modern path used by any AVF client: build a real AVCapturePhoto from
  // the shm frame, tag it with our JPEG + CGImage so fileDataRepresentation
  // / CGImageRepresentation return our bytes, fire the modern delegate
  // didFinishProcessingPhoto:error:.
  // Falls back to the deprecated CMSampleBuffer delegate if the client
  // opts into it (only test harnesses do; production AVF clients implement
  // the modern method).
  SEL oldSel = NSSelectorFromString(
      @"captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:");
  if ([delegate respondsToSelector:oldSel]) {
    CMSampleBufferRef sbuf = cfx_build_cmsb();
    if (!sbuf) { cfxlog(@"[capturePhoto] build_cmsb returned NULL"); return; }
    cfxlog(@"[capturePhoto] dispatching deprecated didFinishProcessingPhotoSampleBuffer:");
    ((void (*)(id, SEL, id, CMSampleBufferRef, CMSampleBufferRef, id, id, id))objc_msgSend)(
        delegate, oldSel, output, sbuf, NULL, (id)nil, (id)nil, (id)nil);
    CFRelease(sbuf);
    return;
  }

  SEL S5 = @selector(captureOutput:didFinishProcessingPhoto:error:);
  if (![delegate respondsToSelector:S5]) {
    cfxlog(@"[capturePhoto] delegate implements neither modern nor deprecated method");
    return;
  }

  uint32_t w = 0, h = 0;
  IOSurfaceRef surf = cfx_build_iosurface_from_shm(&w, &h);
  if (!surf) { cfxlog(@"[capturePhoto] no IOSurface"); return; }

  // captureRequest = nil (no CAMCaptureEngine outside Camera.app). The
  // AVCapturePhoto init handles nil safely — objc_msgSend on nil returns 0
  // for the resolvedSettings / unresolvedSettings calls it makes during init.
  id photo = cfx_build_avcapturephoto_with_request(surf, w, h, nil);
  CFRelease(surf);
  if (!photo) { cfxlog(@"[capturePhoto] no AVCapturePhoto"); return; }

  NSData *jpeg = cfx_build_jpeg_from_shm(NULL, NULL);
  CGImageRef cgImg = cfx_build_cgimage_from_shm(NULL, NULL);
  if (jpeg) objc_setAssociatedObject(photo, CFX_ASSOC_JPEG_KEY, jpeg,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (cgImg) {
    objc_setAssociatedObject(photo, CFX_ASSOC_CGIMG_KEY,
                             (__bridge id)cgImg,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGImageRelease(cgImg);
  }
  cfxlog(@"[capturePhoto] firing didFinishProcessingPhoto: with vcam photo (%lu bytes jpeg)",
         (unsigned long)jpeg.length);
  ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, S5, output, photo, nil);
}

static void cfx_capturePhoto_hook(id self, SEL _cmd, id settings, id delegate) {
  cfxlog(@"[capturePhoto] self=%p settings=%@ delegate=%@",
         self, settings, delegate);
  BOOL forVcam = NO;
  @try {
    NSArray *conns = [self valueForKey:@"connections"];
    for (AVCaptureConnection *conn in conns) {
      for (AVCaptureInputPort *port in conn.inputPorts) {
        id input = port.input;
        if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
          AVCaptureDevice *d = ((AVCaptureDeviceInput *)input).device;
          if ([d.uniqueID isEqualToString:VCAM_UID]) { forVcam = YES; break; }
        }
      }
      if (forVcam) break;
    }
  } @catch (NSException *e) {
    cfxlog(@"connection probe exception: %@", e);
  }
  cfxlog(@"forVcam=%d", forVcam);

  if (!forVcam) {
    typedef void (*OrigFn)(id, SEL, id, id);
    ((OrigFn)cfx_orig_capturePhoto)(self, _cmd, settings, delegate);
    return;
  }
  __strong id retainedSelf = self;
  __strong id retainedDelegate = delegate;
  __strong id retainedSettings = settings;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      cfx_deliver_capturePhoto(retainedSelf, retainedDelegate, retainedSettings);
    }
  });
}

static void cfx_install_capturePhoto_hook(void) {
  Class cls = NSClassFromString(@"AVCapturePhotoOutput");
  if (!cls) { cfxlog(@"AVCapturePhotoOutput missing"); return; }
  SEL sel = @selector(capturePhotoWithSettings:delegate:);
  Method m = class_getInstanceMethod(cls, sel);
  if (!m) { cfxlog(@"capturePhotoWithSettings:delegate: not found"); return; }
  cfx_orig_capturePhoto = method_setImplementation(m, (IMP)cfx_capturePhoto_hook);
  cfxlog(@"installed capturePhoto hook (orig=%p)", cfx_orig_capturePhoto);
}

// MARK: - AVCaptureVideoPreviewLayer.contents pump
//
// AVCaptureVideoPreviewLayer is a CALayer subclass that normally displays
// the camera's preview via internal IOSurface plumbing fed by the daemon.
// For our virtual camera, no daemon-side preview pipeline is built, so the
// layer stays black.
//
// Workaround: capture each AVCaptureVideoPreviewLayer instance bound to
// our virtual camera, and pump CGImage frames into its `contents` property
// at 30 Hz from a background timer. CALayer rendering picks the image up
// without needing the underlying AVF preview infrastructure.

static NSHashTable *cfx_preview_layers = nil;
static dispatch_source_t cfx_preview_timer = NULL;
static IMP cfx_orig_pv_initWithSession = NULL;
static IMP cfx_orig_pv_initWithSessionMakeConnection = NULL;

static CGImageRef cfx_make_cgimage_from_shm(void) CF_RETURNS_RETAINED;
static CGImageRef cfx_make_cgimage_from_shm(void) {
  if (!cfx_shm_open()) return NULL;
  const cfx_shm_header_t *hdr = (const cfx_shm_header_t *)cfx_shm_base;
  uint32_t w = hdr->width, h = hdr->height, bpr = hdr->bytes_per_row;
  if (!w || !h || !bpr) return NULL;
  size_t len = (size_t)bpr * h;
  if ((size_t)CFX_SHM_HEADER_SIZE + len > cfx_shm_size) return NULL;
  CFDataRef data = CFDataCreate(kCFAllocatorDefault,
                                  cfx_shm_base + CFX_SHM_HEADER_SIZE, len);
  if (!data) return NULL;
  CGDataProviderRef prov = CGDataProviderCreateWithCFData(data);
  CFRelease(data);
  if (!prov) return NULL;
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  // BGRA byte order = kCGImageAlphaPremultipliedFirst + kCGBitmapByteOrder32Little
  CGImageRef img = CGImageCreate(
      w, h, 8, 32, bpr, cs,
      kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
      prov, NULL, false, kCGRenderingIntentDefault);
  CGColorSpaceRelease(cs);
  CGDataProviderRelease(prov);
  return img;
}

static void cfx_pump_preview_once(void) {
  if (!cfx_preview_layers || cfx_preview_layers.count == 0) return;
  CGImageRef img = cfx_make_cgimage_from_shm();
  if (!img) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    for (CALayer *layer in cfx_preview_layers) {
      layer.contents = (__bridge id)img;
      layer.contentsGravity = kCAGravityResizeAspectFill;
    }
    CGImageRelease(img);
  });
}

static void cfx_preview_start_timer(void) {
  if (cfx_preview_timer) return;
  dispatch_queue_t q = dispatch_queue_create("com.vphone.camfix.preview", DISPATCH_QUEUE_SERIAL);
  cfx_preview_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  dispatch_source_set_timer(cfx_preview_timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              33333333ull, 2000000ull);
  dispatch_source_set_event_handler(cfx_preview_timer, ^{
    @autoreleasepool { cfx_pump_preview_once(); }
  });
  dispatch_resume(cfx_preview_timer);
  cfxlog(@"preview pump armed (30 Hz)");
}

static BOOL cfx_session_is_for_vcam(AVCaptureSession *session) {
  @try {
    for (AVCaptureInput *inp in session.inputs) {
      if ([inp isKindOfClass:[AVCaptureDeviceInput class]]) {
        AVCaptureDevice *d = ((AVCaptureDeviceInput *)inp).device;
        if ([d.uniqueID isEqualToString:VCAM_UID]) return YES;
      }
    }
  } @catch (NSException *e) {}
  return NO;
}

__attribute__((ns_returns_retained))
static id cfx_pv_initWithSession_hook(id self, SEL _cmd, AVCaptureSession *session) {
  typedef id (*Fn)(id, SEL, AVCaptureSession *);
  id ret = ((Fn)cfx_orig_pv_initWithSession)(self, _cmd, session);
  BOOL forVcam = (session != nil) && cfx_session_is_for_vcam(session);
  cfxlog(@"[PVLayer initWithSession:%p] ret=%p forVcam=%d cls=%@",
         session, ret, forVcam, NSStringFromClass([ret class]));
  if (ret && forVcam) {
    if (!cfx_preview_layers) cfx_preview_layers = [NSHashTable weakObjectsHashTable];
    [cfx_preview_layers addObject:ret];
    cfx_preview_start_timer();
  }
  return ret;
}

__attribute__((ns_returns_retained))
static id cfx_pv_initWithSessionMakeConnection_hook(id self, SEL _cmd,
                                                      AVCaptureSession *session,
                                                      BOOL makeConnection) {
  typedef id (*Fn)(id, SEL, AVCaptureSession *, BOOL);
  id ret = ((Fn)cfx_orig_pv_initWithSessionMakeConnection)(
      self, _cmd, session, makeConnection);
  BOOL forVcam = (session != nil) && cfx_session_is_for_vcam(session);
  cfxlog(@"[PVLayer _initWithSession:%p makeConnection:%d] ret=%p forVcam=%d cls=%@",
         session, makeConnection, ret, forVcam, NSStringFromClass([ret class]));
  if (ret && forVcam) {
    if (!cfx_preview_layers) cfx_preview_layers = [NSHashTable weakObjectsHashTable];
    [cfx_preview_layers addObject:ret];
    cfx_preview_start_timer();
  }
  return ret;
}

static IMP cfx_orig_pv_setSession = NULL;
static void cfx_pv_setSession_hook(id self, SEL _cmd, AVCaptureSession *session) {
  typedef void (*Fn)(id, SEL, AVCaptureSession *);
  ((Fn)cfx_orig_pv_setSession)(self, _cmd, session);
  BOOL forVcam = (session != nil) && cfx_session_is_for_vcam(session);
  cfxlog(@"[PVLayer setSession:%p] self=%p forVcam=%d cls=%@",
         session, self, forVcam, NSStringFromClass([self class]));
  if (session && forVcam) {
    if (!cfx_preview_layers) cfx_preview_layers = [NSHashTable weakObjectsHashTable];
    [cfx_preview_layers addObject:self];
    cfx_preview_start_timer();
  }
}

// Diagnostic: every CALayer subclass that has setSession: should fire here.
// If neither the AVCaptureVideoPreviewLayer hooks fire nor any subclass's
// setSession: shows up here, Camera.app must be using a fully private
// layer class we'll need to detect by walking the layer hierarchy.

// Fallback: scan UIApplication's windows for any AVCaptureVideoPreviewLayer
// (or subclass) and adopt them. Runs once a second; cheap if no windows
// match.

static void cfx_walk_layers(CALayer *layer, NSMutableArray *out) {
  if (!layer) return;
  Class avcvpl = NSClassFromString(@"AVCaptureVideoPreviewLayer");
  if (avcvpl && [layer isKindOfClass:avcvpl]) {
    [out addObject:layer];
  }
  for (CALayer *sub in layer.sublayers) {
    cfx_walk_layers(sub, out);
  }
}

static void cfx_scan_preview_layers(void) {
  Class UIApp = NSClassFromString(@"UIApplication");
  if (!UIApp) return;
  id app = [UIApp performSelector:@selector(sharedApplication)];
  if (!app) return;
  NSArray *windows = nil;
  @try {
    // iOS 13+: connectedScenes → UIWindowScene → windows
    NSSet *scenes = [app valueForKey:@"connectedScenes"];
    NSMutableArray *all = [NSMutableArray array];
    for (id scene in scenes) {
      @try {
        NSArray *w = [scene valueForKey:@"windows"];
        if (w) [all addObjectsFromArray:w];
      } @catch (NSException *e) {}
    }
    if (all.count > 0) windows = all;
  } @catch (NSException *e) {}
  if (!windows.count) {
    @try { windows = [app valueForKey:@"windows"]; } @catch (NSException *e) {}
  }
  if (!windows.count) return;

  NSMutableArray *found = [NSMutableArray array];
  for (id w in windows) {
    @try {
      CALayer *root = [w valueForKey:@"layer"];
      cfx_walk_layers(root, found);
    } @catch (NSException *e) {}
  }
  if (found.count == 0) return;
  if (!cfx_preview_layers) cfx_preview_layers = [NSHashTable weakObjectsHashTable];
  NSUInteger before = cfx_preview_layers.count;
  for (CALayer *layer in found) [cfx_preview_layers addObject:layer];
  NSUInteger after = cfx_preview_layers.count;
  if (after > before) {
    cfxlog(@"[scan] adopted %lu preview layer(s) (total=%lu)",
           (unsigned long)(after - before), (unsigned long)after);
    cfx_preview_start_timer();
  }
}

static dispatch_source_t cfx_scan_timer = NULL;
static void cfx_start_scan_timer(void) {
  if (cfx_scan_timer) return;
  dispatch_queue_t q = dispatch_get_main_queue();
  cfx_scan_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
  dispatch_source_set_timer(cfx_scan_timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                              1000000000ull, 100000000ull);
  dispatch_source_set_event_handler(cfx_scan_timer, ^{
    @autoreleasepool { cfx_scan_preview_layers(); }
  });
  dispatch_resume(cfx_scan_timer);
  cfxlog(@"scan timer armed (1 Hz)");
}

static void cfx_install_preview_layer_hooks(void) {
  Class cls = NSClassFromString(@"AVCaptureVideoPreviewLayer");
  if (!cls) { cfxlog(@"AVCaptureVideoPreviewLayer missing"); return; }
  SEL s1 = @selector(initWithSession:);
  SEL s2 = NSSelectorFromString(@"_initWithSession:makeConnection:");
  SEL s3 = @selector(setSession:);
  Method m1 = class_getInstanceMethod(cls, s1);
  Method m2 = class_getInstanceMethod(cls, s2);
  Method m3 = class_getInstanceMethod(cls, s3);
  if (m1) {
    cfx_orig_pv_initWithSession =
        method_setImplementation(m1, (IMP)cfx_pv_initWithSession_hook);
  }
  if (m2) {
    cfx_orig_pv_initWithSessionMakeConnection =
        method_setImplementation(m2, (IMP)cfx_pv_initWithSessionMakeConnection_hook);
  }
  if (m3) {
    cfx_orig_pv_setSession =
        method_setImplementation(m3, (IMP)cfx_pv_setSession_hook);
  }
  cfxlog(@"installed PVLayer hooks (init=%p initMC=%p setSession=%p)",
         cfx_orig_pv_initWithSession,
         cfx_orig_pv_initWithSessionMakeConnection,
         cfx_orig_pv_setSession);
}

// MARK: - beginMomentCapture / commitMomentCapture hooks
//
// Camera.app uses -[AVCapturePhotoOutput beginMomentCaptureWithSettings:
// delegate:] (Live Photo path) when the user taps the shutter. The original
// implementation throws NSInvalidArgumentException because our daemon's
// photo XPC isn't backed by a real still pipeline.
//
// For our virtual camera, SKIP the original entirely. Just async-deliver
// a CMSampleBuffer to the delegate. We never call orig — so AVF's state
// stays clean and subsequent shutter taps don't compound corruption.

static IMP cfx_orig_beginMomentCapture = NULL;
static IMP cfx_orig_commitMomentCapture = NULL;
static IMP cfx_orig_cancelMomentCapture = NULL;

// Build a minimal AVCaptureResolvedPhotoSettings with just _uniqueID set.
// Bypasses the 32-arg +resolvedSettingsWith… factory (which crashes on
// nil dict args). CAMCaptureEngine's didFinishProcessingPhoto: only reads
// uniqueID off the resolvedSettings to match the pending request.

static id cfx_build_minimal_resolved(int64_t uid) {
  Class outerCls = NSClassFromString(@"AVCaptureResolvedPhotoSettings");
  Class innerCls = NSClassFromString(@"AVCaptureResolvedPhotoSettingsInternal");
  if (!outerCls || !innerCls) return nil;

  id outer = class_createInstance(outerCls, 0);
  id inner = class_createInstance(innerCls, 0);
  if (!outer || !inner) return nil;

  // uniqueID:q (int64_t)
  Ivar uidIvar = class_getInstanceVariable(innerCls, "uniqueID");
  if (uidIvar) {
    *(int64_t *)((char *)(__bridge void *)inner + ivar_getOffset(uidIvar)) = uid;
  }

  // Set photo + preview dimensions so dimension accessors return our size.
  // (Zero structs are technically safe but feed our real dims for realism.)
  struct cfx_dims2 { int32_t w, h; };
  struct cfx_dims2 photoDim = {1280, 720};
  const char *dimNames[] = {"photoDimensions", "previewDimensions", NULL};
  for (int i = 0; dimNames[i]; i++) {
    Ivar iv = class_getInstanceVariable(innerCls, dimNames[i]);
    if (iv) {
      *(struct cfx_dims2 *)((char *)(__bridge void *)inner + ivar_getOffset(iv))
          = photoDim;
    }
  }

  // NSArray-typed ivars should be empty arrays, not nil, so AVF callers
  // can safely send -count etc. Manually retain so the ivars survive
  // past our autorelease pool / ARC scope exit; outer's dealloc will
  // balance with a release.
  const char *arrayNames[] = {"photoManifest", "digitalFlashUserInterfaceRGBEstimate", NULL};
  for (int i = 0; arrayNames[i]; i++) {
    Ivar iv = class_getInstanceVariable(innerCls, arrayNames[i]);
    if (iv) {
      NSArray *empty = @[];
      CFRetain((__bridge CFTypeRef)empty);
      object_setIvar(inner, iv, empty);
    }
  }

  // Wire outer._internal = inner. CFRetain inner so ARC can't drop it
  // before outer's dealloc gets a chance to release it.
  Ivar internalIvar = class_getInstanceVariable(outerCls, "_internal");
  if (internalIvar) {
    CFRetain((__bridge CFTypeRef)inner);
    object_setIvar(outer, internalIvar, inner);
  }

  return outer;
}

// We attach the uid via objc_setAssociatedObject before AVCapturePhoto's
// init calls -resolvedSettings on the captureRequest; the stub reads it.
static const void *CFX_ASSOC_UID_KEY = &CFX_ASSOC_UID_KEY;

static id cfx_stub_resolvedSettings(id self, SEL _cmd) {
  (void)_cmd;
  NSNumber *uidObj = objc_getAssociatedObject(self, CFX_ASSOC_UID_KEY);
  int64_t uid = uidObj.longLongValue;
  id r = cfx_build_minimal_resolved(uid);
  // Log pointer only — calling -description on a half-built obj crashes.
  cfxlog(@"[stub resolvedSettings] uid=%lld -> %p", uid, r);
  return r;
}

static id cfx_stub_unresolvedSettings(id self, SEL _cmd) {
  (void)self; (void)_cmd;
  return nil;
}

static BOOL cfx_stub_lensStabSupported(id self, SEL _cmd) {
  (void)self; (void)_cmd;
  return NO;
}

static void cfx_install_capturerequest_stubs(void) {
  Class cls = NSClassFromString(@"CAMStillImageCaptureRequest");
  if (!cls) { cfxlog(@"CAMStillImageCaptureRequest missing"); return; }
  if (class_addMethod(cls, NSSelectorFromString(@"resolvedSettings"),
                      (IMP)cfx_stub_resolvedSettings, "@@:")) {
    cfxlog(@"stubbed resolvedSettings on CAMStillImageCaptureRequest");
  }
  if (class_addMethod(cls, NSSelectorFromString(@"unresolvedSettings"),
                      (IMP)cfx_stub_unresolvedSettings, "@@:")) {
    cfxlog(@"stubbed unresolvedSettings on CAMStillImageCaptureRequest");
  }
  if (class_addMethod(cls, NSSelectorFromString(@"lensStabilizationSupported"),
                      (IMP)cfx_stub_lensStabSupported, "B@:")) {
    cfxlog(@"stubbed lensStabilizationSupported on CAMStillImageCaptureRequest");
  }
}

static BOOL cfx_output_is_for_vcam(id self) {
  @try {
    NSArray *conns = [self valueForKey:@"connections"];
    for (AVCaptureConnection *conn in conns) {
      for (AVCaptureInputPort *port in conn.inputPorts) {
        id input = port.input;
        if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
          AVCaptureDevice *d = ((AVCaptureDeviceInput *)input).device;
          if ([d.uniqueID isEqualToString:VCAM_UID]) return YES;
        }
      }
    }
  } @catch (NSException *e) {}
  return NO;
}

static void cfx_deliver_photo_to_delegate(id output, id delegate) {
  if (!delegate) return;
  CMSampleBufferRef sbuf = cfx_build_cmsb();
  if (!sbuf) { cfxlog(@"deliver: no shm sample"); return; }
  SEL oldSel = NSSelectorFromString(
      @"captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:");
  if ([delegate respondsToSelector:oldSel]) {
    cfxlog(@"deliver: firing deprecated delegate");
    ((void (*)(id, SEL, id, CMSampleBufferRef, CMSampleBufferRef, id, id, id))objc_msgSend)(
        delegate, oldSel, output, sbuf, NULL, (id)nil, (id)nil, (id)nil);
  } else {
    cfxlog(@"deliver: no deprecated delegate; AVCapturePhoto path needs 27-arg init we don't synthesize");
  }
  CFRelease(sbuf);
}

// MARK: - JPEG + IOSurface builders

typedef struct { int32_t width, height; } cfx_video_dims_t;

static NSData *cfx_build_jpeg_from_shm(uint32_t *outW, uint32_t *outH) {
  if (!cfx_shm_open()) return nil;
  const cfx_shm_header_t *hdr = (const cfx_shm_header_t *)cfx_shm_base;
  uint32_t w = hdr->width, h = hdr->height, bpr = hdr->bytes_per_row;
  if (!w || !h || !bpr) return nil;
  size_t len = (size_t)bpr * h;
  if ((size_t)CFX_SHM_HEADER_SIZE + len > cfx_shm_size) return nil;

  void *copy = malloc(len);
  if (!copy) return nil;
  memcpy(copy, cfx_shm_base + CFX_SHM_HEADER_SIZE, len);

  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGDataProviderRef dp = CGDataProviderCreateWithData(
      NULL, copy, len, cfx_cg_release_data);
  CGImageRef img = CGImageCreate(
      w, h, 8, 32, bpr, cs,
      (CGBitmapInfo)(kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst),
      dp, NULL, false, kCGRenderingIntentDefault);
  CGDataProviderRelease(dp);
  CGColorSpaceRelease(cs);
  if (!img) return nil;

  NSMutableData *data = [NSMutableData data];
  CGImageDestinationRef dest = CGImageDestinationCreateWithData(
      (CFMutableDataRef)data, (CFStringRef)@"public.jpeg", 1, NULL);
  if (!dest) { CGImageRelease(img); return nil; }
  CGImageDestinationAddImage(dest, img, NULL);
  BOOL ok = CGImageDestinationFinalize(dest);
  CFRelease(dest);
  CGImageRelease(img);
  if (!ok) return nil;
  if (outW) *outW = w;
  if (outH) *outH = h;
  return data;
}

static CGImageRef cfx_build_cgimage_from_shm(uint32_t *outW, uint32_t *outH) CF_RETURNS_RETAINED {
  if (!cfx_shm_open()) return NULL;
  const cfx_shm_header_t *hdr = (const cfx_shm_header_t *)cfx_shm_base;
  uint32_t w = hdr->width, h = hdr->height, bpr = hdr->bytes_per_row;
  if (!w || !h || !bpr) return NULL;
  size_t len = (size_t)bpr * h;
  if ((size_t)CFX_SHM_HEADER_SIZE + len > cfx_shm_size) return NULL;
  void *copy = malloc(len);
  if (!copy) return NULL;
  memcpy(copy, cfx_shm_base + CFX_SHM_HEADER_SIZE, len);
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGDataProviderRef dp = CGDataProviderCreateWithData(
      NULL, copy, len, cfx_cg_release_data);
  CGImageRef img = CGImageCreate(
      w, h, 8, 32, bpr, cs,
      (CGBitmapInfo)(kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst),
      dp, NULL, false, kCGRenderingIntentDefault);
  CGDataProviderRelease(dp);
  CGColorSpaceRelease(cs);
  if (outW) *outW = w;
  if (outH) *outH = h;
  return img;
}

static IOSurfaceRef cfx_build_iosurface_from_shm(uint32_t *outW, uint32_t *outH) CF_RETURNS_RETAINED {
  if (!cfx_shm_open()) return NULL;
  const cfx_shm_header_t *hdr = (const cfx_shm_header_t *)cfx_shm_base;
  uint32_t w = hdr->width, h = hdr->height, bpr = hdr->bytes_per_row;
  if (!w || !h || !bpr) return NULL;
  size_t len = (size_t)bpr * h;
  if ((size_t)CFX_SHM_HEADER_SIZE + len > cfx_shm_size) return NULL;
  NSDictionary *props = @{
    (NSString *)kIOSurfaceWidth: @(w),
    (NSString *)kIOSurfaceHeight: @(h),
    (NSString *)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA),
    (NSString *)kIOSurfaceBytesPerElement: @(4),
    (NSString *)kIOSurfaceBytesPerRow: @(bpr),
    (NSString *)kIOSurfaceAllocSize: @(len),
  };
  IOSurfaceRef surf = IOSurfaceCreate((CFDictionaryRef)props);
  if (!surf) return NULL;
  IOSurfaceLock(surf, 0, NULL);
  void *base = IOSurfaceGetBaseAddress(surf);
  if (base) memcpy(base, cfx_shm_base + CFX_SHM_HEADER_SIZE, len);
  IOSurfaceUnlock(surf, 0, NULL);
  if (outW) *outW = w;
  if (outH) *outH = h;
  return surf;
}

// MARK: - Version-agnostic invocation helpers
//
// AVCapturePhoto's designated init and AVCaptureResolvedPhotoSettings'
// factory each take 25+ arguments. The selectors are gigantic strings and
// Apple has been known to add/remove arguments between iOS revisions
// (which silently moves every later arg's positional index). To avoid
// rewriting every libcamfix release against a fixed signature, the
// builders below look up the selector by PREFIX at runtime and fill
// arguments by LABEL — the actual selector component names like
// "photoSurface" or "uniqueID" — so a future arg insertion just gets
// nil/zero in that slot without breaking the rest.

// Walk class_copyMethodList for `cls` (or its metaclass when looking for
// class methods) and return the selector with the most colons that starts
// with `prefix`. Returns NULL if nothing matches.
static SEL cfx_find_selector_by_prefix(Class cls, NSString *prefix,
                                       BOOL classMethod) {
  if (!cls || !prefix.length) return NULL;
  Class c = classMethod ? object_getClass(cls) : cls;
  unsigned int n = 0;
  Method *methods = class_copyMethodList(c, &n);
  if (!methods) return NULL;
  SEL best = NULL;
  NSUInteger bestArgs = 0;
  for (unsigned int i = 0; i < n; i++) {
    SEL s = method_getName(methods[i]);
    NSString *name = NSStringFromSelector(s);
    if (![name hasPrefix:prefix]) continue;
    NSUInteger colons = 0;
    for (NSUInteger j = 0; j < name.length; j++) {
      if ([name characterAtIndex:j] == ':') colons++;
    }
    if (colons > bestArgs) {
      bestArgs = colons;
      best = s;
    }
  }
  free(methods);
  return best;
}

// Normalize the first selector component to a canonical label. Apple
// init/factory selectors start with "initWithX:" / "resolvedSettingsWithX:";
// the helper-side label dictionary keys are just "X" (camelCase). Strips
// the prefix and lowercases the first character of the remainder.
static NSString *cfx_normalize_first_label(NSString *label) {
  for (NSString *prefix in @[@"initWith", @"resolvedSettingsWith"]) {
    if ([label hasPrefix:prefix] && label.length > prefix.length) {
      NSString *rest = [label substringFromIndex:prefix.length];
      return [[[rest substringToIndex:1] lowercaseString]
          stringByAppendingString:[rest substringFromIndex:1]];
    }
  }
  return label;
}

// Resolver block: called once per method argument with the canonical label
// (e.g. "photoSurface") and the runtime type encoding. The block decides
// whether and what to write into `outBuf` (already zeroed). If the block
// doesn't recognize the label, leave outBuf alone — nil for objects,
// zeroed bytes for structs/primitives.
typedef void (^cfx_arg_resolver_t)(NSString *label, const char *typeEnc,
                                   void *outBuf);

// Build + invoke `[target selector]` with arguments filled by `resolver`.
// Works whether `target` is an alloc'd instance (for inits) or a Class
// (for class-method factories). Returns the result if it's an object
// return type, nil otherwise.
static id cfx_invoke_with_labeled_args(id target, SEL selector,
                                       cfx_arg_resolver_t resolver) {
  NSMethodSignature *sig = nil;
  @try { sig = [target methodSignatureForSelector:selector]; }
  @catch (NSException *e) { return nil; }
  if (!sig) return nil;

  NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
  [inv setTarget:target];
  [inv setSelector:selector];

  NSArray<NSString *> *parts =
      [NSStringFromSelector(selector) componentsSeparatedByString:@":"];
  NSUInteger argCount = sig.numberOfArguments - 2;  // -2 for self + _cmd
  for (NSUInteger i = 0; i < argCount; i++) {
    NSString *raw = i < parts.count ? parts[i] : @"";
    NSString *label = (i == 0) ? cfx_normalize_first_label(raw) : raw;

    const char *typeEnc = [sig getArgumentTypeAtIndex:i + 2];
    NSUInteger argSize = 0, argAlign = 0;
    NSGetSizeAndAlignment(typeEnc, &argSize, &argAlign);
    if (argSize == 0) continue;

    // alloca on arm64 returns a 16-byte-aligned buffer; argSize <= 64 in
    // practice for everything Apple uses here (CMTimeRange is 48 bytes).
    void *buf = alloca(argSize);
    memset(buf, 0, argSize);
    if (resolver) resolver(label, typeEnc, buf);
    [inv setArgument:buf atIndex:i + 2];
  }

  @try {
    [inv invoke];
  } @catch (NSException *e) {
    cfxlog(@"invoke %@ threw: %@", NSStringFromSelector(selector), e);
    return nil;
  }

  if (sig.methodReturnLength > 0 &&
      sig.methodReturnType[0] == '@') {
    __unsafe_unretained id result = nil;
    [inv getReturnValue:&result];
    return result;
  }
  return nil;
}

// MARK: - AVCapturePhoto / Resolved settings synthesis

static id cfx_build_resolved_settings(int64_t uniqueID, int32_t w, int32_t h) {
  Class cls = NSClassFromString(@"AVCaptureResolvedPhotoSettings");
  if (!cls) return nil;
  SEL sel = cfx_find_selector_by_prefix(cls, @"resolvedSettingsWithUniqueID:",
                                        /*classMethod*/YES);
  if (!sel) { cfxlog(@"resolved: no factory selector found"); return nil; }

  cfx_video_dims_t photoDim = {w, h};
  cfx_video_dims_t previewDim = {w / 4, h / 4};
  id result = cfx_invoke_with_labeled_args(
      cls, sel,
      ^(NSString *label, const char *typeEnc, void *out) {
        if ([label isEqualToString:@"uniqueID"]) {
          *(int64_t *)out = uniqueID;
        } else if ([label isEqualToString:@"photoDimensions"]) {
          *(cfx_video_dims_t *)out = photoDim;
        } else if ([label isEqualToString:@"previewDimensions"]) {
          *(cfx_video_dims_t *)out = previewDim;
        }
        // All other labels (rawPhotoDimensions, livePhotoMovieEnabled,
        // photoManifest, etc.) stay zeroed/nil — the factory tolerates
        // it on builds where this whole path even works at all
        // (26.5 trips on nil photoManifest, hence the fallback below).
      });
  if (result) cfxlog(@"resolved settings built: %p uid=%lld", result, uniqueID);
  return result;
}

static id cfx_build_avcapturephoto_with_request(IOSurfaceRef surf,
                                                uint32_t w, uint32_t h,
                                                id captureRequest) {
  Class cls = NSClassFromString(@"AVCapturePhoto");
  if (!cls) return nil;
  id alloc_obj = [cls alloc];
  if (!alloc_obj) return nil;

  // Discover the designated init at runtime. Apple may add/remove args
  // between iOS releases; we anchor on the leading components and accept
  // whatever the longest matching selector is.
  SEL initSel = cfx_find_selector_by_prefix(cls, @"initWithTimestamp:",
                                            /*classMethod*/NO);
  if (!initSel) { cfxlog(@"photo: no init selector found"); return nil; }

  CMTime ts = CMClockGetTime(CMClockGetHostTimeClock());
  CGSize sz = CGSizeMake((CGFloat)w, (CGFloat)h);
  NSString *fileType = @"public.jpeg";
  NSDictionary *meta = @{};
  NSString *deviceType = @"AVCaptureDeviceTypeBuiltInWideAngleCamera";

  id result = cfx_invoke_with_labeled_args(
      alloc_obj, initSel,
      ^(NSString *label, const char *typeEnc, void *out) {
        if ([label isEqualToString:@"timestamp"]) {
          *(CMTime *)out = ts;
        } else if ([label isEqualToString:@"photoSurface"]) {
          *(IOSurfaceRef *)out = surf;
        } else if ([label isEqualToString:@"photoSurfaceSize"]) {
          *(CGSize *)out = sz;
        } else if ([label isEqualToString:@"processedFileType"]) {
          *(__unsafe_unretained id *)out = fileType;
        } else if ([label isEqualToString:@"metadata"]) {
          *(__unsafe_unretained id *)out = meta;
        } else if ([label isEqualToString:@"captureRequest"]) {
          *(__unsafe_unretained id *)out = captureRequest;
        } else if ([label isEqualToString:@"sequenceCount"]
                || [label isEqualToString:@"photoCount"]) {
          *(NSInteger *)out = 1;
        } else if ([label isEqualToString:@"sourceDeviceType"]) {
          *(__unsafe_unretained id *)out = deviceType;
        }
        // Every other arg (preview/thumbnail/depth/portrait/hair/skin/
        // teeth/glasses/constantColor surfaces + their metadata dicts,
        // bracketSettings, expectedPhotoProcessingFlags, etc.) stays
        // zero/nil — works for both Camera.app (with non-nil
        // captureRequest) and standalone AVF clients (nil).
      });
  if (result) {
    cfxlog(@"AVCapturePhoto built: %p (captureRequest=%p, sel=%@)",
           result, captureRequest, NSStringFromSelector(initSel));
  }
  return result;
}

static id cfx_build_avcapturephoto(IOSurfaceRef surf, uint32_t w, uint32_t h) {
  return cfx_build_avcapturephoto_with_request(surf, w, h, nil);
}

// MARK: - fileDataRepresentation / CGImageRepresentation hooks
//
// We tag synthesized photos via objc_setAssociatedObject so the hook
// recognizes "ours" without a global dict. Keys are defined earlier in
// the file alongside cfx_deliver_capturePhoto's forward decls.

static IMP cfx_orig_fileDataRep = NULL;
static IMP cfx_orig_cgImageRep = NULL;

static NSData *cfx_fileDataRep_hook(id self, SEL _cmd) {
  NSData *ours = objc_getAssociatedObject(self, CFX_ASSOC_JPEG_KEY);
  if (ours) {
    cfxlog(@"[fileDataRep] returning vcam jpeg (%lu bytes)", (unsigned long)ours.length);
    return ours;
  }
  typedef NSData *(*OrigFn)(id, SEL);
  return ((OrigFn)cfx_orig_fileDataRep)(self, _cmd);
}

static CGImageRef cfx_cgImageRep_hook(id self, SEL _cmd) {
  id wrap = objc_getAssociatedObject(self, CFX_ASSOC_CGIMG_KEY);
  if (wrap) {
    CGImageRef img = (__bridge CGImageRef)wrap;
    cfxlog(@"[cgImageRep] returning vcam CGImage");
    return img;
  }
  typedef CGImageRef (*OrigFn)(id, SEL);
  return ((OrigFn)cfx_orig_cgImageRep)(self, _cmd);
}

static void cfx_install_photo_representation_hooks(void) {
  Class cls = NSClassFromString(@"AVCapturePhoto");
  if (!cls) return;
  Method m1 = class_getInstanceMethod(cls, @selector(fileDataRepresentation));
  Method m2 = class_getInstanceMethod(cls, @selector(CGImageRepresentation));
  if (m1) {
    cfx_orig_fileDataRep = method_setImplementation(m1, (IMP)cfx_fileDataRep_hook);
    cfxlog(@"installed fileDataRepresentation hook");
  }
  if (m2) {
    cfx_orig_cgImageRep = method_setImplementation(m2, (IMP)cfx_cgImageRep_hook);
    cfxlog(@"installed CGImageRepresentation hook");
  }
}

// MARK: - drive the capture state machine

static void cfx_drive_capture(id output, id delegate, id settings) {
  // Extract uniqueID from AVMomentCaptureSettings.
  int64_t uid = 0;
  @try {
    NSNumber *n = [settings valueForKey:@"uniqueID"];
    uid = n.longLongValue;
  } @catch (NSException *e) {}
  cfxlog(@"[drive] uid=%lld settings=%@", uid, [settings class]);

  // Look up the real captureRequest from CAMCaptureEngine's internal
  // registry FIRST. When the user tapped the shutter, CAMCaptureEngine
  // registered a CAMCaptureRequestInfo keyed by uid (the
  // _resultsQueueRegisteredStillImageRequests ivar). Its `request` property
  // is the AVCaptureRequest we need to pass as the `captureRequest:` arg
  // to the AVCapturePhoto init — without it, CAMCaptureEngine's
  // didFinishProcessing handler can't match the photo to a pending
  // request and drops it.
  id captureRequest = nil;
  @try {
    id reqDict = [delegate valueForKey:@"_resultsQueueRegisteredStillImageRequests"];
    if ([reqDict isKindOfClass:[NSDictionary class]]) {
      id info = ((NSDictionary *)reqDict)[@(uid)];
      if (info) {
        id stillReq = [info valueForKey:@"request"];
        cfxlog(@"[drive] CAMStillImageCaptureRequest=%p for uid=%lld",
               stillReq, uid);
        // Tag the captureRequest with the uid so the resolvedSettings stub
        // (which has no parameter context) can recover it.
        objc_setAssociatedObject(stillReq, CFX_ASSOC_UID_KEY, @(uid),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        captureRequest = stillReq;
      } else {
        cfxlog(@"[drive] no CAMCaptureRequestInfo for uid=%lld; keys=%@",
               uid, ((NSDictionary *)reqDict).allKeys);
      }
    }
  } @catch (NSException *e) {
    cfxlog(@"[drive] registry lookup threw: %@", e);
  }

  // Build IOSurface from shm.
  uint32_t w = 0, h = 0;
  IOSurfaceRef surf = cfx_build_iosurface_from_shm(&w, &h);
  if (!surf || !w || !h) {
    cfxlog(@"[drive] no IOSurface — falling back to error finish");
    NSError *err = [NSError errorWithDomain:AVFoundationErrorDomain code:-11800
                                  userInfo:@{NSLocalizedDescriptionKey:@"vcam no shm"}];
    SEL finishSel = @selector(captureOutput:didFinishCaptureForResolvedSettings:error:);
    if ([delegate respondsToSelector:finishSel]) {
      ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, finishSel, output, nil, err);
    }
    if (surf) CFRelease(surf);
    return;
  }
  cfxlog(@"[drive] IOSurface %ux%u built", w, h);

  // Build AVCapturePhoto WITH the real captureRequest.
  id photo = cfx_build_avcapturephoto_with_request(surf, w, h, captureRequest);
  CFRelease(surf);  // photo retains it
  if (!photo) {
    cfxlog(@"[drive] no AVCapturePhoto — abort");
    return;
  }

  // Stamp it with our JPEG so fileDataRepresentation returns our bytes.
  NSData *jpeg = cfx_build_jpeg_from_shm(NULL, NULL);
  CGImageRef cgImg = cfx_build_cgimage_from_shm(NULL, NULL);
  if (jpeg) objc_setAssociatedObject(photo, CFX_ASSOC_JPEG_KEY, jpeg,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (cgImg) {
    objc_setAssociatedObject(photo, CFX_ASSOC_CGIMG_KEY,
                             (__bridge id)cgImg,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGImageRelease(cgImg);
  }
  cfxlog(@"[drive] photo stamped jpeg=%lu bytes", (unsigned long)jpeg.length);

  // Fire the FULL standard delegate sequence. CAMCaptureEngine tracks
  // a _receivedCallbacks set per uid; until ALL expected callbacks
  // arrive, the request stays in
  // _resultsQueueRegisteredStillImageRequests and the engine refuses
  // to start new captures (manifests as "shutter stops working after
  // N taps"). We now have a real resolvedSettings, so we can fire the
  // will/did pre-callbacks too.
  id resolvedForFinish = nil;
  @try {
    resolvedForFinish = [photo valueForKey:@"resolvedSettings"];
  } @catch (NSException *e) {
    cfxlog(@"[drive] photo.resolvedSettings threw: %@", e);
  }
  SEL S1 = @selector(captureOutput:willBeginCaptureBeforeResolvingSettingsForUniqueID:);
  SEL S2 = @selector(captureOutput:willBeginCaptureForResolvedSettings:);
  SEL S3 = @selector(captureOutput:willCapturePhotoForResolvedSettings:);
  SEL S4 = @selector(captureOutput:didCapturePhotoForResolvedSettings:);
  SEL S5 = @selector(captureOutput:didFinishProcessingPhoto:error:);
  SEL S6 = @selector(captureOutput:didFinishCaptureForResolvedSettings:error:);
  SEL Sfinish = NSSelectorFromString(@"_didFinishStillImageCaptureForUniqueID:error:");
  if ([delegate respondsToSelector:S1]) {
    cfxlog(@"[drive] -> willBeginCaptureBefore… uid=%lld", uid);
    ((void (*)(id, SEL, id, int64_t))objc_msgSend)(delegate, S1, output, uid);
  }
  if (resolvedForFinish && [delegate respondsToSelector:S2]) {
    cfxlog(@"[drive] -> willBeginCaptureForResolvedSettings:");
    ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, S2, output, resolvedForFinish);
  }
  if (resolvedForFinish && [delegate respondsToSelector:S3]) {
    cfxlog(@"[drive] -> willCapturePhotoForResolvedSettings:");
    ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, S3, output, resolvedForFinish);
  }
  if (resolvedForFinish && [delegate respondsToSelector:S4]) {
    cfxlog(@"[drive] -> didCapturePhotoForResolvedSettings:");
    ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, S4, output, resolvedForFinish);
  }
  if ([delegate respondsToSelector:S5]) {
    cfxlog(@"[drive] -> didFinishProcessingPhoto:error:");
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, S5, output, photo, nil);
  }
  if ([delegate respondsToSelector:S6]) {
    cfxlog(@"[drive] -> didFinishCapture resolved=%p", resolvedForFinish);
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(
        delegate, S6, output, resolvedForFinish, nil);
  }
  if ([delegate respondsToSelector:Sfinish]) {
    cfxlog(@"[drive] -> _didFinishStillImageCaptureForUniqueID:%lld", uid);
    ((void (*)(id, SEL, int64_t, id))objc_msgSend)(delegate, Sfinish, uid, nil);
  }

  // Signal that the output is ready for the NEXT capture request. AVF's
  // photo output is a 2-deep pipeline — Camera.app's shutter stays
  // disabled until this fires for each in-flight capture.
  SEL Sready = NSSelectorFromString(@"captureOutput:readyForResponsiveRequestAfterResolvedSettings:");
  if (resolvedForFinish && [delegate respondsToSelector:Sready]) {
    cfxlog(@"[drive] -> readyForResponsiveRequestAfterResolvedSettings:");
    ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, Sready, output, resolvedForFinish);
  }

  cfxlog(@"[drive] sequence complete");
}

// We stash (delegate, settings) on the AVCapturePhotoOutput at begin time
// so the commit hook can drive the capture once CAMCaptureEngine has
// registered the request in its internal dict.
static const void *CFX_ASSOC_DELEGATE_KEY = &CFX_ASSOC_DELEGATE_KEY;
static const void *CFX_ASSOC_SETTINGS_KEY = &CFX_ASSOC_SETTINGS_KEY;

static void cfx_beginMomentCapture_hook(id self, SEL _cmd, id settings, id delegate) {
  BOOL forVcam = cfx_output_is_for_vcam(self);
  cfxlog(@"[beginMomentCapture] forVcam=%d delegate=%@", forVcam, delegate);
  if (!forVcam) {
    typedef void (*OrigFn)(id, SEL, id, id);
    ((OrigFn)cfx_orig_beginMomentCapture)(self, _cmd, settings, delegate);
    return;
  }
  // SKIP orig — it throws for our session. Just stash the delegate +
  // settings; commit will drive the photo delivery once CAMCaptureEngine
  // has registered the captureRequest internally.
  objc_setAssociatedObject(self, CFX_ASSOC_DELEGATE_KEY, delegate,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  objc_setAssociatedObject(self, CFX_ASSOC_SETTINGS_KEY, settings,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// NOTE: uniqueID is a pointer-sized integer (not an NSUUID *). Declaring
// it as `id` would cause ARC to retain it on entry, dereferencing the
// integer-as-isa and segfaulting. Use intptr_t to skip the retain.

static void cfx_commitMomentCapture_hook(id self, SEL _cmd, intptr_t uniqueID) {
  BOOL forVcam = cfx_output_is_for_vcam(self);
  cfxlog(@"[commitMomentCapture] forVcam=%d uniqueID=%ld", forVcam, (long)uniqueID);
  if (!forVcam) {
    typedef void (*OrigFn)(id, SEL, intptr_t);
    ((OrigFn)cfx_orig_commitMomentCapture)(self, _cmd, uniqueID);
    return;
  }
  // SKIP orig (would throw) and drive the synthesized photo delivery
  // here, where CAMCaptureEngine has already registered its
  // CAMCaptureRequestInfo for this uid.
  id delegate = objc_getAssociatedObject(self, CFX_ASSOC_DELEGATE_KEY);
  id settings = objc_getAssociatedObject(self, CFX_ASSOC_SETTINGS_KEY);
  if (!delegate) {
    cfxlog(@"[commit] no stashed delegate — was begin called?");
    return;
  }
  __strong id retainedSelf = self;
  __strong id retainedDelegate = delegate;
  __strong id retainedSettings = settings;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      cfx_drive_capture(retainedSelf, retainedDelegate, retainedSettings);
    }
  });
}

static void cfx_cancelMomentCapture_hook(id self, SEL _cmd, intptr_t uniqueID) {
  BOOL forVcam = cfx_output_is_for_vcam(self);
  cfxlog(@"[cancelMomentCapture] forVcam=%d uniqueID=0x%lx", forVcam, (long)uniqueID);
  if (!forVcam) {
    typedef void (*OrigFn)(id, SEL, intptr_t);
    ((OrigFn)cfx_orig_cancelMomentCapture)(self, _cmd, uniqueID);
    return;
  }
  // No-op for vcam — orig throws (the begin was a no-op so there is no
  // live moment to cancel). CAMCaptureEngine drives this when it decides
  // the capture is stale.
}

static void cfx_install_moment_capture_hooks(void) {
  Class cls = NSClassFromString(@"AVCapturePhotoOutput");
  if (!cls) return;
  SEL b = @selector(beginMomentCaptureWithSettings:delegate:);
  SEL c = NSSelectorFromString(@"commitMomentCaptureToPhotoWithUniqueID:");
  SEL x = NSSelectorFromString(@"cancelMomentCaptureWithUniqueID:");
  Method mb = class_getInstanceMethod(cls, b);
  Method mc = class_getInstanceMethod(cls, c);
  Method mx = class_getInstanceMethod(cls, x);
  if (mb) {
    cfx_orig_beginMomentCapture =
        method_setImplementation(mb, (IMP)cfx_beginMomentCapture_hook);
    cfxlog(@"installed beginMomentCapture hook");
  }
  if (mc) {
    cfx_orig_commitMomentCapture =
        method_setImplementation(mc, (IMP)cfx_commitMomentCapture_hook);
    cfxlog(@"installed commitMomentCapture hook");
  }
  if (mx) {
    cfx_orig_cancelMomentCapture =
        method_setImplementation(mx, (IMP)cfx_cancelMomentCapture_hook);
    cfxlog(@"installed cancelMomentCapture hook");
  }
}

// MARK: - AVCaptureSession state guards
//
// After ~4-5s of no real sample buffer flow on the AVCaptureSession's
// preview connection, Camera.app's session transitions to
// "interrupted" / not-running and disables the shutter. We bypass the
// daemon's preview pipeline (we feed CALayer.contents directly), so
// no sample buffers ever flow.
//
// Two guards on AVCaptureSession for our vcam-bound sessions:
//   1. -[AVCaptureSession _setRunning:NO]   → swallow (stay running)
//   2. -[AVCaptureSession _setInterrupted:YES withReason:interruptor:] → swallow

static IMP cfx_orig_setRunning = NULL;
static IMP cfx_orig_setInterrupted = NULL;

static BOOL cfx_session_uses_vcam(id session) {
  @try {
    NSArray *inputs = [session valueForKey:@"inputs"];
    for (id inp in inputs) {
      if ([inp isKindOfClass:[AVCaptureDeviceInput class]]) {
        AVCaptureDevice *d = ((AVCaptureDeviceInput *)inp).device;
        if ([d.uniqueID isEqualToString:VCAM_UID]) return YES;
      }
    }
  } @catch (NSException *e) {}
  return NO;
}

static void cfx_session_setRunning_hook(id self, SEL _cmd, BOOL running) {
  if (!running && cfx_session_uses_vcam(self)) {
    cfxlog(@"[session _setRunning:NO] suppressed for vcam session %p", self);
    return;
  }
  typedef void (*OrigFn)(id, SEL, BOOL);
  ((OrigFn)cfx_orig_setRunning)(self, _cmd, running);
}

static void cfx_session_setInterrupted_hook(id self, SEL _cmd,
                                              BOOL interrupted,
                                              long reason,
                                              id interruptor) {
  if (interrupted && cfx_session_uses_vcam(self)) {
    cfxlog(@"[session _setInterrupted:YES reason=%ld] suppressed for vcam session %p",
           reason, self);
    return;
  }
  typedef void (*OrigFn)(id, SEL, BOOL, long, id);
  ((OrigFn)cfx_orig_setInterrupted)(self, _cmd, interrupted, reason, interruptor);
}

static void cfx_install_session_guards(void) {
  Class cls = NSClassFromString(@"AVCaptureSession");
  if (!cls) { cfxlog(@"AVCaptureSession missing"); return; }
  SEL s1 = NSSelectorFromString(@"_setRunning:");
  SEL s2 = NSSelectorFromString(@"_setInterrupted:withReason:interruptor:");
  Method m1 = class_getInstanceMethod(cls, s1);
  Method m2 = class_getInstanceMethod(cls, s2);
  if (m1) {
    cfx_orig_setRunning = method_setImplementation(m1, (IMP)cfx_session_setRunning_hook);
    cfxlog(@"installed _setRunning: hook");
  } else {
    cfxlog(@"_setRunning: not in objc table");
  }
  if (m2) {
    cfx_orig_setInterrupted = method_setImplementation(m2, (IMP)cfx_session_setInterrupted_hook);
    cfxlog(@"installed _setInterrupted: hook");
  } else {
    cfxlog(@"_setInterrupted: not in objc table");
  }
}

// MARK: - AVCaptureSession state GETTER lies
//
// If Camera.app polls -isRunning / -isInterrupted in its UI loop and
// reacts to a transition (no-frames timer or similar), we can lie to
// keep the UI in "live preview" mode.

static IMP cfx_orig_isRunning = NULL;
static IMP cfx_orig_isInterrupted = NULL;
static int cfx_isRunning_logged = 0;
static int cfx_isInterrupted_logged = 0;

static BOOL cfx_session_isRunning_hook(id self, SEL _cmd) {
  typedef BOOL (*Fn)(id, SEL);
  BOOL real = ((Fn)cfx_orig_isRunning)(self, _cmd);
  if (cfx_session_uses_vcam(self)) {
    if (cfx_isRunning_logged < 3) {
      cfxlog(@"[isRunning] real=%d -> forcing YES (session=%p)", real, self);
      cfx_isRunning_logged++;
    }
    return YES;
  }
  return real;
}

static BOOL cfx_session_isInterrupted_hook(id self, SEL _cmd) {
  typedef BOOL (*Fn)(id, SEL);
  BOOL real = ((Fn)cfx_orig_isInterrupted)(self, _cmd);
  if (cfx_session_uses_vcam(self) && real) {
    if (cfx_isInterrupted_logged < 3) {
      cfxlog(@"[isInterrupted] real=%d -> forcing NO (session=%p)", real, self);
      cfx_isInterrupted_logged++;
    }
    return NO;
  }
  return real;
}

static void cfx_install_session_state_lies(void) {
  Class cls = NSClassFromString(@"AVCaptureSession");
  if (!cls) return;
  Method r = class_getInstanceMethod(cls, @selector(isRunning));
  Method i = class_getInstanceMethod(cls, @selector(isInterrupted));
  if (r) {
    cfx_orig_isRunning = method_setImplementation(r, (IMP)cfx_session_isRunning_hook);
    cfxlog(@"installed isRunning lie");
  }
  if (i) {
    cfx_orig_isInterrupted = method_setImplementation(i, (IMP)cfx_session_isInterrupted_hook);
    cfxlog(@"installed isInterrupted lie");
  }
}

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
    cfx_install_capturePhoto_hook();
    cfx_install_moment_capture_hooks();
    cfx_install_session_guards();
    cfx_install_session_state_lies();
    cfx_install_preview_layer_hooks();
    cfx_install_photo_representation_hooks();
    cfx_install_capturerequest_stubs();
    cfx_start_scan_timer();
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
