# HomeView distance-adaptive UI

Investigation: tvOS 27.2 HomeView 24V514, HomeAccessory17,1 / J490AP. This ledger distinguishes shipped-code observations from runtime proof. Initial research and implementation left installed bundles unchanged; the user subsequently authorized deployment, recorded below.

Current deployment: HomeView is running with host and guest environment
`2.15.0-local.b1ed0817`. The scoped service patch is applied and the installed
daemon's read-only `homeview.distance.get` succeeds. Near/Far/reset input and
visual behavior are left for the user's requested manual test.

## Native model and distance mapping

The shell owns `LevelOfDetail.Aggregator` and `LevelOfDetail.SessionSource`. Session selection prefers an active person matching the current persona, with an active-person fallback. The perceived-person distance enum has `near` and `far` cases. The selected near case maps to native UI detail **2 (increased)**; far maps to **0 (decreased)**. Native detail **1** is named **standard**; a separate physical middle-distance zone has not been established.

Evidence: BreadBoardFramework SHA-256 `f3336f3e9aade1bdfb02fcb50a10880f42c26f892119f635a29aa9e97573bd93`, Session derivation `0x250f8c3a8` (`ev_ac0a387ce9f0972ece5ec99c28ed7e2bcb5f3b3689f8cfe10bd93eb445b18893`) and fallback `0x250f8ca6c` (`ev_86d6cd02a5d0493d477b7cadd302b89f8fab6e8b7a09e22d13606f8e59f7f809`). Session publisher `0x250f8c7b4` (`ev_f3606c84411e83f32f2825ca14a599bc9a6bde809c545c7b1d3472aefedd5903`). Enum descriptions in BreadBoardServices `0x25123eb98` (`ev_cdf38a4bea1ac2b0611537839c3293c7bb696b4c146de332c8017bb847fef2a2`). Live read-only request construction independently printed decreased/standard/increased for 0/1/2, with other override fields absent.

This is an override of the actual distance-derived aggregator. It is not a display-style substitution: aggregator apply `0x250f7f3ec` stores optional detail (`ev_37e5a162f944c92f37e733891a27dbbcb15c13de9f3a80f09e70e8b07336c4d6`); publishing chooses override when present, otherwise source detail (`ev_44c9d112f001161709bcb9ab19ddb1edc7df519ec80a9b8197f241c9d564b6be`). Environment publisher calls this path (`ev_f73fa7e23f2a01d9f7d4d60448063a89e6a3c54ea04a05297fca60bdb5a43308`). BreadBoardUIServices contains the downstream `BBSUILevelOfDetailTrait` and staged detail updates.

Native input types include `LevelOfDetail.PassiveCameraAdaptor`, `AttentionAwarenessSource`, `NearbyPersonPresenceProvider`, and `NearbyInteractionMonitor`; the latter imports `NIDevicePresenceConfiguration`. Perceived entities carry distance, metricDistance, gaze, engagement, persona and recognition confidence. The shell consumes EntityKit distance/pose/gazing/presence/engagement/persona observations; perceptiond is an on-device mobile service with Conclave configuration. The types alone do not establish the upstream sensor hardware or its pairing requirements. The exact EntityKit query and separate known-device NearbyInteraction path are recorded below. The override service itself takes no phone/pairing input and applies directly to the shell's local detail aggregator.

Physical units, thresholds and hysteresis remain unverified. EntityKit has `DistanceProvider`, `DistanceConstants`, near/far/armsReach coding keys and logs for `nearMeters`, `midMeters`, and `armsReachMeters`, plus an optional `DistanceOverrides.json` load path; no such JSON resource is present in the supplied root's EntityKit directory. These strings alone do not establish numeric thresholds. The host control therefore exposes detail modes, not a fabricated meters slider.

## Service ABI and reset scope

BreadBoardServices SHA-256 `ec3350999682d66598d151fcf7bc918e132e39ea50ba010bad5ea6de05defc5d` provides `BBSEnvironmentServiceServerInterface`:

