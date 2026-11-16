#import "TBGlass.h"
#import "TBTheseusMaterial.h"
#import <objc/runtime.h>

@interface TBGlassCardView : UIView
@property (nonatomic, strong) TBTheseusSurface *surface;
@end
@implementation TBGlassCardView
- (void)layoutSubviews {
    [super layoutSubviews];
    self.surface.frame = self.bounds;
    self.opaque = NO;
    // Keep each card rim uncut. The full-page scroll view owns page clipping.
    for (UIView *ancestor = self.superview; ancestor; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:[UIScrollView class]]) break;
        ancestor.clipsToBounds = NO;
        if ([ancestor isKindOfClass:[UITableViewCell class]] ||
            [ancestor isKindOfClass:[UICollectionViewCell class]]) break;
    }
    // A table/collection background is a sibling of its labels and controls.
    // Exclude the whole cell instead of sampling its foreground into the glass.
    UIView *exclusion = self;
    for (UIView *v = self.superview; v; v = v.superview) {
        if ([v isKindOfClass:[UITableViewCell class]] ||
            [v isKindOfClass:[UICollectionViewCell class]]) { exclusion = v; break; }
    }
    if (self.surface.captureExclusion != exclusion) self.surface.captureExclusion = exclusion;
}
@end

static const void *kTBTheseusSurfaceKey = &kTBTheseusSurfaceKey;

void TBApplyTheseusSurface(UIView *host, CGFloat radius, UIColor *tint) {
    if (!host) return;
    TBTheseusSurface *surface = objc_getAssociatedObject(host, kTBTheseusSurfaceKey);
    if (!surface) {
        surface = [[TBTheseusSurface alloc] initWithFrame:host.bounds];
        surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        surface.captureExclusion = host;
        [host insertSubview:surface atIndex:0];
        objc_setAssociatedObject(host, kTBTheseusSurfaceKey, surface, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    host.opaque = NO;
    host.backgroundColor = [UIColor clearColor];
    host.layer.borderWidth = 0;
    host.layer.cornerRadius = radius;
    host.clipsToBounds = NO;
    surface.cornerRadius = radius;
    surface.surfaceTint = tint;
}

UIColor *TBDynamicColor(UIColor *light, UIColor *dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
    }];
}


UIView *TBGlassCard(CGFloat radius) {
    TBGlassCardView *card = [[TBGlassCardView alloc] init];
    TBApplyTheseusSurface(card, radius, nil);
    card.surface = objc_getAssociatedObject(card, kTBTheseusSurfaceKey);
    return card;
}

UIButton *TBGlassButton(NSString *title, BOOL danger) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [b setTitleColor:danger ? [UIColor systemRedColor] : [UIColor labelColor] forState:UIControlStateNormal];
    TBApplyTheseusSurface(b, 24, nil);
    return b;
}

UIBarButtonItem *TBGlassNavigationItem(NSString *title, UIImage *image, id target, SEL action) {
    UIButton *button = TBGlassButton(title ?: @"", NO);
    button.translatesAutoresizingMaskIntoConstraints = YES;
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [button setImage:image forState:UIControlStateNormal];
    button.tintColor = [UIColor labelColor];
    CGSize textSize = title.length ? [title sizeWithAttributes:@{NSFontAttributeName:button.titleLabel.font}] : CGSizeZero;
    button.frame = CGRectMake(0, 0, MAX(44, ceil(textSize.width) + (image ? 24 : 0) + 24), 36);
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityLabel = title;
    TBApplyTheseusSurface(button, 18, nil);
    return [[UIBarButtonItem alloc] initWithCustomView:button];
}

UIView *TBGlassCellBG(CGFloat inset) {
    UIView *bg = [[UIView alloc] init];
    bg.opaque = NO;
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

void TBPrepareTheseusCell(UITableViewCell *cell) {
    cell.backgroundView = nil;
    cell.selectedBackgroundView = nil;
    cell.multipleSelectionBackgroundView = nil;
    cell.automaticallyUpdatesBackgroundConfiguration = NO;
    cell.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    cell.opaque = NO;
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.opaque = NO;
    cell.contentView.backgroundColor = [UIColor clearColor];
}

void TBInstallTheseusCellSurface(UITableViewCell *cell, CGFloat inset) {
    TBPrepareTheseusCell(cell);
    UIView *surface = TBGlassCellBG(inset);
    surface.translatesAutoresizingMaskIntoConstraints = NO;
    surface.userInteractionEnabled = NO;
    [cell.contentView insertSubview:surface atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [surface.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
        [surface.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
        [surface.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
        [surface.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
    ]];
}

void TBGlassTable(UITableView *tv) {
    // Theseus is the only cell surface; no table-wide decorative backing.
    tv.backgroundColor = [UIColor clearColor];
    tv.separatorStyle = UITableViewCellSeparatorStyleNone;
    tv.backgroundView = nil;
}

#pragma mark - 搜索框

void TBStyleSearchBarGlass(UISearchBar *searchBar) {
    if (!searchBar) return;
    static UIImage *emptyBackground;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ emptyBackground = [[UIImage alloc] init]; });
    [searchBar setSearchFieldBackgroundImage:emptyBackground forState:UIControlStateNormal];
    UITextField *field = searchBar.searchTextField;
    field.borderStyle = UITextBorderStyleNone;
    field.background = nil;
    field.disabledBackground = nil;
    TBApplyTheseusSurface(field, CGRectGetHeight(field.bounds) > 0 ? CGRectGetHeight(field.bounds) / 2 : 18, nil);
}
