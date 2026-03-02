#import "vphoned_protocol.h"
#include <unistd.h>

BOOL vp_read_fully(int fd, void *buf, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        ssize_t n = read(fd, (uint8_t *)buf + offset, count - offset);
        if (n <= 0) return NO;
        offset += n;
    }
    return YES;
}

BOOL vp_write_fully(int fd, const void *buf, size_t count) {
    size_t offset = 0;
    while (offset < count) {
        ssize_t n = write(fd, (const uint8_t *)buf + offset, count - offset);
        if (n <= 0) return NO;
        offset += n;
    }
    return YES;
}

void vp_drain(int fd, size_t size) {
    uint8_t buf[32768];
    size_t remaining = size;
    while (remaining > 0) {
        size_t chunk = remaining < sizeof(buf) ? remaining : sizeof(buf);
        if (!vp_read_fully(fd, buf, chunk)) break;
        remaining -= chunk;
    }
}

NSDictionary *vp_read_message(int fd) {
    uint32_t header = 0;
    if (!vp_read_fully(fd, &header, 4)) return nil;
    uint32_t length = ntohl(header);
    if (length == 0 || length > 4 * 1024 * 1024) return nil;

    NSMutableData *payload = [NSMutableData dataWithLength:length];
    if (!vp_read_fully(fd, payload.mutableBytes, length)) return nil;

    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:payload options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    return obj;
}

BOOL vp_write_message(int fd, NSDictionary *dict) {
    NSError *err = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&err];
    if (!json) return NO;

    uint32_t header = htonl((uint32_t)json.length);
    if (!vp_write_fully(fd, &header, 4)) return NO;
    if (!vp_write_fully(fd, json.bytes, json.length)) return NO;
    return YES;
}

NSMutableDictionary *vp_make_response(NSString *type, id reqId) {
    NSMutableDictionary *r = [@{@"v": @PROTOCOL_VERSION, @"t": type} mutableCopy];
    if (reqId) r[@"id"] = reqId;
    return r;
}
