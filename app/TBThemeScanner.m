#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>
#import "TBThemeScanner.h"
#import "TBZip.h"
#import "TBPaths.h"
#import "TBImageUtil.h"
#import "TBDocImport.h"
#import <spawn.h>
#import <sys/stat.h>
#import <errno.h>
extern char **environ;

#pragma mark - 删除用的底层工具（0.15.49）

/// 递归把目录/文件权限放开。素材包里常有 root 所有或只读的文件，
/// App（mobile 用户）直接删会 EACCES，先 chmod 0777 再试一次。
static void TBRecursiveChmod(NSString *path, mode_t mode) {
    if (!path.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    // attributesOfItemAtPath = lstat 语义，不跟随符号链接。
    // （原来用 fileExistsAtPath:isDirectory:，链接指向 / 或大目录时会把整棵系统树
    //   chmod 0777 —— 既危险又巨慢。符号链接只 chmod 链接本身，绝不递归进去。）
    NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
    if (!attr.count) return;
    BOOL isDir = [attr[NSFileType] isEqualToString:NSFileTypeDirectory];
    if (chmod(path.fileSystemRepresentation, mode) != 0) {
        TBLog2(@"[删除] chmod %@ 失败 errno=%d", path, errno);
    }
    if (!isDir) return;
    NSArray *items = [fm contentsOfDirectoryAtPath:path error:NULL];
    for (NSUInteger i = 0; i < items.count; i++) {
        TBRecursiveChmod([path stringByAppendingPathComponent:items[i]], mode);
    }
}

/// 先删内容、再删空目录（目录本身删不掉时，至少把里面的东西清干净）
static BOOL TBRemoveContentsThenDir(NSString *path, NSError **outErr, int *errnoOut) {
    if (!path.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    // 先把这一层目录本身放开写权限：目录不可写时里面的 rename/remove 全会 EACCES，
    // chmod 了内容却删不动目录就是这个原因（unlink/删除条目检查的是父目录 w 位）
    if (chmod(path.fileSystemRepresentation, 0777) != 0) {
        TBLog2(@"[删除] 放开目录本身权限失败 errno=%d：%@", errno, path);
    }
    NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
    BOOL isDir = attr.count && [attr[NSFileType] isEqualToString:NSFileTypeDirectory];
    if (!attr.count) return YES;   // 已经没了
    if (!isDir) {
        NSError *e = nil;
        BOOL ok = [fm removeItemAtPath:path error:&e];
        if (!ok) { if (outErr) *outErr = e; if (errnoOut) *errnoOut = (int)e.code; }
        return ok;
    }
    NSArray *items = [fm contentsOfDirectoryAtPath:path error:NULL];
    for (NSUInteger i = 0; i < items.count; i++) {
        NSError *e = nil;
        int eno = 0;
        if (!TBRemoveContentsThenDir([path stringByAppendingPathComponent:items[i]], &e, &eno)) {
            if (outErr) *outErr = e;
            if (errnoOut) *errnoOut = eno;
            return NO;
        }
    }
    NSError *e = nil;
    if (![fm removeItemAtPath:path error:&e]) {
        if (outErr) *outErr = e;
        if (errnoOut) *errnoOut = (int)e.code;
        return NO;
    }
    return ![fm fileExistsAtPath:path];
}

/// 在解压出来的目录里递归找遮罩图：
///   ① IconBundles/Icon.png  ② icon.png  ③ AppIconMask*  ④ IconMask*
///   ⑤ 任意 PNG / JPG（深度 ≤ 6 层，条目上限保护）
static NSString *TBMaskImageInsideDir(NSString *root) {
    if (!root.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *dirs = [NSMutableArray arrayWithObject:root];
    NSMutableArray *imgs = [NSMutableArray array];
    NSInteger guard = 0;
    while (dirs.count && guard++ < 500) {
        NSString *d = dirs.firstObject;
        [dirs removeObjectAtIndex:0];
        NSArray *items = [fm contentsOfDirectoryAtPath:d error:NULL];
        for (NSUInteger i = 0; i < items.count; i++) {
            NSString *item = items[i];
            if ([item hasPrefix:@"__MACOSX"] || [item hasPrefix:@"."]) continue;
            NSString *full = [d stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) { [dirs addObject:full]; continue; }
            NSString *low = item.lowercaseString;
            if (![low hasSuffix:@".png"] && ![low hasSuffix:@".jpg"] && ![low hasSuffix:@".jpeg"]) continue;
            if ([low isEqualToString:@"icon.png"]) {
                NSString *parent = [d lastPathComponent].lowercaseString;
                if ([parent isEqualToString:@"iconbundles"]) return full;   // 最优命中
            }
            [imgs addObject:full];
        }
    }
    // 其次：任意 icon.png → AppIconMask* → IconMask* → 任意图片
    NSArray *rankPrefixes = @[ @"icon.png", @"icon@", @"appiconmask", @"iconmask" ];
    for (NSUInteger r = 0; r < rankPrefixes.count; r++) {
        NSString *pre = rankPrefixes[r];
        for (NSUInteger i = 0; i < imgs.count; i++) {
            if ([[imgs[i] lastPathComponent].lowercaseString hasPrefix:pre]) return imgs[i];
        }
    }
    return imgs.count ? imgs[0] : nil;
}

/// 扫描根 = 新结构下的 Themes/（主题包）+ Assets/（素材包）
static NSArray<NSString *> *TBScanRoots(void) {
    TBEnsureThemeBoardDirs();
    NSMutableArray *a = [NSMutableArray array];
    [a addObject:TBThemesRoot()];
    if (![a containsObject:TBAssetsRoot()]) [a addObject:TBAssetsRoot()];
    return a;
}

/// 这个子目录值不值得当条目收进来：
///   - 主题包：有 IconBundles / Bundles / 根目录 icon.png
///   - 素材包：只有 AnemoneEffects 或 AppIconMask 也算
/// 最终「是主题包还是素材包」由 TBTheme.isAssetPack 按内容判定。
static BOOL TBIsThemeLikeDirectory(NSString *dir) {
    if (!dir.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *sub in @[@"IconBundles", @"AnemoneEffects", @"Bundles"]) {
        NSString *p = [dir stringByAppendingPathComponent:sub];
        BOOL d = NO;
        if ([fm fileExistsAtPath:p isDirectory:&d] && d) return YES;
    }
    for (NSString *f in @[@"Icon.png", @"icon.png", @"IconMask.png", @"AppIconMask@3x.png"]) {
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:f]]) return YES;
    }
    return NO;
}

