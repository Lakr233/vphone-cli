# HomeView distance: native UI consumers

Static follow-up for HomeView tvOS 27.2 / 24V514, 2026-10-30. This complements
`homeview_distance.md`; it does not establish screenshot or runtime success.
No guest writes were performed in this investigation.

## Findings that affect the live test

- The environment override publishes the requested value as **primary detail**,
  with secondary detail absent. It does not leave the physical source as
  primary and place the simulated value in secondary. See the typed payload
  trace below.
- Settings deliberately pins its navigation content to increased detail
  (Near). Its unchanged appearance is expected, even when the system override
  and scene trait change.
- Music has concrete controls gated by increased detail: product-page More
  and Back/Close buttons. Far should remove these; Near should restore them,
  provided the product page exists and receives the trait.
- PebbleUI contains actual changes to fonts and label geometry. LOD is not a
  promise that every screen, wallpaper or clock must visibly change.
- The bridge's native trait default is decreased detail (0). If its scene
  component is absent or fails to supply an override, a view can remain Far
  despite a successful environment service readback.

The parent live investigation independently reported environment readbacks
0/2, Aggregator applying overrides 0/2, and FrontBoard settings propagation.
Those reports narrow the remaining boundary to the target scene/trait/view,
but do not prove the value in each client's actual view environment. The
purple fullscreen clock's specific LOD consumer has not been established here.

## Typed payload: override really becomes primary

BreadBoardFramework `LevelOfDetail.Aggregator` apply at `0x250f7f3ec` stores the
requested integer at object+0x98 and an optional-present tag 0 at +0xa0
(`0x250f7f578`, `0x250f7f57c`), then calls publication `0x250f7f7a0`.

Publication tests that tag at `0x250f7f960`:

| State | Arguments passed to native Update initializer | Result |
| --- | --- | --- |
| No environment override (tag 1) | x0/x1 from source fields +0x80/+0x88; w2 from +0x90, call `0x250f7f97c` | Original source primary and optional secondary |
| Override present (tag 0) | x0=requested value from +0x98, x1=0, w2=1, call `0x250f7fb78` | Requested primary, secondary=nil |

The latter logs `Publishing level of detail override`. Both paths yield the
constructed payload through `CurrentValuePublisher.yield` at `0x250f7fdb4`.
This is a typed payload trace, beyond the environment service's effective
readback.

The initializer is not inferred from register convention alone:
BreadBoardUIServices `Update.init(_:secondary:)` at `0x251381b44` stores x0/x1
at payload+0/+8 and w2 at +0x10. `Update.primary` at `0x251381b30` reads +0;
`Update.secondary` at `0x251381b38` reads +8 and its optional tag at +0x10.

REA apply `ev_345edfb03842da17a28f42f5fd81191b5427b29785c570b669213a0fc870d3ac`;
publication `ev_d193071912a154f510ae994150ffd46d64580570b10ac36a749b2341d7a38958`.

## Scene settings to UIKit and SwiftUI

1. BBF scene configuration at `0x2510b48cc` configures the scene's
   `BBSUILevelOfDetail.SceneExtension.HostComponent` with its Aggregator.
   DisplayStyle is configured separately later in this setup path.
2. BBUI's async consumer (`0x25137e5fc`, continuation `0x25137ead0`) consumes
   `Publishing.UpdateSequence`. It calls update handler `0x25137f16c`, then
   `0x25137f49c` inside the scene update transaction.
3. `0x25137f49c` writes `bbsui_levelOfDetail` from Update.primary, writes the
   optional secondary into `bbsui_levelOfDetailOverride`, and sets
   `bbsui_levelOfDetailOverridden` according to secondary presence. Its useful
   diagnostic is `Applied update {primary=..., override=..., overriden=...}`.
4. `SceneSettingsDiffAction._performActionsForUIScene...` at `0x25138273c`
   checks the primary-detail diff. Its registered callback `0x2513830e8` →
   `0x251382b68` calls UIWindowScene `_componentDidUpdateTraitOverrides:`.
5. `WindowSceneComponent._traitOverrides` (`0x251382d14` → `0x251382dc4`)
   reads `UIScene._FBSScene.settings`, gets **primary** detail with
   `0x25137dd58`, and constructs a UITraitCollection containing
   `BBSUILevelOfDetailTrait`. This getter does not substitute the secondary
   scene field.
6. Both `UITraitCollection.bbsui_levelOfDetail` (`0x2513821e8`) and legacy
   `.levelOfDetail` (`0x2513826dc`) read the same trait definition. Its Swift
   and ObjC defaults (`0x251382160`, `0x251382368`) both return **0**.
7. PebbleUI `EnvironmentValues.levelOfDetail` (`0x255a0c04c`) is a SwiftUI
   `UITraitBridgedEnvironmentKey`. Bridge `0x255a0c94c` reads the native
   `bbsui_levelOfDetail` getter and maps 0/1/2 directly to
   decreased/standard/increased. `foregroundAmount` is an alias of this key.

