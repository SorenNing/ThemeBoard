#import "TBPanelController.h"
#import <objc/runtime.h>
#import "TBThemeListController.h"
#import "TBThemeDetailController.h"
#import "TBThemeScanner.h"
#import "TBPrefs.h"
#import "TBGlass.h"
#import "TBBottomSheetController.h"
#import "TBTableViewController.h"
#import "TBDocImport.h"
#import "TBToast.h"
#import "TBSpacing.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TBThemeListController () <UISearchResultsUpdating, UIDocumentPickerDelegate>
@property (nonatomic, strong) NSArray<TBTheme *> *themes;
@property (nonatomic, strong) NSArray<TBTheme *> *filtered;
/// 分组后：主题包（有应用图标）/ 素材包（遮罩·边框·阴影·角标）
@property (nonatomic, strong) NSArray<TBTheme *> *themePacks;
@property (nonatomic, strong) NSArray<TBTheme *> *assetPacks;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, assign) NSInteger sortMode;   // 0 名称 1 图标数
/// 0.15.54：强引用当前 picker —— 之前是局部变量，虽然有 present 持有，
/// 但一旦被提前 dismiss（比如 search 控制器抢了呈现）就会连回调一起消失，
/// 表现正是「点了文件完全没反应」。留住它 + delegate 自查日志。
@property (nonatomic, strong) UIDocumentPickerViewController *activePicker;
/// 0.15.63：左滑看门狗 —— didEndEditingRow 不一定会被调用（滑一半松手 / 直接滚动），
/// 用轻量轮询等左滑容器消失后再把 ✓ 补回来
@property (nonatomic, strong) NSTimer *tb_swipeWatchTimer;
- (void)tb_applyCheckmarkForCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)ip;
- (void)tb_applyCheckmarkForCell:(UITableViewCell *)cell
                     atIndexPath:(NSIndexPath *)ip
                           force:(BOOL)force;
- (void)tb_dismissSearch;
@end

static UIView *TBFindSwipePullView(UIView *root, NSInteger depth) {
    if (depth > 4) return nil;
    for (UIView *v in root.subviews) {
        if ([NSStringFromClass(v.class) containsString:@"UISwipeActionPullView"]) return v;
        UIView *r = TBFindSwipePullView(v, depth + 1);
        if (r) return r;
    }
    return nil;
}

// ── 以下三段 = v0.15.41（commit 6868857）原样搬回 ──────────────────────────
static void TBPaintRedLabels(UIView *v, NSInteger depth);

static void TBStyleSwipePullView(UIView *pull) {
    CGFloat scale = [UIScreen mainScreen].scale;
    pull.backgroundColor = [UIColor clearColor];
    pull.layer.cornerRadius = 20;
    pull.layer.cornerCurve = kCACornerCurveContinuous;
    pull.clipsToBounds = YES;

    for (UIView *btn in pull.subviews) {
        btn.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                             [UIColor colorWithWhite:1 alpha:0.14]);
        btn.layer.cornerRadius = 20;
        btn.layer.cornerCurve = kCACornerCurveContinuous;
        btn.clipsToBounds = YES;
        btn.layer.borderWidth = 1.0 / scale;
        btn.layer.borderColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.55],
                                               [UIColor colorWithWhite:1 alpha:0.20]).CGColor;
        TBPaintRedLabels(btn, 0);
    }
}

/// 只把删除按钮里的文字染红；不设 tintColor（会向下继承，染红整张表）
static void TBPaintRedLabels(UIView *v, NSInteger depth) {
    if (!v || depth > 3) return;
    for (UIView *sub in v.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            ((UILabel *)sub).textColor = [UIColor systemRedColor];
        } else {
            TBPaintRedLabels(sub, depth + 1);
        }
    }
}

/// 滑动容器每次布局都重新套样式：样式和原来一模一样，只是时机提前到首帧之前，
/// 不会先闪一下系统灰底，也不会因为「那次没抓到」而整行变灰。
static void (*o_swipePullLayout)(id, SEL);
static void tb_swipePullLayout(id self, SEL _cmd) {
    if (o_swipePullLayout) o_swipePullLayout(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) TBStyleSwipePullView((UIView *)self);
}


@implementation TBThemeListController

- (void)viewDidLoad {
    [TBThemeListController tb_installSwipeStyle];
    [super viewDidLoad];
    self.title = @"主题";
    self.tableView.rowHeight = 76;

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    // 0.15.53：0.15.50 删了系统「取消」按钮后，激活的搜索没有退路（点屏幕/滑动都收不回去）。
    // 三条退出路径：
    // ① 点列表任意处（含空白）→ 收起；cancelsTouchesInView=NO，不影响 cell 点击
    UITapGestureRecognizer *dismissTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tb_dismissSearch)];
    dismissTap.cancelsTouchesInView = NO;
    [self.tableView addGestureRecognizer:dismissTap];
    // ③ 键盘收起（下拉隐藏键盘 / 系统收起）→ 同步退出搜索态
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(tb_dismissSearch)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    // 排序按钮已从导航栏挪进列表（「主题」分组标题右侧），见 viewForHeaderInSection:

    // 三个操作按钮放在「当前使用」下面（见 tableView:cellForRowAtIndexPath: 第 1 段）

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;

    [TBThemeScanner seedDemoThemesIfNeeded];
    [TBPrefs setString:[TBThemeScanner containerThemesDir] forKey:@"ThemeRoot"];
    [TBPrefs synchronize];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}


