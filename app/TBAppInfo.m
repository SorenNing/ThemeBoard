#import "TBAppInfo.h"
#import <objc/message.h>

static NSArray<NSDictionary *> *gApps;
static NSMutableDictionary<NSString *, UIImage *> *gIconCache;

@implementation TBAppInfo

+ (NSArray<NSString *> *)searchRoots {
    return @[
        @"/var/jb/Applications",
        @"/Applications",
        @"/var/jb/var/containers/Bundle/Application",
        @"/var/containers/Bundle/Application",
    ];
}

+ (void)collectInto:(NSMutableDictionary *)map {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *root in [self searchRoots]) {
        NSArray *items = [fm contentsOfDirectoryAtPath:root error:NULL];
        for (NSString *item in items) {
            if ([item hasPrefix:@"."]) continue;
            NSString *p = [root stringByAppendingPathComponent:item];

            // /var/containers/Bundle/Application/<UUID>/<App>.app
            if ([item length] > 30 && [item rangeOfString:@"-"].location != NSNotFound) {
                NSArray *inner = [fm contentsOfDirectoryAtPath:p error:NULL];
                for (NSString *s in inner) {
                    if (![s hasSuffix:@".app"]) continue;
                    [self addAppAtPath:[p stringByAppendingPathComponent:s] into:map];
                }
                continue;
            }
            if (![item hasSuffix:@".app"]) continue;
            [self addAppAtPath:p into:map];
        }
    }
}

+ (void)addAppAtPath:(NSString *)path into:(NSMutableDictionary *)map {
    NSString *plistPath = [path stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!info) return;
    NSString *bid = info[@"CFBundleIdentifier"];
    if (bid.length == 0 || map[bid]) return;

    NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: [bid lastPathComponent];
    map[bid] = @{@"bid": bid, @"name": name, @"path": path};
}

+ (NSArray<NSDictionary *> *)installedApps {
    if (gApps) return gApps;

    // 系统应用优先用 LSApplicationWorkspace（越狱环境可用）
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
    if ([wsClass respondsToSelector:NSSelectorFromString(@"defaultWorkspace")]) {
        id ws = ((id (*)(id, SEL))objc_msgSend)(wsClass, NSSelectorFromString(@"defaultWorkspace"));
        SEL sel = NSSelectorFromString(@"allInstalledApplications");
        if (ws && [ws respondsToSelector:sel]) {
            NSArray *apps = ((id (*)(id, SEL))objc_msgSend)(ws, sel);
            for (id app in apps) {
                @try {
                    NSString *bid = [app respondsToSelector:NSSelectorFromString(@"applicationIdentifier")]
                        ? [app valueForKey:@"applicationIdentifier"] : nil;
                    NSString *name = [app respondsToSelector:NSSelectorFromString(@"localizedName")]
                        ? [app valueForKey:@"localizedName"] : nil;
                    NSURL *bundleURL = [app respondsToSelector:NSSelectorFromString(@"bundleURL")]
                        ? [app valueForKey:@"bundleURL"] : nil;
                    if (bid.length == 0 || map[bid]) continue;
                    map[bid] = @{@"bid": bid,
                                 @"name": name.length ? name : bid,
                                 @"path": bundleURL.path ?: @""};
                } @catch (NSException *e) {}
            }
        }
    }

    [self collectInto:map];
    gApps = [[map allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];
    return gApps;
}

+ (NSString *)displayNameForBundleID:(NSString *)bid {
    for (NSDictionary *d in [self installedApps]) {
        if ([d[@"bid"] isEqualToString:bid]) return d[@"name"];
    }
    return nil;
}

+ (NSString *)bundlePathForBundleID:(NSString *)bid {
    for (NSDictionary *d in [self installedApps]) {
        if ([d[@"bid"] isEqualToString:bid]) return [d[@"path"] length] ? d[@"path"] : nil;
    }
    return nil;
}

+ (UIImage *)iconForBundleID:(NSString *)bid {
    if (!bid) return nil;
    if (!gIconCache) gIconCache = [NSMutableDictionary dictionary];
    UIImage *cached = gIconCache[bid];
    if (cached) return cached;

    // 优先系统图标服务（越狱进程内可直接用）
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImage respondsToSelector:sel]) {
        typedef UIImage *(*Fn)(id, SEL, NSString *, int, double);
        UIImage *img = ((Fn)objc_msgSend)([UIImage class], sel, bid, 0, 3.0);
        if (img) { gIconCache[bid] = img; return img; }
    }

    // 回退：从 app bundle 读图标
    NSString *path = [self bundlePathForBundleID:bid];
    if (path) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                              [path stringByAppendingPathComponent:@"Info.plist"]];
        id icons = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"];
        NSString *base = [icons isKindOfClass:[NSArray class]] ? [icons lastObject] : nil;
        if (base) {
            for (NSString *scale in @[@"@3x", @"@2x", @""]) {
                NSString *p = [path stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"%@%@.png", base, scale]];
                UIImage *img = [UIImage imageWithContentsOfFile:p];
                if (img) { gIconCache[bid] = img; return img; }
            }
        }
    }
    return nil;
}

@end
