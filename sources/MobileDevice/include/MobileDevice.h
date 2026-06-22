//
//  MobileDevice.h
//  MobileDevice
//
//  An interface to the private API of MobileDevice.framework.
//

#ifndef MobileDevice_h
#define MobileDevice_h

#include <CoreFoundation/CoreFoundation.h>


// MARK: Structures

typedef enum {
    kAMRestorableDeviceEventDiscovered,
    kAMRestorableDeviceEventDisappeared
} AMRestorableDeviceEvent;

typedef enum {
    kAMRestorableDeviceStateUnknown,
    kAMRestorableDeviceStateDFU = 16777217,
    kAMRestorableDeviceStateDFUMac = 16777218,
    kAMRestorableDeviceStateRecovery,
    kAMRestorableDeviceStateRestoreOS,
    kAMRestorableDeviceStateBootedOS,
    kAMRestorableDeviceStateRamrodOS,
    kAMRestorableDeviceStatePortDFU
} AMRestorableDeviceState;

typedef struct __AMRestorableDevice* AMRestorableDeviceRef;
typedef struct _AMDevice *AMDeviceRef;
typedef int AMDError;
typedef int AMRestorableClientID;
typedef void (*AMRestorableDeviceEventCallback)( AMRestorableDeviceRef device, AMRestorableDeviceEvent event, void *context );
typedef void (*AMRestorableDeviceProgressUpdateCallback)( AMRestorableDeviceRef device, CFDictionaryRef info, void *context );


// MARK: Constants

#define kAMRestoreOptionsRestoreBootArgs CFSTR("RestoreBootArgs")
#define kAMRestoreOptionsPostRestoreAction CFSTR("PostRestoreAction")
#define kAMRestorePostRestoreShutdown CFSTR("Shutdown")
#define kAMRestorableRestoreOptionWaitForDeviceConnectionToFinishStateMachine CFSTR("WaitForDeviceConnectionToFinishStateMachine")
#define kAMRestoreOptionsPersistentBootArgModifications CFSTR("PersistantBootArgsModifications")
#define kAMRestoreBootArgsAdd CFSTR("Add")
#define kAMRestoreOptionsRestoreBundlePath CFSTR("RestoreBundlePath")
#define kAMRestoreOptionsAuthInstallVariant CFSTR("AuthInstallVariant")
#define kAMRestorableDeviceInfoKeyOverallProgress CFSTR("Overall Progress")
#define kAMRestorableDeviceInfoKeyStatus CFSTR("Status")
#define kAMRestorableDeviceStatusRestoring CFSTR("Restoring")
#define kAMRestorableDeviceStatusSuccessful CFSTR("Successful")
#define kAMRestorableDeviceInfoKeyError CFSTR("Error")

extern const AMRestorableClientID kAMRestorableInvalidClientID;
extern const char kAMRestorableDeviceStateVersion2;



// MARK: Functions

CFMutableDictionaryRef AMRestorableDeviceCopyDefaultRestoreOptions( void ) CF_RETURNS_RETAINED;
AMRestorableClientID AMRestorableDeviceRegisterForNotifications( AMRestorableDeviceEventCallback eventHandler,
                                                                         void *context,
                                                                         CFErrorRef *error );
bool AMRestorableDeviceUnregisterForNotifications(AMRestorableClientID clientID );
AMDError AMDeviceEnterRecovery( AMDeviceRef device );
void AMRestorableDeviceStartWatchingSerialLog( AMRestorableDeviceRef device );
void AMRestorableDeviceStopWatchingSerialLog( AMRestorableDeviceRef device );
void AMRestorableDeviceRestore( AMRestorableDeviceRef device,
                                        CFDictionaryRef options,
                                        AMRestorableDeviceProgressUpdateCallback progressHandler,
                                        void *context );
AMRestorableDeviceState AMRestorableDeviceGetStateWithVersion( AMRestorableDeviceRef aDevice, id version );
bool AMRestorableDeviceSetLogFileURL( AMRestorableDeviceRef aDevice, CFURLRef fileURL, CFStringRef logType );



static inline const void *getAMRestorableDeviceStateVersion2(void)
{
    return (const void *)&kAMRestorableDeviceStateVersion2;
}


#endif /* MobileDevice_h */
