#import <Foundation/Foundation.h>

// 与引擎共享的偏好域。全部走 CFPreferences + Darwin 通知，App 和注入进程互不依赖。
extern NSString *const TBDefaultsDomain;
extern NSString *const TBNotifyChanged;
extern NSString *const TBNotifyApplyCompleted;
extern NSString *const TBKeyApplyRequestID; // NSNumber，非 0 的随机 63-bit 请求 ID

extern NSString *const TBKeyEnabled;        // BOOL 总开关
extern NSString *const TBKeyActiveTheme;    // NSString 主题名
extern NSString *const TBKeyLogEnabled;     // BOOL

// ---- 图标形状 / 特效（引擎与 App 共用，键名不能改）----
extern NSString *const TBKeyUseThemeIconMask;      // BOOL 用遮罩图当图标形状
extern NSString *const TBKeyMaskCornerRadiusOn;    // BOOL 用自定义圆角
extern NSString *const TBKeyMaskCornerRadius;      // double 半径 = (值/60)×图标宽
extern NSString *const TBKeyUseThemeIconOverlay;   // BOOL 边框（AnemoneEffects 叠加层）
extern NSString *const TBKeyUseThemeIconShadow;    // BOOL 阴影
extern NSString *const TBKeyUseThemeBadge;         // BOOL 替换角标底板（SBBadgeBG）

// 独立素材：绝对路径，优先于主题自带的同名素材（换主题也继续生效）
extern NSString *const TBKeyCustomMaskPath;        // NSString
extern NSString *const TBKeyCustomOverlayPath;     // NSString
extern NSString *const TBKeyCustomShadowPath;      // NSString
extern NSString *const TBKeyCustomBadgePath;       // NSString 角标底板
extern NSString *const TBKeyGlassOverlayStrength;  // double 玻璃叠加层强度 0.0~1.0（默认 0.35）

@interface TBPrefs : NSObject

+ (BOOL)boolForKey:(NSString *)key defaultValue:(BOOL)value;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;
+ (NSString *)stringForKey:(NSString *)key;
+ (void)setString:(NSString *)value forKey:(NSString *)key;

+ (double)doubleForKey:(NSString *)key defaultValue:(double)value;
+ (void)setDouble:(double)value forKey:(NSString *)key;

+ (void)synchronize;
// 300ms 合并发送；新的变更会使前一个待确认请求以 NO 结束。
+ (void)notifyChanged;
// 偏好写完后调用。主队列恰好回调一次；只有匹配最新请求的 SpringBoard 回执为 YES。
// 超时（12 秒）、同步/注册失败、被新变更替代均为 NO；不代表偏好已回滚。
+ (void)notifyChangedWithCompletion:(void (^)(BOOL confirmed))completion;

@end
