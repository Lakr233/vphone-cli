// MARK: - BWStillImageSampleBufferSinkNode observation + injection
//
// AVCapturePhotoOutput attaches a sampleBufferAvailableHandler block to the
// still-image sink node; the upstream graph normally drives the node by
// calling -renderSampleBuffer:forInput:, which routes the buffer through
// the node's internal logic and ultimately invokes the handler. Our synth
// has no upstream graph that produces frames, so the handler never fires.
//
// First pass: observe. Hook -setSampleBufferAvailableHandler: and
// -initWithInputMediaType:sinkID: to capture the node + the handler
// block per session, so we can later push a CMSampleBuffer ourselves.

static NSMutableArray *vcc_still_sinks = nil;   // strong refs to nodes
static IMP vcc_still_set_handler_orig = NULL;
static IMP vcc_still_init_orig        = NULL;
static IMP vcc_still_render_orig      = NULL;

typedef id  (*VccStillInitFn)(id self, SEL _cmd, id mediaType, id sinkID);
typedef void (*VccStillSetHandlerFn)(id self, SEL _cmd, id handler);
typedef void (*VccStillRenderFn)(id self, SEL _cmd, CMSampleBufferRef sb, id input);

static id vcc_still_init_hook(id self, SEL _cmd, id mediaType, id sinkID) {
  VccStillInitFn orig = (VccStillInitFn)vcc_still_init_orig;
  id ret = orig(self, _cmd, mediaType, sinkID);
  vcc_log(@"  [StillSink init] self=%p mediaType=%@ sinkID=%@",
          ret, mediaType, sinkID);
  if (ret) {
    if (!vcc_still_sinks) vcc_still_sinks = [NSMutableArray new];
    [vcc_still_sinks addObject:ret];
  }
  return ret;
}

static void vcc_still_set_handler_hook(id self, SEL _cmd, id handler) {
  vcc_log(@"  [StillSink setSampleBufferAvailableHandler:] self=%p handler=%p",
          self, handler);
  VccStillSetHandlerFn orig = (VccStillSetHandlerFn)vcc_still_set_handler_orig;
  orig(self, _cmd, handler);
}

static void vcc_still_render_hook(id self,
                                  SEL _cmd,
                                  CMSampleBufferRef sb,
                                  id input) {
  vcc_log(@"  [StillSink renderSampleBuffer:forInput:] self=%p sb=%p input=%@",
          self, sb, input);
  VccStillRenderFn orig = (VccStillRenderFn)vcc_still_render_orig;
  orig(self, _cmd, sb, input);
}

static void vcc_install_still_sink_observation(void) {
  Class cls = NSClassFromString(@"BWStillImageSampleBufferSinkNode");
  if (!cls) {
    vcc_log(@"  still-sink obs: class missing");
    return;
  }
  SEL initSel = NSSelectorFromString(@"initWithInputMediaType:sinkID:");
  SEL setHSel = @selector(setSampleBufferAvailableHandler:);
  SEL renderSel = @selector(renderSampleBuffer:forInput:);
  vcc_swizzle_method(cls, initSel,
                      (IMP)vcc_still_init_hook, &vcc_still_init_orig);
  vcc_swizzle_method(cls, setHSel,
                      (IMP)vcc_still_set_handler_hook,
                      &vcc_still_set_handler_orig);
  vcc_swizzle_method(cls, renderSel,
                      (IMP)vcc_still_render_hook, &vcc_still_render_orig);
}

// MARK: - BWFigCaptureSession graph callback observation
//
// AVCaptureSession.startRunning → cameracaptured graph build → start → these
// delegate callbacks fire on BWFigCaptureSession. If start fails (error != 0),
// the daemon reports failure back over XPC and client.isRunning stays NO.
// Hook these to see exactly where in the graph startup the failure occurs.

static IMP vcc_sess_didFinishStarting_orig = NULL;
static IMP vcc_sess_didStartSourceNode_orig = NULL;
static IMP vcc_sess_didPrepare_orig = NULL;

