#import "TBMissingController.h"
#import "TBAppInfo.h"
#import "TBGlass.h"

@implementation TBMissingController {
    TBTheme *_theme;
    NSArray<NSDictionary *> *_rows;
}

- (instancetype)initWithTheme:(TBTheme *)theme {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _theme = theme;
        NSMutableArray *miss = [NSMutableArray array];
        for (NSDictionary *app in [TBAppInfo installedApps]) {
            NSString *bid = app[@"bid"];
            if ([bid hasPrefix:@"com.apple."]) continue;   // 系统自带的不算缺失
            if (![_theme hasIconForBundleID:bid]) [miss addObject:app];
        }
        _rows = miss;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"缺少图标";
    self.tableView.rowHeight = 60;
    TBGlassTable(self.tableView);
    TBSetPageBackground(self);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"这个主题没有覆盖 %lu 个已装应用", (unsigned long)_rows.count];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @"这些应用在桌面上会显示系统原图。想补齐就把它们对应的 PNG 放进主题的 IconBundles 目录。";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.backgroundView = TBGlassCellBG(12);
    cell.selectedBackgroundView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSDictionary *row = _rows[indexPath.row];
    cell.textLabel.text = row[@"name"];
    cell.detailTextLabel.text = row[@"bid"];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    cell.imageView.image = [TBAppInfo iconForBundleID:row[@"bid"]];
    cell.imageView.layer.cornerRadius = 8;
    cell.imageView.clipsToBounds = YES;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = _rows[indexPath.row];
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = [NSString stringWithFormat:@"%@.png", row[@"bid"]];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"已复制文件名"
        message:[NSString stringWithFormat:@"%@.png", row[@"bid"]]
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
