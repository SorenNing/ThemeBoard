#import "TBToast.h"
#import "TBGlass.h"

// 高度 / 内边距（设计参数固定）
static const CGFloat kTBToastHeight     = 48.0;
static const CGFloat kTBToastPadX       = 22.0;
static const CGFloat kTBToastIconSize   = 14.0;
static const CGFloat kTBToastIconGap    = 7.0;
static const CGFloat kTBToastDockH      = 64.0;   // 与 TBRootController 的 dock 一致
static const CGFloat kTBToastDockBottom = 34.0;   // 与 TBRootController 的 dock 下边距一致
static const CGFloat kTBToastDockGap    = 44.0;   // 0.15.91：16→44，远离底部手势区（原来贴着底栏会干扰上滑返回/退出）

static const NSTimeInterval kTBToastInDuration  = 0.32;
static const CGFloat        kTBToastInDamping   = 0.78;
static const NSTimeInterval kTBToastHold        = 1.5;
static const NSTimeInterval kTBToastOutDuration = 0.25;
static const CGFloat        kTBToastOutDamping  = 0.90;

static TBToast *_gToast = nil;
static NSInteger _gToastGen = 0;

@interface TBToastView : UIView
@property (nonatomic, strong) UIVisualEffectView *blur;
@property (nonatomic, strong) UIView *fill;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, assign) NSInteger gen;
@end

@implementation TBToastView

- (instancetype)initWithText:(NSString *)text icon:(NSString *)iconName {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = kTBToastHeight / 2.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;   // 只有提示，不挡点击

        self.blur = [[UIVisualEffectView alloc] initWithEffect:
                     [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
        self.blur.userInteractionEnabled = NO;
        [self addSubview:self.blur];

        self.fill = [[UIView alloc] initWithFrame:CGRectZero];
        self.fill.userInteractionEnabled = NO;
        self.fill.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.58],
                                                   [UIColor colorWithWhite:1 alpha:0.14]);
        [self addSubview:self.fill];

        UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        CGSize ts = [text sizeWithAttributes:@{ NSFontAttributeName: font }];
        CGFloat textW = ceil(ts.width) + 2.0;   // 抗锯齿余量

        CGFloat w = textW + kTBToastPadX * 2;
        CGFloat x = kTBToastPadX;
        if (iconName.length) {
            self.icon = [[UIImageView alloc] initWithImage:
                         [[UIImage systemImageNamed:iconName]
                          imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
            self.icon.tintColor = [UIColor labelColor];
            self.icon.contentMode = UIViewContentModeScaleAspectFit;
            self.icon.frame = CGRectMake(kTBToastPadX,
                                         (kTBToastHeight - kTBToastIconSize) / 2.0,
                                         kTBToastIconSize, kTBToastIconSize);
            [self addSubview:self.icon];
            w += kTBToastIconSize + kTBToastIconGap;
            x = kTBToastPadX + kTBToastIconSize + kTBToastIconGap;
        }

        self.label = [[UILabel alloc] initWithFrame:
                      CGRectMake(x, 0, textW, kTBToastHeight)];
        self.label.font = font;
        self.label.text = text;
        self.label.textColor = [UIColor labelColor];
        self.label.textAlignment = NSTextAlignmentLeft;
        self.label.backgroundColor = [UIColor clearColor];
        [self addSubview:self.label];

        self.bounds = CGRectMake(0, 0, ceil(w), kTBToastHeight);   // 宽度只由内容决定
        TBApplyRim(self, 0.55);
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.blur.frame = self.bounds;
    self.fill.frame = self.bounds;
}

@end

@implementation TBToast

+ (void)tb_installLifecycleObserver {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    // 0.16.10：退到后台时【只隐藏不改视图树】—— 在手势过渡期间 removeFromSuperview 会造成那一帧抖动。
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        for (UIView *w in [UIApplication sharedApplication].windows) {
            for (UIView *sub in w.subviews) {
                if ([sub isKindOfClass:[TBToastView class]]) sub.hidden = YES;
            }
        }
        for (UIView *w in [UIApplication sharedApplication].windows) {
            for (UIView *sub in w.subviews) {
                for (UIView *d in sub.subviews) {
                    if ([d isKindOfClass:[TBToastView class]]) d.hidden = YES;
                }
            }
        }
    }];
}

