// VPVirtIOSoundPlugin.m — CoreAudio HAL plugin for the VM's virtio-snd device.
//
// audiomxd loads this bundle from /System/Library/Audio/Plug-Ins/HAL when the
// kernel has published `AppleVirtIOSound` (Info.plist's loading condition).
// Each `AppleVirtIOSound` service becomes two HAL devices, a speaker with the
// service's output streams and a microphone with its input streams, because
// VirtualAudio builds a port from a device's UID and one UID names one kind
// of port. The host opens its microphone only while the guest records: the
// virtio input stream is started when CoreAudio starts the microphone device
// and released when it stops.
//
// Each device clock (VPVirtIOSoundClock.h) is free running, anchored to
// mach_absolute_time when I/O starts, as the macOS plugin's is. The mixed
// output goes into a ring (see VPVirtIOSoundRing.h) and a timer hands it to
// the kernel a period at a time with the async write selector; the virtio
// device paces playback on the host.
// Input runs the other way without a timer: a few periods of the input ring
// are always with the kernel, and each one that comes back full is replaced.
//
// Optional settings in the `com.apple.coreaudio` preference domain, read
// once when audiomxd loads the plugin:
//   VPhoneVirtIOSoundTransportType   four-character transport ("usb ", "bltn")
//   VPhoneVirtIOSoundDeviceUID       speaker device UID (default "PuffinOutput"
//                                    on iPad, iPhone and HomePod mini guests,
//                                    "VPhoneVirtIOSound:0" elsewhere)
//   VPhoneVirtIOSoundInputDeviceUID  microphone device UID (default "Digital
//                                    Mic" on an iPad or iPhone guest,
//                                    "VPhoneVirtIOSoundInput:0" elsewhere)
//   VPhoneVirtIOSoundNominalRate     44100 to start at the alternate rate
//   VPhoneVirtIOSoundProductID       the ProductID VirtualAudio is given
//                                    (default 8010 on an iPad or iPhone
//                                    guest); 0 leaves VirtualAudio's own
//   VPhoneVirtIOSoundLeadPeriods     periods of silence queued ahead of the
//                                    mix at each start, 0 to 8
//
// and one that vphoned keeps, read at load, again when vphoned posts
// `com.vphone.audio.host-latency`, and at each speaker start:
//   VPhoneVirtIOSoundHostLatency     seconds the Mac's output device adds after
//                                    its mixer (vphone-vm sends it with
//                                    `audio.host_latency`), added to the
//                                    speaker's output latency; 0 to 1

#import "VPVirtIOSoundAudioServerDriver.h"

#include <IOKit/IOKitLib.h>
#include <mach-o/dyld.h>
#include <mach/mach_time.h>
#include <math.h>
#include <notify.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "VPVirtIOSoundClock.h"
#include "VPVirtIOSoundConverter.h"
#include "VPVirtIOSoundFilter.h"
#include "VPVirtIOSoundLatency.h"
#include "VPVirtIOSoundProtocol.h"
#include "VPVirtIOSoundRing.h"

// Newer CoreAudio spelling of element 0; both arms of the mute check accept
// the raw 0 regardless.
#ifndef kAudioObjectPropertyElementMain
#define kAudioObjectPropertyElementMain 0
#endif

// MARK: - Constants

/// The macOS plugin's timestamp period: 260 ms of frames.
static const double kTimestampPeriodSeconds = 0.26;
static const UInt32 kSafetyOffsetFrames = 100;
/// How often queued periods are handed to the device: 1/24 s, as the macOS
/// plugin flushes, a little under half a period.
static const uint64_t kFlushIntervalNanoseconds = NSEC_PER_SEC / 24;
static const uint32_t kAsyncReferenceCount = 3;
/// Periods of the input ring the kernel holds at a time, as the macOS plugin
/// keeps (`kInputInitialBuffers`).
static const uint32_t kInputReadsInFlight = 4;
/// Periods captured before reads are served (VPVirtIOSoundRing.h, the input
/// reader), and the most that may be buffered before the oldest are dropped.
static const uint32_t kInputLeadPeriods = 2;
static const uint32_t kInputMaximumBacklogPeriods = 4;
/// How long a stopped input stream waits for its reads to come back before
/// it releases the device with them still out.
static const uint64_t kInputDrainNanoseconds = NSEC_PER_SEC;
/// A start that finds the trigger file also writes what it captures, as the
/// host sent it, to the path beside it, up to the limit. For comparing the
/// capture with what a recording app makes of it.
static const char *const kInputDumpTrigger = "/var/mobile/vpinput.dump";
static const char *const kInputDumpPath = "/var/mobile/vpinput.raw";
static const uint64_t kInputDumpMaximumBytes = 16 * 1024 * 1024;
/// Where the capture's low cut sits. See VPVirtIOSoundFilter.h.
static const double kInputHighPassHertz = 120;

/// How the speaker's queued latency is followed (VPVirtIOSoundLatency.h): a
/// window of in-flight counts every five seconds, once a run has settled as
/// long; up after two windows that ask for more, down after twelve, a minute,
/// that ask for less.
static const uint64_t kLatencyWindowNanoseconds = 5 * NSEC_PER_SEC;
static const uint64_t kLatencySettleNanoseconds = 5 * NSEC_PER_SEC;
static const uint32_t kLatencyRisingWindows = 2;
static const uint32_t kLatencyFallingWindows = 12;

/// What vphoned posts after it stores `VPhoneVirtIOSoundHostLatency`.
static const char *const kHostLatencyNotification = "com.vphone.audio.host-latency";

/// The speaker volume control's range. VirtualAudio maps the guest's volume
/// onto it in a straight line and reads the decibels back, so the range is
/// only how the guest's volume reaches the plugin: `applyGain` takes the
/// position in it, not the decibels, as the gain.
static const float kSpeakerMinimumDecibels = -36.0f;
static const float kMicrophoneMinimumDecibels = -60.0f;

static CFStringRef const kSettingsDomain = CFSTR("com.apple.coreaudio");

/// The data sources the macOS plugin selects: the internal speaker for its
/// output and the internal microphone for its input ('ispk', 'imic'; no SDK
/// constant carries them).
static const UInt32 kVPDataSourceInternalSpeaker = 0x6973706b;
static const UInt32 kVPDataSourceInternalMicrophone = 0x696d6963;

/// `kAudioDevicePropertyMute` ('mute'), which the trimmed iPhoneOS CoreAudio
/// headers leave out (AudioHardwareBase.h stops at the server-side set).
static const UInt32 kVPDevicePropertyMute = 0x6d757465;

/// `kAudioDevicePropertyNominalSampleRate` ('nsrt'), absent from the same
/// trimmed headers.
static const UInt32 kVPDevicePropertyNominalSampleRate = 0x6e737274;

/// The rate a ringtone-preview aggregate runs the vdef at. The virtio wire
/// itself only offers 48000, so the device advertises this rate beside it
/// and the mix converts into the wire rate.
static const double kVPAlternateRate = 44100;

static os_log_t VPLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.vphone.audio", "virtiosound");
    });
    return log;
}

// MARK: - Selector inventory

/// The guest's property vocabulary for this plugin, one line per distinct
/// (operation, selector, scope, element). A syslog capture during a session
/// activation then shows every selector VirtualAudio and the HAL server ask
/// the plugin's objects, which selectors they never ask, and in what order —
/// the inventory a missing-property hunt needs. Repeats are suppressed: the
/// first ask of a tuple logs, later ones only counted by the guest's own
/// noise.
///
/// Everything also lands in `/var/mobile/vpquery.log`: the 2.3.x guest
/// vphoned's syslog tail stopped delivering `com.vphone.audio` lines (the
/// 2.2.5-era tail carried them), and the inventory died with the channel.
/// The file is the reliable transport; each line carries a UTC wall-clock
/// stamp so its entries align with the first-party syslog captures that
/// still work, and a size cap keeps a runaway query loop from filling the
/// disk. audiomxd can write there (the session-4 reflection probe proved
/// the path with `/var/mobile/vpprobe.log`).
static void VPLogToFile(const char *format, ...) __attribute__((format(printf, 1, 2)));

static void VPLogToFile(const char *format, ...) {
    static const char *kPath = "/var/mobile/vpquery.log";
    static const off_t kCap = 4 * 1024 * 1024;
    struct stat st;
    if (stat(kPath, &st) == 0 && st.st_size > kCap) {
        return;
    }
    FILE *file = fopen(kPath, "a");
    if (!file) {
        return;
    }
    struct timeval now;
    gettimeofday(&now, NULL);
    struct tm utc;
    gmtime_r(&now.tv_sec, &utc);
    va_list args;
    va_start(args, format);
    fprintf(file, "%02d:%02d:%02d.%03d ", utc.tm_hour, utc.tm_min, utc.tm_sec, now.tv_usec / 1000);
    vfprintf(file, format, args);
    fputc('\n', file);
    va_end(args);
    fclose(file);
}

/// Whether an image whose path contains `fragment` is mapped into audiomxd.
static BOOL VPImageLoaded(const char *fragment) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, fragment)) {
            return YES;
        }
    }
    return NO;
}

static NSString *VPFourCC(UInt32 code) {
    char text[5] = {
        (char)(code >> 24), (char)(code >> 16), (char)(code >> 8), (char)code, 0,
    };
    return [NSString stringWithFormat:@"%s", text];
}

static void VPLogSelectorQuery(const char *operation, const AudioObjectPropertyAddress *address) {
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        seen = [NSMutableSet set];
    });
    NSString *key = [NSString stringWithFormat:@"%s:%u:%u:%u",
        operation, address->mSelector, address->mScope, address->mElement];
    @synchronized(seen) {
        if ([seen containsObject:key]) {
            return;
        }
        [seen addObject:key];
    }
    os_log(VPLog(), "query %{public}s: '%{public}@' / '%{public}@' / %u",
        operation, VPFourCC(address->mSelector), VPFourCC(address->mScope), address->mElement);
    VPLogToFile("query %s: '%s' / '%s' / %u",
        operation, VPFourCC(address->mSelector).UTF8String,
        VPFourCC(address->mScope).UTF8String, address->mElement);
}

// MARK: - Settings

static UInt32 VPTransportType(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("VPhoneVirtIOSoundTransportType"), kSettingsDomain);
    UInt32 transport = kAudioDeviceTransportTypeUSB;
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        char code[8] = {0};
        if (CFStringGetCString(value, code, sizeof(code), kCFStringEncodingASCII) && strlen(code) == 4) {
            transport = (UInt32)code[0] << 24 | (UInt32)code[1] << 16 | (UInt32)code[2] << 8 | (UInt32)code[3];
        }
    }
    if (value) {
        CFRelease(value);
    }
    return transport;
}

/// The guest's `hw.machine` ("iPad16,1"), read once; empty if unreadable.
static const char *VPMachine(void) {
    static char machine[64];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        size_t size = sizeof(machine) - 1;
        if (sysctlbyname("hw.machine", machine, &size, NULL, 0) != 0) {
            machine[0] = 0;
        }
    });
    return machine;
}

/// A VirtualAudio routing override, or 0 to retain native product selection.
/// HomePod mini uses native B520 route 4 through this audio-only preference.
/// Keep the original VM product token: its donor replacement also changes
/// unrelated services, including HomePodDisplayService's physical gamma path.
///
/// Watch7,18 uses native acoustic product 4017 to select its HALSPP graph.
/// The VM-derived 198 asks for a graph the watch does not ship.
/// See Research/Guest/watch_audio.md.
///
/// VirtualAudio derives its ProductID from a MobileGestalt class answer, and
/// vphone600 lands on a simulator class — 196 presenting an iPad, 195 an
/// iPhone — whose routing constructor skips the sub-port configurations the
/// real routes need: it throws (`RoutingSettings_J98.cpp:805`,
/// `RoutingSettings_N71.cpp:1167`), never initializes, and every session
/// gets "VirtualAudio PlugIn is not initialized yet" — no sound anywhere.
/// 8010 is the one accepted ID found whose category map also covers ringtone
/// previews, on both: an iPhone guest initializes with 8018, its own audio
/// node's acoustic ID, and plays Safari, but a tone's route change dies there
/// as it does with 198 on an iPad. Both defaults below key on this one
/// answer, so a guest gets either the whole route or none of it.
///
/// `VPhoneVirtIOSoundProductID` in the plugin's settings replaces the answer,
/// for trying another ID; 0 there leaves VirtualAudio to itself. vphoned
/// reads the same key (`GuestVirtualAudioProduct`).
static int VPGuestProductID(void) {
    static int product;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *machine = VPMachine();
        product = strncmp(machine, "iPad", 4) == 0 || strncmp(machine, "iPhone", 6) == 0 ? 8010 : 0;
        if (strcmp(machine, "AudioAccessory5,1") == 0) product = 4;
        if (strcmp(machine, "Watch7,18") == 0) product = 4017;
        id chosen = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("VPhoneVirtIOSoundProductID"), kSettingsDomain));
        if ([chosen isKindOfClass:NSNumber.class] && [chosen intValue] >= 0) {
            product = [chosen intValue];
        }
    });
    return product;
}

static NSString *VPDeviceUID(ASDStreamDirection direction, unsigned index) {
    BOOL input = direction == ASDStreamDirectionInput;
    NSString *uid = CFBridgingRelease(CFPreferencesCopyAppValue(
        input ? CFSTR("VPhoneVirtIOSoundInputDeviceUID") : CFSTR("VPhoneVirtIOSoundDeviceUID"),
        kSettingsDomain));
    if ([uid isKindOfClass:NSString.class] && uid.length > 0) {
        return index == 0 ? uid : [NSString stringWithFormat:@"%@:%u", uid, index];
    }
    // VirtualAudio builds a physical device, and a port, only for the UIDs
    // its device factory knows. "PuffinOutput" is the built-in output of
    // Apple-silicon host audio, and the one such UID that publishes a routable
    // speaker ('pspk'). Its twin "PuffinInput" publishes the built-in
    // microphone ('pmbi') too, but bare: record routes ask the port for the
    // product's microphone sub-ports ('btm1', 'vcrg') and throw when it has
    // none. "Digital Mic" is the codec microphone VirtualAudio builds those
    // sub-ports for. Under any name of our own a device is claimed by nothing.
    // Only where the route is set up: a speaker route on a VirtualAudio that
    // was not deadlocked audiomxd and crash-looped it across launches.
    // Native HomePod and watch routes claim PuffinOutput; their microphone
    // arrays are not supplied by the virtual device, so their input keeps a
    // name of our own. A product of 0 claims nothing on any machine: it leaves
    // VirtualAudio to itself, and the route this device would need is then the
    // one VirtualAudio never set up.
    const char *machine = VPMachine();
    BOOL outputOnly = strcmp(machine, "AudioAccessory5,1") == 0 || strcmp(machine, "Watch7,18") == 0;
    if (index == 0 && VPGuestProductID() != 0) {
        if (!input) return @"PuffinOutput";
        if (!outputOnly) return @"Digital Mic";
    }
    return [NSString stringWithFormat:@"VPhoneVirtIOSound%s:%u", input ? "Input" : "", index];
}

