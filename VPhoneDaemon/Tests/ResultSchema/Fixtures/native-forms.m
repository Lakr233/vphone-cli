// Fixture for NativeExtractor rules 6-9. Parsed only, never compiled.
// Each `expect:` line is `<function>[@writer] => <catalog result cell>`.

// vp_gyro_get shape, copied from VPhoneDaemon/Native/vphoned_gyro.m with the
// Encode literal from VPhoneGuestComponents/Gyroscope/VPhoneGyroscopeState.h.
static inline NSDictionary *VPhoneGyroscopeEncode(VPhoneGyroscopeState state) {
    return @{@"enabled": @(state.enabled), @"x": @(state.x), @"y": @(state.y), @"z": @(state.z)};
}

// expect: vp_gyro_get => enabled:any,provider:object:null,provider_running:any,units:string,x:any,y:any,z:any
NSDictionary *vp_gyro_get(void) {
    CFPreferencesSynchronize(CFSTR(VP_GYRO_DOMAIN), CFSTR("mobile"), kCFPreferencesAnyHost);
    VPhoneGyroscopeState state;
    VPhoneGyroscopeDecode(VPhoneGyroscopeRead(CFSTR(VP_GYRO_CONFIGURATION)), &state);
    NSMutableDictionary *result = [VPhoneGyroscopeEncode(state) mutableCopy];
    result[@"units"] = @"rad/s";
    id status = VPhoneGyroscopeRead(CFSTR(VP_GYRO_STATUS));
    if ([status isKindOfClass:NSDictionary.class] &&
        [status[@"updated_at"] isKindOfClass:NSNumber.class] &&
        [status[@"enumerated"] isKindOfClass:NSNumber.class]) {
        result[@"provider"] = status;
        double age = [NSDate date].timeIntervalSince1970 - [status[@"updated_at"] doubleValue];
        BOOL dispatching = [status[@"report_interval_us"] isKindOfClass:NSNumber.class] &&
                           [status[@"report_interval_us"] unsignedLongLongValue] > 0;
        BOOL alive = NO;
        if ([status[@"pid"] isKindOfClass:NSNumber.class]) {
            pid_t pid = [status[@"pid"] intValue];
            alive = pid > 1 && (kill(pid, 0) == 0 || errno == EPERM);
        }
        BOOL fresh = age >= 0 && age < 10;
        result[@"provider_running"] = @([status[@"enumerated"] boolValue] && alive && (fresh || !dispatching));
    } else {
        result[@"provider"] = NSNull.null;
        result[@"provider_running"] = @NO;
    }
    return result;
}

// display.external shape (FoldDisplayExternal.m): the request plist written by one
// function, read back and extended into the status plist by another.
static NSString *const vpExternalRequest = @"/var/mobile/Library/Caches/vphone-external-display.request.plist";
static NSString *const vpExternalStatus = @"/var/mobile/Library/Caches/vphone-external-display.status.plist";

// expect: vpWriteExternalRequest@writer => enabled:boolean,height:integer,nonce:string,width:integer
void vpWriteExternalRequest(BOOL enabled, NSInteger width, NSInteger height, NSString *nonce) {
    NSDictionary *request = @{@"enabled": @(enabled), @"width": @(width), @"height": @(height), @"nonce": nonce};
    [request writeToFile:vpExternalRequest atomically:YES];
}

// expect: vpApplyExternalRequest@writer => enabled:any,error:string?,height:integer,name:string?,nonce:string,ok:boolean?,width:integer
static void vpApplyExternalRequest(void) {
    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:vpExternalRequest];
    if (![request[@"nonce"] isKindOfClass:NSString.class]) return;
    NSMutableDictionary *status = [request mutableCopy];
    @try {
        if ([request[@"enabled"] boolValue]) {
            NSInteger width = [request[@"width"] integerValue];
            status[@"name"] = width == 3840 ? @"VPhone External 4K" : @"VPhone External 1080p";
        }
        status[@"ok"] = @YES;
    } @catch (NSException *exception) {
        status[@"ok"] = @NO;
        status[@"error"] = exception.reason ?: exception.name;
        status[@"enabled"] = @(vpExternalRenderDisplay != nil);
    }
    [status writeToFile:vpExternalStatus atomically:YES];
}

void vpInstallExternalDisplay(void) {
    [@{@"ok": @YES, @"enabled": @NO} writeToFile:vpExternalStatus atomically:YES];
}

