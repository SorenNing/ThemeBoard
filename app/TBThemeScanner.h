#import <UIKit/UIKit.h>
#import "TBTheme.h"

@interface TBThemeScanner : NSObject

/// 需要扫描的主题根目录（按优先级，只返回实际存在的）
+ (NSArray<NSString *> *)themeRoots;

/// 第一个可写的根目录（导入用），没有则创建 /var/jb/Library/Themes
+ (nullable NSString *)writableThemeRoot;

/// 扫描全部主题（不加载图标索引，快）
+ (NSArray<TBTheme *> *)scanThemes;

/// 按名字找主题
+ (nullable TBTheme *)themeNamed:(NSString *)name;

/// 导入一个主题目录（复制到第一个可写的根目录，重名自动加序号），返回新主题路径
+ (nullable NSString *)importThemeDirectory:(NSURL *)srcURL error:(NSError **)error;

/// 每个候选目录的存在/可写/条目数，用于状态诊断
+ (NSArray<NSDictionary *> *)rootDiagnostics;

/// App 容器内的主题目录（RootHide 下唯一可靠的位置）
+ (NSString *)containerThemesDir;

/// 首次启动把包内演示主题复制进容器
+ (void)seedDemoThemesIfNeeded;

/// 导入任意来源：文件夹直接复制，zip 先解包再找主题目录
+ (nullable NSString *)importFromAnyURL:(NSURL *)url error:(NSError **)error;

/// 统一导入：文件夹或 .zip 都吃，返回落地后的主题目录
+ (nullable NSString *)importFromURL:(NSURL *)url error:(NSError **)error;

/// 删除主题目录（不可恢复）
+ (BOOL)deleteTheme:(TBTheme *)theme error:(NSError **)error;

@end
