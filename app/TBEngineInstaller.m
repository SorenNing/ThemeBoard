#import "TBEngineInstaller.h"
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <notify.h>
#import <QuartzCore/QuartzCore.h>

extern char **environ;

static NSString *const kDylibName = @"ThemeBoardEngine.dylib";
static NSString *const kPlistName = @"ThemeBoardEngine.plist";

#pragma mark - 实时运行状态（Darwin 通知请求/应答，不写文件）
NSString *const TBEngineRuntimeStateDidChangeNotification = @"TBEngineRuntimeStateDidChange";
static const char *kRuntimeRequest = "com.ning.themeboard.runtime.request";
static const char *kRuntimeReply = "com.ning.themeboard.runtime.reply";
static int gRuntimeRequestToken = NOTIFY_TOKEN_INVALID;
static int gRuntimeReplyToken = NOTIFY_TOKEN_INVALID;
static uint64_t gRuntimeNonce;
static CFTimeInterval gRuntimeLastReply;
static BOOL gRuntimeAttempted;
static BOOL gRuntimeUnavailable;

static void TBRuntimeChanged(void) {
    [[NSNotificationCenter defaultCenter] postNotificationName:TBEngineRuntimeStateDidChangeNotification object:nil];
}

static void TBRuntimeSetup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t rc = notify_register_check(kRuntimeRequest, &gRuntimeRequestToken);
        if (rc == NOTIFY_STATUS_OK) {
            rc = notify_register_dispatch(kRuntimeReply, &gRuntimeReplyToken, dispatch_get_main_queue(), ^(int token) {
                uint64_t reply = 0;
                if (!gRuntimeNonce || notify_get_state(token, &reply) != NOTIFY_STATUS_OK || reply != gRuntimeNonce) return;
                gRuntimeLastReply = CACurrentMediaTime();
                CFTimeInterval replyTime = gRuntimeLastReply;
                gRuntimeNonce = 0;
                TBRuntimeChanged();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (gRuntimeLastReply == replyTime) TBRuntimeChanged();
                });
            });
        }
        if (rc != NOTIFY_STATUS_OK) {
            gRuntimeUnavailable = YES;
            if (gRuntimeRequestToken != NOTIFY_TOKEN_INVALID) notify_cancel(gRuntimeRequestToken);
            if (gRuntimeReplyToken != NOTIFY_TOKEN_INVALID) notify_cancel(gRuntimeReplyToken);
            gRuntimeRequestToken = gRuntimeReplyToken = NOTIFY_TOKEN_INVALID;
        }
    });
}

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

// 查询是异步的，不阻塞页面/主线程；超时只表示没有应答。
+ (void)refreshRuntimeState {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshRuntimeState]; });
        return;
    }
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
    TBRuntimeSetup();
    if (gRuntimeUnavailable || gRuntimeNonce) return;
    uint64_t nonce = 0;
    do { arc4random_buf(&nonce, sizeof(nonce)); } while (nonce == 0);
    gRuntimeNonce = nonce;
    gRuntimeAttempted = YES;
    uint32_t rc = notify_set_state(gRuntimeRequestToken, nonce);
    if (rc == NOTIFY_STATUS_OK) rc = notify_post(kRuntimeRequest);
    if (rc != NOTIFY_STATUS_OK) {
        gRuntimeNonce = 0;
        gRuntimeUnavailable = YES;
        TBRuntimeChanged();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (gRuntimeNonce != nonce) return;
        gRuntimeNonce = 0;
        gRuntimeLastReply = 0;
        TBRuntimeChanged();
    });
}

+ (NSString *)runtimeState {
    if (gRuntimeLastReply > 0 && CACurrentMediaTime() - gRuntimeLastReply < 5.0) return @"运行中";
    if (gRuntimeUnavailable) return @"状态通道不可用";
    if (gRuntimeNonce) return @"检测中";
    return gRuntimeAttempted ? @"未收到应答" : @"运行状态未知";
}

+ (NSString *)runtimeDetail {
    if ([[self runtimeState] isEqualToString:@"运行中"]) return @"SpringBoard 引擎已实时应答，与写日志开关无关";
    if (gRuntimeUnavailable) return @"无法注册实时通知通道，运行状态未知";
    if (gRuntimeNonce) return @"正在等待 SpringBoard 引擎应答";
    if (gRuntimeAttempted) return @"引擎尚未应答；旧版引擎或通知受限也会如此";
    return @"等待实时检测，不使用日志文件判断存活";
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
