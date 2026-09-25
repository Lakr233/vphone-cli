# RootHide loader links for later-installed applications

## Observation and boundary

The 2026-09-24 TrollSpeed crash reports an unresolved
`@loader_path/.jbroot/usr/lib/libroothide.dylib`. dyld tried the physical
`<jbroot>/Applications/TrollSpeed.app/.jbroot/usr/lib/libroothide.dylib`
and stopped before the application began executing. This identifies a loader
path failure, but the report alone does not prove whether the `.jbroot` link,
the target `usr/lib/libroothide.dylib`, or both are missing. Inspect both on
the guest before changing anything.

RootHide's [developer documentation](https://github.com/roothide/Developer/blob/main/roothide.md)
specifies a `.jbroot` link in every directory containing a Mach-O image and
says package installation or the jailbreak's loader normally creates it.
Apple's [dynamic library documentation](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/DynamicLibraries/100-Articles/DynamicLibraryDesignGuidelines.html)
defines `@loader_path` relative to the referencing image. A link beside the
main executable alone will not cover a dependent image in an embedded
framework or extension directory.

## Present vphone behavior

- `GuestIrisinInstaller.ensureRootHideLinks` seeds the bootstrap root and
  `bin`, `sbin`, `usr/bin`, `usr/sbin`, `usr/lib`, and `usr/libexec` at initial
  bootstrap installation and on `vphoned` startup. It does not cover
  `Applications/*.app` installed later.
- The launchd hook sees physical bootstrap executable paths and app paths
  before `posix_spawn`. It passes `VPHONE_JB_ROOT` and SystemHook injection to
  `xpcproxy` and direct app spawns.
- SystemHook's constructor loads `TweakLoader.dylib` with `dlopen`, but a
  required `LC_LOAD_DYLIB` is resolved by dyld before that constructor. An
  in-process repair there cannot recover this launch failure. SystemHook in
  the parent of a chained spawn could repair links before spawning instead.
- vphone's `apps.install` calls IcliKit, which installs into an application
  container without creating RootHide loader links. The Irisin bootstrap
  installer and Irisin's own package installer are separate installation
  paths. Neither existing vphone link seeding nor a hook on `dpkg` alone
  covers every one of these paths.

## Implemented boundary

The shared `RootHideLoaderLinks` helper runs before the final spawn in both
`launchdhook-vphone` and `SystemHook-vphone`. It accepts executable paths
inside the selected RootHide bootstrap, including `/var` and `/private/var`
spellings, and creates a relative `.jbroot` link in the executable's own
directory. It resolves and validates an existing link, refuses a non-link or
a link to another root, and never writes into an unrelated app container.
The spawn result is preserved if link creation fails; the hooks log the
failure. A single directory operation is bounded work in PID 1. Embedded
frameworks with their own `@loader_path/.jbroot` dependency will still need
their own link before dyld loads them; that needs a separate package-side
pass or a carefully bounded Mach-O directory walk.

The fixed bootstrap link seeding in `vphoned` remains necessary. A test
LaunchDaemon loaded after boot spawned without passing through either observed
interposer: a copied RootHide `true` executable under an unlinked app directory
exited with `OS_REASON_DYLD` (status 6), then exited successfully (status 0)
after its `.jbroot` link was created. Removing vphoned's `usr/libexec` seed
could therefore regress the first Irisin daemon launch. An installer-side link
pass is useful for such jobs and for normal uninstall cleanup, but cannot
cover third-party installers by itself. A dyld path remap could
remove the filesystem links entirely, but would require an early, versioned
patch to the loader, a reliable current-root lookup in every affected process,
and tests for every RootHide load-command form. Its boot-wide reach makes it
the highest-risk option for this specific gap.

## Further verification

1. Check `lstat`/`readlink` of the exact app directory's `.jbroot`, confirm
   `<jbroot>/usr/lib/libroothide.dylib` exists, and inspect the executable's
   `LC_LOAD_DYLIB` entries. Keep the original crash report.
2. Reproduce the missing-link launch on a clone. Confirm launchd logs the
   final physical executable and that the failure happens before SystemHook
   logs its constructor for that PID.
3. With the link in place before spawn, confirm dyld opens the target library,
   TrollSpeed starts, and any later failure is diagnosed separately.
4. Exercise a bundle with a framework or extension referencing the same
   install name, a package upgrade, uninstall, safe mode, and a RootHide root
   rerandomization. Confirm existing non-link `.jbroot` entries are preserved.

On 2026-09-25, a copy of `vphone-27.0-cloudos-26.4` booted with both updated
hooks. Its RootHide `usr/lib/libroothide.dylib` existed. The unlinked
`Applications/Xrash.app` launched and became frontmost; launchd logged
`loader-link ... status=0`, and the new `.jbroot` resolved to the selected
root. The same before/after result was observed for `Applications/irisin.app`.
The test LaunchDaemon described above was unloaded and removed. TrollSpeed
was not installed on this VM, so its exact package remains untested here.
The original named VM then booted with the two updated hooks. Xrash and
Irisin each launched frontmost, and each missing app-directory `.jbroot`
was created and resolved to the selected RootHide root.
