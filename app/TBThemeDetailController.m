#import "TBPanelController.h"
#import "TBThemeDetailController.h"
#import "TBAppInfo.h"
#import "TBThemeScanner.h"
#import "TBPrefs.h"
#import "TBMissingController.h"
#import "TBGlass.h"
#import "TBToast.h"
#import "TBSpacing.h"

#pragma mark - 遮罩偏好键（与引擎 / 抽屉完全一致）

static NSString *const kTBKeyUseThemeIconMask   = @"UseThemeIconMask";
static NSString *const kTBKeyMaskCornerRadiusOn = @"MaskCornerRadiusOn";
static NSString *const kTBKeyMaskCornerRadius   = @"MaskCornerRadius";
static NSString *const kTBKeyUseThemeIconOverlay = @"UseThemeIconOverlay";
static NSString *const kTBKeyUseThemeIconShadow  = @"UseThemeIconShadow";
static const double  kTBDefaultMaskCornerRadius = 13.42;

static const CGFloat kTBCardRadius   = 20.0;   // 与 TBGlassCard(20) / 列表卡片一致
static const CGFloat kTBCardGap      = 12.0;   // 卡片间距（= v0.15.56 的 12，四列/两列/预览都用它）
static const CGFloat kTBSideInset    = 16.0;   // 左右内缩（= v0.15.56）

#pragma mark - 方形卡片 cell（双列网格的通用卡片）

/// 图标卡（grid）竖直节奏：标题 5 → 图标 +4 → 说明 +3 → 底 ≥5，和 sizeForItem 用同一套数字
static const CGFloat kTBGridTitleTop = 5.0;    // 标题 top
static const CGFloat kTBGridTitleIconGap = 4.0;// 图标 top = 标题 bottom + 4
static const CGFloat kTBGridIconCapGap = 3.0;  // 说明 top = 图标 bottom + 3
static const CGFloat kTBGridBottomPad = 5.0;   // 说明 bottom ≤ 卡.bottom − 5
static const CGFloat kTBGridIconScale = 0.86;  // 图标宽 = 卡宽 × 0.86（原来 0.80）
/// 图标卡高度里除图标以外的固定占用（标题最多 2 行 + 各段间隙 + 底边距），实测 48 刚好贴身
static const CGFloat kTBGridTextBlock = 26.0;   // 只留标题那一行的高度（说明行已隐藏，不再预留空白）

@interface TBSquareCardCell : UICollectionViewCell
@property (nonatomic, assign) BOOL compact;          // 四功能小卡
@property (nonatomic, assign) BOOL didBuildConstraints;   // 约束只按首次形态建一次
@property (nonatomic, strong) NSArray *compactCons;
@property (nonatomic, strong) NSArray *gridCons;
@property (nonatomic, strong) NSLayoutConstraint *iconXCons;   // 两种形态共用
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *captionLabel;
@end

@implementation TBSquareCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        _card = TBGlassCard(kTBCardRadius);
        _card.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_card];
        [NSLayoutConstraint activateConstraints:@[
            [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        ]];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor labelColor];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_card addSubview:_titleLabel];

        _icon = [[UIImageView alloc] init];
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.clipsToBounds = NO;
        [_card addSubview:_icon];

        _captionLabel = [[UILabel alloc] init];
        _captionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _captionLabel.font = [UIFont systemFontOfSize:11];
        _captionLabel.textColor = [UIColor secondaryLabelColor];
        _captionLabel.textAlignment = NSTextAlignmentCenter;
        _captionLabel.numberOfLines = 3;
        _captionLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [_card addSubview:_captionLabel];

        NSLayoutConstraint *titleL = [_titleLabel.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:8];
        NSLayoutConstraint *titleR = [_titleLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-8];
        NSLayoutConstraint *capL = [_captionLabel.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:8];
        NSLayoutConstraint *capR = [_captionLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-8];
        _iconXCons = [_icon.centerXAnchor constraintEqualToAnchor:_card.centerXAnchor];

        // ★ 0.15.57：两套形态的约束这里只"备料"不激活，等 setCompact: 第一次定形态时
        //   才建对应的那一套。以前是 init 里先激活 grid、复用成 compact 时再 deactivate/
        //   activate 一遍 —— 每次形态切换都动约束，就是这个分区"闪一下"的来源。
        [NSLayoutConstraint activateConstraints:@[titleL, titleR, capL, capR]];
    }
    return self;
}

