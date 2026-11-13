// ThemeBoardEngine v0.2 — 按 iOS 17.2 真实私有头文件重写
// 依据：headers/17.2/{SBHIconImageCache,SBIcon,SBLeafIcon,SBApplicationIcon,SBHIconManager}.h
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>   // 0.18.18：CATransaction
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <ImageIO/ImageIO.h>
#import <notify.h>
#import <dlfcn.h>
#include <stdlib.h>
#include <string.h>

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

static BOOL gIsPrimary = NO;      // 只有 SpringBoard 类进程写日志文件，避免多进程互相咬行
static NSHashTable *gSeenIconViews = nil;          // 0.18.20：登记见过的 SBIconView（弱引用）
static UIImage *TBThemedForIconObject(id icon);    // 0.18.20：前置声明（定义在后面）
static dispatch_queue_t gLogQueue;
static NSHashTable *gCaches;   // 缓存对象弱引用；批次快照持有存活对象
static NSLock *gLock;

static NSUInteger gServe;
static __thread BOOL gTBSettingsNativeIcon;
static UIImage *TBThemedIconLike(UIImage *orig, NSString *bid);

#import "TBRenderState.h"

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
static id TBPref(NSString *key);  // 文件日志开关在 TBLog 前使用
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

    // 文件日志只在用户打开「写日志」时落盘；系统控制台始终保留诊断输出。
    id enabled = TBPref(@"LogEnabled");
    if (![enabled boolValue]) return;
    static int sPerProcLines = 0;
    if (sPerProcLines >= 2000) return;
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

/// 同一 key 只记一次（启动时上百个图标会把日志配额吃光，导致后面的事件记不上）
static void TBLogOnce(NSString *key, NSString *fmt, ...) {
    static NSMutableSet *seen = nil;
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; lock = [[NSLock alloc] init]; });
    if (!key.length) return;
    [lock lock];
    BOOL first = ![seen containsObject:key];
    if (first && seen.count < 2000) [seen addObject:key];
    [lock unlock];
    if (!first) return;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    TBLog(@"%@", body);
}

#import "TBLiveIconDiagnostics.h"

#pragma mark - 设置 / 索引

static id TBPref(NSString *key) {
    // Rendering reads only the published generation (or an explicit candidate).
    // Disk preferences may already describe the next theme while it is prepared.
    TB_RENDER_SCOPE();
    return TBCurrentRenderState()->preferences[key];
}
static BOOL TBSafeMode(void) {
    id v = TBPref(@"SafeMode");
    return v ? [v boolValue] : NO;
}

static BOOL TBEnabled(void) { id v = TBPref(kEnabled); return v ? [v boolValue] : YES; }
/// 桌面相关位置不再使用分项偏好，由引擎总开关和安全模式控制。
static BOOL TBApplyIconForDesktop(void) {
    return YES;   // ★ 1.45：生效范围 UI 已删除 → 恒开（不再读 ApplyDock/Folder/Switcher）
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

static void TBLoadBundleResources(NSString *themeDir);

/// 取当前主题的 Bundles 资源表。
/// 关键：**没有主题时必须清空** —— 之前只在有主题时重建，切回默认后表里还留着
/// 上一个主题的素材，于是"主题没有 ClockIconBackgroundSquare"永远判成有 → 时钟残留。
static NSMutableDictionary *TBThemeBundleRes(void) {
    TB_RENDER_SCOPE();
    NSString *theme = TBActiveTheme();
    NSString *dir = theme.length ? TBThemeDir(theme) : nil;
    if (!dir) {
        gBundleRes = nil;
        gBundleResTheme = nil;
        return nil;
    }
    TBLoadBundleResources(dir);
    return gBundleRes;
}

static void TBLoadBundleResources(NSString *themeDir) {
    TB_RENDER_SCOPE();
    // 之前只要建过一次就永不重建 —— 换主题后会一直用旧主题的资源表，
    // 导致「主题无此图」的假阴性（时钟底图就是这么丢的）。改为按主题目录缓存。
    if (gBundleRes && gBundleResTheme && [gBundleResTheme isEqualToString:themeDir]) return;
    gBundleRes = [NSMutableDictionary dictionary];
    gBundleResTheme = themeDir ?: @"";
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

/// 时钟底图这类素材自带「透明圆角」，直接交给系统会在四角透出壁纸。
/// 这里把透明像素用表盘底色填满（圆角交给图标遮罩去切）。
static UIImage *TBResourceImage(NSString *name);
static UIImage *TBMatchSystemGeometry(UIImage *img, UIImage *sys);
static UIImage *TBImageForBundle(NSString *bid);      // 前置：时钟判定要用
static UIImage *TBClockRoundedFace(UIImage *img);
static UIImage *TBClockMaterialFace(UIView *v);
static void TBClockClearMappedContents(UIView *v, BOOL clearLayer);
static void TBClockInvalidateCache(void);
static void TBRefreshDynamicIconViewsNow(void);
static UIImage *TBKeyOutCornerColor(UIImage *img);

/// 素材是否带透明像素（粗略判断：抽样看有没有 alpha 明显偏低的像素）
static BOOL TBImageHasTransparency(CGImageRef cg) {
    if (!cg) return YES;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (w < 2 || h < 2) return YES;
    enum { N = 48 };
    unsigned char buf[N * N * 4];
    memset(buf, 0, sizeof(buf));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, N, N, 8, N * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c) return YES;
    CGContextDrawImage(c, CGRectMake(0, 0, N, N), cg);
    CGContextRelease(c);
    for (int i = 0; i < N * N; i++) if (buf[i * 4 + 3] < 200) return YES;
    return NO;
}

/// 完全没透明的素材 → 把四角颜色当背景抠掉（作者导出时忘了去白底）
static UIImage *TBKeyOutCornerColor(UIImage *img) {
    if (!img || !img.CGImage) return img;
    if (TBImageHasTransparency(img.CGImage)) return img;   // 已有透明通道，不动
    size_t w = CGImageGetWidth(img.CGImage), h = CGImageGetHeight(img.CGImage);
    if (w < 4 || h < 4 || w * h > 8 * 1024 * 1024) return img;
    size_t bytes = w * h * 4;
    unsigned char *buf = malloc(bytes);
    if (!buf) return img;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c) { free(buf); return img; }
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), img.CGImage);
    CGContextRelease(c);

    // 四角颜色
    long sr = 0, sg = 0, sb = 0;
    size_t corners[4] = {0, (w - 1) * 4, (h - 1) * w * 4, ((h - 1) * w + w - 1) * 4};
    for (int i = 0; i < 4; i++) { sr += buf[corners[i]]; sg += buf[corners[i] + 1]; sb += buf[corners[i] + 2]; }
    int cr = (int)(sr / 4), cg2 = (int)(sg / 4), cb = (int)(sb / 4);
    const int tol = 26;
    for (size_t i = 0; i < w * h; i++) {
        unsigned char *px = buf + i * 4;
        if (abs((int)px[0] - cr) < tol && abs((int)px[1] - cg2) < tol && abs((int)px[2] - cb) < tol) {
            px[0] = px[1] = px[2] = 0;
            px[3] = 0;
        }
    }
    CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, buf, bytes, NULL);
    CGImageRef outCg = prov ? CGImageCreate(w, h, 8, 32, w * 4, CGColorSpaceCreateDeviceRGB(),
                                            kCGImageAlphaLast | kCGBitmapByteOrderDefault,
                                            prov, NULL, false, kCGRenderingIntentDefault) : NULL;
    if (prov) CGDataProviderRelease(prov);
    if (!outCg) { free(buf); return img; }
    UIImage *out = [UIImage imageWithCGImage:outCg];
    CGImageRelease(outCg);
    TBLogOnce(@"keyout", @"指针素材无透明通道，已按四角颜色抠底（rgb %d,%d,%d）", cr, cg2, cb);
    return out ?: img;
}

/// 把主题素材统一到「系统原本那张图」的尺寸与 scale。
/// 否则素材点数（800pt）与系统（180pt）不一致，系统会放大铺开 → 表盘看着歪掉/花纹不对。
static UIImage *TBMatchSystemGeometry(UIImage *img, UIImage *sys) {
    if (!img) return img;
    if (!sys || sys.size.width < 2 || sys.size.height < 2) return img;
    CGSize want = sys.size;
    CGFloat scale = sys.scale > 0 ? sys.scale : 3.0;
    if (fabs(img.size.width - want.width) < 1.0 && fabs(img.size.height - want.height) < 1.0) return img;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:want format:fmt];
    UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, want.width, want.height)];
    }];
    TBLogOnce(@"facescale", @"表盘几何归一：素材 %.0fpt scale=%.1f → 系统 %.0fpt scale=%.1f",
              img.size.width, img.scale, want.width, scale);
    return out ?: img;
}

/// 玻璃素材缓存（主体高度透明 = 玻璃层）
/// 主题里是否有同名资源（表盘/指针/文件夹底等）
static UIImage *TBResourceImage(NSString *name) {
    TB_RENDER_SCOPE();
    if (gTBSettingsNativeIcon) return nil;
    if (!name.length || TBSafeMode() || !TBEnabled()) return nil;

    // 同一主题同一素材只解码一次（原来每次取图都重新读盘 + 解码 PNG）
    NSString *themeKey = TBActiveTheme() ?: @"";
    if (![themeKey isEqualToString:gResTheme ?: @""]) {
        [gResCache removeAllObjects];
        gResTheme = [themeKey copy];
    }
    NSString *ck = [themeKey stringByAppendingFormat:@"|%@", name];
    id cached = gResCache[ck];
    if (cached) return (cached == [NSNull null]) ? nil : cached;

    [gLock lock];
    TBLoadIndex();
    NSString *dir = nil;
    {
        NSString *theme = TBActiveTheme();
        dir = theme.length ? TBThemeDir(theme) : nil;
    }
    NSMutableDictionary *res = TBThemeBundleRes();   // 无主题 → 清空并返回 nil
    [gLock unlock];
    if (!res.count) { gResCache[ck] = [NSNull null]; return nil; }

    NSString *key = name.lastPathComponent.lowercaseString;
    NSString *path = res[key];
    if ([key hasPrefix:@"clockicon"]) {
        TBLogOnce([@"clocksrc|" stringByAppendingString:(TBActiveTheme() ?: @"")],
                  @"时钟素材来源[%@] %@ → %@",
                  TBActiveTheme() ?: @"?", key,
                  path ? [path stringByReplacingOccurrencesOfString:dir ?: @"" withString:@""] : @"(无)");
    }
    if (!path) {
        NSString *base = [key stringByDeletingPathExtension];
        if ([base hasSuffix:@"@2x"] || [base hasSuffix:@"@3x"])
            base = [base substringToIndex:base.length - 3];
        path = res[base];
    }
    // 必须用 init 方法：imageWithContentsOfFile: 已被本引擎 hook，
    // 在此调用会形成无限递归（栈溢出 → SpringBoard 崩溃循环）。
    if (!path) { gResCache[ck] = [NSNull null]; return nil; }
    UIImage *img = [[UIImage alloc] initWithContentsOfFile:path];
    gResCache[ck] = img ?: (id)[NSNull null];
    return img;
}

static void TBLoadIndex(void) {
    TB_RENDER_SCOPE();
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
/// gFitCache 在文件前段已声明为 NSMutableDictionary<NSString *, UIImage *>，此处不再重复声明。
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

/// 日历 / 时钟这类动态图标：在主题底图上重绘实时内容
static UIImage *TBDynamicIcon(UIImage *base, NSString *bid) {
    // 主题图仅作为背景底图，日期/指针由系统动态绘制
    // 因此这里直接返回底图，不做任何重绘
    return base;
}

static BOOL TBIsDynamicBID(NSString *bid);
static NSString *TBDynamicResourcePath(NSString *bid);
static UIImage *TBCalendarBackgroundForInfo(TBInfo info);
static UIImage *TBCalendarTextOverlay(UIImage *native, TBInfo info);
// Only suppress nested native-generation calls on this thread. The provider is
// also called by background cache workers; they must not bypass theme composition
// merely because the main thread is currently retrieving its native date image.
static __thread BOOL gCalendarProviderDepth;

/// 图标中央偏下区域是否已经有内容（主题自己画好了日期/数字）
/// 日期区指标：*ink 返回"墨"占比，*op 返回不透明占比（用来判断主题图标是否已画日期）
static BOOL TBImageDateAreaMetrics(UIImage *img, CGFloat *ink, CGFloat *op) {
    if (ink) *ink = 0; if (op) *op = 0;
    if (!img) return NO;
    if (!img) return NO;
    const size_t W = 64, H = 64;
    unsigned char *buf = calloc(W * H * 4, 1);
    if (!buf) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NO; }
    UIGraphicsPushContext(ctx);
    [img drawInRect:CGRectMake(0, 0, W, H)];
    UIGraphicsPopContext();
    CGContextRelease(ctx);

    NSInteger dark = 0, total = 0, opaque = 0;
    for (size_t y = (size_t)(H * 0.30); y < (size_t)(H * 0.85); y++) {
        for (size_t x = (size_t)(W * 0.25); x < (size_t)(W * 0.75); x++) {
            unsigned char *p = buf + (y * W + x) * 4;
            if (p[3] < 40) continue;
            CGFloat luma = 0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2];
            total++;
            if (p[3] > 200) opaque++;
            if (luma < 110) dark++;
        }
    }
    free(buf);
    if (total < 10) return NO;
    CGFloat inkPct = dark * 100.0 / total;
    CGFloat opPct = opaque * 100.0 / total;
    if (ink) *ink = inkPct;
    if (op) *op = opPct;
    // 半透明（玻璃）底图不算"已画日期"：它没有日期可看，必须自己写上去
    if (opPct < 80) return NO;
    return inkPct > 3;
}

/// 日历合成（SnowBoard 同款）：主题底图 + 红色星期 + 黑色日期
/// 主题给的 com.apple.mobilecal.png 是空白日历底图，日期必须自己画上去
static UIImage *TBCalendarCompositeImage(UIImage *bg) {
    if (!bg) return nil;
    CGFloat w = bg.size.width > 1 ? bg.size.width : 180.0;
    CGFloat scale = bg.scale > 0 ? bg.scale : 3.0;

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDate *now = [NSDate date];
    NSDateComponents *comp = [cal components:(NSCalendarUnitDay | NSCalendarUnitWeekday) fromDate:now];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.locale = [NSLocale currentLocale];
    // 星期：短格式（周三 / Wed）
    // 用完整的「星期X」而不是缩写（周一）
    NSArray *weekdaySymbols = df.weekdaySymbols;
    NSString *weekText = @"";
    NSInteger wd = comp.weekday - 1;
    if (wd >= 0 && wd < (NSInteger)weekdaySymbols.count) weekText = weekdaySymbols[wd];
    NSString *dayText = [NSString stringWithFormat:@"%ld", (long)comp.day];

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(w, w) format:fmt];
    UIImage *out = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [bg drawInRect:CGRectMake(0, 0, w, w)];

        // 星期（红），字号 = 宽 × 0.1667
        UIFont *weekFont = [UIFont systemFontOfSize:w * 0.190000 weight:UIFontWeightSemibold];
        UIColor *red = [UIColor colorWithRed:1.0 green:0.23137 blue:0.18824 alpha:1.0];
        NSMutableParagraphStyle *center = [[NSMutableParagraphStyle alloc] init];
        center.alignment = NSTextAlignmentCenter;
        NSDictionary *weekAttr = @{
            NSFontAttributeName: weekFont,
            NSForegroundColorAttributeName: red,
            NSParagraphStyleAttributeName: center,
        };
        CGFloat weekH = weekFont.lineHeight;
        [weekText drawInRect:CGRectMake(0, w * 0.115, w, weekH) withAttributes:weekAttr];

        // 日期数字（黑），字号 = 宽 × 0.6583
        UIFont *numFont = [UIFont systemFontOfSize:w * 0.658333 weight:UIFontWeightRegular];
        NSDictionary *numAttr = @{
            NSFontAttributeName: numFont,
            NSForegroundColorAttributeName: [UIColor blackColor],
            NSParagraphStyleAttributeName: center,
        };
        CGFloat numH = numFont.lineHeight;
        [dayText drawInRect:CGRectMake(0, w * 0.30, w, numH) withAttributes:numAttr];
    }];
    return out;
}

/// 取主题图：锁内只做字典查找，读盘/绘制都在锁外，避免 SpringBoard 被拖死
/// 图标圆角遮罩：系统图标是超椭圆遮罩（不是普通圆角矩形）。主题里方角素材
/// （WPS / 设置 / 相机 / 备忘录这些）不打遮罩就是方块，这里统一按超椭圆裁。
static UIImage *TBMaskWithSystemShape(UIImage *art);
static UIImage *TBMaskWithThemeMask(UIImage *art, UIImage *mask);      // 用主题自带遮罩图裁
static UIImage *TBApplyIconShape(UIImage *img, BOOL skipIfRounded);    // 三种模式的统一入口

typedef id (*ContentsImgFn)(id, SEL);
static ContentsImgFn o_contentsImageLive, o_squareContentsImageLive;

typedef struct { double w, h, scale, ratio; } TBClockInfo;   // SBIconImageInfo 的等价布局
typedef TBClockInfo (*TBInfoGetFn)(id, SEL);
typedef void (*TBInfoSetFn)(id, SEL, TBClockInfo);


// 完全照 SnowBoard：roundedRectImageFromImage:withRadius:withCrop:YES
//   radius = (CustomCornerRadius / 60.0) * 图片宽度；上限 = 宽度的一半
//   SB 的 CustomCornerRadius 默认值 = 60 × 22.37% ≈ 13.42
// 我们自己那套（SB 的固定半径公式会"裁多了"）：
//   ① 已学到系统遮罩形状 → 按系统形状裁（最准）
//   ② 素材四角本来就透明（作者已做圆角）→ 跳过裁剪
//   ③ 兜底：按 22.37% 圆角裁
static BOOL TBIconArtAlreadyRounded(UIImage *img) {
    if (!img || !img.CGImage) return NO;
    const size_t W = 16, H = 16;
    unsigned char *buf = calloc(W * H * 4, 1);
    if (!buf) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NO; }
    UIGraphicsPushContext(ctx);
    [img drawInRect:CGRectMake(0, 0, W, H)];
    UIGraphicsPopContext();
    CGContextRelease(ctx);
    BOOL rounded = (buf[3] <= 24) && (buf[(W - 1) * 4 + 3] <= 24) &&
                   (buf[(H - 1) * W * 4 + 3] <= 24) &&
                   (buf[((H - 1) * W + W - 1) * 4 + 3] <= 24);
    free(buf);
    return rounded;
}

// ---- 图标形状：三种模式（优先级从高到低）----
//   ① UseThemeIconMask   主题自带遮罩图 IconMask.png 当 alpha 遮罩（作者明确要的形状）
//   ② MaskCornerRadiusOn 按 SnowBoard 的 CustomCornerRadius 算法裁圆角
//   ③ 现状              gSystemMaskTemplate → 已是圆角素材就跳过 → MIN(宽,高)×22.37% 兜底
static BOOL TBUseThemeIconMask(void) {
    id v = TBPref(@"UseThemeIconMask");
    return v ? [v boolValue] : NO;
}
static BOOL TBMaskCornerRadiusOn(void) {
    id v = TBPref(@"MaskCornerRadiusOn");
    return v ? [v boolValue] : NO;
}
/// AnemoneEffects：玻璃叠加层 / 图标阴影（都必须主题里真的有素材才生效）
static BOOL TBUseThemeIconOverlay(void) {
    id v = TBPref(@"UseThemeIconOverlay");
    return v ? [v boolValue] : NO;
}
static BOOL TBUseThemeIconShadow(void) {
    id v = TBPref(@"UseThemeIconShadow");
    return v ? [v boolValue] : NO;
}
/// CustomCornerRadius：SB 默认 60 × 22.37% ≈ 13.42（60 == 半径等于半宽）
static double TBMaskCornerRadius(void) {
    id v = TBPref(@"MaskCornerRadius");
    double r = 13.42;
    if ([v respondsToSelector:@selector(doubleValue)]) {
        double d = [v doubleValue];
        if (d == d && d >= 0.0) r = d;      // NaN / 负数 → 回到默认
    }
    return r;
}

/// 在一个目录里按名字找文件（大小写不敏感，命中第一个）
static NSString *TBFindFileCI(NSString *dir, NSString *name) {
    if (!dir.length || !name.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([item caseInsensitiveCompare:name] != NSOrderedSame) continue;
        NSString *p = [dir stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && !isDir) return p;
    }
    return nil;
}

/// 逐段解析相对目录（每段都大小写不敏感），任一段不存在就返回 nil
static NSString *TBResolveDirCI(NSString *base, NSString *rel) {
    if (!base.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *cur = base;
    for (NSString *comp in [rel componentsSeparatedByString:@"/"]) {
        if (!comp.length) continue;
        NSString *next = nil;
        for (NSString *item in [fm contentsOfDirectoryAtPath:cur error:NULL]) {
            NSString *full = [cur stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir &&
                [item caseInsensitiveCompare:comp] == NSOrderedSame) { next = full; break; }
        }
        if (!next) return nil;
        cur = next;
    }
    return cur;
}

/// 在目录里找「名字以 prefix 开头、以 .png 结尾」的文件（大小写不敏感），
/// 优先 @3x → @2x → 其它（~iphone / ~ipad 之类的后缀都照收）
static NSString *TBFindBestScaledPNG(NSString *dir, NSString *prefix) {
    if (!dir.length || !prefix.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *lp = prefix.lowercaseString;
    NSString *best = nil;
    NSInteger bestRank = -1;
    for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        NSString *li = item.lowercaseString;
        if (![li hasPrefix:lp] || ![li hasSuffix:@".png"]) continue;
        NSString *p = [dir stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:p isDirectory:&isDir] || isDir) continue;
        NSInteger rank = [li rangeOfString:@"@3x"].location != NSNotFound ? 30
                       : ([li rangeOfString:@"@2x"].location != NSNotFound ? 20 : 10);
        if (rank > bestRank) { bestRank = rank; best = p; }
    }
    return best;
}

/// 遮罩图 alpha 分布统计（全部 0~1）：
///   p90 = 90 分位；solid = alpha>200 的占比；cov = alpha>=18 的占比（二值化后会保留的面积）
///   core = alpha >= 峰值一半 的占比（"核心"面积）
/// 用来区分「很淡的玻璃/渐变遮罩」和「真实形状遮罩」（0.15.47 一刀切二值化把两类都搞坏了）
typedef struct { double p90, solid, cov, core; } TBMaskStats;

static TBMaskStats TBMaskAlphaStats(UIImage *mask) {
    TBMaskStats st = { 1.0, 1.0, 1.0, 1.0 };
    if (!mask) return st;
    const size_t W = 64, H = 64;
    unsigned char *buf = calloc(W * H * 4, 1);
    if (!buf) return st;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return st; }
    UIGraphicsPushContext(ctx);
    [mask drawInRect:CGRectMake(0, 0, W, H)];
    UIGraphicsPopContext();
    CGContextRelease(ctx);

    int hist[256] = {0};
    const int total = (int)(W * H);
    int solid = 0, cov = 0, peak = 0;
    for (int i = 0; i < total; i++) {
        unsigned char a = buf[i * 4 + 3];
        hist[a]++;
        if (a > peak) peak = a;
        if (a > 200) solid++;
        if (a >= 18) cov++;
    }
    int core = 0;
    for (int a = peak / 2; a < 256; a++) core += hist[a];
    int acc = 0, p90 = 255;
    for (int a = 0; a < 256; a++) {
        acc += hist[a];
        if (acc * 10 >= total * 9) { p90 = a; break; }
    }
    free(buf);
    st.p90   = p90 / 255.0;
    st.solid = (double)solid / total;
    st.cov   = (double)cov / total;
    st.core  = (double)core / total;
    return st;
}

/// 「很淡」= 整体 alpha 偏低（p90 < 0.45）或几乎没有实心区（实心占比 < 0.5）
/// 「淡玻璃 / 渐变玻璃层」——**不是形状遮罩**，应该当叠加层用。
/// 比 faint 更严一点，避免把"形状只占画布一小块"的真形状遮罩误判：
///   p90 < 0.45，或者（几乎没有实心区 且 p90 也不高）
static BOOL TBMaskStatsLookGlass(TBMaskStats st) {
    return (st.p90 < 0.45) || (st.solid < 0.15 && st.p90 < 0.75);
}

/// 主题自带遮罩图（大小写不敏感，按顺序命中第一个）。
/// 前三个是经典 Anemone / WinterBoard 的遮罩命名（真实主题里就是这个），
/// 我们自己的 IconMask.png 系列保留为最低优先级兜底：
///   ① IconBundles/Icon.png（含小写 icon.png）
///   ② 主题根目录 icon.png
///   ③ Bundles/com.apple.mobileicons.framework/AppIconMask*.png
///      （同目录还有 TableIconMask / SpotlightAppIconMask，这里只认 AppIconMask）
///   ④ IconMask.png → IconMask@3x.png → IconMask@2x.png
///      → IconBundles/IconMask.png → Bundles/com.apple.springboard/IconMask.png
/// 结果按主题名缓存：同一主题只扫一次盘，换主题或设置变更自动失效
/// （TBReload 里会清这个缓存，这样 App 导入遮罩后不用重启就生效）。

/// 判定一张遮罩图到底是「形状」还是「淡玻璃层」：
///   淡玻璃/渐变玻璃 → 返回 nil（不当形状用），同时把它记到 gMaskGlassImg 给叠加层用；
///   真实形状（硬边 / 柔边都算）→ 原样返回。
static UIImage *TBGlassMaskOrShape(UIImage *img, NSString *key, NSString *label) {
    TB_RENDER_SCOPE();
    gMaskGlassImg = nil;
    gMaskGlassKey = nil;
    if (!img) return nil;
    TBMaskStats st = TBMaskAlphaStats(img);
    if (TBMaskStatsLookGlass(st)) {
        gMaskGlassImg = img;
        gMaskGlassKey = key;
        TBLogOnce([@"glassmask|" stringByAppendingString:key],
                  @"遮罩：%@ 偏淡/是渐变玻璃层（p90=%.2f 实心占比=%.2f 覆盖=%.2f）"
                  @"→ 不当形状遮罩用，改按玻璃叠加层处理（形状回落到自定义圆角 / 系统形状）",
                  label, st.p90, st.solid, st.cov);
        return nil;
    }
    TBLogOnce([@"shapemask|" stringByAppendingString:key],
              @"遮罩：%@ 用作形状遮罩（p90=%.2f 实心占比=%.2f 覆盖=%.2f 核心=%.2f）",
              label, st.p90, st.solid, st.cov, st.core);
    return img;
}

/// 淡玻璃遮罩改当玻璃叠加层：画在图标之上，alpha 乘 GlassOverlayStrength
static UIImage *TBThemeGlassFromFaintMask(void) {
    TB_RENDER_SCOPE();
    if (TBSafeMode() || !TBEnabled()) return nil;
    if (!TBUseThemeIconMask()) return nil;   // 只有在「遮罩」模式 / 素材包遮罩开关打开时才用
    if (!gMaskGlassImg || !gMaskGlassKey || !gMaskThemeKey) return nil;
    if (![gMaskGlassKey isEqualToString:gMaskThemeKey]) return nil;   // 缓存对不上就不冒险
    return gMaskGlassImg;
}

static UIImage *TBThemeMaskImage(void) {
    TB_RENDER_SCOPE();
    if (TBSafeMode() || !TBEnabled()) return nil;
    // 素材包（独立素材）优先：CustomMaskPath
    id cmp = TBPref(@"CustomMaskPath");
    if ([cmp isKindOfClass:[NSString class]] && [(NSString *)cmp length]) {
        NSString *k = [@"cmask:" stringByAppendingString:(NSString *)cmp];
        if (gMaskThemeChecked && gMaskThemeKey && [gMaskThemeKey isEqualToString:k]) return gMaskThemeImg;
        gMaskThemeKey = k; gMaskThemeChecked = YES;
        gMaskThemeImg = [[UIImage alloc] initWithContentsOfFile:(NSString *)cmp];
        TBLogOnce(k, @"遮罩：用独立素材 %@（%.0fx%.0f）", [(NSString *)cmp lastPathComponent],
                  gMaskThemeImg.size.width, gMaskThemeImg.size.height);
        gMaskThemeImg = TBGlassMaskOrShape(gMaskThemeImg, k, [(NSString *)cmp lastPathComponent]);
        return gMaskThemeImg;
    }
    NSString *theme = TBActiveTheme();
    if (!theme.length) return nil;
    if (gMaskThemeChecked && gMaskThemeKey && [gMaskThemeKey isEqualToString:theme]) return gMaskThemeImg;
    gMaskThemeKey = theme;
    gMaskThemeChecked = YES;
    gMaskThemeImg = nil;

    NSString *dir = TBThemeDir(theme);
    if (!dir.length) return nil;

    NSString *path = nil;
    NSString *iconBundles = TBResolveDirCI(dir, @"IconBundles");
    if (iconBundles.length) path = TBFindFileCI(iconBundles, @"Icon.png");        // ①
    if (!path) path = TBFindFileCI(dir, @"Icon.png");                             // ②
    if (!path) {                                                                  // ③
        NSString *fw = TBResolveDirCI(dir, @"Bundles/com.apple.mobileicons.framework");
        if (fw.length) path = TBFindBestScaledPNG(fw, @"AppIconMask");
    }
    if (!path) {                                                                  // ④ 旧写法兜底
        NSArray *cands = @[ @[@"",                             @"IconMask.png"],
                            @[@"",                             @"IconMask@3x.png"],
                            @[@"",                             @"IconMask@2x.png"],
                            @[@"IconBundles",                  @"IconMask.png"],
                            @[@"Bundles/com.apple.springboard", @"IconMask.png"] ];
        for (NSArray *c in cands) {
            NSString *sub = c[0], *name = c[1];
            NSString *d = sub.length ? TBResolveDirCI(dir, sub) : dir;
            if (!d.length) continue;
            NSString *p = TBFindFileCI(d, name);
            if (p) { path = p; break; }
        }
    }

    if (path.length) {
        // 必须用 init：imageWithContentsOfFile: 已被本引擎 hook（递归会爆栈）
        UIImage *img = [[UIImage alloc] initWithContentsOfFile:path];
        if (img) {
            TBLogOnce([@"thememask|" stringByAppendingString:theme],
                      @"图标形状：用主题遮罩图 %@（%.0fx%.0f pt）",
                      [path stringByReplacingOccurrencesOfString:dir withString:@""],
                      img.size.width, img.size.height);
            gMaskThemeImg = TBGlassMaskOrShape(img, theme,
                                               [path stringByReplacingOccurrencesOfString:dir withString:@""]);
            return gMaskThemeImg;
        }
    }
    TBLogOnce([@"thememask|none|" stringByAppendingString:theme],
              @"图标形状：主题里没有遮罩图（IconBundles/Icon.png、icon.png、AppIconMask*、IconMask.png 都没有），落到自定义圆角 / 系统形状");
    return nil;
}

/// 用主题遮罩图裁素材：遮罩图缩放到素材尺寸 → DestinationIn 只留遮罩不透明处
/// （和 TBMaskWithSystemShape 同一套做法，只是把"系统遮罩模板"换成"主题遮罩图"）
/// 遮罩图只取「形状」：把很淡的玻璃遮罩（alpha 0.1~0.5）二值化成 0/1。
/// 不处理的话 DestinationIn 会按 alpha 相乘 → 整个图标被压淡，就是用户说的「看不清」。
static UIImage *TBMaskShapeOnly(UIImage *mask) {
    if (!mask || !mask.CGImage) return mask;
    const size_t W = CGImageGetWidth(mask.CGImage), H = CGImageGetHeight(mask.CGImage);
    if (W < 8 || H < 8 || W > 1600 || H > 1600) return mask;
    size_t bpr = W * 4;
    unsigned char *buf = calloc(H * bpr, 1);
    if (!buf) return mask;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, bpr, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return mask; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), mask.CGImage);

    // ---- 先统计 alpha 分布，决定"要不要归一化" ----
    // 0.15.47 一刀切二值化把两类都搞坏了：
    //   ① 真实形状/软边遮罩（「虚化蒙版」）被压成满幅实心方块 → 看起来"没生效/形状坏了"
    //   ② 渐变玻璃遮罩（「透明遮罩」，下半部更淡）下半部被判成透明 → 图标下半截消失
    // 现在：只有"很淡的玻璃遮罩"才归一化；有大幅柔和渐变的（虚化）原样保留柔边。
    int hist[256] = {0};
    const size_t total = W * H;
    size_t solid = 0, cov = 0;
    int peak = 0;
    for (size_t i = 0; i < total; i++) {
        unsigned char a = buf[i * 4 + 3];
        hist[a]++;
        if (a > peak) peak = a;
        if (a > 200) solid++;
        if (a >= 18) cov++;
    }
    size_t core = 0;
    for (int a = peak / 2; a < 256; a++) core += hist[a];
    size_t acc = 0; int p90 = 255;
    for (int a = 0; a < 256; a++) { acc += hist[a]; if (acc * 10 >= total * 9) { p90 = a; break; } }
    double dp90 = p90 / 255.0, dsolid = (double)solid / total, dcov = (double)cov / total;
    BOOL faint = (dp90 < 0.45) || (dsolid < 0.5);
    // 二值化会大幅放大覆盖面积 → 说明这张图靠"大范围柔和渐变"定义外形（虚化/模糊），
    // 二值化会把柔边吃掉 → 原样返回，保留它自己的圆角与柔边。
    BOOL wideGradient = ((dcov - (double)core / total) > 0.25);
    if (!faint || wideGradient) {
        TBLogOnce([@"maskkeep|" stringByAppendingFormat:@"%.2f|%.2f|%d", dp90, dsolid, (int)wideGradient],
                  @"遮罩：原样使用（不当形状二值化）p90=%.2f 实心占比=%.2f 覆盖=%.2f 核心=%.2f → %@",
                  dp90, dsolid, dcov, (double)core / total,
                  (!faint ? @"真实形状/软边遮罩，保留它自己的圆角与柔边"
                          : @"有大幅柔和渐变（虚化/模糊遮罩），保留柔边"));
        CGContextRelease(ctx); free(buf);
        return mask;
    }
    TBLogOnce([@"maskbin|" stringByAppendingFormat:@"%.2f", dp90],
              @"遮罩：很淡的玻璃遮罩 → 二值化成形状 p90=%.2f 实心占比=%.2f 覆盖=%.2f",
              dp90, dsolid, dcov);
    for (size_t i = 0; i < total; i++) {
        unsigned char a = buf[i * 4 + 3], na = 0;
        if (a >= 18) na = 255;                            // ≥0.07 视为形状内部
        else if (a > 5) na = (unsigned char)((a - 5) * 255 / 13);   // 窄羽化
        buf[i * 4 + 0] = na; buf[i * 4 + 1] = na; buf[i * 4 + 2] = na;
        buf[i * 4 + 3] = na;
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx); free(buf);
    if (!out) return mask;
    UIImage *im = [UIImage imageWithCGImage:out scale:(mask.scale > 0.5 ? mask.scale : 3.0)
                                 orientation:mask.imageOrientation];
    CGImageRelease(out);
    return im ?: mask;
}

