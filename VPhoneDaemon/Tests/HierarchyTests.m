#import <Foundation/Foundation.h>
#import <unistd.h>
#import <CoreGraphics/CoreGraphics.h>
#import <assert.h>
#import <math.h>
#import "../Native/vphoned_ax_hierarchy.h"

// Injected AX functions exercise the walker on macOS without a guest or private AX symbols.
// VP_HIERARCHY_RECEIPTS, when set by the runner, checks JSON output in its temporary directory.
static int calls;
static int mode;
static int rootLabels;
static NSDictionary *coldWalk(VPAxFunctions f, BOOL enabled, int elements, int duration) {
 calls=0;rootLabels=0;
 return vp_ax_walk_with_readiness(f,(__bridge CFTypeRef)@"A",42,elements,8,duration,enabled);
}
static void receipt(NSString *name, NSDictionary *report) {
 NSString *directory=NSProcessInfo.processInfo.environment[@"VP_HIERARCHY_RECEIPTS"];
 if(!directory)return;
 NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
 assert(data && [data writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".json"]] atomically:YES]);
}
static int copyAttr(CFTypeRef element, CFStringRef attr, CFTypeRef *out) {
    ++calls; if(mode==6) usleep(120000);
    NSString *key=(__bridge NSString *)element;
    unsigned long code=(uintptr_t)attr;
    id result=nil;
    if(code==2001 && [key isEqual:@"A"]) ++rootLabels;
    if(((mode>=9 && mode<=11) || mode==17) && rootLabels<2) return mode==11?-25212:-25215;
    if(mode==10) return -25215;
    if(mode==12 && code==2001 && [key isEqual:@"B"]) return -25215;
    if(mode==13 && calls==1) {usleep(750000);return -25215;}
    if(mode==14 && calls==1) return -25215;
    if(code==2003 && ((mode>=18 && mode<=20) || (mode==21 && [key isEqual:@"B"]))) result=[NSData data];
    else if(code==5001) {
      if((mode==7 || mode==14) && [key isEqual:@"A"]) { *out=CFBridgingRetain([NSArray arrayWithObjects:@"B",@"B",@"B",@"B",@"B",@"B",@"B",@"B",@"B",@"B",@"B",@"B",@"B",@"B",@"B",@"B",@"B",nil]);return 0;}
      if((mode==7 || mode==14) && [key isEqual:@"B"]) {*out=CFBridgingRetain(@[]);return 0;}
      if(mode==2) return -25212;
      if(mode==3) { *out=CFBridgingRetain(@"not array");return 0;}
      if(mode==4 && [key isEqual:@"C"]) result=@[@"D"];
      else if(mode==1 && [key isEqual:@"B"]) result=@[@"A"];
      else if([key isEqual:@"A"]) result=@[@"B",@"C"];
      else if([key isEqual:@"B"]) result=@[@"D"];
      else result=@[];
    } else if(code==5002 && mode==5) return -25212;
    else if(code==5002 && ![key isEqual:@"A"]) result=[key isEqual:@"D"]?@"B":@"A";
    else if(code==2001) result=mode==21 && [key isEqual:@"B"]?@"":@"same label";
    else return -25212;
    *out=CFBridgingRetain(result);return 0;
}
static CFTypeID typeID(void) {return CFStringGetTypeID();}
static Boolean frameValue(CFTypeRef value,int kind,void *out) {
 (void)value;assert(kind==3);
 if(mode==20)return false;
 if(mode==21) {*(CGRect *)out=CGRectMake(-250,-30,0,0);return true;}
 *(CGRect *)out=CGRectMake(mode==19?NAN:10,20,30,40);return true;
}
static int timeout(CFTypeRef a,float t) {(void)a;(void)t;return mode==8?-25204:mode==15?-25215:mode==17 && rootLabels==1?-25204:0;}
int main(void) {@autoreleasepool {
 VPAxFunctions f={.copy=copyAttr,.elementTypeID=typeID,.setTimeout=timeout};
 NSDictionary *r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,20,8,1000);
 assert([r[@"count"] intValue]==4);assert(![r[@"truncated"] boolValue]);
 assert(![r[@"readiness"][@"switches_enabled_for_invocation"] boolValue]);
 assert(![r[@"readiness"][@"retry_attempted"] boolValue]);
 assert(![r[@"readiness"][@"retry_resolved"] boolValue]);
 assert([r[@"readiness"][@"initial_query_errors"] count]==0);
 assert([r[@"readiness"][@"wait_ms"] doubleValue]==0);
 assert([r[@"parent_checks"][@"verified"] intValue]==3);
 NSDictionary *root=r[@"roots"][0];assert(root[@"frame"]==NSNull.null);
 assert([root[@"children"] count]==2);assert([root[@"children"][0][@"children"] count]==1);
 // Every nested node carries its child-index path from the root.
 assert([root[@"path"] isEqual:@[]]);
 assert([root[@"children"][0][@"path"] isEqual:@[@0]]);
 assert(([root[@"children"][0][@"children"][0][@"path"] isEqual:@[@0,@0]]));
 assert([root[@"children"][1][@"path"] isEqual:@[@1]]);
 r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,2,8,1000);
 assert([r[@"count"] intValue]==2);assert([r[@"truncated"] boolValue]);
 r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,20,0,1000);
 assert([r[@"count"] intValue]==1);assert([r[@"truncated"] boolValue]);
 mode=1; r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,20,8,1000);
 assert([r[@"count"] intValue]==3);assert([r[@"roots"][0][@"children"][0][@"children"][0][@"cycle"] boolValue]);
 mode=2;r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,20,8,1000);
 assert([r[@"status"] isEqual:@"partial"]);assert([r[@"roots"][0][@"children_status"] isEqual:@"unavailable"]);
 mode=3;r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,20,8,1000);
 assert([r[@"roots"][0][@"query_errors"] lastObject][@"invalid_type"]);
 mode=4;r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,20,8,1000);
 assert([r[@"parent_checks"][@"mismatch"] intValue]==1);
 assert(![r[@"roots"][0][@"children"][1][@"children"][0][@"cycle"] boolValue]);
 mode=5;r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,20,8,1000);
 assert([r[@"parent_checks"][@"unavailable"] intValue]==3);
 mode=6;r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,20,8,100);
 assert([r[@"truncation_reasons"] containsObject:@"timeout"]);assert([r[@"queries"] intValue]==1);
 mode=0;r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,1,8,1000);
 assert([r[@"queries"] intValue]<=8);
 mode=7;r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,2,8,1000);
 assert([r[@"truncation_reasons"] containsObject:@"max_queries"]);assert([r[@"queries"] intValue]==16);
 mode=8;calls=0;r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,20,8,1000);
 assert(calls==0);assert([r[@"queries"] intValue]==0);assert([r[@"status"] isEqual:@"partial"]);
 f.setTimeout=NULL;mode=0;calls=0;r=vp_ax_walk(f,(__bridge CFTypeRef)@"A",42,20,8,1000);
 assert(calls==0);assert([r[@"queries"] intValue]==0);
 r=vp_ax_hierarchy(0,20,8,1000);assert([r[@"status"] isEqual:@"unavailable"]);
 f.setTimeout=timeout;
 mode=9;r=coldWalk(f,YES,20,1000);
 receipt(@"recovered-cold-root",r);
 assert([r[@"count"] intValue]==4); // Cold root must be retried before its children query.
 assert(rootLabels==2);assert([r[@"readiness"][@"retry_attempted"] boolValue]);
 assert([r[@"readiness"][@"retry_resolved"] boolValue]);
 assert([r[@"readiness"][@"initial_query_errors"] count]==1);
 assert([r[@"readiness"][@"initial_query_errors"][0][@"error_code"] intValue]==-25215);
 assert([r[@"roots"][0][@"query_errors"] count]==3);
 assert([r[@"roots"][0][@"children_status"] isEqual:@"complete"]);
 assert([r[@"status"] isEqual:@"complete"]);
 assert([r[@"elapsed_ms"] doubleValue]>=390 && [r[@"elapsed_ms"] doubleValue]<1000);
 assert([r[@"readiness"][@"wait_ms"] doubleValue]>=390 && [r[@"readiness"][@"wait_ms"] doubleValue]<500);
 assert([r[@"queries"] intValue]==calls && calls==24);
 mode=9;r=coldWalk(f,NO,20,1000);receipt(@"disabled-retry",r);
 assert(rootLabels==1);assert(![r[@"readiness"][@"retry_attempted"] boolValue]);
 assert([r[@"roots"][0][@"children_status"] isEqual:@"unavailable"]);
 assert([r[@"roots"][0][@"query_errors"] count]==5);
 mode=11;r=coldWalk(f,YES,20,1000);
 assert(rootLabels==1);assert(![r[@"readiness"][@"retry_attempted"] boolValue]);
 mode=0;r=coldWalk(f,YES,20,1000);
 assert(rootLabels==1);assert(![r[@"readiness"][@"retry_attempted"] boolValue]);
 mode=12;r=coldWalk(f,YES,20,1000);
 assert(rootLabels==1);assert(![r[@"readiness"][@"retry_attempted"] boolValue]);
 mode=9;r=coldWalk(f,YES,20,100);receipt(@"insufficient-budget",r);
 assert(rootLabels==1);assert(![r[@"readiness"][@"retry_attempted"] boolValue]);
 assert([r[@"readiness"][@"wait_ms"] doubleValue]==0);
 assert([r[@"roots"][0][@"query_errors"] count]==5);
 mode=13;r=coldWalk(f,YES,20,1000);
 assert(rootLabels==1);assert(![r[@"readiness"][@"retry_attempted"] boolValue]);
 assert([r[@"elapsed_ms"] doubleValue]<1000);
 mode=10;r=coldWalk(f,YES,20,1000);receipt(@"failed-retry",r);
 assert(rootLabels==2);assert([r[@"readiness"][@"retry_attempted"] boolValue]);
 assert(![r[@"readiness"][@"retry_resolved"] boolValue]);
 assert([r[@"status"] isEqual:@"partial"]);
 assert([r[@"roots"][0][@"children_status"] isEqual:@"unavailable"]);
 assert([r[@"roots"][0][@"query_errors"] count]==6);
 assert([r[@"roots"][0][@"query_errors"] lastObject][@"attribute"]);
 assert([[r[@"roots"][0][@"query_errors"] lastObject][@"attribute"] intValue]==5001);
 assert([[r[@"roots"][0][@"query_errors"] lastObject][@"error_code"] intValue]==-25215);
 mode=14;r=coldWalk(f,YES,2,1000);receipt(@"shared-query-budget",r);
 assert([r[@"queries"] intValue]==16 && calls==16);
 assert([r[@"truncation_reasons"] containsObject:@"max_queries"]);
 mode=15;r=coldWalk(f,YES,20,1000);
 assert(calls==0);assert(![r[@"readiness"][@"retry_attempted"] boolValue]);
 mode=17;r=coldWalk(f,YES,20,1000);receipt(@"retry-timeout-configuration-failed",r);
 assert(calls==1);assert(![r[@"readiness"][@"retry_resolved"] boolValue]);
 assert([r[@"roots"][0][@"children_status"] isEqual:@"unavailable"]);
 f.valueTypeID=CFDataGetTypeID;f.getValue=frameValue;
 mode=18;r=coldWalk(f,YES,20,1000);
 assert([r[@"roots"][0][@"frame"][@"x"] intValue]==10);
 assert([r[@"roots"][0][@"frame"][@"height"] intValue]==40);
 mode=19;r=coldWalk(f,YES,20,1000);assert(r[@"roots"][0][@"frame"]==NSNull.null);
 mode=20;r=coldWalk(f,YES,20,1000);assert(r[@"roots"][0][@"frame"]==NSNull.null);
 // An unnamed, offscreen, zero-size structural node must retain its descendants.
 mode=21;r=coldWalk(f,YES,20,1000);
 assert([r[@"count"] intValue]==4);assert([r[@"status"] isEqual:@"complete"]);
 assert([r[@"roots"][0][@"children"] count]==2);
 NSDictionary *structural=r[@"roots"][0][@"children"][0];
 assert([structural[@"label"] isEqual:@""]);
 assert([structural[@"children"] count]==1);
 assert([structural[@"children_status"] isEqual:@"complete"]);
 assert(([structural[@"frame"] isEqual:@{@"x":@-250,@"y":@-30,@"width":@0,@"height":@0}]));
 receipt(@"unnamed-offscreen-structural-node",r);
 puts("hierarchy tests passed, including cold readiness guards");
}}
