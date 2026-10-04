// VirtIOSoundTests.c — host checks for the virtio-snd HAL plugin's pure parts:
// the format the plugin asks the device for, the rings' counters, and how
// captured frames are served.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "VPVirtIOSoundProtocol.h"
#include "VPVirtIOSoundRing.h"

static int failures;

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__,   \
                #condition);                                                   \
            failures++;                                                        \
        }                                                                      \
    } while (0)

// MARK: - Format choice

static VPVirtIOSoundPCMInfo info(uint64_t formats, uint64_t rates, uint8_t channels) {
    VPVirtIOSoundPCMInfo value;
    memset(&value, 0, sizeof(value));
    value.formats = formats;
    value.rates = rates;
    value.channelsMinimum = 1;
    value.channelsMaximum = channels;
    return value;
}

static void testPrefersFloat48k(void) {
    // What Virtualization.framework's VZHostAudioOutputStreamSink offers.
    VPVirtIOSoundPCMInfo device = info(1ULL << 19 | 1ULL << 5, 1ULL << 7 | 1ULL << 6, 2);
    VPVirtIOSoundStreamFormat format;
    CHECK(VPVirtIOSoundChooseFormat(&device, &format));
    CHECK(format.virtioFormat == kVPVirtIOSoundFormatFloat);
    CHECK(format.isFloat);
    CHECK(format.bitsPerChannel == 32);
    CHECK(format.virtioRate == 7);
    CHECK(format.sampleRate == 48000);
    CHECK(format.channels == 2);
    CHECK(format.bytesPerFrame == 8);
}

static void testFallsBackToInteger(void) {
    VPVirtIOSoundPCMInfo device = info(1ULL << 5, 1ULL << 6, 1);
    VPVirtIOSoundStreamFormat format;
    CHECK(VPVirtIOSoundChooseFormat(&device, &format));
    CHECK(format.virtioFormat == kVPVirtIOSoundFormatS16);
    CHECK(!format.isFloat);
    CHECK(format.sampleRate == 44100);
    CHECK(format.bytesPerFrame == 2);
}

static void testTakesHighestOtherRate(void) {
    VPVirtIOSoundPCMInfo device = info(1ULL << 17, 1ULL << 3 | 1ULL << 10, 2);
    VPVirtIOSoundStreamFormat format;
    CHECK(VPVirtIOSoundChooseFormat(&device, &format));
    CHECK(format.sampleRate == 96000);
    CHECK(format.virtioRate == 10);
}

static void testRefusesUnusableDevice(void) {
    VPVirtIOSoundStreamFormat format;
    VPVirtIOSoundPCMInfo noFormat = info(1ULL << 3, 1ULL << 7, 2);
    CHECK(!VPVirtIOSoundChooseFormat(&noFormat, &format));
    VPVirtIOSoundPCMInfo noRate = info(1ULL << 19, 0, 2);
    CHECK(!VPVirtIOSoundChooseFormat(&noRate, &format));
    VPVirtIOSoundPCMInfo noChannels = info(1ULL << 19, 1ULL << 7, 0);
    CHECK(!VPVirtIOSoundChooseFormat(&noChannels, &format));
}

static void testSizesAndParameters(void) {
    VPVirtIOSoundPCMInfo device = info(1ULL << 19, 1ULL << 7, 2);
    VPVirtIOSoundStreamFormat format;
    CHECK(VPVirtIOSoundChooseFormat(&device, &format));
    uint32_t period = 0;
    uint32_t buffer = 0;
    // 48000 * 8 / 12 = 32000 bytes, rounded up to 16 KiB pages.
    VPVirtIOSoundBufferSizes(&format, 16384, &period, &buffer);
    CHECK(period == 32768);
    CHECK(buffer == 12 * 32768);
    VPVirtIOSoundPCMParameters parameters = VPVirtIOSoundParameters(&format, period, buffer);
    CHECK(parameters.code == 0);
    CHECK(parameters.streamID == 0);
    CHECK(parameters.bufferBytes == buffer);
    CHECK(parameters.periodBytes == period);
    CHECK(parameters.channels == 2);
    CHECK(parameters.format == kVPVirtIOSoundFormatFloat);
    CHECK(parameters.rate == 7);
}

// MARK: - Ring

static void fill(uint8_t *bytes, uint32_t length, uint8_t value) {
    memset(bytes, value, length);
}

