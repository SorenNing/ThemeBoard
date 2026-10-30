#import "TBGlass.h"

UIColor *TBDynamicColor(UIColor *light, UIColor *dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
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
    UIView *card = [[UIView alloc] init];
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
    fill.backgroundColor = TBFillColor();
    fill.userInteractionEnabled = NO;
    [card addSubview:fill];
    [NSLayoutConstraint activateConstraints:@[
        [fill.topAnchor constraintEqualToAnchor:card.topAnchor],
        [fill.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [fill.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [fill.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    TBApplyRim(card, 0.92);
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

void TBAttachWindowFrost(UIWindow *window) {
    if (!window) return;
    NSInteger tag = 0x7B3F;
    for (UIView *v in window.subviews) if (v.tag == tag) return;

    UIView *frost = [[UIView alloc] initWithFrame:window.bounds];
    frost.tag = tag;
    frost.userInteractionEnabled = NO;
    frost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    CAGradientLayer *base = [CAGradientLayer layer];
    base.frame = window.bounds;
    base.colors = @[ (id)TBDynamicColor([UIColor colorWithRed:0.949 green:0.937 blue:0.918 alpha:1],
                                        [UIColor colorWithRed:0.106 green:0.098 blue:0.118 alpha:1]).CGColor,
                     (id)TBDynamicColor([UIColor colorWithRed:0.918 green:0.906 blue:0.941 alpha:1],
                                        [UIColor colorWithRed:0.153 green:0.141 blue:0.173 alpha:1]).CGColor ];
    base.startPoint = CGPointMake(0, 0);
    base.endPoint = CGPointMake(1, 1);
    [frost.layer addSublayer:base];

    CGFloat W = window.bounds.size.width, H = window.bounds.size.height;
    NSArray *blobs = @[@[@(-0.15), @(-0.05), @(1.0), @(0.98), @(0.62)],
                       @[@(0.55), @(0.30), @(0.95), @(0.86), @(0.95)],
                       @[@(0.15), @(0.55), @(1.05), @(0.72), @(1.00)]];
    for (NSArray *b in blobs) {
        CGFloat x = [b[0] doubleValue] * W, y = [b[1] doubleValue] * H;
        CGFloat r = [b[2] doubleValue], g = [b[3] doubleValue], bl = [b[4] doubleValue];
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(x - 220, y - 220, 440, 440)];
        dot.backgroundColor = TBDynamicColor([UIColor colorWithRed:r green:g blue:bl alpha:0.22],
                                             [UIColor colorWithRed:r green:g blue:bl alpha:0.14]);
        dot.layer.cornerRadius = 220;
        dot.userInteractionEnabled = NO;
        [frost addSubview:dot];
    }

    [window insertSubview:frost atIndex:0];
}

void TBAttachFrost(UIView *host) {
    host.backgroundColor = [UIColor clearColor];

    UIView *frost = [[UIView alloc] initWithFrame:host.bounds];
    frost.translatesAutoresizingMaskIntoConstraints = NO;
    frost.userInteractionEnabled = NO;

    // 基色
    CAGradientLayer *base = [CAGradientLayer layer];
    base.frame = [UIScreen mainScreen].bounds;
    base.colors = @[ (id)TBDynamicColor([UIColor colorWithRed:0.949 green:0.937 blue:0.918 alpha:1],
                                        [UIColor colorWithRed:0.106 green:0.098 blue:0.118 alpha:1]).CGColor,
                     (id)TBDynamicColor([UIColor colorWithRed:0.918 green:0.906 blue:0.941 alpha:1],
                                        [UIColor colorWithRed:0.153 green:0.141 blue:0.173 alpha:1]).CGColor ];
    base.startPoint = CGPointMake(0, 0);
    base.endPoint = CGPointMake(1, 1);
    [frost.layer addSublayer:base];

    // 三个色斑
    NSArray *blobs = @[
        @[@(-0.05), @(-0.10), @(0.65), @(0.55), @(0.98), @(0.78), @(0.62)],
        @[@(0.55), @(0.35), @(1.05), @(0.95), @(0.62), @(0.86), @(0.95)],
        @[@(0.20), @(0.62), @(0.80), @(1.10), @(0.55), @(0.72), @(1.00)],
    ];
    for (NSArray *b in blobs) {
        CGFloat x0 = [b[0] doubleValue], y0 = [b[1] doubleValue];
        CGFloat x1 = [b[2] doubleValue], y1 = [b[3] doubleValue];
        CGFloat r = [b[4] doubleValue], g = [b[5] doubleValue], bl = [b[6] doubleValue];
        UIView *dot = [[UIView alloc] init];
        dot.translatesAutoresizingMaskIntoConstraints = NO;
        dot.backgroundColor = TBDynamicColor([UIColor colorWithRed:r green:g blue:bl alpha:0.24],
                                             [UIColor colorWithRed:r green:g blue:bl alpha:0.16]);
        dot.layer.cornerRadius = 160;
        UIView *wrap = dot;
        [frost addSubview:wrap];
        [NSLayoutConstraint activateConstraints:@[
            [dot.widthAnchor constraintEqualToConstant:320],
            [dot.heightAnchor constraintEqualToConstant:320],
            [dot.leadingAnchor constraintEqualToAnchor:frost.leadingAnchor
                                            constant:x0 * [UIScreen mainScreen].bounds.size.width],
            [dot.topAnchor constraintEqualToAnchor:frost.topAnchor
                                          constant:y0 * [UIScreen mainScreen].bounds.size.height],
        ]];
    }

    // 整层轻微模糊，让色斑变成柔光
    frost.layer.shouldRasterize = YES;
    frost.layer.rasterizationScale = [UIScreen mainScreen].scale;

    [host insertSubview:frost atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [frost.topAnchor constraintEqualToAnchor:host.topAnchor],
        [frost.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [frost.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [frost.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
    ]];
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
    tv.backgroundColor = [UIColor clearColor];
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    tv.backgroundView = nil;
}
