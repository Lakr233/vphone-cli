#import "vphoned_ax_element.h"
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <math.h>
#import <time.h>

// MARK: - Pinned private ids
// Private iOS AXRuntime numbers, confirmed live (Research/vphoned_http_api.md, AX attribute and
// action ids). No id appears elsewhere in this file.
enum {
 kAttributeLabel=2001,kAttributeFrame=2003,kAttributeTraits=2004,kAttributeValue=2006,
 kAttributeFocused=2018,kAttributeChildren=5001,kAttributeRole=5003,kAttributeIdentifier=5019,
 kActionActivate=2010,
 kTraitNotEnabled=0x100,kMessagingTimeoutMS=5000,kMaxElements=2000,kMaxDepth=32,kRetryWaitMS=400,
 kNotReadyError=-25215
};
static NSString *const kAssistiveTech=@"UIAccessibilityNotificationVoiceOverIdentifier";

// MARK: - Action names
static NSDictionary<NSString *,NSNumber *> *actionTable(void) {
 return @{@"activate":@(kActionActivate)};
}

// MARK: - Errors
static NSDictionary *failure(NSString *code, NSString *message) {
 return @{@"error":code,@"message":message};
}

// MARK: - Element reads
@interface VPAxReader : NSObject {
@public
 VPAxElementFunctions f;
}
@end
@implementation VPAxReader
- (int)read:(uint32_t)attribute element:(CFTypeRef)element into:(id *)out {
 if(f.ax.setTimeout) f.ax.setTimeout(element,kMessagingTimeoutMS/1000.0f);
 CFTypeRef value=NULL;
 int error=f.ax.copy(element,(CFStringRef)(uintptr_t)attribute,&value);
 if(error || !value) {if(value) CFRelease(value);*out=nil;return error?error:-1;}
 *out=CFBridgingRelease(value);return 0;
}
- (id)get:(uint32_t)attribute element:(CFTypeRef)element {
 id value=nil;[self read:attribute element:element into:&value];return value;
}
- (NSString *)text:(uint32_t)attribute element:(CFTypeRef)element {
 id value=[self get:attribute element:element];
 if([value isKindOfClass:NSString.class]) return value;
 if([value isKindOfClass:NSNumber.class]) return [value stringValue];
 return @"";
}
- (NSArray *)children:(CFTypeRef)element {
 id raw=[self get:kAttributeChildren element:element];
 if(!raw || CFGetTypeID((__bridge CFTypeRef)raw)!=CFArrayGetTypeID()) return nil;
 NSMutableArray *kids=[NSMutableArray array];
 for(id child in (NSArray *)raw) {
  if(CFGetTypeID((__bridge CFTypeRef)child)!=f.ax.elementTypeID()) return nil;
  [kids addObject:child];
 }
 return kids;
}
- (NSDictionary *)frame:(CFTypeRef)element {
 id raw=[self get:kAttributeFrame element:element];
 CGRect rect=CGRectZero;
 if(raw && f.ax.valueTypeID && f.ax.getValue && CFGetTypeID((__bridge CFTypeRef)raw)==f.ax.valueTypeID()
    && f.ax.getValue((__bridge CFTypeRef)raw,3,&rect) && isfinite(rect.origin.x) && isfinite(rect.origin.y)
    && isfinite(rect.size.width) && isfinite(rect.size.height))
  return @{@"x":@(rect.origin.x),@"y":@(rect.origin.y),@"width":@(rect.size.width),@"height":@(rect.size.height)};
 return @{@"x":@0,@"y":@0,@"width":@0,@"height":@0};
}
- (BOOL)enabled:(CFTypeRef)element {
 id traits=[self get:kAttributeTraits element:element];
 return ![traits isKindOfClass:NSNumber.class] || ([traits unsignedLongLongValue] & kTraitNotEnabled)==0;
}
- (BOOL)focused:(CFTypeRef)element {
 id value=[self get:kAttributeFocused element:element];
 return [value isKindOfClass:NSNumber.class] && [value boolValue];
}
@end

