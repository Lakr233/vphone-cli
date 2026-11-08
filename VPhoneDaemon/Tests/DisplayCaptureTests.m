#import <Foundation/Foundation.h>
#include <dlfcn.h>
static void *captureSymbol(void *handle, const char *name);
#define dlsym captureSymbol
#import "../Native/vphoned_display_capture.m"
#undef dlsym
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static dispatch_semaphore_t layoutEntered, layoutRelease;
static atomic_bool blockLayout;
static NSArray<NSDictionary *> *captureLayouts;
static NSUInteger captureLayoutIndex;

static void renderFixture(mach_port_t port, CFStringRef name, void *value, int32_t x, int32_t y) {
    (void)port; (void)name; (void)x; (void)y;
    IOSurfaceRef surface = value;
    if (IOSurfaceLock(surface, 0, NULL) != KERN_SUCCESS) abort();
    unsigned char *pixels = IOSurfaceGetBaseAddress(surface);
    if (!pixels) abort();
    pixels[0] = 255;
    pixels[3] = 255;
    if (IOSurfaceUnlock(surface, 0, NULL) != KERN_SUCCESS) abort();
}

static void *captureSymbol(void *handle, const char *name) {
    return strcmp(name, "CARenderServerRenderDisplay") == 0 ? (void *)renderFixture : dlsym(handle, name);
}

NSDictionary<NSString *, id> *vp_display_layout(void) {
    if (captureLayouts) {
        NSUInteger index = MIN(captureLayoutIndex, captureLayouts.count - 1);
        captureLayoutIndex++;
        return captureLayouts[index];
    }
    dispatch_semaphore_signal(layoutEntered);
    if (atomic_load(&blockLayout)
        && dispatch_semaphore_wait(layoutRelease, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC)) != 0) {
        fputs("stalled layout fixture exceeded its deadline\n", stderr);
        exit(EXIT_FAILURE);
    }
    return @{@"available": @NO, @"geometry_available": @NO};
}

static void require(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message);
        exit(EXIT_FAILURE);
    }
}

static NSDictionary *rect(double width, double height) {
    return @{@"x": @0, @"y": @0, @"width": @(width), @"height": @(height)};
}

static NSMutableDictionary *layout(void) {
    NSString *uuid = @"11111111-2222-4333-8444-555555555555";
    NSMutableDictionary *monitor = [@{
        @"available": @YES, @"geometry_available": @YES, @"monitor_source": @"default_main",
        @"display_id": @7, @"hardware_identifier": uuid, @"point_scale": @3,
        @"interface_orientation": @4, @"bounds": rect(951, 669), @"reference_bounds": rect(669, 951),
    } mutableCopy];
    NSMutableDictionary *display = [@{
        @"displayId": @7, @"uniqueId": uuid, @"pointScale": @3, @"name": @"Inner",
        @"bounds": rect(2007, 2853), @"currentOrientation": @"rot90", @"nativeOrientation": @"rot0",
    } mutableCopy];
    return [@{@"available": @YES, @"geometry_available": @YES,
              @"monitors": @[monitor], @"cadisplays": [NSMutableArray arrayWithObject:display]} mutableCopy];
}

static NSMutableDictionary *coverLayout(void) {
    NSMutableDictionary *item = layout();
    NSMutableDictionary *monitor = item[@"monitors"][0], *display = item[@"cadisplays"][0];
    [monitor removeObjectForKey:@"hardware_identifier"];
    monitor[@"display_id"] = @1;
    monitor[@"display_name"] = @"LCD";
    monitor[@"interface_orientation"] = @1;
    monitor[@"bounds"] = rect(466, 678);
    monitor[@"reference_bounds"] = rect(466, 678);
    [display removeObjectForKey:@"uniqueId"];
    display[@"displayId"] = @1;
    display[@"name"] = @"LCD";
    display[@"bounds"] = rect(1398, 2034);
    return item;
}