- `fetchCurrentEnvironmentWithReply:`
- `applyEnvironmentOverrides:completion:`
- `resetEnvironmentOverridesWithCompletion:`

Requests are `BBSEnvironmentOverrideRequest initWithActivePersonaUniqueIdentifier:displayStyle:levelOfDetail:backlightState:`. Persona is nullable NSString; the remaining fields are nullable NSNumber. Integer detail is restricted to 0...2 (the native description path traps on invalid cases). Nil style/persona/backlight fields preserve previous overrides; they do not clear those fields. Constructor evidence `ev_d531a53b1f54fe27377ba6cd20459e708ab5ed995efc0545998b16f434ea0a9a`.

Server apply merges the request into a single stored optional Overrides value: `0x2511406e4` (`ev_5f0d7d723acc4d4e20ae9e91328ea1ac388407311bfd9913ed5a08f5fda1f6b6`), merge implementation BBS `0x251265458` (`ev_96b738ccaa783c321987c6e3bc118cb496637d095e9d0dd2dc21812e951f360c`), commit and publication `0x25114081c` (`ev_fe3a39859793a4882200c3fc22a4e4e974ad027cbfdd8be96a9e3af6f8da6bb4`). Reset constructs the entire optional Overrides=nil and republishes the environment: `0x251140d20` (`ev_2157eadda8515c1a400f5117ee901a1e368203a7a23cdd1d79e786a3b74abe64`) and `0x251140de4` (`ev_d80a30447f7d3ea907dd9958d44a84f1267f6e9e6b9466ee7cd4571e65ca94d1`). Thus reset scope includes persona, display style, detail and backlight simulation. No selective clear-detail API is established. Fetch returns effective environment values without an override mask, so effective detail cannot identify an override's origin.

Transport construction follows native `BBSEnvironment.Controller`: endpoint mach name `com.apple.breadboardservices`, service `com.apple.breadboard.environment-service`, instance nil (`ev_dafb2ff094158ddcb009d766d61d928a1b88f954e84ee46e4fbb88b59520f2f7`). A copied BSMutableServiceInterface wraps the canonical server protocol using BSObjCProtocol (`ev_594bd54164b6ffaec25126820a9aeae90655c464d98b2d8dc73409ba1f6f121e`). BSServiceInitiatingConnection options use the default multiplexer; configure sets interface, userInitiated service dispatch queue, and lifecycle handlers, then activate. Native PLS reads the remote target asynchronously after activation.

The server gate checks client entitlement `com.apple.private.breadboard.environment.read-write`, then a separate availability predicate; rejection logs distinguish “Client is not entitled” and “Service is unavailable” (`ev_059065e22f243acd69c0b1b41c4e3fc3adb2bf12c04c47ff8725d6337a101ae7`). That availability predicate remains under investigation.

## Current runtime boundary

A temporary native arm64e helper, signed with platform-application, the exact read/write entitlement and the mach-lookup exception, was uploaded to `/var/tmp/homeview-distance-probe` through the existing guest control socket. Read-only fetch under both root and mobile UID501 returned BSServiceConnectionErrorDomain code 3, “XPC error received on message reply handler.” Waiting for the activation handler instead times out after five seconds. BreadBoard remains running PID39 with last exit 0. No environment mutation, reset, pairing or bundle installation has been performed; no near/far screenshot proof exists yet. The helper must be removed after diagnostics.

The in-progress RPC implementation is bounded and fails closed on service/ABI errors. `homeview.distance.set` modes near/standard/far use native integer detail2/1/0. Explicit automatic reset requires `reset_environment:true` and discloses `reset_scope:"environment"`. Unknown initial ownership is reported as mode unknown, override_active null. A successful effective readback alone must never imply that another tool's override is absent. Final connection recovery, readback and runtime tests are pending; host UI integration on an installed updated bundle remains pending user availability/authorization.

## Reveal and validation procedure

