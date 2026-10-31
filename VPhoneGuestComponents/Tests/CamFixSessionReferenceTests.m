#import "CamFixSessionReference.h"
#include <assert.h>

static BOOL checkedDealloc;
static NSHashTable *sessions;
@interface SessionProbe : NSObject
@end
@implementation SessionProbe
- (void)dealloc {
  // Mirrors isRunning -> tracking during AVCaptureSession teardown.
  assert(cfx_load_live_session(self) == nil);
  checkedDealloc = YES;
}
@end

int main(void) {
  @autoreleasepool {
    assert(cfx_load_live_session(nil) == nil);
    sessions = [NSHashTable weakObjectsHashTable];
    @autoreleasepool {
      SessionProbe *session = [SessionProbe new];
      id live = cfx_load_live_session(session);
      assert(live == session);
      [sessions addObject:live];
      assert([sessions containsObject:session]);
      assert(!checkedDealloc);
    }
    assert(checkedDealloc);
    assert(sessions.allObjects.count == 0);
  }
  puts("CamFix session reference: passed");
}
