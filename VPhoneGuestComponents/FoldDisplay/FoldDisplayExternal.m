// Opt-in external monitor. The render server owns the display; FrontBoard
// receives an AirPlay/external identity and chooses mirroring or app scenes.
#import "FoldDisplayPrivate.h"
#include <notify.h>

static NSString *const vpExternalName = @"VPhone External";
static NSString *const vpExternalRequest = @"/var/mobile/Library/Caches/vphone-external-display.request.plist";
static NSString *const vpExternalStatus = @"/var/mobile/Library/Caches/vphone-external-display.status.plist";
static id vpExternalRenderDisplay;
static id vpExternal1080Display, vpExternal4KDisplay;
static int vpExternalNotificationToken;
static int vpExternalInspectionToken;
static int vpExternalRefreshToken;
static IMP vpExternalOriginalType, vpExternalOriginalScale, vpExternalOriginalExternal;
static IMP vpExternalOriginalCloning;

static BOOL vpIsExternalMonitor(id display) {
    return [vpReadObject(display, "name") hasPrefix:vpExternalName] ||
        [vpReadObject(display, "deviceName") hasPrefix:vpExternalName];
}
static long long vpExternalType(id self, SEL cmd) {
    return vpIsExternalMonitor(self) ? 2 : ((long long (*)(id, SEL))vpExternalOriginalType)(self, cmd);
}
static NSUInteger vpExternalScale(id self, SEL cmd) {
    if (!vpIsExternalMonitor(self)) return ((NSUInteger (*)(id, SEL))vpExternalOriginalScale)(self, cmd);
    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(self, sel_registerName("bounds"));
    return bounds.size.width >= 3840 ? 2 : 1;
}
static BOOL vpExternalIsExternal(id self, SEL cmd) {
    return vpIsExternalMonitor(self) ? YES : ((BOOL (*)(id, SEL))vpExternalOriginalExternal)(self, cmd);
}
static BOOL vpExternalCloning(id self, SEL cmd) {
    return vpIsExternalMonitor(self) ? YES : ((BOOL (*)(id, SEL))vpExternalOriginalCloning)(self, cmd);
}

static void vpRefreshExternalDisplaySources(void) {
    // Virtual render objects do not drive the hardware display observer's
    // refresh. Update the existing CADisplay objects so their native KVO
    // observers publish tag/mode changes to SpringBoard's existing sources.
    // Keep the objects: replacing the cached array would lose those observers.
    NSArray *displays = vpReadObject(objc_getClass("CADisplay"), "displays");
    NSString *activeName = [NSDictionary dictionaryWithContentsOfFile:vpExternalStatus][@"name"];
    id active = nil;
    for (id display in displays) {
        if (!vpIsExternalMonitor(display)) continue;
        if ([vpReadObject(display, "name") isEqual:activeName]) { active = display; continue; }
        Method update = class_getInstanceMethod(object_getClass(display), sel_registerName("update"));
        if (update && strcmp(method_getTypeEncoding(update), "v16@0:8") == 0)
            ((void (*)(id, SEL))objc_msgSend)(display, sel_registerName("update"));
    }
    // Publish old-screen disconnection before the newly selected connection.
    if (active) dispatch_async(dispatch_get_main_queue(), ^{
        Method update = class_getInstanceMethod(object_getClass(active), sel_registerName("update"));
        if (update && strcmp(method_getTypeEncoding(update), "v16@0:8") == 0)
            ((void (*)(id, SEL))objc_msgSend)(active, sel_registerName("update"));
    });
}

