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
    self.hl.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.75],
                                             [UIColor colorWithWhite:1 alpha:0.22]);
    TBApplyRim(self, 0.95);
}
@end



UIColor *TBDynamicColor(UIColor *light, UIColor *dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
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
    return TBDynamicColor([UIColor colorWithWhite:1 alpha:0.42],
                          [UIColor colorWithWhite:1 alpha:0.12]);
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
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
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

    UIView *hl = [[UIView alloc] init];
    hl.translatesAutoresizingMaskIntoConstraints = NO;
    hl.userInteractionEnabled = NO;
    [card addSubview:hl];
    [NSLayoutConstraint activateConstraints:@[
        [hl.topAnchor constraintEqualToAnchor:card.topAnchor],
        [hl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [hl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [hl.heightAnchor constraintEqualToConstant:1.0],
    ]];

    card.fill = fill;
    card.hl = hl;
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

void TBSetPageBackground(UIViewController *vc) {
    if (!vc) return;
    UIView *bg = [[TBGradientView alloc] initWithFrame:CGRectMake(0, 0,
        [UIScreen mainScreen].bounds.size.width, [UIScreen mainScreen].bounds.size.height)];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    if ([vc isKindOfClass:[UITableViewController class]]) {
        UITableViewController *t = (UITableViewController *)vc;
        t.tableView.backgroundView = bg;
        t.tableView.backgroundColor = [UIColor clearColor];
    } else {
        vc.view.backgroundColor = [UIColor clearColor];
        [vc.view insertSubview:bg atIndex:0];
    }
}

void TBAttachFrostContainer(UIView *host) {
    if (!host) return;
    NSInteger tag = 0x7B41;
    for (UIView *v in host.subviews) if (v.tag == tag) return;

    UIView *bg = [[UIView alloc] initWithFrame:host.bounds];
    bg.tag = tag;
    bg.userInteractionEnabled = NO;
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = host.bounds;
    g.colors = @[ (id)[UIColor systemGroupedBackgroundColor].CGColor,
                  (id)[UIColor secondarySystemGroupedBackgroundColor].CGColor ];
    g.startPoint = CGPointMake(0, 0);
    g.endPoint = CGPointMake(0, 1);
    [bg.layer addSublayer:g];
    [host insertSubview:bg atIndex:0];
}

void TBAttachWindowFrost(UIWindow *window) {
    if (!window) return;
    window.backgroundColor = [UIColor systemGroupedBackgroundColor];
}

void TBAttachFrost(UIView *host) {
    host.backgroundColor = [UIColor systemGroupedBackgroundColor];
}

UIView *TBGlassCellBG(CGFloat inset) {
    UIView *bg = [[UIView alloc] init];
    bg.backgroundColor = [UIColor clearColor];
    bg.layer.shadowColor = [UIColor blackColor].CGColor;
    bg.layer.shadowOpacity = 0.07;
    bg.layer.shadowRadius = 8;
    bg.layer.shadowOffset = CGSizeMake(0, 2);
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
    tv.backgroundColor = [UIColor clearColor];
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    tv.backgroundView = nil;
}
