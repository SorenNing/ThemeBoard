#import <UIKit/UIKit.h>

/// 动态色（浅色 / 深色各一份）
UIColor *TBDynamicColor(UIColor *light, UIColor *dark);

/// 系统自适应页面底色，供 Theseus 玻璃采样。
void TBApplyPageBackground(UIView *host);

/// 给单个页面铺不透明背景（表格页走 backgroundView，不会随滚动跑）
void TBSetPageBackground(UIViewController *vc);

/// 容器级磨砂（放在导航控制器 view 的最底层，页面本身保持透明）
void TBAttachFrostContainer(UIView *host);

/// 窗口级磨砂底（唯一正确的位置：不会随内容滚动）
void TBAttachWindowFrost(UIWindow *window);

/// 页面级磨砂底（仅在非表格页面用）：四角彩色 blob 渐变，铺满并插到最底层
void TBAttachFrost(UIView *host);

/// 原版 Theseus regular 材质；前景内容不参与自身背景采样。
UIView *TBGlassCard(CGFloat radius);

/// 在任意控件/面板底部安装或复用 Theseus；nil tint 使用原版中性材质。
void TBApplyTheseusSurface(UIView *host, CGFloat radius, UIColor *tint);

/// 给任意视图加白 rim（1px）
void TBApplyRim(UIView *v, CGFloat alpha);

/// 玻璃胶囊按钮（无 dock 版本）
UIButton *TBGlassButton(NSString *title, BOOL danger);

/// App 自有导航操作按钮；系统返回与边缘返回仍交给 UIKit。
UIBarButtonItem *TBGlassNavigationItem(NSString *title, UIImage *image, id target, SEL action);

/// 表格 cell 的玻璃底（带左右内缩）
UIView *TBGlassCellBG(CGFloat inset);

/// 表格 cell 的玻璃卡（按页面边距对齐）：卡片左右边缘始终落在距 UITableView
/// 左右边缘 pageSide 处。.insetGrouped 的 section inset 在不同屏幕/系统上是 20 或 24，
/// 写死 "pageSide - 20" 会得到 16 或 20 —— 这个版本改成运行时按实际 cell 位置换算，
/// 不再依赖魔法数。上下仍保留 2pt 间隙（卡片高度 = 行高 - 4）。
UIView *TBGlassCellAtPageSide(CGFloat pageSide);

/// 表格统一外观：透明底、透明 cell、无分隔线
void TBGlassTable(UITableView *tv);

/// 给 App 自有搜索框使用 Theseus，保持 UIKit 原来的输入与布局。
void TBStyleSearchBarGlass(UISearchBar *searchBar);

/// 兼容入口；不对 UIKit 搜索框进行 swizzle。
void TBInstallGlassSearchBars(void);
