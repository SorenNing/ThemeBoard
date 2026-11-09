#import "TBAppDelegate.h"
#import "TBRootController.h"
#import "TBThemeListController.h"
#import "TBThemeScanner.h"
#import "TBDocImport.h"
#import "TBPanelController.h"
#import "TBGlass.h"
#import "TBPrefs.h"


#pragma mark - App 诊断（不写日志文件）

void TBAppLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[ThemeBoard] %@", msg ?: @"");
}

#pragma mark - 在视图树里找主题列表页

/// 从窗口根 VC 往下找 TBThemeListController（root → nav → 列表）。
/// 外部 openURL 导入完成后要用它 reload + 当弹窗宿主。
static TBThemeListController *TBFindThemeListController(UIViewController *vc, NSInteger depth) {
    if (!vc || depth > 8) return nil;
    if ([vc isKindOfClass:[TBThemeListController class]]) return (TBThemeListController *)vc;
    for (UIViewController *child in vc.childViewControllers) {
        TBThemeListController *r = TBFindThemeListController(child, depth + 1);
        if (r) return r;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) {
        return TBFindThemeListController(((UINavigationController *)vc).topViewController, depth + 1);
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        return TBFindThemeListController(((UITabBarController *)vc).selectedViewController, depth + 1);
    }
    if (vc.presentedViewController) {
        return TBFindThemeListController(vc.presentedViewController, depth + 1);
    }
    return nil;
}


@implementation TBAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 0.15.59：搜索框恢复 100% 系统外观 —— 不再安装任何自绘玻璃
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor colorWithRed:0.870 green:0.858 blue:0.843 alpha:1];
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

#pragma mark - 外部打开（分享 / 用 ThemeBoard 打开）

// iOS 9+ 唯一入口：文件 App 里「共享 → ThemeBoard」、其它 App 的「用…打开」、
// Safari 下载后「打开方式」都会走这里。这条路不经过 UIDocumentPicker，
// 所以完全避开用户设备上「点文件被当成取消 / 257 无权限」的问题。
- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    TBAppLog(@"openURL(options) → %@", url.absoluteString ?: @"(nil)");
    return [self tb_handleIncomingURL:url];
}

// iOS 8 及更早的旧回调（个别 rootless 环境仍会走这条）
- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
  sourceApplication:(NSString *)sourceApplication
         annotation:(id)annotation {
    TBAppLog(@"openURL(legacy) → %@", url.absoluteString ?: @"(nil)");
    return [self tb_handleIncomingURL:url];
}

- (BOOL)tb_handleIncomingURL:(NSURL *)url {
    if (!url || !url.isFileURL) return NO;   // 目前只处理本地文件（zip / 文件夹）
    // 冷启动时 window / 列表页可能还没建好，推迟一拍再导入
    dispatch_async(dispatch_get_main_queue(), ^{
        [self tb_importIncomingURL:url];
    });
    return YES;
}

- (void)tb_importIncomingURL:(NSURL *)url {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *err = nil;
    NSString *dst = [TBThemeScanner importFromAnyURL:url error:&err];
    if (scoped) [url stopAccessingSecurityScopedResource];

    TBThemeListController *list = TBFindThemeListController(self.window.rootViewController, 0);
    [list reload];      // list 为 nil 时是空消息，安全

    UIViewController *host = list ? TBTopPresentingViewController(list) : self.window.rootViewController;
    if (!host) host = self.window.rootViewController;

    TBAppLog(@"外部导入结果 dst=%@ err=%@", dst ?: @"(nil)", err.localizedDescription ?: @"-");
    if (dst) {
        TBPresentAlert(host, @"导入完成",
                       [NSString stringWithFormat:@"已导入：%@", dst.lastPathComponent ?: dst]);
    } else {
        NSString *msg = TBImportFailureMessage(url, err, @"导入失败：读不到这个文件");
        msg = [msg stringByAppendingString:
               @"\n\n可改用：文件 App → 长按 zip → 共享 → ThemeBoard。"];
        TBPresentAlert(host, @"导入失败", msg);
    }
}

- (void)applyAppearance {
    BOOL follow = [TBPrefs boolForKey:@"FollowSystem" defaultValue:YES];
    self.window.overrideUserInterfaceStyle = follow ? UIUserInterfaceStyleUnspecified
                                                    : UIUserInterfaceStyleLight;
}

@end
