#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Narrow Objective-C adapters for unmodified upstream Theseus components.
@interface TBTheseusSurface : UIView
@property (nonatomic, assign) CGFloat cornerRadius;
@property (nonatomic, strong, nullable) UIColor *surfaceTint;
@property (nonatomic, weak, nullable) UIView *captureExclusion;
- (void)invalidateBackground;
@end

@interface TBTheseusSwitch : UIControl
@property (nonatomic, assign, getter=isOn) BOOL on;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
@end

@interface TBTheseusSlider : UIControl
@property (nonatomic, assign) float minimumValue;
@property (nonatomic, assign) float maximumValue;
@property (nonatomic, assign) float value;
@property (nonatomic, assign, getter=isContinuous) BOOL continuous;
- (void)setValue:(float)value animated:(BOOL)animated;
@end

NS_ASSUME_NONNULL_END