// Read-only inspection in the process that owns native display/scene policy.
// An app can see the BKS source without SpringBoard admitting an app scene.
static void vpInspectExternalScenePolicy(void) {
    NSMutableDictionary *report = [@{@"updated": @(NSDate.date.timeIntervalSince1970)} mutableCopy];
    @try {
        id app = vpReadObject(objc_getClass("UIApplication"), "sharedApplication");
        id monitor = vpReadObject(objc_getClass("FBDisplayManager"), "sharedInstance");
        report[@"monitor"] = [monitor description] ?: @"unavailable";
        report[@"transformer"] = [vpReadObject(monitor, "transformer") description] ?: @"unavailable";
        NSMutableArray *scenes = [NSMutableArray array];
        for (id scene in [vpReadObject(app, "connectedScenes") allObjects] ?: @[]) {
            id screen = vpReadObject(scene, "screen");
            id fbs = vpReadObject(scene, "_FBSScene");
            id configuration = vpReadObject(vpReadObject(fbs, "settings"), "displayConfiguration");
            [scenes addObject:@{@"class": NSStringFromClass([scene class]),
                @"scene": [scene description] ?: @"", @"screen": [screen description] ?: @"",
                @"configuration": [configuration description] ?: @"",
                @"windows": [vpReadObject(scene, "windows") description] ?: @""}];
        }
        report[@"scenes"] = scenes;
        report[@"sceneManager"] = [vpReadObject(vpReadObject(objc_getClass("FBSceneManager"), "sharedInstance"), "debugDescription") description] ?: @"unavailable";
        NSMutableDictionary *owners = [NSMutableDictionary dictionary];
        for (Class cls = [app class]; cls; cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                const char *name = ivar_getName(ivars[i]);
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (type[0] != '@' || (!strcasestr(name, "display") && !strcasestr(name, "mirror") && !strcasestr(name, "airplay"))) continue;
                id value = object_getIvar(app, ivars[i]);
                if (value) owners[@(name)] = [value description] ?: @"";
            }
            free(ivars);
        }
        report[@"owners"] = owners;
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        NSMutableDictionary *surface = [NSMutableDictionary dictionary];
        for (unsigned int i = 0; i < count; i++) {
            const char *name = class_getName(classes[i]);
            if (strncmp(name, "SB", 2) || (!strstr(name, "ExternalDisplay") && !strstr(name, "AirPlay") && !strstr(name, "Mirroring"))) continue;
            NSMutableArray *methods = [NSMutableArray array];
            for (int meta = 0; meta < 2; meta++) {
                unsigned int methodCount = 0;
                Method *list = class_copyMethodList(meta ? object_getClass(classes[i]) : classes[i], &methodCount);
                for (unsigned int j = 0; j < methodCount; j++)
                    [methods addObject:[NSString stringWithFormat:@"%s%s %s", meta ? "+" : "-", sel_getName(method_getName(list[j])), method_getTypeEncoding(list[j])]];
                free(list);
            }
            surface[@(name)] = methods;
        }
        free(classes);
        report[@"externalPolicyClasses"] = surface;
    } @catch (NSException *exception) {
        report[@"error"] = exception.reason ?: exception.name;
    }
    [report writeToFile:@"/var/mobile/Library/Caches/vphone-external-display.springboard.plist" atomically:YES];
}

void vpPrepareExternalRenderDisplays(id server) {
    if (!server || (vpExternal1080Display && vpExternal4KDisplay)) return;
    @try {
        Class cls = objc_getClass("CAWindowServerVirtualDisplay");
        Method initializer = class_getInstanceMethod(cls, sel_registerName("initWithOptions:"));
        if (!initializer || strcmp(method_getTypeEncoding(initializer), "@24@0:8@16") != 0) return;
        for (int index = 0; index < 2; index++) {
            if (index ? vpExternal4KDisplay != nil : vpExternal1080Display != nil) continue;
            NSInteger width = index ? 3840 : 1920, height = index ? 2160 : 1080;
            NSString *name = index ? @"VPhone External 4K" : @"VPhone External 1080p";
            id display = ((id (*)(id, SEL, id))objc_msgSend)([cls alloc], sel_registerName("initWithOptions:"), @{
                @"kCAVirtualDisplayWidth": @(width), @"kCAVirtualDisplayHeight": @(height),
                @"kCAVirtualDisplayUpdateRate": @60, @"kCAVirtualDisplayName": name,
            });
            if (!display) continue;
            ((void (*)(id, SEL, id))objc_msgSend)(server, sel_registerName("addDisplay:"), display);
            ((void (*)(id, SEL, long long))objc_msgSend)(display, sel_registerName("setTag:"), 0);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(display, sel_registerName("setEnabled:"), NO);
            if (index) vpExternal4KDisplay = display; else vpExternal1080Display = display;
            vpFoldDisplayLog([NSString stringWithFormat:@"external display: prepared disconnected %@", display]);
        }
    } @catch (NSException *exception) {
        vpFoldDisplayLog([NSString stringWithFormat:@"external display: prepare failed %@", exception.reason]);
    }
}

