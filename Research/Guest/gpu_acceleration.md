# GPU Acceleration in the Guest

Upstream issue Lakr233/vphone-cli#22 asks two things: why a Metal check run
inside the guest printed `device: (null)`, and why a guest whose apps do get
Metal is still laggy for a while after every boot. This note answers both from
measurements taken on 2026-10-04: macOS 27.0.1 (26A434), Apple M5 Pro,
cloudOS 26.4 (23E5207q) kernel, iPadOS 26.6.2 (23G90) userland, iPad Pro guests
`hz120-ipadpro` and `gpuaccel-ipad`. The measuring method is in
`display_refresh_rate.md`.

## The GPU Is in Use

The guest's Metal device is `Apple Paravirtual device GPU`. Each guest process
that uses Metal has a host `com.apple.gpusw.ParavirtualizedGraphicsGPUTask`
process that replays its commands on the host GPU through the host's own AGX
driver.

The issue's check, extended with a compute pass (a 2048×2048 RGBA16F texture, 64
`sin`/`cos` iterations per pixel) and run as a command-line tool:

| | Guest | Host (M5 Pro) |
| --- | --- | --- |
| GPU time for the pass, warm | 2.3–3.8 ms | 2.0–3.3 ms |
| Empty command buffer, commit and `waitUntilCompleted` | 0.12–0.27 ms | 0.02 ms |
| Compile from source and build the pipeline, warm | 80–220 ms | 265 ms uncached |
| The same, first time in a boot | 4.3–8.3 s | — |

GPU work runs at about native speed. A synchronous round trip costs six to
thirteen times the host's, and the first compile in a boot is slow.

The device reports `MTLGPUFamilyCommon3` and argument buffers tier 1, and no
Apple family or Metal 3. An app that requires those sees a lesser GPU than the
host has.

## `device: (null)` Outside an App

Reproduced on 26.6.2 with the tool run as root from a launchd job:

```
kernel: System Policy: MetalTest(648) deny(1) iokit-open-user-client AppleParavirtDeviceUserClient
kernel: IOUC AppleParavirtDeviceUserClient failed sandbox in process pid 648, MetalTest
MetalTest: Failed to create an IOGPUDevice... IOServiceOpen returned kIOReturn(0xE00002E2)
```

A 26.x sandbox knows nothing of the research board's paravirtual devices. An
app's container profile lets the app open the GPU's user client; the platform
policy every other process falls under does not. So Metal works in apps and in
the system UI, and a daemon or a command-line tool gets no device. The same gate
refused, on the same guest:

| User client | Refused to |
| --- | --- |
| `AppleParavirtDeviceUserClient` (Metal) | the command-line tool |
| `AppleVideoToolboxParavirtualizationUserClient` (video decoder) | `com.apple.WebKit` |
| `AppleVirtIONeuralEngineDeviceUserClient` (Neural Engine) | `spotlightknowledged`, `callservicesd` |
| `IOSurfaceAcceleratorParavirtClient` (scaler) | `vphoned` |

On a 27 base this gate is already off: `kernel-boot-iouc_sandbox_gate` is
boot-essential there, because 27 refuses backboardd its framebuffer. The patch
`kernel-cfw-paravirt_user_clients` makes a narrower edit on a 26.x or 18.x base,
and `standard` turns it on (see "On in `standard`" below). With it, on
`gpuaccel-ipad`, the tool prints `device: Apple Paravirtual device GPU` and the
console holds no `failed sandbox` line at all.

### Narrow by class name

The patch does not flip the whole gate. The deny block ends by logging
`IOUC %s failed sandbox in process %s`, and its first `%s` is the class name —
already in `x0` as a C string eight bytes before the fail-log `adrp`. The patch
overwrites that `ldr Xt, [sp, #imm]` with a branch to a code cave that reads the
first eight bytes of the class name, and branches to the gate's NotPermitted
allow target only when they equal one of four prefixes — `ApplePar`, `AppleVid`,
`AppleVir`, `IOSurfac` (AppleParavirt\*, AppleVideoToolboxParavirt\*,
AppleVirtIO\*, IOSurfaceAcceleratorParavirtClient). Any other class runs the
displaced `ldr` and falls through to the real deny, so every other sandbox denial
stays. The cave's fixed words are verified by clang/as assembly and a capstone
round-trip; the two position-dependent branches come from `ARM64Encoder`. The
anchor is the fail-string xref, the NotPermitted allow target and the deny-entry
`cbnz`, the same three the broad gate uses; the declaration is
`kernel-cfw-paravirt_user_clients` (sites `.redirect` and `.cave`).

Verified on a fresh iPad Pro guest (`narrowtest-ipad`, 26.6.2, both opt-in
patches on): it boots, and a plain command-line tool prints

```
RootDomainUserClient IOServiceOpen -> 0xe00002e2 (denied)
Metal device -> ALLOWED
```

— the paravirtual GPU opens from a daemon context while a non-allowlisted client
is still refused. It first shipped off in `standard`, as a per-VM choice; it is
now on, for the reason below.

What it does not change: HLS video in Safari already played at the stream's
60 frames per second without it, with `mediaplaybackd` at 9% of a core and
`videocodecd` at 4%, so WebKit being refused the decoder is not a visible cost
there.

### On in `standard`

`standard` stopped blocking the patch on 2026-10-04. The case put forward for it
was `cameracaptured`, measured on an iPadOS 26.6.2 guest with the old
`standard`. **Corrected the same day:** the crash below is not the gate
refusing the GPU. `cameracaptured` already has a Metal device (its preload
returns early without one), and it dies on a bug in the paravirtual driver's
heap textures, which the patch does not touch ("Heap Textures Have No CPU
Layout" below). What was observed:

- At every boot it prewarms its capture shaders
  (`FigCapturePreloadShadersInternal` → CMCapture `PrewarmThreadSafeSBPs` →
  NRFV3 `-[NRFProcessorV3 prewarm]`) and dies with SIGSEGV at `0xc` inside
  `AppleParavirtGPUMetalIOGPUFamily`. launchd restarts it, and it crash-loops.
- While it does, the first process to touch the AVCapture defaults blocks on a
  synchronous XPC to it (`AVCaptureProprietaryDefaultsSingleton` →
  `csr_ensureClientEstablished`). When a guest app starts recording, that process
  is SpringBoard: Control Center's sensor indicator builds an
  `AVCaptureDeviceDiscoverySession` on the main thread, and the guest UI freezes.
  `audiomxd`'s recording `StartIO` waits 18 s on the same path, and the first
  recording after boot fails.

What stops the crash is `libvcamcaptured` skipping that prewarm, below. The
patch stays on in `standard` for what #22 asked: a daemon or a tool on a 26.x
or 18.x guest gets the GPU and the other paravirtual devices an app already
reaches.

**What this widens.** The edit is at the IOUserClient sandbox gate only. A
process whose own sandbox profile refuses `iokit-open-user-client` for a class
whose name begins with `ApplePar`, `AppleVid`, `AppleVir` or `IOSurfac` is now
let through that gate; every other class is still refused there. The checks a
driver makes itself (entitlements in `newUserClient`, its argument validation)
are untouched; the MACF check before this gate was already opened by
`patch_iouc_failed_macf` (JB-10). The match is on the first eight bytes of the
class name, so it admits every class with one of those prefixes, not only the
four named in the table above: on this research board that means the
paravirtual GPU and device clients (`AppleParavirt*`), the paravirtual
VideoToolbox decoder (`AppleVideo*`), the VirtIO drivers (`AppleVirtIO*`, among
them the Neural Engine) and IOSurface's clients (`IOSurface*`, the root
client as well as the paravirtual accelerator). Who gains: daemons, command-line
tools and system XPC services that run under the platform profile or a profile
of their own — `cameracaptured`, `com.apple.WebKit` processes,
`spotlightknowledged`, `callservicesd`, `vphoned`, and anything a researcher
runs from a shell or a launchd job. Apps gain nothing: their container profile
already opens these devices. On which bases: 26.x and 18.x. On 27 the patch
skips by version, because the boot-essential `kernel-boot-iouc_sandbox_gate`
already opens every user client there, so a 27 guest is unchanged.

**Why that is acceptable for `standard`.** These are research VMs, already
running with the sandbox hooks stubbed and the trust cache admitting anything;
this gate is what still stopped a daemon from opening a device an app opens
freely. The devices are the guest's own paravirtual hardware, their host side
is a per-VM ParavirtualizedGraphics task or the VM process, and every app on the
guest already reaches them, so the attack surface they expose is already
exposed. The narrow patch is still the right shape on 26.x: the broad
gate-off would open `RootDomainUserClient` and every other client too, which
nothing here needs.

A VM that wants the old behaviour unticks the patch
(`vphone-cli fw set-patches <vm> --block kernel-cfw-paravirt_user_clients`) and
re-patches.

