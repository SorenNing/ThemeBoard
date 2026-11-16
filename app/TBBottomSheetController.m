#import "TBBottomSheetController.h"
#import "TBPrefs.h"
#import "TBGlass.h"
#import "TBTheme.h"
#import "TBThemeScanner.h"
#import "TBPanelController.h"
#import "TBPaths.h"
#import "TBImageUtil.h"
#import "TBDocImport.h"
#import "TBToast.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - 偏好键（用 TBPrefs.h 里的常量，键名与引擎完全一致）

static const double  kTBDefaultMaskCornerRadius = 13.42;   // 与设置页 / 引擎默认值一致

/// 抽屉里的三个形状选项（按钮 tag 就是这个顺序）
typedef NS_ENUM(NSInteger, TBSheetMaskMode) {
    TBSheetMaskModeSystem = 0,    // 默认：UseThemeIconMask=NO、MaskCornerRadiusOn=NO
    TBSheetMaskModeThemeMask,     // 遮罩：UseThemeIconMask=YES、MaskCornerRadiusOn=NO
    TBSheetMaskModeCornerRadius,  // 自定义圆角：MaskCornerRadiusOn=YES、UseThemeIconMask=NO
};

#pragma mark - 几何 / 手感参数

static const CGFloat kTBSheetTopGap         = 8.0;   // 高度上限 = 屏高 − 顶部安全区 − 这个间隙
static const CGFloat kTBSheetTopPad         = 8.0;   // 内容顶部留白
static const CGFloat kTBSheetBottomPad      = 8.0;   // 内容底部留白（另加安全区）
static const CGFloat kTBRubberK             = 0.35;  // 橡皮筋阻尼系数（近处斜率 ≈ 0.35）
static const CGFloat kTBSnapVelocity        = 900.0; // 速度吸附阈值（pt/s）
static const CGFloat kTBSnapProjection      = 0.20;  // 速度投影时间（秒）
static const CGFloat kTBDimMaxAlpha         = 0.42;  // 遮罩最深的不透明度
static const CGFloat kTBSheetRadius         = 22.0;  // 抽屉顶部圆角
static const CGFloat kTBSheetPad            = 20.0;  // 左右内缩
static const CGFloat kTBRowHeight           = 44.0;  // 与工具条按钮同高
static const CGFloat kTBRowGap              = 10.0;

// 时长 / 阻尼：打开与关闭各自固定，只有"拖动收尾"用中间那套 + 速度
static const NSTimeInterval kTBOpenDuration   = 0.36;
static const CGFloat        kTBOpenDamping    = 0.88;
static const NSTimeInterval kTBCloseDuration  = 0.30;
static const CGFloat        kTBCloseDamping   = 0.90;
static const NSTimeInterval kTBSettleDuration = 0.34;
static const CGFloat        kTBSettleDamping  = 0.88;

#pragma mark - 同款玻璃按钮

/// 和顶部工具条那三个按钮完全同款：圆角 13、高 44、16 号半粗、白色玻璃底 + 细白边
static void TBApplyToolbarGlass(UIButton *b, BOOL danger) {
    b.translatesAutoresizingMaskIntoConstraints = YES;   // 抽屉里走手动布局
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [b setTitleColor:(danger ? [UIColor systemRedColor] : [UIColor labelColor])
            forState:UIControlStateNormal];
    b.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                       [UIColor colorWithWhite:1 alpha:0.14]);
    b.layer.cornerRadius = 13;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
    b.layer.borderColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                         [UIColor colorWithWhite:1 alpha:0.20]).CGColor;
    TBApplyRim(b, 0.55);
}

@interface TBBottomSheetController () <UIGestureRecognizerDelegate, UIDocumentPickerDelegate>

@property (nonatomic, strong) TBTheme *theme;
@property (nonatomic, assign) BOOL isAssetPack;

// ---- 视图 ----
@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, strong) UIView *sheet;
@property (nonatomic, strong) UIView *sheetFillView;
@property (nonatomic, strong) UIView *hairline;
@property (nonatomic, strong) UIView *handle;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *hintLabel;

@property (nonatomic, strong) NSMutableArray<UIButton *> *choiceButtons;   // 形状三选一 / 素材项
@property (nonatomic, strong) NSMutableArray<UIImageView *> *choiceChecks;
@property (nonatomic, strong) NSMutableArray<UIButton *> *fxButtons;       // 边框 / 阴影 / 角标
@property (nonatomic, strong) NSMutableArray<UIImageView *> *fxChecks;
@property (nonatomic, strong) NSMutableArray<UIButton *> *actionButtons;   // 导入遮罩 / 应用 / 详情
@property (nonatomic, strong) UIButton *applyButton;
@property (nonatomic, strong) UIButton *importButton;
@property (nonatomic, strong) UIButton *detailButton;
@property (nonatomic, strong) UIButton *cancelApplyButton;

@property (nonatomic, strong) UIPanGestureRecognizer *pan;
@property (nonatomic, assign) BOOL cancelApplyInActionRow;   // 素材包：取消应用和应用按钮同一行
@property (nonatomic, assign) NSInteger pendingChoice;       // 待应用的模式（-1 = 没有，仅点选不生效）
@property (nonatomic, strong) NSMutableSet<NSNumber *> *pendingAssets;   // 素材包：待应用项

// ---- 动画状态 ----
/// 位移（正数 = 往下移；0 = 展开，sheetHeight = 收起）
@property (nonatomic, assign) CGFloat offset;
@property (nonatomic, assign) CGFloat dragStartOffset;
@property (nonatomic, assign) CGFloat sheetHeight;      // 展开态高度（= 内容高度）
@property (nonatomic, assign) CGFloat extra;            // 上拉增高量（>0 时抽屉变高，底边始终贴屏底）
@property (nonatomic, assign) CGFloat maxSheetHeight;    // 高度上限：屏高 − 顶部安全区 − 8
@property (nonatomic, assign) CGFloat pendingSheetHeight; // 动画期间算出的新高度，等收尾再落地
@property (nonatomic, strong) NSArray<NSNumber *> *anchors;   // 位移锚点（升序）
@property (nonatomic, assign) NSInteger anchorIndex;
@property (nonatomic, assign) BOOL appeared;
@property (nonatomic, assign) BOOL closing;
@property (nonatomic, strong) UIViewPropertyAnimator *animator;

@end

@implementation TBBottomSheetController

#pragma mark - 生命周期

- (instancetype)initWithTheme:(TBTheme *)theme {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _theme = theme;
        _isAssetPack = theme.isAssetPack;
        _choiceButtons = [NSMutableArray array];
        _choiceChecks = [NSMutableArray array];
        _fxButtons = [NSMutableArray array];
        _fxChecks = [NSMutableArray array];
        _actionButtons = [NSMutableArray array];
        _pendingChoice = -1;
        _pendingAssets = [NSMutableSet set];
    }
    return self;
}

/// 素材类型 → 开关偏好键
- (NSString *)tb_switchKeyForKind:(NSString *)kind {
    if ([kind isEqualToString:@"overlay"]) return TBKeyUseThemeIconOverlay;
    if ([kind isEqualToString:@"shadow"])  return TBKeyUseThemeIconShadow;
    if ([kind isEqualToString:@"badge"])   return TBKeyUseThemeBadge;
    return TBKeyUseThemeIconMask;
}

- (UIButton *)tb_buttonWithTitle:(NSString *)title tag:(NSInteger)tag action:(SEL)action danger:(BOOL)danger {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.tag = tag;
    [b setTitle:title forState:UIControlStateNormal];
    TBApplyToolbarGlass(b, danger);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.sheet addSubview:b];
    return b;
}

