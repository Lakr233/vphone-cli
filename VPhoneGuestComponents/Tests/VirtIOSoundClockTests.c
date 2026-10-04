// VirtIOSoundClockTests.c — host checks for the virtio-snd HAL plugin's
// zero-timestamp clock: the timestamps it answers, and that a reader racing
// re-anchors never mixes two timelines.

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#include "VPVirtIOSoundClock.h"

static int failures;

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__,   \
                #condition);                                                   \
            failures++;                                                        \
        }                                                                      \
    } while (0)

static const uint32_t kPeriodFrames = 12480;

static double ticksPerPeriod(double sampleRate) {
    VPVirtIOSoundClock clock;
    VPVirtIOSoundClockConfigure(&clock, kPeriodFrames, sampleRate, 0);
    uint64_t bits = atomic_load(&clock.timelines[atomic_load(&clock.seed) & 1].hostTicksPerPeriod);
    double ticks;
    memcpy(&ticks, &bits, sizeof(ticks));
    return ticks;
}

/// The clock as it was before its period count stopped being stored: the
/// count kept by the last read and moved forward when a period had passed.
typedef struct {
    uint64_t anchor;
    uint64_t count;
    double ticks;
} Reference;

static void referenceRead(Reference *clock, uint64_t now, double *sampleTime, uint64_t *hostTime) {
    if (now > clock->anchor && (double)(now - clock->anchor) >= (clock->count + 1) * clock->ticks) {
        clock->count = (uint64_t)((now - clock->anchor) / clock->ticks);
    }
    *sampleTime = (double)clock->count * kPeriodFrames;
    *hostTime = clock->anchor + (uint64_t)(clock->count * clock->ticks);
}

// MARK: - Quiescent timestamps

static void testWholePeriodsSinceAnchor(void) {
    VPVirtIOSoundClock clock;
    VPVirtIOSoundClockConfigure(&clock, kPeriodFrames, 48000, 1000);
    double ticks = ticksPerPeriod(48000);
    double sampleTime = -1;
    uint64_t hostTime = 0;
    uint64_t seed = 0;
    CHECK(VPVirtIOSoundClockZeroTimestamp(&clock, 1000 + (uint64_t)(ticks / 2), &sampleTime, &hostTime, &seed));
    CHECK(sampleTime == 0);
    CHECK(hostTime == 1000);
    CHECK(seed == 1);
    CHECK(VPVirtIOSoundClockZeroTimestamp(&clock, 1000 + (uint64_t)(ticks * 2.5), &sampleTime, &hostTime, &seed));
    CHECK(sampleTime == 2.0 * kPeriodFrames);
    CHECK(hostTime == 1000 + (uint64_t)(2 * ticks));
    CHECK(seed == 1);
    // A read from before the anchor answers the anchor itself.
    CHECK(VPVirtIOSoundClockZeroTimestamp(&clock, 10, &sampleTime, &hostTime, &seed));
    CHECK(sampleTime == 0);
    CHECK(hostTime == 1000);
}

static void testMatchesStoredCount(void) {
    VPVirtIOSoundClock clock;
    VPVirtIOSoundClockConfigure(&clock, kPeriodFrames, 44100, 5000);
    Reference reference = {.anchor = 5000, .count = 0, .ticks = ticksPerPeriod(44100)};
    uint64_t now = 5000;
    uint64_t state = 1;
    for (int i = 0; i < 200000; i++) {
        state = state * 6364136223846793005ULL + 1442695040888963407ULL;
        now += (state >> 33) % 400000;
        double sampleTime = 0;
        double expectedSampleTime = 0;
        uint64_t hostTime = 0;
        uint64_t expectedHostTime = 0;
        uint64_t seed = 0;
        CHECK(VPVirtIOSoundClockZeroTimestamp(&clock, now, &sampleTime, &hostTime, &seed));
        referenceRead(&reference, now, &expectedSampleTime, &expectedHostTime);
        if (sampleTime != expectedSampleTime || hostTime != expectedHostTime || seed != 1) {
            CHECK(!"timestamp differs from the stored-count clock");
            return;
        }
    }
}

