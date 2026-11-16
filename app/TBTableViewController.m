#import "TBTableViewController.h"
#import "TBGlass.h"

@interface TBTableViewController ()
@property (nonatomic, assign) UITableViewStyle style;
@property (nonatomic, strong) UIView *bgView;
@end

@implementation TBTableViewController

- (instancetype)initWithStyle:(UITableViewStyle)style {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _style = style;
    }
    return self;
}

- (instancetype)init {
    return [self initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // 1) 背景：独立兄弟视图，铺满整页，永远在最底层
    self.bgView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.bgView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.bgView.userInteractionEnabled = NO;
    [self.view addSubview:self.bgView];
    TBApplyPageBackground(self.bgView);

    // 2) 表格：子视图，透明，压在背景之上
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:self.style];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    // 安全区限定实际裁剪边界；不再叠加导航栏或浮动底栏的 contentInset。
    self.tableView.clipsToBounds = YES;
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.tableView.automaticallyAdjustsScrollIndicatorInsets = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
    ]];
    if (@available(iOS 15.0, *)) {
        // 背景是首个子视图时，也让 UIKit 跟踪正确的表格来展开/收起搜索栏。
        [self setContentScrollView:self.tableView forEdge:NSDirectionalRectEdgeTop];
    }
}

// 0.15.61：0.15.60 在这里给所有 cell 放开 clipsToBounds（配合「卡片按页面 16pt 外扩」的
// 运行时 hack）。hack 已整体撤掉，这里也一并删除，恢复 UIKit 默认裁剪。

- (UIRefreshControl *)refreshControl {
    return self.tableView.refreshControl;
}

- (void)setRefreshControl:(UIRefreshControl *)refreshControl {
    self.tableView.refreshControl = refreshControl;
}

#pragma mark - 默认数据源（子类会覆盖）

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 0; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
}

@end