/// Gives VirtualAudio `VPGuestProductID()` through its own defaults key,
/// `ProductIDOverride` in `com.apple.audio.virtualaudio`, which it reads
/// before deriving one. The key is set here, in the process, on every launch
/// that does not find that value in it: audiomxd's sandbox keeps the write
/// from reaching disk. Whatever is stored gives way, so a guest that still
/// has 198 from the earlier recipe plays tones without anyone deleting it;
/// another ID is chosen with `VPhoneVirtIOSoundProductID`.
///
/// Set in the process, the value reaches VirtualAudio only when this plugin
/// initializes before VirtualAudio reads its defaults. That has been the
/// order on every launch looked at, and nothing guarantees it, so vphoned
/// stores the same value where every later launch of audiomxd finds it
/// whatever the order (`GuestVirtualAudioProduct`). The one line logged says
/// what was done and whether VirtualAudio was already mapped into audiomxd:
/// one that was not cannot have read its defaults yet; one that was may have.
static void VPEnsureVirtualAudioProduct(void) {
    BOOL virtualAudioLoaded = VPImageLoaded("/VirtualAudio.plugin/");
    NSString *outcome;
    int product = VPGuestProductID();
    if (product == 0) {
        outcome = @"no ProductID for this guest, left as is";
    } else {
        CFStringRef domain = CFSTR("com.apple.audio.virtualaudio");
        CFStringRef key = CFSTR("ProductIDOverride");
        id existing = CFBridgingRelease(CFPreferencesCopyAppValue(key, domain));
        if ([existing isKindOfClass:NSNumber.class] && [existing intValue] == product) {
            outcome = [NSString stringWithFormat:@"stored %d, nothing to do", product];
        } else {
            CFNumberRef value = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product);
            CFPreferencesSetAppValue(key, value, domain);
            CFRelease(value);
            id now = CFBridgingRelease(CFPreferencesCopyAppValue(key, domain));
            outcome = [NSString stringWithFormat:@"%@, %@ %d for this launch",
                existing ? [NSString stringWithFormat:@"stored %@", existing] : @"unset",
                [now isKindOfClass:NSNumber.class] && [now intValue] == product ? @"set to" : @"could not be set to",
                product];
        }
    }
    const char *loaded = virtualAudioLoaded ? "already loaded" : "not loaded yet";
    os_log(VPLog(), "ProductIDOverride on '%{public}s': %{public}@; VirtualAudio %{public}s",
        VPMachine(), outcome, loaded);
    VPLogToFile("ProductIDOverride on '%s': %s; VirtualAudio %s", VPMachine(), outcome.UTF8String, loaded);
}

/// How many periods of silence go to the device before the mix at each start.
static const int kDefaultLeadPeriods = 2;
static const int kMaximumLeadPeriods = 8;

static uint32_t VPLeadPeriods(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("VPhoneVirtIOSoundLeadPeriods"), kSettingsDomain);
    int periods = kDefaultLeadPeriods;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberIntType, &periods);
    }
    if (value) {
        CFRelease(value);
    }
    return (uint32_t)MAX(0, MIN(periods, kMaximumLeadPeriods));
}

/// What the Mac's output device adds after its mixer, in seconds, as vphoned
/// last stored it; 0 when it never did. Synchronized first: vphoned writes
/// the domain from another process, and this one's cache would otherwise
/// keep the value it read at load.
static double VPStoredHostLatency(void) {
    CFPreferencesAppSynchronize(kSettingsDomain);
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("VPhoneVirtIOSoundHostLatency"), kSettingsDomain);
    double seconds = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberDoubleType, &seconds);
    }
    if (value) {
        CFRelease(value);
    }
    return isfinite(seconds) && seconds > 0 ? MIN(seconds, kVPVirtIOSoundMaximumHostLatency) : 0;
}

/// The nominal rate the device boots with, for testing how VirtualAudio picks
/// aggregate members: a ringtone-preview vdef runs at 44100 and may require a
/// candidate's *current* nominal rate to match, not just advertised support.
/// 0 (or any unsupported value) leaves the wire rate as the nominal rate.
static double VPNominalRateOverride(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("VPhoneVirtIOSoundNominalRate"), kSettingsDomain);
    double rate = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        double number = 0;
        if (CFNumberGetValue(value, kCFNumberDoubleType, &number) && number > 0) {
            rate = number;
        }
    }
    if (value) {
        CFRelease(value);
    }
    return rate;
}

// MARK: - Resampler

/// Linear-rate conversion of the HAL mix into the virtio wire rate. The
/// virtio stream always runs SET_PARAMS at 48000, but a ringtone-preview
/// aggregate runs the device at 44100; `writeMixBlock` then hands over
/// 44100-frame blocks that must become 48000 frames in the ring. Plain
/// linear interpolation is enough — a preview tone has no content near
/// Nyquist worth protecting.
typedef struct {
    /// The last input frame, the interpolation partner of the next block's
    /// first frame.
    float lastFrame[2];
    /// Where the next output frame falls between the previous and the
    /// current input frame, in input frames.
    double phase;
} VPResampler;

static void VPResamplerReset(VPResampler *resampler) {
    resampler->lastFrame[0] = 0;
    resampler->lastFrame[1] = 0;
    resampler->phase = 0;
}

/// Converts one interleaved stereo float block into `scratch`, returning the
/// output frame count. Outputs land `rateIn / rateOut` input frames apart,
/// so each input frame emits one or two.
static uint32_t VPResamplerProcess(VPResampler *resampler, const float *input, uint32_t inputFrames,
    double rateIn, double rateOut, float *scratch, uint32_t scratchFrames) {
    const double step = rateIn / rateOut;
    uint32_t outputFrames = 0;
    for (uint32_t i = 0; i < inputFrames; i++) {
        const float *current = input + i * 2;
        while (resampler->phase < 1.0 && outputFrames < scratchFrames) {
            float *output = scratch + outputFrames * 2;
            output[0] = resampler->lastFrame[0] + (current[0] - resampler->lastFrame[0]) * (float)resampler->phase;
            output[1] = resampler->lastFrame[1] + (current[1] - resampler->lastFrame[1]) * (float)resampler->phase;
            outputFrames++;
            resampler->phase += step;
        }
        resampler->phase -= 1.0;
        resampler->lastFrame[0] = current[0];
        resampler->lastFrame[1] = current[1];
    }
    return outputFrames;
}

/// Input frames per resampler pass; 512 in at 44100→48000 produces at most
/// 559 out, so a 1024-frame scratch bounds the allocation.
static const uint32_t kResampleChunkFrames = 512;
static const uint32_t kResampleScratchFrames = 1024;

/// What `writeMixBlock` captures instead of the stream object: the I/O
/// thread must not touch Objective-C, so it gets plain pointers that live as
/// long as the device.
typedef struct {
    VPVirtIOSoundRing *ring;
    _Atomic uint32_t *halRate;
    VPResampler *resampler;
    float *scratch;
    uint32_t bytesPerFrame;
    uint32_t wireRate;
    /// The gain the device's volume and mute controls ask for, as the bits
    /// of a float; and the gain the last block ended at, the I/O thread's
    /// own. Applied to float samples only, which is what the device offers.
    bool isFloat;
    _Atomic uint32_t gainBits;
    float appliedGain;
    /// The lead, in bytes, that the first write after a start queues ahead
    /// of its frames. The stream's queue sets it at the start; the I/O thread
    /// takes it.
    _Atomic uint32_t leadRequest;
    /// Since the last start: frames the HAL handed over, bytes that went into
    /// the ring, bytes the ring refused because the device had not returned
    /// the space, and bytes of silence queued as the lead.
    _Atomic uint64_t framesIn;
    _Atomic uint64_t bytesOut;
    _Atomic uint64_t dropped;
    _Atomic uint64_t leadOut;
} VPMixState;

static void VPMixRingWrite(VPMixState *mix, const void *bytes, uint32_t length) {
    if (VPVirtIOSoundRingWrite(mix->ring, bytes, length)) {
        atomic_fetch_add_explicit(&mix->bytesOut, length, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&mix->dropped, length, memory_order_relaxed);
    }
}

/// Tops what is queued ahead of the host up to `lead` bytes, right before
/// the first frames of a run. From here on the mix arrives in real time, so
/// whatever is queued now is the cushion every later period is handed over
/// with — however long the HAL took to start its I/O after `startStream`.
/// What a draining run still has queued counts, except the oldest period in
/// flight: the host may have all but played it, and counting it whole left
/// restarts a period short.
static void VPMixQueueLead(VPMixState *mix, uint32_t lead) {
    uint64_t queued = VPVirtIOSoundRingQueued(mix->ring);
    uint64_t ahead = queued > mix->ring->period ? queued - mix->ring->period : 0;
    if (ahead >= lead) {
        return;
    }
    uint32_t silence = (uint32_t)(lead - ahead);
    if (VPVirtIOSoundRingWriteSilence(mix->ring, silence)) {
        atomic_fetch_add_explicit(&mix->leadOut, silence, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&mix->dropped, silence, memory_order_relaxed);
    }
}

static uint32_t VPGainBits(float gain) {
    uint32_t bits;
    memcpy(&bits, &gain, sizeof(bits));
    return bits;
}

/// Scales one block in place to the gain the controls ask for, moving there
/// across the block so a change does not click. The buffer is the HAL's mix,
/// handed over for this device to consume.
static void VPMixApplyGain(VPMixState *mix, float *samples, uint32_t frames) {
    uint32_t bits = atomic_load_explicit(&mix->gainBits, memory_order_relaxed);
    float target;
    memcpy(&target, &bits, sizeof(target));
    float gain = mix->appliedGain;
    if ((gain == 1.0f && target == 1.0f) || frames == 0) {
        return;
    }
    uint32_t channels = mix->bytesPerFrame / sizeof(float);
    float step = (target - gain) / frames;
    for (uint32_t frame = 0; frame < frames; frame++) {
        gain += step;
        for (uint32_t channel = 0; channel < channels; channel++) {
            samples[frame * channels + channel] *= gain;
        }
    }
    mix->appliedGain = target;
}

static int VPMixWrite(VPMixState *mix, void *buffer, UInt32 frameCount) {
    uint32_t lead = atomic_exchange_explicit(&mix->leadRequest, 0, memory_order_acquire);
    if (lead > 0) {
        VPMixQueueLead(mix, lead);
    }
    if (mix->isFloat) {
        VPMixApplyGain(mix, buffer, frameCount);
    }
    atomic_fetch_add_explicit(&mix->framesIn, frameCount, memory_order_relaxed);
    uint32_t halRate = atomic_load(mix->halRate);
    if (halRate == mix->wireRate) {
        VPMixRingWrite(mix, buffer, frameCount * mix->bytesPerFrame);
        return kAudioHardwareNoError;
    }
    uint32_t done = 0;
    while (done < frameCount) {
        uint32_t chunk = frameCount - done;
        if (chunk > kResampleChunkFrames) {
            chunk = kResampleChunkFrames;
        }
        uint32_t converted = VPResamplerProcess(mix->resampler,
            (const float *)((uint8_t *)buffer + done * mix->bytesPerFrame), chunk,
            halRate, mix->wireRate, mix->scratch, kResampleScratchFrames);
        VPMixRingWrite(mix, mix->scratch, converted * mix->bytesPerFrame);
        done += chunk;
    }
    return kAudioHardwareNoError;
}

// MARK: - Stream

typedef NS_ENUM(NSInteger, VPStreamState) {
    /// The virtio stream is released; SET_PARAMS comes first.
    VPStreamStateIdle,
    /// Started on the device, and CoreAudio is doing I/O.
    VPStreamStateRunning,
    /// CoreAudio stopped; the device stops once what it holds comes back.
    VPStreamStateDraining,
    /// Input only: the device was released with reads still out, and the
    /// stream waits for them before it can be set up again.
    VPStreamStateReleasing,
};

/// The refcon of one async transfer: the stream, and the transfer's bytes in
/// its ring.
typedef struct {
    void *stream;
    uint32_t offset;
    uint32_t length;
} VPTransfer;

/// What the output and input streams share: the virtio stream's identity and
/// format, the serial queue its device commands and completions run on, and
/// the property inventory.
@interface VPVirtIOSoundStream : ASDStream {
@protected
    io_connect_t _connection;
    ASDStreamDirection _direction;
    uint32_t _streamID;
    VPVirtIOSoundStreamFormat _format;
    uint32_t _periodBytes;
    uint32_t _bufferBytes;
    dispatch_queue_t _queue;
    IONotificationPortRef _port;
    VPStreamState _state;
    BOOL _reportedTransferError;
    /// When CoreAudio last started the stream, for the counters' rates.
    uint64_t _startedAt;
}
- (instancetype)initWithConnection:(io_connect_t)connection
                          streamID:(uint32_t)streamID
                            format:(VPVirtIOSoundStreamFormat)format
                         direction:(ASDStreamDirection)direction
                            plugin:(ASDPlugin *)plugin;
/// Frames, at the wire rate, between the guest's I/O and the host's.
@property (nonatomic, readonly) UInt32 queuedLatencyFrames;
/// Called on the stream's queue when `queuedLatencyFrames` changed. Set once,
/// by the device, before the stream runs.
@property (copy, nonatomic) void (^queuedLatencyChanged)(UInt32 frames);
/// The device the stream belongs to, which is where its rate is changed.
@property (weak, nonatomic) ASDAudioDevice *device;
/// Whether the stream answers `kVPAlternateRate` beside the wire rate,
/// converting between the two itself.
@property (nonatomic, readonly) BOOL offersAlternateRate;
/// What the device's volume and mute controls come to, 0 to 1.
- (void)setGain:(float)gain;
@end