@implementation TBThemeScanner

+ (NSArray<NSString *> *)themeRoots {
    return TBScanRoots();
}

+ (NSString *)writableThemeRoot {
    TBEnsureThemeBoardDirs();
    return TBThemesRoot();
}

+ (NSString *)writableAssetRoot {
    TBEnsureThemeBoardDirs();
    return TBAssetsRoot();
}

+ (NSArray<NSDictionary *> *)rootDiagnostics {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *all = [NSMutableArray array];
    [all addObjectsFromArray:TBScanRoots()];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in all) {
        BOOL isDir = NO;
        BOOL exists = [fm fileExistsAtPath:p isDirectory:&isDir];
        [out addObject:@{@"path": p,
                         @"exists": @(exists),
                         @"writable": @(exists && [fm isWritableFileAtPath:p]),
                         @"count": @(exists ? (NSInteger)[fm contentsOfDirectoryAtPath:p error:NULL].count : 0)}];
    }
    return out;
}

+ (NSString *)containerThemesDir {
    TBEnsureThemeBoardDirs();
    return TBThemesRoot();
}

+ (void)seedDemoThemesIfNeeded {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = TBThemesRoot();
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];

    NSArray *existing = [fm contentsOfDirectoryAtPath:root error:NULL];
    if (existing.count > 0) return;

    NSString *bundle = [[NSBundle mainBundle] pathForResource:@"DemoThemes" ofType:nil];
    NSArray *items = bundle ? [fm contentsOfDirectoryAtPath:bundle error:NULL] : nil;
    for (NSString *item in items) {
        if (![item hasSuffix:@".theme"]) continue;
        [fm copyItemAtPath:[bundle stringByAppendingPathComponent:item]
                    toPath:[root stringByAppendingPathComponent:item] error:NULL];
    }
}

+ (NSArray<TBTheme *> *)scanThemes {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<TBTheme *> *themes = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (NSString *root in [self themeRoots]) {
        NSArray *names = [fm contentsOfDirectoryAtPath:root error:NULL];
        for (NSString *n in names) {
            if ([n hasPrefix:@"."]) continue;
            NSString *full = [root stringByAppendingPathComponent:n];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir] || !isDir) continue;

            // 主题包和素材包平级放在同一个根目录下，这里两种都收：
            //   主题包 = 有 IconBundles（Anemone/SnowBoard 图标主题）
            //   素材包 = 只有 AnemoneEffects / AppIconMask / 根目录 icon.png
            if (!TBIsThemeLikeDirectory(full)) continue;

            TBTheme *t = [[TBTheme alloc] initWithPath:full];
            if ([seen containsObject:full]) continue;      // 同一个目录只收一次
            [seen addObject:full];
            [themes addObject:t];
        }
    }
    // 主题包排前面、素材包排后面，各自按名字
    [themes sortUsingComparator:^NSComparisonResult(TBTheme *a, TBTheme *b) {
        BOOL aa = a.isAssetPack, ba = b.isAssetPack;
        if (aa != ba) return aa ? NSOrderedDescending : NSOrderedAscending;
        return [a.name caseInsensitiveCompare:b.name];
    }];
    return themes;
}

+ (TBTheme *)themeNamed:(NSString *)name {
    if (name.length == 0) return nil;
    for (TBTheme *t in [self scanThemes]) {
        if ([t.name isEqualToString:name]) return t;
    }
    return nil;
}

+ (NSString *)uniquePathForName:(NSString *)name inRoot:(NSString *)root {
    NSString *base = name;
    NSString *ext = @"";
    if ([base hasSuffix:@".theme"]) {
        base = [base substringToIndex:base.length - 6];
        ext = @".theme";
    }
    NSString *candidate = [root stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"%@%@", base, ext.length ? ext : @".theme"]];
    int i = 2;
    while ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
        candidate = [root stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@ %d.theme", base, i++]];
    }
    return candidate;
}

+ (NSString *)createAssetPackDirectoryNamed:(NSString *)name error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self writableThemeRoot];
    if (!root) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"没有可写的主题目录"}];
        return nil;
    }
    NSString *base = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!base.length) base = @"素材";
    // 去掉可能带进来的扩展名 / 路径分隔符，只留一个干净的名字
    base = [base stringByDeletingPathExtension];
    base = [base stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    if (!base.length) base = @"素材";

    NSString *candidate = [root stringByAppendingPathComponent:base];
    int i = 2;
    while ([fm fileExistsAtPath:candidate]) {
        candidate = [root stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@ %d", base, i++]];
    }
    NSError *err = nil;
    if (![fm createDirectoryAtPath:candidate withIntermediateDirectories:YES attributes:nil error:&err]) {
        if (error) *error = err;
        return nil;
    }
    return candidate;
}

+ (NSString *)importThemeDirectory:(NSURL *)srcURL error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    // 校验：必须含 IconBundles / Bundles（主题）或 AnemoneEffects / IconMask / Icon.png（素材包）
    NSString *srcPath = srcURL.path;
    BOOL looks = [self dirLooksLikeThemeOrAsset:srcPath];
    TBLog2(@"[导入][目录] src=%@ 像主题/素材=%d 有应用图标=%d",
           srcPath ?: @"(nil)", looks, [self dirHasAppIcons:srcPath]);
    if (!looks) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:3
                                            userInfo:@{NSLocalizedDescriptionKey:
                @"这个文件夹里既没有 IconBundles / Bundles（主题），也没有 AnemoneEffects / IconMask / Icon.png（素材包）"}];
        TBLog2(@"[导入][目录] ❌ 不是主题也不是素材包：%@", srcPath ?: @"(nil)");
        return nil;
    }
    // 目录里可能还套了一层（例如用户选的是解压出来的父文件夹）
    NSString *contentDir = srcPath;
    if (![self dirLooksLikeThemeOrAsset:srcPath]) contentDir = [self findContentDirIn:srcPath] ?: srcPath;
    NSString *niceName = [srcURL lastPathComponent];
    if (!niceName.length) niceName = @"导入";
    return [self placeImportedDir:contentDir niceName:niceName error:error];
}

