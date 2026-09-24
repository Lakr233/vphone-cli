// MARK: - synthetic FigCaptureStream subclass
//
// Subclass BWFigCaptureStream. Ivar offsets are resolved at synth-class
// init time via the ObjC runtime so the layout follows whatever Apple
// ships. Historical disasm of -[BWFigCaptureStream initWith…] and the
// trivial ivar accessors gave us the slot semantics:
//
//   figCaptureStream  : C handle, leave NULL
//   portType          : NSString
//   uniqueID          : NSString
//   isSpecialDeviceID : BOOL (we don't touch it)
//   property cache    : NSDictionary — DO NOT write a non-dict here.
//             Earlier iteration put a deviceID string in the slot; the
//             inherited -_copyProperty: calls [cache
//             objectForKeyedSubscript:key] unconditionally, and the
//             unrecognized-selector crashed cameracaptured. Leave NULL
//             so the lookup short-circuits to nil.
//   streaming         : BOOL — set to 1 so -streaming returns YES.

static Class vcc_synth_stream_class = Nil;
// Resolved at synth-class init. portType/uniqueID are required (-1 -> abort
// class registration); streaming is optional (-1 -> skip the YES poke).
static ptrdiff_t kBWFigCaptureStream_portType_Offset  = -1;
static ptrdiff_t kBWFigCaptureStream_uniqueID_Offset  = -1;
static ptrdiff_t kBWFigCaptureStream_streaming_Offset = -1;

static CFStringRef vcc_cf_kSupportedFormatsArray = NULL;

__attribute__((ns_returns_retained))
static id vcc_synth_stream_copy_property(id self,
                                         SEL _cmd,
                                         id property,
                                         int *err) {
  if (!vcc_cf_kSupportedFormatsArray) {
    vcc_cf_kSupportedFormatsArray =
        vcc_cfconst("kFigCaptureStreamProperty_SupportedFormatsArray");
  }
  if (vcc_cf_kSupportedFormatsArray &&
      [(__bridge id)vcc_cf_kSupportedFormatsArray isEqual:property]) {
    if (err) *err = 0;
    // Empirically: empty SupportedFormatsArray returns +1-retained per
    // ns_returns_retained convention. Non-empty arrays (objects or dicts)
    // trip a daemon-side validation that we don't satisfy → isRunning=0.
    // The AVCaptureDevice.formats list is populated separately via
    // -[FigCaptureSourceBacking initWith…formats:…], so the AVF client
    // still sees both formats and selects activeFormat.
    vcc_log(@"  [SynthStream copyProperty:SupportedFormatsArray] -> empty array");
    return [[NSArray alloc] init];
  }
  if (err) *err = -12787;
  vcc_log(@"  [SynthStream copyProperty:%@] -> nil (err=-12787)",
          [property description]);
  return nil;
}

__attribute__((ns_returns_retained))
static id vcc_synth_stream_copy_property_if_supported(id self,
                                                      SEL _cmd,
                                                      id property,
                                                      int *err) {
  if (err) *err = 0;
  vcc_log(@"  [SynthStream copyPropertyIfSupported:%@] -> nil",
          [property description]);
  return nil;
}

static int vcc_synth_stream_get_property(id self,
                                         SEL _cmd,
                                         id property,
                                         int *err) {
  NSString *propStr = [property description];
  // The daemon's session-start path queries PixelSize on the stream and
  // treats err=-12787 as fatal — propagates up to AVCaptureSessionRuntimeError
  // and stops the session. Return 0 with err=0 (supported, zero value) so
  // the check passes. Same defensive default for any other property we
  // haven't otherwise explicitly handled.
  if (err) *err = 0;
  vcc_log(@"  [SynthStream getProperty:%@] -> 0 err=0", propStr);
  return 0;
}

static int vcc_synth_stream_get_property_if_supported(id self,
                                                      SEL _cmd,
                                                      id property,
                                                      int *err) {
  if (err) *err = 0;
  vcc_log(@"  [SynthStream getPropertyIfSupported:%@] -> 0 err=0",
          [property description]);
  return 0;
}

// Catches the private _copyProperty:requireSupported:error: path. Same
// effective result as -copyProperty:error: (canned values for known
// keys, -12787 otherwise) — just a 3rd BOOL arg.
static id vcc_synth_stream_underscore_copy_property(id self,
                                                    SEL _cmd,
                                                    id property,
                                                    BOOL requireSupported,
                                                    int *err) {
  return vcc_synth_stream_copy_property(self, @selector(copyProperty:error:),
                                         property, err);
}

