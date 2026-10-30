// ThemeBoardEngine — 注入 SpringBoard / iconservicesagent 的主题引擎
// 先做"可观测"：每条取图链都记日志，命中主题图才替换。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>

static NSString *const kDomain = @"com.ning.themeboard";
static NSString *const kNotify = @"com.ning.themeboard.changed";
static NSString *const kActiveTheme = @"ActiveTheme";
static NSString *const kEnabled = @"Enabled";

static NSString *gLogPath;
static NSMutableDictionary<NSString *, NSString *> *gIndex;   // bid -> png 路径
static NSString *gIndexTheme;
static NSLock *gLock;
static BOOL gLoggedIndex;
static NSUInteger gServeCount, gMissCount;

#pragma mark - 日志

static void TBLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    if (!gLogPath) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *dirs = @[@"/var/jb/var/mobile/Library/ThemeBoard", @"/var/mobile/Library/ThemeBoard"];
        for (NSString *d in dirs) {
            [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:NULL];
            if ([fm isWritableFileAtPath:d]) {
                gLogPath = [d stringByAppendingPathComponent:@"engine.log"];
                break;
            }
        }
    }
    NSLog(@"[ThemeBoard] %@", msg);
    if (!gLogPath) return;

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (!fh) {
        [line writeToFile:gLogPath atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    } else {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    }
}

#pragma mark - 设置

static id TBPref(NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kDomain);
    return (__bridge_transfer id)v;
}

static BOOL TBEnabled(void) {
    id v = TBPref(kEnabled);
    return v ? [v boolValue] : YES;
}

static NSString *TBActiveTheme(void) {
    id v = TBPref(kActiveTheme);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

#pragma mark - 主题索引

static NSArray<NSString *> *TBRoots(void) {
    return @[@"/var/jb/Library/Themes", @"/var/mobile/Library/Themes",
             @"/Library/Themes", @"/var/jb/var/mobile/Library/Themes"];
}

static NSString *TBThemeDir(NSString *name) {
    if (name.length == 0) return nil;
    for (NSString *r in TBRoots()) {
        NSString *p = [r stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir) return p;
    }
    return nil;
}

static NSString *TBStripName(NSString *file) {
    NSString *s = [file stringByDeletingPathExtension];
    if ([s hasSuffix:@"@2x"] || [s hasSuffix:@"@3x"]) s = [s substringToIndex:s.length - 3];
    for (NSString *suf in @[@"-large", @"-small", @"-76", @"-60", @"-40"]) {
        if ([s hasSuffix:suf]) s = [s substringToIndex:s.length - suf.length];
    }
    NSRange t = [s rangeOfString:@"~"];
    if (t.location != NSNotFound) s = [s substringToIndex:t.location];
    return s;
}

static void TBLoadIndex(void) {
    NSString *theme = TBActiveTheme();
    if (!theme) { gIndex = nil; gIndexTheme = nil; return; }
    if (gIndex && [gIndexTheme isEqualToString:theme]) return;

    NSString *dir = [TBThemeDir(theme) stringByAppendingPathComponent:@"IconBundles"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSMutableDictionary *rank = [NSMutableDictionary dictionary];

    for (NSString *f in files) {
        if (![[f pathExtension].lowercaseString isEqualToString:@"png"]) continue;
        NSString *bid = TBStripName(f);
        if (bid.length == 0) continue;
        NSInteger r = [f hasSuffix:@"@3x.png"] ? 3 : ([f hasSuffix:@"@2x.png"] ? 2 : 1);
        if ([rank[bid] integerValue] >= r) continue;
        map[bid] = [dir stringByAppendingPathComponent:f];
        rank[bid] = @(r);
    }
    gIndex = map;
    gIndexTheme = theme;
    if (!gLoggedIndex) {
        gLoggedIndex = YES;
        TBLog(@"index %@ -> %lu 个图标 (%@)", theme, (unsigned long)map.count, dir);
    }
}

static UIImage *TBImageForBundle(NSString *bid) {
    if (!bid.length || !TBEnabled()) return nil;
    [gLock lock];
    TBLoadIndex();
    NSString *p = gIndex[bid];
    UIImage *img = p ? [UIImage imageWithContentsOfFile:p] : nil;
    [gLock unlock];
    return img;
}

#pragma mark - hook 工具

static IMP TBHookInstance(Class cls, NSString *selName, IMP replacement, const char *tag) {
    if (!cls) { TBLog(@"hook %s: class 缺失", tag); return NULL; }
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { TBLog(@"hook %@ %@: 方法不存在", NSStringFromClass(cls), selName); return NULL; }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, replacement);
    TBLog(@"hook %@ %@ ok", NSStringFromClass(cls), selName);
    return orig;
}

static IMP TBHookClass(Class cls, NSString *selName, IMP replacement, const char *tag) {
    if (!cls) { TBLog(@"hook %s: class 缺失", tag); return NULL; }
    SEL sel = NSSelectorFromString(selName);
    Method m = class_getClassMethod(cls, sel);
    if (!m) { TBLog(@"hook %@ +%@: 方法不存在", NSStringFromClass(cls), selName); return NULL; }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, replacement);
    TBLog(@"hook +%@ %@ ok", NSStringFromClass(cls), selName);
    return orig;
}

