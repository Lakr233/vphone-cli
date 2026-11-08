#import "Include/VphonedNative.h"

#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurfaceRef.h>
#import <ImageIO/ImageIO.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#include <time.h>

static const size_t vpDisplayCaptureMaxBytes = 64 * 1024 * 1024;
static const double vpDisplayCaptureTimeout = 15;

static NSDictionary *vpCaptureUnavailable(NSString *reason, NSString *state) {
    return @{@"available": @NO, @"reason": reason, @"state": state};
}

static NSNumber *vpCaptureNumber(id value) {
    if (![value isKindOfClass:NSNumber.class]
        || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()
        || !isfinite([value doubleValue])) return nil;
    return value;
}

static NSString *vpCaptureUUID(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] > 36) return nil;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:value];
    NSString *canonical = uuid.UUIDString;
    return [canonical isEqualToString:@"00000000-0000-0000-0000-000000000000"] ? nil : canonical;
}

static NSDictionary *vpCaptureRect(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    NSNumber *x = vpCaptureNumber(value[@"x"]), *y = vpCaptureNumber(value[@"y"]);
    NSNumber *width = vpCaptureNumber(value[@"width"]), *height = vpCaptureNumber(value[@"height"]);
    if (!x || !y || !width || !height || x.doubleValue != 0 || y.doubleValue != 0
        || width.doubleValue <= 0 || height.doubleValue <= 0) return nil;
    return @{@"x": x, @"y": y, @"width": width, @"height": height};
}