@implementation VPVirtIOSoundStream

- (instancetype)initWithConnection:(io_connect_t)connection
                          streamID:(uint32_t)streamID
                            format:(VPVirtIOSoundStreamFormat)format
                         direction:(ASDStreamDirection)direction
                            plugin:(ASDPlugin *)plugin {
    self = [super initWithDirection:direction withPlugin:plugin];
    if (!self) {
        return nil;
    }
    _connection = connection;
    _direction = direction;
    _streamID = streamID;
    _format = format;
    VPVirtIOSoundBufferSizes(&format, (uint32_t)getpagesize(), &_periodBytes, &_bufferBytes);
    _queue = dispatch_queue_create("com.vphone.audio.virtiosound.stream", DISPATCH_QUEUE_SERIAL);
    _port = IONotificationPortCreate(kIOMainPortDefault);
    if (!_port) {
        return nil;
    }
    IONotificationPortSetDispatchQueue(_port, _queue);
    ASDStreamFormat *physical = [self physicalFormatAtRate:format.sampleRate];
    self.streamName = direction == ASDStreamDirectionInput ? @"Input Stream" : @"Output Stream";
    self.physicalFormat = physical;
    self.physicalFormats = @[physical];
    return self;
}

- (void)dealloc {
    if (_port) {
        IONotificationPortDestroy(_port);
    }
}

/// The stream's format as CoreAudio is told it, at one fixed rate.
- (ASDStreamFormat *)physicalFormatAtRate:(double)rate {
    AudioStreamBasicDescription description = {
        .mSampleRate = rate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = (_format.isFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger)
            | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = _format.bytesPerFrame,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = _format.bytesPerFrame,
        .mChannelsPerFrame = _format.channels,
        .mBitsPerChannel = _format.bitsPerChannel,
    };
    ASDStreamFormat *format = [[ASDStreamFormat alloc] initWithAudioStreamBasicDescription:&description];
    format.minimumSampleRate = rate;
    format.maximumSampleRate = rate;
    return format;
}

- (BOOL)offersAlternateRate {
    return NO;
}

- (void)logFormatWithLeadPeriods:(uint32_t)leadPeriods {
    const char *direction = _direction == ASDStreamDirectionInput ? "input" : "output";
    os_log(VPLog(), "stream %u: %{public}s, %.0f Hz, %u channels, %u-bit %{public}s, period %u bytes",
        _streamID, direction, _format.sampleRate, _format.channels, _format.bitsPerChannel,
        _format.isFloat ? "float" : "integer", _periodBytes);
    VPLogToFile("stream %u: %s, %.0f Hz, %u channels, %u-bit %s, period %u bytes, lead %u period(s)",
        _streamID, direction, _format.sampleRate, _format.channels, _format.bitsPerChannel,
        _format.isFloat ? "float" : "integer", _periodBytes, leadPeriods);
}

- (UInt32)queuedLatencyFrames {
    return 0;
}

- (void)setGain:(float)gain {
    (void)gain;
}

// MARK: Property inventory

// The same five entry points as the device's below, logging what the stream
// object itself is asked (its physical formats and layouts mostly) before
// ASDStream answers.

- (BOOL)hasProperty:(AudioObjectPropertyAddress *)address {
    VPLogSelectorQuery("stream-has", address);
    return [super hasProperty:address];
}

- (BOOL)isPropertySettable:(AudioObjectPropertyAddress *)address {
    VPLogSelectorQuery("stream-settable", address);
    return [super isPropertySettable:address];
}

- (UInt32)dataSizeForProperty:(AudioObjectPropertyAddress *)address
           withQualifierSize:(UInt32)qualifierSize
           andQualifierData:(const void *)qualifierData {
    VPLogSelectorQuery("stream-size", address);
    return [super dataSizeForProperty:address withQualifierSize:qualifierSize
                       andQualifierData:qualifierData];
}

- (BOOL)getProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32 *)dataSize
                 andData:(void *)data
              forClient:(UInt32)clientID {
    VPLogSelectorQuery("stream-get", address);
    return [super getProperty:address withQualifierSize:qualifierSize
                 qualifierData:qualifierData dataSize:dataSize
                       andData:data forClient:clientID];
}

- (BOOL)setProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32)dataSize
                 andData:(const void *)data
              forClient:(UInt32)clientID {
    VPLogSelectorQuery("stream-set", address);
    if ([super setProperty:address withQualifierSize:qualifierSize
             qualifierData:qualifierData dataSize:dataSize
                   andData:data forClient:clientID]) {
        return YES;
    }
    // A route that plays and records puts both devices in one aggregate and
    // sets each stream's format there, where a playback route sets the
    // device's nominal rate. ASDStream refuses a plugin stream's format the
    // way ASDAudioDevice refuses its rate (see the device's `setProperty:`):
    // the HAL reports 'what' and the route fails with "failed to set the new
    // format on the aggregate device". The formats of a stream differ only
    // in rate, so the change is the device's rate change, which reaches
    // every stream.
    if ((address->mSelector == kAudioStreamPropertyPhysicalFormat
            || address->mSelector == kAudioStreamPropertyVirtualFormat)
        && dataSize >= sizeof(AudioStreamBasicDescription) && data != NULL) {
        double rate = ((const AudioStreamBasicDescription *)data)->mSampleRate;
        ASDAudioDevice *device = self.device;
        if (rate > 0 && [device supportsSamplingRate:rate]) {
            VPLogToFile("stream %u: format set to %.0f Hz through the device", _streamID, rate);
            device.samplingRate = rate;
            return YES;
        }
    }
    return NO;
}

// MARK: Device commands

- (kern_return_t)callSelector:(uint32_t)selector {
    uint64_t scalar = _streamID;
    kern_return_t result = IOConnectCallScalarMethod(_connection, selector, &scalar, 1, NULL, NULL);
    if (result != KERN_SUCCESS) {
        os_log_error(VPLog(), "stream %u: selector %u failed: 0x%x", _streamID, selector, result);
    }
    return result;
}

/// SET_PARAMS and PREPARE: the device stream is set up and waits for START.
- (BOOL)prepareDevice {
    dispatch_assert_queue(_queue);
    VPVirtIOSoundPCMParameters parameters = VPVirtIOSoundParameters(&_format, _periodBytes, _bufferBytes);
    uint64_t scalar = _streamID;
    kern_return_t result = IOConnectCallMethod(_connection, kVPVirtIOSoundSelectorSetParameters,
        &scalar, 1, &parameters, sizeof(parameters), NULL, NULL, NULL, NULL);
    if (result != KERN_SUCCESS) {
        os_log_error(VPLog(), "stream %u: SET_PARAMS failed: 0x%x", _streamID, result);
        return NO;
    }
    if ([self callSelector:kVPVirtIOSoundSelectorPrepare] != KERN_SUCCESS) {
        [self callSelector:kVPVirtIOSoundSelectorRelease];
        return NO;
    }
    _reportedTransferError = NO;
    return YES;
}

- (void)releaseDevice {
    dispatch_assert_queue(_queue);
    [self callSelector:kVPVirtIOSoundSelectorStop];
    [self callSelector:kVPVirtIOSoundSelectorRelease];
}

- (void)reportTransferError:(IOReturn)result length:(uint32_t)length {
    if (result != kIOReturnSuccess && !_reportedTransferError) {
        _reportedTransferError = YES;
        os_log_error(VPLog(), "stream %u: transfer of %u bytes failed: 0x%x", _streamID, length, result);
        VPLogToFile("stream %u: transfer of %u bytes failed: 0x%x", _streamID, length, result);
    }
}

@end

// MARK: - Output stream

@interface VPVirtIOSoundOutputStream : VPVirtIOSoundStream
- (instancetype)initWithConnection:(io_connect_t)connection
                          streamID:(uint32_t)streamID
                            format:(VPVirtIOSoundStreamFormat)format
                            plugin:(ASDPlugin *)plugin;
- (void)transferCompletedWithLength:(uint32_t)length result:(IOReturn)result;
@end

static void VPWriteCompleted(void *refcon, IOReturn result, void **arguments, UInt32 argumentCount) {
    (void)arguments;
    (void)argumentCount;
    VPTransfer *transfer = refcon;
    VPVirtIOSoundOutputStream *stream = (__bridge VPVirtIOSoundOutputStream *)transfer->stream;
    uint32_t length = transfer->length;
    free(transfer);
    [stream transferCompletedWithLength:length result:result];
}

@implementation VPVirtIOSoundOutputStream {
    VPVirtIOSoundRing _ring;
    dispatch_source_t _timer;
    /// Periods of silence queued ahead of the mix at each device start.
    uint32_t _leadPeriods;
    /// Since the last start: what the device still held then, writes handed
    /// to the device, and how many of them found it with nothing left to
    /// play.
    uint64_t _inFlightAtStart;
    uint64_t _submissions;
    uint64_t _starved;
    /// The fewest and most bytes in flight a write after the first found, for
    /// the run and for the minute `logProgress` last covered.
    uint64_t _minInFlight;
    uint64_t _maxInFlight;
    uint64_t _windowMinInFlight;
    uint64_t _windowMaxInFlight;
    uint64_t _reportedAt;
    /// The host's consumption once the run has settled: when the first write
    /// came back, the bytes returned after it, and when the last one did;
    /// and the longest wait between two returns.
    uint64_t _firstCompletedAt;
    uint64_t _lastCompletedAt;
    uint64_t _completedAfterFirst;
    uint64_t _maxCompletionGap;
    /// The periods queued ahead of the host as reported, and the window it
    /// is fed from: when the window began, the most bytes in flight a write
    /// in it found, and how many writes it saw.
    VPVirtIOSoundLatencyTracker _latency;
    uint64_t _latencyWindowStartedAt;
    uint64_t _latencyWindowMaxInFlight;
    uint64_t _latencyWindowWrites;
    /// The rate CoreAudio runs the stream at, which is the wire rate until a
    /// 44100 aggregate switches the device. The mix block reads it, the rate
    /// change writes it, both lock-free.
    _Atomic uint32_t _halRate;
    VPResampler _resampler;
    float *_resampleScratch;
    VPMixState _mix;
}

/// ASDStream's `stopStream` releases every I/O block the stream holds and
/// `startStream` copies them again from the same properties, so a block set
/// once at init is gone after the first stop: the next start runs with no
/// write block and nothing reaches the ring. It goes back in before every
/// start. The I/O thread must not touch Objective-C or take locks, so the
/// block captures plain state; the stream lives as long as its device.
- (void)installMixBlock {
    VPMixState *mix = &_mix;
    self.writeMixBlock = ^int(UInt32 frameCount, const AudioServerPlugInIOCycleInfo *cycleInfo,
        void *mainBuffer, void *secondaryBuffer, UInt32 clientID) {
        (void)cycleInfo;
        (void)secondaryBuffer;
        (void)clientID;
        return VPMixWrite(mix, mainBuffer, frameCount);
    };
}

- (instancetype)initWithConnection:(io_connect_t)connection
                          streamID:(uint32_t)streamID
                            format:(VPVirtIOSoundStreamFormat)format
                            plugin:(ASDPlugin *)plugin {
    self = [super initWithConnection:connection streamID:streamID format:format
                           direction:ASDStreamDirectionOutput plugin:plugin];
    if (!self) {
        return nil;
    }
    if (!VPVirtIOSoundRingInit(&_ring, _bufferBytes, _periodBytes)) {
        os_log_error(VPLog(), "stream %u: cannot allocate a %u-byte ring", streamID, _bufferBytes);
        return nil;
    }
    _leadPeriods = VPLeadPeriods();
    VPVirtIOSoundLatencyTrackerInit(&_latency, _leadPeriods + 1, kLatencyRisingWindows, kLatencyFallingWindows);
    _resampleScratch = malloc(kResampleScratchFrames * format.bytesPerFrame);
    if (!_resampleScratch) {
        return nil;
    }

    double nominalRate = 0;
    // The 44100 twin: a ringtone-preview aggregate runs the vdef at 44100,
    // and the aggregate only carries devices that answer that rate. The
    // virtio stream itself stays at the wire rate; the mix resamples. The
    // current format follows the nominal-rate override so the device boots
    // already answering 44100, matching how the vdef composes.
    if (self.offersAlternateRate) {
        ASDStreamFormat *reduced = [self physicalFormatAtRate:kVPAlternateRate];
        self.physicalFormats = @[self.physicalFormat, reduced];
        self.physicalFormatSettable = YES;
        double override = VPNominalRateOverride();
        if (override == kVPAlternateRate) {
            nominalRate = override;
            self.physicalFormat = reduced;
        }
    }

    atomic_init(&_halRate, nominalRate > 0 ? (uint32_t)nominalRate : (uint32_t)format.sampleRate);
    VPResamplerReset(&_resampler);
    _mix = (VPMixState){
        .ring = &_ring,
        .halRate = &_halRate,
        .resampler = &_resampler,
        .scratch = _resampleScratch,
        .bytesPerFrame = format.bytesPerFrame,
        .wireRate = (uint32_t)format.sampleRate,
        .isFloat = format.isFloat,
        .appliedGain = 1.0f,
    };
    atomic_init(&_mix.gainBits, VPGainBits(1.0f));
    [self installMixBlock];
    [self logFormatWithLeadPeriods:_leadPeriods];
    return self;
}

- (void)dealloc {
    if (_timer) {
        dispatch_source_cancel(_timer);
    }
    free(_resampleScratch);
    VPVirtIOSoundRingDestroy(&_ring);
}

- (void)setGain:(float)gain {
    atomic_store_explicit(&_mix.gainBits, VPGainBits(gain), memory_order_relaxed);
}

- (BOOL)offersAlternateRate {
    // B520's speaker DSP requires a 48 kHz physical endpoint. Advertising
    // 44.1 kHz makes its 1024-frame graph read 1115 frames from that buffer,
    // producing silence before the PCM reaches us. Source audio at 44.1 kHz
    // still plays through CoreAudio's converter with the endpoint at 48 kHz.
    return _format.sampleRate == 48000.0 && strcmp(VPMachine(), "AudioAccessory5,1") != 0;
}

