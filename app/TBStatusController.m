#import "TBStatusController.h"
#import "TBPrefs.h"
#import "TBThemeScanner.h"
#import "TBTheme.h"
#import "TBGlass.h"

@interface TBStatusController ()
@property (nonatomic, strong) UITextView *textView;
@end

@implementation TBStatusController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"状态";
    TBAttachFrost(self.view);

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
                                         style:UIBarButtonItemStylePlain
                                        target:self action:@selector(refresh)];

    self.textView = [[UITextView alloc] init];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.backgroundColor = [UIColor clearColor];
    self.textView.layer.cornerRadius = 22;
    self.textView.layer.cornerCurve = kCACornerCurveContinuous;
    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    blur.frame = self.textView.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.userInteractionEnabled = NO;
    [self.textView insertSubview:blur atIndex:0];
    self.textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.textView.textContainerInset = UIEdgeInsetsMake(14, 14, 14, 14);
    [self.view addSubview:self.textView];

    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
    ]];

    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (NSString *)engineLogPath {
    for (NSString *p in @[@"/var/jb/var/mobile/Library/ThemeBoard/engine.log",
                          @"/var/mobile/Library/ThemeBoard/engine.log"]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;
    }
    return nil;
}

- (void)refresh {
    NSMutableString *s = [NSMutableString string];

    NSString *logPath = [self engineLogPath];
    NSDictionary *attrs = logPath ? [[NSFileManager defaultManager] attributesOfItemAtPath:logPath error:NULL] : nil;
    NSDate *mtime = attrs[NSFileModificationDate];
    NSTimeInterval age = mtime ? -[mtime timeIntervalSinceNow] : -1;

    [s appendFormat:@"引擎\n"];
    if (!logPath) {
        [s appendFormat:@"  未安装（没有 engine.log）\n"];
    } else if (age >= 0 && age < 300) {
        [s appendFormat:@"  运行中 · %d 秒前的心跳\n", (int)age];
    } else {
        [s appendFormat:@"  日志存在但 %d 分钟没更新\n", (int)(age / 60)];
    }

    [s appendFormat:@"\n设置\n"];
    [s appendFormat:@"  总开关     %@\n", [TBPrefs boolForKey:TBKeyEnabled defaultValue:YES] ? @"开" : @"关"];
    [s appendFormat:@"  当前主题   %@\n", [TBPrefs stringForKey:TBKeyActiveTheme] ?: @"（未选择）"];
    [s appendFormat:@"  范围       Dock %@ · 文件夹 %@ · 切换器 %@ · 设置 %@ · 分享 %@\n",
        [TBPrefs boolForKey:TBKeyApplyDock defaultValue:YES] ? @"✓" : @"✗",
        [TBPrefs boolForKey:TBKeyApplyFolder defaultValue:YES] ? @"✓" : @"✗",
        [TBPrefs boolForKey:TBKeyApplySwitcher defaultValue:YES] ? @"✓" : @"✗",
        [TBPrefs boolForKey:TBKeyApplySettings defaultValue:YES] ? @"✓" : @"✗",
        [TBPrefs boolForKey:TBKeyApplyShare defaultValue:YES] ? @"✓" : @"✗"];

    NSArray<TBTheme *> *themes = [TBThemeScanner scanThemes];
    NSUInteger icons = 0;
    TBTheme *active = nil;
    NSString *activeName = [TBPrefs stringForKey:TBKeyActiveTheme];
    for (TBTheme *t in themes) {
        [t loadIndex];
        if ([t.name isEqualToString:activeName]) active = t;
    }
    if (active) icons = active.iconCount;

    [s appendFormat:@"\n主题\n"];
    [s appendFormat:@"  已发现     %lu 个\n", (unsigned long)themes.count];
    if (active) [s appendFormat:@"  当前主题   %lu 个图标\n", (unsigned long)icons];
    NSArray *roots = [TBThemeScanner themeRoots];
    for (NSString *r in roots) [s appendFormat:@"  %@\n", r];

    [s appendFormat:@"\n环境\n"];
    [s appendFormat:@"  系统       iOS %@\n", [[UIDevice currentDevice] systemVersion]];
    [s appendFormat:@"  机型       %@\n", [[UIDevice currentDevice] model]];
    [s appendFormat:@"  版本       0.2.1\n"];

    if (logPath) {
        NSString *log = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:NULL];
        if (log.length) {
            NSArray *lines = [log componentsSeparatedByString:@"\n"];
            NSUInteger start = lines.count > 30 ? lines.count - 30 : 0;
            [s appendFormat:@"\n最近日志（%@）\n", logPath];
            for (NSUInteger i = start; i < lines.count; i++) {
                if ([lines[i] length]) [s appendFormat:@"%@\n", lines[i]];
            }
        }
    }

    self.textView.text = s;
}

@end