For an Objective-C runtime observer, these UITraitCollection convenience
getters are Swift-only extensions, not Objective-C selectors. Read the native
`BBSUILevelOfDetailTrait` class with UIKit's public `valueForNSIntegerTrait:`.
The native Swift and Objective-C trait definitions share identifier
`com.apple.breadboard.level-of-detail` (`0x251382168`, `0x2513821a8` and the
Objective-C bridge around `0x251382368`). UIKit's SDK `UITraitDefinition`
documentation explicitly specifies that the identifier maps Swift and
Objective-C definitions to the same data. An unavailable convenience selector
must be reported as unavailable, never interpreted as detail zero.

The client scene extension's `setScene:` (`0x25138133c`) lazily registers this
window component via `0x2513cc4e0` and UIScene
`_registerSceneComponentClass:withKey:predicate:`. The traced registration
predicate checks the scene's component by key (`0x2513c1820`). No second
internal-install check was found in these traced registration/trait methods;
that is a bounded observation, not proof that all framework startup paths are
unconditional.

Useful REA evidence:

| Claim | Evidence ID |
| --- | --- |
| Host stream consumes native updates | `ev_82afea7b634d890465293c1e8218002bd12e642c29e7342f6338e6a3b29f1814` |
| Scene writer and applied-update log | `ev_d687fdc0ecb853ea3e936393d4952aecbbf1b5bd687fa2ef3cc1a14c98c4fb1a` |
| Client diff callback | `ev_affe72d38e8e701d1a001a1d0937009dcf59f71b0b2132e32e113eb9aa8e4af6` |
| Window trait collection construction | `ev_e51986f222aae464142e63e129382588cdacdf9f48dba1ab1b16d5b2c70b4093` |
| Notify UIKit of changed trait overrides | `ev_a493e2bae136e620f70692f9266ef7b9d753e93d976276f4f6c416d78f41dda3` |
| SwiftUI bridge | `ev_984d6ac92ba721639ddcebfb21cf75cd31eab8a5482886e1f4aa95469d553a4b` |
| Trait default 0 | `ev_92905653b784385b58688e90be9ff54c3d121604ee1a752ed3cc8e65759b3c9b` |

## Concrete view branches

### Settings is pinned Near

PebbleSettingsApp `SettingsHostView` body (`0x10012007c`) creates a
NavigationStack and partialPrivilegeBlockingView, then calls
`View.overrideLevelOfDetail(.increased)` at `0x100120c10`, followed by
`.pebble()`. The override covers this navigation content, not merely one label.
The body contains the source-file marker
`PebbleSettingsApp/SettingsHostView.swift`.

REA `ev_e3e96a4af58879cb4248da42fb56207b40ddac50938cb1054488c3b77590a509`.

### Music product-page controls

Music body/helper `0x1000759e8` creates a bordered More menu, wraps it with
`requiredLevelOfDetail(.increased)` at `0x10007600c`, then assigns accessibility
identifier `Music.productPage.moreButton` and label `More`. A second specialized
path `0x1001325e0` does the same at `0x100132c90`.

Helper `0x100139b94` constructs Back or Close according to its detail-page
presenter state, wraps the button with the same Near requirement at
`0x10013a300`, and assigns `Music.productPage.closeButton`.

REA `ev_c2ae83e41a97971a596e2047c1f247d1e7db2401d7a049d434c1adcd6d8dbb2b`,
`ev_d45bfeddafa1d2873edf8612fbc20419acd2034f2a3d4395e09d6e90d3948532`,
`ev_10ffdbbb4bc7297302124a38ff2c45689d1a045f18e92f07181fcd89de0f71b3`.

PebbleUI RequiredLevelOfDetailModifier's ViewModifier witness leads to body
`0x255a0ca70`. It reads the current Environment<LevelOfDetail> through
`0x255a7f6e4` and returns optional content absent when current detail is below
the stored requirement. For requirement2, current0/1 hides it and current2
keeps it. The optional discriminator stores distinguish absent from copied
content in the assembly; this is not just a naming inference.
REA `ev_3d6d18bc1227de773ba0f43427680db9c142566ca6ea48c2f24c96a79aa32b28`.

These targets require a loaded product/detail page. The Music sign-in or empty
library screen is not established as a comparable LOD test here.

### Offline app candidates and their prerequisites

Reminders' single direct required-detail call is `0x1002bda28` in helper
`0x1002bd504`: it wraps AddListView in `.requiredLevelOfDetail(.increased)`.
The native Swift associated type describes an account section containing
ForEach<ListView> followed by this required-detail AddListView. This is an
offline list-management target when an account section exists, but no-account
first-launch visibility has not been established.
REA `ev_2305be241bd627477192b9f4b78e33d9ac87e23b050fd28ec406ccfc046b6a42`.

Alarms' only direct required-detail call (`0x100025990`, helper `0x100025714`)
wraps a MobileTimerUISupport.AppLaunchButton in the Near requirement, then
sets accessibility identifier `launch-alarms-app`. This is an alarm activity
surface, not the app's empty list. Alarms' only explicit override
(`0x10004a1d4`) is scoped to the AlarmCell on/off Toggle, not the whole app:
helper `0x10004a42c` selects decreased detail for accessibility DynamicType
sizes, and otherwise copies its Environment<LevelOfDetail>. The app's
ContentView uses PebbleUI.floatingButton for its Add control and overlays
EmptyAlarmsView when the alarm collection and navigation path are empty.
Neither the empty overlay nor its Add button has yet been proved to branch
directly on LOD here. Do not manufacture a guaranteed first-launch visual
change from framework imports.
REA `ev_1f3169eb13501664c28018f9617fb8231b3a847d91c5a5abc255a4b5021293bc`,
`ev_3b2c20531059aca6290507024395418b79320dc7749de45d1b30f9cc102866e6`,
`ev_0b779e797cfed2a64f847f82dc6238ab7272169ca92ddc68a6c1c10d2bfd89f1`,
`ev_14d93c986e245e3f8396cb7bf66172760255bb4bbce9c6d9dca51116b05a29c9`.

