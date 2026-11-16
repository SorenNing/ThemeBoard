#import "TBRootController.h"
#import "TBThemeListController.h"
#import "TBSettingsController.h"
#import "TBStatusController.h"
#import "TBGlass.h"
#import "TBToast.h"

// ---- Tab 切换动画参数（水滴胶囊，总时长 400ms）----
static const NSTimeInterval kTBTabTotal       = 0.40;   // 胶囊总时长
static const NSTimeInterval kTBTabStretch     = 0.26;   // 前段：拉伸 + 位移到目标中心
static const NSTimeInterval kTBTabCollect     = 0.14;   // 后段：收宽 + 回弹（合计 400ms）
static const CGFloat        kTBTabStretchDamp = 1.00;   // 前段不弹（匀速到位，前沿先到）
static const CGFloat        kTBTabSettleDamp  = 0.82;   // 后段轻微回弹
static const CGFloat        kTBTabSquash      = 0.92;   // 高度变扁 8%
static const CGFloat        kTBTabIconPeak    = 0.86;   // 新图标先缩到 0.86
static const CGFloat        kTBTabIconDamp    = 0.75;   // 图标回弹阻尼
static const NSTimeInterval kTBTabTextDur     = 0.40;   // 文字颜色渐变
static const NSTimeInterval kTBTabPageDur     = 0.35;   // 页面移入/移出
static const CGFloat        kTBTabPageShift   = 12.0;   // 页面水平位移（pt）

@interface TBRootController ()
@property (nonatomic, strong) NSArray<UIViewController *> *pages;
@property (nonatomic, strong) UIView *dock;
@property (nonatomic, strong) NSArray<UIButton *> *dockButtons;
@property (nonatomic, strong) UIView *pill;              // 选中的「水滴」胶囊色块
@property (nonatomic, assign) NSInteger current;
@property (nonatomic, strong) UIViewPropertyAnimator *pillAnimator;
@property (nonatomic, assign) BOOL switching;
@property (nonatomic, assign) BOOL draggingDock;   // 底栏跟手拖动中
@property (nonatomic, assign) NSTimeInterval dockDragEndTime;  // 最近一次拖动松手时间（吞掉紧跟着的按钮抬起）
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

    // 0.15.54：删除 0.15.53 加的全屏 UIPanGestureRecognizer（tb_pagePan）。
    // 它加在主视图上，会和 UITableView 的 cell 左滑删除抢手势，导致「左滑删除"滑不动"、
    // 变成切页」。现在 Tab 根页面不再有任何左右滑手势：左右滑什么都不发生，
    // 列表的上下滚动 / cell 左滑删除全部还给 UITableView 自己处理。
    // 切 Tab 仍然只有两种入口：点 dock 按钮、dock 上拖动（tb_dockPan，手势挂在 dock 上）。

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

- (void)relayout {
    CGFloat bottomInset = 86;
    for (UIViewController *vc in self.pages) {
        vc.additionalSafeAreaInsets = UIEdgeInsetsMake(0, 0, bottomInset, 0);
        vc.view.frame = self.view.bounds;
    }
    // 胶囊色块跟着 dock 的尺寸走（旋转 / 尺寸变化时直接落到当前 Tab，不做动画）
    // 拖动中不要抢 pill 的 frame（否则布局一刷新胶囊就飞回当前 Tab）
    if (self.pill && self.dockButtons.count && !self.draggingDock) {
        self.pill.frame = [self pillFrameForTab:self.current];
    }
}

#pragma mark - 底部 dock

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

    // 「水滴」胶囊色块：垫在图标/文字下面，随 Tab 移动
    CGFloat w = dock.bounds.size.width / titles.count;
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(4, 4, w - 8, h - 8)];
    pill.layer.cornerRadius = (h - 8) / 2.0;
    pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.42],
                                           [UIColor colorWithWhite:1 alpha:0.13]);
    pill.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    pill.layer.borderColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                            [UIColor colorWithWhite:1 alpha:0.18]).CGColor;
    pill.userInteractionEnabled = NO;
    [dock addSubview:pill];
    self.pill = pill;

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

    // 底栏跟手滑动：按住左右拖 → 胶囊跟着手指走，松手吸附到最近 Tab 并播水滴动画
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(tb_dockPan:)];
    pan.cancelsTouchesInView = NO;
    [dock addGestureRecognizer:pan];

    self.dock = dock;
    self.dockButtons = btns;
    [self.view addSubview:dock];
    [self refreshDock];
}

/// 某个 Tab 的胶囊色块目标 frame（dock 内坐标）
- (CGRect)pillFrameForTab:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.dockButtons.count) idx = 0;
    UIButton *b = self.dockButtons[idx];
    if (!self.dock) return b.frame;
    return CGRectMake(CGRectGetMinX(b.frame) + 4, 4,
                      CGRectGetWidth(b.frame) - 8, CGRectGetHeight(self.dock.bounds) - 8);
}