The patch was introduced opt-in as `kernel-exp-paravirt_user_clients` and renamed
`kernel-cfw-paravirt_user_clients` when `standard` turned it on, as the naming
rule in `Skills/authoring-patch-sets/SKILL.md` requires. A VM whose
`PatchSelection.plist` still names the old identifier gets `unknownPatch` from
`fw patch` until that entry is removed.

## Lag After Every Boot

Home Screen page swipes on `hz120-ipadpro`, by time since the VM started:

| Since start | On time | Hitches | Host shader compile | Busiest guest processes |
| --- | --- | --- | --- | --- |
| 7 s | 84% | 14 | 59% of a core | dasd 53%, SpringBoard 35%, backboardd 28%, MTLCompilerService 22% |
| 54 s | 89% | 1 | 1% | SpringBoard 25%, backboardd 17% |
| 85 s | 98% | 3 | 0% | backboardd 28%, SpringBoard 28% |

That is the lag the issue describes: after-boot work in the guest plus shaders
being compiled again, gone in about a minute and a half.

The shaders are compiled again because the host's shader cache is never hit.
Opening four apps that had all been opened in earlier boots cost 1.40 CPU-seconds
of host `MTLCompilerService` the first time after a restart and 0.19 the second
time in the same boot.

### Why the cache misses

By default, Virtualization gives ParavirtualizedGraphics a cache directory per VM,
`$DARWIN_USER_CACHE_DIR/com.apple.paravirtualizedgraphics-<number>`, and each
host GPU task keeps its Metal function cache in a `task-<key>` directory under
it. The vphone launcher now keeps a durable copy in the machine folder
(see "Cache location and migration" below). The historical observations here
predate that relocation. `-[PGRemoteTask calculateCachePathAndExtension:taskRoot:]` picks the key:

- when the device's feature byte `0x36` is set, it reads 60 bytes of the guest's
  task root page and takes the 20 at offset `0x28`; if they are not all zero,
  the key is those 20 bytes in hex, 40 characters;
- otherwise the key is ten random bytes, 20 characters.

