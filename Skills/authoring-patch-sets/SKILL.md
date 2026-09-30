---
name: authoring-patch-sets
description: Declare a new firmware patch in a vphone patch set, add a patch set, or write a patch preset. Use when adding or changing a patch in FirmwarePatcher, when a patch needs a version gate, when a patch should be selectable or off by default, or when building an out-of-tree .vphonepatchset.
---

# Authoring Patch Sets

Every patch this project applies is declared in a **patch set**, selected by a
**preset**, and written only if the **gate** says so. A patch that exists in code
but in no manifest still applies — it just cannot be turned off, and it prints a
warning on every run. Declaring it is what makes it real.

## The Three Layers

| Layer | Type | Where |
| --- | --- | --- |
| A patch | `VPhonePatchDeclaration` | a set's `patches` array |
| A set | `VPhonePatchSetManifest` | `FirmwarePatcher/PatchSets/*.swift`, or a `.vphonepatchset`'s `Contents/Resources/Manifest.plist` |
| A preset | `VPhonePatchPreset` | `VPhoneExecutable/VPhoneVirtualization/Resources/patches_presets/*.plist` |

The types live in `VPhoneExecutable/VPhoneCommand/VPhonePatchKit/PatchSet/`. The
nine in-tree sets and the two shipped presets live in
`VPhoneExecutable/VPhoneCommand/FirmwarePatcher/PatchSets/`, listed by
`FirmwarePatchSetCatalog`.

## Adding a Patch to an Existing Set

1. **Write the patch as usual.** Nothing about patch code changes: same
   `ARM64Disassembler` matching, same `ARM64Encoder` / `ARM64` constants for
   replacement bytes, same `emit(...)`. Follow the kernel patcher guardrails in
   `AGENTS.md`.

2. **Note the record identifier your patch emits** — the `patchID:` you pass to
   `emit`. That is what ties the patch to its declaration.

