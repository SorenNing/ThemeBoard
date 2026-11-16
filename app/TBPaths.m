#import "TBPaths.h"
#import <UIKit/UIKit.h>

#pragma mark - 路径诊断（仅系统日志，不写文件）

static void TBPathLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[ThemeBoard] %@", msg);
}

#pragma mark - 根目录

/// 首选：真正的共享目录 /var/mobile/Documents/ThemeBoard（引擎也读这里）
static NSString *const kTBCanonicalRoot = @"/var/mobile/Documents/ThemeBoard";

/// rootless：jbroot 每台设备随机（/var/containers/Bundle/Application/.jbroot-XXXX），
/// 但 <jbroot>/Library/ThemeBoard 这条路径形态固定 —— 用户指定的备选根。
static NSString *TBJBRootThemeBoard(void) {
    static NSString *r = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *appDir = @"/var/containers/Bundle/Application";
        NSArray *kids = [fm contentsOfDirectoryAtPath:appDir error:NULL];
        // ★ 0.15.72：不能再要求 Library/ThemeBoard 已存在（第一次跑时它还不存在 →
        //   之前就因此一直"未找到 jbroot"，回退到容器 Documents 里去了）。
        //   只要能找到一个 .jbroot-* 目录，就拼 <jbroot>/Library/ThemeBoard 返回。
        for (NSString *d in kids) {
            if (![d hasPrefix:@".jbroot-"]) continue;
            NSString *jbroot = [appDir stringByAppendingPathComponent:d];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:jbroot isDirectory:&isDir] || !isDir) continue;
            // Library 存在就用它；不存在也照样拼（后面 createDirectory withIntermediate 会建）
            r = [jbroot stringByAppendingPathComponent:@"Library/ThemeBoard"];
            break;
        }
    });
    return r;
}

static NSString *TBAppContainerRoot(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) return nil;
    return [docs stringByAppendingPathComponent:@"ThemeBoard"];
}

NSString *TBThemeBoardRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        // ★ 0.15.71：**完全取消** /var/mobile/Documents/ThemeBoard。
        //   唯一根 = <jbroot>/Library/ThemeBoard（jbroot 随机，但后面路径固定），
        //   与 SpringBoard 的 /var/jb/Library/Themes 同属 jbroot 树，属主一致可写可删。
        NSString *jb = TBJBRootThemeBoard();
        if (jb) {
            NSError *e1 = nil, *e2 = nil;
            BOOL okT = [fm createDirectoryAtPath:[jb stringByAppendingPathComponent:@"Themes"]
                     withIntermediateDirectories:YES attributes:nil error:&e1];
            BOOL okA = [fm createDirectoryAtPath:[jb stringByAppendingPathComponent:@"Assets"]
                     withIntermediateDirectories:YES attributes:nil error:&e2];
            TBPathLog(@"尝试根 %@ Themes=%d(%@) Assets=%d(%@)", jb, okT,
                      e1.localizedDescription ?: @"ok", okA, e2.localizedDescription ?: @"ok");
            // 只要 Themes/Assets 真的建出来了（或已存在），就用它。
            // 不要再依赖 isWritableFileAtPath：越狱路径上它对 mobile 属主目录也会返回 NO，
            // 上一版就是因此把成功的根又判成"不可写"、退回沙盒（日志 Themes=1(ok) 却仍回退）。
            BOOL haveT = [fm fileExistsAtPath:[jb stringByAppendingPathComponent:@"Themes"]];
            BOOL haveA = [fm fileExistsAtPath:[jb stringByAppendingPathComponent:@"Assets"]];
            if (haveT && haveA) {
                root = jb;
                TBPathLog(@"根目录 = %@（jbroot/Library，写入测试=%d）", root,
                          (int)[fm isWritableFileAtPath:jb]);
                return;
            }
            TBPathLog(@"jbroot 根不可用：Themes=%d Assets=%d", haveT, haveA);
            // <jbroot>/Library 可能是 root:wheel 0755 → mobile 建不了子目录。
            // 依次尝试：/var/jb/Library/ThemeBoard → 沙盒 Documents/ThemeBoard
            for (NSString *c in @[ @"/var/jb/Library/ThemeBoard" ]) {
                NSError *ec = nil;
                BOOL c1 = [fm createDirectoryAtPath:[c stringByAppendingPathComponent:@"Themes"]
                          withIntermediateDirectories:YES attributes:nil error:&ec];
                BOOL c2 = [fm createDirectoryAtPath:[c stringByAppendingPathComponent:@"Assets"]
                          withIntermediateDirectories:YES attributes:nil error:NULL];
                TBPathLog(@"尝试备选根 %@ Themes=%d(%@) Assets=%d", c, c1, ec.localizedDescription ?: @"ok", c2);
                if (c1 && c2 && [fm isWritableFileAtPath:c]) {
                    root = c;
                    TBPathLog(@"根目录 = %@（/var/jb）", root);
                    return;
                }
            }
            TBPathLog(@"⚠️ jbroot/Library 与 /var/jb 都不可写，退回沙盒");
        }
        // 找不到 .jbroot-*（理论不会）：用 /var/jb 这个标准 rootless 软链，
        // 绝不再退回 App 容器（那会变成 <jbroot>/var/mobile/Documents/ThemeBoard，用户明确否掉）
        root = @"/var/jb/Library/ThemeBoard";
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"Themes"]
           withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"Assets"]
           withIntermediateDirectories:YES attributes:nil error:NULL];
        TBPathLog(@"⚠️ 未找到 jbroot，回退到 %@", root);
    });
    return root;
}