typedef void (*VccSessDidFinishStartingFn)(id self, SEL _cmd, id graph, int error);
typedef void (*VccSessDidStartSourceFn)(id self, SEL _cmd, id graph, id node, int error);
typedef void (*VccSessDidPrepareFn)(id self, SEL _cmd, id graph);

static void vcc_sess_didFinishStarting_hook(id self,
                                            SEL _cmd,
                                            id graph,
                                            int error) {
  vcc_log(@"  [Sess graph:didFinishStartingWithError:] self=%p graph=%p err=%d",
          self, graph, error);
  VccSessDidFinishStartingFn orig =
      (VccSessDidFinishStartingFn)vcc_sess_didFinishStarting_orig;
  orig(self, _cmd, graph, error);
}

static void vcc_sess_didStartSourceNode_hook(id self,
                                             SEL _cmd,
                                             id graph,
                                             id node,
                                             int error) {
  vcc_log(@"  [Sess graph:didStartSourceNode:error:] self=%p graph=%p node=%@ err=%d",
          self, graph, node, error);
  VccSessDidStartSourceFn orig =
      (VccSessDidStartSourceFn)vcc_sess_didStartSourceNode_orig;
  orig(self, _cmd, graph, node, error);
}

static void vcc_sess_didPrepare_hook(id self, SEL _cmd, id graph) {
  vcc_log(@"  [Sess graphDidPrepareNodes:] self=%p graph=%p", self, graph);
  VccSessDidPrepareFn orig =
      (VccSessDidPrepareFn)vcc_sess_didPrepare_orig;
  orig(self, _cmd, graph);
}

static void vcc_install_session_graph_observation(void) {
  Class cls = NSClassFromString(@"BWFigCaptureSession");
  if (!cls) {
    vcc_log(@"  session-graph obs: class missing");
    return;
  }
  vcc_swizzle_method(cls,
                      @selector(graph:didFinishStartingWithError:),
                      (IMP)vcc_sess_didFinishStarting_hook,
                      &vcc_sess_didFinishStarting_orig);
  vcc_swizzle_method(cls,
                      @selector(graph:didStartSourceNode:error:),
                      (IMP)vcc_sess_didStartSourceNode_hook,
                      &vcc_sess_didStartSourceNode_orig);
  vcc_swizzle_method(cls,
                      @selector(graphDidPrepareNodes:),
                      (IMP)vcc_sess_didPrepare_hook,
                      &vcc_sess_didPrepare_orig);
}

// MARK: - BWFigCaptureSession init capture + pipelines extraction
//
// To splice our manual sink into a real session, we need a handle to its
// FigCaptureSessionPipelines instance. Hook the session's init and, post-orig,
// reach into the _pipelines ivar via KVC. Store globally so the next-stage
// injector has a live reference.

static IMP vcc_sess_initWithFigSess_orig = NULL;
typedef id (*VccSessInitWithFigSessFn)(id self, SEL _cmd, void *figSess);

static id vcc_captured_bw_session = nil;       // strong ref to the BWFigCaptureSession
static id vcc_captured_pipelines = nil;        // its _pipelines ivar value

__attribute__((ns_returns_retained))
static id vcc_sess_initWithFigSess_hook(id self, SEL _cmd, void *figSess) {
  VccSessInitWithFigSessFn orig =
      (VccSessInitWithFigSessFn)vcc_sess_initWithFigSess_orig;
  id ret = orig(self, _cmd, figSess);
  if (ret) {
    vcc_captured_bw_session = ret;
    @try {
      vcc_captured_pipelines = [ret valueForKey:@"pipelines"];
    } @catch (NSException *e) {
      @try {
        vcc_captured_pipelines = [ret valueForKey:@"_pipelines"];
      } @catch (NSException *e2) {
        vcc_captured_pipelines = nil;
      }
    }
    vcc_log(@"  [BWFigCaptureSession init] -> self=%p figSess=%p _pipelines=%p (class=%@)",
            ret, figSess, vcc_captured_pipelines,
            NSStringFromClass([vcc_captured_pipelines class]));
  }
  return ret;
}

