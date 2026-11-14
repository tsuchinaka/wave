#import "waChartsController.h"
#import "waSession.h"
#import "waPlayer.h"
#import "waRootController.h"
#import "waDetailController.h"
#import "../Skin/waCell.h"
#import "../Skin/waCoverView.h"

@interface waChartsController ()
@property (nonatomic, strong) waChart *chart;
@property (nonatomic, strong) UISegmentedControl *kindControl;
@property (nonatomic, strong) waChromeBar *headerWrap;
@property (nonatomic, assign) CGFloat laidOutWidth;
@end

@implementation waChartsController

- (id)init {
    return [self initWithGroupedStyle:YES];
}

- (id)initWithGroupedStyle:(BOOL)grouped {
    if ((self = [super initWithGroupedStyle:grouped])) {
        self.title = @"Charts";
        self.emptyTitle = @"Charts";
        self.emptyMessage = @"No charts.";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.tableView.separatorColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    self.headerWrap = [[waChromeBar alloc] initWithFrame:CGRectZero];
    NSArray *titles = [NSArray arrayWithObjects:@"Songs", @"Albums", @"Artists", nil];
    self.kindControl = [[UISegmentedControl alloc] initWithItems:titles];
    self.kindControl.segmentedControlStyle = UISegmentedControlStyleBar;
    self.kindControl.selectedSegmentIndex = 0;
    [self.kindControl addTarget:self action:@selector(kindChanged:) forControlEvents:UIControlEventValueChanged];
    [self.headerWrap addSubview:self.kindControl];
    [self layoutHeader];
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                             target:self
                                                                             action:@selector(reload)];
    self.navigationItem.rightBarButtonItem = refresh;
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self layoutHeader];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w < 1.0) return;
    [self layoutHeader];
    if (self.laidOutWidth > 0.0 && fabs(w - self.laidOutWidth) > 1.0 && self.kindControl.selectedSegmentIndex != 0) {
        self.laidOutWidth = w;
        [self.tableView reloadData];
        return;
    }
    self.laidOutWidth = w;
}

- (void)layoutHeader {
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w < 1.0) w = CGRectGetWidth(self.view.bounds);
    if (w < 1.0) w = 320.0;
    self.kindControl.frame = CGRectMake(8.0, 8.0, w - 16.0, 30.0);
    if (self.tableView.tableHeaderView == self.headerWrap && fabs(CGRectGetWidth(self.headerWrap.frame) - w) < 0.5) return;
    self.headerWrap.frame = CGRectMake(0.0, 0.0, w, 46.0);
    self.tableView.tableHeaderView = self.headerWrap;
}

- (void)kindChanged:(UISegmentedControl *)control {
    (void)control;
    BOOL songs = self.kindControl.selectedSegmentIndex == 0;
    self.tableView.separatorStyle = songs ? UITableViewCellSeparatorStyleSingleLine : UITableViewCellSeparatorStyleNone;
    [self.tableView reloadData];
}

- (void)reload {
    self.tableView.backgroundView = nil;
    [self setLoading:YES];
    __weak waChartsController *weakSelf = self;
    [[waSession shared] chartWithCompletion:^(waChart *chart, NSError *error) {
        waChartsController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setLoading:NO];
        if (error) {
            [strongSelf showError:error retry:@selector(reload)];
            return;
        }
        strongSelf.chart = chart;
        strongSelf.state = waPageStateLoaded;
        [strongSelf.tableView reloadData];
    }];
}

- (NSArray *)currentItems {
    if (!self.chart) return [NSArray array];
    if (self.kindControl.selectedSegmentIndex == 1) return self.chart.albums ? self.chart.albums : [NSArray array];
    if (self.kindControl.selectedSegmentIndex == 2) return self.chart.artists ? self.chart.artists : [NSArray array];
    return self.chart.tracks ? self.chart.tracks : [NSArray array];
}

- (BOOL)showsCovers {
    return self.kindControl.selectedSegmentIndex != 0;
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    NSArray *items = [self currentItems];
    if ([self showsCovers]) return items.count ? 1 : 0;
    return (NSInteger)items.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return [self currentItems].count ? 34.0 : 0.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)section;
    if (![self currentItems].count) return nil;
    NSString *title = @"Top Songs";
    if (self.kindControl.selectedSegmentIndex == 1) title = @"Top Albums";
    else if (self.kindControl.selectedSegmentIndex == 2) title = @"Top Artists";
    return [waChrome embossedHeaderWithTitle:title width:CGRectGetWidth(tableView.bounds)];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)indexPath;
    if (![self showsCovers]) return 58.0;
    CGFloat w = CGRectGetWidth(tableView.bounds);
    if (w < 1.0) w = 320.0;
    return [waCoverGrid heightForCount:[self currentItems].count width:w - 20.0];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *items = [self currentItems];
    if ([self showsCovers]) {
        static NSString *kGrid = @"charts.grid";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kGrid];
        waCoverGrid *grid = nil;
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kGrid];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.clipsToBounds = YES;
            grid = [[waCoverGrid alloc] initWithFrame:CGRectZero];
            grid.tag = 810;
            [cell.contentView addSubview:grid];
        } else {
            grid = (waCoverGrid *)[cell.contentView viewWithTag:810];
        }
        CGFloat w = CGRectGetWidth(tableView.bounds) - 20.0;
        CGFloat h = [waCoverGrid heightForCount:items.count width:w];
        grid.frame = CGRectMake(0.0, 0.0, w, h);
        grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [grid setItems:items target:self action:@selector(coverTapped:)];
        return cell;
    }
    waTrack *track = [items objectAtIndex:(NSUInteger)indexPath.row];
    waCell *cell = [waCell cellForTable:tableView subtitle:YES];
    if ([track isKindOfClass:[waTrack class]]) {
        [cell setTrack:track showAlbum:YES];
        cell.indexText = [NSString stringWithFormat:@"%ld", (long)indexPath.row + 1];
    } else if ([track isKindOfClass:[waItem class]]) {
        [cell setItem:(waItem *)track];
        cell.indexText = [NSString stringWithFormat:@"%ld", (long)indexPath.row + 1];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    waCoverGrid *grid = (waCoverGrid *)[cell.contentView viewWithTag:810];
    if (grid) grid.frame = cell.contentView.bounds;
}

- (void)coverTapped:(waCoverView *)cover {
    waItem *item = cover.item;
    if ([item isKindOfClass:[waAlbum class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithAlbum:(waAlbum *)item] animated:YES];
    } else if ([item isKindOfClass:[waArtist class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithArtist:(waArtist *)item] animated:YES];
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self showsCovers]) return;
    NSArray *items = [self currentItems];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)items.count) return;
    id obj = [items objectAtIndex:(NSUInteger)indexPath.row];
    if ([obj isKindOfClass:[waTrack class]]) {
        [[waPlayer shared] playTracks:items startAt:(NSUInteger)indexPath.row context:@"Charts"];
        [[waRootController shared] showPlayer];
    }
}

@end