// 在解包目录里找第一个含 IconBundles / Bundles 的文件夹（广度优先，取最浅的）
+ (NSString *)findThemeDirIn:(NSString *)root {
    return [self findContentDirIn:root];
}

/// 解包目录里找「内容目录」：主题包看 IconBundles / Bundles，
/// 素材包看 AnemoneEffects / Info.plist(TBKind) / Icon.png，两者都认（取最浅的）
+ (NSString *)findContentDirIn:(NSString *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger guard = 0;
    while (stack.count && guard++ < 20000) {
        NSString *dir = stack.firstObject;
        [stack removeObjectAtIndex:0];
        if ([self dirLooksLikeThemeOrAsset:dir]) return dir;
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if ([item hasPrefix:@"."] || [item isEqualToString:@"__MACOSX"]) continue;
            BOOL d = NO;
            NSString *sub = [dir stringByAppendingPathComponent:item];
            if ([fm fileExistsAtPath:sub isDirectory:&d] && d) [stack addObject:sub];
        }
    }
    return nil;
}

/// 这个目录像主题包或素材包（大小写不敏感地找子目录/文件）
+ (BOOL)dirLooksLikeThemeOrAsset:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (!dir.length) return NO;
    NSArray *subs = [fm contentsOfDirectoryAtPath:dir error:NULL];
    NSMutableSet<NSString *> *lower = [NSMutableSet set];
    for (NSString *s in subs) [lower addObject:s.lowercaseString];
    for (NSString *d in @[@"iconbundles", @"bundles", @"anemoneeffects", @"appiconmask"]) {
        if ([lower containsObject:d]) {
            BOOL isDir = NO;
            NSString *p = [dir stringByAppendingPathComponent:d];
            if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) return YES;
        }
    }
    for (NSString *f in @[@"icon.png", @"iconmask.png", @"icon@3x.png",
                          @"appiconmask@3x.png", @"info.plist"]) {
        if ([lower containsObject:f]) return YES;
    }
    return NO;
}

/// 目录里有「真正的应用图标」吗（IconBundles 里带点的 bundleID .png）
+ (BOOL)dirHasAppIcons:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *ib = nil;
    for (NSString *s in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([s caseInsensitiveCompare:@"IconBundles"] == NSOrderedSame) {
            BOOL d = NO;
            NSString *p = [dir stringByAppendingPathComponent:s];
            if ([fm fileExistsAtPath:p isDirectory:&d] && d) ib = p;
            break;
        }
    }
    if (!ib) return NO;
    for (NSString *f in [fm contentsOfDirectoryAtPath:ib error:NULL]) {
        if (![[f pathExtension].lowercaseString isEqualToString:@"png"]) continue;
        NSString *s = [f stringByDeletingPathExtension];
        if ([s hasSuffix:@"@2x"] || [s hasSuffix:@"@3x"]) s = [s substringToIndex:s.length - 3];
        if ([s rangeOfString:@"."].location != NSNotFound) return YES;
    }
    return NO;
}

/// 目录里的素材种类（mask / overlay / shadow / badge），找不到返回 nil
+ (NSString *)detectAssetKindIn:(NSString *)dir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *fx = nil;
    for (NSString *s in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([s caseInsensitiveCompare:@"AnemoneEffects"] == NSOrderedSame) {
            BOOL d = NO;
            NSString *p = [dir stringByAppendingPathComponent:s];
            if ([fm fileExistsAtPath:p isDirectory:&d] && d) fx = p;
            break;
        }
    }
    if (fx) {
        NSArray *files = [fm contentsOfDirectoryAtPath:fx error:NULL];
        for (NSString *f in files) {
            if ([f.lowercaseString hasPrefix:@"iphoneshadow"]) return @"shadow";
            if ([f.lowercaseString hasPrefix:@"iphoneoverlay"]) return @"overlay";
        }
    }
    for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([f.lowercaseString hasPrefix:@"sbbadgebg"]) return @"badge";
    }
    // 主题包里也有遮罩（IconBundles/Icon.png）→ 兜底算遮罩
    if ([self dirLooksLikeThemeOrAsset:dir]) return @"mask";
    return nil;
}

