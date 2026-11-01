#import "TBThemeDetailController.h"
#import "TBAppInfo.h"
#import "TBThemeScanner.h"
#import "TBPrefs.h"
#import "TBMissingController.h"
#import "TBGlass.h"
#import "TBTableViewController.h"

static NSString *const kSummaryID = @"summary";
static NSString *const kGridID = @"grid";

@interface TBThemeDetailController () <UISearchResultsUpdating>
@property (nonatomic, strong) TBTheme *theme;
@property (nonatomic, strong) NSArray<NSString *> *allBids;
@property (nonatomic, strong) NSArray<NSString *> *bids;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UIButton *applyButton;
@property (nonatomic, strong) UIButton *exportButton;
@property (nonatomic, assign) NSUInteger covered;
@property (nonatomic, assign) NSUInteger installed;
@end

@implementation TBThemeDetailController

- (instancetype)initWithTheme:(TBTheme *)theme {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _theme = theme;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.theme.name;

    [self.theme loadIndex];
    self.allBids = [self.theme bundleIdentifiers];
    self.bids = self.allBids;

    [self computeCoverage];

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜应用名或 bundleID";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;

    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kSummaryID];
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:kGridID];
    [self.tableView reloadData];
    [self refreshApplyButton];
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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshApplyButton];
}

- (void)refreshApplyButton {
    BOOL active = [[TBPrefs stringForKey:TBKeyActiveTheme] isEqualToString:self.theme.name];
    [self.applyButton setTitle:(active ? @"已应用" : @"应用这个主题") forState:UIControlStateNormal];
    self.applyButton.alpha = active ? 0.55 : 1.0;
    NSUInteger miss = self.installed > self.covered ? self.installed - self.covered : 0;
    // 右上角只保留「缺 N」（缺失列表入口）；应用/导出在卡片的按钮里
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:(miss ? [NSString stringWithFormat:@"缺 %lu", (unsigned long)miss] : @"全覆盖")
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(missingTapped)],
    ];
}

#pragma mark - 导出已覆盖图标

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
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"导出完成" message:msg
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)missingTapped {
    [self.navigationController pushViewController:[[TBMissingController alloc] initWithTheme:self.theme] animated:YES];
}

- (void)applyTapped {
    [TBPrefs setString:self.theme.name forKey:TBKeyActiveTheme];
    [TBPrefs setBool:YES forKey:TBKeyEnabled];
    [TBPrefs notifyChanged];
    [self refreshApplyButton];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"已应用"
        message:@"设置已写入。引擎生效后桌面会立即换图。" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

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
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 2; }

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? nil : @"全部图标";
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 1 : self.bids.count;
}

