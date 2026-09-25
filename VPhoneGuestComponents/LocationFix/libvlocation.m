#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#include <math.h>

// vphoned replaces this file atomically. An absent file means native location.
static NSString *const VPhoneLocationPath = @"/var/mobile/Library/Caches/vphone-location.json";
static char VPhoneLocationTimerKey;

static CLLocation *vphoneLocation(void) {
    NSData *data = [NSData dataWithContentsOfFile:VPhoneLocationPath];
    if (!data || data.length > 4096) return nil;
    NSDictionary *state = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![state isKindOfClass:NSDictionary.class]) return nil;

    NSNumber *latitude = state[@"latitude"];
    NSNumber *longitude = state[@"longitude"];
    NSNumber *altitude = state[@"altitude"];
    NSNumber *horizontalAccuracy = state[@"horizontal_accuracy"];
    NSNumber *verticalAccuracy = state[@"vertical_accuracy"];
    NSNumber *speed = state[@"speed"];
    NSNumber *course = state[@"course"];
    if (![latitude isKindOfClass:NSNumber.class] || ![longitude isKindOfClass:NSNumber.class] ||
        ![altitude isKindOfClass:NSNumber.class] || ![horizontalAccuracy isKindOfClass:NSNumber.class] ||
        ![verticalAccuracy isKindOfClass:NSNumber.class] || ![speed isKindOfClass:NSNumber.class] ||
        ![course isKindOfClass:NSNumber.class]) return nil;
    if (!isfinite(latitude.doubleValue) || fabs(latitude.doubleValue) > 90 ||
        !isfinite(longitude.doubleValue) || fabs(longitude.doubleValue) > 180 ||
        !isfinite(altitude.doubleValue) || !isfinite(horizontalAccuracy.doubleValue) ||
        horizontalAccuracy.doubleValue < 0 || !isfinite(verticalAccuracy.doubleValue) ||
        verticalAccuracy.doubleValue < 0 || !isfinite(speed.doubleValue) || !isfinite(course.doubleValue)) return nil;

    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue)
                                           altitude:altitude.doubleValue
                                 horizontalAccuracy:horizontalAccuracy.doubleValue
                                   verticalAccuracy:verticalAccuracy.doubleValue
                                            course:course.doubleValue
                                             speed:speed.doubleValue
                                         timestamp:NSDate.date];
}

static BOOL vphoneAuthorized(CLLocationManager *manager) {
    CLAuthorizationStatus status = manager.authorizationStatus;
    return status == kCLAuthorizationStatusAuthorizedAlways || status == kCLAuthorizationStatusAuthorizedWhenInUse;
}

static void vphoneDeliver(CLLocationManager *manager) {
    if (!vphoneAuthorized(manager)) return;
    CLLocation *location = vphoneLocation();
    id<CLLocationManagerDelegate> delegate = manager.delegate;
    if (location && [delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)])
        [delegate locationManager:manager didUpdateLocations:@[location]];
}

@interface CLLocationManager (VPhoneLocation)
- (void)vphone_startUpdatingLocation;
- (void)vphone_stopUpdatingLocation;
- (void)vphone_requestLocation;
- (CLLocation *)vphone_location;
@end

@implementation CLLocationManager (VPhoneLocation)
- (void)vphone_startUpdatingLocation {
    [self vphone_startUpdatingLocation];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = objc_getAssociatedObject(self, &VPhoneLocationTimerKey);
        if (!timer) {
            __weak CLLocationManager *weakManager = self;
            timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *activeTimer) {
                CLLocationManager *manager = weakManager;
                if (manager) vphoneDeliver(manager);
                else [activeTimer invalidate];
            }];
            objc_setAssociatedObject(self, &VPhoneLocationTimerKey, timer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        vphoneDeliver(self);
    });
}

- (void)vphone_stopUpdatingLocation {
    [self vphone_stopUpdatingLocation];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = objc_getAssociatedObject(self, &VPhoneLocationTimerKey);
        [timer invalidate];
        objc_setAssociatedObject(self, &VPhoneLocationTimerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

- (void)vphone_requestLocation {
    if (!vphoneAuthorized(self) || !vphoneLocation()) {
        [self vphone_requestLocation];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ vphoneDeliver(self); });
}

- (CLLocation *)vphone_location {
    if (vphoneAuthorized(self)) {
        CLLocation *location = vphoneLocation();
        if (location) return location;
    }
    return [self vphone_location];
}
@end

static void vphoneSwizzle(SEL original, SEL replacement) {
    Class manager = CLLocationManager.class;
    Method originalMethod = class_getInstanceMethod(manager, original);
    Method replacementMethod = class_getInstanceMethod(manager, replacement);
    if (originalMethod && replacementMethod) method_exchangeImplementations(originalMethod, replacementMethod);
}

__attribute__((constructor)) static void vphoneInstallLocation(void) {
    vphoneSwizzle(@selector(startUpdatingLocation), @selector(vphone_startUpdatingLocation));
    vphoneSwizzle(@selector(stopUpdatingLocation), @selector(vphone_stopUpdatingLocation));
    vphoneSwizzle(@selector(requestLocation), @selector(vphone_requestLocation));
    vphoneSwizzle(@selector(location), @selector(vphone_location));
}