- (UIImageView *)tb_attachCheckTo:(UIButton *)b store:(NSMutableArray<UIImageView *> *)store {
    UIImageView *check = [[UIImageView alloc] initWithImage:
                          [[UIImage systemImageNamed:@"checkmark"]
                           imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    check.tintColor = [UIColor systemBlueColor];
    check.contentMode = UIViewContentModeScaleAspectFit;
    check.userInteractionEnabled = NO;
    check.hidden = YES;
    [b addSubview:check];
    if (store) [store addObject:check];
    return check;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.clipsToBounds = YES;

    // 1) 遮罩：半透明黑，点一下收起抽屉
    self.dimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimView.backgroundColor = [UIColor blackColor];
    self.dimView.alpha = 0;   // 透明度只在动画块里改
    [self.view addSubview:self.dimView];
    [self.dimView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(dimTapped)]];

    // 2) 抽屉本体：磨砂 + 半透明填充 + 顶部圆角
    self.sheet = [[UIView alloc] initWithFrame:CGRectZero];
    self.sheet.backgroundColor = [UIColor clearColor];
    self.sheet.layer.cornerRadius = kTBSheetRadius;
    self.sheet.layer.cornerCurve = kCACornerCurveContinuous;
    self.sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.sheet.clipsToBounds = YES;
    [self.view addSubview:self.sheet];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
                                [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    blur.frame = self.sheet.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [self.sheet addSubview:blur];

    self.sheetFillView = [[UIView alloc] initWithFrame:self.sheet.bounds];
    self.sheetFillView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.sheetFillView.userInteractionEnabled = NO;
    [self.sheet addSubview:self.sheetFillView];

    self.hairline = [[UIView alloc] initWithFrame:CGRectZero];
    self.hairline.userInteractionEnabled = NO;
    [self.sheet addSubview:self.hairline];

    // 3) 拖拽指示条
    self.handle = [[UIView alloc] initWithFrame:CGRectZero];
    self.handle.userInteractionEnabled = NO;
    self.handle.layer.cornerRadius = 2.5;
    [self.sheet addSubview:self.handle];

    // 4) 标题 + 说明
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor labelColor];
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.sheet addSubview:self.titleLabel];

    self.hintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [UIColor secondaryLabelColor];
    self.hintLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.sheet addSubview:self.hintLabel];

    if (!self.isAssetPack) {
        // 5) 形状三选一：默认 / 遮罩 / 自定义圆角（三个同款等宽，竖排）
        NSArray *titles = @[@"默认", @"遮罩", @"自定义圆角"];
        for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
            UIButton *b = [self tb_buttonWithTitle:titles[i] tag:i
                                            action:@selector(choiceTapped:) danger:NO];
            [self.choiceButtons addObject:b];
            [self tb_attachCheckTo:b store:self.choiceChecks];
        }
        // 5.5) 边框 / 阴影 / 角标：一行三个
        NSArray *fxTitles = @[@"边框", @"阴影", @"角标"];
        for (NSInteger i = 0; i < (NSInteger)fxTitles.count; i++) {
            UIButton *b = [self tb_buttonWithTitle:fxTitles[i] tag:i
                                            action:@selector(fxTapped:) danger:NO];
            [self.fxButtons addObject:b];
            [self tb_attachCheckTo:b store:self.fxChecks];
        }
        // 6) 底部一行三个入口：导入遮罩 / 应用主题 / 详情（应用主题是主功能，放中间并高亮）
        self.importButton = [self tb_buttonWithTitle:@"导入遮罩" tag:0
                                              action:@selector(importMaskTapped) danger:NO];
        self.applyButton  = [self tb_buttonWithTitle:@"应用主题" tag:1
                                              action:@selector(applyTapped) danger:NO];
        self.detailButton = [self tb_buttonWithTitle:@"详情" tag:2
                                              action:@selector(detailTapped) danger:NO];
        [self.actionButtons addObjectsFromArray:@[self.importButton, self.applyButton, self.detailButton]];

        // 正在使用时的「取消应用」（单独一行，红字）
        self.cancelApplyButton = [self tb_buttonWithTitle:@"取消应用" tag:0
                                                   action:@selector(cancelApplyTapped) danger:YES];
        self.cancelApplyButton.hidden = YES;
    } else {
        // 素材包：只列它能提供的素材项（遮罩 / 边框 / 阴影 / 角标）
        NSArray<NSDictionary *> *items = [self.theme availableAssetItems];
        for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
            NSDictionary *it = items[i];
            UIButton *b = [self tb_buttonWithTitle:it[@"title"] tag:i
                                            action:@selector(assetItemTapped:) danger:NO];
            [self.choiceButtons addObject:b];
            [self tb_attachCheckTo:b store:self.choiceChecks];
        }
        // 应用 / 正在使用 + 取消应用
        self.applyButton = [self tb_buttonWithTitle:@"应用" tag:0
                                             action:@selector(applyTapped) danger:NO];
        self.cancelApplyButton = [self tb_buttonWithTitle:@"取消应用" tag:0
                                                   action:@selector(cancelApplyTapped) danger:YES];
        self.cancelApplyButton.hidden = YES;
        self.cancelApplyInActionRow = YES;      // 和应用/正在使用同一行
        [self.actionButtons addObjectsFromArray:@[self.applyButton, self.cancelApplyButton]];
    }

    // 7) 拖拽手势：作用在抽屉整块上
    self.pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    self.pan.delegate = self;
    [self.sheet addGestureRecognizer:self.pan];

    self.titleLabel.text = self.theme.name.length ? self.theme.name : (self.isAssetPack ? @"素材" : @"主题");
    self.offset = 10000.0;      // 出场前先藏在屏外，首帧不会闪（位置在 layout 里用 frame 算）

    [self tb_syncPendingAssetsFromApplied];   // 素材包：勾选先还原成「当前已启用」
    [self refreshState];
    [self tb_refreshDynamicColors];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self tb_refreshDynamicColors];
}

/// 深浅色切换时重新解一次动态色
- (void)tb_refreshDynamicColors {
    self.sheetFillView.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                                        [UIColor colorWithWhite:0.10 alpha:0.62]);
    self.hairline.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                                   [UIColor colorWithWhite:1 alpha:0.20]);
    self.handle.backgroundColor = TBDynamicColor([UIColor colorWithWhite:0 alpha:0.18],
                                                 [UIColor colorWithWhite:1 alpha:0.35]);
    for (UIButton *b in self.choiceButtons) TBApplyToolbarGlass(b, NO);
    for (UIButton *b in self.fxButtons) TBApplyToolbarGlass(b, NO);
    TBApplyToolbarGlass(self.applyButton, NO);
    TBApplyToolbarGlass(self.importButton, NO);
    TBApplyToolbarGlass(self.detailButton, NO);
    TBApplyToolbarGlass(self.cancelApplyButton, YES);
    if (!self.isAssetPack) [self tb_stylePrimary:self.applyButton];
    [self refreshState];
}

/// 主功能按钮（应用主题 / 应用）：和其它按钮同款玻璃、同高同宽，
/// 只用「蓝字 + 半粗」强调（位置也在正中间，一眼能看到）
- (void)tb_stylePrimary:(UIButton *)b {
    if (!b || b.hidden) return;
    TBApplyToolbarGlass(b, NO);
    [b setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
}

/// 选中态：亮一点的白玻璃 + 蓝色描边 + 右侧对勾
- (void)tb_applySelectedLook:(UIButton *)b selected:(BOOL)selected check:(UIImageView *)check {
    if (selected) {
        b.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.88],
                                           [UIColor colorWithWhite:1 alpha:0.26]);
        b.layer.borderWidth = 2.0;
        b.layer.borderColor = [UIColor systemBlueColor].CGColor;
    } else {
        b.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                           [UIColor colorWithWhite:1 alpha:0.14]);
        b.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;
        b.layer.borderColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                             [UIColor colorWithWhite:1 alpha:0.20]).CGColor;
    }
    check.hidden = !selected;
}