+ (void)show:(NSString *)text icon:(NSString *)systemImageName in:(UIViewController *)host {
    [self tb_installLifecycleObserver];
    if (!text.length) return;
    // 0.16.10：改挂到 host.view（App 自己的层级），不再挂 window ——
    // 挂 window 时它是"最上层视图"，上滑返回/退出时第一下手势会被它吃掉（用户实测要滑两次）。
    UIView *root = host.view;
    if (!root) return;

    // 同一时间只留一个：旧的直接摘掉（不做退场动画，避免两个叠在一起）
    [TBToast dismissNow];

    TBToastView *t = [[TBToastView alloc] initWithText:text icon:systemImageName];
    _gToastGen++;
    t.gen = _gToastGen;

    CGFloat W = root.bounds.size.width;
    CGFloat H = root.bounds.size.height;
    // ★ 0.16.9：胶囊改到【屏幕顶部】（导航栏下方）—— 底部位置会干扰上滑返回/退出手势。
    CGFloat topSafe = root.safeAreaInsets.top;
    CGFloat y = topSafe + 56.0;                 // 导航栏下方
    if (y + kTBToastHeight > H - 40) y = MAX(topSafe + 8, H - 40 - kTBToastHeight);
    t.center = CGPointMake(W / 2.0, y + kTBToastHeight / 2.0);
    t.alpha = 0.0;
    t.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.94, 0.94),
                                          CGAffineTransformMakeTranslation(0, -18));
    [root addSubview:t];

    UISpringTimingParameters *inP =
        [[UISpringTimingParameters alloc] initWithDampingRatio:kTBToastInDamping];
    UIViewPropertyAnimator *inA = [[UIViewPropertyAnimator alloc] initWithDuration:kTBToastInDuration
                                                                  timingParameters:inP];
    [inA addAnimations:^{
        t.alpha = 1.0;
        t.transform = CGAffineTransformIdentity;
    }];
    [inA startAnimation];

    NSInteger gen = t.gen;
    __weak TBToastView *weakT = t;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kTBToastInDuration + kTBToastHold) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        TBToastView *tv = weakT;
        if (!tv || tv.gen != gen || _gToastGen != gen || !tv.superview) return;

        UISpringTimingParameters *outP =
            [[UISpringTimingParameters alloc] initWithDampingRatio:kTBToastOutDamping];
        UIViewPropertyAnimator *outA = [[UIViewPropertyAnimator alloc] initWithDuration:kTBToastOutDuration
                                                                      timingParameters:outP];
        [outA addAnimations:^{
            tv.alpha = 0.0;
            tv.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.94, 0.94),
                                                   CGAffineTransformMakeTranslation(0, 14));
        }];
        [outA addCompletion:^(UIViewAnimatingPosition pos) {
            [tv removeFromSuperview];
        }];
        [outA startAnimation];
    });
}

+ (void)showAppliedIn:(UIViewController *)host {
    [TBToast show:@"已应用" icon:@"checkmark" in:host];
}

+ (void)showCancelledIn:(UIViewController *)host {
    [TBToast show:@"已取消" icon:nil in:host];
}

+ (void)dismissNow {
    _gToastGen++;   // 让所有在途的 hold 定时器失效
    for (UIView *v in [UIApplication sharedApplication].windows) {
        [self removeToastsIn:v];
    }
}

+ (void)removeToastsIn:(UIView *)v {
    NSArray *kids = [[v subviews] copy];
    NSUInteger i, n = [kids count];
    for (i = 0; i < n; i++) {
        UIView *child = [kids objectAtIndex:i];
        if ([child isKindOfClass:[TBToastView class]]) {
            [child removeFromSuperview];
        } else {
            [self removeToastsIn:child];
        }
    }
}

@end