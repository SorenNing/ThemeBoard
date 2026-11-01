// ThemeBoardEngine v0.2 — 按 iOS 17.2 真实私有头文件重写
// 依据：headers/17.2/{SBHIconImageCache,SBIcon,SBLeafIcon,SBApplicationIcon,SBHIconManager}.h
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <ImageIO/ImageIO.h>

static NSString *const kDomain = @"com.ning.themeboard";
static NSString *const kNotify = @"com.ning.themeboard.changed";
static NSString *const kRespring = @"com.ning.themeboard.respring";
static NSString *const kActiveTheme = @"ActiveTheme";
static NSString *const kEnabled = @"Enabled";

#pragma mark - 结构（照头文件抄，ABI 必须一致）

typedef struct {
    CGSize size;      // 16B
    double scale;     // 8B
    double ratio;     // 8B
} TBImageInfo;        // 32B，HFA(4×double)，走 d0-d3

#pragma mark - 状态

static NSString *gLogPath;
static BOOL gIsPrimary = NO;      // 只有 SpringBoard 类进程写日志文件，避免多进程互相咬行
static dispatch_queue_t gLogQueue;
static NSMutableDictionary<NSString *, NSString *> *gIndex;
static NSString *gIndexTheme;
static NSMutableSet<NSValue *> *gCaches;
static NSCache *gImageCache;      // 已生成的图标缓存
static NSMutableDictionary<NSString *, NSString *> *gBundleRes;   // 文件名 -> Bundles 里的路径
static NSLock *gLock;
static int gProbeCount = 0;      // 探针日志计数（每进程上限）
static NSUInteger gServe, gMiss;

#pragma mark - 日志

/// 运行时获取 iOS 版本主版本号（例如 17、26）
static int TBGetIOSVersion(void) {
    static int version = 17;  // 默认值为 17
    @try {
        NSProcessInfo *info = [NSProcessInfo processInfo];
        NSString *vstr = [info operatingSystemVersionString];
        NSArray *parts = [vstr componentsSeparatedByString:@"."];
        if (parts.count > 0) {
            NSString *firstPart = [parts objectAtIndex:0];
            version = [firstPart intValue];
            if (version <= 0) version = 17;  // 解析失败时回退
        }
    } @catch (...) { }
    return version;
}

/// 检测某个类是否有指定方法（运行时自适应）
static BOOL TBHasMethod(Class cls, NSString *selName) {
    if (!cls) return NO;
    SEL sel = NSSelectorFromString(selName);
    return [cls instancesRespondToSelector:sel] || [cls respondsToSelector:sel];
}

static BOOL TBUIKitIconEnabled(void);
static NSString *TBBIDFromISIcon(id icon);
static NSString *TBProcName(void) {
    static NSString *name = nil;
    if (!name) name = [[NSProcessInfo processInfo] processName] ?: @"?";
    return name;
}

/// 用 C 文件 API 探测可写路径（NSFileManager 的 isWritable 在 SpringBoard 里会误报 NO）
static const char *TBLogFilePath(void) {
    static char path[256] = {0};
    if (path[0]) return path;
    const char *cands[] = {
        "/var/mobile/Library/ThemeBoard/engine.log",
        "/var/jb/var/mobile/Library/ThemeBoard/engine.log",
        // 守护进程（如 iconservicesagent）可能没有 /var/mobile 写权限，退到 /tmp
        "/tmp/themeboard-engine.log",
        "/var/tmp/themeboard-engine.log",
        NULL
    };
    for (int i = 0; cands[i]; i++) {
        FILE *f = fopen(cands[i], "a");
        if (f) {
            fclose(f);
            strncpy(path, cands[i], sizeof(path) - 1);
            return path;
        }
    }
    return NULL;
}

/// 探针：用于排查"某个界面到底走哪条取图接口"。
/// 与 TBLog 不同，它在所有进程里都写，且按进程名分文件，避免互相覆盖。
static void TBProbe(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *name = [[NSProcessInfo processInfo] processName] ?: @"unknown";
    NSString *dir = @"/var/mobile/Library/ThemeBoard";
    NSString *path = [dir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"probe-%@.log", name]];
    FILE *f = fopen(path.UTF8String, "a+");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    if (size < 200 * 80) {          // 每进程最多约 200 行
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss";
        fprintf(f, "%s %s\n", [[df stringFromDate:[NSDate date]] UTF8String], body.UTF8String);
    }
    fclose(f);
}

/// 日志超过 512KB 时截断，只保留后半，避免无限增长
static void TBTrimLog(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    if (sz < 512 * 1024) { fclose(f); return; }
    long keep = 256 * 1024;
    fseek(f, sz - keep, SEEK_SET);
    NSMutableData *d = [NSMutableData data];
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) [d appendBytes:buf length:n];
    fclose(f);
    [d writeToFile:@(path) atomically:YES];
}

static void TBLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *msg = [NSString stringWithFormat:@"[%@] %@", TBProcName(), body];
    NSLog(@"[ThemeBoard] %@", msg);

    // 所有进程都写，但每进程限量 60 行（用于观察 Preferences / iconservicesagent 等进程的行为）
    static int sPerProcLines = 0;
    if (sPerProcLines >= 400) return;
    sPerProcLines++;
    const char *lp = TBLogFilePath();
    if (!lp) return;
    if (!gLogQueue) gLogQueue = dispatch_queue_create("themeboard.log", DISPATCH_QUEUE_SERIAL);
    TBTrimLog(lp);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];

    dispatch_async(gLogQueue, ^{
        FILE *f = fopen(lp, "a");
        if (!f) return;
        fprintf(f, "%s", [line UTF8String]);
        fclose(f);
    });
}

#pragma mark - 设置 / 索引

static id TBPref(NSString *key) {
    // CFPreferences 在多进程间缓存不同步（曾导致 Spotlight/Preferences 里读到"无主题"）。
    // 直接读 plist 文件兜底，保证每个进程都能拿到当前设置。
    static NSDictionary *sCache = nil;
    static NSDate *sCacheTime = nil;
    NSDate *now = [NSDate date];
    if (!sCache || !sCacheTime || [now timeIntervalSinceDate:sCacheTime] > 2.0) {
        for (NSString *p in @[@"/var/mobile/Library/Preferences/com.ning.themeboard.plist",
                              @"/var/jb/var/mobile/Library/Preferences/com.ning.themeboard.plist"]) {
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
            if (d) { sCache = d; break; }
        }
        sCacheTime = now;
    }
    if (sCache[key]) return sCache[key];

    return (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                           (__bridge CFStringRef)kDomain);
}
static BOOL TBSafeMode(void) {
    id v = TBPref(@"SafeMode");
    return v ? [v boolValue] : NO;
}

static BOOL TBEnabled(void) { id v = TBPref(kEnabled); return v ? [v boolValue] : YES; }
/// 分项开关（默认全开）。关掉某一项，对应位置保持系统原样。
static BOOL TBApplyEnabled(NSString *key) {
    id v = TBPref(key);
    return v ? [v boolValue] : YES;
}
/// 程序坞 / 文件夹预览 / App 切换器共用系统图标缓存，三开关任一开即允许替换。
static BOOL TBApplyIconForDesktop(void) {
    // 桌面图标：Dock、文件夹预览、App 切换器共用（打开任一即替换）
    return TBApplyEnabled(@"ApplyDock") || TBApplyEnabled(@"ApplyFolder") || TBApplyEnabled(@"ApplySwitcher");
}

static BOOL TBApplyIconForDock(void) {
    // Dock 独立开关
    return TBApplyEnabled(@"ApplyDock");
}

static BOOL TBApplyIconForFolder(void) {
    // 文件夹预览独立开关
    return TBApplyEnabled(@"ApplyFolder");
}

static BOOL TBApplyIconForSwitcher(void) {
    // App 切换器独立开关
    return TBApplyEnabled(@"ApplySwitcher");
}
static NSString *TBActiveTheme(void) {
    id v = TBPref(kActiveTheme);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSArray<NSString *> *TBRoots(void) {
    // App 容器路径优先（RootHide 下 App 只能写自己的容器，引擎在这里读）
    id root = TBPref(@"ThemeRoot");
    NSMutableArray *a = [NSMutableArray array];
    if ([root isKindOfClass:[NSString class]] && [root length]) [a addObject:root];
    [a addObjectsFromArray:@[@"/var/jb/Library/Themes", @"/var/mobile/Library/Themes",
                             @"/Library/Themes", @"/var/jb/var/Library/Themes"]];
    return a;
}

static NSString *TBThemeDir(NSString *name) {
    if (!name.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = @[ name, [name stringByAppendingString:@".theme"] ];
    for (NSString *root in TBRoots()) {
        for (NSString *n in names) {
            NSString *p = [root stringByAppendingPathComponent:n];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) return p;
        }
        // 再退一步：扫描该根目录，做包含匹配（大小写/空格差异也能命中）
        for (NSString *item in [fm contentsOfDirectoryAtPath:root error:NULL]) {
            BOOL isDir = NO;
            NSString *p = [root stringByAppendingPathComponent:item];
            if (![fm fileExistsAtPath:p isDirectory:&isDir] || !isDir) continue;
            NSString *base = [item hasSuffix:@".theme"] ? [item substringToIndex:item.length - 6] : item;
            if ([base caseInsensitiveCompare:name] == NSOrderedSame) return p;
        }
    }
    return nil;
}

static NSString *TBStripName(NSString *file) {
    NSString *s = [file stringByDeletingPathExtension];
    if ([s hasSuffix:@"@2x"] || [s hasSuffix:@"@3x"]) s = [s substringToIndex:s.length - 3];
    for (NSString *suf in @[@"-large", @"-small", @"-76", @"-60", @"-40"])
        if ([s hasSuffix:suf]) s = [s substringToIndex:s.length - suf.length];
    NSRange t = [s rangeOfString:@"~"];
    if (t.location != NSNotFound) s = [s substringToIndex:t.location];
    return s;
}

static void TBLoadIndex(void);          // 前置声明：TBResourceImage 会用到

static void TBLoadBundleResources(NSString *themeDir) {
    if (gBundleRes) return;
    gBundleRes = [NSMutableDictionary dictionary];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [themeDir stringByAppendingPathComponent:@"Bundles"];
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger guard = 0;
    while (stack.count && guard++ < 3000) {
        NSString *dir = stack.firstObject;
        [stack removeObjectAtIndex:0];
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            NSString *full = [dir stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) continue;
            if (isDir) { [stack addObject:full]; continue; }
            if (![[item pathExtension].lowercaseString isEqualToString:@"png"]) continue;
            gBundleRes[item.lowercaseString] = full;
            NSString *base = [item.stringByDeletingPathExtension lowercaseString];
            if ([base hasSuffix:@"@2x"] || [base hasSuffix:@"@3x"])
                base = [base substringToIndex:base.length - 3];
            if (!gBundleRes[base]) gBundleRes[base] = full;
        }
    }
    TBLog(@"Bundles 资源 %lu 个", (unsigned long)gBundleRes.count);
}