static UIImage *TBMaskWithThemeMask(UIImage *art, UIImage *mask) {
    if (!art || !mask) return art;
    mask = TBMaskShapeOnly(mask);                  // ★ 只取形状，避免把图标压淡
    CGSize pt = art.size;
    if (pt.width < 1 || pt.height < 1) return art;
    if (mask.size.width < 1 || mask.size.height < 1) return art;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = art.scale > 0.5 ? art.scale : 3.0;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:pt format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [art drawInRect:CGRectMake(0, 0, pt.width, pt.height)];
        [mask drawInRect:CGRectMake(0, 0, pt.width, pt.height)   // 按素材尺寸缩放遮罩图
               blendMode:kCGBlendModeDestinationIn alpha:1.0];
    }];
}

/// 按给定半径裁圆角（SB roundedRectImageFromImage:withRadius:withCrop:YES 同款）
static UIImage *TBRoundedCornerImage(UIImage *img, CGFloat radius) {
    CGSize pt = img.size;
    if (pt.width < 1 || pt.height < 1) return img;
    if (radius < 0) radius = 0;
    CGFloat maxR = pt.width / 2.0;
    if (radius > maxR) radius = maxR;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = img.scale > 0.5 ? img.scale : 3.0;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *rd = [[UIGraphicsImageRenderer alloc] initWithSize:pt format:fmt];
    return [rd imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, pt.width, pt.height)
                                                    cornerRadius:radius];
        [p addClip];
        [img drawInRect:CGRectMake(0, 0, pt.width, pt.height)];
    }];
}

/// 把「四角本来就透明的圆角素材」补成方角：用同行/同列最近的边缘像素颜色填四角。
/// 不补的话，素材自己的圆角永远盖过设置 —— 自定义圆角调小（更方）会完全看不出效果。
static UIImage *TBArtSquareFilled(UIImage *img) {
    TB_RENDER_SCOPE();
    if (!img || !img.CGImage) return img;
    // ★ 0.15.71 性能：补方角只是"用边缘颜色填四角"，不需要原分辨率。
    //   大图先降到 ~120px 再做逐像素填充（原来 180~540px 全分辨率跑两趟，
    //   换主题/改遮罩后回桌面要给上百个图标各做一次 → 明显掉帧）。
    {
        size_t w0 = CGImageGetWidth(img.CGImage);
        if (w0 > 120) {
            CGFloat ratio = 120.0 / (CGFloat)w0;
            CGSize small = CGSizeMake(round(img.size.width * ratio),
                                      round(img.size.height * ratio));
            UIGraphicsImageRendererFormat *f2 = [UIGraphicsImageRendererFormat defaultFormat];
            f2.scale = img.scale > 0.5 ? img.scale : 3.0;
            f2.opaque = NO;
            UIGraphicsImageRenderer *rd2 = [[UIGraphicsImageRenderer alloc] initWithSize:small format:f2];
            UIImage *sc = [rd2 imageWithActions:^(UIGraphicsImageRendererContext *c2) {
                [img drawInRect:CGRectMake(0, 0, small.width, small.height)];
            }];
            if (sc.CGImage) img = sc;
        }
    }
    const size_t W = CGImageGetWidth(img.CGImage), H = CGImageGetHeight(img.CGImage);
    if (W < 8 || H < 8 || W > 1400 || H > 1400) return img;
    UIImage *hit = nil;
    @synchronized ([UIImage class]) {
        if (!gSquareFillCache) gSquareFillCache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                                                                       valueOptions:0];
        hit = [gSquareFillCache objectForKey:img];
    }
    if (hit) return hit;

    const size_t bpr = W * 4;
    unsigned char *buf = calloc(H * bpr, 1);
    if (!buf) return img;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, bpr, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return img; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), img.CGImage);

    // 四角都不透明 → 本来就是方角素材，不用补
    if (buf[3] > 24 && buf[(W - 1) * 4 + 3] > 24 &&
        buf[(H - 1) * bpr + 3] > 24 && buf[(H - 1) * bpr + (W - 1) * 4 + 3] > 24) {
        CGContextRelease(ctx); free(buf);
        @synchronized ([UIImage class]) { [gSquareFillCache setObject:img forKey:img]; }
        return img;
    }

    int *xl = calloc(H, sizeof(int)), *xr = calloc(H, sizeof(int));
    int *yt = calloc(W, sizeof(int)), *yb = calloc(W, sizeof(int));
    if (!xl || !xr || !yt || !yb) { free(xl); free(xr); free(yt); free(yb); free(buf); CGContextRelease(ctx); return img; }
    for (size_t y = 0; y < H; y++) {
        xl[y] = -1; xr[y] = -1;
        for (size_t x = 0; x < W; x++) {
            if (buf[y * bpr + x * 4 + 3] > 24) { if (xl[y] < 0) xl[y] = (int)x; xr[y] = (int)x; }
        }
    }
    for (size_t x = 0; x < W; x++) {
        yt[x] = -1; yb[x] = -1;
        for (size_t y = 0; y < H; y++) {
            if (buf[y * bpr + x * 4 + 3] > 24) { if (yt[x] < 0) yt[x] = (int)y; yb[x] = (int)y; }
        }
    }
    for (size_t y = 0; y < H; y++) {
        if (xl[y] < 0) continue;
        for (size_t x = 0; x < W; x++) {
            unsigned char *d = &buf[y * bpr + x * 4];
            if (d[3] > 24) continue;
            const unsigned char *src = NULL;
            int hd = -1, vd = -1;
            if ((int)x < xl[y])      { hd = xl[y] - (int)x; src = &buf[y * bpr + (size_t)xl[y] * 4]; }
            else if ((int)x > xr[y]) { hd = (int)x - xr[y]; src = &buf[y * bpr + (size_t)xr[y] * 4]; }
            if (yt[x] >= 0 && (int)y < yt[x]) {
                int d2 = yt[x] - (int)y;
                if (hd < 0 || d2 < hd) { vd = d2; src = &buf[(size_t)yt[x] * bpr + x * 4]; }
            } else if (yb[x] >= 0 && (int)y > yb[x]) {
                int d2 = (int)y - yb[x];
                if (hd < 0 || d2 < hd) { vd = d2; src = &buf[(size_t)yb[x] * bpr + x * 4]; }
            }
            if (!src) continue;
            d[0] = src[0]; d[1] = src[1]; d[2] = src[2]; d[3] = 255;
        }
    }
    free(xl); free(xr); free(yt); free(yb);
    CGImageRef outRef = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    free(buf);
    if (!outRef) return img;
    UIImage *out = [UIImage imageWithCGImage:outRef scale:(img.scale > 0.5 ? img.scale : 3.0)
                                 orientation:img.imageOrientation];
    CGImageRelease(outRef);
    if (out) { @synchronized ([UIImage class]) { [gSquareFillCache setObject:out forKey:img]; } }
    return out ?: img;
}

/// 图标形状统一入口（图标与时钟表盘共用）：
///   ① 主题遮罩图（作者明确要的形状，这个模式下不做"已圆角就跳过"排查）
///   ② skipIfRounded：素材四角本来透明 → 直接返回，避免裁多
///   ③ MaskCornerRadiusOn：radius = (MaskCornerRadius / 60) × 宽度，上限 宽/2
///   ④ gSystemMaskTemplate：按系统遮罩形状裁（现状）
///   ⑤ 兜底 MIN(宽,高) × 0.2237（现状）
static UIImage *TBApplyIconShape(UIImage *img, BOOL skipIfRounded) {
    TB_RENDER_SCOPE();
    if (!img) return img;
    if (TBUseThemeIconMask()) {                       // ① 主题自带遮罩图
        UIImage *m = TBThemeMaskImage();
        if (m) return TBMaskWithThemeMask(img, m);
        // 主题里没有遮罩图 → 继续往下落到 ② / ③
    }
    CGSize pt = img.size;
    if (pt.width >= 1 && pt.height >= 1 && TBMaskCornerRadiusOn()) {  // ② 自定义圆角半径（用户显式选了就以它为准）
        CGFloat radius = (CGFloat)(TBMaskCornerRadius() / 60.0) * pt.width;
        UIImage *square = TBArtSquareFilled(img);      // 素材自带圆角 → 先补成方角，半径才看得出变化
        TBLogOnce([@"maskradius|" stringByAppendingFormat:@"%@", TBActiveTheme() ?: @""],
                  @"图标形状：自定义圆角 %.2f → radius %.2f（%.0fpt 宽）%@",
                  TBMaskCornerRadius(), radius, pt.width, (square == img ? @"" : @"（已补方角）"));
        return TBRoundedCornerImage(square, radius);
    }
    if (skipIfRounded && TBIconArtAlreadyRounded(img)) return img;    // ③ 已是圆角素材 → 不裁
    if (gSystemMaskTemplate) return TBMaskWithSystemShape(img);       // ④ 按系统形状裁（现状）
    if (pt.width < 16 || pt.height < 16) return img;                  // 现状：太小不动
    return TBRoundedCornerImage(img, MIN(pt.width, pt.height) * 0.2237);  // ⑤ 兜底（现状）
}

static UIImage *TBGlobalEffectImage(UIImage *src, NSString *bid);   // 前置：缓存写入端要用

static UIImage *TBIconRoundedImage(UIImage *img) {
    return TBApplyIconShape(img, YES);   // 图标：保留"已是圆角素材就跳过"保护
}

// ---- AnemoneEffects：玻璃叠加层 / 图标阴影 ----
//   AnemoneEffects/iPhoneOverlay@3x.png → @2x → 无后缀   叠在图标之上
//   AnemoneEffects/iPhoneShadow@3x.png  → @2x            垫在图标之下
// 只看这两个名字；icon_shortcut_mask 之类的专用遮罩不算，AnemoneEffects 也不当形状遮罩用。
// 结果按「主题名 + 名字」缓存，设置变更（TBReload）时清掉。
static UIImage *TBThemeFxImage(int slot, NSString *base) {
    TB_RENDER_SCOPE();
    if (TBSafeMode() || !TBEnabled()) return nil;
    // 素材包（独立素材）优先：CustomOverlayPath / CustomShadowPath
    id cp = TBPref(slot == 0 ? @"CustomOverlayPath" : @"CustomShadowPath");
    if ([cp isKindOfClass:[NSString class]] && [(NSString *)cp length]) {
        NSString *ck = [(slot == 0 ? @"ovl:" : @"shd:") stringByAppendingString:(NSString *)cp];
        if (gFxChecked[slot] && gFxKey[slot] && [gFxKey[slot] isEqualToString:ck]) return gFxImg[slot];
        gFxKey[slot] = ck; gFxChecked[slot] = YES;
        gFxImg[slot] = [[UIImage alloc] initWithContentsOfFile:(NSString *)cp];
        if (gFxImg[slot]) TBLogOnce(ck, @"特效：用独立素材 %@（%.0fx%.0f）", [(NSString *)cp lastPathComponent],
                                    gFxImg[slot].size.width, gFxImg[slot].size.height);
        return gFxImg[slot];
    }
    NSString *theme = TBActiveTheme();
    if (!theme.length) return nil;
    if (gFxChecked[slot] && gFxKey[slot] && [gFxKey[slot] isEqualToString:theme]) return gFxImg[slot];
    gFxKey[slot] = theme;
    gFxChecked[slot] = YES;
    gFxImg[slot] = nil;

    NSString *dir = TBThemeDir(theme);
    if (!dir.length) return nil;
    NSString *fx = TBResolveDirCI(dir, @"AnemoneEffects");
    if (!fx.length) return nil;
    NSArray *names = @[ [base stringByAppendingString:@"@3x.png"],
                        [base stringByAppendingString:@"@2x.png"],
                        [base stringByAppendingString:@".png"] ];
    for (NSString *n in names) {
        NSString *p = TBFindFileCI(fx, n);
        if (!p) continue;
        // 必须用 init：imageWithContentsOfFile: 已被本引擎 hook（递归会爆栈）
        UIImage *img = [[UIImage alloc] initWithContentsOfFile:p];
        if (!img) continue;
        gFxImg[slot] = img;
        TBLogOnce([@[@"overlay|", @"shadow|"][slot] stringByAppendingString:theme],
                  @"特效：用 %@（%.0fx%.0f pt）", n, img.size.width, img.size.height);
        return img;
    }
    return nil;
}
static UIImage *TBThemeOverlayImage(void) { return TBThemeFxImage(0, @"iPhoneOverlay"); }
static UIImage *TBThemeShadowImage(void)  { return TBThemeFxImage(1, @"iPhoneShadow"); }

/// 玻璃叠加层（iPhoneOverlay / 淡玻璃遮罩）强度：0 = 完全不画，1 = 原样叠加。
/// 0.15.48 默认 0.35 → 用户反馈「立体玻璃-遮罩B」「透明玻璃遮罩」都不明显了
/// （0.15.47 及以前是按 alpha 1.0 整张叠上去的）。0.15.49 默认回到 0.6，
/// 观感接近以前，同时保留 0~100% 可调（0 才是关闭）。
static double TBGlassOverlayStrength(void) {
    id v = TBPref(@"GlassOverlayStrength");
    double s = v ? [v doubleValue] : 0.6;
    if (!(s >= 0.0)) s = 0.0;
    if (s > 1.0) s = 1.0;
    return s;
}

/// 把 overlay 按图标的最终形状裁一刀：DestinationIn 取图标自身的 alpha。
/// 不裁的话，遮罩与玻璃层圆角不匹配时玻璃层会在边角溢出色块（"边角露出来"）。
/// iconRect = 图标在合成画布里的位置（有阴影时图标会缩小居中，这里要跟着走）。
static UIImage *TBMaskOverlayToIconAlpha(UIImage *overlay, UIImage *icon, CGRect iconRect) {
    if (!overlay || !icon) return overlay;
    CGSize pt = iconRect.size;
    if (pt.width < 1 || pt.height < 1) return overlay;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = icon.scale > 0.5 ? icon.scale : 3.0;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:pt format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGRect rect = CGRectMake(0, 0, pt.width, pt.height);
        [overlay drawInRect:rect];
        [icon drawInRect:rect blendMode:kCGBlendModeDestinationIn alpha:1.0];
    }];
}

/// 量出图里"有内容"的区域（单位坐标 0~1）。失败返回 NO。
/// 阴影素材自带很大边距（实测「立体玻璃-遮罩B」：画布 340×340，可见云团只占 48%×51%），
/// 不量的话把整张素材按图标 rect 画，云团只有图标宽度的 48%，全被图标盖住。
static BOOL TBImageContentBBox(UIImage *img, CGRect *out) {
    if (!img) return NO;
    const size_t W = 64, H = 64;
    unsigned char *buf = calloc(W * H * 4, 1);
    if (!buf) return NO;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(buf); return NO; }
    UIGraphicsPushContext(ctx);
    [img drawInRect:CGRectMake(0, 0, W, H)];
    UIGraphicsPopContext();
    CGContextRelease(ctx);

    int minx = (int)W, maxx = -1, miny = (int)H, maxy = -1;
    for (int y = 0; y < (int)H; y++) {
        for (int x = 0; x < (int)W; x++) {
            if (buf[((size_t)y * W + x) * 4 + 3] < 8) continue;
            if (x < minx) minx = x;
            if (x > maxx) maxx = x;
            if (y < miny) miny = y;
            if (y > maxy) maxy = y;
        }
    }
    free(buf);
    if (maxx < 0 || maxy < 0) return NO;
    if (out) *out = CGRectMake((double)minx / W, (double)miny / H,
                               (double)(maxx - minx + 1) / W, (double)(maxy - miny + 1) / H);
    return YES;
}

// ---- 阴影 ----
// 0.15.48 把图标缩到 0.80 居中让阴影露出来 —— 用户不接受（"一开阴影图标就变小"）。
// 0.15.49 起：**图标尺寸完全不变**（kTBShadowIconScale = 1.00），阴影改走【视图层】
// （见 TBApplyIconLayerShadow：给图标视图的 layer 设 shadowColor/Opacity/Radius/Offset
//  + shadowPath 圆角矩形）。图内合成只保留很轻的一圈（云团 1.06 倍 + 整体下移），
// 保证纯图内通道（系统图标缓存里的那张图）也能看到阴影的边。
static const CGFloat kTBShadowIconScale   = 1.00;   // 图标不缩小（1.00 = 与画布同尺寸）
static const CGFloat kTBShadowCloudToIcon = 1.06;   // 阴影可见云团 = 图标的 1.06 倍 → 只在边缘露一圈
static const CGFloat kTBShadowOffsetYFrac = 0.035;  // 云团整体下移（阴影偏下更自然）

/// 阴影素材"可见区域"的 bbox 只量一次。
/// TBApplyIconEffects 每次出图都要用，而 TBImageContentBBox 会跑一遍 64×64 重绘 + 扫描；
/// 以前一次出图要算两遍（画一次、打日志一次），属于刷新/布局回调里的纯浪费。
static BOOL TBShadowArtBBox(UIImage *shadow, CGRect *out) {
    if (!shadow) return NO;
    static __weak UIImage *sImg = nil;
    static CGRect sBB = {{0, 0}, {0, 0}};
    static BOOL sHas = NO, sValid = NO;
    if (sValid && sImg == shadow) {
        if (out) *out = sBB;
        return sHas;
    }
    BOOL has = TBImageContentBBox(shadow, &sBB);
    sImg = shadow; sHas = has; sValid = YES;
    if (out) *out = sBB;
    return has;
}

/// 阴影素材在画布里的绘制 rect：把"可见云团"铺到 图标的 kTBShadowCloudToIcon 倍并居中（再整体下移）。
/// 量不出可见区域时退化成"整张素材放大到 2 倍画布居中"（按素材有一半是边距处理）。
static CGRect TBShadowArtRect(UIImage *shadow, CGRect canvas, CGRect iconRect) {
    CGSize art = shadow.size;
    if (art.width < 1 || art.height < 1) return canvas;
    CGSize cloud = CGSizeMake(iconRect.size.width * kTBShadowCloudToIcon,
                              iconRect.size.height * kTBShadowCloudToIcon);
    CGRect bb;
    if (!TBShadowArtBBox(shadow, &bb) || bb.size.width < 0.02 || bb.size.height < 0.02) {
        CGRect r = canvas;
        r.origin.x -= r.size.width * 0.5;
        r.origin.y -= r.size.height * 0.5;
        r.size.width *= 2.0; r.size.height *= 2.0;
        r.origin.y += canvas.size.height * kTBShadowOffsetYFrac;
        return r;
    }
    CGRect r;
    r.size.width  = cloud.width  / bb.size.width;
    r.size.height = cloud.height / bb.size.height;
    r.origin.x = canvas.size.width  / 2.0 - r.size.width  / 2.0;
    r.origin.y = canvas.size.height / 2.0 - r.size.height / 2.0
                 + canvas.size.height * kTBShadowOffsetYFrac;   // 阴影偏下
    return r;
}

/// 特效合成：阴影垫在图标下方 → 图标 → 叠加层盖在图标之上。
/// 画布尺寸保持 = 图标尺寸（不改尺寸 → 下游 TBFitCached / 系统缓存不会把阴影又缩回图标格）。
/// 0.15.49：**图标不缩小**（iconRect = 整块画布）；阴影只在图标边缘/底部露一圈，
/// 真正的投影交给视图层的 TBApplyIconLayerShadow。
static UIImage *TBApplyIconEffects(UIImage *img) {
    TB_RENDER_SCOPE();
    if (!img) return img;
    CGSize pt = img.size;
    if (pt.width < 1 || pt.height < 1) return img;
    UIImage *shadow  = TBUseThemeIconShadow()  ? TBThemeShadowImage()  : nil;
    UIImage *overlay = TBUseThemeIconOverlay() ? TBThemeOverlayImage() : nil;
    if (!overlay) overlay = TBThemeGlassFromFaintMask();   // 淡玻璃遮罩 → 在这里当玻璃层画
    double strength = TBGlassOverlayStrength();
    if (overlay && strength <= 0.001) overlay = nil;       // 0 = 不用玻璃层
    if (!overlay && !shadow) return img;      // 没开 / 主题里没素材 → 原样返回

    CGRect canvas = CGRectMake(0, 0, pt.width, pt.height);
    const CGFloat iconScale = kTBShadowIconScale;          // = 1.00，图标保持原尺寸
    CGRect iconRect = CGRectInset(canvas, pt.width * (1.0 - iconScale) / 2.0,
                                          pt.height * (1.0 - iconScale) / 2.0);
    // overlay 按最终形状裁那一刀只用在这里：DestinationIn 取的是【图标自己的 alpha】，
    // 图标是满尺寸的，所以裁完 overlay 仍是整块（不会被裁掉、也不会出边）。
    if (overlay) overlay = TBMaskOverlayToIconAlpha(overlay, img, iconRect);

    CGRect sr = CGRectZero;
    if (shadow) sr = TBShadowArtRect(shadow, canvas, iconRect);

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = img.scale > 0.5 ? img.scale : 3.0;
    fmt.opaque = NO;
    UIImage *out = [[[UIGraphicsImageRenderer alloc] initWithSize:pt format:fmt]
        imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        if (shadow) [shadow drawInRect:sr blendMode:kCGBlendModeNormal alpha:strength];
        [img drawInRect:iconRect];
        if (overlay) [overlay drawInRect:iconRect blendMode:kCGBlendModeNormal alpha:strength];
    }];
    if (shadow) {
        TBLogOnce([@"shadowfx|" stringByAppendingFormat:@"%.0fx%.0f", pt.width, pt.height],
                  @"阴影：素材 %.0fx%.0f · 画布 %.0fx%.0f · K(图标占比)=%.2f（图标不缩小）· 云团=图标×%.2f "
                  @"→ 图内 rect %.0fx%.0f @(%.0f,%.0f) · 强度 %.2f · 投影走视图层",
                  shadow.size.width, shadow.size.height, pt.width, pt.height, iconScale,
                  kTBShadowCloudToIcon, sr.size.width, sr.size.height, sr.origin.x, sr.origin.y, strength);
    }
    if (overlay) {
        TBLogOnce([@"glassstrength|" stringByAppendingFormat:@"%.2f", strength],
                  @"玻璃层：强度 %.2f（0=不画）· 已按图标形状裁过（图标满尺寸，未被裁掉）· 源=%@", strength,
                  TBUseThemeIconOverlay() ? @"AnemoneEffects/iPhoneOverlay" : @"淡玻璃遮罩");
    }
    return out;
}

/// 图标最终出图：① 按形状裁（主题遮罩 / 自定义圆角 / 系统形状）② 再叠特效（阴影在下、叠加层在上）
static UIImage *TBIconFinalImage(UIImage *img) {
    TB_RENDER_SCOPE();
    return TBApplyIconEffects(TBIconRoundedImage(img));
}

#pragma mark - 阴影（视图层，0.15.49）

/// 特效相关偏好的 1 秒 TTL 缓存：layoutSubviews 里别每次都去问 cfprefsd / 读素材
static void TBShadowLayerParams(BOOL *enabledOut, double *strengthOut) {
    TB_RENDER_SCOPE();
    TBThemeRenderState *state = TBCurrentRenderState();
    if (!state->shadowParamsChecked) {
        state->shadowParamsChecked = YES;
        state->shadowStrength = TBGlassOverlayStrength();
        state->shadowOn = TBUseThemeIconShadow() && (TBThemeShadowImage() != nil) &&
                          !TBSafeMode() && TBEnabled();
    }
    if (enabledOut) *enabledOut = state->shadowOn;
    if (strengthOut) *strengthOut = state->shadowStrength;
}

static char kTBLayerShadowKey;   // 记录已应用的阴影参数（layout 会被反复调用）

/// 阴影走【视图层】：给图标视图的 layer 设 shadowColor/Opacity/Radius/Offset + shadowPath。
///   · 图标尺寸完全不变（图内把图标缩到 0.80 的方案被用户否决）
///   · shadowPath 用圆角矩形 → UIKit 不用为了算阴影去栅格化整棵子树（滚动卡顿的主因）
///   · 强度仍然受 GlassOverlayStrength 控制（0 = 不画，同时把之前设过的清掉）
static void TBApplyIconLayerShadow(id iconView, UIView *imgView) {
    TB_RENDER_SCOPE();
    if (!iconView || ![iconView isKindOfClass:[UIView class]]) return;
    @try {
        UIView *v = (UIView *)iconView;
        CALayer *layer = v.layer;
        if (!layer) return;
        BOOL on = NO;
        double strength = 0;
        TBShadowLayerParams(&on, &strength);
        if (!on || strength <= 0.001) {
            if (layer.shadowOpacity > 0.0) {
                layer.shadowOpacity = 0.0;
                layer.shadowPath = NULL;
                objc_setAssociatedObject(v, &kTBLayerShadowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            return;
        }
        CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"bounds"));
        CGFloat w = b.size.width, h = b.size.height;
        if (w < 4 || h < 4) return;
        CGFloat radius;
        if (TBMaskCornerRadiusOn()) radius = (CGFloat)(TBMaskCornerRadius() / 60.0) * w;
        else radius = MIN(w, h) * 0.2237;      // 和「形状兜底」同一口径（系统超椭圆近似）
        if (radius > MIN(w, h) * 0.5) radius = MIN(w, h) * 0.5;
        CGFloat opacity = (CGFloat)(strength * 0.45);     // 强度 0.6 → opacity 0.27
        CGFloat blur = MAX(3.0, MIN(w, h) * 0.18);
        CGFloat dy = h * 0.05;
        NSString *sig = [NSString stringWithFormat:@"%.1f|%.1f|%.2f|%.2f|%.1f", w, h, opacity, blur, dy];
        NSString *old = objc_getAssociatedObject(v, &kTBLayerShadowKey);
        if ([old isEqualToString:sig]) return;   // 参数没变 → 不动 layer（layout 每次都进来）
        objc_setAssociatedObject(v, &kTBLayerShadowKey, sig, OBJC_ASSOCIATION_COPY_NONATOMIC);

        CGRect r = CGRectMake(0, 0, w, h);
        if (imgView && imgView != v) {
            CGRect f = [imgView convertRect:imgView.bounds toView:v];
            if (f.size.width > 4 && f.size.height > 4) r = f;
        }
        if (layer.masksToBounds) {
            layer.masksToBounds = NO;   // 阴影必须画到 bounds 之外
            TBLogOnce(@"layershadow|unclip", @"阴影（视图层）：图标视图原本会裁剪，已关掉以让阴影露出来");
        }
        layer.shadowColor = [UIColor blackColor].CGColor;
        layer.shadowOpacity = opacity;
        layer.shadowRadius = blur;
        layer.shadowOffset = CGSizeMake(0, dy);
        layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius].CGPath;
        TBLogOnce([@"layershadow|" stringByAppendingFormat:@"%.0fx%.0f|%.2f", w, h, strength],
                  @"阴影（视图层）：图标 %.0fx%.0f 保持不变 · shadowPath %.0fx%.0f 圆角 %.1f · "
                  @"opacity %.2f（强度 %.2f）· blur %.1f · offset %.1f",
                  w, h, r.size.width, r.size.height, radius, opacity, strength, blur, dy);
    } @catch (NSException *e) { }
}

// ---- 图标圆角：用【系统自己的遮罩形状】，不再自己画超椭圆 ----
// 我们是在 SBHIconImageCache 的读路径直接返回图的，这条路径系统认为是"已遮罩"的，
// 所以必须自己遮 —— 但形状要用系统那张（第一次从系统原实现里取到后缓存成模板）。
static UIImage *TBMaskWithSystemShape(UIImage *art) {
    if (!art || !gSystemMaskTemplate) return art;
    CGSize sz = gSystemMaskTemplate.size;
    if (sz.width < 4 || sz.height < 4) return art;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = gSystemMaskTemplate.scale > 0.5 ? gSystemMaskTemplate.scale : 3.0;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [art drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
        // DestinationIn：只保留模板不透明处的像素 = 系统的圆角/超椭圆形状
        [gSystemMaskTemplate drawInRect:CGRectMake(0, 0, sz.width, sz.height)
                              blendMode:kCGBlendModeDestinationIn alpha:1.0];
    }];
}

/// 把系统原实现返回的已遮罩图记成模板
static void TBLearnSystemMask(UIImage *sysMasked) {
    if (!sysMasked || !sysMasked.CGImage) return;
    if (gSystemMaskTemplate && CGSizeEqualToSize(gSystemMaskTemplate.size, sysMasked.size)) return;
    gSystemMaskTemplate = sysMasked;
    TBLogOnce(@"iconmask|learn", @"图标遮罩：已取到系统遮罩形状（%.0fx%.0f pt）",
              sysMasked.size.width, sysMasked.size.height);
}

/// 带缓存的"按尺寸适配"：同一 bid + 同一尺寸只渲染一次（原来每次调用都重画一张）
static UIImage *TBFitCached(UIImage *img, TBInfo info, NSString *bid) {
    TB_RENDER_SCOPE();
    if (!img) return nil;
    if (!bid.length) return TBFitImage(img, info);
    // 键里带主题名：换主题瞬间，同 bid 同尺寸的旧键不能命中旧主题的成品图
    // （bid 变体除外：TBImageForBundle 的图本来就该按 bid 查，不随主题键失效会重复渲染；
    //   这里统一带上主题最安全 —— 60x60 这类同尺寸键在换主题后必须重画。）
    NSString *k = [NSString stringWithFormat:@"%@|%@|%.0fx%.0f|%.1f", TBActiveTheme() ?: @"",
                   bid, info.size.width, info.size.height, info.scale];
    if (!gFitCache) { [gLock lock]; if (!gFitCache) gFitCache = [NSMutableDictionary dictionary]; [gLock unlock]; }
    UIImage *c = gFitCache[k];
    if (c) return c;
    UIImage *out = TBFitImage(img, info);
    if (out) gFitCache[k] = out;
    return out;
}