static void vpApplyExternalRequest(void) {
    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:vpExternalRequest];
    if (![request[@"nonce"] isKindOfClass:NSString.class]) return;
    NSMutableDictionary *status = [request mutableCopy];
    @try {
        id server = vpReadObject(objc_getClass("CAWindowServer"), "serverIfRunning");
        if (!server) @throw [NSException exceptionWithName:@"ExternalDisplay" reason:@"Render server unavailable" userInfo:nil];
        for (id display in @[vpExternal1080Display ?: NSNull.null, vpExternal4KDisplay ?: NSNull.null]) {
            if (display == NSNull.null) continue;
            // Stable render objects are enumerated before SpringBoard starts.
            // Only their connection tags and enabled state change at runtime.
            ((void (*)(id, SEL, long long))objc_msgSend)(display, sel_registerName("setTag:"), 0);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(display, sel_registerName("setEnabled:"), NO);
        }
        vpExternalRenderDisplay = nil;
        if ([request[@"enabled"] boolValue]) {
            NSInteger width = [request[@"width"] integerValue], height = [request[@"height"] integerValue];
            if (!((width == 1920 && height == 1080) || (width == 3840 && height == 2160)))
                @throw [NSException exceptionWithName:@"ExternalDisplay" reason:@"Only 1080p and 4K are supported" userInfo:nil];
            id display = width == 3840 ? vpExternal4KDisplay : vpExternal1080Display;
            if (!display) @throw [NSException exceptionWithName:@"ExternalDisplay" reason:@"External render display was not prepared at boot" userInfo:nil];
            // FrontBoard clears a non-always-connected source with no tag.
            // Publish the source before native external-role classification.
            vpTagRenderDisplay(display, @"AirPlay");
            ((void (*)(id, SEL, BOOL))objc_msgSend)(display, sel_registerName("setEnabled:"), YES);
            vpExternalRenderDisplay = display;
            status[@"name"] = width == 3840 ? @"VPhone External 4K" : @"VPhone External 1080p";
            vpFoldDisplayLog([NSString stringWithFormat:@"external display: connected %ldx%ld %@", (long)width, (long)height, display]);
        } else {
            vpFoldDisplayLog(@"external display: disconnected");
        }
        status[@"ok"] = @YES;
    } @catch (NSException *exception) {
        status[@"ok"] = @NO;
        status[@"error"] = exception.reason ?: exception.name;
        status[@"enabled"] = @(vpExternalRenderDisplay != nil);
        vpFoldDisplayLog([NSString stringWithFormat:@"external display: %@", status[@"error"]]);
    }
    [status writeToFile:vpExternalStatus atomically:YES];
    notify_post("com.vphone.external-display.changed");
}

void vpInstallExternalDisplay(BOOL serverProcess) {
    Class cls = objc_getClass("CADisplay");
    const char *names[] = {"displayType", "pointScale", "isExternal", "isCloningSupported"};
    const char *types[] = {"q16@0:8", "Q16@0:8", "B16@0:8", "B16@0:8"};
    IMP replacements[] = {(IMP)vpExternalType, (IMP)vpExternalScale, (IMP)vpExternalIsExternal, (IMP)vpExternalCloning};
    IMP *originals[] = {&vpExternalOriginalType, &vpExternalOriginalScale, &vpExternalOriginalExternal, &vpExternalOriginalCloning};
    for (int i = 0; i < 4; i++) {
        Method method = class_getInstanceMethod(cls, sel_registerName(names[i]));
        if (!method || strcmp(method_getTypeEncoding(method), types[i]) != 0) {
            vpFoldDisplayLog(@"external display: CADisplay ABI unavailable");
            return;
        }
    }
    for (int i = 0; i < 4; i++)
        *originals[i] = method_setImplementation(class_getInstanceMethod(cls, sel_registerName(names[i])), replacements[i]);
    if (!serverProcess) {
        notify_register_dispatch("com.vphone.external-display.changed", &vpExternalRefreshToken,
            dispatch_get_main_queue(), ^(int token) { vpRefreshExternalDisplaySources(); });
        notify_register_dispatch("com.vphone.external-display.inspect", &vpExternalInspectionToken,
            dispatch_get_main_queue(), ^(int token) { vpInspectExternalScenePolicy(); });
        return;
    }
    // Ignore stale requests at boot: only an explicit host connect activates.
    [@{@"ok": @YES, @"enabled": @NO} writeToFile:vpExternalStatus atomically:YES];
    uint32_t result = notify_register_dispatch("com.vphone.external-display.configure", &vpExternalNotificationToken,
        dispatch_get_main_queue(), ^(int token) { vpApplyExternalRequest(); });
    vpFoldDisplayLog([NSString stringWithFormat:@"external display: request listener %u", result]);
}
