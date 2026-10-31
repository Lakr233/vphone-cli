#import <AVFoundation/AVFoundation.h>

@interface RunningObserver : NSObject
@end
@implementation RunningObserver
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object
                       change:(NSDictionary *)change context:(void *)context {}
@end

// Public AVFoundation API only.
// Run on a background queue. This does not start capture or save images.
NSString *RunCameraSessionProbe(void) {
  AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  if (!device) return @"INCONCLUSIVE: no video device";
  if (![device.uniqueID isEqualToString:@"vphone:vcam:0"])
    return @"INCONCLUSIVE: expected vPhone synthetic camera";
  RunningObserver *observer = [RunningObserver new];
  for (NSUInteger cycle = 0; cycle < 100; cycle++) {
    @autoreleasepool {
      NSError *error = nil;
      AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
      if (!input) return [NSString stringWithFormat:@"INCONCLUSIVE: input creation: %@", error];
      AVCaptureSession *session = [AVCaptureSession new];
      if (![session canAddInput:input]) return @"INCONCLUSIVE: input rejected";
      [session addInput:input];
      AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
      if (![session canAddOutput:output]) return @"INCONCLUSIVE: output rejected";
      [session addOutput:output];
      // Exercise both ordinary and KVO-observed session destruction.
      // Modern Foundation removes registrations during observed-object dealloc.
      if (cycle % 2) [session addObserver:observer forKeyPath:@"running" options:0 context:NULL];
      NSLog(@"SessionProbe cycle %lu releasing configured session", (unsigned long)cycle);
      session = nil;
    }
  }
  return @"Completed 100 configured-session release cycles. This alone does not verify frame delivery.";
}
