#import "TBThemeListController.h"
#import "TBThemeDetailController.h"
#import "TBThemeScanner.h"
#import "TBPrefs.h"
#import "TBGlass.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
// 统一的文件夹选择器：iOS14+ 走 UTType，老系统回退；任何异常都不让它崩
static UIDocumentPickerViewController *TBNewFolderPicker(void) {
    @try {
        if (@available(iOS 14.0, *)) {
            UTType *folder = [UTType typeWithIdentifier:@"public.folder"];
            UTType *zip = [UTType typeWithIdentifier:@"public.zip-archive"];
            NSMutableArray *types = [NSMutableArray array];
            if (folder) [types addObject:folder];
            if (zip) [types addObject:zip];
            if (types.count) {
                return [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
            }
        }
        return [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.folder"]
                                                                    inMode:UIDocumentPickerModeImport];
    } @catch (NSException *e) {
        NSLog(@"[ThemeBoard] picker 创建失败: %@", e);
        return nil;
    }
}

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TBThemeListController () <UISearchResultsUpdating, UIDocumentPickerDelegate>
@property (nonatomic, strong) NSArray<TBTheme *> *themes;
@property (nonatomic, strong) NSArray<TBTheme *> *filtered;
@property (nonatomic, strong) UISearchController *search;
@property (nonatomic, assign) NSInteger sortMode;   // 0 名称 1 图标数
@end

@implementation TBThemeListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"主题";
    self.tableView.rowHeight = 76;
    TBGlassTable(self.tableView);

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    UIBarButtonItem *import = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
                                                              style:UIBarButtonItemStylePlain
                                                             target:self action:@selector(importTapped)];
    UIBarButtonItem *sort = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                                                            style:UIBarButtonItemStylePlain
                                                           target:self action:@selector(sortTapped)];
    self.navigationItem.rightBarButtonItems = @[import, sort];

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

- (void)reload {
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
    if (self.sortMode == 1) {
        base = [base sortedArrayUsingComparator:^NSComparisonResult(TBTheme *a, TBTheme *b) {
            [a loadIndex]; [b loadIndex];
            if (a.iconCount == b.iconCount) return [a.name caseInsensitiveCompare:b.name];
            return a.iconCount > b.iconCount ? NSOrderedAscending : NSOrderedDescending;
        }];
    }
    self.filtered = base;
    [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    [self applyFilter];
}

- (void)sortTapped {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"排序"
                                                               message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"按名称" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        self.sortMode = 0; [self applyFilter];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"按图标数量" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        self.sortMode = 1; [self applyFilter];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 导入

- (void)importTapped {
    UIDocumentPickerViewController *picker = TBNewFolderPicker();
    if (!picker) { [self alertTitle:@"打不开" message:@"系统没有可用的文件夹选择器"]; return; }
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;

    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *err = nil;
    NSString *dst = [TBThemeScanner importFromAnyURL:url error:&err];
    if (scoped) [url stopAccessingSecurityScopedResource];

    if (dst) {
        [self reload];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"导入完成"
            message:dst preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    } else {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"导入失败"
            message:err.localizedDescription ?: @"未知错误" preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

#pragma mark - Table

- (NSString *)activeThemeName {
    return [TBPrefs stringForKey:TBKeyActiveTheme];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"当前使用" : @"已安装主题";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 1) return nil;
    if (self.themes.count == 0) {
        NSArray *roots = [TBThemeScanner themeRoots];
        NSString *where = roots.count ? [roots componentsJoinedByString:@"\n"] : @"（没有可用的主题目录）";
        return [NSString stringWithFormat:@"还没有主题。点右上角 + 导入，或把包含 IconBundles 的文件夹放到：\n%@", where];
    }
    return [NSString stringWithFormat:@"共 %lu 个 · 兼容 SnowBoard / Anemone 的 IconBundles 结构",
            (unsigned long)self.filtered.count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? 1 : self.filtered.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"theme";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.backgroundView = TBGlassCellBG(12);
        cell.selectedBackgroundView = nil;
        cell.imageView.layer.cornerRadius = 11;
        cell.imageView.layer.cornerCurve = kCACornerCurveContinuous;
        cell.imageView.clipsToBounds = YES;
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    if (indexPath.section == 0) {
        NSString *active = [self activeThemeName];
        TBTheme *t = active ? [TBThemeScanner themeNamed:active] : nil;
        cell.textLabel.textColor = t ? [UIColor labelColor] : [UIColor secondaryLabelColor];
        cell.textLabel.text = t ? t.name : @"未应用主题";
        cell.textLabel.textColor = t ? [UIColor labelColor] : [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = t ? [NSString stringWithFormat:@"%lu 个图标", (unsigned long)t.iconCount]
                                      : @"从下方选择一个主题";
        cell.imageView.image = t ? [self thumbFor:t] : [UIImage systemImageNamed:@"circle.dashed"];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = t ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    } else {
        TBTheme *t = self.filtered[indexPath.row];
        [t loadIndex];
        cell.textLabel.text = t.name;
        cell.textLabel.textColor = [UIColor labelColor];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 个图标 · %lu 个文件",
                                     (unsigned long)t.iconCount, (unsigned long)t.fileCount];
        cell.imageView.image = [self thumbFor:t];
        cell.accessoryType = [[self activeThemeName] isEqualToString:t.name]
            ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (UIImage *)thumbFor:(TBTheme *)theme {
    CGFloat s = 46;
    UIImage *cover = [theme coverImageWithSize:s];
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
    TBTheme *t = nil;
    if (indexPath.section == 0) {
        NSString *active = [self activeThemeName];
        t = active ? [TBThemeScanner themeNamed:active] : nil;
        if (!t) return;
    } else {
        t = self.filtered[indexPath.row];
    }
    [self.navigationController pushViewController:[[TBThemeDetailController alloc] initWithTheme:t] animated:YES];
}

#pragma mark - 删除

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1) return nil;
    TBTheme *t = self.filtered[indexPath.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                     title:@"删除"
                                                                   handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:
                                 [NSString stringWithFormat:@"删除「%@」？", t.name]
            message:@"主题文件夹会被直接删除，不可恢复" preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { done(NO); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            NSError *err = nil;
            BOOL ok = [TBThemeScanner deleteTheme:t error:&err];
            if (ok) {
                NSString *active = [TBPrefs stringForKey:TBKeyActiveTheme];
                if ([active isEqualToString:t.name]) [TBPrefs setString:nil forKey:TBKeyActiveTheme];
                [self reload];
            }
            done(ok);
        }]];
        [self presentViewController:ac animated:YES completion:nil];
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}


- (void)alertTitle:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