// MARK: Rate changes

- (BOOL)deviceChangedToSamplingRate:(double)rate {
    // ASD returns YES even when no physical format supports the new rate.
    // Only accept rates this stream actually configured above.
    if (rate != _format.sampleRate && !(rate == kVPAlternateRate && self.offersAlternateRate)) {
        return NO;
    }
    os_log(VPLog(), "rate-probe: stream %u deviceChangedToSamplingRate %.0f (hal %.0f, format %.0f)",
        _streamID, rate, (double)atomic_load(&_halRate), self.physicalFormat.sampleRate);
    VPLogToFile("rate-probe: stream %u deviceChangedToSamplingRate %.0f (hal %.0f, format %.0f)",
        _streamID, rate, (double)atomic_load(&_halRate), self.physicalFormat.sampleRate);
    if (![super deviceChangedToSamplingRate:rate] || self.physicalFormat.sampleRate != rate) {
        return NO;
    }
    uint32_t previous = atomic_load(&_halRate);
    if (rate > 0 && (uint32_t)rate != previous) {
        atomic_store(&_halRate, (uint32_t)rate);
        VPResamplerReset(&_resampler);
        os_log(VPLog(), "stream %u: device rate %.0f -> %.0f, physical format %.0f Hz",
            _streamID, (double)previous, rate, self.physicalFormat.sampleRate);
    }
    return YES;
}

// MARK: Device commands

- (BOOL)startDevice {
    dispatch_assert_queue(_queue);
    VPVirtIOSoundRingReset(&_ring);
    if (![self prepareDevice]) {
        return NO;
    }
    if ([self callSelector:kVPVirtIOSoundSelectorStart] != KERN_SUCCESS) {
        [self callSelector:kVPVirtIOSoundSelectorRelease];
        return NO;
    }
    return YES;
}

/// The device plays what it is handed as it arrives and the mix arrives in
/// real time, so with nothing queued ahead every late period is a gap on the
/// host: measured, a third to a half of all writes found the device with
/// nothing left to play. A few periods of silence first put that much audio
/// between the guest's writes and the host's playback. The I/O thread queues
/// them itself, ahead of its first write (`VPMixQueueLead`): only then is it
/// known what a draining run still holds and how long the HAL took to start,
/// and `written` keeps its one writer.
- (void)queueLead {
    dispatch_assert_queue(_queue);
    atomic_store_explicit(&_mix.leadRequest, _leadPeriods * _periodBytes, memory_order_release);
}

/// The lead plus one period until the host is seen keeping more in flight
/// (`trackLatency`).
- (UInt32)queuedLatencyFrames {
    return _latency.periods * (_periodBytes / _format.bytesPerFrame);
}

// MARK: Counters

- (void)resetCounters {
    dispatch_assert_queue(_queue);
    _startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    _reportedAt = _startedAt;
    _inFlightAtStart = VPVirtIOSoundRingInFlight(&_ring);
    _submissions = 0;
    _starved = 0;
    _minInFlight = UINT64_MAX;
    _maxInFlight = 0;
    _windowMinInFlight = UINT64_MAX;
    _windowMaxInFlight = 0;
    _firstCompletedAt = 0;
    // A draining run's returns carry on into this one, so a gap between its
    // tail and this run's lead still shows.
    if (_inFlightAtStart == 0) {
        _lastCompletedAt = 0;
    }
    _completedAfterFirst = 0;
    _maxCompletionGap = 0;
    _latencyWindowStartedAt = _startedAt;
    _latencyWindowMaxInFlight = 0;
    _latencyWindowWrites = 0;
    atomic_store(&_mix.framesIn, 0);
    atomic_store(&_mix.bytesOut, 0);
    atomic_store(&_mix.dropped, 0);
    atomic_store(&_mix.leadOut, 0);
}

- (double)periodsForBytes:(uint64_t)bytes {
    return bytes == UINT64_MAX ? 0 : (double)bytes / _periodBytes;
}

/// Wire frames a second the host has played since the run settled, from the
/// device's completions. The mix arrives at the wire rate of the guest's
/// clock, so against it this is how far the host's audio clock runs from
/// the guest's, and how fast the cushion would erode or grow.
- (double)hostRate {
    if (_firstCompletedAt == 0 || _lastCompletedAt <= _firstCompletedAt) {
        return 0;
    }
    return (double)_completedAfterFirst / _format.bytesPerFrame / ((_lastCompletedAt - _firstCompletedAt) / 1e9);
}

- (double)hostDriftPPM {
    double rate = self.hostRate;
    return rate > 0 ? (rate / _format.sampleRate - 1) * 1e6 : 0;
}

/// One line per run of the device, for telling a gap on the host (`starved`)
/// from an unhappy HAL clock (`in` far from the nominal rate) from a full
/// ring (`dropped`). `start` is what a draining run still held when this one
/// started, `lead` the silence queued ahead of it, `in flight` the cushion
/// writes after the first found (whole periods: the device returns whole
/// writes, each a period after the last while it plays), `host` the rate
/// the device played at, and `returns` the longest wait between two returns,
/// which a stall on either side stretches.
- (void)logCounters {
    double seconds = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - _startedAt) / 1e9;
    uint64_t framesIn = atomic_load(&_mix.framesIn);
    uint64_t framesOut = atomic_load(&_mix.bytesOut) / _format.bytesPerFrame;
    VPLogToFile("stream %u: %.2f s, %llu writes, %llu starved, %llu bytes dropped, "
        "in %llu frames (%.0f/s, hal %u), out %llu frames (%.0f/s); "
        "start %.2f, lead %.2f, in flight %.2f-%.2f periods; host %.1f/s (%+.0f ppm), returns <= %.0f ms apart",
        _streamID, seconds, (unsigned long long)_submissions, (unsigned long long)_starved,
        (unsigned long long)atomic_load(&_mix.dropped),
        (unsigned long long)framesIn, seconds > 0 ? framesIn / seconds : 0, atomic_load(&_halRate),
        (unsigned long long)framesOut, seconds > 0 ? framesOut / seconds : 0,
        [self periodsForBytes:_inFlightAtStart], [self periodsForBytes:atomic_load(&_mix.leadOut)],
        [self periodsForBytes:_minInFlight], [self periodsForBytes:_maxInFlight],
        self.hostRate, self.hostDriftPPM, _maxCompletionGap / 1e6);
}

/// A line a minute while the device runs, so a long playback shows whether
/// the cushion holds.
- (void)logProgress {
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - _reportedAt < 60 * NSEC_PER_SEC) {
        return;
    }
    VPLogToFile("stream %u: running %.0f s, %llu writes, %llu starved, in flight %.2f-%.2f periods "
        "this minute; host %.1f/s (%+.0f ppm)",
        _streamID, (now - _startedAt) / 1e9, (unsigned long long)_submissions, (unsigned long long)_starved,
        [self periodsForBytes:_windowMinInFlight], [self periodsForBytes:_windowMaxInFlight],
        self.hostRate, self.hostDriftPPM);
    _reportedAt = now;
    _windowMinInFlight = UINT64_MAX;
    _windowMaxInFlight = 0;
}

/// Feeds the latency tracker one window at a time (VPVirtIOSoundLatency.h)
/// and tells the device when the queued figure moves. Windows that began
/// before the run settled do not count: they hold the lead going out at
/// once and a draining run's tail, not what the host keeps.
- (void)trackLatency {
    dispatch_assert_queue(_queue);
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - _latencyWindowStartedAt < kLatencyWindowNanoseconds) {
        return;
    }
    BOOL settled = _latencyWindowStartedAt >= _startedAt + kLatencySettleNanoseconds;
    if (settled && _latencyWindowWrites > 0) {
        uint32_t previous = _latency.periods;
        uint32_t inFlight = VPVirtIOSoundLatencyPeriods(_latencyWindowMaxInFlight, _periodBytes);
        if (VPVirtIOSoundLatencyTrackerAddWindow(&_latency, inFlight)) {
            VPLogToFile("stream %u: queued ahead of the host %u -> %u periods "
                "(in flight up to %u periods in the last %.0f s, floor %u)",
                _streamID, previous, _latency.periods, inFlight, kLatencyWindowNanoseconds / 1e9,
                _latency.floorPeriods);
            if (self.queuedLatencyChanged) {
                self.queuedLatencyChanged(self.queuedLatencyFrames);
            }
        }
    }
    _latencyWindowStartedAt = now;
    _latencyWindowMaxInFlight = 0;
    _latencyWindowWrites = 0;
}

- (void)stopDevice {
    [self releaseDevice];
    _state = VPStreamStateIdle;
}

// MARK: Transfers

- (void)submitPending:(BOOL)partial {
    dispatch_assert_queue(_queue);
    mach_port_t wakePort = IONotificationPortGetMachPort(_port);
    uint32_t offset = 0;
    uint32_t length = 0;
    while (VPVirtIOSoundRingNextSubmission(&_ring, partial, &offset, &length)) {
        VPTransfer *transfer = malloc(sizeof(*transfer));
        if (!transfer) {
            return;
        }
        transfer->stream = (__bridge void *)self;
        transfer->offset = offset;
        transfer->length = length;
        uint64_t reference[kOSAsyncRef64Count] = {0};
        reference[kIOAsyncCalloutFuncIndex] = (uint64_t)(uintptr_t)VPWriteCompleted;
        reference[kIOAsyncCalloutRefconIndex] = (uint64_t)(uintptr_t)transfer;
        uint64_t scalar = _streamID;
        // Nothing in flight when a period goes out means the device already
        // played everything it had: a gap on the host.
        uint64_t inFlight = VPVirtIOSoundRingInFlight(&_ring);
        if (_submissions > 0) {
            if (inFlight == 0) {
                _starved++;
            }
            _minInFlight = MIN(_minInFlight, inFlight);
            _maxInFlight = MAX(_maxInFlight, inFlight);
            _windowMinInFlight = MIN(_windowMinInFlight, inFlight);
            _windowMaxInFlight = MAX(_windowMaxInFlight, inFlight);
            _latencyWindowMaxInFlight = MAX(_latencyWindowMaxInFlight, inFlight);
            _latencyWindowWrites++;
        }
        _submissions++;
        VPVirtIOSoundRingDidSubmit(&_ring, length);
        kern_return_t result = IOConnectCallAsyncMethod(_connection, kVPVirtIOSoundSelectorWrite, wakePort,
            reference, kAsyncReferenceCount, &scalar, 1, _ring.bytes + offset, length, NULL, NULL, NULL, NULL);
        if (result != KERN_SUCCESS) {
            // Nothing will complete this one, so return its space now.
            free(transfer);
            [self transferCompletedWithLength:length result:result];
        }
    }
}

- (void)transferCompletedWithLength:(uint32_t)length result:(IOReturn)result {
    dispatch_assert_queue(_queue);
    VPVirtIOSoundRingDidComplete(&_ring, length);
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (_lastCompletedAt > 0) {
        uint64_t gap = now - _lastCompletedAt;
        _maxCompletionGap = MAX(_maxCompletionGap, gap);
    }
    _lastCompletedAt = now;
    // The host's rate counts once the run has settled: its first returns
    // follow the start, a draining run's tail and the host's own buffering.
    if (now - _startedAt >= 5 * NSEC_PER_SEC) {
        if (_firstCompletedAt == 0) {
            _firstCompletedAt = now;
        } else {
            _completedAfterFirst += length;
        }
    }
    [self reportTransferError:result length:length];
    if (_state == VPStreamStateDraining && VPVirtIOSoundRingInFlight(&_ring) == 0) {
        [self stopDevice];
    }
}

// MARK: ASDStream

/// The flush timer runs only while the stream does. audiomxd keeps its
/// streams for its whole life, so a timer left running after the first
/// sound woke an idle audiomxd 24 times a second, about 21,600 times in 15
/// minutes with nothing playing. Arming and disarming happen on `_queue`,
/// in the same blocks that change `_state`.
- (void)armFlushTimer:(BOOL)armed {
    dispatch_assert_queue(_queue);
    if (armed) {
        dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, kFlushIntervalNanoseconds),
            kFlushIntervalNanoseconds, kFlushIntervalNanoseconds / 10);
    } else {
        dispatch_source_set_timer(_timer, DISPATCH_TIME_FOREVER, 0, 0);
    }
}

- (void)startStream {
    if (!_timer) {
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_timer, DISPATCH_TIME_FOREVER, 0, 0);
        __unsafe_unretained VPVirtIOSoundOutputStream *unretained = self;
        dispatch_source_set_event_handler(_timer, ^{
            if (unretained->_state == VPStreamStateRunning) {
                [unretained submitPending:NO];
                [unretained logProgress];
                [unretained trackLatency];
            }
        });
        dispatch_resume(_timer);
    }
    dispatch_sync(_queue, ^{
        if (self->_state == VPStreamStateIdle && ![self startDevice]) {
            return;
        }
        if (self->_state != VPStreamStateRunning) {
            [self resetCounters];
            [self queueLead];
            [self armFlushTimer:YES];
        }
        self->_state = VPStreamStateRunning;
    });
    [self installMixBlock];
    [super startStream];
}

- (void)stopStream {
    dispatch_sync(_queue, ^{
        if (self->_state != VPStreamStateRunning) {
            return;
        }
        [self logCounters];
        // A start the HAL never wrote after leaves no lead behind.
        atomic_store(&self->_mix.leadRequest, 0);
        [self submitPending:YES];
        // Draining needs no flush: the device's returns end it.
        [self armFlushTimer:NO];
        self->_state = VPStreamStateDraining;
        if (VPVirtIOSoundRingInFlight(&self->_ring) == 0) {
            [self stopDevice];
        }
    });
    [super stopStream];
}

@end

// MARK: - Input stream

@interface VPVirtIOSoundInputStream : VPVirtIOSoundStream
- (instancetype)initWithConnection:(io_connect_t)connection
                          streamID:(uint32_t)streamID
                            format:(VPVirtIOSoundStreamFormat)format
                            plugin:(ASDPlugin *)plugin;
- (void)readCompletedAtOffset:(uint32_t)offset result:(IOReturn)result argument:(uint64_t)argument;
@end

