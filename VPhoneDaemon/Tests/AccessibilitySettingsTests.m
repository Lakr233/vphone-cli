#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <string.h>
#define CHECK(...) do{if(!(__VA_ARGS__)){fprintf(stderr,"FAIL line %d\n",__LINE__);abort();}}while(0)
#import "../Native/vphoned_ax_settings.h"

// A real CFBoolean, not an NSNumber 0/1: isEqual:@NO also accepts 0, so it cannot tell them apart.
static BOOL isBool(id v, BOOL expected) {
 return v && CFGetTypeID((__bridge CFTypeRef)v)==CFBooleanGetTypeID() && [v boolValue]==expected;
}
// JSON text of the value is exactly true or false.
static BOOL jsonBool(id v, BOOL expected) {
 NSData *d=[NSJSONSerialization dataWithJSONObject:@{@"v":v} options:0 error:nil];
 return [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] isEqual:expected?@"{\"v\":true}":@"{\"v\":false}"];
}
#define BOOLCHECK(v,e) CHECK(isBool((v),(e)) && jsonBool((v),(e)))

// Fake libAccessibility: every symbol the resolver names is backed by plain state, so the table's
// lookup, setter calls and read-back run on macOS. Symbol names are written out here, not imported.
static Boolean bools[5];
static NSString *storedSize;          // nil is the never-set state
static NSMutableSet *missing;         // symbol names the resolver refuses
static NSMutableArray *setterCalls;
static BOOL corruptSetter;           // the text size setter stores a name outside the 12

// A revert injected through the resolver's fakes: `revert` runs just before the getter's second read
// since reset, which is the read `set` makes after its settle wait.
static void (^revert)(void);
static int reads;
static void tick(void) {if(++reads==2 && revert) revert();}
static Boolean get0(void) {tick();return bools[0];}
static Boolean get1(void) {tick();return bools[1];}
static Boolean get2(void) {tick();return bools[2];}
static Boolean get3(void) {tick();return bools[3];}
static Boolean get4(void) {tick();return bools[4];}
static void set0(Boolean v) {bools[0]=v;[setterCalls addObject:@"voiceover"];}
static void set1(Boolean v) {bools[1]=v;[setterCalls addObject:@"assistive_touch"];}
static void set2(Boolean v) {bools[2]=v;[setterCalls addObject:@"switch_control"];}
static void set3(Boolean v) {bools[3]=v;[setterCalls addObject:@"reduce_motion"];}
static void set4(Boolean v) {bools[4]=v;[setterCalls addObject:@"full_keyboard_access"];}
static CFStringRef getSize(void) {tick();return storedSize?(CFStringRef)CFBridgingRetain(storedSize):NULL;}
static void setSize(CFStringRef v) {storedSize=corruptSetter?@"UICTContentSizeCategoryUnspecified":(v?(__bridge NSString *)v:nil);[setterCalls addObject:@"text_size"];}

static void *resolve(const char *name) {
 if([missing containsObject:@(name)]) return NULL;
 static const struct {const char *name;void *fn;} table[]={
  {"_AXSVoiceOverTouchEnabled",get0},{"_AXSVoiceOverTouchSetEnabled",set0},
  {"_AXSAssistiveTouchEnabled",get1},{"_AXSAssistiveTouchSetEnabled",set1},
  {"_AXSAssistiveTouchScannerEnabled",get2},{"_AXSAssistiveTouchScannerSetEnabled",set2},
  {"_AXSReduceMotionEnabled",get3},{"_AXSSetReduceMotionEnabled",set3},
  {"_AXSFullKeyboardAccessEnabled",get4},{"_AXSFullKeyboardAccessSetEnabled",set4},
  {"_AXSCopyPreferredContentSizeCategoryName",getSize},{"_AXSSetPreferredContentSizeCategoryName",setSize},
 };
 for(size_t i=0;i<sizeof(table)/sizeof(table[0]);++i) if(!strcmp(table[i].name,name)) return table[i].fn;
 return NULL;
}
static void reset(void) {
 revert=nil;reads=0;corruptSetter=NO;memset(bools,0,sizeof(bools));storedSize=nil;missing=[NSMutableSet set];setterCalls=[NSMutableArray array];
}
static NSDictionary *get(NSString *feature) {return vp_ax_settings_get_with(resolve,feature);}
static NSDictionary *set(NSString *feature, id value) {return vp_ax_settings_set_with(resolve,feature,value);}

