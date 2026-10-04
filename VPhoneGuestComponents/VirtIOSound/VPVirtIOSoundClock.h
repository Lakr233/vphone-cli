// VPVirtIOSoundClock.h — the HAL device's free-running zero-timestamp clock.
//
// `performStartIO` anchors it; the HAL's real-time I/O thread reads it
// through `getZeroTimestampBlock` every cycle. The nominal rate can move
// under it, while I/O runs — the HAL runs the device at 44100 for ringtone
// previews and web audio and at 48000 otherwise — but the period stays the
// frame count the device published when the HAL first read it: the HAL keeps
// that number (it logs it as "Ring buffer size") and re-anchors its timeline
// on every timestamp that does not advance by exactly it. A rate change
// therefore moves only how long a period lasts, and re-anchors.
//
// A timeline is two words, the anchor host time and the period's length in
// host ticks, and a reader must never take one from each of two anchors.
// Writers (never the I/O thread) serialize on a lock, fill the slot readers
// are not using, and then advance `seed`. A reader takes the slot `seed`
// names and keeps it only if `seed` has not moved meanwhile; it retries only
// when an anchor completed during its read, and a stalled writer never makes
// it wait. Nothing else is stored: the period count is the whole periods
// between the anchor and the reader's `now`.
//
// `seed` is also the zero timestamp's seed. It names the timeline, moving
// only at an anchor, which is the one time the HAL should re-anchor its own.

#ifndef VPVirtIOSoundClock_h
#define VPVirtIOSoundClock_h

#include <os/lock.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    _Atomic uint64_t anchorHostTime;
    /// A double's bits.
    _Atomic uint64_t hostTicksPerPeriod;
} VPVirtIOSoundTimeline;

typedef struct {
    /// The current timeline is `timelines[seed & 1]`.
    VPVirtIOSoundTimeline timelines[2];
    _Atomic uint64_t seed;
    os_unfair_lock writeLock;
    /// Set once, by `VPVirtIOSoundClockConfigure`, before any reader.
    uint32_t periodFrames;
} VPVirtIOSoundClock;

/// Fixes the period's frame count for the life of the clock and anchors it
/// at `sampleRate`. Before any reader or other writer.
void VPVirtIOSoundClockConfigure(VPVirtIOSoundClock *clock, uint32_t periodFrames, double sampleRate, uint64_t now);

/// Re-derives how long a period lasts at a new nominal rate and re-anchors
/// at `now`. The period keeps its frame count.
void VPVirtIOSoundClockSetRate(VPVirtIOSoundClock *clock, double sampleRate, uint64_t now);

/// Re-anchors at `now`, keeping the period's length.
void VPVirtIOSoundClockAnchor(VPVirtIOSoundClock *clock, uint64_t now);

/// The zero timestamp at host time `now`: the last whole-period boundary
/// since the anchor. Real-time safe and bounded. False, and nothing written,
/// only when anchors kept completing through every attempt to read one.
bool VPVirtIOSoundClockZeroTimestamp(
    const VPVirtIOSoundClock *clock,
    uint64_t now,
    double *sampleTime,
    uint64_t *hostTime,
    uint64_t *seed);

#endif /* VPVirtIOSoundClock_h */
