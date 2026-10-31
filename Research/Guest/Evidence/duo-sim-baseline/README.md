# iPhone Duo simulator baseline harness

Shared tooling for recording what Apple's own iPhone Duo simulator returns from
public and private APIs in each fold posture, so vphone-duo (iPhone19,4, iOS 27.1
24A94425 in a Virtualization.framework VM) can be compared against it.

**In the repository:**

- the tables: `BASELINE.md`, `<domain>.md`, `vm-notes.md`;
- the harness in `tools/`, the probes in `probes/`, and `smoke.json`;
- `src/`: the per-domain drivers, probe generators, the probe app and the VM
  run scripts, which first lived under `raw/`.

The per-domain record files (`<domain>.json` and `vm-<domain>.json`, 2–63 MB
each) and the transcripts and screenshots under `raw/` (about 1 GB) were
deleted on 2026-10-30. The values worth keeping that were not already in these
tables are now in `Research/Guest/iphone_duo_simulator_reference.md`. Paths to
`*.json` and `raw/` in these notes name output that rerunning the probes
recreates.

- Xcode 27.1 (27A9275), runtime iOS 27.1 (24A94425), device type
  `com.apple.CoreSimulator.SimDeviceType.iPhone-Duo` (iPhone19,4).
- Harness simulator: **`duo-baseline-harness`, UDID `D13582ED-1932-4E12-800F-A44CFE16EA8E`**
  (left shut down; clone it with `tools/sim.zsh clone`). Locale is zh-Hans, so
  screenshots show Chinese UI.
- Never boot, erase or delete the two pre-existing "iPhone Duo" devices
  (`B738069B-…`, `4D48BBE9-…`). `sim.zsh` refuses to boot or shut them down.

| Path | What |
| --- | --- |
| `tools/sim.zsh` | create / clone / boot / shutdown, UDID and pid lookup, runtime root, screenshots, lit/dark check |
| `tools/probe.zsh` | attach lldb to one sim process, run a command file, detach, save a cleaned transcript |
| `tools/prelude.lldb` | sourced before every probe: `thread select 1`, `@import Foundation/UIKit/ObjectiveC/Darwin` |
| `tools/posture.zsh` | drive closed / book / open / an angle, then verify with screenshots and a SpringBoard readback |
| `tools/smoke.zsh` | the end-to-end smoke run that produced `smoke.json` |
| `probes/smoke-springboard.lldb` | the smoke probe; also the template for a probe that emits records |
| `smoke.json` | smoke result (60 records, 3 postures) |
| `raw/smoke/` | smoke transcripts and screenshots |
| `raw/posture/` | posture-driver runs, including the hysteresis evidence below |

All tools are zsh; there is no Python. `jq` is `/opt/homebrew/bin/jq`.

## Quick start

```sh
cd Research/Guest/Evidence/duo-sim-baseline
tools/sim.zsh boot duo-baseline-harness            # boots, waits, prints the UDID
tools/posture.zsh duo-baseline-harness book        # → JSON, exit 0 when verified
tools/probe.zsh duo-baseline-harness SpringBoard my-probe.lldb raw/<domain>/book-springboard.txt
tools/sim.zsh shutdown duo-baseline-harness
```

For your own simulator: `tools/sim.zsh clone duo-baseline-harness duo-baseline-<you>`
(the source must be shut down), then use that name everywhere.

## sim.zsh

```
sim.zsh create [name]                 iPhone Duo / iOS 27.1, prints the UDID
sim.zsh clone <src> <new-name>
sim.zsh boot <name|udid>              boot + bootstatus -b
sim.zsh shutdown <name|udid>
sim.zsh udid <name|udid>
sim.zsh pid <name|udid> <process>     SpringBoard, backboardd, Preferences, MobileSafari, …
sim.zsh ps <name|udid>                every process of that sim (children of its launchd_sim)
sim.zsh runtime-root                  mounted RuntimeRoot (only while a 27.1 sim is booted)
sim.zsh shared-cache                  …/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64
sim.zsh shot <name|udid> <dir> <tag>  <dir>/<tag>-d1.png (cover) and -d3.png (inner) + lit/dark
sim.zsh lit <png>                     "lit|dark mean=… max=…"
```

