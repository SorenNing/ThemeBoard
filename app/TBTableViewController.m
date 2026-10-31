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
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

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