static UIImage *TBImageForBundle(NSString *bid) {
    TB_RENDER_SCOPE();
    if (gTBSettingsNativeIcon) return nil;
    // 日历由 SBCalendarIconImageProvider 专用链处理，禁止通用图标缓存提前返回旧自绘图。
    if ([bid isEqualToString:@"com.apple.mobilecal"]) return nil;
    if (!bid.length || !TBEnabled()) return nil;
    if (TBSafeMode()) return nil;   // 安全模式：只记日志，绝不改图
    // 时钟：表盘当普通图标图交给系统（IconBundles 优先，没有则用 Bundles 的表盘素材），
    // 指针/轴心由 imageSet 注入 —— 与 SnowBoard 一致。

    [gLock lock];
    TBLoadIndex();
    NSString *path = gIndex[bid];
    // 0.18.1：分享面板/分享扩展常带后缀（com.tencent.xin.sharetimeline）→ 逐级截断前缀再试
    if (!path) {
        NSString *trim = bid;
        for (int i = 0; i < 3; i++) {
            NSRange r = [trim rangeOfString:@"." options:NSBackwardsSearch];
            if (r.location == NSNotFound || r.location == 0) break;
            trim = [trim substringToIndex:r.location];
            NSString *p2 = gIndex[trim];
            if (p2) { path = p2; TBLogOnce([@"prefix|" stringByAppendingString:bid],
                                           @"图标前缀归并：%@ → %@", bid, trim); break; }
        }
    }
    [gLock unlock];
    BOOL cameFromMaterial = NO;
    if (!path) {
        // 时钟/日历是动态图标，主题作者通常放在 Bundles/ 下的
        // ClockIcon*.png / CalendarIcon*.png，而不是 IconBundles/<包名>.png
        path = TBDynamicResourcePath(bid);
        if (path) cameFromMaterial = YES;
        if (!path) return nil;
        TBLogOnce([@"dynsrc|" stringByAppendingString:bid],
                  @"dynamic 图来自 Bundles: %@ → %@", bid, path.lastPathComponent);
    }

    BOOL isCalendar = [bid isEqualToString:@"com.apple.mobilecal"];
    NSString *cacheKey = bid;
    if (isCalendar) {
        // 日历按天缓存，跨天自动重画
        NSDateFormatter *dfd = [[NSDateFormatter alloc] init];
        dfd.dateFormat = @"yyyyMMdd";
        cacheKey = [bid stringByAppendingFormat:@"|%@", [dfd stringFromDate:[NSDate date]]];
    }
    UIImage *cached = [gImageCache objectForKey:cacheKey];
    if (cached) return cached;

    UIImage *img = [[UIImage alloc] initWithContentsOfFile:path];   // 不用被 hook 的类方法
    CGFloat inkPct = 0, opPct = 0;
    BOOL looksDrawn = TBImageDateAreaMetrics(img, &inkPct, &opPct);
    BOOL forceNoDate = NO;
    id ndv = TBPref(@"NoCalendarDate");
    if (ndv) forceNoDate = [ndv boolValue];
    BOOL calDynamic = cameFromMaterial || !looksDrawn;
    if (forceNoDate) calDynamic = NO;
    if (isCalendar && img) {
        TBLogOnce([@"caljudge|" stringByAppendingFormat:@"%@|%d", bid, (int)looksDrawn],
                  @"日历判定：墨 %.1f%% / 不透明 %.1f%% → %@%@",
                  inkPct, opPct,
                  (calDynamic ? @"自己写日期" : @"用主题图标原样"),
                  (forceNoDate ? @"（设置里强制不叠加）" : @""));
    }
    if (img && isCalendar) {
        if (!calDynamic) {
            // 主题图标自己已经画了日期/星期 → 直接用，不叠加（否则会重影）
            TBLogOnce(@"calc|static", @"日历：主题图标已自带日期，跳过叠加");
            UIImage *masked = TBIconFinalImage(img);        // 圆角遮罩 + 叠加层/阴影不能漏
            if (masked) img = masked;
            [gImageCache setObject:img forKey:cacheKey];
            return img;
        }
        UIImage *composed = TBCalendarCompositeImage(img);
        if (composed) {
            TBLogOnce(@"calc|ok", @"日历合成：底图 + 红星期 + 黑日期");
            UIImage *masked = TBIconFinalImage(composed);     // 合成后同样要裁圆角 + 叠特效
            if (masked) composed = masked;
            [gImageCache setObject:composed forKey:cacheKey];
            return composed;
        }
    }
    if (img) {
        // 日历/时钟带实时内容，不能进缓存，否则日期和指针会冻住
        BOOL dynamic = [bid isEqualToString:@"com.apple.mobilecal"] ||
                       [bid isEqualToString:@"com.apple.mobiletimer"];
        if (dynamic) {
            static int logged = 0;
            if (logged < 20) { logged++; TBLog(@"dynamic %@", bid); }
            img = TBDynamicIcon(img, bid);
        img = TBIconRoundedImage(img);
        }
        // 按系统遮罩形状裁一刀（= SnowBoard 的 roundedRectImage:withCrop:YES 那一步）
        // 最后一道：按形状裁 + 叠 AnemoneEffects（阴影在下、叠加层在上），一次性出最终图
        img = TBIconFinalImage(img);            // 交给系统前按形状裁 + 叠特效（SB 同款）
        if (!dynamic) [gImageCache setObject:img forKey:bid];
    }
    return img;
}

#pragma mark - 取 bundleID

/// 反 DNS 形式（至少含一个点）才算可用的 bundleID；UUID 之类一律视为不可用
static BOOL TBBIDLooksUsable(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length < 3) return NO;
    return [s rangeOfString:@"."].location != NSNotFound;
}

static NSString *TBBIDFromIcon(id icon) {
    if (!icon) return nil;
    static NSArray *paths = nil;
    if (!paths) paths = @[@"applicationBundleID", @"bundleIdentifier",
                          @"applicationBundleIdentifier", @"leafIdentifier"];
    NSString *fallback = nil;
    for (NSString *k in paths) {
        @try {
            if (![icon respondsToSelector:NSSelectorFromString(k)]) continue;
            id v = [icon valueForKey:k];
            if (![v isKindOfClass:[NSString class]] || ![(NSString *)v length]) continue;
            if (TBBIDLooksUsable(v)) return v;
            if (!fallback) fallback = v;
        } @catch (NSException *e) {}
    }
    return fallback;
}

#pragma mark - hook 工具


    // ★★★ 通知中心图标：0.15.89 起永久封存。
    //   照 SystemX 1.5-8 的 NCBadgedIconView 五连 hook（init×2/set×2/layout）实测：
    //   无任何效果 + 闪屏 + 自动注销。与 0.15.73/82/84/86 四次失败一致。
    //   结论（最终）：本机 17.2.1 上 NC 图标替换不可行，任何 NC* 类 hook 都会破坏通知系统。
    //   除非未来做真机运行时 dump 并找到安全插入点，否则不再尝试。

static void TBRefreshVisibleTablesLight(NSString *why);

// ---- Settings App row icons: synchronous PSTableCell source ----
static __thread BOOL gTBPSGetterDepth;
static __thread BOOL gTBPSSetterDepth;
static const void *kTBPSBidKey=&kTBPSBidKey;
static const void *kTBPSOriginalKey=&kTBPSOriginalKey;
static const void *kTBPSAppliedKey=&kTBPSAppliedKey;
static const void *kTBPSStateKey=&kTBPSStateKey;
static IMP o_tbPSGetIcon, o_tbPSGetLazyIcon, o_tbPSGetIconFromServices;
static IMP o_tbPSSetIcon, o_tbPSPrepareForReuse;

static NSString *TBBidFromAnySpecifier(id spec) {
    if (!spec) return nil;
    @try {
        for (NSString *key in @[@"identifier", @"bundleIdentifier"]) {
            SEL selector=NSSelectorFromString(key);
            if (![spec respondsToSelector:selector]) continue;
            id value=((id(*)(id,SEL))objc_msgSend)(spec,selector);
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value containsString:@"."]) return value;
        }
        SEL property=NSSelectorFromString(@"propertyForKey:");
        if ([spec respondsToSelector:property]) {
            for (NSString *key in @[@"bundleID",@"applicationBundleIdentifier",@"id"]) {
                id value=((id(*)(id,SEL,id))objc_msgSend)(spec,property,key);
                if ([value isKindOfClass:[NSString class]] && [(NSString *)value containsString:@"."]) return value;
            }
        }
    } @catch (NSException *exception) {}
    return nil;
}

static void TBPSClearCellState(id cell) {
    objc_setAssociatedObject(cell,kTBPSBidKey,nil,OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(cell,kTBPSOriginalKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell,kTBPSAppliedKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell,kTBPSStateKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static NSString *TBPSCellBundleID(id cell) {
    // A permission row's specifier identifies its owner, not its glyph.
    // Only an actual active lazy App-icon source may enter this path.
    Ivar activeIvar=class_getInstanceVariable([cell class], "_lazyIcon");
    Ivar appIvar=class_getInstanceVariable([cell class], "_lazyIconAppID");
    if (!activeIvar || !appIvar) return nil;
    const char *activeType=ivar_getTypeEncoding(activeIvar);
    const char *appType=ivar_getTypeEncoding(appIvar);
    ptrdiff_t activeOffset=ivar_getOffset(activeIvar);
    if (!activeType || (activeType[0]!='B' && activeType[0]!='c') ||
        !appType || appType[0]!='@' || activeOffset<0 ||
        (size_t)activeOffset>=class_getInstanceSize([cell class])) return nil;
    unsigned char active=0;
    memcpy(&active,((const unsigned char *)(__bridge const void *)cell)+activeOffset,sizeof(active));
    if (!active) return nil;
    id value=object_getIvar(cell,appIvar);
    return [value isKindOfClass:[NSString class]] && [(NSString *)value containsString:@"."] ? value : nil;
}

static UIImage *TBPSThemedImage(id cell,UIImage *candidate) {
    TB_RENDER_SCOPE();
    if (![candidate isKindOfClass:[UIImage class]]) return candidate;
    NSString *bid=TBPSCellBundleID(cell);
    if (!bid.length) { TBPSClearCellState(cell); return candidate; }
    NSString *oldBid=objc_getAssociatedObject(cell,kTBPSBidKey);
    UIImage *original=objc_getAssociatedObject(cell,kTBPSOriginalKey);
    UIImage *applied=objc_getAssociatedObject(cell,kTBPSAppliedKey);
    if (![oldBid isEqualToString:bid]) {
        // A recycled cell must not use the previous App's source image.
        BOOL stale=(candidate==applied);
        TBPSClearCellState(cell);
        objc_setAssociatedObject(cell,kTBPSBidKey,bid,OBJC_ASSOCIATION_COPY_NONATOMIC);
        original=nil; applied=nil;
        if (stale) return nil;
    }
    if (candidate==applied && original) candidate=original;
    else if (candidate!=original) {
        original=candidate;
        applied=nil;
        objc_setAssociatedObject(cell,kTBPSOriginalKey,original,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell,kTBPSAppliedKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(cell,kTBPSStateKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!TBEnabled() || TBSafeMode() || !TBUIKitIconEnabled()) return candidate;
    NSNumber *generation=objc_getAssociatedObject(cell,kTBPSStateKey);
    NSUInteger currentGeneration=TBCurrentRenderState()->generation;
    if (applied && generation && generation.unsignedLongLongValue==currentGeneration) return applied;
    CGSize size=candidate.size;
    if (size.width<8 || size.height<8) {
        @try {
            SEL selector=NSSelectorFromString(@"iconImageView");
            id view=[cell respondsToSelector:selector] ? ((id(*)(id,SEL))objc_msgSend)(cell,selector) : nil;
            if ([view isKindOfClass:[UIImageView class]]) size=((UIImageView *)view).bounds.size;
        } @catch (NSException *exception) {}
    }
    if (size.width<8 || size.height<8) return candidate;
    // TBImageForBundle already applies shape/effects: do not process it twice.
    UIImage *image=TBImageForBundle(bid);
    if (!image) image=TBGlobalEffectImage(candidate,bid);
    if (![image isKindOfClass:[UIImage class]] || image==candidate) return candidate;
    TBInfo info={size,candidate.scale>0.5 ? candidate.scale : [UIScreen mainScreen].scale,0};
    image=TBFitCached(image,info,[@"settings|" stringByAppendingString:bid]);
    if (!image) return candidate;
    objc_setAssociatedObject(cell,kTBPSAppliedKey,image,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell,kTBPSStateKey,@(currentGeneration),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return image;
}

static id TBPSReadIcon(id cell,SEL selector,IMP original) {
    if (!original) return nil;
    id (*callOriginal)(id,SEL)=(id(*)(id,SEL))original;
    if (gTBPSGetterDepth) return callOriginal(cell,selector);
    BOOL previous=gTBPSGetterDepth, nativePrevious=gTBSettingsNativeIcon;
    gTBPSGetterDepth=YES;
    id native=nil;
    @try {
        // Fetch the native image before the caller stores it in PSTableCell.
        gTBSettingsNativeIcon=YES;
        native=callOriginal(cell,selector);
    } @finally {
        gTBSettingsNativeIcon=nativePrevious;
        gTBPSGetterDepth=previous;
    }
    return TBPSThemedImage(cell,native);
}
static id tb_psGetIcon(id self,SEL selector) { return TBPSReadIcon(self,selector,o_tbPSGetIcon); }
static id tb_psGetLazyIcon(id self,SEL selector) { return TBPSReadIcon(self,selector,o_tbPSGetLazyIcon); }
static id tb_psGetIconFromServices(id self,SEL selector) { return TBPSReadIcon(self,selector,o_tbPSGetIconFromServices); }

static void tb_psSetIcon(id self,SEL selector,id image) {
    if (!o_tbPSSetIcon) return;
    void (*callOriginal)(id,SEL,id)=(void(*)(id,SEL,id))o_tbPSSetIcon;
    if (gTBPSGetterDepth || gTBPSSetterDepth) { callOriginal(self,selector,image); return; }
    BOOL previous=gTBPSSetterDepth;
    gTBPSSetterDepth=YES;
    @try { callOriginal(self,selector,TBPSThemedImage(self,image)); }
    @finally { gTBPSSetterDepth=previous; }
}
static void tb_psPrepareForReuse(id self,SEL selector) {
    BOOL previous=gTBPSGetterDepth, nativePrevious=gTBSettingsNativeIcon;
    gTBPSGetterDepth=YES; gTBSettingsNativeIcon=YES;
    @try { if (o_tbPSPrepareForReuse) ((void(*)(id,SEL))o_tbPSPrepareForReuse)(self,selector); }
    @finally {
        TBPSClearCellState(self);
        gTBPSGetterDepth=previous; gTBSettingsNativeIcon=nativePrevious;
    }
}

static const char *TBPSUnqualifiedType(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV",*type)) type++;
    return type;
}
static BOOL TBPSMethodMatches(Method method,const char *types) {
    if (!method || !types || method_getNumberOfArguments(method)!=strlen(types)-1) return NO;
    char *type=method_copyReturnType(method);
    BOOL matches=(*TBPSUnqualifiedType(type)==types[0]); free(type);
    for (unsigned int i=0;matches && i<strlen(types)-1;i++) {
        type=method_copyArgumentType(method,i);
        char actual=*TBPSUnqualifiedType(type), expected=types[i+1];
        matches=((actual=='c'||actual=='B')&&(expected=='c'||expected=='B')) || actual==expected;
        free(type);
    }
    return matches;
}
static BOOL TBPSInstallMethod(Class cls,SEL selector,IMP replacement,IMP *original,const char *types) {
    if (!cls || !original || !replacement) return NO;
    if (*original) return YES;
    Method method=class_getInstanceMethod(cls,selector);
    if (!TBPSMethodMatches(method,types)) return NO;
    IMP previous=method_getImplementation(method);
    if (!previous || previous==replacement) return NO;
    *original=previous;
    if (class_addMethod(cls,selector,replacement,method_getTypeEncoding(method))) return YES;
    unsigned int count=0; Method *methods=class_copyMethodList(cls,&count); Method local=NULL;
    for (unsigned int i=0;i<count;i++)
        if (sel_isEqual(method_getName(methods[i]),selector)) { local=methods[i]; break; }
    free(methods);
    if (!local || method_getImplementation(local)!=previous) { *original=NULL; return NO; }
    method_setImplementation(local,replacement);
    return YES;
}

// ---- 时钟供图（0.18.1 的四 hook 版）已整体移除：见 0.18.7 说明 ----

// 通知中心：数据层和带头像通知的视图层替换。
static id (*o_ncIcons)(id, SEL);

// ★ 1.34：如果 NC 的图标是每个 recipe 自己带的（NCNotificationIconRecipe.image），
//   那就直接在 recipe 的取图上换。视频里 NC 图标是一张 38x38 的普通 UIImage，
//   说明它最终来自某个 -image/-_image 取值点。
static id (*o_ncRecipeImage)(id, SEL);
static id tb_ncRecipeImage(id self, SEL _cmd) {
    id r = o_ncRecipeImage ? o_ncRecipeImage(self, _cmd) : nil;
    @try {
        NSString *bid = nil;
        for (NSString *k in @[ @"applicationIdentifier", @"_applicationIdentifier",
                               @"bundleIdentifier", @"sectionIdentifier" ]) {
            id v = nil;
            @try { v = [self valueForKey:k]; } @catch (NSException *e) { }
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v containsString:@"."]) { bid = v; break; }
        }
        if (!bid.length) return r;
        UIImage *mine = TBImageForBundle(bid);
        if (!mine) return r;
        TBLogOnce([@"ncr|" stringByAppendingString:bid], @"NC recipe 替换 %@", bid);
        return mine;
    } @catch (NSException *e) { return r; }
}

// 通知请求提供 bundleID，关联到内容对象后供 icons 取用。
static const void *kNCNBidKey = &kNCNBidKey;
static id (*o_ncRequestContent)(id, SEL);

static id tb_ncRequestContent(id self, SEL _cmd) {
    id c = o_ncRequestContent ? o_ncRequestContent(self, _cmd) : nil;
    @try {
        NSString *bid = nil;
        for (NSString *k in @[ @"sectionIdentifier", @"_sectionIdentifier", @"bundleIdentifier",
                               @"_bundleIdentifier", @"sectionID", @"_sectionID" ]) {
            id v = nil;
            @try { v = [self valueForKey:k]; } @catch (NSException *e1) { v = nil; }
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v containsString:@"."]) { bid = v; break; }
        }
        if (c && bid.length) objc_setAssociatedObject(c, kNCNBidKey, bid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @catch (NSException *e) { }
    return c;
}

static id tb_ncIcons(id self, SEL _cmd) {
    TB_RENDER_SCOPE();
    id r = o_ncIcons ? o_ncIcons(self, _cmd) : nil;        // 原实现只调一次
    if (![r isKindOfClass:[NSArray class]] || ((NSArray *)r).count == 0) return r;
    @try {
        NSString *bid = objc_getAssociatedObject(self, kNCNBidKey);   // ★ 1.38 来自 request 的关联
        for (NSString *k in bid.length ? @[] : @[ @"_applicationIdentifier", @"applicationIdentifier",
                               @"sectionIdentifier", @"bundleIdentifier" ]) {
            id v = nil;
            @try { v = [self valueForKey:k]; } @catch (NSException *e) { }
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v containsString:@"."]) { bid = v; break; }
        }
        // ★ 1.34：带"头像"的通知（communication notification，微信/iMessage 那种）
        //   图标位显示的是联系人头像，不是 App 图标 —— 绝不能换成主题 App 图。
        BOOL hasAvatar = NO;
        for (NSString *k in @[ @"communicationContext", @"_communicationContext" ]) {
            @try { if ([self valueForKey:k]) { hasAvatar = YES; break; } } @catch (NSException *ea) { }
        }
        if (!bid.length) return r;
        UIImage *mine = TBImageForBundle(bid);
        if (!mine) return r;
        NSArray *src = (NSArray *)r;
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:src.count];
        // ★ 带头像的通知：第 1 项是联系人头像（不能动），后面那项才是右下角的 App 小图标。
        //   所以「跳过」是不对的 —— 正确的做法是保留头像、只换后面的小图标。
        if (hasAvatar && src.count == 1) return r;   // 只有 1 张 = 头像本身，别动它
        NSUInteger keep = (hasAvatar && src.count >= 2) ? 1 : 0;
        for (NSUInteger i = 0; i < src.count; i++) [out addObject:(i < keep ? src[i] : mine)];
        TBLogOnce([@"nc|" stringByAppendingFormat:@"%@|%lu|%@", bid, (unsigned long)src.count, hasAvatar ? @"av" : @"-"],
                  @"NC 数据层替换 %@（数组 %lu 项%@）", bid, (unsigned long)src.count,
                  hasAvatar ? @"，带头像→保留第1项、只换小图标" : @"");
        return out;
    } @catch (NSException *e) { return r; }
}

// 带头像通知的视图层：仅替换右下角 App 徽标，不改联系人头像。
static void (*o_ncbLayout)(id, SEL);

static UIImageView *TBNCFindImageView(UIView *v, int depth) {
    if (!v || depth > 4) return nil;
    if ([v isKindOfClass:[UIImageView class]]) return (UIImageView *)v;
    for (UIView *k in v.subviews) { UIImageView *r = TBNCFindImageView(k, depth + 1); if (r) return r; }
    return nil;
}

static UIView *TBNCFindBadgeView(UIView *v, int depth) {
    if (!v || depth > 3) return nil;
    if ([NSStringFromClass([v class]) rangeOfString:@"BrandingBadge"].location != NSNotFound) return v;
    for (UIView *k in [v subviews]) { UIView *r = TBNCFindBadgeView(k, depth + 1); if (r) return r; }
    return nil;
}

/// 从视图往上找通知请求（身份在 request 上，1.35/1.37 实证都不在 content/图标视图上）
static NSString *TBNCBidFromView(UIView *v) {
    UIView *p = v;
    for (int i = 0; i < 10 && p; i++, p = p.superview) {
        for (NSString *k in @[ @"notificationRequest", @"_notificationRequest", @"request", @"_request" ]) {
            id r = nil;
            @try { r = [p valueForKey:k]; } @catch (NSException *e) { r = nil; }
            if (!r) continue;
            for (NSString *k2 in @[ @"sectionIdentifier", @"_sectionIdentifier", @"bundleIdentifier", @"_bundleIdentifier" ]) {
                id b = nil;
                @try { b = [r valueForKey:k2]; } @catch (NSException *e2) { b = nil; }
                if ([b isKindOfClass:[NSString class]] && [(NSString *)b containsString:@"."]) return b;
            }
        }
    }
    return nil;
}

/// ★ 1.41：视频实测「最近 VC = CSNotificationViewController」。
/// 从图标视图往上找 VC（nextResponder 链），再在 VC 上找 request → sectionIdentifier。
static NSString *TBNCBidFromViewController(UIView *v, NSString **vcNameOut) {
    UIResponder *r = (UIResponder *)v;
    for (int i = 0; i < 12 && r; i++) {
        r = [r nextResponder];
        if (!r) break;
        if (![r isKindOfClass:[UIViewController class]]) continue;
        if (vcNameOut) *vcNameOut = NSStringFromClass([r class]);
        for (NSString *k in @[ @"notificationRequest", @"_notificationRequest", @"request", @"_request",
                               @"notification", @"_notification" ]) {
            id req = nil;
            @try { req = [r valueForKey:k]; } @catch (NSException *e) { req = nil; }
            if (!req) continue;
            for (NSString *k2 in @[ @"sectionIdentifier", @"_sectionIdentifier", @"bundleIdentifier", @"_bundleIdentifier" ]) {
                id b = nil;
                @try { b = [req valueForKey:k2]; } @catch (NSException *e2) { b = nil; }
                if ([b isKindOfClass:[NSString class]] && [(NSString *)b containsString:@"."]) return b;
            }
        }
        break;   // 只看最近的一个 VC
    }
    return nil;
}

/// 通知内容视图根据关联请求定位身份，只替换徽标中的 App 图标。
static void (*o_ncsLayout)(id, SEL);

static NSString *TBNCBidFromRequestLike(id req) {
    if (!req) return nil;
    for (NSString *k in @[ @"sectionIdentifier", @"_sectionIdentifier",
                           @"bundleIdentifier", @"_bundleIdentifier" ]) {
        id b = nil;
        @try { b = [req valueForKey:k]; } @catch (NSException *e) { b = nil; }
        if ([b isKindOfClass:[NSString class]] && [(NSString *)b containsString:@"."]) return b;
    }
    return nil;
}

static void tb_ncsLayout(id self, SEL _cmd) {
    TB_RENDER_SCOPE();
    if (o_ncsLayout) o_ncsLayout(self, _cmd);
    if (TBSafeMode() || !TBEnabled()) return;
    if (![self isKindOfClass:[UIView class]]) return;
    @try {
        // ② bid
        NSString *bid = nil;
        for (NSString *k in @[ @"notificationRequest", @"_notificationRequest", @"request", @"_request" ]) {
            id rv = nil;
            @try { rv = [self valueForKey:k]; } @catch (NSException *e) { rv = nil; }
            bid = TBNCBidFromRequestLike(rv);
            if (bid.length) break;
        }
        if (!bid.length) return;
        UIImage *th = TBImageForBundle(bid);
        if (!th) return;
        id badged = nil;
        @try { badged = [self valueForKey:@"_badgedIconView"]; } @catch (NSException *e) { badged = nil; }
        UIView *container = [badged isKindOfClass:[UIView class]] ? (UIView *)badged : (UIView *)self;
        NSArray *bvs = nil;
        @try { id v = [container valueForKey:@"_badgeViews"]; if ([v isKindOfClass:[NSArray class]]) bvs = v; }
        @catch (NSException *e2) { bvs = nil; }
        if (!bvs.count) { UIView *bb = TBNCFindBadgeView(container, 0); if (bb) bvs = @[bb]; }
        for (UIView *bv in bvs) {
            UIImageView *iv = TBNCFindImageView(bv, 0);
            if (iv && iv.image != th) {
                iv.image = th;
                iv.contentMode = UIViewContentModeScaleAspectFit;
                TBLogOnce([@"ncb2|" stringByAppendingString:bid], @"NC 小图标已换 %@（内容视图）", bid);
            }
        }
    } @catch (NSException *e) { }
}

static void tb_ncbLayout(id self, SEL _cmd) {
    TB_RENDER_SCOPE();
    if (o_ncbLayout) o_ncbLayout(self, _cmd);
    if (TBSafeMode() || !TBEnabled()) return;
    if (![self isKindOfClass:[UIView class]]) return;
    @try {
        NSString *bid = nil;
        id desc = nil;
        @try { desc = [self valueForKey:@"_badgedIconDescription"]; } @catch (NSException *ed) { desc = nil; }
        if (desc) {
            for (NSString *k in @[@"_bundleIdentifier", @"bundleIdentifier", @"_applicationIdentifier"]) {
                @try {
                    id v = [desc valueForKey:k];
                    if ([v isKindOfClass:[NSString class]] && [(NSString *)v containsString:@"."]) { bid = v; break; }
                } @catch (NSException *ek) { }
            }
        }
        if (!bid.length) bid = TBNCBidFromView((UIView *)self);
        NSString *vcName = nil;
        if (!bid.length) bid = TBNCBidFromViewController((UIView *)self, &vcName);
        if (vcName.length) TBLogOnce([@"ncvc|" stringByAppendingString:vcName],
                                     @"NC 最近 VC = %@（从中取 bid=%@）", vcName, bid ?: @"-");
        UIView *avatar = nil, *badge = nil;
        for (UIView *v in [(UIView *)self subviews]) {
            NSString *cn = NSStringFromClass([v class]);
            if ([cn rangeOfString:@"Avatar"].location != NSNotFound) avatar = v;
            if ([cn rangeOfString:@"BrandingBadge"].location != NSNotFound) badge = v;
            for (UIView *v2 in v.subviews) {
                if ([NSStringFromClass([v2 class]) rangeOfString:@"BrandingBadge"].location != NSNotFound) badge = v2;
            }
        }
        UIImage *th = bid.length ? TBImageForBundle(bid) : nil;
        if (!th) return;
        // ★ 1.39：普通通知的大图已由数据层（icons + request 关联）换好。
        //   这里只处理「带头像」的那种：右下角小 App 图标（NCImageBrandingBadge）。
        // ★ 1.39：日志实证 NCBadgedIconView 有 ivar _badgeViews（普通通知为 nil，
        //   带头像的那种才会有内容）。优先按 _badgeViews 拿，取不到再按类名递归找。
        NSArray *bvs = nil;
        @try { id v = [self valueForKey:@"_badgeViews"]; if ([v isKindOfClass:[NSArray class]]) bvs = v; }
        @catch (NSException *ebv) { bvs = nil; }
        BOOL did = NO;
        if (bvs.count) {
            for (UIView *bv in bvs) {
                UIImageView *iv = TBNCFindImageView(bv, 0);
                if (iv && iv.image != th) {
                    iv.image = th;
                    iv.contentMode = UIViewContentModeScaleAspectFit;
                    did = YES;
                }
            }
        }
        if (!did) {
            UIView *bb = TBNCFindBadgeView((UIView *)self, 0);
            if (bb) {
                UIImageView *iv = TBNCFindImageView(bb, 0);
                if (iv && iv.image != th) {
                    iv.image = th;
                    iv.contentMode = UIViewContentModeScaleAspectFit;
                    did = YES;
                }
            }
        }
        if (did) TBLogOnce([@"ncb|" stringByAppendingString:bid], @"NC 小图标已换 %@", bid);
    } @catch (NSException *e) { }
}

static IMP TBHook(Class cls, NSString *selName, IMP repl, const char *tag) {
    if (!cls) { TBLog(@"· %s: 类不存在", tag); return NULL; }
    Method m = class_getInstanceMethod(cls, NSSelectorFromString(selName));
    if (!m) { TBLog(@"· %s: 方法不存在(%@)", tag, selName); return NULL; }
    IMP orig = method_getImplementation(m);
    if (TBDiagEnabled() &&
        ([NSStringFromClass(cls) containsString:@"Calendar"] ||
         [NSStringFromClass(cls) containsString:@"Clock"] ||
         [NSStringFromClass(cls) isEqualToString:@"SBIcon"])) {
        Class owner = TBDiagOwner(cls, NSSelectorFromString(selName));
        Dl_info originalImage = {0};
        dladdr((const void *)orig, &originalImage);
        TBLog(@"LIVE hook.before class=%@ selector=%@ owner=%@ encoding=%s original=%p image=%s",
              NSStringFromClass(cls), selName, owner ? NSStringFromClass(owner) : @"-",
              method_getTypeEncoding(m), orig, originalImage.dli_fname ?: "-");
    }
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
    if (!gCaches) gCaches = [NSHashTable weakObjectsHashTable];
    [gCaches addObject:cache];
    [gLock unlock];
}

#pragma mark - hook 实现

typedef id (*FnIcon)(id, SEL, id);
typedef id (*FnIconOpt)(id, SEL, id, unsigned long long);
typedef id (*FnImageForIcon)(id, SEL, id, id);
typedef id (*FnIconAppOpt)(id, SEL, id, id, unsigned long long);        // imageForIcon:imageAppearance:options:
typedef id (*FnImageForIconAppOpt)(id, SEL, id, id, id, unsigned long long); // cacheImage:forIcon:imageAppearance:options:
typedef id (*FnGen)(id, SEL, TBImageInfo);
typedef id (*FnISGeneration)(id, SEL, id *);

static FnIcon o_imageForIcon, o_cachedForIcon, o_unmaskedForIcon;
static FnIconOpt o_imageForIconOpt, o_realForIconOpt, o_unmaskedForIconOpt;
static FnImageForIcon o_cacheImageForIcon;
static FnIconAppOpt o_imageForIconApp;                 // 0.18.4：带 imageAppearance 的新签名
static FnImageForIconAppOpt o_cacheImageForIconApp;    // 0.18.4：同上（写端）
static FnGen o_generateIconImageWithInfo;
static FnISGeneration o_isGeneration;
typedef id (*FnISGenerateImage)(id, SEL);
static FnISGenerateImage o_isGenerateImage;

/// ★ 0.18.19 完整读端接管：缓存【读】的时候也给主题图。
/// 与 0.18.14/17 的区别（那两版被回退了）：
///   · 不是"直接返回原图"（那会绕过遮罩/全局效果、还会让大图拖卡）
///   · 而是走和【写缓存端】同一套加工：TBFitCached(主题图, 缓存请求的尺寸) ——
///     成品按「主题+bid+尺寸」缓存，保证尺寸正确、不重复计算、不返回 1024 大图
static UIImage *TBServeReadSide(id cache, id icon) {
    TB_RENDER_SCOPE();
    if (!TBEnabled() || TBSafeMode() || !TBApplyIconForDesktop()) return nil;
    @try {
        NSString *bid = TBBIDFromIcon(icon);
        if (!bid.length || [bid isEqualToString:@"com.apple.mobilecal"]) return nil;
        UIImage *base = TBImageForBundle(bid);
        if (!base) return nil;                 // 主题没覆盖 → 交给系统直通（写端已管全局效果）
        UIImage *out = TBFitCached(base, TBInfoOfCache(cache), bid);
        if (!out) out = base;
        TBLogOnce([@"serveRead|" stringByAppendingString:bid], @"读端接管 %@", bid);
        return out;
    } @catch (NSException *e) { return nil; }
}

static id tb_imageForIcon(id self, SEL _cmd, id icon) {
    TB_RENDER_SCOPE();
    // ★ 0.18.19：先给主题图（读端接管，尺寸/成品都走同一套加工）；没素材再直通。
    //   直通时顺手从系统那张已遮罩图里学一次"系统遮罩形状"，供我们裁剪素材时使用。
    TBRemember(self);
    { UIImage *m = TBServeReadSide(self, icon); if (m) return m; }
    id r = o_imageForIcon ? o_imageForIcon(self, _cmd, icon) : nil;
    // 主题生效时缓存可能已有主题加工结果；仅在无主题时学习系统形状。
    if (!gSystemMaskTemplate && !TBActiveTheme().length && [r isKindOfClass:[UIImage class]])
        TBLearnSystemMask(r);
    return r;
}

static id tb_imageForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TB_RENDER_SCOPE();
    TBRemember(self);
    { UIImage *m = TBServeReadSide(self, icon); if (m) return m; }
    return o_imageForIconOpt ? o_imageForIconOpt(self, _cmd, icon, opt) : nil;
}

static id tb_cachedForIcon(id self, SEL _cmd, id icon) {
    TB_RENDER_SCOPE();
    TBRemember(self);
    { UIImage *m = TBServeReadSide(self, icon); if (m) return m; }
    return o_cachedForIcon ? o_cachedForIcon(self, _cmd, icon) : nil;
}

static id tb_realForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TB_RENDER_SCOPE();
    TBRemember(self);
    { UIImage *m = TBServeReadSide(self, icon); if (m) return m; }
    return o_realForIconOpt ? o_realForIconOpt(self, _cmd, icon, opt) : nil;
}

static id tb_unmaskedForIcon(id self, SEL _cmd, id icon) {
    TB_RENDER_SCOPE();
    TBRemember(self);
    { UIImage *m = TBServeReadSide(self, icon); if (m) return m; }   // ★ 0.18.19：Dock 也接管
    return o_unmaskedForIcon ? o_unmaskedForIcon(self, _cmd, icon) : nil;
}

