#import <Foundation/Foundation.h>

/// 让 App 自己把引擎装进注入目录，再由用户主动触发一次重启桌面
@interface TBEngineInstaller : NSObject

/// 可用的注入目录（不存在或不可写则返回 nil）
+ (nullable NSString *)dynamicLibrariesDir;

/// 引擎是否已经装好
+ (BOOL)isInstalled;

/// 把 App 包内的引擎复制过去（覆盖安装）
+ (BOOL)installEngine:(NSError **)error;

/// 让 SpringBoard 重新加载（重启桌面，不是恢复出厂）
+ (BOOL)respring;

/// 引擎包版本（bundle 里带的）
+ (NSString *)bundledVersion;

@end
