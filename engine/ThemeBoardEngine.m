// ThemeBoardEngine v0.2 — 按 iOS 17.2 真实私有头文件重写
// 依据：headers/17.2/{SBHIconImageCache,SBIcon,SBLeafIcon,SBApplicationIcon,SBHIconManager}.h
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>

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
    if (sPerProcLines >= 60) return;
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
    if (!base) return nil;
    BOOL isCal = [bid isEqualToString:@"com.apple.mobilecal"];
    BOOL isClock = [bid isEqualToString:@"com.apple.mobiletimer"];
    if (!isCal && !isClock) return base;

    CGSize size = base.size;
    if (size.width < 8) return base;

    UIColor *ink = TBAverageLuma(base) > 0.62 ? [UIColor colorWithWhite:0.12 alpha:1]
                                              : [UIColor colorWithWhite:0.98 alpha:1];
    NSDate *now = [NSDate date];

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [base drawInRect:CGRectMake(0, 0, size.width, size.height)];
        CGContextRef c = ctx.CGContext;

        if (isCal) {
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSInteger day = [cal component:NSCalendarUnitDay fromDate:now];
            NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
            ps.alignment = NSTextAlignmentCenter;
            NSString *num = [NSString stringWithFormat:@"%ld", (long)day];
            [num drawInRect:CGRectMake(0, size.height * 0.52, size.width, size.height * 0.40)
             withAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:size.width * 0.42 weight:UIFontWeightBold],
                              NSForegroundColorAttributeName: ink,
                              NSParagraphStyleAttributeName: ps}];
        } else {
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSInteger hour = [cal component:NSCalendarUnitHour fromDate:now] % 12;
            NSInteger minute = [cal component:NSCalendarUnitMinute fromDate:now];
            NSInteger second = [cal component:NSCalendarUnitSecond fromDate:now];

            CGPoint ctr = CGPointMake(size.width / 2, size.height / 2);
            CGFloat R = size.width * 0.40;

            CGFloat aHour = (hour + minute / 60.0) * M_PI / 6.0;
            CGFloat aMin  = (minute + second / 60.0) * M_PI / 30.0;
            CGFloat aSec  = second * M_PI / 30.0;

            CGContextSetStrokeColorWithColor(c, ink.CGColor);
            CGContextSetLineCap(c, kCGLineCapRound);

            CGContextSetLineWidth(c, size.width * 0.055);
            CGContextMoveToPoint(c, ctr.x, ctr.y);
            CGContextAddLineToPoint(c, ctr.x + sin(aHour) * R * 0.55, ctr.y - cos(aHour) * R * 0.55);
            CGContextStrokePath(c);

            CGContextSetLineWidth(c, size.width * 0.038);
            CGContextMoveToPoint(c, ctr.x, ctr.y);
            CGContextAddLineToPoint(c, ctr.x + sin(aMin) * R * 0.82, ctr.y - cos(aMin) * R * 0.82);
            CGContextStrokePath(c);

            CGContextSetStrokeColorWithColor(c, [UIColor colorWithRed:0.95 green:0.26 blue:0.21 alpha:1].CGColor);
            CGContextSetLineWidth(c, size.width * 0.016);
            CGContextMoveToPoint(c, ctr.x, ctr.y);
            CGContextAddLineToPoint(c, ctr.x + sin(aSec) * R * 0.90, ctr.y - cos(aSec) * R * 0.90);
            CGContextStrokePath(c);

            CGContextSetFillColorWithColor(c, ink.CGColor);
            CGContextFillEllipseInRect(c, CGRectMake(ctr.x - size.width * 0.028, ctr.y - size.width * 0.028,
                                                     size.width * 0.056, size.width * 0.056));
        }
    }];
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

static FnIcon o_imageForIcon, o_cachedForIcon, o_unmaskedForIcon;
static FnIconOpt o_imageForIconOpt, o_realForIconOpt, o_unmaskedForIconOpt;
static FnImageForIcon o_cacheImageForIcon;
static FnGen o_generateIconImageWithInfo, o_genericIconImage;
static FnGenSize o_iconImageOfSize;

static id tb_imageForIcon(id self, SEL _cmd, id icon) {
    TBRemember(self);
    NSString *bid = TBBIDFromIcon(icon);
    UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
    if (img) { gServe++; TBLog(@"serve imageForIcon %@", bid); return img; }
    gMiss++; TBLog(@"miss %@", bid ?: @"(无bid)");
    return o_imageForIcon ? o_imageForIcon(self, _cmd, icon) : nil;
}

