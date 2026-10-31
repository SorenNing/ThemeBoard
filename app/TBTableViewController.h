#import <UIKit/UIKit.h>

/// 表格页基类（MarkFont 结构）：
/// - self.view 是普通 UIView，背景是一层独立的兄弟视图，铺在最底层
/// - UITableView 是 self.view 的子视图，不随背景滚动
/// - 子类照旧实现 UITableViewDataSource/Delegate 方法，并可直接用 self.tableView
@interface TBTableViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIRefreshControl *refreshControl;   // 转发到 tableView

- (instancetype)initWithStyle:(UITableViewStyle)style;

@end
