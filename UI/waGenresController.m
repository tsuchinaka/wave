#import "waGenresController.h"
#import "waSession.h"
#import "waDetailController.h"
#import "waRootController.h"
#import "../Skin/waCoverView.h"

@interface waGenreArtistsController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *genreID;
@property (nonatomic, strong) NSArray *artists;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) CGFloat laidOutWidth;
- (id)initWithGenre:(waGenre *)genre;
@end

@implementation waGenreArtistsController

- (id)initWithGenre:(waGenre *)genre {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        self.title = genre.title.length ? genre.title : @"Artists";
        self.genreID = genre.identifier;
        _artists = [NSArray array];
    }
    return self;
}

- (void)loadView {
    CGRect frame = [[UIScreen mainScreen] bounds];
    UIView *root = [[UIView alloc] initWithFrame:frame];
    root.backgroundColor = [UIColor groupTableViewBackgroundColor];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = root;
    UITableView *table = [[UITableView alloc] initWithFrame:frame style:UITableViewStyleGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.backgroundColor = [UIColor groupTableViewBackgroundColor];
    table.separatorStyle = UITableViewCellSeparatorStyleNone;
    table.dataSource = self;
    table.delegate = self;
    self.tableView = table;
    [root addSubview:table];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.center = CGPointMake(frame.size.width / 2.0, 120.0);
    [root addSubview:self.spinner];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyMiniInset) name:waMiniPlayerLayoutDidChangeNotification object:nil];
    [self applyMiniInset];
    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applyMiniInset {
    CGFloat pad = [waRootController miniPlayerCoverHeight];
    UIEdgeInsets inset = UIEdgeInsetsMake(0.0, 0.0, pad, 0.0);
    self.tableView.contentInset = inset;
    self.tableView.scrollIndicatorInsets = inset;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (self.laidOutWidth > 0.0 && fabs(w - self.laidOutWidth) > 1.0) {
        self.laidOutWidth = w;
        [self.tableView reloadData];
        return;
    }
    self.laidOutWidth = w;
}

- (void)reload {
    [self.spinner startAnimating];
    __weak waGenreArtistsController *weakSelf = self;
    [[waSession shared] artistsForGenre:self.genreID completion:^(NSArray *artists, NSError *error) {
        waGenreArtistsController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.spinner stopAnimating];
        if (error) return;
        NSMutableArray *clean = [NSMutableArray array];
        for (id obj in artists) if ([obj isKindOfClass:[waItem class]]) [clean addObject:obj];
        strongSelf.artists = clean;
        [strongSelf.tableView reloadData];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.artists.count ? 1 : 0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)indexPath;
    CGFloat w = CGRectGetWidth(tableView.bounds);
    if (w < 1.0) w = 320.0;
    return [waCoverGrid heightForCount:self.artists.count width:w - 20.0];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)indexPath;
    static NSString *kGrid = @"genre.artists";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kGrid];
    waCoverGrid *grid = nil;
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kGrid];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.clipsToBounds = YES;
        grid = [[waCoverGrid alloc] initWithFrame:CGRectZero];
        grid.tag = 820;
        [cell.contentView addSubview:grid];
    } else {
        grid = (waCoverGrid *)[cell.contentView viewWithTag:820];
    }
    CGFloat w = CGRectGetWidth(tableView.bounds) - 20.0;
    CGFloat h = [waCoverGrid heightForCount:self.artists.count width:w];
    grid.frame = CGRectMake(0.0, 0.0, w, h);
    [grid setItems:self.artists target:self action:@selector(artistTapped:)];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    waCoverGrid *grid = (waCoverGrid *)[cell.contentView viewWithTag:820];
    if (grid) grid.frame = cell.contentView.bounds;
}

- (void)artistTapped:(waCoverView *)cover {
    if ([cover.item isKindOfClass:[waArtist class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithArtist:(waArtist *)cover.item] animated:YES];
    }
}

@end

