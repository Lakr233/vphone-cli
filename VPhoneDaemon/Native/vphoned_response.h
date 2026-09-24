#pragma once
#import <Foundation/Foundation.h>

static inline NSMutableDictionary *vp_make_response(NSString *type, id reqId) {
    NSMutableDictionary *response = [@{@"t": type} mutableCopy];
    if (reqId) response[@"id"] = reqId;
    return response;
}
