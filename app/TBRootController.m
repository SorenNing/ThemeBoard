#import "TBRootController.h"
#import "TBThemeListController.h"
#import "TBSettingsController.h"
#import "TBStatusController.h"
#import "TBGlass.h"
#import "TBToast.h"
#import "TBTheseusDock.h"

@interface TBRootController () <UINavigationControllerDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) NSArray<UIViewController *> *pages;
@property (nonatomic, strong) TBTheseusDock *dock;
@property (nonatomic, assign) NSInteger current;
@property (nonatomic, assign) NSUInteger pageGeneration;
@end

@implementation TBRootController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    TBThemeListController *themes = [[TBThemeListController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav1 = [[UINavigationController alloc] initWithRootViewController:themes];

    TBSettingsController *settings = [[TBSettingsController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *nav2 = [[UINavigationController alloc] initWithRootViewController:settings];

    TBStatusController *status = [[TBStatusController alloc] init];
    UINavigationController *nav3 = [[UINavigationController alloc] initWithRootViewController:status];

    // 导航栏全透明，磨砂从 window 透上来
    UINavigationBarAppearance *ap = [[UINavigationBarAppearance alloc] init];
    [ap configureWithTransparentBackground];
    ap.backgroundColor = [UIColor clearColor];
    ap.shadowColor = [UIColor clearColor];
    for (UINavigationController *nav in @[nav1, nav2, nav3]) {
        nav.navigationBar.standardAppearance = ap;
        nav.navigationBar.scrollEdgeAppearance = ap;
        nav.navigationBar.compactAppearance = ap;
        nav.navigationBar.translucent = YES;
    }

    for (UINavigationController *nav in @[nav1, nav2, nav3]) {
        nav.view.backgroundColor = [UIColor clearColor];
        TBAttachFrostContainer(nav.view);
    }

    self.pages = @[nav1, nav2, nav3];

    for (UIViewController *vc in self.pages) {
        [self addChildViewController:vc];
        vc.view.frame = self.view.bounds;
        vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        vc.view.hidden = YES;
        [self.view addSubview:vc.view];
        [vc didMoveToParentViewController:self];
    }
    self.pages.firstObject.view.hidden = NO;
    self.current = 0;

    // 各 nav 启用系统自带的边缘右滑返回：只有 push 出二级页面后才生效（根页面返回 NO，防卡死）
    for (UINavigationController *nav in self.pages) {
        nav.delegate = self;
        nav.interactivePopGestureRecognizer.enabled = YES;
        nav.interactivePopGestureRecognizer.delegate = self;
    }

    [self buildDock];
    [self relayout];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self relayout];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self relayout];
}

- (void)relayout {
    if (!self.dock) return;
    CGFloat height = 64.0;
    CGFloat width = MAX(0, self.view.bounds.size.width - 36.0);
    CGFloat bottom = 34.0;
    CGRect frame = CGRectMake(18.0,
                              self.view.bounds.size.height - bottom - height,
                              width, height);
    if (!CGRectEqualToRect(self.dock.frame, frame)) self.dock.frame = frame;
    CGFloat extraBottom = MAX(0, height + bottom + 12 - self.view.safeAreaInsets.bottom);
    for (UIViewController *vc in self.pages) {
        UIEdgeInsets insets = UIEdgeInsetsMake(0, 0, extraBottom, 0);
        if (!UIEdgeInsetsEqualToEdgeInsets(vc.additionalSafeAreaInsets, insets)) vc.additionalSafeAreaInsets = insets;
        if (!CGRectEqualToRect(vc.view.frame, self.view.bounds)) vc.view.frame = self.view.bounds;
    }
}

- (void)buildDock {
    self.dock = [[TBTheseusDock alloc] initWithFrame:CGRectZero];
    __weak TBRootController *weakSelf = self;
    self.dock.onSelection = ^(NSInteger index) { [weakSelf tb_switchToTab:index]; };
    self.dock.onReselection = ^(NSInteger index) {
        TBRootController *owner = weakSelf;
        if (!owner || index != owner.current || index < 0 || index >= (NSInteger)owner.pages.count) return;
        [(UINavigationController *)owner.pages[index] popToRootViewControllerAnimated:YES];
    };
    [self.view addSubview:self.dock];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    for (UINavigationController *nav in self.pages) {
        if (nav.interactivePopGestureRecognizer == gr) return nav.viewControllers.count > 1;
    }
    return YES;
}

- (void)tb_switchToTab:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.pages.count || index == self.current) return;
    [TBToast dismissNow];
    UIViewController *old = self.pages[self.current];
    UIViewController *now = self.pages[index];
    CGFloat direction = index > self.current ? 1 : -1;
    NSUInteger generation = ++self.pageGeneration;
    self.current = index;
    self.dock.selectedIndex = index;
    for (UIViewController *vc in self.pages) {
        [vc.view.layer removeAllAnimations];
        vc.view.hidden = vc != old && vc != now;
        vc.view.alpha = 1;
        vc.view.transform = CGAffineTransformIdentity;
    }
    now.view.hidden = NO;
    [now.view layoutIfNeeded];
    now.view.alpha = 0;
    now.view.transform = CGAffineTransformMakeTranslation(12 * direction, 0);
    [self.dock invalidateBackground];
    [UIView animateWithDuration:UIAccessibilityIsReduceMotionEnabled() ? 0 : 0.35
                          delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        now.view.alpha = 1;
        now.view.transform = CGAffineTransformIdentity;
        old.view.alpha = 0;
        old.view.transform = CGAffineTransformMakeTranslation(-12 * direction, 0);
    } completion:^(BOOL finished) {
        if (generation != self.pageGeneration) return;
        old.view.hidden = YES;
        old.view.alpha = 1;
        old.view.transform = CGAffineTransformIdentity;
        [self.dock invalidateBackground];
    }];
}

@end
