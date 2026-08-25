#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <unistd.h>

static BOOL (*orig_setActivationPolicy)(id, SEL, NSInteger);
static CFAbsoluteTime allowRegularUntil = 0;
static const char *kFocusPIDPath = "/tmp/com.zhangjing.RStudioHub.focusPID";

static BOOL ShouldAllowRegularPolicy(void) {
    return CFAbsoluteTimeGetCurrent() < allowRegularUntil;
}

static void ExtendAllowRegularPolicy(void) {
    allowRegularUntil = CFAbsoluteTimeGetCurrent() + 1.0;
}

static pid_t ReadFocusPID(void) {
    FILE *file = fopen(kFocusPIDPath, "r");
    if (!file) {
        return 0;
    }

    int pid = 0;
    if (fscanf(file, "%d", &pid) != 1) {
        pid = 0;
    }
    fclose(file);
    return (pid_t)pid;
}

static void ApplyAccessoryPolicy(void) {
    if (!NSApp || !orig_setActivationPolicy) {
        return;
    }
    if ([NSApp activationPolicy] == NSApplicationActivationPolicyAccessory) {
        return;
    }
    orig_setActivationPolicy(
        NSApp,
        sel_registerName("setActivationPolicy:"),
        NSApplicationActivationPolicyAccessory
    );
}

static void ScheduleAccessoryPolicyBurst(void) {
    // Hide from Dock as early and as often as possible during launch.
    ApplyAccessoryPolicy();
    for (int i = 0; i < 3; i++) {
        double delay = 0.02 * (i + 1);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ApplyAccessoryPolicy();
        });
    }
}

static BOOL always_accessory_setActivationPolicy(id self, SEL _cmd, NSInteger policy) {
    if (ShouldAllowRegularPolicy()
        && policy == NSApplicationActivationPolicyRegular) {
        return orig_setActivationPolicy(self, _cmd, policy);
    }

    if ([NSApp activationPolicy] == NSApplicationActivationPolicyAccessory) {
        return YES;
    }

    return orig_setActivationPolicy(self, _cmd, NSApplicationActivationPolicyAccessory);
}

static void PromoteSelfToRegularIfTargeted(void) {
    pid_t targetPID = ReadFocusPID();
    if (targetPID == 0 || targetPID != getpid()) {
        return;
    }

    // Only widen the allow window. Forcing Regular here flashes Dock + menu bar.
    ExtendAllowRegularPolicy();
}

static void OnHideDockNotification(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo
) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;

    dispatch_async(dispatch_get_main_queue(), ^{
        ApplyAccessoryPolicy();
    });
}

static void OnAllowActivateNotification(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo
) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;

    PromoteSelfToRegularIfTargeted();
}

static void ObserveAppLaunch(void) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:NSApplicationWillFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
        ApplyAccessoryPolicy();
    }];
    [center addObserverForName:NSApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
        ApplyAccessoryPolicy();
        ScheduleAccessoryPolicyBurst();
    }];
}

__attribute__((constructor))
static void rstudio_hub_dockhide_install(void) {
    Class cls = objc_getClass("NSApplication");
    if (cls) {
        SEL sel = sel_registerName("setActivationPolicy:");
        Method method = class_getInstanceMethod(cls, sel);
        if (method) {
            orig_setActivationPolicy = (BOOL (*)(id, SEL, NSInteger))method_getImplementation(method);
            method_setImplementation(method, (IMP)always_accessory_setActivationPolicy);
        }
    }

    CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();

    CFNotificationCenterAddObserver(
        darwin,
        NULL,
        OnHideDockNotification,
        CFSTR("com.zhangjing.RStudioHub.hideDock"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    CFNotificationCenterAddObserver(
        darwin,
        NULL,
        OnAllowActivateNotification,
        CFSTR("com.zhangjing.RStudioHub.allowActivate"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    ObserveAppLaunch();
    dispatch_async(dispatch_get_main_queue(), ^{
        ScheduleAccessoryPolicyBurst();
    });
}