static void vcc_install_session_init_capture(void) {
  Class cls = NSClassFromString(@"BWFigCaptureSession");
  if (!cls) {
    vcc_log(@"  session-init capture: class missing");
    return;
  }
  vcc_swizzle_method(cls,
                      @selector(initWithFigCaptureSession:),
                      (IMP)vcc_sess_initWithFigSess_hook,
                      &vcc_sess_initWithFigSess_orig);
}

// MARK: - BWFigCaptureSession stillImageCoordinator observation
//
// AVCapturePhotoOutput.capturePhoto → daemon-side BWStillImageCaptureCoordinator
// queues a request and fires these delegate callbacks on BWFigCaptureSession.
// If willBegin… fires but didCapture… doesn't, the photo pipeline received
// the request but couldn't satisfy it (typically because no sample buffer
// arrived for it to wrap into a photo).

static IMP vcc_sess_willBeginPhoto_orig = NULL;
static IMP vcc_sess_willBeginPhotoForSettings_orig = NULL;
static IMP vcc_sess_willPreparePhoto_orig = NULL;
static IMP vcc_sess_willCapturePhoto_orig = NULL;
static IMP vcc_sess_didCapturePhoto_orig = NULL;

typedef void (*VccSessWillBeginPhotoFn)(id self, SEL _cmd, id coord, long settingsID);
typedef void (*VccSessSettingsFn)(id self, SEL _cmd, id coord, id settings);
typedef void (*VccSessWillPrepareFn)(id self, SEL _cmd, id coord, id settings, BOOL clientInitiated);
typedef void (*VccSessWillCaptureFn)(id self, SEL _cmd, id coord, id settings, int err);

static void vcc_sess_willBeginPhoto_hook(id self,
                                         SEL _cmd,
                                         id coord,
                                         long settingsID) {
  vcc_log(@"  [Sess stillImageCoordinator:willBeginCaptureBeforeResolvingSettingsForID:] coord=%p id=%ld",
          coord, settingsID);
  VccSessWillBeginPhotoFn orig =
      (VccSessWillBeginPhotoFn)vcc_sess_willBeginPhoto_orig;
  orig(self, _cmd, coord, settingsID);
}

static void vcc_sess_willBeginPhotoForSettings_hook(id self,
                                                    SEL _cmd,
                                                    id coord,
                                                    id settings) {
  vcc_log(@"  [Sess stillImageCoordinator:willBeginCaptureForSettings:] coord=%p settings=%@",
          coord, settings);
  VccSessSettingsFn orig =
      (VccSessSettingsFn)vcc_sess_willBeginPhotoForSettings_orig;
  orig(self, _cmd, coord, settings);
}

static void vcc_sess_willPreparePhoto_hook(id self,
                                           SEL _cmd,
                                           id coord,
                                           id settings,
                                           BOOL clientInitiated) {
  vcc_log(@"  [Sess stillImageCoordinator:willPrepareStillImageCaptureWithSettings:clientInitiated:] coord=%p settings=%@ ci=%d",
          coord, settings, clientInitiated);
  VccSessWillPrepareFn orig =
      (VccSessWillPrepareFn)vcc_sess_willPreparePhoto_orig;
  orig(self, _cmd, coord, settings, clientInitiated);
}

static void vcc_sess_willCapturePhoto_hook(id self,
                                           SEL _cmd,
                                           id coord,
                                           id settings,
                                           int err) {
  vcc_log(@"  [Sess stillImageCoordinator:willCapturePhotoForSettings:error:] coord=%p settings=%@ err=%d",
          coord, settings, err);
  VccSessWillCaptureFn orig =
      (VccSessWillCaptureFn)vcc_sess_willCapturePhoto_orig;
  orig(self, _cmd, coord, settings, err);
}