static id vcc_synth_stream_supported_properties(id self, SEL _cmd) {
  return [NSDictionary dictionary];
}

static int vcc_synth_stream_set_property(id self,
                                         SEL _cmd,
                                         id property,
                                         id value) {
  vcc_log(@"  [SynthStream setProperty:%@] (ignored)", [property description]);
  return 0;
}

static void vcc_synth_stream_dealloc(id self, SEL _cmd) {
  void *p = (__bridge void *)self;
  void **portTypeSlot = (void **)((char *)p + kBWFigCaptureStream_portType_Offset);
  void **uniqueIDSlot = (void **)((char *)p + kBWFigCaptureStream_uniqueID_Offset);
  if (*portTypeSlot) { CFRelease(*portTypeSlot); *portTypeSlot = NULL; }
  if (*uniqueIDSlot) { CFRelease(*uniqueIDSlot); *uniqueIDSlot = NULL; }
  // Skip parent's -dealloc (would touch many uninitialized ivars). Manually
  // destruct + free the storage. ARC blocks direct objc_destructInstance,
  // so resolve via dlsym.
  static void *(*destruct)(id) = NULL;
  if (!destruct) destruct = dlsym(RTLD_DEFAULT, "objc_destructInstance");
  if (destruct) destruct(self);
  free((__bridge void *)self);
}

static void vcc_init_synth_stream_class(void) {
  if (vcc_synth_stream_class) return;
  Class parent = NSClassFromString(@"BWFigCaptureStream");
  if (!parent) {
    vcc_log(@"  synth-stream: BWFigCaptureStream class missing");
    return;
  }
  static const char *const kPortTypeNames[]  = {"_portType", "portType", NULL};
  static const char *const kUniqueIDNames[]  = {"_uniqueID", "uniqueID", NULL};
  static const char *const kStreamingNames[] = {
      "_streaming", "streaming", "_isStreaming", "isStreaming", NULL,
  };
  kBWFigCaptureStream_portType_Offset = vcc_resolve_ivar(
      parent, "BWFigCaptureStream.portType", kPortTypeNames);
  kBWFigCaptureStream_uniqueID_Offset = vcc_resolve_ivar(
      parent, "BWFigCaptureStream.uniqueID", kUniqueIDNames);
  kBWFigCaptureStream_streaming_Offset = vcc_resolve_ivar(
      parent, "BWFigCaptureStream.streaming", kStreamingNames);
  if (kBWFigCaptureStream_portType_Offset < 0 ||
      kBWFigCaptureStream_uniqueID_Offset < 0) {
    vcc_log(@"  synth-stream: required ivar(s) not found — registration aborted");
    return;
  }
  Class cls = objc_allocateClassPair(parent, "VccSynthStream", 0);
  if (!cls) {
    vcc_log(@"  synth-stream: objc_allocateClassPair failed");
    return;
  }
  class_addMethod(cls, @selector(copyProperty:error:),
                  (IMP)vcc_synth_stream_copy_property, "@@:@^i");
  class_addMethod(cls, @selector(copyPropertyIfSupported:error:),
                  (IMP)vcc_synth_stream_copy_property_if_supported, "@@:@^i");
  class_addMethod(cls, @selector(getProperty:error:),
                  (IMP)vcc_synth_stream_get_property, "i@:@^i");
  class_addMethod(cls, @selector(getPropertyIfSupported:error:),
                  (IMP)vcc_synth_stream_get_property_if_supported, "i@:@^i");
  // Also override the underlying _copyProperty:requireSupported:error:
  // so any inherited call path that bypasses the public wrappers (e.g.
  // -getPropertyIfSupported: in older code paths) still lands here
  // instead of crashing on the NULL figCaptureStream vtable deref.
  class_addMethod(cls,
                  NSSelectorFromString(@"_copyProperty:requireSupported:error:"),
                  (IMP)vcc_synth_stream_underscore_copy_property, "@@:@B^i");
  class_addMethod(cls, @selector(supportedProperties),
                  (IMP)vcc_synth_stream_supported_properties, "@@:");
  class_addMethod(cls, @selector(setProperty:value:),
                  (IMP)vcc_synth_stream_set_property, "i@:@@");
  class_addMethod(cls, NSSelectorFromString(@"dealloc"),
                  (IMP)vcc_synth_stream_dealloc, "v@:");
  objc_registerClassPair(cls);
  vcc_synth_stream_class = cls;
  vcc_log(@"  registered VccSynthStream : BWFigCaptureStream (cls=%p)", cls);
}

