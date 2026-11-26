#pragma once
#import <Foundation/Foundation.h>
// Resolves an exported libAccessibility symbol by name, or NULL. Injected so a test can drive fakes.
typedef void *(*VPAxSymbolResolver)(const char *name);
// `{features:{name:value}, unavailable:[name]}` for every feature, or for `feature` alone (nil is all).
// An unknown feature returns `{error:invalid_request, message}`.
NSDictionary *vp_ax_settings_get_with(VPAxSymbolResolver resolve, NSString *feature);
// Sets one feature, waits 2 s, and returns `{feature, value}` read again, only if it still equals the
// requested value. Errors: `{error, message}` with error invalid_request (unknown feature or value),
// unavailable (a symbol is missing, or the guest reverted the setting: the message carries the settled
// value) or ax_failure.
NSDictionary *vp_ax_settings_set_with(VPAxSymbolResolver resolve, NSString *feature, id value);
NSDictionary *vp_ax_settings_get(NSString *feature);
NSDictionary *vp_ax_settings_set(NSString *feature, id value);