/// 主题里是否有同名资源（表盘/指针/文件夹底等）
static UIImage *TBResourceImage(NSString *name) {
    if (!name.length || TBSafeMode() || !TBEnabled()) return nil;
    [gLock lock];
    TBLoadIndex();
    NSString *theme = TBActiveTheme();
    NSString *dir = theme.length ? TBThemeDir(theme) : nil;
    if (dir) TBLoadBundleResources(dir);
    NSMutableDictionary *res = gBundleRes;
    [gLock unlock];
    if (!res.count) return nil;

    NSString *key = name.lastPathComponent.lowercaseString;
    NSString *path = res[key];
    if (!path) {
        NSString *base = [key stringByDeletingPathExtension];
        if ([base hasSuffix:@"@2x"] || [base hasSuffix:@"@3x"])
            base = [base substringToIndex:base.length - 3];
        path = res[base];
    }
    // 必须用 init 方法：imageWithContentsOfFile: 已被本引擎 hook，
    // 在此调用会形成无限递归（栈溢出 → SpringBoard 崩溃循环）。
    if (!path) return nil;
    return [[UIImage alloc] initWithContentsOfFile:path];
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
        if (!bid.length) continue;
        NSInteger r = [f hasSuffix:@"@3x.png"] ? 3 : ([f hasSuffix:@"-large.png"] ? 3 : ([f hasSuffix:@"@2x.png"] ? 2 : 1));
        if ([rank[bid] integerValue] >= r) continue;
        map[bid] = [dir stringByAppendingPathComponent:f];
        rank[bid] = @(r);
    }
    BOOL first = (gIndex == nil);
    gIndex = map;
    gIndexTheme = theme;
    if (first) {
        TBLog(@"索引 %@ → %lu 个图标 (%@)", theme, (unsigned long)map.count, dir);
        if (map.count == 0) {
            TBLog(@"⚠️ 主题目录里没有 PNG：dir=%@", dir ?: @"(未找到目录)");
            TBLog(@"   候选根目录：%@", [TBRoots() componentsJoinedByString:@" | "]);
        }
    }
}

typedef struct { CGSize size; double scale; double ratio; } TBInfo;
typedef TBInfo (*TBInfoFn)(id, SEL);

/// 把主题图缩放成系统期望的尺寸（关键：否则会因 size 不匹配把 SpringBoard 弄崩）
static NSMutableDictionary<NSString *, UIImage *> *gFitCache;

static UIImage *TBFitImage(UIImage *img, TBInfo info) {
    if (!img) return nil;
    CGSize pt = info.size;
    CGFloat scale = info.scale > 0.5 ? info.scale : 3.0;
    if (pt.width < 1 || pt.height < 1) return img;
    if (fabs(img.size.width - pt.width) < 0.6 && fabs(img.size.height - pt.height) < 0.6) return img;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:pt format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, pt.width, pt.height)];
    }];
}

static TBInfo TBInfoOfCache(id cache) {
    TBInfo info = {{60, 60}, 3.0, 0};
    if (!cache || ![cache respondsToSelector:NSSelectorFromString(@"iconImageInfo")]) return info;
    @try {
        TBInfoFn fn = (TBInfoFn)objc_msgSend;
        info = fn(cache, NSSelectorFromString(@"iconImageInfo"));
    } @catch (NSException *e) {}
    if (info.size.width < 1) { info.size = CGSizeMake(60, 60); info.scale = 3.0; }
    return info;
}

static CGFloat TBAverageLuma(UIImage *img) {
    if (!img.CGImage) return 0.5;
    unsigned char px[16 * 4];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 4, 4, 8, 16, cs, kCGImageAlphaPremultipliedLast);
    if (!ctx) { CGColorSpaceRelease(cs); return 0.5; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, 4, 4), img.CGImage);
    CGFloat sum = 0;
    for (int i = 0; i < 16; i++)
        sum += 0.299 * px[i*4] + 0.587 * px[i*4+1] + 0.114 * px[i*4+2];
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return sum / 16.0 / 255.0;
}

/// 日历 / 时钟这类动态图标：在主题底图上重绘实时内容
static UIImage *TBDynamicIcon(UIImage *base, NSString *bid) {
    // 主题图仅作为背景底图，日期/指针由系统动态绘制
    // 因此这里直接返回底图，不做任何重绘
    return base;
}

/// 取主题图：锁内只做字典查找，读盘/绘制都在锁外，避免 SpringBoard 被拖死
static UIImage *TBImageForBundle(NSString *bid) {
    if (!bid.length || !TBEnabled()) return nil;
    if (TBSafeMode()) return nil;   // 安全模式：只记日志，绝不改图

    [gLock lock];
    TBLoadIndex();
    NSString *path = gIndex[bid];
    [gLock unlock];
    if (!path) return nil;

    UIImage *cached = [gImageCache objectForKey:bid];
    if (cached) return cached;

    UIImage *img = [[UIImage alloc] initWithContentsOfFile:path];   // 不用被 hook 的类方法
    if (img) {
        // 日历/时钟带实时内容，不能进缓存，否则日期和指针会冻住
        BOOL dynamic = [bid isEqualToString:@"com.apple.mobilecal"] ||
                       [bid isEqualToString:@"com.apple.mobiletimer"];
        if (dynamic) {
            static int logged = 0;
            if (logged < 20) { logged++; TBLog(@"dynamic %@", bid); }
            img = TBDynamicIcon(img, bid);
        } else {
            [gImageCache setObject:img forKey:bid];
        }
    }
    return img;
}

#pragma mark - 取 bundleID

static NSString *TBBIDFromIcon(id icon) {
    if (!icon) return nil;
    static NSArray *paths = nil;
    if (!paths) paths = @[@"leafIdentifier", @"applicationBundleID", @"bundleIdentifier"];
    for (NSString *k in paths) {
        @try {
            if (![icon respondsToSelector:NSSelectorFromString(k)]) continue;
            id v = [icon valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        } @catch (NSException *e) {}
    }
    return nil;
}

#pragma mark - hook 工具

static IMP TBHook(Class cls, NSString *selName, IMP repl, const char *tag) {
    if (!cls) { TBLog(@"· %s: 类不存在", tag); return NULL; }
    Method m = class_getInstanceMethod(cls, NSSelectorFromString(selName));
    if (!m) { TBLog(@"· %s: 方法不存在(%@)", tag, selName); return NULL; }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, repl);
    TBLog(@"✓ hook %@ -%@", NSStringFromClass(cls), selName);
    return orig;
}

static IMP TBHookClass(Class cls, NSString *selName, IMP repl, const char *tag) {
    if (!cls) { TBLog(@"· %s: 类不存在", tag); return NULL; }
    Method m = class_getClassMethod(cls, NSSelectorFromString(selName));
    if (!m) { TBLog(@"· %s: 类方法不存在(%@)", tag, selName); return NULL; }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, repl);
    TBLog(@"✓ hook %@ +%@", NSStringFromClass(cls), selName);
    return orig;
}

static void TBRemember(id cache) {
    if (!cache) return;
    [gLock lock];
    if (!gCaches) gCaches = [NSMutableSet set];
    [gCaches addObject:[NSValue valueWithPointer:(__bridge const void *)cache]];
    [gLock unlock];
}

#pragma mark - hook 实现

typedef id (*FnIcon)(id, SEL, id);
typedef id (*FnIconOpt)(id, SEL, id, unsigned long long);
typedef id (*FnImageForIcon)(id, SEL, id, id);
typedef id (*FnGen)(id, SEL, TBImageInfo);
typedef id (*FnGenSize)(id, SEL, CGSize, double, BOOL, id);
typedef id (*FnISGeneration)(id, SEL, id *);

static FnIcon o_imageForIcon, o_cachedForIcon, o_unmaskedForIcon;
static FnIconOpt o_imageForIconOpt, o_realForIconOpt, o_unmaskedForIconOpt;
static FnImageForIcon o_cacheImageForIcon;
static FnGen o_generateIconImageWithInfo, o_genericIconImage;
static FnGenSize o_iconImageOfSize;
static FnISGeneration o_isGeneration;
typedef id (*FnISGenerateImage)(id, SEL);
static FnISGenerateImage o_isGenerateImage;