// A literal on either side of `?:` counts; the status plist takes every writer's literal.
// expect: vpExternalDiagnostics => enabled:any,error:string?,height:integer?,name:string?,nonce:string?,ok:boolean?,width:integer?
NSDictionary *vpExternalDiagnostics(void) {
    return [NSDictionary dictionaryWithContentsOfFile:vpExternalStatus] ?: @{@"ok": @NO, @"enabled": @NO};
}

// expect: bridgeDecode => count:integer,items:array
NSDictionary *bridgeDecode(int n) {
    return decodeBridgeJSON(icli_widget_json(n));
}

// expect: bridgeTake => count:integer,items:array
NSString *bridgeTake(int n) {
    return takeCString(icli_widget_json(n));
}

// expect: icli_widget_json => count:integer,items:array
char *icli_widget_json(int count) {
    return icli_json_or_empty(@{@"count": @(count), @"items": @[]});
}

// expect: icli_pair_json => apps:array?,error:string?
char *icli_pair_json(int fail) {
    if (fail) return icli_json_or_empty(@{@"error": @"unavailable"});
    NSMutableArray *apps = [NSMutableArray array];
    return icli_json_or_empty(@{@"apps": apps});
}

// expect: setObjectForm => alpha:string,beta:integer?,gamma:boolean?
NSDictionary *setObjectForm(BOOL flag) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    [d setObject:@"x" forKey:@"alpha"];
    if (flag) {
        [d setObject:@3 forKey:@"beta"];
    }
    for (int i = 0; i < 2; i++) d[@"gamma"] = @YES;
    return d;
}

// expect: ternaryLiteral => a:integer,b:string?,c:boolean?
NSDictionary *ternaryLiteral(BOOL f) {
    return f ? @{@"a": @1, @"b": @"x"} : @{@"a": @2, @"c": @YES};
}

// expect: earlyReturn => base:integer,late:string?
NSDictionary *earlyReturn(BOOL f) {
    NSMutableDictionary *d = [@{@"base": @1} mutableCopy];
    if (f) return d;
    d[@"late"] = @"x";
    return d;
}

// A callee defined only in another file is found through the lookup.
// expect: bridgeRemote => remote:string,total:integer
NSDictionary *bridgeRemote(void) {
    return decodeBridgeJSON(icli_remote_json());
}

// Type inference (REQ-RPC-007): casts, declared locals and parameters give a type; an
// external property, an NSNumber or `?: NSNull.null` gives any.
// expect: nativeTypes => array:array,cast:integer,count:integer,dict:object,external:any,float:number,fmt:string,int:integer,label:string,mixed:any,no:boolean,nullable:string:null,on:boolean,ratio:number,text:string,wrapped:any,yes:boolean
NSDictionary *nativeTypes(int n, double ratio, BOOL on, NSString *label, NSNumber *wrapped) {
    return @{@"count": @(n), @"ratio": @(ratio), @"on": @(on), @"label": label, @"wrapped": wrapped,
             @"yes": @YES, @"no": @NO, @"int": @7, @"float": @1.5, @"text": @"t", @"array": @[@1],
             @"dict": @{@"a": @1}, @"cast": @((int)ratio), @"external": @(pasteboard.changeCount),
             @"mixed": on ? @1 : @"a", @"nullable": label ?: NSNull.null,
             @"fmt": [NSString stringWithFormat:@"%d", n]};
}

// Rule 10: the envelope's `result` value is what the Swift side unwraps.
// expect-unwrap: vp_demo_copy_json["result"] => a:integer
char *vp_demo_copy_json(void) {
    NSDictionary *envelope = @{@"ok": @YES, @"result": @{@"a": @1}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:NSJSONWritingSortedKeys error:NULL];
    return strndup(data.bytes, data.length);
}

// A value passed through from another dictionary is open.
// expect-unwrap: vp_open_copy_json["result"] => open
char *vp_open_copy_json(NSDictionary *result, NSString *error) {
    NSDictionary *envelope = error ? @{@"ok": @NO, @"error": error} : @{@"ok": @YES, @"result": result ?: @{}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:NSJSONWritingSortedKeys error:NULL];
    return strndup(data.bytes, data.length);
}

