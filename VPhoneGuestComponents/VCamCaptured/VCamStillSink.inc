// MARK: - Sink node injection — manually-constructed BWStillImageSampleBufferSinkNode
//
// The daemon's session graph for our synth source builds without a still-image
// pipeline → no BWStillImageSampleBufferSinkNode exists → capturePhoto can't
// find a sink to deliver to → -11803 "Cannot Record".
//
// Manually construct a BWStillImageSampleBufferSinkNode at install time.
// Observation pass: prove the class accepts initialization in our daemon
// context. Next iteration adds the wiring path so capturePhoto sees this
// sink and delivers our shm frame through it.

static id vcc_synth_still_sink = nil;

static void vcc_construct_still_sink(void) {
  Class cls = NSClassFromString(@"BWStillImageSampleBufferSinkNode");
  if (!cls) {
    vcc_log(@"  manual still-sink: class missing");
    return;
  }
  // Per ipsw symaddr the simpler init is -[BWStillImageSampleBufferSinkNode
  // initWithSinkID:] at static 0x1ae333e20. The full init takes inputMediaType
  // + sinkID. Try the simpler one first.
  SEL sinkIdInit = NSSelectorFromString(@"initWithSinkID:");
  id sinkID = @(0xCAFEBABEull);  // synthetic sinkID, unique to us
  id alloced = ((id (*)(Class, SEL))objc_msgSend)(cls, @selector(alloc));
  if (!alloced) {
    vcc_log(@"  manual still-sink: alloc returned nil");
    return;
  }
  if (![alloced respondsToSelector:sinkIdInit]) {
    vcc_log(@"  manual still-sink: doesn't respond to %@",
            NSStringFromSelector(sinkIdInit));
    // Don't init — leak the alloced bytes (cheaper than crashing)
    return;
  }
  @try {
    vcc_synth_still_sink =
        ((id (*)(id, SEL, id))objc_msgSend)(alloced, sinkIdInit, sinkID);
  } @catch (NSException *e) {
    vcc_log(@"  manual still-sink: init exception: %@", e);
    return;
  }
  vcc_log(@"  manual still-sink: created %p (class=%@)",
          vcc_synth_still_sink,
          NSStringFromClass([vcc_synth_still_sink class]));
  if (!vcc_synth_still_sink) return;

  // Probe properties to make sure we got a usable instance.
  @try {
    SEL hdlrGet = @selector(sampleBufferAvailableHandler);
    if ([vcc_synth_still_sink respondsToSelector:hdlrGet]) {
      id existing =
          ((id (*)(id, SEL))objc_msgSend)(vcc_synth_still_sink, hdlrGet);
      vcc_log(@"  manual still-sink: initial sampleBufferAvailableHandler=%p",
              existing);
    } else {
      vcc_log(@"  manual still-sink: no -sampleBufferAvailableHandler");
    }
  } @catch (NSException *e) {
    vcc_log(@"  manual still-sink: probe exception: %@", e);
  }

  // Synthesize a sampleBufferAvailableHandler block and set it on our sink.
  //
  // Per disasm of -[BWStillImageSampleBufferSinkNode renderSampleBuffer:forInput:]
  // at static 0x1ae577428, the block invoke at 0x1ae57758c-590 takes:
  //   x0 = block (auto)
  //   x1 = CMSampleBufferRef sampleBuffer
  //   x2 = BOOL flag (always 0 at this site)
  //   x3 = [x21 requestedSettings] (presumably the AVCapturePhotoSettings)
  //
  // We don't yet have a real XPC reply path; this handler is currently a
  // logging probe that lets us verify our manually-installed handler does
  // fire when we drive -renderSampleBuffer:forInput: ourselves.
  SEL setHandlerSel = @selector(setSampleBufferAvailableHandler:);
  if ([vcc_synth_still_sink respondsToSelector:setHandlerSel]) {
    void (^block)(CMSampleBufferRef, BOOL, id) =
        ^(CMSampleBufferRef sbuf, BOOL flag, id requestedSettings) {
      vcc_log(@"  [SyntheticHandler] sbuf=%p flag=%d settings=%@",
              sbuf, flag, requestedSettings);
      // Extract the image data and write to disk as proof of pipeline integrity.
      if (!sbuf) return;
      CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sbuf);
      if (!pb) {
        vcc_log(@"  [SyntheticHandler] no image buffer");
        return;
      }
      CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
      size_t w = CVPixelBufferGetWidth(pb);
      size_t h = CVPixelBufferGetHeight(pb);
      size_t bpr = CVPixelBufferGetBytesPerRow(pb);
      OSType fmt = CVPixelBufferGetPixelFormatType(pb);
      vcc_log(@"  [SyntheticHandler] pb=%p w=%zu h=%zu bpr=%zu fmt=0x%x",
              pb, w, h, bpr, (unsigned)fmt);
      // Write the raw BGRA bytes beside the shared camera frame for verification.
      const char *out_path = VPHONE_VCAM_SYNTH_PHOTO_PATH;
      uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(pb);
      if (base) {
        int fd = open(out_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
          for (size_t y = 0; y < h; y++) {
            (void)write(fd, base + y * bpr, w * 4);
          }
          close(fd);
          vcc_log(@"  [SyntheticHandler] wrote %s (%zu bytes)",
                  out_path, w * h * 4);
        } else {
          vcc_log(@"  [SyntheticHandler] open(%s) failed: %d", out_path, errno);
        }
      }
      CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    };
    @try {
      ((void (*)(id, SEL, id))objc_msgSend)(vcc_synth_still_sink,
                                              setHandlerSel, block);
      vcc_log(@"  manual still-sink: installed synthetic handler block");
    } @catch (NSException *e) {
      vcc_log(@"  manual still-sink: setHandler exception: %@", e);
    }
    // Verify the handler was stored
    @try {
      id stored = ((id (*)(id, SEL))objc_msgSend)(
          vcc_synth_still_sink, @selector(sampleBufferAvailableHandler));
      vcc_log(@"  manual still-sink: post-set sampleBufferAvailableHandler=%p",
              stored);
    } @catch (NSException *e) {
      vcc_log(@"  manual still-sink: getHandler exception: %@", e);
    }
  } else {
    vcc_log(@"  manual still-sink: doesn't respond to setSampleBufferAvailableHandler:");
  }
}

