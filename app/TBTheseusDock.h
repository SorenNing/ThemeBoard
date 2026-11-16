#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Implemented in Swift. Geometry, rendering, and interaction belong to TheseusTabBar.
@interface TBTheseusDock : UIView
@property (nonatomic, copy, nullable) void (^onSelection)(NSInteger index);
@property (nonatomic, copy, nullable) void (^onReselection)(NSInteger index);
@property (nonatomic, assign) NSInteger selectedIndex;
- (void)invalidateBackground;
@end

NS_ASSUME_NONNULL_END
