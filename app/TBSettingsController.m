#import "TBPanelController.h"
#import "TBSettingsController.h"
#import "TBPrefs.h"
#import "TBThemeScanner.h"
#import "TBGlass.h"
#import "TBTableViewController.h"
#import "TBEngineInstaller.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "TBDocImport.h"
#import "TBSpacing.h"

@interface TBSettingsController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *model;
@end

@implementation TBSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";

    self.tableView.rowHeight = 56;

    self.model = @[
        @[ @{@"t": @"引擎状态", @"act": @"engineInfo"},
           @{@"t": @"重启桌面（让引擎生效）", @"act": @"respring"} ],
        @[ @{@"t": @"启用引擎", @"k": TBKeyEnabled, @"v": @YES, @"d": @"关闭后完全恢复系统原样"} ],
        @[ @{@"t": @"用主题遮罩图", @"k": @"UseThemeIconMask", @"v": @NO,
             @"d": @"主题里放 IconMask.png 就用它当图标形状"},
           @{@"t": @"自定义图标圆角", @"k": @"MaskCornerRadiusOn", @"v": @NO,
             @"d": @"开启后按 CustomCornerRadius 算法（默认 13.42）裁圆角"},
           @{@"t": @"图标圆角半径", @"k": @"MaskCornerRadius", @"v": @13.42, @"num": @YES,
             @"d": @"CustomCornerRadius，60 ≈ 满圆角，默认 13.42"},
           @{@"t": @"透明玻璃强度", @"k": TBKeyGlassOverlayStrength, @"v": @0.35, @"slider": @YES,
             @"d": @"玻璃叠加层（iPhoneOverlay）的浓淡，默认 35%；0 = 不用玻璃层"} ],
        @[ @{@"t": @"在文件管理器中打开主题目录", @"act": @"open"} ],
        @[ @{@"t": @"日历不叠加日期", @"k": @"NoCalendarDate", @"v": @NO,
             @"d": @"主题日历图标已经画了日期时打开，直接用主题图标"} ],
        @[ @{@"t": @"跟随系统深色模式", @"k": @"FollowSystem", @"v": @YES, @"d": @"关掉则固定浅色"} ],
        @[ @{@"t": @"写日志", @"k": TBKeyLogEnabled, @"v": @NO},
           @{@"t": @"安全模式（只记录，不换图）", @"k": @"SafeMode", @"v": @NO},
           @{@"t": @"应用后清图标缓存", @"k": @"PurgeCache", @"v": @NO} ],
    ];

    // 每行配一个 SF Symbol
    NSDictionary *icons = @{
        @"引擎状态": @"waveform.path.ecg", @"重启桌面（让引擎生效）": @"arrow.clockwise.circle", @"安装 / 更新引擎": @"arrow.down.circle",
        @"重启桌面": @"arrow.clockwise.circle",
        @"启用引擎": @"power",
        @"用主题遮罩图": @"square.dashed", @"自定义图标圆角": @"circle.dashed", @"图标圆角半径": @"ruler",
        @"透明玻璃强度": @"drop",
        @"导入主题…": @"square.and.arrow.down", @"在文件管理器中打开主题目录": @"folder.badge.gearshape",
        @"重新扫描主题": @"arrow.triangle.2.circlepath", @"清除当前主题": @"trash",
        @"日历不叠加日期": @"calendar.badge.minus",
        @"跟随系统深色模式": @"circle.lefthalf.filled", @"写日志": @"doc.text", @"安全模式（只记录，不换图）": @"exclamationmark.shield",
        @"应用后清图标缓存": @"arrow.clockwise",
    };
    NSMutableArray *patched = [NSMutableArray array];
    for (NSArray *sec in self.model) {
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *row in sec) {
            NSMutableDictionary *m = [row mutableCopy];
            NSString *ic = icons[row[@"t"]];
            if (ic) m[@"icon"] = ic;
            [rows addObject:m];
        }
        [patched addObject:rows];
    }
    self.model = patched;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.model.count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"引擎组件";
        case 1: return @"开关";
        case 2: return @"图标形状";
        case 3: return @"主题";
        case 4: return @"日历";
        case 5: return @"外观";
        default: return @"诊断";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"引擎运行状态无法仅凭日志确认。RootHide 可能隐藏注入目录；请在 Sileo 查看引擎是否已安装。";
    }
    if (section == 1) return @"关闭后完全恢复系统原样。";
    if (section == 2) return @"优先级：主题遮罩图 → 自定义圆角 → 系统形状。两个开关都关着 = 保持现在这样。";
    if (section == 3) {
        NSMutableString *s = [NSMutableString stringWithString:@"主题目录：\n"];
        for (NSDictionary *d in [TBThemeScanner rootDiagnostics]) {
            NSString *flag = [d[@"exists"] boolValue]
                ? ([d[@"writable"] boolValue] ? @"✓可写" : @"✓只读")
                : @"✗不存在";
            [s appendFormat:@"%@ %@ (%@ 项)\n", flag, d[@"path"], d[@"count"]];
        }
        return s;
    }
    if (section == 4) return nil;
    if (section == 5) return nil;
    if (section == 6) return @"两个诊断开关默认关闭，重启桌面/重启用户空间后不会再自己打开。\n安全模式：只写日志、绝不换图（排查用）。\n清图标缓存：个别图标换了主题赖着不换时才需要打开；平常应用主题本身就会让桌面刷新。";
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.model[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.model[indexPath.section][indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                   reuseIdentifier:nil];
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.backgroundView = TBGlassCellBG(12);
    cell.selectedBackgroundView = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = row[@"t"];
    if (row[@"icon"]) {
        cell.imageView.image = [UIImage systemImageNamed:row[@"icon"]];
        cell.imageView.tintColor = [UIColor secondaryLabelColor];
    }

    if (row[@"slider"]) {
        // 「透明玻璃强度」：0~100% 滑块，实时写入偏好（0 = 完全不画玻璃层）
        double cur = [TBPrefs doubleForKey:row[@"k"] defaultValue:[row[@"v"] doubleValue]];
        if (!(cur >= 0.0) || cur > 1.0) cur = [row[@"v"] doubleValue];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%（0 = 不用玻璃层）", cur * 100.0];
        UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 150, 32)];
        sl.minimumValue = 0.0;
        sl.maximumValue = 1.0;
        sl.value = (float)cur;
        sl.tag = indexPath.section * 100 + indexPath.row;
        [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sl;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (row[@"num"]) {
        // 数值行（MaskCornerRadius）：右侧可编辑的输入框，失焦/点"完成"时写回偏好
        if (row[@"d"]) cell.detailTextLabel.text = row[@"d"];
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 88, 32)];
        tf.textAlignment = NSTextAlignmentRight;
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.borderStyle = UITextBorderStyleRoundedRect;
        tf.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightRegular];
        tf.text = [NSString stringWithFormat:@"%.2f",
                   [TBPrefs doubleForKey:row[@"k"] defaultValue:[row[@"v"] doubleValue]]];
        tf.tag = indexPath.section * 100 + indexPath.row;
        [tf addTarget:self action:@selector(numberChanged:) forControlEvents:UIControlEventEditingDidEnd];
        UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
        bar.items = @[ [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace
                                                                     target:nil action:nil],
                       [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                     target:tf action:@selector(resignFirstResponder)] ];
        tf.inputAccessoryView = bar;
        cell.accessoryView = tf;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (row[@"k"]) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [TBPrefs boolForKey:row[@"k"] defaultValue:[row[@"v"] boolValue]];
        sw.tag = indexPath.section * 100 + indexPath.row;
        [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (row[@"d"]) cell.detailTextLabel.text = row[@"d"];
    } else {
        cell.textLabel.textColor = [UIColor labelColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if ([row[@"act"] isEqualToString:@"engineInfo"]) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            NSString *st = [TBEngineInstaller runtimeState];
            cell.detailTextLabel.text = st;
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }
        if ([row[@"act"] isEqualToString:@"respring"]) {
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.detailTextLabel.text = @"只在装完引擎后用一次";
        }
        if ([row[@"act"] isEqualToString:@"clear"]) {
            cell.textLabel.textColor = [UIColor systemRedColor];
        }
        if ([row[@"act"] isEqualToString:@"open"] && [TBThemeScanner themeRoots].count) {
            cell.detailTextLabel.text = [TBThemeScanner themeRoots].firstObject;
            cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
        }
    }
    return cell;
}