static void sourceChecks(void) {
    NSString *reason = nil;
    NSMutableDictionary *valid = layout();
    NSDictionary *source = vpCaptureSource(valid, &reason);
    require(source != nil && [source[@"display_id"] isEqual:@7], "unique native identity must bind");
    require([source[@"bounds_pixels"] isEqual:rect(2007, 2853)], "capture must retain native bounds");

    source = vpCaptureSource(coverLayout(), &reason);
    require(source != nil, "a cover with UUIDs absent on both sides must bind its unique numeric identity");
    require(source[@"hardware_identifier"] == nil, "UUID-less binding must not manufacture a hardware UUID");
    require([source[@"bounds_pixels"] isEqual:rect(1398, 2034)], "cover capture must retain native bounds");

    for (NSString *field in @[@"displayId", @"name"]) {
        NSMutableDictionary *item = coverLayout();
        NSMutableDictionary *other = [item[@"cadisplays"][0] mutableCopy];
        other[@"displayId"] = @2;
        other[@"name"] = @"Other";
        other[field] = item[@"cadisplays"][0][field];
        [item[@"cadisplays"] addObject:other];
        require(vpCaptureSource(item, &reason) == nil, "UUID-less ID and render-name collisions must fail");
    }
    for (NSString *field in @[@"displayId", @"name", @"pointScale", @"bounds"]) {
        NSMutableDictionary *item = coverLayout();
        [item[@"cadisplays"][0] removeObjectForKey:field];
        require(vpCaptureSource(item, &reason) == nil, "UUID-less binding requires numeric identity, name, scale and geometry");
    }
    NSMutableDictionary *named = coverLayout();
    [named[@"monitors"][0] removeObjectForKey:@"display_name"];
    require(vpCaptureSource(named, &reason) == nil, "UUID-less binding requires the FrontBoard render name");
    named[@"monitors"][0][@"display_name"] = @"Inner";
    require(vpCaptureSource(named, &reason) == nil, "UUID-less FrontBoard and render names must agree");
    for (NSString *field in @[@"hardware_identifier", @"uniqueId"]) {
        for (id value in @[@"11111111-2222-4333-8444-555555555555", @"", @"not-a-uuid",
                           @"00000000-0000-0000-0000-000000000000", NSNull.null]) {
            NSMutableDictionary *item = coverLayout();
            item[[field isEqual:@"uniqueId"] ? @"cadisplays" : @"monitors"][0][field] = value;
            require(vpCaptureSource(item, &reason) == nil, "asymmetric or invalid UUIDs cannot use the UUID-less fallback");
        }
    }
    NSMutableDictionary *mismatch = layout();
    mismatch[@"cadisplays"][0][@"uniqueId"] = @"51E247B8-F389-4F84-BE57-FE54747ED152";
    require(vpCaptureSource(mismatch, &reason) == nil, "present hardware UUIDs must match");
    mismatch = coverLayout();
    mismatch[@"cadisplays"][0][@"bounds"] = rect(1398, 2031);
    require(vpCaptureSource(mismatch, &reason) == nil, "UUID-less native bounds must match scaled reference geometry");
    mismatch = coverLayout();
    mismatch[@"cadisplays"][0][@"pointScale"] = @2;
    require(vpCaptureSource(mismatch, &reason) == nil, "UUID-less display scales must agree");

    for (NSString *uuid in @[@"", @"00000000-0000-0000-0000-000000000000"]) {
        NSMutableDictionary *item = layout();
        item[@"monitors"][0][@"hardware_identifier"] = uuid;
        require(vpCaptureSource(item, &reason) == nil, "missing or zero UUID must not select another display");
    }
    for (NSString *duplicate in @[@"displayId", @"uniqueId", @"name"]) {
        NSMutableDictionary *item = layout();
        NSMutableDictionary *other = [item[@"cadisplays"][0] mutableCopy];
        other[@"displayId"] = @8;
        other[@"uniqueId"] = @"51E247B8-F389-4F84-BE57-FE54747ED152";
        other[@"name"] = @"Other";
        other[duplicate] = item[@"cadisplays"][0][duplicate];
        [item[@"cadisplays"] addObject:other];
        require(vpCaptureSource(item, &reason) == nil, "ambiguous ID, UUID or render name must fail");
    }
    NSMutableDictionary *scale = layout();
    scale[@"cadisplays"][0][@"pointScale"] = @2;
    require(vpCaptureSource(scale, &reason) == nil, "display scales must agree");
    NSMutableDictionary *capped = layout();
    for (int i = 0; i < 15; i++) {
        NSMutableDictionary *other = [capped[@"cadisplays"][0] mutableCopy];
        other[@"displayId"] = @(i + 20);
        other[@"uniqueId"] = [NSString stringWithFormat:@"00000000-0000-4000-8000-%012d", i + 1];
        other[@"name"] = [NSString stringWithFormat:@"Other %d", i];
        [capped[@"cadisplays"] addObject:other];
    }
    require(vpCaptureSource(capped, &reason) == nil, "a potentially truncated inventory cannot prove uniqueness");
    NSMutableDictionary *cappedCover = coverLayout();
    [cappedCover[@"cadisplays"] addObjectsFromArray:[capped[@"cadisplays"] subarrayWithRange:NSMakeRange(1, 15)]];
    require(vpCaptureSource(cappedCover, &reason) == nil, "UUID-less binding cannot bypass the inventory cap");
    for (NSDictionary *bounds in @[rect(16385, 1), rect(16384, 16384), rect(2007.5, 2853)]) {
        NSMutableDictionary *item = layout();
        item[@"cadisplays"][0][@"bounds"] = bounds;
        require(vpCaptureSource(item, &reason) == nil, "fractional or oversized allocation must fail");
    }
    NSMutableDictionary *limit = layout();
    limit[@"cadisplays"][0][@"bounds"] = rect(4096, 4096);
    require(vpCaptureSource(limit, &reason) != nil, "source geometry at the allocation limit remains admissible");
}