Extract BreadBoardFramework, BreadBoardServices, BreadBoardUIServices and EntityKit from the supplied HomeView shared cache with ipsw `dyld extract --slide --objc`; open the matching extracted image in REA. Follow Session detail selection through Aggregator publication and Environment publisher, then trace request merge and reset separately. Use the addresses as documentation of this exact artifact, not runtime offsets.

Before any mutation, resolve service activation/gate failure. Then establish a test-owned baseline, capture native environment and screenshot, apply far and near while keeping the helper/connection alive, verify native completion plus independent readback and visual layout changes, reset with explicit environment-wide acknowledgement, and confirm restored automatic state. Do not complete setup, provision HomeKit, pair or sign in for this test. No claim of runtime success should be made until these steps pass.

## Host controls and deployment boundary

The HomeView Controls panel has a Viewing Distance section. Near, Standard
Detail and Far send the native detail overrides; Standard Detail is not a
physical middle-distance claim. Current mode is Unknown until the daemon can
establish ownership. Refresh reads native effective state. A failed write
invalidates the displayed mode and requires a new read, since a lost reply may
follow a committed write. Disconnect invalidates outstanding replies so an old
connection cannot overwrite a newer read.

Automatic uses a button explicitly labeled Reset Environment Simulation. Its
help text lists persona, display style, detail and backlight because the native
reset clears those overrides together. Near/Far requests supply nil for the
unrelated request fields. These controls are shown only for HomeView; an older
guest without the capability reports that distance simulation is unavailable.

After an updated bundle and environment are authorized and installed, the
experimental `dyld-exp-homeview_environment_service` patch must be explicitly
selected. It is off in every shipped preset. It is admitted only for HomeView
and gated to the reviewed 27.2 userland; changing its selection uses the normal
guest patch install/undo path. It opens only the environment service's
internal-install branch, retaining the client entitlement check. Global
`os_variant_has_internal_content` remains unchanged. The added vphoned
entitlement is `com.apple.private.breadboard.environment.read-write`.

RPC examples for the future installed environment (not executed as live writes
during this investigation):

```zsh
vphone-launchpad-cli guest rpc HomeView homeview.distance.get '{}'
vphone-launchpad-cli guest rpc HomeView homeview.distance.set '{"mode":"far"}'
vphone-launchpad-cli guest rpc HomeView homeview.distance.set '{"mode":"near"}'
vphone-launchpad-cli guest rpc HomeView homeview.distance.set \
  '{"mode":"automatic","reset_environment":true}'
```

The result contains `available`, `mode`, `level_of_detail`, `override_active`,
`applied` and `reset_scope:"environment"`. Unknown ownership has
`mode:"unknown"`, `override_active:null`; an effective value alone cannot reveal
another client's override. Successful writes require native acknowledgement and
a separate fetch, and the requested nonautomatic detail must match that fetch.

The full goal remains incomplete until the authorized installed bundle can
activate the service, Near/Far visibly change native UI, reset restores native
behavior, and the actual host controls pass those same transitions. Offline
patch tests and model tests do not prove those runtime behaviors. Root/mobile
client identity and override lifetime across disconnects remain runtime checks.

## Offline validation, 2026-10-30

- Xcode MCP built the finished VPhone bundle successfully after the final
  patcher fix; bundle admission passed. Build log:
  `/var/folders/xd/m1z8xjr17n96_qtw6tb5z0hw0000gn/T/ActionArtifacts/default/BuildProject/BuildProject-Log-20261030-200349.txt`.
- Xcode ran 94 focused patch catalog, resolution, declaration, version,
  selection, plan, gate and semantic HomeView patcher tests successfully.
  The environment-selected full-cache XCTest fixture was skipped because that
  environment variable was absent; the separate real-cache CLI test below was
  executed. Results:
  `/var/folders/xd/m1z8xjr17n96_qtw6tb5z0hw0000gn/T/ActionArtifacts/default/RunSomeTests/EA7474D8-052E-4A12-AD60-E4326B00BFAB.txt`.
