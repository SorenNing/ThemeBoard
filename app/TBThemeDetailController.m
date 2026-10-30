#import "TBThemeDetailController.h"
#import "TBAppInfo.h"
#import "TBThemeScanner.h"
#import "TBPrefs.h"
#import "TBMissingController.h"
#import "TBGlass.h"

@interface TBThemeDetailController () <UICollectionViewDataSource, UICollectionViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) TBTheme *theme;
@property (nonatomic, strong) NSArray<NSString *> *allBids;
@property (nonatomic, strong) NSArray<NSString *> *bids;
@property (nonatomic, strong) UICollectionView *grid;
@property (nonatomic, strong) UIButton *applyButton;
@property (nonatomic, strong) UILabel *coverageLabel;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, assign) NSUInteger covered;
@property (nonatomic, assign) NSUInteger installed;
@end

@implementation TBThemeDetailController

- (instancetype)initWithTheme:(TBTheme *)theme {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _theme = theme;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.title = self.theme.name;

    [self.theme loadIndex];
    self.allBids = [self.theme bundleIdentifiers];
    self.bids = self.allBids;

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜应用名或 bundleID";
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = YES;

    [self computeCoverage];
    [self buildHeader];
    [self buildGrid];
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

- (void)buildHeader {
    UIView *card = TBGlassCard(24);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    UIImageView *cover = [[UIImageView alloc] init];
    cover.translatesAutoresizingMaskIntoConstraints = NO;
    cover.image = [self.theme coverImageWithSize:120];
    cover.contentMode = UIViewContentModeScaleAspectFit;
    cover.layer.cornerRadius = 12;
    cover.layer.cornerCurve = kCACornerCurveContinuous;
    cover.clipsToBounds = YES;
    [card addSubview:cover];

    UILabel *count = [[UILabel alloc] init];
    count.translatesAutoresizingMaskIntoConstraints = NO;
    count.text = [NSString stringWithFormat:@"%lu 个图标", (unsigned long)self.allBids.count];
    count.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    [card addSubview:count];

    self.coverageLabel = [[UILabel alloc] init];
    self.coverageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.coverageLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.coverageLabel.textColor = [UIColor secondaryLabelColor];
    self.coverageLabel.text = [NSString stringWithFormat:@"覆盖 %lu / %lu 个已装应用 · %lu 个文件",
                               (unsigned long)self.covered, (unsigned long)self.installed,
                               (unsigned long)self.theme.fileCount];
    [card addSubview:self.coverageLabel];

    self.applyButton = TBGlassButton(@"应用这个主题", NO);
    [self.applyButton addTarget:self action:@selector(applyTapped) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:self.applyButton];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [card.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [cover.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [cover.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [cover.widthAnchor constraintEqualToConstant:60],
        [cover.heightAnchor constraintEqualToConstant:60],

        [count.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [count.leadingAnchor constraintEqualToAnchor:cover.trailingAnchor constant:14],

        [self.coverageLabel.topAnchor constraintEqualToAnchor:count.bottomAnchor constant:2],
        [self.coverageLabel.leadingAnchor constraintEqualToAnchor:cover.trailingAnchor constant:14],
        [self.coverageLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],

        [self.applyButton.topAnchor constraintEqualToAnchor:self.coverageLabel.bottomAnchor constant:14],
        [self.applyButton.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [self.applyButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [self.applyButton.heightAnchor constraintEqualToConstant:46],
        [self.applyButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
}

- (void)buildGrid {
    UICollectionViewFlowLayout *fl = [[UICollectionViewFlowLayout alloc] init];
    CGFloat w = ([UIScreen mainScreen].bounds.size.width - 16 * 2 - 12 * 2) / 3.0;
    fl.itemSize = CGSizeMake(w, w + 26);
    fl.minimumInteritemSpacing = 12;
    fl.minimumLineSpacing = 16;
    fl.sectionInset = UIEdgeInsetsMake(14, 16, 30, 16);

    self.grid = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:fl];
    self.grid.translatesAutoresizingMaskIntoConstraints = NO;
    self.grid.backgroundColor = [UIColor clearColor];
    self.grid.dataSource = self;
    self.grid.delegate = self;
    [self.grid registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"cell"];
    [self.view addSubview:self.grid];

    UIView *card = self.view.subviews.firstObject;
    [NSLayoutConstraint activateConstraints:@[
        [self.grid.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:4],
        [self.grid.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.grid.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.grid.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshApplyButton];
}

- (void)refreshApplyButton {
    BOOL active = [[TBPrefs stringForKey:TBKeyActiveTheme] isEqualToString:self.theme.name];
    [self.applyButton setTitle:(active ? @"已应用" : @"应用这个主题") forState:UIControlStateNormal];
    self.applyButton.alpha = active ? 0.55 : 1.0;
    if (active) {
        self.navigationItem.rightBarButtonItem = [self missingButton];
    } else {
        self.navigationItem.rightBarButtonItems = @[[self missingButton],
            [[UIBarButtonItem alloc] initWithTitle:@"应用" style:UIBarButtonItemStyleDone
                                            target:self action:@selector(applyTapped)]];
    }
}

- (UIBarButtonItem *)missingButton {
    NSUInteger miss = self.installed > self.covered ? self.installed - self.covered : 0;
    return [[UIBarButtonItem alloc] initWithTitle:(miss ? [NSString stringWithFormat:@"缺 %lu", (unsigned long)miss] : @"全覆盖")
                                           style:UIBarButtonItemStylePlain
                                          target:self action:@selector(missingTapped)];
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
        message:@"设置已写入。引擎生效后桌面会立即换图；引擎未安装时需要先装引擎。"
        preferredStyle:UIAlertControllerStyleAlert];
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
            if (name && [[name lowercaseString] rangeOfString:q2].location != NSNotFound) return YES;
            return NO;
        }]];
    }
    [self.grid reloadData];
}

#pragma mark - Collection

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return self.bids.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:indexPath];
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

    NSString *bid = self.bids[indexPath.row];
    CGFloat w = ([UIScreen mainScreen].bounds.size.width - 16 * 2 - 12 * 2) / 3.0;

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, w, w)];
    iv.image = [self.theme imageForBundleID:bid];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.layer.cornerRadius = w * 0.2237;
    iv.layer.cornerCurve = kCACornerCurveContinuous;
    iv.clipsToBounds = YES;
    [cell.contentView addSubview:iv];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, w + 5, w, 20)];
    NSString *name = [TBAppInfo displayNameForBundleID:bid];
    label.text = name.length ? name : [bid componentsSeparatedByString:@"."].lastObject;
    label.font = [UIFont systemFontOfSize:11];
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [cell.contentView addSubview:label];
    return cell;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSString *bid = self.bids[indexPath.row];
    UIImage *img = [self.theme imageForBundleID:bid];
    NSString *name = [TBAppInfo displayNameForBundleID:bid] ?: bid;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:name
                                                               message:bid
                                                        preferredStyle:UIAlertControllerStyleAlert];
    CGFloat s = 160;
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake((270 - s) / 2, 56, s, s)];
    iv.image = img;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    [ac.view addSubview:iv];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制文件名" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = [NSString stringWithFormat:@"%@.png", bid];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