Across every VM and every boot on this Mac — 1823 task directories — the name is
20 characters, the random form. Not one is keyed. So the keyed branch is never
taken here, for any guest, which matches the feature byte being off:
`-[_PGDevice features]` returns the struct inline at device `+0x4e4`, and byte
`0x36` of it (device `+0x51a`) is what gates the read. The guest side has nothing
to offer it either: the AppleParavirt kext's task-root setup makes no use of a
cdhash or any 20-byte identity (its code-signing strings are XNU's, not the
kext's).

So this cannot be fixed by a guest firmware patch, which is the only thing
`fw`/`cfw` produce:

- The cache that misses is the **host's**, kept by `PGRemoteTask` in the VM
  service's address space.
- Whether it is keyed is decided **host-side** by that feature byte, which is off
  on this ParavirtualizedGraphics version and is not something the guest is seen
  to switch.
- Even with the feature on, the key is read from the guest's task-root page, and
  giving the guest driver code to populate it would be new kext code — but it
  would still only matter if the host read it, which it does not.

**Correction (2026-10-19):** the guest does switch that byte. It is
supportsTask3, set by the binary version the guest kext negotiates, and a
kernel patch can ask for it. See "The keyed host cache: binary version 252
(Task3)" below. The rest of this paragraph predates that.

Reaching the host cache would mean changing the host ParavirtualizedGraphics
framework. That is Apple's code on the sealed system volume, and the shipped
bundle runs only system libraries, so it is out of scope. The post-boot
recompile is therefore a limitation of the host paravirtual GPU, not a guest
patch we can write. (A per-app `MTLBinaryArchive` inside a guest app would
persist that app's own pipelines, but that is an app change, not a VM one.)

### Seeding the cache from the host (2026-10-18)

The section above concluded that only Apple's framework could fix the misses.
The cache is plain files in a user-owned directory, so a host process can write
into it before a task opens it. That works. A seed is safe only when it holds
what **the same guest process** compiled in an earlier boot. A seed that mixes
entries from several processes hangs the guest GPU. The safe form works, but
it buys little: about two points of on-time frames. So nothing ships.

Measured on `Lychee` (iPhone, iOS 27.0.1, cloudOS 26.4 (23E5207q) driver,
macOS 27.0.1 host, bundle 2.10.1).

#### What the host checks on a hit

`-[ParavirtualizedGraphicsGPUTask handshakeWithTaskRoot:…cachePath:cacheExtension:reply:]`
in `com.apple.gpusw.ParavirtualizedGraphicsGPUTask` consumes the sandbox
extension and calls `MTLSetShaderCachePath(cachePath)`. Without a path it sets
`FS_CACHE_SIZE=0`. Everything after that is Metal's ordinary per-process
function cache, `MTLCompilerFSCache` under `MultiLevelBinaryFSCache` in
`Metal.framework`. PG adds no format and no check of its own.

`MTLCompilerFSCache::getElementImpl(MTLUINT256_t, void**, size_t*)` looks up the
key, requires the entry to be longer than 64 bytes, and compares the first 32
bytes with `SHA-256` of the body and the next 32 with the key it asked for. A
mismatch calls `invalidateCache()`, and a match returns the body. That is the
whole check. Nothing on a hit names a process, a device or a driver. A
well-formed entry is used as it is, whatever task wrote it.

PG then builds the pipeline with
`newComputePipelineStateWithDescriptor:options:0 reflection:nil error:`, after
`setResourceIndex:` and `setForceResourceIndex:YES` from the guest's command.
On failure it logs `Failed to create compute pipeline: …` to its host log.

#### File layout

- `com.apple.paravirtualizedgraphics-<ecid in decimal>/task-<random>/<arch>/functions.{list,data}`,
  `<arch>` being `16777235_530` here. A task's directory goes away when its
  process exits. The framework leaves a directory that no task owns where it
  is: ten made by earlier experiments outlived many boots.
- `functions.list`: a 32-byte constant header, then for each entry its fields
  and its key, then 8 zero bytes. The first entry's fields are `u32` tag, `u64`
  0, `u64` size, `u64` offset; the others' are `u64` 0, `u64` size, `u64`
  offset. A key is 32 bytes and comes *after* its entry's fields.
- `functions.data`: the entries, 8-byte aligned, padded to a multiple of 64 KiB.
  An entry is `SHA-256(body)`, its own key, then the body. `size` counts all
  three.
- Bodies are of two kinds. A Mach-O (`feedfacf`) holds an AGX binary with
  `__TEXT,__text` and `__GPU_METADATA`, `__GPU_LD_MD`, `__GPU_STATS_MD`,
  and the rest. A blob starting `ef13c710` carries argument names
  (`mvp_matrix`, `view_matrix`, `Params_t`…), which looks like reflection.
  These are the "pairs" seen earlier. In the 656-entry task, 400 are Mach-O
  and 256 are blobs.

#### Why a mixed seed breaks

The same key holds different bytes in different processes. Every
cross-process difference found (44 shared keys over six tasks of one boot)
falls in one of three places:

- `__GPU_STATS_MD`: the compile time. Harmless.
- One `u32` in `__GPU_LD_MD`, in the record `0x0c, 0x10, ID, 0, 0, len, name`
  (the name being the AGX function's, such as `fca15dhmha4` or `eot`). In one
  task the ID follows the order of compilation: entries 29 to 43 carry 29 to
  43. Each binary therefore embeds a per-process compile counter.
- One or two words in the reflection blobs (for example 121 against 123).

Rewriting every Mach-O ID to `1000000 + n`, with the SHA-256 recomputed, did
**not** stop the failure on its own. The ID is not the whole story, and what
else ties an entry to its process was not pinned down.

The failure itself, now with both logs:

- Host (`log stream` for the GPU task and `MTLCompilerService`): every compile
  in backboardd's task succeeds, and no `Failed to create compute pipeline`
  is logged. `downsample_4_compute` is never sent to the compiler: it is a hit.
- Guest (`logs.syslog` for backboardd, taken while Camera launches): within
  about 2 s, backboardd's CoreAnimation command buffers end with
  `Caused GPU Hang Error (00000003:kIOGPUCommandBufferCallbackErrorHang)`.
  The GPU restarts, and only then does the next `newComputePipelineState…`
  fail. That failure is the `Compilation failed` abort in
  `CA::OGL::MetalContext::get_compute_pipeline` under
  `BlurStateCompute::downsample_box_4`.

So a hit is not rejected. It is *executed*, and the binary from another process
hangs the GPU. The ddmin pair from earlier, list positions 34 and 35, turns out
to be AGX's own blit kernel `blit_uber_buf_to_tex_uint`, not a CoreAnimation
kernel. The oracle was also flaky. Neither result was worth chasing.

#### Seeding a task with its own entries

The first task the guest creates after start, about 7 s in, is backboardd's.
That is its render server: a backboardd crash takes down that host task.
`prefill` here fills only that task's directory, with the files the same task
had at the end of the previous boot.

| Seed for backboardd's task | Boot, unlock, launch Camera | Result |
| --- | --- | --- |
| Its own files from a previous cold boot | 3 runs | 0 restarts each |
| The `boot1` union of every task | 2 runs | 14 and 393 restarts |
| The `boot1` union with every ID rewritten | 1 run | 105 restarts |

The full test then ran as three pairs: a cold boot, then a boot whose backboardd
task was seeded with that cold boot's backboardd files. Each boot launched all
eleven apps, Camera included. Compile CPU is the per-process delta of host
`MTLCompilerService` CPU time across the workload.

| Run | GPU restarts | New backboardd / cameracaptured crashes | Host compile CPU | Compiles, all (backboardd) |
| --- | --- | --- | --- | --- |
| cold 1 | 0 | 0 | 3.86 s | 640 (374) |
| seeded 1 | 0 | 0 | 1.58 s | 270 (4) |
| cold 2 | 0 | 0 | 3.76 s | 632 (373) |
| seeded 2 | 0 | 0 | 1.58 s | 273 (7) |
| cold 3 | 0 | 0 | 3.89 s | 640 (374) |
| seeded 3 | 0 | 0 | 1.82 s | 313 (27) |

These runs also reported frame pacing. Those numbers are void, for two
reasons. They came from `AppUsage.lastSubmittedTime` of the host task's
`AGXDeviceUserClient`, which was later seen not to move at all during
animations. And the workload's `{"t":"home"}` is not a command
(`unknown command: home`; the home button is `{"t":"key","name":"home"}`),
so the apps opened on top of each other and the stores never held the
go-home animation.

Two more seeded runs went wrong because the harness picked a leftover union
directory instead of backboardd's task. They gave 1010 restarts each, which
confirms the mixed case once more.

#### Where the first-use lag is

The complaint, reproduced: after a boot, opening Settings and going home is
choppy, and it smooths out after a few rounds. Frames here come from the guest:
a launchd job polls QuartzCore's exported `CARenderServerGetFrameCounter(0)`
every 0.5 ms and logs each change. Lychee renders at 60 Hz (gaps cluster at
14–17 ms). "On time" is a gap of 20 ms or less. Each window is the 3 s after
`apps.launch` of Settings (open) or the home key (close), five rounds, starting
about 14 s after the VM is up.

| Window | Cold A on time (bb compiles, Settings compiles) | Cold B | backboardd seeded from cold B |
| --- | --- | --- | --- |
| open1 | 69.8% (29, 23) | 68.3% (31, 20 in open2) | 75.6% (0, 15) |
| close1 | **36.1%** (57) | **43.6%** (61) | **38.1%** (0) |
| open2 | 76.1% (19) | 51.1% (20) | 81.6% (0) |
| close2 | 80.0% (2) | 73.3% (1) | 74.4% (1) |
| open3–5 | 83–86% | 78–87% | 80–86% |
| close3–5 | 79–84% | 69–77% | 70–78% |

Seeding backboardd's host task removed every **host** compile, and the first
go-home was still as choppy (38%). There is a second compile stage, in the
guest, and that is where the remaining first-use cost sits.

#### The guest's own shader cache is thrown away at every boot

Per round, on a cold boot (guest `processes.list` CPU at each window edge, host
`proc_pid_rusage` of the VM service and the GPU tasks): the first go-home differs
from later ones in one way only. The **guest's** `MTLCompilerService` takes
0.41 s of CPU there (0.49 s in open1, 0.15 s in open2, then nothing), while
SpringBoard and backboardd use the same CPU in every round. Host disk reads of
`Disk.img` are negligible. Its log (`logs.syslog` for `MTLCompilerService`)
shows the work is all for backboardd: over three rounds, 71
`MTLSpecializeFunctionToArchive` requests (820 ms) and 90 `MTLBuildFunctions`
(189 ms), on every boot.

Why the guest compiles at all, and why it starts over at each boot:

- CoreAnimation normally renders from precompiled pipelines in
  `MTLBinaryArchive`s. On the paravirtual GPU, backboardd logs `Precompiled
  pipelines disabled on unsupported hardware.`, so every pipeline is built at
  run time, on its render thread.
- backboardd does keep a Metal cache. `StartWindowServer` calls
  `MTLSetShaderCachePath` with its system container's Caches
  (`/private/var/containers/Data/System/<uuid>/Library/Caches`, holding
  `functions.{list,data}` and `32023/libraries.*`). Within one boot it works: a
  backboardd killed and relaunched compiles nothing.
- Across a boot it does not. The cache key is constant: the driver's
  `-[AppleParavirtDevice setupCompiler]` passes `cacheUUID` = SHA-256 of its
  own build date, and Metal mixes in only its build stamp. But
  `libCoreFSCache.dylib` writes `kern.bootsessionuuid` into the head of
  `functions.list` (bytes 4–39, after the magic `45 36 27 18`). At open it
  resets a cache stamped by another boot. Seen directly: the header went from
  `96E73E64-…` to `30366BEF-…` with the boot session, and `functions.list`
  from 19,372 bytes to 1,004. A clean `system.shutdown` changes nothing.
  Every guest Metal cache follows the same rule, SpringBoard's and the apps'
  (`/var/mobile/Library/Caches/<bundle id>/com.apple.metal`) included.
- `libCoreFSCache` reads `FS_CACHE_REUSE_ON_REBOOT`. With it set, a cache from
  another boot is kept. Verified without rebooting: write a foreign UUID into
  the header and relaunch backboardd. Without the variable the cache resets
  (19,260 to 5,932 bytes). With it set through `launchd.setenv`, nothing
  changes (19,148 bytes, foreign header kept) and backboardd compiles 2
  functions in the guest instead of 92.

  **2026-11-03 correction:** on the measured iOS 26.6.2 base the same env=1
  branch also skips the 32-byte compiler cache key, not just the 64-byte
  boot/system stamp. Therefore a compiler update can retain stale shader
  output even after its key changes. The native GLES cache repair keeps the
  key comparison on the reuse path and derives the driver's key from the
  installed plugin; see [Native GLES semantics](#native-gles-semantics).
  The measurements above establish cross-boot reuse but did not test compiler-version changes.

Effect on the first go-home, five Settings rounds after a backboardd relaunch
with a foreign UUID in its cache (a stand-in for a boot):

| Guest cache | Host cache for backboardd's new task | Runs | close1 on time | Guest compiles for backboardd |
| --- | --- | --- | --- | --- |
| reset (today) | cold | 3 | 50.9 / 50.0 / 51.9% | 92–93 |
| reused | cold (about 120 host compiles) | 2 | 56.4 / 56.9% | 2–3 |
| reused | seeded with its own files | 2 | 65.3 / 71.4% | 0–2 |

Later go-homes run at about 78–83% on time in every mode, and no run had a GPU
restart. Fixing both caches makes the first go-home better than any cold one,
and it is the only combination that does. It is not yet as smooth as a warm
one. Settings' own first open still compiles about 20 functions on the host.

What setting the variable at boot takes:

- iOS launchd ignores `/private/var/db/com.apple.xpc.launchd/config/system.plist`
  `EnvironmentVariables` (tried: not applied, cache reset). `launchd.setenv`
  lasts only until the next boot.
- So the variable comes from SystemHook (`VPhoneGuestComponents/SystemHook`),
  which is inserted into every spawn. Its constructor calls
  `setenv("FS_CACHE_REUSE_ON_REBOOT", "1", 0)` first, before the xpcproxy,
  `DISABLE_TWEAKS` and per-daemon early returns, and before any Metal code in
  the process runs. It does so only while `/usr/lib/vphone-metal-cache-reuse`
  exists. That marker is the patch `system-systemhook-cfw-metal_cache_reuse`
  (Guest System set, on in `standard`, off for Apple TV): `cfw install` and
  `cfw update-environment` write it when the patch is selected and remove it
  when it is not. A SystemHook without the marker behaves as before.
- The host half is the backboardd-only seed above, with the same caveat: it
  relies on backboardd's task being the first one created. It is not part of
  this patch.

#### Real reboots with the patch (2026-10-19)

`Lychee` again, now on a local 2.10.1 build with the patch. Each run is a real
reboot: vphoned `system.shutdown`, then `vm start`, unlock, 10 s, then five
Settings rounds measured as above (guest `CARenderServerGetFrameCounter`
probe, 3 s windows, on time = gap of 20 ms or less). Guest compiles are the
`Compilation SUCCESS (ParentProcessName=backboardd…` lines in `logs.syslog` for
`MTLCompilerService` over the rounds. The header is bytes 4–39 of backboardd's
`functions.list` in its system container. The host cache was cold in every
run. GPU restarts are the `Trying to restart GPU` lines in that boot's
`Lychee.log`.

| Run | Bundle | Header after boot | `functions.list` before shutdown → after boot | backboardd guest compiles | GPU restarts | close1 on time | close2–5 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| base1 | 2.10.1 | new | 10,356 → 10,804 | 142 | 0 | 30.4% | 67–90% |
| base2 | 2.10.1 | new | 19,372 → 10,692 | 146 | 0 | 31.7% | 66–86% |
| new1 | patched | kept | 6,156 → 8,844 | 159 | 0 | 31.8% | 62–93% |
| new2 | patched | kept | 19,204 → 19,316 | **0** | 0 | **43.9%** | 67–90% |
| new3 | patched | kept | 19,316 → 19,316 | **0** | 0 | **37.3%** | 63–89% |

- The cache now outlives a reboot: the header stays `8A5597B7-…` through three
  boots and the file keeps its size, where every unpatched boot writes a new
  boot UUID and starts again from about 10 KB.
- new1 compiled as much as a cold boot because the boot before it was the
  first with the variable and did no rounds, so its cache held 6 KB. From then
  on (new2, new3) backboardd compiles nothing in the guest during the rounds,
  and `MTLCompilerService` logs nothing at all.
- The first go-home rises from about 31% to 37–44% on time. That is less than
  the 51% → 56% the fake-boot stand-in predicted for the guest cache alone
  (from a lower starting point here: a real boot has more going on in its first
  minute than a relaunched backboardd). Later rounds are unchanged. The rest
  of the first go-home is the host cache, which still recompiles at every boot.
- Installing it here: Lychee had no restore tree for `cfw install`, and
  `cfw update-environment` refused to run with less than 50 GiB free on the
  volume (17 GiB). The new SystemHook reached the guest through vphoned's live
  environment sync at `vm start`, and the marker was written with vphoned
  `files.write`, i.e. the bytes the installer writes, not the installer itself.
  The installer step is unchanged code in the same shape as the persona-lookup
  marker next to it, and is not exercised by this run.

#### Verdict

- Per-process host seeding is safe in every run made: eleven with Camera or the
  Settings loop, three of them with all eleven apps.
- Neither cache alone fixes the first-use lag. The guest's Metal cache, reset at
  every boot through `kern.bootsessionuuid`, is half of it. The host's per-task
  cache, emptied with every task, is the other half. With both kept, the first
  go-home goes from about 51% to 65–71% on time.
- The guest half is an environment variable that Apple's own library honours,
  and it reaches every process. It ships as
  `system-systemhook-cfw-metal_cache_reuse`. On real reboots it keeps the
  guest cache and removes every guest compile, taking the first go-home from
  about 31% to 37–44%. The host half rests on the first-task assumption
  described above and does not ship.


The tools for these runs were scratch code outside the repo: a cache dumper, an
ID rewriter, the guest frame-counter job (C, built with `xcrun -sdk iphoneos
clang`) and zsh drivers. The method to repeat: watch the guest log for `Trying
to restart GPU` and capture backboardd's syslog while Camera launches. A result
without the restart count is worthless, and so is one that stops before Camera.

#### The keyed host cache: binary version 252 (Task3), 2026-10-19

The host half can be fixed the way Apple designed it: a task cache named after
the guest process, which therefore persists, instead of one named at random.

Where the feature byte comes from. `-[_PGDevice setBinaryVersion:]` fills the
host's `APVFeatures` from the version the guest kext asks for
(`getAPVFeaturesForVersion`, a ladder reached through a jump table for versions
200–252). Field names from the ivar's type encoding in the GPU task binary:

| Offset | Field | First version |
| --- | --- | --- |
| `0x33` | supportsMultipleDisplays | 245 |
| `0x34` | supportsDisplayBrightnessCaps | 250 |
| `0x35` | supportsHDRContentHeadroom | 251 |
| `0x36` | supportsTask3 | 252 |

The host logs the request: `Guest requested binary version: 245, setting
binary version to: 245` for the cloudOS 26.4 kext.

What 250–252 change on the host (macOS 27.0.1), from every read of those bytes:
`0x34` only in `-[_PGDisplayNub testUpdateBrightnessCaps:]`; `0x35` nowhere
found; `0x36` only in `calculateCachePathAndExtension:`. The GPU task process
reads its copy of the struct in one place, the handshake, and only
supportsArgumentBuffers. The version itself (`_binaryVersion`, `+0x4e0`) is
read only for MMIO readback and suspend/resume.

The guest side, in AppleParavirtGPUIOGPUFamily (cloudOS 26.4):

- `setupVersion` writes its version to device register `+0x34`, reads back what
  the host granted, and builds its own feature table from it. That table stops
  at 245, so a granted 252 is invalid to the guest and it steps back down.
  Nothing else in the kext reads the stored version (`+0x51c`).
- Each task's root page is a fresh 16 KiB buffer. The kext writes a 40-byte
  header (`0x00`–`0x27`; the word at `+4` is 2), and bytes `0x28`–`0x3b`, the
  ones Task3 reads as the key, stay zero.

Phase 1, `kernel-exp-paravirt_gpu_task3`: the request becomes 252 and the
guest's features are computed from its original 245. Verified on `Lychee`
(installed with `cfw update-kernel`): the host logs `Guest requested binary
version: 252, setting binary version to: 252`, 0 GPU restarts, Settings opens
and closes normally, and task directories still have 20-character random names,
because the key bytes are zero. On its own it changes nothing visible; it is
the switch the identity write needs.

#### Task3 executable identity implementation, 2026-10-20

Phase 2 extends the same opt-in declaration with `.identity_hook` and
`.identity_code`. All four sites are discovered and encoded before any write;
an unresolved site aborts a selected Task3 operation. Initially opt-in under
`kernel-exp-paravirt_gpu_task3`, it was tested with Lychee explicitly enabling
it. Standard now enables it under `kernel-cfw-paravirt_gpu_task3`; see the
preset promotion below. Runtime coverage is still one host/guest combination.

The key is the owning executable's **20-byte code-signing cdhash**. It is neither
a process name nor a PID, and it is obtained from the task recorded by the GPU
task's superclass, rather than `current_proc()`. Concurrent tasks for the same
executable intentionally share an identity; different executable builds have
different identities. A missing proc or cdhash leaves twenty zero bytes, which
retains the host's ephemeral fallback. No host cache files are mixed or copied.

Reveal procedure (cloudOS 26.4 `kernelcache.research.vphone600`, XNU
12377.100.591.502.1, UUID `784F88D3-2AF5-3D4A-AB00-365607646E44`):

1. Anchor the GPU task initializer with `Failed to create Page Table Lock`.
   Its root header tail has stores at offsets 8, 16, 20, 28 and 36; hook the
   descriptor load immediately after that tail, before descriptor preparation
   and host task registration. Observed initializer `0xfffffe0007ec6b54`, hook
   `0xfffffe0007ec6e18`, root pointer x8, self x19, displaced
   `ldr x0,[x19,#0x228]`. The allocation is a fresh 16 KiB page, although its
   header view is 40 bytes; the host separately reads 60 bytes for Task3. The
   matcher follows the sized allocation's saved return into the same descriptor
   ivar and requires at least 60 bytes of backing storage.
2. Follow the initializer's superclass vtable call, checking that it receives
   the original x2 task argument. In `IOGPUTask::init` at
   `0xfffffe00085df244`, the task is retained and stored at self+0x28. Derive
   this displacement from the store of the saved incoming task argument; it
   is not an assumed IOGPU or XNU structure layout.
3. Anchor `flow_divert_get_app_data` with `(%u): failed to get the cdhash`.
   The call whose null result reaches that log, followed by the 20-byte CDHASH
   TLV append, identifies `cs_get_cdhash` at `0xfffffe0009199c4c`. Its body
   matches `bsd/kern/kern_cs.c`: CS_SIGNED test, authenticated text-vnode load,
   `ubc_cs_blob_get`, null check, pointer to the blob's cdhash. It returns a
   pointer, not a copied hash.
4. That same caller's `proc_task` sequence reveals the `proc_struct_size`
   global (`0xfffffe00096f94b0` in this image). Find the inverse getter through
   references to that global: subtract it from incoming task, validate the
   proc zone, test `TF_HASPROC` (0x00800000), return proc or null. This is
   `get_bsdtask_info` at `0xfffffe0008d7f140`, matching
   `osfmk/kern/bsd_kern.c`. It is a leaf without a PAC prologue, so a generic
   preceding-PAC function finder is unsuitable for this helper.

The trampoline clears the key, saves x0–x18 and LR in a 160-byte aligned stack
frame, calls both helpers with null checks, copies exactly five 32-bit words to
root+0x28, restores registers and SP, replays the descriptor load and resumes.
The original next block does not consume incoming NZCV before its virtual
descriptor call. No original header bytes are changed. Kernel addresses above
are research observations only; the patch uses Capstone operands, in-image
xrefs and decoded kernelcache rebases, without these addresses or offsets.

REA/Hopper evidence: task initializer
`ev_97a491f7966123b66da8c5af9fa362bff268001ed04d1852c8d29f0131e0852e`,
flow-divert caller
`ev_bf9605f45f5e2ee44e2ec3ffad5da9c09169a458c131844a3a8f566c681865fb`,
cdhash getter
`ev_ca619a3011ec225a768642db3ad6537ef2258616da2141359e3dcb838d46b707`.
Kernel collection SHA-256
`86895a2eebeb7fcfb68bcd60f2d7e685687faea07ee31166fb58c872b38e0d92`.
The symbol database's linked JSON dumps are absent in this checkout; no
external symbol dump is required by the implementation. Hopper merged some
neighboring functions; bounded Capstone disassembly established actual entry
points. Static evidence establishes code behavior, not runtime cache reuse.

Validation procedure: encoder parity against Keystone 0.9.2 and Capstone,
fixture discovery and no-write failure tests, trampoline execution with
deliberately clobbered volatile registers, then install with `cfw update-kernel`.
On Lychee, verify version 252, persistent 40-hex task keys across full reboots,
per-program separation, Settings animation rounds, Camera, host/guest compiler
activity and the per-boot `Trying to restart GPU` count. Performance conclusions
require those runtime checks; warm-state animation limits above still apply.

Local validation: 61 targeted tests across encoder, catalogue, version,
selection, declaration, plan, gate and Task3 suites passed. The final Task3 pass
also tests both missing anchors and confirms that no Task3 bytes are emitted.
The complete `VPhone` bundle build and bundle admission passed. After macOS
administrator authorization, `cfw update-kernel Lychee` installed all four
Task3 sites, with no undeclared patch records. The temporary lowered free-space
check was used only by the installation test bundle on this volume (31 GiB
free), then restored to 50 GiB in source. Runtime tests use the separately
installed final bundle `2.10.1-local.e2defa6e`, which retains the 50 GiB check.

Runtime method: macOS 27.0.1 host, iOS 27.0.1 (24A446) guest with cloudOS
26.4 (23E5207q) driver, five CPUs, 8 GiB RAM, existing guest cache-reuse marker
enabled. Start with an empty host ECID cache, perform five Settings open/home
rounds (three-second pauses), launch Camera for ten seconds, shut down the
guest, and start a fresh VM process. No host files are seeded or copied. Each
boot logs negotiated version 252. Host compiler counts select only
`ParentProcessName=com_apple_gpusw_Paravirtualized_*`; fixed display conversion
work in the Virtualization process and unrelated host programs are excluded.
The guest compiler capture lasts 55 seconds around the application tests;
host capture includes boot through shutdown. Both compile counters count log
events, not unique shaders.

Two identities independently checked against guest binaries with
`codesign -d --verbose=4`:

| Executable | cdhash and retained host directory suffix |
| --- | --- |
| backboardd | `e5543fa5f8667c6cb0d0da787f1b029a9ee3350d` |
| SpringBoard | `73c64934fd90e09f461a339f84dad665f0669885` |

Preferences itself did not create a directory matching its executable hash in
these runs; CoreAnimation work is performed by the rendering servers. Nine
distinct `task-<40 hex>` directories survived the first shutdown and were
reused on the next boot. Host GPU task process IDs change between boots, so
this is disk persistence rather than retained task-service memory.

| Full boot | Retained keys | Host GPU compiles, whole run | Host GPU compiles, Settings rounds | Guest compiles, 55 s | GPU restarts | First home on time | Home rounds 2–5 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 01, empty host cache | 9 | 631 | 121 | 64 | 0 | 44.4% | 61–72% |
| 02, reused | same 9 | 17 | 5 | 11 | 0 | 61.8% | 66–74% |
| 03, reused | same 9 | 12 | **0** | 22 | 0 | 59.2% | 63–72% |

Camera reached the foreground and returned home in all three runs. The
backboardd host `functions.list` grew from 31,404 to 32,692 to 34,036 bytes as
additional variants were learned. SpringBoard's stayed at 4,412 bytes. Guest
compiles were attributed to backboardd and include Camera and late work;
remaining variants still compile, so neither counter is promised to reach zero
for an arbitrary workload. The eight fixed host display conversion compiles
per run are outside these task caches.

Frame figures use the guest `CARenderServerGetFrameCounter` probe, aligned to
host command windows at probe launch, and count observed inter-sample gaps
between zero and one second as on time when at most 20 ms. They include pauses
inside each open/home command window, are not animation FPS, and are only a
small repeated-workload comparison on this machine. The cold host run already
had the guest cache-reuse change; this is not an unpatched-versus-patched A/B.
The host compilation reduction and key retention directly establish cache
reuse. The frame gaps do not establish visible animation stutter: the probe
does not separate animation frames from idle intervals or command pauses.
The user reports smooth warmed animations. Quantifying visible hitches would
require an animation-specific measurement; these samples cannot settle that.

No new crash reports appeared during the first two application-test windows.
The third produced a Passbook widget `SIGTRAP`: `_assertionFailure` →
`swift_unexpectedError` → FinanceKit+7,719,608. Its fault, frames and image UUIDs
match an existing October 18 report, predating this identity patch. No new
backboardd or cameracaptured crash appeared. A fourth full boot then launched
Notes, Calendar, Reminders, Settings, Safari, News, Podcasts, Tips, Music,
Camera and Contacts, returning home between launches. All eleven foreground
checks passed, with zero GPU restarts and no new crash reports during the
application-test window. Lychee was shut down normally afterward. The temporary
installation bundle with the lowered disk check was removed from Launchpad.
Raw runtime captures and the Swift report driver are local scratch artifacts under
`/tmp/vphone-shader-cache-hopper/`, not shipped components.

#### Cache location and migration, 2026-10-20

The durable host cache now lives at `<machine>/ShaderCache`. For Lychee this is
`/Users/arbifox/.vphone/machines/Lychee/ShaderCache`. Guest Metal caches remain
inside the guest filesystem in `Disk.img`; this change relocates the host
ParavirtualizedGraphics cache only.

An initial symlink experiment preserved every file checksum but failed runtime
validation: the Virtualization service logged sandbox metadata denials for the
redirected path, and GPU task compilation rose to 1,525 events without updating
the relocated files. Symlinks are therefore not the shipped storage design.

Before creating the VM, `VPhoneShaderCache.prepare` uses the machine ECID and
the invoking user's Darwin cache directory to locate Apple's required working
directory, `com.apple.paravirtualizedgraphics-<decimal ECID>`. On first use it
copies an existing unmanaged directory intact into `ShaderCache`. It seeds a real
working directory from that durable snapshot before each boot. The VM delegate
checkpoints the working copy at guest shutdown; the parent CLI checkpoints
again after vphone-vm exits, including device teardown writes. A `.host-ecid`
file inside the snapshot lets the unentitled CLI find only that ECID's working
directory, without a private Virtualization API or arbitrary stored host path.

Each transfer copies to a sibling staging directory, then replaces the entire
destination. Independently warmed `functions.list`/`functions.data` files are
never merged. Failed copies leave the prior snapshot intact. Permissions use
the shared host-file walker without following symlinks. Both roots must be real
directories. The local experimental alias was removed during validation;
production setup rejects aliases. An ECID lock stays held for the entire VM
session so concurrent launches cannot replace an active working cache.

Tests cover paired file preservation, checkpointing, repeated setup, a renamed
machine, host cache eviction/reseeding, whole-snapshot replacement, foreign
aliases, checkpoint failure, symlink rejection, concurrent launch exclusion and
hard-linked lock rejection. Initial relocation validation passed twelve
cache/permission tests and 61 targeted Task3, encoder and patch-selection tests,
plus the `VPhone` workspace build and bundle admission. The original 50 GiB
installer guard and, at that point, shipped Task3 preset defaults were unchanged.

All 14 existing Lychee `functions.list`/`functions.data` checksums matched the
initial move. With relocation bundle `2.10.1-local.12d3a7da`, two full boot/shutdown
cycles each passed five Settings rounds and Camera's foreground check. Each
recorded zero host GPU task compiles, zero guest compiles during the 55-second
collection, eight fixed host display compiles, eleven retained executable keys
and zero GPU resets. After the first shutdown, the framework working directory
was moved aside; the second boot restored it exclusively from the machine
snapshot and retained all eleven keys. After each shutdown, all 14 paired file
checksums matched between the working and durable trees. Neither run logged a
checkpoint error.

The first application-test window produced no new crash report. The second
produced one Passbook widget SIGTRAP: its exception and first eight fault frames
exactly match the previously documented FinanceKit assertion failure. A brief
third boot retrieved that report; Lychee was shut down afterward. These are
cache-location health checks, not animation smoothness benchmarks.
The durable snapshot is current after shutdown; changes made during a running
session reside in Apple's working directory until checkpointed. Killing both
VM and CLI can lose that session's new entries.

The unfinished Claude handoff and its probe directory are preserved outside
the checkout at `/Users/arbifox/.vphone/research/shader-cache-2026-10-20/`.
They are research artifacts, not bundle inputs or proposed PR files.
The `validation` subdirectory holds the relocation run captures, compilation
report, checksum manifests and build/test logs.

Deletion semantics correction: the first implementation imported the surviving
working copy whenever `ShaderCache` was missing, so deleting the durable folder
could silently restore the warmed host cache. A `.host-ecid` marker in the
working copy now distinguishes a managed cache from a first-use import. When
`ShaderCache` is missing and the working copy is managed, preparation starts
with an empty snapshot and replaces the working copy. Checkpointing also
respects a missing machine snapshot instead of recreating it at shutdown.
To regenerate the host cache, stop the VM, delete `<machine>/ShaderCache`,
then start the VM with the corrected bundle. Deleting it while the VM is
running does not evict shaders already loaded into memory; the reset takes
effect at the next boot. Guest Metal caches inside `Disk.img` are a separate
layer and are not cleared by this host-only reset.

The correction passes fourteen cache/permission tests, including deleting the
machine snapshot while the VM session is active and deleting it between boots.
The full bundle build and admission pass. In bundle
`2.10.1-local.ee7a374e`, the original machine snapshot was moved to an external
research backup while leaving Apple's managed working copy intact. The next
boot began with only `.host-ecid` in the machine snapshot and regenerated its
host caches: 607 GPU task compile events overall, 129 during five Settings
rounds. The following boot retained all seven newly generated task keys and
recorded seven GPU task compile events overall, one during Settings. Both had
zero guest compiles in the 55-second collection, eight fixed display compiles,
successful Settings/Camera foreground checks and zero GPU resets. All ten
paired cache file checksums matched after the second shutdown. The reset clears
the host layer; it does not promise visible lag or a fully cold guest layer.
The reset test window had no new crash reports. The warm window had one
Passbook widget report with the same exception and first eight fault frames as
the preexisting FinanceKit failure; a brief diagnostic boot retrieved it and
the VM was shut down again.
Captures and build/test logs are preserved beside the earlier validation under
`reset-validation`.

#### Task3 enabled in Standard, 2026-10-20

Standard now enables the complete Task3 patch as
`kernel-cfw-paravirt_gpu_task3`, alongside the already enabled guest Metal cache
reuse marker. The shipped Standard plist and built-in fallback agree; tvOS and
tvOS 4K explicitly block Task3. The old experimental identifier maps to the new
one when reading VM selections, plans and receipts, preserving saved opt-outs
and recognizing kernels already installed by development bundles.

New Standard creations apply both layers automatically. The resolved kernel
patch is part of the template's boot-chain digest, so a template lacking Task3
does not satisfy the new Standard key. Existing machines need their new Core
Bundle bound, `cfw update-environment`, then `cfw update-kernel` while stopped.
Launchpad exposes both updates through its helper. No restore or data erasure
is involved. See `Documents/en/storage/shader-cache.md` for the user workflow.

This changes preset selection and record naming only; the four kernel writes
and runtime coverage above are unchanged. The direct kernel patcher default
remains false for reference-fixture callers; normal firmware pipelines set it
from the resolved plan. Older hosts remain untested.

Validation: 62 focused Task3, encoder, catalog and patch-model tests passed,
including Standard enablement, migration of the old identifier, explicit
blocking and tvOS exclusions. The complete `VPhone` bundle build and admission
check passed. The finished bundle's read-only `fw patches Lychee --json` report
recognized the existing Task3 kernel receipt as applied under the new name,
with `inPreset: true`, `wanted: true` and `pending: false`. No guest rewrite or
additional runtime boot was needed for this preset-only change.

## Heap Textures Have No CPU Layout

On the iPadOS 26.6.2 iPad Pro guest (cloudOS 26.4 driver, `standard` preset),
`cameracaptured` crashed at every boot and launchd throttled its restarts
(`successive crashes = 6`): `SIGSEGV`, `KERN_INVALID_ADDRESS` at `0xc`, on the
precompilation queue:

```
AppleParavirtGPUMetalIOGPUFamily +35956
NRFV3       -[ToneMappingCurves initWithWithContext:] +1076
NRFV3       -[RawDFInferenceGen initWithMetalContext:] +112
NRFV3       -[RawDFProcessor initWithCommandQueue:] +1048
NRFV3       -[NRFProcessorV3 prewarm] +224
CMCapture   PrewarmThreadSafeSBPs +9392
CMCapture   __FigCapturePreloadShadersInternal_block_invoke_2 +1084
```

While it crash-loops, any process that first touches AVCapture defaults waits
in a synchronous XPC to it. SpringBoard's main thread did, through the Control
Center sensor indicator's `AVCaptureDeviceDiscoverySession`, as soon as an app
started recording, and the guest UI froze until the VM was restarted. audiomxd's
`StartIO` for the recording blocked 18 s the same way, so the first recording
after each boot failed.

It is a bug in the guest's Metal driver, not the sandbox gate above:

- `-[ToneMappingCurves initWithWithContext:]` makes a shared `MTLHeap`
  (`setStorageMode:0`, `setSize:0xc800`), takes textures from it with
  `-newTextureWithDescriptor:`, and fills each with
  `-replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:`.
  `+1076` is the return address of that call.
- `AppleParavirtTexture` keeps a texture's CPU layout in the ivar `_dimension`.
  Every initialiser fills it except
  `-initWithHeap:resource:offset:length:descriptor:`, the one
  `-[AppleParavirtHeap newTextureWithDescriptor:]` uses.
  `-replaceRegion:…` (`0x8c28` in the 23E5207q driver; `+35956` is `0x8c74`)
  starts with `ldr x8, [x0, _dimension]; ldur x19, [x8, #0xc]`. That fault is
  at `0xc`. `-getBytes:…fromRegion:…` reads it the same way.
- The daemon has a Metal device. `FigCapturePreloadShadersInternal` takes
  `[[FigMetalContext metalDevice] newCommandQueue]` first and returns early
  when it is nil, and the faulting frame is a method of a real
  `AppleParavirtTexture`. `kernel-exp-paravirt_user_clients` therefore changes
  nothing here; a guest with it crashes the same way.

Any CPU upload into or readback from a heap-allocated texture faults on this
driver, in any process. The prewarm is where `cameracaptured` meets it at every
launch.

To reveal it in a driver, look for the ivar offset slot named `_dimension` in
`xcrun llvm-objdump --macho --objc-meta-data` (`0x6b7ac` in 23E5207q). List the
`ldrsw xN, [x8, #0x7ac]` loads of it with `ipsw macho disass <driver> --vaddr
0xdc8 --count 41000`. In 23E5207q these are every `AppleParavirtTexture` init
except `initWithHeap:…`, plus `dealloc`, `getBytes:…` and `replaceRegion:…`.

### Skipping the prewarm

`libvcamcaptured` removes the one call to `PrewarmThreadSafeSBPs`
(`VPhoneGuestComponents/VCamCaptured/Prewarm/`). Prewarming only compiles
shaders ahead of first use, and nothing waits on that function: it returns
nothing, stores no global and signals nothing. The rest of the preload still
runs. That includes the processor flags `FigCapturePreloadShadersInternal`
records, `DMPerformMigrationIfNeeded`, and the deferred shader cache copy.
Deferred photo processing waits up to 180 s on that copy's semaphore
(`FigWaitForDeferredShaderCacheCopyCompletion`), so skipping the whole preload
would not be safe.

The hook runs synchronously in the dylib's constructor, so it runs before the
daemon's own launch code, and only when
`/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle` is
installed. The call site is found from the one exported symbol, with no fixed
address:

1. `FigCapturePreloadShaders` is `mov w0, #0; b FigCapturePreloadShadersInternal`.
2. In that function, before its return, exactly one
   `adrp x16; add x16, x16, #imm; pacia x16, xN`. This is the block's invoke,
   `__FigCapturePreloadShadersInternal_block_invoke_2`.
3. In the block, before its return, exactly one `ldr x0, [xN, #0x20]; bl`
   whose target is a function of CMCapture's `__text`. That is
   `PrewarmThreadSafeSBPs(commandQueue)`, with the queue as the block's first
   capture. iOS 27 has a second captured load in the block, but it calls a
   stub outside `__text`.

The `bl` becomes a `nop` (`vcc_patch_word`, which checks the old word first).
Over the real bytes, the scan gives these unslid addresses:

| Build | Internal | Block | Call | `PrewarmThreadSafeSBPs` |
| --- | --- | --- | --- | --- |
| iPadOS 26.6.2 (23G90), and the 26.6 cache | `0x1aeb2f06c` | `0x1aeb2f930` | `0x1aeb2fd68` | `0x1aeb300d4` |
| iOS 27.0 (24A435) | `0x1b0758ff0` | `0x1b07598c4` | `0x1b0759d10` | `0x1b075a070` |

`make -C VPhoneGuestComponents test-vcam-prewarm` runs the same scan over a
synthetic stream with these decoys and checks each refusal.

On a guest, check these:

- `/var/mobile/Media/SimulatedCamera/vcamcaptured.log` (and `vcamcaptured:` in
  the system log) has
  `gpu prewarm: internal 0x… block 0x… call 0x… -> PrewarmThreadSafeSBPs 0x…: skipped`,
  with the 23G90 addresses above. Any `gpu prewarm: kept, …` line names the
  step that refused.
- `logs.crashes` has no `cameracaptured` report newer than the update.
- `services.print` with label `com.apple.cameracaptured` shows
  `successive crashes = 0`.
- Starting a recording in an app neither freezes SpringBoard nor delays the
  first recording.

This does not fix the driver. NRF or RawDF processing during a real capture,
or any other heap texture upload, would still fault.

## Heap Index Buffers

Unity games drew their meshes scrambled: the right vertices joined into the
wrong triangles, so scenes broke into spikes and stretched faces, and a
full-screen quad came out as one triangle. Textures were correct. Seen on
2026-10-14 in Wing Fighter on iPhone17,3 iOS 27.0.1 and in Subway Surfers on
an iPad16,1 iPadOS 26.6.2 guest, both on the cloudOS 26.4 (23E5207q) driver,
bundle 2.9.4, host macOS 27.0.1 on an M4. It is not the userland version: both
bases showed it.

### Measured

A probe run from a launchd job draws a quad that should cover a 64×64 target
and counts the lit pixels. Every path through plain buffers covered 100%:
indexed and non-indexed draws, 16- and 32-bit indices, `indexBufferOffset`
from 0 to 128 and unaligned, `baseVertex`, instancing, `stage_in` layouts with
strides 12 to 44 and attribute offsets, half, short-normalised and
uchar-normalised formats, several streams, per-instance step functions,
`setVertexBytes`, shared buffers rewritten between frames, a 4 MiB
write-combined ring, blit uploads into private buffers, a 64 MiB buffer read
16 and 64 MiB in, and `newBufferWithBytesNoCopy`.

Buffers carved from an `MTLHeap` split by role. A shared heap of 8 MiB, its
first buffer filled with decoys, then six 64 KiB buffers each holding the
quad's vertices at 0 and its indices at 1024:

```
heap buf#1..#6 vb only (plain ib)              cover 100.0%  OK
heap buf#1..#6 ib only (plain vb)              cover   0.0%  BAD
heap ib, indexBufferOffset 70000 (64-bit cmd)  cover 100.0%  OK
heap ib, indexBufferOffset 1000 (16-bit cmd)   cover   0.0%  BAD
heap ib instanceCount:1 variant                cover   0.0%  BAD
heap ib baseVertex variant                     cover   0.0%  BAD
```

Vertex buffers from a heap work at any offset; index buffers from a heap fail,
unless the draw's own `indexBufferOffset` is large. Compute kernels read and
write heap buffers correctly, so the memory is right and the draw is wrong. One
more symptom points the same way: every heap buffer reports `heapOffset` 0.

### Why

`-[PGSerializerRenderCommandEncoder drawIndexedPrimitives:…]` has two
encodings per method: a compact command with 16-bit fields and a full one with
64-bit fields. In the 23E5207q driver:

| Method | Compact / full command | Choice | Truncating store |
| --- | --- | --- | --- |
| `…indexBufferOffset:` | 0x7 / 0x6 | `0x1421c cbnz x27` | `0x14284 strh w8, [x25, #0xa]` |
| `…indexBufferOffset:instanceCount:` | 0x9 / 0x8 | `0x140b0 cbnz x28` | `0x14120 strh w8, [x26, #0xa]` |
| `…instanceCount:baseVertex:baseInstance:` | 0x1d / 0x1c and 0xb / 0xa | `0x143b4 cbnz x20`, `0x143c4 cbz w24` | `0x14450 strh w8, [x26, #0x8]` |

The choice tests only the draw's own arguments: `indexCount`,
`indexBufferOffset` and, where the method has them, the instance and base
values must each fit in 16 bits. The stored value is `[indexBuffer parentResourceOffset]
+ indexBufferOffset`, and `parentResourceOffset` is a sub-allocated buffer's
offset in its heap, which the test never sees. An index buffer 64 KiB or more
into a heap is read from `(heapOffset + indexBufferOffset) mod 65536`: another
mesh's indices, which reference vertices that exist, so nothing faults. Vertex
bindings go through `setBuffers:offsets:…` with 64-bit offsets, and the
indirect `drawIndexedPrimitives:indexType:indexBuffer:indexBufferOffset:indirectBuffer:…`
has only a 64-bit form.

Two more methods store `parentResourceOffset` in 16 bits and are not patched:
`drawPatches:…:patchIndexBuffer:…` and `drawIndexedPatches:…` (tessellation),
and `-[PGSerializerBlitCommandEncoder copyFromTexture:…toBuffer:…]` at
`0x230e0`. Mobile games rarely tessellate; the blit was not measured.

### The patch

`system-paravirt_gpu-cfw-heap_index_offset` turns each selecting branch into an
unconditional `b` to the full command, which the driver already sends whenever
a value does not fit, so the host accepts it. Each site is found by the
compact command's `mov w2, #size ; mov w3, #command` pair, unique in `__text`,
and the branch must lead to the full command's own pair; a driver laid out
otherwise is refused unchanged (`CustomFirmwareParavirtGPUIndexOffset`). The
cost is 12 to 28 bytes more per indexed draw.

Verified on the iPad guest with the patched driver in place: every heap row
above covers 100%, the plain-buffer probe is unchanged, and Subway Surfers
draws its menu scene and gameplay correctly.

## OpenGL ES

Upstream issue Lakr233/vphone-cli#793: `[[EAGLContext alloc] initWithAPI:]`
returned nil for every API in a guest while Metal worked. OpenGL ES on Apple
GPUs is AppleMetalGLRenderer, a renderer over Metal, and on the paravirtual GPU
it failed at three points in turn. Measured on 2026-11-02: host macOS 27.2,
cloudOS 26.4 (23E5207q) kernel, iPhone17,3 iOS 27.0.1 userland, test VM
`glestest-iphone`.

### No renderer

`gfxInitializeLibrary` in `OpenGLES.framework/libGFXShared.dylib` walks the
`IOAcceleratorES` services and, for each, reads `IOGLESBundleName` and
`IOGLESMetalBundleName` from the registry; the renderer it loads is
`/System/Library/Extensions/<name>.bundle`. With neither key there is no
renderer and no context. The AGX personalities carry
`IOGLESBundleName = AppleMetalGLRenderer` (`AGXG14X` in the j236c kernelcache
of the same cloudOS IPSW); `AppleParavirtGPUARM` names only its Metal plugin.
A personality's keys become the driver's property table, so
`kernel-cfw-paravirt_gles_renderer` adds the AGX key to the personality in
`__PRELINK_INFO`. With it, all three APIs return a context, `GLEngine` and
`AppleMetalGLRenderer` load, and `glClear` with a readback works.

### Shaders crash the compiler service

The first draw with a shader failed with
`GPU Hang Error (00000003:kIOGPUCommandBufferCallbackErrorHang)` and an
unchanged framebuffer, while `MTLCompilerService` crashed in the compiler
plugin, `libAppleParavirtCompilerPluginIOGPUFamily.dylib`, which this project
builds (`VPhoneGuestComponents/GraphicLoader`). A copy of the plugin that wrote
each module it received to `/private/var/tmp` showed what OpenGL ES sends it:

```
target triple = "air64-apple-ios"
!air.language_version = !{!0}
!air.fragment = !{!4}
!0 = !{!"OpenGL ES GLSL", i32 1, i32 0, i32 0}
!10 = !{i32 2, !"air.buffer", !"air.buffer_size", i32 112, !"air.location_index", i32 12, i32 1, !"air.read"}
!12 = !{i32 4, !"air.sampler", !"air.location_index", i32 0, i32 1}
```

A module from the Metal front end has `!air.version = !{i32 2, i32 7, i32 0}`,
a versioned triple, and argument nodes that go on to `air.address_space`,
`air.arg_type_size`, `air.arg_type_align_size`, `air.arg_type_name` and
`air.arg_name`. GPUCompiler reads those without bounds or null checks:
`MTLDowngradeAIRModule` and `MetalModule::materialize` dereference
`getNamedMetadata("air.version")`, and `air::Reflection::create` reads
`air.address_space` at a fixed index past the end of the GL buffer node. The
plugin now completes an OpenGL ES module before compiling it, from the entry
point's own types, and gives it the version the front end writes, 2.7.0 — also
the plugin's target, which `MTLCompilerService` passes as a packed version tuple
(`0x700000002`) in the field the plugin calls `targetTriple`.

The host carries the same GPUCompiler (32023), so the plugin built for macOS
runs the guest's modules on the host: `make -C VPhoneGuestComponents
test-gles-air` turns three captured modules into metallibs, loads each in the
host's Metal and links the vertex and fragment functions into a pipeline.

### The host refuses the primitive restart command

Shaders then compiled, and the guest kernel logged an `AppleParavirtGPU
HardwareDiagnosisReport` and a GPU restart for every GL command buffer. The
host task (`com.apple.gpusw.ParavirtualizedGraphicsGPUTask`) logged
`Command buffer failed: NSGenericException <redacted reason>`. A task starts
for each guest process that opens the GPU, so a probe that pauses after creating
its context leaves time to attach lldb to the new one and break on
`objc_exception_throw`: the reason is `Invalid viewport index`, thrown by the
handler that replays `setPrimitiveRestartEnabled:index:` after checking `index`
against `[device maxViewportCount]`. OpenGL ES sends the restart index there,
`0xffffffff`. `system-paravirt_gpu-cfw-primitive_restart` makes the guest
driver's serialiser for that call return at entry, so Metal's own restart
behaviour applies (on, at the index type's largest value).

### Measured

| Probe | Result |
| --- | --- |
| EAGL API 1, 2, 3 | all OK; `GL_RENDERER` "Apple Paravirtual device GPU", `GL_VERSION` "OpenGL ES 3.0 Metal - 105" |
| ES 2 shader draw, root and mobile launchd jobs | exact readback of draw and clear |
| ES 2 textured quad, 2x2 nearest texture, `mat4`/`float`/`vec4` uniforms, varyings | all four texels exact |
| ES 3 uniform block, flat `int` varying, `texelFetch`, fixed-index restart strip | both quads exact, the split gap clear |
| App drawing through `CAEAGLLayer` at 1290x2796 | 1560 frames presented, a rotating triangle on screen |

No `MTLCompilerService` crash and no GPU restart in any of these.
`Research/0_binary_patch_comparison.md` ("OpenGL ES in guests (2026-11-02)") has
the bytes and what is not covered.

### Native GLES semantics

Signed clip-z remains a separate pass-state issue after these corrections.
The paired compiler/viewport correction and its on/off pixel controls are
documented in [GLES signed depth clipping](gles_depth_clip.md).

Further testing on iOS 26.6.2 (23G90), cloudOS 26.4 (23E5207q) and macOS
26.6.2 (25G83, Apple M5 Max) found failures after contexts and basic draws
worked. The following results come from development builds on that OS pair.
Six declarations cover these repairs; their semantic discovery, version gates
and rollback rules are in the [patch comparison](../0_binary_patch_comparison.md#native-gles-follow-up-2026-11-02).

**Drawable orientation.** The renderer normally uses a private IOSurface
attachment `yInvert` flag. A 16-case host/guest control showed it reversing
host rows but having no effect through PV. Selecting the renderer's existing
`AGX_GL_VIEWPORT_INVERT_CONFIG=UPPER_LEFT` path corrects viewport/scissor
orientation. SystemHook sets it only while `/usr/lib/vphone-gles-upper-left`
exists and preserves explicit environment values. This locates a behavioral
gap without identifying the exact missing transport field.

**Vertex and instance IDs.** Captured vertex-ID AIR compiles on host Metal
without a descriptor or with public UInt (36), but private format 43 aborts
in `CloneAttributeDescriptor`; the guest's ID buffer contains the expected
uint values, including 0, 1, 2. Only the serialized formats 43/44 become UInt,
after guest shader variant generation, preserving original descriptors and
AIR. Separately, ES1's generated fragments use `OpenGL ES Program`;
`GLESAIR.mm` accepts it alongside `OpenGL ES GLSL` and completes missing buffer
address space, size and alignment independently, preserving producer values.
Partial buffer metadata was not demonstrated to cause the descriptor crash.

**Restart-disabled strips.** Suppressing the unsupported restart command
leaves Metal discarding the maximum index even when GLES restart is disabled.
The repair selects GLEngine's existing primitive expansion for disabled
indexed line/triangle strips: vertices are packed into a nonindexed draw,
retaining vertex/instance IDs. Every affected strip incurs CPU copying, even
when its indices contain no maximum value. Seven baseline cases, seven
builtin controls and a 36-case line/triangle matrix passed in the guest;
UInt8/UInt16 exercise maximum indices, UInt32 uses 65535 as a high-index control.

**Points.** PV inherits a zero-returning
`pipelineFlagsWithVertexVariant:fragmentVariant:` implementation. Four guards
on the resulting point-size usage bit suppress valid `GL_POINTS` draws.
Removing only those guards restores 12 size cases and three triangle controls
(15/21), but six coordinate gradients remain inverted. Host/guest replay
shows that `pointCoordYFlipEnabled` changes host pixels and has no effect
through the measured PV path, independently of drawable orientation.
The compiler therefore lowers only GLES fragment `air.point_coord.y` to
`1-y` for `float2` and `half2`, preserving X. A named metadata marker makes
this idempotent; malformed indices/types are rejected without mutation,
and ordinary varyings and non-GLES modules are unchanged. Retained
[AIR tests](../../VPhoneGuestComponents/Tests/GLESAIRTests.mm) record fixture
origins and the coordinate oracle. Revisit this compensation if PV begins
honoring the native flag, to avoid double inversion.

**Stale compiler output.** A fresh process cache passed 21/21 point cases
while the old default cache remained at 15/21 after the compiler change.
The driver hashes fixed date/time literals into its function-cache identity;
Metal's library cache has a separate identity. Deriving the driver's seed
from the installed plugin is necessary but insufficient: on this base,
`FS_CACHE_REUSE_ON_REBOOT=1` skips both the 32-byte key comparison and the
64-byte boot/system-stamp comparison. The repair retains key validation while
skipping only the boot check. After restoring the old default cache, updating
and rebooting, the first run and a warm repeat both pass 21/21 without a
cache-path override, cache deletion or rendering hook. The installed driver's
seed was checked against the installed plugin's content-derived identity.

### Verifying the GLES repairs

Historical development validation passed 22 standalone guest processes: 20
correctness checks covering original ID shaders, texture effects, shared
contexts, BGRA/NV12 imports and conversion/fences, a three-slot queue, VBO
controls, restart and points; two timing checks measured submission/completion
and restart copying. Timing observations do not establish application performance.
An ordinary app separately passed ES1/2/3 and Metal, with each surface submitting
30 frames. A nine-position native-resolution screenshot comparison had maximum
sampled RGB difference 1.465452/255 (tolerance 8). These are sampled screen checks.

For independent guest validation, exercise nonzero first/indexed vertex IDs,
instance IDs, restart-enabled/disabled strips with maximum indices, and ES1/2/3
point sizes and coordinate gradients through native GLES. Record pixel results,
process exit status/signal and a native-resolution app screenshot. Change one
selection at a time with `fw set-patches`, run `cfw update-environment`, fully
reboot and check applied/pending receipts before rerunning identical inputs.
Re-upload temporary binaries after each reboot. Point on/off/on measured
21 → 3 → 21: the disabled run had zero GL errors and only triangles passed.
Orientation and restart opt-outs reproduced their failures and recovered when
re-enabled. Restore `standard` after these controls. Separately restore an old
default cache before a compiler update, then verify both first-use and warm
results without overriding the cache path.

Run retained host regressions from the repository root with Xcode and an Apple
GPU. AIR checks cover completion, point pixels, scope and idempotence; patcher
checks cover discovery rejection, exact mutations, dependencies and rollback:

```zsh
make -C VPhoneGuestComponents test-gles-air
xcodebuild -workspace VPhone.xcworkspace -scheme FirmwarePatcherTests \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/vphone-native-patcher-tests \
  -only-testing:FirmwarePatcherTests/DyldSharedCacheMetalVertexFormatTests \
  -only-testing:FirmwarePatcherTests/DyldSharedCacheGLESPrimitiveRestartTests \
  -only-testing:FirmwarePatcherTests/DyldSharedCacheGLESPointDrawTests \
  -only-testing:FirmwarePatcherTests/DyldSharedCacheMetalCacheReuseTests \
  -only-testing:FirmwarePatcherTests/CustomFirmwareParavirtGPUCompilerCacheTests \
  -only-testing:FirmwarePatcherTests/MachOSymbolTargetsTests \
  -only-testing:FirmwarePatcherTests/FirmwarePatchSetCatalogTests \
  -only-testing:FirmwarePatcherTests/FirmwareGuestPatchResolutionTests test
```

Host tests do not establish installed-VM rendering. The guest checks do not
establish full GLES conformance, ES1 lighting/fog, every framebuffer combination,
arbitrary app compatibility, physical-camera behavior or performance. Validate
other OS pairs before widening the gates.

## Settings That Do Nothing Here

Both are private properties of `VZMacGraphicsDeviceConfiguration`, tried on
`gpuaccel-ipad` across restarts and not kept in the code.

- `_enableProcessIsolation = false`. The guest still had ten host GPU task
  processes and the same pacing: Settings 98% on time either way, Safari 70%
  against 68%, Today View 87% against 88%.
- `_deviceFeatureLevel`. The default, 0, already gives what the highest level,
  5 (the framework logs it as "2027"), gives: Common3 and argument buffers tier 1. Level 1
  ("2022") takes both away.

## Reproducing the Check

The tool is the issue's snippet built for the guest:

```zsh
xcrun -sdk iphoneos clang -arch arm64e -miphoneos-version-min=17.0 -fobjc-arc -O2 \
    -framework Foundation -framework Metal -framework QuartzCore -o MetalTest MetalTest.m
codesign -s - -f MetalTest
```

Copy it with `files.write` (`encoding: base64`), `files.chmod` it to 755, and run
it from a launchd plist with `RunAtLoad` and `StandardOutPath` loaded through
`services.load`. `/var/tmp` is emptied at every boot.