int main(void) {@autoreleasepool {
 // lookup: no param lists every feature, none unavailable, unset text size reports l
 reset();bools[2]=1;
 NSDictionary *r=get(nil);
 CHECK([r[@"unavailable"] count]==0);
 CHECK([r[@"features"] count]==6);
 BOOLCHECK(r[@"features"][@"switch_control"],YES);
 BOOLCHECK(r[@"features"][@"voiceover"],NO);
 CHECK([r[@"features"][@"text_size"] isEqual:@"l"]);

 // lookup by name returns only that feature
 r=get(@"reduce_motion");
 CHECK([r[@"features"] count]==1);
 BOOLCHECK(r[@"features"][@"reduce_motion"],NO);

 // each mapped stored name reports its short name
 NSDictionary *pairs=@{@"UICTContentSizeCategoryXS":@"xs",@"UICTContentSizeCategoryXXXL":@"xxxl",
  @"UICTContentSizeCategoryAccessibilityM":@"ax1",@"UICTContentSizeCategoryAccessibilityXXXL":@"ax5"};
 for(NSString *stored in pairs) {storedSize=stored;CHECK([get(@"text_size")[@"features"][@"text_size"] isEqual:pairs[stored]]);}

 // unavailable row: a missing getter or setter reports unavailable, and set fails unavailable
 reset();[missing addObject:@"_AXSVoiceOverTouchEnabled"];
 r=get(nil);
 CHECK([r[@"unavailable"] isEqual:@[@"voiceover"]] && r[@"features"][@"voiceover"]==nil && [r[@"features"] count]==5);
 reset();[missing addObject:@"_AXSAssistiveTouchSetEnabled"];
 CHECK([get(@"assistive_touch")[@"unavailable"] isEqual:@[@"assistive_touch"]]);
 r=set(@"assistive_touch",@YES);
 CHECK([r[@"error"] isEqual:@"unavailable"] && setterCalls.count==0);
 reset();[missing addObject:@"_AXSSetPreferredContentSizeCategoryName"];
 CHECK([set(@"text_size",@"xl")[@"error"] isEqual:@"unavailable"]);

 // unmapped stored text size is reported in unavailable for text_size only
 reset();storedSize=@"UICTContentSizeCategoryUnspecified";
 r=get(nil);
 CHECK([r[@"unavailable"] isEqual:@[@"text_size"]] && r[@"features"][@"text_size"]==nil && [r[@"features"] count]==5);
 r=get(@"text_size");
 CHECK([r[@"unavailable"] isEqual:@[@"text_size"]] && [r[@"features"] count]==0);

 // invalid feature
 reset();
 r=get(@"brightness");
 CHECK([r[@"error"] isEqual:@"invalid_request"] && [r[@"message"] containsString:@"voiceover"]);
 r=set(@"brightness",@YES);
 CHECK([r[@"error"] isEqual:@"invalid_request"] && setterCalls.count==0);
 CHECK([set(nil,@YES)[@"error"] isEqual:@"invalid_request"]);

 // invalid value for each type: bool needs a JSON boolean, text size needs one of the 12 names
 for(id bad in @[@1,@"true",@"yes",[NSNull null]]) {
  r=set(@"reduce_motion",bad);
  CHECK([r[@"error"] isEqual:@"invalid_request"] && [r[@"message"] containsString:@"true or false"]);
 }
 for(id bad in @[@"huge",@"UICTContentSizeCategoryL",@"XL",@YES,@3]) {
  r=set(@"text_size",bad);
  CHECK([r[@"error"] isEqual:@"invalid_request"] && [r[@"message"] containsString:@"xxxl"] && [r[@"message"] containsString:@"ax5"]);
 }
 CHECK(setterCalls.count==0);

 // set calls the setter, reads back, and persists
 r=set(@"voiceover",@YES);
 CHECK([r[@"feature"] isEqual:@"voiceover"] && bools[0]==1);
 BOOLCHECK(r[@"value"],YES);
 CHECK([setterCalls isEqual:@[@"voiceover"]]);
 r=set(@"voiceover",@NO);
 CHECK(bools[0]==0);
 BOOLCHECK(r[@"value"],NO);
 r=set(@"text_size",@"ax3");
 CHECK([r[@"value"] isEqual:@"ax3"] && [storedSize isEqual:@"UICTContentSizeCategoryAccessibilityXL"]);
 CHECK([get(@"text_size")[@"features"][@"text_size"] isEqual:@"ax3"]);
 r=set(@"text_size",@"xs");
 CHECK([storedSize isEqual:@"UICTContentSizeCategoryXS"]);

 // a set whose read back is not one of the 12 sizes fails
 reset();corruptSetter=YES;
 r=set(@"text_size",@"xl");
 CHECK([r[@"error"] isEqual:@"ax_failure"]);

 // settle: set waits at least 2 s and under 3 s before the second read, and a held value succeeds
 reset();
 NSDate *start=[NSDate date];
 r=set(@"reduce_motion",@YES);
 NSTimeInterval took=-[start timeIntervalSinceNow];
 CHECK(took>=2 && took<3);
 BOOLCHECK(r[@"value"],YES);

 // injected revert, bool feature: the second read differs, set fails unavailable naming the settled value
 reset();
 revert=^{bools[2]=0;};
 r=set(@"switch_control",@YES);
 CHECK([r[@"error"] isEqual:@"unavailable"] && [r[@"message"] containsString:@"reverted switch_control to false after it was set to true"] && r[@"value"]==nil);
 reset();bools[1]=1;
 revert=^{bools[1]=1;};
 r=set(@"assistive_touch",@NO);
 CHECK([r[@"error"] isEqual:@"unavailable"] && [r[@"message"] containsString:@"reverted assistive_touch to true after it was set to false"]);

 // injected revert, text_size: the settled short name is in the message
 reset();
 revert=^{storedSize=@"UICTContentSizeCategoryS";};
 r=set(@"text_size",@"xl");
 CHECK([r[@"error"] isEqual:@"unavailable"] && [r[@"message"] containsString:@"reverted text_size to s"]);

 // a NULL second read is l: it succeeds when l was requested and fails (settled l) otherwise
 reset();
 revert=^{storedSize=nil;};
 r=set(@"text_size",@"l");
 CHECK(r[@"error"]==nil && [r[@"value"] isEqual:@"l"]);
 reset();
 revert=^{storedSize=nil;};
 r=set(@"text_size",@"xl");
 CHECK([r[@"error"] isEqual:@"unavailable"] && [r[@"message"] containsString:@"reverted text_size to l"]);

 // an unmapped second read fails unavailable with the raw name in the message
 reset();
 revert=^{storedSize=@"UICTContentSizeCategoryUnspecified";};
 r=set(@"text_size",@"xl");
 CHECK([r[@"error"] isEqual:@"unavailable"] && [r[@"message"] containsString:@"UICTContentSizeCategoryUnspecified"]);

 // a fresh guest accepts a set and reads it back
 reset();
 r=set(@"full_keyboard_access",@YES);
 BOOLCHECK(r[@"value"],YES);
 puts("accessibility settings tests passed");
}}