// Trigger-the-handler probe: call -renderSampleBuffer:forInput: on our
// synth sink directly with a synthetic CMSampleBuffer built from
// vcc_latest_frame. If our manually-installed handler fires, we have
// proven the synthetic-handler approach works at the API level.
static void vcc_drive_still_sink_once(void) {
  if (!vcc_synth_still_sink) return;
  CMSampleBufferRef sbuf = vcc_build_cmsb_from_shm();
  if (!sbuf) {
    vcc_log(@"  still-drive: no shm frame yet");
    return;
  }
  SEL renderSel = @selector(renderSampleBuffer:forInput:);
  if (![vcc_synth_still_sink respondsToSelector:renderSel]) {
    vcc_log(@"  still-drive: sink doesn't respond to renderSampleBuffer:forInput:");
    CFRelease(sbuf);
    return;
  }
  vcc_log(@"  still-drive: calling renderSampleBuffer: on sink %p with sbuf=%p",
          vcc_synth_still_sink, sbuf);
  @try {
    ((void (*)(id, SEL, CMSampleBufferRef, id))objc_msgSend)(
        vcc_synth_still_sink, renderSel, sbuf, nil);
    vcc_log(@"  still-drive: render call returned");
  } @catch (NSException *e) {
    vcc_log(@"  still-drive: render exception: %@", e);
  }
  CFRelease(sbuf);
}

// MARK: - FigCaptureSessionParsedConfiguration observation
//
// This is the daemon-side parser that converts the XPC session config into
// the structured configuration the graph builder uses. After init,
// _parsedStillImageSinkConfigurations is populated; if empty, no still
// pipeline will be built.

static IMP vcc_parsed_cfg_init_orig = NULL;
typedef id (*VccParsedCfgInitFn)(id self,
                                 SEL _cmd,
                                 id sessionCfg,
                                 BOOL clientSetsUserInitiated,
                                 id restrictions);