### PebbleUI fonts and label geometry

`UIFont.pebblePreferredFont(forTextStyle:sizeCategory:levelOfDetail:)`
(`0x255a88cdc` → `0x255a88ce0`) branches at `0x255a89000` on detail<2.
Decreased and standard remap subheadline to title3, body and callout to title2,
and footnote to body before resolving the font. Increased retains the supplied
text style. This supports larger, less detailed typography at Far, not a global
framebuffer scaling effect.
REA `ev_d3ae6123df49b78d4c3d095841beee8a749aed6804958fccb125693bd0de0906`.

Native TitleAndIcon label body `0x255acf6f0` reads Environment<LevelOfDetail>
and chooses 16 versus22 and 8 versus12 geometry constants for increased versus
lower detail. TitleAndAccessory body `0x255acdf20` similarly selects gap8/12.
The label-layout helper `0x255ad0390` branches on detail before constructing
its frame constraints. These are actual layout branches; exact screen-space
dimensions also depend on the surrounding layout and explicit overrides.
REA `ev_5d1b1251f1e6baf419ea1490379736cb8fe9205ea5a17c074a8d76744f04d095`,
`ev_24e93619ba907ebca10277cd1b52e63a30d517757744b8efa4f6a867c685cc2d`,
`ev_a08ab43f60d2ffd1af956c54baec12e4526baa957c07422cd3ce9a0a30d3dd0b`.

SystemStatusBar body (`0x255a10bdc`) calls the preferred-font helper with an
explicit detail2 for at least one font request (`0x255a118bc`). That subview
cannot be assumed to resize from the scene trait.
REA `ev_77f7486ce0bf4a93387bd2f6d9513dea0d12f0c22baa95cc7cae48e9b5f0062f`.

### Timers fullscreen activity: strongest offline candidate

A local timer needs no Music catalog or reminder account. The target is its
**fullscreen activity**, whose TimerActivityView associated type selects
AnalogTimerView. The ordinary Timers DetailView is a configuration List and
is not this view. The empty DurationsGrid is not a proven equivalent test.

AnalogTimerView's metadata descriptor `0x10008ca48` names the type and its
native field inventory contains `_lod: Environment<LevelOfDetail>`. Its
appearance handler `0x10000fc68` and change handler `0x10000fe8c` compare
that environment value to `.increased`, updating the same observable
StylingModel boolean (keypath `0x100083080`, stored byte+0x4a). The following
consumers read that exact observed property:

| Consumer | Near (2) | Far/standard (0/1) |
| --- | --- | --- |
| Analog clock layout in `0x1000144c0` | max-width constraint230 | max-width constraint320 |
| Clock scaling in that body | 1 | 1.2 or approximately1.2857 according to remaining time |
| Uppercased timer label font | 22pt | 32pt |
| Bottom-bar toolbar (`0x1000100cc` → `0x10001029c`) | Constructed | Optional toolbar content absent |

The toolbar builder `0x100010738` identifies its Cancel and Pause/Resume
buttons as `cancel-timer`, `pause-timer`, and `resume-timer`. The layout and
font constants were verified in ARM64 conditional selections at
`0x100014dc4`–`0x100014dd4` and `0x1000152b8`–`0x1000152c8`; they are not
pseudocode argument guesses. Frame constraints can still be capped by the
available parent size.

REA appearance/change `ev_159a8e8eb1ebed0c1b3b3aa2d0a6c9d0462c186a49cd33fa54f7121d66bb96c2`,
`ev_50193668921fe6fabb651bf95cf51bcaad48f308f0de4955b8508ce34e19eb62`;
clock/label body `ev_987150c006681ff2249e5d8466de386d9a6d02256d445187ed7a13f9cf504f7f`;
toolbar `ev_bc2c1c9b14ac0d5dc95fcfa27b391b7a327bdebe5975ad474841d245d9e6a180`,
`ev_0c2cec4a888560119506529e19b6904de27cfa68d5ab84d7ff033d87678f99fe`;
button IDs `ev_f75f828415c74a54e6c8461f2ae634d32d0e9c7e7be535b0fea1e4e82bd56c44`.

Timers.Controls body `0x1000438c0` separately compares the inherited detail
to increased: button frames are54 at Near,66 otherwise. It wraps the first
button in `requiredLevelOfDetail(.increased)` at `0x100043d14`; first-button
helper `0x100043fb4` identifies it as Cancel (`cancel-timer`). Pause/Resume
helper is `0x100044414`. However, the app's one explicit override call
`0x100007324` pins a **Controls instance inside Platter** to increased detail.
Therefore the Platter form is not interchangeable with fullscreen analog
activity for this test.
REA `ev_6c94bcd21660c126fc5d9adf6f8726dcf798a154c1ffcafbe9643717e87e2f88`,
`ev_7fa1e88545ca96cd34387feeda0214882f8da62251a01189092bf8951e25387b`,
`ev_c94d82253a3443693d6c244c37606cef20e0f9bdf98148dded5da355004b1b92`.

