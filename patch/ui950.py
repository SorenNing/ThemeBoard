#!/usr/bin/env python3
# 0.9.5 修补：详情页预览/网格布局、窗口底色
import re

# 1) 详情页：预览复用 coverImageWithSize，约束挂对卡片
p = 'app/TBThemeDetailController.m'
s = open(p).read()

start = s.find('    // 横排 4 个小预览')
end = s.find('    UILabel *count')
assert start > 0 and end > start, (start, end)
new = '''    // 横排 4 个小预览：复用列表页验证过的 2x2 封面，切四块
    UIImage *sheet = [self.theme coverImageWithSize:176];
    for (NSInteger i = 0; i < 4; i++) {
        CGFloat cell = 88.0;
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(cell, cell)];
        UIImage *crop = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [sheet drawAtPoint:CGPointMake(-((i % 2) * cell), -((i / 2) * cell))];
        }];
        UIImageView *iv = [[UIImageView alloc] initWithImage:crop];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.layer.cornerRadius = 9;
        iv.layer.cornerCurve = kCACornerCurveContinuous;
        iv.clipsToBounds = YES;
        [card addSubview:iv];
    }

'''
s = s[:start] + new + s[end:]

s = s.replace('- (void)addCoverConstraints {\n    UIView *card = self.view.subviews.firstObject;',
              '- (void)addCoverConstraints:(UIView *)card {')
s = s.replace('    [self addCoverConstraints];', '    [self addCoverConstraints:card];')

# 网格 top 锚到卡片底部，间隙收紧
s = s.replace('[self.grid.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:6],',
              '[self.grid.topAnchor constraintEqualToAnchor:card.bottomAnchor constant:8],')
open(p, 'w').write(s)
print('detail patched')

# 2) 窗口底色固定为页面基色（转场时不再透黑）
p = 'app/TBAppDelegate.m'
s = open(p).read()
s = s.replace('self.window.backgroundColor = [UIColor systemBackgroundColor];',
              'self.window.backgroundColor = [UIColor colorWithRed:0.898 green:0.886 blue:0.867 alpha:1];')
open(p, 'w').write(s)
print('window patched')