`pid` matches the executable's basename among the children of the sim's own
`launchd_sim`, so several booted sims never get mixed up.

A panel that is not being driven captures as pure black (`max=0`); `lit` means
some pixel of a 32×32 downscale exceeds 24. Display 1 captures 1398×2034
(portrait); display 3 captures **2853×2007** (landscape — the panel's native
rotation is 270).

`simctl io screenshot` works headless on this host. (An older note in
`Research/Guest/iphone_duo_bringup.md` says it captures black without
Simulator.app; that is not the case for this runtime — a black capture means the
panel is off.)

## probe.zsh

```
probe.zsh <udid|name> <process|pid> <cmdfile|-> [out.txt]
  PROBE_TIMEOUT=120      watchdog: SIGINT lldb, again after 10 s, SIGTERM after 10 more
  PROBE_FULL_SYMBOLS=1   load all symbol tables up front (≈16 s/attach instead of ≈3 s)
  PROBE_NO_PRELUDE=1     skip prelude.lldb
```

It runs `lldb --batch --no-lldbinit -p PID`, with `symbols.load-on-demand`
on, sources `prelude.lldb` and then your file with stop-on-error **off**, then
`process detach` and `quit`. Afterwards it checks the target: if it was left
stopped (`T`) it gets `SIGCONT` and a warning; if it disappeared, a warning.
With `out.txt` it writes the cleaned transcript there and lldb's untouched
output to `out.raw.txt`; without, it prints the cleaned transcript. Cleaning
keeps everything after your file's `command source` echo and drops lldb's
chatter (attach banner, "Executing commands in", the Objective-C++ note,
detach lines). Each `(lldb) expr …` echo stays as the delimiter for its result.
Exit status 124 means the watchdog fired. An interrupted expression cancels the
rest of the command file, and lldb still detaches (tested with an endless loop
in Preferences: the app kept running).

Avoid side effects in SpringBoard beyond what a probe needs: every probe stops
the whole process for ~3 s.

### Writing probes

An expression can span lines: `expr -l objc -O --` alone on a line, the body,
then an **empty line**. One-line `expr -l objc -O -- …` works too.

Rules learned the hard way:

- **Prefix locals** (`vpScreens`, `vi`): short names such as `names` or `m`
  collide with symbols in the shared cache ("Multiple internal symbols found").
- **Do not rely on lldb persistent `$variables`**. An `id $x` cannot be messaged
  later ("no known method"), and after declaring a persistent struct variable
  other `$variables` became "undeclared". Do the whole job inside one expression.
- **Cast an `id` to `(NSObject *)` before `-description`** and similar NSObject
  protocol methods (`[(NSObject *)[obj valueForKey:@"x"] description]`);
  `[id description]` fails with "no known method".
- **Non-object returns and struct arguments go through a cast `objc_msgSend`**:
  `((long (*)(id, SEL, id))objc_msgSend)(obj, @selector(displayContentModeForWindowScene:), scene)`.
- **C functions — exported or private, in the shared cache only — via `dlsym`**,
  cast to their real signature:
  `((id (*)(NSString *))dlsym(RTLD_DEFAULT, "MGCopyAnswer"))(@"ProductType")` → `iPhone19,4`.
  Declare structs inline (`struct VPSwapSettings { … };`) when the function
  takes or fills one; see `posture.zsh`.
- **Classes that exist only in the shared cache** need no headers:
  `NSClassFromString(@"SBDisplayToolService")`, then KVC (`valueForKey:` also
  reads ivars such as `@"_displayToolService"`) or cast `objc_msgSend`. To read a
  struct ivar: `class_getInstanceVariable` + `ivar_getOffset` on
  `(__bridge void *)obj` (see the readback in `posture.zsh`).
- **Never let a block escape the expression.** Blocks written in an expression
  live in lldb's JIT memory; one stored by the target (a completion handler, an
  observer) can outlive it. Pass `nil` completions; blocks used only inside the
  expression (helpers like `vpAdd` in the smoke probe) are fine.
