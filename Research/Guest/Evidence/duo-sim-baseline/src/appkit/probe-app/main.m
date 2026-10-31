// VPAppKitProbe: a minimal third-party-style UIKit app for the iPhone Duo baseline
// (appkit domain). It supports all four orientations, adopts the scene lifecycle with
// one window scene, and logs every scene / geometry / trait / screen / hinge callback,
// each with a snapshot of the geometry the app sees, as JSON lines to
// <data container>/Documents/events.jsonl (and NSLog). Only public API, except the snapshot reads the private
// UITraitCollection -displayCornerRadius when it responds.
#import <UIKit/UIKit.h>
#include <mach/mach_time.h>

static NSFileHandle *VPLogHandle;
static double VPMono(void) {
  static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
  return (double)mach_continuous_time() * tb.numer / tb.denom / 1e9;
}
static NSDictionary *VPRect(CGRect r) { return @{@"x": @(r.origin.x), @"y": @(r.origin.y), @"width": @(r.size.width), @"height": @(r.size.height)}; }
static NSDictionary *VPInsets(UIEdgeInsets i) { return @{@"top": @(i.top), @"left": @(i.left), @"bottom": @(i.bottom), @"right": @(i.right)}; }

static UIWindowScene *VPScene(void) {
  for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
    if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
  return nil;
}

static NSDictionary *VPSnapshot(UIWindowScene *ws) {
  if (!ws) return @{};
  UIWindow *w = ws.windows.firstObject;
  UIScreen *sc = ws.screen;
  UITraitCollection *tc = ws.traitCollection;
  UIWindowSceneGeometry *g = ws.effectiveGeometry;
  NSMutableArray *screens = [NSMutableArray array];
  for (UIScreen *s in UIScreen.screens) [screens addObject:[NSString stringWithFormat:@"%p", s]];
  return @{
    @"scene": [NSString stringWithFormat:@"%p", ws],
    @"activationState": @(ws.activationState),
    @"screen": [NSString stringWithFormat:@"%p", sc],
    @"screenIsMain": @(sc == UIScreen.mainScreen),
    @"screens": screens,
    @"mainScreen": [NSString stringWithFormat:@"%p", UIScreen.mainScreen],
    @"screenBounds": VPRect(sc.bounds), @"screenNativeBounds": VPRect(sc.nativeBounds), @"screenScale": @(sc.scale),
    @"sceneBounds": VPRect(ws.coordinateSpace.bounds),
    @"geometryBounds": VPRect(g.coordinateSpace.bounds),
    @"geometryOrientation": @(g.interfaceOrientation),
    @"geometryResizing": @(g.isInteractivelyResizing),
    @"geometryOrientationLocked": @(g.isInterfaceOrientationLocked),
    @"interfaceOrientation": @(ws.interfaceOrientation),
    @"hsc": @(tc.horizontalSizeClass), @"vsc": @(tc.verticalSizeClass), @"idiom": @(tc.userInterfaceIdiom),
    @"displayScale": @(tc.displayScale), @"displayCornerRadius(private)": [tc respondsToSelector:NSSelectorFromString(@"displayCornerRadius")] ? [tc valueForKey:@"displayCornerRadius"] : [NSNull null],
    @"windowFrame": w ? VPRect(w.frame) : [NSNull null],
    @"windowSafeArea": w ? VPInsets(w.safeAreaInsets) : [NSNull null],
    @"statusBarFrame": VPRect(ws.statusBarManager.statusBarFrame),
    @"deviceOrientation": @(UIDevice.currentDevice.orientation),
  };
}

static void VPLog(NSString *event, id detail) {
  NSDictionary *rec = @{@"t": @(CFAbsoluteTimeGetCurrent()), @"mono": @(VPMono()), @"event": event,
                        @"detail": detail ?: [NSNull null], @"snapshot": VPSnapshot(VPScene())};
  NSData *d = [NSJSONSerialization dataWithJSONObject:rec options:NSJSONWritingSortedKeys error:nil];
  if (!d) return;
  NSLog(@"VPAppKitProbe %@", [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]);
  [VPLogHandle writeData:d]; [VPLogHandle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

static NSString *VPHingeDesc(UIHinge *h) {
  return h ? [NSString stringWithFormat:@"status=%ld angle=%.3f", (long)h.status, (double)h.angle] : @"nil";
}

// MARK: - View controller

@interface VPViewController : UIViewController
@property (nonatomic, strong) UILabel *label;
@property (nonatomic) CGRect lastBounds;
@end

@implementation VPViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemTealColor;
  self.label = [UILabel new];
  self.label.numberOfLines = 0;
  self.label.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
  self.label.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.label];
  UILayoutGuide *sa = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [self.label.leadingAnchor constraintEqualToAnchor:sa.leadingAnchor constant:8],
    [self.label.trailingAnchor constraintEqualToAnchor:sa.trailingAnchor constant:-8],
    [self.label.topAnchor constraintEqualToAnchor:sa.topAnchor constant:8]]];
  UIHingeInteraction *hi = [[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction *i, UIHingeInteractionUpdate *u) {
    VPLog(@"UIHingeInteraction.update", VPHingeDesc(u.hinge));
  }];
  [self.view addInteraction:hi];
  NSArray *traits = @[UITraitHorizontalSizeClass.class, UITraitVerticalSizeClass.class, UITraitDisplayScale.class,
                      UITraitUserInterfaceIdiom.class, UITraitDisplayGamut.class, UITraitLayoutDirection.class];
  [self registerForTraitChanges:traits withHandler:^(VPViewController *vc, UITraitCollection *prev) {
    VPLog(@"traitChange", [NSString stringWithFormat:@"prev hsc=%ld vsc=%ld scale=%.1f now hsc=%ld vsc=%ld scale=%.1f",
      (long)prev.horizontalSizeClass, (long)prev.verticalSizeClass, prev.displayScale,
      (long)vc.traitCollection.horizontalSizeClass, (long)vc.traitCollection.verticalSizeClass, vc.traitCollection.displayScale]);
  }];
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)c {
  [super viewWillTransitionToSize:size withTransitionCoordinator:c];
  VPLog(@"viewWillTransitionToSize", @{@"width": @(size.width), @"height": @(size.height)});
}
- (void)viewSafeAreaInsetsDidChange { [super viewSafeAreaInsetsDidChange]; VPLog(@"viewSafeAreaInsetsDidChange", VPInsets(self.view.safeAreaInsets)); }
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  if (!CGRectEqualToRect(self.lastBounds, self.view.bounds)) {
    self.lastBounds = self.view.bounds;
    VPLog(@"viewDidLayoutSubviews.boundsChanged", VPRect(self.view.bounds));
  }
  NSDictionary *s = VPSnapshot(VPScene());
  self.label.text = [NSString stringWithFormat:@"VPAppKitProbe\nscene %@\nscreen %@ main=%@\norient %@ hsc %@ vsc %@\nsafe %@",
    s[@"sceneBounds"], s[@"screenBounds"], s[@"screenIsMain"], s[@"interfaceOrientation"], s[@"hsc"], s[@"vsc"],
    s[@"windowSafeArea"]];
}
@end