/// 静止态刷新：选中项亮、其余暗（首帧 / 旋转时用，不带动画）
- (void)refreshDock {
    for (UIButton *b in self.dockButtons) {
        BOOL on = (b.tag == self.current);
        UIColor *c = on ? [UIColor labelColor] : [UIColor secondaryLabelColor];
        ((UIImageView *)[b viewWithTag:101]).tintColor = c;
        ((UILabel *)[b viewWithTag:102]).textColor = c;
        b.alpha = on ? 1.0 : 0.75;
        ((UIImageView *)[b viewWithTag:101]).transform = CGAffineTransformIdentity;
        // 拖动会临时改图标/文字 alpha，静止态必须归位
        ((UIImageView *)[b viewWithTag:101]).alpha = 1.0;
        ((UILabel *)[b viewWithTag:102]).alpha = 1.0;
    }
}

#pragma mark - Tab 切换（水滴：前沿先到、后沿慢半拍 + 轻微回弹，共 400ms）

#pragma mark - 边缘右滑返回（UINavigationControllerDelegate / 手势代理）

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    // 0.15.54：只剩系统自带的 interactivePop 手势（边缘右滑返回）。
    // 只有导航栈里真的 push 了页面（count > 1）才放行；Tab 根页面一律返回 NO，
    // 避免根页面手势把系统导航状态搞乱（卡死 / 吃掉列表触摸）。
    if ([gr isKindOfClass:[UIScreenEdgePanGestureRecognizer class]] ||
        [gr.view isKindOfClass:[UINavigationBar class]]) {
        UINavigationController *nav = nil;
        for (UINavigationController *cand in self.pages) {
            if (cand.interactivePopGestureRecognizer == gr) { nav = cand; break; }
        }
        if (nav) return (nav.viewControllers.count > 1);
    }
    return YES;
}

- (void)tabTapped:(UIButton *)sender {
    // 拖动中（第二根手指）或拖动刚松手（cancelsTouchesInView=NO，抬起会同时落进按钮）都不算点击
    if (self.draggingDock || CACurrentMediaTime() - self.dockDragEndTime < 0.35) return;
    NSInteger idx = sender.tag;
    if (idx == self.current) {
        UINavigationController *nav = (UINavigationController *)self.pages[idx];
        [nav popToRootViewControllerAnimated:YES];
        return;
    }
    [self tb_switchToTab:idx];
}

- (void)tb_dockPan:(UIPanGestureRecognizer *)g {
    NSInteger n = (NSInteger)self.dockButtons.count;
    if (n < 1) return;
    CGFloat w = self.dock.bounds.size.width / n;
    CGFloat h = self.dock.bounds.size.height;
    CGPoint p = [g locationInView:self.dock];

    if (g.state == UIGestureRecognizerStateBegan) {
        // 拖动开始：取消在途的水滴胶囊动画，从「看得见的位置」接管（不因 switching 拒绝手势）
        self.draggingDock = YES;
        if (self.pillAnimator) {
            [self.pillAnimator stopAnimation:YES];
            self.pillAnimator = nil;
        }
        [self.pill.layer removeAllAnimations];
        CALayer *pres = self.pill.layer.presentationLayer;
        self.pill.frame = pres ? pres.frame : [self pillFrameForTab:self.current];
        self.switching = NO;
    }
    if (!self.draggingDock) return;
    if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat x = MIN(MAX(p.x - w / 2.0, 0.0), self.dock.bounds.size.width - w);
        self.pill.frame = CGRectMake(x + 4, 4, w - 8, h - 8);     // 胶囊跟手（等宽，不做拉伸形变）
        // 图标/文字按与胶囊中心的距离淡入淡出（拖到哪边哪边亮）
        CGFloat pc = CGRectGetMidX(self.pill.frame);
        for (UIButton *b in self.dockButtons) {
            CGFloat d = fabs(CGRectGetMidX(b.frame) - pc) / w;    // 0 = 正对，1 = 隔一个
            CGFloat on = MAX(0.0, 1.0 - d);
            ((UIImageView *)[b viewWithTag:101]).alpha = 0.45 + 0.55 * on;
            ((UILabel *)[b viewWithTag:102]).alpha = 0.45 + 0.55 * on;
        }
        return;
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {
        if (!self.draggingDock) return;
        self.draggingDock = NO;
        self.dockDragEndTime = CACurrentMediaTime();
        // 图标/文字亮度归位（拖动中的 0.45~1.0 过渡值不能带进切页动画）
        for (UIButton *b in self.dockButtons) {
            ((UIImageView *)[b viewWithTag:101]).alpha = 1.0;
            ((UILabel *)[b viewWithTag:102]).alpha = 1.0;
        }
        if (g.state != UIGestureRecognizerStateEnded) {          // 被系统取消：静默吸回当前 Tab
            [UIView animateWithDuration:0.22 delay:0
                                options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                             animations:^{ self.pill.frame = [self pillFrameForTab:self.current]; }
                             completion:nil];
            return;
        }
        CGFloat vx = [g velocityInView:self.dock].x;
        NSInteger idx = (NSInteger)floor(p.x / w);
        if (vx > 320.0) idx = (NSInteger)floor(p.x / w) + 1;        // 向右快甩 → 往下一格
        else if (vx < -320.0) idx = (NSInteger)floor(p.x / w) - 1;  // 向左快甩 → 往上一格（原先少减一，甩了等于没甩）
        idx = MAX(0, MIN(idx, n - 1));
        if (idx == self.current) {                                   // 没换页：吸附回原位
            [UIView animateWithDuration:0.22 delay:0
                                options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                             animations:^{ self.pill.frame = [self pillFrameForTab:self.current]; }
                             completion:^(BOOL f) { [self refreshDock]; }];
            return;
        }
        [self tb_switchToTab:idx];                                   // 水滴动画自己会从手指位置接管并更新 self.current
    }
}

