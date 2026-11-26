#import <Foundation/Foundation.h>
#import <stdlib.h>
#define CHECK(...) do{if(!(__VA_ARGS__)){fprintf(stderr,"FAIL line %d\n",__LINE__);abort();}}while(0)
#import "../Native/vphoned_ax_element.h"

// A fake AX tree drives the element resolver on macOS without a guest. Elements are NSStrings; the
// literal ids below are the same private numbers the daemon uses, written here as the fake's own
// wire format rather than imported from the code under test.
static NSDictionary *tree;   // key -> @{label,value,identifier,role,traits,kids}
static NSMutableDictionary *state;
static int childReads,performCalls,performError,setError,rootLabelFailures;
static NSMutableArray *sets;

static int copyAttr(CFTypeRef element, CFStringRef attr, CFTypeRef *out) {
 NSString *key=(__bridge NSString *)element;unsigned long code=(uintptr_t)attr;
 NSDictionary *node=tree[key];
 if(code==2001 && [key isEqual:@"root"] && rootLabelFailures>0) {--rootLabelFailures;return -25215;}
 id result=nil;
 switch(code) {
  case 2001:result=node[@"label"];break;
  case 2006:result=state[key]?:node[@"value"];break;
  case 2004:result=node[@"traits"];break;
  case 2018:result=state[[key stringByAppendingString:@"#focus"]];break;
  case 5003:result=node[@"role"];break;
  case 5019:result=node[@"identifier"];break;
  case 5001:++childReads;result=node[@"kids"]?:@[];break;
  default:return -25212;
 }
 if(!result) return -25212;
 *out=CFBridgingRetain(result);return 0;
}
static CFTypeID typeID(void) {return CFStringGetTypeID();}
static int timeout(CFTypeRef e,float t) {(void)e;CHECK(t==5.0f);return 0;}
static int perform(CFTypeRef e,CFStringRef a) {(void)e;(void)a;++performCalls;return performError;}
static int setValue(CFTypeRef e,CFStringRef a,CFTypeRef v) {
 unsigned long code=(uintptr_t)a;NSString *key=(__bridge NSString *)e;
 [sets addObject:@{@"id":@(code),@"value":(__bridge id)v}];
 if(setError) return setError;
 if(code==2006) state[key]=(__bridge id)v;
 if(code==2018) state[[key stringByAppendingString:@"#focus"]]=@([((__bridge NSDictionary *)v)[@"focused"] intValue]);
 return 0;
}
static VPAxElementFunctions fns(void) {
 return (VPAxElementFunctions){.ax={.copy=copyAttr,.elementTypeID=typeID,.setTimeout=timeout},.perform=perform,.setValue=setValue};
}
static void reset(void) {
 childReads=performCalls=performError=setError=rootLabelFailures=0;state=[NSMutableDictionary dictionary];sets=[NSMutableArray array];
}
static NSDictionary *run(NSDictionary *selector, NSDictionary *op) {
 reset();
 return vp_ax_element_run(fns(),(__bridge CFTypeRef)@"root",42,selector,op,NO);
}
static NSDictionary *attributes(NSDictionary *selector) {return run(selector,@{@"op":@"attributes"});}
static void expectError(NSDictionary *r, NSString *code) {
 CHECK([r[@"error"] isEqual:code]);CHECK([r[@"message"] length]>0);
 for(NSString *key in r) CHECK([@[@"error",@"message",@"count"] containsObject:key]);
}

