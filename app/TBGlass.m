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
    // The scroll viewport clips the page. Individual cells must not cut the
    // glass's rounded rim/shadow into a rectangular row-sized strip.
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


static UIColor *TBPageBaseColor(void) {
    return [UIColor systemGroupedBackgroundColor];
}

void TBApplyRim(UIView *view, CGFloat alpha) {
    // Compatibility for any remaining caller: rim is rendered by Theseus.
    (void)alpha;
    TBApplyTheseusSurface(view, view.layer.cornerRadius, nil);
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

// ── 按页面边距对齐的表格玻璃卡 ─────────────────────────────────────────────
// .insetGrouped 的左右 section inset 不是固定值：不同屏幕宽度/系统上实测有 20 和 24
// 两种。0.15.59 写死 "16 - 20 = -4" 时，在 24pt inset 的机器上卡片落在 24-4=20，
// 比目标 16 多 4pt（这就是「部分页面卡片边距不对」的来源）。
// 这里改成运行时把 cell 换算到 UITableView 坐标系，再反推卡片需要的外扩量，
// 任何 section inset 下卡片边缘都精确落在 pageSide。
@interface TBPageSideCellBG : UIView
@property (nonatomic, strong) UIView *card;
@property (nonatomic, assign) CGFloat pageSide;
@end

@implementation TBPageSideCellBG
- (void)layoutSubviews {
    [super layoutSubviews];

    UIView *cell = self.superview;
    while (cell && ![cell isKindOfClass:[UITableViewCell class]]) cell = cell.superview;
    UITableView *tv = nil;
    for (UIView *v = cell ?: self; v; v = v.superview) {
        if ([v isKindOfClass:[UITableView class]]) { tv = (UITableView *)v; break; }
    }

    CGFloat left = 0.0, right = 0.0;
    if (cell && tv) {
        CGRect r = [cell convertRect:cell.bounds toView:tv];
        left  = self.pageSide - CGRectGetMinX(r);
        right = self.pageSide - (CGRectGetWidth(tv.bounds) - CGRectGetMaxX(r));
    }
    CGFloat w = MAX(0.0, CGRectGetWidth(self.bounds) - left - right);
    self.card.frame = CGRectMake(left, 2.0, w, MAX(0.0, CGRectGetHeight(self.bounds) - 4.0));
}
@end

UIView *TBGlassCellAtPageSide(CGFloat pageSide) {
    TBPageSideCellBG *bg = [[TBPageSideCellBG alloc] init];
    bg.backgroundColor = [UIColor clearColor];
    bg.pageSide = pageSide;
    bg.card = TBGlassCard(20);
    [bg addSubview:bg.card];
    return bg;
}

void TBGlassTable(UITableView *tv) {
    // 表格背景必须透明，否则它会盖住页面底色（默认是白色）
    // 页面底色由 TBSetPageBackground / TBTableViewController 的背景视图提供
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

void TBInstallGlassSearchBars(void) {
    // Owned controllers call TBStyleSearchBarGlass after their UIKit layout.
    // Do not swizzle UISearchBar or change its layout and focus animations.
}