- (void)tb_switchToTab:(NSInteger)idx {
    if (idx < 0 || idx >= (NSInteger)self.pages.count) return;
    NSInteger from = self.current;
    if (idx == from) return;

    [TBToast dismissNow];        // 切页时不要留旧 toast

    UIViewController *old = self.pages[from];
    UIViewController *now = self.pages[idx];
    CGFloat dir = (idx > from) ? 1.0 : -1.0;    // 新页面从点击方向进来

    // 快速连点时先归一化其他页，避免上一次动画留下的半透明/位移残留
    for (UIViewController *vc in self.pages) {
        if (vc == now || vc == old) continue;
        vc.view.hidden = YES;
        vc.view.alpha = 1.0;
        vc.view.transform = CGAffineTransformIdentity;
    }

    // ---- 1) 新页面：从点击方向偏移 12pt 移入并淡入（0.35s）；旧页面反向轻推淡出 ----
    now.view.hidden = NO;
    [now.view setNeedsLayout];
    [now.view layoutIfNeeded];
    now.view.alpha = 0.0;
    now.view.transform = CGAffineTransformMakeTranslation(kTBTabPageShift * dir, 0);

    __weak typeof(self) wself = self;
    [UIView animateWithDuration:kTBTabPageDur
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        __strong typeof(self) s = wself;
        if (!s) return;
        now.view.alpha = 1.0;
        now.view.transform = CGAffineTransformIdentity;
        old.view.alpha = 0.0;
        old.view.transform = CGAffineTransformMakeTranslation(-kTBTabPageShift * dir, 0);
    } completion:^(BOOL finished) {
        __strong typeof(self) s = wself;
        if (!s) return;
        // 连点时上一轮的旧页可能已经是当前页，别再把它藏起来
        if (s.pages[s.current].view != old.view) old.view.hidden = YES;
        old.view.alpha = 1.0;
        old.view.transform = CGAffineTransformIdentity;
    }];

    // ---- 2) 文字颜色：旧 → 未选中色，新 → 选中色，400ms 交叉渐变 ----
    for (UIButton *b in self.dockButtons) {
        BOOL on = (b.tag == idx);
        UILabel *lb = (UILabel *)[b viewWithTag:102];
        UIImageView *iv = (UIImageView *)[b viewWithTag:101];
        UIColor *c = on ? [UIColor labelColor] : [UIColor secondaryLabelColor];
        [UIView transitionWithView:lb duration:kTBTabTextDur
                           options:UIViewAnimationOptionTransitionCrossDissolve |
                                   UIViewAnimationOptionBeginFromCurrentState
                        animations:^{ lb.textColor = c; } completion:nil];
        [UIView transitionWithView:iv duration:kTBTabTextDur
                           options:UIViewAnimationOptionTransitionCrossDissolve |
                                   UIViewAnimationOptionBeginFromCurrentState
                        animations:^{ iv.tintColor = c; } completion:nil];
        [UIView animateWithDuration:kTBTabTotal
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ b.alpha = on ? 1.0 : 0.75; }
                         completion:nil];
    }

    // ---- 3) 图标：新选中图标先缩到 0.86 再弹回 1.0（damping 0.75，与胶囊同步）----
    UIImageView *newIcon = (UIImageView *)[self.dockButtons[idx] viewWithTag:101];
    newIcon.transform = CGAffineTransformMakeScale(kTBTabIconPeak, kTBTabIconPeak);
    UISpringTimingParameters *iconSpring =
        [[UISpringTimingParameters alloc] initWithDampingRatio:kTBTabIconDamp];
    UIViewPropertyAnimator *iconAnim =
        [[UIViewPropertyAnimator alloc] initWithDuration:kTBTabTotal timingParameters:iconSpring];
    [iconAnim addAnimations:^{
        newIcon.transform = CGAffineTransformIdentity;
    }];
    [iconAnim startAnimation];

    // ---- 4) 胶囊色块：前沿先到、后沿慢半拍（宽度先拉长再收回）、高度压扁 8%、回弹停稳 ----
    [self tb_animatePillFromTab:from toTab:idx];

    self.current = idx;
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [g impactOccurred];
}

