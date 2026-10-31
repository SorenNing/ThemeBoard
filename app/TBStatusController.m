#import "TBStatusController.h"
#import "TBPrefs.h"
#import "TBThemeScanner.h"
#import "TBTheme.h"
#import "TBGlass.h"

@interface TBStatusController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSString *logText;
@property (nonatomic, strong) NSString *engineState;
@property (nonatomic, strong) NSString *engineDetail;
@end

@implementation TBStatusController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"状态";
    self.view.backgroundColor = [UIColor clearColor];
    // 顺序不能反：TBGlassTable 会把 backgroundColor 清成透明


    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 52;
    self.table.estimatedSectionHeaderHeight = 24;
    TBGlassTable(self.table);
    TBSetPageBackground(self);
    [self.view addSubview:self.table];

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(refresh)];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (NSString *)logPath {
    // 只用这个路径（引擎就写在这里，实测 6.4MB、实时更新）
    return @"/var/mobile/Library/ThemeBoard/engine.log";
}

- (void)refresh {
    NSString *path = [self logPath];
    NSDictionary *attrs = path ? [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] : nil;
    NSDate *mtime = attrs[NSFileModificationDate];
    NSTimeInterval age = mtime ? -[mtime timeIntervalSinceNow] : -1;

    if (!path) {
        self.engineState = @"未运行";
        self.engineDetail = @"找不到 engine.log，引擎没有注入";
    } else if (age >= 0 && age < 180) {
        self.engineState = @"运行中";
        self.engineDetail = [NSString stringWithFormat:@"%d 秒前的心跳", (int)age];
    } else {
        self.engineState = @"已停止";
        self.engineDetail = [NSString stringWithFormat:@"%d 分钟没有更新", (int)(age / 60)];
    }

    if (path) {
        NSString *log = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (log.length == 0) {
            // 引擎可能写在了另一个映射路径；把能找到的所有候选都试一遍
            for (NSString *alt in @[@"/var/jb/var/mobile/Library/ThemeBoard/engine.log",
                                    @"/var/mobile/Library/ThemeBoard/engine.log"]) {
                NSString *l2 = [NSString stringWithContentsOfFile:alt encoding:NSUTF8StringEncoding error:NULL];
                if (l2.length) { log = l2; path = alt; break; }
            }
        }
        NSArray *lines = [log componentsSeparatedByString:@"\n"];
        NSUInteger start = lines.count > 40 ? lines.count - 40 : 0;
        NSMutableArray *tail = [NSMutableArray array];
        for (NSUInteger i = start; i < lines.count; i++) {
            if ([lines[i] length]) [tail addObject:lines[i]];
        }
        self.logText = [tail componentsJoinedByString:@"\n"];
        if (!self.logText.length) self.logText = @"（日志存在但为空）";
    } else {
        self.logText = @"（没有日志）";
    }
    [self.table reloadData];
}

#pragma mark - 数据

- (NSString *)activeTheme {
    return [TBPrefs stringForKey:TBKeyActiveTheme] ?: @"未选择";
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? nil : (s == 1 ? @"环境" : @"引擎日志");
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 3 : (s == 1 ? 3 : 1);
}

- (CGFloat)tableView:(UITableView *)t heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == 2) return 300;
    if (ip.section == 0 && ip.row == 0) return 78;
    return 52;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.backgroundView = TBGlassCellBG(12);
    cell.selectedBackgroundView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13];

    if (ip.section == 0) {
        NSArray *syms = @[@"waveform.path.ecg", @"paintpalette", @"square.grid.2x2"];
        if (ip.row < syms.count) {
            cell.imageView.image = [UIImage systemImageNamed:syms[ip.row]];
            cell.imageView.tintColor = [UIColor secondaryLabelColor];
        }
        if (ip.row == 0) {
            cell.textLabel.text = self.engineState;
            cell.textLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
            cell.detailTextLabel.text = nil;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;

            BOOL on = [self.engineState isEqualToString:@"运行中"];
            UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
            dot.backgroundColor = on ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
            dot.layer.cornerRadius = 5;
            cell.accessoryView = dot;

            UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(58, 46, t.bounds.size.width - 120, 18)];
            sub.text = self.engineDetail;
            sub.font = [UIFont systemFontOfSize:13];
            sub.textColor = [UIColor secondaryLabelColor];
            sub.tag = 900;
            [cell.contentView addSubview:sub];
        } else if (ip.row == 1) {
            cell.textLabel.text = @"当前主题";
            cell.detailTextLabel.text = [self activeTheme];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            NSArray<TBTheme *> *themes = [TBThemeScanner scanThemes];
            cell.textLabel.text = @"已发现主题";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu 个", (unsigned long)themes.count];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    } else if (ip.section == 1) {
        NSArray *rows = @[@[@"系统", [[UIDevice currentDevice] systemVersion], @"iphone"],
                          @[@"机型", [[UIDevice currentDevice] model], @"iphone.gen3"],
                          @[@"版本", @"0.11.5", @"number"]];
        cell.imageView.image = [UIImage systemImageNamed:rows[ip.row][2]];
        cell.imageView.tintColor = [UIColor secondaryLabelColor];
        cell.textLabel.text = rows[ip.row][0];
        cell.detailTextLabel.text = rows[ip.row][1];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        // 日志块：图标固定在左上角，和文字对齐，不用默认 imageView（会垂直居中）
        UIImageView *logIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"doc.text"]];
        logIcon.tintColor = [UIColor secondaryLabelColor];
        logIcon.frame = CGRectMake(16, 14, 16, 16);
        [cell.contentView addSubview:logIcon];

        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(40, 8, t.bounds.size.width - 88, 268)];
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        tv.backgroundColor = [UIColor clearColor];
        tv.editable = NO;
        tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        tv.textColor = [UIColor secondaryLabelColor];
        tv.text = self.logText;
        [cell.contentView addSubview:tv];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 2) {
        [UIPasteboard generalPasteboard].string = self.logText;
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [g impactOccurred];
    }
}

@end
