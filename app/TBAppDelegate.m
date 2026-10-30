#import "TBAppDelegate.h"
#import "TBRootController.h"

@implementation TBAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[TBRootController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
