#import "vphoned_ax_settings.h"
#import <dlfcn.h>

// MARK: - Table
// One row per feature: the getter and setter exported by libAccessibility (symbols recorded in
// Research/vphoned_http_api.md, "Accessibility settings symbols"). Bool setters take a Boolean;
// the text size getter returns a +1 CFString (NULL when never set) and its setter takes a CFString.
typedef struct {
 const char *feature;
 BOOL text;
 const char *getter,*setter;
} VPAxSettingRow;
static const VPAxSettingRow kRows[]={
 {"voiceover",NO,"_AXSVoiceOverTouchEnabled","_AXSVoiceOverTouchSetEnabled"},
 {"assistive_touch",NO,"_AXSAssistiveTouchEnabled","_AXSAssistiveTouchSetEnabled"},
 {"switch_control",NO,"_AXSAssistiveTouchScannerEnabled","_AXSAssistiveTouchScannerSetEnabled"},
 {"reduce_motion",NO,"_AXSReduceMotionEnabled","_AXSSetReduceMotionEnabled"},
 {"full_keyboard_access",NO,"_AXSFullKeyboardAccessEnabled","_AXSFullKeyboardAccessSetEnabled"},
 {"text_size",YES,"_AXSCopyPreferredContentSizeCategoryName","_AXSSetPreferredContentSizeCategoryName"},
};
#define ROW_COUNT (sizeof(kRows)/sizeof(kRows[0]))
// Text size short name -> stored UICTContentSizeCategory name, in size order.
static NSArray<NSArray<NSString *> *> *textSizes(void) {
 return @[@[@"xs",@"UICTContentSizeCategoryXS"],@[@"s",@"UICTContentSizeCategoryS"],
  @[@"m",@"UICTContentSizeCategoryM"],@[@"l",@"UICTContentSizeCategoryL"],
  @[@"xl",@"UICTContentSizeCategoryXL"],@[@"xxl",@"UICTContentSizeCategoryXXL"],
  @[@"xxxl",@"UICTContentSizeCategoryXXXL"],@[@"ax1",@"UICTContentSizeCategoryAccessibilityM"],
  @[@"ax2",@"UICTContentSizeCategoryAccessibilityL"],@[@"ax3",@"UICTContentSizeCategoryAccessibilityXL"],
  @[@"ax4",@"UICTContentSizeCategoryAccessibilityXXL"],@[@"ax5",@"UICTContentSizeCategoryAccessibilityXXXL"]];
}
static NSString *shortName(NSString *stored) {
 for(NSArray *pair in textSizes()) if([pair[1] isEqual:stored]) return pair[0];
 return nil;
}
static NSString *storedName(NSString *name) {
 for(NSArray *pair in textSizes()) if([pair[0] isEqual:name]) return pair[1];
 return nil;
}
static NSDictionary *failure(NSString *code, NSString *message) {
 return @{@"error":code,@"message":message};
}
static NSString *joined(NSArray<NSString *> *names) {return [names componentsJoinedByString:@", "];}
static NSString *unknownFeature(NSString *feature) {
 NSMutableArray *names=[NSMutableArray array];
 for(size_t i=0;i<ROW_COUNT;++i) [names addObject:@(kRows[i].feature)];
 return [NSString stringWithFormat:@"Unknown feature %@; use one of %@",feature,joined(names)];
}
static const VPAxSettingRow *row(NSString *feature) {
 for(size_t i=0;i<ROW_COUNT;++i) if([feature isEqual:@(kRows[i].feature)]) return &kRows[i];
 return NULL;
}