#pragma mark - 数据

/// 收起搜索（0.15.53：搜索栏删了系统「取消」按钮后的退出路径）
- (void)tb_dismissSearch {
    if (self.search && self.search.active) {
        self.search.active = NO;   // searchBar 会跟着失焦收起
        [self applyFilter];
    }
}

/// ② 开始拖动列表 → 收起搜索（用户往下滑是明确的「退出搜索」意图）
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self tb_dismissSearch];
}

/// ② 兜底：大位移滚动（只在用户真实拖动/惯性时触发；搜索激活动画也会改 contentOffset，别误收）
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (!self.search.active) return;
    BOOL userScrolling = scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating;
    if (userScrolling && fabs(scrollView.contentOffset.y) > 10.0) [self tb_dismissSearch];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self tb_stopSwipeWatch];
}

- (void)dealloc {
    [_tb_swipeWatchTimer invalidate];
}

- (void)reload {
    // 0.15.63：reload 时先收掉左滑看门狗（行会重建，扫描旧 cell 没意义）
    [self tb_stopSwipeWatch];
    self.themes = [TBThemeScanner scanThemes];
    [self applyFilter];
    [self.refreshControl endRefreshing];
}

- (void)applyFilter {
    NSArray *base = self.themes;
    NSString *q = self.search.searchBar.text;
    if (q.length) {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(TBTheme *t, NSDictionary *b) {
            return [t.name rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound;
        }];
        base = [base filteredArrayUsingPredicate:p];
    }
    NSArray *sorted = base;
    if (self.sortMode == 1) {
        sorted = [base sortedArrayUsingComparator:^NSComparisonResult(TBTheme *a, TBTheme *b) {
            [a loadIndex]; [b loadIndex];
            if (a.iconCount == b.iconCount) return [a.name caseInsensitiveCompare:b.name];
            return a.iconCount > b.iconCount ? NSOrderedAscending : NSOrderedDescending;
        }];
    }
    self.filtered = sorted;

    // 分组：主题包（有 IconBundles/<反向域名>.png 等应用图标）/ 素材包（只有遮罩、边框、阴影、角标）
    NSMutableArray<TBTheme *> *packs = [NSMutableArray array];
    NSMutableArray<TBTheme *> *assets = [NSMutableArray array];
    for (TBTheme *t in sorted) {
        if (t.isAssetPack) [assets addObject:t];
        else               [packs addObject:t];
    }
    self.themePacks = packs;
    self.assetPacks = assets;

    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    [self applyFilter];
}

- (void)sortTapped {
    // 自绘玻璃选择弹窗（TBChoicePanelController），不再用系统 action sheet
    __weak typeof(self) wself = self;
    TBChoicePanelController *p = [TBChoicePanelController
        panelWithTitle:@"排序方式"
               message:nil
               options:@[ @"按名称", @"按图标数量" ]
               handler:^(NSInteger idx) {
        __strong typeof(self) s = wself;
        if (!s || idx < 0) return;
        s.sortMode = (idx == 0) ? 0 : 1;      // 排序逻辑不变
        [s applyFilter];
    }];
    [p presentOver:self];
}

#pragma mark - 导入

- (void)importTapped {
    // 0.15.59：主推「文件 App 分享到 ThemeBoard」通路 —— 它走 AppDelegate 的
    //   application:openURL:options:，完全不经过 UIDocumentPicker，
    //   避开用户设备上「点文件被当成取消 / 257 无权限」的问题。
    //   原来的 picker 保留为第二选项（无害）。
    if (self.search.isActive) [self tb_dismissSearch];
    __weak typeof(self) wself = self;
    TBChoicePanelController *p = [TBChoicePanelController
        panelWithTitle:@"导入主题"
               message:@"推荐用「文件」App 直接分享给 ThemeBoard：不经过系统文件选择器，最稳。\n（这条通路在你这台机器上一定能走通）"
               options:@[ @"选择文件导入", @"用「文件」App 分享到 ThemeBoard" ]
               handler:^(NSInteger idx) {
        __strong typeof(self) s = wself;
        if (!s || idx < 0) return;
        if (idx == 0) [s tb_presentImportPicker];
        else          [s tb_showShareImportHelp];
    }];
    [p presentOver:self];
}

/// 「文件」App 分享导入的步骤说明
- (void)tb_showShareImportHelp {
    TBPresentAlert(self, @"用「文件」App 分享到 ThemeBoard",
        @"1. 打开「文件」App，找到要导入的 zip（或主题文件夹）\n"
        @"2. 长按它 → 共享（也可以点右上角分享按钮）\n"
        @"3. 在 App 列表里点「ThemeBoard」\n\n"
        @"ThemeBoard 会直接打开并导入 —— 不经过系统文件选择器，"
        @"不会再出现「点了文件被当成取消」的问题。\n\n"
        @"如果共享列表里没有 ThemeBoard：点列表底部的「更多」把它打开。");
}

