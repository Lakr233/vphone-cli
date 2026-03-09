Lean TweakLoader
================

Purpose
- Provide the `/var/jb/usr/lib/TweakLoader.dylib` component expected by the
  vphone JB basebin runtime (`systemhook.dylib`).
- Load user tweak dylibs from
  `/var/jb/Library/MobileSubstrate/DynamicLibraries` into matching processes.

Current behavior
- Enumerates substrate-style `.plist` files in the tweak directory.
- Supports:
  - `Filter.Bundles`
  - `Filter.Executables`
- `dlopen`s the corresponding `.dylib` when the current process matches.

Logging
- Writes to `/var/jb/var/mobile/Library/TweakLoader/tweakloader.log`.
