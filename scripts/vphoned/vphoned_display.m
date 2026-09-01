/*
 * vphoned_display — Dynamic guest display/backlight state probe.
 */

#import "vphoned_display.h"

#include <notify.h>

/// SpringBoard publishes this Boolean Darwin-notification state across
/// processes.  Unlike SBBacklightController it is readable from a
/// LaunchDaemon, so it remains usable when the private SpringBoard classes
/// are not present in this process.  The token is retained instead of being
/// registered per sample; Host polling is only 4 Hz while a CMIO client is
/// actively consuming this VM.
static int gBlankedScreenToken = -1;
static BOOL gBlankedScreenTokenChecked = NO;

static NSNumber *vp_springboard_blanked_screen(void) {
  if (!gBlankedScreenTokenChecked) {
    gBlankedScreenTokenChecked = YES;
    int token = -1;
    if (notify_register_check("com.apple.springboard.hasBlankedScreen", &token) ==
        NOTIFY_STATUS_OK) {
      gBlankedScreenToken = token;
    }
  }
  if (gBlankedScreenToken < 0)
    return nil;

  uint64_t value = 0;
  if (notify_get_state(gBlankedScreenToken, &value) != NOTIFY_STATUS_OK)
    return nil;
  // The published state is Boolean. Treat unexpected future values as
  // unknown rather than guessing their meaning on a new OS build.
  if (value > 1)
    return nil;
  return @(value != 0);
}

NSDictionary *vp_display_state_query(void) {
  NSNumber *blankedScreen = vp_springboard_blanked_screen();
  NSNumber *displayOn = blankedScreen ? @(!blankedScreen.boolValue) : nil;

  NSMutableDictionary *result = [@{
      @"display_on" : displayOn ?: [NSNull null],
      @"blanked_screen" : blankedScreen ?: [NSNull null],
      @"locked" : [NSNull null],
  } mutableCopy];
  if (displayOn)
    result[@"source"] = @"notify:com.apple.springboard.hasBlankedScreen";
  return result;
}