- (void)tb_presentImportPicker {
    // iOS14+：initForOpeningContentTypes:asCopy:NO（open in place，只用具体类型，见 TBNewImportPicker）
    // 老系统：initWithDocumentTypes:inMode:UIDocumentPickerModeImport
    // 搜索态下 self.presentedViewController 是搜索控制器，会抢走呈现 → 先退出搜索
    if (self.search.isActive) [self tb_dismissSearch];

    UIDocumentPickerViewController *picker =
        TBNewImportPicker(@[ UTTypeZIP, UTTypeFolder ],
                          @[ @"public.zip-archive", @"public.folder" ]);
    if (!picker) { [self alertTitle:@"打不开" message:@"系统没有可用的文件夹选择器"]; return; }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    self.activePicker = picker;                 // 强持有，防提前释放

    // ★ 0.15.54：从「真正的最顶层 VC」present。之前在 self 上 present，若 self 上面
    //   还挂着弹层/搜索控制器，picker 是弹出来了，但选中回调落不到 self 上（用户实测：
    //   跳到文件选择器后点文件完全没反应，且 didPickDocumentsAtURLs / WasCancelled 一行日志都没有）。
    UIViewController *host = TBTopPresentingViewController(self);
    NSLog(@"[ThemeBoard] 导入 picker: self=%@ host=%@ delegate==self?%d",
          NSStringFromClass([self class]), NSStringFromClass([host class]),
          (picker.delegate == (id)self) ? 1 : 0);
    TBLog2(@"[导入][picker] 即将 present self=%@ host=%@ delegate==self?%d",
           NSStringFromClass([self class]), NSStringFromClass([host class]),
           (picker.delegate == (id)self) ? 1 : 0);
    [host presentViewController:picker animated:YES completion:^{
        TBLog2(@"[导入][picker] present 完成 picker.presenting=%@",
               NSStringFromClass([picker.presentingViewController class]));
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    // ★ 0.15.54：这里是回调的「第一行」。用户实测 app.log 里连这一行都没有，
    //   说明要么回调没进（呈现层级/delegate 问题），要么日志被前面 return 掉。
    //   先无条件打，定位用。
    NSLog(@"[ThemeBoard] ★进入 didPickDocumentsAtURLs urls.count=%lu", (unsigned long)urls.count);
    TBLog2(@"[导入][picker] ★进入回调 didPickDocumentsAtURLs urls.count=%lu delegate=%@",
           (unsigned long)urls.count, NSStringFromClass([controller.delegate class]));
    self.activePicker = nil;

    NSURL *url = urls.firstObject;
    TBLog2(@"[导入] 主题列表：didPickDocumentsAtURLs 入口，选中 %lu 个，第一个=%@ isICloud=%d",
           (unsigned long)urls.count, url.absoluteString ?: @"(nil)",
           TBURLIsICloud(url) ? 1 : 0);
    if (!url) return;

    // 真正的读取/复制在 TBThemeScanner 里用 NSFileCoordinator 做（会触发 iCloud 下载）
    NSError *err = nil;
    NSString *dst = [TBThemeScanner importFromAnyURL:url error:&err];
    TBLog2(@"[导入] 主题列表：结果 dst=%@ err=%@", dst ?: @"(nil)", err.localizedDescription ?: @"-");

    if (dst) {
        [self reload];
        TBPresentAlert(self, @"导入完成", dst);
    } else {
        NSString *msg = err.localizedDescription
            ?: TBImportFailureMessage(url, nil, @"导入失败：读不到选中的内容");
        msg = [msg stringByAppendingString:@"\n\n可改用：文件 App → 长按 zip → 共享 → ThemeBoard。"];
        TBLog2(@"[导入] 主题列表：失败弹窗内容：%@", msg);
        TBPresentAlert(self, @"导入失败", msg);
    }
}

/// 老系统的单 URL 回调（iOS 11 起已废弃，个别系统版本只回这一条）→ 统一转给复数版本
- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentAtURL:(NSURL *)url {
    TBLog2(@"[导入][picker] 旧回调 didPickDocumentAtURL=%@", url.absoluteString ?: @"(nil)");
    if (!url) return;
    [self documentPicker:controller didPickDocumentsAtURLs:@[ url ]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // 0.15.54：取消也要有日志，否则排障时无法区分「没回调」和「用户取消」
    NSLog(@"[ThemeBoard] documentPickerWasCancelled");
    TBLog2(@"[导入][picker] 用户取消 documentPickerWasCancelled");
    self.activePicker = nil;
}

#pragma mark - 顶部工具条

- (UIView *)buildToolbarBar {
    CGFloat w = MAX(320.0, self.tableView.bounds.size.width);
    UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 56)];
    head.backgroundColor = [UIColor clearColor];
    head.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [head addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:head.leadingAnchor constant:20],
        [bar.trailingAnchor constraintEqualToAnchor:head.trailingAnchor constant:-20],
        [bar.topAnchor constraintEqualToAnchor:head.topAnchor constant:8],
        [bar.heightAnchor constraintEqualToConstant:44],
    ]];

    // 与主题详情页的按钮同款：圆角 13、高 44、16 号半粗、白色玻璃底 + 细边
    NSArray *titles = @[@"重新扫描", @"导入主题", @"清除主题"];
    NSMutableArray *all = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [b setTitle:titles[i] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [b setTitleColor:(i == 2 ? [UIColor systemRedColor] : [UIColor labelColor])
                forState:UIControlStateNormal];
        b.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                           [UIColor colorWithWhite:1 alpha:0.14]);
        b.layer.cornerRadius = 13;
        b.layer.cornerCurve = kCACornerCurveContinuous;
        TBApplyRim(b, 0.55);
        b.tag = i;
        [all addObject:b];
    }
    UIButton *scan = all[0], *imp = all[1], *clr = all[2];

    for (UIButton *b in all) [bar addSubview:b];
    for (UIButton *b in all) {
        [b addTarget:self action:@selector(toolbarTapped:) forControlEvents:UIControlEventTouchUpInside];
    }

    [NSLayoutConstraint activateConstraints:@[
        [scan.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [scan.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [scan.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],

        [imp.leadingAnchor constraintEqualToAnchor:scan.trailingAnchor constant:10],
        [imp.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [imp.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [imp.widthAnchor constraintEqualToAnchor:scan.widthAnchor multiplier:1.61],

        [clr.leadingAnchor constraintEqualToAnchor:imp.trailingAnchor constant:10],
        [clr.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [clr.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [clr.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [clr.widthAnchor constraintEqualToAnchor:imp.widthAnchor],
    ]];
    return head;
}

- (void)toolbarTapped:(UIButton *)b {
    switch (b.tag) {
        case 0: [self rescanTapped]; break;   // 重新扫描
        case 1: [self importTapped]; break;   // 导入主题
        default: [self clearTapped]; break;   // 清除主题
    }
}

- (void)rescanTapped {
    [self reload];
    [self alertTitle:@"扫描完成"
             message:[NSString stringWithFormat:@"找到 %lu 个主题", (unsigned long)self.themes.count]];
}

- (void)clearTapped {
    NSString *active = [TBPrefs stringForKey:TBKeyActiveTheme];
    if (!active.length) {
        [self alertTitle:@"当前没有应用主题" message:@"桌面已经是系统原样"];
        return;
    }
    // 自绘玻璃确认弹窗（TBConfirmPanelController），不再用系统 UIAlertController
    __weak typeof(self) wself = self;
    TBPresentConfirm(self, [NSString stringWithFormat:@"清除「%@」？", active],
                     @"桌面图标会恢复系统原样，主题文件夹不会被删除",
                     @"取消", @"清除", YES, ^(BOOL ok) {
        if (!ok) return;
        __strong typeof(self) s = wself;
        if (!s) return;
        [TBPrefs setString:nil forKey:TBKeyActiveTheme];
        [TBPrefs notifyChanged];
        [s reload];
    });
}

#pragma mark - Table

- (NSString *)activeThemeName {
    return [TBPrefs stringForKey:TBKeyActiveTheme];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"当前使用";
    if (section == 1) return nil;
    if (section == 2) return self.themePacks.count ? @"主题" : nil;      // 组 1：有应用图标的主题包
    return self.assetPacks.count ? @"素材" : nil;                        // 组 2：素材包
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 3) return nil;
    if (self.themes.count == 0) {
        NSArray *roots = [TBThemeScanner themeRoots];
        NSString *where = roots.count ? [roots componentsJoinedByString:@"\n"] : @"（没有可用的主题目录）";
        return [NSString stringWithFormat:@"还没有主题。点上面的「导入主题」，或把包含 IconBundles 的文件夹放到：\n%@", where];
    }
    return [NSString stringWithFormat:@"共 %lu 个（主题 %lu · 素材 %lu）· 兼容 SnowBoard / Anemone 的 IconBundles 结构",
            (unsigned long)self.filtered.count,
            (unsigned long)self.themePacks.count,
            (unsigned long)self.assetPacks.count];
}

#pragma mark - 分组标题（「主题」右侧挂排序按钮）

/// 分组标题的左缩进：和玻璃卡片左边对齐（系统内缩 20 + 卡片自身 12）
static const CGFloat kTBListHeaderInset = 32.0;

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    if (section == 2) return 56.0;   // 「主题」标题 + 右侧排序按钮
    if (section == 1) return 8.0;    // 按钮行上方的小间距（这一组本来就没有标题）
    return 34.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    CGFloat w = tableView.bounds.size.width;
    if (w < 1) w = [UIScreen mainScreen].bounds.size.width;
    CGFloat h = [self tableView:tableView heightForHeaderInSection:section];
    UIView *head = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    head.backgroundColor = [UIColor clearColor];

    NSString *title = [self tableView:tableView titleForHeaderInSection:section];
    if (title.length) {
        UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
        lab.text = title;
        lab.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        lab.textColor = [UIColor secondaryLabelColor];
        lab.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        if (section == 2) {
            lab.frame = CGRectMake(kTBListHeaderInset, (h - 20.0) / 2.0,
                                   w - kTBListHeaderInset * 2 - 64.0, 20.0);
        } else {
            lab.frame = CGRectMake(kTBListHeaderInset, h - 20.0 - 4.0, w - kTBListHeaderInset * 2, 20.0);
        }
        [head addSubview:lab];
    }

    if (section == 2) {
        // 排序按钮：从导航栏挪到这里（「主题」分组标题右侧）。
        // 0.15.53：58×44 → 40×32（圆角 10 / 图标 18pt）——之前和三操作按钮一样大，喧宾夺主
        UIButton *sort = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImageSymbolConfiguration *sc =
            [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightRegular];
        [sort setImage:[UIImage systemImageNamed:@"arrow.up.arrow.down" withConfiguration:sc]
              forState:UIControlStateNormal];
        sort.tintColor = [UIColor labelColor];
        sort.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                              [UIColor colorWithWhite:1 alpha:0.14]);
        sort.layer.cornerRadius = 10;
        sort.layer.cornerCurve = kCACornerCurveContinuous;
        TBApplyRim(sort, 0.55);
        sort.frame = CGRectMake(w - kTBListHeaderInset - 40.0, (h - 32.0) / 2.0 - 5.0, 40.0, 32.0);   // 0.15.60 起：上移 5pt，与分组标题文字视觉居中
        sort.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        [sort addTarget:self action:@selector(sortTapped) forControlEvents:UIControlEventTouchUpInside];
        [head addSubview:sort];
    }
    return head;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 1;
    if (section == 2) return self.themePacks.count;
    return self.assetPacks.count;
}

/// 当前 section 对应的数据源（2=主题包，3=素材包）
- (NSArray<TBTheme *> *)themesInSection:(NSInteger)section {
    return section == 2 ? self.themePacks : self.assetPacks;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 ? 62 : 76;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 第 1 段：三个操作按钮（在「当前使用」下面）
    if (indexPath.section == 1) {
        UITableViewCell *bc = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                     reuseIdentifier:nil];
        bc.backgroundColor = [UIColor clearColor];
        bc.contentView.backgroundColor = [UIColor clearColor];
        bc.selectionStyle = UITableViewCellSelectionStyleNone;
        UIView *bar = [self buildToolbarBar];
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        [bc.contentView addSubview:bar];
        [NSLayoutConstraint activateConstraints:@[
            [bar.leadingAnchor constraintEqualToAnchor:bc.contentView.leadingAnchor],
            [bar.trailingAnchor constraintEqualToAnchor:bc.contentView.trailingAnchor],
            [bar.topAnchor constraintEqualToAnchor:bc.contentView.topAnchor constant:4],
            [bar.heightAnchor constraintEqualToConstant:56],
        ]];
        return bc;
    }

    static NSString *cid = @"theme";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        // 卡片必须放进 contentView：系统左滑只平移 contentView，挂在 backgroundView
        // 上的卡片不会跟着走（表现就是内容左移、卡片留在原地，内容跑到卡片外面）。
        UIView *bg = TBGlassCellBG(12);
        bg.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView insertSubview:bg atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [bg.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
            // 注意贴 cell 而不是 contentView：contentView 不含右侧附件区，
            // 贴它卡片会变窄，✓ 就露到卡片外面去了
            [bg.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
            [bg.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
            [bg.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
        ]];
        cell.selectedBackgroundView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.imageView.layer.cornerRadius = 11;
        cell.imageView.layer.cornerCurve = kCACornerCurveContinuous;
        cell.imageView.clipsToBounds = YES;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    if (indexPath.section == 0) {
        NSString *active = [self activeThemeName];
        TBTheme *t = active ? [TBThemeScanner themeNamed:active] : nil;
        [t loadIndex];   // 缺这行导致“当前使用”显示 0 个图标
        cell.textLabel.text = t ? t.name : @"未应用主题";
        cell.textLabel.textColor = t ? [UIColor labelColor] : [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = t ? [NSString stringWithFormat:@"%lu 个图标 · 已应用", (unsigned long)t.iconCount]
                                      : @"从下方选择一个主题";
        cell.imageView.image = t ? [self thumbFor:t] : [UIImage systemImageNamed:@"circle.dashed"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 2) {
        NSArray<TBTheme *> *list = self.themePacks;
        if (indexPath.row >= (NSInteger)list.count) {
            [self tb_applyCheckmarkForCell:cell atIndexPath:indexPath];
            return cell;
        }
        TBTheme *t = list[indexPath.row];
        [t loadIndex];
        cell.textLabel.text = t.name;
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 个图标 · %lu 个文件",
                                     (unsigned long)t.iconCount, (unsigned long)t.fileCount];
        cell.imageView.image = [self thumbFor:t];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        NSArray<TBTheme *> *list = self.assetPacks;
        if (indexPath.row >= (NSInteger)list.count) {
            [self tb_applyCheckmarkForCell:cell atIndexPath:indexPath];
            return cell;
        }
        TBTheme *t = list[indexPath.row];
        cell.textLabel.text = t.name;
        cell.textLabel.textColor = [UIColor labelColor];
        // 副标题只列这个人素材包实际提供的项：遮罩 / 边框 / 阴影 / 角标
        cell.detailTextLabel.text = [self tb_assetSubtitleFor:t];
        cell.imageView.image = [self thumbFor:t];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    // 0.15.63：✓ 不再在各分支各写一次，统一按「当前 active 主题」重算
    [self tb_applyCheckmarkForCell:cell atIndexPath:indexPath];
    return cell;
}

#pragma mark - ✓ 勾选（0.15.63）

/// 唯一的 ✓ 计算入口：任何时刻（首次配置、复用、滚动、左滑开始/结束、reload）
/// 都以「当前 active 主题」为准重新算，不看任何缓存（0.15.41 存 associated object
/// 的做法会在「滑一半松手 / reload / reuse / didEndEditingRow 没被调用」时丢掉勾）。
/// 段 2 = 主题包行 → active 打勾；段 0/1/3 → 一律无勾（与之前外观一致）。
- (void)tb_applyCheckmarkForCell:(UITableViewCell *)cell atIndexPath:(NSIndexPath *)ip {
    if (!cell || !ip) return;
    [self tb_applyCheckmarkForCell:cell atIndexPath:ip force:NO];
}

- (void)tb_applyCheckmarkForCell:(UITableViewCell *)cell
                     atIndexPath:(NSIndexPath *)ip
                           force:(BOOL)force {
    if (!cell || !ip) return;
    UITableViewCellAccessoryType acc = UITableViewCellAccessoryNone;
    if (ip.section == 2) {
        NSArray<TBTheme *> *list = self.themePacks;
        if (ip.row >= 0 && ip.row < (NSInteger)list.count) {
            NSString *active = [TBPrefs stringForKey:TBKeyActiveTheme];
            BOOL isActive = active.length > 0 &&
                            [list[ip.row].name isEqualToString:active];
            acc = isActive ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        }
    }
    if (force) {
        // 左滑结束：UIKit 可能把附件那层留在隐藏/复位中间态，
        // 先归零再设一次，强制它重建附件（外观不变，只是让 ✓ 一定回来）
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    if (force || cell.accessoryType != acc) {
        cell.accessoryType = acc;
    }
}

/// 屏幕上的每一行都按当前 active 主题重算一次 ✓（供左滑 watch / 滚动结束调用）
- (void)tb_refreshVisibleCheckmarksForce:(BOOL)force {
    for (NSIndexPath *ip in [self.tableView indexPathsForVisibleRows]) {
        UITableViewCell *c = [self.tableView cellForRowAtIndexPath:ip];
        if (c) [self tb_applyCheckmarkForCell:c atIndexPath:ip force:force];
    }
}

/// 抓到的左滑容器是不是「还开着」：隐藏 / 透明 / 宽度归零的残留视图不算
- (BOOL)tb_pullLooksActive:(UIView *)pull {
    if (!pull) return NO;
    if (pull.hidden || pull.alpha < 0.01) return NO;
    if (pull.bounds.size.width < 1.0) return NO;
    return YES;
}

/// 这一行（含子视图）里是否还挂着左滑容器
- (BOOL)tb_rowHasActiveSwipePull:(UITableViewCell *)cell {
    return [self tb_pullLooksActive:TBFindSwipePullView(cell, 0)];
}

/// 整张表里是否还有活着的左滑容器（有的系统版本把它挂在 cell 的父层）
- (BOOL)tb_anyActiveSwipePull {
    for (NSIndexPath *ip in [self.tableView indexPathsForVisibleRows]) {
        UITableViewCell *c = [self.tableView cellForRowAtIndexPath:ip];
        if (c && [self tb_rowHasActiveSwipePull:c]) return YES;
    }
    return [self tb_pullLooksActive:TBFindSwipePullView(self.tableView, 0)];
}

/// 素材包副标题：「遮罩 · 边框 · 阴影 · 角标」里实际有的项
- (NSString *)tb_assetSubtitleFor:(TBTheme *)t {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *it in [t availableAssetItems]) {
        NSString *title = it[@"title"];
        if (title.length) [names addObject:title];
    }
    if (!names.count) return @"素材包";
    return [names componentsJoinedByString:@" · "];
}

- (UIImage *)thumbFor:(TBTheme *)theme {
    CGFloat s = 46;
    // 0.15.57：2×2 拼图抽成公共函数（主页视觉与之前完全一致，详情页「图标预览」卡共用同一份）
    UIImage *cover = TBThemeFourUpImage(theme, s);
    if (!cover) return [UIImage systemImageNamed:@"square.grid.2x2"];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(s, s)];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, s, s) cornerRadius:s * 0.2237];
        [p addClip];
        [cover drawInRect:CGRectMake(0, 0, s, s)];
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) return;   // 按钮行
    TBTheme *t = nil;
    if (indexPath.section == 0) {
        // 「当前使用」保持原样：直接进详情页（这一版不动它）
        NSString *active = [self activeThemeName];
        t = active ? [TBThemeScanner themeNamed:active] : nil;
        if (!t) return;
        @try {
            [self.navigationController pushViewController:[[TBThemeDetailController alloc] initWithTheme:t] animated:YES];
        } @catch (NSException *e) {
            [self alertTitle:[NSString stringWithFormat:@"详情页失败：%@", e.name ?: @"异常"]
                     message:[NSString stringWithFormat:@"%@", e.reason ?: @"(无原因)"]];
        }
        return;
    }
    // 组 1「主题」/ 组 2「素材」：点行 → 弹自定义底部抽屉（详情入口在抽屉里）
    NSArray<TBTheme *> *list = [self themesInSection:indexPath.section];
    t = (indexPath.row < (NSInteger)list.count) ? list[indexPath.row] : nil;
    if (!t) return;
    // 崩溃诊断：把异常原因直接弹出来（这段时间点卡片若闪退，这里能抓到真凶）
    @try {
        [self presentSheetForTheme:t];
    } @catch (NSException *e) {
        [self alertTitle:[NSString stringWithFormat:@"打开失败：%@", e.name ?: @"异常"]
                 message:[NSString stringWithFormat:@"%@", e.reason ?: @"(无原因)"]];
    }
}

#pragma mark - 底部抽屉

/// 点主题卡片：弹出抽屉（遮罩三选一 + 应用主题 + 详情）
- (void)presentSheetForTheme:(TBTheme *)theme {
    if (!theme) return;
    TBBottomSheetController *sheet = [[TBBottomSheetController alloc] initWithTheme:theme];
    __weak typeof(self) weakSelf = self;
    sheet.onApply = ^(TBTheme *t) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s.tableView reloadData];            // 刷新「当前使用」和右侧 ✓
        [TBToast showAppliedIn:s];           // 玻璃胶囊 toast（无按钮，1.5s 自动收起）
    };
    sheet.onCancelApply = ^(TBTheme *t) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s.tableView reloadData];
        [TBToast showCancelledIn:s];         // 「已取消」同一套胶囊
    };
    sheet.onDetail = ^(TBTheme *t) {
        __strong typeof(self) s = weakSelf;
        if (!s) return;
        [s.navigationController pushViewController:[[TBThemeDetailController alloc] initWithTheme:t] animated:YES];
    };
    [sheet presentOver:self];
}