static void vcc_sess_didCapturePhoto_hook(id self,
                                          SEL _cmd,
                                          id coord,
                                          id settings) {
  vcc_log(@"  [Sess stillImageCoordinator:didCapturePhotoForSettings:] coord=%p settings=%@",
          coord, settings);
  VccSessSettingsFn orig =
      (VccSessSettingsFn)vcc_sess_didCapturePhoto_orig;
  orig(self, _cmd, coord, settings);
}

static void vcc_install_still_coordinator_observation(void) {
  Class cls = NSClassFromString(@"BWFigCaptureSession");
  if (!cls) {
    vcc_log(@"  still-coord obs: BWFigCaptureSession missing");
    return;
  }
  vcc_swizzle_method(cls,
                      @selector(stillImageCoordinator:willBeginCaptureBeforeResolvingSettingsForID:),
                      (IMP)vcc_sess_willBeginPhoto_hook,
                      &vcc_sess_willBeginPhoto_orig);
  vcc_swizzle_method(cls,
                      @selector(stillImageCoordinator:willBeginCaptureForSettings:),
                      (IMP)vcc_sess_willBeginPhotoForSettings_hook,
                      &vcc_sess_willBeginPhotoForSettings_orig);
  vcc_swizzle_method(cls,
                      @selector(stillImageCoordinator:willPrepareStillImageCaptureWithSettings:clientInitiated:),
                      (IMP)vcc_sess_willPreparePhoto_hook,
                      &vcc_sess_willPreparePhoto_orig);
  vcc_swizzle_method(cls,
                      @selector(stillImageCoordinator:willCapturePhotoForSettings:error:),
                      (IMP)vcc_sess_willCapturePhoto_hook,
                      &vcc_sess_willCapturePhoto_orig);
  vcc_swizzle_method(cls,
                      @selector(stillImageCoordinator:didCapturePhotoForSettings:),
                      (IMP)vcc_sess_didCapturePhoto_hook,
                      &vcc_sess_didCapturePhoto_orig);
}

// MARK: - BWStillImageCoordinatorNode existence detector
//
// If our synth session never instantiates BWStillImageCoordinatorNode, the
// capturePhoto request has nowhere to land. Swizzle its known internal
// method (-_enqueueRequestWithSettings:serviceRequestsIfNecessary:) so we
// detect whether the coordinator exists and ever sees a capture request.

static IMP vcc_still_coord_enqueue_orig = NULL;
typedef void (*VccStillCoordEnqueueFn)(id self, SEL _cmd, id settings, BOOL serviceIfNecessary);

static void vcc_still_coord_enqueue_hook(id self,
                                         SEL _cmd,
                                         id settings,
                                         BOOL serviceIfNecessary) {
  vcc_log(@"  [StillCoord enqueueRequest] self=%p settings=%@ service=%d",
          self, settings, serviceIfNecessary);
  VccStillCoordEnqueueFn orig =
      (VccStillCoordEnqueueFn)vcc_still_coord_enqueue_orig;
  orig(self, _cmd, settings, serviceIfNecessary);
}

static void vcc_install_still_coord_node_observation(void) {
  Class cls = NSClassFromString(@"BWStillImageCoordinatorNode");
  if (!cls) {
    vcc_log(@"  still-coord-node obs: class missing");
    return;
  }
  vcc_swizzle_method(cls,
                      @selector(_enqueueRequestWithSettings:serviceRequestsIfNecessary:),
                      (IMP)vcc_still_coord_enqueue_hook,
                      &vcc_still_coord_enqueue_orig);
}

