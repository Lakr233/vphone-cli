#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <assert.h>
static NSMutableArray *events;
static int allocations,failAllocation;
static BOOL missingSymbols;
static void *fakeCreate(CFAllocatorRef allocator) { (void)allocator; return (void *)1; }
static void *fakeKeyboard(CFAllocatorRef allocator,uint64_t timestamp,uint32_t page,uint32_t usage,boolean_t down,uint32_t options) {
    (void)allocator;(void)options;
    if(++allocations==failAllocation)return NULL;
    return (void *)CFBridgingRetain([@{@"time":@(timestamp),@"page":@(page),@"usage":@(usage),@"down":@(down)} mutableCopy]);
}
static void fakeInteger(void *event,uint32_t field,CFIndex value) {
    ((__bridge NSMutableDictionary *)event)[@(field)]=@(value);
}
static void fakeSender(void *event,uint64_t sender) { ((__bridge NSMutableDictionary *)event)[@"sender"]=@(sender); }
static void fakeDispatch(void *client,void *event) { assert(client==(void *)1);[events addObject:[(__bridge NSDictionary *)event copy]]; }
static void *fakeOpen(const char *path,int mode) { (void)path;(void)mode;return (void *)1; }
static void *fakeSymbol(void *library,const char *name) {
    (void)library;if(missingSymbols)return NULL;
    if(!strcmp(name,"IOHIDEventSystemClientCreate"))return fakeCreate;
    if(!strcmp(name,"IOHIDEventCreateKeyboardEvent"))return fakeKeyboard;
    if(!strcmp(name,"IOHIDEventSetIntegerValue"))return fakeInteger;
    if(!strcmp(name,"IOHIDEventSetSenderID"))return fakeSender;
    if(!strcmp(name,"IOHIDEventSystemClientDispatchEvent"))return fakeDispatch;
    abort();
}
#define dlopen fakeOpen
#define dlsym fakeSymbol
#include "../vphoned-darwinos/VPhoneDarwinHID.m"
#undef dlopen
#undef dlsym
static void reset(void) { [events removeAllObjects];allocations=0;failAllocation=0; }
int main(int argc,char **argv) { @autoreleasepool {
    (void)argv;events=[NSMutableArray new];missingSymbols=argc>1;
    char *error=NULL;
    if(missingSymbols) {
        assert(!vp_darwin_hid_available());assert(!vp_darwin_hid_submit(12,64,-1,false,&error));
        assert(error && events.count==0);free(error);puts("Missing-symbol path fails without dispatch");return 0;
    }
    assert(vp_darwin_hid_available());
    assert(vp_darwin_hid_submit(12,64,-1,false,&error) && !error && events.count==2);
    assert([events[0][@"down"] boolValue] && ![events[1][@"down"] boolValue]);
    assert([events[1][@"time"] unsignedLongLongValue]-[events[0][@"time"] unsignedLongLongValue]>=gPressTicks);
    assert([events[0][@4] intValue]==1 && [events[0][@"sender"] unsignedLongLongValue]==0x8000000817319372);
    reset();assert(vp_darwin_hid_submit(12,64,1,true,&error));assert(events.count==1 && [events[0][@((3u<<16)|5u)] intValue]==1);
    reset();assert(!vp_darwin_hid_submit(12,64,2,false,&error));free(error);error=NULL;assert(events.count==0);
    assert(!vp_darwin_hid_submit(12,64,-1,true,&error));free(error);error=NULL;assert(events.count==0);
    reset();failAllocation=1;assert(!vp_darwin_hid_submit(12,64,-1,false,&error));free(error);error=NULL;assert(events.count==0);
    reset();failAllocation=2;assert(!vp_darwin_hid_submit(12,64,-1,false,&error));free(error);error=NULL;assert(events.count==0);
    reset();assert(vp_darwin_hid_submit(12,64,0,false,&error));assert(events.count==1 && ![events[0][@"down"] boolValue]);
    puts("HID mock tests passed: timing, metadata, explicit transitions, malformed action, allocation atomicity");
    return 0;
}}