static id tb_imageForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TBRemember(self);
    NSString *bid = TBBIDFromIcon(icon);
    UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
    if (img) { gServe++; TBLog(@"serve imageForIcon:options: %@ opt=%llu", bid, opt); return img; }
    return o_imageForIconOpt ? o_imageForIconOpt(self, _cmd, icon, opt) : nil;
}

static id tb_cachedForIcon(id self, SEL _cmd, id icon) {
    TBRemember(self);
    NSString *bid = TBBIDFromIcon(icon);
    UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
    if (img) { gServe++; TBLog(@"serve cachedImageForIcon %@", bid); return img; }
    return o_cachedForIcon ? o_cachedForIcon(self, _cmd, icon) : nil;
}

static id tb_realForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TBRemember(self);
    NSString *bid = TBBIDFromIcon(icon);
    UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
    if (img) { gServe++; TBLog(@"serve realImageForIcon %@", bid); return img; }
    return o_realForIconOpt ? o_realForIconOpt(self, _cmd, icon, opt) : nil;
}

static id tb_unmaskedForIcon(id self, SEL _cmd, id icon) {
    TBRemember(self);
    NSString *bid = TBBIDFromIcon(icon);
    UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
    if (img) { gServe++; TBLog(@"serve unmaskedImageForIcon %@", bid); return img; }
    return o_unmaskedForIcon ? o_unmaskedForIcon(self, _cmd, icon) : nil;
}

static id tb_unmaskedForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TBRemember(self);
    NSString *bid = TBBIDFromIcon(icon);
    UIImage *img = TBFitImage(TBImageForBundle(bid), TBInfoOfCache(self));
    if (img) { gServe++; TBLog(@"serve unmaskedImageForIcon:options %@", bid); return img; }
    return o_unmaskedForIconOpt ? o_unmaskedForIconOpt(self, _cmd, icon, opt) : nil;
}

/// 缓存落盘的那一刻换掉图 —— 这样所有后续消费者（含变体缓存）拿到的都是主题图
static id tb_cacheImageForIcon(id self, SEL _cmd, id image, id icon) {
    TBRemember(self);
    return o_cacheImageForIcon ? o_cacheImageForIcon(self, _cmd, image, icon) : nil;
}

