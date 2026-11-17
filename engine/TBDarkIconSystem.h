// Ning. Read screen traits on main; worker threads use the last observed style.
// Screen traits are independent of ThemeBoard's own FollowSystem preference.
#include <stdatomic.h>
static _Atomic(int) gTBDarkObservedStyle;
static BOOL TBDarkSystemAppearance(void) {
    int style=atomic_load_explicit(&gTBDarkObservedStyle,memory_order_acquire);
    if ([NSThread isMainThread]) {
        @try {
            UIUserInterfaceStyle observed=[UIScreen mainScreen].traitCollection.userInterfaceStyle;
            if (observed==UIUserInterfaceStyleLight || observed==UIUserInterfaceStyleDark) {
                style=(int)observed;
                atomic_store_explicit(&gTBDarkObservedStyle,style,memory_order_release);
            }
        } @catch (NSException *exception) { }
    }
    return style==UIUserInterfaceStyleDark;
}