static id tb_imageForIcon(id self, SEL _cmd, id icon) {
    TBRemember(self);
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
        if (img) { gServe++; TBLog(@"serve imageForIcon %@", bid); return img; }
        gMiss++; TBLog(@"miss %@", bid ?: @"(无bid)");
    }
    return o_imageForIcon ? o_imageForIcon(self, _cmd, icon) : nil;
}

static id tb_imageForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TBRemember(self);
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
        if (img) { gServe++; TBLog(@"serve imageForIcon:options: %@ opt=%llu", bid, opt); return img; }
    }
    return o_imageForIconOpt ? o_imageForIconOpt(self, _cmd, icon, opt) : nil;
}

static id tb_cachedForIcon(id self, SEL _cmd, id icon) {
    TBRemember(self);
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
        if (img) { gServe++; TBLog(@"serve cachedImageForIcon %@", bid); return img; }
    }
    return o_cachedForIcon ? o_cachedForIcon(self, _cmd, icon) : nil;
}

static id tb_realForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TBRemember(self);
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
        if (img) { gServe++; TBLog(@"serve realImageForIcon %@", bid); return img; }
    }
    return o_realForIconOpt ? o_realForIconOpt(self, _cmd, icon, opt) : nil;
}

static id tb_unmaskedForIcon(id self, SEL _cmd, id icon) {
    TBRemember(self);
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
        if (img) { gServe++; TBLog(@"serve unmaskedImageForIcon %@", bid); return img; }
    }
    return o_unmaskedForIcon ? o_unmaskedForIcon(self, _cmd, icon) : nil;
}

static id tb_unmaskedForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TBRemember(self);
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
        if (img) { gServe++; TBLog(@"serve unmaskedImageForIcon:options %@", bid); return img; }
    }
    return o_unmaskedForIconOpt ? o_unmaskedForIconOpt(self, _cmd, icon, opt) : nil;
}

/// 缓存落盘的那一刻换掉图 —— 这样所有后续消费者（含变体缓存）拿到的都是主题图
static id tb_cacheImageForIcon(id self, SEL _cmd, id image, id icon) {
    TBRemember(self);
    static int loggedCache = 0;
    if (loggedCache < 40) {
        loggedCache++;
        NSString *sz = @"-";
        if ([image isKindOfClass:[UIImage class]]) {
            sz = [NSString stringWithFormat:@"%.0fx%.0f", ((UIImage *)image).size.width, ((UIImage *)image).size.height];
        }
        TBLog(@"api=cacheImage bid=%@ cls=%@ img=%@", TBBIDFromIcon(icon) ?: @"(nil)",
              NSStringFromClass(object_getClass(image)), sz);
    }
    return o_cacheImageForIcon ? o_cacheImageForIcon(self, _cmd, image, icon) : nil;
}

static id tb_generateIconImageWithInfo(id self, SEL _cmd, TBImageInfo info) {
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(self);
        UIImage *img = TBImageForBundle(bid);
        if (img) { gServe++; TBLog(@"serve generateIconImageWithInfo %@", bid); return img; }
    }
    return o_generateIconImageWithInfo ? o_generateIconImageWithInfo(self, _cmd, info) : nil;
}

// ---- SBIconImageView.setImage:（SnowBoard 核心通道，快捷指令桌面）----
typedef void (*SetImgFn)(id, SEL, id);
static SetImgFn o_setImageOnIconView;

static void tb_setImageOnIconView(id self, SEL _cmd, id image) {
    if (TBEnabled() && !TBSafeMode()) {
        @try {
            id icon = nil;
            if ([self respondsToSelector:NSSelectorFromString(@"icon")]) {
                icon = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"icon"));
            }
            NSString *bid = TBBIDFromIcon(icon);
            if (bid) {
                UIImage *img = TBImageForBundle(bid);
                if (img) {
                    // 只调用一次原实现，用主题图（不递归）
                    if (o_setImageOnIconView) o_setImageOnIconView(self, _cmd, img);
                    gServe++; TBLog(@"serve SBIconImageView.setImage %@", bid);
                    return;
                }
            }
        } @catch (NSException *e) { }
    }
    if (o_setImageOnIconView) o_setImageOnIconView(self, _cmd, image);
}

// ---- SBIconImageView.resetImageWithAppIcon:（SnowBoard 通道，拖拽放置重建）----
typedef void (*ResetImgFn)(id, SEL, id);
static ResetImgFn o_resetImageOnIconView;

static void tb_resetImageOnIconView(id self, SEL _cmd, id icon) {
    // 先让系统完成重置（保持层树完整、不递归）
    if (o_resetImageOnIconView) o_resetImageOnIconView(self, _cmd, icon);
    // 再用主题图覆盖，保证拖拽/状态重建后仍是主题
    if (TBEnabled() && !TBSafeMode()) {
        @try {
            NSString *bid = TBBIDFromIcon(icon);
            if (bid) {
                UIImage *img = TBImageForBundle(bid);
                if (img && o_setImageOnIconView) {
                    o_setImageOnIconView(self, NSSelectorFromString(@"setImage:"), img);
                    gServe++; TBLog(@"serve SBIconImageView.resetImageWithAppIcon %@", bid);
                }
            }
        } @catch (NSException *e) { }
    }
}

// ---- IconServices 生成阶段（拖拽/资源库重建后仍保持主题）----
// 这里先让系统生成原始 IFImage，再仅替换其位图。不要在 SBIconView
// getter 或 crossfade getter 中主动 setImage:，那些方法位于 SpringBoard
// 初始化热路径，容易递归并触发 SpringBoard 重启。
typedef id (*TBISGenerationFn)(id, SEL, id *);
typedef id (*TBIFObjectFn)(id, SEL);
typedef CGSize (*TBIFSizeFn)(id, SEL);
typedef double (*TBIFDoubleFn)(id, SEL);
typedef BOOL (*TBIFBoolFn)(id, SEL);
typedef id (*TBIFCacheInitFn)(id, SEL, CGImageRef, double, CGSize, BOOL, CGSize);
typedef id (*TBIFDataInitFn)(id, SEL, id, id, id);
typedef void (*TBIFSetLargestFn)(id, SEL, BOOL);

/// 主题里该 bundleID 的原图（用 ImageIO 读，不依赖 UIKit：iconservicesagent
/// 里 UIKit 可能没有加载，走 UIImage 会静默拿到 nil）
static CGImageRef TBCGImageForBundle(NSString *bid) {
    if (!bid.length || !TBEnabled() || TBSafeMode()) return NULL;
    [gLock lock];
    TBLoadIndex();
    NSString *path = gIndex[bid];
    [gLock unlock];
    if (!path.length) return NULL;
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    return img;   // Create 规则：调用方负责释放
}

static BOOL TBIFReadGeometry(id image, CGSize *pixelSize, CGSize *minimumSize,
                             CGSize *iconSize, double *scale, BOOL *placeholder,
                             BOOL *largest) {
    if (!image) return NO;
    SEL pixelSel = NSSelectorFromString(@"pixelSize");
    SEL minSel = NSSelectorFromString(@"minimumSize");
    SEL iconSel = NSSelectorFromString(@"iconSize");
    SEL scaleSel = NSSelectorFromString(@"scale");
    SEL placeholderSel = NSSelectorFromString(@"placeholder");
    SEL largestSel = NSSelectorFromString(@"largest");
    if (![image respondsToSelector:pixelSel] || ![image respondsToSelector:minSel] ||
        ![image respondsToSelector:iconSel] || ![image respondsToSelector:scaleSel] ||
        ![image respondsToSelector:placeholderSel] || ![image respondsToSelector:largestSel]) return NO;
    TBIFSizeFn sizeFn = (TBIFSizeFn)objc_msgSend;
    TBIFDoubleFn doubleFn = (TBIFDoubleFn)objc_msgSend;
    TBIFBoolFn boolFn = (TBIFBoolFn)objc_msgSend;
    if (pixelSize) *pixelSize = sizeFn(image, pixelSel);
    if (minimumSize) *minimumSize = sizeFn(image, minSel);
    if (iconSize) *iconSize = sizeFn(image, iconSel);
    if (scale) *scale = doubleFn(image, scaleSel);
    if (placeholder) *placeholder = boolFn(image, placeholderSel);
    if (largest) *largest = boolFn(image, largestSel);
    return YES;
}

/// 用 CoreGraphics 把主题图重绘成系统要求的精确像素尺寸
static CGImageRef TBRasterFromCGImage(CGImageRef src, CGSize pixelSize) {
    if (!src) return NULL;
    size_t w = (size_t)pixelSize.width;
    size_t h = (size_t)pixelSize.height;
    if (w < 1 || h < 1 || w > 1200 || h > 1200) return NULL;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    if (!cs) return NULL;
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextClearRect(ctx, CGRectMake(0, 0, w, h));
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), src);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;   // Create 规则：调用方负责释放
}

/// 只接受系统图标生成器真正会产出、且尺寸自洽的几何参数
static BOOL TBISGeometrySupported(CGSize pixelSize, CGSize minimumSize, CGSize iconSize,
                                  double scale, BOOL placeholder) {
    if (placeholder) return NO;
    if (scale < 1 || scale > 3 || floor(scale) != scale) return NO;
    if (pixelSize.width < 1 || pixelSize.width > 1200) return NO;
    if (pixelSize.width != pixelSize.height || floor(pixelSize.width) != pixelSize.width) return NO;
    if (minimumSize.width <= 0 || minimumSize.width != minimumSize.height) return NO;
    if (iconSize.width < minimumSize.width || iconSize.width != iconSize.height) return NO;
    if (fabs(iconSize.width * scale - pixelSize.width) > 0.001) return NO;
    return YES;
}