- The host model tests pass all four modes, refusal, unavailable/malformed
  replies, unknown ownership, a committed write with a lost reply, and an old
  read arriving after reconnect. Daemon logic tests pass 410 checks, including
  explicit reset acknowledgement policy.
- Cloned the supplied cache to `.build/homeview-cache-validation` with APFS
  clones. The actual built CLI's dry run located exactly `0x251269fec`.
  Applying changed `e00e0036` to `1f2003d5` and re-attested only slot 922 in
  `.48`. Independent `ipsw dyld disass` confirmed the preceding `cbz w28`
  entitlement rejection and internal getter call were untouched. Byte comparison
  of that chunk found only the four instruction bytes and its 32-byte slot
  hash changed. Repeating reported already patched with no signature writes.
- `cfw patch-dsc-revert` restored the one captured instruction and re-attested
  its page. Every cloned cache file then compared byte-identically to the
  supplied cache. Both original and restored `.48` have SHA-256
  `e1b3a717e9e93b81f6542aa7ee11ded01a0e83b5c91fa8b65ba7bc67ee87dd67`.
- No installed bundle, guest cache, VM binding, setup state, phone pairing or
  account was changed. Temporary diagnostic helpers were removed. Near/Far
  visual behavior and the installed host control remain unverified.

## EntityKit distance input and separate device-presence input

The following is static shipped-artifact evidence from the HomeView 27.2 cache. It identifies the shell's consumed observations; it does not establish every upstream sensor producer or prove that an actual donor device's sensing works without account setup or pairing.

`EntityMonitor` owns `EntityKit.DynamicEntityModel`, an `entitiesPublisher` of `Set<PerceivedEntity>`, a persona-provider closure, and a listener task. `PeopleMonitor` separately owns an entity-listener task and a people publisher. These fields are visible in the recovered ObjC/Swift class metadata. The default entity-model construction at `0x251155fa4–0x251155fbc` calls `DynamicEntityModel.init()`; it takes no phone or pairing parameter.

The entity query requests eight components: `EKC.Distance`, `PersonaIdentifier`, `UserIdentities`, `Pose`, `Gazing`, `Presence`, `Engagement`, and `IdentityAggressors`. Its filter combines `EKC.Classification.person` and `EKC.Presence.viscinity` (the spelling is the shipped enum case), visible at `0x250f83bb8–0x250f83cf8`. At `0x250f8479c–0x250f84828`, `EntityMonitor` selects `EntityDescriptor.anyEntity`, obtains `DynamicEntityModel.remoteModel`, and invokes `stream(query:from:)`. The returned `EntityModel.RemoteQueryAsyncIterator` feeds conversion routines `0x250f866bc` and `0x250f86784`.

The conversion at `0x250f86e4c–0x250f86ec0` deliberately collapses EntityKit's distance categories:

| EntityKit `EKC.Distance` | `PerceivedEntity.Distance` |
| --- | --- |
| `armsReach`, `near` | `near` (byte 0) |
| `mid`, `far`, other cases | `far` (byte 1) |

Thus an upstream `mid` observation does not imply the shell's standard-detail mode. Separately, `0x250f86fb8–0x250f86fec` reads `EKC.Pose.position` and computes its distance to `CartePoint.origin`; an absent pose produces positive infinity. This is the entity's metric-distance field, rather than a conversion of the discrete near/far label into invented meter values. Session detail selection then uses the selected entity's discrete distance as described above.

`NearbyInteractionMonitor` is a distinct device-presence path. At `0x251126874–0x251126938`, it builds `NIRegionPredicate` values named `inner` and `outer` using device-presence presets 4 and 5, creates `NIDevicePresenceConfiguration` with `initWithInnerBoundary:outerBoundary:error:`, and sets `allowedDevices` to 2. The native `NIInternalUtils.NIRelationshipSpecifierToString:` at `0x21c51b4ec` indexes a table at `0x2609905c0`; table entry 2 points to the literal `Known Devices` at `0x21c55751d`. That exact label does not establish which account or pairing relationships qualify. The delegate callback `session:object:didUpdateRegion:previousRegion:` at `0x2511278e0` reads `deviceIdentifier` and updates a set of nearby object identifiers. This device-presence code is not the converter of `EKC.Distance` into `PerceivedEntity.Distance`.

