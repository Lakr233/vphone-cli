// Frames delivered straight to AVCaptureVideoDataOutput delegates of vcam
// sessions whose capture graph never runs.

#import "CamFixPrivate.h"
#include "CamFixFrameGeometry.h"

// MARK: - client-side video delivery for vcam sessions
//
// When a session's capture graph never runs, its AVCaptureVideoDataOutput
// delegates starve. Deliver the shared-layer sample directly to the
// delegate on the output's own callback queue — the same pattern as the
// photo delivery path. In this VM the synthetic source is the only camera,
// so any vcam session's data output is ours. Stops while the graph
// delivers (see cfx_graph_is_delivering).

static NSHashTable *cfx_vcam_sessions = nil;  // weak, guarded
static pthread_mutex_t cfx_vcam_sessions_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t cfx_video_deliver_count = 0;
static _Atomic uint64_t cfx_video_deliver_ok = 0;
static _Atomic int cfx_video_deliver_logged = 0;

// Also arms the 30 Hz pump: a session with a data output and no preview
// layer would otherwise never start it.
void cfx_track_vcam_session(id session) {
  if (!session) return;
  BOOL added = NO;
  pthread_mutex_lock(&cfx_vcam_sessions_lock);
  if (!cfx_vcam_sessions) cfx_vcam_sessions = [NSHashTable weakObjectsHashTable];
  if (![cfx_vcam_sessions containsObject:session]) {
    [cfx_vcam_sessions addObject:session];
    added = YES;
  }
  pthread_mutex_unlock(&cfx_vcam_sessions_lock);
  if (!added) return;
  cfxlog(@"[video delivery] tracking session %p", session);
  dispatch_async(dispatch_get_main_queue(), ^{ cfx_preview_start_timer(); });
}

// MARK: - per-connection frame shape

// The pixel format the client asked for; the data plane produces BGRA or
// 420v, so a 420f request gets 420v (logged once).
static uint32_t cfx_output_pixel_format(id out) {
  NSDictionary *settings = nil;
  @try { settings = [out valueForKey:@"videoSettings"]; } @catch (NSException *e) {}
  uint32_t want = [settings[(NSString *)kCVPixelBufferPixelFormatTypeKey] unsignedIntValue];
  if (want == VCC_FMT_BGRA) return VCC_FMT_BGRA;
  if (want == VCC_FMT_420V || want == VCC_FMT_420F) {
    static int logged = 0;
    if (want == VCC_FMT_420F && logged++ == 0) {
      cfxlog(@"[video delivery] client asked for 420f; delivering 420v");
    }
    return VCC_FMT_420V;
  }
  return VCC_FMT_BGRA;
}

// Clockwise angle the connection wants, 0 being the landscape frame.
static int cfx_connection_angle(id conn) {
  double a = 0;
  @try { a = [[conn valueForKey:@"videoRotationAngle"] doubleValue]; } @catch (NSException *e) {}
  return ((int)lround(a / 90.0) & 3) * 90;
}

// Landscape size a session preset delivers on a real camera; 0 x 0 when the
// preset does not pin one (Photo, High, InputPriority), so the frame's own
// size is kept.
static void cfx_preset_size(id out, uint32_t *w, uint32_t *h) {
  NSString *preset = nil;
  @try { preset = [[out valueForKey:@"session"] valueForKey:@"sessionPreset"]; }
  @catch (NSException *e) {}
  static NSDictionary *sizes = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sizes = @{
      AVCaptureSessionPreset352x288: @[@352, @288],
      AVCaptureSessionPreset640x480: @[@640, @480],
      AVCaptureSessionPreset1280x720: @[@1280, @720],
      AVCaptureSessionPreset1920x1080: @[@1920, @1080],
      AVCaptureSessionPresetiFrame960x540: @[@960, @540],
      AVCaptureSessionPresetiFrame1280x720: @[@1280, @720],
    };
  });
  NSArray *wh = preset ? sizes[preset] : nil;
  *w = [wh[0] unsignedIntValue];
  *h = [wh[1] unsignedIntValue];
}

static id cfx_first_video_connection(id out) {
  NSArray *conns = nil;
  @try { conns = [out valueForKey:@"connections"]; } @catch (NSException *e) {}
  return conns.firstObject;
}

// The size this output's frames will have: the preset turned for the
// connection, or the portrait / landscape crop of the shm frame.
BOOL cfx_output_frame_size(id out, uint32_t *w, uint32_t *h) {
  uint32_t pw = 0, ph = 0, fw = 0, fh = 0;
  cfx_preset_size(out, &pw, &ph);
  if (!cfx_shm_frame_size(&fw, &fh)) return NO;
  cfx_frame_plan_t plan;
  double zoom = [cfx_overrides()[@"zoom"] doubleValue];
  if (cfx_frame_plan(fw, fh, pw, ph, cfx_connection_angle(cfx_first_video_connection(out)),
                     zoom, &plan) != 0) {
    return NO;
  }
  *w = plan.out_w;
  *h = plan.out_h;
  return YES;
}

