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

/// 容错读取：文件里只要有一个坏字节，UTF-8 整体解码就会返回 nil。
/// 先尝试 UTF-8，失败则用 Latin-1（永不失败），并且只读末尾 256KB。
static NSString *TBReadLogLossy(NSString *path) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;
    unsigned long long size = 0;
    @try {
        size = [fh seekToEndOfFile];
        unsigned long long tailLen = size > 256 * 1024 ? 256 * 1024 : size;
        [fh seekToFileOffset:size - tailLen];
        NSData *data = [fh readDataToEndOfFile];
        [fh closeFile];
        if (!data.length) return nil;
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!s) s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        if (!s) s = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
        return s;
    } @catch (NSException *e) {
        return nil;
    }
}

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
    NSMutableString *out = [NSMutableString string];

    // ---- 1. 存活标记：引擎构造器第一件事写它（C 文件 API，最可靠）----
    NSString *markerText = nil;
    for (NSString *mk in @[@"/var/mobile/Library/ThemeBoard/alive.txt",
                           @"/var/jb/var/mobile/Library/ThemeBoard/alive.txt"]) {
        NSString *t = [NSString stringWithContentsOfFile:mk encoding:NSUTF8StringEncoding error:NULL];
        if (t.length) { markerText = t; break; }
    }
    if (markerText.length) {
        NSArray *ml = [markerText componentsSeparatedByString:@"\n"];
        NSUInteger keep = ml.count > 8 ? ml.count - 8 : 0;
        [out appendFormat:@"【存活标记】引擎已被加载\n%@\n\n",
            [[ml subarrayWithRange:NSMakeRange(keep, ml.count - keep)] componentsJoinedByString:@"\n"]];
    } else {
        [out appendString:@"【存活标记】没有 —— 引擎 dylib 未被加载\n\n"];
    }

    // ---- 2. 引擎日志 ----
    NSString *path = @"/var/mobile/Library/ThemeBoard/engine.log";
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if (!attrs) {
        NSString *alt = @"/var/jb/var/mobile/Library/ThemeBoard/engine.log";
        NSDictionary *a2 = [[NSFileManager defaultManager] attributesOfItemAtPath:alt error:NULL];
        if (a2) { path = alt; attrs = a2; }
    }
    NSDate *mtime = attrs[NSFileModificationDate];
    NSTimeInterval age = mtime ? -[mtime timeIntervalSinceNow] : -1;

    if (!attrs) {
        self.engineState = @"未运行";
        self.engineDetail = @"找不到 engine.log";
    } else if (age >= 0 && age < 180) {
        self.engineState = @"运行中";
        self.engineDetail = [NSString stringWithFormat:@"%d 秒前的心跳", (int)age];
    } else {
        self.engineState = @"已停止";
        self.engineDetail = age < 0 ? @"时间异常"
            : [NSString stringWithFormat:@"%d 分钟没有更新", (int)(age / 60)];
    }

    NSString *log = TBReadLogLossy(path);
    if (!log.length) {
        for (NSString *a in @[@"/var/jb/var/mobile/Library/ThemeBoard/engine.log",
                              @"/var/mobile/Library/ThemeBoard/engine.log"]) {
            NSString *l2 = TBReadLogLossy(a);
            if (l2.length) { log = l2; break; }
        }
    }
    if (!log.length) {
        [out appendString:@"【引擎日志】（没有日志）"];
    } else {
        NSArray *lines = [log componentsSeparatedByString:@"\n"];
        NSUInteger start = lines.count > 40 ? lines.count - 40 : 0;
        NSMutableArray *tail = [NSMutableArray array];
        for (NSUInteger i = start; i < lines.count; i++) {
            if ([lines[i] length]) [tail addObject:lines[i]];
        }
        NSString *body = [tail componentsJoinedByString:@"\n"];
        [out appendFormat:@"【引擎日志】\n%@", body.length ? body : @"（日志存在但为空）"];
    }
    self.logText = out;
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
                          @[@"版本", @"0.12.3", @"number"]];
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