/// 胶囊两段式动画：
///   前段 260ms —— 从旧位置拉伸到「旧 ∪ 新」的合并区间，并整体位移到新 Tab 中心（高度压扁 8%）
///   后段 140ms —— 宽度收回到目标胶囊、高度回弹（damping 0.82）
/// 合计 400ms，全程用系统 UIViewPropertyAnimator + 弹簧时序，无第三方库。
- (void)tb_animatePillFromTab:(NSInteger)from toTab:(NSInteger)to {
    if (!self.pill || ![self.dockButtons count]) return;

    CGRect a = [self pillFrameForTab:from];
    CGRect b = [self pillFrameForTab:to];
    CALayer *pres = self.pill.layer.presentationLayer;
    CGRect nowFrame = pres ? pres.frame : self.pill.frame;

    // 打断上一次（快速连点）：先落到看得见的位置，避免跳变
    if (self.pillAnimator) {
        [self.pillAnimator stopAnimation:NO];
        self.pillAnimator = nil;
    }
    [self.pill.layer removeAllAnimations];
    self.pill.frame = nowFrame;      // 落到看得见的位置再重新起跑
    self.switching = YES;

    // 合并区间（拉伸段）：取两者并集，保证「前沿先到、后沿慢半拍」
    CGFloat left  = MIN(CGRectGetMinX(nowFrame), MIN(CGRectGetMinX(a), CGRectGetMinX(b)));
    CGFloat right = MAX(CGRectGetMaxX(nowFrame), MAX(CGRectGetMaxX(a), CGRectGetMaxX(b)));
    CGFloat midY  = CGRectGetMidY(b);
    CGFloat h     = CGRectGetHeight(b) * kTBTabSquash;   // 高度压扁 8%
    CGRect stretch = CGRectMake(left, midY - h / 2.0, right - left, h);

    __weak typeof(self) wself = self;
    UISpringTimingParameters *p1 =
        [[UISpringTimingParameters alloc] initWithDampingRatio:kTBTabStretchDamp];
    UIViewPropertyAnimator *a1 = [[UIViewPropertyAnimator alloc] initWithDuration:kTBTabStretch
                                                               timingParameters:p1];
    self.pillAnimator = a1;
    [a1 addAnimations:^{
        __strong typeof(self) s = wself;
        if (!s) return;
        s.pill.frame = stretch;    // 前沿先冲到目标、后沿还在原地 → 视觉上拉长
    }];
    [a1 addCompletion:^(UIViewAnimatingPosition pos) {
        __strong typeof(self) s = wself;
        if (!s) return;
        if (pos != UIViewAnimatingPositionEnd || s.pillAnimator != a1) {
            // 被打断（连点/拖动接管）：只清状态，不许动 pill 的 frame
            if (s.pillAnimator == a1) { s.switching = NO; s.pillAnimator = nil; }
            return;
        }

        UISpringTimingParameters *p2 =
            [[UISpringTimingParameters alloc] initWithDampingRatio:kTBTabSettleDamp];
        UIViewPropertyAnimator *a2 = [[UIViewPropertyAnimator alloc] initWithDuration:kTBTabCollect
                                                                   timingParameters:p2];
        s.pillAnimator = a2;
        [a2 addAnimations:^{
            s.pill.frame = b;      // 收宽 + 高度回弹，轻微停稳
        }];
        [a2 addCompletion:^(UIViewAnimatingPosition p) {
            __strong typeof(self) ss = s;
            if (!ss) return;
            if (p != UIViewAnimatingPositionEnd || ss.pillAnimator != a2) {
                // 被打断（拖动接管/连点）：保持当前可见位置，别跳到旧目标
                if (ss.pillAnimator == a2) { ss.switching = NO; ss.pillAnimator = nil; }
                return;
            }
            ss.switching = NO;
            ss.pillAnimator = nil;
            ss.pill.frame = b;
        }];
        [a2 startAnimation];
    }];
    [a1 startAnimation];
}

@end