static id tb_unmaskedForIconOpt(id self, SEL _cmd, id icon, unsigned long long opt) {
    TB_RENDER_SCOPE();
    TBRemember(self);
    { UIImage *m = TBServeReadSide(self, icon); if (m) return m; }   // ★ 0.18.19：Dock 也接管
    return o_unmaskedForIconOpt ? o_unmaskedForIconOpt(self, _cmd, icon, opt) : nil;
}

/// 缓存落盘的那一刻换掉图 —— 这样所有后续消费者（含变体缓存）拿到的都是主题图
static id tb_cacheImageForIcon(id self, SEL _cmd, id image, id icon) {
    TB_RENDER_SCOPE();
    // 缓存写入端接管（这是唯一在本机实测有效的手段：系统写入缓存时把非主题图换成主题图）。
    // 系统在这台 iOS 17.2 上不会因为 purge/clear/update 就丢掉旧合成图，必须在这里拦截。
    TBRemember(self);
    @try {
        NSString *bid = TBBIDFromIcon(icon);
        if (TBDiagDynamicBID(bid)) TBDiagEmit(@"cache.in", icon, _cmd, image, nil, NSStringFromClass([self class]));
        if (bid.length && TBApplyIconForDesktop() && !TBSafeMode()) {
            UIImage *mine = TBFitCached(TBImageForBundle(bid), TBInfoOfCache(self), bid) ?: TBImageForBundle(bid);
            if (mine) {
                if (TBDiagDynamicBID(bid)) TBDiagEmit(@"cache.theme", icon, _cmd, image, mine, @"system cache write");
                TBLogOnce([@"cachewrite|" stringByAppendingString:bid], @"cachewrite %@", bid);
                return o_cacheImageForIcon ? o_cacheImageForIcon(self, _cmd, mine, icon) : nil;
            }
            // 主题没覆盖 → 全局效果：把系统图加工后再落缓存
            UIImage *g = TBGlobalEffectImage(image, bid);
            if (g && g != image) {
                if (TBDiagDynamicBID(bid)) TBDiagEmit(@"cache.effects", icon, _cmd, image, g, @"system cache write");
                TBLogOnce([@"cachewriteG|" stringByAppendingString:bid], @"cachewrite(全局) %@", bid);
                return o_cacheImageForIcon ? o_cacheImageForIcon(self, _cmd, g, icon) : nil;
            }
        }
    } @catch (NSException *e) { }
    return o_cacheImageForIcon ? o_cacheImageForIcon(self, _cmd, image, icon) : nil;
}

/// 0.18.4：iOS 17 过渡动画（点进 App / 退出回桌面）走的是带 imageAppearance 的新签名缓存，
/// 老签名 imageForIcon:options: 接不到 → 动画期露出原图。这里同样在**缓存写入端**接管。
static id tb_imageForIconApp(id self, SEL _cmd, id icon, id appearance, unsigned long long opt) {
    TB_RENDER_SCOPE();
    TBRemember(self);
    // ★ 1.46：进/退 App 的形变走这条「带 imageAppearance」的读端。以前只接管写端，
    //   缓存里没有这张外观变体（深色外观 = 系统黑底图）时就直通 → 悬浮 Dock 常驻区闪原图。
    { UIImage *m = TBServeReadSide(self, icon); if (m) return m; }
    id r = o_imageForIconApp ? o_imageForIconApp(self, _cmd, icon, appearance, opt) : nil;
    if (!gSystemMaskTemplate && !TBActiveTheme().length && [r isKindOfClass:[UIImage class]]) TBLearnSystemMask(r);
    return r;
}

static id tb_cacheImageForIconApp(id self, SEL _cmd, id image, id icon, id appearance, unsigned long long opt) {
    TB_RENDER_SCOPE();
    TBRemember(self);
    @try {
        NSString *bid = TBBIDFromIcon(icon);
        if (TBDiagDynamicBID(bid)) TBDiagEmit(@"cache.in", icon, _cmd, image, nil, NSStringFromClass([self class]));
        if (bid.length && TBApplyIconForDesktop() && !TBSafeMode()) {
            UIImage *mine = TBFitCached(TBImageForBundle(bid), TBInfoOfCache(self), bid) ?: TBImageForBundle(bid);
            if (mine) {
                if (TBDiagDynamicBID(bid)) TBDiagEmit(@"cache.theme", icon, _cmd, image, mine, @"system cache write");
                TBLogOnce([@"cachewriteA|" stringByAppendingString:bid], @"cachewrite(appearance) %@", bid);
                return o_cacheImageForIconApp ? o_cacheImageForIconApp(self, _cmd, mine, icon, appearance, opt) : nil;
            }
            UIImage *g = TBGlobalEffectImage(image, bid);
            if (g && g != image) {
                if (TBDiagDynamicBID(bid)) TBDiagEmit(@"cache.effects", icon, _cmd, image, g, @"system cache write");
                TBLogOnce([@"cachewriteAG|" stringByAppendingString:bid], @"cachewrite(appearance,全局) %@", bid);
                return o_cacheImageForIconApp ? o_cacheImageForIconApp(self, _cmd, g, icon, appearance, opt) : nil;
            }
        }
    } @catch (NSException *e) { }
    return o_cacheImageForIconApp ? o_cacheImageForIconApp(self, _cmd, image, icon, appearance, opt) : nil;
}

/// 全局效果（默认开）：主题没覆盖的 App，拿系统自己的图标图，套上同一套
/// 形状（遮罩/自定义圆角）与边框/阴影 —— 这样整个桌面观感统一。
static BOOL TBGlobalEffectOn(void) {
    id v = TBPref(@"GlobalIconEffect");
    return v ? [v boolValue] : YES;
}
static UIImage *TBGlobalEffectImage(UIImage *src, NSString *bid) {
    TB_RENDER_SCOPE();
    if (gTBSettingsNativeIcon || !src || !bid.length) return src;
    if (!TBGlobalEffectOn() || TBSafeMode() || !TBEnabled()) return src;
    // 时钟/日历是动态合成图标，不套
    if ([bid isEqualToString:@"com.apple.mobiletimer"] ||
        [bid isEqualToString:@"com.apple.mobilecal"]) return src;
    BOOL anyFx = (TBUseThemeIconMask() || TBMaskCornerRadiusOn() ||
                  TBUseThemeIconOverlay() || TBUseThemeIconShadow());
    if (!anyFx) return src;
    if (src.size.width < 16 || src.size.height < 16) return src;
    NSString *theme = TBActiveTheme() ?: @"";
    // 缓存键带「主题 + 特效参数指纹」：参数没变就一直命中，不必每次刷新都重算所有图标
    // （0.15.48 的日志里 TBReload 一晚上跑了 256 次，每次 gGlobalImgCache = nil，
    //  于是几十个图标全部重新套形状+特效 → 主线程被拖死。现在只在参数真的变了才失效。）
    // ★ 指纹必须覆盖【所有会改变出图的输入】：
    //   - MaskCornerRadius 数值（滑块只改数值不改开关，旧指纹不含它 → 调圆角后全局效果的
    //     图标一直吃旧形状，要换主题/重启才变）
    //   - CustomMaskPath / 主题遮罩文件的修改时间（App 导入遮罩后 TBReload 会清 gMaskThemeImg，
    //     但旧指纹让这里直接命中缓存 → 「已覆盖主题图标的遮罩」永远不更新）
    NSString *maskPath = nil;
    {
        id cmp = TBPref(@"CustomMaskPath");
        if ([cmp isKindOfClass:[NSString class]]) maskPath = cmp;
    }
    NSString *maskSig = @"";
    NSString *maskFile = maskPath.length ? maskPath : nil;
    if (!maskFile) {
        NSString *theme = TBActiveTheme() ?: @"";
        if (theme.length) {
            NSString *dir = TBThemeDir(theme);
            NSString *ib = dir.length ? TBResolveDirCI(dir, @"IconBundles") : nil;
            maskFile = ib.length ? TBFindFileCI(ib, @"Icon.png") : nil;
        }
    }
    if (maskFile.length) {
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:maskFile error:NULL];
        NSDate *mt = at[NSFileModificationDate];
        maskSig = [NSString stringWithFormat:@"@%llu", mt ? (unsigned long long)[mt timeIntervalSince1970] : 0];
    }
    NSString *fp = [NSString stringWithFormat:@"%@|%d%d%d%d|%.2f|%.2f|%@%@",
                    theme,
                    TBUseThemeIconMask() ? 1 : 0, TBMaskCornerRadiusOn() ? 1 : 0,
                    TBUseThemeIconOverlay() ? 1 : 0, TBUseThemeIconShadow() ? 1 : 0,
                    TBGlassOverlayStrength(),
                    TBMaskCornerRadiusOn() ? TBMaskCornerRadius() : 0.0,
                    maskPath.length ? maskPath : @"-",
                    maskSig];
    NSString *key = [NSString stringWithFormat:@"%@|%.0fx%.0f", bid, src.size.width, src.size.height];
    UIImage *hit = nil;
    @synchronized ([UIImage class]) {
        if (!gGlobalImgCache || ![gGlobalCacheTheme isEqualToString:fp]) {
            gGlobalImgCache = [NSMutableDictionary dictionary];
            gGlobalCacheTheme = [fp copy];
        } else if (gGlobalImgCache.count > 4000) {
            [gGlobalImgCache removeAllObjects];
        }
        hit = gGlobalImgCache[key];
    }
    if (hit) return hit;
    UIImage *square = TBArtSquareFilled(src);          // 系统图自带圆角 → 先补方角，形状才听我们的
    UIImage *shaped = TBApplyIconShape(square, NO);
    UIImage *out = TBApplyIconEffects(shaped) ?: shaped;
    if (!out) return src;
    @synchronized ([UIImage class]) {
        if ([gGlobalCacheTheme isEqualToString:fp]) gGlobalImgCache[key] = out;
    }
    TBLogOnce([@"globalfx|" stringByAppendingString:bid], @"全局效果：%@ 已套形状/特效", bid);
    return out;
}

typedef id (*FnInfoImage)(id, SEL, TBImageInfo);
static FnInfoImage o_iconImageWithInfo, o_unmaskedIconImageWithInfo;

/// SnowBoard 的通道：在 SBIcon 这层交出【原始素材】，遮罩/合成/缓存/刷新全交给系统
static id tb_iconImageWithInfo(id self, SEL _cmd, TBImageInfo info) {
    TB_RENDER_SCOPE();
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(self);
        if ([bid isEqualToString:@"com.apple.mobilecal"]) {
            id native = o_iconImageWithInfo ? o_iconImageWithInfo(self, _cmd, info) : nil;
            TBDiagEmit(@"calendar.classic", self, _cmd, native, nil, @"passthrough");
            return native;
        }
        UIImage *img = TBImageForBundle(bid);
        if (img) { gServe++; TBLogOnce([@"iconInfo|" stringByAppendingString:bid ?: @"?"], @"serve iconImageWithInfo %@", bid); return img; }
        UIImage *sys = o_iconImageWithInfo ? o_iconImageWithInfo(self, _cmd, info) : nil;
        UIImage *g = TBGlobalEffectImage(sys, bid);
        if (g && g != sys) { gServe++; return g; }
        return sys;
    }
    return o_iconImageWithInfo ? o_iconImageWithInfo(self, _cmd, info) : nil;
}

static id tb_unmaskedIconImageWithInfo(id self, SEL _cmd, TBImageInfo info) {
    TB_RENDER_SCOPE();
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(self);
        if ([bid isEqualToString:@"com.apple.mobilecal"]) {
            id native = o_unmaskedIconImageWithInfo ? o_unmaskedIconImageWithInfo(self, _cmd, info) : nil;
            TBDiagEmit(@"calendar.classic", self, _cmd, native, nil, @"passthrough");
            return native;
        }
        UIImage *img = TBImageForBundle(bid);
        if (img) { gServe++; TBLogOnce([@"iconInfoU|" stringByAppendingString:bid ?: @"?"], @"serve unmaskedIconImageWithInfo %@", bid); return img; }
        UIImage *sys = o_unmaskedIconImageWithInfo ? o_unmaskedIconImageWithInfo(self, _cmd, info) : nil;
        UIImage *g = TBGlobalEffectImage(sys, bid);
        if (g && g != sys) { gServe++; return g; }
        return sys;
    }
    return o_unmaskedIconImageWithInfo ? o_unmaskedIconImageWithInfo(self, _cmd, info) : nil;
}

static id tb_generateIconImageWithInfo(id self, SEL _cmd, TBImageInfo info) {
    TB_RENDER_SCOPE();
    if (TBApplyIconForDesktop()) {
        NSString *bid = TBBIDFromIcon(self);
        if ([bid isEqualToString:@"com.apple.mobilecal"]) {
            id native = o_generateIconImageWithInfo ? o_generateIconImageWithInfo(self, _cmd, info) : nil;
            TBDiagEmit(@"calendar.classic", self, _cmd, native, nil, @"passthrough");
            return native;
        }
        UIImage *img = TBImageForBundle(bid);
        if (img) { gServe++; TBLog(@"serve generateIconImageWithInfo %@", bid); return img; }
    }
    return o_generateIconImageWithInfo ? o_generateIconImageWithInfo(self, _cmd, info) : nil;
}

// ---- iOS 17.2 日历专用提供者：底图 + 系统原生星期/日期 ----
typedef id (*CalendarProviderImageFn)(id, SEL, TBInfo);
typedef void (*CalendarProviderReloadFn)(id, SEL);
static CalendarProviderImageFn o_calendarProviderImage;
static CalendarProviderImageFn o_calendarProviderUnmasked;
static CalendarProviderReloadFn o_calendarReload;
static BOOL gDoneCalendarProvider;

static UIImage *TBCalendarComposeNative(UIImage *base, UIImage *native, TBInfo info) {
    TB_RENDER_SCOPE();
    if (!base || !native) return base;
    CGFloat w = info.size.width > 1 ? info.size.width : base.size.width;
    CGFloat h = info.size.height > 1 ? info.size.height : w;
    CGFloat scale = info.scale > 0.5 ? info.scale : (base.scale > 0.5 ? base.scale : 3.0);
    CGFloat ink = 0, op = 0;
    if (TBImageDateAreaMetrics(base, &ink, &op)) {
        TBDiagEmit(@"calendar.static", nil, NULL, native, base, @"existing static-date decision");
        return base;
    }
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = scale; fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(w, h) format:fmt];
    UIImage *text = TBCalendarTextOverlay(native, info);
    TBDiagEmit(@"calendar.text", nil, NULL, native, text, @"native text overlay");
    if (!text) return base;
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [base drawInRect:CGRectMake(0, 0, w, h)];
        [text drawInRect:CGRectMake(0, 0, w, h)];
    }];
}

static id tb_calendarProviderImage(id self, SEL _cmd, TBInfo info) {
    TB_RENDER_SCOPE();
    if (TBDiagEnabled()) TBDiagEmit(@"calendar.enter", self, _cmd, nil, nil,
        [NSString stringWithFormat:@"provider size=%.1fx%.1f scale=%.1f depth=%d",
          info.size.width, info.size.height, info.scale, (int)gCalendarProviderDepth]);
    if (gCalendarProviderDepth || !TBEnabled() || TBSafeMode() || !TBActiveTheme().length)
        return o_calendarProviderImage ? o_calendarProviderImage(self, _cmd, info) : nil;
    BOOL previousDepth = gCalendarProviderDepth;
    id native = nil;
    gCalendarProviderDepth = YES;
    @try {
        native = o_calendarProviderImage ? o_calendarProviderImage(self, _cmd, info) : nil;
    } @finally {
        gCalendarProviderDepth = previousDepth;
    }
    UIImage *base = TBCalendarBackgroundForInfo(info);
    TBDiagEmit(@"calendar.native-base", self, _cmd, native, base, @"after original");
    if (base && [native isKindOfClass:[UIImage class]]) {
        UIImage *result = TBCalendarComposeNative(base, native, info);
        TBDiagEmit(@"calendar.result", self, _cmd, result, base, @"composed");
        return result;
    }
    return native ?: base;
}

static id tb_calendarProviderUnmasked(id self, SEL _cmd, TBInfo info) {
    TB_RENDER_SCOPE();
    if (TBDiagEnabled()) TBDiagEmit(@"calendar.enter", self, _cmd, nil, nil,
        [NSString stringWithFormat:@"provider size=%.1fx%.1f scale=%.1f depth=%d",
          info.size.width, info.size.height, info.scale, (int)gCalendarProviderDepth]);
    if (gCalendarProviderDepth || !TBEnabled() || TBSafeMode() || !TBActiveTheme().length)
        return o_calendarProviderUnmasked ? o_calendarProviderUnmasked(self, _cmd, info) : nil;
    BOOL previousDepth = gCalendarProviderDepth;
    id native = nil;
    gCalendarProviderDepth = YES;
    @try {
        native = o_calendarProviderUnmasked ? o_calendarProviderUnmasked(self, _cmd, info) : nil;
    } @finally {
        gCalendarProviderDepth = previousDepth;
    }
    UIImage *base = TBCalendarBackgroundForInfo(info);
    TBDiagEmit(@"calendar.native-base", self, _cmd, native, base, @"after original");
    if (base && [native isKindOfClass:[UIImage class]]) {
        UIImage *result = TBCalendarComposeNative(base, native, info);
        TBDiagEmit(@"calendar.result", self, _cmd, result, base, @"composed");
        return result;
    }
    return native ?: base;
}

static void tb_calendarProviderReload(id self, SEL _cmd) {
    if (o_calendarReload) o_calendarReload(self, _cmd);
}

static void TBInstallCalendarProviderHooks(void) {
    if (gDoneCalendarProvider) return;
    Class cls = NSClassFromString(@"SBCalendarIconImageProvider");
    if (!cls) return;
    gDoneCalendarProvider = YES;
    if (TBHasMethod(cls, @"iconImageWithInfo:"))
        o_calendarProviderImage = (CalendarProviderImageFn)TBHook(cls, @"iconImageWithInfo:",
            (IMP)tb_calendarProviderImage, "日历专用合成");
    if (TBHasMethod(cls, @"unmaskedIconImageWithInfo:"))
        o_calendarProviderUnmasked = (CalendarProviderImageFn)TBHook(cls, @"unmaskedIconImageWithInfo:",
            (IMP)tb_calendarProviderUnmasked, "日历专用合成(unmasked)");
    if (TBHasMethod(cls, @"reloadIconImage"))
        o_calendarReload = (CalendarProviderReloadFn)TBHook(cls, @"reloadIconImage",
            (IMP)tb_calendarProviderReload, "日历专用刷新");
}

// ---- SBIconImageView.setImage:（SnowBoard 核心通道，快捷指令桌面）----
typedef void (*SetImgFn)(id, SEL, id);
static SetImgFn o_setImageOnIconView;

