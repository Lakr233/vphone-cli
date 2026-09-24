// MARK: - synthetic FigCaptureDevice subclass
//
// Subclass `BWFigCaptureDevice` at runtime via objc_allocateClassPair, then
// instantiate via +alloc. We write the deviceID NSString directly into the
// inherited ivar slot. Ivar offsets are resolved at synth-class init time
// via the ObjC runtime (class_getInstanceVariable + ivar_getOffset) so
// the layout follows whatever Apple ships, not a hardcoded 26.5 value.
//
// To prevent the crash in
// `-[BWFigCaptureDevice _copyProperty:requireSupported:error:]` (where the
// inherited body would deref the NULL figCaptureDevice via
// CMBaseObjectGetVTable), we OVERRIDE the public ObjC wrappers
// (-copyProperty:error:, -getProperty:error:, -copyPropertyIfSupported:error:)
// in our subclass so they never call _copyProperty:. Each override returns
// canned values for known properties and sets *err=-12787 ("property not
// supported") for everything else.

// Resolved at synth-class init. -1 until populated; vcc_init_synth_device_class
// refuses to register the synth class if resolution fails so we never write
// to a stale offset.
static ptrdiff_t kBWFigCaptureDevice_deviceID_Offset = -1;

// Resolve an instance-variable offset by name on `cls`, trying each
// candidate in `names` (NULL-terminated) until one matches. Returns -1
// if none match. Logs the outcome so a future iOS rename surfaces in
// the install log instead of silently writing to a wrong slot.
static ptrdiff_t vcc_resolve_ivar(Class cls,
                                  const char *what,
                                  const char *const *names) {
  if (!cls) {
    vcc_log(@"  ivar %s: class missing", what ? what : "?");
    return -1;
  }
  for (unsigned i = 0; names[i]; i++) {
    Ivar iv = class_getInstanceVariable(cls, names[i]);
    if (iv) {
      ptrdiff_t off = ivar_getOffset(iv);
      vcc_log(@"  ivar %s -> %s @ +0x%lx", what ? what : "?",
              names[i], (long)off);
      return off;
    }
  }
  vcc_log(@"  ivar %s: no candidate matched on %s", what ? what : "?",
          class_getName(cls));
  return -1;
}

// Cached CF constant — resolved lazily from CMCaptureCore / CMCaptureDevice.
static CFStringRef vcc_cf_kClock = NULL;

static void vcc_load_synth_cfconsts(void) {
  if (!vcc_cf_kClock) vcc_cf_kClock = vcc_cfconst("kFigCaptureDeviceProperty_Clock");
}

// Returns a CMClockRef (CoreMedia host time clock). Lifetime tied to the
// process — we never release it.
static CFTypeRef vcc_get_host_clock(void) {
  static CFTypeRef cached = NULL;
  if (cached) return cached;
  typedef CFTypeRef (*GetHostClockFn)(void);
  GetHostClockFn fn = (GetHostClockFn)dlsym(RTLD_DEFAULT, "CMClockGetHostTimeClock");
  if (!fn) {
    vcc_log(@"  synth-dev: CMClockGetHostTimeClock missing");
    return NULL;
  }
  cached = fn();
  if (cached) CFRetain(cached);  // keep it alive
  return cached;
}

// copyProperty: follows the +1 "copy" convention — return must be retained.
__attribute__((ns_returns_retained))
static id vcc_synth_copy_property(id self, SEL _cmd, id property, int *err) {
  NSString *propStr = [property description];
  if (vcc_cf_kClock &&
      [(__bridge id)vcc_cf_kClock isEqual:property]) {
    CFTypeRef clk = vcc_get_host_clock();
    if (err) *err = clk ? 0 : -12787;
    vcc_log(@"  [SynthDev copyProperty:Clock] -> %p", clk);
    if (!clk) return nil;
    CFRetain(clk);
    return (__bridge_transfer id)clk;  // +1 retained, ns_returns_retained
  }
  if (err) *err = -12787;
  vcc_log(@"  [SynthDev copyProperty:%@] -> nil (err=-12787)", propStr);
  return nil;
}

