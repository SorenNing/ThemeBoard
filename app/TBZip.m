#import "TBZip.h"
#import <zlib.h>
#import <errno.h>

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

@implementation TBZip

+ (BOOL)unzipFileAtPath:(NSString *)zipPath toDirectory:(NSString *)dstDir error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:zipPath options:NSDataReadingMappedIfSafe error:NULL];
    if (!data.length) {
        NSString *msg = [NSString stringWithFormat:@"读不到 zip（%@，errno=%d）", zipPath, errno];
        if (error) *error = [NSError errorWithDomain:@"TBZip" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: msg}];
        return NO;
    }
    const uint8_t *b = data.bytes;
    NSUInteger n = data.length;

    // 找 EOCD（0x06054b50），从尾部往前扫
    NSInteger eocd = -1;
    NSUInteger minPos = n > 65557 + 22 ? n - 65557 - 22 : 0;
    for (NSInteger i = (NSInteger)n - 22; i >= (NSInteger)minPos; i--) {
        if (rd32(b + i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd < 0) {
        if (error) *error = [NSError errorWithDomain:@"TBZip" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"不是有效的 zip"}];
        return NO;
    }

    uint16_t count = rd16(b + eocd + 10);
    uint32_t cdOffset = rd32(b + eocd + 16);
    if (cdOffset >= n) return NO;

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dstDir withIntermediateDirectories:YES attributes:nil error:NULL];

    NSUInteger p = cdOffset;
    NSUInteger done = 0;
    for (uint16_t i = 0; i < count && p + 46 <= n; i++) {
        if (rd32(b + p) != 0x02014b50) break;
        uint16_t method   = rd16(b + p + 10);
        uint32_t csize    = rd32(b + p + 20);
        uint32_t usize    = rd32(b + p + 24);
        uint16_t nameLen  = rd16(b + p + 28);
        uint16_t extraLen = rd16(b + p + 30);
        uint16_t cmtLen   = rd16(b + p + 32);
        uint32_t localOff = rd32(b + p + 42);
        if (p + 46 + nameLen > n) break;

        NSString *name = [[NSString alloc] initWithBytes:b + p + 46 length:nameLen encoding:NSUTF8StringEncoding];
        p += 46 + nameLen + extraLen + cmtLen;
        if (!name.length) continue;
        if ([name hasPrefix:@"__MACOSX/"]) continue;
        if ([name containsString:@".."]) continue;

        NSString *outPath = [dstDir stringByAppendingPathComponent:name];
        if ([name hasSuffix:@"/"]) {
            [fm createDirectoryAtPath:outPath withIntermediateDirectories:YES attributes:nil error:NULL];
            continue;
        }

        // 本地头
        if (localOff + 30 > n || rd32(b + localOff) != 0x04034b50) continue;
        uint16_t lNameLen  = rd16(b + localOff + 26);
        uint16_t lExtraLen = rd16(b + localOff + 28);
        NSUInteger dataOff = localOff + 30 + lNameLen + lExtraLen;
        if (dataOff + csize > n) continue;

        NSData *out = nil;
        if (method == 0) {
            out = [data subdataWithRange:NSMakeRange(dataOff, csize)];
        } else if (method == 8) {
            NSMutableData *buf = [NSMutableData dataWithLength:usize ?: (csize * 6)];
            z_stream s;
            memset(&s, 0, sizeof(s));
            if (inflateInit2(&s, -15) != Z_OK) continue;
            s.next_in = (Bytef *)(b + dataOff);
            s.avail_in = csize;
            s.next_out = (Bytef *)buf.mutableBytes;
            s.avail_out = (uInt)buf.length;
            int rc = inflate(&s, Z_FINISH);
            NSUInteger produced = buf.length - s.avail_out;
            inflateEnd(&s);
            if (rc != Z_STREAM_END && rc != Z_OK) continue;
            [buf setLength:produced];
            out = buf;
        } else {
            continue;
        }

        [fm createDirectoryAtPath:[outPath stringByDeletingLastPathComponent]
       withIntermediateDirectories:YES attributes:nil error:NULL];
        if ([out writeToFile:outPath atomically:NO]) done++;
    }

    if (done == 0) {
        if (error) *error = [NSError errorWithDomain:@"TBZip" code:3
                                            userInfo:@{NSLocalizedDescriptionKey: @"zip 里没有可用文件"}];
        return NO;
    }
    return YES;
}

@end
