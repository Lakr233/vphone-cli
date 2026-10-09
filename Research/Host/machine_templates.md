# Machine templates

A template is a complete machine that boots once, for its setup boot, before
it is frozen, and never after. New machines are cloned
from it with `clonefile(2)` and a new identity (see
[machine identity and clone](machine_identity_and_clone.md)), so a second
machine for the same firmware costs a clone and a few hundred MB of first-boot
writes instead of a 20 GB restore. User-facing behavior is in
[Create and run](../../Documents/Guides/create-and-run.md#templates). What
templates save against the alternatives that were measured, and the build and
clone timings, are in [disk space](disk_space.md).

Code: `VPhoneKit/VPhoneCoreKit/Bundle/VPhoneMachineTemplateKey.swift` (the key,
pure), `VPhoneMachineTemplates.swift` (storage, freeze, adopt, clone, boot
refusal), `VPhoneTemplateSlimmingRequest.swift` (switches to slimming),
`VPhoneTemplateSetupBoot.swift` (the setup boot's steps, against a
`VPhoneTemplateSetupMachine`),
`VPhoneExecutable/VPhoneCommand/VPhoneCommand/VirtualMachine/VPhoneMachineTemplateKeys.swift`
(resolving a key from options or from a machine's records),
`VPhoneTemplateSetup.swift` (the switches, the `vphone-vm` the setup boot
drives over `vphone.sock`), `VPhoneVirtualMachineCreator.swift` (`vm create`)
and `VPhoneVirtualMachineTemplateCommand.swift` (`vm template`). Tests:
`VPhoneKit/VPhoneCoreKitTests/Bundle/MachineTemplate*Tests.swift`,
`TemplateSlimmingRequestTests.swift`, `TemplateSetupBootTests.swift` (the
step machine against a scripted guest).

## Key

Everything a clone inherits and could not change without a restore:

| Field | Source for a create | Source for `adopt` |
| --- | --- | --- |
| device | `VPhoneIPSWCache.guestDevice` of the iPhone IPSW (and `--device`) | `config.plist` `guestProductType` |
| iOS version and build | iPhone IPSW `BuildManifest` | `restore-info.json` `ios` |
| cloudOS version and build | cloudOS IPSW `BuildManifest` | `restore-info.json` `cloudOS` |
| preset | `--preset` | `PatchPlan.plist` `Preset` |
| boot-chain plan digest | the preset resolved against the two versions | `PatchPlan.plist` `EnabledPatches`, `Parameters` |
| bundle series | this `vphone-cli`'s `Info.plist` | `launchpad.json` `bootChain`, else the `Guest` receipt part when `cfw install` wrote it, else this `vphone-cli` |
| disk size (decimal GB) | `--disk-size` | `Disk.img` length |
| slimming: trim, setup boot, service profile, service groups, removed apps | the slimming switches (below); the trim as `VPhoneSystemTrimSpec.keyValue` (`standard/1/en,zh,zh-Hans`) | `Template.plist` steps `vm template trim` and `vm template setup` recorded, else nothing done |
| format version | 2 | 2 |

The identifier is the first 12 hex digits of the SHA-256 of one
`name=value` line per field in a fixed order (`canonicalDescription`); a test
pins one value against `shasum`. Any change to what a field means raises the
format version instead, so old templates stop matching rather than matching
wrongly. Format 2 added `service-groups` (P2's format-1 templates, never
booted, list as stale and still serve `--template <id>` with a warning).

The plan digest hashes the sorted identifiers of the enabled patches whose
catalog target is `.firmware(*)` (AVPBooter, iBSS, iBEC, LLB, TXM, kernelcache,
DeviceTree), plus any enabled identifier the catalog does not know (an
external set's, counted to be safe), and the preset's parameters. Guest
patches are left out: `cfw update-environment` applies them to a clone in
either direction. The preset itself is a field because `standard` and
`experimental` also differ in `guest.identity`, which only a full
`cfw install` writes into Preboot.

Not in the key: CPU, memory, screen, network, unlock at startup. They are
`config.plist` settings that `vm create` sets on the clone.

A machine Launchpad created with boot-chain overrides has a digest of its
own, so it never serves a create without them. Launchpad builds a template
with the boot-chain overrides only and applies guest overrides to the clone
(see Lifecycle), so no template carries a guest override in its
`PatchSelection.plist`. A template's staleness check
re-resolves with the template's own `PatchSelection.plist`.

## Storage

```
<library>/.templates/
  <id>/                       frozen template: a machine folder + Template.plist
  .building-<id>-<uuid>/<id>/ a build in progress, or one that failed
  .lock-<id>                  flock(2) held while <id> is built
```

- Same volume as the machines, so a clone is a `clonefile`; hidden, so
  `VPhoneLibrary.scan` (`.skipsHiddenFiles`) and with it `vm list` and
  Launchpad never list a template.
- `Template.plist`: `Identifier`, `Key`, `Created`, `BuiltWithBundleVersion`,
  `BootChainBundleVersion`, `SourceMachine` (the name a derived mDNS name
  follows from), `Frozen`, `FrozenAt`, `Build` (a UUID set each time a template
  is frozen or adopted), `Steps` (`SnapshotDeleted`, `SetupDone`,
  `ServiceProfile`, `ServiceGroups`, `RemovedApps`, `TrimTier`, and
  `UnregisterAttempts`: the removed apps vphoned had to unregister more than
  once, with the count; not part of the key),
  `Sources` (`IPhone`, `CloudOS`: the IPSW sources a `vm create` build or
  `vm template adopt --iphone-source … --cloudos-source …` named; not part of
  the key). `vm template find` and `vm create` resolve a request's builds
  the same way, without downloading (`VPhoneMachineTemplates.resolveBuilds`,
  `VPhoneMachineTemplateKeys.resolveBuilds`): from the IPSWs when both are
  local files or cached, else from the newest template recorded with the
  same sources (`templates(builtFrom:device:in:)`). A local path that no
  longer exists counts as not here (`VPhoneIPSWCache.localArchive` answers
  nil); a local file that is not an IPSW is still an error. `vm create`
  downloads only when no template matches and it has to build one, so
  Launchpad can offer to delete a template's IPSWs and a CLI create clones
  without them. Until 2026-10-09 `vm create` resolved through
  `VPhoneFirmwarePreparer.resolveSources` first and downloaded both IPSWs
  (about 13 GB) before it looked for a template, and `find` failed with "IPSW
  not found" for a deleted local IPSW (Launchpad 2.9 end-to-end test, B3 and
  B4).
- `TemplateSource.plist` in a machine cloned from a template: `Identifier`,
  `Build` (the template's `Build`), `Cloned`. A plain `vm clone` keeps it
  (the copy shares the template's blocks too); `vm export` excludes it (an
  import shares nothing). `VPhoneMachineTemplates.usage` maps each template to
  the machines (and templates adopted from such machines) cloned from it.
  The identifier alone does not say that: a template deleted and built again
  with the same key gets the same identifier and shares nothing with the
  clones of the old one. A clone counts for a template only when
  `VPhoneMachineTemplateSource.isClone(of:)` says so: both `Build`s equal, or,
  when either side has none (records written before 2026-10-09), `Cloned` no
  earlier than the template's `FrozenAt` (else `Created`). Until then the
  rebuilt template counted the old build's clones as its users, in `vm
  template list/show`, Launchpad's "N machine(s) use it" and the delete notes
  (PR #633 retest, N1). `vm template list/show --json` add `build` and
  `frozenAt`. `vm list --json` and `vm info --json` report each clone's
  `template` and `templateMatch` (`current`, `earlierBuild` or `deleted`,
  `VPhoneMachineTemplates.match`), and Launchpad's inspector shows that
  instead of reading `TemplateSource.plist` and `Template.plist` itself (see
  [Rules Launchpad shares with the CLI](#rules-launchpad-shares-with-the-cli)).
  `vm template list/show` print the users with the template's
  allocated size; `vm delete` of the last machine cloned from the template
  that exists now prints a note to delete it (`unusedTemplate(after:in:)`;
  deleting a clone of an earlier build prints nothing), never deleting it
  itself. `vm template delete` says what the deletion frees
  (`VPhoneMachineTemplates.deletionNote`, from `usage` read before it), from
  facts it has: with machines using the template, it names them and says the
  blocks they share stay allocated until they change them or are deleted;
  with none, "no machine uses it now; deleting frees its blocks (a local Time
  Machine snapshot may keep them until it expires)". It cannot know whether
  the template was cloned before and the clones deleted, so it no longer says
  "no machine was cloned from it", and a local snapshot can keep the blocks,
  so it no longer says "its space is free now" (retest B8). `--json` (with
  `--force`) prints `deleted`, `path`, `machines`, `blocksFreed` and the
  same `note`.
- `vm rebase <vm> --onto <id>` takes a template as the base
  (`VPhoneDiskRebaseBase.resolve`; a machine with that name wins). It only
  reads and clones the template's image, and writes no `TemplateSource.plist`
  into the rebased machine: that machine shares disk blocks but keeps its own
  SEP storage and identity, so `usage` does not count it. Rebasing a clone of
  a template onto that template, or onto another clone of the same `Build`,
  frees nearly nothing; the command notes it and reports such blocks as
  already shared (`F_LOG2PHYS_EXT`, see [disk rebase](disk_rebase.md)).
- A build happens in `.building-<id>-<uuid>/<id>/` and is frozen by writing
  `Frozen = true` and one `renamex_np(RENAME_EXCL)` to `.templates/<id>`. A
  listed template is always complete; a race with another build of the same
  key fails the rename and leaves the build unfrozen.
- `freeze` and `adopt` refuse unless `Steps` produced the slimming the key
  promises, and refuse a trim whose `SnapshotDeleted` is false
  (`VPhoneMachineTemplateSteps.problems`).
- `freeze` and `adopt` remove the restore tree (`iPhone*_Restore`): a template
  never keeps it. `vm create` removes it before the trim whatever
  `--keep-artifacts` says and warns that the flag keeps it only with
  `--no-template`; `adopt` says it removed it.
- A clone drops `Template.plist`, `Snapshots/` and `vphone.sock`.

## Disk use

Launchpad shows each machine's and template's **Exclusive** size beside what
its files allocate (`st_blocks`): the blocks no other machine or template in
its libraries holds, what deleting it frees. `VPhoneLaunchpadDiskMeter`
measures every machine and template folder of every library in one pass
(templates are found as `.templates/<12 hex>`, builds left out): each file's
data ranges come from `SEEK_DATA`/`SEEK_HOLE` and `fcntl(F_LOG2PHYS_EXT)`
(`VPhoneLaunchpadDiskExtents`), and a sweep over the range ends of all
folders, per device, credits a stretch covered by exactly one folder to it.
Blocks a folder's own files share (its `Snapshots/`) count once, as its own; a
file the volume does not map (a compressed one) counts its allocated size.

It does not use APFS's private size (`ATTR_CMNEXT_PRIVATESIZE`), which
Launchpad used at first: a Time Machine local snapshot shares every block
that existed when it was taken, so after each hourly snapshot every machine's
and template's private size read 0 until it wrote again (Launchpad 2.9
end-to-end test, B7), and users read that as "deleting it frees nothing".
Those blocks are freed once the snapshot expires (Time Machine keeps hourly
local snapshots for 24 hours), so the extent comparison counts them as the
folder's own, and the help text says a local snapshot can keep them until
then. macOS has no public per-file "held by a snapshot" figure to show the
difference: `tmutil` and the volume's purgeable size are per volume.

Cost, measured 2026-10-09 on clones of a booted 64 GB sparse machine image
(21.6 GB allocated, 123,030 physical ranges): 0.08–0.11 s to map one image,
3 ms for the sweep over three of them, 0.27 s for a first pass over three
folders, 4 ms for a pass that maps nothing. A file is mapped again only when
its size, mtime or ctime changes; the pass runs off the main actor at most
every 30 s, with a 15 s mapping budget after which the rest is mapped on a
later pass (those folders show no exclusive size meanwhile).

Mapping opens the file (`O_EVTONLY`), and while it is open `lsof` lists
Launchpad for the image. `cfw install` refuses a disk someone holds, and
until the change below `vm stop` signalled every holder (SIGINT, and SIGKILL
to whoever was left at its timeout). The retest of PR #633 (N2) found
Launchpad mapping running machines' images about every 30 s, so a forced
`vm stop` could kill Launchpad. Launchpad therefore opens a machine's files only when
`VPhoneLaunchpadDiskAccess` allows it: no `vm launch` of its own still runs
for the machine (starting, running, stopping), the last `lsof` names no other
process for its disk, and Launchpad has no operation on it (a creation, a
template build, an export, an install or update, a shutdown or stop) or on a
whole library (an import, a template deletion). Templates are opened unless a
library-wide operation runs or a creation is saving or cloning one (below). It asks again right before
each file is mapped, so a machine started during a pass is not opened. Any
other machine keeps the ranges last mapped, and a stopped one is opened only
when a file's size, mtime or ctime changed since then: once after each run.
Launchpad leaves its own process out when it asks `lsof` which machines run.
A `vphone-cli` started outside Launchpad, or a root process `lsof` does not
show to the user, in the ~0.1 s a changed stopped image is being mapped can
still see it held.

What a holder is decides what the CLI does with it
(`VPhoneProcessHolder`, by `proc_pidpath`). Only `vphone-vm` (any copy of the
bundle) and Virtualization's VM service
(`Virtualization.framework/…/com.apple.Virtualization.VirtualMachine`) run a
machine. `vm stop` asks the machine's `vphone-vm` (found by `--config`) with
SIGINT, or, without one, the VM processes holding its disk; after the timeout
it SIGKILLs only VM processes still holding the disk or the `vphone-vm` of
that config, found again so a reused PID is not hit. Any other holder
(Launchpad's meter, Spotlight, a backup tool, a trim or rebase attaching the
image) is named and never signalled. Until 2026-10-09 `vm stop` SIGINTed every
`lsof` holder when it found no `vphone-vm` and SIGKILLed every holder left
after the timeout, so a stop that hit the meter's 0.1 s window could kill
Launchpad (PR #633 retest, N2). `cfw install`, `update-environment` and
`update-kernel` still refuse any other holder, as do snapshot, revert, adopt,
trim and the setup boot (`VPhoneBundleActivity.requireStopped`, over
`Disk.img`, `SEPStorage` and `nvram.bin`): a file another process has open is
not standing still. Their refusals name each holder (`process 900
vphone-launchpad`) and say when none of them runs the VM, so a reader is not
taken for a running machine.

A clone (`vm clone`, and `vm create --template` cloning a template) only reads
its source, so it waits out a holder that runs no machine: while every holder
is such a process and the control socket is not live, each of its two checks
(before and after the copy) asks again every 0.1 s for up to 2 s, then refuses
as before (`requireStopped(_:waitingForReaders:)`). A VM process holding the
source, or a live socket, refuses at once, so a clone still cannot take a
machine that is running or starting; a template is never booted. Writes keep
the strict check. In Launchpad 2.9.0 New Machine failed at its clone step with
"VM '<id>' is in use: … open in process <pid> vphone-launchpad": the adopt
step refreshed the machine list, the meter saw the new template folder, never
mapped, and opened its `Disk.img` just as `vm create --template` checked it;
retrying the step passed at once. Launchpad now also leaves every template
unopened while a creation of its own is at its adopt or clone step
(`VPhoneLaunchpadDiskAccess.templatesMayOpen`, asked before each file as
above), and the wait covers a mapping that was already under way, or another
reader, when the clone starts.

Launchpad judges the holders `lsof` lists the same way
(`VPhoneLaunchpadDiskHolder`, a copy of the `VPhoneProcessHolder` rule, since
Launchpad does not link VPhoneCoreKit; both are tested against one table, see
[Rules Launchpad shares with the CLI](#rules-launchpad-shares-with-the-cli)). Only a VM holder makes a machine
running. Until 2026-10-09 any holder did, so a `tail -f` on `Disk.img` showed
the machine as running and `vphone-launchpad-cli vm start` refused it as
"already running or busy" (PR #633 retest, L1). Any other holder leaves the
machine stopped. It still counts as held for the disk meter
(`VPhoneLaunchpadDiskAccess.isHeld`), and Launchpad refuses `cfw install`,
`update-environment` and `update-kernel` by name before the helper runs them.
`vm list` reports such holders as `diskOpenIn`. A start is not refused, because
`vphone-cli vm launch` does not refuse one either: Virtualization opens the
disk itself. The Launchpad CLI prints a note naming the holder.

Blocks shared with a file outside the libraries (a `cp -c` copy elsewhere)
count as the folder's own; the CLI's `vm template list/show` print only the
allocated size.

### Rules Launchpad shares with the CLI

PR #633 left two rules written twice, once in VPhoneCoreKit for `vphone-cli`
and once in Launchpad: which disk holder runs a machine, and whether a clone
came from the template that has its identifier now. Launchpad does not link
VPhoneCoreKit on purpose. It ships apart from `VPhone.bundle`, works with
every bundle of its series, and drives each machine through the `vphone-cli`
of the bundle that machine is bound to; VPhoneCoreKit is that bundle's
implementation and changes with every bundle build. Linking it (or a slice
of it, through a project reference from `VPhoneLaunchpad.xcodeproj` to
`VPhoneKit.xcodeproj`) would compile Launchpad's build-time copy of the rule
in place of the answer of the bundle it is talking to, and would pull the
kit's package graph (ArgumentParser, libarchive) into Launchpad's build. It
moves the copy into the linker rather than removing it. So, as of
2026-10-09:

- **Template match: asked of the CLI.** `vm list --json` already read each
  machine's `TemplateSource.plist` (`template`), and Launchpad already runs it
  every 5 s for each library. It now also reports `templateMatch`, decided by
  `VPhoneMachineTemplateSource.isClone(of:)` against the template that
  `VPhoneMachineTemplates.template(_:in:)` loads, and Launchpad only decodes
  it (`VPhoneLaunchpadMachine.templateOrigin`). Launchpad no longer reads
  either plist. The copy had already drifted: it took any frozen
  `Template.plist` whose identifier matched its folder, while the CLI also
  requires the key to match and the folder to load as a machine, so a
  damaged template counted as present in Launchpad and as deleted in the CLI.
  A bundle that does not report `templateMatch`, or reports a value this
  Launchpad does not know, leaves the Template row out. 2.9 was not released
  when the field was added, so it is part of the 2.9 series contract
  (`minimumBundleComponents`), not a new series.
- **Disk holder kind: one table, two copies.** Launchpad runs `lsof` itself
  over every listed machine on each refresh, every second while it waits for
  a machine it did not start to stop, and right before an operation that
  needs the disk, and it leaves its own disk meter out by PID. Asking
  `vphone-cli` would add a process and a library-wide `lsof` to every
  `vphone-cli vm list` for a ten-line path test that is a host fact, not bundle data.
  The two copies stay, and both are tested against
  `VPhoneKit/VPhoneCoreKitTests/VirtualMachine/ProcessHolderKinds.json`:
  `LaunchLayoutTests` checks `VPhoneProcessHolder.kind`, and
  `VPhoneLaunchpad/Tests/TemplatesTests.sh` checks
  `VPhoneLaunchpadDiskHolder.runsMachine` (running for `virtualMachine` and
  `virtualizationService`). Changing either copy without the table, or the
  table without both copies, fails a test.

Other places where Launchpad reads the bundle's own files or repeats its
values, found while doing this and left as they are: `config.plist`
(`diskImage` for `lsof`, `guestProductType` with a `FirmwareOriginals`
fallback, read in both `VPhoneLaunchpadMachine` and `VPhoneLaunchpadIPSWCache`),
`restore-info.json` (`variant`, for the unfinished-install check that
mirrors `vm launch`), the `.templates` layout for the disk meter, the
`vm delete` note text (`VPhoneLaunchpadTemplateNotice`), and New Machine's
removable apps and default languages, which repeat
`VPhoneTemplateSlimmingRequest.defaultRemovedApps` and
`VPhoneSystemTrim.defaultKeptLanguages`.

## Never booting once frozen

The P0 measurement: booting a template after clones exist raised one clone's
private bytes from 0.42 GB to 0.80 GB, and every later clone would inherit
that boot's state. Three layers keep a frozen template from booting:

1. `VPhoneLibrary.bundle(named:)` accepts only a machine name (one component,
   no leading `.`), so no verb taking a machine name reaches `.templates`.
2. `vm launch` checks `VPhoneMachineTemplates.requireBootable`.
3. `VPhoneBootCommand.validate`, which `vphone-vm` runs on its arguments,
   checks it too, DFU included: a folder directly in `.templates`, a frozen
   record, or an unreadable one is refused. A machine in a staging folder may
   boot; the setup boot runs there.

A staging machine's control socket,
`<library>/.templates/.building-<id>-<uuid>/<id>/vphone.sock`, is about 125
bytes for `~/.vphone/machines`, past the 104 bytes of `sun_path`.
`VPhoneUnixSocket.withAddressablePath` binds (in `vphone-vm`) and connects
(`VPhoneUnixSocket.connect`, so every host client) through a symbolic link to
the socket's folder inside a fresh 0700 folder under `/tmp`, removed right
after; the kernel follows the link, so the socket is the one at the long path.

## Slimming switches

`VPhoneTemplateSlimmingRequest.resolve()` maps the switches of `vm create`
and `vm template setup` to the key's slimming:

| Switches | trim | setup boot | services | groups | removed apps |
| --- | --- | --- | --- | --- | --- |
| none (`--slim on`) | `defaultTrim`: `standard/1/en,zh,zh-Hans` | yes | trimmed | none | list C (10 apps) |
| `--slim off` | none | yes | none | none | none |
| `--service-profile none` | default | yes | none | none | list C |
| `--remove-apps off` | default | yes | trimmed | none | none |
| `--keep-apps a,b` | default | yes | trimmed | none | list C minus a, b |
| `--accounts-off` | default | yes | trimmed | `accounts` | list C |
| `--trim conservative` | `conservative/1` | yes | trimmed | none | list C |
| `--keep-languages ja` | `standard/1/en,ja` | yes | trimmed | none | list C |

List C: `com.apple.AppStore`, `Home`, `tv`, `news`, `facetime`, `MobileStore`,
`MobileSMS`, `games`, `findmy`, `Passbook` (P0 and P1 verified each stays
removed across a respring and a reboot on 27.0). Camera stays for camera
passthrough checks; Phone lives on the System volume and vphoned refuses it.
Contradictions are refused, all at once: `--slim off` with any slimming
switch, `--accounts-off` without the trimmed profile, `--keep-apps` naming an
app outside list C or with `--remove-apps off`, an unknown or reserved tier
(`aggressive`), `--keep-languages` with a tier that removes no language data,
an unknown profile. `--keep-languages` alone means `--trim standard` keeping
those languages.
`--no-template` takes no slimming switch; `--template <id>` takes them only to
check them against the template.

`trimmed` is the service list measured for the guest's iOS, and vphoned has
one for iOS 26 and 27 (`GuestServiceProfile.supportedMajors`, mirrored by
`VPhoneTemplateSlimmingRequest.trimmedServiceProfileMajors`; see
[`service_trimming.md`](../Guest/service_trimming.md#ios-26)). Elsewhere
`services.profile.apply trimmed` refuses ("No trimmed service list for iOS
25"), which would fail a build at service-profile, after the restore and most
of the setup boot. So `VPhoneMachineTemplateSlimming.fitted(toIOSVersion:)`
turns `trimmed` into `none` on such a version, where the key is made
(`VPhoneMachineTemplateKeys.key`) and in `vm template setup`, and
`--accounts-off`, whose group is part of the list, is refused there before
anything is built. iOS 26 templates had `services none` until the 26 list
existed (2026-10-09); they now take `trimmed` like iOS 27 ones, so their key
changes and a 26 template built before is no longer found for a default
create, only for `--service-profile none`.

`--slim off` still has a setup boot: skipping Setup and waiting for
first-boot work are not slimming. Without them every clone would start at the
Setup screen and write its own first-boot state (P2 measured 3.2 GB per clone
after seven minutes, P0 0.35 GB with a setup boot). It deletes the orig-fs
snapshot too, which is harmless (CFW's rename and `cfw update-environment`
do not use it) and is what lets an offline trim free its space. The sign-in
follow-up daemons stay on with `--slim off`; a template that went through
`setup.skip` has no follow-up item for them to show (P0).

The services the key promises are fixed per template, although vphoned can
switch the profile on a running machine: a clone of a trimmed template starts
trimmed without a reboot of its own, and `services.profile.apply none` undoes
it on that clone.

## Offline trim

Code: `VPhoneKit/VPhoneCoreKit/Bundle/VPhoneSystemTrim.swift` (tiers, the
versioned list, path rules, applying a trim to a volume root by descriptor,
reading the disk layout) and
`VPhoneExecutable/VPhoneCommand/VPhoneCommand/VirtualMachine/VPhoneMachineTemplateTrimmer.swift`
(attach, mount, trim, unmount, detach, record). Tests:
`VPhoneKit/VPhoneCoreKitTests/Bundle/SystemTrimTests.swift`.

List version 1, paths relative to the System volume:

| Tier | Entry | Selection |
| --- | --- | --- |
| conservative | `usr/standalone/update` | its contents (243 MB SU ramdisk, 114 MB baseband firmware) |
| standard | `System/Library/PreinstalledAssetsV2/RequiredByOs/com_apple_MobileAsset_SharingDeviceAssets` | the folder |
| standard | `System/Library/NanoTimeKit/FaceBundles` | its contents |
| standard | `System/Library/LinguisticData` | children `RequiredAssets_<lang>.bundle` whose `<lang>` is not kept |
| aggressive | reserved (other languages' `.lproj`, Health, some fonts) | refused: not validated |

These are the deletions measured and booted on 2026-10-07/08 (see
`Research/Guest/template_snapshot_deletion.md`). Never listed: the dyld
shared cache and its `.symbols` (the CFW cache patcher resolves symbols from
it), ML models, `/Applications`. Changing an entry raises
`VPhoneSystemTrim.listVersion`.

The key value is `<tier>/<list version>[/<kept languages>]`, `none` without
trim. The kept languages default to `en,zh-Hans,zh` (`zh` is the bundle
`zh-Hans` shares); English is always kept. A machine already trimmed takes
only the same trim again, or a heavier tier after `conservative`
(`VPhoneSystemTrimSpec.canFollow`).

How it runs, without root:

1. Refuse a running machine (`VPhoneBundleActivity.requireStopped`), a frozen
   template or a folder directly in `.templates`, and a machine with a
   `TemplateSource.plist` (its blocks are the template's; deleting files would
   free nothing).
2. `diskutil image attach -noMount Disk.img` (`Disk.img` must be a regular
   single-link file, owned by the invoking user under sudo). `diskutil` takes
   no image-class key and needs none: it attaches the headerless image as raw
   and, with `-noMount`, mounts none of its volumes. A failed attach is read
   for a device all the same, and one is ejected.
3. The `Apple_APFS` partition from the attach output (`<device>\t<content>`
   lines; the synthesized container's `Apple_APFS_Container` and
   `Apple_APFS_Volume` lines are skipped), its `APFSContainerReference`
   from `diskutil info -plist`, and the one volume whose `Roles` contain
   `System` from `diskutil apfs list -plist`, after checking the
   container's physical store is that partition. No slice numbers.
4. `diskutil mount -mountOptions nosuid,nodev,noowners,nobrowse -mountPoint
   <mkdtemp 0700 folder in /private/var/tmp>/system <volume>`. A user who
   attached the image may mount it this way; as root it works the same.
5. Pin the mount point by descriptor, check `f_mntfromname` is the volume,
   and refuse unless `System/Library/CoreServices/SystemVersion.plist` exists.
6. Delete each entry through `VPhoneConfinedDirectory`: every component is
   opened `O_NOFOLLOW`, a link on the way or a volume change is refused, a
   link at the leaf is deleted as a link, and each target must pass
   `VPhoneSystemTrimSpec.permits` first. Bytes removed are the `st_blocks` of
   what went, a second hard link counting as nothing; each entry is logged.
7. Unmount (`force` as a fallback) and `diskutil eject` the image's disk (a
   forced `diskutil unmountDisk` and a second eject as the fallback, the form
   macOS 15 also accepts) on every way out, then record `Steps.TrimTier`.

### The snapshot dependency

The trimmed blocks stay allocated until the guest deletes the
`orig-fs.disabled.rn-*` snapshot `cfw install` left; the host cannot (SIP,
`-69863` even as root). Only the setup boot does it
(`apfs.snapshot.delete`). Two rules follow:

- `VPhoneMachineTemplateSlimming.problems`: a key with a trim but no setup
  boot is refused before anything is built. Every key `vm create` resolves
  has the setup boot (`--slim off` included), so this guards keys built by
  hand; `--trim` defaults to `standard`.
- `VPhoneMachineTemplateSteps.problems`: `freeze` and `adopt` refuse a trim
  whose `SnapshotDeleted` is false. Refused rather than warned about: such a
  template costs exactly what an untrimmed one does while its clones have
  lost the files, and its key would promise savings it never made.

### Measured

2026-10-08, iPhone17,3 iOS 27.0 (24A435) / cloudOS 26.4, created by
Launchpad (bundle 2.7.0 local, standard preset) and stopped after its first
boot; `vm template trim p3-src --tier standard` from a build-directory
`vphone-cli`, as the user, no root:

| Entry | Removed | Bytes |
| --- | --- | --- |
| `usr/standalone/update` | 16 items | 361.7 MB |
| `…/com_apple_MobileAsset_SharingDeviceAssets` | the folder | 237.6 MB |
| `NanoTimeKit/FaceBundles` | 76 bundles | 147.9 MB |
| `LinguisticData` | 57 `RequiredAssets_*` bundles (en, zh-Hans, zh kept) | 418.7 MB |
| total | | 1.17 GB |

The run took 4.7 s. `Disk.img` went from 35,977,296 to 35,977,880 blocks:
the snapshot keeps everything, as expected. A second run removed nothing; a
conservative trim afterwards and `aggressive` were refused, and so was
`vm template adopt --force` (trim without snapshot deletion). The machine then
booted through Launchpad to the Setup greeting with vphoned answering and 258
apps registered, no panic. With P4's snapshot deletion the 2026-10-07
prototype returned 1.19 GB for the same deletions
(`Research/Guest/template_snapshot_deletion.md`), and so did a full build's
setup boot, read off the System volume (that note's "Reclaim in a template
build"). Where these paths sit among the System volume's 16 GB, and why the
other large items are never trimmed, is in [disk space](disk_space.md).

`vm delete` of the second of two machines cloned from a template printed
`note: template 2246f982776c (~18.92 GB) is no longer used by any machine; …`;
the first printed nothing, and `vm template list` showed `machines using it:
p3-a, p3-b`, then `none`. The size is the template's allocated bytes,
blocks it shares with other files included.

## Setup boot

`VPhoneTemplateSetupBoot.run()` drives a `VPhoneTemplateSetupMachine`. The
real one (`VPhoneTemplateSetupVirtualMachine`) starts `vphone-vm` the way
`vm launch` does: `requireBootable` (a frozen template is refused),
`VPhoneBundleActivity.requireStopped`, this bundle's vphoned staged,
`VPhoneBootCommand.validate`; headless for `vm template setup` unless
`--window`, windowed in `vm create` like its first-boot check (the template's
setup boot is the guest's first boot). It talks to vphoned through
`vphone.sock`'s `rpc` verb and reads `guest_error`.

| Step | Calls | Deadline | Passes when |
| --- | --- | --- | --- |
| connect | `ping` every second | 300 s | vphoned answers |
| 0 snapshot | `apfs.snapshot.delete {force}` | 120 s | no `orig-fs.disabled.rn-*` in `remaining`/`after` (none to begin with is fine) |
| a skip | `setup.skip {force}`, any refusal retried | 600 s | `setup_done` |
| b settle | `setup.settle {timeout_s ≤ 30}` repeated, a progress line after each | 600 s overall | `settled` (system apps expanded and data migration finished) |
| c apps | `apps.remove_system {bundle_ids, force}` | 300 s | every app `removed`, `absent` or `unregistered_stale` |
| d/e profile | `services.profile.apply {profile, groups, force}`, `services.profile` | 180 s | no `failed`; the record holds `signin_followup` and the extra groups; followupd and appleidsetupd disabled |
| f reboot | `processes.list` (launchd's `start_time`), `system.reboot {force}`, then `ping` and `processes.list` (10 s timeout) every 3 s | 300 s | vphoned answers with another launchd start time |
| f verify | `apfs.snapshots`, `setup.status`, `services.profile`, `apps.list`, `ping`, repeated | 120 s | no snapshot, Setup done, the profile recorded with `running` empty, no removed app listed |
| crash reports | `logs.crashes`, `files.remove {path}` for each report under `/Logs/CrashReporter/` | 60 s | (a warning on failure) |
| name | `device.name.set {}` | 30 s | (a warning on failure) |
| g stop | SIGINT to `vphone-vm` | 60 s | it exits without "turning it off" (the guest shut down within its 15 s) |

`setup.skip` is retried on any refusal: right after vphoned first answers on
a guest that just finished its first boot, it failed with "Cannot allocate
memory". The keys it writes are idempotent.

The setup boot is the guest's first boot, and the first boot's data migration
runs until 60–180 s after the VM starts (`Research/Guest/setup_assistant_skip.md`,
"The first boot after a restore"). Until it ends, SpringBoard has not decided
whether to run Setup, and FrontBoard ignores the request to restart it. Until
2026-10-09 `setup.skip` always restarted SpringBoard. FrontBoard ignored the
relaunch, the `launchctl stop` fallback failed with "144 Requestor lacks
required entitlement", and the step was retried until migration ended. That
took 45–98 s of every build (p4-src 87 s on 2026-10-08; 49, 56, 63, 79 and
98 s in later builds). vphoned now writes the keys and leaves SpringBoard alone
while migration has not finished (`respring: {restarted: false, reason:
"data_migration_pending"}`, logged as `SpringBoard left alone`). SpringBoard
reads the keys when migration ends. The settle step waits for the end of
migration (`data_migration_done`) as well as for the app expansion, so no
later step, and no template frozen from the boot, can come before it. Before
this change, that guarantee was only a side effect of the skip's retries:
`staged_system_apps` empties 26–67 s before migration ends.

This makes the steps report where the time goes, but it does not shorten the
boot. The wait is the migration (`SpringBoard.migrator`, which waits for
PosterBoard's poster migration), and every clone would otherwise repeat it.
Right after it ends, LaunchServices drops 7 records (265 → 258 apps) and
installd works for about 10 s, which the settle window covers before apps are
removed. Measured on `ss-raw` (27.0, never booted, reverted from a snapshot
between runs, 2026-10-09):

| Run | vphoned | setup-skip | settle | VM start → remove-apps | migration end → remove-apps |
| --- | --- | --- | --- | --- | --- |
| A | before | 98 s (11 refusals) | 11 s | 114 s | — |
| A2 | before | 56 s (6) | 10 s | 72 s | — |
| A3 | before | 54 s (6) | 10 s | 70 s | 14 s |
| N1 | after | 0 s | 64 s | 70 s | — |
| N2 | after | 0 s | 80 s | 86 s | 15 s |
| e2e (`vm create`, template 8e02beba26ce) | after | 0 s | 64 s | 69 s | — |

2.9.0 failed every creation on a slower Mac (a MacBook Air, 2026-10-09):
`setup.skip` was refused 14 times and its 120 s deadline ran out before data
migration ended. vphoned now passes the skip at once, and the settle step
waits for migration for up to 600 s, printing `waiting for the guest's
first-boot data migration (N s)` after each call of at most 30 s. The skip's
own deadline is 600 s too: a 2.9.0 vphoned (refused until migration ends)
gets through, and its refusals print `waiting for the guest's first-boot data
migration before SpringBoard can restart (N s)` at most every 30 s instead of
one error line each.

The migration's length varies between runs, and so does the boot. Measured
from the end of migration, the old and the new flow both reach remove-apps
about 15 s later. The reboot step took either about 10 s or about 33 s (4 of 6
runs), with either vphoned. The guest's crash reports show why: a
`panic-full` "initproc failed to start … Library not loaded:
/usr/lib/libSystem.B.dylib … (no such file, no dyld cache)" right at a boot,
after which the VM boots again. It happened on the setup boot's first boot
(N3: a few seconds lost) and on the boot after its reboot (the e2e build: the
33 s reboot). The cause is not known yet. Every run also left `duetexpertd`
crash reports, every 10 s after the reboot ("Failed to initialize datavault
for DuetExpertCenterAsset"), and one `PridePosterExtension` crash during
migration.

Retries: a call that did not reach vphoned (no socket, guest not connected,
timeout) or that vphoned refused with `retryable: true` or `reason: busy`
(`apfs.snapshot.delete` on EBUSY) is repeated every 3 s until the step's
deadline. Other refusals fail the step, except `apps.remove_system`'s
`remove_incomplete`, whose `results` are read: a strict setup boot fails on
any app not removed; a lenient one reports it and leaves it out of the
recorded steps, so the adopted key says what was done. A template build (key
fixed) is always strict, and so is `vm template setup --strict` on a machine
(`VPhoneTemplateSetupPlan.requiresEveryApp`); a strict run also checks, once
the profile is applied, that nothing fell short of the plan
(`VPhoneTemplateSetupOutcome.deviations(from:)`) and fails before the reboot
if anything did.

After the reboot the verify step sometimes finds a removed app listed again
for a few seconds (`removed apps are installed again: com.apple.tv` three
times in one 27.0 build; News and TV for about 6 s on 26.6.2), and the next
poll finds it gone. The step's retries absorb it; a reappearance that lasted
past the 120 s deadline would fail the build.

An app left behind was seen once in two setup boots on 27.0 (2026-10-08,
Find My): "LaunchServices still lists the app after unregistration". icli's
`unregisterApp` looks at the record straight after `icli_unregister_app`, and
LaunchServices had not dropped it yet. The lenient setup boot then recorded
nine removed apps, `adopt` saved the template under a key `vm template find`
never computes for the default options, and every later create with them
missed it and built another 17.5 GB template (B1). vphoned now polls the
record every 0.1 s for up to 2.5 s, unregisters once more if it is still
listed, and only then fails the app (`GuestAppUnregistration`). It
reports `unregister_attempts` for an app that needed more than one call. The
setup boot keeps it (`VPhoneTemplateSetupAppResult.unregisterAttempts`),
prints `  <bundle id>: unregistered after N attempts` in its remove-apps step
and a summary line in its report, and records the counts in
`Steps.UnregisterAttempts`, so the race can be counted from build logs and
`vm template show`. Until 2026-10-09 the count never left vphoned (retest
G1). It does not tell a first check that still saw the app from one that did
not: an app that left LaunchServices while vphoned polled still counts 1. For Launchpad
the setup boot is meant to run with `--strict` and the adopt with
`--expect <id>` (below), so a template is never saved under a key the request
did not ask for.

On any failure the VM is killed, the failure names the step
(`VPhoneTemplateSetupFailure`), and nothing is recorded:
`recordSetupBoot` writes only a complete outcome (`SnapshotDeleted`,
`SetupDone`, `ServiceProfile`, `ServiceGroups`, `RemovedApps`; `TrimTier` is
left to the trim, and the snapshot is gone before the trim's record is ever
checked), so `freeze` keeps refusing the build.

The device name: `vphone-vm` pins the guest's name to the machine's name
(`device.name.set`) on every connect, and the pin lives in
`/var/db/vphone/devicename.plist` on the Data volume. Left in place, every
clone would show the template's name (its identifier, or the adopted
machine's name) until its own VM connects, and its first DHCP lease would
carry it (P1). The setup boot clears it last.

The crash reports: every build's first boot after `cfw install` (the setup
boot) writes a `panic-full-*.ips` of `initproc failed to start … Library not
loaded: /usr/lib/libSystem.B.dylib … (no such file, no dyld cache)`. That
panic is not the setup boot's. The restore reboots into the installed system
before `cfw install` has copied the OS cryptex onto the System volume (vphone
boots without the cryptex graft: every boot logs `cryptex1 sniff: ignition
failed: 8`, then `dyld[1]: ignition disabled`), so launchd finds no dyld
cache and the kernel panics; `vm create` and Launchpad wait for exactly that
panic as the sign that the restore's reboot happened. iOS writes the report
at the next boot, which is the setup boot, and the frozen template then gave
every clone a kernel panic it never had, plus a dozen `duetexpertd` crashes
(below). Matched by boot session UUID on 2026-10-09: `panic-full` reports in
setup-boot and clone crash lists all name the session of the restore's
post-restore boot in the `-dfu.log` (for example `A40A5DEA…` in
`template-0fa581ca-dfu.log`, `AF2B2981…` in `template-9530cc5e-dfu.log`,
written 2 s into that build's setup boot). A no-template machine gets the
same report at its first boot. Console logs of installed guests showed no
`panic(` in any boot: 0 in 35 boots of a trimmed, snapshot-deleted build, 19
of a clone of a fixed template and 24 of a `--no-template` machine, by
`system.reboot` and by `vm stop` + `vm start` (2026-10-09).

After the verify step the setup boot lists the reports (`logs.crashes`) and
deletes each one with `files.remove`; the report says `crash reports
cleared: 13 crash report(s): duetexpertd ×11, SiriSearchFeedback ×1,
panic-full ×1` (2026-10-09 build). A report it cannot delete is a warning, as
the device name is.

The report could be avoided at the source by stopping the DFU VM when iBoot
prints its banner after the restore, instead of waiting for the panic. That
would remove the panic and its report for every machine, `--no-template`
included, and save a few seconds. It is not done: it changes the stop
condition in both `vm create` and Launchpad (which must keep working with
older bundles of its series), and one full creation has to confirm that
nothing required happens in that boot; the logs show only Preboot mounted
before launchd.

The reboot step's 33 s: `system.reboot` is answered at once, and the first
`ping` a moment later can still reach the old vphoned; the `processes.list`
sent after it reaches vphoned as launchd stops it and is never answered, so
`vphone.sock`'s read timeout runs out. With the 30 s it had, the step took
33 s instead of 9–10 s in 4 of 6 builds (2026-10-09), and replaying the same
polling against a running guest hit it in 3 of 8 reboots (33.3–33.5 s). The
poll's `processes.list` now uses `VPhoneTemplateSetupTimeouts.rebootPoll`
(10 s): the same replay took at most 13.3 s, and a fresh boot answers within
a few seconds.

`duetexpertd` crashes about every 10 s from the first boot on every iOS 27.0
guest, template or not (13 reports on a `--no-template` machine with no trim,
no snapshot deletion and no service profile): `EXC_BREAKPOINT` in
`ATXEnableMobileAssetDataVault` (AppPredictionInternal, from
`_ATXInitializeInOwnerProcess`), "Failed to initialize datavault for
DuetExpertCenterAsset". Neither the trim nor the slimming causes it; the
trimmed profile turns `com.apple.duetexpertd` off, so it stops after the
setup boot's reboot. The reports clones used to show were the template's
first-boot ones; a clone of a template built with the cleanup had none after
12 reboots and 6 cold starts. A machine without the profile keeps crashing.

Measured on iPhone17,3 27.0 (24A435), 2026-10-08: Launchpad created
`p4-src` (first boot at Setup), `vm template setup p4-src` took 2 min 16 s
(Setup's restart refused for 87 s, settle 25 s, reboot 10 s, stop 4 s), the
image grew from 16.8 to 19.3 GB allocated. Two clones started through
Launchpad came up at the Lock Screen and unlocked to the Home Screen (with
"Trust This Computer?"), Setup done, 249 apps with the ten gone, 141 services
off and none running, no snapshot, device names `p4-a` and `p4-b`. Private
bytes (`ATTR_CMNEXT_PRIVATESIZE`) of each clone: 0.17 and 0.09 GB a minute in,
0.58 GB after seven minutes, against 3.2 GB for P2's never-booted template.
The template's own private bytes were 0.10 GB, the blocks both clones
rewrote. A Time Machine local snapshot counts as sharing, so measure a file
made after the latest one, as these clones were.

## Lifecycle

- **vm create** (default): key from the options and switches → lock →
  restore and `cfw install` into the staging folder → restore tree removed →
  offline trim (records `Steps.TrimTier`) → setup boot (step 0 deletes the
  snapshot; records `SnapshotDeleted`, `SetupDone`, the profile, groups and
  apps) → recorded key must equal the requested one → `freeze` → clone.
  A failure leaves the build; `vm template setup .building-…` runs the trim
  if the build stopped before it recorded one, retries the setup boot under
  the lock and freezes the build on success.
- **Launchpad** (2.9, `VPhoneLaunchpadCreationPipeline`, steps in
  `VPhoneLaunchpadCreationPlan`) first runs `vm template find --json` with
  the request (IPSW sources, device, preset and boot-chain overrides, disk
  size, slimming switches). A usable template is cloned at once. Otherwise it
  builds one in a temporary library machine `template-<8 hex>`: `vm new`,
  `fw prepare`, `fw set-patches` with the boot-chain overrides only,
  `fw patch`, the DFU restore and `cfw install` through the helper, without
  its own first boot; then `vm template trim <name> --tier …` (left out for
  trim none), `vm template setup <name> --strict [switches]` (headless; fails
  when an app it should remove stays), `vm template adopt <name> --json
  --iphone-source … --cloudos-source … --expect <id>` (the id `find`
  computed, or a second `find` once the restore downloaded the IPSWs; a
  build whose key differs fails the step with the differing fields), then
  `vm create <name> --template <id> --skip-first-boot --cpu … --memory …
  --network …`. When the request has guest patch overrides (the bundle's
  `fw patches` catalog places the patch outside the boot chain), the clone
  then gets `fw set-patches <name>` with every override and `cfw
  update-environment <name>` through the helper's existing verb, before its
  own first boot. An adopt refused because another
  create saved the same key meanwhile falls back to that template and deletes
  the build. The helper's root surface is unchanged: `cfw install` runs on
  the temporary machine, a visible library machine, before it is adopted,
  and the guest overrides go through its existing `cfw update-environment`
  on the clone; trim, setup and adopt run as the user. The setup boot's `vphone-vm` is
  spawned by `vphone-cli`, itself a pipe child of Launchpad like the
  pipeline's DFU boot, not through `vphone-launchpad-launcher`, so Launchpad
  is its responsible process while it runs: a privacy prompt would be
  Launchpad's own (it carries the microphone and location entitlements), and
  quitting Launchpad interrupts the build, which the quit confirmation for a
  running creation already covers. `vm template trim` and
  `vm template setup` on a library machine write an unfrozen `Template.plist`
  (key from its records) when it has none, and record their steps there.
  The setup boot trims nothing: it keeps the tier `vm template trim`
  recorded, and refuses a `--trim` that names another one.
- `freeze` and `adopt` refuse a record whose steps did not produce the key's
  slimming, and a trim whose snapshot was not deleted.
- `vm template adopt <vm> --expect <id>` refuses, before anything moves,
  unless the key the machine's records give hashes to `<id>`, the identifier
  `vm template find` gave the request
  (`VPhoneMachineTemplateKey.mismatch(expecting:known:)`). A hash cannot be
  undone, so the expected key is looked for among the library's templates and
  builds, then among the keys that differ from the machine's only in slimming
  (trim tier, setup boot, profile, groups, any subset of the default apps:
  some tens of thousands of hashes); when found, the refusal names each field
  (`removed apps: expected com.apple.findmy removed too, the machine still
  has it`), otherwise it spells out the machine's canonical description to
  compare with `find --json`'s key. With `--json` the refusal is also printed
  to stdout: `adopted: false`, `error: unexpected_template`, `message`, `id`
  (computed), `expected`, `key`, `expectedKey` (or null), `differences`,
  `canonicalDescription`, `steps`; the exit status is 1.

## Staleness

`vm template list` marks a template stale when any of these holds:

- its series differs from this `vphone-cli`'s (a new series rebuilds);
- its preset no longer resolves, or resolves to another boot-chain digest;
- `FirmwarePatchDrift` finds a boot-chain patch whose receipt part disagrees
  with what the plan wants.

A stale template is never used. Guest-environment updates within a series do
not make a template stale; the clone can take `cfw update-environment`.

## Shared secrets

Every clone of a template shares its SEP root secret, gigalocker, Data/User
volume keys, `mobileactivationd.uuid`, the Data contents the restore wrote and
what the setup boot wrote: Setup done, the keychain items and caches of one
first boot, the removed-app backups and the service record. The setup boot
never pairs a host, signs in or unlocks with a passcode, so no trusted host or
account is shared. `vm create --no-template` builds a machine with secrets of
its own.
