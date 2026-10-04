// VPVirtIOSoundAudioServerDriver.h — the part of AudioServerDriver we use.
//
// AudioServerDriver.framework is the private Objective-C layer Apple's HAL
// plugins are written in; BuiltinAudioPlugin uses it on iOS and
// AppleVirtIOSound.driver on macOS. It ships no headers, so these are the
// classes and selectors the macOS AppleVirtIOSound plugin calls, declared
// with the signatures its class-dump shows. AudioServerDriver.tbd beside
// this file lets the linker bind them two-level.

#ifndef VPVirtIOSoundAudioServerDriver_h
#define VPVirtIOSoundAudioServerDriver_h

#import <Foundation/Foundation.h>

// The iPhoneOS SDK ships <CoreAudio/AudioServerPlugIn.h> and
// <CoreAudio/AudioHardwareBase.h> from 27.0 on. Built with an older one (26.5
// has neither), the HAL names this plugin uses are declared here with the
// values and layouts those headers give them.
#if __has_include(<CoreAudio/AudioServerPlugIn.h>)
#import <CoreAudio/AudioServerPlugIn.h>
#else
#import <CoreAudioTypes/CoreAudioTypes.h>

#if __has_include(<CoreAudio/AudioHardwareBase.h>)
#import <CoreAudio/AudioHardwareBase.h>
#else
typedef UInt32 AudioObjectPropertySelector;
typedef UInt32 AudioObjectPropertyScope;
typedef UInt32 AudioObjectPropertyElement;

typedef struct AudioObjectPropertyAddress {
    AudioObjectPropertySelector mSelector;
    AudioObjectPropertyScope mScope;
    AudioObjectPropertyElement mElement;
} AudioObjectPropertyAddress;

enum {
    kAudioHardwareNoError = 0,
    kAudioHardwareUnspecifiedError = 'what',
    kAudioObjectPropertyScopeGlobal = 'glob',
    kAudioObjectPropertyScopeInput = 'inpt',
    kAudioObjectPropertyScopeOutput = 'outp',
    kAudioObjectPropertyElementMain = 0,
    kAudioDeviceTransportTypeUSB = 'usb ',
    kAudioVolumeControlClassID = 'vlme',
    kAudioMuteControlClassID = 'mute',
    kAudioDataSourceControlClassID = 'dsrc',
    kAudioStreamPropertyVirtualFormat = 'sfmt',
    kAudioStreamPropertyPhysicalFormat = 'pft ',
};
#endif

typedef struct AudioServerPlugInHostInterface AudioServerPlugInHostInterface;
typedef const AudioServerPlugInHostInterface *AudioServerPlugInHostRef;
typedef struct AudioServerPlugInDriverInterface AudioServerPlugInDriverInterface;
typedef AudioServerPlugInDriverInterface **AudioServerPlugInDriverRef;

typedef struct AudioServerPlugInIOCycleInfo {
    UInt64 mIOCycleCounter;
    UInt32 mNominalIOBufferFrameSize;
    AudioTimeStamp mCurrentTime;
    AudioTimeStamp mInputTime;
    AudioTimeStamp mOutputTime;
    Float64 mMainHostTicksPerFrame;
    Float64 mDeviceHostTicksPerFrame;
} AudioServerPlugInIOCycleInfo;

/// 443ABAB8-E7B3-491A-B985-BEB9187030DB
#define kAudioServerPlugInTypeUUID \
    CFUUIDGetConstantUUIDWithBytes(NULL, 0x44, 0x3A, 0xBA, 0xB8, 0xE7, 0xB3, 0x49, 0x1A, 0xB9, 0x85, 0xBE, 0xB9, 0x18, \
        0x70, 0x30, 0xDB)
#endif

/// `ASDStreamDirection`: the HAL scope four-character codes.
typedef UInt32 ASDStreamDirection;
static const ASDStreamDirection ASDStreamDirectionOutput = kAudioObjectPropertyScopeOutput;
static const ASDStreamDirection ASDStreamDirectionInput = kAudioObjectPropertyScopeInput;

@class ASDPlugin;