/// IOKit calls an async completion with as many arguments as the kernel
/// sent, so with one this is `IOAsyncCallback1`. The macOS plugin's block
/// receives the same pair and reads neither; the argument is only logged
/// here, once.
static void VPReadCompleted(void *refcon, IOReturn result, void *argument) {
    VPTransfer *transfer = refcon;
    VPVirtIOSoundInputStream *stream = (__bridge VPVirtIOSoundInputStream *)transfer->stream;
    uint32_t offset = transfer->offset;
    free(transfer);
    [stream readCompletedAtOffset:offset result:result argument:(uint64_t)(uintptr_t)argument];
}

/// Frames per converter pass; 512 out at 48000→44100 take at most 559 in,
/// so a 1024-frame scratch bounds the allocation.
static const uint32_t kCaptureChunkFrames = 512;
static const uint32_t kCaptureScratchFrames = 1024;

/// What `readInputBlock` captures instead of the stream object, as the mix
/// block does (`VPMixState`).
typedef struct {
    VPVirtIOSoundInputReader *reader;
    uint32_t bytesPerFrame;
    uint32_t wireRate;
    /// The rate CoreAudio reads the stream at, which is the wire rate until
    /// a route that plays and records at 44100 switches the device. The
    /// read block reads it, the rate change writes it.
    _Atomic uint32_t halRate;
    /// The conversion between the two, the I/O thread's own. `scratch` is
    /// NULL for a format the converter does not take; the stream then
    /// offers the wire rate only.
    VPVirtIOSoundConverter converter;
    float *scratch;
    /// Set when the stream starts: the converter starts over, as the reader
    /// does.
    _Atomic bool restart;
} VPCaptureState;

/// Fills `buffer` with `frameCount` captured frames at the rate CoreAudio
/// reads at, or with silence where the reader has none.
static void VPCaptureRead(VPCaptureState *capture, void *buffer, UInt32 frameCount) {
    uint32_t halRate = atomic_load_explicit(&capture->halRate, memory_order_relaxed);
    bool restart = atomic_exchange_explicit(&capture->restart, false, memory_order_acq_rel);
    if (halRate == capture->wireRate || capture->scratch == NULL) {
        VPVirtIOSoundInputReaderRead(capture->reader, buffer, frameCount);
        return;
    }
    VPVirtIOSoundConverter *converter = &capture->converter;
    if (restart || converter->outputRate != halRate) {
        VPVirtIOSoundConverterReset(converter, capture->wireRate, halRate, converter->channels);
    }
    UInt32 done = 0;
    while (done < frameCount) {
        uint32_t chunk = MIN(frameCount - done, kCaptureChunkFrames);
        float *output = (float *)((uint8_t *)buffer + done * capture->bytesPerFrame);
        uint32_t needed = VPVirtIOSoundConverterInputFrames(converter, chunk);
        if (needed > kCaptureScratchFrames) {
            // No pair of rates the device offers comes near this.
            memset(output, 0, chunk * capture->bytesPerFrame);
        } else {
            VPVirtIOSoundInputReaderRead(capture->reader, capture->scratch, needed);
            VPVirtIOSoundConverterProcess(converter, capture->scratch, output, chunk);
        }
        done += chunk;
    }
}

@implementation VPVirtIOSoundInputStream {
    VPVirtIOSoundInputRing _ring;
    VPVirtIOSoundInputReader _reader;
    VPCaptureState _capture;
    /// Counts stops, so a drain deadline knows the stop it was set for.
    uint64_t _stops;
    /// CoreAudio started the stream while it was `Releasing`.
    BOOL _startWhenReleased;
    BOOL _refillScheduled;
    BOOL _loggedFirstRead;
    /// Reads the device returned since CoreAudio last started the stream.
    uint64_t _completions;
    /// The level of what those reads held, per channel for the first two:
    /// the largest sample and the sum of squares over `_measuredFrames`.
    float _peak[2];
    double _squares[2];
    uint64_t _measuredFrames;
    /// Where the captured periods are also written, when
    /// `kInputDumpTrigger` exists at a start. Diagnostic only.
    FILE *_dump;
    uint64_t _dumpedBytes;
    /// The low cut each captured period goes through before the HAL reads it.
    VPVirtIOSoundHighPass _highPass;
    /// The device's mute control. Its volume is not applied: what the host
    /// captures is already at the level the Mac's input is set to.
    _Atomic bool _muted;
}

/// ASDStream releases this block at every stop, as it does the output
/// stream's (`installMixBlock`), so it goes back in before every start.
- (void)installReadBlock {
    VPCaptureState *capture = &_capture;
    _Atomic bool *muted = &_muted;
    uint32_t bytesPerFrame = _format.bytesPerFrame;
    self.readInputBlock = ^int(UInt32 frameCount, const AudioServerPlugInIOCycleInfo *cycleInfo,
        void *mainBuffer, void *secondaryBuffer, UInt32 clientID) {
        (void)cycleInfo;
        (void)secondaryBuffer;
        (void)clientID;
        // Read even when muted, so the ring keeps moving.
        VPCaptureRead(capture, mainBuffer, frameCount);
        if (atomic_load_explicit(muted, memory_order_relaxed)) {
            memset(mainBuffer, 0, frameCount * bytesPerFrame);
        }
        return kAudioHardwareNoError;
    };
}

- (void)setGain:(float)gain {
    atomic_store_explicit(&_muted, gain == 0, memory_order_relaxed);
}

- (instancetype)initWithConnection:(io_connect_t)connection
                          streamID:(uint32_t)streamID
                            format:(VPVirtIOSoundStreamFormat)format
                            plugin:(ASDPlugin *)plugin {
    self = [super initWithConnection:connection streamID:streamID format:format
                           direction:ASDStreamDirectionInput plugin:plugin];
    if (!self) {
        return nil;
    }
    if (!VPVirtIOSoundInputRingInit(&_ring, _bufferBytes, _periodBytes)) {
        os_log_error(VPLog(), "stream %u: cannot allocate a %u-byte ring", streamID, _bufferBytes);
        return nil;
    }
    _reader = (VPVirtIOSoundInputReader){
        .ring = &_ring,
        .bytesPerFrame = format.bytesPerFrame,
        .leadBytes = kInputLeadPeriods * _periodBytes,
        .maximumBacklogBytes = kInputMaximumBacklogPeriods * _periodBytes,
    };
    _capture = (VPCaptureState){
        .reader = &_reader,
        .bytesPerFrame = format.bytesPerFrame,
        .wireRate = (uint32_t)format.sampleRate,
    };
    atomic_init(&_capture.halRate, (uint32_t)format.sampleRate);
    // The 44100 twin, as the speaker's stream has it: a route that plays and
    // records at that rate sets it on both streams of its aggregate, and
    // fails when one refuses. The virtio stream stays at the wire rate;
    // captured frames are converted as they are read. Only for what the
    // converter takes, which is what the host sends.
    if (format.sampleRate == 48000.0 && format.isFloat && format.bitsPerChannel == 32
        && format.channels <= kVPVirtIOSoundConverterMaximumChannels) {
        _capture.scratch = malloc(kCaptureScratchFrames * format.bytesPerFrame);
    }
    if (_capture.scratch) {
        VPVirtIOSoundConverterReset(&_capture.converter, _capture.wireRate, (uint32_t)kVPAlternateRate,
            format.channels);
        ASDStreamFormat *reduced = [self physicalFormatAtRate:kVPAlternateRate];
        self.physicalFormats = @[self.physicalFormat, reduced];
        self.physicalFormatSettable = YES;
        if (VPNominalRateOverride() == kVPAlternateRate) {
            self.physicalFormat = reduced;
            atomic_store(&_capture.halRate, (uint32_t)kVPAlternateRate);
        }
    }
    // The low cut runs on each captured period in the ring, at the wire rate,
    // before the converter above reads it.
    VPVirtIOSoundHighPassConfigure(&_highPass, format.sampleRate, kInputHighPassHertz);
    [self installReadBlock];
    [self logFormatWithLeadPeriods:kInputLeadPeriods];
    return self;
}

- (void)dealloc {
    free(_capture.scratch);
    VPVirtIOSoundInputRingDestroy(&_ring);
}

- (BOOL)offersAlternateRate {
    return _capture.scratch != NULL;
}

// MARK: Rate changes

- (BOOL)deviceChangedToSamplingRate:(double)rate {
    if (rate != _format.sampleRate && !(rate == kVPAlternateRate && self.offersAlternateRate)) {
        return NO;
    }
    if (![super deviceChangedToSamplingRate:rate] || self.physicalFormat.sampleRate != rate) {
        return NO;
    }
    uint32_t previous = atomic_load(&_capture.halRate);
    if (rate > 0 && (uint32_t)rate != previous) {
        atomic_store(&_capture.halRate, (uint32_t)rate);
        os_log(VPLog(), "stream %u: device rate %.0f -> %.0f, physical format %.0f Hz",
            _streamID, (double)previous, rate, self.physicalFormat.sampleRate);
        VPLogToFile("stream %u: device rate %.0f -> %.0f, physical format %.0f Hz",
            _streamID, (double)previous, rate, self.physicalFormat.sampleRate);
    }
    return YES;
}

/// What the reader keeps between the host's capture and the guest's read.
- (UInt32)queuedLatencyFrames {
    return kInputLeadPeriods * (_periodBytes / _format.bytesPerFrame);
}

// MARK: Device commands

/// The macOS plugin's order: the reads go to the device between PREPARE and
/// START, so capture has somewhere to land from its first frame.
- (BOOL)startDevice {
    dispatch_assert_queue(_queue);
    VPVirtIOSoundInputRingReset(&_ring);
    if (![self prepareDevice]) {
        return NO;
    }
    _state = VPStreamStateRunning;
    [self submitReads];
    if ([self callSelector:kVPVirtIOSoundSelectorStart] != KERN_SUCCESS) {
        [self stopDevice];
        return NO;
    }
    return YES;
}

/// STOP and RELEASE. Reads still out keep their ring slots until the kernel
/// returns them, so the stream is not `Idle` before then.
- (void)stopDevice {
    [self releaseDevice];
    _state = VPVirtIOSoundInputRingInFlight(&_ring) == 0 ? VPStreamStateIdle : VPStreamStateReleasing;
}

/// One line per run, the input twin of the output stream's: `in` is what
/// the host captured, `out` what CoreAudio read of it, `silent` the frames
/// it was handed as silence instead (the lead at each start, then gaps), and
/// `skipped` what was dropped to bound the backlog.
- (void)logCounters {
    double seconds = (double)(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - _startedAt) / 1e9;
    uint64_t framesIn = _completions * (_periodBytes / _format.bytesPerFrame);
    uint64_t framesOut = atomic_load(&_reader.servedFrames);
    VPLogToFile("stream %u: %.2f s, %llu reads, in %llu frames (%.0f/s), out %llu frames (%.0f/s), "
        "%llu silent, %llu bytes skipped",
        _streamID, seconds, (unsigned long long)_completions,
        (unsigned long long)framesIn, seconds > 0 ? framesIn / seconds : 0,
        (unsigned long long)framesOut, seconds > 0 ? framesOut / seconds : 0,
        (unsigned long long)atomic_load(&_reader.silentFrames),
        (unsigned long long)atomic_load(&_reader.skippedBytes));
    if (_measuredFrames > 0) {
        double level[2] = {0, 0};
        double peak[2] = {0, 0};
        for (unsigned channel = 0; channel < 2; channel++) {
            level[channel] = 10 * log10(MAX(_squares[channel] / (double)_measuredFrames, 1e-12));
            peak[channel] = 20 * log10(MAX((double)_peak[channel], 1e-6));
        }
        VPLogToFile("stream %u: captured level %.1f / %.1f dBFS RMS, peak %.1f / %.1f dBFS",
            _streamID, level[0], level[1], peak[0], peak[1]);
    }
    if (_dump) {
        fclose(_dump);
        _dump = NULL;
        VPLogToFile("stream %u: wrote %llu captured bytes to %s",
            _streamID, (unsigned long long)_dumpedBytes, kInputDumpPath);
    }
}

/// Adds one returned period to the level counters, and to the dump when
/// there is one, then runs it through the low cut. Float samples only, which
/// is what the host sends.
- (void)measurePeriodAtOffset:(uint32_t)offset {
    if (!_format.isFloat || _format.bitsPerChannel != 32 || _format.channels == 0) {
        return;
    }
    const float *samples = (const float *)(_ring.bytes + offset);
    uint32_t channels = _format.channels;
    uint32_t frames = _periodBytes / _format.bytesPerFrame;
    for (uint32_t frame = 0; frame < frames; frame++) {
        for (uint32_t channel = 0; channel < MIN(channels, 2u); channel++) {
            float sample = samples[frame * channels + channel];
            if (!isfinite(sample)) {
                continue;
            }
            _peak[channel] = MAX(_peak[channel], fabsf(sample));
            _squares[channel] += (double)sample * sample;
        }
    }
    if (channels == 1) {
        _peak[1] = _peak[0];
        _squares[1] = _squares[0];
    }
    _measuredFrames += frames;
    if (_dump && _dumpedBytes < kInputDumpMaximumBytes) {
        _dumpedBytes += fwrite(samples, 1, _periodBytes, _dump);
    }
    // Measured and dumped as the host sent it; the HAL reads it filtered.
    VPVirtIOSoundHighPassProcess(&_highPass, (float *)(_ring.bytes + offset), frames, channels);
}

// MARK: Transfers