#pragma mark - 删除

// ══════════════════════════════════════════════════════════════════════════
//  左滑「删除」整段恢复 v0.15.41（commit 6868857）的实现 —— 用户点名那版观感 / 交互都没问题，
//  0.15.57~0.15.61 期间加的「即时删除 + TBToast + CALayer 玻璃子层 + CGRectInset」全部撤掉。
//  唯一保留的一条工程约束（不改观感）：
//    · hook 必须先调原实现（引擎侧那条替换了 layoutSubviews 却不调原实现的 hook 已永久移除）；
//    · UIContextualAction 的 handler 先【同步】调用 completionHandler，再下一拍 present 确认弹窗，
//      否则 UIKit 的 swipe 事务收尾时会算错按钮数（NSInternalInconsistencyException）。
// ══════════════════════════════════════════════════════════════════════════

/// 给这一行套上样式；找不到滑动容器返回 NO（外观与原来完全一致，只是把
/// 「找容器」这件事做得更彻底：cell / cell 的父视图 / 表格 / 整个窗口都试一遍）
+ (void)tb_installSwipeStyle {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    Class pull = NSClassFromString(@"UISwipeActionPullView");
    if (!pull) return;
    Method m = class_getInstanceMethod(pull, @selector(layoutSubviews));
    if (m) {
        o_swipePullLayout = (void (*)(id, SEL))method_getImplementation(m);
        method_setImplementation(m, (IMP)tb_swipePullLayout);
    }
}

