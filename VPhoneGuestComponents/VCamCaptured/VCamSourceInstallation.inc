// MARK: - synthetic source construction

// Published as the synthetic source's CaptureDeviceID attribute, and matched
// against by the -[BWFigCaptureDeviceVendor copyDeviceWithID:…] hook. One
// declaration: the two must stay identical or the device lookup stops matching.
static NSString *const kVccSynthDeviceID = @"vphone:vcam:device:0";

static id vcc_build_backing(void) {
  Class backingClass = NSClassFromString(@"FigCaptureSourceBacking");
  if (!backingClass) {
    vcc_log(@"  FigCaptureSourceBacking class missing");
    return nil;
  }
  CFStringRef k_uid  = vcc_cfconst("kFigCaptureSourceAttributeKey_UniqueID");
  CFStringRef k_dt   = vcc_cfconst("kFigCaptureSourceAttributeKey_DeviceType");
  CFStringRef k_ln   = vcc_cfconst("kFigCaptureSourceAttributeKey_LocalizedName");
  CFStringRef k_mid  = vcc_cfconst("kFigCaptureSourceAttributeKey_ModelID");
  CFStringRef k_pos  = vcc_cfconst("kFigCaptureSourceAttributeKey_Position");
  CFStringRef k_st   = vcc_cfconst("kFigCaptureSourceAttributeKey_SourceType");
  CFStringRef k_cdid = vcc_cfconst("kFigCaptureSourceAttributeKey_CaptureDeviceID");
  if (!k_uid || !k_dt) {
    vcc_log(@"  required attr keys missing");
    return nil;
  }

  NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
  attrs[(__bridge NSString *)k_uid] = @"vphone:vcam:0";
  // DeviceType: empirical sweep
  //   - 1 (BuiltInWideAngleCamera): Camera.app routes to the real ISP /
  //     hardware path and fails immediately because no hardware backs
  //     us — viewfinder stream pool isn't even spun up.
  //   - 2: Camera.app's Photo/Video tabs use the generic / soft path
  //     and at least start the FigCameraViewfinderStream init pool
  //     (~2000/sec) before stalling at openWithDestination:. This is
  //     where we have a chance to inject a destination.
  // Keep 2 until the inject-destination shape is figured out.
  attrs[(__bridge NSString *)k_dt]  = @(2);
  if (k_ln)  attrs[(__bridge NSString *)k_ln]  = @"vphone Virtual Camera";
  if (k_mid) attrs[(__bridge NSString *)k_mid] = @"vphone-vcam-1";
  if (k_pos) attrs[(__bridge NSString *)k_pos] = @(1);
  // sourceType MUST be 1 (video) for the daemon's media-type filter to
  // include this source in a vide-typed FigCaptureSourceRemoteCopyCaptureSources
  // request. Without it, attrs[SourceType] = nil → intValue = 0 → fails
  // the tbnz w8 gate in handleCopySourcesMessage.
  if (k_st)  attrs[(__bridge NSString *)k_st]  = @(1);
  // captureSession_buildGraphWithConfiguration (CMCapture vmaddr 0x1ae2b1910)
  // iterates the source list and calls
  // _FigCaptureSourceGetAttribute(source, kFigCaptureSourceAttributeKey_CaptureDeviceID)
  // then -[NSMutableArray addObject:] with the result. If the key is missing
  // the call returns nil and the array throws NSInvalidArgumentException
  // ("object cannot be nil") inside -[__NSArrayM insertObject:atIndex:] —
  // which kills cameracaptured as soon as any AVCaptureSession references
  // our synth.
  //
  // The value must be a string, NOT a number. -[BWFigCaptureDeviceVendor
  // _createDevice:reason:clientPID:figCaptureDevice:] sends isEqualToString:
  // to it; an NSNumber raises "unrecognized selector". Use a unique opaque
  // string outside whatever pattern Apple uses for hardware cameras.
  if (k_cdid) attrs[(__bridge NSString *)k_cdid] = kVccSynthDeviceID;

  // After hooking _FigCaptureSourceGetAttribute via lldb we observed
  // Camera.app's graph builder also queries these 5 boolean / scheme keys
  // against our synth. Provide explicit values so the builder doesn't bail
  // on a nil capability check. Verified order observed via lldb:
  //   SmartCameraSupported, StillImageNoiseReductionAndFusionScheme,
  //   MidFrameSynchronizationNotSupported, TimeOfFlightAssistedAutoFocusSupported,
  //   StructuredLightAssistedAutoFocusSupported
  // Resolve the canonical CFString constant by symbol name when possible (some
  // are defined in a private framework not in the dyld exports trie, so we fall
  // back to the plain string after the Fig naming convention:
  // kFigSupportedFormat_VideoMinFrameRate → "VideoMinFrameRate").
  NSString *(^figKeyN)(const char *) = ^NSString *(const char *symname) {
    void **slot = dlsym(RTLD_DEFAULT, symname);
    if (slot && *slot) return (__bridge NSString *)(CFStringRef)(*slot);
    const char *cs = symname;
    const char *u = strrchr(cs, '_');
    if (u) cs = u + 1;
    return [NSString stringWithUTF8String:cs];
  };
  attrs[figKeyN("kFigCaptureSourceAttributeKey_SmartCameraSupported")] = @NO;
  attrs[figKeyN("kFigCaptureSourceAttributeKey_StillImageNoiseReductionAndFusionScheme")] = @(0);
  attrs[figKeyN("kFigCaptureSourceAttributeKey_MidFrameSynchronizationNotSupported")] = @NO;
  attrs[figKeyN("kFigCaptureSourceAttributeKey_TimeOfFlightAssistedAutoFocusSupported")] = @NO;
  attrs[figKeyN("kFigCaptureSourceAttributeKey_StructuredLightAssistedAutoFocusSupported")] = @NO;

  // Construct a FigCaptureSourceVideoFormat via its private init taking a
  // stream format dictionary. Required keys recovered by reversing
  // `-[FigCaptureSourceFormat formatDescription]` + `-format` + `-dimensions`:
  //   "Name"            (NSString)  -- required by base init's cbz guard
  //   "Width"           (NSNumber)  -- becomes dimensions.width
  //   "Height"          (NSNumber)  -- becomes dimensions.height
  //   "PixelFormatType" (NSNumber)  -- 4cc fed to CMVideoFormatDescriptionCreate
  // All other keys read by the subclass init fall through to default
  // (0/nil) values via objectForKeyedSubscript: chains.
  NSArray *formats = @[];
  Class fmtClass = NSClassFromString(@"FigCaptureSourceVideoFormat");
  if (fmtClass) {
    // Publish TWO formats: one BGRA, one 420v at the same 1280x720
    // dimensions. Clients that filter on BGRA (e.g. Loupe / Magnifier)
    // see one; clients that pick the canonical ISP pixel format (AVF's
    // _preferredFormatForPreset: matcher for AVCaptureSessionPresetHigh)
    // pick the 420v one. Same preset list + frame-rate range on both.
    NSDictionary *commonKeys = @{
      @"DefaultActiveFormat" : @NO,  // overridden on the active one
      figKeyN("kFigSupportedFormat_VideoMinFrameRate") : @(1),
      figKeyN("kFigSupportedFormat_VideoMaxFrameRate") : @(60),
      // -[FigCaptureSourceVideoFormat maxZoomFactor] takes a fast path that
      // returns 1.0 for raw bayer formats; for BGRA (our case) it falls to
      // a fancy path that reads stabilizationTypeOverrideForCinematic / -ForStandard
      // and consults a dimension-table when either equals 3. Setting this
      // key to 3 makes the table apply (returns 16.0 for 1280-wide formats),
      // which keeps -[AVCaptureFigVideoDevice setVideoZoomFactor:] from
      // throwing "out-of-range [1, activeFormat.videoMaxZoomFactor]" when
      // Camera.app sets a default zoom > 1.0.
      @"VideoStabilizationTypeOverrideForStandard" : @(3),
      // Without AVCaptureSessionPresets, -[AVCaptureDevice
      // supportsAVCaptureSessionPreset:] returns NO for every preset
      // (canAddInput=False everywhere except InputPriority). Camera.app
      // uses High/Photo — list them all so common AVF clients pass.
      @"AVCaptureSessionPresets" : @[
        @"AVCaptureSessionPresetHigh",
        @"AVCaptureSessionPreset1280x720",
        @"AVCaptureSessionPreset640x480",
        @"AVCaptureSessionPresetMedium",
        @"AVCaptureSessionPresetLow",
        @"AVCaptureSessionPresetPhoto",
        @"AVCaptureSessionPreset352x288",
      ],
    };
    NSMutableDictionary *bgra_fmt = [@{
      @"Name"            : @"vphone-vcam-720p-bgra",
      @"Width"           : @1280,
      @"Height"          : @720,
      @"PixelFormatType" : @(0x42475241u),  // 'BGRA'
    } mutableCopy];
    [bgra_fmt addEntriesFromDictionary:commonKeys];

    NSMutableDictionary *y420v_fmt = [@{
      @"Name"            : @"vphone-vcam-720p-420v",
      @"Width"           : @1280,
      @"Height"          : @720,
      @"PixelFormatType" : @(0x34323076u),  // '420v'
    } mutableCopy];
    [y420v_fmt addEntriesFromDictionary:commonKeys];
    // Mark 420v as default — it's what AVF's preset matcher prefers when
    // picking _setActiveFormat: under standard presets.
    y420v_fmt[@"DefaultActiveFormat"] = @YES;

    SEL fmtInitSel = NSSelectorFromString(
        @"initWithFigCaptureStreamFormatDictionary:");
    NSMutableArray *formatObjs = [NSMutableArray array];
    for (NSDictionary *fmtDict in @[ bgra_fmt, y420v_fmt ]) {
      id fmtAlloc = ((id (*)(Class, SEL))objc_msgSend)(fmtClass,
                                                         @selector(alloc));
      id fmtObj = nil;
      if (fmtAlloc) {
        fmtObj = ((id (*)(id, SEL, id))objc_msgSend)(
            fmtAlloc,
            fmtInitSel,
            fmtDict);
      }
      vcc_log(@"  FigCaptureSourceVideoFormat (%@) = %p",
              fmtDict[@"Name"],
              fmtObj);
      if (fmtObj) [formatObjs addObject:fmtObj];
    }
    formats = formatObjs;
  } else {
    vcc_log(@"  FigCaptureSourceVideoFormat class missing");
  }

  SEL initSel = NSSelectorFromString(
      @"initWithMediaType:attributes:cachedProperties:formats:"
      @"missingFormatNames:synchronizedStreamUniqueIDs:"
      @"unsynchronizedStreamUniqueIDs:");
  id alloced = ((id (*)(Class, SEL))objc_msgSend)(backingClass,
                                                    @selector(alloc));
  if (!alloced) return nil;
  uint32_t mediaTypeVideo = 0x76696465;  // 'vide'
  id backing = ((id (*)(id, SEL, uint32_t, id, id, id, id, id, id))objc_msgSend)(
      alloced,
      initSel,
      mediaTypeVideo,
      attrs,
      [NSMutableDictionary dictionary],
      formats,
      @[],
      @[],
      @[]);
  vcc_log(@"  backing = %p (attrs.count=%lu formats.count=%lu)",
          backing,
          (unsigned long)attrs.count,
          (unsigned long)formats.count);
  return backing;
}