static void testAnchorAndRateChange(void) {
    VPVirtIOSoundClock clock;
    VPVirtIOSoundClockConfigure(&clock, kPeriodFrames, 48000, 0);
    double sampleTime = 0;
    uint64_t hostTime = 0;
    uint64_t seed = 0;
    VPVirtIOSoundClockAnchor(&clock, 1000000);
    CHECK(VPVirtIOSoundClockZeroTimestamp(&clock, 1000000, &sampleTime, &hostTime, &seed));
    CHECK(sampleTime == 0);
    CHECK(hostTime == 1000000);
    CHECK(seed == 2);
    // The period keeps its frames and only lasts longer.
    VPVirtIOSoundClockSetRate(&clock, 44100, 2000000);
    double ticks = ticksPerPeriod(44100);
    CHECK(clock.periodFrames == kPeriodFrames);
    CHECK(VPVirtIOSoundClockZeroTimestamp(&clock, 2000000 + (uint64_t)(ticks * 3.5), &sampleTime, &hostTime, &seed));
    CHECK(sampleTime == 3.0 * kPeriodFrames);
    CHECK(hostTime == 2000000 + (uint64_t)(3 * ticks));
    CHECK(seed == 3);
    // A plain anchor keeps the new length.
    VPVirtIOSoundClockAnchor(&clock, 3000000);
    CHECK(VPVirtIOSoundClockZeroTimestamp(&clock, 3000000 + (uint64_t)(ticks * 1.5), &sampleTime, &hostTime, &seed));
    CHECK(hostTime == 3000000 + (uint64_t)ticks);
    CHECK(seed == 4);
}

// MARK: - Racing anchors

/// The writer's timelines are a function of their seed, so a reader can tell
/// from the seed it got what anchor and period length it must have used.
static const uint64_t kAnchorStep = 1000000;
static const int kRaceAnchors = 200000;

static VPVirtIOSoundClock raceClock;
static double raceTicks[2];
static _Atomic bool raceDone;

/// The rate flips every second anchor, so the writer alternates rate changes
/// and plain anchors, and the two seeds that share a slot never share a rate.
static unsigned raceRateIndex(uint64_t seed) {
    return (seed >> 1) & 1;
}

static double raceRate(uint64_t seed) {
    return raceRateIndex(seed) ? 48000 : 44100;
}

static void *raceWriter(void *argument) {
    (void)argument;
    for (uint64_t seed = 2; seed < 2 + (uint64_t)kRaceAnchors; seed++) {
        if (raceRate(seed) == raceRate(seed - 1)) {
            VPVirtIOSoundClockAnchor(&raceClock, seed * kAnchorStep);
        } else {
            VPVirtIOSoundClockSetRate(&raceClock, raceRate(seed), seed * kAnchorStep);
        }
    }
    atomic_store(&raceDone, true);
    return NULL;
}

static void testReaderNeverMixesTimelines(void) {
    raceTicks[0] = ticksPerPeriod(44100);
    raceTicks[1] = ticksPerPeriod(48000);
    VPVirtIOSoundClockConfigure(&raceClock, kPeriodFrames, raceRate(1), 1 * kAnchorStep);
    atomic_store(&raceDone, false);
    pthread_t writer;
    CHECK(pthread_create(&writer, NULL, raceWriter, NULL) == 0);
    uint64_t reads = 0;
    uint64_t refused = 0;
    uint64_t mixed = 0;
    uint64_t lastSeed = 0;
    while (!atomic_load(&raceDone)) {
        // Far enough past every anchor that the period count is large and
        // a wrong period length shows in the host time.
        uint64_t now = (uint64_t)(kRaceAnchors + 100) * kAnchorStep + (reads % 7919) * 997;
        double sampleTime = 0;
        uint64_t hostTime = 0;
        uint64_t seed = 0;
        if (!VPVirtIOSoundClockZeroTimestamp(&raceClock, now, &sampleTime, &hostTime, &seed)) {
            refused++;
            continue;
        }
        reads++;
        uint64_t anchor = seed * kAnchorStep;
        double ticks = raceTicks[raceRateIndex(seed)];
        uint64_t count = (uint64_t)((now - anchor) / ticks);
        if (sampleTime != (double)count * kPeriodFrames || hostTime != anchor + (uint64_t)(count * ticks)
            || seed < lastSeed) {
            mixed++;
        }
        lastSeed = seed;
    }
    pthread_join(writer, NULL);
    CHECK(reads > 0);
    CHECK(mixed == 0);
    if (mixed) {
        fprintf(stderr, "%llu of %llu reads mixed timelines\n", (unsigned long long)mixed, (unsigned long long)reads);
    }
    printf("VirtIOSoundClockTests: %llu racing reads, %llu refused\n",
        (unsigned long long)reads, (unsigned long long)refused);
}

int main(void) {
    testWholePeriodsSinceAnchor();
    testMatchesStoredCount();
    testAnchorAndRateChange();
    testReaderNeverMixesTimelines();
    if (failures) {
        fprintf(stderr, "VirtIOSoundClockTests: %d failure(s)\n", failures);
        return 1;
    }
    printf("VirtIOSoundClockTests: all passed\n");
    return 0;
}