Static suggested replay: create/start a temporary local timer, display its
fullscreen analog activity, compare Near/Far and the toolbar, then cancel the
temporary timer. This investigation did not perform that replay or establish
that fullscreen activity presentation is working in this VM.

## Update behavior, display style and bounded inventory

The scene HostComponent defaults to UpdateBehavior.primaryOnly (tag0).
primaryWithPrecedingSecondary is tag1; latching is tag2. Latching handler
`0x25137ffbc` stages a reduction while foreground, logging
`Staging level of detail`; it accepts increases and background updates.
Presence of this mechanism does not prove that a particular tested app is
configured to latch. The follow-up below establishes Charcuterie's actual
assignment for ordinary app scenes. No updateBehavior assignment occurs in
the local BBF scene configuration block around `0x2510b48cc`.
REA `ev_0cfba0a02a32d70be668e9805bd9a97c7d7e7e73b0a670da062e5bbcf3a42dfe`,
`ev_266e4d194cf56a03a57a3780310ebc93697e26d09a571e0c6ab9a4a0bb2060e9`.

LOD and DisplayStyle have separate native publisher/scene/trait paths. The
traced font, required-content and label branches read LOD, without reading
DisplayStyle in those decision blocks. A Near/Far simulation does not by itself
request another app, clock face, canvas or display style.

The generic PebbleModifier also has a prototype-settings override path:
closure `0x255a360cc` calls `0x255a90e64` (source marker
`PebbleUI/PrototypeSettings.swift`). That transform preserves inherited LOD
when its stored option is sentinel3 and replaces it for a non3 option. This
is a second possible local override, distinct from SettingsHostView's explicit
Near override. Its live option value was not inspected here.
REA `ev_46bc2d76ad5115ce18f10adb9dfad6a9c842d90378b9174b2f43b1edfbeb9d99`.

Bounded import inventory: Music, Reminders, Alarms and Timers directly import
EnvironmentValues.levelOfDetail and requiredLevelOfDetail. Alarms and Timers
also import explicit overrideLevelOfDetail; Timers' Platter scope is traced
above, while Alarms' complete override scopes remain untraced. Music and
Reminders have no direct overrideLevelOfDetail import in the
examined symbol tables. This does not rule out framework or inlined overrides.
PodcastsPebble has no direct LOD import in its examined table. RushmoreFramework
exports `rm_overrideLevelOfDetailIncreased` (`0x256d05824`), which calls the
PebbleUI increased override; its one in-framework caller `0x256ca0190` remains
unidentified. Do not generalize that helper to all Rushmore widgets.
REA for helper `ev_d308ae3d6704984028874ae568f412621292f250e5769a1251dfb010e3d0d448`.

The supplied FeatureFlags/Domain/BreadBoard.plist lists campoSlice, rushmore,
lantern, displayScale, canvasScalingJ310, appDrawer and other feature-complete
flags; it contains no explicitly LOD-named flag. These names do not prove a
runtime feature's availability or an LOD dependency.

Additional bounded plist inspection: PebbleUI declares only OpaqueSheetBlur;
Reminders declares ContextMenus, ModernEmphasis, SubtasksInSmartLists and
TimeZone. Rushmore declares Andromino, Monarch, SolariumPosters, StandByInfra,
StandByInfraEditing, StandByInfraGallery and Switcheroo; several carry a
DisclosureRequired identifier. No runtime enablement conclusion follows from
these declarations alone.

## Next runtime discriminator

Inspect the **same target scene** at these boundaries, retaining its scene ID:
publisher `Applied update` primary/secondary; FBSScene settings
`bbsui_levelOfDetail`; UIWindowScene trait `bbsui_levelOfDetail`; SwiftUI
EnvironmentValues.levelOfDetail; then a verified consumer such as Music's More
button. A primary0/2 but fixed UIKit trait implicates component registration or
trait invalidation. A changing UIKit trait but fixed SwiftUI environment points
to a local environment override or SwiftUI bridge; Settings already has a
proven override. If both change but the clock stays identical, the selected
clock is not yet a demonstrated LOD consumer. Foreground staging must be
checked per scene rather than assumed from the enum's existence.

## Ambient clock versus app presentation: bounded follow-up

The follow-up question was why a purple fullscreen clock remained visible
after app launch requests, with environment displayStyle=standard and
backlight=ActiveOn. Those environment values do not themselves establish
which Sandwich slice or app scene is foreground. Static investigation did
not prove that the clock was an intentionally modal overlay, nor that another
app had reached foreground presentation.

Rushmore.app's Swift entry point delegates its entire Scene body to
`RushmoreFramework.Rushmore.bootstrap`. Charcuterie owns the relevant shell
presentation layer: SandwichViewModel has separate ambient, app drawer,
app-switcher, live activity, Buddy and Campo slice view models, an
AppPresentationStateSource and a SystemUIVisibilitySource. Native
AmbientContentViewModel holds a SandwichSceneViewModel and tracks editing
and ActiveFacePortalInfo. AppDrawerPresentationGate separately contains a
gesture-suppression AssertableCondition and pro-installer settings. These
fields identify the state boundaries worth inspecting; their declarations
alone do not establish the live state or a blocked gate.