// FigCaptureSourceCreateFromBacking signature (5 args):
//   (CFAllocatorRef allocator, FigCaptureSourceBacking *backing,
//    audit_token_t *token, int unused_x3, FigCaptureSource **outSource)
typedef int (*VCC_CreateFn)(CFAllocatorRef, id, void *, int, void **);

static void *vcc_create_synthetic_source(VCC_CreateFn create_fn, id backing) {
  audit_token_t self_token;
  mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
  kern_return_t kr = task_info(mach_task_self(), TASK_AUDIT_TOKEN,
                               (task_info_t)&self_token, &count);
  if (kr != KERN_SUCCESS) {
    vcc_log(@"  task_info(TASK_AUDIT_TOKEN) failed: %d", kr);
    return NULL;
  }

  void *outSource = NULL;
  int ret = create_fn(kCFAllocatorDefault, backing, &self_token, 0, &outSource);
  vcc_log(@"  CreateFromBacking ret=0x%x outSource=%p", (unsigned)ret,
          outSource);
  return outSource;
}

// Walk the synthetic's PAC-signed vtable to call CopyProperty (vtable[6]) for
// confirmation of the contract methods. This is purely diagnostic; uses only
// dlsym-resolvable anchors (CMBaseObjectGetVTable) and standard PAC builtins.
static void vcc_probe_contract(void *source) {
  void *(*CMBaseObjectGetVTable)(void *) =
      (void *(*)(void *))vcc_dlsym_fn("CMBaseObjectGetVTable");
  if (!CMBaseObjectGetVTable) return;
  void *V = CMBaseObjectGetVTable(source);
  vcc_log(@"  CMBaseObjectGetVTable(synth) = %p", V);
  if (!V) return;

  // Auth the vtable pointer (data key A, address-blended discriminator).
  void **vtable_slot = (void **)((char *)V + 8);
  void *real_vtable_signed = *vtable_slot;
  uintptr_t vt_disc =
      __builtin_ptrauth_blend_discriminator(vtable_slot, 47377);
  void *real_vtable = __builtin_ptrauth_auth(real_vtable_signed,
                                              ptrauth_key_asda, vt_disc);
  vcc_log(@"  real_vtable @ %p", real_vtable);

  // Auth method6 (instruction key A) then resign for the C ABI call.
  void **method6_slot = (void **)((char *)real_vtable + 48);
  void *method6_signed = *method6_slot;
  uintptr_t m6_disc =
      __builtin_ptrauth_blend_discriminator(method6_slot, 38693);
  void *method6 = __builtin_ptrauth_auth_and_resign(
      method6_signed, ptrauth_key_asia, m6_disc,
      ptrauth_key_function_pointer, 0);
  vcc_log(@"  CopyProperty (vtable[6]) @ %p", method6);

  typedef int (*VCC_CopyPropFn)(void *src, CFStringRef key,
                                 CFAllocatorRef alloc, CFTypeRef *out);
  VCC_CopyPropFn copyProp = (VCC_CopyPropFn)method6;

  CFStringRef k_attrs = vcc_cfconst(
      "kFigCaptureSourceProperty_AttributesDictionary");
  CFStringRef k_fmts  = vcc_cfconst("kFigCaptureSourceProperty_Formats");

  CFTypeRef outAttrs = NULL;
  int e1 = copyProp(source, k_attrs, kCFAllocatorDefault, &outAttrs);
  vcc_log(@"  CopyProperty(AttributesDictionary) ret=%d out=%p (%@)",
          e1, outAttrs, outAttrs);
  if (outAttrs) CFRelease(outAttrs);

  CFTypeRef outFmts = NULL;
  int e2 = copyProp(source, k_fmts, kCFAllocatorDefault, &outFmts);
  vcc_log(@"  CopyProperty(Formats) ret=%d out=%p (count=%ld)",
          e2, outFmts,
          outFmts && CFGetTypeID(outFmts) == CFArrayGetTypeID()
              ? CFArrayGetCount(outFmts) : -1);
  if (outFmts) CFRelease(outFmts);
}

