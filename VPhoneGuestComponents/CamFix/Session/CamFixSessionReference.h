#import <Foundation/Foundation.h>

// The ordinary weak store aborts if AVFoundation calls a session getter from
// -dealloc. This runtime entry point leaves the slot nil instead. Use an alias
// so ARC still manages the local weak slot and its subsequent strong load.
extern id cfx_storeWeakOrNil(id __weak *location, id value)
    __asm("_objc_storeWeakOrNil");

static inline id cfx_load_live_session(id __unsafe_unretained session) {
  __weak id candidate = nil;
  cfx_storeWeakOrNil(&candidate, session);
  return candidate;
}
