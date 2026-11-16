#import "TBBackdropView.h"

@implementation TBBackdropView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.isAccessibilityElement = NO;
        self.contentMode = UIViewContentModeScaleAspectFill;
        self.clipsToBounds = YES;
        self.opaque = YES;
        [self tb_updateImage];
    }
    return self;
}

- (void)tb_updateImage {
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    NSString *name = dark ? @"Backdrop04-dark" : @"Backdrop04-light";
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"jpg"];
    [UIView performWithoutAnimation:^{
        self.image = path ? [UIImage imageWithContentsOfFile:path] : nil;
    }];
    self.backgroundColor = [UIColor clearColor];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) [self tb_updateImage];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (!previousTraitCollection ||
        [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self tb_updateImage];
    }
}

@end
