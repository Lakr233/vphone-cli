# Host Trackpad Gestures → Guest Touch

How macOS trackpad gestures are replayed as touches inside the virtual iPhone,
and the trade-offs that are load-bearing.

---

## Behavior

| Host gesture               | Guest gesture                                                        |
| -------------------------- | -------------------------------------------------------------------- |
| Two-finger scroll          | One finger presses under the pointer and follows the physical motion, then lifts |
| Two-finger pinch (magnify) | Two fingers spreading/closing horizontally around the pointer         |

Both are host-side translations of `NSEvent`s in `VPhoneVirtualMachineView`
(`scrollWheel(with:)` / `magnify(with:)`). The guest never sees a scroll or
magnify event — it sees an ordinary drag or pinch.

A swipe keeps scrolling for as long as the trackpad keeps reporting travel: it
is **not** bounded by where the pointer sits or by the size of the window (see
"Edge re-anchoring" below).

Toggle: **Keys → Trackpad Scroll & Pinch to Touch** (on by default).
Persisted as `trackpadGesturesEnabled` (`UserDefaults` key
`trackpadGesturesDisabled`).

---

## Injection paths

`sendTouchEvent(phase:localPoints:swipeAim:allowOutside:timestamp:)` fans out to
whichever touch channel the running base uses:

| Base                              | Channel                                                          |
| --------------------------------- | ---------------------------------------------------------------- |
| iOS 18 (`useGuestTouchInjection`) | vphoned `{"t":"touch"}` / `{"t":"touch2"}` → `vp_hid_touch[_2]()` → `IOHIDEventCreateDigitizerEvent` |
| iOS 26                            | Native VZ `_VZTouch(view:index:phase:location:swipeAim:timestamp:)` × N inside one `_VZMultiTouchEvent` |

A guest that predates `touch2` advertises no `touch2` capability
(`VPhoneControl.supportsMultiTouch`), so pinch degrades to a single-finger move
there; the auto-update push normally brings the new agent in.

`vp_hid_touch` (single finger) and `vp_hid_touch2` share one
`dispatch_digitizer_points()` helper. Finger 0 keeps `index = 1, identity = 2`
so the pre-existing single-touch path is bit-for-bit unchanged; additional
fingers carry their own identity so the guest tracks them separately.

`allowOutside` forwards coordinates past the view instead of clamping them.
Keep it: the finger model runs past the edge on purpose during a re-anchor, and
clamping the reported position would make the release snap back to the edge.

---

## Direction convention

`scrollingDeltaX/Y` carry AppKit's scroll direction, which is inverted by the
user's natural-scrolling preference. The code compensates with
`event.isDirectionInvertedFromDevice` and treats the result as the physical
finger direction, with one extra sign on the x axis:

```swift
var dx = -event.scrollingDeltaX
var dy = event.scrollingDeltaY
if event.isDirectionInvertedFromDevice { dx = -dx; dy = -dy }
// dy > 0 == finger moved up, dx > 0 == finger moved right
```