static NSString *TBBIDFromIcon(id icon) {
    if (!icon) return nil;
    @try {
        if ([icon respondsToSelector:NSSelectorFromString(@"leafIdentifier")]) {
            id v = [icon valueForKey:@"leafIdentifier"];
            if ([v isKindOfClass:[NSString class]]) return v;
        }
        if ([icon respondsToSelector:NSSelectorFromString(@"applicationBundleID")]) {
            id v = [icon valueForKey:@"applicationBundleID"];
            if ([v isKindOfClass:[NSString class]]) return v;
        }
        if ([icon respondsToSelector:NSSelectorFromString(@"bundleIdentifier")]) {
            id v = [icon valueForKey:@"bundleIdentifier"];
            if ([v isKindOfClass:[NSString class]]) return v;
        }
    } @catch (NSException *e) {}
    return nil;
}

#pragma mark - 具体 hook

typedef id (*IconFn)(id, SEL, id);
typedef id (*IconOptFn)(id, SEL, id, unsigned long);
typedef UIImage *(*UIImageIconFn)(id, SEL, NSString *, int, double);

static IconFn oImageForIcon, oCachedForIcon;
static IconOptFn oRealForIconOptions;
static UIImageIconFn oUIImageIcon;

static id tb_imageForIcon(id self, SEL _cmd, id icon) {
    NSString *bid = TBBIDFromIcon(icon);
    UIImage *img = TBImageForBundle(bid);
    if (img) {
        gServeCount++;
        TBLog(@"serve cache %@", bid);
        return img;
    }
    gMissCount++;
    if (bid) TBLog(@"miss %@", bid);
    return oImageForIcon ? oImageForIcon(self, _cmd, icon) : nil;
}

static id tb_cachedForIcon(id self, SEL _cmd, id icon) {
    NSString *bid = TBBIDFromIcon(icon);
    UIImage *img = TBImageForBundle(bid);
    if (img) {
        gServeCount++;
        TBLog(@"serve cached %@", bid);
        return img;
    }
    return oCachedForIcon ? oCachedForIcon(self, _cmd, icon) : nil;
}

static id tb_realForIconOptions(id self, SEL _cmd, id icon, unsigned long opts) {
    NSString *bid = TBBIDFromIcon(icon);
    UIImage *img = TBImageForBundle(bid);
    if (img) {
        gServeCount++;
        TBLog(@"serve real %@", bid);
        return img;
    }
    return oRealForIconOptions ? oRealForIconOptions(self, _cmd, icon, opts) : nil;
}

static UIImage *tb_uiimageIcon(id self, SEL _cmd, NSString *bid, int format, double scale) {
    UIImage *img = TBImageForBundle(bid);
    if (img) {
        gServeCount++;
        TBLog(@"serve UIImage %@", bid);
        return img;
    }
    return oUIImageIcon ? oUIImageIcon(self, _cmd, bid, format, scale) : nil;
}

#pragma mark - 安装

static void TBInstallHooks(void) {
    Class cache = NSClassFromString(@"SBHIconImageCache");
    Class appIcon = NSClassFromString(@"SBApplicationIcon");
    Class leaf = NSClassFromString(@"SBLeafIcon");
    Class uiimg = [UIImage class];

    TBLog(@"环境: cache=%@ appIcon=%@ leaf=%@", cache ? @"有" : @"无", appIcon ? @"有" : @"无", leaf ? @"有" : @"无");

    if (cache) {
        oImageForIcon = (IconFn)TBHookInstance(cache, @"imageForIcon:", (IMP)tb_imageForIcon, "cache.imageForIcon");
        oCachedForIcon = (IconFn)TBHookInstance(cache, @"cachedImageForIcon:", (IMP)tb_cachedForIcon, "cache.cachedImageForIcon");
        oRealForIconOptions = (IconOptFn)TBHookInstance(cache, @"realImageForIcon:options:", (IMP)tb_realForIconOptions, "cache.realImageForIcon");
    }
    if (appIcon) {
        TBHookInstance(appIcon, @"generateIconImage:", (IMP)tb_imageForIcon, "appIcon.generateIconImage");
    }
    oUIImageIcon = (UIImageIconFn)TBHookClass(uiimg, @"_applicationIconImageForBundleIdentifier:format:scale:",
                                              (IMP)tb_uiimageIcon, "UIImage.icon");
}

#pragma mark - 生命周期

static void TBReload(CFNotificationCenterRef center, void *observer, CFNotificationName name,
                     const void *object, CFDictionaryRef info) {
    [gLock lock];
    gIndex = nil;
    gLoggedIndex = NO;
    [gLock unlock];
    TBLog(@"设置变更，索引重建");
}

__attribute__((constructor))
static void TBMain(void) {
    gLock = [[NSLock alloc] init];
    TBLog(@"=== ThemeBoardEngine 加载 pid=%d ===", getpid());
    TBLog(@"当前主题: %@ / 开关: %@", TBActiveTheme() ?: @"(无)", TBEnabled() ? @"开" : @"关");

    TBInstallHooks();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    TBReload, (__bridge CFStringRef)kNotify, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    // 心跳：每分钟刷一次日志 mtime，App 端据此判断引擎在跑
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        while (1) {
            sleep(60);
            if (gLogPath) {
                [[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: [NSDate date]}
                                                ofItemAtPath:gLogPath error:NULL];
            }
        }
    });
}