NSString *TBThemesRoot(void) {
    return [TBThemeBoardRoot() stringByAppendingPathComponent:@"Themes"];
}

NSString *TBAssetsRoot(void) {
    return [TBThemeBoardRoot() stringByAppendingPathComponent:@"Assets"];
}

BOOL TBEnsureThemeBoardDirs(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *themes = TBThemesRoot();
    NSString *assets = TBAssetsRoot();
    for (NSString *p in @[themes, assets]) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir] || !isDir) {
            [fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:NULL];
        }
    }
    BOOL isDir = NO;
    return [fm fileExistsAtPath:themes isDirectory:&isDir] && isDir && [fm isWritableFileAtPath:themes];
}

NSArray<NSString *> *TBLegacyThemeRoots(void) {
    NSMutableArray *out = [NSMutableArray array];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length) [out addObject:[docs stringByAppendingPathComponent:@"Themes"]];   // 0.15.41 及以前真正在用的
    [out addObject:@"/var/mobile/Documents/Themes"];                                   // 需求点名的旧位置
    [out addObject:TBThemeBoardRoot()];                                                // 早前有人直接丢在根下
    [out addObject:@"/var/mobile/Library/Themes"];
    [out addObject:@"/var/jb/Library/Themes"];
    [out addObject:@"/var/jb/var/Library/Themes"];
    [out addObject:@"/Library/Themes"];
    if (TBJBRootThemeBoard()) [out addObject:TBJBRootThemeBoard()];   // jbroot/Library/ThemeBoard
    return out;
}

BOOL TBPathEqualToPath(NSString *a, NSString *b) {
    if (!a.length || !b.length) return NO;
    NSString *x = [a stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    NSString *y = [b stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]];
    return [x isEqualToString:y];
}

/// 目录看起来像主题 / 素材包（迁移时只搬这种，别把乱七八糟的东西搬进来）
static BOOL TBPathLooksLikeThemeDir(NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *sub in @[@"IconBundles", @"AnemoneEffects", @"Bundles"]) {
        BOOL d = NO;
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:sub] isDirectory:&d] && d) return YES;
    }
    for (NSString *f in @[@"Icon.png", @"icon.png", @"IconMask.png", @"AppIconMask@3x.png", @"Info.plist"]) {
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:f]]) {
            // Info.plist 只有配合上面的素材目录才算（避免把随便一个带 plist 的目录当主题）
            if ([f isEqualToString:@"Info.plist"]) continue;
            return YES;
        }
    }
    return NO;
}

#pragma mark - 启动迁移

NSString *TBMigrateLegacyThemeDirectories(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    TBEnsureThemeBoardDirs();

    NSString *themesRoot = TBThemesRoot();
    NSMutableString *summary = [NSMutableString string];
    NSInteger copied = 0, skipped = 0, failed = 0;

    for (NSString *legacy in TBLegacyThemeRoots()) {
        if (!legacy.length) continue;
        if (TBPathEqualToPath(legacy, themesRoot) || TBPathEqualToPath(legacy, TBAssetsRoot())) continue;

        BOOL isDir = NO;
        if (![fm fileExistsAtPath:legacy isDirectory:&isDir] || !isDir) continue;

        NSArray *items = [fm contentsOfDirectoryAtPath:legacy error:NULL];
        for (NSString *item in items) {
            if ([item hasPrefix:@"."]) continue;
            if ([item isEqualToString:@"Themes"] || [item isEqualToString:@"Assets"]) continue;   // 就是新结构本身
            if ([item isEqualToString:@"Exports"]) continue;                                       // 详情页导出目录，不是主题

            NSString *src = [legacy stringByAppendingPathComponent:item];
            BOOL d = NO;
            if (![fm fileExistsAtPath:src isDirectory:&d] || !d) continue;
            if (!TBPathLooksLikeThemeDir(src)) { continue; }

            NSString *dst = [themesRoot stringByAppendingPathComponent:item];
            if ([fm fileExistsAtPath:dst]) { skipped++; continue; }   // 已迁移过 / 同名已存在 → 跳过，绝不覆盖

            NSError *err = nil;
            if ([fm copyItemAtPath:src toPath:dst error:&err]) {
                copied++;
                TBPathLog(@"迁移主题：%@ → %@", src, dst);
            } else {
                failed++;
                // 失败只记录，不动源目录（用户主题不能丢）
                TBPathLog(@"⚠️ 迁移失败（跳过）：%@ → %@（%@）", src, dst,
                          err.localizedDescription ?: @"未知错误");
            }
        }
    }

    if (copied || failed) {
        [summary appendFormat:@"迁移：复制 %ld 个，跳过 %ld 个，失败 %ld 个", (long)copied, (long)skipped, (long)failed];
        TBPathLog(@"%@ → %@", summary, themesRoot);
    } else {
        [summary appendString:(skipped ? [NSString stringWithFormat:@"迁移：无新增（%ld 个已存在）", (long)skipped]
                                        : @"迁移：没有需要迁移的旧目录")];
    }
    return summary;
}

#pragma mark - 外部打开

BOOL TBOpenPathExternally(NSString *path) {
    if (!path.length) return NO;
    NSArray *cands = @[ [NSString stringWithFormat:@"filza://view%@", path],
                        [NSString stringWithFormat:@"shareddocuments://%@", path],
                        [NSString stringWithFormat:@"filza://%@", path] ];
    for (NSString *s in cands) {
        NSURL *u = [NSURL URLWithString:s];
        if (!u) continue;
        if ([[UIApplication sharedApplication] canOpenURL:u]) {
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
            return YES;
        }
    }
    return NO;
}