/// 某一形态的约束（第一次用到时才创建，之后复用同一个数组，不再重建）
- (NSArray *)tb_constraintsForCompact:(BOOL)compact {
    if (compact) {
        if (!_compactCons) {
            // 功能卡：更小一档的小方卡（概览 / 应用主题 / 取消应用 / 导出），图标 20pt
            _compactCons = @[
                [_titleLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:10],
                _iconXCons,
                [_icon.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
                [_icon.widthAnchor constraintEqualToConstant:20],
                [_icon.heightAnchor constraintEqualToConstant:20],
                [_captionLabel.topAnchor constraintEqualToAnchor:_icon.bottomAnchor constant:4],
                [_captionLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_card.bottomAnchor constant:-8],
            ];
        }
        return _compactCons;
    }
    if (!_gridCons) {
        // 图标卡：标题（最多 2 行）→ 图标（卡宽 × 0.86）→ 说明（1 行，中间截断）
        _gridCons = @[
            [_titleLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:kTBGridTitleTop],
            _iconXCons,
            [_icon.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:kTBGridTitleIconGap],
            [_icon.widthAnchor constraintEqualToAnchor:_card.widthAnchor multiplier:kTBGridIconScale],
            [_icon.heightAnchor constraintEqualToAnchor:_icon.widthAnchor],
            [_captionLabel.topAnchor constraintEqualToAnchor:_icon.bottomAnchor constant:kTBGridIconCapGap],
            [_captionLabel.bottomAnchor constraintLessThanOrEqualToAnchor:_card.bottomAnchor constant:-kTBGridBottomPad],
        ];
    }
    return _gridCons;
}

- (void)setCompact:(BOOL)compact {
    if (_didBuildConstraints && _compact == compact) return;
    BOOL wasBuilt = _didBuildConstraints;
    if (wasBuilt) {                                   // 只有真换形态才动约束
        [NSLayoutConstraint deactivateConstraints:[self tb_constraintsForCompact:_compact]];
    }
    _compact = compact;
    _didBuildConstraints = YES;
    [NSLayoutConstraint activateConstraints:[self tb_constraintsForCompact:compact]];
    // 字体/行数只是属性，不动约束（不会引起布局抖动）
    _titleLabel.font = [UIFont systemFontOfSize:(compact ? 12.5 : 13) weight:UIFontWeightSemibold];
    _captionLabel.font = [UIFont systemFontOfSize:(compact ? 10 : 11)];
    _captionLabel.numberOfLines = compact ? 3 : 1;    // 说明只给 1 行
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.card.alpha = highlighted ? 0.7 : 1.0;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // ★ 只清内容，绝不碰约束（碰约束 = 复用瞬间抖一下）
    self.card.alpha = 1.0;
    self.icon.image = nil;
    self.icon.alpha = 1.0;
    self.titleLabel.text = nil;
    self.captionLabel.text = nil;
    self.captionLabel.hidden = NO;
}

@end

#pragma mark - 预览卡（section 1）：系统形态 / 图标预览（2×2）

/// 预览卡基类：外观、圆角、玻璃、内边距全部跟 4 列图标卡同一套
/// （标题 top 5 → 内容 top +4 → 内容 bottom −5，内容宽 = 卡宽 × 0.86）
@interface TBPreviewTileCell : UICollectionViewCell
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *content;
@end

@implementation TBPreviewTileCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        _card = TBGlassCard(kTBCardRadius);
        _card.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_card];
        [NSLayoutConstraint activateConstraints:@[
            [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        ]];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor labelColor];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.numberOfLines = 1;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_card addSubview:_titleLabel];

        _content = [[UIView alloc] init];
        _content.translatesAutoresizingMaskIntoConstraints = NO;
        _content.backgroundColor = [UIColor clearColor];
        [_card addSubview:_content];

        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:kTBGridTitleTop],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:6],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-6],
            [_content.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:kTBGridTitleIconGap],
            [_content.centerXAnchor constraintEqualToAnchor:_card.centerXAnchor],
            [_content.widthAnchor constraintEqualToAnchor:_card.widthAnchor multiplier:kTBGridIconScale],
            [_content.bottomAnchor constraintEqualToAnchor:_card.bottomAnchor constant:-kTBGridBottomPad],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.card.alpha = 1.0;
}

@end

/// 「系统形态」：单张合成图（当前形状 + 叠加层 + 阴影）+ 原来的说明
@interface TBShapePreviewCell : TBPreviewTileCell
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *captionLabel;
@end

@implementation TBShapePreviewCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _imageView = [[UIImageView alloc] init];
        _imageView.translatesAutoresizingMaskIntoConstraints = NO;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.clipsToBounds = NO;
        [self.content addSubview:_imageView];

        _captionLabel = [[UILabel alloc] init];
        _captionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _captionLabel.font = [UIFont systemFontOfSize:9];
        _captionLabel.textColor = [UIColor secondaryLabelColor];
        _captionLabel.textAlignment = NSTextAlignmentCenter;
        _captionLabel.numberOfLines = 2;   // 原来的说明是多行的（「主题里没有遮罩图\n→ 系统形状」）
        _captionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.content addSubview:_captionLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_imageView.topAnchor constraintEqualToAnchor:self.content.topAnchor],
            [_imageView.leadingAnchor constraintEqualToAnchor:self.content.leadingAnchor],
            [_imageView.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor],
            [_captionLabel.topAnchor constraintEqualToAnchor:_imageView.bottomAnchor constant:2],
            [_captionLabel.leadingAnchor constraintEqualToAnchor:self.content.leadingAnchor],
            [_captionLabel.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor],
            [_captionLabel.bottomAnchor constraintEqualToAnchor:self.content.bottomAnchor],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.imageView.image = nil;
    self.captionLabel.text = nil;
}