int main(void) {@autoreleasepool {
 // root -> [a, b -> [c]]; "Wi-Fi" appears twice, the second is disabled.
 tree=@{@"root":@{@"label":@"App",@"role":@"Application",@"kids":@[@"a",@"b"]},
  @"a":@{@"label":@"Wi-Fi",@"value":@"On",@"identifier":@"wifi",@"role":@"Cell",@"traits":@0x41},
  @"b":@{@"label":@"Group",@"role":@"Group",@"kids":@[@"c"]},
  @"c":@{@"label":@"Wi-Fi",@"identifier":@"wifi2",@"role":@"Cell",@"traits":@0x141}};

 NSDictionary *r=attributes(@{@"path":@[@0]});
 CHECK([r[@"label"] isEqual:@"Wi-Fi"]);CHECK([r[@"value"] isEqual:@"On"]);CHECK([r[@"identifier"] isEqual:@"wifi"]);
 CHECK([r[@"role"] isEqual:@"Cell"]);CHECK([r[@"path"] isEqual:@[@0]]);CHECK([r[@"pid"] intValue]==42);
 CHECK([r[@"enabled"] boolValue]);CHECK(r[@"focused"] && ![r[@"focused"] boolValue]);
 for(NSString *k in @[@"label",@"value",@"identifier",@"role",@"frame",@"enabled",@"focused",@"path",@"pid"]) CHECK(r[k]);
 CHECK([r[@"frame"][@"width"] intValue]==0);
 // The path descent reads children once per level, never a full walk.
 r=attributes(@{@"path":@[@1,@0]});
 CHECK([r[@"identifier"] isEqual:@"wifi2"]);CHECK(r[@"enabled"] && ![r[@"enabled"] boolValue]);
 CHECK(childReads<=2);
 CHECK([attributes(@{@"path":@[]})[@"label"] isEqual:@"App"]);

 expectError(attributes(@{@"path":@[@5]}),@"not_found");
 expectError(attributes(@{@"path":@[@0,@0]}),@"not_found");
 expectError(attributes(@{@"path":@[@0],@"text":@"Other"}),@"stale");
 expectError(attributes(@{@"path":@[@0],@"role":@"Button"}),@"stale");
 expectError(attributes(@{@"path":@[@0],@"identifier":@"nope"}),@"stale");
 CHECK([attributes(@{@"path":@[@0],@"text":@"Wi-Fi",@"role":@"Cell",@"identifier":@"wifi"})[@"label"] isEqual:@"Wi-Fi"]);

 r=attributes(@{@"text":@"wi-fi"});
 expectError(r,@"ambiguous");CHECK([r[@"count"] intValue]==2);CHECK([r[@"message"] containsString:@"index"]);
 CHECK([attributes(@{@"text":@"Wi-Fi",@"index":@1})[@"path"] isEqual:@[@1,@0]]);
 CHECK([attributes(@{@"text":@"Wi-Fi",@"index":@0})[@"path"] isEqual:@[@0]]);
 expectError(attributes(@{@"text":@"Wi-Fi",@"index":@2}),@"not_found");
 CHECK([attributes(@{@"text":@"On"})[@"path"] isEqual:@[@0]]); // text also matches the value
 CHECK([attributes(@{@"text":@"Wi",@"match":@"exact"})[@"error"] isEqual:@"not_found"]);
 CHECK([attributes(@{@"identifier":@"wifi2"})[@"path"] isEqual:@[@1,@0]]);
 CHECK([attributes(@{@"role":@"Group"})[@"path"] isEqual:@[@1]]);
 expectError(attributes(@{@"text":@"missing"}),@"not_found");

 expectError(attributes(@{@"path":@[@0],@"index":@0}),@"invalid_request");
 expectError(attributes(@{}),@"invalid_request");
 expectError(attributes(@{@"match":@"exact"}),@"invalid_request");
 expectError(attributes(@{@"text":@"  "}),@"invalid_request");
 expectError(attributes(@{@"identifier":@""}),@"invalid_request");
 expectError(attributes(@{@"role":@" \n"}),@"invalid_request");
 expectError(attributes(@{@"path":@"0"}),@"invalid_request");
 expectError(attributes(@{@"path":@[@(-1)]}),@"invalid_request");
 expectError(attributes(@{@"path":@[@1.5]}),@"invalid_request");
 expectError(attributes(@{@"path":@[@"x"]}),@"invalid_request");
 expectError(attributes(@{@"text":@"Wi-Fi",@"index":@(-1)}),@"invalid_request");
 expectError(attributes(@{@"text":@"Wi-Fi",@"match":@"regex"}),@"invalid_request");

 // activate
 r=run(@{@"path":@[@0]},@{@"op":@"action",@"name":@"activate"});
 CHECK([r[@"activated"] boolValue]);CHECK([r[@"action"] isEqual:@"activate"]);CHECK(performCalls==1);
 CHECK([r[@"label"] isEqual:@"Wi-Fi"]);CHECK([r[@"role"] isEqual:@"Cell"]);
 r=run(@{@"path":@[@0]},@{@"op":@"action"});CHECK([r[@"action"] isEqual:@"activate"]);
 r=run(@{@"path":@[@0]},@{@"op":@"action",@"name":@"swipe"});
 expectError(r,@"invalid_request");CHECK([r[@"message"] containsString:@"activate"]);CHECK(performCalls==0);
 reset();performError=-25200;
 r=vp_ax_element_run(fns(),(__bridge CFTypeRef)@"root",42,@{@"path":@[@0]},@{@"op":@"action"},NO);
 expectError(r,@"ax_failure");

 // focus sets attribute 2018 to the full dictionary, then reads it back
 r=run(@{@"path":@[@0]},@{@"op":@"focus"});
 CHECK(sets.count==1);CHECK([sets[0][@"id"] intValue]==2018);
 CHECK([sets[0][@"value"][@"focused"] intValue]==1);
 CHECK([sets[0][@"value"][@"assistiveTech"] isEqual:@"UIAccessibilityNotificationVoiceOverIdentifier"]);
 CHECK([r[@"focused"] boolValue]);
 reset();setError=-25204;
 expectError(vp_ax_element_run(fns(),(__bridge CFTypeRef)@"root",42,@{@"path":@[@0]},@{@"op":@"focus"},NO),@"ax_failure");

 // set_value reads back
 r=run(@{@"path":@[@0]},@{@"op":@"set_value",@"value":@"abc"});
 CHECK([sets[0][@"id"] intValue]==2006);CHECK([r[@"value"] isEqual:@"abc"]);
 expectError(run(@{@"path":@[@0]},@{@"op":@"set_value"}),@"invalid_request");
 reset();setError=-25200;
 expectError(vp_ax_element_run(fns(),(__bridge CFTypeRef)@"root",42,@{@"path":@[@0]},@{@"op":@"set_value",@"value":@"x"},NO),@"ax_failure");

 expectError(run(@{@"path":@[@0]},@{@"op":@"bogus"}),@"invalid_request");

 // unavailable: missing symbols
 reset();VPAxElementFunctions bare=fns();bare.perform=NULL;
 expectError(vp_ax_element_run(bare,(__bridge CFTypeRef)@"root",42,@{@"path":@[@0]},@{@"op":@"action"},NO),@"unavailable");
 bare=fns();bare.ax.setTimeout=NULL;
 expectError(vp_ax_element_run(bare,(__bridge CFTypeRef)@"root",42,@{@"path":@[@0]},@{@"op":@"attributes"},NO),@"unavailable");
 expectError(vp_ax_element_run(fns(),NULL,42,@{@"path":@[@0]},@{@"op":@"attributes"},NO),@"unavailable");
 expectError(vp_ax_element(0,@{@"path":@[@0]},@{@"op":@"attributes"}),@"unavailable");

 // A freshly enabled AX stack that refuses the first query gets one 400 ms wait.
 reset();rootLabelFailures=1;
 NSDate *start=NSDate.date;
 r=vp_ax_element_run(fns(),(__bridge CFTypeRef)@"root",42,@{@"path":@[@0]},@{@"op":@"attributes"},YES);
 CHECK([r[@"label"] isEqual:@"Wi-Fi"]);CHECK(-[start timeIntervalSinceNow]>=0.39);
 reset();rootLabelFailures=1;start=NSDate.date;
 vp_ax_element_run(fns(),(__bridge CFTypeRef)@"root",42,@{@"path":@[@0]},@{@"op":@"attributes"},NO);
 CHECK(-[start timeIntervalSinceNow]<0.39);

 // Element cap: a wide tree with no match reports the cap.
 NSMutableDictionary *big=[NSMutableDictionary dictionary];NSMutableArray *kids=[NSMutableArray array];
 for(int i=0;i<2100;++i) {NSString *k=[NSString stringWithFormat:@"n%d",i];big[k]=@{@"label":@"x",@"role":@"Cell"};[kids addObject:k];}
 big[@"root"]=@{@"label":@"App",@"kids":kids};tree=big;
 r=attributes(@{@"text":@"zzz"});expectError(r,@"not_found");CHECK([r[@"message"] containsString:@"cap"]);
 puts("element tests passed");
}}
