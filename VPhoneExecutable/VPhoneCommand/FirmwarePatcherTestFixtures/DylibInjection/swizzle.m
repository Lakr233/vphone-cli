#import <Foundation/Foundation.h>
#import <objc/runtime.h>

@interface WorldHelloSwizzle : NSObject
- (NSString *)worldHelloMessage;
@end

@implementation WorldHelloSwizzle
+ (void)load {
    Class greeting = objc_getClass("Greeting");
    Method original = class_getInstanceMethod(greeting, @selector(message));
    Method replacement = class_getInstanceMethod(self, @selector(worldHelloMessage));
    if (original == NULL || replacement == NULL) {
        abort();
    }
    method_exchangeImplementations(original, replacement);
}

- (NSString *)worldHelloMessage {
    return @"world hello";
}
@end