static void tb_setImageOnIconView(id self, SEL _cmd, id image) {
    TB_RENDER_SCOPE();
    if (TBEnabled() && !TBSafeMode()) {
        @try {
            // 阴影（视图层）：图标图像视图自己也挂一份，覆盖"走 setImage: 贴图"的图标
            if ([self isKindOfClass:[UIView class]]) TBApplyIconLayerShadow(self, nil);
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
    TB_RENDER_SCOPE();
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

// ---- 自愈式校验：布局时只做指针比对，图不对才贴一次（收敛后不再触发）----
typedef void (*LayoutFn)(id, SEL);
static LayoutFn o_iconViewLayout;
static char kTBAppliedImageKey;
static char kTBAppliedSourceKey;
static char kTBOverrideImageKey;
static char kTBCrossfadeProxyKey;
static char kTBCrossfadeOwnerKey;
static int gHealDepth = 0;
static NSUInteger gReloadRunSeq = 0;

/// 在子视图里找第一个能 setImage: 的 UIImageView（用于 App 资源库的 pod 视图）
static UIView *TBFindImageViewIn(UIView *root, NSInteger depth) {
    if (!root || depth > 4) return nil;
    if ([root isKindOfClass:NSClassFromString(@"UIImageView")] &&
        [root respondsToSelector:NSSelectorFromString(@"setImage:")]) return root;
    for (UIView *sub in root.subviews) {
        UIView *hit = TBFindImageViewIn(sub, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

/// 取某个图标视图里真正承载图片的视图：
/// 普通图标走 _iconImageView；资源库 pod / 自定义视图走 _customIconImageViewController
static id TBImageViewForIconView(id view) {
    if (!view) return nil;
    @try {
        SEL ivSel = NSSelectorFromString(@"_iconImageView");
        if ([view respondsToSelector:ivSel]) {
            id iv = ((id (*)(id, SEL))objc_msgSend)(view, ivSel);
            if (iv && [iv respondsToSelector:NSSelectorFromString(@"setImage:")]) return iv;
        }
    } @catch (NSException *e) { }
    @try {
        SEL vcSel = NSSelectorFromString(@"_customIconImageViewController");
        if ([view respondsToSelector:vcSel]) {
            id vc = ((id (*)(id, SEL))objc_msgSend)(view, vcSel);
            if (vc) {
                SEL imgSel = NSSelectorFromString(@"imageView");
                if ([vc respondsToSelector:imgSel]) {
                    id c = ((id (*)(id, SEL))objc_msgSend)(vc, imgSel);
                    if (c && [c respondsToSelector:NSSelectorFromString(@"setImage:")]) return c;
                }
                SEL vSel = NSSelectorFromString(@"view");
                if ([vc respondsToSelector:vSel]) {
                    UIView *vv = ((id (*)(id, SEL))objc_msgSend)(vc, vSel);
                    UIView *hit = TBFindImageViewIn(vv, 0);
                    if (hit) return hit;
                }
            }
        }
    } @catch (NSException *e) { }
    return nil;
}

static BOOL TBApplyThemeToIconView(id self) {
    TB_RENDER_SCOPE();
    if (!self) return NO;
    @try {
        id iv = TBImageViewForIconView(self);
        if (!iv || ![iv respondsToSelector:NSSelectorFromString(@"image")] ||
            ![iv respondsToSelector:NSSelectorFromString(@"setImage:")]) {
            TBLogOnce([@"skip-iv|" stringByAppendingString:NSStringFromClass([self class])],
                      @"skip-iv cls=%@", NSStringFromClass([self class]));
            return NO;
        }
        // 阴影（视图层）：不受"主题有没有这张图"影响 —— 全局效果的图标也要有阴影。
        // 图标尺寸不变；参数没变时这个调用是空操作（内部有去重）。
        TBApplyIconLayerShadow(self, (UIView *)iv);
        SEL iconSel = NSSelectorFromString(@"icon");
        id icon = [self respondsToSelector:iconSel] ?
            ((id (*)(id, SEL))objc_msgSend)(self, iconSel) : nil;
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *theme = TBImageForBundle(bid);
        if (!theme) {
            return NO;
        }
        CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(iv, NSSelectorFromString(@"bounds"));
        UIImage *want = theme;
        if (b.size.width > 1 && b.size.height > 1 &&
            (fabs(theme.size.width - b.size.width) > 0.6 || fabs(theme.size.height - b.size.height) > 0.6)) {
            UIImage *cached = objc_getAssociatedObject(iv, &kTBAppliedImageKey);
            UIImage *source = objc_getAssociatedObject(iv, &kTBAppliedSourceKey);
            if (source == theme && cached && fabs(cached.size.width - b.size.width) < 0.6 &&
                fabs(cached.size.height - b.size.height) < 0.6) {
                want = cached;
            } else {
                TBInfo fi; fi.size = b.size; fi.scale = 0; fi.ratio = 0;
                want = TBFitImage(theme, fi) ?: theme;
                objc_setAssociatedObject(iv, &kTBAppliedImageKey, want, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(iv, &kTBAppliedSourceKey, theme, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        UIImage *cur = ((id (*)(id, SEL))objc_msgSend)(iv, NSSelectorFromString(@"image"));
        if (cur == want) return NO;   // 已经是我们的图，什么都不做
        ((void (*)(id, SEL, id))objc_msgSend)(iv, NSSelectorFromString(@"setImage:"), want);
        TBLogOnce([@"heal|" stringByAppendingString:bid ?: @"?"], @"heal %@", bid);
        return YES;
    } @catch (NSException *e) { }
    return NO;
}

static void TBPurgeIcons(id cache, NSArray *icons);

/// 定点刷新可见视图（时钟、文件夹与普通图标分开处理）。
static NSInteger TBHealOneView(UIView *v, NSMutableArray *iconsOut) {
    TB_RENDER_SCOPE();
    if (!v) return 0;
    NSInteger fixed = 0;
    NSString *vcls = NSStringFromClass([v class]);
    // 时钟视图：换主题后要重画。顺序完全照 SnowBoard 的 refreshIconView:fully:：
    //   ① 图标自身清缓存（purgeCachedImages / reloadIconImage）
    //   ② 图片视图 clearCachedImages（无则 _clearCachedImages）
    //   ③ updateClockImages ④ updateImageAnimated:NO ⑤ _updateOverlayImage
    // 只在【这一个时钟视图】上做，对整棵视图树调用会崩。
    if ([vcls rangeOfString:@"Clock"].location != NSNotFound) {
        @try {
            TBClockClearMappedContents(v, NO);
            TBLogOnce([@"clockrefresh|" stringByAppendingString:vcls], @"时钟视图重画 %@", vcls);
            NSMutableString *st = [NSMutableString string];
            SEL iconSel = NSSelectorFromString(@"icon");
            if ([v respondsToSelector:iconSel]) {
                id icon = ((id (*)(id, SEL))objc_msgSend)(v, iconSel);
                if (icon) {
                    if ([icon respondsToSelector:NSSelectorFromString(@"purgeCachedImages")]) {
                        ((void (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(@"purgeCachedImages"));
                        [st appendString:@"icon.purge "];
                    } else if ([icon respondsToSelector:NSSelectorFromString(@"reloadIconImage")]) {
                        ((void (*)(id, SEL))objc_msgSend)(icon, NSSelectorFromString(@"reloadIconImage"));
                        [st appendString:@"icon.reload "];
                    } else {
                        [st appendString:@"icon.none "];
                    }
                }
            }
            if ([v respondsToSelector:NSSelectorFromString(@"clearCachedImages")]) {
                ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"clearCachedImages"));
                [st appendString:@"clear "];
            } else if ([v respondsToSelector:NSSelectorFromString(@"_clearCachedImages")]) {
                ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"_clearCachedImages"));
                [st appendString:@"_clear "];
            } else {
                [st appendString:@"clear.none "];
            }
            if ([v respondsToSelector:NSSelectorFromString(@"updateClockImages")]) {
                ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"updateClockImages"));
            }
            if ([v respondsToSelector:NSSelectorFromString(@"updateImageAnimated:")]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(v, NSSelectorFromString(@"updateImageAnimated:"), NO);
                [st appendString:@"updateImage "];
            }
            if ([v respondsToSelector:NSSelectorFromString(@"_updateOverlayImage")]) {
                ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"_updateOverlayImage"));
                [st appendString:@"overlay "];
            }
            // SnowBoard refreshIconView:fully:YES 的最后一步：把 icon 重新设一遍。
            // 这一下才会让系统重建时钟的组件（表盘才会跟着主题变）。
            {
                id ic = nil;
                if ([v respondsToSelector:NSSelectorFromString(@"icon")]) {
                    ic = ((id (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"icon"));
                }
                SEL a = NSSelectorFromString(@"_setIcon:animated:");
                SEL b = NSSelectorFromString(@"setIcon:animated:");
                if (ic && [v respondsToSelector:a]) {
                    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(v, a, ic, NO);
                    [st appendString:@"setIcon(priv) "];
                } else if (ic && [v respondsToSelector:b]) {
                    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(v, b, ic, NO);
                    [st appendString:@"setIcon "];
                } else {
                    [st appendString:@"setIcon.none "];
                }
            }
            // 不直接写 layer.contents；表盘只通过 contentsImage/squareContentsImage 输入。
            // 这样系统自己的指针合成、缓存生命周期和恢复默认路径保持完整。
            // 方案 D：用系统自己的"图标图已更新"回调逼它重算合成图
            {
                id ic = nil;
                if ([v respondsToSelector:NSSelectorFromString(@"icon")]) {
                    ic = ((id (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"icon"));
                }
                id cache = nil;
                @try { cache = [v valueForKey:@"_iconImageCache"]; } @catch (NSException *e) { }
                if (ic && [v respondsToSelector:NSSelectorFromString(@"iconImageDidUpdate:")]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(v, NSSelectorFromString(@"iconImageDidUpdate:"), ic);
                    [st appendString:@"imgDidUpdate "];
                }
                if (ic && cache &&
                    [v respondsToSelector:NSSelectorFromString(@"iconImageCache:didUpdateImageForIcon:")]) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(
                        v, NSSelectorFromString(@"iconImageCache:didUpdateImageForIcon:"), cache, ic);
                    [st appendString:@"cacheDidUpdate "];
                }
            }
            if ([v respondsToSelector:NSSelectorFromString(@"updateUnanimated")]) {
                @try {
                    ((void (*)(id, SEL))objc_msgSend)(v, NSSelectorFromString(@"updateUnanimated"));
                    [st appendString:@"updateUnanimated "];
                } @catch (NSException *e) { }
            }
            TBLog(@"时钟刷新：%@", st);
        } @catch (NSException *e) { }
    }
    BOOL special = ([vcls rangeOfString:@"Folder"].location != NSNotFound) ||
                   ([vcls rangeOfString:@"Clock"].location != NSNotFound) ||
                   ([vcls rangeOfString:@"Library"].location != NSNotFound);
    if (!special &&
        ([v respondsToSelector:NSSelectorFromString(@"icon")] ||
         [v respondsToSelector:NSSelectorFromString(@"_iconImageView")])) {
        // 完全照 SnowBoard 的 refreshIconView:fully:，对【每个图标视图】跑一遍：
        //   [icon purgeCachedImages / reloadIconImage] → [imageView clearCachedImages /
        //   _clearCachedImages] → updateClockImages → updateImageAnimated:NO → _updateOverlayImage
        // （素材已由 SBIcon 层给出，这几步负责让系统把缓存里的旧图丢掉、重新合成）
        {
            @try {
                SEL iconSel = NSSelectorFromString(@"icon");
                id ic = [v respondsToSelector:iconSel]
                      ? ((id (*)(id, SEL))objc_msgSend)(v, iconSel) : nil;
                if (ic) {
                    if ([ic respondsToSelector:NSSelectorFromString(@"purgeCachedImages")]) {
                        ((void (*)(id, SEL))objc_msgSend)(ic, NSSelectorFromString(@"purgeCachedImages"));
                    } else if ([ic respondsToSelector:NSSelectorFromString(@"reloadIconImage")]) {
                        ((void (*)(id, SEL))objc_msgSend)(ic, NSSelectorFromString(@"reloadIconImage"));
                    }
                }
                id iv = nil;
                @try { iv = [v valueForKey:@"_iconImageView"]; } @catch (NSException *e) { }
                if (!iv) iv = v;
                if ([iv respondsToSelector:NSSelectorFromString(@"clearCachedImages")]) {
                    ((void (*)(id, SEL))objc_msgSend)(iv, NSSelectorFromString(@"clearCachedImages"));
                } else if ([iv respondsToSelector:NSSelectorFromString(@"_clearCachedImages")]) {
                    ((void (*)(id, SEL))objc_msgSend)(iv, NSSelectorFromString(@"_clearCachedImages"));
                }
                if ([iv respondsToSelector:NSSelectorFromString(@"updateClockImages")]) {
                    ((void (*)(id, SEL))objc_msgSend)(iv, NSSelectorFromString(@"updateClockImages"));
                }
                if ([iv respondsToSelector:NSSelectorFromString(@"updateImageAnimated:")]) {
                    ((void (*)(id, SEL, BOOL))objc_msgSend)(iv, NSSelectorFromString(@"updateImageAnimated:"), NO);
                }
                if ([iv respondsToSelector:NSSelectorFromString(@"_updateOverlayImage")]) {
                    ((void (*)(id, SEL))objc_msgSend)(iv, NSSelectorFromString(@"_updateOverlayImage"));
                }
                if ([v respondsToSelector:NSSelectorFromString(@"setIcon:animated:")]) {
                    ((void (*)(id, SEL, id, BOOL))objc_msgSend)(v, NSSelectorFromString(@"setIcon:animated:"), ic, NO);
                }
                fixed++;
            } @catch (NSException *e) { }
        }
        if (iconsOut && iconsOut.count < 250) {
            @try {
                SEL iconSel = NSSelectorFromString(@"icon");
                if ([v respondsToSelector:iconSel]) {
                    id icon = ((id (*)(id, SEL))objc_msgSend)(v, iconSel);
                    if (icon && ![iconsOut containsObject:icon]) [iconsOut addObject:icon];
                }
            } @catch (NSException *e) { }
        }
    }
    // The batch collector already flattened this subtree; recursion here would
    // refresh the same descendants once for every ancestor in the queue.
    (void)iconsOut;
    return fixed;
}

/// Refresh only the live calendar/clock carriers. These cannot use a static
/// override image: after publishing a generation their providers and observers
/// must be asked for a new image even when ordinary overrides succeeded.
static void TBRefreshDynamicIconViewsNow(void) {
    TB_RENDER_SCOPE();
    NSMutableArray<UIView *> *clockViews = [NSMutableArray array];
    NSMutableArray<UIView *> *calendarViews = [NSMutableArray array];
    NSMutableOrderedSet *icons = [NSMutableOrderedSet orderedSet];
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    for (UIWindow *window in [[UIApplication sharedApplication] windows])
        [stack addObject:window];
    NSUInteger scanned = 0;
    while (stack.count && scanned++ < 12000) {
        UIView *view = stack.lastObject; [stack removeLastObject];
        [stack addObjectsFromArray:[view.subviews copy]];
        @try {
            id icon = [view respondsToSelector:NSSelectorFromString(@"icon")] ?
                ((id (*)(id, SEL))objc_msgSend)(view, NSSelectorFromString(@"icon")) : nil;
            NSString *bid = TBBIDFromIcon(icon);
            BOOL calendar = [bid isEqualToString:@"com.apple.mobilecal"];
            BOOL clock = [bid isEqualToString:@"com.apple.mobiletimer"];
            BOOL clockCarrier = [NSStringFromClass([view class]) rangeOfString:@"Clock"].location != NSNotFound;
            if (calendar) [calendarViews addObject:view];
            if (clockCarrier) [clockViews addObject:view];
            if ((calendar || clock || clockCarrier) && icon) [icons addObject:icon];
        } @catch (NSException *e) { }
    }
    // Purging the shared cache alone does not tell live image providers to reload.
    for (id icon in icons) {
        @try {
            SEL purge = NSSelectorFromString(@"purgeCachedImages");
            SEL reload = NSSelectorFromString(@"reloadIconImage");
            if ([icon respondsToSelector:purge]) ((void (*)(id, SEL))objc_msgSend)(icon, purge);
            if ([icon respondsToSelector:reload]) ((void (*)(id, SEL))objc_msgSend)(icon, reload);
        } @catch (NSException *e) { }
    }
    // These are the observer notifications retained by the stable refresh path.
    // Limit them to the two live icons so ordinary icons keep the new transaction.
    for (id cache in gCaches.allObjects) {
        for (id icon in icons) {
            @try {
                SEL update = NSSelectorFromString(@"notifyObserversOfUpdateForIcon:");
                SEL unmasked = NSSelectorFromString(@"notifyObserversOfUnmaskedUpdateForIcon:");
                if ([cache respondsToSelector:update])
                    ((void (*)(id, SEL, id))objc_msgSend)(cache, update, icon);
                if ([cache respondsToSelector:unmasked])
                    ((void (*)(id, SEL, id))objc_msgSend)(cache, unmasked, icon);
            } @catch (NSException *e) { }
        }
    }
    for (UIView *view in calendarViews) {
        // TBImageForBundle intentionally returns nil for mobilecal; refresh its
        // native provider/image view instead of waiting for an override image.
        TBHealOneView(view, nil);
        @try {
            SEL update = NSSelectorFromString(@"_updateIconImageViewAnimated:");
            if ([view respondsToSelector:update])
                ((void (*)(id, SEL, BOOL))objc_msgSend)(view, update, NO);
        } @catch (NSException *e) { }
    }
    for (UIView *view in clockViews) {
        // Target actual live image carriers, not only the enclosing SBIconView.
        // Clear the old mapped face after overrides are removed, then run the
        // stable component refresh sequence, including updateClockImages.
        TBClockClearMappedContents(view, YES);
        TBHealOneView(view, nil);
    }
    TBLog(@"动态图标刷新：日历视图 %lu / 时钟载体 %lu / 图标 %lu（遍历 %lu）",
          (unsigned long)calendarViews.count, (unsigned long)clockViews.count,
          (unsigned long)icons.count, (unsigned long)scanned);
}

static void TBHealAllIconViews(void) {
    // ★ 0.15.90：heal 只在该进程真的有桌面图标时才做。
    //   日志实锤：一次换主题时 Filza 600 视图 / Sileo 491 / RootHide 371 / Preferences 102
    //   全都在各自窗口树里做全量 heal（纯浪费 CPU，还拖垮整机）。只有 SpringBoard 需要。
    static int sHealHost = -1;
    if (sHealHost < 0) {
        NSString *pn = [NSProcessInfo processInfo].processName ?: @"";
        sHealHost = [pn isEqualToString:@"SpringBoard"] ? 1 : 0;
        TBLog(@"heal: 宿主=%@ → %@", pn, sHealHost ? @"执行" : @"跳过（无桌面图标）");
    }
    if (!sHealHost) return;
    if (gHealDepth > 0) return;
    gHealDepth++;
    NSUInteger healSeq = gReloadRunSeq;
    TBLog(@"heal: 开始收集窗口树（分批异步重贴）");
    @try {
        // ① 一次性快照：把所有窗口里要处理的视图按序收平（此刻仍是一次遍历，但只做收集，
        //    不跑每个视图七八步的重贴 msgSend —— 纯收集在主线程是亚毫秒级）
        NSMutableArray *queue = [NSMutableArray array];
        NSMutableArray *stack = [NSMutableArray array];
        for (UIView *w in [[UIApplication sharedApplication] windows]) [stack addObject:w];
        while (stack.count && queue.count < 600) {
            UIView *v = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (!v) continue;
            [queue addObject:v];
            [stack addObjectsFromArray:[v.subviews copy]];
        }
        TBLog(@"heal: 收集 %lu 个视图待处理（每批 24，批间 8ms）", (unsigned long)queue.count);
        if (queue.count == 0) { gHealDepth--; return; }

        // ② 分批异步重贴：每批 36 个视图一批批 dispatch_async，批间让出主线程
        __block NSInteger cursor = 0;          // 已处理到的下标（heal 返回值是修复数不是视图数，用游标推进）
        __block NSInteger fixed = 0;
        __block NSMutableArray *seen = [NSMutableArray array];
        __block NSInteger batch = 0;
        __block void (^drain)(void) = nil;   // 链式强引用在结尾 drain=nil 时断开（队列有限必会走完）
        drain = ^{
            if (healSeq != gReloadRunSeq) { gHealDepth--; drain = nil; return; }
            if (cursor >= (NSInteger)queue.count) {
                TBLog(@"heal: 分批重贴完成 fixed=%ld seen=%lu（%ld 批）",
                      (long)fixed, (unsigned long)seen.count, (long)batch);
                gHealDepth--;
                drain = nil;
                return;
            }
            NSInteger start = cursor;
            NSInteger end = MIN(start + 24, (NSInteger)queue.count);
            for (NSInteger i = start; i < end; i++) {
                UIView *v = queue[i];
                if (!v.window && ![v isKindOfClass:[UIWindow class]]) continue;   // 已离屏
                fixed += TBHealOneView(v, seen);
            }
            cursor = end;
            batch++;
            if (batch <= 3 || batch % 5 == 0) {
                TBLog(@"heal: 批 %ld 完成（%ld/%lu）", (long)batch, (long)end, (unsigned long)queue.count);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.008 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), drain);
        };
        dispatch_async(dispatch_get_main_queue(), drain);
    } @catch (NSException *e) {
        TBLog(@"heal: 异常 %@", e.reason);
        gHealDepth--;
    }
}

static __weak UIView *gLastClockView;   // 最近一次看到的时钟视图

static void tb_iconViewLayoutSubviews(id self, SEL _cmd) {
    TB_RENDER_SCOPE();
    if (o_iconViewLayout) o_iconViewLayout(self, _cmd);
    if (!TBApplyIconForDesktop() || TBSafeMode() || !TBEnabled()) return;

    // ★ 0.18.20（换路·第一步）：优先用系统自带的「覆盖图」入口 —— 装上就生效、优先级最高，
    //   不再靠事后改 CALayer.contents。方法不存在时退回原来的做法。
    @try {
        if (!gSeenIconViews) gSeenIconViews = [NSHashTable weakObjectsHashTable];
        [gSeenIconViews addObject:self];
        id icon = [self valueForKey:@"icon"];
        UIImage *img = TBThemedForIconObject(icon);
        SEL sSet = NSSelectorFromString(@"setOverrideImage:");
        if (img && icon && [self respondsToSelector:sSet]) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            ((void (*)(id, SEL, id))objc_msgSend)(self, sSet, img);
            objc_setAssociatedObject(self, &kTBOverrideImageKey, img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SEL sApp = NSSelectorFromString(@"setOverrideIconImageAppearance:");
            if ([self respondsToSelector:sApp]) {
                id light = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"SBHIconImageAppearance"),
                                                           NSSelectorFromString(@"lightAppearance"));
                if (light) ((void (*)(id, SEL, id))objc_msgSend)(self, sApp, light);
            }
            [CATransaction commit];
            // 主动把主题图写进图标缓存（17.2 上是 cacheImage:forIcon:）——缓存里一开始就是主题图
            id iv = [self valueForKey:@"_iconImageView"];
            id cache = (iv && [iv respondsToSelector:NSSelectorFromString(@"iconImageCache")])
                     ? [iv valueForKey:@"iconImageCache"] : nil;
            if (cache && [cache respondsToSelector:NSSelectorFromString(@"cacheImage:forIcon:")])
                ((void (*)(id, SEL, id, id))objc_msgSend)(cache, NSSelectorFromString(@"cacheImage:forIcon:"), img, icon);
            TBLogOnce([@"ovr|" stringByAppendingString:TBBIDFromIcon(icon) ?: @"?"], @"overrideImage 已设");
            return;
        }
    } @catch (NSException *e) { }
    TBApplyThemeToIconView(self);
}

// ★ 0.18.20（换路）：iOS 17 起图标是走这些【带 traitCollection/context/options】的现代选择子生成的
//   （我们以前只挂了老的单参数 iconImageWithInfo: → 生成那一刻没被接管 → 首帧是原图）。
//   这里补挂它们；方法不存在就跳过（TBHasMethod 守护）。
typedef id (*FnImgTCO)(id, SEL, TBImageInfo, id, id, unsigned long long);
typedef id (*FnImgTO)(id, SEL, TBImageInfo, id, unsigned long long);
static FnImgTCO o_imgTCO = NULL;
static FnImgTO  o_imgTO = NULL;

static id TBThemedForIconObject(id icon) {
    TB_RENDER_SCOPE();
    if (!TBEnabled() || TBSafeMode() || !TBApplyIconForDesktop()) return nil;
    @try {
        NSString *bid = TBBIDFromIcon(icon);
        if (!bid.length) return nil;
        return TBImageForBundle(bid);
    } @catch (NSException *e) { return nil; }
}

static id tb_imgTCO(id self, SEL _cmd, TBImageInfo info, id tc, id ctx, unsigned long long opt) {
    TB_RENDER_SCOPE();
    UIImage *m = TBThemedForIconObject(self);
    if (m) { TBLogOnce(@"modern|tco", @"现代取图 tco 已接管"); return m; }
    id native = o_imgTCO ? o_imgTCO(self, _cmd, info, tc, ctx, opt) : nil;
    if (TBDiagEnabled() && TBDiagDynamicBID(TBBIDFromIcon(self)))
        TBDiagEmit(@"icon.modern-original", self, _cmd, native, nil, @"passthrough");
    return native;
}
static id tb_imgTO(id self, SEL _cmd, TBImageInfo info, id tc, unsigned long long opt) {
    TB_RENDER_SCOPE();
    UIImage *m = TBThemedForIconObject(self);
    if (m) { TBLogOnce(@"modern|to", @"现代取图 to 已接管"); return m; }
    id native = o_imgTO ? o_imgTO(self, _cmd, info, tc, opt) : nil;
    if (TBDiagEnabled() && TBDiagDynamicBID(TBBIDFromIcon(self)))
        TBDiagEmit(@"icon.modern-original", self, _cmd, native, nil, @"passthrough");
    return native;
}

// ★ 1.46：退出/进入 App 的形变（图标缩放 / SBIconImageCrossfadeView）取的是 SBIcon 的
//   「方形原图」squareContentsImage —— 它是未被主题接管的（我们只挂过 SBLiveIconImageView
//   上同名方法给时钟用）。系统原实现返回未遮罩素材，深色外观下就是那块黑底图 →
//   悬浮 Dock 常驻区在退出动画里闪原图。这里把它也换成主题图。
typedef id (*SquareContentsFn)(id, SEL);
static SquareContentsFn o_squareContentsIcon = NULL;

static id tb_squareContentsIcon(id self, SEL _cmd) {
    TB_RENDER_SCOPE();
    if (TBEnabled() && !TBSafeMode() && TBApplyIconForDesktop()) {
        @try {
            NSString *bid = TBBIDFromIcon(self);
            UIImage *m = bid.length ? TBImageForBundle(bid) : nil;
            if (m) {
                TBLogOnce([@"sqc|" stringByAppendingString:bid], @"方形原图接管 %@", bid);
                return m;
            }
        } @catch (NSException *e) { }
    }
    return o_squareContentsIcon ? o_squareContentsIcon(self, _cmd) : nil;
}

/// 悬浮 Dock 的过渡图兼容。SBIconImageCrossfadeView 在进/退 App 时先把源图层置零、
/// 再用自己的 proxy 层贴原图 → 我们提前在 proxy 里贴主题图，首帧就不再闪系统原图。
/// 只把载体换成主题图，不改任何转场几何/时机；老设备如果类/签名不匹配则跳过，
/// 保留系统原实现。
typedef id (*TBCrossfadeObjectFn)(id, SEL);
typedef void (*TBCrossfadeVoidFn)(id, SEL);
typedef void (*TBCrossfadeFractionFn)(id, SEL, CGFloat);
static TBCrossfadeVoidFn o_crossfadePrepare;
static TBCrossfadeFractionFn o_crossfadeFade;
static TBCrossfadeVoidFn o_crossfadeCleanup;
static BOOL gDoneCrossfade;
static __thread unsigned int gCrossfadeDepth;
static NSHashTable *gCrossfadeStates;

static void TBCrossfadeDetach(CALayer *source, CALayer *proxy, float opacity) {
    if (!source && !proxy) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    @try {
        // 本引擎只写过 0；若系统已设置新的非零透明度，保留系统最新值。
        if (source && source.opacity == 0.0f) source.opacity = opacity;
        [proxy removeFromSuperlayer];
    } @finally { [CATransaction commit]; }
}

@interface TBCrossfadeState : NSObject
@property (nonatomic, strong) CALayer *source;
@property (nonatomic, strong) CALayer *proxy;
@property (nonatomic, weak) UIView *imageView;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic) float nativeOpacity;
@property (nonatomic) BOOL active;
@end
@implementation TBCrossfadeState
- (void)restore {
    if (!self.active) return;
    self.active = NO;
    TBCrossfadeDetach(self.source, self.proxy, self.nativeOpacity);
}
- (void)dealloc {
    if (!_active) return;
    CALayer *source = _source, *proxy = _proxy;
    float opacity = _nativeOpacity;
    if ([NSThread isMainThread]) TBCrossfadeDetach(source, proxy, opacity);
    else dispatch_async(dispatch_get_main_queue(), ^{ TBCrossfadeDetach(source, proxy, opacity); });
}
@end

static UIView *TBCrossfadeImageView(id crossfade) {
    if (![crossfade isKindOfClass:[UIView class]]) return nil;
    SEL getter = NSSelectorFromString(@"iconImageView");
    if (![crossfade respondsToSelector:getter]) return nil;
    id iv = ((TBCrossfadeObjectFn)objc_msgSend)(crossfade, getter);
    return [iv isKindOfClass:[UIView class]] ? iv : nil;
}

static void TBCrossfadeRestore(id crossfade) {
    TBCrossfadeState *state = objc_getAssociatedObject(crossfade, &kTBCrossfadeProxyKey);
    [state restore];
    objc_setAssociatedObject(crossfade, &kTBCrossfadeProxyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void TBCrossfadeRestoreAll(void) {
    // 仅由主线程的主题切换批次调用。
    for (TBCrossfadeState *state in gCrossfadeStates.allObjects) [state restore];
    [gCrossfadeStates removeAllObjects];
}

static void TBCrossfadeInstallProxy(id crossfade) {
    if (!TBEnabled() || TBSafeMode() || !TBActiveTheme().length) return;
    UIView *iv = TBCrossfadeImageView(crossfade);
    if (!iv || ![iv isDescendantOfView:crossfade]) return;
    SEL iconGetter = NSSelectorFromString(@"icon");
    SEL squareGetter = NSSelectorFromString(@"squareContentsImage");
    if (![iv respondsToSelector:iconGetter] || ![iv respondsToSelector:squareGetter]) return;
    id icon = ((TBCrossfadeObjectFn)objc_msgSend)(iv, iconGetter);
    NSString *bid = TBBIDFromIcon(icon);
    // 实时时钟保留原合成图/指针，不用静态主题底图盖住它。
    if (!bid.length || [bid isEqualToString:@"com.apple.mobiletimer"]) return;
    id original = ((TBCrossfadeObjectFn)objc_msgSend)(iv, squareGetter);
    if (![original isKindOfClass:[UIImage class]] || ![(UIImage *)original CGImage]) return;
    UIImage *native = original;
    if (!isfinite(native.size.width) || !isfinite(native.size.height) ||
        native.size.width < 1 || native.size.height < 1 ||
        native.size.width > 512 || native.size.height > 512) return;
    UIImage *image = TBImageForBundle(bid);
    if (!image) return;
    TBInfo info = { native.size, native.scale > 0.5 ? native.scale : 3.0, 0 };
    image = TBFitCached(image, info, [@"transition|" stringByAppendingString:bid]);
    if (!image.CGImage) return;
    CALayer *container = ((UIView *)crossfade).layer;
    CALayer *source = iv.layer;
    CGRect frame = [iv convertRect:iv.bounds toView:crossfade];
    if (!source.contents || !isfinite(frame.origin.x) || !isfinite(frame.origin.y) ||
        !isfinite(frame.size.width) || !isfinite(frame.size.height) || frame.size.width < 1 || frame.size.height < 1 ||
        !CATransform3DIsAffine(source.transform) || fabs(iv.transform.b) > 0.0001 || fabs(iv.transform.c) > 0.0001) return;
    NSHashTable *owners = objc_getAssociatedObject(source, &kTBCrossfadeOwnerKey);
    TBCrossfadeState *owner = owners.anyObject;
    if (owner.active) return; // 同一源图层不可同时被两段转场隐藏。
    TBCrossfadeState *state = [TBCrossfadeState new];
    state.source = source; state.imageView = iv; state.image = image;
    state.nativeOpacity = source.opacity;
    state.proxy = [CALayer layer];
    owners = [NSHashTable weakObjectsHashTable]; [owners addObject:state];
    objc_setAssociatedObject(source, &kTBCrossfadeOwnerKey, owners, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(crossfade, &kTBCrossfadeProxyKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gCrossfadeStates) gCrossfadeStates = [NSHashTable weakObjectsHashTable];
    [gCrossfadeStates addObject:state];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    @try {
        CALayer *proxy = state.proxy;
        proxy.name = @"com.ning.themeboard.transition";
        proxy.frame = frame;
        proxy.contents = (__bridge id)image.CGImage;
        proxy.contentsScale = image.scale;
        proxy.contentsGravity = source.contentsGravity;
        proxy.contentsRect = source.contentsRect; proxy.contentsCenter = source.contentsCenter;
        proxy.minificationFilter = source.minificationFilter; proxy.magnificationFilter = source.magnificationFilter;
        proxy.cornerRadius = source.cornerRadius; proxy.masksToBounds = source.masksToBounds;
        proxy.opacity = source.opacity; proxy.hidden = source.hidden;
        [container addSublayer:proxy];
        state.active = YES;
        source.opacity = 0.0f;
    } @finally { [CATransaction commit]; }
}

static void tb_crossfadePrepare(id self, SEL _cmd) {
    if (![NSThread isMainThread] || gCrossfadeDepth) { if (o_crossfadePrepare) o_crossfadePrepare(self, _cmd); return; }
    gCrossfadeDepth++;
    @try {
        @try { TBCrossfadeRestore(self); } @catch (NSException *e) { }
        if (o_crossfadePrepare) o_crossfadePrepare(self, _cmd);
        @try { TBCrossfadeInstallProxy(self); } @catch (NSException *e) { TBCrossfadeRestore(self); }
    } @finally { gCrossfadeDepth--; }
}
static void tb_crossfadeFade(id self, SEL _cmd, CGFloat fraction) {
    if (![NSThread isMainThread] || gCrossfadeDepth) { if (o_crossfadeFade) o_crossfadeFade(self, _cmd, fraction); return; }
    gCrossfadeDepth++;
    @try {
        TBCrossfadeState *state = objc_getAssociatedObject(self, &kTBCrossfadeProxyKey);
        @try {
            BOOL valid = state.active &&
                state.imageView == TBCrossfadeImageView(self) &&
                TBEnabled() && !TBSafeMode();
            if (state && !valid) { TBCrossfadeRestore(self); state = nil; }
            // 原实现每次看到的都是上次的原生透明度，不能把我们写入的 0 当作下一帧输入。
            if (state.active) { [CATransaction begin]; [CATransaction setDisableActions:YES]; state.source.opacity = state.nativeOpacity; [CATransaction commit]; }
        } @catch (NSException *e) { TBCrossfadeRestore(self); state = nil; }
        if (o_crossfadeFade) o_crossfadeFade(self, _cmd, fraction);
        if (!state.active) return;
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        @try {
            state.nativeOpacity = state.source.opacity;
            state.proxy.opacity = state.nativeOpacity; state.proxy.hidden = state.source.hidden;
            state.source.opacity = 0.0f;
        } @finally { [CATransaction commit]; }
    } @finally { gCrossfadeDepth--; }
}
static void tb_crossfadeCleanup(id self, SEL _cmd) {
    @try { if ([NSThread isMainThread]) TBCrossfadeRestore(self); } @catch (NSException *e) { }
    if (![NSThread isMainThread]) {
        TBCrossfadeState *state = objc_getAssociatedObject(self, &kTBCrossfadeProxyKey);
        dispatch_async(dispatch_get_main_queue(), ^{ [state restore]; });
    }
    if (o_crossfadeCleanup) o_crossfadeCleanup(self, _cmd);
}

static BOOL TBCrossfadeMethodMatches(Class cls, NSString *name, const char *type) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(name));
    return method && strcmp(method_getTypeEncoding(method), type) == 0;
}
static void TBInstallCrossfadeHooks(void) {
    if (gDoneCrossfade || ![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) return;
    Class cls = NSClassFromString(@"SBIconImageCrossfadeView");
    Class iv = NSClassFromString(@"SBIconImageView");
    if (!cls || !iv || ![cls isSubclassOfClass:[UIView class]] || ![iv isSubclassOfClass:[UIView class]]) return;
    // 来自已读参考源码的 ABI；不符时保留系统原实现。
    if (!TBCrossfadeMethodMatches(cls, @"prepareGeometry", "v16@0:8") ||
        !TBCrossfadeMethodMatches(cls, @"setSourceFadeFraction:", "v24@0:8d16") ||
        !TBCrossfadeMethodMatches(cls, @"cleanup", "v16@0:8") ||
        !TBCrossfadeMethodMatches(cls, @"iconImageView", "@16@0:8") ||
        !TBCrossfadeMethodMatches(iv, @"icon", "@16@0:8") ||
        !TBCrossfadeMethodMatches(iv, @"squareContentsImage", "@16@0:8")) return;
    // 若方法继承自父类，先在目标类物化槽位，避免 method_setImplementation 改到父类。
    for (NSString *name in @[@"prepareGeometry", @"setSourceFadeFraction:", @"cleanup"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(cls, selector);
        class_addMethod(cls, selector, method_getImplementation(method), method_getTypeEncoding(method));
    }
    gDoneCrossfade = YES; // TBInstall 会重试；必须在任何替换前置位。
    o_crossfadePrepare = (TBCrossfadeVoidFn)TBHook(cls, @"prepareGeometry", (IMP)tb_crossfadePrepare, "Dock crossfade.prepare");
    o_crossfadeFade = (TBCrossfadeFractionFn)TBHook(cls, @"setSourceFadeFraction:", (IMP)tb_crossfadeFade, "Dock crossfade.fade");
    o_crossfadeCleanup = (TBCrossfadeVoidFn)TBHook(cls, @"cleanup", (IMP)tb_crossfadeCleanup, "Dock crossfade.cleanup");
}

/// 批量刷新时对登记过的图标视图设置或清理本引擎的 override，
/// 未覆盖的旧图标清除覆盖后让系统重取，避免布局热路径同步刷新自身。
static NSInteger TBReapplyIconsLight(void) {
    TB_RENDER_SCOPE();
    NSArray *views = gSeenIconViews ? gSeenIconViews.allObjects : @[];
    NSInteger n = 0;
    for (UIView *v in views) {
        @try {
            id icon = [v valueForKey:@"icon"];
            UIImage *img = TBThemedForIconObject(icon);
            UIImage *previous = objc_getAssociatedObject(v, &kTBOverrideImageKey);
            SEL setOverride = NSSelectorFromString(@"setOverrideImage:");
            if (!img) {
                // 只清除本引擎设置过的覆盖图；系统或其他插件设置的覆盖不动。
                if (!previous || ![v respondsToSelector:setOverride]) continue;
                objc_setAssociatedObject(v, &kTBOverrideImageKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                ((void (*)(id, SEL, id))objc_msgSend)(v, setOverride, nil);
                // 布局时图像和浅色外观一起覆盖；撤销时必须一起交还系统。
                SEL clearAppearance = NSSelectorFromString(@"setOverrideIconImageAppearance:");
                if ([v respondsToSelector:clearAppearance])
                    ((void (*)(id, SEL, id))objc_msgSend)(v, clearAppearance, nil);
                SEL purge = NSSelectorFromString(@"purgeCachedImages");
                if (icon && [icon respondsToSelector:purge]) ((void (*)(id, SEL))objc_msgSend)(icon, purge);
                SEL update = NSSelectorFromString(@"_updateIconImageViewAnimated:");
                if ([v respondsToSelector:update]) ((void (*)(id, SEL, BOOL))objc_msgSend)(v, update, NO);
                n++;
                continue;
            }
            if ([v respondsToSelector:setOverride]) {
                ((void (*)(id, SEL, id))objc_msgSend)(v, setOverride, img);
                objc_setAssociatedObject(v, &kTBOverrideImageKey, img, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            static const char *inv[] = { "purgeCachedImages", "invalidateIconImageCache", "_invalidateIconImageCache", "reloadIconImage", "_reloadIconImage" };
            for (size_t i = 0; i < sizeof(inv)/sizeof(inv[0]); i++) {
                SEL sel = NSSelectorFromString(@(inv[i]));
                if (icon && [icon respondsToSelector:sel])
                    ((void (*)(id, SEL))objc_msgSend)(icon, sel);
            }
            n++;
        } @catch (NSException *e) { }
    }
    TBLog(@"轻量刷新：重设 override %ld 个图标视图（不重贴、不刷桌面）", (long)n);
    return n;
}

// ---- 换图标后重贴（拖拽放置/资源库→桌面 时系统直接贴原始图，读端 hook 管不到）----
// 只在 SBIconView 更换 icon 时触发一次，不在 getter 热路径里，所以不会像
// 之前那样引起 SpringBoard 闪屏重启。
typedef void (*SetIconFn)(id, SEL, id, BOOL);
static SetIconFn o_setIconAnimated;

static void tb_setIconAnimated(id self, SEL _cmd, id icon, BOOL animated) {
    TB_RENDER_SCOPE();
    if (o_setIconAnimated) o_setIconAnimated(self, _cmd, icon, animated);
    if (!TBApplyIconForDesktop() || TBSafeMode() || !TBEnabled()) return;
    @try {
        NSString *bid = TBBIDFromIcon(icon);
        UIImage *theme = TBImageForBundle(bid);
        if (!theme) return;
        TBLogOnce([@"reapply|" stringByAppendingString:bid ?: @"?"], @"reapply %@", bid);
        TBThemeRenderState *sourceState = TBCurrentRenderState();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (sourceState != TBCommittedState()) return;
            TB_RENDER_WITH(sourceState);
            @try {
                if ([self respondsToSelector:NSSelectorFromString(@"icon")] &&
                    ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"icon")) != icon) return;
                id iv = [self valueForKey:@"_iconImageView"];
                if (!iv || ![iv respondsToSelector:NSSelectorFromString(@"setImage:")]) return;
                SEL boundsSel = NSSelectorFromString(@"bounds");
                CGRect b = ((CGRect (*)(id, SEL))objc_msgSend)(iv, boundsSel);
                TBInfo fi;
                fi.size = (b.size.width > 1 && b.size.height > 1) ? b.size : CGSizeMake(60, 60);
                fi.scale = 0; fi.ratio = 0;
                UIImage *fit = TBFitImage(theme, fi);
                if (fit) {
                    ((void (*)(id, SEL, id))objc_msgSend)(iv, NSSelectorFromString(@"setImage:"), fit);
                }
            } @catch (NSException *e) { }
        });
    } @catch (NSException *e) { }
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
    TB_RENDER_SCOPE();
    if (gTBSettingsNativeIcon || !bid.length || !TBEnabled() || TBSafeMode()) return NULL;
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

static id tb_isGeneration(id self, SEL _cmd, id *recordIdentifiers) {
    id original = o_isGeneration ? o_isGeneration(self, _cmd, recordIdentifiers) : nil;
    if (!original || !TBEnabled() || TBSafeMode()) return original;
    int reason = 0;
    id out = TBReplaceGeneratedImage(self, original, &reason);
    if (out != original) gServe++;
    return out;
}

static id tb_isGenerateImage(id self, SEL _cmd) {
    id original = o_isGenerateImage ? o_isGenerateImage(self, _cmd) : nil;
    if (!original || !TBEnabled() || TBSafeMode()) return original;
    int reason = 0;
    id out = TBReplaceGeneratedImage(self, original, &reason);
    if (out != original) gServe++;
    return out;
}

// ---- IFImage（IconServices 图标服务，快捷指令/资源库共用）----
typedef id (*IFImgFn)(id, SEL, id);
typedef id (*IFSizeFn)(id, SEL, CGSize, double);
static IFImgFn o_ifImgDescriptor;
static IFSizeFn o_ifImgSize;

static id tb_ifImgDescriptor(id self, SEL _cmd, id descriptor) {
    TB_RENDER_SCOPE();
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
    TB_RENDER_SCOPE();
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

typedef UIImage *(*UIActivityIconFn)(id, SEL, NSString *);
static UIActivityIconFn o_activityIcon;

/// ShareSheet.framework/UIActivity：分享面板里每个 App 的图标
static UIImage *tb_activityImageForBID(id self, SEL _cmd, NSString *bid) {
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
    TB_RENDER_SCOPE();
    if (!TBEnabled() || TBSafeMode()) {
        return o_isiconCG ? o_isiconCG(self, _cmd, descriptor) : NULL;
    }
    @try {

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
    TB_RENDER_SCOPE();
    if (!TBEnabled() || TBSafeMode()) {
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

/// 动态图标（时钟/日历）在主题 Bundles/ 里找对应素材：
/// ClockIcon* / CalendarIcon*，优先 @3x > @2x > 1x
static NSString *TBDynamicResourcePath(NSString *bid) {
    TB_RENDER_SCOPE();
    if (!bid.length || !TBIsDynamicBID(bid)) return nil;
    NSString *prefix = [bid isEqualToString:@"com.apple.mobiletimer"] ? @"clockicon" : @"calendaricon";
    [gLock lock];
    TBLoadIndex();
    NSMutableDictionary *res = TBThemeBundleRes();   // 无主题 → 清空
    [gLock unlock];
    if (!res.count) return nil;

    (void)prefix;
    // 明确按名字优先级挑，支持多种后缀变体（_1024/_1200/@3x 等）
    NSArray<NSString *> *baseCandidates = [bid isEqualToString:@"com.apple.mobiletimer"]
        ? @[@"clockiconbackgroundsquare", @"clockiconbackground", @"clockicon"]
        : @[@"calendariconbackgroundsquare", @"calendariconbackground", @"calendaricon"];
    for (NSString *base in baseCandidates) {
        NSString *lowerBase = [base lowercaseString];
        NSString *best = nil;
        NSInteger bestLen = 0;
        for (NSString *key in res) {
            if (![key hasPrefix:lowerBase]) continue;
            if (![key hasSuffix:@".png"]) continue;
            // 命中即可，越短越准（clockiconbackgroundsquare.png 优先于 ..._1024.png）
            NSInteger len = (NSInteger)key.length;
            if (!best || len < bestLen) { best = res[key]; bestLen = len; }
        }
        if (best) return best;
    }
    return nil;
}

// Settings root uses IconServices SwiftUI rather than PSTableCell for App rows.
// Keep all additional work confined to Preferences and actual application icons.
typedef id (*TBSettingsISSizeFn)(id, SEL, CGSize, double);
typedef void (*TBSettingsISAsyncFn)(id, SEL, id, id);
static IMP o_settingsISSize, o_settingsISAsync;

static NSString *TBSettingsISBundleID(id icon) {
    NSString *direct=TBBIDFromISIcon(icon);
    if (TBBIDLooksUsable(direct)) return direct;
    id identity=nil;
    @try { identity=[icon valueForKey:@"_identity"]; } @catch (NSException *exception) {}
    for (NSString *key in @[@"bundleIdentifier",@"applicationBundleIdentifier",@"resourceIdentifier"]) {
        @try {
            id value=[identity valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && TBBIDLooksUsable(value)) return value;
        } @catch (NSException *exception) {}
    }
    return nil;
}

static UIImage *TBSettingsISImage(NSString *bid, CGSize size, double scale) {
    TB_RENDER_SCOPE();
    if (gTBSettingsNativeIcon || !TBEnabled() || TBSafeMode() ||
        ![bid isKindOfClass:[NSString class]] || ![bid containsString:@"."]) return nil;
    if (!isfinite(size.width) || !isfinite(size.height) ||
        size.width < 1 || size.height < 1 || size.width > 512 || size.height > 512 ||
        !isfinite(scale) || scale < 1 || scale > 4) return nil;
    // App-image identity comes from ISIcon itself, never a preference owner ID.
    UIImage *image = TBImageForBundle(bid);
    // Calendar's desktop provider stays untouched; Settings requests its static App icon.
    if (!image && [bid isEqualToString:@"com.apple.mobilecal"]) {
        [gLock lock];
        TBLoadIndex();
        NSString *path = gIndex[bid];
        [gLock unlock];
        if (path.length) image = TBIconFinalImage([[UIImage alloc] initWithContentsOfFile:path]);
    }
    if (!image) return nil;
    TBInfo info = { size, scale, 0 };
    return TBFitImage(image, info);
}

static id TBSettingsISObjectImage(id icon, id original) {
    if (![original isKindOfClass:[UIImage class]]) return original;
    UIImage *native = original;
    UIImage *image = TBSettingsISImage(TBSettingsISBundleID(icon), native.size, native.scale);
    return image ?: original;
}

static id tb_settingsISSize(id self, SEL selector, CGSize size, double scale) {
    id native = o_settingsISSize ? ((TBSettingsISSizeFn)o_settingsISSize)(self, selector, size, scale) : nil;
    // Preserve the system's returned object type; unknown wrappers pass through.
    if (![native isKindOfClass:[UIImage class]]) return native;
    UIImage *image = TBSettingsISImage(TBSettingsISBundleID(self), ((UIImage *)native).size,
                                      ((UIImage *)native).scale);
    return image ?: native;
}

struct TBSettingsBlockHeader {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    const unsigned long *descriptor;
};
static BOOL TBSettingsCGCompletionMatches(id block) {
    if (!block) return NO;
    const struct TBSettingsBlockHeader *header = (__bridge const void *)block;
    if (!(header->flags & (1 << 30)) || !header->descriptor) return NO;
    const unsigned char *entry = (const unsigned char *)header->descriptor + 2 * sizeof(unsigned long);
    if (header->flags & (1 << 25)) entry += 2 * sizeof(void *);
    const char *types = *(const char * const *)entry;
    if (!types) return NO;
    @try {
        NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:types];
        if (!signature || signature.numberOfArguments != 2 ||
            *TBPSUnqualifiedType(signature.methodReturnType) != 'v') return NO;
        const char *argument = TBPSUnqualifiedType([signature getArgumentTypeAtIndex:1]);
        return strcmp(argument, @encode(CGImageRef)) == 0;
    } @catch (NSException *exception) { return NO; }
}

static void tb_settingsISAsync(id self, SEL selector, id descriptor, id completion) {
    if (!o_settingsISAsync) return;
    TBSettingsISAsyncFn native = (TBSettingsISAsyncFn)o_settingsISAsync;
    if (gTBSettingsNativeIcon || !TBSettingsCGCompletionMatches(completion)) {
        native(self, selector, descriptor, completion);
        return;
    }
    NSString *bid = TBSettingsISBundleID(self);
    if (![bid isKindOfClass:[NSString class]] || ![bid containsString:@"."]) {
        native(self, selector, descriptor, completion);
        return;
    }
    // Keep native delivery timing, queue and single completion. The block ABI is
    // checked above; unfamiliar signatures are never wrapped or guessed.
    void (^callback)(CGImageRef) = completion;
    native(self, selector, descriptor, ^(CGImageRef original) {
        UIImage *replacement = nil;
        @try {
            if (original) {
                double scale = [UIScreen mainScreen].scale;
                @try {
                    id value = [descriptor valueForKey:@"sanitizedScale"];
                    if ([value respondsToSelector:@selector(doubleValue)]) scale = [value doubleValue];
                } @catch (NSException *exception) {}
                if (isfinite(scale) && scale >= 1 && scale <= 4) {
                    CGSize size = CGSizeMake(CGImageGetWidth(original) / scale,
                                             CGImageGetHeight(original) / scale);
                    replacement = TBSettingsISImage(bid, size, scale);
                }
            }
        } @catch (NSException *exception) { replacement = nil; }
        callback(replacement.CGImage ?: original);
    });
}

static BOOL TBSettingsISSizeMatches(Class cls) {
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(@"imageForSize:scale:"));
    if (!TBPSMethodMatches(method, "@@:{d")) return NO;
    char *type = method_copyArgumentType(method, 2);
    BOOL matches = type && strcmp(TBPSUnqualifiedType(type), @encode(CGSize)) == 0;
    free(type);
    return matches;
}

static id tb_isicon_image(id self, SEL _cmd, id descriptor) {
    TB_RENDER_SCOPE();
    id ret = o_isiconImg ? o_isiconImg(self, _cmd, descriptor) : nil;
    if (!TBEnabled() || TBSafeMode()) return ret;
    if ([TBProcName() isEqualToString:@"Preferences"])
        return TBSettingsISObjectImage(self, ret);

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
    TB_RENDER_SCOPE();
    id ret = o_isiconImg2 ? o_isiconImg2(self, _cmd, descriptor) : nil;
    if (!TBEnabled() || TBSafeMode()) return ret;
    if ([TBProcName() isEqualToString:@"Preferences"])
        return TBSettingsISObjectImage(self, ret);

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
typedef UIImage *(*ImgNameBundleFn)(id, SEL, NSString *, NSBundle *);
typedef UIImage *(*ImgNameBundleTraitFn)(id, SEL, NSString *, NSBundle *, id);
static ImgNameFn o_imageNamed, o_imageWithFile;
static ImgNameBundleFn o_imageNamedInBundle;
static ImgNameBundleTraitFn o_imageNamedInBundleTrait;
typedef UIImage *(*AppIconFn)(id, SEL, id, int);
typedef UIImage *(*AppIconScaleFn)(id, SEL, id, int, double);
static AppIconFn o_appIcon;
static AppIconScaleFn o_appIconScale;

static BOOL TBIsThemedResourceName(NSString *name);
static NSString *TBBIDFromIcon(id icon);

static UIImage *TBCalendarBackgroundForInfo(TBInfo info) {
    TB_RENDER_SCOPE();
    if (!TBEnabled() || TBSafeMode() || !TBActiveTheme().length) return nil;
    NSString *path = nil;
    // 日历底图优先取 IconBundles/com.apple.mobilecal.png，
    // 没有时再取 Bundles/CalendarIconBackground*。
    [gLock lock];
    TBLoadIndex();
    path = gIndex[@"com.apple.mobilecal"];
    [gLock unlock];
    if (!path.length) path = TBDynamicResourcePath(@"com.apple.mobilecal");
    TBDiagEmit(@"calendar.path", nil, NULL, nil, nil, path ?: @"missing theme background");
    if (!path.length) return nil;
    UIImage *img = [[UIImage alloc] initWithContentsOfFile:path];
    if (!img) return nil;
    return TBIconFinalImage(TBFitImage(img, info));
}

/// 从系统完整日历图中只提取星期/日期文字，过滤白色背景，避免覆盖主题底图。
static UIImage *TBCalendarTextOverlay(UIImage *native, TBInfo info) {
    if (!native || !native.CGImage) return nil;
    CGSize size = info.size.width > 1 ? info.size : native.size;
    CGFloat scale = info.scale > 0.5 ? info.scale : (native.scale > 0.5 ? native.scale : 3.0);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = scale; fmt.opaque = YES;
    UIGraphicsImageRenderer *rr = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    UIImage *scaled = [rr imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [native drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
    CGImageRef cg = scaled.CGImage;
    if (!cg) return nil;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    unsigned char *src = calloc(w * h * 4, 1);
    CGContextRef sc = src ? CGBitmapContextCreate(src, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
    CGContextRef oc = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!sc || !oc) { if (sc) CGContextRelease(sc); if (oc) CGContextRelease(oc); free(src); return nil; }
    CGContextDrawImage(sc, CGRectMake(0, 0, w, h), cg);
    unsigned char *dst = CGBitmapContextGetData(oc); memset(dst, 0, w * h * 4);
    for (size_t y = 0; y < h; y++) {
        CGFloat ny = (CGFloat)y / (CGFloat)MAX(h - 1, 1);
        if (ny < 0.06 || ny > 0.84) continue;
        for (size_t x = 0; x < w; x++) {
            unsigned char *p = src + (y * w + x) * 4;
            if (p[3] < 10) continue;
            int mx = MAX(p[0], MAX(p[1], p[2]));
            int mn = MIN(p[0], MIN(p[1], p[2]));
            int lum = (299 * p[0] + 587 * p[1] + 114 * p[2]) / 1000;
            BOOL red = p[0] > 130 && p[0] > p[1] * 1.25 && p[0] > p[2] * 1.25;
            BOOL black = mx - mn < 45 && lum < 210;
            if (!red && !black) continue;
            unsigned char *q = dst + (y * w + x) * 4;
            if (red) {
                CGFloat a = MAX((255.0 - p[1]) / 196.0, (255.0 - p[2]) / 207.0);
                q[0] = 255; q[1] = 59; q[2] = 48; q[3] = (unsigned char)MIN(255.0, MAX(0.0, a * 255.0));
            } else {
                int a = 255 - lum;
                q[0] = q[1] = q[2] = 0; q[3] = (unsigned char)MIN(255, MAX(0, a));
            }
        }
    }
    CGImageRef outCG = CGBitmapContextCreateImage(oc);
    CGContextRelease(sc); CGContextRelease(oc); free(src);
    if (!outCG) return nil;
    UIImage *out = [UIImage imageWithCGImage:outCG scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(outCG);
    return out;
}

/// 设置页图标 / 通知中心 共用 UIKit 应用图标入口
static BOOL TBUIKitIconEnabled(void) {
    return !gTBSettingsNativeIcon;   // ★ 1.45：设置页图标开关已删除 → 恒开
}

/// UIKit 私有 format 参数里能识别的「请求尺寸」。只用于系统原实现没给图时的兜底，
/// 而且只会用来把主题图缩小，绝不会放大 —— 宁可小一点，也不能再出现"图标巨大"。
static CGFloat TBAppIconPointsForFormat(int format) {
    switch (format & 0xFF) {
        case 1:  return 29.0;    // 设置 / 通知中心这类列表用的小图标
        case 2:  return 40.0;    // 分享面板 / 搜索结果
        case 3:  return 60.0;    // 主屏图标尺寸
        default: return 0.0;     // 0 = 默认大图，不猜（交给系统原实现给尺寸）
    }
}

/// format → 请求尺寸（pt）缓存，避免每次调用都跑一遍系统原实现。
static NSMutableDictionary *gUIFmtSize;

/// 把主题图按「调用方请求的尺寸」重绘。
/// 之前直接把主题原图（180×180 / 1024×1024）返回，UIKit 只按自己的期望布局缩放、
/// 或者根本不缩放 → 别的 App 列表里图标巨大。这里解析请求尺寸并重绘：
///   ① 系统原实现返回图的尺寸（最可靠：那就是调用方要的尺寸）
///   ② :scale: 变体传进来的 scale
///   ③ format 兜底表（只搬小不搬大）
/// 三者都拿不到 → 返回 nil，调用方原样返回主题图（保持旧行为，不冒险）。
static UIImage *TBUIKitSizedThemeIcon(UIImage *theme, id self, SEL _cmd, id identifier,
                                      int format, double scale, BOOL hasScale) {
    if (!theme) return nil;
    CGSize want = CGSizeZero;
    CGFloat wantScale = hasScale ? scale : 0;

    // ① 先看缓存
    if (!gUIFmtSize) gUIFmtSize = [NSMutableDictionary dictionary];
    NSString *fkey = [NSString stringWithFormat:@"%d|%d", format, hasScale ? 1 : 0];
    NSValue *cv = gUIFmtSize[fkey];
    if (cv) {
        want = cv.CGSizeValue;
    } else {
        @try {
            UIImage *sys = hasScale
                ? (o_appIconScale ? o_appIconScale(self, _cmd, identifier, format, scale) : nil)
                : (o_appIcon      ? o_appIcon(self, _cmd, identifier, format)         : nil);
            if ([sys isKindOfClass:[UIImage class]] && sys.size.width >= 1 && sys.size.height >= 1) {
                want = sys.size;
                if (sys.scale > 0.5) wantScale = sys.scale;
                gUIFmtSize[fkey] = [NSValue valueWithCGSize:want];
            }
        } @catch (NSException *e) { }
    }

    // ③ format 兜底（拿不到系统图时）
    if (want.width < 1 || want.height < 1) {
        CGFloat side = TBAppIconPointsForFormat(format);
        if (side > 0) want = CGSizeMake(side, side);
    }
    if (want.width < 1 || want.height < 1) return nil;         // 真拿不到 → 交回原图
    if (wantScale < 0.5) wantScale = theme.scale > 0.5 ? theme.scale : 3.0;

    // 主题图本来就比请求尺寸小 → 不必重绘（也避免无意义的重绘）
    if (theme.size.width <= want.width + 0.6 && theme.size.height <= want.height + 0.6) return theme;

    TBInfo info = { want, wantScale, 0 };
    UIImage *out = TBFitCached(theme, info, ([identifier isKindOfClass:[NSString class]] ? identifier : nil));
    TBLogOnce([@"uikiticonsize|" stringByAppendingFormat:@"%d|%@", format, identifier ?: @"?"],
              @"UIKit 应用图标尺寸适配：fmt=%d scale=%.1f 请求 %.0fx%.0fpt ← 主题图 %.0fx%.0fpt → %@",
              format, wantScale, want.width, want.height,
              theme.size.width, theme.size.height, (out && out != theme ? @"已重绘" : @"保持原图"));
    return out ?: theme;
}

static UIImage *tb_appIconImageForBID(id self, SEL _cmd, id identifier, int format) {
    TB_RENDER_SCOPE();
    if (gTBSettingsNativeIcon) return o_appIcon ? o_appIcon(self, _cmd, identifier, format) : nil;
    if (TBUIKitIconEnabled() && [identifier isKindOfClass:[NSString class]] && [identifier length]) {
        UIImage *img = TBImageForBundle(identifier);
        if (img) {
            gServe++;
            UIImage *sized = TBUIKitSizedThemeIcon(img, self, _cmd, identifier, format, 0, NO) ?: img;
            TBLogOnce([@"uikiticon|" stringByAppendingFormat:@"%@|%d", identifier, format],
                      @"serve 应用图标 %@ fmt=%d → %.0fx%.0fpt", identifier, format,
                      sized.size.width, sized.size.height);
            return sized;
        }
        // 0.15.53：主题【没覆盖】的 App 也走全局效果 —— 之前这条链只对主题覆盖的 App 出
        // 主题图，其余 App 原样返回系统图，于是 App 切换器多任务卡片里一部分 App 还是
        // 系统圆角矩形、和套了遮罩的混在一起。这里对系统原图先 TBArtSquareFilled →
        // TBApplyIconShape → TBApplyIconEffects（TBGlobalEffectImage 内部就是这个顺序），
        // 再按请求尺寸重绘；开关门控（GlobalIconEffect / 形状参数开关）都在函数里。
        UIImage *sys = o_appIcon ? o_appIcon(self, _cmd, identifier, format) : nil;
        UIImage *g = TBGlobalEffectImage(sys, identifier);
        if (g && g != sys) {
            gServe++;
            UIImage *sized = TBUIKitSizedThemeIcon(g, self, _cmd, identifier, format, 0, NO) ?: g;
            TBLogOnce([@"uikitfx|" stringByAppendingFormat:@"%@|%d", identifier, format],
                      @"切换器遮罩：%@（%.0f×%.0f）未覆盖主题，已套全局效果 fmt=%d",
                      identifier, sys.size.width, sys.size.height, format);
            return sized;
        }
        return sys;
    }
    return o_appIcon ? o_appIcon(self, _cmd, identifier, format) : nil;
}

static UIImage *tb_appIconImageForBIDScale(id self, SEL _cmd, id identifier, int format, double scale) {
    TB_RENDER_SCOPE();
    if (gTBSettingsNativeIcon) return o_appIconScale ? o_appIconScale(self, _cmd, identifier, format, scale) : nil;
    if (TBUIKitIconEnabled() && [identifier isKindOfClass:[NSString class]] && [identifier length]) {
        UIImage *img = TBImageForBundle(identifier);
        if (img) {
            gServe++;
            UIImage *sized = TBUIKitSizedThemeIcon(img, self, _cmd, identifier, format, scale, YES) ?: img;
            TBLogOnce([@"uikiticons|" stringByAppendingFormat:@"%@|%d", identifier, format],
                      @"serve 应用图标 %@ fmt=%d scale=%.1f → %.0fx%.0fpt", identifier, format, scale,
                      sized.size.width, sized.size.height);
            return sized;
        }
        // 0.15.53：:scale: 变体同样接全局效果（理由同上）
        UIImage *sys = o_appIconScale ? o_appIconScale(self, _cmd, identifier, format, scale) : nil;
        UIImage *g = TBGlobalEffectImage(sys, identifier);
        if (g && g != sys) {
            gServe++;
            UIImage *sized = TBUIKitSizedThemeIcon(g, self, _cmd, identifier, format, scale, YES) ?: g;
            TBLogOnce([@"uikitfxs|" stringByAppendingFormat:@"%@|%d", identifier, format],
                      @"切换器遮罩：%@（%.0f×%.0f）未覆盖主题，已套全局效果 fmt=%d scale=%.1f",
                      identifier, sys.size.width, sys.size.height, format, scale);
            return sized;
        }
    }
    return o_appIconScale ? o_appIconScale(self, _cmd, identifier, format, scale) : nil;
}

static UIImage *tb_imageNamed(id self, SEL _cmd, NSString *name) {
    TB_RENDER_SCOPE();
    if (!TBIsThemedResourceName(name)) {
        return o_imageNamed ? o_imageNamed(self, _cmd, name) : nil;
    }
    UIImage *sys0 = o_imageNamed ? o_imageNamed(self, _cmd, name) : nil;
    UIImage *img = TBMatchSystemGeometry(TBResourceImage(name), sys0);
    if (img && [name hasPrefix:@"ClockIconBackground"]) img = TBClockRoundedFace(img);
    if (img) {
        TBDiagResource(self, _cmd, name, img, @"UIImage themed resource");
        gServe++;
        if (name.length < 48) TBLogOnce([@"res2|" stringByAppendingString:name.lowercaseString],
                                        @"res2 imageNamed %@", name);
        TBLog(@"serve 资源 %@", name);
        return img;
    }
    TBDiagResource(self, _cmd, name, sys0, @"UIImage original resource");
    return sys0;
}

/// +[UIImage imageNamed:inBundle:]、+[UIImage imageNamed:inBundle:compatibleWithTraitCollection:]
/// SpringBoard 的时钟视图有时走这两个变体，只挂 imageNamed: 拦不到
static UIImage *tb_imageNamedInBundle(id self, SEL _cmd, NSString *name, NSBundle *bundle) {
    TB_RENDER_SCOPE();
    if (!TBIsThemedResourceName(name)) {
        return o_imageNamedInBundle ? o_imageNamedInBundle(self, _cmd, name, bundle) : nil;
    }
    UIImage *sys = o_imageNamedInBundle ? o_imageNamedInBundle(self, _cmd, name, bundle) : nil;
    UIImage *img = TBMatchSystemGeometry(TBResourceImage(name), sys);
    if (img && [name hasPrefix:@"ClockIconBackground"]) img = TBClockRoundedFace(img);
    if (img) {
        TBDiagResource(self, _cmd, name, img, @"UIImage themed resource");
        gServe++;
        if (name.length < 48) TBLogOnce([@"res2|" stringByAppendingString:name.lowercaseString],
                                        @"res2 inBundle %@", name);
        TBLog(@"serve 资源(bundle) %@", name);
        return img;
    }
    TBDiagResource(self, _cmd, name, sys, @"UIImage original resource");
    return sys;
}

static UIImage *tb_imageNamedInBundleTrait(id self, SEL _cmd, NSString *name, NSBundle *bundle, id trait) {
    TB_RENDER_SCOPE();
    if (!TBIsThemedResourceName(name)) {
        return o_imageNamedInBundleTrait ? o_imageNamedInBundleTrait(self, _cmd, name, bundle, trait) : nil;
    }
    UIImage *sys = o_imageNamedInBundleTrait ? o_imageNamedInBundleTrait(self, _cmd, name, bundle, trait) : nil;
    UIImage *img = TBMatchSystemGeometry(TBResourceImage(name), sys);
    if (img) {
        TBDiagResource(self, _cmd, name, img, @"UIImage themed resource");
        gServe++;
        if (name.length < 48) TBLogOnce([@"res2|" stringByAppendingString:name.lowercaseString],
                                        @"res2 inBundleTrait %@", name);
        // 时钟表盘素材：这条路径（系统按名字取资源）也要「圆角 + 白底」，
        // 否则半透明玻璃会透出系统那块深色底盘 → 显示发黑（资源路径之前漏了这步）
        if ([name hasPrefix:@"ClockIconBackground"]) {
            img = TBClockRoundedFace(img);
            TBLogOnce([@"facefeed|res|" stringByAppendingString:(TBActiveTheme() ?: @"")],
                      @"表盘供图[资源路径] 主题=%@ %@", TBActiveTheme() ?: @"?", name);
        }
        TBLog(@"serve 资源(bundleTrait) %@", name);
        return img;
    }
    TBDiagResource(self, _cmd, name, sys, @"UIImage original resource");
    return sys;
}

/// 只有这些名字才值得查主题资源。imageWithContentsOfFile 是极热接口，
/// 这里不能加锁、不能访问文件系统（曾导致 SpringBoard 被拖死 → 整机重启）。
static BOOL TBIsThemedResourceName(NSString *name) {
    if (name.length < 6 || name.length > 48) return NO;
    unichar c0 = [name characterAtIndex:0];
    if (c0 != 'C' && c0 != 'A' && c0 != 'S' && c0 != 'K') return NO;
    // 指针/轴心素材绝不替换：它们的画布尺寸与表盘不是同一坐标系，
    // 交给系统会导致指针错位甚至跑到看不见的地方（只剩纯白表盘）。
    // 指针一律由系统自己画（黑时针 + 黑分针 + 橙秒针），与官方效果一致。
    if ([name rangeOfString:@"Hand"].location != NSNotFound) return NO;
    if ([name rangeOfString:@"Dot"].location != NSNotFound) return NO;
    // 分工（对齐 SnowBoard）：
    //  · 表盘（ClockIconBackground*）→ 资源重定向，替换系统表盘图
    //  · 指针/轴心（ClockIcon*Hand / *Dot）→ 不在这里，改由
    //    SBHClockHandsImageSet 注入（见 tb_makeImageSet）
    if ([name hasPrefix:@"ClockIconBackground"]) return YES;
    // 角标底板（SBBadgeBG@3x.png）：主题/素材包里有就替换（UseThemeBadge / CustomBadgePath）
    if ([name hasPrefix:@"SBBadgeBG"]) {
        id ub = TBPref(@"UseThemeBadge");
        if (ub && [ub boolValue]) return YES;
        id cb = TBPref(@"CustomBadgePath");
        if ([cb isKindOfClass:[NSString class]] && [(NSString *)cb length]) return YES;
        return NO;
    }
    static NSArray<NSString *> *prefixes = nil;
    if (!prefixes) prefixes = @[@"ANEM", @"CalendarIcon", @"Keypad"];
    for (NSString *p in prefixes) {
        if ([name hasPrefix:p]) return YES;
    }
    return NO;
}

static BOOL TBIsThemedResourceName(NSString *name);

static UIImage *tb_imageWithFile(id self, SEL _cmd, NSString *path) {
    TB_RENDER_SCOPE();
    if (!TBIsThemedResourceName(path.lastPathComponent)) {
        return o_imageWithFile ? o_imageWithFile(self, _cmd, path) : nil;
    }
    UIImage *img = TBResourceImage(path);
    if (img) { TBDiagResource(self, _cmd, path.lastPathComponent, img, @"UIImage themed file"); gServe++; TBLog(@"serve 资源文件 %@", path.lastPathComponent); return img; }

    return o_imageWithFile ? o_imageWithFile(self, _cmd, path) : nil;
}

#pragma mark - NSBundle 资源重定向（SpringBoard 自带的表盘/指针等）

typedef NSString *(*BundlePathFn)(id, SEL, NSString *, NSString *);
typedef NSString *(*BundlePathDirFn)(id, SEL, NSString *, NSString *, NSString *);
static BundlePathFn o_pathForRes;
static BundlePathDirFn o_pathForResDir;

static NSString *TBResourcePathNamed(NSString *name, NSString *ext) {
    TB_RENDER_SCOPE();
    if (gTBSettingsNativeIcon) return nil;
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
    TB_RENDER_SCOPE();
    if (!TBIsThemedResourceName(name)) {
        return o_pathForRes ? o_pathForRes(self, _cmd, name, ext) : nil;
    }
    NSString *p = TBResourcePathNamed(name, ext);
    if (p) { TBDiagResource(self, _cmd, name, nil, p); TBLog(@"serve 资源路径 %@.%@", name, ext); return p; }
    NSString *nativePath = o_pathForRes ? o_pathForRes(self, _cmd, name, ext) : nil;
    TBDiagResource(self, _cmd, name, nil, nativePath ?: @"original path nil");
    return nativePath;
}

static NSString *tb_pathForResDir(id self, SEL _cmd, NSString *name, NSString *ext, NSString *subdir) {
    TB_RENDER_SCOPE();
    if (!TBIsThemedResourceName(name)) {
        return o_pathForResDir ? o_pathForResDir(self, _cmd, name, ext, subdir) : nil;
    }
    NSString *p = TBResourcePathNamed(name, ext);
    if (p) { TBDiagResource(self, _cmd, name, nil, p); TBLog(@"serve 资源路径(in) %@.%@", name, ext); return p; }
    NSString *nativePath = o_pathForResDir ? o_pathForResDir(self, _cmd, name, ext, subdir) : nil;
    TBDiagResource(self, _cmd, name, nil, nativePath ?: @"original path nil");
    return nativePath;
}

#pragma mark - 桌面时钟（SBHClockApplicationIconImageView 自己合成表盘+指针，绕过图片缓存）


#pragma mark - 设置页图标（PSSpecifier，17.2 头文件确认）

// - (void)setupIconImageWithBundle:(id)bundle;
// - (void)setupIconImageWithPath:(id)path;
// 设置页每个 App 行的图标由这里生成，之前的 UIImage/ISIcon hook 都不会被调用。
typedef void (*SetupIconFn)(id, SEL, id);
static SetupIconFn o_setupIconBundle;

/// 从 PSSpecifier 取 bundleID：identifier / bundleID / propertyForKey:
static NSString *TBBidFromSpecifier(id spec) {
    @try {
        for (NSString *k in @[ @"identifier", @"bundleIdentifier" ]) {
            if ([spec respondsToSelector:NSSelectorFromString(k)]) {
                id v = ((id (*)(id, SEL))objc_msgSend)(spec, NSSelectorFromString(k));
                if ([v isKindOfClass:[NSString class]] && [(NSString *)v containsString:@"."]) return v;
            }
        }
        if ([spec respondsToSelector:NSSelectorFromString(@"propertyForKey:")]) {
            id v = ((id (*)(id, SEL, id))objc_msgSend)(spec, NSSelectorFromString(@"propertyForKey:"), @"bundleID");
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v containsString:@"."]) return v;
            v = ((id (*)(id, SEL, id))objc_msgSend)(spec, NSSelectorFromString(@"propertyForKey:"), @"applicationBundleIdentifier");
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v containsString:@"."]) return v;
        }
    } @catch (NSException *e) {}
    return nil;
}

/// 按原图尺寸返回主题图（0.15.93：设置主页 App 列表的图标是 specifier.icon 提供的，
/// setupIconImageWithBundle: 在 17.2 上不触发，所以补 getter/setter 两条）
static UIImage *TBThemedIconLike(UIImage *orig, NSString *bid) {
    if (!bid.length) return nil;
    if (!TBUIKitIconEnabled() || !TBEnabled() || TBSafeMode()) return nil;
    UIImage *img = TBImageForBundle(bid);
    if (![img isKindOfClass:[UIImage class]]) return nil;
    UIImage *out = TBApplyIconEffects(TBApplyIconShape(img, NO)) ?: img;
    if ([orig isKindOfClass:[UIImage class]] && orig.size.width > 1) {
        TBInfo info = { orig.size, orig.scale > 0.5 ? orig.scale : 3.0, 0 };
        UIImage *sized = TBFitCached(out, info, bid);
        if (sized) out = sized;
    }
    return out;
}

static UIImage *(*o_specIcon)(id, SEL);
static UIImage *tb_specIcon(id self, SEL _cmd) {
    UIImage *orig = o_specIcon ? o_specIcon(self, _cmd) : nil;
    @try {
        NSString *bid = TBBidFromSpecifier(self);
        UIImage *out = TBThemedIconLike(orig, bid);
        if (out) {
            TBLogOnce([@"specicon|" stringByAppendingString:bid], @"设置页图标(specifier.icon)：%@ 已替换", bid);
            return out;
        }
    } @catch (NSException *e) {}
    return orig;
}

static void (*o_specSetIcon)(id, SEL, id);
static void tb_specSetIcon(id self, SEL _cmd, id icon) {
    @try {
        NSString *bid = TBBidFromSpecifier(self);
        UIImage *out = TBThemedIconLike((UIImage *)icon, bid);
        if (out) { if (o_specSetIcon) o_specSetIcon(self, _cmd, out); return; }
    } @catch (NSException *e) {}
    if (o_specSetIcon) o_specSetIcon(self, _cmd, icon);
}

static void tb_setupIconWithBundle(id self, SEL _cmd, id bundle) {
    if (o_setupIconBundle) o_setupIconBundle(self, _cmd, bundle);
    // 0.15.95：先无条件确认这个 hook 到底有没有被调用（17.2 头文件里 PSSpecifier 只有
    //   setupIconImageWithBundle: / setupIconImageWithPath: 两条图标方法，没有 icon/setIconImage:，
    //   所以之前"设置了但没生效"很可能是写入方式不对）
    {
        NSString *tag = [@"spcall|" stringByAppendingString:[bundle description] ?: @"?"];
        TBLogOnce(tag, @"设置页图标 setup 被调用：cls=%@ bundle=%@",
                  NSStringFromClass([self class]), bundle);
    }
    if (!TBEnabled() || TBSafeMode() || !TBUIKitIconEnabled()) return;
    @try {
        NSString *bid = nil;
        id b = bundle;
        if ([b isKindOfClass:[NSString class]]) bid = (NSString *)b;
        if (![bid containsString:@"."] && [bundle respondsToSelector:NSSelectorFromString(@"bundleIdentifier")]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(bundle, NSSelectorFromString(@"bundleIdentifier"));
            if ([v isKindOfClass:[NSString class]]) bid = v;
        }
        if (!bid.length || ![bid containsString:@"."]) {
            for (NSString *k in @[@"identifier", @"bundleIdentifier"]) {
                if ([self respondsToSelector:NSSelectorFromString(k)]) {
                    id v = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(k));
                    if ([v isKindOfClass:[NSString class]] && [(NSString *)v containsString:@"."]) { bid = v; break; }
                }
            }
        }
        if (!bid.length) return;
        UIImage *img = TBImageForBundle(bid);
        if (!img) { TBLogOnce([@"spmiss|" stringByAppendingString:bid], @"miss(设置页) %@", bid); return; }
        BOOL done = NO;
        // ① setIconImage:（若存在）
        if ([self respondsToSelector:NSSelectorFromString(@"setIconImage:")]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self, NSSelectorFromString(@"setIconImage:"), img);
            done = YES;
        }
        // ② KVC 写 icon（PSSpecifier 内部有 _icon，KVC 能直接命中）
        if (!done) {
            @try { [self setValue:img forKey:@"icon"]; done = YES; } @catch (NSException *e) {}
        }
        // ③ setProperty:forKey:@"icon"
        if (!done && [self respondsToSelector:NSSelectorFromString(@"setProperty:forKey:")]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(self, NSSelectorFromString(@"setProperty:forKey:"), img, @"icon");
            done = YES;
        }
        if (done) TBLogOnce([@"spserve|" stringByAppendingString:bid], @"serve(设置页) %@", bid);
        else TBLogOnce([@"spfail|" stringByAppendingString:bid], @"设置页图标写入失败（无可用 setter）%@", bid);
    } @catch (NSException *e) { }
}

// 时钟视图会从 imageSet 里取这三层指针叠加上去（17.2 头文件：
// + makeHoursHandLayerWithImageSet: / makeMinutesHandLayerWithImageSet: /
// + makeSecondsHandLayerWithImageSet:）。我们接管背景图后必须同时把这些层置空，
// 否则会出现"主题图自带一根秒针 + 系统又叠一根"的双指针。

#pragma mark - 时钟图像集注入（SnowBoard 同款：makeImageSetForMetrics:）

typedef id (*ClockImageSetFn)(id, SEL, void *);
static ClockImageSetFn o_makeImageSet, o_imageSet;

static void TBApplyClockImagesToSet(id set) {
    TB_RENDER_SCOPE();
    if (!set || !TBEnabled() || TBSafeMode()) return;
    // 主题素材 → 图像集成员（名字与 SnowBoard 反编译里一致）
    struct { NSString *key; NSString *res; } map[] = {
        {@"hours",         @"ClockIconHourHand"},
        {@"minutes",       @"ClockIconMinuteHand"},
        {@"seconds",       @"ClockIconSecondHand"},
        {@"hourMinuteDot", @"ClockIconBlackDot"},
        {@"secondDot",     @"ClockIconRedDot"},
    };
    NSInteger applied = 0, restored = 0;
    // 时钟素材准备结果缓存：同主题同成员只解码/抠白底/缩放一次。
    // 系统每次重建针集（约每 10 秒）都会走到这里，原来每次重跑一遍 → 持续耗电发热。
    static NSMutableDictionary *gPrepared = nil;
    static NSString *gPreparedTheme = nil;
    static dispatch_once_t oncePrep;
    dispatch_once(&oncePrep, ^{ gPrepared = [NSMutableDictionary dictionary]; });
    NSString *prepTheme = TBActiveTheme() ?: @"";
    if (![prepTheme isEqualToString:gPreparedTheme ?: @""]) {
        [gPrepared removeAllObjects];
        gPreparedTheme = [prepTheme copy];
    }

    static NSMutableDictionary *gOriginalMembers = nil;
    static dispatch_once_t onceMembers;
    static BOOL captured = NO;
    dispatch_once(&onceMembers, ^{ gOriginalMembers = [NSMutableDictionary dictionary]; });
    if (!captured) {
        // 只在这套针集【第一次被我们碰到、还没注入过】时记录系统原图 —— 这是唯一干净的一份。
        // （之前是"每项第一次见到就记"，结果把自己注入过的主题针也记成了系统原图 → 恢复时多一套针）
        captured = YES;
        for (unsigned i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
            SEL g = NSSelectorFromString(map[i].key);
            if (![set respondsToSelector:g]) continue;
            id v = ((id (*)(id, SEL))objc_msgSend)(set, g);
            if ([v isKindOfClass:[UIImage class]]) gOriginalMembers[map[i].key] = v;
        }
        TBLog(@"时钟图像集：已记录系统原图 %lu 项", (unsigned long)gOriginalMembers.count);
    }
    for (unsigned i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
        SEL setter0 = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
                                           [[map[i].key substringToIndex:1] uppercaseString],
                                           [map[i].key substringFromIndex:1]]);
        NSString *pkey = [prepTheme stringByAppendingFormat:@"|%@", map[i].key];
        {
            UIImage *prep = gPrepared[pkey];
            if ([prep isKindOfClass:[UIImage class]] && [set respondsToSelector:setter0]) {
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(set, setter0, prep);
                    applied++;
                } @catch (NSException *e) { }
                continue;
            }
        }
        UIImage *img = TBResourceImage(map[i].res);
        if (!img) {
            // 主题没这一项 → 还原系统原样（系统的针集是缓存复用的，不还原会残留上一个主题的针）
            UIImage *keep = gOriginalMembers[map[i].key];
            if (keep && [set respondsToSelector:setter0]) {
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(set, setter0, keep);
                    restored++;
                } @catch (NSException *e) { }
            }
            continue;
        }
        img = TBKeyOutCornerColor(img);   // 作者导出忘去白底时兜底

        // 关键：系统图像集里每根针都是按图标尺寸算好的，
        // 直接塞素材原图会大得离谱（248x547 那种画布）。这里取系统原本
        // 那一项的尺寸当目标，把主题素材缩放到同样大小（SnowBoard 同做法）。
        SEL getter = NSSelectorFromString(map[i].key);
        UIImage *orig = nil;
        if ([set respondsToSelector:getter]) {
            id v = ((id (*)(id, SEL))objc_msgSend)(set, getter);
            if ([v isKindOfClass:[UIImage class]]) orig = v;
        }

        // 系统那一项的尺寸：只认第一次读到的"正常值"，之后读到坏值（0 或过小）一律忽略。
        // 否则一旦注入过坏尺寸的图，下次读到的就是它自己 → 越传越坏，系统拉伸铺满 → 针变粗。
        static NSMutableDictionary *gMemberSize = nil;
        static dispatch_once_t onceTok;
        dispatch_once(&onceTok, ^{ gMemberSize = [NSMutableDictionary dictionary]; });
        CGSize target = orig ? orig.size : CGSizeZero;
        NSValue *cachedSize = gMemberSize[map[i].key];
        if (target.width < 4 || target.height < 4) {
            if (cachedSize) {
                target = cachedSize.CGSizeValue;
                TBLogOnce([@"clocksizefb|" stringByAppendingFormat:@"%@|%@", map[i].key, TBActiveTheme() ?: @""],
                          @"时钟针 %@：系统那一项尺寸异常，改用首次记录的正常值 %.0fx%.0f pt",
                          map[i].key, target.width, target.height);
            }
        } else if (!cachedSize) {
            gMemberSize[map[i].key] = [NSValue valueWithCGSize:target];
        }
        TBLogOnce([@"clocksize|" stringByAppendingFormat:@"%@|%@", map[i].key, TBActiveTheme() ?: @""],
                  @"时钟素材尺寸 %@：主题原图 %.0fx%.0f pt scale=%.0f → 目标 %.0fx%.0f pt",
                  map[i].key, img.size.width, img.size.height, img.scale,
                  target.width, target.height);
        if (target.width < 1 || target.height < 1) continue;   // 系统没有这项就别乱塞

        // 与 SnowBoard 完全一致：只做一步 —— 把主题这张图缩放到「系统原本那根针」的尺寸。
        // 不做轴心换算、不改色、不动别的成员（主题没有的成员保持系统原样）。
        // 与 SnowBoard 同一步：把主题图缩放到系统那一项的尺寸。
        // 关键：点尺寸和 scale 都要和系统原本那张完全一致，否则像素尺寸变大，
        // 系统按像素铺开 → 指针看起来又粗又长。
        // SnowBoard 的规则：**只缩小，从不放大**。
        // 主题针比系统那项小就原样用（放大只会把细针糊成一坨粗块 —— 这就是"针变粗"的原因）；
        // 比系统大才按比例缩到能放进去。
        CGFloat oscale = orig.scale > 0.5 ? orig.scale : 1.0;
        CGSize tsz = img.size, osz = target;
        BOOL bigger = (tsz.width > osz.width + 0.01) || (tsz.height > osz.height + 0.01);
        if (bigger) {
            CGFloat k = MIN(osz.width / MAX(tsz.width, 0.01), osz.height / MAX(tsz.height, 0.01));
            target = CGSizeMake(tsz.width * k, tsz.height * k);
        } else {
            target = tsz;      // 主题针比系统那项小 → 目标就是它自己（这一步之前漏了，
                               // 结果还是按系统尺寸放大 → 细针糊成粗块）
        }
        if (bigger || fabs(img.scale - oscale) > 0.01) {
            UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
            fmt.scale = oscale;
            fmt.opaque = NO;
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:target format:fmt];
            img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [img drawInRect:CGRectMake(0, 0, target.width, target.height)];
            }];
            TBLogOnce([@"clockscale|" stringByAppendingFormat:@"%@|%@", map[i].key, TBActiveTheme() ?: @""],
                      @"时钟针 %@：主题 %.0fx%.0f → 注入 %.0fx%.0f pt（系统那一项 %.0fx%.0f，%@）",
                      map[i].key, tsz.width, tsz.height, img.size.width, img.size.height,
                      osz.width, osz.height, bigger ? @"按比例缩小" : @"原样用，不放大");
        }

        SEL setter = NSSelectorFromString([NSString stringWithFormat:@"set%@%@:",
                                          [[map[i].key substringToIndex:1] uppercaseString],
                                          [map[i].key substringFromIndex:1]]);
        if (![set respondsToSelector:setter]) continue;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(set, setter, img);
            applied++;
            gPrepared[pkey] = img;
        } @catch (NSException *e) { }
    }
    if (applied > 0 || restored > 0) {
        TBLogOnce([@"clockset|" stringByAppendingFormat:@"%@|%ld|%ld", prepTheme,
                   (long)applied, (long)restored],
                  @"时钟图像集：注入 %ld 项，还原系统 %ld 项", (long)applied, (long)restored);
    }
}