static id TBCreateIFImageReplacement(id original, CGImageRef raster, CGSize minimumSize,
                                     CGSize iconSize, double scale, BOOL placeholder, BOOL largest) {
    if (!original || !raster) return nil;
    Class cacheClass = NSClassFromString(@"IFCacheImage");
    Class imageClass = NSClassFromString(@"IFImage");
    SEL cacheSel = NSSelectorFromString(@"initWithCGImage:scale:minimumSize:placeholder:iconSize:");
    SEL dataSel = NSSelectorFromString(@"initWithData:uuid:validationToken:");
    if (!cacheClass || !imageClass || ![cacheClass instancesRespondToSelector:cacheSel] ||
        ![imageClass instancesRespondToSelector:dataSel]) return nil;

    TBIFCacheInitFn cacheInit = (TBIFCacheInitFn)objc_msgSend;
    id cacheImage = cacheInit([cacheClass alloc], cacheSel, raster, scale, minimumSize, placeholder, iconSize);
    if (!cacheImage) return nil;
    SEL bitmapSel = NSSelectorFromString(@"bitmapData");
    if (![cacheImage respondsToSelector:bitmapSel]) return nil;
    id bitmapData = ((TBIFObjectFn)objc_msgSend)(cacheImage, bitmapSel);
    id uuid = [original valueForKey:@"uuid"];
    id validationToken = [original valueForKey:@"validationToken"];
    if (!bitmapData || !uuid) return nil;
    // 系统校验令牌固定 40 字节，长度不对说明 ABI 变了，直接放弃
    if (![validationToken respondsToSelector:@selector(length)] ||
        [(NSData *)validationToken length] != 40) return nil;

    TBIFDataInitFn dataInit = (TBIFDataInitFn)objc_msgSend;
    id replacement = dataInit([imageClass alloc], dataSel, bitmapData, uuid, validationToken);
    if (!replacement) return nil;
    SEL largestSel = NSSelectorFromString(@"setLargest:");
    if ([replacement respondsToSelector:largestSel]) {
        ((TBIFSetLargestFn)objc_msgSend)(replacement, largestSel, largest);
    }
    return replacement;
}

// 生成链统一替换入口。返回 original 表示未替换；reason 为失败原因码：
// 0 成功 / 1 无 bundleID / 2 几何不符 / 3 动态图标 / 4 非 bundle 图标 /
// 5 主题无图 / 6 重绘失败 / 7 像素尺寸不符 / 8 IFImage 重建失败 / 99 异常
static id TBReplaceGeneratedImage(id self, id original, int *reasonOut) {
    if (reasonOut) *reasonOut = 0;
    if (!original) return nil;
    @try {
        id icon = [self valueForKey:@"icon"];
        NSString *bid = [icon valueForKey:@"bundleIdentifier"];
        if (![bid isKindOfClass:[NSString class]] || bid.length == 0) {
            if (reasonOut) *reasonOut = 1;
            return original;
        }
        CGSize pixelSize = CGSizeZero, minimumSize = CGSizeZero, iconSize = CGSizeZero;
        double scale = 0;
        BOOL placeholder = NO, largest = NO;
        if (!TBIFReadGeometry(original, &pixelSize, &minimumSize, &iconSize, &scale, &placeholder, &largest) ||
            !TBISGeometrySupported(pixelSize, minimumSize, iconSize, scale, placeholder)) {
            if (reasonOut) *reasonOut = 2;
            return original;
        }
        // 日历/时钟每天要变，交给 SpringBoard 的专用钩子，这里保持原图
        if ([bid isEqualToString:@"com.apple.mobilecal"] ||
            [bid isEqualToString:@"com.apple.mobiletimer"]) {
            if (reasonOut) *reasonOut = 3;
            return original;
        }
        // 只处理系统自带的 bundle 图标（digest 为 NSUUID），其余类一律放行
        id digest = [original valueForKey:@"digest"];
        if (![digest isKindOfClass:[NSUUID class]]) {
            if (reasonOut) *reasonOut = 4;
            return original;
        }
        CGImageRef theme = TBCGImageForBundle(bid);
        if (!theme) {
            if (reasonOut) *reasonOut = 5;
            return original;
        }
        CGImageRef raster = TBRasterFromCGImage(theme, pixelSize);
        CGImageRelease(theme);
        if (!raster) {
            if (reasonOut) *reasonOut = 6;
            return original;
        }
        if (CGImageGetWidth(raster) != (size_t)pixelSize.width ||
            CGImageGetHeight(raster) != (size_t)pixelSize.height) {
            CGImageRelease(raster);
            if (reasonOut) *reasonOut = 7;
            return original;
        }
        id replacement = TBCreateIFImageReplacement(original, raster, minimumSize, iconSize,
                                                    scale, placeholder, largest);
        CGImageRelease(raster);
        if (!replacement) {
            if (reasonOut) *reasonOut = 8;
            return original;
        }
        return replacement;
    } @catch (NSException *e) {
        if (reasonOut) *reasonOut = 99;
        return original;
    }
}

static void TBLogGenerationResult(id request, id original, id result, int reason, const char *api) {
    static int logged = 0;
    if (logged >= 24) return;
    logged++;
    NSString *bid = nil;
    @try {
        bid = [[request valueForKey:@"icon"] valueForKey:@"bundleIdentifier"];
    } @catch (NSException *e) { }
    TBLog(@"gen %s ret=%d r=%d bid=%@", api, result != original, reason, bid ?: @"(nil)");
}

static id tb_isGeneration(id self, SEL _cmd, id *recordIdentifiers) {
    id original = o_isGeneration ? o_isGeneration(self, _cmd, recordIdentifiers) : nil;
    if (!original || !TBEnabled() || TBSafeMode()) return original;
    int reason = 0;
    id out = TBReplaceGeneratedImage(self, original, &reason);
    if (out != original) gServe++;
    TBLogGenerationResult(self, original, out, reason, "returningRecordIdentifiers");
    return out;
}

static id tb_isGenerateImage(id self, SEL _cmd) {
    id original = o_isGenerateImage ? o_isGenerateImage(self, _cmd) : nil;
    if (!original || !TBEnabled() || TBSafeMode()) return original;
    int reason = 0;
    id out = TBReplaceGeneratedImage(self, original, &reason);
    if (out != original) gServe++;
    TBLogGenerationResult(self, original, out, reason, "generateImage");
    return out;
}

// ---- IFImage（IconServices 图标服务，快捷指令/资源库共用）----
typedef id (*IFImgFn)(id, SEL, id);
typedef id (*IFSizeFn)(id, SEL, CGSize, double);
static IFImgFn o_ifImgDescriptor;
static IFSizeFn o_ifImgSize;

static id tb_ifImgDescriptor(id self, SEL _cmd, id descriptor) {
    if (!TBEnabled() || TBSafeMode()) {
        return o_ifImgDescriptor ? o_ifImgDescriptor(self, _cmd, descriptor) : nil;
    }
    @try {
        NSString *bid = TBBIDFromISIcon(self);
        if (bid.length) {
            UIImage *img = TBImageForBundle(bid);
            if (img) { gServe++; TBLog(@"serve IFImage.desc %@", bid); return img; }
        }
    } @catch (NSException *e) { }
    return o_ifImgDescriptor ? o_ifImgDescriptor(self, _cmd, descriptor) : nil;
}

static id tb_ifImgSize(id self, SEL _cmd, CGSize size, double scale) {
    if (!TBEnabled() || TBSafeMode()) {
        return o_ifImgSize ? o_ifImgSize(self, _cmd, size, scale) : nil;
    }
    @try {
        NSString *bid = TBBIDFromISIcon(self);
        if (bid.length) {
            UIImage *img = TBImageForBundle(bid);
            if (img) { gServe++; TBLog(@"serve IFImage.size %@", bid); return img; }
        }
    } @catch (NSException *e) { }
    return o_ifImgSize ? o_ifImgSize(self, _cmd, size, scale) : nil;
}

static id tb_iconImageOfSize(id self, SEL _cmd, CGSize size, double scale, BOOL gracefully, id drawing) {
    TBRemember(self);
    // 这里拿不到 icon，只做观测：确认这条链是否真的被走
    static int once = 0;
    if (once < 3) { once++; TBLog(@"观测 _iconImageOfSize:%.0fx%.0f scale=%.1f", size.width, size.height, scale); }
    return o_iconImageOfSize ? o_iconImageOfSize(self, _cmd, size, scale, gracefully, drawing) : nil;
}

typedef UIImage *(*UIActivityIconFn)(id, SEL, NSString *);
static UIActivityIconFn o_activityIcon;

/// ShareSheet.framework/UIActivity：分享面板里每个 App 的图标
static UIImage *tb_activityImageForBID(id self, SEL _cmd, NSString *bid) {
    if (!TBApplyEnabled(@"ApplyShare")) {
        // 分享面板：第三方 App 不走 UIActivity 通道
        // 已 hook SBHIconImageCache，通过桌面开关控制
        return o_activityIcon ? o_activityIcon(self, _cmd, bid) : nil;
    }
    if (gProbeCount < 20) { gProbeCount++; TBLog(@"probe UIActivity %@", bid); }
    UIImage *img = TBImageForBundle(bid);
    if (img) { gServe++; TBLog(@"serve UIActivity %@", bid); return img; }
    return o_activityIcon ? o_activityIcon(self, _cmd, bid) : nil;
}


