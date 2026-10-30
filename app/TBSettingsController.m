#import "TBSettingsController.h"
#import "TBPrefs.h"
#import "TBThemeScanner.h"
#import "TBGlass.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
// 统一的文件夹选择器：iOS14+ 走 UTType，老系统回退；任何异常都不让它崩
static UIDocumentPickerViewController *TBNewFolderPicker(void) {
    @try {
        if (@available(iOS 14.0, *)) {
            UTType *folder = [UTType typeWithIdentifier:@"public.folder"];
            if (folder) {
                return [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[folder] asCopy:NO];
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

@interface TBSettingsController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *model;
@end

@implementation TBSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";

    TBAttachFrost(self.view);
    TBGlassTable(self.tableView);
    self.tableView.rowHeight = 56;

    self.model = @[
        @[ @{@"t": @"启用引擎", @"k": TBKeyEnabled, @"v": @YES, @"d": @"关闭后完全恢复系统原样"} ],
        @[ @{@"t": @"程序坞", @"k": TBKeyApplyDock, @"v": @YES},
           @{@"t": @"文件夹预览", @"k": TBKeyApplyFolder, @"v": @YES},
           @{@"t": @"App 切换器", @"k": TBKeyApplySwitcher, @"v": @YES},
           @{@"t": @"设置页图标", @"k": TBKeyApplySettings, @"v": @YES},
           @{@"t": @"分享面板", @"k": TBKeyApplyShare, @"v": @YES} ],
        @[ @{@"t": @"导入主题…", @"act": @"import"},
           @{@"t": @"在文件管理器中打开主题目录", @"act": @"open"},
           @{@"t": @"重新扫描主题", @"act": @"rescan"},
           @{@"t": @"清除当前主题", @"act": @"clear"} ],
        @[ @{@"t": @"写日志", @"k": TBKeyLogEnabled, @"v": @YES} ],
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.model.count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"引擎";
        case 1: return @"生效范围";
        case 2: return @"主题";
        default: return @"诊断";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"引擎是注入系统进程的组件，App 只负责选择和写设置。";
    if (section == 1) return @"关掉某一项，那个位置就保持系统原样。";
    if (section == 2) {
        NSMutableString *s = [NSMutableString stringWithString:@"主题目录：\n"];
        for (NSDictionary *d in [TBThemeScanner rootDiagnostics]) {
            NSString *flag = [d[@"exists"] boolValue]
                ? ([d[@"writable"] boolValue] ? @"✓可写" : @"✓只读")
                : @"✗不存在";
            [s appendFormat:@"%@ %@ (%@ 项)\n", flag, d[@"path"], d[@"count"]];
        }
        return s;
    }
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
    cell.textLabel.text = row[@"t"];

    if (row[@"k"]) {
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
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.model[indexPath.section][indexPath.row];
    NSString *act = row[@"act"];
    if (!act) return;

    if ([act isEqualToString:@"import"]) {
        UIDocumentPickerViewController *picker = TBNewFolderPicker();
        if (!picker) { [self alert:@"打不开" msg:@"系统没有可用的文件夹选择器"]; return; }
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    } else if ([act isEqualToString:@"open"]) {
        [self openThemeFolder];
    } else if ([act isEqualToString:@"rescan"]) {
        NSArray *themes = [TBThemeScanner scanThemes];
        [self alert:@"扫描完成" msg:[NSString stringWithFormat:@"找到 %lu 个主题", (unsigned long)themes.count]];
    } else if ([act isEqualToString:@"clear"]) {
        [TBPrefs setString:nil forKey:TBKeyActiveTheme];
        [TBPrefs notifyChanged];
        [self alert:@"已清除" msg:@"当前不再使用任何主题"];
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
    if (!url) return;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSError *err = nil;
    NSString *dst = [TBThemeScanner importThemeDirectory:url error:&err];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (dst) [self alert:@"导入完成" msg:dst];
    else [self alert:@"导入失败" msg:err.localizedDescription ?: @"未知错误"];
}

- (void)alert:(NSString *)title msg:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