- (BOOL)styleSwipeForRowAtIndexPath:(NSIndexPath *)indexPath tableView:(UITableView *)tableView {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    UIView *root = cell ? (cell.superview ?: cell) : tableView;
    UIView *pull = nil;
    if (root) pull = TBFindSwipePullView(root, 0);
    if (!pull && cell) pull = TBFindSwipePullView(cell, 0);
    if (!pull) pull = TBFindSwipePullView(tableView, 0);
    if (!pull) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            pull = TBFindSwipePullView(w, 0);
            if (pull) break;
        }
    }
    if (!pull) return NO;
    TBStyleSwipePullView(pull);
    return YES;
}

- (void)tableView:(UITableView *)tableView
willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    // 复用/滚动/刷新进入屏幕时都按「当前 active 主题」重算一次 ✓，不依赖任何缓存
    [self tb_applyCheckmarkForCell:cell atIndexPath:indexPath];
}

- (void)tableView:(UITableView *)tableView willBeginEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    // 右侧 ✓ 是 cell 的附件，不跟着 contentView 一起平移 → 滑开时会露在卡片外面，
    // 先收起来。0.15.63 起不再把旧值塞进 associated object：结束时按 active 主题重算。
    // ★★ 0.15.64：滑动开始时【不再清空勾】。用户必现路径：先滑别的行 → 再滑带 ✓ 那行，
    //    勾会消失（就是这行清空造成的），取消滑动才回来。现在让 ✓ 全程显示。
    [self tb_startSwipeWatch];
    // 原版：0.05 秒后给这一行套样式（现在 swizzle 也会套，这里保留做兜底）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self styleSwipeForRowAtIndexPath:indexPath tableView:tableView];
    });
}