/// Keeps `kInputReadsInFlight` periods with the device. A full ring leaves
/// fewer out, and a failed read is not replaced at once, so either way the
/// stream looks again a period later instead of waiting for a completion
/// that may not come.
- (void)submitReads {
    dispatch_assert_queue(_queue);
    mach_port_t wakePort = IONotificationPortGetMachPort(_port);
    uint32_t offset = 0;
    while (VPVirtIOSoundInputRingInFlight(&_ring) < kInputReadsInFlight * _periodBytes
        && VPVirtIOSoundInputRingNextSubmission(&_ring, &offset)) {
        VPTransfer *transfer = malloc(sizeof(*transfer));
        if (!transfer) {
            break;
        }
        transfer->stream = (__bridge void *)self;
        transfer->offset = offset;
        transfer->length = _periodBytes;
        uint64_t reference[kOSAsyncRef64Count] = {0};
        reference[kIOAsyncCalloutFuncIndex] = (uint64_t)(uintptr_t)VPReadCompleted;
        reference[kIOAsyncCalloutRefconIndex] = (uint64_t)(uintptr_t)transfer;
        uint64_t scalar = _streamID;
        size_t size = _periodBytes;
        VPVirtIOSoundInputRingDidSubmit(&_ring);
        kern_return_t result = IOConnectCallAsyncMethod(_connection, kVPVirtIOSoundSelectorRead, wakePort,
            reference, kAsyncReferenceCount, &scalar, 1, NULL, 0, NULL, NULL, _ring.bytes + offset, &size);
        if (result != KERN_SUCCESS) {
            // Nothing will complete this one, so return its slot now.
            free(transfer);
            [self readCompletedAtOffset:offset result:result argument:0];
            return;
        }
    }
    if (VPVirtIOSoundInputRingInFlight(&_ring) < kInputReadsInFlight * _periodBytes) {
        [self scheduleRefill];
    }
}

- (void)scheduleRefill {
    if (_refillScheduled) {
        return;
    }
    _refillScheduled = YES;
    uint64_t period = NSEC_PER_SEC * (_periodBytes / _format.bytesPerFrame) / (uint64_t)_format.sampleRate;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)period), _queue, ^{
        self->_refillScheduled = NO;
        if (self->_state == VPStreamStateRunning) {
            [self submitReads];
        }
    });
}

- (void)readCompletedAtOffset:(uint32_t)offset result:(IOReturn)result argument:(uint64_t)argument {
    dispatch_assert_queue(_queue);
    if (!_loggedFirstRead) {
        _loggedFirstRead = YES;
        VPLogToFile("stream %u: first read back: result 0x%x, argument 0x%llx",
            _streamID, result, (unsigned long long)argument);
    }
    if (result != kIOReturnSuccess) {
        // Whatever the slot holds is not this period's capture.
        memset(_ring.bytes + offset, 0, _periodBytes);
        [self reportTransferError:result length:_periodBytes];
    } else if (_state == VPStreamStateRunning) {
        [self measurePeriodAtOffset:offset];
    }
    VPVirtIOSoundInputRingDidComplete(&_ring);
    _completions++;
    BOOL returned = VPVirtIOSoundInputRingInFlight(&_ring) == 0;
    switch (_state) {
    case VPStreamStateRunning:
        if (result == kIOReturnSuccess) {
            [self submitReads];
        } else {
            [self scheduleRefill];
        }
        break;
    case VPStreamStateDraining:
        if (returned) {
            [self stopDevice];
        }
        break;
    case VPStreamStateReleasing:
        if (returned) {
            _state = VPStreamStateIdle;
            if (_startWhenReleased) {
                _startWhenReleased = NO;
                [self startDevice];
            }
        }
        break;
    case VPStreamStateIdle:
        break;
    }
}

// MARK: ASDStream

- (void)startStream {
    dispatch_sync(_queue, ^{
        self->_completions = 0;
        memset(self->_peak, 0, sizeof(self->_peak));
        memset(self->_squares, 0, sizeof(self->_squares));
        self->_measuredFrames = 0;
        self->_dumpedBytes = 0;
        VPVirtIOSoundHighPassReset(&self->_highPass);
        if (!self->_dump && access(kInputDumpTrigger, F_OK) == 0) {
            self->_dump = fopen(kInputDumpPath, "w");
        }
        atomic_store(&self->_reader.servedFrames, 0);
        atomic_store(&self->_reader.silentFrames, 0);
        atomic_store(&self->_reader.skippedBytes, 0);
        self->_startedAt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        // What an earlier run left in the ring is old by now.
        atomic_store(&self->_reader.restart, true);
        atomic_store(&self->_capture.restart, true);
        switch (self->_state) {
        case VPStreamStateIdle:
            [self startDevice];
            break;
        case VPStreamStateDraining:
            // Still started on the device: capture carries on.
            self->_state = VPStreamStateRunning;
            [self submitReads];
            break;
        case VPStreamStateReleasing:
            self->_startWhenReleased = YES;
            break;
        case VPStreamStateRunning:
            break;
        }
    });
    [self installReadBlock];
    [super startStream];
}

/// The reads still out come back as the host fills them, a period apart, and
/// the device is released after the last. Releasing it first would leave the
/// kernel holding ring slots with nothing said about when it returns them;
/// that is the fallback, for a host that has stopped filling them.
- (void)stopStream {
    dispatch_sync(_queue, ^{
        self->_startWhenReleased = NO;
        if (self->_state != VPStreamStateRunning) {
            return;
        }
        [self logCounters];
        if (VPVirtIOSoundInputRingInFlight(&self->_ring) == 0) {
            [self stopDevice];
            return;
        }
        self->_state = VPStreamStateDraining;
        uint64_t stop = ++self->_stops;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)kInputDrainNanoseconds), self->_queue, ^{
            if (self->_state == VPStreamStateDraining && self->_stops == stop) {
                VPLogToFile("stream %u: %llu bytes of reads still out, releasing",
                    self->_streamID, (unsigned long long)VPVirtIOSoundInputRingInFlight(&self->_ring));
                [self stopDevice];
            }
        });
    });
    [super stopStream];
}

@end

// MARK: - Device

/// One open user client of an `AppleVirtIOSound` service. The service's
/// speaker and microphone devices share it, as the output and input streams
/// of the macOS plugin's one device do; each stream still talks to the
/// kernel from its own queue.
@interface VPVirtIOSoundConnection : NSObject
- (instancetype)initWithService:(io_service_t)service;
@property (nonatomic, readonly) io_connect_t port;
@property (nonatomic, readonly) uint32_t streamCount;
/// PCM_INFO for one virtio stream.
- (BOOL)getInfo:(VPVirtIOSoundPCMInfo *)info forStream:(uint32_t)streamID;
@end

@implementation VPVirtIOSoundConnection

- (instancetype)initWithService:(io_service_t)service {
    self = [super init];
    if (!self) {
        return nil;
    }
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &_port);
    if (result != KERN_SUCCESS) {
        os_log_error(VPLog(), "cannot open AppleVirtIOSound: 0x%x", result);
        return nil;
    }
    CFTypeRef value = IORegistryEntryCreateCFProperty(
        service, CFSTR(kVPVirtIOSoundStreamCountKey), kCFAllocatorDefault, 0);
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberSInt32Type, &_streamCount);
    }
    if (value) {
        CFRelease(value);
    }
    // What the device offers, for the record: the format choice below and
    // the split into two devices both follow from these.
    for (uint32_t streamID = 0; streamID < _streamCount; streamID++) {
        VPVirtIOSoundPCMInfo info;
        if ([self getInfo:&info forStream:streamID]) {
            VPLogToFile("stream %u: direction %u, formats 0x%llx, rates 0x%llx, channels %u-%u",
                streamID, info.direction, info.formats, info.rates,
                info.channelsMinimum, info.channelsMaximum);
        }
    }
    return self;
}

- (void)dealloc {
    if (_port) {
        IOServiceClose(_port);
    }
}

- (BOOL)getInfo:(VPVirtIOSoundPCMInfo *)info forStream:(uint32_t)streamID {
    memset(info, 0, sizeof(*info));
    uint64_t scalar = streamID;
    size_t size = sizeof(*info);
    kern_return_t result = IOConnectCallMethod(_port, kVPVirtIOSoundSelectorPCMInfo,
        &scalar, 1, NULL, 0, NULL, NULL, info, &size);
    if (result != KERN_SUCCESS || size != sizeof(*info)) {
        os_log_error(VPLog(), "stream %u: PCM_INFO failed: 0x%x", streamID, result);
        return NO;
    }
    return YES;
}

@end

@class VPVirtIOSoundDevice;

/// iOS's ASD controls refuse every change a client asks for. A set of the
/// control's value — and of the device's `vold` or `mute`, which the HAL
/// turns into one — ends in `changeDecibelValue:`, `changeScalarValue:` or
/// `changeValue:`, and the framework's own return NO (each is `mov w0, #0;
/// ret` in the guest's AudioServerDriver): the driver is expected to
/// subclass them. Until it does the HAL answers 'what', VirtualAudio logs
/// `FAIL … selector "vold"`, and the guest's volume moves nothing. These
/// take the change and tell the device, which turns it into the gain its
/// streams apply.
@interface VPVirtIOSoundLevelControl : ASDLevelControl
@property (weak, nonatomic) VPVirtIOSoundDevice *device;
@end

@interface VPVirtIOSoundMuteControl : ASDBooleanControl
@property (weak, nonatomic) VPVirtIOSoundDevice *device;
@end

@interface VPVirtIOSoundDevice : ASDAudioDevice
/// The device for one direction of a service's streams, or nil when the
/// service has no usable stream that way.
- (instancetype)initWithConnection:(VPVirtIOSoundConnection *)connection
                         direction:(ASDStreamDirection)direction
                             index:(unsigned)index
                            plugin:(ASDPlugin *)plugin;
- (void)addControls;
- (void)volumeChanged;
- (void)muteChangedTo:(BOOL)muted;
/// The speaker's part of the host's output latency changed; see
/// `updateOutputLatency:`.
- (void)hostLatencyChangedTo:(double)seconds;
@property (nonatomic, readonly) BOOL isSpeaker;
@end

@implementation VPVirtIOSoundLevelControl

- (BOOL)changeDecibelValue:(float)value {
    [self setDecibelValue:value];
    [self.device volumeChanged];
    return YES;
}

- (BOOL)changeScalarValue:(float)value {
    [self setScalarValue:value];
    [self.device volumeChanged];
    return YES;
}

@end

@implementation VPVirtIOSoundMuteControl

- (BOOL)changeValue:(BOOL)value {
    [self setValue:value];
    [self.device muteChangedTo:value];
    return YES;
}

@end

@implementation VPVirtIOSoundDevice {
    VPVirtIOSoundConnection *_connection;
    /// The scope of everything the device has: its streams and its controls.
    ASDStreamDirection _direction;
    VPVirtIOSoundClock _clock;
    /// The virtio wire rate, the only rate the device actually runs at.
    double _wireRate;
    /// The second advertised rate, or 0 when the wire rate leaves nothing to
    /// convert (44100 beside 48000).
    double _alternateRate;
    /// The nominal rate the clock last ran, so a re-set of the current rate
    /// does not re-anchor it.
    double _clockRate;
    /// The mute control `addControls` registered, for the device-level
    /// mute selector's forwarding below.
    ASDBooleanControl *_muteControl;
    ASDLevelControl *_volumeControl;
    /// The device's streams, which apply the gain the controls come to.
    NSMutableArray<VPVirtIOSoundStream *> *_streams;
    /// The mute state the device-level selector answers; shadowed beside the
    /// control because the control's own value is only reachable through its
    /// 'bcvl' property, whose getter shape the guest ASD does not publish.
    UInt32 _muteState;
    /// B520 routing selects a hardware processing mode on PuffinOutput.
    /// The virtual device has no board DSP; retain the requested native mode
    /// as a synchronous HAL property while the host receives ordinary PCM.
    _Atomic UInt32 _homePodMode;
    /// The speaker's output latency and its parts, on `_latencyQueue`: what
    /// the stream keeps queued ahead of the host (wire frames), what the
    /// Mac's output device adds (seconds), and the figure last handed to the
    /// HAL. `_latencyRate` is the nominal rate it is counted in, which a
    /// rate change moves from another thread.
    dispatch_queue_t _latencyQueue;
    UInt32 _queuedLatencyFrames;
    double _hostLatency;
    UInt32 _requestedLatency;
    _Atomic uint32_t _latencyRate;
}

