#import <UIKit/UIKit.h>

/// 动态色（浅色 / 深色各一份）
UIColor *TBDynamicColor(UIColor *light, UIColor *dark);

/// 窗口级磨砂底（唯一正确的位置：不会随内容滚动）
void TBAttachWindowFrost(UIWindow *window);

/// 页面级磨砂底（仅在非表格页面用）：四角彩色 blob 渐变，铺满并插到最底层
void TBAttachFrost(UIView *host);

/// 玻璃卡片：SystemThinMaterial 打底 + 玻璃填充 + 白 rim
UIView *TBGlassCard(CGFloat radius);

/// 给任意视图加白 rim（1px）
void TBApplyRim(UIView *v, CGFloat alpha);

/// 玻璃胶囊按钮（无 dock 版本）
UIButton *TBGlassButton(NSString *title, BOOL danger);

/// 表格 cell 的玻璃底（带左右内缩）
UIView *TBGlassCellBG(CGFloat inset);

/// 表格统一外观：透明底、透明 cell、无分隔线
void TBGlassTable(UITableView *tv);
