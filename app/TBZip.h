#import <Foundation/Foundation.h>

/// 极简 zip 解包（store + deflate），够用于主题包导入
@interface TBZip : NSObject
+ (BOOL)unzipFileAtPath:(NSString *)zipPath toDirectory:(NSString *)dstDir error:(NSError **)error;
@end
