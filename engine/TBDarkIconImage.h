// Ning. Only called on original theme artwork, before existing shape/effects.
#import "TBDarkIconPixels.h"

// Copy rule: caller owns the returned CGImage, including unchanged fallback.
static CGImageRef TBDarkIconCGImage(CGImageRef image) CF_RETURNS_RETAINED;
static CGImageRef TBDarkIconCGImage(CGImageRef image) {
    if (!image) return NULL;
    size_t w=CGImageGetWidth(image), h=CGImageGetHeight(image);
    if (w<12 || h<12 || w>2048 || h>2048 || w*h>1024*1024) return CGImageRetain(image);
    CGColorSpaceRef original=CGImageGetColorSpace(image);
    CGColorSpaceRef space=original && CGColorSpaceGetModel(original)==kCGColorSpaceModelRGB ?
        CGColorSpaceRetain(original) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=space ? CGBitmapContextCreate(NULL,w,h,8,w*4,space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
    if (space) CGColorSpaceRelease(space);
    if (!context) return CGImageRetain(image);
    CGContextSetBlendMode(context,kCGBlendModeCopy);
    CGContextDrawImage(context,CGRectMake(0,0,w,h),image);
    uint8_t *pixels=CGBitmapContextGetData(context);
    size_t changed=TBDarkIconProcessRGBA(pixels,w,h,CGBitmapContextGetBytesPerRow(context));
    CGImageRef output=changed ? CGBitmapContextCreateImage(context) : NULL;
    CGContextRelease(context);
    return output ?: CGImageRetain(image);
}
static UIImage *TBDarkIconImage(UIImage *image) {
    TB_RENDER_SCOPE();
    if (!image.CGImage || !TBCurrentRenderState()->darkIconBackground) return image;
    CGImageRef output=TBDarkIconCGImage(image.CGImage);
    if (!output) return image;
    UIImage *result=output==image.CGImage ? image :
        [UIImage imageWithCGImage:output scale:image.scale orientation:image.imageOrientation];
    CGImageRelease(output);
    if (result && result != image) {
        result=[result imageWithRenderingMode:image.renderingMode];
        result=[result imageWithAlignmentRectInsets:image.alignmentRectInsets];
    }
    return result ?: image;
}