#pragma mark - IconServices（设置页 / 资源库 / 通知中心那条链）

typedef CGImageRef (*ISIconCGFn)(id, SEL, id);
static ISIconCGFn o_isiconCG, o_isiconCG2;

static NSString *TBBIDFromISIcon(id icon) {
    if (!icon) return nil;
    for (NSString *k in @[@"bundleIdentifier", @"applicationBundleIdentifier"]) {
        @try {
            id v = [icon valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        } @catch (NSException *e) {}
    }
    @try {
        id ident = [icon valueForKey:@"_identity"];
        for (NSString *k in @[@"bundleIdentifier", @"applicationBundleIdentifier", @"resourceIdentifier"]) {
            id v = [ident valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        }
        id res = [ident valueForKey:@"resource"];
        id v2 = [res valueForKey:@"bundleIdentifier"];
        if ([v2 isKindOfClass:[NSString class]] && [v2 length]) return v2;
    } @catch (NSException *e) {}
    return nil;
}

static UIImage *TBImageFromISIcon(id icon, id descriptor) {
    NSString *bid = TBBIDFromISIcon(icon);
    if (!bid.length) return nil;
    UIImage *img = TBImageForBundle(bid);
    if (!img) return nil;

    CGSize pt = CGSizeMake(60, 60);
    CGFloat scale = 3.0;
    @try {
        NSValue *sv = [descriptor valueForKey:@"sanitizedSize"];
        if ([sv isKindOfClass:[NSValue class]]) pt = sv.CGSizeValue;
        NSNumber *sc = [descriptor valueForKey:@"sanitizedScale"];
        if ([sc isKindOfClass:[NSNumber class]]) scale = sc.doubleValue;
    } @catch (NSException *e) {}
    if (pt.width < 1) pt = CGSizeMake(60, 60);
    if (scale < 0.5) scale = 3.0;

    TBInfo info = { pt, (double)scale, 0 };
    return TBFitImage(img, info);
}

static CGImageRef tb_isicon_cg(id self, SEL _cmd, id descriptor) {
    static int loggedIcon0 = 0;
    if (loggedIcon0 < 20) { loggedIcon0++; TBLog(@"api=ISIcon.cg1 bid=%@", TBBIDFromISIcon(self) ?: @"(nil)"); }
    if (!TBApplyEnabled(@"ApplySettings")) {
        return o_isiconCG ? o_isiconCG(self, _cmd, descriptor) : NULL;
    }
    @try {
        TBProbe(@"ISIcon CGImageForImageDescriptor %@", TBBIDFromISIcon(self));
        if (gProbeCount < 20) { gProbeCount++; TBLog(@"probe ISIcon %@", TBBIDFromISIcon(self)); }
        UIImage *img = TBImageFromISIcon(self, descriptor);
        if (img && img.CGImage) {
            gServe++;
            TBLog(@"serve ISIcon %@", TBBIDFromISIcon(self));
            return img.CGImage;
        }
    } @catch (NSException *e) {
        TBLog(@"ISIcon 异常: %@", e.reason);
    }
    return o_isiconCG ? o_isiconCG(self, _cmd, descriptor) : NULL;
}

static CGImageRef tb_isicon_cg2(id self, SEL _cmd, id descriptor) {
    static int loggedIcon1 = 0;
    if (loggedIcon1 < 20) { loggedIcon1++; TBLog(@"api=ISIcon.cg2 bid=%@", TBBIDFromISIcon(self) ?: @"(nil)"); }
    if (!TBApplyEnabled(@"ApplySettings")) {
        return o_isiconCG2 ? o_isiconCG2(self, _cmd, descriptor) : NULL;
    }
    @try {
        UIImage *img = TBImageFromISIcon(self, descriptor);
        if (img && img.CGImage) {
            gServe++;
            TBLog(@"serve ISIcon(1) %@", TBBIDFromISIcon(self));
            return img.CGImage;
        }
    } @catch (NSException *e) {}
    return o_isiconCG2 ? o_isiconCG2(self, _cmd, descriptor) : NULL;
}


// 返回类型不确定（UIImage 或 CGImageRef），运行时按真实类型替换；只对日历/时钟生效
typedef id (*ISIconImgFn)(id, SEL, id);
static ISIconImgFn o_isiconImg, o_isiconImg2;

static BOOL TBIsDynamicBID(NSString *bid) {
    return [bid isEqualToString:@"com.apple.mobilecal"] || [bid isEqualToString:@"com.apple.mobiletimer"];
}

static id tb_isicon_image(id self, SEL _cmd, id descriptor) {
    static int loggedIcon2 = 0;
    if (loggedIcon2 < 20) { loggedIcon2++; TBLog(@"api=ISIcon.img1 bid=%@", TBBIDFromISIcon(self) ?: @"(nil)"); }
    id ret = o_isiconImg ? o_isiconImg(self, _cmd, descriptor) : nil;
    if (!TBApplyEnabled(@"ApplySettings")) return ret;

    NSString *bid = TBBIDFromISIcon(self);
    if (!TBIsDynamicBID(bid)) return ret;

    @try {
        UIImage *ours = TBImageFromISIcon(self, descriptor);
        if (!ours) return ret;
        if ([ret isKindOfClass:[UIImage class]]) {
            gServe++;
            TBLog(@"serve ISIcon.img %@", bid);
            return ours;
        }
        if (ret && CFGetTypeID((__bridge CFTypeRef)ret) == CGImageGetTypeID()) {
            gServe++;
            TBLog(@"serve ISIcon.cg %@", bid);
            return (__bridge id)ours.CGImage;
        }
    } @catch (NSException *e) {
        TBLog(@"ISIcon.image 异常: %@", e.reason);
    }
    return ret;
}

static id tb_isicon_image2(id self, SEL _cmd, id descriptor) {
    static int loggedIcon3 = 0;
    if (loggedIcon3 < 20) { loggedIcon3++; TBLog(@"api=ISIcon.img2 bid=%@", TBBIDFromISIcon(self) ?: @"(nil)"); }
    id ret = o_isiconImg2 ? o_isiconImg2(self, _cmd, descriptor) : nil;
    if (!TBApplyEnabled(@"ApplySettings")) return ret;

    NSString *bid = TBBIDFromISIcon(self);
    if (!TBIsDynamicBID(bid)) return ret;

    @try {
        UIImage *ours = TBImageFromISIcon(self, descriptor);
        if (!ours) return ret;
        if ([ret isKindOfClass:[UIImage class]]) {
            gServe++;
            TBLog(@"serve ISIcon.img2 %@", bid);
            return ours;
        }
        if (ret && CFGetTypeID((__bridge CFTypeRef)ret) == CGImageGetTypeID()) {
            gServe++;
            TBLog(@"serve ISIcon.cg2 %@", bid);
            return (__bridge id)ours.CGImage;
        }
    } @catch (NSException *e) {}
    return ret;
}

#pragma mark - SpringBoard 资源替换（时钟表盘/指针、文件夹底图）

typedef UIImage *(*ImgNameFn)(id, SEL, NSString *);
static ImgNameFn o_imageNamed, o_imageWithFile;
typedef UIImage *(*AppIconFn)(id, SEL, id, int);
typedef UIImage *(*AppIconScaleFn)(id, SEL, id, int, double);
static AppIconFn o_appIcon;
static AppIconScaleFn o_appIconScale;

static BOOL TBIsThemedResourceName(NSString *name);
static NSString *TBBIDFromIcon(id icon);

/// 设置页图标 / 通知中心 共用 UIKit 应用图标入口
static BOOL TBUIKitIconEnabled(void) {
    return TBApplyEnabled(@"ApplySettings") || TBApplyEnabled(@"ApplyNotification");
}

static UIImage *tb_appIconImageForBID(id self, SEL _cmd, id identifier, int format) {
    if (TBUIKitIconEnabled() && [identifier isKindOfClass:[NSString class]] && [identifier length]) {
        UIImage *img = TBImageForBundle(identifier);
        if (img) { gServe++; TBLog(@"serve 应用图标 %@ fmt=%d", identifier, format); return img; }
    }
    return o_appIcon ? o_appIcon(self, _cmd, identifier, format) : nil;
}

static UIImage *tb_appIconImageForBIDScale(id self, SEL _cmd, id identifier, int format, double scale) {
    if (TBUIKitIconEnabled() && [identifier isKindOfClass:[NSString class]] && [identifier length]) {
        UIImage *img = TBImageForBundle(identifier);
        if (img) { gServe++; TBLog(@"serve 应用图标 %@ fmt=%d scale=%.0f", identifier, format, scale); return img; }
    }
    return o_appIconScale ? o_appIconScale(self, _cmd, identifier, format, scale) : nil;
}

static UIImage *tb_imageNamed(id self, SEL _cmd, NSString *name) {
    if (!TBIsThemedResourceName(name)) {
        return o_imageNamed ? o_imageNamed(self, _cmd, name) : nil;
    }
    UIImage *img = TBResourceImage(name);
    if (img) { gServe++; TBLog(@"serve 资源 %@", name); return img; }
    TBProbe(@"imageNamed 未命中 %@", name);
    return o_imageNamed ? o_imageNamed(self, _cmd, name) : nil;
}

/// 只有这些名字才值得查主题资源。imageWithContentsOfFile 是极热接口，
/// 这里不能加锁、不能访问文件系统（曾导致 SpringBoard 被拖死 → 整机重启）。
static BOOL TBIsThemedResourceName(NSString *name) {
    if (name.length < 6 || name.length > 48) return NO;
    unichar c0 = [name characterAtIndex:0];
    if (c0 != 'C' && c0 != 'A' && c0 != 'S' && c0 != 'K') return NO;
    static NSArray<NSString *> *prefixes = nil;
    if (!prefixes) prefixes = @[@"ClockIcon", @"ANEM", @"SBClock", @"CalendarIcon", @"Keypad"];
    for (NSString *p in prefixes) {
        if ([name hasPrefix:p]) return YES;
    }
    return NO;
}

static BOOL TBIsThemedResourceName(NSString *name);

static UIImage *tb_imageWithFile(id self, SEL _cmd, NSString *path) {
    if (!TBIsThemedResourceName(path.lastPathComponent)) {
        return o_imageWithFile ? o_imageWithFile(self, _cmd, path) : nil;
    }
    UIImage *img = TBResourceImage(path);
    if (img) { gServe++; TBLog(@"serve 资源文件 %@", path.lastPathComponent); return img; }
    TBProbe(@"imageWithContentsOfFile 未命中 %@", path.lastPathComponent);
    return o_imageWithFile ? o_imageWithFile(self, _cmd, path) : nil;
}

#pragma mark - NSBundle 资源重定向（SpringBoard 自带的表盘/指针等）

typedef NSString *(*BundlePathFn)(id, SEL, NSString *, NSString *);
typedef NSString *(*BundlePathDirFn)(id, SEL, NSString *, NSString *, NSString *);
static BundlePathFn o_pathForRes;
static BundlePathDirFn o_pathForResDir;

static NSString *TBResourcePathNamed(NSString *name, NSString *ext) {
    if (!name.length || TBSafeMode() || !TBEnabled()) return nil;
    [gLock lock];
    TBLoadIndex();
    NSString *theme = TBActiveTheme();
    NSString *dir = theme.length ? TBThemeDir(theme) : nil;
    if (dir) TBLoadBundleResources(dir);
    NSMutableDictionary *res = gBundleRes;
    [gLock unlock];
    if (!res.count) return nil;

    NSString *key = ext.length ? [NSString stringWithFormat:@"%@.%@", name.lowercaseString, ext.lowercaseString]
                               : name.lowercaseString;
    NSString *hit = res[key] ?: res[name.lowercaseString];
    return hit;
}

static NSString *tb_pathForRes(id self, SEL _cmd, NSString *name, NSString *ext) {
    if (!TBIsThemedResourceName(name)) {
        return o_pathForRes ? o_pathForRes(self, _cmd, name, ext) : nil;
    }
    NSString *p = TBResourcePathNamed(name, ext);
    if (p) { TBLog(@"serve 资源路径 %@.%@", name, ext); return p; }
    return o_pathForRes ? o_pathForRes(self, _cmd, name, ext) : nil;
}

static NSString *tb_pathForResDir(id self, SEL _cmd, NSString *name, NSString *ext, NSString *subdir) {
    if (!TBIsThemedResourceName(name)) {
        return o_pathForResDir ? o_pathForResDir(self, _cmd, name, ext, subdir) : nil;
    }
    NSString *p = TBResourcePathNamed(name, ext);
    if (p) { TBLog(@"serve 资源路径(in) %@.%@", name, ext); return p; }
    return o_pathForResDir ? o_pathForResDir(self, _cmd, name, ext, subdir) : nil;
}

#pragma mark - 桌面时钟（SBHClockApplicationIconImageView 自己合成表盘+指针，绕过图片缓存）

typedef struct { double w, h, scale, ratio; } TBClockInfo;      // SBIconImageInfo 的等价布局
typedef id (*ClockIconImageFn)(id, SEL, TBClockInfo, BOOL);
static ClockIconImageFn o_clockIconImage;

static id tb_clockIconImage(id self, SEL _cmd, TBClockInfo info, BOOL mask) {
    if (TBEnabled() && !TBSafeMode()) {
        UIImage *img = TBImageForBundle(@"com.apple.mobiletimer");
        if (img) {
            TBLog(@"serve 时钟图标（桌面合成）");
            TBInfo fi; fi.size = CGSizeMake(info.w, info.h); fi.scale = info.scale; fi.ratio = 0;
            return TBFitImage(img, fi);
        }
    }
    return o_clockIconImage ? o_clockIconImage(self, _cmd, info, mask) : nil;
}

#pragma mark - 设置页图标（PSSpecifier，17.2 头文件确认）

// - (void)setupIconImageWithBundle:(id)bundle;
// - (void)setupIconImageWithPath:(id)path;
// 设置页每个 App 行的图标由这里生成，之前的 UIImage/ISIcon hook 都不会被调用。
typedef void (*SetupIconFn)(id, SEL, id);
static SetupIconFn o_setupIconBundle, o_setupIconPath;

static void tb_setupIconWithBundle(id self, SEL _cmd, id bundle) {
    if (o_setupIconBundle) o_setupIconBundle(self, _cmd, bundle);
    if (!TBEnabled() || TBSafeMode() || !TBUIKitIconEnabled()) return;
    @try {
        NSString *bid = nil;
        for (NSString *k in @[@"identifier", @"bundleIdentifier"]) {
            if ([self respondsToSelector:NSSelectorFromString(k)]) {
                id v = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(k));
                if ([v isKindOfClass:[NSString class]] && [(NSString *)v containsString:@"."]) { bid = v; break; }
            }
        }
        if (!bid.length) return;
        UIImage *img = TBImageForBundle(bid);
        if (!img) { TBLog(@"miss(设置页) %@", bid); return; }
        SEL setIcon = NSSelectorFromString(@"setIconImage:");
        if ([self respondsToSelector:setIcon]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self, setIcon, img);
            TBLog(@"serve(设置页) %@", bid);
        }
    } @catch (NSException *e) { }
}

