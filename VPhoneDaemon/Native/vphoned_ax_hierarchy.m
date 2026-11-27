#import "vphoned_ax_hierarchy.h"
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <math.h>
#import <time.h>

// These private iOS attribute numbers are NOT macOS AX string attributes.
// Primary mapping: witchan/ios-mcp, commit 8f46b68, MCPAXNodeSource.m.
// Only 5001 supplies immediate children; visible/explorer arrays are never roots.
static double milliseconds(void) {
 struct timespec value; clock_gettime(CLOCK_MONOTONIC,&value);
 return value.tv_sec*1000.0+value.tv_nsec/1e6;
}
@interface VPAxWalker : NSObject {
@public
 VPAxFunctions f;
 int maxElements,maxDepth,maxQueries,timeoutMS,queries,verified,mismatch,unavailable;
 double start;
 CFMutableDictionaryRef seenMap;
 NSUInteger seenCount;
 NSMutableSet *active,*reasons;
 BOOL incomplete,switchesEnabled,retryAttempted,retryResolved;
 double readinessWait;
 NSArray *initialReadinessErrors;
}
- (NSDictionary *)node:(CFTypeRef)element parent:(CFTypeRef)parent depth:(int)depth path:(NSArray *)path;
@end
@implementation VPAxWalker
- (void)dealloc {
 if(seenMap) { CFRelease(seenMap); seenMap=NULL; }
}
- (BOOL)budget {
 if(queries>=maxQueries) {[reasons addObject:@"max_queries"];return NO;}
 if(milliseconds()-start>=timeoutMS) {[reasons addObject:@"timeout"];return NO;}
 return YES;
}
- (id)attribute:(uint32_t)attribute element:(CFTypeRef)element errors:(NSMutableArray *)errors {
 if(![self budget]) return nil;
 double remaining=timeoutMS-(milliseconds()-start);
 int timeoutError=f.setTimeout?f.setTimeout(element,(float)(MIN(100.0,remaining)/1000.0)):-25208;
 if(timeoutError) {
  [errors addObject:@{@"attribute":@(attribute),@"error_code":@(timeoutError),@"value_present":@NO,@"timeout_configuration_failed":@YES}];
  incomplete=YES; return nil;
 }
 CFTypeRef value=NULL; ++queries;
 int error=f.copy(element,(CFStringRef)(uintptr_t)attribute,&value);
 if(error || !value) {
  [errors addObject:@{@"attribute":@(attribute),@"error_code":@(error),@"value_present":@(value!=NULL)}];
  if(value) CFRelease(value);
  return nil;
 }
 return CFBridgingRelease(value);
}
// Only a newly enabled AX invocation may wait for the first root query to become ready.
// Historical failures remain separate after resolution; child-query failures never retry.
- (id)rootLabel:(CFTypeRef)element errors:(NSMutableArray *)errors {
 id value=[self attribute:2001 element:element errors:errors];
 NSDictionary *initial=errors.lastObject;
 if(value || !switchesEnabled || queries!=1 || [initial[@"attribute"] intValue]!=2001 ||
    [initial[@"error_code"] intValue]!=-25215 || [initial[@"value_present"] boolValue] ||
    [initial[@"timeout_configuration_failed"] boolValue]) return value;
 initialReadinessErrors=@[initial];
 // Reserve time for the retry. Waiting must not reset the walk's global deadline.
 if(![self budget] || timeoutMS-(milliseconds()-start)<=400.0) return nil;
 double waitStart=milliseconds();
 struct timespec delay={.tv_sec=0,.tv_nsec=400000000};nanosleep(&delay,NULL);
 readinessWait=milliseconds()-waitStart;
 if(![self budget]) return nil;
 int before=queries;
 value=[self attribute:2001 element:element errors:errors];
 retryAttempted=queries>before;retryResolved=value!=nil;
 if(retryResolved) [errors removeObject:initial];
 return value;
}
- (NSString *)text:(id)value {
 if(!value || CFGetTypeID((__bridge CFTypeRef)value)!=CFStringGetTypeID())return @"";
 NSString *string=value;
 return string.length>1024?[string substringToIndex:1024]:string;
}
- (id)frame:(id)value {
 if(!value || !f.valueTypeID || !f.getValue || CFGetTypeID((__bridge CFTypeRef)value)!=f.valueTypeID()) return NSNull.null;
 CGRect rect;
 if(!f.getValue((__bridge CFTypeRef)value,3,&rect) || !isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
   !isfinite(rect.size.width) || !isfinite(rect.size.height)) return NSNull.null;
 return @{@"x":@(rect.origin.x),@"y":@(rect.origin.y),@"width":@(rect.size.width),@"height":@(rect.size.height)};
}
- (id)parentProof:(CFTypeRef)element parent:(CFTypeRef)parent errors:(NSMutableArray *)errors {
 if(!parent)return NSNull.null;
 id actual=[self attribute:5002 element:element errors:errors];
 if(!actual || CFGetTypeID((__bridge CFTypeRef)actual)!=f.elementTypeID()) {++unavailable;incomplete=YES;return @NO;}
 BOOL matches=CFEqual((__bridge CFTypeRef)actual,parent);
 if(matches) ++verified; else {++mismatch;incomplete=YES;}
 return @(matches);
}
- (NSDictionary *)node:(CFTypeRef)element parent:(CFTypeRef)parent depth:(int)depth path:(NSArray *)path {
 if(![self budget]) return nil;
 const void *existingValue=NULL;
 if(CFDictionaryGetValueIfPresent(seenMap,element,&existingValue)) {
  NSUInteger existing=(NSUInteger)(uintptr_t)existingValue;
  NSMutableArray *errors=[NSMutableArray array];
  id proof=[self parentProof:element parent:parent errors:errors];
  NSString *reference=[NSString stringWithFormat:@"ax-%lu",(unsigned long)existing];
  BOOL cycle=[active containsObject:reference]; if(cycle) incomplete=YES;
  return @{@"ref":reference,@"path":path,@"cycle":@(cycle),@"parent_verified":proof,@"query_errors":errors.copy};
 }
 if(seenCount>=(NSUInteger)maxElements) {[reasons addObject:@"max_elements"];return nil;}
 NSUInteger index=seenCount++;
 NSString *identity=[NSString stringWithFormat:@"ax-%lu",(unsigned long)index];
 CFDictionarySetValue(seenMap,element,(const void *)(uintptr_t)index);
 [active addObject:identity];
 NSMutableArray *errors=[NSMutableArray array];
 id proof=[self parentProof:element parent:parent errors:errors];
 NSString *label=[self text:depth==0?[self rootLabel:element errors:errors]:[self attribute:2001 element:element errors:errors]];
 NSString *identifier=[self text:[self attribute:5019 element:element errors:errors]];
 id type=[self attribute:5003 element:element errors:errors];
 NSString *role=[self text:type];
 id frame=[self frame:[self attribute:2003 element:element errors:errors]];
 id raw=[self attribute:5001 element:element errors:errors];
 NSMutableArray *children=[NSMutableArray array];
 NSString *status=@"complete";
 if(!raw || CFGetTypeID((__bridge CFTypeRef)raw)!=CFArrayGetTypeID()) {status=@"unavailable";incomplete=YES;
  if(raw) [errors addObject:@{@"attribute":@5001,@"error_code":@0,@"value_present":@YES,@"invalid_type":@YES}];}
 else {
  CFArrayRef array=(__bridge CFArrayRef)raw;
  CFIndex count=CFArrayGetCount(array);
  if(depth>=maxDepth && count) {[reasons addObject:@"max_depth"];status=@"truncated";}
  else for(CFIndex i=0;i<count;++i) {
   if(![self budget]) {status=@"truncated";break;}
   CFTypeRef child=CFArrayGetValueAtIndex(array,i);
   if(!child || CFGetTypeID(child)!=f.elementTypeID()) {status=@"unavailable";incomplete=YES;
    [errors addObject:@{@"attribute":@5001,@"error_code":@0,@"value_present":@(child!=NULL),@"invalid_child_type":@YES}];continue;}
   NSDictionary *node=[self node:child parent:element depth:depth+1 path:[path arrayByAddingObject:@(i)]];
   if(!node) {status=@"truncated";break;}
   [children addObject:node];
  }
 }
 if(![self budget] && [status isEqual:@"unavailable"]) status=@"truncated";
 [active removeObject:identity];
 return @{@"id":identity,@"path":path,@"label":label,@"identifier":identifier,@"role":role,@"frame":frame,
   @"children":children.copy,@"children_status":status,@"query_errors":errors.copy,@"parent_verified":proof,@"depth":@(depth)};
}
@end

