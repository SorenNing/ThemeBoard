#import "TBPrefs.h"

NSString *const TBDefaultsDomain = @"com.ning.themeboard";
NSString *const TBNotifyChanged  = @"com.ning.themeboard.changed";

NSString *const TBKeyEnabled       = @"Enabled";
NSString *const TBKeyActiveTheme   = @"ActiveTheme";
NSString *const TBKeyLogEnabled    = @"LogEnabled";

NSString *const TBKeyUseThemeIconMask    = @"UseThemeIconMask";
NSString *const TBKeyMaskCornerRadiusOn  = @"MaskCornerRadiusOn";
NSString *const TBKeyMaskCornerRadius    = @"MaskCornerRadius";
NSString *const TBKeyUseThemeIconOverlay = @"UseThemeIconOverlay";
NSString *const TBKeyUseThemeIconShadow  = @"UseThemeIconShadow";
NSString *const TBKeyUseThemeBadge       = @"UseThemeBadge";

NSString *const TBKeyCustomMaskPath    = @"CustomMaskPath";
NSString *const TBKeyCustomOverlayPath = @"CustomOverlayPath";
NSString *const TBKeyCustomShadowPath  = @"CustomShadowPath";
NSString *const TBKeyCustomBadgePath   = @"CustomBadgePath";
NSString *const TBKeyGlassOverlayStrength = @"GlassOverlayStrength";

@implementation TBPrefs

+ (id)_valueForKey:(NSString *)key {
    return (__bridge_transfer id)CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)TBDefaultsDomain);
}

+ (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)value {
    id v = [self _valueForKey:key];
    if (!v) return value;
    return [v boolValue];
}

+ (void)setBool:(BOOL)value forKey:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (value ? kCFBooleanTrue : kCFBooleanFalse),
                             (__bridge CFStringRef)TBDefaultsDomain);
    [self synchronize];
}

+ (NSString *)stringForKey:(NSString *)key {
    id v = [self _valueForKey:key];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

+ (void)setString:(NSString *)value forKey:(NSString *)key {
    if (value) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFStringRef)value,
                                 (__bridge CFStringRef)TBDefaultsDomain);
    } else {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL,
                                 (__bridge CFStringRef)TBDefaultsDomain);
    }
    [self synchronize];
}

+ (double)doubleForKey:(NSString *)key defaultValue:(double)value {
    id v = [self _valueForKey:key];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : value;
}

+ (void)setDouble:(double)value forKey:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFNumberRef)@(value),
                             (__bridge CFStringRef)TBDefaultsDomain);
    [self synchronize];
}

+ (void)synchronize {
    CFPreferencesAppSynchronize((__bridge CFStringRef)TBDefaultsDomain);
}

+ (void)notifyChanged {
    // ★ 0.15.90：发送端防抖 —— 拖动滑块/连点开关会在 1 秒内发出十几条 Darwin 通知，
    //   每个装了引擎的进程都要各自跑一次全量刷新（日志实锤 17~20 次）→ SpringBoard 被杀。
    //   这里 300ms 防抖，只发最后一次。
    static NSUInteger sPending = 0;
    static BOOL sScheduled = NO;
    sPending++;
    if (sScheduled) return;
    sScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSUInteger n = sPending;
        sPending = 0;
        sScheduled = NO;
        [self synchronize];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)TBNotifyChanged,
                                             NULL, NULL, true);
        if (n > 1) NSLog(@"[ThemeBoard] notifyChanged 防抖：合并 %lu 次 → 发 1 次", (unsigned long)n);
    });
}

@end