// MARK: - Read
// The feature's value, or nil when a symbol is missing or a stored text size is not one of the 12.
// `raw` (optional) receives the stored text size name when it is not one of the 12.
static id readValueNamed(VPAxSymbolResolver resolve, const VPAxSettingRow *r, NSString **raw) {
 void *getter=resolve(r->getter);
 if(!getter || !resolve(r->setter)) return nil;
 if(!r->text) return [NSNumber numberWithBool:((Boolean (*)(void))getter)()!=0];
 CFStringRef stored=((CFStringRef (*)(void))getter)();
 if(!stored) return @"l";
 NSString *name=CFBridgingRelease(stored);
 NSString *mapped=shortName(name);
 if(!mapped && raw) *raw=name;
 return mapped;
}
static id readValue(VPAxSymbolResolver resolve, const VPAxSettingRow *r) {return readValueNamed(resolve,r,NULL);}
static NSDictionary *settingsReport(VPAxSymbolResolver resolve, NSString *feature) {
 NSMutableDictionary *features=[NSMutableDictionary dictionary];
 NSMutableArray *unavailable=[NSMutableArray array];
 for(size_t i=0;i<ROW_COUNT;++i) {
  if(feature && ![feature isEqual:@(kRows[i].feature)]) continue;
  id value=readValue(resolve,&kRows[i]);
  if(value) features[@(kRows[i].feature)]=value; else [unavailable addObject:@(kRows[i].feature)];
 }
 return @{@"features":features,@"unavailable":unavailable};
}

NSDictionary *vp_ax_settings_get_with(VPAxSymbolResolver resolve, NSString *feature) {
 if(feature && !row(feature)) return failure(@"invalid_request",unknownFeature(feature));
 return settingsReport(resolve,feature);
}

// MARK: - Write
// The guest may undo a setting shortly after it was applied, so the value is read again this long after.
static const NSTimeInterval kSettleSeconds=2;
static NSString *shown(id v) {
 if([v isKindOfClass:NSString.class]) return v;
 return [v boolValue]?@"true":@"false";
}
static NSDictionary *appliedReport(NSString *feature, id back) {
 return @{@"feature":feature,@"value":back};
}
NSDictionary *vp_ax_settings_set_with(VPAxSymbolResolver resolve, NSString *feature, id value) {
 const VPAxSettingRow *r=feature?row(feature):NULL;
 if(!r) return failure(@"invalid_request",unknownFeature(feature));
 NSString *stored=nil;
 if(r->text) {
  stored=[value isKindOfClass:NSString.class]?storedName(value):nil;
  if(!stored) {
   NSMutableArray *names=[NSMutableArray array];
   for(NSArray *pair in textSizes()) [names addObject:pair[0]];
   return failure(@"invalid_request",[NSString stringWithFormat:@"value for text_size must be one of %@",joined(names)]);
  }
 } else if(![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()) {
  return failure(@"invalid_request",[NSString stringWithFormat:@"value for %@ must be true or false",feature]);
 }
 void *getter=resolve(r->getter),*setter=resolve(r->setter);
 if(!getter || !setter) return failure(@"unavailable",[NSString stringWithFormat:@"%@ is not available on this guest",feature]);
 if(r->text) ((void (*)(CFStringRef))setter)((__bridge CFStringRef)stored);
 else ((void (*)(Boolean))setter)([value boolValue]);
 id back=readValue(resolve,r);
 if(!back) return failure(@"ax_failure",[NSString stringWithFormat:@"%@ read back a value this method does not name",feature]);
 [NSThread sleepForTimeInterval:kSettleSeconds];
 NSString *raw=nil;
 id settled=readValueNamed(resolve,r,&raw);
 if(!settled) return failure(@"unavailable",[NSString stringWithFormat:@"the guest reverted %@; it settled on %@, a value this method does not name",feature,raw?:@"an unreadable value"]);
 BOOL held=r->text?[settled isEqual:value]:[settled boolValue]==[value boolValue];
 if(!held) return failure(@"unavailable",[NSString stringWithFormat:@"the guest reverted %@ to %@ after it was set to %@",feature,shown(settled),shown(value)]);
 return appliedReport(feature,settled);
}

// MARK: - Live
static void *liveResolve(const char *name) {
 static void *library;
 static dispatch_once_t once;
 dispatch_once(&once,^{library=dlopen("/usr/lib/libAccessibility.dylib",RTLD_NOW);});
 return library?dlsym(library,name):NULL;
}
NSDictionary *vp_ax_settings_get(NSString *feature) {return vp_ax_settings_get_with(liveResolve,feature);}
NSDictionary *vp_ax_settings_set(NSString *feature, id value) {return vp_ax_settings_set_with(liveResolve,feature,value);}