// Rule 10 through a helper in the same file: the envelope literal is built by vpNestedReply.
// expect-unwrap: vp_nested_copy_json["result"] => available:boolean,level:integer
static NSDictionary *vpNestedReply(NSInteger level) {
    if (level < 0) return @{@"ok": @NO, @"error": @"bad level"};
    return @{@"ok": @YES, @"result": @{@"available": @YES, @"level": @(level)}};
}

char *vp_nested_copy_json(void) {
    NSDictionary *reply = vpNestedReply(1);
    NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
    return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}

// Rule 11 bridge: the elements added to the array the function returns.
// expect-elements: icli_rows_json => id:string,name:string?,size:integer
char *icli_rows_json(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *skipped = [NSMutableArray array];
    for (id proxy in rows) {
        [out addObject:icliRowDictionary(proxy)];
        [skipped addObject:@"ignored"];
    }
    return icli_system_json(out) ?: strdup("[]");
}

NSDictionary *icliRowDictionary(id proxy) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"id"] = @"row";
    d[@"size"] = @(3);
    if (proxy) {
        d[@"name"] = @"n";
    }
    return d;
}

// Typed forms: each key takes the type its ObjC form gives it. FormsPoint is
// declared in the lookup source (native-icli.m).
static BOOL formsConfigured;
static double formsClock(void) { return 1.5; }
static NSString *formsLabel(int n) { return n ? @"x" : nil; }
@interface FormsWalker : NSObject {
@public
    int queries, seen;
    double start;
    NSMutableArray *reasons, *visited;
    NSPredicate *predicate;
}
@property (nonatomic) NSInteger level;
- (NSInteger)depth;
@end

// Calls with a declared return type, file-scope variables, members, comparisons and arithmetic.
// expect: formsCalls => clock:number,configured:boolean,elapsed:number,flag:integer,label:string,level:integer,pid:integer,queries:integer,reasons:array
NSDictionary *formsCalls(FormsWalker *walker, pid_t pid) {
    return @{@"pid": @(pid), @"label": formsLabel(1) ?: @"", @"clock": @(formsClock()),
             @"configured": @(formsConfigured), @"queries": @(walker->queries),
             @"elapsed": @(formsClock() - walker->start), @"level": @(walker.level),
             @"flag": @(walker->queries != 0), @"reasons": walker->reasons};
}

// NSNull on some path is nullable, never optional or any; two different types are still any.
// expect: formsNull => depth:integer:null,mixed:any,provider:object:null,tag:string:null,when:boolean:null
NSDictionary *formsNull(BOOL on, id status, FormsWalker *walker, NSString *tag) {
    id depth = on ? @([walker depth]) : NSNull.null;
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    r[@"depth"] = depth;
    r[@"mixed"] = on ? @1 : @"a";
    if ([status isKindOfClass:NSDictionary.class]) {
        r[@"provider"] = status;
    } else {
        r[@"provider"] = [NSNull null];
    }
    r[@"tag"] = tag ?: [NSNull null];
    r[@"when"] = on ? [NSNull null] : @YES;
    return r;
}

// Arrays by literal, `alloc`, `addObject:` and a typed local; an open object is an object.
// expect: formsArrays => failed:array,names:array,open:object,roots:array,sorted:array
NSDictionary *formsArrays(NSDictionary *entitlements, NSMutableSet *reasons) {
    NSMutableArray *failed = [[NSMutableArray alloc] init];
    id names = [NSMutableArray array];
    [names addObject:@"n"];
    NSArray *roots = @[@"a"];
    return @{@"failed": failed, @"names": names, @"roots": roots, @"open": entitlements ?: @{},
             @"sorted": [reasons.allObjects sortedArrayUsingSelector:@selector(compare:)]};
}

// An exception's name.
// expect: formsException => native_exception:string?,ok:boolean
NSDictionary *formsException(void) {
    NSMutableDictionary *r = [@{@"ok": @YES} mutableCopy];
    @try {
        formsClock();
    } @catch (NSException *exception) {
        r[@"native_exception"] = exception.name;
    }
    return r;
}

// A struct field read through the lookup.
// expect: formsStruct => enabled:boolean,x:number
NSDictionary *formsStruct(FormsPoint point) {
    return @{@"enabled": @(point.enabled), @"x": @(point.x)};
}