@interface ASDObject : NSObject
@property (weak, nonatomic) ASDObject *owner;
@property (weak, nonatomic) ASDPlugin *plugin;
/// The object's registered CoreAudio class FourCharCode (what
/// `kAudioObjectPropertyClass` answers). Server-side ASD getter.
- (UInt32)objectClass;
/// Whether the object's class chain carries a CoreAudio class — the predicate
/// ASDAudioDevice's property dispatch consults when routing device-level
/// selectors like `kAudioDevicePropertyMute` to controls.
- (BOOL)isKindOfAudioClass:(UInt32)classID;
/// The property plumbing the plugin driver's C ops call into. The iOS
/// ASDAudioDevice implements these for its selector set — which, disassembled,
/// contains no `kAudioDevicePropertyMute`, so a plugin device answers that
/// selector by overriding them. Signatures follow the arm64e argument layout
/// of ASDAudioDevice's own implementations; both accessors return a handled
/// flag (YES = the C-op layer reports success, NO = it answers 'what').
- (BOOL)hasProperty:(AudioObjectPropertyAddress *)address;
- (BOOL)isPropertySettable:(AudioObjectPropertyAddress *)address;
- (UInt32)dataSizeForProperty:(AudioObjectPropertyAddress *)address
           withQualifierSize:(UInt32)qualifierSize
           andQualifierData:(const void *)qualifierData;
- (BOOL)getProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32 *)dataSize
                 andData:(void *)data
              forClient:(UInt32)clientID;
- (BOOL)setProperty:(AudioObjectPropertyAddress *)address
      withQualifierSize:(UInt32)qualifierSize
          qualifierData:(const void *)qualifierData
               dataSize:(UInt32)dataSize
                 andData:(const void *)data
              forClient:(UInt32)clientID;
@end

@interface ASDPlugin : ASDObject
@property (readonly, nonatomic) AudioServerPlugInDriverRef driverRef;
@property (readonly, nonatomic) NSString *bundleID;
- (void)halInitializeWithPluginHost:(AudioServerPlugInHostRef)host;
- (void)addAudioDevice:(id)device;
- (NSArray *)audioDevices;
@end

/// Signatures from the macOS plugin's block type encodings.
typedef int (^ASDGetZeroTimestampBlock)(Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed, UInt32 clientID);
typedef int (^ASDWillDoBlock)(UInt32 operationID, Boolean *willDo, Boolean *willDoInPlace);
typedef int (^ASDIOBlock)(
    UInt32 frameCount,
    const AudioServerPlugInIOCycleInfo *cycleInfo,
    void *mainBuffer,
    void *secondaryBuffer,
    UInt32 clientID);

@interface ASDAudioDevice : ASDObject
- (instancetype)initWithDeviceUID:(NSString *)uid withPlugin:(ASDPlugin *)plugin;
@property (copy, nonatomic) NSString *deviceName;
@property (copy, nonatomic) NSString *modelName;
@property (copy, nonatomic) NSString *manufacturerName;
@property (nonatomic) BOOL canBeDefaultInputDevice;
@property (nonatomic) BOOL canBeDefaultOutputDevice;
@property (nonatomic) BOOL canBeDefaultSystemDevice;
@property (nonatomic) BOOL canChangeDeviceName;
@property (nonatomic) double samplingRate;
@property (copy, nonatomic) NSArray<NSNumber *> *samplingRates;
@property (nonatomic) UInt32 timestampPeriod;
@property (nonatomic) UInt32 inputSafetyOffset;
@property (nonatomic) UInt32 outputSafetyOffset;
@property (nonatomic) UInt32 inputLatency;
@property (nonatomic) UInt32 outputLatency;
@property (nonatomic) UInt32 transportType;
@property (readonly, nonatomic) BOOL hasOutput;
/// The rates the device answers `kAudioDevicePropertyAvailableSampleRates`
/// with; the framework validates a nominal-rate change against
/// `supportsSamplingRate:` before switching.
- (BOOL)supportsSamplingRate:(double)rate;
@property (copy, nonatomic) ASDGetZeroTimestampBlock getZeroTimestampBlock;
@property (copy, nonatomic) ASDWillDoBlock willDoReadInputBlock;
@property (copy, nonatomic) ASDWillDoBlock willDoWriteMixBlock;
- (void)addInputStream:(id)stream;
- (void)addOutputStream:(id)stream;
- (NSArray *)outputStreams;
- (int)performStartIO;
- (int)performStopIO;
@end

/// A hardware volume control, as the macOS `AppleVirtIOSound.driver` creates
/// one for its device. Signatures follow the selectors its binary references;
/// the factory returns an autoreleased control bound to the plugin.
@interface ASDLevelControl : ASDObject
+ (instancetype)volumeControlWithDecibelValue:(float)decibelValue
                                  minimumValue:(float)minimumValue
                                  maximumValue:(float)maximumValue
                                    isSettable:(BOOL)settable
                                   forElement:(UInt32)element
                                      inScope:(UInt32)scope
                                   withPlugin:(ASDPlugin *)plugin;
