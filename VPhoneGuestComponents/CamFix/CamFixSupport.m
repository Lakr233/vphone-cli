// Logging and the "is this bound to our virtual camera" probes every hook
// shares.

#import "CamFixPrivate.h"

// MARK: - logging

void cfxlog(NSString *fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  FILE *fp = fopen(VPHONE_VCAM_APP_LOG_PATH, "a");
  if (fp) {
    fprintf(fp, "[camfix:%d] %s\n", getpid(), line.UTF8String ?: "?");
    fclose(fp);
  } else {
    NSLog(@"camfix: %@", line);
  }
}

// MARK: - runtime overrides

// Optional knobs, read at most once a second from
// VPHONE_VCAM_DIRECTORY/camfix-video.plist so a guest can be tuned without
// redeploying the dylib (vphoned files.write can put it there). Absent keys
// keep the default behaviour.
//   position  (string) "front" / "back": the side the vcam device reports
//   zoom      (number) >= 1, crops data-output frames further into the centre
//   turns     (int)    extra clockwise quarter turns for data-output frames
//   mirror    (bool)   replaces the connection's videoMirrored
//   dumpFrame (bool)   every 3 s, saves a delivered frame as delivered.jpg
NSDictionary *cfx_overrides(void) {
  static NSDictionary *cached = nil;
  static CFAbsoluteTime readAt = 0;
  static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
  pthread_mutex_lock(&lock);
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (now - readAt > 1.0) {
    readAt = now;
    NSDictionary *d = [NSDictionary
        dictionaryWithContentsOfFile:@VPHONE_VCAM_DIRECTORY "/camfix-video.plist"];
    if (!(d == cached || [d isEqual:cached])) {
      cfxlog(@"[overrides] %@", d ?: @"(none)");
    }
    cached = d;
  }
  NSDictionary *d = cached;
  pthread_mutex_unlock(&lock);
  return d;
}

// MARK: - vcam binding probes

BOOL cfx_session_is_for_vcam(AVCaptureSession *session) {
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

BOOL cfx_output_is_for_vcam(id self) {
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
  } @catch (NSException *e) {
    cfxlog(@"connection probe exception: %@", e);
  }
  return NO;
}