NSDictionary *vp_ax_walk(VPAxFunctions functions, CFTypeRef root, pid_t pid, int elements, int depth, int duration) {
 return vp_ax_walk_with_readiness(functions,root,pid,elements,depth,duration,NO);
}
NSDictionary *vp_ax_walk_with_readiness(VPAxFunctions functions, CFTypeRef root, pid_t pid, int elements, int depth, int duration, BOOL switchesEnabled) {
 VPAxWalker *walker=[VPAxWalker new];walker->f=functions;walker->switchesEnabled=switchesEnabled;
 walker->maxElements=MAX(1,MIN(elements,2000));walker->maxDepth=MAX(0,MIN(depth,32));
 walker->timeoutMS=MAX(100,MIN(duration,10000));walker->maxQueries=walker->maxElements*8;
 walker->seenMap=CFDictionaryCreateMutable(kCFAllocatorDefault,0,&kCFTypeDictionaryKeyCallBacks,NULL);
 walker->seenCount=0;walker->active=[NSMutableSet set];walker->reasons=[NSMutableSet set];walker->start=milliseconds();
 NSDictionary *node=root && functions.copy && functions.elementTypeID && walker->seenMap?[walker node:root parent:NULL depth:0 path:@[]]:nil;
 BOOL truncated=walker->reasons.count>0;
 NSString *status=!node?@"unavailable":truncated || walker->incomplete?@"partial":@"complete";
 return @{@"source":@"ax",@"format":@"nested",@"relationship_source":@"AXUIElementCopyAttributeValue:5001",
  @"pid":@(pid),@"roots":node?@[node]:@[],@"count":@(walker->seenCount),@"status":status,
  @"truncated":@(truncated),@"truncation_reasons":[walker->reasons.allObjects sortedArrayUsingSelector:@selector(compare:)],
  @"limits":@{@"max_elements":@(walker->maxElements),@"max_depth":@(walker->maxDepth),@"max_queries":@(walker->maxQueries),@"timeout_ms":@(walker->timeoutMS)},
  @"queries":@(walker->queries),@"elapsed_ms":@(milliseconds()-walker->start),
  @"readiness":@{@"switches_enabled_for_invocation":@(switchesEnabled),@"retry_attempted":@(walker->retryAttempted),
   @"retry_resolved":@(walker->retryResolved),@"wait_ms":@(walker->readinessWait),@"max_wait_ms":@400,
   @"initial_query_errors":walker->initialReadinessErrors?:@[]},
  @"parent_checks":@{@"verified":@(walker->verified),@"mismatch":@(walker->mismatch),@"unavailable":@(walker->unavailable)}};
}
VPAxFunctions vp_ax_load_functions(void) {
 void *ax=dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",RTLD_NOW);
 VPAxFunctions f={0};
#define LOAD(M,N) f.M=(typeof(f.M))(ax?dlsym(ax,N):NULL)
 LOAD(createApp,"_AXUIElementCreateAppElementWithPid");LOAD(copy,"AXUIElementCopyAttributeValue");
 LOAD(setTimeout,"AXUIElementSetMessagingTimeout");LOAD(elementTypeID,"AXUIElementGetTypeID");
 LOAD(valueTypeID,"AXValueGetTypeID");LOAD(getValue,"AXValueGetValue");
#undef LOAD
 return f;
}
// The one place AX is switched on for an invocation and restored afterwards.
NSDictionary *vp_ax_with_enabled(void (^body)(BOOL enabledForInvocation)) {
 void *library=dlopen("/usr/lib/libAccessibility.dylib",RTLD_NOW);
 Boolean (*appEnabled)(void)=library?dlsym(library,"_AXSApplicationAccessibilityEnabled"):NULL;
 void (*setApp)(Boolean)=library?dlsym(library,"_AXSApplicationAccessibilitySetEnabled"):NULL;
 Boolean (*autoEnabled)(void)=library?dlsym(library,"_AXSAutomationEnabled"):NULL;
 void (*setAuto)(Boolean)=library?dlsym(library,"_AXSSetAutomationEnabled"):NULL;
 void (*client)(uint32_t)=dlsym(RTLD_DEFAULT,"__AXSetRequestingClient");
 uint64_t (*override)(uint64_t)=dlsym(RTLD_DEFAULT,"_AXOverrideRequestingClientType");
 if(client) client(2); if(override) override(2);
 BOOL beforeApp=appEnabled?appEnabled():NO,beforeAuto=autoEnabled?autoEnabled():NO;
 BOOL changedApp=appEnabled && setApp && !beforeApp, changedAuto=autoEnabled && setAuto && !beforeAuto;
 @try {
  if(changedApp) setApp(true); if(changedAuto) setAuto(true);
  BOOL enabledForInvocation=(changedApp && appEnabled()) || (changedAuto && autoEnabled());
  body(enabledForInvocation);
 } @finally {
  if(changedAuto)setAuto(false);if(changedApp)setApp(false);
 }
 return @{@"requesting_client":@(client!=NULL),@"requesting_client_override":@(override!=NULL),
  @"switches_before":@{@"application":appEnabled?@(beforeApp):NSNull.null,@"automation":autoEnabled?@(beforeAuto):NSNull.null},
  @"switches_after_restore":@{@"application":appEnabled?@(appEnabled()):NSNull.null,@"automation":autoEnabled?@(autoEnabled()):NSNull.null}};
}
NSDictionary *vp_ax_hierarchy(int pid,int maxElements,int maxDepth,int timeoutMS) {
 VPAxFunctions f=vp_ax_load_functions();
 CFTypeRef root=f.createApp && pid>1?f.createApp(pid):NULL;
 __block NSDictionary *result=nil;
 NSDictionary *switches=vp_ax_with_enabled(^(BOOL enabledForInvocation) {
  @try {
   result=vp_ax_walk_with_readiness(f,root,pid,maxElements,maxDepth,timeoutMS,enabledForInvocation);
  } @catch(NSException *exception) {
   NSMutableDictionary *failure=[vp_ax_walk(f,NULL,pid,maxElements,maxDepth,timeoutMS) mutableCopy];
   failure[@"native_exception"]=exception.name; result=failure.copy;
  }
 });
 NSMutableDictionary *report=[result mutableCopy];
 report[@"symbols"]=@{@"create_application":@(f.createApp!=NULL),@"copy_attribute":@(f.copy!=NULL),
  @"set_timeout":@(f.setTimeout!=NULL),@"element_type_id":@(f.elementTypeID!=NULL),
  @"requesting_client":switches[@"requesting_client"],@"requesting_client_override":switches[@"requesting_client_override"]};
 NSDictionary *before=switches[@"switches_before"],*after=switches[@"switches_after_restore"];
 report[@"switches_before"]=before;
 report[@"switches_after_restore"]=after;
 result=report.copy;
 if(root) CFRelease(root);
 return result;
}