@end

/// 「图标预览」：直接显示主页列表卡片左边那块 2×2 拼图（同一个 TBThemeFourUpImage，
/// 同一组代表性图标），不是详情页自己的 previewBids —— 两处必须长得一模一样。
@interface TBFourIconCell : TBPreviewTileCell
@property (nonatomic, strong) UIImageView *imageView;
@end

@implementation TBFourIconCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _imageView = [[UIImageView alloc] init];
        _imageView.translatesAutoresizingMaskIntoConstraints = NO;
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.clipsToBounds = NO;
        [self.content addSubview:_imageView];
        [NSLayoutConstraint activateConstraints:@[
            [_imageView.topAnchor constraintEqualToAnchor:self.content.topAnchor],
            [_imageView.leadingAnchor constraintEqualToAnchor:self.content.leadingAnchor],
            [_imageView.trailingAnchor constraintEqualToAnchor:self.content.trailingAnchor],
            [_imageView.bottomAnchor constraintEqualToAnchor:self.content.bottomAnchor],
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.imageView.image = nil;
}

@end

#pragma mark - 预览合并卡（遮罩预览 + 前几个图标，一张卡内 2×3 并排）

static const CGFloat kTBPreviewPad  = 14.0;
static const CGFloat kTBPreviewGap  = 12.0;
static const CGFloat kTBPreviewImgH = 76.0;
static const CGFloat kTBPreviewCapH = 26.0;

/// 合并预览卡的高度（宽度 = 卡宽）。卡内是 3 列 × 2 行，第 0 格是遮罩预览。
static CGFloat TBPreviewCardHeight(CGFloat width) {
    CGFloat innerW = width - kTBPreviewPad * 2.0;
    CGFloat slotW = (innerW - kTBPreviewGap * 2.0) / 3.0;
    CGFloat imgH = MIN(kTBPreviewImgH, MAX(40.0, slotW));
    return kTBPreviewPad * 2.0 + (imgH + 4.0 + kTBPreviewCapH) * 2.0 + kTBPreviewGap;
}

@interface TBPreviewCardCell : UICollectionViewCell
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *slots;
@property (nonatomic, strong) NSMutableArray<UILabel *> *caps;
@end

@implementation TBPreviewCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];

        _card = TBGlassCard(kTBCardRadius);       // 一张卡装下全部预览
        _card.clipsToBounds = YES;
        [self.contentView addSubview:_card];

        _slots = [NSMutableArray array];
        _caps = [NSMutableArray array];
        for (NSInteger i = 0; i < 6; i++) {
            UIImageView *iv = [[UIImageView alloc] init];
            iv.contentMode = UIViewContentModeScaleAspectFit;
            iv.clipsToBounds = NO;
            iv.hidden = YES;
            [_card addSubview:iv];
            [_slots addObject:iv];

            UILabel *cl = [[UILabel alloc] init];
            cl.font = [UIFont systemFontOfSize:9.5];
            cl.textColor = [UIColor secondaryLabelColor];
            cl.textAlignment = NSTextAlignmentCenter;
            cl.numberOfLines = 2;
            cl.lineBreakMode = NSLineBreakByTruncatingTail;
            cl.hidden = YES;
            [_card addSubview:cl];
            [_caps addObject:cl];
        }
    }
    return self;
}

/// 第 0 格 = 遮罩预览（配说明），后面依次是主题里的前几个图标
- (void)setPreviewImages:(NSArray *)images captions:(NSArray<NSString *> *)captions {
    for (NSInteger i = 0; i < (NSInteger)self.slots.count; i++) {
        UIImageView *iv = self.slots[i];
        UILabel *cap = self.caps[i];
        id o = (i < (NSInteger)images.count) ? images[i] : nil;
        UIImage *im = [o isKindOfClass:[UIImage class]] ? o : nil;
        NSString *tx = (i < (NSInteger)captions.count) ? captions[i] : nil;
        if (!tx.length) tx = nil;
        iv.image = im;
        cap.text = tx;
        iv.hidden = (im == nil);
        cap.hidden = (tx == nil);
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.contentView.bounds;
    self.card.frame = b;
    CGFloat innerW = b.size.width - kTBPreviewPad * 2.0;
    CGFloat slotW = (innerW - kTBPreviewGap * 2.0) / 3.0;
    CGFloat imgH = MIN(kTBPreviewImgH, MAX(40.0, slotW));
    for (NSInteger i = 0; i < (NSInteger)self.slots.count; i++) {
        NSInteger row = i / 3, col = i % 3;
        CGFloat x = kTBPreviewPad + col * (slotW + kTBPreviewGap);
        CGFloat y = kTBPreviewPad + row * (imgH + 4.0 + kTBPreviewCapH + kTBPreviewGap);
        self.slots[i].frame = CGRectMake(x, y, slotW, imgH);
        self.caps[i].frame = CGRectMake(x - 2, y + imgH + 4.0, slotW + 4, kTBPreviewCapH);
    }
}

@end

#pragma mark - 分区标题

@interface TBSectionHeaderView : UICollectionReusableView
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation TBSectionHeaderView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor secondaryLabelColor];
        [self addSubview:_titleLabel];
        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4],
            [_titleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6],
        ]];
    }
    return self;
}
@end