// MARK: - _sSourceList manipulation

static void vcc_install_synthetic(void) {
  vcc_image_t img;
  int rc = vcc_image_resolve(&img, "FigCaptureSourceServerStart");
  if (rc != 0) {
    vcc_log(@"  image resolve failed rc=%d", rc);
    return;
  }
  vcc_log(@"  CMCapture mh=%p slide=0x%lx text=%p words=%zu nsyms=%u",
          img.mh, (unsigned long)img.slide, img.text, img.text_words,
          img.nsyms);

  // DSC strips per-image LC_SYMTAB names to "<redacted>" — symtab walking
  // by name doesn't work. Recover the two private function addresses via
  // a structural pattern scan of __text for the daemon's filter chain.
  uintptr_t si_fn_addr = 0, prewarm_fn_addr = 0;
  uintptr_t hit_pc =
      vcc_find_filter_chain(&img, &si_fn_addr, &prewarm_fn_addr);
  vcc_log(@"  filter-chain scan: pc=0x%lx si_fn=0x%lx prewarm_fn=0x%lx",
          (unsigned long)hit_pc, (unsigned long)si_fn_addr,
          (unsigned long)prewarm_fn_addr);

  // Patch the per-source ownership/prewarming filter that runs inside the
  // iteration loop of handleCopySourcesMessage. Without these patches,
  // every source is rejected unless its ClientBundleIdentifier property
  // matches the requesting client's signing-id AND PrewarmingEnabled is
  // YES — which is never true for our synthetic source nor for the daemon
  // bring-up source against a non-Camera.app client.
  uintptr_t per_source_pc = vcc_find_per_source_filter(&img);
  if (per_source_pc) {
    int ok = vcc_patch_two_nops(per_source_pc);
    vcc_log(@"  per-source NOP patch %s @ 0x%lx",
            ok ? "OK" : "FAILED", (unsigned long)per_source_pc);
  } else {
    vcc_log(@"  per-source filter not located — daemon will skip our source");
  }

  if (prewarm_fn_addr) {
    typedef CFTypeRef (*PrewarmFn)(void);
    PrewarmFn pf = (PrewarmFn)ptrauth_sign_unauthenticated(
        (void *)prewarm_fn_addr, ptrauth_key_function_pointer, 0);
    CFTypeRef setv = pf();
    vcc_log(@"  prewarming allowlist set = %p (%@)",
            setv, (__bridge id)setv);

    // Patch the daemon's prewarming-bundle allowlist so EVERY XPC client
    // passes the `[set containsObject:clientSI]` gate in
    // _captureSourceServer_handleCopySourcesMessage. We don't mutate the
    // set's contents — we object_setClass it to a dynamically-built
    // subclass whose -containsObject: implementation always returns YES.
    // This is __DATA-clean (no __TEXT writes, no TXM concerns) and
    // limited to this single singleton instance.
    if (setv) {
      id theSet = (__bridge id)setv;
      Class origCls = object_getClass(theSet);
      Class allowCls = objc_allocateClassPair(
          origCls, "vcc_AlwaysAllowSet", 0);
      if (allowCls) {
        IMP yesImp = imp_implementationWithBlock(
            ^BOOL(__unused id self_, __unused id obj) { return YES; });
        Method orig = class_getInstanceMethod(origCls,
                                              @selector(containsObject:));
        const char *types = orig ? method_getTypeEncoding(orig) : "B@:@";
        class_addMethod(allowCls, @selector(containsObject:), yesImp, types);
        objc_registerClassPair(allowCls);
        object_setClass(theSet, allowCls);
        vcc_log(@"  swizzled set's class -> vcc_AlwaysAllowSet (orig=%s)",
                class_getName(origCls));
      } else {
        vcc_log(@"  objc_allocateClassPair returned nil (already registered?)");
      }
    }
  }


  // Force daemon's source-server init so `_sSourceList` is allocated.
  void *start_fn = vcc_dlsym_fn("FigCaptureSourceServerStart");
  if (start_fn) {
    ((void (*)(void))start_fn)();
    vcc_log(@"  called FigCaptureSourceServerStart()");
  }

  // Resolve _sSourceList structurally:
  //
  //   LC_SYMTAB → __captureSourceServer_initializeStatics_block_invoke
  //     (the dispatch_once init body — static text symbol, retained
  //      in the on-device DSC nlist even when static *data* symbols
  //      like `_sSourceList` itself are stripped)
  //     → BL CFArrayCreateMutable inside the block body
  //     → adrp+str x0, [Xn, #imm]  ← stores into _sSourceList
  //
  // Every link is a structural ARM64 pattern, so the chain is stable
  // across iOS revisions. The static-init function naming convention
  // (`<class>_initializeStatics_block_invoke`) has been used by Apple
  // since the iOS 14 era and persists through 26.x.
  uintptr_t fnCFArrayCreate = (uintptr_t)dlsym(RTLD_DEFAULT,
                                                "CFArrayCreateMutable");
  // The on-device nlist exports static text symbols with leading
  // underscores. Block-invoke names take one extra underscore vs the
  // outer C symbol — try the canonical first, plus a triple-_ variant
  // some clangs emit.
  static const char *kInitBlockNames[] = {
      "__captureSourceServer_initializeStatics_block_invoke",
      "___captureSourceServer_initializeStatics_block_invoke",
      NULL,
  };
  uintptr_t blockInvoke = 0;
  for (unsigned i = 0; kInitBlockNames[i]; i++) {
    blockInvoke = vcc_lookup_lc_symtab(&img, kInitBlockNames[i]);
    if (blockInvoke) {
      vcc_log(@"  init-statics block-invoke (%s) @ 0x%lx",
              kInitBlockNames[i], (unsigned long)blockInvoke);
      break;
    }
  }
  // If the symbol is stripped on-device (typical for the DSC), walk
  // the structural chain rooted at FigCaptureSourceServerStart to
  // find the dispatch_once block-invoke. The chain is:
  //
  //   FigCaptureSourceServerStart  (exported, addr known)
  //     `cmn x?, #0x1 ; b.ne <wrapper>`     (onceToken check)
  //   wrapper                       (`.cold.1`, static; addr from b.ne)
  //     `bl <cold.1>`               (we land here from b.ne; target IS cold.1)
  //   cold.1                        (5–6 instructions, static)
  //     `adrp x0,...; add x0, x0, ...`  (onceToken pointer)
  //     `adrp x1,...; add x1, x1, ...`  (block-constant pointer)
  //     `bl <dispatch_once stub>`
  //   block constant                (struct __Block_literal in __DATA_CONST)
  //     +0x10 = invoke pointer (PAC-signed; raw bytes are the function
  //                             address before signature stripping)
  if (!blockInvoke) {
    uintptr_t fnFigStart = (uintptr_t)dlsym(RTLD_DEFAULT,
                                            "FigCaptureSourceServerStart");
    if (fnFigStart) {
      fnFigStart = (uintptr_t)ptrauth_strip((void *)fnFigStart,
                                             ptrauth_key_function_pointer);
      uint32_t *ip = (uint32_t *)fnFigStart;
      uintptr_t coldWrapper = 0;
      // Step 1: find `cmn x?, #0x1; b.ne <target>` and decode target.
      // CMN (immediate) 64-bit, no shift:
      //   1011 0001 00ii iiii iiii iinn nnn1 1111
      // mask 0xFFC0001F, match 0xB100001F.
      // B.NE: 0101 0100 iiii iiii iiii iiii iii0 0001
      //   mask 0xFF00001F, match 0x54000001.
      for (unsigned i = 0; i < 256 && !coldWrapper; i++) {
        uint32_t cmn = ip[i];
        if ((cmn & 0xFFC0001Fu) != 0xB100001Fu) continue;
        // imm12 in bits[21:10]
        uint32_t imm = (cmn >> 10) & 0xFFFu;
        if (imm != 1) continue;
        if (i + 1 >= 256) continue;
        uint32_t bne = ip[i + 1];
        if ((bne & 0xFF00001Fu) != 0x54000001u) continue;
        int32_t imm19 = (int32_t)((bne & 0x00FFFFE0u) << 8) >> 11;
        coldWrapper = (uintptr_t)&ip[i + 1] + (intptr_t)imm19;
      }
      if (!coldWrapper) {
        vcc_log(@"  cmn+b.ne onceToken-check pattern not found in "
                @"FigCaptureSourceServerStart");
      } else {
        vcc_log(@"  cold-wrapper site @ 0x%lx", (unsigned long)coldWrapper);
        // Step 2: cold wrapper starts with `bl <cold.1>`. Decode.
        uint32_t bl = *(uint32_t *)coldWrapper;
        uintptr_t cold1 = 0;
        if ((bl & 0xFC000000u) == 0x94000000u) {
          int32_t imm26 = (int32_t)((bl & 0x03FFFFFFu) << 6) >> 4;
          cold1 = coldWrapper + (intptr_t)imm26;
          vcc_log(@"  cold.1 @ 0x%lx", (unsigned long)cold1);
        }
        // Step 3: walk cold.1 looking for the LAST `adrp x1,...; add x1,
        // x1, #imm` pair BEFORE the dispatch_once `bl`. That's the block
        // constant. cold.1 is typically only 5–6 instructions long.
        if (cold1) {
          uint32_t *cip = (uint32_t *)cold1;
          uintptr_t blockConst = 0;
          for (unsigned i = 0; i < 16; i++) {
            uint32_t add = cip[i];
            if ((add & 0xFF800000u) != 0x91000000u) continue;
            if ((add & 0x1Fu) != 1) continue;        // ADD x1, ...
            if (((add >> 5) & 0x1Fu) != 1) continue;
            uint32_t add_imm = (add >> 10) & 0xFFFu;
            // Walk back for matching adrp x1
            for (unsigned k = 1; k <= 4 && k <= i; k++) {
              uint32_t adrp = cip[i - k];
              if ((adrp & 0x9F000000u) != 0x90000000u) continue;
              if ((adrp & 0x1Fu) != 1) continue;
              uintptr_t adrp_pc = (uintptr_t)&cip[i - k];
              blockConst = vcc_adrp_target(adrp_pc, adrp) + add_imm;
              break;
            }
            if (blockConst) break;
          }
          if (!blockConst) {
            vcc_log(@"  block-constant adrp+add not found in cold.1");
          } else {
            vcc_log(@"  block constant @ 0x%lx", (unsigned long)blockConst);
            // Step 4: read invoke pointer at offset 0x10 within the
            // block constant. PAC-strip and assign as block-invoke.
            uintptr_t rawInvoke = *(uintptr_t *)(blockConst + 0x10);
            blockInvoke = (uintptr_t)ptrauth_strip(
                (void *)rawInvoke, ptrauth_key_function_pointer);
            vcc_log(@"  init block-invoke (via cold.1 chain) @ 0x%lx",
                    (unsigned long)blockInvoke);
          }
        }
      }
    }
  }
  uintptr_t sSourceListAddr = 0;
  if (blockInvoke) {
    uintptr_t globals[8] = {0};
    unsigned ng = vcc_collect_call_then_store_globals(blockInvoke,
                                                       /*maxInsns*/512,
                                                       /*lookahead*/12,
                                                       globals, 8);
    for (unsigned i = 0; i < ng; i++) {
      vcc_log(@"  init-statics global #%u: 0x%lx",
              i, (unsigned long)globals[i]);
    }
    // The init block initializes both `_sSourceListLock` (lock
    // handle) and `_sSourceList` (CFArray) in order. Walk the
    // discovered globals and pick the first one whose slot value
    // is actually a CFArray — that's the source list. The lock
    // entry has a void* mutex handle which malloc_zone validates
    // but isa fails the CFArray-class check.
    uintptr_t symLookup = vcc_lookup_lc_symtab(&img, "_sSourceList");
    if (symLookup) {
      vcc_log(@"  _sSourceList also in LC_SYMTAB at 0x%lx — using",
              (unsigned long)symLookup);
      sSourceListAddr = symLookup;
    } else {
      for (unsigned i = 0; i < ng; i++) {
        if (vcc_slot_value_is_cfarray(globals[i])) {
          uintptr_t val = 0;
          if (globals[i]) val = *(uintptr_t *)globals[i];
          vcc_log(@"  _sSourceList chosen (init-store #%u, CFArray @ 0x%lx) at 0x%lx",
                  i, (unsigned long)val, (unsigned long)globals[i]);
          sSourceListAddr = globals[i];
          break;
        }
      }
      if (!sSourceListAddr) {
        vcc_log(@"  no init-store global slot held a CFArray; falling "
                @"back to first init-store");
        if (ng > 0) sSourceListAddr = globals[0];
      }
    }
  } else {
    vcc_log(@"  init-statics block-invoke lookup failed");
  }
  if (!sSourceListAddr) {
    vcc_log(@"  data global resolve failed: _sSourceList not located");
    return;
  }

  // For the lock, the call-anchor approach requires knowing which
  // mutex-create function the daemon uses (FigSimpleMutexCreate / Init
  // / etc. — name varies across iOS). Skip locking entirely: our
  // dispatch_after fires after FigCaptureSourceServerStart's
  // dispatch_once block has finished, and we're the only writer to
  // _sSourceList during this init window.
  CFMutableArrayRef *sSourceListSlot =
      (CFMutableArrayRef *)sSourceListAddr;
  vcc_log(@"  lock acquisition skipped (single-threaded init window)");
  vcc_log(@"  _sSourceList slot @ %p (list=%p)", sSourceListSlot,
          *sSourceListSlot);

  // Resolve FigCaptureSourceCreateFromBacking. Marked `external` in
  // CMCapture's symtab — should be in the dyld exports trie.
  void *create_p = vcc_dlsym_fn("FigCaptureSourceCreateFromBacking");
  if (!create_p) {
    vcc_log(@"  abort: FigCaptureSourceCreateFromBacking not dlsym-resolvable");
    return;
  }
  VCC_CreateFn create_fn = (VCC_CreateFn)create_p;

  id backing = vcc_build_backing();
  if (!backing) return;
  void *source = vcc_create_synthetic_source(create_fn, backing);
  if (!source) {
    vcc_log(@"  create returned NULL — abort");
    return;
  }

  vcc_probe_contract(source);

  // Dump ALL existing sources' AttributesDictionary so we can mirror what
  // the daemon's stock (bring-up / hardware) sources use for keys like
  // DeviceType, SmartCameraSupported, Streams, Ports, etc.
  {
    CFMutableArrayRef listSnap = *sSourceListSlot;
    CFIndex cnt = listSnap ? CFArrayGetCount(listSnap) : 0;
    vcc_log(@"  --- existing sources (count=%ld) ---", (long)cnt);
    void *(*CMBaseObjectGetVTable)(void *) =
        (void *(*)(void *))vcc_dlsym_fn("CMBaseObjectGetVTable");
    for (CFIndex i = 0; i < cnt; i++) {
      void *s = (void *)CFArrayGetValueAtIndex(listSnap, i);
      vcc_log(@"    source[%ld] = %p", (long)i, s);
      if (!CMBaseObjectGetVTable) continue;
      void *V = CMBaseObjectGetVTable(s);
      if (!V) continue;
      void **vtable_slot = (void **)((char *)V + 8);
      void *real_vtable_signed = *vtable_slot;
      uintptr_t vt_disc =
          __builtin_ptrauth_blend_discriminator(vtable_slot, 47377);
      void *real_vtable = __builtin_ptrauth_auth(real_vtable_signed,
                                                  ptrauth_key_asda, vt_disc);
      if (!real_vtable) continue;
      void **method6_slot = (void **)((char *)real_vtable + 48);
      void *method6_signed = *method6_slot;
      uintptr_t m6_disc =
          __builtin_ptrauth_blend_discriminator(method6_slot, 38693);
      void *method6 = __builtin_ptrauth_auth_and_resign(
          method6_signed, ptrauth_key_asia, m6_disc,
          ptrauth_key_function_pointer, 0);
      typedef int (*CP)(void *, CFStringRef, CFAllocatorRef, CFTypeRef *);
      CP copyProp = (CP)method6;
      CFStringRef k_attrs = vcc_cfconst(
          "kFigCaptureSourceProperty_AttributesDictionary");
      CFTypeRef out = NULL;
      int e = copyProp(s, k_attrs, kCFAllocatorDefault, &out);
      vcc_log(@"      attrs ret=%d -> %@", e, (__bridge id)out);
      if (out) CFRelease(out);
    }
  }

  CFMutableArrayRef list = *sSourceListSlot;
  if (!list) {
    vcc_log(@"  _sSourceList is NULL (server init not yet allocated it) — abort");
    return;
  }
  CFIndex preCount = CFArrayGetCount(list);
  CFArrayAppendValue(list, source);
  CFIndex postCount = CFArrayGetCount(list);
  vcc_log(@"  appended source — list %ld -> %ld", (long)preCount,
          (long)postCount);

  CFStringRef notifNameCF = vcc_cfconst(
      "kFigCaptureSourceNotification_SourceInfoArrayChanged");
  if (notifNameCF) {
    char buf[256];
    if (CFStringGetCString(notifNameCF, buf, sizeof(buf),
                           kCFStringEncodingUTF8)) {
      uint32_t status = notify_post(buf);
      vcc_log(@"  notify_post(%s) -> %u", buf, status);
    } else {
      vcc_log(@"  CFStringGetCString failed for notif name");
    }
  } else {
    vcc_log(@"  notif name CFString constant missing");
  }
}