static id tb_makeImageSet(id self, SEL _cmd, void *metrics) {
    id set = o_makeImageSet ? o_makeImageSet(self, _cmd, metrics) : nil;
    TBApplyClockImagesToSet(set);   // 主题有的成员才替换，没有的保持系统的
    return set;
}

static id tb_imageSet(id self, SEL _cmd, void *metrics) {
    id set = o_imageSet ? o_imageSet(self, _cmd, metrics) : nil;
    TBApplyClockImagesToSet(set);
    return set;
}

#pragma mark - 安装

static BOOL gDoneImageHooks = NO;      // UIImage / NSBundle 那组
static BOOL gDoneISIcon = NO;
static BOOL gDoneActivity = NO;
static BOOL gDoneCache = NO;
// ---- 静态图标模式：隐藏系统指针（图标自己画了指针，否则会重影）----
// ---- 替换角标底板（SBBadgeBG）：系统取角标图不走 imageNamed:，只能从视图层换 ----
//
// 0.15.49 重写。用户实测症状：换主题之后角标「看起来像有两个 / 一直变不回来」，
// 检查发现旧角标会一直赖在图标上，注销（刷新桌面）之后才消失 —— 根因是**没有还原路径**。
// 这一版：
//   ① 【还原】：换主题 / 关角标开关 / 取消应用 / 设置变更（TBReload）时，把之前换上的
//      底板写回系统原图（下面 gBadgeRestores 还原表），日志打「角标：还原 N 处」。
//   ② 只在「真有素材（SBBadgeBG*）或 CustomBadgePath」时才替换；没有素材一律不动。
//   ③ 只换【底板那一层】：整棵角标子树里面积最大的那个 UIImageView（系统底板）；
//      有 UILabel 的层绝不碰 layer.contents —— 数字必须留着。
//   ④ 幂等：同一个角标一次布局只处理一次（还原表里查"还是不是我们换的图"），
//      绝不既改 image 又改 layer.contents（那会画两层 = "两个角标叠着"）。
//   ⑤ 日志必打「角标：命中 <完整路径>」/「角标：没找到素材」（换主题、开机各一次）。
static void (*o_badgeLayout)(id, SEL);
static NSMutableDictionary *gBadgeOrig;   // 类名 → 该类自己的原始 layoutSubviews IMP