/// 把解包/复制出来的目录放到正确的位置：主题 → Themes/，素材包 → Assets/（并写 Info.plist）
+ (NSString *)placeImportedDir:(NSString *)srcDir niceName:(NSString *)niceName error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isAsset = ![self dirHasAppIcons:srcDir];
    NSString *name = niceName.length ? niceName : srcDir.lastPathComponent;
    NSString *dst = nil;
    if (isAsset) {
        NSString *root = [self writableAssetRoot];
        if (!root) {
            if (error) *error = [NSError errorWithDomain:@"TB" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"没有可写的素材目录（Assets）"}];
            return nil;
        }
        dst = [self uniqueDirectoryPathForName:name inRoot:root];
    } else {
        NSString *root = [self writableThemeRoot];
        if (!root) {
            if (error) *error = [NSError errorWithDomain:@"TB" code:2
                userInfo:@{NSLocalizedDescriptionKey: @"没有可写的主题目录（Themes）"}];
            return nil;
        }
        dst = [self uniquePathForName:name inRoot:root];
    }
    TBLog2(@"[导入][放置] 判定=%@ 源=%@ → 目标=%@", isAsset ? @"素材包" : @"主题包", srcDir, dst);

    NSError *mvErr = nil;
    BOOL placed = NO;
    // 只有来自临时目录（iCloud 协调副本 / 解包目录）的才直接 move；
    // 用户自己选的目录一律 copy，绝不搬走用户的东西。
    NSString *tmpRoot = [NSTemporaryDirectory() stringByStandardizingPath];
    BOOL inTmp = [srcDir hasPrefix:tmpRoot];
    if (inTmp) placed = [fm moveItemAtPath:srcDir toPath:dst error:&mvErr];
    if (!placed) {
        // 跨卷 / 权限：退回"复制"（原目录在临时区时再删源）
        NSError *cpErr = nil;
        if (![fm copyItemAtPath:srcDir toPath:dst error:&cpErr]) {
            if (error) *error = cpErr ?: mvErr;
            TBLog2(@"[导入][放置] ❌ 移动失败(%@) 复制也失败(%@)",
                   mvErr.localizedDescription ?: @"-", cpErr.localizedDescription ?: @"-");
            return nil;
        }
        if (inTmp) [fm removeItemAtPath:srcDir error:NULL];
    }
    if (isAsset) {
        NSString *kind = [self detectAssetKindIn:dst] ?: @"mask";
        if (![fm fileExistsAtPath:[dst stringByAppendingPathComponent:@"Info.plist"]]) {
            [self writeAssetInfoAt:dst kind:kind name:name];
        }
        TBLog2(@"[导入][放置] ✅ 素材包已放入 Assets：%@（kind=%@）", dst, kind);
    } else {
        TBLog2(@"[导入][放置] ✅ 主题包已放入 Themes：%@", dst);
    }
    return dst;
}

+ (NSString *)describeTree:(NSString *)root limit:(NSInteger)limit {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableString *out = [NSMutableString string];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger n = 0;
    while (stack.count && n < limit) {
        NSString *dir = stack.firstObject;
        [stack removeObjectAtIndex:0];
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if ([item hasPrefix:@"."]) continue;
            NSString *rel = [dir substringFromIndex:MIN(root.length, dir.length)];
            [out appendFormat:@"%@/%@\n", rel, item];
            if (++n >= limit) break;
            BOOL d = NO;
            NSString *sub = [dir stringByAppendingPathComponent:item];
            if ([fm fileExistsAtPath:sub isDirectory:&d] && d) [stack addObject:sub];
        }
    }
    return out;
}

+ (NSString *)importFromAnyURL:(NSURL *)url error:(NSError **)error {
    if (!url) {
        TBLog2(@"[导入][主题] ❌ 没有选择文件（url=nil）");
        if (error) *error = [NSError errorWithDomain:@"TB" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"没有选择文件"}];
        return nil;
    }
    TBLog2(@"[导入][主题] 入口 url=%@（%@）",
           url.absoluteString ?: @"(nil)", TBURLIsICloud(url) ? @"iCloud" : @"本地/其它 provider");
    // iCloud 云盘的文件在没下载时只是占位符（.icloud），直接 contentsOfFile: 拿到空数据。
    // 统一走 TBCopyCoordinatedItemToTemp：
    //   ① startAccessingSecurityScopedResource
    //   ② NSFileCoordinator + NSFileCoordinatorReadingWithoutChanges（0.15.59 起，照 MarkFont 的可工作实现）
    //   ③ 在 accessor 里把文件 / 整个目录递归复制到 NSTemporaryDirectory()
    // 之后再在副本上跑原来的本地导入流程。
    NSError *copyErr = nil;
    NSURL *tmp = TBCopyCoordinatedItemToTemp(url, &copyErr);
    if (!tmp) {
        TBLog2(@"[导入][主题] ❌ 复制到临时目录失败：%@", copyErr.localizedDescription ?: @"(无错误信息)");
        if (error) *error = copyErr ?: [NSError errorWithDomain:@"TB" code:7
            userInfo:@{NSLocalizedDescriptionKey: @"复制到临时目录失败"}];
        return nil;
    }
    TBLog2(@"[导入][主题] 临时副本=%@", tmp.path);

    // 0.15.53：zip 兜底 —— asCopy 副本 / iCloud 下载副本有时会把 .zip 后缀弄丢
    // （或用户网盘里的文件本来就没后缀），只按 pathExtension 判断会漏掉解压分支。
    // 这里按文件魔数 "PK\x03\x04" 识别，是 zip 就把副本补上 .zip 再走原流程。
    {
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:tmp.path isDirectory:&isDir] && !isDir) {
            NSData *head = nil;
            NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:tmp.path];
            if (fh) { head = [fh readDataOfLength:4]; [fh closeFile]; }
            NSString *ext = tmp.pathExtension.lowercaseString;
            BOOL isZipMagic = head.length >= 4 &&
                ((const uint8_t *)head.bytes)[0] == 'P' && ((const uint8_t *)head.bytes)[1] == 'K' &&
                (((const uint8_t *)head.bytes)[2] == 3 || ((const uint8_t *)head.bytes)[2] == 5 ||
                 ((const uint8_t *)head.bytes)[2] == 7);
            NSDictionary *at = [fm attributesOfItemAtPath:tmp.path error:NULL];
            TBLog2(@"[导入][主题] 副本 字节数=%lu 扩展名=%@ zip魔数=%d",
                   (unsigned long)[at fileSize], ext.length ? ext : @"(无)", isZipMagic ? 1 : 0);
            if (isZipMagic && ![ext isEqualToString:@"zip"]) {
                NSString *fixed = [tmp.path stringByAppendingPathExtension:@"zip"];
                if (fixed && [fm moveItemAtPath:tmp.path toPath:fixed error:NULL]) {
                    TBLog2(@"[导入][主题] 副本没有 .zip 后缀但内容是 zip → 改名 %@", fixed.lastPathComponent);
                    tmp = [NSURL fileURLWithPath:fixed];
                }
            }
        }
    }

    __block NSString *result = nil;
    __block NSError *inner = nil;
    @try {
        result = [self importLocalURL:tmp error:&inner];
    } @catch (NSException *ex) {
        inner = [NSError errorWithDomain:@"TB" code:9
                                userInfo:@{NSLocalizedDescriptionKey:
                                               [NSString stringWithFormat:@"导入异常：%@", ex.reason ?: ex.name]}];
    }
    TBRemoveTempCopy(tmp);   // 临时副本用完即删（成功失败都删）

    if (result) {
        TBLog2(@"[导入][主题] ✅ 成功 → %@", result);
        return result;
    }
    TBLog2(@"[导入][主题] ❌ 本地导入失败：%@", (inner ?: copyErr).localizedDescription ?: @"(无错误信息)");
    if (error) *error = inner ?: copyErr;
    return nil;
}