#pragma mark - 详情页

@interface TBThemeDetailController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
                                       UISearchResultsUpdating>
@property (nonatomic, strong) TBTheme *theme;
@property (nonatomic, strong) NSArray<NSString *> *allBids;
@property (nonatomic, strong) NSArray<NSString *> *bids;        // 搜索过滤后
@property (nonatomic, strong) NSArray<NSString *> *previewBids; // 预览方卡用的前几个
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, strong) UIView *bgView;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, assign) NSUInteger covered;
@property (nonatomic, assign) NSUInteger installed;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) NSUInteger applyFeedbackGeneration;
@property (nonatomic, strong) UIImage *maskPreviewImage;   // 遮罩预览（已按当前形状裁好）
@property (nonatomic, copy) NSString *maskPreviewCaption;
- (void)tb_dismissSearch;

- (void)tb_prefsChanged;   // 偏好变更通知 → 刷新遮罩预览
@end

/// 偏好一变（形状三模式 / 叠加层 / 阴影 / 导入遮罩）就让遮罩预览立即重算
static void TBDetailPrefsChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                                 const void *object, CFDictionaryRef userInfo) {
    TBThemeDetailController *vc = (__bridge TBThemeDetailController *)observer;
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [vc tb_prefsChanged];
    });
}


@implementation TBThemeDetailController

- (instancetype)initWithTheme:(TBTheme *)theme {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _theme = theme;
    }
    return self;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.theme.name;

    [self.theme loadIndex];
    self.allBids = [self.theme bundleIdentifiers];
    self.bids = self.allBids;

    // 预览方卡：取前 5 个真的有图的图标
    NSMutableArray<NSString *> *pv = [NSMutableArray array];
    for (NSString *bid in self.allBids) {
        if ([self.theme imageForBundleID:bid]) {
            [pv addObject:bid];
            if (pv.count >= 5) break;
        }
    }
    self.previewBids = pv;

    [self computeCoverage];
    [self tb_buildUI];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜应用名或 bundleID";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;

    // 0.15.53：与列表页同款的三条搜索退出路径（0.15.50 删了系统「取消」按钮）。
    // ① 点网格任意处收起；cancelsTouchesInView=NO，不影响 cell 点按
    UITapGestureRecognizer *dismissTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tb_dismissSearch)];
    dismissTap.cancelsTouchesInView = NO;
    [self.collectionView addGestureRecognizer:dismissTap];
    // ③ 键盘收起（下拉隐藏键盘 / 系统收起）→ 同步退出搜索态
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tb_dismissSearch)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    [self refreshMaskPreview];
    [self refreshApplyState];

    // 偏好变更（形状 / 叠加层 / 阴影）：预览卡片立即刷新
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)(self), TBDetailPrefsChanged,
                                    (__bridge CFStringRef)TBNotifyChanged, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)(self),
                                       (__bridge CFStringRef)TBNotifyChanged, NULL);
}

/// 遮罩/特效参数变了 → 重算预览并只重载「预览」分区
- (void)tb_prefsChanged {
    [self refreshMaskPreview];
    if (self.collectionView.numberOfSections > 1) {
        [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:1]];
    }
}

