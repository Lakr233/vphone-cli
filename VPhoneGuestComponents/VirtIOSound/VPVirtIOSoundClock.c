// VPVirtIOSoundClock.c — see VPVirtIOSoundClock.h for the read contract.

#include "VPVirtIOSoundClock.h"

#include <mach/mach_time.h>
#include <string.h>

/// Reads are retried only when an anchor completed inside one, and anchors
/// come from property sets and I/O starts, so a second attempt all but
/// always succeeds; the bound keeps the I/O thread's work finite regardless.
static const int kReadAttempts = 8;

static double VPHostTicksPerPeriod(uint32_t periodFrames, double sampleRate) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double hostTicksPerSecond = 1e9 * timebase.denom / timebase.numer;
    return hostTicksPerSecond * periodFrames / sampleRate;
}

/// With `writeLock` held.
static double VPCurrentHostTicksPerPeriod(const VPVirtIOSoundClock *clock) {
    uint64_t seed = atomic_load_explicit(&clock->seed, memory_order_relaxed);
    uint64_t bits = atomic_load_explicit(&clock->timelines[seed & 1].hostTicksPerPeriod, memory_order_relaxed);
    double hostTicksPerPeriod;
    memcpy(&hostTicksPerPeriod, &bits, sizeof(hostTicksPerPeriod));
    return hostTicksPerPeriod;
}

/// With `writeLock` held: fills the slot readers are not using, then makes
/// it current.
static void VPPublish(VPVirtIOSoundClock *clock, uint64_t anchorHostTime, double hostTicksPerPeriod) {
    uint64_t seed = atomic_load_explicit(&clock->seed, memory_order_relaxed);
    VPVirtIOSoundTimeline *next = &clock->timelines[(seed + 1) & 1];
    // A reader still on the seed before the current one reads this slot.
    // The fence puts the current seed's publication before these stores, so
    // a reader that sees any of them also sees the seed has moved.
    atomic_thread_fence(memory_order_release);
    uint64_t bits;
    memcpy(&bits, &hostTicksPerPeriod, sizeof(bits));
    atomic_store_explicit(&next->anchorHostTime, anchorHostTime, memory_order_relaxed);
    atomic_store_explicit(&next->hostTicksPerPeriod, bits, memory_order_relaxed);
    atomic_store_explicit(&clock->seed, seed + 1, memory_order_release);
}

void VPVirtIOSoundClockConfigure(VPVirtIOSoundClock *clock, uint32_t periodFrames, double sampleRate, uint64_t now) {
    memset(clock, 0, sizeof(*clock));
    clock->writeLock = OS_UNFAIR_LOCK_INIT;
    clock->periodFrames = periodFrames;
    VPVirtIOSoundClockSetRate(clock, sampleRate, now);
}

void VPVirtIOSoundClockSetRate(VPVirtIOSoundClock *clock, double sampleRate, uint64_t now) {
    double hostTicksPerPeriod = VPHostTicksPerPeriod(clock->periodFrames, sampleRate);
    os_unfair_lock_lock(&clock->writeLock);
    VPPublish(clock, now, hostTicksPerPeriod);
    os_unfair_lock_unlock(&clock->writeLock);
}

void VPVirtIOSoundClockAnchor(VPVirtIOSoundClock *clock, uint64_t now) {
    os_unfair_lock_lock(&clock->writeLock);
    VPPublish(clock, now, VPCurrentHostTicksPerPeriod(clock));
    os_unfair_lock_unlock(&clock->writeLock);
}

bool VPVirtIOSoundClockZeroTimestamp(
    const VPVirtIOSoundClock *clock,
    uint64_t now,
    double *sampleTime,
    uint64_t *hostTime,
    uint64_t *seed) {
    for (int attempt = 0; attempt < kReadAttempts; attempt++) {
        uint64_t before = atomic_load_explicit(&clock->seed, memory_order_acquire);
        const VPVirtIOSoundTimeline *timeline = &clock->timelines[before & 1];
        uint64_t anchor = atomic_load_explicit(&timeline->anchorHostTime, memory_order_relaxed);
        uint64_t bits = atomic_load_explicit(&timeline->hostTicksPerPeriod, memory_order_relaxed);
        // Keeps the slot's loads before the second look at the seed.
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&clock->seed, memory_order_relaxed) != before) {
            continue;
        }
        double hostTicksPerPeriod;
        memcpy(&hostTicksPerPeriod, &bits, sizeof(hostTicksPerPeriod));
        uint64_t count = now > anchor ? (uint64_t)((now - anchor) / hostTicksPerPeriod) : 0;
        *sampleTime = (double)count * clock->periodFrames;
        *hostTime = anchor + (uint64_t)(count * hostTicksPerPeriod);
        *seed = before;
        return true;
    }
    return false;
}