static CMSampleBufferRef cfx_build_cmsb_for(id out, id conn) {
  NSDictionary *ov = cfx_overrides();
  uint32_t fmt = cfx_output_pixel_format(out);
  int angle = cfx_connection_angle(conn);
  BOOL mirror = NO;
  @try { mirror = [[conn valueForKey:@"videoMirrored"] boolValue]; } @catch (NSException *e) {}
  if (ov[@"mirror"]) mirror = [ov[@"mirror"] boolValue];
  int turns = [ov[@"turns"] intValue];
  double zoom = [ov[@"zoom"] doubleValue];
  uint32_t pw = 0, ph = 0;
  cfx_preset_size(out, &pw, &ph);

  uint32_t w = 0, h = 0;
  CMSampleBufferRef sb =
      cfx_build_oriented_cmsb(fmt, pw, ph, angle, zoom, turns, mirror, &w, &h);
  // Override `dumpFrame`: every 3 s, save what the client receives.
  static CFAbsoluteTime dumpedAt = 0;
  if (sb && [ov[@"dumpFrame"] boolValue] && CFAbsoluteTimeGetCurrent() - dumpedAt > 3) {
    dumpedAt = CFAbsoluteTimeGetCurrent();
    CGImageRef img = vcc_cgimage_from_pixel_buffer(CMSampleBufferGetImageBuffer(sb));
    NSData *jpg = cfx_jpeg_from_cgimage(img);
    if (img) CGImageRelease(img);
    [jpg writeToFile:@VPHONE_VCAM_DIRECTORY "/delivered.jpg" atomically:YES];
  }
  static uint64_t shapeKey = 0;
  uint64_t key = ((uint64_t)fmt << 32) ^ ((uint64_t)(angle & 0x3ff) << 20) ^
                 ((uint64_t)(turns & 3) << 16) ^ ((uint64_t)mirror << 15) ^
                 ((uint64_t)w << 40) ^ (uint64_t)h;
  if (sb && key != shapeKey) {
    shapeKey = key;
    cfxlog(@"[video delivery] shape fmt=%.4s preset=%ux%u angle=%d turns=%d mirror=%d -> %ux%u",
           (char *)&(uint32_t){CFSwapInt32HostToBig(fmt)}, pw, ph, angle, turns & 3, mirror,
           w, h);
  }
  return sb;
}

void cfx_deliver_video_frames_once(void) {
  pthread_mutex_lock(&cfx_vcam_sessions_lock);
  NSArray *sessions = cfx_vcam_sessions.allObjects;
  pthread_mutex_unlock(&cfx_vcam_sessions_lock);
  if (sessions.count == 0 || cfx_graph_is_delivering()) return;
  Class dataOutCls = NSClassFromString(@"AVCaptureVideoDataOutput");
  if (!dataOutCls) return;

  for (id sess in sessions) {
    NSArray *outputs = nil;
    @try { outputs = [sess valueForKey:@"outputs"]; } @catch (NSException *e) { continue; }
    for (id out in outputs) {
      if (![out isKindOfClass:dataOutCls]) continue;
      id delegate = nil;
      dispatch_queue_t q = nil;
      @try { delegate = [out valueForKey:@"sampleBufferDelegate"]; } @catch (NSException *e) {}
      @try { q = [out valueForKey:@"sampleBufferCallbackQueue"]; } @catch (NSException *e) {}
      if (!delegate) continue;
      NSArray *conns = nil;
      @try { conns = [out valueForKey:@"connections"]; } @catch (NSException *e) {}
      for (id conn in conns) {
        BOOL enabled = NO;
        @try { enabled = [[conn valueForKey:@"enabled"] boolValue]; } @catch (NSException *e) {}
        if (!enabled) continue;
        CMSampleBufferRef sb = cfx_build_cmsb_for(out, conn);
        if (!sb) continue;
        cfx_video_deliver_count++;
        dispatch_async(q ?: dispatch_get_main_queue(), ^{
          @autoreleasepool {
            @try {
              ((void (*)(id, SEL, id, CMSampleBufferRef, id))objc_msgSend)(
                  delegate,
                  @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                  out,
                  sb,
                  conn);
              cfx_video_deliver_ok++;
            } @catch (NSException *e) {
              if (cfx_video_deliver_logged++ < 8) {
                cfxlog(@"[video delivery] delegate exception: %@", e);
              }
            }
            CFRelease(sb);
          }
        });
      }
    }
  }
  if (cfx_video_deliver_count && (cfx_video_deliver_count % 90) == 1) {
    cfxlog(@"[video delivery] attempted=%llu ok=%llu",
           (unsigned long long)cfx_video_deliver_count,
           (unsigned long long)cfx_video_deliver_ok);
  }
}