// MARK: - Scene delegate

@interface VPSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation VPSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
  UIWindowScene *ws = (UIWindowScene *)scene;
  self.window = [[UIWindow alloc] initWithWindowScene:ws];
  self.window.rootViewController = [VPViewController new];
  [self.window makeKeyAndVisible];
  [ws addObserver:self forKeyPath:@"effectiveGeometry" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
  VPLog(@"scene:willConnectToSession", session.persistentIdentifier);
}
- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)o change:(NSDictionary *)ch context:(void *)ctx {
  VPLog(@"KVO.effectiveGeometry", @{@"old": [ch[NSKeyValueChangeOldKey] description] ?: @"", @"new": [ch[NSKeyValueChangeNewKey] description] ?: @""});
}
- (void)windowScene:(UIWindowScene *)ws didUpdateEffectiveGeometry:(UIWindowSceneGeometry *)prev {
  VPLog(@"windowScene:didUpdateEffectiveGeometry:", @{@"previous": prev.description ?: @"", @"current": ws.effectiveGeometry.description ?: @""});
}
- (void)windowScene:(UIWindowScene *)ws didUpdateCoordinateSpace:(id<UICoordinateSpace>)prevSpace
  interfaceOrientation:(UIInterfaceOrientation)prevOrientation traitCollection:(UITraitCollection *)prevTraits {
  VPLog(@"windowScene:didUpdateCoordinateSpace:interfaceOrientation:traitCollection:",
        @{@"prevBounds": VPRect(prevSpace.bounds), @"prevOrientation": @(prevOrientation),
          @"prevHsc": @(prevTraits.horizontalSizeClass), @"prevVsc": @(prevTraits.verticalSizeClass)});
}
- (void)sceneDidDisconnect:(UIScene *)s { VPLog(@"sceneDidDisconnect", nil); }
- (void)sceneDidBecomeActive:(UIScene *)s { VPLog(@"sceneDidBecomeActive", nil); }
- (void)sceneWillResignActive:(UIScene *)s { VPLog(@"sceneWillResignActive", nil); }
- (void)sceneWillEnterForeground:(UIScene *)s { VPLog(@"sceneWillEnterForeground", nil); }
- (void)sceneDidEnterBackground:(UIScene *)s { VPLog(@"sceneDidEnterBackground", nil); }
@end

// MARK: - App delegate

@interface VPAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation VPAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
  NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  NSString *path = [docs stringByAppendingPathComponent:@"events.jsonl"];
  if (![NSFileManager.defaultManager fileExistsAtPath:path]) [NSData.data writeToFile:path atomically:YES];
  VPLogHandle = [NSFileHandle fileHandleForWritingAtPath:path];
  [VPLogHandle seekToEndOfFile];
  [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
  NSArray *names = @[UISceneWillConnectNotification, UISceneDidDisconnectNotification, UISceneDidActivateNotification,
                     UISceneWillDeactivateNotification, UISceneWillEnterForegroundNotification, UISceneDidEnterBackgroundNotification,
                     UIScreenDidConnectNotification, UIScreenDidDisconnectNotification, UIScreenModeDidChangeNotification,
                     UIDeviceOrientationDidChangeNotification, UIApplicationDidBecomeActiveNotification,
                     UIApplicationWillResignActiveNotification];
  for (NSString *n in names)
    [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
      VPLog([@"notification." stringByAppendingString:note.name], [NSString stringWithFormat:@"%@", note.object]);
    }];
  VPLog(@"didFinishLaunching", @{@"pid": @(getpid())});
  return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
  UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
  c.delegateClass = VPSceneDelegate.class;
  return c;
}
- (UIInterfaceOrientationMask)application:(UIApplication *)app supportedInterfaceOrientationsForWindow:(UIWindow *)w {
  return UIInterfaceOrientationMaskAll;
}
@end

int main(int argc, char *argv[]) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(VPAppDelegate.class)); }
}
