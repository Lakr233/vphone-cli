# Sandbox Escape — worse_query (containermanagerd TOCTOU)

**Date:** 2026-11-14  
**Status:** UNPATCHED as of iOS 26.0–26.7.2, iOS 27.0–27.2.1, iOS 27.3b1  
**Author:** Taj C (forcequitOS)  
**Repos:** [worse_query](https://github.com/forcequitOS/worse_query) (617 stars),
[Erosion](https://github.com/jailbreakdotparty/Erosion) (820 stars),
[bad_query](https://github.com/forcequitOS/bad_query) (predecessor)

## Bug Class

**TOCTOU symlink race** against `containermanagerd`'s container path resolution.

No kernel bug. No code injection. No persistence. Pure userland sandbox escape via
a confused daemon.

## How It Works

1. **Prerequisite:** App has a valid App Group entitlement (personal Apple ID sideloading
   works). The App Group gives you a writable `Library/Caches` directory.

2. **Symlink swap:** Delete `Library/Caches` in your App Group container. Replace it with
   a symlink pointing to the **target path** you want to read/write.

3. **Query containermanagerd:** Build a container query via `libsystem_containermanager.dylib`:
   ```objc
   query_set_class(query, 7);                    // class 7 = appGroup
   query_set_group_identifiers(query, group_id);
   query_set_part(query, 3);                     // part 3 = Library/Caches
   query_set_flags(query, flags);                // iOS 26: 0x800000000, iOS 27: 0x8000000000
   ```

4. **Daemon follows symlink:** `containermanagerd` resolves the path, follows the symlink
   to the target, and issues a **sandbox extension token** for that path.

5. **Consume token:** Call `sandbox_extension_consume()` — now you have read/write access
   to the target path from your app sandbox.

6. **Cleanup:** Remove symlink, recreate the real `Library/Caches` directory, release the
   extension handle when done.

## Accessible Paths

```
/var/mobile/Containers/Data/Application/*         ← other apps' data
/var/mobile/Containers/Data/InternalDaemon/*
/var/mobile/Containers/Data/PluginKitPlugin/*
/var/mobile/Containers/Shared/AppGroup/*           ← other apps' shared data
/var/containers/Data/System                        (iOS 27 only)
/var/containers/Shared/SystemGroup/*               (iOS 27 only)
```

## pathleak — Container Enumeration

Since container UUIDs are random, `worse_query` includes `pathleak` — a brute-force
inode enumeration using `fsgetpath()`:

```objc
for (uint64_t inode = 1; inode <= max_inode; inode++) {
    ssize_t n = fsgetpath(buffer, sizeof(buffer), &fsid, inode);
    // match against target prefix → collect container paths
}
```

- `fsgetpath()` leaks paths across sandbox boundaries (separate primitive)
- Maps UUID paths to bundle IDs via `com.apple.containermanager.identifier` xattr
- ~30 seconds on first run

## iOS 26 vs 27 Flag Difference

The `flags` field differs between versions — a 37-bit-wide bitmask:
- **iOS 26.x:** `0x0000000800000000` (bit 35)
- **iOS 27.x:** `0x0000008000000000` (bit 39)

Erosion's Swift wrapper auto-detects the OS version and sets the right flag.

## Erosion — Tweaks Built on worse_query

[Erosion](https://github.com/jailbreakdotparty/Erosion) (by jailbreakdotparty) is a
SwiftUI app that uses `worse_query` to apply system customizations:

- **Three write primitives:**
  - Direct write (overwrite in place)
  - Temp-swap (atomic rename)
  - Atomic fd (truncate → write → fsync → verify → rollback on failure)
- **Tweaks:**
  - MobileGestalt editing (iOS 27 only)
  - PosterBoard wallpapers (`.tendies` archives)
  - Configuration profiles (supervision + footnote)
  - Dialer themes
  - File browser with full read/write
- **Respring method:** WebView GPU/memory crash — 500 blurred 3D divs + 10MB
  crypto random per tick + share API spam → jetsam kills SpringBoard

## Chain Relevance

worse_query is **not a kernel exploit** and the author explicitly states it's not
relevant to a jailbreak. However, for our research it's interesting as:

1. **Complementary primitive:** If our kernel chain achieves R/W but no sandbox escape,
   worse_query provides the userland file access layer
2. **Container enumeration:** `pathleak`'s `fsgetpath()` technique reveals container
   UUIDs that would otherwise require kernel reads to discover
3. **Research surface:** The `containermanagerd` XPC interface likely has more queryable
   classes beyond 7, and other `part` values beyond 3, worth reversing

## Reproduction

```bash
# Clone
git clone https://github.com/forcequitOS/worse_query.git
cd worse_query

# Open in Xcode, set your team, configure an App Group entitlement
# The App Group ID must match the one in worse_query.m / WorseQuerySwift.swift
# Build and run on device (iOS 26.0 - 26.7.2 or iOS 27.0 - 27.2.1)
```

Key: you need a valid App Group entitlement. Personal Apple ID sideloading works.
Enterprise certs can break App Groups.
