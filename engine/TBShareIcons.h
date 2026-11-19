// ShareSheet/SharingUI app icons. Included after TBThemedIconLike.
// Private selectors are ABI-checked; never inspect KVC identities or view trees.
#import <mach-o/dyld.h>
#include <string.h>

static IMP o_tbShareActivity, o_tbShareExtension, o_tbShareHelper, o_tbShareDelivery;
static __thread unsigned gTBShareDepth;
static int gTBSharePending, gTBShareComplete;
static BOOL gTBShareInstalling;

// The existing theme effects pipeline owns main-thread mutable caches. Keep
// worker-queue deliveries native instead of moving callbacks or blocking main.
static BOOL TBShareEnabled(void) {
    return [NSThread isMainThread] && !gTBSettingsNativeIcon &&
           TBEnabled() && !TBSafeMode() && TBUIKitIconEnabled();
}

static NSString *TBShareString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

// Use verified object getters, including class getters, without KVC or ivar guesses.
static id TBShareObject(id object, NSString *name) {
    if (!object) return nil;
    SEL sel = NSSelectorFromString(name);
    Class cls = object_getClass(object);
    if (!TBPSMethodMatches(class_getInstanceMethod(cls, sel), "@@:")) return nil;
    @try { return ((id(*)(id,SEL))objc_msgSend)(object,sel); }
    @catch (__unused NSException *exception) { return nil; }
}

static id TBShareProxyForIdentifier(NSString *identifier) {
    if (!identifier.length) return nil;
    Class cls = NSClassFromString(@"LSPlugInKitProxy");
    SEL sel = NSSelectorFromString(@"pluginKitProxyForIdentifier:");
    if (!TBPSMethodMatches(class_getClassMethod(cls,sel), "@@:@")) return nil;
    @try { return ((id(*)(id,SEL,id))objc_msgSend)(cls,sel,identifier); }
    @catch (__unused NSException *exception) { return nil; }
}

static NSString *TBShareIdentifier(id object) {
    return TBShareString(TBShareObject(object,@"bundleIdentifier"));
}

static NSString *TBShareContainerIdentifier(id proxy) {
    id container = TBShareObject(proxy,@"containingBundle");
    return container != proxy ? TBShareIdentifier(container) : nil;
}

static BOOL TBShareExactIcon(NSString *identifier) {
    if (!identifier.length) return NO;
    [gLock lock];
    @try { TBLoadIndex(); return [gIndex[identifier] isKindOfClass:NSString.class]; }
    @finally { [gLock unlock]; }
}

// A dedicated extension icon wins; then use the system's actual containing app.
// The previous three-component fallback is retained only after these exact choices.
static UIImage *TBShareResolve(NSString *identifier, NSString *host) {
    BOOL exactExtension = TBShareExactIcon(identifier), exactHost = TBShareExactIcon(host);
    UIImage *image = exactExtension ? TBImageForBundle(identifier) : nil;
    if (!image && exactHost) image = TBImageForBundle(host);
    if (!image && !exactHost && host.length) image = TBImageForBundle(host);
    if (!image && !exactExtension && identifier.length) image = TBImageForBundle(identifier);
    return image;
}

static UIImage *TBShareForIdentifier(NSString *identifier) {
    identifier = TBShareString(identifier);
    if (!identifier) return nil;
    id proxy = TBShareProxyForIdentifier(identifier);
    return TBShareResolve(identifier,TBShareContainerIdentifier(proxy));
}

static UIImage *TBShareForExtension(id activity) {
    NSString *host = TBShareString(TBShareObject(activity,@"containingAppBundleIdentifier"));
    id helper = TBShareObject(activity,@"activityBundleHelper");
    id proxy = TBShareObject(helper,@"bundleProxy");
    if (!proxy) proxy = TBShareObject(activity,@"applicationExtension");
    NSString *identifier = TBShareIdentifier(proxy);
    if (!host) host = TBShareContainerIdentifier(proxy);
    // NSExtension supplies identifier, whereas an LS proxy supplies bundleIdentifier.
    if (!identifier) identifier = TBShareString(TBShareObject(proxy,@"identifier"));
    if (!host && identifier) host = TBShareContainerIdentifier(TBShareProxyForIdentifier(identifier));
    return TBShareResolve(identifier,host);
}

static UIImage *TBShareForHelper(id helper) {
    id proxy = TBShareObject(helper,@"bundleProxy");
    return TBShareResolve(TBShareIdentifier(proxy),TBShareContainerIdentifier(proxy));
}

static UIImage *TBShareFit(UIImage *themed, id original) {
    // A nil/non-image resource retains the original missing-resource semantics.
    if (!themed || ![original isKindOfClass:UIImage.class]) return original;
    UIImage *native = original;
    CGSize size = native.size;
    CGFloat scale = native.scale;
    if (!isfinite(size.width) || !isfinite(size.height) ||
        !isfinite(scale) || size.width < 1 || size.height < 1 || scale <= 0 ||
        size.width * scale > 4096 || size.height * scale > 4096) return native;
    // TBImageForBundle has already applied the complete theme pipeline once.
    // Redraw only to match size AND scale; do not touch the shared fit cache.
    if (CGSizeEqualToSize(themed.size,size) && themed.scale == scale &&
        themed.imageOrientation == UIImageOrientationUp) { gServe++; return themed; }
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    UIImage *result = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [themed drawInRect:(CGRect){CGPointZero,size}];
    }];
    if (result) { gServe++; return result; }
    return native;
}

