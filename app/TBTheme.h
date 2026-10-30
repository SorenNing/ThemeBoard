#import <UIKit/UIKit.h>

@interface TBTheme : NSObject

@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *iconBundlesPath;
@property (nonatomic, assign) NSUInteger iconCount;      // 覆盖的 bundleID 数
@property (nonatomic, assign) NSUInteger fileCount;      // IconBundles 内文件数
@property (nonatomic, assign) BOOL hasBundles;           // 是否含 Bundles/（整包替换）

- (instancetype)initWithPath:(NSString *)path;

- (void)loadIndex;                                        // 幂等；扫描 IconBundles
- (NSArray<NSString *> *)bundleIdentifiers;               // 已排序
- (nullable NSString *)imagePathForBundleID:(NSString *)bid;
- (nullable UIImage *)imageForBundleID:(NSString *)bid;   // 带缓存
- (BOOL)hasIconForBundleID:(NSString *)bid;

/// 2x2 拼图封面（用于列表缩略图）
- (nullable UIImage *)coverImageWithSize:(CGFloat)size;

@end