// 时钟视图会从 imageSet 里取这三层指针叠加上去（17.2 头文件：
// + makeHoursHandLayerWithImageSet: / makeMinutesHandLayerWithImageSet: /
// + makeSecondsHandLayerWithImageSet:）。我们接管背景图后必须同时把这些层置空，
// 否则会出现"主题图自带一根秒针 + 系统又叠一根"的双指针。
typedef id (*ClockLayerFn)(id, SEL, id);
static ClockLayerFn o_clockHandLayer[3];

static id tb_clockHandLayer(id self, SEL _cmd, id imageSet) {
    // 保留系统指针层：直接调用原实现，让系统正常生成指针
    for (int i = 0; i < 3; i++) {
        if (o_clockHandLayer[i]) return o_clockHandLayer[i](self, _cmd, imageSet);
    }
    return nil;
}

#pragma mark - 安装

static BOOL gDoneImageHooks = NO;      // UIImage / NSBundle 那组
static BOOL gDoneISIcon = NO;
static BOOL gDoneActivity = NO;
static BOOL gDoneCache = NO;
static BOOL gDoneClock = NO;
static BOOL gDoneSpecifier = NO;
static BOOL gDoneGen = NO;
static BOOL gDoneISGeneration = NO;

static void TBInstall(void) {
    // 检测 iOS 主版本
    int iosVer = TBGetIOSVersion();
    Class cache = NSClassFromString(@"SBHIconImageCache");
    Class icon  = NSClassFromString(@"SBIcon");
    Class isicon = NSClassFromString(@"ISIcon");
    Class activity = NSClassFromString(@"UIActivity");
    Class spec = NSClassFromString(@"PSSpecifier");
    Class clockView = NSClassFromString(@"SBHClockApplicationIconImageView");
    if (gIsPrimary) {
        TBLog(@"=== iOS 版本=%d 类状态: SBHIconImageCache=%@ SBIcon=%@ ISIcon=%@ UIActivity=%@ PSSpecifier=%@ ClockView=%@ ===",
              iosVer,
              cache ? @"有" : @"无",
              icon ? @"有" : @"无",
              isicon ? @"有" : @"无",
              activity ? @"有" : @"无",
              spec ? @"有" : @"无",
              clockView ? @"有" : @"无");
    }

    // UIImage / NSBundle 资源钩子（跨版本稳定）
    if (!gDoneImageHooks) {
        o_imageNamed = (ImgNameFn)TBHookClass([UIImage class], @"imageNamed:",
                                              (IMP)tb_imageNamed, "UIImage.imageNamed");
        o_imageWithFile = (ImgNameFn)TBHookClass([UIImage class], @"imageWithContentsOfFile:",
                                                 (IMP)tb_imageWithFile, "UIImage.imageWithContentsOfFile");
        o_pathForRes = (BundlePathFn)TBHookClass([NSBundle class], @"pathForResource:ofType:",
                                                 (IMP)tb_pathForRes, "NSBundle.pathForResource");
        o_pathForResDir = (BundlePathDirFn)TBHookClass([NSBundle class], @"pathForResource:ofType:inDirectory:",
                                                       (IMP)tb_pathForResDir, "NSBundle.pathForResource:inDirectory");
        o_appIcon = (AppIconFn)TBHookClass([UIImage class], @"_applicationIconImageForBundleIdentifier:format:",
                                           (IMP)tb_appIconImageForBID, "应用图标");
        o_appIconScale = (AppIconScaleFn)TBHookClass([UIImage class], @"_applicationIconImageForBundleIdentifier:format:scale:",
                                                     (IMP)tb_appIconImageForBIDScale, "应用图标(scale)");
        gDoneImageHooks = YES;
    }

    // ISIcon（运行时检测）
    if (isicon && !gDoneISIcon) {
        gDoneISIcon = YES;
        if (TBHasMethod(isicon, @"CGImageForImageDescriptor:")) {
            o_isiconCG = (ISIconCGFn)TBHook(isicon, @"CGImageForImageDescriptor:", (IMP)tb_isicon_cg, "ISIcon 取图");
        }
        if (TBHasMethod(isicon, @"CGImageForDescriptor:")) {
            o_isiconCG2 = (ISIconCGFn)TBHook(isicon, @"CGImageForDescriptor:", (IMP)tb_isicon_cg2, "ISIcon 取图 2");
        }
        if (TBHasMethod(isicon, @"imageForImageDescriptor:")) {
            o_isiconImg = (ISIconImgFn)TBHook(isicon, @"imageForImageDescriptor:", (IMP)tb_isicon_image, "ISIcon 图像");
        }
        if (TBHasMethod(isicon, @"imageForDescriptor:")) {
            o_isiconImg2 = (ISIconImgFn)TBHook(isicon, @"imageForDescriptor:", (IMP)tb_isicon_image2, "ISIcon 图像 2");
        }
    }

    // 桌面时钟图标（运行时检测）
    if (clockView && !gDoneClock) {
        gDoneClock = YES;
        if (TBHasMethod(clockView, @"iconImageWithImageInfo:includingMask:")) {
            o_clockIconImage = (ClockIconImageFn)TBHookClass(clockView, @"iconImageWithImageInfo:includingMask:",
                                                             (IMP)tb_clockIconImage, "桌面时钟图标");
        }
        if (TBHasMethod(clockView, @"makeHoursHandLayerWithImageSet:")) {
            o_clockHandLayer[0] = (ClockLayerFn)TBHookClass(clockView, @"makeHoursHandLayerWithImageSet:",
                                                            (IMP)tb_clockHandLayer, "时钟时针层");
        }
        if (TBHasMethod(clockView, @"makeMinutesHandLayerWithImageSet:")) {
            o_clockHandLayer[1] = (ClockLayerFn)TBHookClass(clockView, @"makeMinutesHandLayerWithImageSet:",
                                                            (IMP)tb_clockHandLayer, "时钟分针层");
        }
        if (TBHasMethod(clockView, @"makeSecondsHandLayerWithImageSet:")) {
            o_clockHandLayer[2] = (ClockLayerFn)TBHookClass(clockView, @"makeSecondsHandLayerWithImageSet:",
                                                            (IMP)tb_clockHandLayer, "时钟秒针层");
        }
    }

    // PSSpecifier 设置页图标（iOS 17.2+ 使用此通道）
    if (spec && !gDoneSpecifier) {
        gDoneSpecifier = YES;
        if (TBHasMethod(spec, @"setupIconImageWithBundle:")) {
            o_setupIconBundle = (SetupIconFn)TBHook(spec, @"setupIconImageWithBundle:",
                                                    (IMP)tb_setupIconWithBundle, "PSSpecifier 设置页图标");
        }
    }

    // UIActivity 分享面板图标（运行时检测）
    if (activity && !gDoneActivity) {
        gDoneActivity = YES;
        if (TBHasMethod(activity, @"_activityImageForApplicationBundleIdentifier:")) {
            o_activityIcon = (UIActivityIconFn)TBHookClass(activity,
                @"_activityImageForApplicationBundleIdentifier:", (IMP)tb_activityImageForBID, "UIActivity 图标");
        }
    }

    // SBHIconImageCache 主通道（所有版本的核心缓存接口）
    if (cache && !gDoneCache) {
        gDoneCache = YES;
        // 跨版本最稳定的核心方法
        if (TBHasMethod(cache, @"imageForIcon:")) {
            o_imageForIcon = (FnIcon)TBHook(cache, @"imageForIcon:", (IMP)tb_imageForIcon, "imageForIcon");
        }
        if (TBHasMethod(cache, @"imageForIcon:options:")) {
            o_imageForIconOpt = (FnIconOpt)TBHook(cache, @"imageForIcon:options:", (IMP)tb_imageForIconOpt, "imageForIcon:options");
        }
        if (TBHasMethod(cache, @"cachedImageForIcon:")) {
            o_cachedForIcon = (FnIcon)TBHook(cache, @"cachedImageForIcon:", (IMP)tb_cachedForIcon, "cachedImageForIcon");
        }
        // iOS 17.2+ 特有
        if (iosVer >= 17 && TBHasMethod(cache, @"realImageForIcon:options:")) {
            o_realForIconOpt = (FnIconOpt)TBHook(cache, @"realImageForIcon:options:", (IMP)tb_realForIconOpt, "realImageForIcon:options");
        }
        if (iosVer >= 17 && TBHasMethod(cache, @"unmaskedImageForIcon:")) {
            o_unmaskedForIcon = (FnIcon)TBHook(cache, @"unmaskedImageForIcon:", (IMP)tb_unmaskedForIcon, "unmaskedImageForIcon");
        }
        if (iosVer >= 17 && TBHasMethod(cache, @"unmaskedImageForIcon:options:")) {
            o_unmaskedForIconOpt = (FnIconOpt)TBHook(cache, @"unmaskedImageForIcon:options:", (IMP)tb_unmaskedForIconOpt, "unmaskedImageForIcon:options");
        }
        // cacheImage:forIcon: 所有版本都存在
        if (TBHasMethod(cache, @"cacheImage:forIcon:")) {
            o_cacheImageForIcon = (FnImageForIcon)TBHook(cache, @"cacheImage:forIcon:", (IMP)tb_cacheImageForIcon, "cacheImage:forIcon");
        }
    }

    // SBIconImageView.setImage:（安全版，SnowBoard 通道）
    Class iconImageViewCls = NSClassFromString(@"SBIconImageView");
    if (iconImageViewCls && TBHasMethod(iconImageViewCls, @"setImage:")) {
        o_setImageOnIconView = (SetImgFn)TBHook(iconImageViewCls, @"setImage:", (IMP)tb_setImageOnIconView, "SBIconImageView");
    }
    // SBIconImageView.resetImageWithAppIcon:（拖拽放置/状态重建通道）
    if (iconImageViewCls && TBHasMethod(iconImageViewCls, @"resetImageWithAppIcon:")) {
        o_resetImageOnIconView = (ResetImgFn)TBHook(iconImageViewCls, @"resetImageWithAppIcon:", (IMP)tb_resetImageOnIconView, "SBIconImageView.reset");
    }

    // 暂不安装 _iconImageView / crossfade getter hook：iOS 17.2 的 getter
    // 属于 SpringBoard 图标初始化热路径，hook 本身会造成闪屏重启。

    // iconservicesagent 的最终生成通道：资源库拖拽/桌面重建会重新经过这里。
    // 只在原实现返回后替换 IFImage，失败一律返回原图。
    Class generation = NSClassFromString(@"ISGenerationRequest");
    if (generation && !gDoneISGeneration) {
        gDoneISGeneration = YES;
        if (TBHasMethod(generation, @"generateImageReturningRecordIdentifiers:")) {
            o_isGeneration = (FnISGeneration)TBHook(generation,
                @"generateImageReturningRecordIdentifiers:",
                (IMP)tb_isGeneration, "ISGenerationRequest 图标生成");
        }
        if (TBHasMethod(generation, @"generateImage")) {
            o_isGenerateImage = (FnISGenerateImage)TBHook(generation,
                @"generateImage", (IMP)tb_isGenerateImage,
                "ISGenerationRequest generateImage");
        }
    }

    // IFImage（IconServices 通道）
    Class ifImage = NSClassFromString(@"IFImage");
    if (ifImage) {
        if (TBHasMethod(ifImage, @"imageForDescriptor:")) {
            o_ifImgDescriptor = (IFImgFn)TBHook(ifImage, @"imageForDescriptor:", (IMP)tb_ifImgDescriptor, "IFImage.desc");
        }
        if (TBHasMethod(ifImage, @"imageForSize:scale:")) {
            o_ifImgSize = (IFSizeFn)TBHook(ifImage, @"imageForSize:scale:", (IMP)tb_ifImgSize, "IFImage.size");
        }
    }

    // generateIconImageWithInfo: 仅在 iOS 17.x 上启用（唯一已验证版本）
    if (icon && !gDoneGen) {
        gDoneGen = YES;
        if (TBHasMethod(icon, @"generateIconImageWithInfo:")) {
            o_generateIconImageWithInfo = (FnGen)TBHook(icon, @"generateIconImageWithInfo:",
                                                        (IMP)tb_generateIconImageWithInfo, "generateIconImageWithInfo");
        }
    }
}


