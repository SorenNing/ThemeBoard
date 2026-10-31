#import "TBGlass.h"

// 前置声明（这些函数定义在文件后半部分，视图子类要用）
static UIColor *TBPageTopColor(void);
static UIColor *TBPageBottomColor(void);
static UIColor *TBFillColor(void);
static UIColor *TBRimColor(CGFloat alpha);
void TBApplyRim(UIView *v, CGFloat alpha);

#pragma mark - 动态色视图（深浅色切换即时生效）

@interface TBGradientView : UIView
@end
@implementation TBGradientView {
    CAGradientLayer *_g;
    NSArray<UIView *> *_blobs;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _g = [CAGradientLayer layer];
        _g.startPoint = CGPointMake(0, 0);
        _g.endPoint = CGPointMake(1, 1);
        [self.layer addSublayer:_g];

        NSMutableArray *b = [NSMutableArray array];
        for (int i = 0; i < 3; i++) {
            UIView *dot = [[UIView alloc] initWithFrame:CGRectZero];
            dot.userInteractionEnabled = NO;
            dot.layer.cornerRadius = 220;
            dot.autoresizingMask = UIViewAutoresizingNone;
            [self addSubview:dot];
            [b addObject:dot];
        }
        _blobs = b;
        [self tb_update];
    }
    return self;
}

- (void)tb_update {
    _g.colors = @[ (id)TBPageTopColor().CGColor, (id)TBPageBottomColor().CGColor ];

    // 三个柔光斑（沿用旧版配色）
    NSArray *specs = @[ @[@(-0.15), @(-0.05), @(0.98), @(0.78), @(0.62)],
                        @[@( 0.55), @( 0.30), @(0.62), @(0.86), @(0.95)],
                        @[@( 0.15), @( 0.55), @(0.55), @(0.72), @(1.00)] ];
    for (NSUInteger i = 0; i < _blobs.count; i++) {
        NSArray *sp = specs[i];
        UIView *dot = _blobs[i];
        dot.backgroundColor = TBDynamicColor(
            [UIColor colorWithRed:[sp[2] doubleValue] green:[sp[3] doubleValue] blue:[sp[4] doubleValue] alpha:0.22],
            [UIColor colorWithRed:[sp[2] doubleValue] green:[sp[3] doubleValue] blue:[sp[4] doubleValue] alpha:0.14]);
        dot.tag = 1000 + (NSInteger)i;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    [super traitCollectionDidChange:prev];
    [self tb_update];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _g.frame = self.bounds;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    NSArray *specs = @[ @[@(-0.15), @(-0.05)], @[@(0.55), @(0.30)], @[@(0.15), @(0.55)] ];
    for (NSUInteger i = 0; i < _blobs.count; i++) {
        CGFloat x = [specs[i][0] doubleValue] * W;
        CGFloat y = [specs[i][1] doubleValue] * H;
        _blobs[i].frame = CGRectMake(x - 220, y - 220, 440, 440);
    }
}
@end

@interface TBGlassCardView : UIView
@property (nonatomic, strong) UIView *fill;
@property (nonatomic, strong) UIView *hl;
@end
@implementation TBGlassCardView
- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    [super traitCollectionDidChange:prev];
    [self tb_refresh];
}
- (void)tb_refresh {
    self.fill.backgroundColor = TBFillColor();
    TBApplyRim(self, 0.92);
}
@end



UIColor *TBDynamicColor(UIColor *light, UIColor *dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
}


static UIColor *TBPageBaseColor(void) {
    return TBDynamicColor([UIColor colorWithRed:0.870 green:0.858 blue:0.843 alpha:1],
                           [UIColor colorWithRed:0.110 green:0.104 blue:0.120 alpha:1]);
}

// MarkFont 色板：浅色暖米白 / 深色 #1B191E
static UIColor *TBPageTopColor(void) {
    return TBDynamicColor([UIColor colorWithRed:0.898 green:0.886 blue:0.867 alpha:1],
                           [UIColor colorWithRed:0.125 green:0.118 blue:0.137 alpha:1]);
}
static UIColor *TBPageBottomColor(void) {
    return TBDynamicColor([UIColor colorWithRed:0.855 green:0.843 blue:0.827 alpha:1],
                           [UIColor colorWithRed:0.098 green:0.090 blue:0.110 alpha:1]);
}

static UIColor *TBFillColor(void) {
    return TBDynamicColor([UIColor colorWithWhite:1 alpha:0.34],
                          [UIColor colorWithWhite:1 alpha:0.10]);
}

static UIColor *TBRimColor(CGFloat alpha) {
    return TBDynamicColor([UIColor colorWithWhite:1 alpha:alpha],
                          [UIColor colorWithWhite:1 alpha:alpha * 0.30]);
}

void TBApplyRim(UIView *v, CGFloat alpha) {
    CGFloat scale = [UIScreen mainScreen].scale;
    v.layer.borderWidth = 1.0 / scale;
    v.layer.borderColor = TBRimColor(alpha).CGColor;
}