// Join only values produced by vp_display_layout's ABI-checked getters. Display
// type is deliberately absent: its FrontBoard and CoreAnimation enums differ.
static NSDictionary *vpCaptureSource(NSDictionary *layout, NSString **reason) {
    if (![layout[@"available"] isKindOfClass:NSNumber.class] || ![layout[@"available"] boolValue]
        || ![layout[@"geometry_available"] isKindOfClass:NSNumber.class] || ![layout[@"geometry_available"] boolValue]) {
        *reason = @"FrontBoard did not provide an active layout";
        return nil;
    }
    NSArray *monitors = layout[@"monitors"], *displays = layout[@"cadisplays"];
    // Discovery stops at 16 rows. At that boundary an unseen duplicate can
    // prevent a unique binding, even when the returned rows look distinct.
    if (![monitors isKindOfClass:NSArray.class] || monitors.count != 1
        || ![displays isKindOfClass:NSArray.class] || displays.count == 0 || displays.count >= 16) {
        *reason = @"The active layout or display inventory is absent, ambiguous or at its discovery limit";
        return nil;
    }
    NSDictionary *monitor = monitors.firstObject;
    if (![monitor isKindOfClass:NSDictionary.class] || ![monitor[@"monitor_source"] isEqual:@"default_main"]
        || ![monitor[@"available"] boolValue] || ![monitor[@"geometry_available"] boolValue]) {
        *reason = @"The default-main display monitor is unavailable";
        return nil;
    }
    NSNumber *displayID = vpCaptureNumber(monitor[@"display_id"]);
    NSNumber *scale = vpCaptureNumber(monitor[@"point_scale"]);
    NSNumber *orientation = vpCaptureNumber(monitor[@"interface_orientation"]);
    NSString *uuid = vpCaptureUUID(monitor[@"hardware_identifier"]);
    NSDictionary *points = vpCaptureRect(monitor[@"bounds"]);
    NSDictionary *reference = vpCaptureRect(monitor[@"reference_bounds"]);
    if (!displayID || displayID.doubleValue < 1 || displayID.doubleValue > UINT32_MAX
        || floor(displayID.doubleValue) != displayID.doubleValue || !scale || scale.doubleValue <= 0
        || !orientation || orientation.doubleValue < 1 || orientation.doubleValue > 4
        || floor(orientation.doubleValue) != orientation.doubleValue
        || (monitor[@"hardware_identifier"] && !uuid) || !points || !reference) {
        *reason = @"The active display has an invalid hardware UUID, numeric identity or geometry";
        return nil;
    }
    NSDictionary *selected = nil;
    NSUInteger matchingIDs = 0, matchingUUIDs = 0;
    for (id object in displays) {
        if (![object isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *display = object;
        NSNumber *candidateID = vpCaptureNumber(display[@"displayId"]);
        NSString *candidateUUID = vpCaptureUUID(display[@"uniqueId"]);
        BOOL sameID = candidateID && candidateID.doubleValue == displayID.doubleValue;
        BOOL sameUUID = [candidateUUID isEqualToString:uuid];
        matchingIDs += sameID;
        matchingUUIDs += sameUUID;
        if (sameID) selected = display;
    }
    NSString *name = selected[@"name"];
    NSString *frontboardName = monitor[@"display_name"];
    NSNumber *nativeScale = vpCaptureNumber(selected[@"pointScale"]);
    NSDictionary *pixels = vpCaptureRect(selected[@"bounds"]);
    NSUInteger matchingNames = 0;
    if ([name isKindOfClass:NSString.class] && name.length > 0 && name.length <= 128) {
        for (id display in displays) {
            if ([display isKindOfClass:NSDictionary.class] && [display[@"name"] isEqual:name]) matchingNames++;
        }
    }
    BOOL uuidMatches = uuid ? matchingUUIDs == 1 && [vpCaptureUUID(selected[@"uniqueId"]) isEqualToString:uuid]
                            : selected[@"uniqueId"] == nil;
    if (!selected || matchingIDs != 1 || !uuidMatches || matchingNames != 1
        || !nativeScale || nativeScale.doubleValue != scale.doubleValue || !pixels) {
        *reason = @"FrontBoard identity does not uniquely match a named CoreAnimation display at the same scale";
        return nil;
    }
    double width = [pixels[@"width"] doubleValue], height = [pixels[@"height"] doubleValue];
    if (width > 16384 || height > 16384
        || floor(width) != width || floor(height) != height || width * height > vpDisplayCaptureMaxBytes / 4) {
        *reason = @"Native display bounds exceed the capture allocation limit";
        return nil;
    }
    // Some default-main cover displays expose no UUID on either side. Bind
    // those only when the render name and scaled reference raster also agree.
    if (!uuid && (![frontboardName isKindOfClass:NSString.class] || ![frontboardName isEqualToString:name]
                  || width != [reference[@"width"] doubleValue] * scale.doubleValue
                  || height != [reference[@"height"] doubleValue] * scale.doubleValue)) {
        *reason = @"UUID-less display identity requires matching render names and scaled reference bounds";
        return nil;
    }
    NSMutableDictionary *source = [NSMutableDictionary dictionaryWithDictionary:@{
        @"display_id": displayID, @"name": name, @"point_scale": scale,
        @"bounds_pixels": pixels, @"frontboard_bounds_points": points,
        @"frontboard_reference_bounds_points": reference, @"frontboard_interface_orientation": orientation,
    }];
    if (uuid) source[@"hardware_identifier"] = uuid;
    if ([frontboardName isKindOfClass:NSString.class] && frontboardName.length <= 128) {
        source[@"frontboard_display_name"] = frontboardName;
    }
    for (NSString *key in @[@"currentOrientation", @"nativeOrientation"]) {
        NSNumber *value = vpCaptureNumber(selected[key]);
        if (value) source[key] = value;
        else if ([selected[key] isKindOfClass:NSString.class] && [selected[key] length] <= 32) source[key] = selected[key];
    }
    return source;
}

static NSDictionary *vpCaptureRender(NSDictionary *source, BOOL (^cancelled)(void)) {
    // This is the same private C ABI and arguments already used by
    // FoldDisplayPanel.m. A void return provides no renderer error status.
    static void (*render)(mach_port_t, CFStringRef, void *, int32_t, int32_t);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *quartz = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_LOCAL);
        render = quartz ? dlsym(quartz, "CARenderServerRenderDisplay") : NULL;
    });
    if (!render) return vpCaptureUnavailable(@"The render-server capture entry point is unavailable", @"unsupported");
    size_t width = [source[@"bounds_pixels"][@"width"] unsignedLongLongValue];
    size_t height = [source[@"bounds_pixels"][@"height"] unsignedLongLongValue];
    size_t rowBytes = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4);
    if (rowBytes < width * 4 || rowBytes > vpDisplayCaptureMaxBytes / height) {
        return vpCaptureUnavailable(@"Aligned native rows exceed the capture allocation limit", @"invalid_bounds");
    }
    size_t allocation = IOSurfaceAlignProperty(kIOSurfaceAllocSize, rowBytes * height);
    if (allocation < rowBytes * height || allocation > vpDisplayCaptureMaxBytes) {
        return vpCaptureUnavailable(@"Aligned native surface exceeds the capture allocation limit", @"invalid_bounds");
    }
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (__bridge NSString *)kIOSurfaceWidth: @(width), (__bridge NSString *)kIOSurfaceHeight: @(height),
        (__bridge NSString *)kIOSurfaceBytesPerElement: @4, (__bridge NSString *)kIOSurfaceBytesPerRow: @(rowBytes),
        (__bridge NSString *)kIOSurfacePixelFormat: @(0x42475241), (__bridge NSString *)kIOSurfaceAllocSize: @(allocation),
    });
    if (!surface) return vpCaptureUnavailable(@"The native capture surface could not be allocated", @"allocation_failed");
    CGColorSpaceRef colorSpace = NULL;
    CGDataProviderRef provider = NULL;
    CGImageRef image = NULL;
    CGImageDestinationRef destination = NULL;
    BOOL locked = NO;
    IOSurfaceLockOptions lockOptions = 0;
    @try {
        size_t actualWidth = IOSurfaceGetWidth(surface), actualHeight = IOSurfaceGetHeight(surface);
        size_t stride = IOSurfaceGetBytesPerRow(surface), bytes = IOSurfaceGetAllocSize(surface);
        if (actualWidth != width || actualHeight != height || stride < width * 4
            || IOSurfaceGetPixelFormat(surface) != 0x42475241 || IOSurfaceGetBytesPerElement(surface) != 4
            || IOSurfaceGetPlaneCount(surface) != 0
            || bytes > vpDisplayCaptureMaxBytes || stride > bytes / height) {
            return vpCaptureUnavailable(@"The allocated surface does not match its bounded native geometry", @"invalid_surface");
        }
        if (IOSurfaceLock(surface, 0, NULL) != KERN_SUCCESS) {
            return vpCaptureUnavailable(@"The native surface could not be initialized", @"surface_lock_failed");
        }
        locked = YES;
        void *base = IOSurfaceGetBaseAddress(surface);
        if (!base) return vpCaptureUnavailable(@"The native surface has no readable storage", @"invalid_surface");
        // Zero storage, including padding, before a void-returning private call.
        // No uninitialized bytes may become an exported image.
        memset(base, 0, bytes);
        if (IOSurfaceUnlock(surface, 0, NULL) != KERN_SUCCESS) {
            return vpCaptureUnavailable(@"The initialized surface could not be unlocked", @"surface_unlock_failed");
        }
        locked = NO;
        if (cancelled()) return vpCaptureUnavailable(@"Capture was cancelled before rendering", @"cancelled");
        render(0, (__bridge CFStringRef)source[@"name"], surface, 0, 0);
        if (cancelled()) return vpCaptureUnavailable(@"Capture exceeded its deadline during rendering", @"cancelled");
        if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL) != KERN_SUCCESS) {
            return vpCaptureUnavailable(@"The rendered native surface could not be read", @"surface_lock_failed");
        }
        locked = YES;
        lockOptions = kIOSurfaceLockReadOnly;
        base = IOSurfaceGetBaseAddress(surface);
        if (!base) return vpCaptureUnavailable(@"The rendered surface has no readable storage", @"invalid_surface");
        BOOL changed = NO;
        for (size_t y = 0; y < height && !changed; y++) {
            const unsigned char *row = (const unsigned char *)base + y * stride;
            for (size_t x = 0; x < width * 4; x++) {
                if (row[x]) { changed = YES; break; }
            }
        }
        if (!changed) {
            return vpCaptureUnavailable(@"The render server left the zero-initialized surface unchanged; content is unverified", @"empty_surface");
        }
        colorSpace = CGColorSpaceCreateDeviceRGB();
        provider = CGDataProviderCreateWithData(NULL, base, stride * height, NULL);
        if (colorSpace && provider) {
            image = CGImageCreate(width, height, 8, 32, stride, colorSpace,
                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, provider, NULL, false, kCGRenderingIntentDefault);
        }
        NSMutableData *png = [NSMutableData data];
        if (image) destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
        if (!destination) return vpCaptureUnavailable(@"The native raster could not be encoded", @"encoding_failed");
        CGImageDestinationAddImage(destination, image, NULL);
        if (!CGImageDestinationFinalize(destination) || png.length == 0 || png.length > vpDisplayCaptureMaxBytes) {
            return vpCaptureUnavailable(@"PNG encoding failed or exceeded the capture output limit", @"encoding_failed");
        }
        if (cancelled()) return vpCaptureUnavailable(@"Capture exceeded its deadline during encoding", @"cancelled");
        NSString *encoded = [png base64EncodedStringWithOptions:0];
        return @{
            @"available": @YES, @"format": @"png", @"base64": encoded,
            @"width": @(width), @"height": @((NSUInteger)height),
            @"row_bytes": @((NSUInteger)stride), @"surface_bytes": @((NSUInteger)bytes),
            @"pixel_format": @"BGRA8", @"png_bitmap": @"premultiplied_first_32_little", @"color_space": @"DeviceRGB",
            @"rotation_applied": @0, @"resized": @NO, @"orientation_mapping_verified": @NO,
            @"color_profile_verified": @NO, @"capture_content_verified": @NO,
            @"renderer": @"CARenderServerRenderDisplay", @"renderer_status": @"private_void_return_no_error_status",
        };
    } @finally {
        if (destination) CFRelease(destination);
        if (image) CGImageRelease(image);
        if (provider) CGDataProviderRelease(provider);
        if (colorSpace) CGColorSpaceRelease(colorSpace);
        if (locked) IOSurfaceUnlock(surface, lockOptions, NULL);
        CFRelease(surface);
    }
}

