#import "TBThemeScanner.h"

// 兼容 SnowBoard / Anemone 的放置位置；roothide 用 /var/jb 前缀
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
    for (NSString *p in TBRootCandidates()) {
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir) {
            if (![out containsObject:p]) [out addObject:p];
        }
    }
    return out;
}

+ (NSString *)writableThemeRoot {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in [self themeRoots]) {
        if ([fm isWritableFileAtPath:p]) return p;
    }
    // 一个都没有可写的：建 /var/jb/Library/Themes
    NSString *p = @"/var/jb/Library/Themes";
    [fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:NULL];
    if ([fm isWritableFileAtPath:p]) return p;
    return nil;
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

+ (BOOL)deleteTheme:(TBTheme *)theme error:(NSError **)error {
    if (!theme.path) return NO;
    return [[NSFileManager defaultManager] removeItemAtPath:theme.path error:error];
}

@end
