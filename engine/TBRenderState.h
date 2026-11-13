// Private to ThemeBoardEngine.m. Rendering keeps a committed generation until a
// fully prepared candidate is published. No UI objects belong to this state.
@interface TBThemeRenderState : NSObject {
@public
    NSDictionary *preferences;
    NSRecursiveLock *renderLock;
    NSUInteger generation;
    NSMutableDictionary *fitCache, *index, *bundleRes, *resourceCache;
    NSString *indexTheme, *bundleResTheme, *resourceTheme;
    NSCache *imageCache, *clockFaceCache;
    UIImage *systemMaskTemplate, *maskThemeImg, *maskGlassImg;
    NSString *maskThemeKey, *maskGlassKey;
    BOOL maskThemeChecked;
    NSMapTable *squareFillCache;
    NSMutableSet *glassNames;
    UIImage *fxImg[2];
    NSString *fxKey[2];
    BOOL fxChecked[2];
    NSMutableDictionary *globalImgCache, *badgeThemeImgCache;
    NSString *globalCacheTheme, *badgeThemeImgCacheTheme;
    BOOL shadowParamsChecked, shadowOn;
    double shadowStrength;
}
- (instancetype)initWithPreferences:(NSDictionary *)values generation:(NSUInteger)seq;
@end

@implementation TBThemeRenderState
- (instancetype)initWithPreferences:(NSDictionary *)values generation:(NSUInteger)seq {
    if ((self = [super init])) {
        preferences = [values copy] ?: @{};
        generation = seq;
        renderLock = [[NSRecursiveLock alloc] init];
        imageCache = [[NSCache alloc] init]; imageCache.countLimit = 600;
        clockFaceCache = [[NSCache alloc] init]; clockFaceCache.countLimit = 8;
        fitCache = [NSMutableDictionary dictionary];
        resourceCache = [NSMutableDictionary dictionary];
    }
    return self;
}
@end

static TBThemeRenderState *gCommittedThemeState;
static __thread void *gScopedThemeState;

static NSDictionary *TBReadPreferenceValues(void) {
    // A present plist is authoritative even when ActiveTheme was removed.
    // Falling back to a stale cfprefsd value would re-apply a cancelled theme.
    for (NSString *path in @[@"/var/mobile/Library/Preferences/com.ning.themeboard.plist",
                             @"/var/jb/var/mobile/Library/Preferences/com.ning.themeboard.plist"]) {
        NSDictionary *values = [NSDictionary dictionaryWithContentsOfFile:path];
        if (values) return [values copy];
    }
    NSArray *known = @[@"Enabled", @"ActiveTheme", @"LogEnabled", @"SafeMode",
                       @"PurgeCache", @"FollowSystem", @"NoCalendarDate", @"ThemeRoot",
                       @"ApplyRequestID", @"UseThemeIconMask", @"MaskCornerRadiusOn",
                       @"MaskCornerRadius", @"UseThemeIconOverlay", @"UseThemeIconShadow",
                       @"UseThemeBadge", @"CustomMaskPath", @"CustomOverlayPath",
                       @"CustomShadowPath", @"CustomBadgePath", @"GlassOverlayStrength",
                       @"GlobalIconEffect"];
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:known.count];
    for (NSString *key in known) {
        id value = CFBridgingRelease(CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key, (__bridge CFStringRef)kDomain));
        if (value) out[key] = value;
    }
    return out;
}

static TBThemeRenderState *TBCommittedState(void) {
    @synchronized ([TBThemeRenderState class]) {
        if (!gCommittedThemeState)
            gCommittedThemeState = [[TBThemeRenderState alloc] initWithPreferences:TBReadPreferenceValues() generation:0];
        return gCommittedThemeState;
    }
}
static TBThemeRenderState *TBCurrentRenderState(void) {
    return gScopedThemeState ? (__bridge TBThemeRenderState *)gScopedThemeState : TBCommittedState();
}
static void TBPublishRenderState(TBThemeRenderState *state) {
    @synchronized ([TBThemeRenderState class]) { gCommittedThemeState = state; }
}

