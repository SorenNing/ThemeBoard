#import "TBEngineInstaller.h"
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

static NSString *const kDylibName = @"ThemeBoardEngine.dylib";
static NSString *const kPlistName = @"ThemeBoardEngine.plist";

@implementation TBEngineInstaller

+ (NSArray<NSString *> *)candidateDirs {
    return @[@"/var/jb/Library/MobileSubstrate/DynamicLibraries",
             @"/Library/MobileSubstrate/DynamicLibraries",
             @"/var/jb/usr/lib/TweakInject",
             @"/usr/lib/TweakInject"];
}

+ (NSString *)dynamicLibrariesDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *d in [self candidateDirs]) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:d isDirectory:&isDir]) continue;
        if (isDir && [fm isWritableFileAtPath:d]) return d;
    }
    return nil;
}

+ (BOOL)isInstalled {
    for (NSString *d in [self candidateDirs]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:[d stringByAppendingPathComponent:kDylibName]]) {
            return YES;
        }
    }
    return NO;
}

+ (NSString *)bundledPathFor:(NSString *)name {
    NSString *p = [[NSBundle mainBundle] pathForResource:name.stringByDeletingPathExtension
                                                 ofType:name.pathExtension
                                            inDirectory:@"Engine"];
    if (p) return p;
    return [[NSBundle mainBundle] pathForResource:name.stringByDeletingPathExtension
                                           ofType:name.pathExtension];
}

+ (NSString *)bundledVersion {
    NSString *p = [self bundledPathFor:@"version.txt"];
    NSString *v = p ? [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL] : nil;
    return [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (BOOL)installEngine:(NSError **)error {
    NSString *dir = [self dynamicLibrariesDir];
    if (!dir) {
        if (error) *error = [NSError errorWithDomain:@"TBEngine" code:1
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                           @"看不到可写的注入目录（可能被 RootHide 隐藏），只能用引擎包安装"}];
        return NO;
    }

    NSString *dylib = [self bundledPathFor:kDylibName];
    if (!dylib) {
        if (error) *error = [NSError errorWithDomain:@"TBEngine" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"App 包里没有引擎文件"}];
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dstDylib = [dir stringByAppendingPathComponent:kDylibName];
    NSString *dstPlist = [dir stringByAppendingPathComponent:kPlistName];

    [fm removeItemAtPath:dstDylib error:NULL];
    if (![fm copyItemAtPath:dylib toPath:dstDylib error:error]) return NO;

    NSString *plist = [self bundledPathFor:kPlistName];
    if (plist) {
        [fm removeItemAtPath:dstPlist error:NULL];
        [fm copyItemAtPath:plist toPath:dstPlist error:NULL];
    }
    [fm setAttributes:@{NSFilePosixPermissions: @(0755)} ofItemAtPath:dstDylib error:NULL];
    if (plist) [fm setAttributes:@{NSFilePosixPermissions: @(0644)} ofItemAtPath:dstPlist error:NULL];
    return YES;
}

+ (NSString *)helperPath {
    for (NSString *p in @[@"/var/jb/usr/bin/themeboard-helper", @"/usr/bin/themeboard-helper"]) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
    }
    return nil;
}

+ (NSString *)runHelperTest {
    NSString *tool = [self helperPath];
    if (!tool) return @"找不到 themeboard-helper（助手包没装）";

    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"helper-test.txt"];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:NULL];

    const char *argv[5];
    argv[0] = tool.UTF8String;
    argv[1] = "--test";
    argv[2] = outPath.UTF8String;
    argv[3] = NULL;

    pid_t pid;
    int rc = posix_spawn(&pid, tool.UTF8String, NULL, NULL, (char *const *)argv, environ);
    if (rc != 0) return [NSString stringWithFormat:@"启动失败 rc=%d (%s)", rc, strerror(rc)];

    int status = 0;
    waitpid(pid, &status, 0);

    NSString *report = [NSString stringWithContentsOfFile:outPath encoding:NSUTF8StringEncoding error:NULL];
    if (!report.length) {
        return [NSString stringWithFormat:@"助手已运行（exit=%d），但没有写出报告", WEXITSTATUS(status)];
    }
    return report;
}

+ (BOOL)openSileoForEngine {
    NSArray *urls = @[@"sileo://package/com.ning.themeboard.engine",
                      @"zbra://packages/com.ning.themeboard.engine"];
    for (NSString *s in urls) {
        NSURL *u = [NSURL URLWithString:s];
        if (u && [[UIApplication sharedApplication] canOpenURL:u]) {
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
            return YES;
        }
    }
    return NO;
}

+ (BOOL)respring {
    NSArray *candidates = @[@[@"/var/jb/usr/bin/sbreload", @[]],
                            @[@"/var/jb/usr/bin/respring", @[]],
                            @[@"/var/jb/usr/bin/jbctl", @[@"respring"]],
                            @[@"/var/jb/usr/bin/killall", @[@"-HUP", @"SpringBoard"]],
                            @[@"/var/jb/usr/bin/pkill", @[@"-9", @"SpringBoard"]],
                            @[@"/usr/bin/sbreload", @[]],
                            @[@"/usr/bin/killall", @[@"-HUP", @"SpringBoard"]],
                            @[@"/usr/bin/pkill", @[@"-9", @"SpringBoard"]]];
    for (NSArray *pair in candidates) {
        NSString *tool = pair[0];
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:tool]) continue;

        const char *argv[8];
        argv[0] = tool.UTF8String;
        NSInteger n = 1;
        for (NSString *a in pair[1]) argv[n++] = a.UTF8String;
        argv[n] = NULL;

        pid_t pid;
        int rc = posix_spawn(&pid, tool.UTF8String, NULL, NULL, (char *const *)argv, environ);
        if (rc == 0) return YES;
    }
    return NO;
}

@end