3. **Declare it** in the right set, with the identifier being the record
   identifier, or the part before `.<site>` when the patch writes several
   sites. Name it by the scheme in [Naming](#naming):

   ```swift
   VPhonePatchDeclaration(
       identifier: "kernel-boot-my_patch",
       title: "What it is, in three or four words",
       summary: "What it does and why the guest needs it. One or two sentences.",
       target: .firmware(.kernelcache),
       applicability: VPhonePatchApplicability(iOSBase: .major(27)),
       bootEssential: true,
   )
   ```

4. **Build and run the golden corpus.** A record no declaration covers prints
   `[!] <component>: <id> is declared by no patch set; applying it anyway`. Grep
   the logs for `declared by no patch set` — it must be absent.

### Naming

A patch identifier is `{component}-{effect}-{name}`, hyphen-separated:

- **component** — where the bytes land: `avpbooter`, `ibss`, `ibec`, `llb`,
  `txm`, `kernel`, `devicetree`, `dyld` (the shared cache), `preboot`, or
  `system-<binary>` for a guest system binary or file
  (`system-seputil-boot-gigalocker_uuid`, `system-vphoned-boot-install`).
- **effect** — derived, never chosen: `boot` if `bootEssential`, else `exp` if
  `standard` leaves it off, else `cfw`. A patch that changes either property is
  renamed with it.
- **name** — snake_case, `[a-z0-9_]`, no dots or hyphens.

`Every patch identifier names its component, effect and patch` in
`FirmwarePatchSetCatalogTests` checks the shape, the effect and uniqueness for
every bundled declaration.

### Identifiers Are the Contract

A declaration covers its own record and any record `<identifier>.<site>` —
only a dot starts a site:

- `kernel-boot-kcall10` covers `kernel-boot-kcall10.sy_call`, `kernel-boot-kcall10.sy_munge`, …
- `kernel-boot-sandbox_ext` covers `kernel-boot-sandbox_ext.3` and every other index
- `kernel-boot-post_validation` does **not** cover `kernel-boot-post_validation_unsigned`
- `kernel-cfw-debugger` does **not** cover `kernel-cfw-debuggerless`

An underscore continues a snake_case name, so it never separates a site: emit
`.1`, not `_1`.

Pick the granularity a user would want to tick. One declaration per patch method
is usually right — a patch writing four sites that only work together is one
checkbox, because half of it would not boot. Where sites are genuinely
independent, declare them separately: `kernel-*-sandbox_*` is five declarations,
one per MACF hook, because turning one hook off is a sensible thing to want.

**Never let one declaration read as a site of another.**
`No patch identifier is a record-site prefix of another` fails if you do.

## Version Gates

`applicability` is the only correct way to say "this patch is for release X". It
is a structured enum, never a string:

```swift
VPhonePatchApplicability(iOSBase: .major(27))                        // every 27.x
VPhonePatchApplicability(iOSBase: .release(major: 26, minor: 0))     // exactly 26.0
VPhonePatchApplicability(cloudOS: .atLeast(major: 26, minor: 4))     // 26.4 and later
VPhonePatchApplicability(iOSBase: .oneOf([.release(major: 26, minor: 0), .major(18)]))
```

`iOSBase` is the iPhone base whose userland is restored into the guest; `cloudOS`
is the release supplying the kernel and boot chain. Only major and minor are
compared, so 18.6.2 satisfies `.major(18)`.

An unreadable version satisfies only `.any`. That is deliberate: a patch pinned
to a release must not apply when nothing knows which release this is.

Two rules follow, and they are the ones people get wrong:

- **A version gate is not a preference.** Use it when applying the patch
  elsewhere would patch the wrong shapes or break the guest. Do not use it to
  express "most people want this off" — that is what a preset's block list is
  for.
- **A preset cannot widen a gate.** Checking a box in the UI changes the
  selection, never the applicability. So a patch pinned to iOS 18 is unreachable
  on 26.x, by design. If a patch genuinely needs to be available everywhere *and*
  off by default, give it `.any` applicability and block it in `standard`.

Do **not** add a boolean flag to `FirmwarePipeline` or a `--force-something` CLI
flag for this. The patches behind `--frida`, `--force-exc-guard` and
`--force-dsc-maxslide` are declarations now, and all three flags are gone.
Adding another is a regression.

## Boot-Essential Patches

Set `bootEssential: true` when the guest does not boot without the patch. This
does not prevent it being turned off — an external set replacing it is a
supported case — but it makes the consequence visible: the resolver reports it in
`droppedBootEssentials`, `fw patch` logs `[!] Boot-essential patches are off:`,
and the Launchpad editor warns before letting it be unticked.

A boot-essential declaration must have a `summary`. The test enforces it: it is
the text someone reads before unticking a box that stops their VM booting.

## Adding a New Patch Set

A set is worth creating when its patches share a reason to be on or off together.
Copy the shape of `FirmwareKernelFridaPatchSet.swift` — it is the smallest one:

```swift
public enum FirmwareMyPatchSet {
    public static let identifier = "com.vphone.patchset.my"

    public static let manifest = VPhonePatchSetManifest(
        identifier: identifier,
        name: "My Patches",
        summary: "One line on what this set is for",
        patches: [ /* declarations */ ],
        requires: ["vphone.kernel.base"],
        provides: ["vphone.my"],
        conflictsWith: [],
        after: ["vphone.kernel.base"],
    )
}
```

Then:

1. Add the manifest to `FirmwarePatchSetCatalog.bundled`.
2. If the set maps to a whole patcher, gate that patcher's construction in
   `FirmwarePipelineComponents.buildComponentList` on `includesSet(...)`. **This
   matters:** a patcher left in place while its set is out of the preset emits
   records nothing declares, and undeclared records apply. Leaving the set out
   has to mean leaving the patcher out.
3. Add the set to both shipped preset plists (both name every set; presets differ
   by their selection, not by which sets they draw on).
4. Run the catalogue tests.

### Capabilities, Requires, Conflicts, After

`provides` names capabilities; a set implicitly provides its own identifier.
`requires` must be satisfied by some set in the plan or resolution fails.
`conflictsWith` is enforced **symmetrically** — either side naming the other is a
conflict, so an older set need not be edited to learn about a newer rival. There
is no `Supersedes`: a conflict is an error, not a silent winner. `after` orders
the sets, and a cycle is an error.

Two sets may not declare the same patch identifier. A set that *replaces* another
set's patch gives its version a new identifier, and the preset blocks the
original.

## Writing a Preset

Presets are prewritten and reviewed. Nothing in the tool writes one; a VM records
only which boxes its owner changed, and those compose on top.

`standard` is what every VM gets. Any other preset must be asked for with
`--preset`. Both shipped presets name all nine sets and differ only in their
selection:

```xml
<key>Selection</key>
<dict>
	<key>Kind</key>
	<string>Block</string>
	<key>Patches</key>
	<array>
		<string>kernel-exp-frida_thread_set_state_entitlement_flag</string>
	</array>
</dict>
```

`Kind` is `All`, `Allow` or `Block` — never both lists, because a manifest able to
carry both invites a preset where one silently wins. Use `Block` for "everything
except"; use `Allow` only for a deliberately minimal preset, remembering that a
patch added later will not be in it.

When you add or change a preset plist, mirror it in
`FirmwarePatchSetCatalog` — that Swift copy is what a dev build with no staged
bundle falls back to, and `The shipped preset plists match the built-in copies`
fails if they drift.

### What a VM Records

`fw set-patches` writes `<vm>/PatchSelection.plist`, and is the only writer:

```zsh
vphone-cli fw set-patches lab --preset extended --block kernel-cfw-debugger
vphone-cli fw set-patches lab                       # back to the preset alone
```

Each run writes the whole record, and only differences survive it — an
identifier the preset already agrees with is dropped, so a later preset revision
still reaches a VM whose boxes were never touched. The Launchpad's patch editor
reads `fw patches --json` and writes through this verb rather than touching a VM
bundle itself. Blocking a boot-essential patch is allowed; it warns on stderr.

## Out-of-Tree Patch Sets

**Start from `VPhoneExecutable/VPhoneCommand/VPhonePatchSetExample`.** It is a
complete, building set — one iBEC string rewrite — and the loader tests load it,
so it is kept working. Copy the target, change the identifier, replace the patcher.

An external set is a macOS loadable bundle with the `.vphonepatchset` extension:

```
Mine.vphonepatchset/
  Contents/
    Info.plist                 CFBundleExecutable names the binary
    MacOS/Mine                 exports vphone_patch_set_principal
    Resources/Manifest.plist    what the set declares
    _CodeSignature/             written by `vphone-cli patchset import`
```

Build it against the `VPhonePatchKit.framework` the bundle ships — it is built
with library evolution and ships its `.swiftinterface`, so an out-of-tree set
links against the same copy `vphone-cli` loads rather than statically linking a
second disassembler. The target needs
`LD_RUNPATH_SEARCH_PATHS = @executable_path/../Frameworks` so the framework beside
`vphone-cli` is the one that resolves.

Three things make up the code side, and there is nothing else to implement:

```swift
// 1. The entry point. One exported C symbol, copied verbatim.
@_cdecl("vphone_patch_set_principal")
public func makeMyPatchSetPrincipal() -> UnsafeMutableRawPointer {
    VPhonePatchSetPrincipal.export(MyPatchSet())
}

// 2. The principal, asked for one patcher per component the manifest declares
//    an enabled patch for. The inherited default throws for anything else, so a
//    manifest promising a component the code does not handle is a loud error.
public final class MyPatchSet: VPhonePatchSetPrincipal {
    public override func makePatcher(
        for component: VPhoneFirmwareComponent,
        data: Data,
        context: VPhonePatchSetContext,
    ) throws -> any BufferedPatcher {
        guard component == .iBEC else {
            return try super.makePatcher(for: component, data: data, context: context)
        }
        return MyPatcher(data: data, gate: context.gate, verbose: context.verbose)
    }
}

// 3. A BufferedPatcher per component: `patchedData` is how the pipeline reads the
//    bytes back, and `gate` is how a per-VM checkmark reaches your patch sites.
```

Not `NSPrincipalClass`, even though that is the usual way a loadable bundle names
its entry point. PatchKit is built for library evolution, so a subclass of
`VPhonePatchSetPrincipal` has a resilient superclass and its metadata is realized
at first use, not at image load; the class is therefore not registered with the
ObjC runtime when the bundle is mapped, `NSClassFromString` cannot find it, and
`Bundle.principalClass` silently returns whichever class *was* registered. The
exported symbol has none of that.

`context` carries what the plan resolved: `iOSBase` and `cloudOS`, the `gate`, the
preset's `parameters`, and `verbose`. Ask the gate before you write, never after —
a patch whose records are already in the buffer cannot be turned off.

Set `MinimumPatchKitVersion` to the API version you need. A set requiring a newer
PatchKit than the bundle has is refused with a readable error instead of failing
in the dynamic loader.

Then import it, which is also what signs it:

```zsh
vphone-cli patchset import ./Mine.vphonepatchset   # copies into ~/.vphone/patchsets, ad hoc signs
vphone-cli patchset list                           # and says whether it still matches the import
```

A set straight out of Xcode is *linker* ad hoc signed: the Mach-O has a signature
but the bundle seals no resources, so `codesign --verify` rejects it. Import runs
one `codesign --force --sign -` pass over the bundle, which is what fixes that.
The signature is re-checked from disk at every load, so a set edited afterwards
stops loading until it is imported again.

A preset references one by identifier *and* path:

```xml
<dict>
	<key>Kind</key><string>External</string>
	<key>Identifier</key><string>com.example.patchset.mine</string>
	<key>Path</key><string>/path/to/Mine.vphonepatchset</string>
</dict>
```

Both are required: the manifest found at that path must declare that identifier,
or replacing the file would silently change which patches a preset applies.

Such a preset goes in `~/.vphone/patches_presets/`, not in the bundle: shipped
presets live in a sealed bundle and never reference anything outside it. A user
preset cannot claim an identifier a shipped one already has, so nothing can
redefine `standard`.

**A loaded set patches the boot chain only.** Every declared patch must target a
firmware component; a guest-side target is refused at import, because the guest
half of an install is the privileged step and loads no external set at all.

**Security boundary.** Root `cfw install` loads bundled sets only. An external
set reaches a privileged run only after the Launchpad helper has imported it and
pinned its cdhash. Unsigned or invalidly signed sets are ad hoc re-signed at
import, not at load. Do not add a path that lets root open an arbitrary file.

The honest limit: a loaded set is code in the patching process. The gate is what
makes its patches selectable, and a patcher that ignores the gate applies anyway.
What does hold is the signature check at load and the rule above.

## Checking Your Work

```zsh
# Build
xcodebuild -workspace VPhone.xcworkspace -scheme VPhoneCommand -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeCommand build

# What the catalogue now says
vphone-cli fw patches                 # for a person
vphone-cli fw patches --json          # what the Launchpad editor reads

# The model and catalogue tests
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeCommand test-without-building
```

The suites that must pass: `Version requirements`, `Patch selection`,
`Patch declarations`, `Plan resolution`, `Patch gate`,
`Bundled patch set catalogue`. Reference-fixture suites fail on machines without
`ipsws/ref_extract`; that is an environment gap, not a regression.

Then verify byte-identity for anything you did not intend to change. Patching the
same firmware with the same preset must produce the same bytes, and `standard`
must keep producing what it produced before your change unless changing that was
the point.

Finally: **for any change applying new patches, update
`Research/0_binary_patch_comparison.md`.** That is a standing rule in `AGENTS.md`,
and a new declaration with no research note is an incomplete change.
