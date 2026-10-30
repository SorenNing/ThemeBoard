#import <UIKit/UIKit.h>

@interface TBAppInfo : NSObject

/// 已安装应用（含系统应用），元素 @{@"bid":…, @"name":…, @"path":…}
+ (NSArray<NSDictionary *> *)installedApps;
+ (nullable NSString *)displayNameForBundleID:(NSString *)bid;
+ (nullable NSString *)bundlePathForBundleID:(NSString *)bid;
+ (nullable UIImage *)iconForBundleID:(NSString *)bid;

@end
