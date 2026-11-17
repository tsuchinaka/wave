#import "waTableController.h"
#import "waCell.h"
#import "waRootController.h"
#import "waActions.h"

@interface waPaddedView : UIView
@property (nonatomic, assign) CGFloat bottomPad;
@end

@implementation waPaddedView
- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *wrap = [self viewWithTag:9043];
    if (!wrap) return;
    wrap.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    CGRect bounds = self.bounds;
    CGFloat pad = [waRootController miniPlayerCoverHeight];
    self.bottomPad = pad;
    CGFloat height = CGRectGetHeight(bounds) - pad;
    if (height < 1.0) height = 1.0;
    wrap.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(bounds), height);
}
@end

@interface waTableController ()
@property (nonatomic, strong) UIView *stateView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation waTableController

- (id)initWithGroupedStyle:(BOOL)grouped {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _grouped = grouped;
    }
    return self;
}

- (void)loadView {
    CGRect frame = [[UIScreen mainScreen] bounds];
    waPaddedView *root = [[waPaddedView alloc] initWithFrame:frame];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.backgroundColor = self.grouped ? [UIColor groupTableViewBackgroundColor] : [UIColor whiteColor];
    self.view = root;

    UIView *wrap = [[UIView alloc] initWithFrame:frame];
    wrap.tag = 9043;
    wrap.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    wrap.backgroundColor = [UIColor clearColor];
    [root addSubview:wrap];

    UITableView *table = [[UITableView alloc] initWithFrame:wrap.bounds
                                                      style:self.grouped ? UITableViewStyleGrouped : UITableViewStylePlain];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = self;
    table.delegate = self;
    table.backgroundColor = self.grouped ? [UIColor groupTableViewBackgroundColor] : [UIColor whiteColor];
    table.separatorColor = [UIColor lightGrayColor];
    table.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView = table;
    [wrap addSubview:table];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.center = CGPointMake(frame.size.width / 2.0, frame.size.height / 2.0);
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [root addSubview:self.spinner];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.title.length) self.title = @"";
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (bar) {
        bar.barStyle = UIBarStyleDefault;
        bar.translucent = NO;
        bar.tintColor = nil;
        [bar setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyMiniPlayerLayout) name:waMiniPlayerLayoutDidChangeNotification object:nil];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(rowHeld:)];
    hold.minimumPressDuration = 0.4;
    [self.tableView addGestureRecognizer:hold];
}

- (NSDictionary *)contextMenuForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)indexPath;
    return nil;
}

- (void)rowHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (self.tableView.editing || self.editing) return;
    if ([waActions isShowingInView:self.view]) return;
    CGPoint point = [gesture locationInView:self.tableView];
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:point];
    if (!path) return;
    NSDictionary *menu = [self contextMenuForRowAtIndexPath:path];
    NSArray *actions = [menu objectForKey:@"actions"];
    if (![actions isKindOfClass:[NSArray class]] || !actions.count) return;
    NSString *title = [menu objectForKey:@"title"];
    // Present on the next turn so the gesture is not still active when the
    // sheet takes the view.
    dispatch_async(dispatch_get_main_queue(), ^{
        [waActions showInView:self.view title:[title isKindOfClass:[NSString class]] ? title : nil actions:actions];
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [[waRootController shared] refreshMiniPlayer];
}

- (void)applyMiniPlayerLayout {
    if (!self.isViewLoaded) return;
    [self.view setNeedsLayout];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)reload {
    [self.tableView reloadData];
}

- (void)setLoading:(BOOL)loading {
    if (loading) {
        [self clearStateView];
        self.tableView.backgroundView = nil;
        self.state = waPageStateLoading;
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }
}

- (void)clearStateView {
    [self.stateView removeFromSuperview];
    self.stateView = nil;
}

- (void)showEmpty:(NSString *)title message:(NSString *)message {
    [self clearStateView];
    self.state = waPageStateEmpty;
    self.emptyTitle = title;
    self.emptyMessage = message;
    waEmptyState *empty = [[waEmptyState alloc] initWithTitle:title message:message];
    empty.frame = self.tableView.bounds;
    empty.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    empty.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = empty;
    self.stateView = empty;
    [self.tableView reloadData];
}

- (void)showError:(NSError *)error retry:(SEL)retry {
    self.state = waPageStateError;
    [self showEmpty:@"Cannot Load" message:error.localizedDescription.length ? error.localizedDescription : @"Check your connection and try again."];
    if (retry && [self respondsToSelector:retry]) {
        UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"Retry"
                                                                 style:UIBarButtonItemStyleBordered
                                                                target:self
                                                                action:retry];
        self.navigationItem.rightBarButtonItem = item;
    }
}

#pragma mark - table defaults

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return 0; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)indexPath;
    return [waCell cellForTable:tableView];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (!self.grouped) return;
    NSInteger rows = [self tableView:tableView numberOfRowsInSection:indexPath.section];
    [waCell applyGroupedBackground:cell rows:rows row:indexPath.row];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end