- (instancetype)initWithConnection:(VPVirtIOSoundConnection *)connection
                         direction:(ASDStreamDirection)direction
                             index:(unsigned)index
                            plugin:(ASDPlugin *)plugin {
    self = [super initWithDeviceUID:VPDeviceUID(direction, index) withPlugin:plugin];
    if (!self) {
        return nil;
    }
    _connection = connection;
    _direction = direction;
    atomic_init(&_homePodMode, 'defa');
    BOOL input = direction == ASDStreamDirectionInput;

    double sampleRate = 0;
    UInt32 latencyFrames = 0;
    BOOL alternate = YES;
    for (uint32_t streamID = 0; streamID < connection.streamCount; streamID++) {
        VPVirtIOSoundPCMInfo info;
        if (![connection getInfo:&info forStream:streamID]) {
            continue;
        }
        if (info.direction != (input ? kVPVirtIOSoundDirectionInput : kVPVirtIOSoundDirectionOutput)) {
            continue;
        }
        VPVirtIOSoundStreamFormat format;
        if (!VPVirtIOSoundChooseFormat(&info, &format)) {
            os_log_error(VPLog(), "stream %u: no usable format (formats 0x%llx, rates 0x%llx)",
                streamID, info.formats, info.rates);
            continue;
        }
        // One device has one clock, so every stream must share its rate.
        if (sampleRate != 0 && format.sampleRate != sampleRate) {
            continue;
        }
        VPVirtIOSoundStream *stream;
        if (input) {
            stream = [[VPVirtIOSoundInputStream alloc] initWithConnection:connection.port
                                                                 streamID:streamID
                                                                   format:format
                                                                   plugin:plugin];
        } else {
            stream = [[VPVirtIOSoundOutputStream alloc] initWithConnection:connection.port
                                                                  streamID:streamID
                                                                    format:format
                                                                    plugin:plugin];
        }
        if (!stream) {
            continue;
        }
        stream.device = self;
        if (!input) {
            __weak VPVirtIOSoundDevice *weakSelf = self;
            stream.queuedLatencyChanged = ^(UInt32 frames) {
                [weakSelf queuedLatencyChangedTo:frames];
            };
        }
        if (!_streams) {
            _streams = [NSMutableArray array];
        }
        [_streams addObject:stream];
        sampleRate = format.sampleRate;
        latencyFrames = stream.queuedLatencyFrames;
        alternate = alternate && stream.offersAlternateRate;
        if (input) {
            [self addInputStream:stream];
        } else {
            [self addOutputStream:stream];
        }
    }
    if (sampleRate == 0) {
        return nil;
    }

    _wireRate = sampleRate;
    // The streams convert between the two rates themselves, the mix as it
    // is written and captured frames as they are read.
    _alternateRate = alternate ? kVPAlternateRate : 0;
    // The nominal rate the device answers at boot: the wire rate unless the
    // override names the alternate (testing VirtualAudio's aggregate-member
    // selection, which may compare the current nominal rate, not the list).
    double nominalRate = sampleRate;
    double override = VPNominalRateOverride();
    if (_alternateRate > 0 && override == _alternateRate) {
        nominalRate = _alternateRate;
    }
    // The period is fixed at `kTimestampPeriodSeconds` of the rate the device
    // starts at, and published below as its timestamp period.
    VPVirtIOSoundClockConfigure(&_clock, (uint32_t)(nominalRate * kTimestampPeriodSeconds), nominalRate,
        mach_absolute_time());
    _clockRate = nominalRate;
    self.deviceName = input ? @"vphone Microphone" : @"vphone Speaker";
    self.modelName = @"Virtual Sound Device";
    self.manufacturerName = @"vphone";
    self.canBeDefaultOutputDevice = !input;
    self.canBeDefaultSystemDevice = !input;
    self.canBeDefaultInputDevice = input;
    self.canChangeDeviceName = NO;
    self.samplingRates = _alternateRate ? @[@(_alternateRate), @(sampleRate)] : @[@(sampleRate)];
    self.samplingRate = nominalRate;
    // What the stream keeps between the guest's I/O and the host's, so the
    // HAL presents video against when the sound is heard, not when it is
    // written, and stamps a recording with when it was captured. In frames
    // of the rate the device starts at. The speaker's adds what the Mac's
    // output device does after its mixer, and follows both parts as they
    // change (`updateOutputLatency:`); the microphone's is set once.
    _latencyRate = (uint32_t)nominalRate;
    if (input) {
        self.inputSafetyOffset = kSafetyOffsetFrames;
        self.inputLatency = VPVirtIOSoundLatencyFrames(latencyFrames, sampleRate, nominalRate, 0);
    } else {
        _latencyQueue = dispatch_queue_create("com.vphone.audio.virtiosound.latency", DISPATCH_QUEUE_SERIAL);
        _queuedLatencyFrames = latencyFrames;
        _hostLatency = VPStoredHostLatency();
        _requestedLatency = VPVirtIOSoundLatencyFrames(latencyFrames, sampleRate, nominalRate, _hostLatency);
        self.outputSafetyOffset = kSafetyOffsetFrames;
        self.outputLatency = _requestedLatency;
        VPLogToFile("speaker latency %u frames at %.0f Hz (%.1f ms): queued %u frames + host %.1f ms",
            _requestedLatency, nominalRate, _requestedLatency * 1000.0 / nominalRate, latencyFrames,
            _hostLatency * 1000);
    }
    self.transportType = VPTransportType();
    self.timestampPeriod = _clock.periodFrames;

    [self installIOBlocks];
    UInt32 transport = self.transportType;
    os_log(VPLog(), "device %{public}@: %.0f Hz nominal (%.0f wire, %.0f advertised too), transport '%c%c%c%c'",
        VPDeviceUID(direction, index), nominalRate, sampleRate, _alternateRate,
        (char)(transport >> 24), (char)(transport >> 16), (char)(transport >> 8), (char)transport);
    VPLogToFile("device %s: %.0f Hz nominal (%.0f wire, %.0f advertised too), transport '%c%c%c%c'",
        VPDeviceUID(direction, index).UTF8String, nominalRate, sampleRate, _alternateRate,
        (char)(transport >> 24), (char)(transport >> 16), (char)(transport >> 8), (char)transport);
    return self;
}

/// ASDAudioDevice's `performStopIO` releases every I/O block the device holds
/// (and clears the unretained copies the I/O thread calls), and
/// `performStartIO` copies them again from the same properties. Blocks set
/// once at init therefore survive exactly one start: after the first stop
/// the device has no zero-timestamp block, the HAL reads "Device … is not
/// running", waits five seconds for a timeline and fails the start — every
/// start after the first. They go back in before every start.
- (void)installIOBlocks {
    VPVirtIOSoundClock *clock = &_clock;
    Boolean input = _direction == ASDStreamDirectionInput;
    self.getZeroTimestampBlock = ^int(Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed, UInt32 clientID) {
        (void)clientID;
        // False only when anchors kept landing through every read attempt;
        // no timestamp beats one built from two timelines.
        return VPVirtIOSoundClockZeroTimestamp(clock, mach_absolute_time(), sampleTime, hostTime, seed)
            ? kAudioHardwareNoError : kAudioHardwareUnspecifiedError;
    };
    self.willDoReadInputBlock = ^int(UInt32 operationID, Boolean *willDo, Boolean *willDoInPlace) {
        (void)operationID;
        *willDo = input;
        *willDoInPlace = true;
        return kAudioHardwareNoError;
    };
    self.willDoWriteMixBlock = ^int(UInt32 operationID, Boolean *willDo, Boolean *willDoInPlace) {
        (void)operationID;
        *willDo = !input;
        *willDoInPlace = true;
        return kAudioHardwareNoError;
    };
}

- (int)performStartIO {
    [self installIOBlocks];
    int result = [super performStartIO];
    if (result == kAudioHardwareNoError) {
        VPVirtIOSoundClockAnchor(&_clock, mach_absolute_time());
    }
    // Looks at the stored host latency again, in case its notification did
    // not reach audiomxd: then the next playback after a change still has it.
    if (_latencyQueue) {
        dispatch_async(_latencyQueue, ^{
            [self updateHostLatency:VPStoredHostLatency() reason:"start"];
        });
    }
    return result;
}

// MARK: Output latency

- (BOOL)isSpeaker {
    return _direction == ASDStreamDirectionOutput;
}

- (void)queuedLatencyChangedTo:(UInt32)frames {
    dispatch_async(_latencyQueue, ^{
        self->_queuedLatencyFrames = frames;
        [self updateOutputLatency:"queue"];
    });
}

- (void)hostLatencyChangedTo:(double)seconds {
    dispatch_async(_latencyQueue, ^{
        [self updateHostLatency:seconds reason:"host"];
    });
}

- (void)updateHostLatency:(double)seconds reason:(const char *)reason {
    dispatch_assert_queue(_latencyQueue);
    if (seconds == _hostLatency) {
        return;
    }
    _hostLatency = seconds;
    [self updateOutputLatency:reason];
}

/// Hands the HAL the speaker's latency when its parts add up to a new
/// figure. AudioServerPlugIn.h requires a configuration change for that,
/// and the host takes it from PerformDeviceConfigurationChange with I/O
/// stopped, then restarts I/O: the streams stop and start as at any other
/// stop, and a player hears a short break. The tracker keeps those rare.
///
/// The request runs here, not on a stream's queue: a host that performs the
/// change before the request returns stops I/O from inside it, and a
/// stream's `stopStream` waits on its own queue.
///
/// A rate change alone does not ask for one. The figure is counted in the
/// current nominal rate whenever one of its parts moves; until then a 44100
/// run (a ringtone preview or web audio, no picture to keep in step) reads
/// the 48000 count, about 9% long.
- (void)updateOutputLatency:(const char *)reason {
    dispatch_assert_queue(_latencyQueue);
    double rate = atomic_load(&_latencyRate);
    UInt32 frames = VPVirtIOSoundLatencyFrames(_queuedLatencyFrames, _wireRate, rate, _hostLatency);
    if (frames == _requestedLatency) {
        return;
    }
    VPLogToFile("speaker latency %u -> %u frames at %.0f Hz (%.1f ms): queued %u frames (%.1f ms) "
        "+ host %.1f ms; %s changed, requesting a configuration change",
        _requestedLatency, frames, rate, frames * 1000.0 / rate, _queuedLatencyFrames,
        _queuedLatencyFrames * 1000.0 / _wireRate, _hostLatency * 1000, reason);
    _requestedLatency = frames;
    [self requestConfigurationChange:^{
        self.outputLatency = frames;
        VPLogToFile("speaker latency %u frames applied", frames);
    }];
}

// MARK: Rate changes

- (BOOL)supportsSamplingRate:(double)rate {
    BOOL supported = rate == _wireRate || (_alternateRate > 0 && rate == _alternateRate);
    os_log(VPLog(), "rate-probe: supportsSamplingRate %.0f -> %{public}s",
        rate, supported ? "yes" : "no");
    VPLogToFile("rate-probe: supportsSamplingRate %.0f -> %s", rate, supported ? "yes" : "no");
    return supported;
}

/// The virtio stream keeps SET_PARAMS at the wire rate whatever the HAL
/// runs; only the clock's period math and the mix's input rate follow the
/// nominal rate, and the streams hear about it from `super` before the
/// clock moves.
- (void)setSamplingRate:(double)rate {
    os_log(VPLog(), "rate-probe: setSamplingRate %.0f (clock %.0f)", rate, _clockRate);
    VPLogToFile("rate-probe: setSamplingRate %.0f (clock %.0f)", rate, _clockRate);
    [super setSamplingRate:rate];
    if (rate > 0 && [self supportsSamplingRate:rate] && rate != _clockRate) {
        _clockRate = rate;
        atomic_store(&_latencyRate, (uint32_t)rate);
        VPVirtIOSoundClockSetRate(&_clock, rate, mach_absolute_time());
        os_log(VPLog(), "nominal rate -> %.0f Hz", rate);
    }
}

// MARK: Device-level properties

/// VirtualAudio's route code asks the device itself for
/// `kAudioDevicePropertyMute` (scope 'outp', element 0) while establishing
/// the pspk route — Device_HAL_Common's unmute, then a read-back. The iOS
/// ASDAudioDevice's property dispatch has no 'mute' case at all (the
/// disassembly of the guest's AudioServerDriver contains the FourCharCode in
/// exactly two places, both inside ASDBooleanControl's control-level code,
/// none in ASDAudioDevice's selector trees), and the HAL server answers the
/// set 'what' at HALS_UCPlugIn.cpp:1190 without ever forwarding the selector
/// here — a guest probe saw these overrides dispatch for every selector but
/// 'mute'. The route's throw that follows is quieted host-side, in the
/// VirtualAudio binary patch; this dispatch stays as macOS's ASD carries it,
/// with the mute control this device registered as the backing store, for
/// the build that does forward. The microphone device answers the same way
/// in its own scope.
static BOOL VPIsDeviceMuteAddress(const AudioObjectPropertyAddress *address, ASDStreamDirection scope) {
    return address->mSelector == kVPDevicePropertyMute
        && (address->mScope == scope
            || address->mScope == kAudioObjectPropertyScopeGlobal)
        && (address->mElement == kAudioObjectPropertyElementMain
            || address->mElement == 0);
}

/// `kAudioDevicePropertyNominalSampleRate` is a global-scope, main-element
/// property ('nsrt'/glob/0). A device-level mute address check accepts the
/// device's own scope as well; the rate has no per-scope form, so global only.
static BOOL VPIsDeviceRateAddress(const AudioObjectPropertyAddress *address) {
    return address->mSelector == kVPDevicePropertyNominalSampleRate
        && address->mScope == kAudioObjectPropertyScopeGlobal
        && (address->mElement == kAudioObjectPropertyElementMain
            || address->mElement == 0);
}

- (BOOL)isHomePodModeAddress:(const AudioObjectPropertyAddress *)address {
    return _direction == ASDStreamDirectionOutput
        && strcmp(VPMachine(), "AudioAccessory5,1") == 0
        && address->mSelector == 'mode'
        && address->mScope == kAudioObjectPropertyScopeGlobal
        && address->mElement == kAudioObjectPropertyElementMain;
}

/// The HAL host marshals unknown selectors only when 'cust' advertises
/// them. All three fields match AudioServerPlugInCustomPropertyInfo. The
/// guest ASD emits 'raww' for raw payloads and zero for no qualifier; its
/// addCustomProperty: rejects a zero payload type.
typedef struct {
    UInt32 selector;
    UInt32 propertyDataType;
    UInt32 qualifierDataType;
} VPHomePodCustomPropertyInfo;

- (BOOL)isHomePodCustomPropertiesAddress:(const AudioObjectPropertyAddress *)address {
    return _direction == ASDStreamDirectionOutput
        && strcmp(VPMachine(), "AudioAccessory5,1") == 0
        && address->mSelector == 'cust'
        && address->mScope == kAudioObjectPropertyScopeGlobal
        && address->mElement == kAudioObjectPropertyElementMain;
}

- (BOOL)hasProperty:(AudioObjectPropertyAddress *)address {
    VPLogSelectorQuery("has", address);
    if (VPIsDeviceMuteAddress(address, _direction) || [self isHomePodModeAddress:address]
        || [self isHomePodCustomPropertiesAddress:address]) {
        return YES;
    }
    return [super hasProperty:address];
}

- (BOOL)isPropertySettable:(AudioObjectPropertyAddress *)address {
    VPLogSelectorQuery("settable", address);
    if ([self isHomePodCustomPropertiesAddress:address]) {
        return NO;
    }
    if (VPIsDeviceMuteAddress(address, _direction) || VPIsDeviceRateAddress(address)
        || [self isHomePodModeAddress:address]) {
        return YES;
    }
    return [super isPropertySettable:address];
}

- (UInt32)dataSizeForProperty:(AudioObjectPropertyAddress *)address
           withQualifierSize:(UInt32)qualifierSize
           andQualifierData:(const void *)qualifierData {
    VPLogSelectorQuery("size", address);
    if ([self isHomePodCustomPropertiesAddress:address]) {
        return [super dataSizeForProperty:address withQualifierSize:qualifierSize
                        andQualifierData:qualifierData] + sizeof(VPHomePodCustomPropertyInfo);
    }
    if (VPIsDeviceMuteAddress(address, _direction) || [self isHomePodModeAddress:address]) {
        return sizeof(UInt32);
    }
    return [super dataSizeForProperty:address withQualifierSize:qualifierSize
                     andQualifierData:qualifierData];
}

