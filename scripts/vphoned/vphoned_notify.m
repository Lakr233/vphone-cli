/*
 * vphoned_notify — Low power mode state sync.
 *
 * Sets LPM state via notify_set_state("com.apple.system.lowpowermode") + notify_post.
 * All registrations for a notification name share one state value, so this
 * updates what NSProcessInfo and SpringBoard read via notify_get_state —
 * mirroring what powerd does internally when the user toggles Low Power Mode.
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
