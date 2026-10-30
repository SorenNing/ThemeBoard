#import "TBRootController.h"
#import "TBThemeListController.h"
#import "TBSettingsController.h"
#import "TBStatusController.h"
#import "TBGlass.h"

@interface TBRootController ()
@property (nonatomic, strong) NSArray<UIViewController *> *pages;
@property (nonatomic, strong) UIView *dock;
@property (nonatomic, strong) NSArray<UIButton *> *dockButtons;
@property (nonatomic, assign) NSInteger current;
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

    [self buildDock];
    [self relayout];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self relayout];
}

- (void)relayout {
    CGFloat bottomInset = 86;
    for (UIViewController *vc in self.pages) {
        vc.additionalSafeAreaInsets = UIEdgeInsetsMake(0, 0, bottomInset, 0);
        vc.view.frame = self.view.bounds;
    }
}

- (void)buildDock {
    CGFloat h = 64, margin = 18;
    UIView *dock = [[UIView alloc] initWithFrame:CGRectMake(margin, self.view.bounds.size.height - h - 34,
                                                          self.view.bounds.size.width - margin * 2, h)];
    dock.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    dock.layer.cornerRadius = h / 2;
    dock.layer.cornerCurve = kCACornerCurveContinuous;
    dock.clipsToBounds = YES;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    blur.frame = dock.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [dock addSubview:blur];

    UIView *fill = [[UIView alloc] initWithFrame:dock.bounds];
    fill.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    fill.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                          [UIColor colorWithWhite:1 alpha:0.12]);
    fill.userInteractionEnabled = NO;
    [dock addSubview:fill];
    TBApplyRim(dock, 0.55);

    NSArray *titles = @[@"主题", @"设置", @"状态"];
    NSArray *icons = @[@"square.grid.2x2.fill", @"slider.horizontal.3", @"waveform.path.ecg"];
    NSMutableArray *btns = [NSMutableArray array];

    CGFloat w = dock.bounds.size.width / titles.count;
    for (NSInteger i = 0; i < titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(i * w, 0, w, h);
        b.tag = i;
        [b addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImageView *iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:icons[i]]];
        iv.tag = 101;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.frame = CGRectMake(w / 2 - 11, 12, 22, 22);
        iv.userInteractionEnabled = NO;
        [b addSubview:iv];

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(0, 36, w, 14)];
        lb.tag = 102;
        lb.text = titles[i];
        lb.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        lb.textAlignment = NSTextAlignmentCenter;
        lb.userInteractionEnabled = NO;
        [b addSubview:lb];

        [dock addSubview:b];
        [btns addObject:b];
    }

    self.dock = dock;
    self.dockButtons = btns;
    [self.view addSubview:dock];
    [self refreshDock];
}

- (void)refreshDock {
    for (UIButton *b in self.dockButtons) {
        BOOL on = (b.tag == self.current);
        UIColor *c = on ? [UIColor labelColor] : [UIColor secondaryLabelColor];
        ((UIImageView *)[b viewWithTag:101]).tintColor = c;
        ((UILabel *)[b viewWithTag:102]).textColor = c;
        b.alpha = on ? 1.0 : 0.75;
    }
}

- (void)tabTapped:(UIButton *)sender {
    NSInteger idx = sender.tag;
    if (idx == self.current) {
        UINavigationController *nav = (UINavigationController *)self.pages[idx];
        [nav popToRootViewControllerAnimated:YES];
        return;
    }
    self.pages[self.current].view.hidden = YES;
    self.pages[idx].view.hidden = NO;
    self.current = idx;
    [self refreshDock];
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [g impactOccurred];
}

@end