- (void)tableView:(UITableView *)tableView didEndEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    [self tb_stopSwipeWatch];
    // 0.15.63：不还原 associated object，直接重算「这一行现在是不是 active 主题」。
    // 即使期间发生过 reload / cell 复用（关联值丢了、对象换了一个）也算得回来。
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (cell) {
        [self tb_applyCheckmarkForCell:cell atIndexPath:indexPath force:YES];
    } else {
        // 行已经不在了（刚删掉 / 划出去了）→ 其它可见行的 ✓ 也要保住
        [self tb_refreshVisibleCheckmarksForce:YES];
    }
}

#pragma mark - 左滑看门狗（didEndEditingRow 没被调用时的兜底）

- (void)tb_startSwipeWatch {
    [self tb_stopSwipeWatch];
    NSDate *beganAt = [NSDate date];
    __weak typeof(self) wself = self;
    NSTimer *t = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *tm) {
        __strong typeof(self) s = wself;
        if (!s) { [tm invalidate]; return; }
        // 前 0.35s 是左滑容器出现/收起的动画窗口，这段时间不碰 accessory（避免闪）
        if ([[NSDate date] timeIntervalSinceDate:beganAt] < 0.35) return;
        if ([s tb_anyActiveSwipePull]) return;   // 还在滑（或容器还在动画中）
        // 左滑容器已不在任何一行上 → 这次左滑真的结束了（不管有没有回调 didEndEditingRow）
        [tm invalidate];
        s.tb_swipeWatchTimer = nil;
        [s tb_refreshVisibleCheckmarksForce:YES];
        TBLog2(@"[勾选] 左滑看门狗：左滑容器已消失 → 重算可见行 ✓");
    }];
    // 必须挂 CommonModes：默认模式在列表拖动（UITrackingRunLoopMode）期间不跑，
    // 而「滑一半直接滚动」恰恰就是拖动状态
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
    self.tb_swipeWatchTimer = t;
}

