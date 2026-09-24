// MARK: - viewfinder stream injection
//
// Camera.app's preview path goes through FigCameraViewfinderStream, NOT
// BWImageQueueSinkNode. The stream exposes -enqueueVideoSampleBuffer: which
// the daemon's normal frame producer calls to deliver each frame to the
// client (Camera.app's AVCaptureVideoPreviewLayer). For our synth source —
// which has no real producer — we hook -[FigCameraViewfinderStream init],
// capture each instance, and drive enqueueVideoSampleBuffer: ourselves on
// a 30 Hz timer, wrapping vcc_latest_frame pixels in a fresh CMSampleBuffer.

// Forward declaration — full definition is later in the file under the
// "shared-frame reader" section.
typedef struct vcc_latest_frame_s {
  pthread_mutex_t lock;
  uint32_t width;
  uint32_t height;
  uint32_t bytes_per_row;
  uint8_t *pixels;
  size_t   pixels_capacity;
  size_t   pixels_length;
} vcc_latest_frame_t;
extern vcc_latest_frame_t vcc_latest_frame;

// CVPixelBuffer release callback for the malloc'd pixel buffer. Has to be
// a real C function (block isn't compatible with the callback signature).
static void vcc_cv_release_bytes(void *refcon, const void *baseAddress) {
  (void)refcon;
  free((void *)baseAddress);
}

static IMP vcc_vfs_init_orig = NULL;
static IMP vcc_vfs_open_orig = NULL;
static IMP vcc_vfs_close_orig = NULL;
static NSMutableArray *vcc_vf_streams = nil;  // strong refs
static dispatch_source_t vcc_vf_timer = NULL;
static dispatch_queue_t vcc_vf_q = NULL;
static uint64_t vcc_vf_pts_ns = 0;
static uint64_t vcc_vf_enqueue_count = 0;
static uint64_t vcc_vf_enqueue_success = 0;

typedef id (*VccVfsInitFn)(id self, SEL _cmd);
typedef void (*VccVfsOpenFn)(id self, SEL _cmd, id dest);
typedef void (*VccVfsCloseFn)(id self, SEL _cmd);

static _Atomic uint64_t vcc_vfs_init_count = 0;

static id vcc_vfs_init_hook(id self, SEL _cmd) {
  VccVfsInitFn orig = (VccVfsInitFn)vcc_vfs_init_orig;
  id ret = orig(self, _cmd);
  // Throttled — Camera.app spins ~2000 inits/sec without ever opening
  // (session config silently incomplete). Log every 1024th to keep the log
  // file usable.
  uint64_t n = atomic_fetch_add(&vcc_vfs_init_count, 1) + 1;
  if ((n & 0x3ff) == 1) {
    vcc_log(@"  [VFS init] -> %p (total=%llu)",
            ret, (unsigned long long)n);
  }
  return ret;
}

static void vcc_vfs_open_hook(id self, SEL _cmd, id dest) {
  vcc_log(@"  [VFS open] self=%p dest=%@", self, dest);
  VccVfsOpenFn orig = (VccVfsOpenFn)vcc_vfs_open_orig;
  orig(self, _cmd, dest);
  if (!vcc_vf_streams) vcc_vf_streams = [NSMutableArray array];
  [vcc_vf_streams addObject:self];
  vcc_log(@"  [VFS open] captured stream %p (total=%lu)",
          self, (unsigned long)vcc_vf_streams.count);
}

static void vcc_vfs_close_hook(id self, SEL _cmd) {
  vcc_log(@"  [VFS close] self=%p", self);
  if (vcc_vf_streams) [vcc_vf_streams removeObject:self];
  VccVfsCloseFn orig = (VccVfsCloseFn)vcc_vfs_close_orig;
  orig(self, _cmd);
}

// Build a CMSampleBuffer wrapping the latest shm frame. Caller must
// CFRelease the result.
static CMSampleBufferRef vcc_build_cmsb_from_shm(void) {
  pthread_mutex_lock(&vcc_latest_frame.lock);
  uint32_t w = vcc_latest_frame.width;
  uint32_t h = vcc_latest_frame.height;
  uint32_t bpr = vcc_latest_frame.bytes_per_row;
  size_t len = vcc_latest_frame.pixels_length;
  if (!len || !w || !h || !bpr) {
    pthread_mutex_unlock(&vcc_latest_frame.lock);
    return NULL;
  }
  void *pixels = malloc(len);
  if (!pixels) {
    pthread_mutex_unlock(&vcc_latest_frame.lock);
    return NULL;
  }
  memcpy(pixels, vcc_latest_frame.pixels, len);
  pthread_mutex_unlock(&vcc_latest_frame.lock);

  CVPixelBufferRef pb = NULL;
  CVReturn cvr = CVPixelBufferCreateWithBytes(
      kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
      pixels, bpr, vcc_cv_release_bytes, NULL, NULL, &pb);
  if (cvr != kCVReturnSuccess || !pb) {
    free(pixels);
    return NULL;
  }

  CMVideoFormatDescriptionRef desc = NULL;
  OSStatus s = CMVideoFormatDescriptionCreateForImageBuffer(
      kCFAllocatorDefault, pb, &desc);
  if (s != noErr || !desc) {
    CVPixelBufferRelease(pb);
    return NULL;
  }

  // Monotonic PTS at 30 fps. The viewfinder's internal jitter buffer
  // discards frames whose PTS doesn't advance, so we increment per call.
  vcc_vf_pts_ns += 33333333ull;  // 1/30s in nanoseconds
  CMSampleTimingInfo timing = {
      .duration = CMTimeMake(1, 30),
      .presentationTimeStamp = CMTimeMake((int64_t)vcc_vf_pts_ns, 1000000000),
      .decodeTimeStamp = kCMTimeInvalid,
  };

  CMSampleBufferRef cmsb = NULL;
  s = CMSampleBufferCreateForImageBuffer(
      kCFAllocatorDefault, pb, true, NULL, NULL, desc, &timing, &cmsb);
  CFRelease(desc);
  CVPixelBufferRelease(pb);
  if (s != noErr || !cmsb) return NULL;
  return cmsb;
}