/// 背景 + 双列方形卡片网格
- (void)tb_buildUI {
    self.view.backgroundColor = [UIColor clearColor];

    self.bgView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.bgView.userInteractionEnabled = NO;
    [self.view addSubview:self.bgView];
    TBApplyPageBackground(self.bgView);

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumInteritemSpacing = kTBCardGap;
    layout.minimumLineSpacing = kTBCardGap;
    layout.sectionInset = UIEdgeInsetsMake(8, kTBSideInset, 28, kTBSideInset);   // 上 8 / 下 28（= v0.15.56）

    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    // ★ 0.15.57：两种形态用各自的 reuse identifier，cell 从创建起就只会是那一种形态，
    //   不会出现「compact 卡被网格复用 / 网格卡被 compact 复用」→ 约束来回换 → 闪一下。
    [self.collectionView registerClass:[TBSquareCardCell class]
            forCellWithReuseIdentifier:@"cardCompact"];
    [self.collectionView registerClass:[TBSquareCardCell class]
            forCellWithReuseIdentifier:@"cardGrid"];
    [self.collectionView registerClass:[TBShapePreviewCell class]
            forCellWithReuseIdentifier:@"shapePreview"];
    [self.collectionView registerClass:[TBFourIconCell class]
            forCellWithReuseIdentifier:@"fourIcon"];
    [self.collectionView registerClass:[TBSectionHeaderView class]
            forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
                   withReuseIdentifier:@"header"];
    [self.view addSubview:self.collectionView];

    [NSLayoutConstraint activateConstraints:@[
        [self.collectionView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshMaskPreview];      // 遮罩形状参数可能在别处改过
    [self refreshApplyState];
    [self.collectionView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.applyFeedbackGeneration++; // 离页后即使返回，也不弹之前请求的提示。
}

- (void)computeCoverage {
    NSArray<NSDictionary *> *apps = [TBAppInfo installedApps];
    self.installed = apps.count;
    NSUInteger hit = 0;
    for (NSDictionary *a in apps) {
        if ([self.theme hasIconForBundleID:a[@"bid"]]) hit++;
    }
    self.covered = hit;
}

/// 应用状态 + 右上角「缺 N」入口（原有功能入口全部保留）
- (void)refreshApplyState {
    self.active = [[TBPrefs stringForKey:TBKeyActiveTheme] isEqualToString:self.theme.name];
    NSUInteger miss = self.installed > self.covered ? self.installed - self.covered : 0;
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:(miss ? [NSString stringWithFormat:@"缺 %lu", (unsigned long)miss] : @"全覆盖")
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(missingTapped)],
    ];
    if (self.collectionView.numberOfSections > 0) {
        [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:0]];
    }
}

#pragma mark - 遮罩预览

/// 示例图标：优先用主题里第一张真图；没有就画一张占位方图（保证预览永远有东西看）
- (UIImage *)tb_sampleIcon {
    for (NSString *bid in self.allBids) {
        UIImage *img = [self.theme imageForBundleID:bid];
        if (img) return img;
    }
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(180, 180)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor systemBlueColor] setFill];
        UIRectFill(CGRectMake(0, 0, 180, 180));
        [[UIColor whiteColor] setFill];
        UIBezierPath *p = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(55, 55, 70, 70)];
        [p fill];
    }];
}

/// 按当前生效的形状 + AnemoneEffects（叠加层 / 阴影）裁出示例图标：
///   UseThemeIconMask  → 用主题的遮罩图（找不到就顺延，和引擎一致）
///   MaskCornerRadiusOn → 圆角 = (MaskCornerRadius / 60) × 边长
///   否则               → 系统形状 22.37%
///   UseThemeIconShadow → 阴影垫在图标下方
///   UseThemeIconOverlay→ 叠加层盖在图标之上
/// 任一参数变了，viewWillAppear / 通知回调都会重算这张预览
- (void)refreshMaskPreview {
    BOOL useThemeMask = [TBPrefs boolForKey:kTBKeyUseThemeIconMask defaultValue:NO];
    BOOL cornerOn = [TBPrefs boolForKey:kTBKeyMaskCornerRadiusOn defaultValue:NO];
    double r = [TBPrefs doubleForKey:kTBKeyMaskCornerRadius defaultValue:kTBDefaultMaskCornerRadius];
    if (!(r > 0.0)) r = kTBDefaultMaskCornerRadius;

    UIImage *art = [self tb_sampleIcon];
    UIImage *mask = nil;
    if (useThemeMask) {
        NSString *p = [self.theme iconMaskPath];
        if (p.length) mask = [UIImage imageWithContentsOfFile:p];
    }
    // AnemoneEffects：主题里真的有素材才算"生效"
    UIImage *shadow = nil, *overlay = nil;
    NSString *shadowPath = [self.theme anemoneEffectPath:@"iPhoneShadow"];
    NSString *overlayPath = [self.theme anemoneEffectPath:@"iPhoneOverlay"];
    if ([TBPrefs boolForKey:kTBKeyUseThemeIconShadow defaultValue:NO] && shadowPath.length)
        shadow = [UIImage imageWithContentsOfFile:shadowPath];
    if ([TBPrefs boolForKey:kTBKeyUseThemeIconOverlay defaultValue:NO] && overlayPath.length)
        overlay = [UIImage imageWithContentsOfFile:overlayPath];

    const CGFloat side = 200.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];
    UIImage *out = [rd imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGRect rect = CGRectMake(0, 0, side, side);
        if (shadow) [shadow drawInRect:rect];                 // ① 阴影垫在下面

        CGContextSaveGState(c);
        if (mask) {                                           // ② 形状：主题遮罩图
            [art drawInRect:rect];
            [mask drawInRect:rect blendMode:kCGBlendModeDestinationIn alpha:1.0];
        } else if (cornerOn) {                                //    形状：自定义圆角
            CGFloat radius = (CGFloat)(r / 60.0) * side;
            CGFloat maxR = side / 2.0;
            if (radius > maxR) radius = maxR;
            UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius];
            [p addClip];
            [art drawInRect:rect];
        } else {                                              //    形状：系统形状
            UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:rect
                                                         cornerRadius:side * 0.2237];
            [p addClip];
            [art drawInRect:rect];
        }
        CGContextRestoreGState(c);

        if (overlay) [overlay drawInRect:rect];                // ③ 叠加层盖在上面
    }];
    self.maskPreviewImage = out;

    NSMutableString *cap = [NSMutableString string];
    if (useThemeMask && mask) {
        [cap appendString:@"主题遮罩图"];
    } else if (cornerOn) {
        [cap appendFormat:@"自定义圆角\n半径 %.2f", r];
    } else if (useThemeMask) {
        [cap appendString:@"主题里没有遮罩图\n→ 系统形状"];
    } else {
        [cap appendString:@"系统形状\n（22.37%）"];
    }
    if (overlay || shadow) {
        [cap appendString:@"\n"];
        if (overlay) [cap appendString:@"＋叠加层 "];
        if (shadow) [cap appendString:@"＋阴影"];
    }
    self.maskPreviewCaption = cap;
}

