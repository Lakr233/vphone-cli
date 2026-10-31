#pragma once
#import <Foundation/Foundation.h>

// Small ABI surface from Apple's IOHIDfamily HIDVirtualEventService.h, plus
// the C event and serialization functions IOKit exports. Everything is
// resolved at runtime, so the guest library needs no private SDK stub: the
// functions are dlsyms, the service class an NSClassFromString.
@protocol VPhoneHingeHIDService <NSObject>
@property (weak) id delegate;
@property (readonly) uint64_t serviceID;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
- (void)setCancelHandler:(dispatch_block_t)handler;
- (void)activate;
- (void)cancel;
- (BOOL)dispatchEvent:(id)event;
@end

// Apple's virtual-machine host controls ("AVP" in locationd): a service with
// primary usage page 0xFF61, usage 0x5B, whose vendor-defined events carry a
// dictionary in IOKit's XML serialization (at most 256 bytes). locationd's
// CLDeviceStateRelay subscribes to it on a VM with a foldable's motion
// capabilities and turns each dictionary into the hinge-angle and
// device-state services CoreMotion reads (CoreMotion_DeviceStateRelay_Crane
// 0xFF0C/0x21 and _DeviceState 0xFF0C/0x22), the services Apple's Duo
// simulator shows:
//     {source: hinge-slider-control, type: range, value: <degrees>}
//     {source: orientation-picker-control, type: enum,
//      value: ambiguous|portrait|landscape-left|landscape-right|faceup|facedown}
#define VP_HOST_CONTROLS_USAGE_PAGE 0xff61
#define VP_HOST_CONTROLS_USAGE 0x5b
#define VP_HOST_CONTROLS_MAX_DATA 256

//     IOHIDEventCreateVendorDefinedEvent(allocator, timeStamp, usagePage,
//                                        usage, version, data, length, options)
typedef void *(*VPhoneHingeVendorEventFactory)(void *, uint64_t, uint32_t, uint32_t, uint32_t,
                                               const uint8_t *, long, uint32_t);
//     IOCFSerialize(object, options)
typedef CFDataRef (*VPhoneHingeSerializer)(CFTypeRef, uint32_t);
