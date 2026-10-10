// Front-camera alias for the single virtual camera.
//
// The synthetic source is published once, as a back camera
// (kFigCaptureSourceAttributeKey_Position = 1). A client that asks for the
// front camera gets no device, its session has no input,
// cfx_session_is_for_vcam() never matches and its AVCaptureVideoDataOutput
// starves. Only the preview layer pump still draws frames, so the screen
// looks alive while nothing reaches the client's sample buffer delegate.
//
// The alias answers an empty front or back lookup with the vcam device, and
// reports the vcam device's position as the side the process asked for last.
// One process uses one side at a time, which is what a phone with two
// cameras looks like to it. A client that enumerates devicesWithMediaType:
// and filters on position never says which side it wants; for those the
// `position` override decides (CamFixSupport.m).

#import "CamFixPrivate.h"

static _Atomic long cfx_vcam_reported_position = AVCaptureDevicePositionBack;
static const void *kCfxRequestedPositionKey = &kCfxRequestedPositionKey;
static int cfx_front_alias_logged = 0;

static AVCaptureDevice *cfx_vcam_device(void) {
  return [AVCaptureDevice deviceWithUniqueID:VCAM_UID];
}

static BOOL cfx_is_video_request(NSString *mediaType) {
  return mediaType == nil || [mediaType isEqualToString:AVMediaTypeVideo];
}

static void cfx_note_requested_position(long position, NSString *via) {
  if (position != AVCaptureDevicePositionFront &&
      position != AVCaptureDevicePositionBack) {
    return;
  }
  long previous = cfx_vcam_reported_position;
  cfx_vcam_reported_position = position;
  if (previous != position) {
    cfxlog(@"[front alias] %@ asked for %@; vcam now reports that side", via,
           position == AVCaptureDevicePositionFront ? @"front" : @"back");
  }
}

// MARK: - -[AVCaptureDevice position]

static IMP cfx_orig_device_position = NULL;

static long cfx_device_position_hook(id self, SEL _cmd) {
  typedef long (*Fn)(id, SEL);
  long real = ((Fn)cfx_orig_device_position)(self, _cmd);
  NSString *uid = nil;
  @try { uid = [self valueForKey:@"uniqueID"]; } @catch (NSException *e) {}
  if (![uid isEqualToString:VCAM_UID]) return real;
  // A client that enumerates devicesWithMediaType: and filters on position
  // never says which side it wants; the override decides for it.
  NSString *forced = cfx_overrides()[@"position"];
  if ([forced isEqualToString:@"front"]) return AVCaptureDevicePositionFront;
  if ([forced isEqualToString:@"back"]) return AVCaptureDevicePositionBack;
  return cfx_vcam_reported_position;
}

// MARK: - +[AVCaptureDevice devicesWithMediaType:] diagnostics

static IMP cfx_orig_devices_with_media = NULL;
static int cfx_devices_diag_logged = 0;

static NSArray *cfx_devices_with_media_hook(id self, SEL _cmd, NSString *mediaType) {
  typedef NSArray *(*Fn)(id, SEL, NSString *);
  NSArray *devices = ((Fn)cfx_orig_devices_with_media)(self, _cmd, mediaType);
  if (cfx_devices_diag_logged++ < 4) {
    NSMutableArray *desc = [NSMutableArray array];
    for (AVCaptureDevice *d in devices) {
      [desc addObject:[NSString stringWithFormat:@"%@(pos=%ld)", d.uniqueID, (long)d.position]];
    }
    cfxlog(@"[front alias] devicesWithMediaType:%@ -> %@", mediaType, desc);
  }
  return devices;
}

// MARK: - +[AVCaptureDevice defaultDeviceWithDeviceType:mediaType:position:]

static IMP cfx_orig_default_device = NULL;