// `[v isKindOfClass:C.class]` types the value it guards, in an `if` and in a ternary.
// expect: formsGuard => ipv4:object,router:string?
NSDictionary *formsGuard(NSDictionary *service) {
    NSDictionary *ipv4 = [service[@"IPv4"] isKindOfClass:NSDictionary.class] ? service[@"IPv4"] : @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"ipv4"] = ipv4;
    if ([ipv4[@"Router"] isKindOfClass:NSString.class]) out[@"router"] = ipv4[@"Router"];
    return out;
}

// Foundation selectors, comparisons and arithmetic.
// expect: formsSelectors => alive:boolean,fresh:integer,ms:number,total:integer,when:number
NSDictionary *formsSelectors(NSNumber *n, NSDate *d, double age, int count) {
    return @{@"alive": @([n boolValue]), @"total": @([n unsignedLongLongValue]),
             @"when": @([d timeIntervalSince1970]), @"fresh": @(age >= 0 && age < 10),
             @"ms": @(count * 1000.0)};
}

// SDK property chains the sources do not declare: CoreLocation, NSDate, NSProcessInfo.
// expect: formsSdkChains => age:number,lat:number,simulated:boolean,up:number,when:number
NSDictionary *formsSdkChains(CLLocation *location) {
    return @{@"lat": @(location.coordinate.latitude),
             @"simulated": @(location.sourceInformation.isSimulatedBySoftware),
             @"age": @(MAX(0, -location.timestamp.timeIntervalSinceNow)),
             @"when": @(NSDate.date.timeIntervalSince1970),
             @"up": @(NSProcessInfo.processInfo.systemUptime)};
}

// A member chain ending in count, a CFIndex, a boxed C string, a block's declared result and a date formatter.
// expect: formsScalars => fresh:boolean,length:integer,path:string,seen:integer,stamp:string
NSDictionary *formsScalars(FormsWalker *walker, CFIndex length, const char *path, NSDate *date, NSDateFormatter *formatter) {
    BOOL (^fresh)(NSDate *) = ^BOOL(NSDate *d) { return YES; };
    return @{@"seen": @(walker->visited.count), @"length": @(length), @"path": @(path),
             @"fresh": @(fresh(date)), @"stamp": [formatter stringFromDate:date]};
}

// Receivers reached through `->`, a predicate filter and a `const` pointer declaration.
// expect: formsReceivers => filtered:array,prefix:string,sorted:array
NSDictionary *formsReceivers(FormsWalker *walker, NSDictionary *texts) {
    static NSString *const kPrefix = @"p";
    return @{@"sorted": [walker->reasons.allObjects sortedArrayUsingSelector:@selector(compare:)],
             @"filtered": [texts.allKeys filteredArrayUsingPredicate:walker->predicate], @"prefix": kPrefix};
}

// `array.firstObject[@"k"]` reads what the dictionaries added to the array carry; integer and number join as number.
// expect: formsElements => pixels:array,plus:number
NSDictionary *formsElements(double level) {
    NSMutableArray *displays = [NSMutableArray array];
    NSMutableArray *pixels = [NSMutableArray array];
    [displays addObject:@{@"pixels": pixels, @"plus": @(level)}];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"pixels"] = displays.firstObject[@"pixels"] ?: @[];
    result[@"plus"] = displays.firstObject[@"plus"] ?: @0;
    return result;
}

// Several declarators in one statement, the second after an initializer.
// expect: formsDeclarators => failed:array,ok:array
NSDictionary *formsDeclarators(void) {
    NSMutableArray *ok = [NSMutableArray array], *failed = [NSMutableArray array];
    return @{@"ok": ok, @"failed": failed};
}

// A wrapper that serializes the dictionary literal it is given.
// expect: formsWrapped => source:string,verified:boolean
char *formsWrapped(void) {
    return launchJSON(@{@"verified": @YES, @"source": @"runningboard"});
}

// A boxed C comparison or logical expression is an `int`; only BOOL values and YES/NO literals are boolean.
// expect: formsBoxedC => and:integer,eq:integer,ge:integer,lt:integer,ne:integer,not:integer,or:integer,real:boolean,yes:boolean
NSDictionary *formsBoxedC(int a, int b) {
    BOOL real = a > b;
    return @{@"eq": @(a == b), @"ne": @(a != b), @"lt": @(a < b), @"ge": @(a >= b), @"and": @(a && b),
             @"or": @(a || b), @"not": @(!a), @"real": @(real), @"yes": @YES};
}