UIView *TBGlassCard(CGFloat radius) {
    TBGlassCardView *card = [[TBGlassCardView alloc] init];
    card.layer.cornerRadius = radius;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    card.backgroundColor = [UIColor clearColor];

    UIVisualEffectView *blur =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    blur.translatesAutoresizingMaskIntoConstraints = NO;
    blur.userInteractionEnabled = NO;
    [card insertSubview:blur atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [blur.topAnchor constraintEqualToAnchor:card.topAnchor],
        [blur.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [blur.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [blur.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    UIView *fill = [[UIView alloc] init];
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    fill.userInteractionEnabled = NO;
    [card addSubview:fill];
    [NSLayoutConstraint activateConstraints:@[
        [fill.topAnchor constraintEqualToAnchor:card.topAnchor],
        [fill.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [fill.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [fill.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    card.fill = fill;
    card.hl = nil;
    [card tb_refresh];
    return card;
}

UIButton *TBGlassButton(NSString *title, BOOL danger) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [b setTitleColor:danger ? [UIColor systemRedColor] : [UIColor labelColor] forState:UIControlStateNormal];
    b.backgroundColor = danger
        ? TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55], [UIColor colorWithWhite:1 alpha:0.10])
        : TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62], [UIColor colorWithWhite:1 alpha:0.14]);
    b.layer.cornerRadius = 24;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    TBApplyRim(b, 0.55);
    return b;
}

static UIImage *TBPagePatternImage(void) {
    static UIImage *light = nil, *dark = nil;
    BOOL isDark = (UITraitCollection.currentTraitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    UIImage *cached = isDark ? dark : light;
    if (cached) return cached;

    CGSize size = [UIScreen mainScreen].bounds.size;
    if (size.width < 1) size = CGSizeMake(390, 844);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        UIColor *top = isDark ? [UIColor colorWithRed:0.125 green:0.118 blue:0.137 alpha:1]
                              : [UIColor colorWithRed:0.898 green:0.886 blue:0.867 alpha:1];
        UIColor *bot = isDark ? [UIColor colorWithRed:0.098 green:0.090 blue:0.110 alpha:1]
                              : [UIColor colorWithRed:0.855 green:0.843 blue:0.827 alpha:1];
        CGColorSpaceRef sp = CGColorSpaceCreateDeviceRGB();
        CGFloat comps[8] = {0,0,0,0,0,0,0,0};
        const CGFloat *t = CGColorGetComponents(top.CGColor);
        const CGFloat *b = CGColorGetComponents(bot.CGColor);
        comps[0]=t[0]; comps[1]=t[1]; comps[2]=t[2]; comps[3]=1;
        comps[4]=b[0]; comps[5]=b[1]; comps[6]=b[2]; comps[7]=1;
        CGGradientRef grad = CGGradientCreateWithColorComponents(sp, comps, NULL, 2);
        CGContextDrawLinearGradient(c, grad, CGPointMake(0, 0), CGPointMake(size.width, size.height), 0);
        CGGradientRelease(grad);
        CGColorSpaceRelease(sp);

        CGFloat alpha = isDark ? 0.18 : 0.30;
        CGColorSpaceRef sp2 = CGColorSpaceCreateDeviceRGB();
        NSArray *blobs = @[@[@(-0.15), @(-0.05), @(0.98), @(0.78), @(0.62)],
                           @[@( 0.55), @( 0.30), @(0.62), @(0.86), @(0.95)],
                           @[@( 0.15), @( 0.55), @(0.55), @(0.72), @(1.00)]];
        for (NSArray *bl in blobs) {
            CGPoint ctr = CGPointMake([bl[0] doubleValue] * size.width, [bl[1] doubleValue] * size.height);
            UIColor *col = [UIColor colorWithRed:[bl[2] doubleValue] green:[bl[3] doubleValue]
                                            blue:[bl[4] doubleValue] alpha:alpha];
            UIColor *clear = [col colorWithAlphaComponent:0.0];
            const CGFloat *cc = CGColorGetComponents(col.CGColor);
            const CGFloat *c0 = CGColorGetComponents(clear.CGColor);
            CGFloat comps[8] = { cc[0], cc[1], cc[2], cc[3], c0[0], c0[1], c0[2], 0.0 };
            CGGradientRef grad2 = CGGradientCreateWithColorComponents(sp2, comps, NULL, 2);
            CGContextDrawRadialGradient(c, grad2, ctr, 0, ctr, 260, 0);
            CGGradientRelease(grad2);
        }
        CGColorSpaceRelease(sp2);
    }];
    if (isDark) dark = img; else light = img;
    return img;
}

void TBApplyPageBackground(UIView *host) {
    if (!host) return;
    host.backgroundColor = TBPageBaseColor();
}

void TBSetPageBackground(UIViewController *vc) {
    if (!vc) return;
    vc.view.backgroundColor = TBPageBaseColor();
    if ([vc isKindOfClass:[UITableViewController class]]) {
        ((UITableViewController *)vc).tableView.backgroundColor = [UIColor clearColor];
    }
}

void TBAttachFrostContainer(UIView *host) {
    if (!host) return;
    host.backgroundColor = TBPageBaseColor();
}

void TBAttachWindowFrost(UIWindow *window) {
    if (!window) return;
    window.backgroundColor = TBPageBaseColor();
}

void TBAttachFrost(UIView *host) {
    host.backgroundColor = [UIColor systemGroupedBackgroundColor];
}

UIView *TBGlassCellBG(CGFloat inset) {
    UIView *bg = [[UIView alloc] init];
    bg.backgroundColor = [UIColor clearColor];
    UIView *card = TBGlassCard(20);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [bg addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:bg.topAnchor constant:2],
        [card.bottomAnchor constraintEqualToAnchor:bg.bottomAnchor constant:-2],
        [card.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:inset],
        [card.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-inset],
    ]];
    return bg;
}

void TBGlassTable(UITableView *tv) {
    // 表格背景必须透明，否则它会盖住页面底色（默认是白色）
    // 页面底色由 TBSetPageBackground / TBTableViewController 的背景视图提供
    tv.backgroundColor = [UIColor clearColor];
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    tv.backgroundView = nil;
}