static void vcc_vf_drive_once(void) {
  if (!vcc_vf_streams || vcc_vf_streams.count == 0) return;
  CMSampleBufferRef cmsb = vcc_build_cmsb_from_shm();
  if (!cmsb) return;
  SEL sel = NSSelectorFromString(@"enqueueVideoSampleBuffer:");
  for (id stream in [vcc_vf_streams copy]) {
    int ret = ((int (*)(id, SEL, CMSampleBufferRef))objc_msgSend)(
        stream, sel, cmsb);
    vcc_vf_enqueue_count++;
    if (ret == 0) vcc_vf_enqueue_success++;
    if ((vcc_vf_enqueue_count & 29) == 1) {
      vcc_log(@"  [VFS drive] enqueue ret=%d (count=%llu ok=%llu)",
              ret,
              (unsigned long long)vcc_vf_enqueue_count,
              (unsigned long long)vcc_vf_enqueue_success);
    }
  }
  CFRelease(cmsb);
}

static void vcc_install_viewfinder_hooks(void) {
  Class cls = NSClassFromString(@"FigCameraViewfinderStream");
  if (!cls) {
    vcc_log(@"  VF hook: class missing");
    return;
  }
  SEL init_sel = NSSelectorFromString(@"init");
  SEL open_sel = NSSelectorFromString(@"openWithDestination:");
  SEL close_sel = NSSelectorFromString(@"close");
  Method m;
  if ((m = class_getInstanceMethod(cls, init_sel))) {
    vcc_vfs_init_orig = method_setImplementation(m, (IMP)vcc_vfs_init_hook);
  }
  if ((m = class_getInstanceMethod(cls, open_sel))) {
    vcc_vfs_open_orig = method_setImplementation(m, (IMP)vcc_vfs_open_hook);
  }
  if ((m = class_getInstanceMethod(cls, close_sel))) {
    vcc_vfs_close_orig = method_setImplementation(m, (IMP)vcc_vfs_close_hook);
  }
  vcc_log(@"  swizzled FigCameraViewfinderStream init/open/close");

  // Drive at 30 Hz. Frames are enqueued only when at least one stream is
  // open AND a fresh shm frame exists (covered by build_cmsb_from_shm).
  vcc_vf_q = dispatch_queue_create("com.vphone.vcam.vfdrive",
                                     DISPATCH_QUEUE_SERIAL);
  vcc_vf_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          vcc_vf_q);
  dispatch_source_set_timer(vcc_vf_timer,
                            dispatch_time(DISPATCH_TIME_NOW, 0),
                            33333333ull, 2000000ull);
  dispatch_source_set_event_handler(vcc_vf_timer, ^{
    @autoreleasepool { vcc_vf_drive_once(); }
  });
  dispatch_resume(vcc_vf_timer);
  vcc_log(@"  viewfinder drive timer armed (30 Hz)");
}

static void vcc_install_sink_observation(void) {
  Class iqsn = NSClassFromString(@"BWImageQueueSinkNode");
  Class rqsn = NSClassFromString(@"BWRemoteQueueSinkNode");
  if (!iqsn || !rqsn) {
    vcc_log(@"  sink obs: classes missing iqsn=%p rqsn=%p", iqsn, rqsn);
    return;
  }

  SEL iqsnInit = NSSelectorFromString(
      @"initWithHFRSupport:ispJitterCompensationEnabled:"
      @"clientAuditToken:sinkID:");
  SEL rqsnInit = NSSelectorFromString(
      @"initWithMediaType:clientAuditToken:sinkID:cameraInfoByPortType:");
  SEL renderSel = @selector(renderSampleBuffer:forInput:);

  vcc_swizzle_method(iqsn, iqsnInit, (IMP)vcc_iqsn_init_hook,
                      &vcc_iqsn_init_orig);
  vcc_swizzle_method(rqsn, rqsnInit, (IMP)vcc_rqsn_init_hook,
                      &vcc_rqsn_init_orig);
  vcc_swizzle_method(iqsn, renderSel, (IMP)vcc_iqsn_render_hook,
                      &vcc_iqsn_render_orig);
  vcc_swizzle_method(rqsn, renderSel, (IMP)vcc_rqsn_render_hook,
                      &vcc_rqsn_render_orig);
}