// Strong references to every manufactured synth stream, so they can't be
// released early by autorelease churn or refcount bugs in our dealloc.
// Memory grows by one stream per session start; acceptable for diagnosis.
static NSMutableArray *vcc_synth_streams_strong_refs = nil;

__attribute__((ns_returns_retained))
static id vcc_make_synth_stream(NSString *uniqueID,
                                NSString *deviceID,
                                NSString *portType) {
  if (!vcc_synth_stream_class) vcc_init_synth_stream_class();
  if (!vcc_synth_stream_class) return nil;
  // Use +alloc via runtime — ARC-safe (class_createInstance is
  // OBJC_ARC_UNAVAILABLE and the retain-count semantics don't match what
  // ARC expects). Function attributed ns_returns_retained so callers
  // treat the +1 from alloc correctly without autorelease.
  id s = ((id (*)(Class, SEL))objc_msgSend)(vcc_synth_stream_class,
                                              @selector(alloc));
  if (!s) return nil;

  void *p = (__bridge void *)s;
  *(void **)((char *)p + kBWFigCaptureStream_portType_Offset) =
      (void *)CFBridgingRetain([portType copy]);
  *(void **)((char *)p + kBWFigCaptureStream_uniqueID_Offset) =
      (void *)CFBridgingRetain([uniqueID copy]);
  // property-cache NSDictionary ivar intentionally left NULL — the
  // parent class unconditionally sends -objectForKeyedSubscript: to it,
  // and an earlier iteration that stored deviceID there crashed with
  // unrecognized-selector. The deviceID isn't read off the stream by
  // inherited code anyway (only a per-stream BOOL comparison result is).
  (void)deviceID;
  // streaming BOOL — set to 1 so -streaming returns YES. Optional:
  // skip if the ivar isn't present on this build.
  if (kBWFigCaptureStream_streaming_Offset >= 0) {
    *(uint8_t *)((char *)p + kBWFigCaptureStream_streaming_Offset) = 1;
  }

  // Pin so dealloc never runs — diagnostic to isolate the autorelease-
  // pool-drain crash. Each session start leaks one stream.
  if (!vcc_synth_streams_strong_refs) {
    vcc_synth_streams_strong_refs = [NSMutableArray new];
  }
  [vcc_synth_streams_strong_refs addObject:s];

  vcc_log(@"  synth-stream: %p uid=%@ port=%@ devID=%@",
          s, uniqueID, portType, deviceID);
  return s;
}

// MARK: - hook BWFigCaptureDeviceVendor copyStreamsWithUniqueIDs:forDevice:
//
// When forDevice is our synth, manufacture one VccSynthStream per requested
// uniqueID so that the vendor's identity-matching inner loop in
// `-_copyStreamsForAttributes:` produces a result array whose count matches
// the input attributes count.

static IMP vcc_copy_streams_orig = NULL;
typedef id (*VccCopyStreamsFn)(id self,
                               SEL _cmd,
                               NSArray *uniqueIDs,
                               id forDevice,
                               int priority,
                               int *err);

static id vcc_copy_streams_hook(id self,
                                SEL _cmd,
                                NSArray *uniqueIDs,
                                id forDevice,
                                int priority,
                                int *err) {
  if (forDevice && object_getClass(forDevice) == vcc_synth_device_class) {
    vcc_log(@"  [copyStreamsWithUniqueIDs forDevice:synth] ids=%@", uniqueIDs);
    NSMutableArray *out = [NSMutableArray array];
    void *p = (__bridge void *)forDevice;
    NSString *devID = (__bridge NSString *)(*(void **)((char *)p + kBWFigCaptureDevice_deviceID_Offset));
    for (NSString *uid in uniqueIDs) {
      id s = vcc_make_synth_stream(uid, devID, @"Back");
      if (s) [out addObject:s];
    }
    if (err) *err = 0;
    vcc_log(@"  [copyStreamsWithUniqueIDs] -> %lu streams",
            (unsigned long)out.count);
    return out;
  }
  VccCopyStreamsFn orig = (VccCopyStreamsFn)vcc_copy_streams_orig;
  return orig(self, _cmd, uniqueIDs, forDevice, priority, err);
}

static void vcc_install_copy_streams_hook(void) {
  Class cls = NSClassFromString(@"BWFigCaptureDeviceVendor");
  if (!cls) return;
  SEL sel = NSSelectorFromString(
      @"copyStreamsWithUniqueIDs:forDevice:deviceClientPriority:error:");
  vcc_swizzle_method(cls, sel, (IMP)vcc_copy_streams_hook, &vcc_copy_streams_orig);
}