// MARK: - FigCaptureStillImageSinkPipeline init detector
//
// Per CMCapture symbols, the still pipeline is constructed via:
//   -[FigCaptureStillImageSinkPipeline initWithConfiguration:captureDevice:
//      sourceOutputsByPortType:captureStatusDelegate:inferenceScheduler:
//      graph:name:]
// Hook this to see if it's called for our synth session, and what its
// arguments look like. If it's never called, the daemon's graph-build code
// decides upstream that no still pipeline is needed (probably based on a
// source attribute). If it's called and returns nil, we can inspect the
// arguments to figure out which is missing.

static IMP vcc_still_pipe_init_orig = NULL;
typedef id (*VccStillPipeInitFn)(id self,
                                 SEL _cmd,
                                 id config,
                                 id device,
                                 id outputsByPortType,
                                 id captureStatusDelegate,
                                 id inferenceScheduler,
                                 id graph,
                                 id name);

__attribute__((ns_returns_retained))
static id vcc_still_pipe_init_hook(id self,
                                   SEL _cmd,
                                   id config,
                                   id device,
                                   id outputsByPortType,
                                   id captureStatusDelegate,
                                   id inferenceScheduler,
                                   id graph,
                                   id name) {
  vcc_log(@"  [StillPipe init] self=%p config=%@ device=%@ outputs.count=%lu name=%@",
          self, config, device,
          (unsigned long)([outputsByPortType respondsToSelector:@selector(count)]
                          ? [outputsByPortType count] : 0),
          name);
  VccStillPipeInitFn orig = (VccStillPipeInitFn)vcc_still_pipe_init_orig;
  id ret = orig(self, _cmd, config, device, outputsByPortType,
                captureStatusDelegate, inferenceScheduler, graph, name);
  vcc_log(@"  [StillPipe init] -> %p", ret);
  return ret;
}

static void vcc_install_still_pipeline_observation(void) {
  Class cls = NSClassFromString(@"FigCaptureStillImageSinkPipeline");
  if (!cls) {
    vcc_log(@"  still-pipe obs: class missing");
    return;
  }
  SEL sel = NSSelectorFromString(
      @"initWithConfiguration:captureDevice:sourceOutputsByPortType:"
      @"captureStatusDelegate:inferenceScheduler:graph:name:");
  vcc_swizzle_method(cls, sel, (IMP)vcc_still_pipe_init_hook,
                      &vcc_still_pipe_init_orig);
}

// MARK: - FigCaptureSessionPipelines.addStillImageSinkPipelineSessionStorage
//
// Per CMCapture symbols, this is the daemon-side method that registers a
// still-image sink pipeline with the session. If captureSession_buildGraph-
// WithConfiguration's still-pipeline branch ever runs for our synth source,
// this method gets called. If it's never called for our test, the upstream
// gate (parsed still-image sink configurations array empty?) is what we
// need to address.

static IMP vcc_pipelines_addStill_orig = NULL;
typedef void (*VccPipelinesAddStillFn)(id self, SEL _cmd, id storage);

static void vcc_pipelines_addStill_hook(id self, SEL _cmd, id storage) {
  vcc_log(@"  [Pipelines addStillImageSinkPipelineSessionStorage:] self=%p storage=%@",
          self, storage);
  VccPipelinesAddStillFn orig =
      (VccPipelinesAddStillFn)vcc_pipelines_addStill_orig;
  orig(self, _cmd, storage);
}

static void vcc_install_pipelines_addStill_observation(void) {
  Class cls = NSClassFromString(@"FigCaptureSessionPipelines");
  if (!cls) {
    vcc_log(@"  pipelines obs: class missing");
    return;
  }
  vcc_swizzle_method(cls,
                      @selector(addStillImageSinkPipelineSessionStorage:),
                      (IMP)vcc_pipelines_addStill_hook,
                      &vcc_pipelines_addStill_orig);
}