static UIImage *tb_shareActivityImage(id self, SEL cmd, NSString *identifier) {
    ++gTBShareDepth;
    @try {
        UIImage *original = o_tbShareActivity ? ((UIImage *(*)(id,SEL,id))o_tbShareActivity)(self,cmd,identifier) : nil;
        if (gTBShareDepth != 1 || ![original isKindOfClass:UIImage.class]) return original;
        TB_RENDER_SCOPE();
        if (!TBShareEnabled()) return original;
        @try { return TBShareFit(TBShareForIdentifier(identifier),original); }
        @catch (__unused NSException *exception) { return original; }
    } @finally { --gTBShareDepth; }
}

static UIImage *tb_shareExtensionImage(id self, SEL cmd) {
    ++gTBShareDepth;
    @try {
        UIImage *original = o_tbShareExtension ? ((UIImage *(*)(id,SEL))o_tbShareExtension)(self,cmd) : nil;
        if (gTBShareDepth != 1 || ![original isKindOfClass:UIImage.class]) return original;
        TB_RENDER_SCOPE();
        if (!TBShareEnabled()) return original;
        @try { return TBShareFit(TBShareForExtension(self),original); }
        @catch (__unused NSException *exception) { return original; }
    } @finally { --gTBShareDepth; }
}

static UIImage *tb_shareHelperImage(id self, SEL cmd, int format, long long category) {
    ++gTBShareDepth;
    @try {
        UIImage *original = o_tbShareHelper ? ((UIImage *(*)(id,SEL,int,long long))o_tbShareHelper)(self,cmd,format,category) : nil;
        if (gTBShareDepth != 1 || ![original isKindOfClass:UIImage.class]) return original;
        TB_RENDER_SCOPE();
        if (!TBShareEnabled()) return original;
        @try { return TBShareFit(TBShareForHelper(self),original); }
        @catch (__unused NSException *exception) { return original; }
    } @finally { --gTBShareDepth; }
}

// Preserve worker-queue delivery, cancellation semantics, category and flags.
static void tb_shareDeliverImage(id self, SEL cmd, UIImage *image, NSString *identifier,
                                 long long category, NSString *contentSize, BOOL placeholder) {
    ++gTBShareDepth;
    @try {
        UIImage *result = image;
        if (gTBShareDepth == 1 && !placeholder && [image isKindOfClass:UIImage.class]) {
            TB_RENDER_SCOPE();
            if (TBShareEnabled()) {
                @try { result = TBShareFit(TBShareForIdentifier(identifier),image); }
                @catch (__unused NSException *exception) { result = image; }
            }
        }
        if (o_tbShareDelivery) ((void(*)(id,SEL,id,id,long long,id,BOOL))o_tbShareDelivery)
            (self,cmd,result,identifier,category,contentSize,placeholder);
    } @finally { --gTBShareDepth; }
}

static void TBShareInstallIcons(void) {
    if (![NSThread isMainThread]) return;
    if (gTBShareInstalling || __atomic_load_n(&gTBShareComplete,__ATOMIC_ACQUIRE)) return;
    gTBShareInstalling = YES;
    // Each original slot is a separate once-only guard. A missing class/method
    // remains eligible for later images; do not mark a whole class done early.
    Class activity = NSClassFromString(@"UIActivity");
    if (activity) TBPSInstallMethod(object_getClass(activity),
        NSSelectorFromString(@"_activityImageForApplicationBundleIdentifier:"),
        (IMP)tb_shareActivityImage,&o_tbShareActivity,"@@:@");
    TBPSInstallMethod(NSClassFromString(@"UIApplicationExtensionActivity"),
        NSSelectorFromString(@"_activityImage"),
        (IMP)tb_shareExtensionImage,&o_tbShareExtension,"@@:");
    TBPSInstallMethod(NSClassFromString(@"_UIActivityBundleHelper"),
        NSSelectorFromString(@"imageForApplicationIconFormat:activityCategory:"),
        (IMP)tb_shareHelperImage,&o_tbShareHelper,"@@:iq");
    TBPSInstallMethod(NSClassFromString(@"SFUIActivityImageProvider"),
        NSSelectorFromString(@"_handleIconImage:bundleIdentifier:activityCategory:contentSizeCategory:placeholder:"),
        (IMP)tb_shareDeliverImage,&o_tbShareDelivery,"v@:@@q@B");
    if (o_tbShareActivity && o_tbShareExtension && o_tbShareHelper && o_tbShareDelivery)
        __atomic_store_n(&gTBShareComplete,1,__ATOMIC_RELEASE);
    gTBShareInstalling = NO;
}

static void TBShareQueueInstall(void) {
    if (__atomic_load_n(&gTBShareComplete,__ATOMIC_ACQUIRE)) return;
    if (__atomic_exchange_n(&gTBSharePending,1,__ATOMIC_ACQ_REL)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Clear before scanning so an image arriving during the scan schedules
        // another main-queue pass instead of losing its notification.
        __atomic_store_n(&gTBSharePending,0,__ATOMIC_RELEASE);
        @autoreleasepool { TBShareInstallIcons(); }
    });
}

static void TBShareImageLoaded(const struct mach_header *header, intptr_t slide) {
    (void)header; (void)slide;
    // dyld may hold its loader lock. No ObjC lookup, dlopen, or image enumeration.
    TBShareQueueInstall();
}

static void TBShareObserveImages(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _dyld_register_func_for_add_image(TBShareImageLoaded); });
}