static id tb_generateIconImageWithInfo(id self, SEL _cmd, TBImageInfo info) {
    NSString *bid = TBBIDFromIcon(self);
    UIImage *img = TBImageForBundle(bid);
    if (img) { gServe++; TBLog(@"serve generateIconImageWithInfo %@", bid); return img; }
    return o_generateIconImageWithInfo ? o_generateIconImageWithInfo(self, _cmd, info) : nil;
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
    id ret = o_isiconImg ? o_isiconImg(self, _cmd, descriptor) : nil;

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
    id ret = o_isiconImg2 ? o_isiconImg2(self, _cmd, descriptor) : nil;

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

static BOOL TBIsThemedResourceName(NSString *name);
static NSString *TBBIDFromIcon(id icon);

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
    if (!TBEnabled() || TBSafeMode()) return;
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
    if (TBEnabled() && !TBSafeMode()) {
        if (TBImageForBundle(@"com.apple.mobiletimer")) return nil;
    }
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

static void TBInstall(void) {
    Class cache = NSClassFromString(@"SBHIconImageCache");
    Class icon  = NSClassFromString(@"SBIcon");
    Class leaf  = NSClassFromString(@"SBLeafIcon");
    if (gIsPrimary) {
        TBLog(@"类状态: SBHIconImageCache=%@ SBIcon=%@ UIActivity=%@ ISIcon=%@",
              cache ? @"有" : @"无", icon ? @"有" : @"无",
              NSClassFromString(@"UIActivity") ? @"有" : @"无",
              NSClassFromString(@"ISIcon") ? @"有" : @"无");
    }

    // 只替换主题里确实存在的同名资源，其它一概放行
    if (!gDoneImageHooks) {
        o_imageNamed = (ImgNameFn)TBHookClass([UIImage class], @"imageNamed:",
                                              (IMP)tb_imageNamed, "UIImage.imageNamed");
        o_imageWithFile = (ImgNameFn)TBHookClass([UIImage class], @"imageWithContentsOfFile:",
                                                 (IMP)tb_imageWithFile, "UIImage.imageWithContentsOfFile");
        o_pathForRes = (BundlePathFn)TBHook([NSBundle class], @"pathForResource:ofType:",
                                                 (IMP)tb_pathForRes, "NSBundle.pathForResource");
        o_pathForResDir = (BundlePathDirFn)TBHookClass([NSBundle class], @"pathForResource:ofType:inDirectory:",
                                                       (IMP)tb_pathForResDir, "NSBundle.pathForResource:inDirectory");
        gDoneImageHooks = (o_imageNamed != NULL);
    }

    Class isicon = NSClassFromString(@"ISIcon");
    if (isicon && !gDoneISIcon) {
        o_isiconCG  = (ISIconCGFn)TBHook(isicon, @"CGImageForImageDescriptor:", (IMP)tb_isicon_cg, "ISIcon取图");
        o_isiconCG2 = (ISIconCGFn)TBHook(isicon, @"CGImageForDescriptor:", (IMP)tb_isicon_cg2, "ISIcon取图2");
        o_isiconImg  = (ISIconImgFn)TBHook(isicon, @"imageForImageDescriptor:", (IMP)tb_isicon_image, "ISIcon图像");
        o_isiconImg2 = (ISIconImgFn)TBHook(isicon, @"imageForDescriptor:", (IMP)tb_isicon_image2, "ISIcon图像2");
        gDoneISIcon = YES;
    }

    Class clockView = NSClassFromString(@"SBHClockApplicationIconImageView");
    if (clockView && !gDoneClock) {
        gDoneClock = YES;
        o_clockIconImage = (ClockIconImageFn)TBHookClass(clockView, @"iconImageWithImageInfo:includingMask:",
                                                         (IMP)tb_clockIconImage, "桌面时钟图标");
        o_clockHandLayer[0] = (ClockLayerFn)TBHookClass(clockView, @"makeHoursHandLayerWithImageSet:",
                                                        (IMP)tb_clockHandLayer, "时钟时针层");
        o_clockHandLayer[1] = (ClockLayerFn)TBHookClass(clockView, @"makeMinutesHandLayerWithImageSet:",
                                                        (IMP)tb_clockHandLayer, "时钟分针层");
        o_clockHandLayer[2] = (ClockLayerFn)TBHookClass(clockView, @"makeSecondsHandLayerWithImageSet:",
                                                        (IMP)tb_clockHandLayer, "时钟秒针层");
    }

    Class spec = NSClassFromString(@"PSSpecifier");
    if (spec && !gDoneSpecifier) {
        gDoneSpecifier = YES;
        o_setupIconBundle = (SetupIconFn)TBHook(spec, @"setupIconImageWithBundle:",
                                                (IMP)tb_setupIconWithBundle, "PSSpecifier设置页图标");
    }

    Class activity = NSClassFromString(@"UIActivity");
    if (activity && !gDoneActivity) {
        o_activityIcon = (UIActivityIconFn)TBHookClass(activity,
            @"_activityImageForApplicationBundleIdentifier:", (IMP)tb_activityImageForBID, "UIActivity图标");
        gDoneActivity = YES;
    }

    if (cache && !gDoneCache) {
        gDoneCache = YES;
        o_imageForIcon        = (FnIcon)TBHook(cache, @"imageForIcon:", (IMP)tb_imageForIcon, "imageForIcon");
        o_imageForIconOpt     = (FnIconOpt)TBHook(cache, @"imageForIcon:options:", (IMP)tb_imageForIconOpt, "imageForIcon:options");
        o_cachedForIcon       = (FnIcon)TBHook(cache, @"cachedImageForIcon:", (IMP)tb_cachedForIcon, "cachedImageForIcon");
        o_realForIconOpt      = (FnIconOpt)TBHook(cache, @"realImageForIcon:options:", (IMP)tb_realForIconOpt, "realImageForIcon:options");
        o_unmaskedForIcon     = (FnIcon)TBHook(cache, @"unmaskedImageForIcon:", (IMP)tb_unmaskedForIcon, "unmaskedImageForIcon");
        o_unmaskedForIconOpt  = (FnIconOpt)TBHook(cache, @"unmaskedImageForIcon:options:", (IMP)tb_unmaskedForIconOpt, "unmaskedImageForIcon:options");
        o_cacheImageForIcon   = (FnImageForIcon)TBHook(cache, @"cacheImage:forIcon:", (IMP)tb_cacheImageForIcon, "cacheImage:forIcon");
    }
    if (icon && !gDoneGen) {
        gDoneGen = YES;
        o_generateIconImageWithInfo = (FnGen)TBHook(icon, @"generateIconImageWithInfo:", (IMP)tb_generateIconImageWithInfo, "generateIconImageWithInfo");
    }
}

#pragma mark - 刷新

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