// MARK: - graph-build error suppressors
//
// captureSession_buildGraphWithConfiguration's per-source iteration bails
// to OSStatus -12783 along three known paths on our synth source:
//
//   (1) -[FigCaptureCameraSourcePipeline requiresMasterClock] returns YES,
//       and the post-iteration check (OR of all pipelines' returns) bails
//       on a virtual source that has no real ISP/HW clock.
//   (2) _cs_addObjectToStreamsAttributes returns -12783 when an inherited
//       ivar slot is NULL (called from _FigVideoCaptureSourcesActivate-
//       AndCreateDevices during session activation).
//   (3) -[BWFigVideoCaptureStream initWithCaptureStream:…] sets *errOut
//       = -12783 in its validation-failure path.
//
// (1) is neutralized by rewriting the function's prologue to `mov w0, #0; ret`.
// The function's address is resolved from CMCapture's LC_SYMTAB by name —
// no hardcoded VMA.
//
// (2)+(3) are neutralized by scanning CMCapture's __text for the specific
// MOVN encodings the compiler used to prepare -12783 in w20 / w8, and
// rewriting each to `MOVZ w?, #0`. -12783 is a capture-specific OSStatus
// emitted only by the daemon; over-application is benign because the
// daemon's only consumer in the VM is our synth.

static void vcc_install_csp_requires_master_clock_hook(void) {
  vcc_image_t img;
  if (vcc_image_resolve(&img, "FigCaptureSourceServerStart") != 0) {
    vcc_log(@"  graph-build patches: image resolve failed");
    return;
  }

  // (1) Resolve -[FigCaptureCameraSourcePipeline requiresMasterClock] via
  // LC_SYMTAB. The function is called via direct C dispatch (not in the
  // objc method table on observed builds, so swizzling won't work), so
  // we rewrite its prologue in place. The PAC-signed address from the
  // symtab is stripped before the write.
  static const char *const kReqMCSyms[] = {
      "_-[FigCaptureCameraSourcePipeline requiresMasterClock]",
      "-[FigCaptureCameraSourcePipeline requiresMasterClock]",
      NULL,
  };
  uintptr_t reqMC = 0;
  for (unsigned i = 0; kReqMCSyms[i]; i++) {
    reqMC = vcc_lookup_lc_symtab(&img, kReqMCSyms[i]);
    if (reqMC) {
      vcc_log(@"  requiresMasterClock @ 0x%lx (sym=%s)",
              (unsigned long)reqMC, kReqMCSyms[i]);
      break;
    }
  }
  if (reqMC) {
    uintptr_t target = (uintptr_t)ptrauth_strip(
        (void *)reqMC, ptrauth_key_function_pointer);
    uint32_t insn0 = ((const uint32_t *)target)[0];
    uint32_t insn1 = ((const uint32_t *)target)[1];
    // Sanity anchor: the second prologue insn should be pacibsp on every
    // arm64e build that signs return addresses. Refuse the patch if it
    // isn't — we'd rather skip than rewrite an unrelated function.
    if (insn1 != 0xD503237Fu) {
      vcc_log(@"  requiresMasterClock @ 0x%lx: insn1=0x%08x != pacibsp; skip",
              (unsigned long)target, insn1);
    } else {
      int ok1 = vcc_patch_word(target,     insn0, 0x52800000u);  // mov w0, #0
      int ok2 = vcc_patch_word(target + 4, insn1, 0xd65f03c0u);  // ret
      vcc_log(@"  requiresMasterClock prologue patch @ 0x%lx: %d/%d",
              (unsigned long)target, ok1, ok2);
    }
  } else {
    vcc_log(@"  requiresMasterClock symbol not in LC_SYMTAB; patch skipped");
  }

  // (2) `mov w20, #-12783` (MOVN encoding 0x12863dd4) -> `mov w20, #0`.
  vcc_scan_and_patch(&img, 0x12863dd4u, 0x52800014u,
                     "mov w20, #-12783 -> #0");
  // (3) `mov w8, #-12783` (MOVN encoding 0x12863dc8) -> `mov w8, #0`.
  vcc_scan_and_patch(&img, 0x12863dc8u, 0x52800008u,
                     "mov w8, #-12783 -> #0");
}