+ (NSString *)importLocalURL:(NSURL *)url error:(NSError **)error {
    NSString *ext = [url pathExtension].lowercaseString;
    TBLog2(@"[导入][本地] url=%@ ext=%@", url.path ?: @"(nil)", ext ?: @"(无)");
    if ([ext isEqualToString:@"zip"]) {
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"unzip-%@", [[NSUUID UUID] UUIDString]]];
        NSError *e = nil;
        TBLog2(@"[导入][zip] 开始解包 %@ → %@", url.path, tmp);
        BOOL unzipped = [TBZip unzipFileAtPath:url.path toDirectory:tmp error:&e];
        if (!unzipped) {
            TBLog2(@"[导入][zip] 内置解压失败（%@），改试系统 unzip", e.localizedDescription ?: @"-");
            [[NSFileManager defaultManager] createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:NULL];
            const char *cands[] = {"/var/jb/usr/bin/unzip", "/usr/bin/unzip"};
            for (int i = 0; i < 2 && !unzipped; i++) {
                if (![[NSFileManager defaultManager] isExecutableFileAtPath:@(cands[i])]) continue;
                const char *argv[] = {cands[i], "-o", "-q", url.path.UTF8String, "-d", tmp.UTF8String, NULL};
                pid_t pid; int st = 0;
                if (posix_spawn(&pid, cands[i], NULL, NULL, (char *const *)argv, environ) == 0) {
                    waitpid(pid, &st, 0);
                    unzipped = (WEXITSTATUS(st) == 0);
                    TBLog2(@"[导入][zip] %s 退出码=%d → %@", cands[i], WEXITSTATUS(st), unzipped ? @"成功" : @"失败");
                } else {
                    TBLog2(@"[导入][zip] 起不了 %s（沙盒/权限）", cands[i]);
                }
            }
        } else {
            TBLog2(@"[导入][zip] ✅ 内置解压成功");
        }
        if (!unzipped) {
            NSString *why = e.localizedDescription ?: @"未知原因";
            if (error) *error = [NSError errorWithDomain:@"TB" code:5 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"解压失败：内置解析与 unzip 都没成功（%@）。\n可以把 zip 先在「文件」App 里解压成文件夹，再用「导入」选那个文件夹。", why]}];
            TBLog2(@"[导入][zip] ❌ 解压最终失败：%@", why);
            return nil;
        }
        NSString *contentDir = [self findContentDirIn:tmp];
        TBLog2(@"[导入][zip] 解包内容：\n%@", [self describeTree:tmp limit:20]);
        if (!contentDir) {
            NSString *tree = [self describeTree:tmp limit:12];
            if (error) *error = [NSError errorWithDomain:@"TB" code:4 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"zip 里既没有主题资源（IconBundles / Bundles），也没有素材资源（AnemoneEffects / IconMask / Icon.png）。\n解压内容：\n%@", tree]}];
            TBLog2(@"[导入][zip] ❌ 没找到主题/素材目录");
            return nil;
        }
        if ([contentDir isEqualToString:tmp]) {
            // 解包出来的内容直接铺在临时根目录上（zip 里没有顶层文件夹）→ 先收进一个子目录
            NSString *holder = [tmp stringByAppendingPathComponent:@"tb-pack"];
            NSError *mk = nil;
            if ([[NSFileManager defaultManager] createDirectoryAtPath:holder withIntermediateDirectories:YES
                                                                    attributes:nil error:&mk]) {
                NSFileManager *fm = [NSFileManager defaultManager];
                NSMutableArray *move = [NSMutableArray array];
                for (NSString *it in [fm contentsOfDirectoryAtPath:tmp error:NULL]) {
                    if ([it hasPrefix:@"."] || [it isEqualToString:@"tb-pack"]) continue;
                    [move addObject:it];
                }
                for (NSString *it in move) {
                    [fm moveItemAtPath:[tmp stringByAppendingPathComponent:it]
                                toPath:[holder stringByAppendingPathComponent:it] error:NULL];
                }
                contentDir = holder;
                TBLog2(@"[导入][zip] zip 内容没有顶层文件夹 → 收进 %@", holder);
            }
        }
        // 用 zip 文件名更直观（解包出来的名字常常是 "xxx-master"）
        NSString *niceName = [[url lastPathComponent] stringByDeletingPathExtension];
        if (!niceName.length) niceName = @"导入";
        return [self placeImportedDir:contentDir niceName:niceName error:error];
    }
    return [self importThemeDirectory:url error:error];
}

+ (NSString *)themeDirInside:(NSString *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"IconBundles"]]) return root;

    NSArray *items = [fm contentsOfDirectoryAtPath:root error:NULL];
    NSString *fallback = nil;
    for (NSString *it in items) {
        if ([it hasPrefix:@"."] || [it isEqualToString:@"__MACOSX"]) continue;
        NSString *p = [root stringByAppendingPathComponent:it];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir] || !isDir) continue;
        if ([fm fileExistsAtPath:[p stringByAppendingPathComponent:@"IconBundles"]]) return p;
        if (!fallback) fallback = p;
    }
    return fallback;
}


+ (NSArray<NSString *> *)zipsInDocuments {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:NULL];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *it in items) {
        if ([[it pathExtension].lowercaseString isEqualToString:@"zip"]) [out addObject:it];
    }
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

