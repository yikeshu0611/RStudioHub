#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

static BOOL g_keepRegular = NO;

static void rsh_set_policy(NSApplicationActivationPolicy policy) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_keepRegular) {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        } else {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        }
    });
}

__attribute__((constructor))
static void rsh_init(void) {
    rsh_set_policy(NSApplicationActivationPolicyAccessory);

    NSDistributedNotificationCenter *center = [NSDistributedNotificationCenter defaultCenter];
    [center addObserverForName:@"com.zhangjing.RStudioHub.hideDock"
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *note) {
        g_keepRegular = NO;
        rsh_set_policy(NSApplicationActivationPolicyAccessory);
    }];
    [center addObserverForName:@"com.zhangjing.RStudioHub.showDock"
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *note) {
        g_keepRegular = YES;
        rsh_set_policy(NSApplicationActivationPolicyRegular);
    }];
}
