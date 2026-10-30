#import "TBTheme.h"

@interface TBTheme ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *index;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *cache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *rank;
@property (nonatomic, assign) BOOL loaded;
@end

@implementation TBTheme

- (instancetype)initWithPath:(NSString *)path {
    if ((self = [super init])) {
        _path = [path copy];
        _name = [[path lastPathComponent] copy];
        if ([_name hasSuffix:@".theme"]) _name = [_name substringToIndex:_name.length - 6];
        _iconBundlesPath = [[path stringByAppendingPathComponent:@"IconBundles"] copy];
        _hasBundles = [[NSFileManager defaultManager] fileExistsAtPath:
                       [path stringByAppendingPathComponent:@"Bundles"]];
        _index = [NSMutableDictionary dictionary];
        _cache = [NSMutableDictionary dictionary];
        _rank  = [NSMutableDictionary dictionary];
    }
    return self;
}

// 文件名 → bundleID（剥离 @2x/@3x/-large/~ipad 等后缀）
static NSString *TBBundleIDFromFilename(NSString *file) {
    NSString *s = [file stringByDeletingPathExtension];
    if ([s hasSuffix:@"@2x"] || [s hasSuffix:@"@3x"]) s = [s substringToIndex:s.length - 3];
    for (NSString *suffix in @[@"-large", @"-small", @"-76", @"-60", @"-40"]) {
        if ([s hasSuffix:suffix]) s = [s substringToIndex:s.length - suffix.length];
    }
    NSRange tilde = [s rangeOfString:@"~"];
    if (tilde.location != NSNotFound) s = [s substringToIndex:tilde.location];
    return s;
}

static NSInteger TBScaleRank(NSString *file) {
    if ([file hasSuffix:@"@3x.png"]) return 30;
    if ([file hasSuffix:@"-large.png"]) return 28;
    if ([file hasSuffix:@"@2x.png"]) return 20;
    return 10;
}

- (void)loadIndex {
    if (self.loaded) return;
    self.loaded = YES;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:self.iconBundlesPath error:NULL];
    if (!files) return;

    self.fileCount = files.count;
    for (NSString *file in files) {
        if ([file hasPrefix:@"."]) continue;
        if (![[file pathExtension].lowercaseString isEqualToString:@"png"]) continue;
        NSString *bid = TBBundleIDFromFilename(file);
        if (bid.length == 0) continue;

        NSInteger rank = TBScaleRank(file);
        NSNumber *old = self.rank[bid];
        if (old && old.integerValue >= rank) continue;

        self.index[bid] = [self.iconBundlesPath stringByAppendingPathComponent:file];
        self.rank[bid] = @(rank);
    }
    self.iconCount = self.index.count;
}

- (NSArray<NSString *> *)bundleIdentifiers {
    [self loadIndex];
    return [self.index.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

- (NSString *)imagePathForBundleID:(NSString *)bid {
    [self loadIndex];
    return bid ? self.index[bid] : nil;
}

- (UIImage *)imageForBundleID:(NSString *)bid {
    if (!bid) return nil;
    UIImage *img = self.cache[bid];
    if (img) return img;

    NSString *p = [self imagePathForBundleID:bid];
    if (!p) return nil;
    img = [UIImage imageWithContentsOfFile:p];
    if (img) self.cache[bid] = img;
    return img;
}

- (BOOL)hasIconForBundleID:(NSString *)bid {
    return bid && [self imagePathForBundleID:bid] != nil;
}

- (UIImage *)coverImageWithSize:(CGFloat)size {
    [self loadIndex];
    NSArray<NSString *> *bids = [self bundleIdentifiers];
    if (bids.count == 0) return nil;

    NSArray *prefer = @[@"com.apple.mobilesafari", @"com.tencent.xin", @"com.apple.MobileSMS",
                        @"com.apple.Preferences", @"com.ss.iphone.ugc.Aweme", @"com.taobao.taobao4iphone"];
    NSMutableArray *pick = [NSMutableArray array];
    for (NSString *p in prefer) {
        if ([bids containsObject:p] && pick.count < 4) [pick addObject:p];
    }
    for (NSString *b in bids) {
        if (pick.count >= 4) break;
        if (![pick containsObject:b]) [pick addObject:b];
    }

    CGFloat cell = size / 2.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size) format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        for (NSUInteger i = 0; i < pick.count && i < 4; i++) {
            UIImage *img = [self imageForBundleID:pick[i]];
            if (!img) continue;
            CGFloat x = (i % 2) * cell, y = (i / 2) * cell;
            [img drawInRect:CGRectMake(x, y, cell, cell)];
        }
    }];
}

@end
