// AVCaptureVideoDataOutput's recommended asset-writer settings for vcam
// outputs.
//
// A client that records its data output's frames builds an
// AVAssetWriterInput from -recommendedVideoSettingsForAssetWriterWithOutputFileType:.
// The output derives those settings from the capture graph's negotiated
// format; a vcam session's graph never runs, so the real answer has width,
// height and bit rate 0 and the writer fails on its first frame. Answer with
// H.264 at the size video delivery produces for this output.

#import "CamFixPrivate.h"

static IMP cfx_orig_recommended = NULL;

static NSDictionary *cfx_recommended_hook(id self, SEL _cmd, NSString *fileType) {
  typedef NSDictionary *(*Fn)(id, SEL, NSString *);
  NSDictionary *real = ((Fn)cfx_orig_recommended)(self, _cmd, fileType);
  if (!cfx_output_is_for_vcam(self)) return real;
  uint32_t w = 0, h = 0;
  if (!cfx_output_frame_size(self, &w, &h)) return real;
  NSDictionary *ours = @{
    AVVideoCodecKey: AVVideoCodecTypeH264,
    AVVideoWidthKey: @(w),
    AVVideoHeightKey: @(h),
    AVVideoCompressionPropertiesKey: @{
      AVVideoAverageBitRateKey: @(2000000),
      AVVideoExpectedSourceFrameRateKey: @(30),
      AVVideoMaxKeyFrameIntervalKey: @(30),
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    },
  };
  cfxlog(@"[writer settings] %@ -> %ux%u H.264", fileType, w, h);
  return ours;
}

void cfx_install_asset_writer_settings(void) {
  Class out = NSClassFromString(@"AVCaptureVideoDataOutput");
  Method m = out ? class_getInstanceMethod(
                       out, @selector(recommendedVideoSettingsForAssetWriterWithOutputFileType:))
                 : NULL;
  if (!m) return;
  cfx_orig_recommended = method_setImplementation(m, (IMP)cfx_recommended_hook);
  cfxlog(@"installed recommendedVideoSettings hook");
}