- (CGFloat)tableView:(UITableView *)t heightForRowAtIndexPath:(NSIndexPath *)ip {
    return ip.section == 0 ? 190 : 88;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 0) {
        UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:kSummaryID forIndexPath:ip];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.backgroundView = TBGlassCellBG(12);

        for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

        // 横排 5 个小预览
        UIView *prev = nil;
        NSMutableArray<UIImage *> *thumbs = [NSMutableArray array];
        for (NSString *bid in [self.theme bundleIdentifiers]) {
            if (thumbs.count >= 5) break;
            UIImage *img = [self.theme imageForBundleID:bid];
            if (img) [thumbs addObject:img];
        }
        while (thumbs.count < 5) [thumbs addObject:[UIImage systemImageNamed:@"app"]];
        for (UIImage *img in thumbs) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:img];
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            iv.contentMode = UIViewContentModeScaleAspectFill;
            iv.layer.cornerRadius = 8;
            iv.layer.cornerCurve = kCACornerCurveContinuous;
            iv.clipsToBounds = YES;
            [cell.contentView addSubview:iv];
            [NSLayoutConstraint activateConstraints:@[
                [iv.widthAnchor constraintEqualToConstant:36],
                [iv.heightAnchor constraintEqualToConstant:36],
                [iv.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:14],
                (prev ? [iv.leadingAnchor constraintEqualToAnchor:prev.trailingAnchor constant:7]
                      : [iv.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16]),
            ]];
            prev = iv;
        }

        UILabel *summary = [[UILabel alloc] init];
        summary.translatesAutoresizingMaskIntoConstraints = NO;
        summary.numberOfLines = 0;
        summary.font = [UIFont systemFontOfSize:13];
        summary.textColor = [UIColor secondaryLabelColor];
        summary.text = [NSString stringWithFormat:@"%lu 个图标\n覆盖 %lu / %lu 个已装应用 · %lu 个文件",
                        (unsigned long)self.allBids.count, (unsigned long)self.covered,
                        (unsigned long)self.installed, (unsigned long)self.theme.fileCount];
        [cell.contentView addSubview:summary];

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        BOOL active = [[TBPrefs stringForKey:TBKeyActiveTheme] isEqualToString:self.theme.name];
        [btn setTitle:(active ? @"已应用" : @"应用这个主题") forState:UIControlStateNormal];
        btn.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                             [UIColor colorWithWhite:1 alpha:0.14]);
        [btn setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        btn.layer.cornerRadius = 13;
        btn.layer.cornerCurve = kCACornerCurveContinuous;
        TBApplyRim(btn, 0.55);
        [btn addTarget:self action:@selector(applyTapped) forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:btn];
        self.applyButton = btn;

        // 导出按钮（与应用同款玻璃：半透明填充 + 白边 + 同圆角）
        UIButton *exp = [UIButton buttonWithType:UIButtonTypeSystem];
        exp.translatesAutoresizingMaskIntoConstraints = NO;
        [exp setTitle:@"导出" forState:UIControlStateNormal];
        exp.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [exp setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        exp.backgroundColor = TBDynamicColor([UIColor colorWithWhite:1 alpha:0.62],
                                             [UIColor colorWithWhite:1 alpha:0.14]);
        exp.layer.cornerRadius = 13;
        exp.layer.cornerCurve = kCACornerCurveContinuous;
        TBApplyRim(exp, 0.55);
        [exp addTarget:self action:@selector(exportTapped) forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:exp];
        self.exportButton = exp;

        [NSLayoutConstraint activateConstraints:@[
            [summary.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:58],
            [summary.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:18],
            [summary.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-18],

            [btn.topAnchor constraintEqualToAnchor:summary.bottomAnchor constant:12],
            [btn.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [btn.trailingAnchor constraintEqualToAnchor:exp.leadingAnchor constant:-10],
            [btn.heightAnchor constraintEqualToConstant:44],
            [btn.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-14],

            [exp.topAnchor constraintEqualToAnchor:summary.bottomAnchor constant:12],
            [exp.leadingAnchor constraintEqualToAnchor:btn.trailingAnchor constant:10],
            [exp.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [exp.heightAnchor constraintEqualToConstant:44],
        ]];
        return cell;
    }

    // 图标行
    UITableViewCell *cell = [t dequeueReusableCellWithIdentifier:kGridID forIndexPath:ip];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.backgroundView = TBGlassCellBG(12);
    cell.selectedBackgroundView = nil;
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

    NSString *bid = self.bids[ip.row];
    CGFloat side = 56;

    UIImageView *iv = [[UIImageView alloc] initWithImage:[self.theme imageForBundleID:bid]];
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = side * 0.2237;
    iv.layer.cornerCurve = kCACornerCurveContinuous;
    iv.clipsToBounds = YES;
    [cell.contentView addSubview:iv];

    UILabel *name = [[UILabel alloc] init];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *dn = [TBAppInfo displayNameForBundleID:bid];
    name.text = dn.length ? dn : [bid componentsSeparatedByString:@"."].lastObject;
    name.font = [UIFont systemFontOfSize:14];
    name.textColor = [UIColor labelColor];
    name.lineBreakMode = NSLineBreakByTruncatingTail;
    [cell.contentView addSubview:name];

    UILabel *sub = [[UILabel alloc] init];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.text = bid;
    sub.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    sub.textColor = [UIColor secondaryLabelColor];
    sub.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [cell.contentView addSubview:sub];

    [NSLayoutConstraint activateConstraints:@[
        [iv.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [iv.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:14],
        [iv.widthAnchor constraintEqualToConstant:side],
        [iv.heightAnchor constraintEqualToConstant:side],

        [name.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:18],
        [name.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:12],
        [name.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-14],

        [sub.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:2],
        [sub.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:12],
        [sub.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-14],
    ]];
    return cell;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != 1) return;
    NSString *bid = self.bids[ip.row];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:
                             [TBAppInfo displayNameForBundleID:bid] ?: bid message:bid
                             preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制文件名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"%@.png", bid];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