static void captureChecks(void) {
    NSMutableDictionary *before = coverLayout();
    captureLayouts = @[before, before];
    captureLayoutIndex = 0;
    NSDictionary *report = vpCapturePerform(^BOOL { return NO; });
    require([report[@"available"] boolValue] && [report[@"format"] isEqual:@"png"],
            "stable UUID-less metadata must reach the production renderer and PNG encoder");
    require([report[@"source"] isEqual:report[@"source_after"]], "both capture samples must retain the same binding");
    require([report[@"identity_binding"] isEqual:@"matching_display_id_render_name_scale_and_reference_bounds_without_hardware_uuid"],
            "UUID-less capture must report its actual binding evidence");
    require([report[@"rotation_applied"] isEqual:@0] && [report[@"resized"] isEqual:@NO]
            && [report[@"orientation_mapping_verified"] isEqual:@NO] && [report[@"capture_content_verified"] isEqual:@NO],
            "raw capture cannot claim orientation or content verification");
    for (NSString *field in @[@"displayId", @"name", @"pointScale", @"bounds", @"uniqueId"]) {
        NSMutableDictionary *after = coverLayout();
        after[@"cadisplays"][0][field] = [field isEqual:@"bounds"] ? rect(1398, 2031)
            : [field isEqual:@"name"] ? @"Other" : [field isEqual:@"uniqueId"] ? @"11111111-2222-4333-8444-555555555555" : @2;
        captureLayouts = @[before, after];
        captureLayoutIndex = 0;
        require([vpCapturePerform(^BOOL { return NO; })[@"state"] isEqual:@"source_changed"],
                "capture must refuse changed identity, name, scale, geometry or UUID availability");
    }
    captureLayouts = nil;
}

int main(void) {
    @autoreleasepool {
        sourceChecks();
        captureChecks();
        require([vp_display_capture_active()[@"state"] isEqual:@"main_thread_caller"],
                "main-thread capture must not block its run loop");
        layoutEntered = dispatch_semaphore_create(0);
        layoutRelease = dispatch_semaphore_create(0);
        atomic_store(&blockLayout, true);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_queue_t requests = dispatch_queue_create("vphone.test.capture-requests", DISPATCH_QUEUE_SERIAL);
        __block NSDictionary *first;
        dispatch_async(requests, ^{
            first = vp_display_capture_active();
            dispatch_semaphore_signal(done);
        });
        require(dispatch_semaphore_wait(layoutEntered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
                "capture must enter the layout fixture");
        require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) == 0,
                "caller response must be bounded while its private dependency stalls");
        require([first[@"state"] isEqual:@"timed_out"], "stalled capture must time out");
        dispatch_async(requests, ^{
            require([vp_display_capture_active()[@"state"] isEqual:@"busy"],
                    "timed-out capture must retain admission while its dependency runs");
            dispatch_semaphore_signal(done);
        });
        require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
                "busy admission must answer without another private call");
        atomic_store(&blockLayout, false);
        dispatch_semaphore_signal(layoutRelease);
        dispatch_async(requests, ^{
            dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC);
            while (true) {
                NSDictionary *report = vp_display_capture_active();
                if (![report[@"state"] isEqual:@"busy"]) {
                    require([report[@"state"] isEqual:@"source_unavailable"], "admission must recover after the task drains");
                    break;
                }
                require(dispatch_time(DISPATCH_TIME_NOW, 0) < deadline, "capture admission did not recover");
                usleep(1000);
            }
            dispatch_semaphore_signal(done);
        });
        require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
                "recovered capture must answer from a background caller");
        puts("display capture: identity binding, allocation bounds and retained admission passed");
    }
    return EXIT_SUCCESS;
}