static void testRingSubmitsWholePeriods(void) {
    VPVirtIOSoundRing ring;
    CHECK(VPVirtIOSoundRingInit(&ring, 4 * 64, 64));
    uint8_t frames[96];
    fill(frames, sizeof(frames), 1);
    CHECK(VPVirtIOSoundRingWrite(&ring, frames, sizeof(frames)));

    uint32_t offset = 0;
    uint32_t length = 0;
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, false, &offset, &length));
    CHECK(offset == 0 && length == 64);
    VPVirtIOSoundRingDidSubmit(&ring, length);
    // 32 bytes pending: not a period yet.
    CHECK(!VPVirtIOSoundRingNextSubmission(&ring, false, &offset, &length));
    // When the stream stops, the tail goes too.
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, true, &offset, &length));
    CHECK(offset == 64 && length == 32);
    VPVirtIOSoundRingDidSubmit(&ring, length);
    CHECK(VPVirtIOSoundRingInFlight(&ring) == 96);
    VPVirtIOSoundRingDidComplete(&ring, 64);
    VPVirtIOSoundRingDidComplete(&ring, 32);
    CHECK(VPVirtIOSoundRingInFlight(&ring) == 0);
    VPVirtIOSoundRingDestroy(&ring);
}

static void testRingKeepsInFlightBytes(void) {
    VPVirtIOSoundRing ring;
    CHECK(VPVirtIOSoundRingInit(&ring, 4 * 64, 64));
    uint8_t frames[256];
    fill(frames, sizeof(frames), 2);
    CHECK(VPVirtIOSoundRingWrite(&ring, frames, 256));
    // Full: submitting frees nothing, only completion does.
    CHECK(!VPVirtIOSoundRingWrite(&ring, frames, 64));
    uint32_t offset = 0;
    uint32_t length = 0;
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, false, &offset, &length));
    VPVirtIOSoundRingDidSubmit(&ring, length);
    CHECK(!VPVirtIOSoundRingWrite(&ring, frames, 64));
    VPVirtIOSoundRingDidComplete(&ring, length);
    CHECK(VPVirtIOSoundRingWrite(&ring, frames, 64));
    // All or nothing: 65 bytes do not fit in what is left.
    CHECK(!VPVirtIOSoundRingWrite(&ring, frames, 65));
    VPVirtIOSoundRingDestroy(&ring);
}

static void testRingWrapsWritesAndSplitsSubmissions(void) {
    VPVirtIOSoundRing ring;
    CHECK(VPVirtIOSoundRingInit(&ring, 4 * 64, 64));
    uint8_t first[224];
    fill(first, sizeof(first), 3);
    CHECK(VPVirtIOSoundRingWrite(&ring, first, sizeof(first)));
    uint32_t offset = 0;
    uint32_t length = 0;
    // Three whole periods, then the 32-byte tail at 192.
    for (int i = 0; i < 3; i++) {
        CHECK(VPVirtIOSoundRingNextSubmission(&ring, false, &offset, &length));
        VPVirtIOSoundRingDidSubmit(&ring, length);
        VPVirtIOSoundRingDidComplete(&ring, length);
    }
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, true, &offset, &length));
    CHECK(offset == 192 && length == 32);
    VPVirtIOSoundRingDidSubmit(&ring, length);
    VPVirtIOSoundRingDidComplete(&ring, length);

    // 64 bytes now start at 224 and wrap: 32 at the end, 32 at the front.
    uint8_t second[64];
    for (unsigned i = 0; i < sizeof(second); i++) {
        second[i] = (uint8_t)i;
    }
    CHECK(VPVirtIOSoundRingWrite(&ring, second, sizeof(second)));
    CHECK(memcmp(ring.bytes + 224, second, 32) == 0);
    CHECK(memcmp(ring.bytes, second + 32, 32) == 0);
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, false, &offset, &length));
    CHECK(offset == 224 && length == 32);
    VPVirtIOSoundRingDidSubmit(&ring, length);
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, true, &offset, &length));
    CHECK(offset == 0 && length == 32);
    VPVirtIOSoundRingDestroy(&ring);
}

