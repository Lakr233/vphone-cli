#!/usr/bin/env python3
"""Merge Campo's needed backboard/frontboard launch mach-services into an
entitlements plist's mach-lookup exception array, in place. See
0_binary_patch_comparison.md #14.

Usage: campo_mach_lookup_exceptions.py <entitlements.plist>
"""
import plistlib
import sys

EXCEPTION_KEY = "com.apple.security.exception.mach-lookup.global-name"

SERVICES = [
    "com.apple.backboard.display.services",
    "com.apple.iohideventsystem",
    "com.apple.CARenderServer",
    "com.apple.backboard.hid.services",
    "com.apple.backboard.hid-services.xpc",
    "com.apple.backboard.TouchDeliveryPolicyServer",
    "com.apple.backboard.system-app-server",
    "com.apple.backboard.watchdog",
    "com.apple.backboard.oswatchdog",
    "com.apple.backboard.altsysapp",
    "com.apple.AttentionAwareness",
    "PurpleSystemEventPort",
    "PurpleWorkspacePort",
    "com.apple.frontboard.systemappservices",
    "com.apple.frontboard.workspace",
    "com.apple.frontboardservices.systemappmanager",
    "com.apple.frontboard.watchdog",
]


def merge(path):
    with open(path, "rb") as f:
        entitlements = plistlib.load(f)

    existing = list(entitlements.get(EXCEPTION_KEY, []))
    added = [s for s in SERVICES if s not in existing]
    entitlements[EXCEPTION_KEY] = existing + added

    with open(path, "wb") as f:
        plistlib.dump(entitlements, f)

    print("  [+] Campo mach-lookup exception count: %d (+%d added)"
          % (len(entitlements[EXCEPTION_KEY]), len(added)))


def main(argv):
    if len(argv) != 2:
        print("usage: campo_mach_lookup_exceptions.py <entitlements.plist>",
              file=sys.stderr)
        return 2
    merge(argv[1])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
