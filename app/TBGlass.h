#import <UIKit/UIKit.h>

/// 动态色（浅色 / 深色各一份）
UIColor *TBDynamicColor(UIColor *light, UIColor *dark);

/// 给一个普通视图铺上页面背景（渐变 + 柔光斑），供表格页基类使用
void TBApplyPageBackground(UIView *host);

/// 给单个页面铺不透明背景（表格页走 backgroundView，不会随滚动跑）
void TBSetPageBackground(UIViewController *vc);

/// 容器级磨砂（放在导航控制器 view 的最底层，页面本身保持透明）
void TBAttachFrostContainer(UIView *host);

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

/// 表格 cell 的玻璃卡（按页面边距对齐）：卡片左右边缘始终落在距 UITableView
/// 左右边缘 pageSide 处。.insetGrouped 的 section inset 在不同屏幕/系统上是 20 或 24，
/// 写死 "pageSide - 20" 会得到 16 或 20 —— 这个版本改成运行时按实际 cell 位置换算，
/// 不再依赖魔法数。上下仍保留 2pt 间隙（卡片高度 = 行高 - 4）。
UIView *TBGlassCellAtPageSide(CGFloat pageSide);

/// 表格统一外观：透明底、透明 cell、无分隔线
void TBGlassTable(UITableView *tv);

/// 自绘毛玻璃搜索框：干掉系统灰底，在输入框底下垫一层
/// SystemThinMaterial + 白 0.55/0.12 填充 + 1px 亮边，圆角 = 高/2。
void TBStyleSearchBarGlass(UISearchBar *sb);

/// 全局安装：swizzle UISearchBar 的 layoutSubviews，任何页面的搜索框（详情页/
/// 主题页/设置页）只要一布局就自动套上上面这套玻璃外观，且缩放/旋转后仍然贴合。
void TBInstallGlassSearchBars(void);