#pragma mark - 布局（唯一写 sheet 几何的地方）

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    if (W < 1 || H < 1) return;

    // dim 只跟 view 一样大，不参与 sheet 的位移，动画期间改它也不会跳
    self.dimView.frame = self.view.bounds;

    // 兜底：动画已被系统打断（切后台 / 被打断）时别把 animator 永远留着，
    // 否则所有布局都会被 early-return 挡掉，抽屉再也摆不正
    if (self.animator && self.animator.state != UIViewAnimatingStateActive) {
        self.animator = nil;
    }

    // ---- 先把内容按当前宽度排一遍，拿到真实内容高度 ----
    CGFloat contentH = [self tb_layoutContentWithWidth:W];
    // 高度上限：屏高 − 顶部安全区 − 8（可以拉到接近全屏，但不能顶到刘海/状态栏）
    CGFloat topInset = MAX(self.view.safeAreaInsets.top, 20.0);
    CGFloat maxH = H - topInset - kTBSheetTopGap;
    maxH = MAX(maxH, 240.0);
    CGFloat expandedH = MIN(round(contentH), maxH);
    expandedH = MAX(expandedH, 200.0);
    self.maxSheetHeight = maxH;
    self.sheetHeight = expandedH;
    if (self.extra > maxH - expandedH) self.extra = MAX(0.0, maxH - expandedH);
    self.anchors = @[ @(0.0), @(round(expandedH * 0.5)), @(expandedH) ];

    // ★ 关键：动画中 / 关闭中，绝不回写 sheet 的 frame / dim.alpha
    if (self.closing || self.animator) {
        self.pendingSheetHeight = expandedH;
        return;
    }

    // 静止态：底边永远贴屏底，高度 = 内容高度 + 上拉增高量，靠 frame 的 top 表达位移
    //（不用 transform：frame + transform 混用是未定义行为）
    [self tb_applyFrame];
    self.dimView.alpha = [self dimAlphaForOffset:self.offset];
    self.hairline.frame = CGRectMake(0, 0, W, 1.0 / [UIScreen mainScreen].scale);
}

#pragma mark - 几何（底边恒定贴屏底）

/// 抽屉当前应有的 frame：
///   高度 = sheetHeight + extra（上拉增高），top = 屏高 − 高度 + offset（>0 = 往下走）
/// 因为高度随上拉一起变高、底边不动，所以上拉时下面**不会**露出桌面背景。
- (CGRect)tb_sheetFrame {
    CGFloat W = self.view.bounds.size.width;
    CGFloat H = self.view.bounds.size.height;
    CGFloat h = self.sheetHeight + self.extra;
    if (h < 1.0) h = 1.0;
    return CGRectMake(0, H - h + self.offset, W, h);
}

- (void)tb_applyFrame {
    self.sheet.frame = [self tb_sheetFrame];
}

/// 越过「全屏上限」之后的手感：渐近 30pt（越拉越紧，不会真的继续上移）
- (CGFloat)tb_rubberOver:(CGFloat)over {
    if (over <= 0) return 0;
    const CGFloat L = 30.0;
    return over * L / (L + over);
}

/// 排内容（也顺手把每个按钮的 frame 定好），返回内容需要的高度
- (CGFloat)tb_layoutContentWithWidth:(CGFloat)W {
    CGFloat pad = kTBSheetPad;
    CGFloat innerW = MAX(1.0, W - pad * 2);
    CGFloat y = kTBSheetTopPad;

    self.handle.frame = CGRectMake((W - 36) / 2.0, y, 36, 5);
    y += 5 + 12;

    self.titleLabel.frame = CGRectMake(pad, y, innerW, 20);
    y += 22;

    self.hintLabel.frame = CGRectMake(pad, y, innerW, 16);
    y += 20;

    for (UIButton *b in self.choiceButtons) {
        b.frame = CGRectMake(pad, y, innerW, kTBRowHeight);
        y += kTBRowHeight + kTBRowGap;
    }
    if (self.choiceButtons.count) {
        y -= kTBRowGap;
        y += 12;
    }

    if (self.fxButtons.count) {
        CGFloat third = (innerW - kTBRowGap * 2) / 3.0;
        for (NSInteger i = 0; i < (NSInteger)self.fxButtons.count; i++) {
            UIButton *b = self.fxButtons[i];
            b.frame = CGRectMake(pad + i * (third + kTBRowGap), y, third, kTBRowHeight);
        }
        y += kTBRowHeight + 12;
    }

    // 底部按钮行：只排可见的，等宽
    NSMutableArray<UIButton *> *vis = [NSMutableArray array];
    for (UIButton *b in self.actionButtons) if (!b.hidden) [vis addObject:b];
    if (vis.count) {
        CGFloat gap = kTBRowGap;
        CGFloat w = (innerW - gap * (vis.count - 1)) / MAX(1, (CGFloat)vis.count);
        for (NSInteger i = 0; i < (NSInteger)vis.count; i++) {
            vis[i].frame = CGRectMake(pad + i * (w + gap), y, w, kTBRowHeight);
        }
        y += kTBRowHeight;
    }

    if (!self.cancelApplyInActionRow && !self.cancelApplyButton.hidden) {
        y += kTBRowGap;
        self.cancelApplyButton.frame = CGRectMake(pad, y, innerW, kTBRowHeight);
        y += kTBRowHeight;
    }

    // 对勾贴右边（每个按钮自己的坐标）
    for (NSInteger i = 0; i < (NSInteger)self.choiceButtons.count; i++) {
        UIButton *b = self.choiceButtons[i];
        if (i < (NSInteger)self.choiceChecks.count) {
            self.choiceChecks[i].frame = CGRectMake(b.bounds.size.width - 30,
                                                    (b.bounds.size.height - 18) / 2.0, 18, 18);
        }
    }
    for (NSInteger i = 0; i < (NSInteger)self.fxButtons.count; i++) {
        UIButton *b = self.fxButtons[i];
        if (i < (NSInteger)self.fxChecks.count) {
            self.fxChecks[i].frame = CGRectMake(b.bounds.size.width - 26,
                                                (b.bounds.size.height - 18) / 2.0, 18, 18);
        }
    }

    CGFloat safeBottom = MAX(self.view.safeAreaInsets.bottom, 10);
    return y + safeBottom + kTBSheetBottomPad;
}

/// 从某个位移处逐渐淡入的 dim 透明度
- (CGFloat)dimAlphaForOffset:(CGFloat)offset {
    CGFloat hi = MAX(1.0, self.sheetHeight);
    if (offset >= hi - 0.5) return 0;
    CGFloat p = 1.0 - MAX(0.0, MIN(1.0, offset / hi));      // 0=收起 1=展开
    return kTBDimMaxAlpha * (0.55 + 0.45 * p);
}

#pragma mark - 状态刷新

- (BOOL)tb_themeActive {
    NSString *active = [TBPrefs stringForKey:TBKeyActiveTheme];
    return active.length && [active isEqualToString:self.theme.name];
}

- (BOOL)tb_hasMask {
    return [self.theme iconMaskPath].length > 0 ||
           [TBPrefs stringForKey:TBKeyCustomMaskPath].length > 0;
}
- (BOOL)tb_hasOverlay {
    return [self.theme anemoneEffectPath:@"iPhoneOverlay"].length > 0 ||
           [TBPrefs stringForKey:TBKeyCustomOverlayPath].length > 0;
}
- (BOOL)tb_hasShadow {
    return [self.theme anemoneEffectPath:@"iPhoneShadow"].length > 0 ||
           [TBPrefs stringForKey:TBKeyCustomShadowPath].length > 0;
}
- (BOOL)tb_hasBadge {
    return [self.theme badgePath].length > 0 ||
           [TBPrefs stringForKey:TBKeyCustomBadgePath].length > 0;
}

/// 当前形状模式（读偏好，和引擎同一套判断优先级）
- (TBSheetMaskMode)currentMode {
    if ([TBPrefs boolForKey:TBKeyUseThemeIconMask defaultValue:NO]) return TBSheetMaskModeThemeMask;
    if ([TBPrefs boolForKey:TBKeyMaskCornerRadiusOn defaultValue:NO]) return TBSheetMaskModeCornerRadius;
    return TBSheetMaskModeSystem;
}