typedef struct {
    void *previous;
    void *retained;
} TBRenderScope;

static TBRenderScope TBEnterRenderState(TBThemeRenderState *requested) {
    if (gScopedThemeState && (!requested || (__bridge void *)requested == gScopedThemeState))
        return (TBRenderScope){NULL, NULL};
    TBThemeRenderState *state = requested ?: TBCommittedState();
    TBRenderScope scope = {gScopedThemeState, (__bridge_retained void *)state};
    gScopedThemeState = (__bridge void *)state;
    return scope;
}
static void TBLeaveRenderState(TBRenderScope *scope) {
    if (!scope->retained) return;
    TBThemeRenderState *state = (__bridge_transfer TBThemeRenderState *)scope->retained;
    scope->retained = NULL;
    gScopedThemeState = scope->previous;
    (void)state; // ARC releases the pinned generation after nested calls return.
}
typedef struct { void *retained; } TBRenderCacheScope;
static TBRenderCacheScope TBLockRenderCache(void) {
    NSRecursiveLock *lock = TBCurrentRenderState()->renderLock;
    [lock lock];
    return (TBRenderCacheScope){(__bridge_retained void *)lock};
}
static void TBUnlockRenderCache(TBRenderCacheScope *scope) {
    NSRecursiveLock *lock = (__bridge_transfer NSRecursiveLock *)scope->retained;
    [lock unlock];
}
#define TB_RENDER_CACHE_LOCK() TBRenderCacheScope tb_cache_scope __attribute__((cleanup(TBUnlockRenderCache), unused)) = TBLockRenderCache()
#define TB_RENDER_SCOPE() TBRenderScope tb_render_scope __attribute__((cleanup(TBLeaveRenderState), unused)) = TBEnterRenderState(nil)
#define TB_RENDER_WITH(state) TBRenderScope tb_render_scope __attribute__((cleanup(TBLeaveRenderState), unused)) = TBEnterRenderState(state)

// Existing image processing retains its algorithms; its caches are now owned by
// a generation. Nested hooks on the same thread cannot mix old and new state.
#define gFitCache (TBCurrentRenderState()->fitCache)
#define gIndex (TBCurrentRenderState()->index)
#define gIndexTheme (TBCurrentRenderState()->indexTheme)
#define gBundleRes (TBCurrentRenderState()->bundleRes)
#define gBundleResTheme (TBCurrentRenderState()->bundleResTheme)
#define gImageCache (TBCurrentRenderState()->imageCache)
#define gClockFaceCache (TBCurrentRenderState()->clockFaceCache)
#define gSystemMaskTemplate (TBCurrentRenderState()->systemMaskTemplate)
#define gMaskThemeImg (TBCurrentRenderState()->maskThemeImg)
#define gMaskThemeKey (TBCurrentRenderState()->maskThemeKey)
#define gMaskThemeChecked (TBCurrentRenderState()->maskThemeChecked)
#define gMaskGlassImg (TBCurrentRenderState()->maskGlassImg)
#define gMaskGlassKey (TBCurrentRenderState()->maskGlassKey)
#define gSquareFillCache (TBCurrentRenderState()->squareFillCache)
#define gGlassNames (TBCurrentRenderState()->glassNames)
#define gFxImg (TBCurrentRenderState()->fxImg)
#define gFxKey (TBCurrentRenderState()->fxKey)
#define gFxChecked (TBCurrentRenderState()->fxChecked)
#define gGlobalImgCache (TBCurrentRenderState()->globalImgCache)
#define gGlobalCacheTheme (TBCurrentRenderState()->globalCacheTheme)
#define gBadgeThemeImgCache (TBCurrentRenderState()->badgeThemeImgCache)
#define gBadgeThemeImgCacheTheme (TBCurrentRenderState()->badgeThemeImgCacheTheme)
#define gResCache (TBCurrentRenderState()->resourceCache)
#define gResTheme (TBCurrentRenderState()->resourceTheme)