- (BOOL)getProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32 *)dataSize
                 andData:(void *)data
              forClient:(UInt32)clientID {
    VPLogSelectorQuery("get", address);
    if ([self isHomePodCustomPropertiesAddress:address]) {
        UInt32 inheritedSize = [super dataSizeForProperty:address withQualifierSize:qualifierSize
                                        andQualifierData:qualifierData];
        UInt32 requiredSize = inheritedSize + sizeof(VPHomePodCustomPropertyInfo);
        if (dataSize == NULL || *dataSize < requiredSize || data == NULL) {
            return NO;
        }
        UInt32 actualSize = inheritedSize;
        if (inheritedSize != 0 && (![super getProperty:address withQualifierSize:qualifierSize
            qualifierData:qualifierData dataSize:&actualSize andData:data forClient:clientID]
            || actualSize != inheritedSize)) {
            return NO;
        }
        const VPHomePodCustomPropertyInfo mode = {'mode', 'raww', 0};
        memcpy((uint8_t *)data + inheritedSize, &mode, sizeof(mode));
        *dataSize = requiredSize;
        return YES;
    }
    if ([self isHomePodModeAddress:address]) {
        if (dataSize == NULL || *dataSize < sizeof(UInt32) || data == NULL) {
            return NO;
        }
        *(UInt32 *)data = atomic_load(&_homePodMode);
        *dataSize = sizeof(UInt32);
        return YES;
    }
    if (VPIsDeviceMuteAddress(address, _direction)) {
        if (dataSize == NULL || *dataSize < sizeof(UInt32)) {
            return NO;
        }
        *(UInt32 *)data = _muteState;
        *dataSize = sizeof(UInt32);
        return YES;
    }
    if (VPIsDeviceRateAddress(address)) {
        if (dataSize == NULL || *dataSize < sizeof(double) || data == NULL) {
            return NO;
        }
        *(double *)data = _clockRate;
        *dataSize = sizeof(double);
        return YES;
    }
    return [super getProperty:address withQualifierSize:qualifierSize
                 qualifierData:qualifierData dataSize:dataSize
                       andData:data forClient:clientID];
}

/// The rate set the route code's "Synchronously setting sample rate" runs
/// into. ASDAudioDevice's own `setProperty:` 'nsrt' case checks
/// `supportsSamplingRate:` (that call reaches the plugin — the rate-probe
/// log shows it answering) and then hands the change to a second internal
/// gate whose tail call returns NO for a plugin device; the C-op layer maps
/// that NO to 'what' at HALS_UCPlugIn.cpp:1190, the set "Gives up", and a
/// 44100 session finds no device at its rate ("No audio device is
/// available"). The commit the gate would perform lives in
/// `setSamplingRate:` — disassembled, that method logs, then dispatches a
/// block that stores the rate and fans it out to every stream — so the
/// device performs the change itself here, through its own override, and
/// answers YES.
- (BOOL)setProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32)dataSize
                 andData:(const void *)data
              forClient:(UInt32)clientID {
    VPLogSelectorQuery("set", address);
    if ([self isHomePodModeAddress:address]) {
        if (dataSize != sizeof(UInt32) || data == NULL) {
            return NO;
        }
        UInt32 mode = *(const UInt32 *)data;
        if (mode != 'defa' && mode != 'raww' && mode != 'tphn' && mode != 'meas') {
            return NO;
        }
        UInt32 previous = atomic_exchange(&_homePodMode, mode);
        if (previous != mode) {
            [self.plugin changedProperty:address forObject:self];
            VPLogToFile("HomePod speaker mode '%c%c%c%c'",
                (int)(mode >> 24), (int)((mode >> 16) & 0xff),
                (int)((mode >> 8) & 0xff), (int)(mode & 0xff));
        }
        return YES;
    }
    if (VPIsDeviceMuteAddress(address, _direction)) {
        if (dataSize < sizeof(UInt32) || data == NULL) {
            return NO;
        }
        [_muteControl setValue:*(const UInt32 *)data != 0];
        [self muteChangedTo:*(const UInt32 *)data != 0];
        return YES;
    }
    if (VPIsDeviceRateAddress(address)) {
        if (dataSize < sizeof(double) || data == NULL) {
            return NO;
        }
        double rate = *(const double *)data;
        if (rate <= 0 || ![self supportsSamplingRate:rate]) {
            return NO;
        }
        [self setSamplingRate:rate];
        return YES;
    }
    return [super setProperty:address withQualifierSize:qualifierSize
                 qualifierData:qualifierData dataSize:dataSize
                       andData:data forClient:clientID];
}

// MARK: Controls

/// The gain the streams apply: silence when muted or at the bottom of the
/// volume control's range, else the square of the control's position in it.
///
/// The guest's speaker chain is the raw one (`speaker_raw_chains`), with none
/// of the loudness the board's own chain adds at low volumes, so the control's
/// decibels taken as they are leave the middle of the slider quiet: -18 dB at
/// half. The square is the usual taper for a volume with nothing after it:
/// -12 dB at half, -24 dB at a quarter, and unity at the top.
- (void)applyGain {
    float decibels = _volumeControl.decibelValue;
    float minimum = _volumeControl.minimumDecibelValue;
    float position = minimum < 0 ? 1 - decibels / minimum : 1;
    position = fminf(fmaxf(position, 0), 1);
    float gain = _muteState ? 0 : position * position;
    for (VPVirtIOSoundStream *stream in _streams) {
        [stream setGain:gain];
    }
    VPLogToFile("device %s: %s, %.1f dB of %.0f, gain %.3f",
        _direction == ASDStreamDirectionInput ? "microphone" : "speaker",
        _muteState ? "muted" : "unmuted", decibels, minimum, gain);
}

- (void)volumeChanged {
    [self applyGain];
}

- (void)muteChangedTo:(BOOL)muted {
    _muteState = muted;
    [self applyGain];
}

- (void)addControls {
    // The control set a real speaker answers with: one selected data-source
    // value ('ispk', "Speakers"), then mute and volume, all on the master
    // element of the output scope; a microphone has the same three in the
    // input scope, its data source 'imic', "Microphone". Mirrored argument
    // for argument from the
    // macOS plugin, which adds these from its own
    // `halInitializeWithPluginHost:` — after the device is built, before it
    // is registered — and never from inside the device's init: calling
    // `addControl:` during the device's init fails the whole device
    // activation (HALS_PlugIn.cpp:162). The pspk route runs in HardwareOnly
    // volume mode and reads this control set; without it every volume query
    // on the route fails and the endpoint is retyped "Unspecified" after
    // the first playback, silencing every later one.
    BOOL input = _direction == ASDStreamDirectionInput;
    ASDSelectorValue *source = [[ASDSelectorValue alloc] init];
    [source setValue:input ? kVPDataSourceInternalMicrophone : kVPDataSourceInternalSpeaker];
    [source setName:input ? @"Microphone" : @"Speakers"];
    ASDSelectorControl *dataSource = [[ASDSelectorControl alloc]
        initWithIsSettable:YES
                forElement:0
                  inScope:_direction
                withPlugin:self.plugin
         andObjectClassID:kAudioDataSourceControlClassID];
    [dataSource addValue:source];
    [dataSource setSelectedValues:@[source]];
    [self addControl:dataSource];

    // The macOS plugin's `-[AVIODevice _addMuteAndVolumeControlsInScope:]`
    // argument-for-argument: mute off, volume at -30 dB in a [-60, 0] dB
    // range pushed to its maximum, both settable. But not through its
    // factories: on the guest ASD those are state-dependent — runs where
    // they returned real controls still failed VirtualAudio's route unmute
    // with 'what' (a factory mute control does not answer
    // kAudioDevicePropertyMute), and later runs crashed audiomxd outright
    // when the volume factory's return value was the raw FourCharCode
    // 'togl', release-faulted in this function's epilogue (audiomxd-*.ips;
    // successive-crash loops in launchd). The explicit-class initializers
    // construct controls deterministically — a guest-side reflection probe
    // confirmed both initializers return real ASD controls — so pin the
    // class IDs the way the data-source control above pins 'dsrc'.
    ASDPlugin *plugin = self.plugin;
    VPVirtIOSoundMuteControl *mute = [[VPVirtIOSoundMuteControl alloc] initWithValue:NO
        isSettable:YES forElement:0 inScope:_direction
        withPlugin:plugin andObjectClassID:kAudioMuteControlClassID];
    float minimum = input ? kMicrophoneMinimumDecibels : kSpeakerMinimumDecibels;
    VPVirtIOSoundLevelControl *volume = [[VPVirtIOSoundLevelControl alloc] initWithDecibelValue:minimum / 2
        minimumValue:minimum maximumValue:0.0 isSettable:YES
        forElement:0 inScope:_direction
        withPlugin:plugin andObjectClassID:kAudioVolumeControlClassID];
    mute.device = self;
    volume.device = self;
    [self addControl:mute];
    [self addControl:volume];
    [mute setValue:0];
    [volume setDecibelValue:volume.maximumDecibelValue];
    _muteControl = mute;
    _volumeControl = volume;
    _muteState = 0;
    os_log(VPLog(), "%{public}s controls added: dsrc, mute, volume", input ? "microphone" : "speaker");
    VPLogToFile("%s controls added: dsrc '%s', mute, volume",
        input ? "microphone" : "speaker", input ? "imic" : "ispk");
}

@end

// MARK: - Plugin

@interface VPVirtIOSoundPlugin : ASDPlugin
@end

@implementation VPVirtIOSoundPlugin

// The plugin object (not a device) answers its own selectors — the box-level
// queries the HAL server makes while enumerating plugins. Logged the same way
// so the inventory covers every object this bundle publishes.

- (BOOL)hasProperty:(AudioObjectPropertyAddress *)address {
    VPLogSelectorQuery("plugin-has", address);
    return [super hasProperty:address];
}

- (BOOL)isPropertySettable:(AudioObjectPropertyAddress *)address {
    VPLogSelectorQuery("plugin-settable", address);
    return [super isPropertySettable:address];
}

- (UInt32)dataSizeForProperty:(AudioObjectPropertyAddress *)address
           withQualifierSize:(UInt32)qualifierSize
           andQualifierData:(const void *)qualifierData {
    VPLogSelectorQuery("plugin-size", address);
    return [super dataSizeForProperty:address withQualifierSize:qualifierSize
                       andQualifierData:qualifierData];
}

- (BOOL)getProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32 *)dataSize
                 andData:(void *)data
              forClient:(UInt32)clientID {
    VPLogSelectorQuery("plugin-get", address);
    return [super getProperty:address withQualifierSize:qualifierSize
                 qualifierData:qualifierData dataSize:dataSize
                       andData:data forClient:clientID];
}

- (BOOL)setProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32)dataSize
                 andData:(const void *)data
              forClient:(UInt32)clientID {
    VPLogSelectorQuery("plugin-set", address);
    return [super setProperty:address withQualifierSize:qualifierSize
                 qualifierData:qualifierData dataSize:dataSize
                       andData:data forClient:clientID];
}

- (void)halInitializeWithPluginHost:(AudioServerPlugInHostRef)host {
    [super halInitializeWithPluginHost:host];
    // First, so this launch's ProductIDOverride, device and stream lines
    // follow it in the file rather than precede it.
    VPLogToFile("=== plugin load ===");
    VPEnsureVirtualAudioProduct();
    io_iterator_t services = IO_OBJECT_NULL;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("AppleVirtIOSound"), &services);
    if (result != KERN_SUCCESS) {
        os_log_error(VPLog(), "no AppleVirtIOSound service: 0x%x", result);
        return;
    }
    static const ASDStreamDirection directions[] = {ASDStreamDirectionOutput, ASDStreamDirectionInput};
    unsigned index = 0;
    unsigned published = 0;
    NSMutableArray<VPVirtIOSoundDevice *> *speakers = [NSMutableArray array];
    io_service_t service;
    while ((service = IOIteratorNext(services))) {
        VPVirtIOSoundConnection *connection = [[VPVirtIOSoundConnection alloc] initWithService:service];
        IOObjectRelease(service);
        if (!connection) {
            continue;
        }
        for (unsigned i = 0; i < sizeof(directions) / sizeof(directions[0]); i++) {
            VPVirtIOSoundDevice *device = [[VPVirtIOSoundDevice alloc] initWithConnection:connection
                                                                                direction:directions[i]
                                                                                    index:index
                                                                                   plugin:self];
            if (device) {
                [device addControls];
                [self addAudioDevice:device];
                published++;
                if (device.isSpeaker) {
                    [speakers addObject:device];
                }
            }
        }
        index++;
    }
    IOObjectRelease(services);
    os_log(VPLog(), "published %u virtio sound device(s)", published);
    VPLogToFile("published %u virtio sound device(s)", published);
    if (speakers.count > 0) {
        [self observeHostLatencyFor:speakers];
    }
}

/// vphoned stores what the Mac's output device adds after its mixer and
/// posts `kHostLatencyNotification`; each speaker takes the stored value
/// again. Each speaker read it at load, and reads it again at each start, so
/// a launch that misses a post still catches up. The registration's status
/// is logged: a sandbox that refused it would show here.
- (void)observeHostLatencyFor:(NSArray<VPVirtIOSoundDevice *> *)speakers {
    static int token;
    dispatch_queue_t queue = dispatch_queue_create("com.vphone.audio.virtiosound.host-latency", DISPATCH_QUEUE_SERIAL);
    uint32_t status = notify_register_dispatch(kHostLatencyNotification, &token, queue, ^(int received) {
        (void)received;
        double seconds = VPStoredHostLatency();
        VPLogToFile("host latency notification: %.1f ms stored", seconds * 1000);
        for (VPVirtIOSoundDevice *speaker in speakers) {
            [speaker hostLatencyChangedTo:seconds];
        }
    });
    VPLogToFile("host latency: listening for %s: %s (status %u)", kHostLatencyNotification,
        status == NOTIFY_STATUS_OK ? "registered" : "refused", status);
}

@end

// MARK: - Factory

__attribute__((visibility("default")))
void *VPVirtIOSoundFactory(CFAllocatorRef allocator, CFUUIDRef requestedType);

void *VPVirtIOSoundFactory(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    (void)allocator;
    if (!CFEqual(requestedType, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    static VPVirtIOSoundPlugin *plugin;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        plugin = [[VPVirtIOSoundPlugin alloc] init];
    });
    return plugin.driverRef;
}