Charcuterie contains native bottom-edge/home-affordance machinery, including
ScreenEdgePanThresholdGesture, onBarSwipeDismiss and home navigation. A
specific localized `Swipe up to begin` at `0x2516ee964` is explicitly commented
as text above the home affordance **at the end of setup** (`0x2516ee9bc`). It
must not be cited as proof that swiping dismisses every ambient clock state.

SandwichViewModel's path `0x25176f0d4` queues a task named
`SandwichViewModel.dismissAmbient` (`0x25176f594`). Async continuation
`0x2517720e8` logs `Dismissing ambient`; continuation `0x2517722a0` retrieves
the ambient view model and passes `BreadBoardUIServices.DismissalScope.all`
into `0x25164208c`. This establishes a native dismissal request, not that the
clock slice disappears: its exact effect can include dismissing ambient
editing/presentation state. A normal tap/swipe/Home route to remove the
specific observed clock was not recovered in this bounded pass.
REA `ev_650ac0c43d6e65a0443eb17cecab7421970ec61c2fb4848157acd7548dff293a`.

The pass stopped when the parent live investigation reproduced a fresh Metal
shader-library lookup failure under BreadBoard's exact installed entitlements
and mobile identity (MTLLibraryErrorDomain3, sandbox restriction; cache
extension failures EPERM). That is parent-reported runtime evidence, not an
execution observed in this static pass. It provides a concrete failure to
resolve before interpreting unresponsive gestures as presentation policy.
No guest changes, patch changes or gesture injection were performed here.

## Artifacts and reproducibility

All addresses are unslid documentation for this exact donor, not patch offsets.
Scratch extracts and symbol/disassembly inventories are under
`/tmp/homeview-transport`; existing BBF extract is `/tmp/homeview-extract`.

| Artifact | SHA-256 |
| --- | --- |
| BreadBoardFramework | `f3336f3e9aade1bdfb02fcb50a10880f42c26f892119f635a29aa9e97573bd93` |
| BreadBoardUIServices | `89d22bccece1b8fc75337836424a52fae608a7bd633d0d41e78941ad594a3678` |
| PebbleUI | `ea34b6e75b9f3e98654fd236b32ba130a579c7af8bd621baada56dfbdee1e158` |
| PebbleSettingsApp | `6077a6af81c1c395996bf84bb54f4743c30fdb7e6e1d97c76a76b54e3add97ca` |
| Music | `52d6517e4e2bed003a3b52ee18306fedb68d6574355859e898958b611e49f46f` |
| Reminders | `5e7afe073ee50b56c2f7915370e25e58b65318c76996939bd25b907ad207202a` |
| Alarms | `20113596071b51fe3480e65639513c37ce2c85cd6d4d85b41c81cf4854f5f3ee` |
| Timers | `895324d2cb1aa299efb4cdf3fa60c2c5c890c39f859ebd185c3606697a52c494` |
| RushmoreFramework | `96c034371acd6307f4bbd922246b2af8e89f4591ab6711dda48a6c0e2ca85a6f` |
| Charcuterie | `802943feb5520ab2fe09f70e4647424b432a42737f1df8f1d71aaf0310fed72c` |
| BreadBoardFramework.asm | `d07d314452902870b227c85188aca845c9cc18b83c81c5748b3b6fcc426652bf` |
| BreadBoardUIServices.asm | `eced1d01280e0fc2c96827cfecb4c232d1c487045925fce02ba7f353081d3c53` |
| PebbleUI.asm | `3850bb573c057c417f7221f5ad7934f7282973c1fa44874635fcb537fc084d81` |
| Charcuterie.asm | `8acc032817b690a2f0d80d398bf3253d7f489b19affbab3b4e674695f8a57a85` |
| Charcuterie-swift.txt | `f523ab74a7dd2af6a6f80b7adafbdaf05f53fe000eeb9643b6f8faaeabd60768` |

REA snapshots: `bbuis-consumers.snapshot.json`,
`pebbleui-consumers.snapshot.json`, `settings-consumers.snapshot.json`,
`music-consumers.snapshot.json`, `rushmore-consumers.snapshot.json`,
`bbf-consumers.snapshot.json`, `reminders-consumers.snapshot.json`,
`alarms-consumers.snapshot.json`, `timers-consumers.snapshot.json`, and
`charcuterie-ambient.snapshot.json` in that
scratch directory. Matching snapshots retain the function dossiers and their
inline evidence. Static Swift pseudocode can lose arguments and optional tags;
the payload and optional-content conclusions above were checked against ARM64
stores/branches, not pseudocode alone. This investigation leaves exact clock
consumers, all app-specific feature prerequisites and live trait delivery
unresolved.

## Follow-up: reaching the Timer fullscreen activity

The ordinary Timers configuration row is not evidence that AnalogTimerView
is on screen. This pass recovered a separate App Intent entry and the native
ActivityKit lifecycle. It did not establish a tap or URL sequence that opens
fullscreen from the configuration List.

