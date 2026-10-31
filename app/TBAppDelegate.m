#import "TBAppDelegate.h"
#import "TBRootController.h"
#import "TBGlass.h"
#import "TBPrefs.h"

@implementation TBAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor colorWithRed:0.898 green:0.886 blue:0.867 alpha:1];
    self.window.rootViewController = [[TBRootController alloc] init];
    [self.window makeKeyAndVisible];

    // 背景铺在 window 上，导航栏/标签栏都透明，磨砂才不会被内容滚动带跑
    TBAttachWindowFrost(self.window);

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyAppearance)
                                                 name:@"TBAppearanceChanged"
                                               object:nil];
    [self applyAppearance];
    return YES;
}

- (void)applyAppearance {
    BOOL follow = [TBPrefs boolForKey:@"FollowSystem" defaultValue:YES];
    self.window.overrideUserInterfaceStyle = follow ? UIUserInterfaceStyleUnspecified
                                                    : UIUserInterfaceStyleLight;
}

@end