For the host simulation control, the native environment override consumes only the level-of-detail request and has no phone/pairing input. For physical sensing, the established app-side pipeline is EntityKit person observations into entity/session detail selection, alongside a separate known-device NearbyInteraction path. Whether EntityKit's upstream producer or the known-device source requires particular setup or pairing in a given hardware configuration remains unverified; nearby/perception entitlements alone do not answer that question.

Artifact and scratch evidence locations:

- Extracted `BreadBoardFramework`: `/tmp/homeview-extract/BreadBoardFramework`, SHA-256 `f3336f3e9aade1bdfb02fcb50a10880f42c26f892119f635a29aa9e97573bd93`.
- Extracted `NearbyInteraction`: `/tmp/homeview-transport/NearbyInteraction`, SHA-256 `eb22c7fa056d3580403cf70497742874cb50fd2841aef18441474d3e95dabf74`.
- Full annotated cache disassembly for the app framework: `/tmp/homeview-transport/BreadBoardFramework.asm`, SHA-256 `d07d314452902870b227c85188aca845c9cc18b83c81c5748b3b6fcc426652bf`.
- Metadata inventory: `/tmp/homeview-bbf-objc.txt`; symbol inventory: `/tmp/homeview-transport/bbf-symbols.txt`.

The disassembly was produced with `ipsw dyld disass --image BreadBoardFramework --cache /tmp/homeview-address-cache --demangle` against the supplied original cache. NearbyInteraction enum-table and description methods were inspected with the same cache's address-based disassembly and extracted-image `ipsw macho dump`. These are reproducible static observations, not a successful physical-sensor replay. No bundle install, pairing, account setup, environment mutation or REA target switch was performed for this subsection.

## Retail service gate resolved

The separate service predicate is the exported BreadBoardFoundation `Platform.isInternalInstall` getter (`_$s20BreadBoardFoundation8PlatformO17isInternalInstallSbvgZ`) at `0x250f0f6f8`. It caches exactly `os_variant_has_internal_content("com.apple.BreadBoard")`, without a preference lookup in this getter. Foundation SHA-256 `f0d08b9cdee8c4292391977ebe87798edf0cedb0478c7e1b78e582f7e639ddaa`; initializer evidence `ev_4380af1e616bf43713680d006f2186b177411bbb1bdfd49d462b477e94ca181c`, getter `ev_77bae608fff892ca3168788c6fe025a9fdf47d4ac002513883227577a5fe88c5`. A bounded read-only native guest call independently returned `internal_content=false`.

In the environment server's accepting-connection function `0x251269eb8` (only `func_251269eb8` in this artifact's symbol inventory), the entitlement result is guarded by `cbz w28` at `0x251269fe4`. The following call at `0x251269fe8` resolves via stub `0x258063a60` to the Foundation internal-install getter. `tbz w0,#0` at `0x251269fec` selects the “Service is unavailable” rejection path at `0x25126a1c8`. This explains an entitled client being refused on the retail guest. The implemented optional DSC patch changes only this environment-service branch and preserves the prior client entitlement check; it does not change os_variant or Platform.isInternalInstall globally. Clone-based application, repeat and undo passed as recorded above. No such patch has been deployed to the VM.

The bridge retains a bounded native connection attempt so a later scoped service repair can work without falsifying global internal-install status. Activation failures report that the retail service requires the scoped simulation-service patch. Timeout/disconnect invalidates ownership; reconnect retires the old connection and ignores stale generation callbacks. Detail getters are checked against runtime NSInteger method encodings. Writes require native acknowledgement and a separate fetch with matching native level before returning applied=true. The explicit environment-wide reset guard is enforced at the RPC boundary. Total native bound is up to five seconds each for activation, mutation reply and independent readback.