@interface waGenresController ()
@property (nonatomic, strong) NSArray *genres;
@property (nonatomic, strong) NSArray *artists;
@property (nonatomic, strong) waChromeBar *chromeBar;
@property (nonatomic, strong) UIScrollView *genreStrip;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) waCoverGrid *grid;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, copy) NSString *selectedGenreID;
@property (nonatomic, copy) NSString *selectedGenreTitle;
@property (nonatomic, assign) CGFloat gridWidth;
@end

@implementation waGenresController

- (id)init {
    return [self initWithGroupedStyle:YES];
}

- (id)initWithGroupedStyle:(BOOL)grouped {
    if ((self = [super initWithGroupedStyle:grouped])) {
        self.title = @"Genres";
        _genres = [NSArray array];
        _artists = [NSArray array];
        self.tableView = nil;
    }
    return self;
}

- (void)loadView {
    CGRect frame = [[UIScreen mainScreen] bounds];
    UIView *root = [[UIView alloc] initWithFrame:frame];
    root.backgroundColor = [UIColor groupTableViewBackgroundColor];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = root;

    self.chromeBar = [[waChromeBar alloc] initWithFrame:CGRectZero];
    [root addSubview:self.chromeBar];

    self.genreStrip = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.genreStrip.backgroundColor = [UIColor clearColor];
    self.genreStrip.showsHorizontalScrollIndicator = NO;
    self.genreStrip.directionalLockEnabled = YES;
    self.genreStrip.alwaysBounceHorizontal = YES;
    self.genreStrip.delaysContentTouches = NO;
    self.genreStrip.canCancelContentTouches = NO;
    [self.chromeBar addSubview:self.genreStrip];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:frame];
    scroll.backgroundColor = [UIColor clearColor];
    scroll.alwaysBounceVertical = YES;
    scroll.delaysContentTouches = YES;
    self.scrollView = scroll;
    [root addSubview:scroll];

    self.grid = [[waCoverGrid alloc] initWithFrame:CGRectZero];
    [scroll addSubview:self.grid];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.center = CGPointMake(frame.size.width / 2.0, 160.0);
    [root addSubview:self.spinner];
    [root bringSubviewToFront:self.chromeBar];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.barStyle = UIBarStyleDefault;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(viewDidLayoutSubviews) name:waMiniPlayerLayoutDidChangeNotification object:nil];
    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)layoutGrid {
    CGFloat w = CGRectGetWidth(self.view.bounds);
    CGFloat h = CGRectGetHeight(self.view.bounds);
    if (w < 1.0 || h < 1.0) return;
    CGFloat mini = [waRootController miniPlayerCoverHeight];
    self.chromeBar.frame = CGRectMake(0.0, 0.0, w, 46.0);
    self.genreStrip.frame = self.chromeBar.bounds;
    self.scrollView.frame = CGRectMake(0.0, 46.0, w, h - 46.0);
    UIEdgeInsets inset = UIEdgeInsetsMake(0.0, 0.0, mini, 0.0);
    self.scrollView.contentInset = inset;
    self.scrollView.scrollIndicatorInsets = inset;
    CGFloat gridH = [waCoverGrid heightForCount:self.artists.count width:w];
    if (gridH < 1.0) gridH = 1.0;
    self.grid.frame = CGRectMake(0.0, 4.0, w, gridH);
    CGFloat contentH = gridH + 12.0;
    CGFloat visible = CGRectGetHeight(self.scrollView.bounds) - mini;
    if (contentH < visible) contentH = visible + 1.0;
    self.scrollView.contentSize = CGSizeMake(w, contentH);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutGrid];
    CGFloat w = CGRectGetWidth(self.view.bounds);
    if (self.artists.count && fabs(w - self.gridWidth) > 0.5) {
        self.gridWidth = w;
        [self.grid setItems:self.artists target:self action:@selector(artistTapped:)];
    }
}