- (void)switchChanged:(UISwitch *)sw {
    NSInteger section = sw.tag / 100, row = sw.tag % 100;
    NSDictionary *item = self.model[section][row];
    [TBPrefs setBool:sw.on forKey:item[@"k"]];
    [TBPrefs notifyChanged];
    if ([item[@"k"] isEqualToString:@"FollowSystem"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"TBAppearanceChanged" object:nil];
    }
}

/// 滑块行（透明玻璃强度）：拖动即实时写入偏好 + 通知引擎
- (void)sliderChanged:(UISlider *)sl {
    NSInteger section = sl.tag / 100, row = sl.tag % 100;
    if (section < 0 || section >= (NSInteger)self.model.count) return;
    if (row < 0 || row >= (NSInteger)self.model[section].count) return;
    NSDictionary *item = self.model[section][row];
    NSString *k = item[@"k"];
    if (!k.length) return;
    [TBPrefs setDouble:(double)sl.value forKey:k];
    [TBPrefs notifyChanged];        // 实时生效：引擎收到 Darwin 通知后重画
    NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:section];
    UITableViewCell *c = [self.tableView cellForRowAtIndexPath:ip];
    c.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%（0 = 不用玻璃层）", sl.value * 100.0];
}

/// 数值行编辑结束：写回偏好（非法输入回默认值）
- (void)numberChanged:(UITextField *)tf {
    NSInteger section = tf.tag / 100, row = tf.tag % 100;
    if (section < 0 || section >= (NSInteger)self.model.count) return;
    if (row < 0 || row >= (NSInteger)self.model[section].count) return;
    NSDictionary *item = self.model[section][row];
    NSString *k = item[@"k"];
    if (!k.length) return;
    double v = tf.text.doubleValue;
    if (tf.text.length == 0 || v < 0 || v != v || v > 10000) v = [item[@"v"] doubleValue];
    [TBPrefs setDouble:v forKey:k];
    [TBPrefs notifyChanged];
    tf.text = [NSString stringWithFormat:@"%.2f", v];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.model[indexPath.section][indexPath.row];
    NSString *act = row[@"act"];
    if (!act) return;

    if ([act isEqualToString:@"import"]) {
        // 与主题列表页同一个选择器（0.15.59：iOS14+ = asCopy:NO，只用具体类型）
        UIDocumentPickerViewController *picker =
            TBNewImportPicker(@[ UTTypeZIP, UTTypeFolder ],
                                  @[ @"public.zip-archive", @"public.folder" ]);
        if (!picker) { [self alert:@"打不开" msg:@"系统没有可用的文件夹选择器"]; return; }
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    } else if ([act isEqualToString:@"respring"]) {
        TBPresentConfirm(self, @"重启桌面？",
                         @"屏幕会黑一下然后回到桌面，正在运行的应用会被关闭。装完新引擎后用一次即可。",
                         @"取消", @"重启", YES, ^(BOOL ok) {
            if (!ok) return;
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 (__bridge CFStringRef)@"com.ning.themeboard.respring",
                                                 NULL, NULL, true);
        });
    } else if ([act isEqualToString:@"open"]) {
        [self openThemeFolder];
    } else if ([act isEqualToString:@"rescan"]) {
        NSArray *themes = [TBThemeScanner scanThemes];
        [self alert:@"扫描完成" msg:[NSString stringWithFormat:@"找到 %lu 个主题", (unsigned long)themes.count]];
    } else if ([act isEqualToString:@"installEngine"]) {
        [self installEngineTapped];
    } else if ([act isEqualToString:@"helperTest"]) {
        NSString *r = [TBEngineInstaller runHelperTest];
        [self alert:@"助手自检" msg:r];
    } else if ([act isEqualToString:@"respring"]) {
        [self confirmRespring];
    } else if ([act isEqualToString:@"clear"]) {
        [TBPrefs setString:nil forKey:TBKeyActiveTheme];
        [TBPrefs notifyChanged];
        [self alert:@"已清除" msg:@"当前不再使用任何主题"];
    }
}

