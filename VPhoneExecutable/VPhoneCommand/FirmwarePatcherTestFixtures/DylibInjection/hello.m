#import <Foundation/Foundation.h>

@interface Greeting : NSObject
- (NSString *)message;
@end

@implementation Greeting
- (NSString *)message {
    return @"hello world";
}
@end

int main(void) {
    @autoreleasepool {
        puts([[[Greeting new] message] UTF8String]);
    }
    return 0;
}