- (void)reload {
    [self.spinner startAnimating];
    __weak waGenresController *weakSelf = self;
    [[waSession shared] genresWithCompletion:^(NSArray *genres, NSError *error) {
        waGenresController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.spinner stopAnimating];
        if (error) return;
        NSMutableArray *clean = [NSMutableArray array];
        for (id obj in genres) if ([obj isKindOfClass:[waItem class]]) [clean addObject:obj];
        strongSelf.genres = clean;
        if (clean.count && !strongSelf.selectedGenreID.length) {
            waGenre *first = [clean objectAtIndex:0];
            strongSelf.selectedGenreID = first.identifier;
            strongSelf.selectedGenreTitle = first.title;
        }
        [strongSelf buildStrip];
        [strongSelf loadArtists];
    }];
}

- (void)buildStrip {
    for (UIView *view in [self.genreStrip.subviews copy]) [view removeFromSuperview];
    CGFloat x = 8.0;
    UIFont *font = [UIFont boldSystemFontOfSize:12.0];
    for (NSUInteger i = 0; i < self.genres.count; i++) {
        waGenre *genre = [self.genres objectAtIndex:i];
        if (![genre isKindOfClass:[waItem class]]) continue;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        [waChrome styleButton:button title:genre.title];
        CGSize text = [genre.title sizeWithFont:font];
        CGFloat width = text.width + 22.0;
        if (width < 64.0) width = 64.0;
        button.frame = CGRectMake(x, 8.0, width, 30.0);
        button.tag = (NSInteger)i;
        button.selected = [genre.identifier isEqualToString:self.selectedGenreID];
        button.exclusiveTouch = YES;
        [button addTarget:self action:@selector(genreTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.genreStrip addSubview:button];
        x += width + 6.0;
    }
    CGFloat w = CGRectGetWidth(self.view.bounds);
    if (w < 1.0) w = 320.0;
    self.genreStrip.contentSize = CGSizeMake(MAX(x + 8.0, w), 46.0);
}

- (void)genreTapped:(UIButton *)button {
    if (button.tag < 0 || button.tag >= (NSInteger)self.genres.count) return;
    waGenre *genre = [self.genres objectAtIndex:(NSUInteger)button.tag];
    if (![genre isKindOfClass:[waItem class]]) return;
    self.selectedGenreID = genre.identifier;
    self.selectedGenreTitle = genre.title;
    for (UIView *view in self.genreStrip.subviews) {
        if (![view isKindOfClass:[UIButton class]]) continue;
        ((UIButton *)view).selected = (view.tag == button.tag);
    }
    [self loadArtists];
}

- (void)showArtists:(NSArray *)artists {
    self.artists = artists ? artists : [NSArray array];
    self.gridWidth = 0.0;
    [self layoutGrid];
    CGFloat w = CGRectGetWidth(self.view.bounds);
    if (w < 1.0) w = 320.0;
    self.gridWidth = w;
    [self.grid setItems:self.artists target:self action:@selector(artistTapped:)];
    [self.scrollView setContentOffset:CGPointZero animated:NO];
}

- (void)loadArtists {
    if (!self.selectedGenreID.length) return;
    NSString *requested = [self.selectedGenreID copy];
    [self.spinner startAnimating];
    __weak waGenresController *weakSelf = self;
    [[waSession shared] artistsForGenre:requested completion:^(NSArray *artists, NSError *error) {
        waGenresController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (![strongSelf.selectedGenreID isEqualToString:requested]) return;
        [strongSelf.spinner stopAnimating];
        if (error) {
            [strongSelf showArtists:[NSArray array]];
            return;
        }
        NSMutableArray *clean = [NSMutableArray array];
        for (id obj in artists) if ([obj isKindOfClass:[waItem class]]) [clean addObject:obj];
        [strongSelf showArtists:clean];
    }];
}

- (void)artistTapped:(waCoverView *)cover {
    if ([cover.item isKindOfClass:[waArtist class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithArtist:(waArtist *)cover.item] animated:YES];
    }
}

- (void)seeAllArtists:(UIButton *)button {
    (void)button;
}

@end