static IMP vcc_copy_streams_from_orig = NULL;
typedef id (*VccCopyStreamsFromFn)(id self,
                                   SEL _cmd,
                                   id fromDevice,
                                   NSArray *positions,
                                   NSArray *deviceTypes,
                                   int prio,
                                   BOOL allowsLoss,
                                   int *err);

static id vcc_copy_streams_from_hook(id self,
                                     SEL _cmd,
                                     id fromDevice,
                                     NSArray *positions,
                                     NSArray *deviceTypes,
                                     int prio,
                                     BOOL allowsLoss,
                                     int *err) {
  if (fromDevice && object_getClass(fromDevice) == vcc_synth_device_class) {
    vcc_log(@"  [copyStreamsFromDevice:synth positions=%@ deviceTypes=%@]",
            positions, deviceTypes);
    NSMutableArray *out = [NSMutableArray array];
    void *p = (__bridge void *)fromDevice;
    NSString *devID = (__bridge NSString *)(*(void **)((char *)p + kBWFigCaptureDevice_deviceID_Offset));
    NSUInteger count = positions.count;
    for (NSUInteger i = 0; i < count; i++) {
      NSString *uid = [NSString stringWithFormat:@"%@:stream:%lu",
                                                  devID, (unsigned long)i];
      id s = vcc_make_synth_stream(uid, devID, @"Back");
      if (s) [out addObject:s];
    }
    if (err) *err = 0;
    vcc_log(@"  [copyStreamsFromDevice] -> %lu streams",
            (unsigned long)out.count);
    return out;
  }
  VccCopyStreamsFromFn orig = (VccCopyStreamsFromFn)vcc_copy_streams_from_orig;
  return orig(self, _cmd, fromDevice, positions, deviceTypes,
              prio, allowsLoss, err);
}

static void vcc_install_copy_streams_from_hook(void) {
  Class cls = NSClassFromString(@"BWFigCaptureDeviceVendor");
  if (!cls) return;
  SEL sel = NSSelectorFromString(
      @"copyStreamsFromDevice:positions:deviceTypes:deviceClientPriority:allowsStreamControlLoss:error:");
  vcc_swizzle_method(cls, sel, (IMP)vcc_copy_streams_from_hook,
                     &vcc_copy_streams_from_orig);
}

__attribute__((ns_returns_retained))
static id vcc_make_synth_device(NSString *deviceID) {
  if (!vcc_synth_device_class) vcc_init_synth_device_class();
  if (!vcc_synth_device_class) return nil;

  // Use +alloc via runtime — ARC-safe. Function attributed
  // ns_returns_retained so ARC treats the alloc'd +1 correctly.
  id d = ((id (*)(Class, SEL))objc_msgSend)(vcc_synth_device_class,
                                              @selector(alloc));
  if (!d) {
    vcc_log(@"  synth-dev: class_createInstance failed");
    return nil;
  }
  // Write deviceID at the runtime-resolved ivar offset via
  // CFBridgingRetain so our -dealloc override CFRelease's it.
  NSString *idCopy = [deviceID copy];
  void *slotBase  = (__bridge void *)d;
  void **slot     = (void **)((char *)slotBase + kBWFigCaptureDevice_deviceID_Offset);
  *slot = (void *)CFBridgingRetain(idCopy);

  // Pin so dealloc never runs — diagnostic to isolate the autorelease
  // pool drain crash. Each session start leaks one synth device.
  static NSMutableArray *vcc_synth_devs_strong_refs = nil;
  if (!vcc_synth_devs_strong_refs) {
    vcc_synth_devs_strong_refs = [NSMutableArray new];
  }
  [vcc_synth_devs_strong_refs addObject:d];

  vcc_log(@"  synth-dev: %p deviceID=%@ (slot@+0x%lx=%p)",
          d, idCopy, (long)kBWFigCaptureDevice_deviceID_Offset, *slot);
  return d;
}

static void vcc_install_device_vendor_hook(void) {
  Class cls = NSClassFromString(@"BWFigCaptureDeviceVendor");
  if (!cls) {
    vcc_log(@"  device-vendor hook: class missing");
    return;
  }
  SEL sel = NSSelectorFromString(
      @"copyDeviceWithID:forClient:informClientWhenDeviceAvailableAgain:error:");
  vcc_swizzle_method(cls, sel, (IMP)vcc_copy_device_hook, &vcc_copy_device_orig);
}