/// 让 SpringBoard 自己重绘桌面图标（不注销）
static void TBRefreshSpringBoard(void) {
    Class sc = NSClassFromString(@"SBIconController");
    if (sc) {
        @try {
            id ctrl = ((id (*)(id, SEL))objc_msgSend)(sc, NSSelectorFromString(@"sharedInstance"));
            SEL selMgr = NSSelectorFromString(@"iconManager");
            if (ctrl && [ctrl respondsToSelector:selMgr]) {
                id mgr = ((id (*)(id, SEL))objc_msgSend)(ctrl, selMgr);
                SEL selNote = NSSelectorFromString(@"noteIconStateChangedExternally");
                if (mgr && [mgr respondsToSelector:selNote]) {
                    ((void (*)(id, SEL))objc_msgSend)(mgr, selNote);
                    TBLog(@"已通知 SpringBoard 刷新图标");
                    return;
                }
            }
        } @catch (NSException *e) {
            TBLog(@"刷新失败: %@", e.reason);
        }
    }
    TBLog(@"· 没有找到 iconManager，图标要等下次重绘");
}

/// 取桌面上所有图标（用于按需清理缓存）
static NSArray *TBAllIcons(void) {
    @try {
        Class sc = NSClassFromString(@"SBIconController");
        if (sc) {
            id ctrl = ((id (*)(id, SEL))objc_msgSend)(sc, NSSelectorFromString(@"sharedInstance"));
            id mgr = [ctrl valueForKey:@"iconManager"];
            id model = [mgr valueForKey:@"iconModel"];
            id leaf = [model valueForKey:@"leafIcons"];
            if ([leaf isKindOfClass:[NSArray class]] && [leaf count]) return leaf;
            id all = [model valueForKey:@"icons"];
            if ([all isKindOfClass:[NSArray class]] && [all count]) return all;
        }
    } @catch (NSException *e) {
        TBLog(@"取图标列表失败: %@", e.reason);
    }
    return @[];
}