#pragma mark - 操作卡片

- (void)tb_notifyApplyWithCancelledFeedback:(BOOL)cancelled {
    NSUInteger generation = ++self.applyFeedbackGeneration;
    [TBToast dismissNow];
    __weak TBThemeDetailController *weakSelf = self;
    [TBPrefs notifyChangedWithCompletion:^(BOOL confirmed) {
        TBThemeDetailController *owner = weakSelf;
        if (!owner || owner.applyFeedbackGeneration != generation || !owner.isViewLoaded ||
            !owner.view.window || owner.presentedViewController || owner.isBeingDismissed ||
            owner.isMovingFromParentViewController ||
            (owner.navigationController && owner.navigationController.topViewController != owner) ||
            [UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
        // 自绘底栏切页只隐藏父视图，不一定转发生命周期回调。
        for (UIView *view = owner.view; view; view = view.superview) {
            if (view.hidden || view.alpha < 0.01) return;
        }
        if (confirmed) {
            if (cancelled) [TBToast showCancelledIn:owner];
            else [TBToast showAppliedIn:owner];
        } else {
            [TBToast show:@"设置已保存，尚未收到应用完成确认" icon:@"clock" in:owner];
        }
    }];
    [self refreshApplyState]; // 这里只反映偏好已保存；成功提示必须等 SpringBoard 回执。
}

- (void)applyTapped {
    [TBPrefs setString:self.theme.name forKey:TBKeyActiveTheme];
    [TBPrefs setBool:YES forKey:TBKeyEnabled];
    [self tb_notifyApplyWithCancelledFeedback:NO];
}

- (void)cancelApplyTapped {
    NSString *active = [TBPrefs stringForKey:TBKeyActiveTheme];
    if (![active isEqualToString:self.theme.name]) return;
    __weak TBThemeDetailController *weakSelf = self;
    TBPresentConfirm(self, @"取消应用？", @"桌面图标会恢复系统原样，主题文件夹不会被删除",
                     @"取消", @"取消应用", YES, ^(BOOL ok) {
        TBThemeDetailController *owner = weakSelf;
        if (!ok || !owner || !owner.isViewLoaded || !owner.view.window) return;
        // 确认面板关闭前，当前主题可能已被别处修改。
        if (![[TBPrefs stringForKey:TBKeyActiveTheme] isEqualToString:owner.theme.name]) return;
        [TBPrefs setString:nil forKey:TBKeyActiveTheme];
        [owner tb_notifyApplyWithCancelledFeedback:YES];
    });
}

- (void)exportTapped {
    NSArray<NSDictionary *> *apps = [TBAppInfo installedApps];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *root = [docs stringByAppendingPathComponent:[NSString stringWithFormat:@"Exports/%@", self.theme.name]];
    NSString *iconsDir = [root stringByAppendingPathComponent:@"IconBundles"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:root error:nil];
    [fm createDirectoryAtPath:iconsDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    NSUInteger copied = 0;
    for (NSDictionary *a in apps) {
        NSString *bid = a[@"bid"];
        NSString *src = [self.theme imagePathForBundleID:bid];
        if (src.length == 0) {
            [missing addObject:[NSString stringWithFormat:@"%@\t%@", bid, a[@"name"] ?: @""]];
            continue;
        }
        NSString *dst = [iconsDir stringByAppendingPathComponent:src.lastPathComponent];
        [fm removeItemAtPath:dst error:nil];
        if ([fm copyItemAtPath:src toPath:dst error:nil]) copied++;
    }
    NSString *missingPath = [root stringByAppendingPathComponent:@"缺失清单.txt"];
    [[missing componentsJoinedByString:@"\n"] writeToFile:missingPath atomically:YES
                                                  encoding:NSUTF8StringEncoding error:nil];

    NSString *msg = [NSString stringWithFormat:@"已导出 %lu 个图标，缺失 %lu 个（清单在同目录）\n\n%@",
                     (unsigned long)copied, (unsigned long)missing.count, root];
    TBPresentAlert(self, @"导出完成", msg);
}

- (void)missingTapped {
    [self.navigationController pushViewController:[[TBMissingController alloc] initWithTheme:self.theme] animated:YES];
}

#pragma mark - 搜索

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text;
    if (q.length == 0) {
        self.bids = self.allBids;
    } else {
        NSString *q2 = [q lowercaseString];
        self.bids = [self.allBids filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *bid, NSDictionary *b) {
            if ([[bid lowercaseString] rangeOfString:q2].location != NSNotFound) return YES;
            NSString *tail = [[bid componentsSeparatedByString:@"."] lastObject];
            if ([[tail lowercaseString] rangeOfString:q2].location != NSNotFound) return YES;
            NSString *name = [TBAppInfo displayNameForBundleID:bid];
            return name && [[name lowercaseString] rangeOfString:q2].location != NSNotFound;
        }]];
    }
    [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:2]];
}

