// VPVirtIOSoundProtocol.h — the guest kernel's AppleVirtIOSoundUserClient.
//
// The cloudOS kernelcache matches `AppleVirtIOSound` to virtio device 0x19
// (virtio-snd) and publishes `AppleVirtIOSoundUserClient` for it, but no iOS
// userland ships the CoreAudio half that drives it: macOS has
// /System/Library/Audio/Plug-Ins/HAL/AppleVirtIOSound.driver, cloudOS and
// iOS have nothing. The selectors below were read out of that macOS plugin
// (Research/Guest/virtio_sound.md); each one forwards one virtio-snd request,
// so the structures are the virtio specification's own.
//
// Nothing here depends on CoreAudio, so the host test harness compiles it.

#ifndef VPVirtIOSoundProtocol_h
#define VPVirtIOSoundProtocol_h

#include <stdbool.h>
#include <stdint.h>

// MARK: - User-client selectors

enum {
    /// 1 scalar in (stream ID), `VPVirtIOSoundPCMInfo` out.
    kVPVirtIOSoundSelectorPCMInfo = 1,
    /// 1 scalar in (stream ID), `VPVirtIOSoundPCMParameters` in.
    kVPVirtIOSoundSelectorSetParameters = 3,
    /// 1 scalar in (stream ID) each.
    kVPVirtIOSoundSelectorPrepare = 4,
    kVPVirtIOSoundSelectorStart = 5,
    kVPVirtIOSoundSelectorStop = 6,
    kVPVirtIOSoundSelectorRelease = 7,
    /// Async. 1 scalar in (stream ID), the PCM bytes as the input structure.
    /// The kernel keeps the caller's pages until the completion arrives.
    kVPVirtIOSoundSelectorWrite = 8,
    /// Async. 1 scalar in (stream ID), one period of the caller's pages as the
    /// output structure. The device fills it with captured PCM and the
    /// completion arrives when the period is full.
    kVPVirtIOSoundSelectorRead = 9,
};

/// The IORegistry key on the `AppleVirtIOSound` service with the stream count.
#define kVPVirtIOSoundStreamCountKey "AVIOSoundStreamCountKey"

// MARK: - virtio-snd structures

/// `struct virtio_snd_pcm_info`.
typedef struct {
    uint32_t hdaFunctionNodeID;
    uint32_t features;
    uint64_t formats;
    uint64_t rates;
    uint8_t direction;
    uint8_t channelsMinimum;
    uint8_t channelsMaximum;
    uint8_t padding[5];
} VPVirtIOSoundPCMInfo;
_Static_assert(sizeof(VPVirtIOSoundPCMInfo) == 32, "virtio_snd_pcm_info is 32 bytes");

/// `struct virtio_snd_pcm_set_params`. The kernel fills the header (request
/// code and stream ID) from the scalar; the plugin leaves it zero.
typedef struct {
    uint32_t code;
    uint32_t streamID;
    uint32_t bufferBytes;
    uint32_t periodBytes;
    uint32_t features;
    uint8_t channels;
    uint8_t format;
    uint8_t rate;
    uint8_t padding;
} VPVirtIOSoundPCMParameters;
_Static_assert(sizeof(VPVirtIOSoundPCMParameters) == 24, "virtio_snd_pcm_set_params is 24 bytes");

enum {
    kVPVirtIOSoundDirectionOutput = 0,
    kVPVirtIOSoundDirectionInput = 1,
};

/// `VIRTIO_SND_PCM_FMT_*` values the plugin can feed CoreAudio from.
enum {
    kVPVirtIOSoundFormatS16 = 5,
    kVPVirtIOSoundFormatS32 = 17,
    kVPVirtIOSoundFormatFloat = 19,
};

// MARK: - Stream format

/// The one format a stream runs at: what CoreAudio is told and what
/// SET_PARAMS asks the device for.
typedef struct {
    double sampleRate;
    uint32_t channels;
    uint32_t bitsPerChannel;
    uint32_t bytesPerFrame;
    bool isFloat;
    uint8_t virtioFormat;
    uint8_t virtioRate;
} VPVirtIOSoundStreamFormat;

/// The sample rate behind a `VIRTIO_SND_PCM_RATE_*` index, or 0.
double VPVirtIOSoundRateForIndex(uint8_t index);

/// Pick a format from what the device offers: 32-bit float, then 32-bit and
/// 16-bit signed integer; 48 kHz, then 44.1 kHz, then the highest rate; the
/// widest channel count. False when the device offers nothing usable.
bool VPVirtIOSoundChooseFormat(const VPVirtIOSoundPCMInfo *info, VPVirtIOSoundStreamFormat *format);

/// Period and buffer sizes for a format: a period is a twelfth of a second
/// rounded up to whole pages, and the buffer holds twelve periods, as Apple's
/// macOS plugin sizes them.
void VPVirtIOSoundBufferSizes(
    const VPVirtIOSoundStreamFormat *format,
    uint32_t pageSize,
    uint32_t *periodBytes,
    uint32_t *bufferBytes);

/// The SET_PARAMS body for a format and its sizes.
VPVirtIOSoundPCMParameters VPVirtIOSoundParameters(
    const VPVirtIOSoundStreamFormat *format,
    uint32_t periodBytes,
    uint32_t bufferBytes);

#endif /* VPVirtIOSoundProtocol_h */
