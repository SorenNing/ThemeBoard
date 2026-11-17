// Ning. Included after TBReload; adds no global UIView/UIImage hooks or timers.
@interface TBDarkAppearanceProbe : UIView
@end
static void TBDarkScheduleAppearanceCheck(void);
@implementation TBDarkAppearanceProbe
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (!previous || previous.userInterfaceStyle != self.traitCollection.userInterfaceStyle)
        TBDarkScheduleAppearanceCheck();
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) TBDarkScheduleAppearanceCheck();
}
@end

static BOOL TBDarkWantsObservation(NSDictionary *values) {
    return [values[@"DarkIconBackground"] boolValue] &&
        (!values[@"Enabled"] || [values[@"Enabled"] boolValue]) &&
        ![values[@"SafeMode"] boolValue];
}
static BOOL TBDarkExpectedState(NSDictionary *values) {
    return TBDarkWantsObservation(values) && TBDarkSystemAppearance();
}
static void TBDarkRefreshObservation(NSDictionary *values) {
    if (![NSThread isMainThread]) return;
    static NSHashTable<TBDarkAppearanceProbe *> *probes;
    static NSArray *tokens;
    static const void *probeKey = &probeKey;
    BOOL active = TBDarkWantsObservation(values);
    if (!active) {
        for (TBDarkAppearanceProbe *probe in probes.allObjects) {
            UIWindow *window = probe.window;
            [probe removeFromSuperview];
            if (window) objc_setAssociatedObject(window, probeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    if (!tokens) {
        NSMutableArray *observers = [NSMutableArray array];
        for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification,
                                           UIWindowDidBecomeVisibleNotification,
                                           UISceneDidActivateNotification]) {
            id token = [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil
                queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                    (void)note;
                    TBDarkScheduleAppearanceCheck();
                }];
            [observers addObject:token];
        }
        tokens = [observers copy]; // Keep observer tokens for the process lifetime.
    }
    if (!probes) probes = [NSHashTable weakObjectsHashTable];
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (objc_getAssociatedObject(window, probeKey)) continue;
        TBDarkAppearanceProbe *probe = [[TBDarkAppearanceProbe alloc] initWithFrame:CGRectZero];
        probe.userInteractionEnabled = NO;
        probe.isAccessibilityElement = NO;
        probe.accessibilityElementsHidden = YES;
        probe.backgroundColor = [UIColor clearColor];
        objc_setAssociatedObject(window, probeKey, probe, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [probes addObject:probe];
        [window addSubview:probe];
    }
}
static void TBDarkScheduleAppearanceCheck(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ TBDarkScheduleAppearanceCheck(); });
        return;
    }
    static BOOL pending;
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        pending = NO;
        NSDictionary *values = TBReadPreferenceValues();
        TBDarkRefreshObservation(values);
        static NSInteger requestedStyle = -1;
        static NSUInteger requestedSequence;
        BOOL expected = TBDarkExpectedState(values);
        if (expected == TBCommittedState()->darkIconBackground) {
            requestedStyle = -1;
            return;
        }
        // A candidate can take several main-loop turns to prewarm. Repeated
        // window/trait notifications must not keep cancelling that candidate.
        if (requestedStyle == (NSInteger)expected && requestedSequence == gReloadRunSeq)
            return;
        TBReload(NULL, NULL, NULL, NULL, NULL);
        requestedStyle = (NSInteger)expected;
        requestedSequence = gReloadRunSeq;
    });
}