/// 收起搜索（0.15.53：搜索栏删了系统「取消」按钮后的退出路径）
- (void)tb_dismissSearch {
    if (self.search && self.search.active) {
        self.search.active = NO;   // searchBar 会跟着失焦收起
        self.bids = self.allBids;
        if (self.collectionView.numberOfSections > 2) {
            [self.collectionView reloadSections:[NSIndexSet indexSetWithIndex:2]];
        }
    }
}

/// ② 开始拖动网格 → 收起搜索（用户往下滑是明确的「退出搜索」意图）
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self tb_dismissSearch];
}

/// ② 兜底：大位移滚动（只在用户真实拖动/惯性时触发；搜索激活动画也会改 contentOffset，别误收）
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!self.search.active) return;
    BOOL userScrolling = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating;
    if (userScrolling && fabs(scrollView.contentOffset.y) > 10.0) [self tb_dismissSearch];
}

#pragma mark - 网格（双列方形卡片）

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv { return 3; }

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s {
    if (s == 0) return 4;                       // 概览 / 应用 / 取消应用 / 导出
    if (s == 1) return 2;                       // 两张预览卡：系统形态 / 图标预览
    return self.bids.count;
}

- (CGFloat)collectionView:(UICollectionView *)cv
layout:(UICollectionViewLayout *)layout
heightForHeaderInSection:(NSInteger)s {
    return s == 0 ? 0.0 : 30.0;   // 分组标题 30（= v0.15.56）
}

/// 预览区只有两张卡：算成「一行居中」，左右各留 (W - (2w + 12)) / 2
- (UIEdgeInsets)collectionView:(UICollectionView *)cv
                        layout:(UICollectionViewLayout *)layout
        insetForSectionAtIndex:(NSInteger)s {
    // 左右 16、上 8、下 28（= v0.15.56）
    if (s != 1) return UIEdgeInsetsMake(8, kTBSideInset, 28, kTBSideInset);
    CGFloat W = cv.bounds.size.width;
    if (W < 1) W = [UIScreen mainScreen].bounds.size.width;
    CGFloat w = floor((W - kTBSideInset * 2 - kTBCardGap * 3) / 4.0);
    if (w < 56) w = 56;
    CGFloat side = floor((W - (2 * w + kTBCardGap)) / 2.0);
    while (side > 0 && (2 * w + kTBCardGap + 2 * side) > W) side -= 1;   // 防浮点把两卡挤成两行
    if (side < 0) side = 0;
    return UIEdgeInsetsMake(8, side, 28, side);
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)cv
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)ip {
    if (![kind isEqualToString:UICollectionElementKindSectionHeader]) return nil;
    TBSectionHeaderView *h = [cv dequeueReusableSupplementaryViewOfKind:kind
                                                    withReuseIdentifier:@"header"
                                                           forIndexPath:ip];
    h.titleLabel.text = (ip.section == 1)
        ? @"预览"
        : [NSString stringWithFormat:@"全部图标（%lu）", (unsigned long)self.bids.count];
    return h;
}

- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)layout
  sizeForItemAtIndexPath:(NSIndexPath *)ip {
    CGFloat W = cv.bounds.size.width;
    if (W < 1) W = [UIScreen mainScreen].bounds.size.width;
    if (ip.section == 0) {                      // 四个功能卡：再小一档（78 高）
        CGFloat two = floor((W - kTBSideInset * 2 - kTBCardGap) / 2.0);
        if (two < 120) two = 120;
        return CGSizeMake(two, 78);
    }
    if (ip.section == 1) {                      // 预览：两张卡，尺寸与 4 列图标卡完全一致
        CGFloat w = floor((W - kTBSideInset * 2 - kTBCardGap * 3) / 4.0);
        if (w < 56) w = 56;
        return CGSizeMake(w, floor(w * kTBGridIconScale) + kTBGridTextBlock);
    }
    // 全部图标：四列，图标 = 卡宽 × 0.86，高度 = 图标 + 文字块（与 cell 内约束同一套数字）
    CGFloat col = floor((W - kTBSideInset * 2 - kTBCardGap * 3) / 4.0);
    if (col < 56) col = 56;
    CGFloat iconH = floor(col * kTBGridIconScale);
    return CGSizeMake(col, iconH + kTBGridTextBlock);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)ip {
    // 预览分区：第 1 张「系统形态」（遮罩合成图），第 2 张「图标预览」（2×2 四个图标）
    if (ip.section == 1) {
        if (ip.item == 0) {
            TBShapePreviewCell *sc = [cv dequeueReusableCellWithReuseIdentifier:@"shapePreview"
                                                                    forIndexPath:ip];
            sc.titleLabel.text = @"系统形态";
            sc.imageView.image = self.maskPreviewImage;
            sc.captionLabel.text = self.maskPreviewCaption.length ? self.maskPreviewCaption : @"遮罩预览";
            return sc;
        }
        TBFourIconCell *fc = [cv dequeueReusableCellWithReuseIdentifier:@"fourIcon" forIndexPath:ip];
        fc.titleLabel.text = @"图标预览";
        // 和主页列表卡片左边那块 2×2 完全同源（TBThemeFourUpImage），不另选图标
        fc.imageView.image = TBThemeFourUpImage(self.theme, 240.0);
        return fc;
    }

    NSString *cardID = (ip.section == 0) ? @"cardCompact" : @"cardGrid";
    TBSquareCardCell *cell = [cv dequeueReusableCellWithReuseIdentifier:cardID forIndexPath:ip];
    cell.icon.tintColor = [UIColor secondaryLabelColor];
    cell.compact = (ip.section == 0);   // 与 identifier 一一对应，幂等，不会换约束
    cell.captionLabel.hidden = NO;
    if (ip.section == 0) {
        NSString *sym = nil;
        switch (ip.item) {
            case 0: sym = @"square.grid.2x2"; break;
            case 1: sym = self.active ? @"checkmark.circle.fill" : @"checkmark.circle"; break;
            case 2: sym = @"arrow.uturn.backward.circle"; break;
            default: sym = @"square.and.arrow.up"; break;
        }
        UIImageSymbolConfiguration *sc =
            [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIFontWeightRegular];
        cell.icon.image = [[UIImage systemImageNamed:sym withConfiguration:sc]
                           imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        cell.icon.contentMode = UIViewContentModeCenter;
        if (ip.item == 0) {
            cell.titleLabel.text = @"概览";
            cell.captionLabel.text = [NSString stringWithFormat:@"%lu 个图标\n覆盖 %lu/%lu · %lu 文件",
                                      (unsigned long)self.allBids.count, (unsigned long)self.covered,
                                      (unsigned long)self.installed, (unsigned long)self.theme.fileCount];
        } else if (ip.item == 1) {
            cell.titleLabel.text = self.active ? @"已应用" : @"应用主题";
            cell.captionLabel.text = self.active ? @"当前正在使用" : @"点一下立即换图";
        } else if (ip.item == 2) {
            cell.titleLabel.text = @"取消应用";
            cell.captionLabel.text = self.active ? @"恢复系统图标\n（不删主题）" : @"当前未应用";
        } else {
            cell.titleLabel.text = @"导出";
            cell.captionLabel.text = @"导出已覆盖图标\n到“文件”App";
        }
        cell.icon.alpha = (ip.item == 1 && self.active) ? 0.6 : 1.0;
        cell.titleLabel.textColor = ([UIColor labelColor]);
        return cell;
    }

    // 全部图标（四列方形卡：图标 = 卡宽 × 0.80，名字小字 2 行截断）
    NSString *bid = self.bids[ip.item];
    cell.icon.contentMode = UIViewContentModeScaleAspectFit;
    cell.icon.alpha = 1.0;
    cell.icon.image = [self.theme imageForBundleID:bid];
    cell.titleLabel.textColor = [UIColor labelColor];
    cell.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    cell.titleLabel.numberOfLines = 2;
    cell.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    NSString *dn = [TBAppInfo displayNameForBundleID:bid];
    cell.titleLabel.text = dn.length ? dn : [[bid componentsSeparatedByString:@"."] lastObject];
    cell.captionLabel.hidden = YES;          // 四列空间紧，只留名字（2 行截断）
    cell.captionLabel.text = nil;
    return cell;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    [cv deselectItemAtIndexPath:ip animated:YES];
    if (ip.section == 1) return;             // 预览卡只做展示
    if (ip.section == 0) {
        if (ip.item == 0) {                  // 概览卡：点一下刷新统计
            [self computeCoverage];
            [self refreshApplyState];
            return;
        }
        if (ip.item == 1) { [self applyTapped]; return; }
        if (ip.item == 2) { [self cancelApplyTapped]; return; }
        [self exportTapped];
        return;
    }
    // 图标卡：保留原来的「复制文件名」入口
    NSString *bid = self.bids[ip.item];
    TBPresentAlert(self, [TBAppInfo displayNameForBundleID:bid] ?: bid, [NSString stringWithFormat:@"%@.png", bid]);
}

@end