/// 素材包：这一项是否已经指向本包并开启
- (BOOL)tb_assetItemActive:(NSDictionary *)item {
    NSString *cur = [TBPrefs stringForKey:item[@"key"]];
    BOOL on = [TBPrefs boolForKey:[self tb_switchKeyForKind:item[@"kind"]] defaultValue:NO];
    return on && cur.length && [cur isEqualToString:item[@"path"]];
}

/// 素材包：所有可用项都已启用 → 视为「正在使用」
- (BOOL)tb_assetPackApplied {
    NSArray *items = [self.theme availableAssetItems];
    if (!items.count) return NO;
    for (NSDictionary *it in items) {
        if (![self tb_assetItemActive:it]) return NO;
    }
    return YES;
}

/// 素材包：任意一项在用 → 「取消应用」就该显示（原来要全部启用才显示）
- (BOOL)tb_assetPackAnyApplied {
    NSArray *items = [self.theme availableAssetItems];
    if (!items.count) return NO;
    for (NSDictionary *it in items) {
        if ([self tb_assetItemActive:it]) return YES;
    }
    return NO;
}

/// 把「当前已启用的项」同步成勾选集合（打开面板时先还原现状，应用时再以勾选为准）
- (void)tb_syncPendingAssetsFromApplied {
    if (!self.isAssetPack) return;
    [self.pendingAssets removeAllObjects];
    NSArray *items = [self.theme availableAssetItems];
    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
        if ([self tb_assetItemActive:items[i]]) [self.pendingAssets addObject:@(i)];
    }
}

/// 素材包四种 kind → @[kind, Custom*Path 键, 开关键]
/// （应用时「以勾选为准」要遍历全部四种：没勾的 kind 一律清掉）
static NSArray<NSArray<NSString *> *> *TBAssetKindTable(void) {
    static NSArray *t = nil;
    if (!t) {
        t = @[ @[@"mask",    @"CustomMaskPath",    TBKeyUseThemeIconMask],
               @[@"overlay", @"CustomOverlayPath", TBKeyUseThemeIconOverlay],
               @[@"shadow",  @"CustomShadowPath",  TBKeyUseThemeIconShadow],
               @[@"badge",   @"CustomBadgePath",   TBKeyUseThemeBadge] ];
    }
    return t;
}

