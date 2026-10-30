#import "TBThemeScanner.h"
#import "TBZip.h"
#import <spawn.h>
extern char **environ;
#import "TBZip.h"
#import <spawn.h>
extern char **environ;

// 兼容 SnowBoard / Anemone 的放置位置；roothide 用 /var/jb 前缀
// App 自己的容器目录 —— RootHide 下 /var/jb 对 App 不可见，只有这里一定可读写
static NSString *TBContainerThemes(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"Themes"];
}

static NSArray<NSString *> *TBRootCandidates(void) {
    return @[
        @"/var/jb/Library/Themes",
        @"/var/mobile/Library/Themes",
        @"/Library/Themes",
        @"/var/jb/var/mobile/Library/Themes",
    ];
}

@implementation TBThemeScanner

+ (NSArray<NSString *> *)themeRoots {
    NSMutableArray *out = [NSMutableArray array];

    // 容器目录永远排第一，且始终创建
    NSString *container = TBContainerThemes();
    [[NSFileManager defaultManager] createDirectoryAtPath:container
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    [out addObject:container];

    for (NSString *p in TBRootCandidates()) {
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir) {
            if (![out containsObject:p]) [out addObject:p];
        }
    }
    return out;
}

+ (NSString *)writableThemeRoot {
    NSString *container = TBContainerThemes();
    [[NSFileManager defaultManager] createDirectoryAtPath:container
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    return container;
}

+ (NSArray<NSDictionary *> *)rootDiagnostics {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableArray *all = [NSMutableArray arrayWithObject:TBContainerThemes()];
    [all addObjectsFromArray:TBRootCandidates()];
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
    return TBContainerThemes();
}

+ (void)seedDemoThemesIfNeeded {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = TBContainerThemes();
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

            // 主题必须含 IconBundles（Anemone/SnowBoard 图标主题）
            NSString *ib = [full stringByAppendingPathComponent:@"IconBundles"];
            BOOL ibDir = NO;
            if (![fm fileExistsAtPath:ib isDirectory:&ibDir] || !ibDir) continue;

            TBTheme *t = [[TBTheme alloc] initWithPath:full];
            if ([seen containsObject:t.name]) continue;
            [seen addObject:t.name];
            [themes addObject:t];
        }
    }
    [themes sortUsingComparator:^NSComparisonResult(TBTheme *a, TBTheme *b) {
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

+ (NSString *)importThemeDirectory:(NSURL *)srcURL error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [self writableThemeRoot];
    if (!root) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"没有可写的主题目录"}];
        return nil;
    }

    // 校验：必须含 IconBundles 或 Bundles
    NSString *srcPath = srcURL.path;
    BOOL hasIB = [fm fileExistsAtPath:[srcPath stringByAppendingPathComponent:@"IconBundles"]];
    BOOL hasBundles = [fm fileExistsAtPath:[srcPath stringByAppendingPathComponent:@"Bundles"]];
    if (!hasIB && !hasBundles) {
        if (error) *error = [NSError errorWithDomain:@"TB" code:3
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           @"这个文件夹里没有 IconBundles 或 Bundles"}];
        return nil;
    }

    NSString *dst = [self uniquePathForName:[srcURL lastPathComponent] inRoot:root];
    NSError *err = nil;
    if (![fm copyItemAtPath:srcPath toPath:dst error:&err]) {
        if (error) *error = err;
        return nil;
    }
    return dst;
}

// 在解包目录里找第一个含 IconBundles / Bundles 的文件夹（广度优先，取最浅的）
+ (NSString *)findThemeDirIn:(NSString *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count) {
        NSString *dir = queue.firstObject;
        [queue removeObjectAtIndex:0];
        BOOL hasIB = [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"IconBundles"]];
        BOOL hasB = [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Bundles"]];
        if (hasIB || hasB) return dir;
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            if ([item hasPrefix:@"."] || [item isEqualToString:@"__MACOSX"]) continue;
            BOOL isDir = NO;
            NSString *sub = [dir stringByAppendingPathComponent:item];
            if ([fm fileExistsAtPath:sub isDirectory:&isDir] && isDir) [queue addObject:sub];
        }
    }
    return nil;
}

+ (NSString *)importFromAnyURL:(NSURL *)url error:(NSError **)error {
    NSString *ext = [url pathExtension].lowercaseString;
    if ([ext isEqualToString:@"zip"]) {
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"unzip-%@", [[NSUUID UUID] UUIDString]]];
        NSError *e = nil;
        BOOL unzipped = [TBZip unzipFileAtPath:url.path toDirectory:tmp error:&e];
        if (!unzipped) {
            [[NSFileManager defaultManager] createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:NULL];
            const char *cands[] = {"/var/jb/usr/bin/unzip", "/usr/bin/unzip"};
            for (int i = 0; i < 2 && !unzipped; i++) {
                if (![[NSFileManager defaultManager] isExecutableFileAtPath:@(cands[i])]) continue;
                const char *argv[] = {cands[i], "-o", "-q", url.path.UTF8String, "-d", tmp.UTF8String, NULL};
                pid_t pid; int st = 0;
                if (posix_spawn(&pid, cands[i], NULL, NULL, (char *const *)argv, environ) == 0) {
                    waitpid(pid, &st, 0);
                    unzipped = (WEXITSTATUS(st) == 0);
                }
            }
        }
        if (!unzipped) {
            if (error) *error = e ?: [NSError errorWithDomain:@"TB" code:5
                userInfo:@{NSLocalizedDescriptionKey: @"解压失败：内置解析与 unzip 都没成功"}];
            return nil;
        }
        NSString *themeDir = [self findThemeDirIn:tmp];
        if (!themeDir) {
            if (error) *error = [NSError errorWithDomain:@"TB" code:4
                                                userInfo:@{NSLocalizedDescriptionKey:
                                                               @"zip 里没找到 IconBundles 目录"}];
            return nil;
        }
        // 解包出来的名字常常是 "xxx-master"，用 zip 文件名更直观
        NSString *niceName = [[url lastPathComponent] stringByDeletingPathExtension];
        NSString *root = [self writableThemeRoot];
        NSString *dst = [self uniquePathForName:niceName inRoot:root];
        NSError *e2 = nil;
        if (![[NSFileManager defaultManager] moveItemAtPath:themeDir toPath:dst error:&e2]) {
            if (error) *error = e2;
            return nil;
        }
        return dst;
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


+ (BOOL)deleteTheme:(TBTheme *)theme error:(NSError **)error {
    if (!theme.path) return NO;
    return [[NSFileManager defaultManager] removeItemAtPath:theme.path error:error];
}

@end