__attribute__((ns_returns_retained))
static id vcc_synth_copy_property_if_supported(id self,
                                               SEL _cmd,
                                               id property,
                                               int *err) {
  NSString *propStr = [property description];
  if (err) *err = 0;
  vcc_log(@"  [SynthDev copyPropertyIfSupported:%@] -> nil", propStr);
  return nil;
}

static int vcc_synth_get_property(id self, SEL _cmd, id property, int *err) {
  NSString *propStr = [property description];
  if (err) *err = -12787;
  vcc_log(@"  [SynthDev getProperty:%@] -> 0 (err=-12787)", propStr);
  return 0;
}

static id vcc_synth_supported_properties(id self, SEL _cmd) {
  // BWFigVideoCaptureDevice expects an NSDictionary here — it queries the
  // returned object via -objectForKeyedSubscript: for property keys (e.g.
  // kFigCaptureDeviceProperty_SupportedSynchronizedStreamsGroups). Returning
  // an NSSet would crash on that selector.
  vcc_log(@"  [SynthDev supportedProperties] -> empty dict");
  return [NSDictionary dictionary];
}

static id vcc_synth_unique_id(id self, SEL _cmd) {
  void **slot = (void **)((char *)(__bridge void *)self
                          + kBWFigCaptureDevice_deviceID_Offset);
  id idVal = (__bridge id)(*slot);
  return idVal;
}

static void vcc_synth_dealloc(id self, SEL _cmd) {
  void **slot = (void **)((char *)(__bridge void *)self
                          + kBWFigCaptureDevice_deviceID_Offset);
  if (*slot) {
    CFRelease((CFTypeRef)*slot);
    *slot = NULL;
  }
  // Skip parent's -dealloc and finish destruction ourselves. ARC marks
  // objc_destructInstance as unavailable, so resolve via dlsym.
  static void *(*destruct)(id) = NULL;
  if (!destruct) destruct = dlsym(RTLD_DEFAULT, "objc_destructInstance");
  if (destruct) destruct(self);
  free((__bridge void *)self);
}

static void vcc_init_synth_device_class(void) {
  if (vcc_synth_device_class) return;
  Class parent = NSClassFromString(@"BWFigCaptureDevice");
  if (!parent) {
    vcc_log(@"  synth-dev: BWFigCaptureDevice class missing");
    return;
  }
  static const char *const kDeviceIDNames[] = {
      "_deviceID", "deviceID", NULL,
  };
  kBWFigCaptureDevice_deviceID_Offset = vcc_resolve_ivar(
      parent, "BWFigCaptureDevice.deviceID", kDeviceIDNames);
  if (kBWFigCaptureDevice_deviceID_Offset < 0) {
    vcc_log(@"  synth-dev: required ivar not found — registration aborted");
    return;
  }
  vcc_load_synth_cfconsts();

  Class cls = objc_allocateClassPair(parent, "VccSynthDevice", 0);
  if (!cls) {
    vcc_log(@"  synth-dev: objc_allocateClassPair failed");
    return;
  }

  class_addMethod(cls, @selector(copyProperty:error:),
                  (IMP)vcc_synth_copy_property, "@@:@^i");
  class_addMethod(cls, @selector(copyPropertyIfSupported:error:),
                  (IMP)vcc_synth_copy_property_if_supported, "@@:@^i");
  class_addMethod(cls, @selector(getProperty:error:),
                  (IMP)vcc_synth_get_property, "i@:@^i");
  class_addMethod(cls, @selector(supportedProperties),
                  (IMP)vcc_synth_supported_properties, "@@:");
  class_addMethod(cls, @selector(uniqueID),
                  (IMP)vcc_synth_unique_id, "@@:");
  class_addMethod(cls, NSSelectorFromString(@"dealloc"),
                  (IMP)vcc_synth_dealloc, "v@:");

  objc_registerClassPair(cls);
  vcc_synth_device_class = cls;
  vcc_log(@"  registered VccSynthDevice : BWFigCaptureDevice (cls=%p)", cls);
}