- (void)refreshState {
    BOOL activeTheme = [self tb_themeActive];

    if (!self.isAssetPack) {
        TBSheetMaskMode mode = [self currentMode];
        BOOL hasMask = [self tb_hasMask];
        BOOL pend = (self.pendingChoice >= 0);
        for (UIButton *b in self.choiceButtons) {
            BOOL selected = pend ? (b.tag == self.pendingChoice) : (b.tag == (NSInteger)mode);
            UIImageView *check = self.choiceChecks[b.tag];
            BOOL available = (b.tag != (NSInteger)TBSheetMaskModeThemeMask) || hasMask;
            if (!available && !selected) {
                [self tb_applySelectedLook:b selected:NO check:check];
                b.alpha = 0.45;
                [b setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
            } else {
                [self tb_applySelectedLook:b selected:selected check:check];
                b.alpha = 1.0;
                [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
            }
            if (b.tag == (NSInteger)TBSheetMaskModeCornerRadius) {
                double r = [TBPrefs doubleForKey:TBKeyMaskCornerRadius defaultValue:kTBDefaultMaskCornerRadius];
                NSString *t = selected ? [NSString stringWithFormat:@"自定义圆角 %.2f", r] : @"自定义圆角";
                [b setTitle:t forState:UIControlStateNormal];
            } else {
                NSString *base = (b.tag == (NSInteger)TBSheetMaskModeSystem) ? @"默认" : @"遮罩";
                BOOL wait = pend && (b.tag == self.pendingChoice);
                [b setTitle:(wait ? [base stringByAppendingString:@"（待应用）"] : base)
                    forState:UIControlStateNormal];
            }
        }

        // 边框 / 阴影 / 角标
        for (UIButton *b in self.fxButtons) {
            NSInteger i = b.tag;
            NSString *key = (i == 0) ? TBKeyUseThemeIconOverlay : ((i == 1) ? TBKeyUseThemeIconShadow : TBKeyUseThemeBadge);
            BOOL avail = (i == 0) ? [self tb_hasOverlay] : ((i == 1) ? [self tb_hasShadow] : [self tb_hasBadge]);
            BOOL on = [TBPrefs boolForKey:key defaultValue:NO];
            UIImageView *check = (i < (NSInteger)self.fxChecks.count) ? self.fxChecks[i] : nil;
            [self tb_applySelectedLook:b selected:(avail && on) check:check];
            if (!avail) {
                b.alpha = 0.45;
                [b setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
            } else {
                b.alpha = 1.0;
                [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
            }
            [b setTitle:[NSString stringWithFormat:@"%@：%@", @[@"边框", @"阴影", @"角标"][MIN(i, 2)],
                        (on ? @"开" : @"关")] forState:UIControlStateNormal];
            if (avail && on) [self tb_styleFxOn:b];
        }

        // 底部：应用主题 / 正在使用
        [self.applyButton setTitle:(pend ? @"应用" : (activeTheme ? @"正在使用" : @"应用主题"))
                          forState:UIControlStateNormal];
        [self tb_stylePrimary:self.applyButton];
        self.applyButton.alpha = (pend || !activeTheme) ? 1.0 : 0.55;
        self.cancelApplyButton.hidden = !activeTheme;
        self.importButton.hidden = NO;
        self.detailButton.hidden = NO;

        // 说明文字
        if (mode == TBSheetMaskModeThemeMask) {
            self.hintLabel.text = hasMask ? @"图标形状：遮罩（主题遮罩图 / 自定义遮罩）"
                                          : @"图标形状：遮罩（主题里没有遮罩图，引擎会落到系统形状）";
        } else if (mode == TBSheetMaskModeCornerRadius) {
            double r = [TBPrefs doubleForKey:TBKeyMaskCornerRadius defaultValue:kTBDefaultMaskCornerRadius];
            self.hintLabel.text = [NSString stringWithFormat:@"图标形状：自定义圆角 %.2f ≈ 宽度的 %.2f%%",
                                   r, (r / 60.0) * 100.0];
        } else {
            self.hintLabel.text = hasMask ? @"图标形状：默认（系统形状，主题里带遮罩图）"
                                          : @"图标形状：默认（系统形状）";
        }
    } else {
        // 素材包：逐项显示是否已启用
        NSArray<NSDictionary *> *items = [self.theme availableAssetItems];
        for (NSInteger i = 0; i < (NSInteger)self.choiceButtons.count && i < (NSInteger)items.count; i++) {
            UIButton *b = self.choiceButtons[i];
            BOOL on = [self tb_assetItemActive:items[i]];
            BOOL wait = [self.pendingAssets containsObject:@(i)];
            [self tb_applySelectedLook:b selected:(on || wait) check:self.choiceChecks[i]];
            if (wait && !on) self.choiceChecks[i].hidden = YES;     // 待应用：只高亮，不出对勾
            NSString *sfx = on ? @"（已启用）" : (wait ? @"（待应用）" : @"");
            [b setTitle:[NSString stringWithFormat:@"%@%@", items[i][@"title"], sfx]
              forState:UIControlStateNormal];
            b.alpha = 1.0;
            [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        }
        BOOL applied = [self tb_assetPackApplied];
        BOOL anyApplied = [self tb_assetPackAnyApplied];
        BOOL pendAny = (self.pendingAssets.count > 0);
        [self.applyButton setTitle:(pendAny ? @"应用" : (applied ? @"正在使用" : @"应用"))
                          forState:UIControlStateNormal];
        [self tb_stylePrimary:self.applyButton];
        self.applyButton.alpha = (pendAny || !applied) ? 1.0 : 0.55;
        self.applyButton.hidden = NO;
        self.cancelApplyButton.hidden = !anyApplied;      // 任意一项在用就显示

        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *it in items) [names addObject:it[@"title"]];
        self.hintLabel.text = [NSString stringWithFormat:@"素材包 · 可提供：%@", [names componentsJoinedByString:@" / "]];
    }

    // 行数/标题变了 → 重新排一次；动画中 layout 会自己早退，安全
    [self.view setNeedsLayout];
}

/// 「开」状态的玻璃按钮：淡蓝底 + 蓝字（不用描边，和选中态区分）
- (void)tb_styleFxOn:(UIButton *)b {
    b.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.16];
    [b setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
}

#pragma mark - 交互

- (void)choiceTapped:(UIButton *)sender {
    if (self.isAssetPack) return;
    TBSheetMaskMode mode = (TBSheetMaskMode)sender.tag;
    if (mode == TBSheetMaskModeThemeMask && ![self tb_hasMask]) {
        [self tb_alert:@"这个主题没有自带遮罩"
               message:@"它里面没有形状遮罩文件（IconBundles/Icon.png、icon.png、AppIconMask* 等），也没有全局自定义遮罩。\n先点「导入遮罩」选一张图，或从素材包里应用一个遮罩，再切到「遮罩」。"];
        return;
    }
    if (mode == TBSheetMaskModeCornerRadius) {
        [self tb_showRadiusPanel];     // 自定义圆角 → 自绘面板（滑块 + 输入框）
        return;
    }
    // 只记「选中」，不动设置 —— 点下面的「应用」才真正生效
    self.pendingChoice = (NSInteger)mode;
    [self refreshState];
}

/// 素材包：点一项 = 设全局 Custom*Path + 开对应开关（再点一次关掉）
- (void)assetItemTapped:(UIButton *)sender {
    NSArray<NSDictionary *> *items = [self.theme availableAssetItems];
    NSInteger i = sender.tag;
    if (i < 0 || i >= (NSInteger)items.count) return;
    // 只切换「待应用」勾选，不动设置 —— 点下面的「应用」才真正生效
    NSNumber *n = @(i);
    if ([self.pendingAssets containsObject:n]) [self.pendingAssets removeObject:n];
    else [self.pendingAssets addObject:n];
    [self refreshState];
}

- (void)fxTapped:(UIButton *)sender {
    if (self.isAssetPack) return;
    NSInteger i = sender.tag;
    NSString *key = (i == 0) ? TBKeyUseThemeIconOverlay : ((i == 1) ? TBKeyUseThemeIconShadow : TBKeyUseThemeBadge);
    BOOL avail = (i == 0) ? [self tb_hasOverlay] : ((i == 1) ? [self tb_hasShadow] : [self tb_hasBadge]);
    NSString *name = (i == 0) ? @"边框" : ((i == 1) ? @"阴影" : @"角标");
    if (!avail) {
        NSString *detail = (i == 2)
            ? @"主题/素材包里没有 Bundles/SBBadgeBG@3x.png、Bundles/com.apple.springboard/SBBadgeBG@3x.png，也没有全局自定义角标。\n开启也不会有任何变化，所以没有改动设置。"
            : [NSString stringWithFormat:@"它里面没有 AnemoneEffects/%@.png（@3x / @2x / 无后缀都找过了），也没有全局自定义素材。\n开启也不会有任何变化，所以没有改动设置。",
               (i == 0 ? @"iPhoneOverlay" : @"iPhoneShadow")];
        [self tb_alert:[NSString stringWithFormat:@"这个主题没有%@素材", name] message:detail];
        return;
    }
    BOOL on = [TBPrefs boolForKey:key defaultValue:NO];
    [TBPrefs setBool:!on forKey:key];
    [TBPrefs notifyChanged];
    [self refreshState];
}

/// 自定义圆角：自绘玻璃面板（数值输入框 + 滑块双向联动），不用系统 UIAlertController
- (void)tb_showRadiusPanel {
    double cur = [TBPrefs doubleForKey:TBKeyMaskCornerRadius defaultValue:kTBDefaultMaskCornerRadius];
    if (!(cur >= 0.0) || cur > 30.0) cur = kTBDefaultMaskCornerRadius;
    __weak typeof(self) wself = self;
    TBRadiusPanelController *p = [TBRadiusPanelController panelWithValue:cur
                                                                handler:^(BOOL confirmed, double value) {
        __strong typeof(self) s = wself;
        if (!s || !confirmed) return;
        [TBPrefs setBool:YES forKey:TBKeyMaskCornerRadiusOn];
        [TBPrefs setBool:NO forKey:TBKeyUseThemeIconMask];
        [TBPrefs setDouble:value forKey:TBKeyMaskCornerRadius];
        [TBPrefs notifyChanged];
        [s refreshState];
    }];
    [p presentOver:self];
}

#pragma mark - 应用 / 取消应用

- (void)applyTapped {
    if (self.isAssetPack) {
        NSArray<NSDictionary *> *all = [self.theme availableAssetItems];
        // 「以当前勾选为准」：
        //   勾选的 kind → 写入 Custom*Path + 开关 YES
        //   没勾选的 kind（遮罩/边框/阴影/角标）→ 清掉 Custom*Path + 开关 NO
        // 这样换素材时上一个会自动取消，不会叠加。
        NSMutableSet<NSString *> *checkedKinds = [NSMutableSet set];
        for (NSNumber *n in self.pendingAssets) {
            NSInteger i = n.integerValue;
            if (i < 0 || i >= (NSInteger)all.count) continue;
            NSString *kind = all[i][@"kind"];
            if (kind.length) [checkedKinds addObject:kind];
        }
        for (NSDictionary *it in all) {
            NSString *kind = it[@"kind"];
            if (!kind.length || ![checkedKinds containsObject:kind]) continue;
            [TBPrefs setString:it[@"path"] forKey:it[@"key"]];
            [TBPrefs setBool:YES forKey:[self tb_switchKeyForKind:kind]];
            if ([kind isEqualToString:@"mask"]) {
                [TBPrefs setBool:NO forKey:TBKeyMaskCornerRadiusOn];   // 遮罩优先，别和圆角打架
            }
        }
        NSMutableArray<NSString *> *cleared = [NSMutableArray array];
        for (NSArray<NSString *> *kt in TBAssetKindTable()) {
            if ([checkedKinds containsObject:kt[0]]) continue;
            if ([TBPrefs stringForKey:kt[1]].length > 0) [cleared addObject:kt[0]];
            [TBPrefs setString:nil forKey:kt[1]];
            [TBPrefs setBool:NO forKey:kt[2]];
        }
        [TBPrefs notifyChanged];
        [self tb_syncPendingAssetsFromApplied];
        [self refreshState];
        if (checkedKinds.count) [TBToast showAppliedIn:self];
        if (cleared.count) {
            TBLog2(@"[素材包] 已按勾选清掉未选中的 kind: %@", [cleared componentsJoinedByString:@"/"]);
        }
        return;   // 素材包不关抽屉：用户可以继续微调
    }
    if (self.pendingChoice >= 0) {            // 先把选中的形状落到设置
        TBSheetMaskMode m = (TBSheetMaskMode)self.pendingChoice;
        self.pendingChoice = -1;
        if (m == TBSheetMaskModeSystem) {
            [TBPrefs setBool:NO forKey:TBKeyUseThemeIconMask];
            [TBPrefs setBool:NO forKey:TBKeyMaskCornerRadiusOn];
        } else if (m == TBSheetMaskModeThemeMask) {
            [TBPrefs setBool:YES forKey:TBKeyUseThemeIconMask];
            [TBPrefs setBool:NO forKey:TBKeyMaskCornerRadiusOn];
            double r = [TBPrefs doubleForKey:TBKeyMaskCornerRadius defaultValue:kTBDefaultMaskCornerRadius];
            if (!(r > 0.0)) [TBPrefs setDouble:kTBDefaultMaskCornerRadius forKey:TBKeyMaskCornerRadius];
        }
        [TBPrefs notifyChanged];
        [self refreshState];
        [TBToast showAppliedIn:self];
        return;                                // 形状改了不关抽屉
    }
    // 与详情页「应用这个主题」完全一致
    [TBPrefs setString:self.theme.name forKey:TBKeyActiveTheme];
    [TBPrefs setBool:YES forKey:TBKeyEnabled];
    [TBPrefs notifyChanged];
    [self refreshState];
    __weak typeof(self) wself = self;
    [self closeThen:^{
        __strong typeof(self) s = wself;
        if (s.onApply) s.onApply(s.theme);
    }];
}

- (void)cancelApplyTapped {
    if (self.isAssetPack) {
        [TBPrefs setString:nil forKey:TBKeyCustomMaskPath];
        [TBPrefs setString:nil forKey:TBKeyCustomOverlayPath];
        [TBPrefs setString:nil forKey:TBKeyCustomShadowPath];
        [TBPrefs setString:nil forKey:TBKeyCustomBadgePath];
        [TBPrefs setBool:NO forKey:TBKeyUseThemeIconMask];
        [TBPrefs setBool:NO forKey:TBKeyUseThemeIconOverlay];
        [TBPrefs setBool:NO forKey:TBKeyUseThemeIconShadow];
        [TBPrefs setBool:NO forKey:TBKeyUseThemeBadge];
        [self.pendingAssets removeAllObjects];      // 勾选也一并清空
        [TBPrefs notifyChanged];
        [self refreshState];
        if (self.onCancelApply) self.onCancelApply(self.theme);   // 宿主页弹「已取消」胶囊
        return;
    }
    if (![self tb_themeActive]) return;
    [TBPrefs setString:nil forKey:TBKeyActiveTheme];
    [TBPrefs notifyChanged];
    [self refreshState];
    if (self.onCancelApply) self.onCancelApply(self.theme);
}

/// 详情：不做「先收回再 push」的两次动画 —— 直接 dismiss(NO)，再由宿主 push
- (void)detailTapped {
    if (self.closing) return;
    self.closing = YES;                 // 立刻冻结布局回写，避免 dismiss 期间再动 sheet
    self.view.userInteractionEnabled = NO;
    __weak typeof(self) wself = self;
    [self dismissViewControllerAnimated:NO completion:^{
        __strong typeof(self) s = wself;
        if (s.onDetail) s.onDetail(s.theme);
    }];
}

- (void)dimTapped {
    [self closeThen:nil];
}

#pragma mark - 关闭（唯一出口：0.30 / 0.90 + 同一动画块里位移与淡出）

- (void)closeThen:(void (^)(void))then {
    [self tb_closeWithVelocity:0 then:then];
}

- (void)tb_closeWithVelocity:(CGFloat)vy then:(void (^)(void))then {
    if (self.closing) return;
    // ① 先把「看得见的位置」从 presentationLayer 写回模型，再开始关闭动画
    [self tb_freezeToPresentation];
    self.closing = YES;
    self.view.userInteractionEnabled = NO;

    __weak typeof(self) wself = self;
    [self tb_animateTo:self.sheetHeight
                 extra:0
              dimAlpha:0
              duration:kTBCloseDuration
               damping:kTBCloseDamping
              velocity:vy
            completion:^{
        __strong typeof(self) s = wself;
        if (!s) return;
        s.offset = s.sheetHeight;
        s.dimView.alpha = 0;
        s.dimView.hidden = YES;
        [s dismissViewControllerAnimated:NO completion:^{      // 只 dismiss 一次
            if (then) then();
        }];
    }];
}

#pragma mark - 拖动（橡皮筋 + 速度吸附）

/// 阻尼橡皮筋：越过边界后按 1 - 1/(over*k+1) 衰减
- (CGFloat)rubberBand:(CGFloat)raw {
    CGFloat lo = self.anchors.firstObject.doubleValue;   // 展开
    CGFloat hi = self.anchors.lastObject.doubleValue;    // 收起
    CGFloat dim = MAX(1.0, self.sheetHeight);
    if (raw < lo) {
        CGFloat over = lo - raw;
        return lo - (over * dim * kTBRubberK) / (dim + kTBRubberK * over);
    }
    if (raw > hi) {
        CGFloat over = raw - hi;
        return hi + (over * dim * kTBRubberK) / (dim + kTBRubberK * over);
    }
    return raw;
}

- (NSInteger)nearestAnchorForOffset:(CGFloat)offset {
    NSInteger best = 0;
    CGFloat bestDist = CGFLOAT_MAX;
    for (NSInteger i = 0; i < (NSInteger)self.anchors.count; i++) {
        CGFloat d = fabs(self.anchors[i].doubleValue - offset);
        if (d < bestDist) { bestDist = d; best = i; }
    }
    return best;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (self.closing) return;
    CGPoint v = [pan velocityInView:self.view];
    CGFloat dy = [pan translationInView:self.view].y;

    switch (pan.state) {
        case UIGestureRecognizerStateBegan: {
            [self tb_freezeToPresentation];     // 动画中途接管：冻结在看得见的位置
            self.dragStartOffset = self.offset;
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGFloat raw = self.dragStartOffset + dy;
            if (raw < 0) {
                // 上拉：底边始终贴屏底，靠「增高」而不是「上移」——所以下面不会露出桌面背景。
                // 到高度上限之后改用橡皮筋阻尼（渐近 30pt），不再真的往上走。
                CGFloat pull = -raw;
                CGFloat room = MAX(0.0, self.maxSheetHeight - self.sheetHeight);
                CGFloat grow;
                if (pull <= room) grow = pull;
                else               grow = room + [self tb_rubberOver:pull - room];
                self.offset = 0.0;
                self.extra = grow;
            } else {
                self.offset = [self rubberBand:raw];
                self.extra = 0.0;
            }
            [self tb_applyFrame];
            // dim 跟手淡出（只在拖动时改 alpha，不碰 hidden）
            self.dimView.alpha = [self dimAlphaForOffset:self.offset];
            break;
        }
        default: {   // ended / cancelled / failed
            CGFloat vy = v.y;
            CGFloat projected = self.offset + vy * kTBSnapProjection;   // 用落点预判
            NSInteger cur = [self nearestAnchorForOffset:self.offset];
            NSInteger want = [self nearestAnchorForOffset:projected];
            if (vy > kTBSnapVelocity && want <= cur) want = MIN(cur + 1, (NSInteger)self.anchors.count - 1);
            if (vy < -kTBSnapVelocity && want >= cur) want = MAX(cur - 1, 0);
            [self settleToAnchor:want velocity:vy];
            break;
        }
    }
}

/// 停止在飞的动画，并把模型值对齐到当前视觉位置（避免接管瞬间跳变）
- (void)tb_freezeToPresentation {
    CALayer *pl = self.sheet.layer.presentationLayer;
    CALayer *dl = self.dimView.layer.presentationLayer;
    CGFloat visualAlpha = dl ? dl.opacity : self.dimView.alpha;
    if (!isfinite(visualAlpha)) visualAlpha = self.dimView.alpha;

    CGFloat H = self.view.bounds.size.height;
    CGRect pf = pl ? pl.frame : self.sheet.frame;
    CGFloat visTop = pf.origin.y;
    CGFloat visH   = pf.size.height;
    if (!isfinite(visTop)) visTop = self.sheet.frame.origin.y;
    if (!isfinite(visH) || visH < 1.0) visH = self.sheetHeight;

    // 从「看得见的位置」反推模型值：高度差 → extra，底边位置差 → offset
    CGFloat extra  = visH - self.sheetHeight;
    CGFloat offset = visTop - (H - visH);
    if (offset < -0.5) { extra += -offset; offset = 0.0; }
    if (extra < 0) extra = 0.0;

    if (self.animator) {
        [self.animator stopAnimation:NO];      // 不跳到终点，停在当前位置
        self.animator = nil;
    }
    [self.sheet.layer removeAllAnimations];
    [self.dimView.layer removeAllAnimations];

    self.extra = extra;
    self.offset = MAX(0.0, offset);
    [self tb_applyFrame];
    self.dimView.alpha = visualAlpha;
}

/// 吸附到某个锚点；收到「收起」锚点走统一的 close（同 0.30 / 0.90）
- (void)settleToAnchor:(NSInteger)idx velocity:(CGFloat)vy {
    idx = MAX(0, MIN(idx, (NSInteger)self.anchors.count - 1));
    if (idx == (NSInteger)self.anchors.count - 1) {
        [self tb_closeWithVelocity:vy then:nil];
        return;
    }
    self.anchorIndex = idx;
    [self tb_animateTo:self.anchors[idx].doubleValue
                 extra:0
              dimAlpha:-1
              duration:kTBSettleDuration
               damping:kTBSettleDamping
              velocity:vy
            completion:nil];
}

#pragma mark - 唯一的动画执行器

/// to: 目标位移；dimAlpha < 0 表示按 offset 自动算
/// 位移与 dim 在**同一个** animations block 里，时长/阻尼由调用方给死：
///   打开 0.36 / 0.88、关闭 0.30 / 0.90、拖动收尾 0.34 / 0.88
- (void)tb_animateTo:(CGFloat)to
               extra:(CGFloat)toExtra
            dimAlpha:(CGFloat)dimAlpha
            duration:(NSTimeInterval)duration
             damping:(CGFloat)damping
            velocity:(CGFloat)vy
          completion:(void (^)(void))done {
    if (self.animator) {                    // 理论不重入：保险起见只保留最后一个
        [self.animator stopAnimation:NO];
        self.animator = nil;
    }
    [self.sheet.layer removeAllAnimations];
    [self.dimView.layer removeAllAnimations];

    CGFloat from = self.offset;
    CGFloat dist = to - from;
    CGFloat normalized = 0.0;
    if (fabs(dist) > 0.5 && fabs(vy) > 1.0) {
        normalized = vy / fabs(dist);       // 速度归一化：pt/s ÷ 行程 → 行程比例/s
        normalized = MAX(-6.0, MIN(6.0, normalized));
    }

    UISpringTimingParameters *spring =
        [[UISpringTimingParameters alloc] initWithDampingRatio:damping
                                               initialVelocity:CGVectorMake(0, normalized)];
    UIViewPropertyAnimator *an = [[UIViewPropertyAnimator alloc] initWithDuration:duration
                                                                timingParameters:spring];
    self.animator = an;

    __weak typeof(self) wself = self;
    [an addAnimations:^{
        __strong typeof(self) s = wself;
        if (!s) return;
        s.offset = to;
        s.extra = MAX(0.0, toExtra);
        [s tb_applyFrame];       // 底边贴屏底 + 高度随 extra 变化，一个动画块里走完
        s.dimView.alpha = (dimAlpha < 0) ? [s dimAlphaForOffset:to] : dimAlpha;
    }];
    [an addCompletion:^(UIViewAnimatingPosition position) {
        __strong typeof(self) s = wself;
        if (!s) return;
        if (s.animator == an) s.animator = nil;
        if (position != UIViewAnimatingPositionEnd) return;
        s.offset = to;
        s.extra = MAX(0.0, toExtra);
        s.pendingSheetHeight = 0;
        if (done) done();
    }];
    [an startAnimation];
}

#pragma mark - 出现

- (void)presentOver:(UIViewController *)host {
    if (!host || self.presentingViewController || self.presentedViewController) return;
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;   // 不用 UISheetPresentationController
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [host presentViewController:self animated:NO completion:^{         // 系统动画关掉，自己动
        [self animateIn];
    }];
}

- (void)animateIn {
    [self.view layoutIfNeeded];       // 先把几何算出来（锚点在这里生成）
    self.appeared = YES;
    self.offset = self.sheetHeight;   // 从屏外开始
    self.extra = 0;
    [self tb_applyFrame];
    self.dimView.alpha = 0;
    self.anchorIndex = 0;
    [self tb_animateTo:0
                 extra:0
              dimAlpha:kTBDimMaxAlpha
              duration:kTBOpenDuration
               damping:kTBOpenDamping
              velocity:0
            completion:nil];
}

#pragma mark - 尺寸变化

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    if (self.closing) return;
    [self tb_freezeToPresentation];
    __weak typeof(self) wself = self;
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        __strong typeof(self) s = wself;
        if (!s || s.closing) return;
        // 尺寸变了：回到展开态再重新排，避免用旧高度算出的位移
        s.appeared = YES;
        s.offset = 0;
        [s.view setNeedsLayout];
        [s.view layoutIfNeeded];
        [s tb_animateTo:0 extra:0 dimAlpha:kTBDimMaxAlpha duration:0.2 damping:0.9 velocity:0 completion:nil];
    }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 从后台回来 / 系统打断了动画的兜底：位置不正就吸回展开态
    if (!self.closing && !self.animator && self.appeared &&
        (fabs(self.offset) > 0.5 || self.extra > 0.5)) {
        self.offset = 0;
        self.extra = 0;
        [self.view setNeedsLayout];
    }
}

#pragma mark - 弹窗

- (void)tb_alert:(NSString *)title message:(NSString *)msg {
    TBPresentAlert(self, title, msg);      // 自绘玻璃提示弹窗（不再用系统 UIAlertController）
}

#pragma mark - 导入遮罩（先弹自绘面板 → 文件选择器 / Filza）

- (void)importMaskTapped {
    NSString *dir = self.theme.path;
    if (!dir.length) {
        [self tb_alert:@"导入失败" message:@"找不到主题目录，无法写入遮罩"];
        return;
    }
    NSString *msg = [NSString stringWithFormat:@"遮罩会写入这个主题：\n%@\n\n可以选一张图片，也可以直接选一个 zip（会自动解压，找里面的 IconBundles/Icon.png、icon.png，其次任意 PNG/JPG）。\n也可以用 Filza 把图片直接放进 IconBundles/Icon.png。", dir];
    __weak typeof(self) wself = self;
    TBChoicePanelController *p = [TBChoicePanelController panelWithTitle:@"导入遮罩"
                                                                 message:msg
                                                                 options:@[@"选择文件导入", @"跳转 Filza 导入",
                                                                           @"用「文件」App 分享到 ThemeBoard"]
                                                                 handler:^(NSInteger idx) {
        __strong typeof(self) s = wself;
        if (!s || idx < 0) return;
        if (idx == 0)      [s tb_pickMaskFile];
        else if (idx == 1) [s tb_openPathInFilza:dir];
        else               [s tb_showShareImportHelp];
    }];
    [p presentOver:self];
}

- (void)tb_showShareImportHelp {
    TBPresentAlert(self, @"用「文件」App 分享到 ThemeBoard",
        @"1. 打开「文件」App，长按要导入的 zip\n"
        @"2. 点「共享」→ 在 App 列表里选「ThemeBoard」\n"
        @"3. ThemeBoard 会直接打开并导入，不经过系统文件选择器\n"
        @"   （这条通路不会出现「点了文件被当成取消」）\n\n"
        @"导入完成后回到主题列表，点开这个包就能看到它的遮罩；\n"
        @"想把它当成本主题的遮罩：进入本主题 →「导入遮罩」→ 选择导入后的 IconBundles/Icon.png。");
}

- (void)tb_openPathInFilza:(NSString *)path {
    if (TBOpenPathExternally(path)) return;
    [UIPasteboard generalPasteboard].string = path ?: @"";
    [self tb_alert:@"打不开 Filza" message:[NSString stringWithFormat:
        @"系统里没有装 Filza（也没有可用的文件 App）。\n路径已复制到剪贴板：\n%@", path]];
}

- (void)tb_pickMaskFile {
    // 与导入主题同一个访问层：iOS14+ = initForOpeningContentTypes:asCopy:YES，老系统 = Import 模式
    // 类型放开到 public.item：否则 iCloud 上不匹配的文件会被系统置灰、根本点不动
    // （选完再由我们自己判定是不是图片，见 didPickDocumentsAtURLs）
    UIDocumentPickerViewController *picker =
        TBNewImportPicker(@[ UTTypePNG, UTTypeJPEG, UTTypeZIP ],
                                    @[ @"public.png", @"public.jpeg", @"public.zip-archive" ]);
    if (!picker) { [self tb_alert:@"打不开" message:@"系统没有可用的图片选择器"]; return; }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;

    // 0.15.54：抽屉是从列表页 present 上来的，再在抽屉上 present picker 属于「嵌套呈现」，
    // 回调容易丢。统一从最顶层 VC 发，并留日志。
    UIViewController *host = TBTopPresentingViewController(self);
    TBLog2(@"[导入遮罩][picker] 即将 present self=%@ host=%@ delegate==self?%d",
           NSStringFromClass([self class]), NSStringFromClass([host class]),
           (picker.delegate == (id)self) ? 1 : 0);
    [host presentViewController:picker animated:YES completion:^{
        TBLog2(@"[导入遮罩][picker] present 完成 presenting=%@",
               NSStringFromClass([picker.presentingViewController class]));
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSLog(@"[ThemeBoard] ★进入遮罩 didPickDocumentsAtURLs urls.count=%lu", (unsigned long)urls.count);
    TBLog2(@"[导入遮罩][picker] ★进入回调 urls.count=%lu delegate=%@",
           (unsigned long)urls.count, NSStringFromClass([controller.delegate class]));
    NSURL *url = urls.firstObject;
    if (!url) return;

    // 签发类型放开了，这里要把「不是图片也不是 zip」的挡掉并说清楚
    static NSArray *kImgExt;
    if (!kImgExt) kImgExt = @[ @"png", @"jpg", @"jpeg", @"heic", @"webp", @"tiff", @"bmp" ];
    NSString *ext = url.pathExtension.lowercaseString;

    // 直接选到 zip：解压到临时目录，递归找 IconBundles/Icon.png、icon.png，其次任意 PNG/JPG
    if ([ext isEqualToString:@"zip"]) {
        NSString *why = nil;
        NSString *imgPath = [TBThemeScanner extractMaskImageFromZip:url reason:&why];
        if (!imgPath.length) {
            [self tb_alert:@"压缩包里没有遮罩图"
                   message:(why.length ? why : @"解压后没找到可用的图片，换一个压缩包再试")];
            return;
        }
        TBLog2(@"[导入遮罩] zip 里找到遮罩图：%@", imgPath);
        url = [NSURL fileURLWithPath:imgPath];      // 后面按普通图片继续走
        ext = url.pathExtension.lowercaseString;
    }

    if (![kImgExt containsObject:(ext ?: @"")]) {
        // zip 分支拿到的临时图也要删掉：找不到目标目录 / 判型失败时原代码直接 return，
        // tbmaskv-* 临时文件会永久留在 /tmp（App 容器 tmp 系统可能清、也可能不清）
        [TBThemeScanner removeTempMaskImage:url.path];
        [self tb_alert:@"这不是图片"
               message:[NSString stringWithFormat:
                        @"遮罩需要 PNG / JPG 图片，或者一个装着遮罩图的 zip。\n你选的是「%@」。",
                        url.lastPathComponent ?: @"这个文件"]];
        return;
    }

    NSString *dir = self.theme.path;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (dir.length == 0 || ![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) {
        [self tb_alert:@"导入失败" message:@"找不到主题目录，无法写入遮罩"];
        return;
    }
    if (![fm isWritableFileAtPath:dir]) {
        [self tb_alert:@"导入失败" message:[NSString stringWithFormat:@"主题目录不可写：\n%@", dir]];
        return;
    }

    NSArray<NSString *> *paths = [self tb_maskDestinationPaths];
    if (paths.count == 0) {
        [self tb_alert:@"导入失败" message:@"主题目录里建不出 IconBundles，无法写入遮罩"];
        return;
    }

    NSString *old = [self.theme iconMaskPath];
    if (old.length) {
        __weak typeof(self) wself = self;
        TBChoicePanelController *p = [TBChoicePanelController
            panelWithTitle:@"覆盖已有遮罩？"
                   message:[NSString stringWithFormat:@"主题里已经有一个遮罩图：\n%@\n\n继续会覆盖它。", old]
                   options:@[@"覆盖"]
                   handler:^(NSInteger idx) {
            __strong typeof(self) s = wself;
            if (s && idx == 0) [s tb_writeMaskFromURL:url toPaths:paths];
        }];
        // 无论用户选「覆盖」还是放弃，zip 解出来的临时图都不能留在 /tmp
        [TBThemeScanner removeTempMaskImage:url.path];
        [p presentOver:self];
        return;
    }
    [self tb_writeMaskFromURL:url toPaths:paths];
    // 正常写入完成：临时副本使命结束
    [TBThemeScanner removeTempMaskImage:url.path];
}

/// 导入遮罩的落盘位置（按引擎查找优先级）
- (NSArray<NSString *> *)tb_maskDestinationPaths {
    NSString *dir = self.theme.path;
    if (!dir.length) return @[];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *out = [NSMutableArray array];

    NSString *ib = nil;
    for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        BOOL d = NO;
        NSString *full = [dir stringByAppendingPathComponent:item];
        if ([fm fileExistsAtPath:full isDirectory:&d] && d &&
            [item caseInsensitiveCompare:@"IconBundles"] == NSOrderedSame) { ib = full; break; }
    }
    if (!ib.length) {
        ib = [dir stringByAppendingPathComponent:@"IconBundles"];
        [fm createDirectoryAtPath:ib withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    BOOL isDir = NO;
    if (ib.length && [fm fileExistsAtPath:ib isDirectory:&isDir] && isDir) {
        [out addObject:[ib stringByAppendingPathComponent:@"Icon.png"]];
        [out addObject:[ib stringByAppendingPathComponent:@"icon.png"]];
    }
    return out;
}

- (void)tb_writeMaskFromURL:(NSURL *)url toPaths:(NSArray<NSString *> *)paths {
    NSError *readErr = nil;
    NSData *raw = TBReadCoordinatedData(url, &readErr);

    if (raw.length == 0) {
        [TBThemeScanner removeTempMaskImage:url.path];   // zip 临时图：失败也要清理
        [self tb_alert:@"导入失败" message:TBImportFailureMessage(url, readErr, @"读不到选中的图片文件")];
        return;
    }
    UIImage *img = [[UIImage alloc] initWithData:raw];
    NSData *png = img ? TBMaskPNGDataFromImage(img) : nil;
    if (png.length == 0) {
        [TBThemeScanner removeTempMaskImage:url.path];   // zip 临时图：失败也要清理
        [self tb_alert:@"导入失败" message:@"这张图没法解析成遮罩（换一张 PNG/JPG 再试）"];
        return;
    }

    NSMutableArray<NSString *> *ok = [NSMutableArray array];
    NSMutableArray<NSString *> *bad = [NSMutableArray array];
    for (NSString *p in paths) {
        NSError *err = nil;
        if ([png writeToFile:p options:NSDataWritingAtomic error:&err]) [ok addObject:p];
        else [bad addObject:p];
    }

    if (ok.count == 0) {
        [TBThemeScanner removeTempMaskImage:url.path];   // zip 临时图：失败也要清理
        [self tb_alert:@"导入失败" message:[NSString stringWithFormat:
            @"没法写入主题目录（可能不可写）：\n%@", [bad componentsJoinedByString:@"\n"]]];
        return;
    }

    [TBPrefs setBool:YES forKey:TBKeyUseThemeIconMask];
    [TBPrefs setBool:NO forKey:TBKeyMaskCornerRadiusOn];
    [TBPrefs notifyChanged];
    [self refreshState];

    NSMutableString *msg = [NSMutableString stringWithString:@"遮罩已写入当前主题，并已切换为「遮罩」：\n"];
    [msg appendString:[ok componentsJoinedByString:@"\n"]];
    if (bad.count) [msg appendFormat:@"\n\n（以下位置写入失败）\n%@", [bad componentsJoinedByString:@"\n"]];
    [self tb_alert:@"导入成功" message:msg];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // 用户取消：什么都不做（但要留日志，便于区分「没回调」和「用户取消」）
    TBLog2(@"[导入遮罩][picker] 用户取消 documentPickerWasCancelled");
}

@end
