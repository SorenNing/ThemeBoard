#import "TBRootController.h"
#import "TBThemeListController.h"
#import "TBSettingsController.h"
#import "TBStatusController.h"

@implementation TBRootController

- (void)viewDidLoad {
    [super viewDidLoad];

    TBThemeListController *themes = [[TBThemeListController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav1 = [[UINavigationController alloc] initWithRootViewController:themes];
    nav1.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"主题"
                                                   image:[UIImage systemImageNamed:@"square.grid.2x2"]
                                           selectedImage:[UIImage systemImageNamed:@"square.grid.2x2.fill"]];

    TBSettingsController *settings = [[TBSettingsController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav2 = [[UINavigationController alloc] initWithRootViewController:settings];
    nav2.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"设置"
                                                   image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                                           selectedImage:[UIImage systemImageNamed:@"slider.horizontal.3"]];

    TBStatusController *status = [[TBStatusController alloc] init];
    UINavigationController *nav3 = [[UINavigationController alloc] initWithRootViewController:status];
    nav3.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"状态"
                                                   image:[UIImage systemImageNamed:@"waveform.path.ecg"]
                                           selectedImage:[UIImage systemImageNamed:@"waveform.path.ecg"]];

    self.viewControllers = @[nav1, nav2, nav3];
    self.tabBar.tintColor = [UIColor labelColor];
}

@end