/// 调「这个类自己的」原始 layoutSubviews（找不到该类的记录时才退回全局 o_badgeLayout）
static void TBBadgeCallOrig(id self, SEL _cmd) {
    void (*imp)(id, SEL) = NULL;
    [gLock lock];
    NSValue *v = gBadgeOrig[NSStringFromClass([self class])];
    [gLock unlock];
    if (v) imp = (void (*)(id, SEL))[v pointerValue];
    if (imp) imp(self, _cmd);
    else if (o_badgeLayout) o_badgeLayout(self, _cmd);
}

/// 主题角标图缓存：key = 文件路径，换主题整表作废。
/// ★ 必须缓存：幂等检查（plate.image == e.appliedImage）靠 UIImage 指针相等。
///   原来 ②③ 分支每次 layout 都 initWithContentsOfFile: 造新实例 ——
///   系统把底板图写回（image == 系统图）后我们再换一次时，还原表里会叠出
///   「origImage = 上一次的主题角标」的记录链；TBBadgeRestoreAll 按序还原，
///   最后一遍恰恰把【旧主题角标】写回底板 = 换主题后旧角标赖着不走。
///   同一文件返回同一实例后，记录链断掉，还原一定回到系统原图。
///   （只在主线程 layoutSubviews 里访问，不加锁。）
static UIImage *TBBadgeImageFromFileCached(NSString *path) {
    TB_RENDER_SCOPE();
    if (!path.length) return nil;
    NSString *theme = TBActiveTheme() ?: @"";
    if (!gBadgeThemeImgCache || ![gBadgeThemeImgCacheTheme isEqualToString:theme]) {
        gBadgeThemeImgCache = [NSMutableDictionary dictionary];
        gBadgeThemeImgCacheTheme = [theme copy];
    } else if (gBadgeThemeImgCache.count > 8) {
        [gBadgeThemeImgCache removeAllObjects];   // 上限保护（路径变体不会太多）
    }
    UIImage *hit = gBadgeThemeImgCache[path];
    if (hit) return hit;
    // 必须用 init：imageWithContentsOfFile: 已被本引擎 hook（递归会爆栈）
    UIImage *im = [[UIImage alloc] initWithContentsOfFile:path];
    if (im) gBadgeThemeImgCache[path] = im;
    return im;
}

/// 角标素材查找：返回图，并回填它到底来自哪个文件（日志要打完整路径）
static UIImage *TBThemeBadgeImageWithPath(NSString **outPath) {
    TB_RENDER_SCOPE();
    if (outPath) *outPath = nil;

    // ① 全局自定义素材 / 素材包（CustomBadgePath）—— 最高优先，按路径缓存
    id cb = TBPref(@"CustomBadgePath");
    if ([cb isKindOfClass:[NSString class]] && [(NSString *)cb length]) {
        static NSString *sCachedPath = nil;
        static UIImage *sCachedImg = nil;
        static BOOL sCachedDone = NO;
        NSString *cps = [(NSString *)cb copy];
        if (!sCachedDone || ![cps isEqualToString:sCachedPath ?: @""]) {
            sCachedPath = cps;
            sCachedDone = YES;
            // 必须用 init：imageWithContentsOfFile: 已被本引擎 hook（递归会爆栈）
            sCachedImg = [[UIImage alloc] initWithContentsOfFile:cps];
        }
        if (sCachedImg) {
            if (outPath) *outPath = cps;
            return sCachedImg;
        }
    }
    if (TBSafeMode()) return nil;

    NSString *theme = TBActiveTheme();
    if (!theme.length) return nil;

    // ② 主题 Bundles 递归表（大小写不敏感；Bundles/ 与 Bundles/com.apple.springboard/ 都覆盖）
    [gLock lock];
    NSMutableDictionary *res = TBThemeBundleRes();
    NSString *hit = nil;
    NSArray *keys = @[ @"sbbadgebg@3x.png", @"sbbadgebg@2x.png", @"sbbadgebg.png", @"sbbadgebg" ];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSString *p = res[keys[i]];
        if (p.length) { hit = [p copy]; break; }
    }
    [gLock unlock];
    if (hit.length) {
        UIImage *im = TBBadgeImageFromFileCached(hit);
        if (im) { if (outPath) *outPath = hit; return im; }
    }

    // ③ IconBundles / AnemoneEffects / 主题根目录（老主题常把角标丢在这些地方；素材包同名也算）
    NSString *dir = TBThemeDir(theme);
    if (dir.length) {
        NSArray *subs = @[ @"IconBundles", @"AnemoneEffects", @"" ];
        for (NSUInteger i = 0; i < subs.count; i++) {
            NSString *sub = subs[i];
            NSString *d = sub.length ? TBResolveDirCI(dir, sub) : dir;
            if (!d.length) continue;
            NSString *p = TBFindBestScaledPNG(d, @"SBBadgeBG");
            if (!p) continue;
            UIImage *im = TBBadgeImageFromFileCached(p);
            if (im) { if (outPath) *outPath = p; return im; }
        }
    }
    return nil;
}

/// 带日志的角标素材查找：同一主题（且"有没有素材"的结论没变）只打一次。
/// 必打「角标：命中 <完整路径>」或「角标：没找到素材」。
static UIImage *TBThemeBadgeImage(void) {
    TB_RENDER_SCOPE();
    static NSString *sLoggedTheme = nil;
    static BOOL sLoggedFound = NO;
    NSString *theme = TBActiveTheme() ?: @"";
    NSString *path = nil;
    UIImage *img = TBThemeBadgeImageWithPath(&path);
    BOOL found = (img != nil);
    BOOL same = (sLoggedTheme && [sLoggedTheme isEqualToString:theme] && sLoggedFound == found);
    if (!same) {
        sLoggedTheme = [theme copy];
        sLoggedFound = found;
        if (found) {
            TBLog(@"角标：命中 %@", path.length ? path : @"(自定义素材，路径为空)");
        } else {
            TBLog(@"角标：没找到素材（找过 CustomBadgePath、Bundles/SBBadgeBG@3x|@2x|.png、"
                  @"Bundles/com.apple.springboard/SBBadgeBG*、IconBundles/SBBadgeBG*、"
                  @"AnemoneEffects/SBBadgeBG* 和素材包同名文件，都大小写不敏感）"
                  @"→ 不改角标。要换请在抽屉里「导入角标图片」，或把 SBBadgeBG@3x.png 放进主题 Bundles/");
        }
    }
    return img;
}

#pragma mark - 角标还原表

/// 一条还原记录：我们换掉过哪一层、换之前是什么（视图一律弱引用，注销时不留野指针）
@interface TBBadgeRestore : NSObject
@property (nonatomic, weak) UIView *owner;         // 角标根视图（判断"还是不是我们换的图"）
@property (nonatomic, weak) UIImageView *plate;    // 被换的底板（nil = 走 layer.contents 通道）
@property (nonatomic, weak) UIView *contentsView;  // 直接写在 layer.contents 上的那一层
@property (nonatomic, strong) UIImage *origImage;
@property (nonatomic, assign) UIViewContentMode origMode;
@property (nonatomic, assign) BOOL origClips;
@property (nonatomic, strong) UIColor *origBG;
@property (nonatomic, assign) BOOL hadRedBG;
@property (nonatomic, strong) UIImage *appliedImage;
@property (nonatomic, strong) id origContents;
@end

@implementation TBBadgeRestore
@end

static NSMutableArray<TBBadgeRestore *> *gBadgeRestores;   // 全局还原表
static BOOL gBadgeApplied = NO;                            // 现在有没有我们换上去的角标

/// 这个角标上换过的地方，是不是"还是我们换的那张图"（是 → 本次布局不用再处理，幂等）
static BOOL TBBadgeAlreadyApplied(UIView *owner) {
    NSArray *list = gBadgeRestores;
    if (!list.count) return NO;
    for (NSUInteger i = 0; i < list.count; i++) {
        TBBadgeRestore *e = list[i];
        if (e.owner != owner) continue;
        if (e.contentsView) {
            if (e.contentsView.layer.contents) return YES;
        } else if (e.plate && e.plate.image == e.appliedImage) {
            return YES;
        }
    }
    return NO;
}

static void TBBadgeRemember(TBBadgeRestore *e) {
    if (!gBadgeRestores) gBadgeRestores = [NSMutableArray array];
    [gBadgeRestores addObject:e];
    gBadgeApplied = YES;
}

/// 还原我们换过的所有底板（换主题 / 关角标开关 / 取消应用 / 设置变更都走这里）。
/// 必须在主线程调用（会碰 UIKit 视图）。
static NSUInteger TBBadgeRestoreAll(NSString *why) {
    if (!gBadgeRestores.count) { gBadgeApplied = NO; return 0; }
    NSArray *list = [gBadgeRestores copy];
    [gBadgeRestores removeAllObjects];
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < list.count; i++) {
        TBBadgeRestore *e = list[i];
        @try {
            if (e.contentsView) {
                if (e.contentsView.layer.contents) { e.contentsView.layer.contents = e.origContents; n++; }
            } else if (e.plate) {
                e.plate.image = e.origImage;          // 写回系统原图
                e.plate.contentMode = e.origMode;
                e.plate.clipsToBounds = e.origClips;
                if (e.hadRedBG) e.plate.backgroundColor = e.origBG;
                n++;
            }
        } @catch (NSException *ex) { }
    }
    gBadgeApplied = NO;
    if (n) TBLog(@"角标：还原 %lu 处（%@）", (unsigned long)n, why ?: @"设置变更");
    return n;
}

#pragma mark - 角标底板识别 / 替换

/// 角标子树里找【系统底板】：面积最大的那个 UIImageView（最底层、面积最大的那一层）
static UIImageView *TBBadgeFindPlate(UIView *root) {
    UIImageView *best = nil;
    CGFloat bestA = 0;
    NSMutableArray *level = [NSMutableArray arrayWithObject:root];
    for (int d = 0; d <= 5 && level.count; d++) {
        NSMutableArray *next = [NSMutableArray array];
        for (NSUInteger i = 0; i < level.count; i++) {
            UIView *v = level[i];
            NSArray *kids = [[v subviews] copy];
            for (NSUInteger k = 0; k < kids.count; k++) {
                UIView *sv = kids[k];
                if (sv.hidden) continue;
                if ([sv isKindOfClass:[UIImageView class]]) {
                    CGRect b = sv.bounds;
                    CGFloat a = b.size.width * b.size.height;
                    if (a > bestA) { bestA = a; best = (UIImageView *)sv; }
                }
                [next addObject:sv];
            }
        }
        level = next;
    }
    return best;
}

/// 子树里有没有 UILabel —— 有就绝不能碰这一层的 layer.contents
/// （UILabel 的文字就是画在自己的 layer.contents 上的，换掉 = 数字消失）
static BOOL TBBadgeHasLabel(UIView *v, int depth) {
    if (depth > 5) return NO;
    if ([v isKindOfClass:[UILabel class]]) return YES;
    NSArray *kids = [[v subviews] copy];
    for (NSUInteger i = 0; i < kids.count; i++) {
        if (TBBadgeHasLabel(kids[i], depth + 1)) return YES;
    }
    return NO;
}

/// 只换【一层】底板；返回换了几层（0 或 1）。
/// 绝不既改 image 又改 layer.contents —— 那会画两层（"角标有两个"）。
static NSUInteger TBBadgeApply(UIView *root, UIImage *badge, BOOL verbose) {
    if (!root || !badge) return 0;

    // ① 优先：面积最大的 UIImageView = 系统底板
    UIImageView *plate = TBBadgeFindPlate(root);
    if (plate) {
        if (plate.image == badge) return 1;      // 已经是主题角标 → 幂等（不重复叠加、不重复记录）
        TBBadgeRestore *e = [[TBBadgeRestore alloc] init];
        e.owner = root;
        e.plate = plate;
        e.origImage = plate.image;
        e.origMode = plate.contentMode;
        e.origClips = plate.clipsToBounds;
        e.origBG = plate.backgroundColor;
        plate.image = badge;
        plate.contentMode = UIViewContentModeScaleToFill;
        plate.clipsToBounds = YES;
        // 底板自己画的红底 → 抹掉（只动底板，不碰数字和其它 view）
        UIColor *bg = e.origBG;
        CGFloat r = 0, g = 0, b = 0, a = 0;
        if (bg && [bg getRed:&r green:&g blue:&b alpha:&a] &&
            a > 0.2 && r > 0.45 && r > g * 1.6 && r > b * 1.6) {
            e.hadRedBG = YES;
            plate.backgroundColor = [UIColor clearColor];
        }
        e.appliedImage = badge;
        TBBadgeRemember(e);
        if (verbose) {
            TBLogOnce([@"badgeplate|" stringByAppendingFormat:@"%@|%@",
                       NSStringFromClass([plate class]), TBActiveTheme() ?: @""],
                      @"角标替换：底板 %@ frame=%@ 原图=%@ → 主题角标 %@（只换这一层，数字层没碰）",
                      NSStringFromClass([plate class]),
                      NSStringFromCGRect(CGRectIntegral(plate.frame)),
                      e.origImage ? NSStringFromCGSize(e.origImage.size) : @"(无)",
                      NSStringFromCGSize(badge.size));
        }
        return 1;
    }

    // ② 兜底：没有 UIImageView 底板 —— 只在「本层直接画了 CGImage，且子树里没有 UILabel」时换一次
    if (!TBBadgeHasLabel(root, 0) && root.layer.contents &&
        CFGetTypeID((__bridge CFTypeRef)root.layer.contents) == CGImageGetTypeID()) {
        TBBadgeRestore *e = [[TBBadgeRestore alloc] init];
        e.owner = root;
        e.contentsView = root;
        e.origContents = root.layer.contents;
        root.layer.contents = (__bridge id)badge.CGImage;
        e.appliedImage = badge;
        TBBadgeRemember(e);
        if (verbose) {
            TBLogOnce([@"badgecontents|" stringByAppendingFormat:@"%@|%@",
                       NSStringFromClass([root class]), TBActiveTheme() ?: @""],
                      @"角标替换：%@ 的 layer.contents 底板 → 主题角标（子树里没有 UILabel，数字不受影响）",
                      NSStringFromClass([root class]));
        }
        return 1;
    }
    return 0;
}

/// 还原之后：让屏幕上已有的角标重新布局一次 —— 新主题（有素材）立刻补上，
/// 没素材的主题就保持系统原样。只碰类名带 Badge 的视图，量很小。
static int TBBadgeRelayoutTree(UIView *v, int depth) {
    if (depth > 8) return 0;
    int n = 0;
    NSArray *kids = [[v subviews] copy];
    if ([NSStringFromClass([v class]) rangeOfString:@"Badge"
                                           options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [v setNeedsLayout];
        [v layoutIfNeeded];
        return 1;
    }
    for (NSUInteger i = 0; i < kids.count; i++) n += TBBadgeRelayoutTree(kids[i], depth + 1);
    return n;
}

static void TBBadgeRelayoutVisible(void) {
    TB_RENDER_SCOPE();
    @try {
        NSArray *wins = [[UIApplication sharedApplication] windows];
        for (NSUInteger i = 0; i < wins.count; i++) TBBadgeRelayoutTree(wins[i], 0);
    } @catch (NSException *e) { }
}

/// 子树里有没有「这个指针的视图」（0.12s 补刷用：找不到 = 已被复用/销毁，别再贴）
static BOOL TBBadgeTreeHasOwner(UIView *root, uintptr_t tag, int depth) {
    if (!root || depth > 8) return NO;
    if ((uintptr_t)root == tag) return YES;
    for (UIView *k in root.subviews) {
        if (TBBadgeTreeHasOwner(k, tag, depth + 1)) return YES;
    }
    return NO;
}

static void tb_badgeLayout(id self, SEL _cmd) {
    TB_RENDER_SCOPE();
    if (![self isKindOfClass:[UIView class]]) {
        TBBadgeCallOrig(self, _cmd);
        return;
    }
    // 父类/子类各挂了一次 hook 时，系统的 [super layoutSubviews] 会把我们拉回来：
    // 只放行最外层那一次，避免同一次布局把角标处理两遍（"两个角标叠着"来源之一）
    static int sDepth = 0;
    if (sDepth > 0) {
        TBBadgeCallOrig(self, _cmd);
        return;
    }
    sDepth++;
    UIView *selfView = (UIView *)self;
    @try {
        // 安全模式 / 总开关关闭：所有新路径（角标/阴影 layer/全局效果）都必须直通原实现。
        // 原来这里只查 UseThemeBadge —— 安全模式下只要开过角标就会继续换图，违背直通原则。
        if (TBSafeMode() || !TBEnabled()) {
            if (gBadgeApplied) TBBadgeRestoreAll(@"安全模式或总开关关闭");
            TBBadgeCallOrig(self, _cmd);
            sDepth--;
            return;
        }
        id ub = TBPref(@"UseThemeBadge");
        BOOL on = (ub && [ub boolValue]);
        id cb = TBPref(@"CustomBadgePath");
        BOOL hasCustom = ([cb isKindOfClass:[NSString class]] && [(NSString *)cb length] > 0);

        if (!on && !hasCustom) {
            // 关掉开关 / 取消应用 → 把之前换上的底板还原成系统原图（不还原就会"赖着不走"）
            if (gBadgeApplied) TBBadgeRestoreAll(@"角标开关已关闭");
            if (o_badgeLayout) o_badgeLayout(self, _cmd);
            sDepth--;
            return;
        }

        TBBadgeCallOrig(self, _cmd);   // 先让系统把底板和数字摆好

        UIImage *badge = TBThemeBadgeImage();
        if (!badge) { sDepth--; return; }               // 没素材一律不动

        if (TBBadgeAlreadyApplied(selfView)) { sDepth--; return; }   // 幂等

        NSUInteger hits = TBBadgeApply(selfView, badge, YES);
        if (hits > 0) {
            TBLogOnce([@"badgecount|" stringByAppendingFormat:@"%@|%@",
                       NSStringFromClass([self class]), TBActiveTheme() ?: @""],
                      @"角标替换：已换底板（%@，%lu 处）", NSStringFromClass([self class]),
                      (unsigned long)hits);
            // 系统有时在 layout 之后才把图写回去 → 稍后补一次（同样幂等，不会叠加）。
            // ★ 旧块捕获了「当时的 badge 图」：0.12s 内若换了主题并已还原（TBReload），
            //   会把【旧主题】的角标贴回去。补两道闸：
            //   ① owner 必须还在屏幕视图树上（不在 = 已销毁/进复用池）；
            //   ② 原有 gBadgeApplied / 幂等检查保留。
            __weak UIView *wv = selfView;
            uintptr_t ownerTag = (uintptr_t)selfView;
            TBThemeRenderState *badgeState = TBCurrentRenderState();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (badgeState != TBCommittedState()) return;
                UIView *v = wv;
                if (!v) return;
                if (!gBadgeApplied) return;                    // 已经被还原了，不要再贴回去
                if (TBBadgeAlreadyApplied(v)) return;          // 已经是我们换的图
                BOOL stillOnScreen = NO;
                @try {
                    NSArray *wins = [[UIApplication sharedApplication] windows];
                    for (UIView *w in wins) {
                        if (TBBadgeTreeHasOwner(w, ownerTag, 0)) { stillOnScreen = YES; break; }
                    }
                } @catch (NSException *e) { }
                if (!stillOnScreen) return;                    // 不在屏幕上：别把旧主题角标贴回复用池
                TBBadgeApply(v, badge, NO);
            });
        }
    } @catch (NSException *e) {
        TBLog(@"角标替换异常：%@", e.reason);
    }
    sDepth--;
}

static BOOL gDoneBadge = NO;

static BOOL gDoneClock = NO;

// ---- 时钟表盘：SBHClockApplicationIconImageView 把整块表盘合成进自己的 contents，
//      没有子视图，所以「重画」不会让它重新取图。SnowBoard 的做法是 hook
//      SBLiveIconImageView -contentsImage / -squareContentsImage，直接返回主题表盘。
// ---- 指针颜色 / 秒针显隐：系统自己的接口（SnowBoard 用的就是这三个）----

static ContentsImgFn o_contentsImageLive, o_squareContentsImageLive;
static BOOL sInClockContents = NO;   // 防自调用（hook 装错层会无限递归）

static BOOL TBIsClockView(id v) {
    NSString *cls = NSStringFromClass([v class]);
    return [cls rangeOfString:@"Clock"].location != NSNotFound;
}

/// 按视图当前尺寸把主题表盘做成对应像素尺寸的图
/// 表盘必须带圆角遮罩：系统给出的图标是遮罩过的（超椭圆），我们直接写
/// layer.contents 的话，四角不透明就会露出方块（就是「时不时变成方的」）。
/// 形状规则与图标完全一致（① 主题遮罩图 → ② 自定义圆角 → ③ 系统形状 → 兜底）
static UIImage *TBClockRoundedFace(UIImage *img) {
    TB_RENDER_SCOPE();
    // 表盘与普通图标统一走形状、玻璃叠加和阴影；不写 layer.contents。
    UIImage *shaped = TBApplyIconShape(img, NO);
    return TBApplyIconEffects(shaped) ?: shaped;
}

/// 时钟表盘：SnowBoard 的做法 —— 主题 Bundles 里有 ClockIconBackgroundSquare 就用它
/// （按图标圆角遮罩好），没有就返回 nil，让调用方走系统原实现。
/// 注意：不走 IconBundles 的静态图标；静态图标只在列表/快照里用，不参与实时时钟。
static void TBClockInvalidateCache(void) {
    [gClockFaceCache removeAllObjects];
}

static void TBClockClearMappedContents(UIView *v, BOOL clearLayer) {
    if (!v) return;
    @try { [v setValue:nil forKey:@"mappedContentsImage"]; } @catch (NSException *e) { }
    @try { [v setValue:nil forKey:@"squareMappedContentsImage"]; } @catch (NSException *e) { }
    if (clearLayer) {
        v.layer.contents = nil;
        v.layer.contentsGravity = kCAGravityResize;
        [v setNeedsDisplay];
    }
}

static UIImage *TBClockMaterialFace(UIView *v) {
    TB_RENDER_SCOPE();
    if (!v) return nil;
    NSString *key = [NSString stringWithFormat:@"%@|%.0fx%.0f|%.1f", TBActiveTheme() ?: @"",
                     v.bounds.size.width, v.bounds.size.height, [UIScreen mainScreen].scale];
    UIImage *ready = [gClockFaceCache objectForKey:key];
    if (ready) return ready;
    UIImage *face = TBResourceImage(@"ClockIconBackgroundSquare");
    if (!face) return nil;
    CGFloat sc = [UIScreen mainScreen].scale;
    if (sc < 0.5) sc = 3.0;
    TBInfo info;
    info.size = v.bounds.size;
    info.scale = sc;
    info.ratio = 0;
    if (info.size.width < 1 || info.size.height < 1) info.size = CGSizeMake(64, 64);
    UIImage *out = TBClockRoundedFace(TBFitImage(face, info));
    if (out) [gClockFaceCache setObject:out forKey:key];
    return out;
}

static id tb_clockContentsImage(id self, SEL _cmd) {
    TB_RENDER_SCOPE();
    TBDiagEmit(@"clock.enter", self, _cmd, nil, nil, sInClockContents ? @"shared guard=1" : @"shared guard=0");
    if (!sInClockContents && TBIsClockView(self)) {
        UIImage *face = TBClockMaterialFace((UIView *)self);
        if (face) {
            TBDiagEmit(@"clock.theme", self, _cmd, face, nil, @"material face");
            TBLogOnce(@"clockface|contents", @"时钟表盘：contentsImage 返回主题表盘 %.0fx%.0f",
                      face.size.width, face.size.height);
            return face;
        }
    }
    if (sInClockContents) return nil;                 // 逃出递归
    if (!o_contentsImageLive) return nil;
    sInClockContents = YES;
    id r = o_contentsImageLive(self, _cmd);
    sInClockContents = NO;
    TBDiagEmit(@"clock.original", self, _cmd, r, nil, @"after original");
    return r;
}

