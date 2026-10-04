// VPVirtIOSoundProtocol.c — format choice and SET_PARAMS sizing.

#include "VPVirtIOSoundProtocol.h"

#include <string.h>

// MARK: - Rates

// `VIRTIO_SND_PCM_RATE_*`, indexed by the bit the device sets in `rates`.
static const double kRates[] = {
    5512, 8000, 11025, 16000, 22050, 32000, 44100,
    48000, 64000, 88200, 96000, 176400, 192000, 384000,
};
static const uint8_t kRateCount = sizeof(kRates) / sizeof(kRates[0]);

double VPVirtIOSoundRateForIndex(uint8_t index) {
    return index < kRateCount ? kRates[index] : 0;
}

static bool chooseRate(uint64_t rates, uint8_t *index) {
    static const uint8_t preferred[] = {7, 6}; // 48 kHz, 44.1 kHz
    for (unsigned i = 0; i < sizeof(preferred); i++) {
        if (rates & (1ULL << preferred[i])) {
            *index = preferred[i];
            return true;
        }
    }
    for (int bit = kRateCount - 1; bit >= 0; bit--) {
        if (rates & (1ULL << bit)) {
            *index = (uint8_t)bit;
            return true;
        }
    }
    return false;
}

// MARK: - Format

bool VPVirtIOSoundChooseFormat(const VPVirtIOSoundPCMInfo *info, VPVirtIOSoundStreamFormat *format) {
    memset(format, 0, sizeof(*format));
    if (info->channelsMaximum == 0) {
        return false;
    }
    uint8_t rate = 0;
    if (!chooseRate(info->rates, &rate)) {
        return false;
    }
    if (info->formats & (1ULL << kVPVirtIOSoundFormatFloat)) {
        format->virtioFormat = kVPVirtIOSoundFormatFloat;
        format->bitsPerChannel = 32;
        format->isFloat = true;
    } else if (info->formats & (1ULL << kVPVirtIOSoundFormatS32)) {
        format->virtioFormat = kVPVirtIOSoundFormatS32;
        format->bitsPerChannel = 32;
    } else if (info->formats & (1ULL << kVPVirtIOSoundFormatS16)) {
        format->virtioFormat = kVPVirtIOSoundFormatS16;
        format->bitsPerChannel = 16;
    } else {
        return false;
    }
    format->virtioRate = rate;
    format->sampleRate = VPVirtIOSoundRateForIndex(rate);
    format->channels = info->channelsMaximum;
    format->bytesPerFrame = format->bitsPerChannel / 8 * format->channels;
    return true;
}

// MARK: - Sizes

enum { kPeriodsPerBuffer = 12 };

void VPVirtIOSoundBufferSizes(
    const VPVirtIOSoundStreamFormat *format,
    uint32_t pageSize,
    uint32_t *periodBytes,
    uint32_t *bufferBytes) {
    uint32_t perSecond = (uint32_t)format->sampleRate * format->bytesPerFrame;
    uint32_t period = perSecond / kPeriodsPerBuffer;
    period = (period + pageSize - 1) / pageSize * pageSize;
    *periodBytes = period;
    *bufferBytes = period * kPeriodsPerBuffer;
}

VPVirtIOSoundPCMParameters VPVirtIOSoundParameters(
    const VPVirtIOSoundStreamFormat *format,
    uint32_t periodBytes,
    uint32_t bufferBytes) {
    VPVirtIOSoundPCMParameters parameters;
    memset(&parameters, 0, sizeof(parameters));
    parameters.bufferBytes = bufferBytes;
    parameters.periodBytes = periodBytes;
    parameters.channels = (uint8_t)format->channels;
    parameters.format = format->virtioFormat;
    parameters.rate = format->virtioRate;
    return parameters;
}
