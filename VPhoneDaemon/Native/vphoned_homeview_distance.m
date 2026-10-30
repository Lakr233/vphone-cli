/* HomeView's native, distance-derived level-of-detail service. The wire API is
 * BBSEnvironmentServiceServerInterface in BreadBoardServices 27.2 (24V514).
 * See Research/Firmware/homeview_distance.md for the inspected ABI and limits.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <stdatomic.h>

static Class vpHomeViewRequestClass(void) {
    if (access("/System/Library/CoreServices/BreadBoard.app/BreadBoard", F_OK) != 0) return Nil;
    char machine[128] = {0}, model[128] = {0};
    size_t machineSize = sizeof(machine), modelSize = sizeof(model);
    sysctlbyname("hw.machine", machine, &machineSize, NULL, 0);
    sysctlbyname("hw.model", model, &modelSize, NULL, 0);
    if (strncmp(machine, "HomeAccessory17,", 16) != 0
        && strcmp(model, "J490AP") != 0 && strcmp(model, "J491AP") != 0) return Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/BreadBoardServices.framework/BreadBoardServices", RTLD_NOW | RTLD_LOCAL);
    });
    return NSClassFromString(@"BBSEnvironmentOverrideRequest");
}

bool vp_homeview_distance_available(void) {
    return vpHomeViewRequestClass() != Nil;
}

@protocol VPBBSEnvironmentRemote
- (void)fetchCurrentEnvironmentWithReply:(void (^)(id, NSError *))reply;
- (void)applyEnvironmentOverrides:(id)request completion:(void (^)(id, NSError *))reply;
- (void)resetEnvironmentOverridesWithCompletion:(void (^)(id, NSError *))reply;
@end
@interface NSObject (VPHomeViewPrivate)
+ (id)endpointForMachName:(NSString *)name service:(NSString *)service instance:(id)instance;
+ (id)interfaceWithIdentifier:(NSString *)identifier;
+ (id)protocolForProtocol:(Protocol *)protocol;
+ (id)defaultMultiplexer;
+ (id)userInitiated;
+ (id)queueWithName:(NSString *)name serviceQuality:(id)quality;
- (void)setMultiplexer:(id)value;
- (void)setServer:(id)value;
- (void)setInterface:(id)value;
- (void)setQueue:(id)value;
- (void)setActivationHandler:(id)value;
- (void)setInterruptionHandler:(id)value;
- (void)setInvalidationHandler:(id)value;
- (id)initWithEndpoint:(id)endpoint options:(void (^)(id))options;
- (void)configure:(void (^)(id))configuration;
- (void)activate;
- (void)invalidate;
- (id)remoteTarget;
- (id)initWithActivePersonaUniqueIdentifier:(id)persona displayStyle:(id)style levelOfDetail:(id)detail backlightState:(id)backlight;
- (NSInteger)levelOfDetail;
@end

static id vpDistanceConnection;
static NSString *vpDistanceMode;
static atomic_bool vpDistanceDisconnected;
static atomic_uint vpDistanceGeneration;
static NSLock *vpDistanceLock;
static dispatch_once_t vpDistanceLockOnce;

static BOOL vpDistanceIntegerGetter(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = type && (strcmp(type, @encode(NSInteger)) == 0);
    free(type);
    return valid;
}

static const char *vpDistanceUnqualifiedType(const char *type) {
    // Distributed-object protocols encode `oneway void` as Vv. Qualifiers
    // describe calling semantics, not a different register/argument layout.
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL vpDistanceProtocolABI(Protocol *protocol) {
    // Runtime protocol metadata verifies the outer callback is an ObjC block.
    // Its nested (environment, NSError) signature comes from the inspected
    // native callers; Objective-C method encodings do not retain block arguments.
    for (NSString *name in @[@"fetchCurrentEnvironmentWithReply:", @"applyEnvironmentOverrides:completion:", @"resetEnvironmentOverridesWithCompletion:"]) {
        BOOL apply = [name hasPrefix:@"apply"];
        struct objc_method_description description = protocol_getMethodDescription(protocol, NSSelectorFromString(name), YES, YES);
        if (!description.types) return NO;
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:description.types];
        if (strcmp(vpDistanceUnqualifiedType(signature.methodReturnType), @encode(void)) || signature.numberOfArguments != (apply ? 4 : 3)) return NO;
        if (apply && strcmp(vpDistanceUnqualifiedType([signature getArgumentTypeAtIndex:2]), @encode(id))) return NO;
        if (strcmp(vpDistanceUnqualifiedType([signature getArgumentTypeAtIndex:apply ? 3 : 2]), "@?")) return NO;
    }
    return YES;
}

static BOOL vpDistanceServiceABI(Protocol *protocol) {
    if (!vpDistanceProtocolABI(protocol)) return NO;
    Method constructor = class_getInstanceMethod(vpHomeViewRequestClass(), @selector(initWithActivePersonaUniqueIdentifier:displayStyle:levelOfDetail:backlightState:));
    if (!constructor) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(constructor)];
    if (strcmp(signature.methodReturnType, @encode(id)) || signature.numberOfArguments != 6) return NO;
    for (NSUInteger argument = 2; argument < 6; argument++) if (strcmp([signature getArgumentTypeAtIndex:argument], @encode(id))) return NO;
    return YES;
}

static id<VPBBSEnvironmentRemote> vpDistanceRemote(void) {
    if (atomic_exchange(&vpDistanceDisconnected, false)) {
        atomic_fetch_add(&vpDistanceGeneration, 1);
        [vpDistanceConnection invalidate];
        vpDistanceConnection = nil;
        vpDistanceMode = nil;
    }
    if (!vpDistanceConnection) {
        NSString *service = @"com.apple.breadboard.environment-service";
        Protocol *protocol = NSProtocolFromString(@"BBSEnvironmentServiceServerInterface");
        if (!protocol || !vpDistanceServiceABI(protocol)) return nil;
        id endpoint = [NSClassFromString(@"BSServiceConnectionEndpoint") endpointForMachName:@"com.apple.breadboardservices" service:service instance:nil];
        id interface = [NSClassFromString(@"BSMutableServiceInterface") interfaceWithIdentifier:service];
        [interface setServer:[NSClassFromString(@"BSObjCProtocol") protocolForProtocol:protocol]];
        interface = [interface copy];
        id queue = [NSClassFromString(@"BSServiceDispatchQueue") queueWithName:service serviceQuality:[NSClassFromString(@"BSServiceQuality") userInitiated]];
        if (!endpoint || !interface || !queue) return nil;
        vpDistanceConnection = [[NSClassFromString(@"BSServiceInitiatingConnection") alloc] initWithEndpoint:endpoint options:^(id options) {
            [options setMultiplexer:[NSClassFromString(@"BSServiceInitiatingConnectionMultiplexer") defaultMultiplexer]];
        }];
        dispatch_semaphore_t activated = dispatch_semaphore_create(0);
        unsigned generation = atomic_load(&vpDistanceGeneration);
        [vpDistanceConnection configure:^(id config) {
            [config setInterface:interface];
            [config setQueue:queue];
            [config setActivationHandler:^(id connection) { (void)connection; dispatch_semaphore_signal(activated); }];
            [config setInterruptionHandler:^{ if (atomic_load(&vpDistanceGeneration) == generation) atomic_store(&vpDistanceDisconnected, true); }];
            [config setInvalidationHandler:^{ if (atomic_load(&vpDistanceGeneration) == generation) atomic_store(&vpDistanceDisconnected, true); }];
        }];
        [vpDistanceConnection activate];
        if (dispatch_semaphore_wait(activated, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC))) {
            atomic_store(&vpDistanceDisconnected, true);
            return nil;
        }
    }
    return [vpDistanceConnection remoteTarget];
}

static NSDictionary *vpDistanceReply(const char *mode) {
    if (!vp_homeview_distance_available()) return @{@"ok":@NO,@"error":@"HomeView distance simulation is unavailable on this guest"};
    NSString *requested = mode ? [NSString stringWithUTF8String:mode] : nil;
    if (requested && ![@[@"automatic",@"near",@"standard",@"far"] containsObject:requested]) return @{@"ok":@NO,@"error":@"Invalid HomeView distance mode"};
    id<VPBBSEnvironmentRemote> remote = vpDistanceRemote();
    if (!remote) return @{@"ok":@NO,@"error":@"HomeView environment service did not activate; retail firmware requires the scoped environment simulation service patch"};
    if (atomic_load(&vpDistanceDisconnected)) { vpDistanceMode = nil; return @{@"ok":@NO,@"error":@"HomeView environment service disconnected; reconnect required"}; }
    __block id environment;
    __block NSError *error;
    dispatch_semaphore_t completion = dispatch_semaphore_create(0);
    void (^reply)(id,NSError *) = ^(id value,NSError *failure) { environment=value; error=failure; dispatch_semaphore_signal(completion); };
    if (requested) vpDistanceMode = nil;
    if ([requested isEqual:@"automatic"]) [remote resetEnvironmentOverridesWithCompletion:reply];
    else if (requested) {
        if (!vpDistanceIntegerGetter(vpHomeViewRequestClass(), @selector(levelOfDetail))) return @{@"ok":@NO,@"error":@"HomeView request detail getter ABI mismatch"};
        NSInteger detail = [requested isEqual:@"near"] ? 2 : [requested isEqual:@"far"] ? 0 : 1;
        id request = [[vpHomeViewRequestClass() alloc] initWithActivePersonaUniqueIdentifier:nil displayStyle:nil levelOfDetail:@(detail) backlightState:nil];
        if (!request || [request levelOfDetail] != detail) return @{@"ok":@NO,@"error":@"HomeView level-of-detail request ABI mismatch"};
        [remote applyEnvironmentOverrides:request completion:reply];
    } else [remote fetchCurrentEnvironmentWithReply:reply];
    if (dispatch_semaphore_wait(completion, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC))) {
        vpDistanceMode = nil;
        return @{@"ok":@NO,@"error":@"HomeView environment service timed out; override state is unknown"};
    }
    if (requested && (error || !environment)) vpDistanceMode = nil;
    if (error || !environment) return @{@"ok":@NO,@"error":error ? [NSString stringWithFormat:@"%@: %@",error,error.userInfo] : @"HomeView environment service returned no state"};
    if (requested) {
        dispatch_semaphore_t readDone = dispatch_semaphore_create(0);
        environment = nil;
        error = nil;
        [remote fetchCurrentEnvironmentWithReply:^(id value, NSError *failure) {
            environment = value;
            error = failure;
            dispatch_semaphore_signal(readDone);
        }];
        if (dispatch_semaphore_wait(readDone, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC))) return @{@"ok":@NO,@"error":@"HomeView override acknowledgement received but independent readback timed out; override state is unknown"};
        if (error || !environment) return @{@"ok":@NO,@"error":@"HomeView override acknowledgement received but independent readback failed; override state is unknown"};
    }
    if (!vpDistanceIntegerGetter([environment class], @selector(levelOfDetail))) return @{@"ok":@NO,@"error":@"HomeView environment readback ABI mismatch"};
    NSInteger level = [environment levelOfDetail];
    if (level < 0 || level > 2) return @{@"ok":@NO,@"error":@"HomeView environment returned an unsupported detail level"};
    if (atomic_load(&vpDistanceDisconnected)) {
        vpDistanceMode = nil;
        return @{@"ok":@NO,@"error":@"HomeView environment disconnected during readback; override state is unknown"};
    }
    if (!requested && vpDistanceMode && ![vpDistanceMode isEqual:@"automatic"]) {
        NSInteger expected = [vpDistanceMode isEqual:@"near"] ? 2 : [vpDistanceMode isEqual:@"far"] ? 0 : 1;
        if (level != expected) vpDistanceMode = nil;
    }
    if (requested) {
        // Ownership is recorded only after acknowledgement and a separate fetch.
        NSInteger expected = [requested isEqual:@"near"] ? 2 : [requested isEqual:@"far"] ? 0 : 1;
        if (![requested isEqual:@"automatic"] && level != expected) return @{@"ok":@NO,@"error":@"HomeView detail override readback did not match"};
        vpDistanceMode = requested;
    }
    return @{@"ok":@YES,@"result":@{@"available":@YES,@"mode":vpDistanceMode ?: @"unknown",@"level_of_detail":@(level),@"override_active":vpDistanceMode ? @(![vpDistanceMode isEqual:@"automatic"]) : NSNull.null,@"applied":@(requested != nil),@"reset_scope":@"environment"}};
}

char *vp_homeview_distance_copy_json(const char *mode) {
    @autoreleasepool {
        dispatch_once(&vpDistanceLockOnce, ^{ vpDistanceLock = [NSLock new]; });
        [vpDistanceLock lock];
        NSDictionary *reply;
        @try { reply = vpDistanceReply(mode); }
        @catch (NSException *exception) { reply = @{@"ok":@NO,@"error":[@"HomeView environment ABI exception: " stringByAppendingString:exception.reason ?: exception.name]}; }
        [vpDistanceLock unlock];
        NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
        return data ? strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String) : NULL;
    }
}
