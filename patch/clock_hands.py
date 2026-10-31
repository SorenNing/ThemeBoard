import re

p = 'engine/ThemeBoardEngine.m'
s = open(p).read()

if 'tb_clockHandLayer' not in s:
    # 1) 三个指针层工厂都返回 nil：由主题图自己带指针
    s = s.replace('#pragma mark - 安装', '''// 时钟视图会从 imageSet 里取这三层指针叠加上去（17.2 头文件：
// + makeHoursHandLayerWithImageSet: / makeMinutesHandLayerWithImageSet: /
// + makeSecondsHandLayerWithImageSet:）。我们接管背景图后必须同时把这些层置空，
// 否则会出现"主题图自带一根秒针 + 系统又叠一根"的双指针。
typedef id (*ClockLayerFn)(id, SEL, id);
static ClockLayerFn o_clockHandLayer[3];

static id tb_clockHandLayer(id self, SEL _cmd, id imageSet) {
    if (TBEnabled() && !TBSafeMode()) {
        if (TBImageForBundle(@"com.apple.mobiletimer")) return nil;
    }
    for (int i = 0; i < 3; i++) {
        if (o_clockHandLayer[i]) return o_clockHandLayer[i](self, _cmd, imageSet);
    }
    return nil;
}

#pragma mark - 安装''')

    # 2) 安装三组 hook
    s = s.replace('''        o_clockIconImage = (ClockIconImageFn)TBHookClass(clockView, @"iconImageWithImageInfo:includingMask:",
                                                         (IMP)tb_clockIconImage, "桌面时钟图标");''',
'''        o_clockIconImage = (ClockIconImageFn)TBHookClass(clockView, @"iconImageWithImageInfo:includingMask:",
                                                         (IMP)tb_clockIconImage, "桌面时钟图标");
        o_clockHandLayer[0] = (ClockLayerFn)TBHookClass(clockView, @"makeHoursHandLayerWithImageSet:",
                                                        (IMP)tb_clockHandLayer, "时钟时针层");
        o_clockHandLayer[1] = (ClockLayerFn)TBHookClass(clockView, @"makeMinutesHandLayerWithImageSet:",
                                                        (IMP)tb_clockHandLayer, "时钟分针层");
        o_clockHandLayer[2] = (ClockLayerFn)TBHookClass(clockView, @"makeSecondsHandLayerWithImageSet:",
                                                        (IMP)tb_clockHandLayer, "时钟秒针层");''')

open(p, 'w').write(s)
print('ok', 'tb_clockHandLayer' in s)