+ (NSString *)importZipInDocuments:(NSString *)zipName error:(NSError **)error {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *url = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:zipName]];
    return [self importFromAnyURL:url error:error];
}

#pragma mark - 素材包（Assets/）

/// 通用：在 root 下要一个不重名的目录（不带 .theme 后缀）
+ (NSString *)uniqueDirectoryPathForName:(NSString *)name inRoot:(NSString *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    base = [base stringByDeletingPathExtension];
    base = [base stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    if (!base.length) base = @"素材";
    NSString *candidate = [root stringByAppendingPathComponent:base];
    int i = 2;
    while ([fm fileExistsAtPath:candidate]) {
        candidate = [root stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@ %d", base, i++]];
    }
    return candidate;
}

+ (NSString *)assetKindTitle:(NSString *)kind {
    if ([kind isEqualToString:@"overlay"]) return @"边框";
    if ([kind isEqualToString:@"shadow"])  return @"阴影";
    return @"遮罩";
}

/// 素材包里那份标记类型的 Info.plist（App 靠它 + 文件内容双重识别）
+ (void)writeAssetInfoAt:(NSString *)dir kind:(NSString *)kind name:(NSString *)name {
    NSDictionary *info = @{ @"TBKind": kind ?: @"mask",
                            @"TBName": name ?: [dir lastPathComponent],
                            @"TBAssetType": [self assetKindTitle:kind] };
    [info writeToFile:[dir stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
}

+ (NSString *)importAssetDirectory:(NSURL *)url kind:(NSString *)kind error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self writableAssetRoot];
    NSString *dst = [self uniqueDirectoryPathForName:[url lastPathComponent] inRoot:root];
    NSError *err = nil;
    if (![fm copyItemAtPath:url.path toPath:dst error:&err]) {
        if (error) *error = err ?: [NSError errorWithDomain:@"TB" code:6
            userInfo:@{NSLocalizedDescriptionKey: @"复制素材目录失败"}];
        return nil;
    }
    [self writeAssetInfoAt:dst kind:kind name:[url lastPathComponent]];
    return dst;
}

/// 导入素材：图片 → Assets/<名字>/{IconBundles/Icon.png | AnemoneEffects/iPhoneOverlay@3x.png}
/// kind: mask / overlay / shadow
+ (NSString *)importAssetFromURL:(NSURL *)url kind:(NSString *)kind error:(NSError **)error {
    if (!url) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"没有选择文件"}];
        return nil;
    }
    NSString *k = kind.length ? kind : @"mask";
    NSFileManager *fm = [NSFileManager defaultManager];

    // 文件夹：整体搬进来（先经文件协调器复制到沙盒临时目录，iCloud 上的目录也能下载下来）
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:url.path isDirectory:&isDir] && isDir) {
        NSError *cpErr = nil;
        NSURL *tmp = TBCopyCoordinatedItemToTemp(url, &cpErr);
        if (!tmp) {
            if (error) *error = cpErr;
            return nil;
        }
        NSString *r = [self importAssetDirectory:tmp kind:k error:error];
        TBRemoveTempCopy(tmp);
        return r;
    }

    // 单个图片：必须走 NSFileCoordinator（iCloud 未下载的文件直接读会是占位符）
    NSError *readErr = nil;
    NSData *raw = TBReadCoordinatedData(url, &readErr);
    if (!raw.length) {
        if (error) *error = readErr ?: [NSError errorWithDomain:@"TB" code:7
            userInfo:@{NSLocalizedDescriptionKey: @"读不到图片（换一张 PNG/JPG 再试）"}];
        return nil;
    }
    UIImage *img = [[UIImage alloc] initWithData:raw];
    if (!img) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:7
            userInfo:@{NSLocalizedDescriptionKey:
                           TBImportFailureMessage(url, nil, @"读不到图片（换一张 PNG/JPG 再试）")}];
        return nil;
    }

    NSString *root = [self writableAssetRoot];
    NSString *baseName = [[url lastPathComponent] stringByDeletingPathExtension];
    if (!baseName.length) baseName = @"素材";
    NSString *dst = [self uniqueDirectoryPathForName:baseName inRoot:root];

    NSError *err = nil;
    if (![fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:&err]) {
        if (error) *error = err;
        return nil;
    }

    NSString *rel = nil;
    NSData *png = nil;
    if ([k isEqualToString:@"overlay"]) {
        rel = @"AnemoneEffects/iPhoneOverlay@3x.png";
        png = TBPlainPNGDataFromImage(img);
    } else if ([k isEqualToString:@"shadow"]) {
        rel = @"AnemoneEffects/iPhoneShadow@3x.png";
        png = TBPlainPNGDataFromImage(img);
    } else {
        rel = @"IconBundles/Icon.png";
        png = TBMaskPNGDataFromImage(img);
    }
    NSString *file = [dst stringByAppendingPathComponent:rel];
    [fm createDirectoryAtPath:[file stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:NULL];
    if (!png.length || ![png writeToFile:file options:NSDataWritingAtomic error:&err]) {
        [fm removeItemAtPath:dst error:NULL];
        if (error) *error = err ?: [NSError errorWithDomain:@"TB" code:8
            userInfo:@{NSLocalizedDescriptionKey: @"写不进 Assets 目录"}];
        return nil;
    }
    [self writeAssetInfoAt:dst kind:k name:baseName];
    return dst;
}