// MARK: - Selector
static BOOL blank(id value) {
 return ![value isKindOfClass:NSString.class] ||
  [[(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length]==0;
}
static BOOL wholeNumber(id value) {
 return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID() &&
  [value doubleValue]>=0 && [value doubleValue]==floor([value doubleValue]);
}
// Returns an invalid_request failure, or nil when the selector is well formed.
static NSDictionary *validateSelector(NSDictionary *selector) {
 for(NSString *key in @[@"text",@"identifier",@"role"])
  if(selector[key] && blank(selector[key])) return failure(@"invalid_request",[NSString stringWithFormat:@"%@ must be a non-blank string",key]);
 id match=selector[@"match"];
 if(match && ![match isEqual:@"contains"] && ![match isEqual:@"exact"]) return failure(@"invalid_request",@"match must be contains or exact");
 if(selector[@"index"] && !wholeNumber(selector[@"index"])) return failure(@"invalid_request",@"index must be a non-negative integer");
 id path=selector[@"path"];
 if(path) {
  if(![path isKindOfClass:NSArray.class]) return failure(@"invalid_request",@"path must be an array of non-negative integers");
  for(id step in (NSArray *)path) if(!wholeNumber(step)) return failure(@"invalid_request",@"path must be an array of non-negative integers");
  if(selector[@"index"]) return failure(@"invalid_request",@"index cannot be combined with path");
 }
 if(!selector[@"text"] && !selector[@"identifier"] && !selector[@"role"] && !path)
  return failure(@"invalid_request",@"give at least one of text, identifier, role or path");
 return nil;
}

// MARK: - Resolution
// True when every given text, role and identifier agrees with the element.
static BOOL matches(VPAxReader *reader, CFTypeRef element, NSDictionary *selector) {
 NSString *text=selector[@"text"];
 if(text) {
  BOOL exact=[selector[@"match"] isEqual:@"exact"];
  BOOL hit=NO;
  for(NSString *candidate in @[[reader text:kAttributeLabel element:element],[reader text:kAttributeValue element:element]])
   hit=hit||(exact?[candidate caseInsensitiveCompare:text]==NSOrderedSame:[candidate localizedCaseInsensitiveContainsString:text]);
  if(!hit) return NO;
 }
 if(selector[@"role"] && ![[reader text:kAttributeRole element:element] isEqual:selector[@"role"]]) return NO;
 if(selector[@"identifier"] && ![[reader text:kAttributeIdentifier element:element] isEqual:selector[@"identifier"]]) return NO;
 return YES;
}
@interface VPAxHit : NSObject
@property id element;@property NSArray *path;
@end
@implementation VPAxHit
@end
@interface VPAxSearch : NSObject {
@public
 VPAxReader *reader;NSDictionary *selector;
 NSMutableArray<VPAxHit *> *hits;int visited;BOOL capped;
}
@end
@implementation VPAxSearch
- (void)visit:(CFTypeRef)element path:(NSArray *)path {
 ++visited;
 if(matches(reader,element,selector)) {VPAxHit *hit=[VPAxHit new];hit.element=(__bridge id)element;hit.path=path;[hits addObject:hit];}
 NSArray *kids=[reader children:element];
 if(!kids.count) return;
 if((int)path.count>=kMaxDepth) {capped=YES;return;}
 for(NSUInteger i=0;i<kids.count;++i) {
  if(visited>=kMaxElements) {capped=YES;return;}
  [self visit:(__bridge CFTypeRef)kids[i] path:[path arrayByAddingObject:@(i)]];
 }
}
@end

// Returns the element and its path, or sets *error.
static id resolve(VPAxReader *reader, CFTypeRef root, NSDictionary *selector, NSArray **pathOut, NSDictionary **error) {
 NSArray *path=selector[@"path"];
 if(path) {
  id current=(__bridge id)root;
  for(NSUInteger depth=0;depth<path.count;++depth) {
   NSArray *kids=[reader children:(__bridge CFTypeRef)current];
   NSUInteger index=[path[depth] unsignedIntegerValue];
   if(index>=kids.count) {*error=failure(@"not_found",@"no element at that path; take a fresh path from ui.tree");return nil;}
   current=kids[index];
  }
  CFTypeRef node=(__bridge CFTypeRef)current;
  BOOL textStale=selector[@"text"] && ![[reader text:kAttributeLabel element:node] isEqual:selector[@"text"]];
  BOOL roleStale=selector[@"role"] && ![[reader text:kAttributeRole element:node] isEqual:selector[@"role"]];
  BOOL idStale=selector[@"identifier"] && ![[reader text:kAttributeIdentifier element:node] isEqual:selector[@"identifier"]];
  if(textStale || roleStale || idStale) {
   *error=failure(@"stale",@"the element at that path no longer matches; refresh the path from a new ui.tree");return nil;
  }
  *pathOut=path;return current;
 }
 VPAxSearch *search=[VPAxSearch new];
 search->reader=reader;search->selector=selector;search->hits=[NSMutableArray array];
 [search visit:root path:@[]];
 NSString *capNote=@"the element or depth cap was reached before a match; narrow the selector, check text and role";
 NSUInteger count=search->hits.count;
 if(count==0) {
  *error=failure(@"not_found",search->capped?capNote:@"no element matches; check text and role");return nil;
 }
 NSNumber *index=selector[@"index"];
 if(count>1 && !index) {
  *error=@{@"error":@"ambiguous",@"count":@(count),
   @"message":[NSString stringWithFormat:@"%lu elements match; pass index 0..%lu or a path from ui.tree",(unsigned long)count,(unsigned long)count-1]};
  return nil;
 }
 NSUInteger chosen=index?index.unsignedIntegerValue:0;
 if(chosen>=count) {
  *error=failure(@"not_found",search->capped?capNote:[NSString stringWithFormat:@"index %lu is out of range for %lu matches",(unsigned long)chosen,(unsigned long)count]);
  return nil;
 }
 *pathOut=search->hits[chosen].path;
 return search->hits[chosen].element;
}

// MARK: - Operations
static NSDictionary *attributesReport(VPAxReader *reader, CFTypeRef element, NSString *label, NSString *role, NSArray *path, pid_t pid) {
 return @{@"label":label,@"value":[reader text:kAttributeValue element:element],
  @"identifier":[reader text:kAttributeIdentifier element:element],@"role":role,
  @"frame":[reader frame:element],@"enabled":@([reader enabled:element]),@"focused":@([reader focused:element]),
  @"path":path,@"pid":@(pid)};
}
static NSDictionary *activatedReport(NSString *actionName, NSString *label, NSString *role, pid_t pid) {
 return @{@"activated":@YES,@"action":actionName,@"label":label,@"role":role,@"pid":@(pid)};
}
static NSDictionary *focusedReport(VPAxReader *reader, CFTypeRef element, NSString *label, NSString *role, pid_t pid) {
 return @{@"focused":@([reader focused:element]),@"label":label,@"role":role,@"pid":@(pid)};
}
static NSDictionary *valueReport(VPAxReader *reader, CFTypeRef element, NSString *label, NSString *role, pid_t pid) {
 return @{@"value":[reader text:kAttributeValue element:element],@"label":label,@"role":role,@"pid":@(pid)};
}
NSDictionary *vp_ax_element_run(VPAxElementFunctions functions, CFTypeRef root, pid_t pid, NSDictionary *selector, NSDictionary *operation, BOOL switchesEnabled) {
 NSDictionary *invalid=validateSelector(selector);
 if(invalid) return invalid;
 NSString *op=operation[@"op"];
 NSString *actionName=nil;
 if([op isEqual:@"action"]) {
  actionName=operation[@"name"]?:@"activate";
  if(![actionName isKindOfClass:NSString.class] || !actionTable()[actionName])
   return failure(@"invalid_request",[NSString stringWithFormat:@"unknown action; known actions: %@",
    [[actionTable().allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]]);
 } else if([op isEqual:@"set_value"]) {
  if(![operation[@"value"] isKindOfClass:NSString.class]) return failure(@"invalid_request",@"value must be a string");
 } else if(![op isEqual:@"attributes"] && ![op isEqual:@"focus"]) return failure(@"invalid_request",@"unknown operation");
 if(!root || !functions.ax.copy || !functions.ax.elementTypeID || !functions.ax.setTimeout ||
    ([op isEqual:@"action"] && !functions.perform) || (([op isEqual:@"focus"] || [op isEqual:@"set_value"]) && !functions.setValue))
  return failure(@"unavailable",@"accessibility element access is not supported on this guest");

 VPAxReader *reader=[VPAxReader new];reader->f=functions;
 if(switchesEnabled) {
  // A freshly enabled AX stack can refuse the first query; wait once, as the hierarchy walk does.
  id probe=nil;
  if([reader read:kAttributeLabel element:root into:&probe]==kNotReadyError) {
   struct timespec delay={.tv_sec=0,.tv_nsec=kRetryWaitMS*1000000L};nanosleep(&delay,NULL);
  }
 }
 NSArray *path=nil;NSDictionary *error=nil;
 id found=resolve(reader,root,selector,&path,&error);
 if(!found) return error;
 CFTypeRef element=(__bridge CFTypeRef)found;
 NSString *label=[reader text:kAttributeLabel element:element],*role=[reader text:kAttributeRole element:element];
 if([op isEqual:@"attributes"]) return attributesReport(reader,element,label,role,path,pid);
 if([op isEqual:@"action"]) {
  int code=functions.perform(element,(CFStringRef)(uintptr_t)actionTable()[actionName].unsignedIntValue);
  if(code) return failure(@"ax_failure",[NSString stringWithFormat:@"the element does not support %@ (AX error %d); try another element",actionName,code]);
  return activatedReport(actionName,label,role,pid);
 }
 if([op isEqual:@"focus"]) {
  NSDictionary *request=@{@"focused":@1,@"assistiveTech":kAssistiveTech};
  int code=functions.setValue(element,(CFStringRef)(uintptr_t)kAttributeFocused,(__bridge CFTypeRef)request);
  if(code) return failure(@"ax_failure",[NSString stringWithFormat:@"focus failed (AX error %d); try another element",code]);
  return focusedReport(reader,element,label,role,pid);
 }
 int code=functions.setValue(element,(CFStringRef)(uintptr_t)kAttributeValue,(__bridge CFTypeRef)operation[@"value"]);
 if(code) return failure(@"ax_failure",[NSString stringWithFormat:@"set_value failed (AX error %d); the element may not be editable",code]);
 return valueReport(reader,element,label,role,pid);
}

NSDictionary *vp_ax_element(int pid, NSDictionary *selector, NSDictionary *operation) {
 VPAxElementFunctions f={.ax=vp_ax_load_functions()};
 void *ax=dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",RTLD_NOW);
 f.perform=(typeof(f.perform))(ax?dlsym(ax,"AXUIElementPerformAction"):NULL);
 f.setValue=(typeof(f.setValue))(ax?dlsym(ax,"AXUIElementSetAttributeValue"):NULL);
 CFTypeRef root=f.ax.createApp && pid>1?f.ax.createApp(pid):NULL;
 __block NSDictionary *result=nil;
 @try {
  vp_ax_with_enabled(^(BOOL enabledForInvocation) {
   result=vp_ax_element_run(f,root,pid,selector,operation,enabledForInvocation);
  });
 } @catch(NSException *exception) {
  result=failure(@"ax_failure",[NSString stringWithFormat:@"accessibility call raised %@",exception.name]);
 }
 if(root) CFRelease(root);
 return result;
}
