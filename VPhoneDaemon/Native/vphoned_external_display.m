#import "Include/VphonedNative.h"
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <notify.h>
#include <unistd.h>

static NSString *const requestPath = @"/var/mobile/Library/Caches/vphone-external-display.request.plist";
static NSString *const statusPath = @"/var/mobile/Library/Caches/vphone-external-display.status.plist";

NSDictionary<NSString *, id> *vp_external_display_status(void) {
    return [NSDictionary dictionaryWithContentsOfFile:statusPath] ?: @{@"enabled": @NO, @"ok": @NO, @"error": @"External display component not connected"};
}

NSDictionary<NSString *, id> *vp_external_display_diagnostics(void) {
    NSTimeInterval start = NSDate.date.timeIntervalSince1970;
    notify_post("com.vphone.external-display.inspect");
    for (int i = 0; i < 100; i++) {
        NSDictionary *report = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Caches/vphone-external-display.springboard.plist"];
        if ([report[@"updated"] doubleValue] >= start) return report;
        usleep(50000);
    }
    return @{@"available": @NO, @"error": @"SpringBoard inspection did not respond"};
}

NSDictionary<NSString *, id> *vp_external_display_configure(BOOL enabled, NSInteger width, NSInteger height) {
    if (enabled && !((width == 1920 && height == 1080) || (width == 3840 && height == 2160)))
        return @{@"ok": @NO, @"error": @"Only 1920x1080 and 3840x2160 are supported"};
    NSString *nonce = NSUUID.UUID.UUIDString;
    NSDictionary *request = @{@"enabled": @(enabled), @"width": @(width), @"height": @(height), @"nonce": nonce};
    if (![request writeToFile:requestPath atomically:YES]) return @{@"ok": @NO, @"error": @"Cannot write display request"};
    notify_post("com.vphone.external-display.configure");
    for (int i = 0; i < 50; i++) {
        NSDictionary *status = vp_external_display_status();
        if ([status[@"nonce"] isEqual:nonce]) return status;
        usleep(100000);
    }
    return @{@"ok": @NO, @"error": @"External display component did not acknowledge request"};
}

NSData *vp_external_display_frame(NSString **error) {
    @autoreleasepool {
        NSDictionary *status = vp_external_display_status();
        NSInteger width = [status[@"width"] integerValue], height = [status[@"height"] integerValue];
        if (![status[@"enabled"] boolValue] || ![status[@"ok"] boolValue] ||
            !((width == 1920 && height == 1080) || (width == 3840 && height == 2160))) {
            if (error) *error = @"External display is disconnected";
            return nil;
        }
        void *io = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface", RTLD_NOW);
        void *ca = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW);
        void *(*create)(CFDictionaryRef) = dlsym(io, "IOSurfaceCreate");
        void *(*base)(void *) = dlsym(io, "IOSurfaceGetBaseAddress");
        size_t (*stride)(void *) = dlsym(io, "IOSurfaceGetBytesPerRow");
        kern_return_t (*lock)(void *, uint32_t, uint32_t *) = dlsym(io, "IOSurfaceLock");
        kern_return_t (*unlock)(void *, uint32_t, uint32_t *) = dlsym(io, "IOSurfaceUnlock");
        void (*render)(mach_port_t, CFStringRef, void *, int32_t, int32_t) = dlsym(ca, "CARenderServerRenderDisplay");
        if (!create || !base || !stride || !lock || !unlock || !render) {
            if (error) *error = @"Display capture API unavailable";
            return nil;
        }
        void *surface = create((__bridge CFDictionaryRef)@{@"IOSurfaceWidth": @(width), @"IOSurfaceHeight": @(height),
            @"IOSurfaceBytesPerElement": @4, @"IOSurfacePixelFormat": @((uint32_t)'BGRA')});
        if (!surface) { if (error) *error = @"Cannot allocate display surface"; return nil; }
        NSString *name = status[@"name"];
        if (![name isEqual:@"VPhone External 1080p"] && ![name isEqual:@"VPhone External 4K"]) {
            CFRelease(surface); if (error) *error = @"Unexpected external display name"; return nil;
        }
        render(0, (__bridge CFStringRef)name, surface, 0, 0);
        if (lock(surface, 1, NULL) != KERN_SUCCESS) {
            CFRelease(surface); if (error) *error = @"Cannot read display surface"; return nil;
        }
        size_t bytesPerRow = stride(surface);
        NSData *pixels = base(surface) ? [NSData dataWithBytes:base(surface) length:bytesPerRow * height] : nil;
        unlock(surface, 1, NULL);
        CFRelease(surface);
        if (!pixels) { if (error) *error = @"Display surface has no pixels"; return nil; }
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
        CGImageRef image = CGImageCreate(width, height, 8, 32, bytesPerRow, space,
            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little, provider, NULL, NO, kCGRenderingIntentDefault);
        NSMutableData *jpeg = [NSMutableData data];
        CGImageDestinationRef destination = image ? CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL) : NULL;
        BOOL success = NO;
        if (destination) {
            CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.8});
            success = CGImageDestinationFinalize(destination);
            CFRelease(destination);
        }
        if (image) CGImageRelease(image);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(space);
        if (!success) { if (error) *error = @"Cannot encode display frame"; return nil; }
        return jpeg;
    }
}