- Discovery inside the target: `class_copyMethodList` / `class_copyIvarList` /
  `objc_copyClassNamesForImage` / protocol conformance in an expression;
  `image lookup -r -n <regex>` and `disassemble -n <symbol>` as plain lldb
  commands. `ipsw class-dump <sim cache> <framework>` works for frameworks in the
  sim cache, but `ipsw dyld disass` crashed on this cache (objc stub parsing),
  and SpringBoard.framework is not in the cache — use lldb against the live
  process for those.
- **Emit records as JSON from inside the expression**: build an `NSArray` of
  `NSDictionary`, end with
  `[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:… options:0 error:nil] encoding:NSUTF8StringEncoding]`;
  `-O` prints it as one line that `jq` takes as is (`probes/smoke-springboard.lldb`).

### Probing an app

```sh
xcrun simctl launch D13582ED-1932-4E12-800F-A44CFE16EA8E com.apple.Preferences   # prints "com.apple.Preferences: <pid>"
tools/probe.zsh duo-baseline-harness Preferences my-probe.lldb out.txt         # or pass the pid
xcrun simctl launch D13582ED-1932-4E12-800F-A44CFE16EA8E com.apple.mobilesafari  # process name MobileSafari
```

Probe apps the same way as SpringBoard; `[[UIApplication sharedApplication]
connectedScenes]` there returns the app's own `UIWindowScene`. Daemons work too
(backboardd: `tools/probe.zsh … backboardd …`); UIKit is not loaded there, so do
not call UIKit in those probes. For a daemon that is not running yet, trigger it
first (launch the client, or `xcrun simctl spawn <udid> launchctl kickstart …`).

App-side hinge API seen in Preferences (for whoever takes that domain):
`UIHingeInteraction` / `UIHingeInteractionUpdate`, `_UISceneHingeStateClientComponent
-hingeState`, `_UIHingeState -hingeAngle`, and `UIApplication
-currentHingePoseStateForTesting` / `-setHingePoseStateForTesting:`.

## Posture: the mechanism

**SpringBoard has a built-in display tool, and the harness calls it in-process.**
SpringBoardFoundation in the sim shared cache embeds the help text of Apple's
internal `suiatool` swap command
(`[-duration=<seconds>] [-deviceOrientation=<orientation>] [-position=<closed|book|open|0.0-1.0>] [-fade | -continuous] [-wait]`,
printed in full by `SBFDisplayToolSwapSettingsUsageDescription()`). The client is
`SBSDisplayToolService` (SpringBoardServices) and talks over BSServiceConnection
`com.apple.springboard.sbdisplay`. SpringBoard's server, `SBDisplayToolService`
(held in `-[SpringBoard _displayToolService]`), checks the caller for the
entitlement `com.apple.springboard.sbdisplay.service`, hops to the main queue,
parses the options with `SBFDisplayToolSwapSettingsFromDictionary` and calls
`-[SBDisplayToolServiceCoordinator performDisplaySwapWithSettings:completion:]`.
No binary in the sim runtime carries that entitlement (and there is no
`suiatool` binary), so `posture.zsh` skips the XPC front door and does in
SpringBoard, over lldb, exactly what the server does after its entitlement check:

```objc
SBFDisplayToolSwapSettingsFromArguments(@[@"-position=book", …], &settings, &error);  // BOOL, fills the struct
[[[UIApplication sharedApplication] valueForKey:@"_displayToolService"] valueForKey:@"_swapCoordinator"]
    performDisplaySwapWithSettings:settings completion:nil];                           // BOOL: started
// settings = {q state; d duration; q deviceOrientation; q profileOverride; B waitForCompletion;
//             q targetMode; d targetHingePosition; d lockedForTestingUntil}
```

The coordinator runs a synthetic hinge sweep and pushes it through
`SBFDevicePoseProvider` (`_pushCurrentSettingsThroughPose:`), so the hinge state
machine, `SBDisplayContentModeCoordinator` and `SBFDisplayContentModeResolver`
resolve the displays the same way they would for real hinge motion. The device
turns on and off panels and moves the foreground app between them. `targetMode`
1 means an absolute position: closed 0.0, book 0.5556 (100°), open 1.0 (180°).
Each swap takes a 10-second testing lock (`lockForTesting`) so real hinge input is
ignored; `posture.zsh … unlock` releases it early. In the sim the state persists
after the lock expires (checked 30 s after the swap: unchanged).