The vertical sign comes from the header contract (`NSEvent.h`: "the event's
scrolling values are inverted from the device's physical direction …
compensate by multiplying -1") plus the historical NSScrollView convention
that the un-inverted delta is positive for an upward gesture.

The horizontal sign is **empirically calibrated**, not derived: with both axes
compensated the same way, hardware testing showed the guest finger following
the fingers vertically but mirrored horizontally. The two axes apparently do
not share a baseline. `scrollDelta(of:)` is the single place this lives — flip
the sign there if a base or a scroll-preference setting comes out reversed.

Guest coordinates are top-left origin, so "up" means a smaller `y`; the view's
non-flipped local space is converted by `normalizeCoordinate`.

---

## Gesture state machine

1. **Start threshold.** A finger is only pressed once the gesture has travelled
   `scrollStartThreshold` (2pt), and the carried travel is applied immediately
   afterwards. Taps and zero-travel scrolls therefore never reach the guest as
   a click, and the finger never sits idle after being pressed — which is what
   turned pointer rests into long presses and text selection.
2. **Throttled updates.** Trackpads emit 60-120Hz. The finger's position
   advances on every frame, but events are forwarded at most once per
   `scrollMinSendInterval` (1/70s); the release carries the final position. At
   120Hz that halves the traffic into the guest's HID queue, which was showing
   up as stutter and as the finger drifting on after the gesture ended.
3. **Edge re-anchoring.** See below.
4. **Home strip snap.** An upward swipe that starts inside the bottom
   `homeEdgeSnapFraction` (10%) of the window is pressed at the very bottom edge
   instead of at the pointer. See below.
5. **Pinch exclusion.** A drag and a pinch never overlap: `magnify` is ignored
   while a synthetic finger is down and vice versa, because interleaved
   one-finger and two-finger touches leave the guest with no coherent gesture.
   `mouseDown` also releases any synthetic finger so it cannot steal the slot
   from a real click.

---

## Starting point and the Home indicator strip

The finger normally presses down wherever the pointer is, which lets the pointer
position pick the gesture: from the edge it is an edge gesture, in the content
area it is a scroll.

Unlocking is the one case where that is not enough. iOS only recognises an
upward unlock / home gesture when the touch **begins** inside the Home indicator
strip at the very bottom of the screen. A swipe starting a few points higher is
an ordinary drag, so on hardware the lock screen unlocked with the pointer
parked on the bar and stopped working as soon as it moved up a little — the
boundary, not the travel budget, was what changed.

`scrollStartPoint(for:travel:)` covers that: an upward swipe (`travel.y > |travel.x|`)
starting inside the bottom `homeEdgeSnapFraction` of the window is pressed at
`y = 0` instead. Everywhere else the pointer is used verbatim, so the rest of
the window keeps scrolling normally — including the bottom area for downward
swipes.

Cost: an upward swipe that begins in that bottom strip is a home / unlock
gesture rather than a scroll, which is the same trade the real device makes. If
that strip feels too tall (or too short) for unlocking, tune
`homeEdgeSnapFraction`.

---

## Edge re-anchoring (why the swipe is not limited by the pointer)

iOS scrolls a view by moving the touch: the offset equals the distance the
finger travels **on screen**. A window is finite, so a finger that simply walks
in one direction runs out of screen — and once past the edge the guest clamps
the touch to the border and stops following it, which makes the rest of the
swipe scroll nothing at all. That is what "the swipe stops early, and how early
depends on where my pointer was" was: the travel available was the distance
from the pointer to the edge in the direction of the swipe.

Handing out-of-range coordinates to the guest (`allowOutside`) does not fix
this on its own — the clamp happens inside the guest. It only keeps the host's
own model honest about where the finger is.

The fix is to give the swipe a fresh window of travel whenever it runs out:

```swift
if isPastScrollEdge(target) {
    scrollOverflow.x += delta.x
    scrollOverflow.y += delta.y
    if hypot(scrollOverflow.x, scrollOverflow.y) >= Self.scrollRebaseThreshold {
        rebaseScrollTouch()          // lift here, re-press on the far side
    }
}
```

`rebaseScrollTouch()` lifts the finger at the edge and presses it back down at
`scrollRebaseLandingInset` (12% of the window) measured from the edge it ran
into, **towards the opposite side**. Every re-anchor therefore hands back
roughly a full window of travel in the direction of the swipe, independent of
where the pointer is — that is what removes the pointer-position dependency.

Two details are load-bearing:

- **The gap.** `scrollRebaseGap` (20ms) separates the lift from the re-press,
  and the re-press is issued on the next scroll event once the gap has elapsed.
  Back-to-back events that share a timestamp get folded into a single move by
  the guest, so the touch appears to teleport from one edge to the other: iOS
  reads that as one very fast drag in the wrong direction and the content snaps
  back across the whole window.
- **Travel banked during the gap is replayed** (`flushScrollPending()`), not
  dropped, otherwise a fast swipe would lose distance to every re-press and the
  scroll would lag behind the fingers.

The threshold (12pt) is deliberately small: past the edge the finger is clamped
by the guest, so every frame spent out there is a frame where the guest sees an
idle finger — which it escalates into a long press if it goes on long enough.

### Rejected: momentum replay

Following AppKit's inertia stream dragged the guest on after the user had
stopped ("my hand is off the trackpad and it is still scrolling"). Momentum is
AppKit's synthetic deceleration; the guest produces its own once the finger
lifts at `.ended`, so replaying it double-counts. `momentumPhase` events are
now dropped — they only force a release in case a finger is somehow still down.

---

## Remaining simplifications

- **One swipe still costs a re-anchor every ~88% of the window.** Each one is a
  20ms lift. That is the price of unbounded travel; the alternative is a swipe
  that stops at the window edge.
- **Pinch radius is clamped** to `[8, min(width,height) * 0.45]` and only
  changes with `magnification`; the pinch center stays where the gesture began.
  Near a screen edge the two fingers get clamped independently, which distorts
  the ratio slightly.
- **Mouse wheels are untouched** — only events with
  `hasPreciseScrollingDeltas` are translated. Devices that report deltas without
  gesture phases (e.g. Magic Mouse) get a full press-drag-release per event so
  no finger is left pressed.
- **`scrollToTouchScale`** is 1.5, not 1: a single trackpad swipe produces much
  less travel than a finger covers on a phone screen, so at 1:1 an ordinary
  swipe could not carry a gesture that has to cross a third of the screen
  (unlock, back) to completion. It is the knob for "how much scroll per
  centimetre" — raise it for longer travel per swipe, lower it to make the
  finger easier to aim.

---

## Manual verification checklist

Requires a VM with the paired base and a physical trackpad.

1. Home screen: two-finger swipe left/right — pages turn in the same direction
   as the fingers.
2. Lock screen: an upward swipe unlocks with the pointer parked on the Home bar
   **and** with it anywhere in the bottom 10% of the window.
3. Settings (long list): a single long swipe scrolls the whole list from top to
   bottom without stopping part-way, **from any pointer position** — including
   with the pointer parked against the edge you are swiping towards.
4. An upward swipe starting *outside* the bottom strip must still scroll, not
   unlock.
5. Swipe distance and speed track the fingers: no lag, no run-on after release.
6. Photos/Maps: pinch out zooms in, pinch in zooms out.
7. Resting the pointer over text and swiping must not start a text selection.
8. Toggle the menu item off — trackpad gestures stop, mouse drag still works.