Native Timers metadata declares `TimerActivityStyle` cases in order `round`,
`capsule`, `platter`, `fullScreen`. `ShowTimerActivityIntent.perform` continuation
`0x1000495b0` reads the timer ID and style parameter, logs its style request,
and calls `MTActivitiesUpdater.requestTimerStyle(timer:style:)` with the style
tag plus one. Thus fullScreen is `RequestedStyle` **4**. Independently,
`OpenTimerEntityIntent` continuation `0x100073648` requests literal 4 when the
selected MTTimer's state equals 3; other states navigate the application's
configuration flow. REA
`ev_33b5ade602c2b66bf254bdd7f3d4305d2f34c792d596d5f2d8b1a423364b2eab`,
`ev_3fdd06737258fa36e3a8abb298a69cd36b877c4d1014f4d7389cca1d0d47e611`.

The shipped `Timers.app/Metadata.appintents/extract.actionsdata` declares
ShowTimerActivityIntent discoverable, with required ID and style parameters,
default style `fullScreen`, `openAppWhenRun: false`, authenticationPolicy 0
and no requiredCapabilities. These are App Intent declarations, not proof
that an arbitrary caller has ActivityKit's downstream permissions. No
pairing, account or persona argument appears in this style request.

### A style request requires an existing activity

MobileTimerSupport's MTActivitiesUpdater is a pure Swift `_SwiftObject`, with
no Objective-C selectors in its native ObjC method metadata. Its timer method
`0x1b2ab0b44` continues at `0x1b2ab0c20`: enumerate
`Activity<TimerActivityAttributes>.activities`, match the timer ID from the
attributes' TimerContext, set the context's requestedStyle, retain the current
relevanceScore, create ActivityContent with no staleDate, and await
`Activity.update`. **No matching activity means return without creating one.**
REA `ev_368bdccab6b643d0627af5f3ac1c32b987e5d2a9cc2870a91a1b761f484512ca`,
`ev_bc47ca2ad0774a2d729a189c84960d58015b47abee0802e357566d5d5dc7108c`.
The RequestedStyle rawValue getter `0x1b2ab0a34` is an identity return, so the
argument 4 is also its raw value
(`ev_29d6f347071b9ff1766ee3b3a8a108eaf93b16a2f8e2f87d3db2d4291eee24f3`).

There is a separate, real Objective-C creation route:
`MTActivitiesManager.contextForTimer:` creates a TimerContext from the native
MTTimer; `timerProxy` returns TimerActivityProviderProxy; its
`createActivityWithContext:completion:` bridges a Swift method with completion
`@Sendable (NSError?) -> Void`. Its update method has the same one-error
completion shape. This differs from the alarm update method, whose completion
also contains an optional String. The native timer creation selector is at
`0x1b2aa6ac0`; its exported Swift dispatch thunk is `0x1b2ab45b4`.

`MTActivitiesManager.createActivityWithTimer:completion:` (`0x1b2a426b0`)
builds that context, sets requestedStyle derived from MTTimer.timerContext's
`kMTTimerRequestedActivityStyle`, then forwards to the proxy. The conversion
table at `0x1b2ad9678` maps dictionary values 0/1/2/3 to RequestedStyle 4/1/2/3;
an absent value yields 0. A freshly constructed context therefore need not
equal the manager's derived requested style. REA
`ev_0276e369476a19f2093945cf2a83a72721e22d8d7c4c8719ccb8ee81932c617a`,
`ev_3e5ede28dc558da954a57231ba4cc4b99521284038ef0595209bb6e375185800`,
`ev_2f51af2e5ca29ff9fa1f95bf0cca77de01b24d54d60a919f9b2baacd44357aed`,
`ev_139a4d5fdc1c7b59eefced08276e40330e9c70217fb12cf36bb0c5fe1f5e9ac3`.

The proxy's create worker reaches `0x1b2aa1db8`, rejects an activity with the
same TimerContext ID, then calls `0x1b2aa907c`. That builds an ActivityKit
Activity.Request using all presentation destinations and a process content
source, then calls `Activity.request`. There is no paused-state, pairing,
persona or account rejection in this bounded provider path. Downstream
ActivityKit admission remains a runtime question. REA
`ev_03601e4831e040f264fd3389336af6b500f85b48091d6e1dbfb999dbd147b2a8`,
`ev_dc383ce60012bbc20da4f7a6957fac1c9a6c2006e9abc42be9ac335cdc7141b8`.

### Native coordinator's timer-state policy

MobileTimer's MTActivityCoordinator `source:didAddTimers:` block
`0x1a3f1d7fc` calls MTTimer.state and only creates an activity for state 3
(`createActivityWithTimer:completion:` through selector stub `0x1a802f900`).
`processTimerStateUpdate:fromTimer:` (`0x1a3f1ebf4`) identifies state 3 as
`starting/resuming timer`. When the previous state is 1 or 2 it queues
`0x1a3f1eec4`, which calls **updateActivityWithTimer**, not create. New state 2
also calls that update selector through block `0x1a3f1efc4`. This explains why
resuming alone need not repair a failed initial activity creation; it does not
prove which failure occurred on the VM.

This coordinator evidence was decoded directly with `ipsw dyld disass` against
the original cache and its symbol cache. REA's cold MobileTimer provider failed
startup after 120 seconds; no REA function evidence is claimed for it. Saved
raw assembly: `/tmp/homeview-transport/mobiletimer-added-activity.asm` (SHA-256
`1631ef425fdf71cf60a5f36b633687a80aca5058a1292e837ca2a7f82a162b0c`) and
`mobiletimer-state-activity.asm`
(`2b7f9ae465cfea74756efbf05996e95ea417f9662dad5b9bf9e12f1e8ee0a31b`).

