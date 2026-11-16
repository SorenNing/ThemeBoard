#import <UIKit/UIKit.h>

/// 动态色（浅色 / 深色各一份）
UIColor *TBDynamicColor(UIColor *light, UIColor *dark);

/// 原版 Theseus regular 材质；前景内容不参与自身背景采样。
UIView *TBGlassCard(CGFloat radius);

/// 在任意控件/面板底部安装或复用 Theseus；nil tint 使用原版中性材质。
void TBApplyTheseusSurface(UIView *host, CGFloat radius, UIColor *tint);

/// 玻璃胶囊按钮（无 dock 版本）
UIButton *TBGlassButton(NSString *title, BOOL danger);

/// App 自有导航操作按钮；系统返回与边缘返回仍交给 UIKit。
UIBarButtonItem *TBGlassNavigationItem(NSString *title, UIImage *image, id target, SEL action);

/// 表格 cell 的玻璃底（带左右内缩）
UIView *TBGlassCellBG(CGFloat inset);

/// 移除系统单元格重复背景；业务内容与 accessory 保持原样。
void TBPrepareTheseusCell(UITableViewCell *cell);
void TBInstallTheseusCellSurface(UITableViewCell *cell, CGFloat inset);

/// 表格统一外观：透明底、透明 cell、无分隔线
void TBGlassTable(UITableView *tv);

/// 给 App 自有搜索框使用 Theseus，保持 UIKit 原来的输入与布局。
void TBStyleSearchBarGlass(UISearchBar *searchBar);
