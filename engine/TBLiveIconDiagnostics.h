// Private live-icon diagnostics. Existing LogEnabled controls all work here.
// Never writes images, changes rendering, or installs additional hooks.
static BOOL TBDiagEnabled(void) {
    static BOOL springboard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ springboard = [[NSProcessInfo processInfo].processName isEqualToString:@"SpringBoard"]; });
    return springboard && [TBCurrentRenderState()->preferences[@"LogEnabled"] boolValue];
}
static BOOL TBDiagDynamicBID(NSString *bid) {
    return [bid isEqualToString:@"com.apple.mobilecal"] ||
           [bid isEqualToString:@"com.apple.mobiletimer"];
}
static BOOL TBDiagTake(NSString *key, NSUInteger limit) {
    if (!TBDiagEnabled()) return NO;
    static NSLock *lock;
    static NSMutableDictionary *counts;
    static NSUInteger total;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; counts = [NSMutableDictionary dictionary]; });
    [lock lock];
    NSUInteger count = [counts[key] unsignedIntegerValue];
    BOOL take = total < 600 && count < limit;
    if (take) { counts[key] = @(count + 1); total++; }
    [lock unlock];
    return take;
}
// Same-size 16x16 premultiplied RGBA fingerprints compare pixels rather than
// UIImage identity. Include source geometry and transparent-edge statistics.
static NSString *TBDiagImage(id object) {
    if (!object) return @"nil";
    if (![object isKindOfClass:[UIImage class]]) return NSStringFromClass([object class]);
    UIImage *image = object;
    CGImageRef cg = image.CGImage;
    if (!cg) return @"UIImage(no CGImage)";
    unsigned char px[16 * 16 * 4] = {0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, 16, 16, 8, 16 * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return @"UIImage(bitmap unavailable)";
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 16, 16), cg);
    CGContextRelease(ctx);
    uint64_t hash = UINT64_C(14695981039346656037);
    NSUInteger transparent = 0;
    for (NSUInteger i = 0; i < sizeof(px); i++) { hash ^= px[i]; hash *= UINT64_C(1099511628211); }
    for (NSUInteger i = 3; i < sizeof(px); i += 4) if (px[i] < 245) transparent++;
    return [NSString stringWithFormat:@"%zux%zu/%.1f fp=%016llx alpha<245=%lu/256 cornerA=%u,%u,%u,%u",
        CGImageGetWidth(cg), CGImageGetHeight(cg), image.scale,
        (unsigned long long)hash, (unsigned long)transparent,
        px[3], px[63], px[963], px[1023]];
}
static void TBDiagEmit(NSString *stage, id receiver, SEL selector,
                       id source, id result, NSString *detail) {
    if (!TBDiagEnabled()) return;
    TBThemeRenderState *scoped = TBCurrentRenderState();
    TBThemeRenderState *committed = TBCommittedState();
    NSString *cls = receiver ? NSStringFromClass([receiver class]) : @"-";
    NSString *sel = selector ? NSStringFromSelector(selector) : @"-";
    NSString *key = [NSString stringWithFormat:@"%lu|%@|%@|%@|%@", (unsigned long)scoped->generation,
                     stage, cls, sel, detail ?: @""];
    if (!TBDiagTake(key, 2)) return;
    TBLog(@"LIVE stage=%@ self=%@ sel=%@ thread=%@ scoped=%lu committed=%lu active=%@ detail=%@ src={%@} out={%@}",
        stage, cls, sel, [NSThread isMainThread] ? @"main" : @"background",
        (unsigned long)scoped->generation, (unsigned long)committed->generation,
        scoped->preferences[@"ActiveTheme"] ?: @"(default)", detail ?: @"-",
        TBDiagImage(source), TBDiagImage(result));
}
static void TBDiagResource(id receiver, SEL selector, NSString *name, id image, NSString *detail) {
    if (!TBDiagEnabled() ||
        !([name hasPrefix:@"ClockIconBackground"] || [name hasPrefix:@"CalendarIcon"])) return;
    TBDiagEmit(@"resource.redirect", receiver, selector, image, nil,
              [NSString stringWithFormat:@"%@ => %@", name, detail ?: @"-"]);
}
static Class TBDiagOwner(Class cls, SEL selector) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        BOOL found = NO;
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(methods[i]) == selector) { found = YES; break; }
        }
        free(methods);
        if (found) return c;
    }
    return Nil;
}
static void TBDiagProbeOnce(void) {
    if (!TBDiagTake(@"abi.inventory", 1)) return;
    for (NSString *name in @[@"SBCalendarIconImageProvider", @"SBHCalendarApplicationIcon",
                             @"SBIcon", @"SBHClockApplicationIconImageView"]) {
        Class cls = NSClassFromString(name);
        for (NSString *method in @[@"generateIconImageWithInfo:", @"iconImageWithInfo:",
            @"unmaskedIconImageWithInfo:", @"reloadIconImage", @"contentsImage", @"squareContentsImage",
            @"iconImageWithInfo:traitCollection:context:options:", @"iconImageWithInfo:traitCollection:options:"]) {
            SEL sel = NSSelectorFromString(method);
            Method instance = cls ? class_getInstanceMethod(cls, sel) : NULL;
            Method classMethod = cls ? class_getClassMethod(cls, sel) : NULL;
            Class owner = instance ? TBDiagOwner(cls, sel) : Nil;
            Dl_info imageInfo = {0};
            IMP imp = instance ? method_getImplementation(instance) : NULL;
            if (imp) dladdr((const void *)imp, &imageInfo);
            TBLog(@"LIVE ABI class=%@ selector=%@ instance=%d classMethod=%d owner=%@ encoding=%s IMP=%p image=%s",
                  name, method, instance != NULL, classMethod != NULL,
                  owner ? NSStringFromClass(owner) : @"-",
                  instance ? method_getTypeEncoding(instance) : "-", imp,
                  imageInfo.dli_fname ?: "-");
        }
    }
}
static NSString *TBBIDFromIcon(id icon);
static void TBDiagCaptureLiveViews(NSString *phase) {
    if (!TBDiagEnabled()) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    for (UIWindow *window in [[UIApplication sharedApplication] windows]) [stack addObject:window];
    NSUInteger scanned = 0;
    while (stack.count && scanned++ < 12000) {
        UIView *view = stack.lastObject; [stack removeLastObject];
        [stack addObjectsFromArray:[view.subviews copy]];
        @try {
            id icon = [view respondsToSelector:NSSelectorFromString(@"icon")] ?
                ((id (*)(id, SEL))objc_msgSend)(view, NSSelectorFromString(@"icon")) : nil;
            NSString *bid = TBBIDFromIcon(icon);
            BOOL clock = [NSStringFromClass([view class]) rangeOfString:@"Clock"].location != NSNotFound;
            if (!clock && !TBDiagDynamicBID(bid)) {
                // Calendar UIImageViews can lack an icon property; resolve only
                // their immediate icon-owning ancestor, without invoking getters.
                if (![view isKindOfClass:[UIImageView class]]) continue;
                UIView *parent = view.superview;
                for (NSUInteger depth = 0; parent && depth < 4; depth++, parent = parent.superview) {
                    if (![parent respondsToSelector:NSSelectorFromString(@"icon")]) continue;
                    id ownerIcon = ((id (*)(id, SEL))objc_msgSend)(parent, NSSelectorFromString(@"icon"));
                    NSString *ownerBID = TBBIDFromIcon(ownerIcon);
                    if (TBDiagDynamicBID(ownerBID)) { icon = ownerIcon; bid = ownerBID; }
                    break;
                }
                if (!TBDiagDynamicBID(bid)) continue;
            }
            id image = [view isKindOfClass:[UIImageView class]] ? [(UIImageView *)view image] : nil;
            id layer = view.layer.contents;
            UIImage *layerImage = nil;
            if (layer && CFGetTypeID((__bridge CFTypeRef)layer) == CGImageGetTypeID())
                layerImage = [UIImage imageWithCGImage:(__bridge CGImageRef)layer];
            TBDiagEmit(@"view.final", view, NULL, image, layerImage,
                [NSString stringWithFormat:@"%@ bid=%@ iconClass=%@", phase, bid ?: @"-",
                  icon ? NSStringFromClass([icon class]) : @"-"]);
        } @catch (NSException *e) { }
    }
}