The sibling runtime investigation reported one owned paused timer and an empty
native timerActivities callback. That is consistent with the updater's no-op
path; it is not a runtime result observed by this static pass. No guest
activity, timer, account or patch was changed here.

Additional extract identity: MobileTimerSupport SHA-256
`48fc136fdfd46a121b0d6882fb2c5632137de6b733a21c19739bd02a1bc46099`;
MobileTimer `57befb0a7699b270effb5b9c872c45cfaf523b18c04940629b38fa9659cf4ff9`.
Full-cache Swift/ObjC inventory is
`/tmp/homeview-transport/MobileTimerSupport-native.txt` (SHA-256
`8126e837fe5784f7deca3f74e8623bba6d1729f73f0ab73aea40c44229b879b4`).
REA snapshot `mobiletimer-support.snapshot.json` retains the corresponding
native function dossiers. Timers' snapshot was saved after the intent trace.

## Follow-up: ActivityInput error 0 and daemon ownership

A parent-run helper calling the native TimerActivityProviderProxy create path
received an error wrapped as `com.apple.mobiletimer` code 0 with description
`com.apple.ActivityKit.ActivityInput error 0`. That description alone does not
identify an entitlement failure. ActivityKit's shipped Swift metadata names
ActivityInputServerError.Code cases `invalidInput`, `notAllowed`,
`configuration`, `connection`, `unknown`, in that order. Its raw initializer
`0x25080f110` accepts integers 0...4 unchanged; raw getter `0x25080f124` and
CustomNSError.errorCode getter `0x25080f16c` read the same enum byte. Thus
ActivityInput **0 means invalidInput**. The errorDomain getter `0x25080f150`
returns `com.apple.ActivityKit.ActivityInput`. errorUserInfo `0x25080f174`
also preserves an optional underlying error; flattening localizedDescription
can lose the narrower reason.

The parent's matching liveactivitiesd requestResolver log supplied the narrower
reason: `is not permitted to specify multiple process content sources`.
SessionCore's exact static gate at `0x257130868` compares the requested process
descriptor with the requester's descriptor (`0x2571309b4`–`0x2571309bc`). An
equal descriptor is accepted. For an unequal descriptor, it reads the
ContentSourceResolver.Permissions.multipleProcessContentSources boolean
(`0x2571309d4`); false branches into the rejection/log path, whose literal
reference is `0x257130b94`. Despite the wording, this gate can reject a
**single foreign process source**, not just an array containing multiple
sources.

Permissions construction at `0x257130ee4` reads
`com.apple.private.sessionkit.permitMultipleProcessInputs` at `0x257130fe0`,
calls `hasEntitlement:` through stub `0x25801cf90` at `0x257131004`, and places
the result in the permissions flags (`0x257131054`). Independent read-only
codesign inspection of the original HomeView mobiletimerd confirms that
entitlement is true. The parent reports the installed mobiletimerd matches
the original binary and retains that entitlement. A helper signed with the
app's entitlements therefore does not reproduce the daemon's native creation
authority. This explains this particular helper failure; it does not prove
why normal timer creation originally failed, or that a daemon-entitled helper
will successfully present a scene.

This bounded follow-up used full-cache Swift metadata and direct `ipsw`
disassembly, without opening a new REA session. Artifacts under
`/tmp/homeview-transport`:

| Artifact | SHA-256 |
| --- | --- |
| SessionCore | `df6e403abc56da99ce5b23be4ab117f63b431b5b7ae26762e391bbeba694a586` |
| activitykit-input-error.asm | `b673c870601789766e5348af5a81d95fafc4ce2a84dd9a3251fe3ce1da4e2251` |
| sessioncore-multi-input-gate.asm | `4230dc095586b4402e8d3eb7c9ab11a1986f970cb518b44db5b7c8b4f86e00ff` |
| sessioncore-content-permissions.asm | `95889968e442f4b4e19b0154de3e38329d73232d58f5bec9ad50a5a68c9d4242` |

### Subsequent ephemeral and unbounded request checks

After adding only permitMultipleProcessInputs, the parent reported the native
helper advanced to `Requesting process is not entitled to make this request`.
ActivityKit's `ActivityAuthorizationError.failureReason` references that exact
literal at `0x2507f4ed8`. It is a shared authorization failure description,
not the name of one entitlement.

The specific native timer request sets **isEphemeral=true and
isUnbounded=true**: at MobileTimerSupport `0x1b2aa9728`/`0x1b2aa972c`, x6/x7
are both 1 before the typed Activity.Request initializer at `0x1b2aa9730`.
SessionCore's authorizer checks these flags in order:

1. `0x257132b2c`: read ActivityRequest.isEphemeral. If true, test
   `com.apple.private.activitykit.ephemeralActivityRequester` with
   `hasEntitlement:` at `0x257132b5c`. False branches to `0x257133154` and logs
   `Requester is not entitled to request ephemeral activities`.
2. `0x257132b70`: read ActivityRequest.isUnbounded. If true, test
   `com.apple.private.activitykit.unboundedActivityRequester` at
   `0x257132ba0`. False branches to `0x257133210` and logs the corresponding
   unbounded-activities rejection.