static NSDictionary *vpCapturePerform(BOOL (^cancelled)(void)) {
    NSString *reason = nil;
    NSDictionary *before = vpCaptureSource(vp_display_layout(), &reason);
    if (!before) return vpCaptureUnavailable(reason, @"source_unavailable");
    if (cancelled()) return vpCaptureUnavailable(@"Capture was cancelled before rendering", @"cancelled");
    NSDictionary *raster = vpCaptureRender(before, cancelled);
    if (![raster[@"available"] boolValue]) return raster;
    NSDictionary *after = vpCaptureSource(vp_display_layout(), &reason);
    if (!after || ![before isEqualToDictionary:after]) {
        return vpCaptureUnavailable(@"Active display identity or geometry changed during capture", @"source_changed");
    }
    if (cancelled()) return vpCaptureUnavailable(@"Capture exceeded its response deadline", @"cancelled");
    NSMutableDictionary *result = [raster mutableCopy];
    result[@"source"] = before;
    result[@"source_after"] = after;
    result[@"identity_binding"] = before[@"hardware_identifier"]
        ? @"matching_nonzero_hardware_uuid_display_id_and_scale_with_unique_render_name"
        : @"matching_display_id_render_name_scale_and_reference_bounds_without_hardware_uuid";
    result[@"attribution_limit"] = @"Matching metadata before and after is not an atomic display epoch or proof of rendered content";
    return result;
}

