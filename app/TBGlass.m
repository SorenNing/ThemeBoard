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

void TBAttachFrostContainer(UIView *host) {
    if (!host) return;
    host.backgroundColor = [UIColor systemGroupedBackgroundColor];
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