Both paths join a throw of ActivityAuthorizationError.unentitled, with its
enum-case symbol explicitly resolved at `0x257133448`. Consequently the
app-entitled helper with only permitMultipleProcessInputs lacks at least the
first of these required permissions; both are required for the exact native
timer request. The original HomeView mobiletimerd carries both. This identifies
these specific gates without asserting that those permissions alone satisfy
every later ActivityKit check.

`com.apple.private.sessionkit.sessionRequest` is checked later at
`0x25713442c`; its successful path skips some target application validation.
It does not replace the earlier ephemeral/unbounded checks. Its missing path
inspects the target LSApplicationRecord and NSSupportsLiveActivities policy,
so treating sessionRequest as the first generic entitlement fix would obscure
the earlier requirements. No entitlement or guest state was changed in this
static pass.

Additional raw disassembly files in `/tmp/homeview-transport`:

| Artifact | SHA-256 |
| --- | --- |
| sessioncore-request-entitlement-start.asm | `a2b429c17b48412f271365e33a51791a9822743cee9f8e5f1036092acdf08cc3` |
| sessioncore-request-entitlement-gates.asm | `4cec3cbf4d8abfe09489ae3ad4665c8160099cfe19be72a07775312127996b83` |
| mobiletimer-activity-request-flags.asm | `ac1588e451d6b76c89ecd1d5285788861307d4c5bb1910adc267f61cdaffa489` |

## Follow-up: ordinary app scenes explicitly latch Far reductions

The parent reported a native UIKit probe with environment Far→Near→Far
(0→2→0). The app's FBS settings, UIWindowScene and view received 0 then 2 while
foreground; the final 0 arrived only when foreground became false. This pass
found the actual shell assignment and the matching synchronous policy.

Charcuterie's SceneDefinitionResolver function `0x2519a1adc` reads
SceneDescriptor.presentation and obtains its enum case at `0x2519a1db8`.
Its metadata accessor `0x2519abe50` names nominal descriptor `0x251ab3cf4`;
that descriptor's relative name points to `ScenePresentation` at
`0x251a9d850`. Its three payload-case records in field descriptor
`0x251af4dfc` name `app`, `system`, `placeholder`, in order, at
`0x251ae8d81`, `0x251ae8d85`, `0x251ae8d8c`. Thus these are ScenePresentation
tags, not SceneLifespan tags.

The resolver branches at `0x2519a1dd0`/`0x2519a1dd8`: app (tag 0) and
placeholder (tag 2) select **UpdateBehavior.latching** via the exported case
at `0x2519a1e5c`; system (tag 1) selects **primaryOnly** at `0x2519a1de0`.
It stores this chosen behavior into BaseSceneModifier. The modifier's native
configuration method `0x2519a331c` obtains the scene's
BBSUILevelOfDetail.SceneExtension.HostComponent, copies that behavior, and
calls its actual **updateBehavior setter at `0x2519a34a0`**. This establishes
ordinary app policy beyond the HostComponent's primaryOnly initializer default.
A separate LiveActivity modifier explicitly sets
primaryWithPrecedingSecondary at `0x2519a4d74`.

The previously traced latching method `0x25137ffbc` checks behavior tag 2,
gets mutableSettings and its isForeground flag (`0x251380188`), and compares
the proposed LOD against previousSettings.bbsui_levelOfDetail at
`0x2513801d0`. An equal/increased value follows the normal update path. A
foreground reduction follows `Staging level of detail`, saves the proposed
value in a staged optional (`0x2513806cc`–`0x2513806d4`), and writes the previous
LOD back into outgoing settings (`0x2513806dc`–`0x2513807d4`).

The separate foreground-diff method `0x251380848` reads previous and current
isForeground. **Previous true and current false** at
`0x251380b84`/`0x251380b8c` calls `0x251380cc8` at `0x251380b94`. That method
writes the staged value through the native set-bbsui_levelOfDetail selector
at `0x251380fe4`, then clears the staged optional. No timer, idle interval or
delay queue occurs in these branches. The parent's probe observation matches
the shell's app policy; this static pass did not independently inspect the
probe's live SceneDescriptor or observe its execution.

Practical implication: increasing detail (Near) can update an ordinary active
app immediately, while reducing it (Far) can wait until that app goes to the
background. Reopening the app then tests the Far layout. System scenes and
Live Activities have different explicitly selected policies; the ordinary
app result must not be generalized to all screens.

No REA session or guest changes were needed. The complete hashed Charcuterie
and BreadBoardUIServices assembly inventories above contain these sites;
bounded excerpts under `/tmp/homeview-transport` are:

| Artifact | SHA-256 |
| --- | --- |
| charcuterie-scene-lod-policy.asm | `97ee2ad5550bd6ebe183f5331a30e3d1da507b23a842252fe1326ce1fb0e5040` |
| charcuterie-scene-lod-assignment.asm | `7e285543ec902f9028a2f12b0637bd7e72af341bd3fcbb6710e0aa1461bb7f80` |
| bbsui-lod-latching-and-foreground.asm | `e82b71fb85b41eb923580ad3a22cf917e996e560c6b37c8c5fa9f3ef5dfdc08c` |
