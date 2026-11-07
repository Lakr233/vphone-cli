// Fixture for NativeExtractor rules 6-9. Parsed only, never compiled.
// Each `expect:` line is `<function>[@writer] => <catalog result cell>`.

// vp_gyro_get shape, copied from VPhoneDaemon/Native/vphoned_gyro.m with the
// Encode literal from VPhoneGuestComponents/Gyroscope/VPhoneGyroscopeState.h.
static inline NSDictionary *VPhoneGyroscopeEncode(VPhoneGyroscopeState state) {
    return @{@"enabled": @(state.enabled), @"x": @(state.x), @"y": @(state.y), @"z": @(state.z)};
}

// expect: vp_gyro_get => enabled:any,provider:any,provider_running:any,units:string,x:any,y:any,z:any
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

// expect: vpApplyExternalRequest@writer => enabled:any,error:any?,height:integer,name:string?,nonce:string,ok:boolean?,width:integer
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
// expect: vpExternalDiagnostics => enabled:any,error:any?,height:integer?,name:string?,nonce:string?,ok:boolean?,width:integer?
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
// expect: nativeTypes => array:array,cast:integer,count:integer,dict:object,external:any,float:number,fmt:string,int:integer,label:string,mixed:any,no:boolean,nullable:any,on:boolean,ratio:number,text:string,wrapped:any,yes:boolean
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