- (void)tb_stopSwipeWatch {
    [self.tb_swipeWatchTimer invalidate];
    self.tb_swipeWatchTimer = nil;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 与 0.15.41 的差异只有一处（分区逻辑不变）：那一版只有「已安装主题」一段，
    // 现在拆成 2「主题」/ 3「素材」，两段都可删。
    if (indexPath.section < 2) return nil;
    NSArray<TBTheme *> *list = [self themesInSection:indexPath.section];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)list.count) return nil;
    TBTheme *t = list[indexPath.row];

    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                     title:@"删除"
                                                                   handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        // 0.15.41 原版：先问「删除「x」？」再删。
        // completionHandler 必须同步收尾（UIKit 当场结束这次 swipe 事务），模态放到下一拍。
        done(YES);
        dispatch_async(dispatch_get_main_queue(), ^{
            // ★ 0.15.68：确认弹窗换回自绘玻璃（TBPresentConfirm）。0.15.62 回退时误用了
            //   系统 UIAlertController —— 从 swipe 事务里 present 系统 alert 正是会打断
            //   UIKit 的场景之一，可能与"删除没法用"有关；玻璃版 0.15.47 之前一直稳定。
            TBPresentConfirm(self, [NSString stringWithFormat:@"删除「%@」？", t.name],
                             @"主题文件夹会被直接删除，不可恢复",
                             @"取消", @"删除", YES, ^(BOOL ok) {
                if (!ok) return;
                NSError *err = nil;
                BOOL ok2 = [TBThemeScanner deleteTheme:t error:&err];
                if (ok2) {
                    [self tb_clearPrefsPointingInto:t.path];
                    NSString *active = [TBPrefs stringForKey:TBKeyActiveTheme];
                    if ([active isEqualToString:t.name]) [TBPrefs setString:nil forKey:TBKeyActiveTheme];
                    [TBPrefs notifyChanged];
                    [self reload];
                } else {
                    TBLog2(@"[删除] 失败 err=%@", err.localizedDescription ?: @"-");
                }
            });
        });
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

