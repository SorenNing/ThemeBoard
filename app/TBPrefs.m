#import "TBPrefs.h"
#import <notify.h>
#import <stdint.h>
#import <stdlib.h>

NSString *const TBDefaultsDomain = @"com.ning.themeboard";
NSString *const TBNotifyChanged  = @"com.ning.themeboard.changed";
NSString *const TBNotifyApplyCompleted = @"com.ning.themeboard.apply.completed";
NSString *const TBKeyApplyRequestID = @"ApplyRequestID";

// 以下状态只在主队列访问。普通调参也轮换 ID，但不创建 completion / 超时任务。
static const NSTimeInterval kTBApplyConfirmationTimeout = 12.0;
static uint64_t gTBApplyRequestID;
static uint64_t gTBApplySentRequestID;
static NSTimeInterval gTBApplyDeadline;
static void (^gTBApplyCompletion)(BOOL);
static int gTBApplyReplyToken = NOTIFY_TOKEN_INVALID;
static NSUInteger gTBPendingChanges;
static BOOL gTBChangeScheduled;

static void TBFinishApplyRequest(uint64_t requestID, BOOL confirmed) {
    if (!requestID || requestID != gTBApplyRequestID || !gTBApplyCompletion) return;
    void (^completion)(BOOL) = gTBApplyCompletion;
    NSTimeInterval deadline = gTBApplyDeadline;
    gTBApplyCompletion = nil;
    // 异步交付避免回调重入；真正交付前再检查新变更和超时，禁止排队中的旧成功。
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(confirmed && requestID == gTBApplyRequestID &&
                   requestID == gTBApplySentRequestID &&
                   [NSProcessInfo processInfo].systemUptime < deadline);
    });
}

static BOOL TBEnsureApplyReplyObserver(void) {
    if (gTBApplyReplyToken != NOTIFY_TOKEN_INVALID) return YES;
    int token = NOTIFY_TOKEN_INVALID;
    uint32_t status = notify_register_dispatch(TBNotifyApplyCompleted.UTF8String, &token,
                                               dispatch_get_main_queue(), ^(int replyToken) {
        if (replyToken != gTBApplyReplyToken || !gTBApplyCompletion ||
            gTBApplySentRequestID != gTBApplyRequestID) return;
        uint64_t replyID = 0;
        if (notify_get_state(replyToken, &replyID) != NOTIFY_STATUS_OK ||
            replyID != gTBApplyRequestID) return;
        TBFinishApplyRequest(replyID, YES);
    });
    if (status != NOTIFY_STATUS_OK) {
        if (token != NOTIFY_TOKEN_INVALID) notify_cancel(token);
        return NO; // 下次请求允许重试注册；这次仍发送变更，只是不能确认成功。
    }
    gTBApplyReplyToken = token;
    return YES;
}

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
    [self notifyChangedWithCompletion:nil];
}

+ (void)notifyChangedWithCompletion:(void (^)(BOOL))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self notifyChangedWithCompletion:completion]; });
        return;
    }

    // 新的点击/调参立即结束旧请求，不能让它被下一次提交顺带确认为成功。
    TBFinishApplyRequest(gTBApplyRequestID, NO);
    uint64_t requestID = 0;
    do {
        arc4random_buf(&requestID, sizeof(requestID));
        requestID &= INT64_MAX;
    } while (!requestID || requestID == gTBApplyRequestID);
    gTBApplyRequestID = requestID;
    gTBApplySentRequestID = 0;
    gTBApplyCompletion = [completion copy];
    gTBApplyDeadline = [NSProcessInfo processInfo].systemUptime + kTBApplyConfirmationTimeout;

    // 必须先监听回执，再写 ID / 发变更，防止快速提交的回执丢失。
    BOOL canConfirm = !completion || TBEnsureApplyReplyObserver();
    CFPreferencesSetAppValue((__bridge CFStringRef)TBKeyApplyRequestID,
                             (__bridge CFNumberRef)@(requestID),
                             (__bridge CFStringRef)TBDefaultsDomain);
    BOOL saved = CFPreferencesAppSynchronize((__bridge CFStringRef)TBDefaultsDomain);
    if (completion) {
        if (!canConfirm || !saved) {
            TBFinishApplyRequest(requestID, NO);
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTBApplyConfirmationTimeout * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                TBFinishApplyRequest(requestID, NO);
            });
        }
    }

    // 保留原 300ms 合并窗口；窗口内只有最后一次 ID 与 completion 有权成功。
    gTBPendingChanges++;
    if (gTBChangeScheduled) return;
    gTBChangeScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSUInteger n = gTBPendingChanges;
        gTBPendingChanges = 0;
        gTBChangeScheduled = NO;
        if (!CFPreferencesAppSynchronize((__bridge CFStringRef)TBDefaultsDomain))
            TBFinishApplyRequest(gTBApplyRequestID, NO);
        gTBApplySentRequestID = gTBApplyRequestID;
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)TBNotifyChanged,
                                             NULL, NULL, true);
        if (n > 1) NSLog(@"[ThemeBoard] notifyChanged 防抖：合并 %lu 次 → 发 1 次", (unsigned long)n);
    });
}

@end
