// MISFixConfig.h — the hook's one configuration file.
//
// `/usr/lib/libmisfix.plist`, beside the dylib, so a process that can load the
// hook can always read its settings: installd and misagent are sandboxed, and
// /usr/lib is the one directory both already reach.
//
// Keys, all optional. An absent or unreadable file leaves every behaviour off,
// which is the same as not injecting the hook at all.
//
//     UniqueDeviceID  (string)  The UDID to answer MobileGestalt with. Set it
//                               to a device already registered with a team and
//                               that team's provisioning profiles install on
//                               this guest. Empty or absent: the guest answers
//                               with its own.

#ifndef MISFIX_CONFIG_H
#define MISFIX_CONFIG_H

#include <CoreFoundation/CoreFoundation.h>

/// The configured UDID, or NULL when none is set.
///
/// Borrowed — the caller must not release it. Re-read when the file's
/// modification time or size changes, so editing the plist takes effect on the
/// next query without restarting anything.
CFStringRef MISFixCopyConfiguredDeviceIdentifier(void);

#endif