Both temporary diagnostic helpers were removed from the guest by exact filename. No environment overrides were written or cleared, and no processes, settings, pairings or bundles were modified. Near/far visual verification remains pending a repaired service in an authorized updated bundle.

## Bridge final review

Runtime checks validate the request constructor's object argument ABI, primitive NSInteger detail getters, and all three canonical protocol methods' void return/object/block argument shapes. Nested callback signatures are derived from inspected native callers because Objective-C protocol method encodings retain only `@?` for a block. An atomic disconnect check before returning ownership/readback rejects a connection lost during the acknowledgement/fetch sequence. Activation timeout marks the connection for retirement; a later request creates a fresh connection, and generation checks ignore retired-connection callbacks.

Guest-independent RPC policy checks verify that automatic reset without explicit acknowledgement is rejected before native transport, acknowledged reset is admitted, near/standard/far require no broad-reset acknowledgement, and unsupported enum strings are rejected. The daemon logic suite passed 410 checks with zero failures. Native arm64e tvOS compilation with `-Werror -fsyntax-only` passed.

Both root and mobile UID501 read-only probes failed at the retail internal-install gate, so those attempts do not establish whether an activated service admits cross-user clients. The endpoint is a launchd Mach service hosted by mobile BreadBoard; there is no evidence yet that the guest daemon must change UID to use it. Keep the daemon's existing identity until an authorized repaired-service runtime test provides an actual identity-specific failure.

## Override lifetime and mutation reply ordering

Static lifetime audit of these same artifacts establishes shared publisher state, rather than a per-client override bag. BreadBoardFramework wiring at `0x251196ee8` creates an `EnvironmentAggregator`; its read/apply/reset closures all capture the same publisher reference (the three context stores at `0x251196f5c`, `0x251196f70`, and `0x251196f84`). That aggregator is passed to `BBSEnvironment.Listener` at `0x251196ff8`. `LevelOfDetailPublisher` metadata identifies its one optional `_overrides` value. In BreadBoardServices, listener construction `0x251269c60` allocates its Coordinator from the supplied controller before creating the connection listener. Accepted connections configure that Coordinator as `interfaceTarget` in `0x2512684e8`; they do not create a separate publisher or override value. Wiring evidence: `ev_8fd96d375cec79e2f7d4412704b83418f5640ffc97581ccd858c86fa4c960318`, listener construction `ev_5f03078019404c11f708a3fd52a02c4a76844d5c74089868fa040f7e9c12d795`, connection configuration `ev_657e1ad6b3b5514f6df7cb4d17c6a38706ea2dc9d187171949bccf9628de5bec`.

The accepted connection's invalidation callback is `0x25126a6f4`, whose captured context contains the client PID and whose body calls `0x2512685ec`. The latter only logs `Connection invalidated {connection=%@, client.pid=%d}` and releases logging temporaries; it does not invoke apply/reset or access the controlling publisher. Invalidation therefore has no native reset action in this inspected path. The static implication is that closing Controls, retiring a daemon client connection, or losing a client does not automatically restore automatic detail while the shell publisher remains alive. Explicit reset or another override operation changes the shared state; no persistence across publisher/BreadBoard restart is established. Callback evidence `ev_19d973924673cf0b91c42e6c4d793d69bc9dae9eecd163817f337095af196931`, full invalidation body `ev_e785c7fc81fd42aeec47db8e28cb1f764d43d2da68c8a4ce232725e7a740f77b`. Actual disconnect/restart behavior remains a runtime validation item because the retail gate prevented successful service activation during this investigation.

