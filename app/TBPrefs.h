#import <Foundation/Foundation.h>

// 与引擎共享的偏好域。全部走 CFPreferences + Darwin 通知，App 和注入进程互不依赖。
extern NSString *const TBDefaultsDomain;
extern NSString *const TBNotifyChanged;

extern NSString *const TBKeyEnabled;        // BOOL 总开关
extern NSString *const TBKeyActiveTheme;    // NSString 主题名
extern NSString *const TBKeyApplyDock;      // BOOL
extern NSString *const TBKeyApplyFolder;    // BOOL
extern NSString *const TBKeyApplySwitcher;  // BOOL
extern NSString *const TBKeyApplySettings;  // BOOL
extern NSString *const TBKeyApplyShare;     // BOOL
extern NSString *const TBKeyApplyNotification; // BOOL 通知中心
extern NSString *const TBKeyLogEnabled;     // BOOL

@interface TBPrefs : NSObject

+ (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)value;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;
+ (NSString *)stringForKey:(NSString *)key;
+ (void)setString:(NSString *)value forKey:(NSString *)key;

+ (void)synchronize;
+ (void)notifyChanged;

@end