static id cfx_default_device_hook(id self, SEL _cmd, NSString *deviceType,
                                  NSString *mediaType, long position) {
  cfx_note_requested_position(position, @"defaultDeviceWithDeviceType");
  typedef id (*Fn)(id, SEL, NSString *, NSString *, long);
  id dev = ((Fn)cfx_orig_default_device)(self, _cmd, deviceType, mediaType, position);
  // The vcam is the only camera, so an empty answer for either side gets it:
  // with the `position` override set, the device reports one side and AVF's
  // own position match would otherwise lose the other.
  if (dev || !cfx_is_video_request(mediaType) ||
      (position != AVCaptureDevicePositionFront && position != AVCaptureDevicePositionBack)) {
    return dev;
  }
  AVCaptureDevice *vcam = cfx_vcam_device();
  if (vcam && cfx_front_alias_logged++ < 8) {
    cfxlog(@"[front alias] defaultDevice(%@, %ld) empty -> %@", deviceType, position, VCAM_UID);
  }
  return vcam;
}

// MARK: - AVCaptureDeviceDiscoverySession

static IMP cfx_orig_discovery_make = NULL;
static IMP cfx_orig_discovery_devices = NULL;

static id cfx_discovery_make_hook(id self, SEL _cmd, NSArray *deviceTypes,
                                  NSString *mediaType, long position) {
  cfx_note_requested_position(position, @"discoverySession");
  typedef id (*Fn)(id, SEL, NSArray *, NSString *, long);
  id session = ((Fn)cfx_orig_discovery_make)(self, _cmd, deviceTypes, mediaType, position);
  if (session && cfx_is_video_request(mediaType)) {
    objc_setAssociatedObject(session, kCfxRequestedPositionKey, @(position),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return session;
}

static NSArray *cfx_discovery_devices_hook(id self, SEL _cmd) {
  typedef NSArray *(*Fn)(id, SEL);
  NSArray *devices = ((Fn)cfx_orig_discovery_devices)(self, _cmd);
  NSNumber *requested = objc_getAssociatedObject(self, kCfxRequestedPositionKey);
  long side = requested.longValue;
  if (devices.count > 0 ||
      (side != AVCaptureDevicePositionFront && side != AVCaptureDevicePositionBack)) {
    return devices;
  }
  AVCaptureDevice *vcam = cfx_vcam_device();
  if (!vcam) return devices;
  if (cfx_front_alias_logged++ < 8) {
    cfxlog(@"[front alias] discovery(%ld).devices empty -> [%@]", side, VCAM_UID);
  }
  return @[vcam];
}

// MARK: - install

void cfx_install_front_camera_alias(void) {
  Class devCls = NSClassFromString(@"AVCaptureDevice");
  Class figCls = NSClassFromString(@"AVCaptureFigVideoDevice");
  Class discCls = NSClassFromString(@"AVCaptureDeviceDiscoverySession");

  // The vcam device is an AVCaptureFigVideoDevice; hook position where that
  // class (or its superclass) answers it.
  Method pos = figCls ? class_getInstanceMethod(figCls, @selector(position)) : NULL;
  if (pos) {
    cfx_orig_device_position = method_setImplementation(pos, (IMP)cfx_device_position_hook);
    cfxlog(@"installed front alias: position");
  }
  Method def = devCls ? class_getClassMethod(
                            devCls, @selector(defaultDeviceWithDeviceType:mediaType:position:))
                      : NULL;
  if (def) {
    cfx_orig_default_device = method_setImplementation(def, (IMP)cfx_default_device_hook);
    cfxlog(@"installed front alias: defaultDeviceWithDeviceType");
  }
  Method dwm = devCls ? class_getClassMethod(devCls, @selector(devicesWithMediaType:)) : NULL;
  if (dwm) {
    cfx_orig_devices_with_media = method_setImplementation(dwm, (IMP)cfx_devices_with_media_hook);
    cfxlog(@"installed devicesWithMediaType diag");
  }
  Method make = discCls ? class_getClassMethod(
                              discCls, @selector(discoverySessionWithDeviceTypes:mediaType:position:))
                        : NULL;
  Method devs = discCls ? class_getInstanceMethod(discCls, @selector(devices)) : NULL;
  if (make && devs) {
    cfx_orig_discovery_make = method_setImplementation(make, (IMP)cfx_discovery_make_hook);
    cfx_orig_discovery_devices = method_setImplementation(devs, (IMP)cfx_discovery_devices_hook);
    cfxlog(@"installed front alias: discovery session");
  }
}