Mutation replies are completion results, rather than acknowledgements sent before the operation runs. `applyEnvironmentOverrides:completion:` (`0x251269364`) starts an async task; `0x251268f80` dispatches the controller's async apply witness and resumes at `0x2512690ec`. Only its success continuation `0x2512691f0` constructs `BBSEnvironmentValues` from the returned environment. The outer continuation `0x25126959c` then invokes the original reply block with environment in `x1` and nil error in `x2`; on failure it supplies nil environment and a converted `NSError`. Reset (`0x2512699b4`) likewise awaits its controller reset witness in `0x251269708`, resumes through `0x2512698b8`, and wraps the environment in `0x251268b40`; its outer reply continuation `0x2512568cc` / `0x25125550c` uses the same `(environment, NSError)` result convention. Apply-witness evidence `ev_62eceb9e518354745d6dc89281bca2387d7fdfa80f25295f539c83957b5c22e7`, apply result continuation `ev_8be08cb2611380323fcac68dc3ba12e7cf53a53b66c2d7827796da45f1db4009`, reset witness `ev_b3dd08b0facb0a59652eed052154f67435bcc5b2b2e1a0700502d0d92d2b50e0`, reset result continuation `ev_c3f39df806a3f99dc82ea16ca32204e3a7a9634f46d8e63ccf92d1201983d150`.

The already-recorded publisher commit paths store the merged/nil `_overrides`, update publication, await `0x25113f4d0`, then invoke the current-environment reader `0x25113fe04` before returning (apply tail `0x2511409fc–0x251140aa4`; reset tail `0x251140fc8–0x25114106c`). Thus the server's successful mutation reply follows the async publisher commit and carries its resulting environment. It is not evidence that a UI frame has rendered, and another client can subsequently change the shared state; the bridge's separate fetch and future visual verification remain appropriate.

Additional reproducible disassembly: `/tmp/homeview-transport/BreadBoardServices.asm`, SHA-256 `e8c1eec5e35eecee6826d37fbbb753302ae115a3a06ef915e30f6d013b48a52a`; the BreadBoardFramework disassembly and binary hashes are recorded above. This audit performed no guest calls, environment writes, bundle updates or source-code changes. REA sessions were closed after inspection.

## Prepared rollout input, not applied

The VM remains bound to host/guest environment `2.15.0-local.176e4e80`
(`launchpad.json` read back on 2026-10-30). Its recorded selection is `homeview`
with only the existing setup bypass explicitly allowed. Preparing distance
simulation must preserve that current choice: `fw export-preset` with a new
`--allow` argument replaces a VM's override list rather than appending to it.

The actual built CLI exported these local artifacts without changing the VM:

```zsh
vphone-cli fw export-preset HomeView \
  --output .build/homeview-distance-validation/homeview-current.plist
vphone-cli fw export-preset \
  --preset .build/homeview-distance-validation/homeview-current.plist \
  --allow dyld-exp-homeview_environment_service \
  --output .build/homeview-distance-validation/homeview-distance.plist
```

Both exported selections are block lists. Comparing them proves that the
distance preset removes exactly `dyld-exp-homeview_environment_service` from
the blocked set and adds no blocked entries. Patch sets and parameters are
identical, and the existing setup bypass stays allowed. These are reviewable
inputs for a future authorized test, not a changed machine configuration.
Re-export if the VM's choices change before deployment. Applying this preset,
installing the updated bundle/environment and booting its native service
remain pending user availability.

## Completion audit

| Requirement | Current authoritative evidence | Status |
| --- | --- | --- |
| Identify what drives the distance-adaptive UI | EntityKit person query, categorical conversion, session selection and local detail aggregator traced in the supplied 24V514 binaries | Established statically; physical sensor behavior not replayed |
| Determine whether an iPhone VM is needed for simulation | Native override takes local detail values, and its inspected apply path commits directly to the shared publisher; separate known-device presence path documented | No pairing input is needed by this simulation path; upstream physical-sensing prerequisites remain unverified |
| Add host controls | HomeView-only SwiftUI section and model compile in the finished bundle; mode/readback/error/reconnect tests pass; actual section renders at the 460-point minimum width with mocked readbacks | Implemented and layout reviewed; input and installed control flow still unverified |
| Add functioning guest transport | Canonical protocol/constructor ABI checked; reply order traced through async commit; installed daemon successfully activates and fetches native state after the oneway-void fix | Live read transport and root-client access verified; mutations still await the user's test |
| Enable the retail service reversibly | Optional declared patch changes one service gate, preserves entitlement checks, re-attests its page; actual CLI repeat/undo proves byte-identical cache restoration | Applied to HomeView after authorization and recorded in its Guest receipt; remains off by default in shipped presets |
| Prove Near/Far adapt the actual native UI and reset restores native behavior | Requires an activated guest service, native readbacks, and before/after screenshots through the actual host controls | Missing; cannot claim end-to-end success |
| Honor the no-update constraint | No installation preceded the user's explicit authorization; subsequent deployment uses Launchpad's helper | Honored; authorization now provided |