static void testRingQueuesSilenceAhead(void) {
    VPVirtIOSoundRing ring;
    CHECK(VPVirtIOSoundRingInit(&ring, 4 * 64, 64));
    uint8_t frames[160];
    fill(frames, sizeof(frames), 4);
    CHECK(VPVirtIOSoundRingWrite(&ring, frames, sizeof(frames)));
    CHECK(VPVirtIOSoundRingQueued(&ring) == 160);
    uint32_t offset = 0;
    uint32_t length = 0;
    for (int i = 0; i < 2; i++) {
        CHECK(VPVirtIOSoundRingNextSubmission(&ring, false, &offset, &length));
        VPVirtIOSoundRingDidSubmit(&ring, length);
    }
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, true, &offset, &length));
    VPVirtIOSoundRingDidSubmit(&ring, length);
    VPVirtIOSoundRingDidComplete(&ring, 64);
    // In flight counts as queued until the device returns it.
    CHECK(VPVirtIOSoundRingQueued(&ring) == 96);

    // Silence lands behind what is queued, wrapping, and goes out in
    // periods like any other bytes.
    CHECK(VPVirtIOSoundRingWriteSilence(&ring, 128));
    CHECK(VPVirtIOSoundRingQueued(&ring) == 224);
    CHECK(ring.bytes[159] == 4);
    for (unsigned i = 160; i < 256; i++) {
        CHECK(ring.bytes[i] == 0);
    }
    CHECK(ring.bytes[0] == 0 && ring.bytes[31] == 0);
    CHECK(ring.bytes[32] == 4);
    CHECK(VPVirtIOSoundRingNextSubmission(&ring, false, &offset, &length));
    CHECK(offset == 160 && length == 64);
    // All or nothing, as a mix write: 64 bytes do not fit in the 32 left.
    CHECK(!VPVirtIOSoundRingWriteSilence(&ring, 64));
    CHECK(VPVirtIOSoundRingWriteSilence(&ring, 32));
    CHECK(VPVirtIOSoundRingQueued(&ring) == 256);
    VPVirtIOSoundRingDestroy(&ring);
}

static void testRingResetAndValidation(void) {
    VPVirtIOSoundRing ring;
    CHECK(!VPVirtIOSoundRingInit(&ring, 100, 64));
    CHECK(!VPVirtIOSoundRingInit(&ring, 128, 0));
    CHECK(VPVirtIOSoundRingInit(&ring, 128, 64));
    uint8_t frames[64] = {0};
    CHECK(VPVirtIOSoundRingWrite(&ring, frames, 64));
    VPVirtIOSoundRingReset(&ring);
    uint32_t offset = 0;
    uint32_t length = 0;
    CHECK(!VPVirtIOSoundRingNextSubmission(&ring, true, &offset, &length));
    CHECK(VPVirtIOSoundRingInFlight(&ring) == 0);
    VPVirtIOSoundRingDestroy(&ring);
}

// MARK: - Input ring

/// Hand the device the next slot and return it filled with `value`, as one
/// completed read does.
static void capturePeriod(VPVirtIOSoundInputRing *ring, uint8_t value) {
    uint32_t offset = 0;
    CHECK(VPVirtIOSoundInputRingNextSubmission(ring, &offset));
    VPVirtIOSoundInputRingDidSubmit(ring);
    fill(ring->bytes + offset, ring->period, value);
    VPVirtIOSoundInputRingDidComplete(ring);
}

static void testInputRingHandsOutWholeSlots(void) {
    VPVirtIOSoundInputRing ring;
    CHECK(!VPVirtIOSoundInputRingInit(&ring, 100, 64));
    CHECK(!VPVirtIOSoundInputRingInit(&ring, 128, 0));
    CHECK(VPVirtIOSoundInputRingInit(&ring, 4 * 64, 64));
    uint32_t offset = 99;
    // Four slots, in order, then nothing: a slot in flight is not free.
    for (uint32_t slot = 0; slot < 4; slot++) {
        CHECK(VPVirtIOSoundInputRingNextSubmission(&ring, &offset));
        CHECK(offset == slot * 64);
        VPVirtIOSoundInputRingDidSubmit(&ring);
    }
    CHECK(!VPVirtIOSoundInputRingNextSubmission(&ring, &offset));
    CHECK(VPVirtIOSoundInputRingInFlight(&ring) == 256);
    CHECK(VPVirtIOSoundInputRingAvailable(&ring) == 0);
    // Completion frees nothing either: the frames are not read yet.
    VPVirtIOSoundInputRingDidComplete(&ring);
    CHECK(VPVirtIOSoundInputRingInFlight(&ring) == 192);
    CHECK(VPVirtIOSoundInputRingAvailable(&ring) == 64);
    CHECK(!VPVirtIOSoundInputRingNextSubmission(&ring, &offset));
    // Only a whole period read frees a slot, and it is the first one again.
    uint8_t frames[64];
    CHECK(VPVirtIOSoundInputRingRead(&ring, frames, 32));
    CHECK(!VPVirtIOSoundInputRingNextSubmission(&ring, &offset));
    CHECK(VPVirtIOSoundInputRingRead(&ring, frames, 32));
    CHECK(VPVirtIOSoundInputRingNextSubmission(&ring, &offset));
    CHECK(offset == 0);
    VPVirtIOSoundInputRingDestroy(&ring);
}