/// 把一个 zip 解压到临时目录，递归找出里面的遮罩图，返回【临时图片路径】（调用方用完自行删）。
/// 找图顺序：IconBundles/Icon.png → icon.png → AppIconMask* → IconMask* → 任意 PNG/JPG。
/// 找不到就回填 reason（带压缩包里的文件名列表），方便用户知道到底为什么不行。
+ (nullable NSString *)extractMaskImageFromZip:(NSURL *)zipURL reason:(NSString **)reason {
    if (reason) *reason = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    NSURL *copy = TBCopyCoordinatedItemToTemp(zipURL, &err);
    if (!copy) {
        if (reason) *reason = TBImportFailureMessage(zipURL, err, @"压缩包读不出来");
        return nil;
    }
    NSString *zipPath = copy.path;
    NSString *work = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"tb-maskzip-%@", [NSUUID UUID].UUIDString]];
    NSError *uzErr = nil;
    BOOL ok = [TBZip unzipFileAtPath:zipPath toDirectory:work error:&uzErr];
    TBRemoveTempCopy(copy);
    if (!ok) {
        [fm removeItemAtPath:work error:NULL];
        TBLog2(@"[导入遮罩][zip] ❌ 解压失败 %@ err=%@", zipPath, uzErr.localizedDescription ?: @"-");
        if (reason) *reason = [NSString stringWithFormat:@"解压失败：%@（%@）",
                               uzErr.localizedDescription ?: @"不是有效的 zip",
                               zipURL.lastPathComponent ?: @"这个文件"];
        return nil;
    }
    NSString *found = TBMaskImageInsideDir(work);
    if (!found.length) {
        // 列几个文件名 —— 只说「没找到」用户没法定位
        NSMutableArray *names = [NSMutableArray array];
        NSMutableArray *dirs = [NSMutableArray arrayWithObject:work];
        NSInteger guard = 0;
        while (dirs.count && names.count < 8 && guard++ < 200) {
            NSString *d = dirs.firstObject;
            [dirs removeObjectAtIndex:0];
            NSArray *items = [fm contentsOfDirectoryAtPath:d error:NULL];
            for (NSUInteger i = 0; i < items.count; i++) {
                NSString *item = items[i];
                if ([item hasPrefix:@"__MACOSX"] || [item hasPrefix:@"."]) continue;
                NSString *full = [d stringByAppendingPathComponent:item];
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
                if (isDir) { [dirs addObject:full]; continue; }
                [names addObject:item];
            }
        }
        [fm removeItemAtPath:work error:NULL];
        TBLog2(@"[导入遮罩][zip] ❌ 包里没有图片：%@", [names componentsJoinedByString:@", "]);
        if (reason) *reason = [NSString stringWithFormat:
            @"压缩包里没有找到图片（找过 IconBundles/Icon.png、icon.png、AppIconMask*、IconMask*，"
            @"以及任意 PNG/JPG）。\n里面是：\n%@",
            names.count ? [names componentsJoinedByString:@"\n"] : @"(空压缩包)"];
        return nil;
    }
    NSString *ext = found.pathExtension.length ? found.pathExtension.lowercaseString : @"png";
    NSString *dest = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"tbmaskv-%@.%@", [NSUUID UUID].UUIDString, ext]];
    NSError *cpErr = nil;
    BOOL cp = [fm copyItemAtPath:found toPath:dest error:&cpErr];
    [fm removeItemAtPath:work error:NULL];
    if (!cp) {
        if (reason) *reason = [NSString stringWithFormat:@"压缩包里的图片拿不出来：%@",
                               cpErr.localizedDescription ?: @"未知原因"];
        return nil;
    }
    TBLog2(@"[导入遮罩][zip] ✅ %@ → %@", zipURL.lastPathComponent ?: @"?", dest);
    return dest;
}

/// 删掉 extractMaskImageFromZip 返回的临时图片（tbmaskv-*)。
/// 用完即删：之前正常写入/中途 return 的路径都不删，/tmp 会一直堆文件。
/// 只认 /tmp 下的 tbmaskv-* 前缀，其它路径一律不动（防误删）。
+ (void)removeTempMaskImage:(NSString *)path {
    if (!path.length) return;
    NSString *tmp = [NSTemporaryDirectory() stringByStandardizingPath];
    NSString *full = [path stringByStandardizingPath];
    if (!full.length || ![full hasPrefix:tmp]) return;
    if (![[full lastPathComponent] hasPrefix:@"tbmaskv-"]) return;
    NSError *err = nil;
    if ([[NSFileManager defaultManager] removeItemAtPath:full error:&err]) {
        TBLog2(@"[导入遮罩][zip] 临时图已删：%@", [full lastPathComponent]);
    } else {
        TBLog2(@"[导入遮罩][zip] 临时图删除失败（%@）：%@", err.localizedDescription ?: @"-", full);
    }
}


/// 0.15.69：把 root 拥有的旧主题交给 mobile —— Filza 拷进来的文件整棵树属主是 root，
/// App(mobile) 连 chmod 都做不了（errno=1/513）。这里用 posix_spawn 调系统 chown。
static int TBChownMobile(NSString *path) {
    if (path.length == 0) return -1;
    // 真机上 chown 常见位置：/usr/bin/chown（rootless jbroot）、/bin/chown、/usr/sbin/chown。
    // iSH 里是 /bin/chown → coreutils。逐个探测，用第一个可执行的那个。
    NSString *bin = nil;
    for (NSString *c in @[@"/usr/bin/chown", @"/bin/chown", @"/usr/sbin/chown",
                          @"/var/jb/usr/bin/chown", @"/var/jb/bin/chown"]) {
        if (access(c.fileSystemRepresentation, X_OK) == 0) { bin = c; break; }
    }
    if (!bin) {
        // rootless：jbroot 每台设备随机（/var/containers/Bundle/Application/.jbroot-XXXX/…）
        // 通过 environ 里的 JBRootPath/_MSSafeMode 等变量不可靠，直接 glob。
        NSError *gerr = nil;
        NSArray *cands = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:&gerr];
        for (NSString *d in cands) {
            if (![d hasPrefix:@".jbroot-"]) continue;
            NSString *c = [@"/var/containers/Bundle/Application"
                stringByAppendingPathComponent:[d stringByAppendingPathComponent:@"usr/bin/chown"]];
            if (access(c.fileSystemRepresentation, X_OK) == 0) { bin = c; break; }
            c = [@"/var/containers/Bundle/Application"
                stringByAppendingPathComponent:[d stringByAppendingPathComponent:@"bin/chown"]];
            if (access(c.fileSystemRepresentation, X_OK) == 0) { bin = c; break; }
        }
    }
    if (!bin) return -2;   // 没有 chown 可用
    gChownBin = bin;
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    pid_t pid = -1;
    char *argv[] = { (char*)bin.fileSystemRepresentation, (char*)"-R",
                     (char*)"mobile:mobile", (char*)path.fileSystemRepresentation, NULL };
    int rc = posix_spawn(&pid, argv[0], NULL, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) return rc;
    int st = 0; waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : -3;
}