/// 只清这些图标的缓存；icons 为空则退化为全清
static void TBPurgeIcons(NSValue *cacheValue, NSArray *icons) {
    id cache = (__bridge id)cacheValue.pointerValue;
    if (!cache) return;
    @try {
        if (icons.count) {
            SEL sel = NSSelectorFromString(@"purgeCachedImagesForIcons:");
            if ([cache respondsToSelector:sel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(cache, sel, icons);
            }
        } else {
            SEL all = NSSelectorFromString(@"purgeAllCachedImages");
            if ([cache respondsToSelector:all]) {
                ((void (*)(id, SEL))objc_msgSend)(cache, all);
            }
        }
    } @catch (NSException *e) {
        TBLog(@"清理异常: %@", e.reason);
    }
}

/// 只清「主题覆盖到的」那几十个图标的缓存，小批 + 间隔，避免把 SpringBoard 拖死。
static void TBPurgeThemedIcons(void) {
    if (TBSafeMode()) { TBLog(@"安全模式：跳过清缓存"); return; }
    id v = TBPref(@"PurgeCache");
    if (v && ![v boolValue]) { TBLog(@"已跳过清缓存（设置里关掉了）"); return; }

    [gLock lock];
    NSArray *caches = gCaches.allObjects;
    NSDictionary *index = gIndex;
    [gLock unlock];

    NSMutableSet *bids = [NSMutableSet set];
    for (NSString *bid in index) [bids addObject:bid];
    if (!bids.count || !caches.count) { TBLog(@"清缓存：没有可清的目标"); return; }

    // 取当前图标列表
    NSArray *icons = nil;
    @try {
        id ctrl = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"SBIconController"), NSSelectorFromString(@"sharedInstance"));
        id model = ((id (*)(id, SEL))objc_msgSend)(ctrl, NSSelectorFromString(@"iconModel"));
        icons = ((id (*)(id, SEL))objc_msgSend)(model, NSSelectorFromString(@"leafIcons"));
    } @catch (NSException *e) { icons = nil; }
    if (![icons isKindOfClass:[NSArray class]] || !icons.count) { TBLog(@"清缓存：拿不到图标列表"); return; }

    // 只挑主题覆盖到的
    NSMutableArray *targets = [NSMutableArray array];
    for (id icon in icons) {
        NSString *bid = TBBIDFromIcon(icon);
        if (bid && [bids containsObject:bid]) [targets addObject:icon];
    }
    if (!targets.count) { TBLog(@"清缓存：没有匹配到的图标"); return; }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger i = 0;
        while (i < targets.count) {
            NSUInteger n = MIN((NSUInteger)10, targets.count - i);
            NSArray *part = [targets subarrayWithRange:NSMakeRange(i, n)];
            for (NSValue *cv in caches) {
                id cache = cv.nonretainedObjectValue;
                @try {
                    SEL sel = NSSelectorFromString(@"purgeCachedImagesForIcons:");
                    if ([cache respondsToSelector:sel]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(cache, sel, part);
                    }
                } @catch (NSException *e) { }
            }
            i += n;
            usleep(250000);   // 每小批之间 250ms，让出主线程
        }
        TBLog(@"已小批清理 %lu 个图标缓存（每批 10 个）", (unsigned long)targets.count);
    });
}

static void TBReload(CFNotificationCenterRef c, void *o, CFNotificationName n, const void *obj, CFDictionaryRef info) {
    [gLock lock];
    gIndex = nil;
    NSArray *caches = gCaches.allObjects;
    [gLock unlock];
    TBLog(@"设置变更：重建索引，清理 %lu 个缓存", (unsigned long)caches.count);

    BOOL allowPurge = YES;
    id pv = TBPref(@"PurgeCache");
    if (pv) allowPurge = [pv boolValue];
    if (!allowPurge) { TBLog(@"已跳过清缓存（设置里关掉了）"); return; }

    // 主线程、按图标、分批清理：一次清光会把 SpringBoard 拖死
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *icons = TBAllIcons();
        NSArray *cacheList = caches;
        if (icons.count == 0) {
            // 拿不到图标列表时退化为旧方式，但只清一次且容错
            for (NSValue *v in cacheList) { TBPurgeIcons(v, nil); }
            TBLog(@"清缓存（无图标列表）");
            return;
        }

        const NSUInteger chunk = 30;
        NSUInteger i = 0;
        NSInteger round = 0;
        while (i < icons.count) {
            NSUInteger n = MIN(chunk, icons.count - i);
            NSArray *part = [icons subarrayWithRange:NSMakeRange(i, n)];
            for (NSValue *v in cacheList) { TBPurgeIcons(v, part); }
            i += n;
            round++;
            usleep(20000);   // 每批之间让出 20ms，避免主线程长时间被占用
        }
        TBLog(@"已分批清理 %lu 个图标的缓存（%ld 批）", (unsigned long)icons.count, (long)round);
    });

    [gImageCache removeAllObjects];
    if (TBPref(@"ForceRefresh") && [TBPref(@"ForceRefresh") boolValue]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            TBRefreshSpringBoard();
        });
    }
}

/// App 请求重启桌面：让 SpringBoard 退出，系统会自动把它拉起来（等效 respring）
static void TBHandleRespring(CFNotificationCenterRef c, void *o, CFNotificationName n,
                             const void *obj, CFDictionaryRef info) {
    if (!gIsPrimary) return;
    TBLog(@"收到重启桌面请求 → 退出 SpringBoard");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(0); });
}

/// 最原始的存活标记：用 C 文件 API 直接写，绕开一切 Objective-C 机制。
/// 只要这个文件出现，就说明 dylib 被 dyld 加载并执行了构造器。
static void TBTouchMarker(const char *tag) {
    const char *paths[] = {
        "/var/mobile/Library/ThemeBoard/alive.txt",
        "/var/jb/var/mobile/Library/ThemeBoard/alive.txt",
        "/tmp/themeboard-alive.txt",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        FILE *f = fopen(paths[i], "a");
        if (!f) continue;
        time_t t = time(NULL);
        struct tm tmv;
        localtime_r(&t, &tmv);
        fprintf(f, "%02d:%02d:%02d pid=%d %s %s\n",
                tmv.tm_hour, tmv.tm_min, tmv.tm_sec, getpid(), tag,
                [[[NSProcessInfo processInfo] processName] UTF8String] ?: "?");
        fclose(f);
    }
}

__attribute__((constructor))
static void TBMain(void) {
    TBTouchMarker("constructor");   // 第一件事：证明自己被加载
    BOOL hasCache = NO;
    @try {
    hasCache = NSClassFromString(@"SBHIconImageCache") != nil;
    BOOL hasActivity = NSClassFromString(@"UIActivity") != nil;
    BOOL hasISIcon = NSClassFromString(@"ISIcon") != nil;
    // 注意：这里【不能】提前 return。构造器执行得极早，
    // SpringBoardHome 可能尚未加载，NSClassFromString 会返回 nil，
    // 一旦提前退出，引擎在 SpringBoard 里就永远装不上 hook。
    // 刷屏问题改由「只有 SpringBoard 写日志文件 + 串行队列」控制。

    // 用【进程名】判断，而不是 hasCache —— 构造器阶段 SBHIconImageCache 可能还没加载，
    // 用类判断会导致 SpringBoard 自己被当成"非主进程"，于是什么都不写。
    NSString *pname = [[NSProcessInfo processInfo] processName] ?: @"";
    gIsPrimary = [pname isEqualToString:@"SpringBoard"] ||
                 [pname rangeOfString:@"iconservicesagent"].location != NSNotFound;
    gLock = [[NSLock alloc] init];
    gImageCache = [[NSCache alloc] init];
    gImageCache.countLimit = 600;
    if (hasCache) {
        TBLog(@"=== ThemeBoardEngine 加载 pid=%d ===", getpid());
        TBLog(@"主题=%@ 开关=%@", TBActiveTheme() ?: @"(无)", TBEnabled() ? @"开" : @"关");
    }
    TBInstall();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TBHandleRespring,
                                    (__bridge CFStringRef)kRespring, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TBReload,
                                    (__bridge CFStringRef)kNotify, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    } @catch (NSException *e) {
        TBTouchMarker("crash");
    }

    // 心跳只在负责图标缓存的进程（SpringBoard）里跑，避免多进程反复改日志时间戳
    // 延迟重试：IconServices / ShareSheet 等框架是懒加载的，
    // 构造器执行时可能还没载入，导致对应 hook 一辈子装不上。
    for (int i = 1; i <= 10; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            TBInstall();
        });
    }

    if (!hasCache) return;
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