static void testInputRingReadsInOrderAcrossTheEnd(void) {
    VPVirtIOSoundInputRing ring;
    CHECK(VPVirtIOSoundInputRingInit(&ring, 2 * 64, 64));
    uint8_t frames[96];
    capturePeriod(&ring, 1);
    // All or none: 65 bytes are not there yet.
    CHECK(!VPVirtIOSoundInputRingRead(&ring, frames, 65));
    CHECK(VPVirtIOSoundInputRingAvailable(&ring) == 64);
    CHECK(VPVirtIOSoundInputRingRead(&ring, frames, 32));
    capturePeriod(&ring, 2);
    CHECK(VPVirtIOSoundInputRingRead(&ring, frames, 64));
    CHECK(frames[0] == 1 && frames[31] == 1 && frames[32] == 2 && frames[63] == 2);
    // The third period lands in the first slot; a read from 96 wraps into it.
    capturePeriod(&ring, 3);
    CHECK(VPVirtIOSoundInputRingRead(&ring, frames, 96));
    CHECK(frames[0] == 2 && frames[31] == 2 && frames[32] == 3 && frames[95] == 3);
    CHECK(VPVirtIOSoundInputRingAvailable(&ring) == 0);

    CHECK(!VPVirtIOSoundInputRingSkip(&ring, 1));
    capturePeriod(&ring, 4);
    CHECK(VPVirtIOSoundInputRingSkip(&ring, 60));
    CHECK(VPVirtIOSoundInputRingRead(&ring, frames, 4));
    CHECK(frames[0] == 4);

    VPVirtIOSoundInputRingReset(&ring);
    CHECK(VPVirtIOSoundInputRingAvailable(&ring) == 0);
    CHECK(VPVirtIOSoundInputRingInFlight(&ring) == 0);
    VPVirtIOSoundInputRingDestroy(&ring);
}

// MARK: - Input reader

static bool isAll(const uint8_t *bytes, uint32_t length, uint8_t value) {
    for (uint32_t i = 0; i < length; i++) {
        if (bytes[i] != value) {
            return false;
        }
    }
    return true;
}

/// Eight-byte frames, 64-byte periods, a two-period lead, and at most four
/// periods buffered.
static VPVirtIOSoundInputReader reader(VPVirtIOSoundInputRing *ring) {
    VPVirtIOSoundInputReader value;
    memset(&value, 0, sizeof(value));
    value.ring = ring;
    value.bytesPerFrame = 8;
    value.leadBytes = 2 * 64;
    value.maximumBacklogBytes = 4 * 64;
    return value;
}

static void testReaderWaitsForTheLead(void) {
    VPVirtIOSoundInputRing ring;
    CHECK(VPVirtIOSoundInputRingInit(&ring, 12 * 64, 64));
    VPVirtIOSoundInputReader input = reader(&ring);
    uint8_t frames[32];

    // Nothing captured, then one period: silence, and nothing consumed.
    fill(frames, sizeof(frames), 0xff);
    VPVirtIOSoundInputReaderRead(&input, frames, 4);
    CHECK(isAll(frames, 32, 0));
    capturePeriod(&ring, 1);
    fill(frames, sizeof(frames), 0xff);
    VPVirtIOSoundInputReaderRead(&input, frames, 4);
    CHECK(isAll(frames, 32, 0));
    CHECK(VPVirtIOSoundInputRingAvailable(&ring) == 64);

    // The second period is the lead: reads are served, oldest first.
    capturePeriod(&ring, 2);
    VPVirtIOSoundInputReaderRead(&input, frames, 4);
    CHECK(isAll(frames, 32, 1));
    CHECK(input.servedFrames == 4 && input.silentFrames == 8);
    // And stay served below the lead, down to the last frame.
    for (int i = 0; i < 3; i++) {
        VPVirtIOSoundInputReaderRead(&input, frames, 4);
    }
    CHECK(isAll(frames, 32, 2));
    CHECK(VPVirtIOSoundInputRingAvailable(&ring) == 0);

    // Running dry is silence, and the lead is waited for again.
    VPVirtIOSoundInputReaderRead(&input, frames, 4);
    CHECK(isAll(frames, 32, 0));
    capturePeriod(&ring, 3);
    VPVirtIOSoundInputReaderRead(&input, frames, 4);
    CHECK(isAll(frames, 32, 0));
    capturePeriod(&ring, 4);
    VPVirtIOSoundInputReaderRead(&input, frames, 4);
    CHECK(isAll(frames, 32, 3));
    VPVirtIOSoundInputRingDestroy(&ring);
}