__attribute__((ns_returns_retained))
static id vcc_parsed_cfg_init_hook(id self,
                                   SEL _cmd,
                                   id sessionCfg,
                                   BOOL clientSetsUserInitiated,
                                   id restrictions) {
  VccParsedCfgInitFn orig = (VccParsedCfgInitFn)vcc_parsed_cfg_init_orig;
  id ret = orig(self, _cmd, sessionCfg, clientSetsUserInitiated, restrictions);
  if (ret) {
    id stillCfgs = nil;
    @try {
      stillCfgs = [ret valueForKey:@"parsedStillImageSinkConfigurations"];
    } @catch (NSException *e) {
      stillCfgs = nil;
    }
    id cameraCfgs = nil;
    @try {
      cameraCfgs = [ret valueForKey:@"parsedCameraSourceConfigurations"];
    } @catch (NSException *e) {
      cameraCfgs = nil;
    }
    vcc_log(@"  [ParsedCfg init] -> %p stillCfgs.count=%lu cameraCfgs.count=%lu",
            ret,
            (unsigned long)(stillCfgs && [stillCfgs respondsToSelector:@selector(count)]
                            ? [stillCfgs count] : 0),
            (unsigned long)(cameraCfgs && [cameraCfgs respondsToSelector:@selector(count)]
                            ? [cameraCfgs count] : 0));
    if (cameraCfgs && [cameraCfgs respondsToSelector:@selector(count)]
        && [cameraCfgs count] > 0) {
      vcc_log(@"  [ParsedCfg] cameraCfgs[0] class=%@",
              NSStringFromClass([[cameraCfgs firstObject] class]));
    }
    if (stillCfgs && [stillCfgs respondsToSelector:@selector(count)]
        && [stillCfgs count] > 0) {
      id stillCfg = [stillCfgs firstObject];
      vcc_log(@"  [ParsedCfg] stillCfgs[0] class=%@ desc=%@",
              NSStringFromClass([stillCfg class]), stillCfg);
      // Dump the still cfg's properties — what does it tell the graph builder?
      id connConfigs = nil, primaryConnConfig = nil, movieCfg = nil, pointCfg = nil;
      @try { connConfigs = [stillCfg valueForKey:@"stillImageConnectionConfigurations"]; } @catch (NSException *e) {}
      @try {
        primaryConnConfig = [stillCfg valueForKey:@"primaryStillImageConnectionConfiguration"];
      } @catch (NSException *e) {}
      @try { movieCfg = [stillCfg valueForKey:@"movieFileVideoConnectionConfiguration"]; } @catch (NSException *e) {}
      @try { pointCfg = [stillCfg valueForKey:@"pointCloudDataConnectionConfiguration"]; } @catch (NSException *e) {}
      vcc_log(@"  [ParsedCfg] stillCfgs[0].connCfgs=%@",
              connConfigs ?: @"(nil)");
      vcc_log(@"  [ParsedCfg] stillCfgs[0].primary=%@", primaryConnConfig ?: @"(nil)");
      // Also dump the camera source config to see what source it's bound to
      id cameraCfg = [cameraCfgs firstObject];
      id sourceID = nil, deviceType = nil, captureDeviceID = nil;
      @try { sourceID = [cameraCfg valueForKey:@"sourceID"]; } @catch (NSException *e) {}
      @try { deviceType = [cameraCfg valueForKey:@"sourceDeviceType"]; } @catch (NSException *e) {}
      @try { captureDeviceID = [cameraCfg valueForKey:@"captureDeviceID"]; } @catch (NSException *e) {}
      vcc_log(@"  [ParsedCfg] cameraCfg sourceID=%@ deviceType=%@ captureDeviceID=%@",
              sourceID ?: @"(nil)", deviceType ?: @"(nil)",
              captureDeviceID ?: @"(nil)");
    }
  }
  return ret;
}

static void vcc_install_parsed_cfg_observation(void) {
  Class cls = NSClassFromString(@"FigCaptureSessionParsedConfiguration");
  if (!cls) {
    vcc_log(@"  parsed-cfg obs: class missing");
    return;
  }
  SEL sel = NSSelectorFromString(
      @"initWithSessionConfiguration:clientSetsUserInitiatedCaptureRequestTime:restrictions:");
  vcc_swizzle_method(cls, sel, (IMP)vcc_parsed_cfg_init_hook,
                      &vcc_parsed_cfg_init_orig);
}