/// Mirrors the boolean control's explicit-class initializer: pins the
/// control class ID instead of trusting the factory to pick one.
- (instancetype)initWithDecibelValue:(float)decibelValue
                        minimumValue:(float)minimumValue
                        maximumValue:(float)maximumValue
                          isSettable:(BOOL)settable
                         forElement:(UInt32)element
                            inScope:(UInt32)scope
                         withPlugin:(ASDPlugin *)plugin
                   andObjectClassID:(UInt32)classID;
@property (nonatomic, readonly) float scalarValue;
@property (nonatomic, readonly) float decibelValue;
@property (nonatomic, readonly) float minimumDecibelValue;
@property (nonatomic, readonly) float maximumDecibelValue;
- (void)setDecibelValue:(float)value;
- (void)setScalarValue:(float)value;
/// What a client's set of the control's value ends in. The framework's own
/// refuse (return NO); a driver that takes the change overrides them.
- (BOOL)changeDecibelValue:(float)value;
- (BOOL)changeScalarValue:(float)value;
@end

/// The matching mute control.
@interface ASDBooleanControl : ASDObject
+ (instancetype)muteControlWithValue:(BOOL)value
                          isSettable:(BOOL)settable
                          forElement:(UInt32)element
                             inScope:(UInt32)scope
                          withPlugin:(ASDPlugin *)plugin;
/// The guest ASD also answers this explicit-class initializer. Its
/// `muteControlWithValue:...` factory yields a control that does not answer
/// `kAudioDevicePropertyMute` (VirtualAudio's route unmute fails 'what'),
/// so the mute control pins `kAudioMuteControlClassID` through this one the
/// way the data-source control pins `kAudioDataSourceControlClassID`.
- (instancetype)initWithValue:(BOOL)value
                   isSettable:(BOOL)settable
                  forElement:(UInt32)element
                     inScope:(UInt32)scope
                  withPlugin:(ASDPlugin *)plugin
            andObjectClassID:(UInt32)classID;
@property (nonatomic, readonly, getter=booleanValue) BOOL booleanValue;
- (void)setValue:(UInt32)value;
/// As `changeDecibelValue:` above, for a set of the control's value.
- (BOOL)changeValue:(BOOL)value;
@end

/// One selectable value of an `ASDSelectorControl`, as the macOS
/// `AppleVirtIOSound.driver` configures its speaker data source.
@interface ASDSelectorValue : ASDObject
- (void)setValue:(UInt32)value;
- (void)setName:(NSString *)name;
@end

/// A data-source selector control; the class ID is a CoreAudio control class
/// (`kAudioDataSourceControlClassID`).
@interface ASDSelectorControl : ASDObject
- (instancetype)initWithIsSettable:(BOOL)settable
                       forElement:(UInt32)element
                          inScope:(UInt32)scope
                      withPlugin:(ASDPlugin *)plugin
                 andObjectClassID:(UInt32)classID;
- (void)addValue:(ASDSelectorValue *)value;
- (void)setSelectedValues:(NSArray<ASDSelectorValue *> *)values;
@end

@interface ASDAudioDevice (Controls)
- (void)addControl:(ASDObject *)control;
@end

@interface ASDStreamFormat : NSObject <NSCopying>
- (instancetype)initWithAudioStreamBasicDescription:(AudioStreamBasicDescription)description;
@property (nonatomic) double sampleRate;
@property (nonatomic) double minimumSampleRate;
@property (nonatomic) double maximumSampleRate;
@end

@interface ASDStream : ASDObject
- (instancetype)initWithDirection:(ASDStreamDirection)direction withPlugin:(ASDPlugin *)plugin;
@property (copy, nonatomic) NSString *streamName;
@property (copy, nonatomic) ASDStreamFormat *physicalFormat;
@property (copy, nonatomic) NSArray<ASDStreamFormat *> *physicalFormats;
@property (nonatomic) BOOL physicalFormatSettable;
@property (copy, nonatomic) ASDIOBlock readInputBlock;
@property (copy, nonatomic) ASDIOBlock writeMixBlock;
/// Sent to every stream when the device's nominal sample rate changed; the
/// default implementation reconciles the physical format with the new rate.
- (void)deviceChangedToSamplingRate:(double)rate;
- (void)startStream;
- (void)stopStream;
@end

#endif /* VPVirtIOSoundAudioServerDriver_h */