`posture.zsh` then waits until the coordinator is idle (`_currentSettings.state
== 0`, no instant swap or replay running), reads SpringBoard once (the resolver
description, which includes the pose provider's), screenshots both displays,
and prints one JSON object. Exit 0 means the lit panel matches the posture
(closed → cover, book/open → inner), 3 a mismatch.

```
posture.zsh <udid|name> closed|book|open [-duration=<s>] [-fade|-continuous] [-deviceOrientation=<o>]
posture.zsh <udid|name> angle <degrees> [same options]     # position = degrees / 180
posture.zsh <udid|name> status                             # readback + screenshots only
posture.zsh <udid|name> unlock                             # release the testing lock
  POSTURE_OUT=dir        artifacts (default raw/posture)
  POSTURE_SETTLE=3       seconds before the first readback
  POSTURE_ANCHOR=closed|open|none
```

### Results (smoke run, `raw/smoke/`)

| posture | hinge state (pose provider) | prevailing policy | primary on | inner applied | cover applied | display 1 | display 3 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| closed | `.closed`, 0.000 (0°) | FullyClosed | cover | disabled | primaryContent | lit | dark |
| book | `.partiallyOpen`, 0.556 (100°) | FoldingDual | inner | primaryContent | auxiliaryContent | dark | lit |
| open | `.openFlat`, 1.000 (180°) | FoldingDual | inner | primaryContent | auxiliaryContent | dark | lit |

Screenshots: `raw/smoke/20261029-134407-closed-d{1,3}.png`,
`20261029-134427-book-d{1,3}.png`, `20261029-134502-open-d{1,3}.png`; readbacks
in the matching `-readback.txt`; posture JSON in the matching `.json` and in
`smoke.json` `meta.postures`. Preferences was in the foreground: closed shows its
compact layout on the cover, book and open show the split layout on the inner.

`-[SBDisplayContentModeCoordinator displayContentModeForWindowScene:]` returns
1 = disabled, 2 = primaryContent, 3 = auxiliaryContent (matched against the
resolver's names). The cover's scene is `SB-main` (display identity `Main`),
the inner's is `com.apple.springboard.bringup` (`Unknown.main[3]`).
`primaryWindowScene` and `activeWindowScene` follow the posture. Resolver
policies listed: Single, FoldingDual, Yoink, Tent, FullyClosed,
ForceCoverDisplayEnabledOnly; preferred transition style `.continuousLive`.

### Hysteresis — why `book` anchors at closed

The hinge regions move with where the hinge last stopped
(`raw/posture/*-readback.txt`):

- At rest at 0°: `closed 0.00→0.47`, `partiallyOpen 0.47→0.97` — a sweep to 100° swaps to the inner.
- Closed at 0° → `angle 60`: stays `.closed` on the cover; regions become `closed 0.00→0.63`, `toOpen 0.33→0.97`.
- Then `book` without an anchor (`20261029-134037-book.json`): 100° < 113°, so it stays `.closed` on the cover — the run that failed verification.
- `book` → `angle 60` stays `.partiallyOpen` on the inner (`toClosed` needs more).

So `posture.zsh book` first does an instant swap to closed (`-duration=0`,
artifacts under `<out>/anchor/`) and then sweeps 0° → 100°, which is the
"book from closed swaps cover to inner" case in Apple's help text. A sweep from
open to book also lands on `.partiallyOpen`/inner (checked). `closed` and `open`
are the ends of the range and need no anchor; `angle` sweeps from wherever the
hinge is unless `POSTURE_ANCHOR` says otherwise — record the starting posture
with any angle result.

### Other mechanisms, not used

- `-[SBDisplayToolServiceCoordinator performHingeReplayWithSettings:samplesPath:completion:]`
  replays loops of the recorded `hinge-samples.csv` (SBFHingeReplaySettings,
  `-mode=swap|party -loop= -band=fast|medium|slow …`). It is for motion studies,
  not for landing in a posture; reachable the same way if a later agent needs
  realistic sweeps.
- Hinge-angle HID events into the sim's backboardd (the VM's Hinge dylib path)
  were not tried: the display tool already exercises SpringBoard's resolver path
  with Apple's own sweep, and the sim's CoreSimulator side offers no hinge HID
  service (`simctl io enumerate` lists none).
- Xcode/CoreSimulator: no fold control found (no Simulator.app on this host;
  DeviceKit has no hinge strings; `simctl` has no posture subcommand).

## Limits

- **CoreMotion is not driven.** The sweep lives in SpringBoard's
  `SBFDevicePoseProvider`. `CMAngleManager +isAvailable` is YES (range 0–180°) and
  SpringBoard's `_cmAngleManager` reports `isAngleActive` YES, and
  `CMMagicPoseManager +isAvailable` is YES, but nothing here makes locationd's
  angle stream or magic pose follow the posture. Treat app-side CMAngleManager /
  CMMagicPoseManager / CoreDevice hinge values as unverified until a probe shows
  them changing. Likewise backboardd sees no hinge HID event.
- **What reaches apps is unverified.** Preferences moves between panels, but
  whether `UIHingeInteraction` / `_UISceneHingeStateClientComponent` report the
  posture in an app is for the app-side domain to establish.
- Every probe stops the target for ~3 s; a swap started by a probe begins only
  after lldb detaches.
- SpringBoard's `[UIScreen mainScreen]` is the cover (`Main`, "LCD") in every
  posture. The inner `UIScreen` ("LCD-1") reported bounds 669×951 right after
  boot and **951×669 after the first unfold**, and stayed 951×669 in all later
  postures, closed included. Record the posture history with any inner-screen
  value.
- Only portrait device orientation was exercised (`Device: portrait (1)`;
  `interfaceOrientation` 1 in every record). `-deviceOrientation=` is accepted by
  the swap.

## Record format

One JSON file per domain (`<domain>.json`, e.g. `screens.json`, `mobilegestalt.json`),
raw transcripts under `raw/<domain>/`:

```json
{
  "meta": {
    "domain": "screens",
    "runtime": {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "version": "27.1", "buildversion": "24A94425"},
    "device": {"name": "duo-baseline-harness", "udid": "D13582ED-…", "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"},
    "xcode": "Xcode 27.1 Build version 27A9275",
    "host": "27.0.1 Apple M5 Pro",
    "date": "2026-10-29T05:44:07Z",
    "postures": [ /* the posture.zsh JSON for each posture used */ ]
  },
  "records": [
    {
      "api": "UIScreen.nativeBounds",
      "kind": "public",
      "process": "SpringBoard",
      "posture": "book",
      "orientation": "portrait",
      "call": "[UIScreen screens][1].nativeBounds",
      "value": {"x": 0, "y": 0, "width": 2007, "height": 2853},
      "error": null
    }
  ]
}
```

- `api`: stable `Class.member` or function name — the join key with vphone-duo.
- `kind`: `public` (SDK headers) or `private`.
- `process`: executable name the call ran in (`SpringBoard`, `backboardd`, `Preferences`, …).
- `posture`: `closed` | `book` | `open` | `angle<deg>` as passed to `posture.zsh`
  (add the starting posture in `call` or `meta` for angles).
- `orientation`: `portrait` | `portraitUpsideDown` | `landscapeLeft` |
  `landscapeRight` — the interface orientation of the scene the call ran under
  (SpringBoard: the primary window scene).
- `call`: the exact expression, enough to re-run it.
- `value`: JSON — numbers and booleans as such, `CGRect` as `{x, y, width, height}`,
  `CGSize` as `{width, height}`, objects as their `description` string, `null`
  when there is none.
- `error`: `null`, or the error / exception / lldb error text (then `value` is `null`).

`smoke.json` is in this format; `tools/smoke.zsh` shows how a probe's JSON line is
tagged with process, posture and orientation and merged with `meta`.