/// 删除后：把指向这个目录里的 Custom*Path 清掉并把对应开关关掉（否则设置里留着死路径）
- (void)tb_clearPrefsPointingInto:(NSString *)dir {
    if (!dir.length) return;
    NSString *prefix = [dir hasSuffix:@"/"] ? dir : [dir stringByAppendingString:@"/"];
    NSArray<NSArray<NSString *> *> *table = @[ @[@"CustomMaskPath", TBKeyUseThemeIconMask],
                                               @[@"CustomOverlayPath", TBKeyUseThemeIconOverlay],
                                               @[@"CustomShadowPath", TBKeyUseThemeIconShadow],
                                               @[@"CustomBadgePath", TBKeyUseThemeBadge] ];
    for (NSArray<NSString *> *row in table) {
        NSString *cur = [TBPrefs stringForKey:row[0]];
        if (cur.length && [cur hasPrefix:prefix]) {
            TBLog2(@"[删除] 清理偏好 %@（原值 %@）", row[0], cur);
            [TBPrefs setString:nil forKey:row[0]];
            [TBPrefs setBool:NO forKey:row[1]];
        }
    }
}


- (void)alertTitle:(NSString *)title message:(NSString *)msg {
    TBPresentAlert(self, title, msg);      // 自绘玻璃提示弹窗
}

@end