The goal is not complete. The user will test Near/Far/reset on the updated VM.
No additional phone VM, account provisioning or global internal-build change is
justified by the available evidence.

## Local host layout verification

A standalone Swift/AppKit harness compiled the unchanged production distance
section and model with a mock observable guest control. Self-captured
`NSHostingView` images at the actual Controls minimum width of 460 points show
the initial Unknown state, Automatic/reset state, and unsupported capability
state. The complete reset label and its environment-wide scope explanation
are readable, and no production text overlaps or clips. Evidence is under
`.build/homeview-distance-ui`: `self-initial.png`, `self-reset-layout.png`,
`self-unavailable-layout.png`, and `verification.md`.

This verifies rendering with mocked readbacks, not button input or live guest
behavior. The external CUA observer stalled before returning a hierarchy or
screenshot and was intentionally canceled; its exact helper was terminated.
The subsequent self-contained rendering runs exited normally. SwiftUI exposed
no actionable controls through the attempted in-process NSView/AX routes, so
no selection/apply/reset interaction is claimed. The mock log contains only
reads; model tests remain the evidence for request construction. No installed
bundle or VM was modified by either attempt.

## Authorized deployment and read-only readiness check

The user authorized bundle/environment installation on 2026-10-30 and reserved
Near/Far/reset testing for themselves. Launchpad installed local build
`2.15.0-local.938b13aa` with host policy/preflight passing. The VM's `homeview`
selection retained its existing setup bypass and explicitly added only
`dyld-exp-homeview_environment_service`. `cfw update-environment` applied the
reviewed instruction at `0x251269fec`, re-attested slot 922 in `.48`, and recorded
the service patch in the Guest receipt. The first boot reached vphoned, but
the daemon's initial native ABI validator rejected the service before opening
its connection.

A temporary read-only runtime probe found the protocol's exact return encoding
is **`Vv` (oneway void)**, not plain `v`. Its three method encodings are
`Vv24@0:8@?16`, `Vv32@0:8@16@?24`, and `Vv24@0:8@?16`; the request constructor
is `@48@0:8@16@24@32@40`. The validator now removes standard Objective-C type
qualifiers before checking the underlying ABI. A native regression test uses
oneway protocol fixtures, the exact observed encoding, an invalid callback
type and a missing method. It passes without weakening the argument-count or
block checks.

The corrected native bridge, compiled into a temporary root probe with the
daemon's exact entitlements, successfully activated and fetched the native
environment without any override write. Both diagnostic files were removed
from the guest. Xcode then built the finished bundle successfully (log
`BuildProject-Log-20261030-203939.txt` in the same ActionArtifacts directory
recorded above). Launchpad installed **`2.15.0-local.b1ed0817`**, with policy
and host preflight passing, stopped HomeView, updated its guest environment,
and restarted it. Its host and guest environment bindings both name this
version; the boot chain remains `2.15.0-local.0f803fd7`.

The installed daemon's read-only RPC now returns:

```json
{"applied":0,"available":true,"level_of_detail":2,"mode":"unknown","override_active":null,"reset_scope":"environment"}
```

This verifies the patched service activates for vphoned running as root and
returns the expected native state. Unknown ownership remains intentional;
an effective detail value does not reveal another client's override mask.
No Near/Far/standard/automatic mutation was sent by the agent. HomeView is
left running for the user's test under **Device → Controls → Viewing Distance**.