static void testReaderBoundsTheBacklog(void) {
    VPVirtIOSoundInputRing ring;
    CHECK(VPVirtIOSoundInputRingInit(&ring, 12 * 64, 64));
    VPVirtIOSoundInputReader input = reader(&ring);
    uint8_t frames[32];
    // Four periods buffered are allowed and read from the oldest.
    for (uint8_t period = 1; period <= 4; period++) {
        capturePeriod(&ring, period);
    }
    VPVirtIOSoundInputReaderRead(&input, frames, 4);
    CHECK(isAll(frames, 32, 1));
    CHECK(input.skippedBytes == 0);
    // Two more make 352 bytes: over the limit, so all but the lead goes and
    // the read continues from what is left.
    capturePeriod(&ring, 5);
    capturePeriod(&ring, 6);
    VPVirtIOSoundInputReaderRead(&input, frames, 4);
    CHECK(input.skippedBytes == 352 - 128);
    CHECK(isAll(frames, 32, 5));
    CHECK(VPVirtIOSoundInputRingAvailable(&ring) == 128 - 32);
    VPVirtIOSoundInputRingDestroy(&ring);
}

static void testReaderDropsWhatTheLastRunLeft(void) {
    VPVirtIOSoundInputRing ring;
    CHECK(VPVirtIOSoundInputRingInit(&ring, 12 * 64, 64));
    VPVirtIOSoundInputReader input = reader(&ring);
    uint8_t frames[32];
    capturePeriod(&ring, 1);
    capturePeriod(&ring, 2);
    capturePeriod(&ring, 3);
    VPVirtIOSoundInputReaderRead(&input, frames, 4);
    CHECK(isAll(frames, 32, 1));

    // A new start: the 160 bytes still buffered are old, and the lead is
    // waited for from scratch.
    input.restart = true;
    VPVirtIOSoundInputReaderRead(&input, frames, 4);
    CHECK(isAll(frames, 32, 0));
    CHECK(VPVirtIOSoundInputRingAvailable(&ring) == 0);
    capturePeriod(&ring, 4);
    capturePeriod(&ring, 5);
    VPVirtIOSoundInputReaderRead(&input, frames, 4);
    CHECK(isAll(frames, 32, 4));

    // A read larger than the lead is served once that much is there.
    uint8_t large[192];
    input.restart = true;
    capturePeriod(&ring, 6);
    capturePeriod(&ring, 7);
    VPVirtIOSoundInputReaderRead(&input, large, 24);
    CHECK(isAll(large, 192, 0));
    capturePeriod(&ring, 8);
    capturePeriod(&ring, 9);
    capturePeriod(&ring, 10);
    VPVirtIOSoundInputReaderRead(&input, large, 24);
    CHECK(isAll(large, 64, 8) && isAll(large + 64, 64, 9) && isAll(large + 128, 64, 10));
    VPVirtIOSoundInputRingDestroy(&ring);
}

int main(void) {
    testPrefersFloat48k();
    testFallsBackToInteger();
    testTakesHighestOtherRate();
    testRefusesUnusableDevice();
    testSizesAndParameters();
    testRingSubmitsWholePeriods();
    testRingKeepsInFlightBytes();
    testRingWrapsWritesAndSplitsSubmissions();
    testRingQueuesSilenceAhead();
    testRingResetAndValidation();
    testInputRingHandsOutWholeSlots();
    testInputRingReadsInOrderAcrossTheEnd();
    testReaderWaitsForTheLead();
    testReaderBoundsTheBacklog();
    testReaderDropsWhatTheLastRunLeft();
    if (failures) {
        fprintf(stderr, "VirtIOSoundTests: %d failure(s)\n", failures);
        return 1;
    }
    printf("VirtIOSoundTests: all passed\n");
    return 0;
}
