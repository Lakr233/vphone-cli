# Lean TweakLoader

Purpose

- Provide the `/var/jb/usr/lib/TweakLoader.dylib` component expected by the
  vphone JB basebin runtime (`systemhook.dylib`).
- Load user tweak dylibs from
  `/var/jb/Library/MobileSubstrate/DynamicLibraries` into matching processes.

Current behavior

- Enumerates substrate-style `.plist` files in the tweak directory.
- Two engagement tiers:
  - `Filter.Frameworks` tweaks are scheduled in *every* process and
    `dlopen`ed asynchronously once a matching `*.framework/` image loads
    (`_dyld_register_func_for_add_image`); no `dlopen` happens in a process
    where the named framework never appears.
  - Tweaks filtered by `Filter.Bundles` / `Filter.Executables`, or with no
    filter, load only in `.app/` processes plus the daemon allowlist in
    `kVPhoneAllowedDaemonPaths`.
- `dlopen`s the corresponding `.dylib` when the current process matches.

Logging

- Writes to `/var/jb/var/mobile/Library/TweakLoader/tweakloader.log`.
