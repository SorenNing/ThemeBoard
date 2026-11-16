#import <UIKit/UIKit.h>

/// 表格页基类：
/// - self.view 和 UITableView 透明，无额外页面底板
/// - UITableView 铺满页面，内容可滚到透明顶部与底栏后方
/// - 子类照旧实现 UITableViewDataSource/Delegate 方法，并可直接用 self.tableView
@interface TBTableViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIRefreshControl *refreshControl;   // 转发到 tableView

- (instancetype)initWithStyle:(UITableViewStyle)style;

@end