static id tb_clockSquareContentsImage(id self, SEL _cmd) {
    TB_RENDER_SCOPE();
    TBDiagEmit(@"clock.enter", self, _cmd, nil, nil, sInClockContents ? @"shared guard=1" : @"shared guard=0");
    if (!sInClockContents && TBIsClockView(self)) {
        UIImage *face = TBClockMaterialFace((UIView *)self);
        if (face) { TBDiagEmit(@"clock.theme", self, _cmd, face, nil, @"material face"); return face; }
    }
    if (sInClockContents) return nil;
    if (!o_squareContentsImageLive) return nil;
    sInClockContents = YES;
    id r = o_squareContentsImageLive(self, _cmd);
    sInClockContents = NO;
    TBDiagEmit(@"clock.original", self, _cmd, r, nil, @"after original");
    return r;
}

/// 找真正「自己声明」了这个方法的类（不能挂到只有继承实现的类上，否则原实现
/// 指针会指向我们自己的 hook → 自调用递归）
static Class TBClassDeclaring(Class cls, SEL sel) {
    for (Class c = cls; c && c != [NSObject class]; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        BOOL found = NO;
        for (unsigned int i = 0; i < n; i++) {
            if (method_getName(ms[i]) == sel) { found = YES; break; }
        }
        free(ms);
        if (found) return c;
    }
    return Nil;
}


/// 安装：优先挂 SBLiveIconImageView（时钟视图的父类，SnowBoard 也是挂这里），
/// 再兜底挂 SBIconImageView 的同名实现。
static void TBInstallClockContentsHooks(void) {
    // 时钟类自己声明这两个方法；优先直接钩专用类，避免父类已有缓存映射继续复用旧表盘。
    Class live = NSClassFromString(@"SBHClockApplicationIconImageView");
    if (!live) live = NSClassFromString(@"SBLiveIconImageView");
    if (!live) live = NSClassFromString(@"SBIconImageView");
    if (!live) { TBLog(@"contentsImage：找不到图标图片视图类"); return; }
    // contentsImage / squareContentsImage 都是实例方法（用 TBHook，不是 TBHookClass）
    Class c1 = TBClassDeclaring(live, NSSelectorFromString(@"contentsImage"));
    if (c1) o_contentsImageLive = (ContentsImgFn)TBHook(c1, @"contentsImage",
                                                        (IMP)tb_clockContentsImage, "时钟contents");
    Class c2 = TBClassDeclaring(live, NSSelectorFromString(@"squareContentsImage"));
    if (c2) o_squareContentsImageLive = (ContentsImgFn)TBHook(c2, @"squareContentsImage",
                                                              (IMP)tb_clockSquareContentsImage, "时钟squareContents");
    // 指针与中心点完全交回系统，不再注入主题针集。
}

static BOOL gDoneSpecifier = NO;
static BOOL gDoneGen = NO;
static BOOL gDoneISGeneration = NO;
static BOOL gDoneIconImageView = NO;
static BOOL gDoneSetIcon = NO;
static BOOL gDoneLayout = NO;
static BOOL gDoneIFImage = NO;

// 仅 SpringBoard 回应 App 存活查询；不依赖写日志或图标 Hook。
static void TBInstallRuntimeResponder(void) {
    static BOOL installed = NO;
    static int requestToken = NOTIFY_TOKEN_INVALID;
    static int replyToken = NOTIFY_TOKEN_INVALID;
    if (installed || ![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]) return;
    uint32_t rc = notify_register_check("com.ning.themeboard.runtime.reply", &replyToken);
    if (rc == NOTIFY_STATUS_OK) {
        rc = notify_register_dispatch("com.ning.themeboard.runtime.request", &requestToken,
                                     dispatch_get_main_queue(), ^(int token) {
            uint64_t nonce = 0;
            if (notify_get_state(token, &nonce) != NOTIFY_STATUS_OK || !nonce) return;
            if (notify_set_state(replyToken, nonce) == NOTIFY_STATUS_OK)
                notify_post("com.ning.themeboard.runtime.reply");
        });
    }
    if (rc == NOTIFY_STATUS_OK) { installed = YES; return; }
    if (requestToken != NOTIFY_TOKEN_INVALID) notify_cancel(requestToken);
    if (replyToken != NOTIFY_TOKEN_INVALID) notify_cancel(replyToken);
    requestToken = replyToken = NOTIFY_TOKEN_INVALID;
}

static void TBInstall(void) {
    TBInstallRuntimeResponder();
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
        o_imageNamedInBundle = (ImgNameBundleFn)TBHookClass([UIImage class], @"imageNamed:inBundle:",
                                                            (IMP)tb_imageNamedInBundle, "UIImage.imageNamed:inBundle");
        o_imageNamedInBundleTrait = (ImgNameBundleTraitFn)TBHookClass([UIImage class],
                                                            @"imageNamed:inBundle:compatibleWithTraitCollection:",
                                                            (IMP)tb_imageNamedInBundleTrait,
                                                            "UIImage.imageNamed:inBundle:trait");
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

    if ([TBProcName() isEqualToString:@"Preferences"]) {
        TBPSInstallMethod(isicon,NSSelectorFromString(@"getCGImageForImageDescriptor:completion:"),
                          (IMP)tb_settingsISAsync,&o_settingsISAsync,"v@:@@");
        if (TBSettingsISSizeMatches(isicon))
            TBPSInstallMethod(isicon,NSSelectorFromString(@"imageForSize:scale:"),
                              (IMP)tb_settingsISSize,&o_settingsISSize,"@@:{d");
    }

    // 桌面时钟图标（运行时检测）
    if (clockView && !gDoneClock) {
        gDoneClock = YES;
        // 指针一律用系统自己的（黑时针 + 黑分针 + 橙秒针），不注入主题指针。
        // 表盘：hook contentsImage，始终返回当前主题的表盘（换主题后自然就是新表盘）
        TBInstallClockContentsHooks();
    }

    // 日历专用提供者：系统在原生提供者里生成星期和日期。
    TBInstallCalendarProviderHooks();
    TBDiagProbeOnce();

    // ★★★ 通知中心图标：0.15.89 起永久封存。
    //   照 SystemX 1.5-8 的 NCBadgedIconView 五连 hook（init×2/set×2/layout）实测：
    //   无任何效果 + 闪屏 + 自动注销。与 0.15.73/82/84/86 四次失败一致。
    //   结论（最终）：本机 17.2.1 上 NC 图标替换不可行，任何 NC* 类 hook 都会破坏通知系统。
    //   除非未来做真机运行时 dump 并找到安全插入点，否则不再尝试。

    // ★ 0.18.7：0.18.1 的「时钟供图」（SBLiveIconImageView / SBHClockApplicationIconImageView 上
    //   重挂 contentsImage / squareContentsImage，4 个 orig 槽）已整体移除。
    //   它和 0.16.9 里那套 TBInstallClockContentsHooks（带 gDoneClock 保护、走 TBClassDeclaring）重复，
    //   而且是无保护重挂 → 会造成 orig 槽自我覆盖 / 自我递归。现在只保留 0.16.9 原有那套（时钟行为回到 0.16.9）。

    // 角标底板替换：从视图层换图（SBIconBadgeView / _SBIconBadgeView）。
    // ★ 0.15.51 拷问修复：这个块原来被嵌进了上面 clockView 的 if 里（0.15.49 少一个闭括号），
    //   桌面上没有时钟图标视图时整个角标 hook 都装不上（替换/还原全失效，表现即 0.15.49 的
    //   「角标赖着不走 / 变不回来」）。现在独立成块，clockView 有没有都装。
    if (!gDoneBadge) {
        gDoneBadge = YES;
        for (NSString *clsName in @[@"SBIconBadgeView", @"_SBIconBadgeView", @"SBHIconBadgeView"]) {
            Class bc = NSClassFromString(clsName);
            if (!bc) continue;
            if (TBHasMethod(bc, @"layoutSubviews")) {
                // 每个类存自己的 orig IMP（共用一个全局会让 A 类实例调进 B 类的原始实现）。
                // 注意：必须在 TBHook 之前取 method_getImplementation —— hook 后 Method 里的 imp
                // 就被改写成本实现的了。
                Method bm = class_getInstanceMethod(bc, @selector(layoutSubviews));
                IMP borig = bm ? method_getImplementation(bm) : NULL;
                o_badgeLayout = (void (*)(id, SEL))TBHook(bc, @"layoutSubviews",
                                                          (IMP)tb_badgeLayout, "角标视图");
                if (borig) {
                    if (!gBadgeOrig) gBadgeOrig = [NSMutableDictionary dictionary];
                    gBadgeOrig[clsName] = [NSValue valueWithPointer:borig];
                }
            }
        }
    }
        // 不接管 iconImageWithImageInfo:includingMask:
        // 那一层返回的是「表盘+指针」的合成图，接管后系统画的指针会变形
        //（三根一样粗、橙秒针消失）。改由资源重定向提供 ClockIconBackgroundSquare，
        // 让系统自己合成底图与指针 —— 与 SnowBoard 一致。

    if (spec && !gDoneSpecifier && ![TBProcName() isEqualToString:@"Preferences"]) {
        gDoneSpecifier=YES;
        if (TBHasMethod(spec,@"setupIconImageWithBundle:"))
            o_setupIconBundle=(SetupIconFn)TBHook(spec,@"setupIconImageWithBundle:",
                (IMP)tb_setupIconWithBundle,"PSSpecifier 设置页图标");
    }
    // Independent original slots permit the existing finite installation retries.
    if ([TBProcName() isEqualToString:@"Preferences"]) {
        Class cell=NSClassFromString(@"PSTableCell");
        TBPSInstallMethod(cell,NSSelectorFromString(@"getIcon"),(IMP)tb_psGetIcon,&o_tbPSGetIcon,"@@:");
        TBPSInstallMethod(cell,NSSelectorFromString(@"getLazyIcon"),(IMP)tb_psGetLazyIcon,&o_tbPSGetLazyIcon,"@@:");
        TBPSInstallMethod(cell,NSSelectorFromString(@"getIconFromIconServices"),
                          (IMP)tb_psGetIconFromServices,&o_tbPSGetIconFromServices,"@@:");
        TBPSInstallMethod(cell,NSSelectorFromString(@"setIcon:"),(IMP)tb_psSetIcon,&o_tbPSSetIcon,"v@:@");
        TBPSInstallMethod(cell,NSSelectorFromString(@"prepareForReuse"),
                          (IMP)tb_psPrepareForReuse,&o_tbPSPrepareForReuse,"v@:");
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

        // 0.18.4：带 imageAppearance 的新签名（iOS 17 过渡动画用的就是它）
        // ★ 0.18.6：同样只装一次（否则 orig 槽会被我们自己的实现覆盖 → 自我递归）
        static BOOL gDoneAppearanceHooks = NO;
        if (!gDoneAppearanceHooks) {
            gDoneAppearanceHooks = YES;
        if (TBHasMethod(cache, @"imageForIcon:imageAppearance:options:")) {
            o_imageForIconApp = (FnIconAppOpt)TBHook(cache, @"imageForIcon:imageAppearance:options:",
                                                     (IMP)tb_imageForIconApp, "imageForIcon:appearance:options");
        }
        if (TBHasMethod(cache, @"cacheImage:forIcon:imageAppearance:options:")) {
            o_cacheImageForIconApp = (FnImageForIconAppOpt)TBHook(cache, @"cacheImage:forIcon:imageAppearance:options:",
                                                                 (IMP)tb_cacheImageForIconApp, "cacheImage:forIcon:appearance:options");
        }
        }
    }

    // SBIconImageView.setImage:（安全版，SnowBoard 通道）
    Class iconImageViewCls = NSClassFromString(@"SBIconImageView");
    if (iconImageViewCls && !gDoneIconImageView) {
        gDoneIconImageView = YES;
        if (TBHasMethod(iconImageViewCls, @"setImage:")) {
            o_setImageOnIconView = (SetImgFn)TBHook(iconImageViewCls, @"setImage:", (IMP)tb_setImageOnIconView, "SBIconImageView");
        }
        // SBIconImageView.resetImageWithAppIcon:（拖拽放置/状态重建通道）
        if (TBHasMethod(iconImageViewCls, @"resetImageWithAppIcon:")) {
            o_resetImageOnIconView = (ResetImgFn)TBHook(iconImageViewCls, @"resetImageWithAppIcon:", (IMP)tb_resetImageOnIconView, "SBIconImageView.reset");
        }
    }


    // 方法可能延迟出现；每个选择子独立保护，避免重试覆盖原实现并递归。
    {
        static BOOL gDoneModernTCO = NO;
        static BOOL gDoneModernTO = NO;
        Class ic = NSClassFromString(@"SBIcon");
        if (ic) {
            if (!gDoneModernTCO && TBHasMethod(ic, @"iconImageWithInfo:traitCollection:context:options:")) {
                gDoneModernTCO = YES;
                o_imgTCO = (FnImgTCO)TBHook(ic, @"iconImageWithInfo:traitCollection:context:options:", (IMP)tb_imgTCO, "现代取图 tco");
            }
            if (!gDoneModernTO && TBHasMethod(ic, @"iconImageWithInfo:traitCollection:options:")) {
                gDoneModernTO = YES;
                o_imgTO = (FnImgTO)TBHook(ic, @"iconImageWithInfo:traitCollection:options:", (IMP)tb_imgTO, "现代取图 to");
            }
            // ★ 1.46：进退 App 形变动画的方形原图通道（挂真正声明它的那个类，避免自递归）
            static BOOL gDoneSquareContents = NO;
            if (!gDoneSquareContents) {
                Class sqDecl = TBClassDeclaring(ic, NSSelectorFromString(@"squareContentsImage"));
                if (sqDecl) {
                    gDoneSquareContents = YES;
                    o_squareContentsIcon = (SquareContentsFn)TBHook(sqDecl, @"squareContentsImage",
                                                                    (IMP)tb_squareContentsIcon, "方形原图(进退动画)");
                }
            }
        }
    }

    // SBIconImageCrossfadeView 进退 App 转场代理层（只换主题图，不改转场行为）
    TBInstallCrossfadeHooks();

    // SBIconView -layoutSubviews（自愈校验：图不对才贴，收敛后不再触发）
    Class iconViewCls2 = NSClassFromString(@"SBIconView");
    if (iconViewCls2 && !gDoneLayout && TBHasMethod(iconViewCls2, @"layoutSubviews")) {
        gDoneLayout = YES;
        o_iconViewLayout = (LayoutFn)TBHook(iconViewCls2, @"layoutSubviews",
                                            (IMP)tb_iconViewLayoutSubviews, "SBIconView.layout");
    }
    // ★ 1.33：通知中心数据层（类不存在就跳过）
    {
        static BOOL gDoneNC = NO;
        if (!gDoneNC) {
            gDoneNC = YES;
            Class ncc = NSClassFromString(@"NCNotificationContent");
            if (ncc) {
                Class rc = NSClassFromString(@"NCNotificationIconRecipe");
                if (rc && class_getInstanceMethod(rc, NSSelectorFromString(@"image")))
                    o_ncRecipeImage = (id (*)(id, SEL))TBHook(rc, @"image", (IMP)tb_ncRecipeImage, "NC recipe.image");
                else if (rc && class_getInstanceMethod(rc, NSSelectorFromString(@"_image")))
                    o_ncRecipeImage = (id (*)(id, SEL))TBHook(rc, @"_image", (IMP)tb_ncRecipeImage, "NC recipe._image");
            }
            if (ncc && TBHasMethod(ncc, @"icons"))
                o_ncIcons = (id (*)(id, SEL))TBHook(ncc, @"icons", (IMP)tb_ncIcons, "NC 图标(数据层)");
            // NC 视图层：只挂容器，小图标在其徽标子视图中查找。
            Class reqCls = NSClassFromString(@"NCNotificationRequest");
            if (reqCls && TBHasMethod(reqCls, @"content"))
                o_ncRequestContent = (id (*)(id, SEL))TBHook(reqCls, @"content", (IMP)tb_ncRequestContent, "NC request.content");
            Class ncsCls = NSClassFromString(@"NCNotificationSeamlessContentView");
            if (ncsCls && TBHasMethod(ncsCls, @"layoutSubviews"))
                o_ncsLayout = (void (*)(id, SEL))TBHook(ncsCls, @"layoutSubviews", (IMP)tb_ncsLayout, "NC 内容视图");
            Class ncbCls = NSClassFromString(@"NCBadgedIconView");
            if (ncbCls && TBHasMethod(ncbCls, @"layoutSubviews"))
                o_ncbLayout = (void (*)(id, SEL))TBHook(ncbCls, @"layoutSubviews", (IMP)tb_ncbLayout, "NC 图标视图");
        }
    }

    // SBIconView -_setIcon:animated:（若存在则用；17.2 上通常不存在）
    Class iconViewCls = NSClassFromString(@"SBIconView");
    if (iconViewCls && !gDoneSetIcon && TBHasMethod(iconViewCls, @"_setIcon:animated:")) {
        gDoneSetIcon = YES;
        o_setIconAnimated = (SetIconFn)TBHook(iconViewCls, @"_setIcon:animated:",
                                              (IMP)tb_setIconAnimated, "SBIconView._setIcon");
    }

    // 不安装 _iconImageView / crossfade getter hook：那属于图标初始化热路径。

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
    if (ifImage && !gDoneIFImage) {
        gDoneIFImage = YES;
        if (TBHasMethod(ifImage, @"imageForDescriptor:")) {
            o_ifImgDescriptor = (IFImgFn)TBHook(ifImage, @"imageForDescriptor:", (IMP)tb_ifImgDescriptor, "IFImage.desc");
        }
        if (TBHasMethod(ifImage, @"imageForSize:scale:")) {
            o_ifImgSize = (IFSizeFn)TBHook(ifImage, @"imageForSize:scale:", (IMP)tb_ifImgSize, "IFImage.size");
        }
    }

    // 一次性自检：确认关键 hook 都已就位（每个进程只打一行）
    static BOOL loggedState = NO;
    if (!loggedState) {
        loggedState = YES;
        TBLog(@"hookstate cache=%d gen=%d genImg=%d ifimg=%d sbiv=%d",
              o_imageForIcon != NULL, o_isGeneration != NULL,
              o_isGenerateImage != NULL, o_ifImgSize != NULL,
              o_setImageOnIconView != NULL);
    }

    // generateIconImageWithInfo: 仅在 iOS 17.x 上启用（唯一已验证版本）
    if (icon && !gDoneGen) {
        gDoneGen = YES;
        if (TBHasMethod(icon, @"generateIconImageWithInfo:")) {
            o_generateIconImageWithInfo = (FnGen)TBHook(icon, @"generateIconImageWithInfo:",
                                                        (IMP)tb_generateIconImageWithInfo, "generateIconImageWithInfo");
        }
        if (TBHasMethod(icon, @"iconImageWithInfo:")) {
            o_iconImageWithInfo = (FnInfoImage)TBHook(icon, @"iconImageWithInfo:",
                                                      (IMP)tb_iconImageWithInfo, "iconImageWithInfo");
        }
        if (TBHasMethod(icon, @"unmaskedIconImageWithInfo:")) {
            o_unmaskedIconImageWithInfo = (FnInfoImage)TBHook(icon, @"unmaskedIconImageWithInfo:",
                                                             (IMP)tb_unmaskedIconImageWithInfo, "unmaskedIconImageWithInfo");
        }
    }
}


/// 让 SpringBoard 自己重绘桌面图标（不注销）
/// 节流：noteIconStateChangedExternally 会让 SpringBoard 重排整个桌面，
/// 日志里它在 01:04~01:05 稳定 3~4 秒一次地打，主线程就是这么被拖死的。
/// 这里限制到最少 2 秒一次，被压掉的请求只记日志（合并成后面的那一次）。
static void TBRefreshSpringBoard(NSString *why) {
    static NSLock *sLock = nil;
    static NSTimeInterval sLast = 0;
    static NSUInteger sCalls = 0, sThrottled = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sLock = [[NSLock alloc] init]; });

    const NSTimeInterval kMinInterval = 2.0;
    static BOOL sFollow = NO;   // 是否已安排「节流收尾刷新」
    [sLock lock];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    sCalls++;
    if (sLast > 0 && now - sLast < kMinInterval) {
        NSTimeInterval since = now - sLast;
        sThrottled++;
        NSUInteger n = sCalls, t = sThrottled;
        BOOL needFollow = !sFollow;
        sFollow = YES;
        [sLock unlock];
        TBLog(@"刷新节流：距上次 SpringBoard 刷新仅 %.2fs（< %.1fs）→ 跳过第 %lu 次请求（已压掉 %lu 次，触发者=%@）",
              since, kMinInterval, (unsigned long)n, (unsigned long)t, why ?: @"?");
        // ★ 被压掉的请求不再直接丢弃（原注释写「合并成后面的那一次」但实际没有）：
        //   安排一次收尾刷新，保证最后一次设置变更也能落到桌面。
        if (needFollow) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMinInterval * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [sLock lock];
                sFollow = NO;
                NSTimeInterval gap = [NSDate timeIntervalSinceReferenceDate] - sLast;
                [sLock unlock];
                if (gap >= kMinInterval - 0.05) TBRefreshSpringBoard(@"节流收尾");
            });
        }
        return;
    }
    sLast = now;
    NSUInteger n = sCalls;
    [sLock unlock];

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
                    TBLog(@"已通知 SpringBoard 刷新图标（触发者=%@ 第 %lu 次）", why ?: @"?", (unsigned long)n);
                    return;
                }
            }
        } @catch (NSException *e) {
            TBLog(@"刷新失败: %@", e.reason);
        }
    }
    TBLog(@"· 没有找到 iconManager，图标要等下次重绘（触发者=%@ 第 %lu 次）", why ?: @"?", (unsigned long)n);
}

/// 取桌面上所有图标（用于按需清理缓存）
static NSArray *TBAllIcons(void) {
    @try {
        Class sc = NSClassFromString(@"SBIconController");
        if (!sc) return @[];
        id ctrl = ((id (*)(id, SEL))objc_msgSend)(sc, NSSelectorFromString(@"sharedInstance"));
        if (!ctrl) return @[];

        // 17.2 的 SBIconModel 不支持 leafIcons 的 KVC，改成按方法探测
        id model = nil;
        SEL modelSel = NSSelectorFromString(@"iconModel");
        if ([ctrl respondsToSelector:modelSel]) {
            model = ((id (*)(id, SEL))objc_msgSend)(ctrl, modelSel);
        }
        if (!model) {
            id mgr = [ctrl valueForKey:@"iconManager"];
            if ([mgr respondsToSelector:modelSel]) {
                model = ((id (*)(id, SEL))objc_msgSend)(mgr, modelSel);
            }
        }
        if (!model) return @[];

        NSArray *candidates = @[@"leafIcons", @"icons", @"allIcons", @"visibleIcons", @"leafIconsInIconList"];
        for (NSString *selName in candidates) {
            SEL sel = NSSelectorFromString(selName);
            if (![model respondsToSelector:sel]) continue;
            id arr = ((id (*)(id, SEL))objc_msgSend)(model, sel);
            if ([arr isKindOfClass:[NSArray class]] && [(NSArray *)arr count]) {
                TBLogOnce([@"iconslist|" stringByAppendingString:selName],
                          @"图标列表来源 %@ 共 %lu 个", selName, (unsigned long)[(NSArray *)arr count]);
                return arr;
            }
        }
        TBLogOnce(@"iconslist|none", @"图标列表：候选选择器全部为空");
    } @catch (NSException *e) {
        TBLog(@"取图标列表失败: %@", e.reason);
    }
    return @[];
}

/// 只清这些图标的缓存；icons 为空则退化为全清
static void TBPurgeIcons(id cache, NSArray *icons) {
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
/// （0.15.53：原来的 TBInvalidateIconViews 同步整表循环已并入 TBRunReload 的分批异步版，
///   这里不再保留独立函数 —— 通知逻辑只有这一处使用方。）

/// 正在执行的那次刷新序号（延迟任务用它判断自己是不是过期了）
// Every notification invalidates any in-flight preparation. Only the last
// generation may be published or acknowledged.
static int gApplyReplyToken = NOTIFY_TOKEN_INVALID;

static uint64_t TBApplyID(NSDictionary *values) {
    id value = values[@"ApplyRequestID"];
    return [value respondsToSelector:@selector(unsignedLongLongValue)] ?
           [value unsignedLongLongValue] : 0;
}

static void TBConfirmPublishedState(TBThemeRenderState *state) {
    if (![[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"] ||
        gApplyReplyToken == NOTIFY_TOKEN_INVALID || state != TBCommittedState()) return;
    uint64_t requestID = TBApplyID(state->preferences);
    if (!requestID) return;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    NSDictionary *latest = TBReadPreferenceValues();
    if (TBApplyID(latest) != requestID || ![latest isEqualToDictionary:state->preferences]) return;
    if (notify_set_state(gApplyReplyToken, requestID) == NOTIFY_STATUS_OK) {
        notify_post("com.ning.themeboard.apply.completed");
        TBLog(@"主题提交完成，回执请求=%llu", (unsigned long long)requestID);
    }
}

static void TBRunReload(NSUInteger mySeq, NSString *why);

static void TBReload(CFNotificationCenterRef c, void *o, CFNotificationName n,
                     const void *obj, CFDictionaryRef info) {
    // UIKit and all generation transitions are owned by the main thread.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ TBReload(NULL, NULL, NULL, NULL, NULL); });
        return;
    }
    NSUInteger sequence = ++gReloadRunSeq;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (sequence == gReloadRunSeq) TBRunReload(sequence, @"偏好变更");
    });
}

static void TBRefreshVisibleTablesLight(NSString *why) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSMutableArray<UIView *> *stack = [NSMutableArray array];
            for (UIView *w in [[UIApplication sharedApplication] windows]) [stack addObject:w];
            NSInteger n = 0, hit = 0;
            while (stack.count && n < 400) {
                UIView *v = stack.firstObject;
                [stack removeObjectAtIndex:0];
                n++;
                if ([v isKindOfClass:[UITableView class]]) { [(UITableView *)v reloadData]; hit++; }
                [stack addObjectsFromArray:[v.subviews copy]];
            }
            if (hit) TBLog(@"轻量刷新(%@)：reloadData %ld 个表格", why ?: @"?", (long)hit);
        } @catch (NSException *e) { }
    });
}

// Collect once on the main thread. Prewarming does not mutate views or system
// caches, so the previously committed generation remains visible throughout.
static NSArray<UIView *> *TBVisibleIconViews(void) {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    for (UIView *window in [[UIApplication sharedApplication] windows])
        [stack addObject:window];
    NSUInteger scanned = 0;
    while (stack.count && scanned++ < 12000) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view respondsToSelector:NSSelectorFromString(@"icon")]) {
            [views addObject:view];
            if (!gSeenIconViews) gSeenIconViews = [NSHashTable weakObjectsHashTable];
            [gSeenIconViews addObject:view];
        }
        [stack addObjectsFromArray:[view.subviews copy]];
    }
    return views;
}

static void TBRunReload(NSUInteger mySeq, NSString *why) {
    if (mySeq != gReloadRunSeq) return;
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    NSDictionary *values = TBReadPreferenceValues();
    TBThemeRenderState *candidate = [[TBThemeRenderState alloc]
        initWithPreferences:values generation:mySeq];
    NSString *theme = [values[@"ActiveTheme"] isKindOfClass:[NSString class]] ? values[@"ActiveTheme"] : nil;
    if (theme.length && (!values[@"Enabled"] || [values[@"Enabled"] boolValue]) &&
        ![values[@"SafeMode"] boolValue]) {
        TB_RENDER_WITH(candidate);
        if (!TBThemeDir(theme).length) {
            TBLog(@"主题未找到，保留原图且不回执：%@", theme);
            return;
        }
    }
    BOOL springboard = [[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"];
    if (!springboard) {
        TBDiagEmit(@"publish.before", nil, NULL, nil, nil, @"before publish");
        TBPublishRenderState(candidate);
        TBDiagEmit(@"publish.after", nil, NULL, nil, nil, @"after publish");
        TBRefreshVisibleTablesLight(why);
        return;
    }
    NSArray<UIView *> *views = TBVisibleIconViews();
    NSMutableOrderedSet<NSString *> *bids = [NSMutableOrderedSet orderedSet];
    @try {
        TB_RENDER_WITH(candidate);
        TBLoadIndex();
        (void)TBThemeMaskImage();
        (void)TBThemeOverlayImage();
        (void)TBThemeShadowImage();
        // Clock and calendar use their own live-icon pipelines after commit.
        for (UIView *view in views) {
            id icon = ((id (*)(id, SEL))objc_msgSend)(view, NSSelectorFromString(@"icon"));
            NSString *bid = TBBIDFromIcon(icon);
            if (bid.length && ![bid isEqualToString:@"com.apple.mobilecal"] &&
                ![bid isEqualToString:@"com.apple.mobiletimer"])
                [bids addObject:bid];
        }
    } @catch (NSException *e) {
        TBLog(@"主题准备失败（旧图保持）：%@", e.reason); return;
    }
    NSArray<NSString *> *pending = bids.array;
    __block NSUInteger cursor = 0;
    __block void (^prepare)(void) = nil;
    prepare = ^{
        if (mySeq != gReloadRunSeq) { prepare = nil; return; }
        @try {
            TB_RENDER_WITH(candidate);
            NSUInteger end = MIN(cursor + 18, pending.count);
            for (; cursor < end; cursor++) {
                UIImage *image = TBImageForBundle(pending[cursor]);
                if (image.CGImage) (void)CGImageGetWidth(image.CGImage);
            }
        } @catch (NSException *e) {
            TBLog(@"图像准备失败（旧图保持）：%@", e.reason);
            prepare = nil; return;
        }
        if (cursor < pending.count) {
            dispatch_async(dispatch_get_main_queue(), prepare);
            return;
        }
        prepare = nil;
        if (mySeq != gReloadRunSeq) return;
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
        if (![values isEqualToDictionary:TBReadPreferenceValues()]) {
            TBLog(@"准备期间偏好变化，弃用过期图像"); return;
        }
        // Publish and update visible carriers in one disabled-animation transaction.
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        TBDiagEmit(@"publish.before", nil, NULL, nil, nil, @"before publish");
        TBPublishRenderState(candidate);
        TBDiagEmit(@"publish.after", nil, NULL, nil, nil, @"after publish");
        TBCrossfadeRestoreAll();
        if (gBadgeApplied) TBBadgeRestoreAll(@"主题切换");
        NSArray *icons = TBAllIcons();
        NSArray *caches = gCaches.allObjects;
        if (icons.count) for (id cache in caches) TBPurgeIcons(cache, icons);
        BOOL overrideOK = NSClassFromString(@"SBIconView") &&
            [NSClassFromString(@"SBIconView") instancesRespondToSelector:NSSelectorFromString(@"setOverrideImage:")];
        NSInteger updated = overrideOK ? TBReapplyIconsLight() : 0;
        if (!overrideOK || updated == 0) {
            // The old compatibility path is asynchronous. Do not claim completion.
            TBHealAllIconViews();
            TBRefreshSpringBoard(why);
        }
        TBRefreshDynamicIconViewsNow();
        TBDiagCaptureLiveViews(@"after refresh");
        if (TBDiagEnabled()) dispatch_async(dispatch_get_main_queue(), ^{
            if (mySeq != gReloadRunSeq || candidate != TBCommittedState()) return;
            TBDiagCaptureLiveViews(@"next main tick");
        });
        TBBadgeRelayoutVisible();
        if (overrideOK && updated > 0) {
            [CATransaction setCompletionBlock:^{
                if (mySeq == gReloadRunSeq) TBConfirmPublishedState(candidate);
            }];
        }
        [CATransaction commit];
        TBLog(@"主题代次 %lu 提交，预热 %lu 图，重设 %ld 视图", (unsigned long)mySeq,
              (unsigned long)pending.count, (long)updated);
    };
    dispatch_async(dispatch_get_main_queue(), prepare);
}

/// App 请求重启桌面：让 SpringBoard 退出，系统会自动把它拉起来（等效 respring）
static void TBHandleRespring(CFNotificationCenterRef c, void *o, CFNotificationName n,
                             const void *obj, CFDictionaryRef info) {
    if (!gIsPrimary) return;
    TBLog(@"收到重启桌面请求 → 退出 SpringBoard");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ exit(0); });
}



__attribute__((constructor))
static void TBMain(void) {
    BOOL hasCache = NO;
    @try {
    hasCache = NSClassFromString(@"SBHIconImageCache") != nil;
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
    (void)TBCommittedState();
    if ([pname isEqualToString:@"SpringBoard"] &&
        notify_register_check("com.ning.themeboard.apply.completed", &gApplyReplyToken) != NOTIFY_STATUS_OK)
        gApplyReplyToken = NOTIFY_TOKEN_INVALID;
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

    // ★ 0.18.5：0.18.3/0.18.4 的「首启补刷」（启动后 3s/8s 各做一次 heal + 刷新桌面）
    //   疑似导致 SpringBoard 反复重启（闪屏，一黑一亮），已整块移除。
    //   等稳定后再考虑更轻的替代方案（先确认不再闪屏）。

    } @catch (NSException *e) {
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

}
