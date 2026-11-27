// Фрагмент из ответа этапа 19 (SIGTERM через devicectl --console). НЕ КОМПИЛИРОВАЛСЯ и на устройстве не запускался.
// Вставлять в AppDelegate и UIViewController приложения; это не самостоятельный файл.

// AppDelegate.h — свойство:
@property(nonatomic) UIBackgroundTaskIdentifier bgTask;

// AppDelegate.m — в начало application:didFinishLaunchingWithOptions:
    self.bgTask = UIBackgroundTaskInvalid;
    [UIApplication sharedApplication].idleTimerDisabled = YES; // экран не гаснет

// UIViewController — в viewDidAppear:
    UIApplication *app = [UIApplication sharedApplication];
    self.bgTask = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // фоновая работа; по готовности:
        dispatch_async(dispatch_get_main_queue(), ^{
            [app endBackgroundTask:self.bgTask];
            self.bgTask = UIBackgroundTaskInvalid;
        });
    });