- (void)installEngineTapped {
    NSError *err = nil;
    if ([TBEngineInstaller dynamicLibrariesDir] == nil) {
        TBChoicePanelController *p = [TBChoicePanelController
            panelWithTitle:@"这台设备要用引擎包安装"
                   message:@"RootHide 把注入目录对 App 隐藏了，App 无法直接写入。\n在 Sileo 里装「ThemeBoard 引擎」即可，装完重启一次桌面，以后不用再管。"
                   options:@[@"复制包名", @"去 Sileo"]
                   handler:^(NSInteger idx) {
            if (idx == 0) {
                [UIPasteboard generalPasteboard].string = @"com.ning.themeboard.engine";
            } else if (idx == 1) {
                if (![TBEngineInstaller openSileoForEngine]) {
                    [self alert:@"打不开 Sileo" msg:@"请手动在 Sileo 搜索 ThemeBoard 引擎"];
                }
            }
        }];
        p.cancelTitle = @"好";
        [p presentOver:self];
        return;
    }

    if ([TBEngineInstaller installEngine:&err]) {
        [self.tableView reloadData];
        TBPresentConfirm(self, @"引擎已写入",
                         @"需要重启一次桌面才会加载。现在就重启吗？\n（只会重启 SpringBoard，不影响其他东西）",
                         @"稍后", @"立即重启", NO, ^(BOOL ok) {
            if (ok) [self doRespring];
        });
    } else {
        [self alert:@"安装失败" msg:err.localizedDescription ?: @"未知错误"];
    }
}