NSDictionary<NSString *, id> *vp_display_capture_active(void) {
    dispatch_time_t responseDeadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(vpDisplayCaptureTimeout * NSEC_PER_SEC));
    if (NSThread.isMainThread) {
        return vpCaptureUnavailable(@"Native capture requires a background caller", @"main_thread_caller");
    }
    static dispatch_semaphore_t slot;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        slot = dispatch_semaphore_create(1);
        queue = dispatch_queue_create("vphoned.display.capture", DISPATCH_QUEUE_SERIAL);
    });
    if (dispatch_semaphore_wait(slot, DISPATCH_TIME_NOW) != 0) {
        return vpCaptureUnavailable(@"A native capture is still queued or running", @"busy");
    }
    NSLock *lock = [NSLock new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL cancelled = NO, finished = NO;
    __block NSDictionary *result = nil;
    struct timespec start = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &start) != 0) {
        dispatch_semaphore_signal(slot);
        return vpCaptureUnavailable(@"The capture deadline clock is unavailable", @"clock_unavailable");
    }
    double deadline = start.tv_sec + start.tv_nsec / 1e9 + vpDisplayCaptureTimeout;
    BOOL (^isCancelled)(void) = ^BOOL {
        struct timespec now = {0};
        BOOL clockAvailable = clock_gettime(CLOCK_MONOTONIC, &now) == 0;
        [lock lock];
        BOOL value = cancelled || !clockAvailable || now.tv_sec + now.tv_nsec / 1e9 >= deadline;
        [lock unlock];
        return value;
    };
    dispatch_async(queue, ^{
        @try {
            @autoreleasepool {
                NSDictionary *report;
                @try {
                    report = isCancelled() ? vpCaptureUnavailable(@"Queued capture was cancelled before starting", @"cancelled")
                                           : vpCapturePerform(isCancelled);
                } @catch (NSException *exception) {
                    report = vpCaptureUnavailable(exception.reason ?: exception.name, @"exception");
                }
                [lock lock];
                result = report;
                finished = YES;
                [lock unlock];
                dispatch_semaphore_signal(done);
            }
        } @finally {
            // The task, not a timed-out caller, owns the gate and every CF
            // resource until the private render call actually returns.
            dispatch_semaphore_signal(slot);
        }
    });
    if (dispatch_semaphore_wait(done, responseDeadline) != 0) {
        [lock lock];
        cancelled = YES;
        NSDictionary *completed = finished ? result : nil;
        [lock unlock];
        return completed ?: vpCaptureUnavailable(@"Native capture exceeded its response deadline; an admitted private call may still be running", @"timed_out");
    }
    [lock lock];
    NSDictionary *completed = result;
    [lock unlock];
    return completed;
}
