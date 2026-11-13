# Poster extension read-only instrumented helper

The next diagnostic step is a guest-side helper loaded into the poster
extension process. It must be an observation tool, not a general process
launcher or UI mutator.

## Contract

`poster.inspect` accepts a target PID discovered by `processes.spawn(ps)` and a
short list of read-only fields. The helper verifies that the PID's executable
and bundle identity are the poster wallpaper extension before attaching. It
returns one bounded JSON document (64 KiB) containing:

- process identity, start time and executable UUID;
- the extension's FBScene instances and each scene's activation state;
- display identity, bounds in points, native pixel width/height and scale;
- interface orientation, `mode`/display-mode description and layer/surface
  identifiers;
- a monotonic timestamp and a generation counter for every sampled object.

Missing private selectors are reported as `available: false` with the selector
name; the helper never fabricates values and never changes orientation,
visibility, transforms, or layer contents.

## Isolation and limits

The helper is started only through the signed guest payload and a dedicated
RPC, not through arbitrary `processes.spawn`. It accepts one PID, performs one
sample, and exits. It has a 3 second wall-clock limit, a 64 KiB response cap,
and no filesystem/network access. The target must be a poster extension child
of SpringBoard or the known wallpaper host; otherwise it refuses the request.
All Objective-C/Swift private API calls are dynamically looked up and wrapped
in exception-safe probes. The output contains class/selector names and scalar
geometry only, never image bytes or user content.

## Delivery order

1. Add the helper to the guest resource payload and record its hash in the
   daemon's bootstrap manifest.
2. Add `poster.inspect` to vphoned with PID and identity checks before launch.
   The RPC plumbing now exists and returns an explicit `available:false` until
   the signed helper is installed and admitted.
3. Extend the host client with `inspectPosterExtension(pid:)` and persist the
   timestamped JSON under the existing `Research/Guest/Evidence` workflow.
4. Compare live FBScene geometry with the host snapshot and the 72pt band
   transition history before attempting any corrective action.