- (void)confirmRespring {
    TBPresentConfirm(self, @"重启桌面？",
                     @"屏幕会黑一下，随后回到桌面，正在运行的 App 会被关闭",
                     @"取消", @"重启", YES, ^(BOOL ok) {
        if (ok) [self doRespring];
    });
}

- (void)doRespring {
    if (![TBEngineInstaller respring]) {
        [self alert:@"重启失败" msg:@"找不到 sbreload / killall，请手动重启桌面"];
    }
}

- (void)openThemeFolder {
    NSString *path = [TBThemeScanner writableThemeRoot];
    if (!path) { [self alert:@"打不开" msg:@"没有可写的主题目录"]; return; }
    NSArray *urls = @[[NSString stringWithFormat:@"filza://view%@", path],
                      [NSString stringWithFormat:@"shareddocuments://%@", path],
                      [NSString stringWithFormat:@"filza://%@", path]];
    __block BOOL opened = NO;
    for (NSString *s in urls) {
        NSURL *u = [NSURL URLWithString:s];
        if (!u) continue;
        if ([[UIApplication sharedApplication] canOpenURL:u]) {
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
            opened = YES;
            break;
        }
    }
    if (!opened) {
        [UIPasteboard generalPasteboard].string = path;
        [self alert:@"已复制路径" msg:path];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    TBLog2(@"[导入] 设置页：选中 %lu 个，第一个=%@", (unsigned long)urls.count, url.absoluteString ?: @"(nil)");
    if (!url) return;
    NSError *err = nil;
    NSString *dst = [TBThemeScanner importFromAnyURL:url error:&err];   // 内部走文件协调器
    TBLog2(@"[导入] 设置页：结果 dst=%@ err=%@", dst ?: @"(nil)", err.localizedDescription ?: @"-");
    if (dst) [self alert:@"导入完成" msg:dst];
    else [self alert:@"导入失败" msg:(err.localizedDescription
                                  ?: TBImportFailureMessage(url, nil, @"未知错误"))];
}

- (void)alert:(NSString *)title msg:(NSString *)msg {
    TBPresentAlert(self, title, msg);      // 自绘玻璃提示弹窗
}

@end
