#import "TBPrefs.h"

NSString *const TBDefaultsDomain = @"com.ning.themeboard";
NSString *const TBNotifyChanged  = @"com.ning.themeboard.changed";

NSString *const TBKeyEnabled       = @"Enabled";
NSString *const TBKeyActiveTheme   = @"ActiveTheme";
NSString *const TBKeyApplyDock     = @"ApplyDock";
NSString *const TBKeyApplyFolder   = @"ApplyFolder";
NSString *const TBKeyApplySwitcher = @"ApplySwitcher";
NSString *const TBKeyApplySettings = @"ApplySettings";
NSString *const TBKeyApplyShare    = @"ApplyShare";
NSString *const TBKeyLogEnabled    = @"LogEnabled";

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

+ (void)synchronize {
    CFPreferencesAppSynchronize((__bridge CFStringRef)TBDefaultsDomain);
}

+ (void)notifyChanged {
    [self synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)TBNotifyChanged,
                                         NULL, NULL, true);
}

@end
