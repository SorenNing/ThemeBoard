#import "TBAppDelegate.h"
#import "TBRootController.h"
#import "TBGlass.h"

@implementation TBAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor systemBackgroundColor];
    self.window.rootViewController = [[TBRootController alloc] init];
    [self.window makeKeyAndVisible];

    // 背景铺在 window 上，导航栏/标签栏都透明，磨砂才不会被内容滚动带跑
    TBAttachWindowFrost(self.window);

    UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
    [ap configureWithTransparentBackground];
    ap.backgroundColor = [UIColor clearColor];
    ap.shadowColor = [UIColor clearColor];
    for (UIViewController *vc in ((UITabBarController *)self.window.rootViewController).viewControllers) {
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UINavigationBar *bar = ((UINavigationController *)vc).navigationBar;
            bar.standardAppearance = ap;
            bar.scrollEdgeAppearance = ap;
            bar.compactAppearance = ap;
            bar.translucent = YES;
        }
    }
    return YES;
}

@end
