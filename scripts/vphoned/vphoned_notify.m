/*
 * vphoned_notify — Darwin notification helpers.
 *
 * Low power mode: Sets LPM state via notify_set_state + notify_post.
 * Generic notify_post: Posts an arbitrary Darwin notification name, optionally
 * setting a uint64 state value before posting.
 */

#import "vphoned_notify.h"
#import "vphoned_protocol.h"
#include <notify.h>

NSDictionary *vp_handle_notify_command(NSDictionary *msg) {
  id reqId = msg[@"id"];
  BOOL enabled = [msg[@"enabled"] boolValue];

  int token = 0;
  BOOL ok = (notify_register_check("com.apple.system.lowpowermode", &token) ==
             NOTIFY_STATUS_OK);
  if (ok) {
    notify_set_state(token, enabled ? 1 : 0);
    ok = (notify_post("com.apple.system.lowpowermode") == NOTIFY_STATUS_OK);
    notify_cancel(token);
  }

  NSLog(@"vphoned: low_power_mode %s -> %s", enabled ? "on" : "off",
        ok ? "ok" : "failed");
  NSMutableDictionary *r = vp_make_response(@"low_power_mode", reqId);
  r[@"ok"] = @(ok);
  return r;
}

NSDictionary *vp_handle_notify_post_command(NSDictionary *msg) {
  id reqId = msg[@"id"];
  NSString *name = msg[@"name"];
  if (!name || name.length == 0) {
    NSMutableDictionary *r = vp_make_response(@"err", reqId);
    r[@"msg"] = @"missing notification name";
    return r;
  }

  const char *cname = [name UTF8String];
  BOOL hasState = (msg[@"state"] != nil);
  BOOL ok = YES;

  if (hasState) {
    uint64_t state = [msg[@"state"] unsignedLongLongValue];
    int token = 0;
    ok = (notify_register_check(cname, &token) == NOTIFY_STATUS_OK);
    if (ok) {
      notify_set_state(token, state);
      ok = (notify_post(cname) == NOTIFY_STATUS_OK);
      notify_cancel(token);
    }
    NSLog(@"vphoned: notify_post %@ state=%llu -> %s", name, state,
          ok ? "ok" : "failed");
  } else {
    ok = (notify_post(cname) == NOTIFY_STATUS_OK);
    NSLog(@"vphoned: notify_post %@ -> %s", name, ok ? "ok" : "failed");
  }

  NSMutableDictionary *r = vp_make_response(@"notify_post", reqId);
  r[@"ok"] = @(ok);
  return r;
}