/// 递归 chown：先改目录本身，再遍历内容（目录大也够快，主题包几百个文件毫秒级）
static NSString *gChownBin;
static void TBRecursiveChownMobile(NSString *path) {
    int rc = TBChownMobile(path);
    TBLog2(@"[删除] chown bin=%@ -R mobile:mobile rc=%d %@", gChownBin ?: @"(未找到)", rc, path);
    if (rc != 0) {
        // chown 不可用/失败时退回逐文件（老路径）
        NSFileManager *fm = [NSFileManager defaultManager];
        TBChownMobile(path);
        NSArray *kids = [[fm subpathsAtPath:path] copy];
        for (NSString *k in kids) TBChownMobile([path stringByAppendingPathComponent:k]);
    }
}

+ (BOOL)deleteTheme:(TBTheme *)theme error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = theme.path;
    TBLog2(@"[删除] 请求删除「%@」path=%@ 素材包=%d", theme.name ?: @"?",
           path ?: @"(nil)", theme ? (int)theme.isAssetPack : 0);
    if (!path.length) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:10 userInfo:@{
            NSLocalizedDescriptionKey: @"这个条目没有可删除的目录（path 为空）"}];
        TBLog2(@"[删除] ❌ path 为空，无法删除");
        return NO;
    }
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:11 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"目录已经不存在：%@", path]}];
        TBLog2(@"[删除] ❌ 目录不存在：%@", path);
        return NO;
    }
    // 安全护栏：绝不删「主题根 / 素材根」本身
    for (NSString *root in @[ TBThemesRoot(), TBAssetsRoot() ]) {
        if ([path isEqualToString:root] || [root hasPrefix:[path stringByAppendingString:@"/"]]) {
            if (error) *error = [NSError errorWithDomain:@"TB" code:12 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"拒绝删除根目录：%@", path]}];
            TBLog2(@"[删除] ❌ 拒绝删除根目录：%@", path);
            return NO;
        }
    }
    BOOL underKnownRoot = NO;
    for (NSString *root in @[ TBThemesRoot(), TBAssetsRoot() ]) {
        if ([path hasPrefix:[root stringByAppendingString:@"/"]]) { underKnownRoot = YES; break; }
    }
    if (!underKnownRoot) TBLog2(@"[删除] ⚠️ 不在已知根目录下，仍然按 path 删除：%@", path);

    // ---- 删除：按序重试 ----
    // 用户实测素材包会弹「未能移除"虚化蒙版.theme"，因为你没有访问许可」：
    // 素材包/主题包里的文件常是 root 或只读权限，直接 removeItemAtPath 会 EACCES。
    // 这里按序来：① 直接删 → ② 递归 chmod 0777 再删 → ③ 先删内容、再删空目录。
    int lastErrno = 0;
    NSError *err = nil;
    BOOL ok = [fm removeItemAtPath:path error:&err];
    if (!ok) lastErrno = (int)err.code;
    BOOL still = [fm fileExistsAtPath:path];

    if ((!ok || still)) {
        TBLog2(@"[删除] 第 1 次失败（errno=%d，%@）→ 递归 chmod 0777 后重试：%@",
               lastErrno, err.localizedDescription ?: @"无错误", path);
        TBRecursiveChmod(path, 0777);
        err = nil;
        ok = [fm removeItemAtPath:path error:&err];
        if (!ok) lastErrno = (int)err.code;
        still = [fm fileExistsAtPath:path];
    }
    if ((!ok || still)) {
        TBLog2(@"[删除] 第 2 次失败（errno=%d，%@）→ 递归 chown mobile 后重试：%@",
               lastErrno, err.localizedDescription ?: @"无错误", path);
        TBRecursiveChownMobile(path);          // root 拥有的旧主题 → 交给 mobile
        TBRecursiveChmod(path, 0777);
        err = nil;
        ok = [fm removeItemAtPath:path error:&err];
        if (!ok) lastErrno = (int)err.code;
        still = [fm fileExistsAtPath:path];
    }
    if ((!ok || still)) {
        TBLog2(@"[删除] 第 3 次失败（errno=%d，%@）→ 改为先删内容、再删目录：%@",
               lastErrno, err.localizedDescription ?: @"无错误", path);
        NSError *e3 = nil;
        int e3no = 0;
        ok = TBRemoveContentsThenDir(path, &e3, &e3no);
        if (!ok) { err = e3; if (e3no) lastErrno = e3no; }
    }
    // 二次确认：有些路径 removeItemAtPath 返回 YES 但目录还在（文件系统写入延迟）
    if (ok && [fm fileExistsAtPath:path]) {
        ok = NO;
        if (!err) err = [NSError errorWithDomain:@"TB" code:13 userInfo:@{
            NSLocalizedDescriptionKey: @"删除后目录仍然存在（可能没有权限）"}];
    }
    TBLog2(@"[删除] %@ path=%@ errno=%d（%@）", ok ? @"✅ 成功" : @"❌ 失败", path, lastErrno,
           err.localizedDescription ?: @"无错误");
    if (!ok && error) {
        NSString *why = err.localizedDescription.length ? err.localizedDescription
                                                        : @"未知原因（权限或只读文件系统）";
        *error = [NSError errorWithDomain:@"TB" code:(err.code ?: 14) userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@（errno=%d）", why, lastErrno],
            NSFilePathErrorKey: path ?: @"",
            @"errno": @(lastErrno),
            NSLocalizedFailureReasonErrorKey: @"已依次尝试：直接删除 → 递归 chmod 0777 → 先删内容再删目录"}];
    }
    return ok;
}

@end
