#import "waListViewController.h"
#import "waListViewController+SearchPrivate.h"
#import "../Services/waAPIClient.h"
#import "../Services/waDebugLog.h"
#import "../Services/waImageLoader.h"
#import "../Models/waMediaItem.h"
#import "../Views/waPlaceholder.h"
#import "../Views/waArtworkCell.h"
#import "../Views/waHomeSectionView.h"
#import "../Views/waHomeSectionCell.h"
#import "../Views/waSearchCells.h"
#import "../Services/waTheme.h"
#import "waMediaDetailViewController.h"
#import "waMediaResultsViewController.h"
#import "waPlaylistViewController.h"
#import "../Services/waAudioPlayer.h"
#import "../Views/waMediaActionSheet.h"
#import "../Services/waDownloadManager.h"
#import <QuartzCore/QuartzCore.h>

typedef NS_ENUM(NSInteger, waSearchFilter) {
    waSearchFilterAll = 0,
    waSearchFilterOffline,
    waSearchFilterTracks,
    waSearchFilterAlbums,
    waSearchFilterPlaylists,
    waSearchFilterArtists
};

typedef NS_ENUM(NSInteger, waSearchDisplaySection) {
    waSearchDisplayTracks = waMediaItemTypeSong,
    waSearchDisplayAlbums = waMediaItemTypeAlbum,
    waSearchDisplayArtists = waMediaItemTypeArtist,
    waSearchDisplayPlaylists = waMediaItemTypePlaylist
};

@interface waListViewController () <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIView *searchChrome;
@property (nonatomic, strong) UIView *filterHeaderView;
@property (nonatomic, strong) UIScrollView *filterScrollView;
@property (nonatomic, strong) NSArray *filterButtons;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, strong) NSArray *sections;
@property (nonatomic, strong) NSArray *allSections;
@property (nonatomic, strong) NSArray *offlineItems;
@property (nonatomic, strong) NSArray *hasMore;
@property (nonatomic, strong) NSArray *displaySections;
@property (nonatomic, assign) waSearchFilter selectedFilter;
@property (nonatomic, strong) UIView *stateView;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIImageView *stateIconView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *spinnerBackdrop;
@property (nonatomic, strong) UIView *loadingOverlay;
@property (nonatomic, assign) NSUInteger searchGeneration;
@property (nonatomic, copy) NSString *lastSearchedQuery;
@property (nonatomic, assign) NSUInteger searchFetchLimit;
@property (nonatomic, assign) BOOL searchFailed;
@property (nonatomic, strong) NSMutableArray *recentQueries;
@property (nonatomic, assign) BOOL showingRecents;
@property (nonatomic, assign) BOOL downloadReloadScheduled;
@property (nonatomic, assign) CGSize lastStyledViewSize;
@property (nonatomic, strong) NSMutableDictionary *filterButtonWidths;
- (BOOL)isHorizontalDisplaySection:(NSInteger)section;
- (BOOL)isStaticTitleRow:(NSIndexPath *)path;
- (NSArray *)itemsForDisplaySection:(NSInteger)section;
- (NSInteger)mediaTypeForDisplaySection:(NSInteger)section;
- (waMediaItem *)bestArtistForQuery:(NSString *)query artists:(NSArray *)artists;
- (void)mergeArtistDiscographyForArtist:(waMediaItem *)artist query:(NSString *)query generation:(NSUInteger)generation;
- (NSString *)normalizedSearchText:(NSString *)text;
- (void)rebuildDisplaySections;
- (NSString *)titleForDisplaySection:(NSInteger)section;
- (NSString *)subtitleForSearchItem:(waMediaItem *)item;
- (NSString *)songMetadataForSearchItem:(waMediaItem *)item;
- (void)refreshVisibleLikeState;
- (void)layoutSearchChrome;
- (CGFloat)cachedWidthForFilterButton:(UIButton *)button;
- (void)filterButtonTapped:(UIButton *)button;
- (void)moreButtonTapped:(UIButton *)button;
- (void)selectSearchItem:(waMediaItem *)item context:(NSArray *)context;
- (BOOL)hasResults;
- (void)updateRecentsVisibility;
- (void)saveRecentQuery:(NSString *)query;
- (void)ensureFullResultsForMediaType:(NSInteger)type completion:(void (^)(void))completion;
- (void)publishSearchWaveWithFound:(NSMutableArray *)found allFound:(NSMutableArray *)allFound more:(NSMutableArray *)more limit:(NSUInteger)limit query:(NSString *)query;
- (void)runExactSecondPassForQuery:(NSString *)query tokens:(NSArray *)tokens artist:(waMediaItem *)artist generation:(NSUInteger)generation;
- (void)pushFullResultsForType:(NSInteger)type;
- (void)reloadOfflineItems;
- (BOOL)offlineItem:(waMediaItem *)item matchesQuery:(NSString *)query;
- (void)searchKeyboardWillShow:(NSNotification *)notification;
- (void)searchKeyboardWillHide:(NSNotification *)notification;
@end

static NSString *waSearchDurationString(NSTimeInterval duration) {
    if (!isfinite(duration) || duration < 0.0) return @"";
    NSUInteger total = (NSUInteger)duration;
    return [NSString stringWithFormat:@"%lu:%02lu", (unsigned long)(total / 60), (unsigned long)(total % 60)];
}

static waMediaItem *waSearchItemFromDownload(waDownload *download) {
    if (!download) return nil;
    waMediaItem *item = [waMediaItem itemWithDictionary:@{
        @"type": @"song",
        @"trackId": download.identifier ?: @"",
        @"title": download.title ?: @"Downloaded Song",
        @"artist": download.artist ?: @"",
        @"artistName": download.artist ?: @"",
        @"albumName": download.albumName ?: @"",
        @"thumbnailURL": download.thumbnailURL ?: @"",
        @"duration": @(download.duration),
        @"explicit": @(download.isExplicit)
    }];
    item.identifier = download.identifier;
    item.trackId = download.identifier;
    item.type = waMediaItemTypeSong;
    if (download.metadata) item.metadata = download.metadata;
    return item;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation waListViewController

- (void)applySearchBarStyle {
    BOOL modern = [waTheme isModernSystem];
    // Let UIKit draw the complete search control. Only reset properties that
    // were previously customized here; all text-field colors, fonts, borders,
    // placeholder and cancel-button styling remain native.
    self.searchBar.barStyle = UIBarStyleDefault;
    self.searchBar.translucent = modern;
    self.searchBar.tintColor = nil;
    self.searchBar.backgroundColor = [UIColor clearColor];
    self.searchBar.backgroundImage = nil;
    self.searchChrome.backgroundColor = [UIColor clearColor];
    if (modern && [self.searchBar respondsToSelector:NSSelectorFromString(@"setBarTintColor:")]) {
        @try { [self.searchBar setValue:nil forKey:@"barTintColor"]; } @catch (NSException *exception) { (void)exception; }
    }
    if (modern && [self.searchBar respondsToSelector:NSSelectorFromString(@"setSearchBarStyle:")]) {
        @try { [self.searchBar setValue:@(0) forKey:@"searchBarStyle"]; } @catch (NSException *exception) { (void)exception; }
    }
    [self applyInterFontToSearchSubviews:self.searchBar];
}

- (void)applyInterFontToSearchSubviews:(UIView *)view {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UITextField class]]) {
            ((UITextField *)subview).font = [waTheme secondaryRegularFontOfSize:16.0];
        }
        [self applyInterFontToSearchSubviews:subview];
    }
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:YES animated:YES];
    [self applyInterFontToSearchSubviews:searchBar];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [self searchBar:searchBar textDidChange:@""];
    [searchBar resignFirstResponder];
    [searchBar setShowsCancelButton:NO animated:YES];
}

- (id)init {
    if ((self = [super init])) self.title = @"Search";
    return self;
}

- (void)loadView {
    UIView *root = [[UIView alloc] initWithFrame:CGRectZero];
    root.backgroundColor = [waTheme backgroundColor];
    self.view = root;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.showsVerticalScrollIndicator = YES;
    [root addSubview:self.tableView];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.sections = @[@[], @[], @[], @[]];
    self.allSections = @[@[], @[], @[], @[]];
    self.hasMore = @[@NO, @NO, @NO, @NO];
    self.displaySections = @[];
    self.selectedFilter = waSearchFilterAll;

    self.searchChrome = [[UIView alloc] initWithFrame:CGRectZero];
    self.searchChrome.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.searchChrome];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Songs, albums and artists";
    if ([waTheme isModernSystem]) {
        // Native: search bar lives in nav bar, not custom chrome
        self.navigationItem.titleView = self.searchBar;
        self.searchChrome.hidden = YES;
    } else {
        [self.searchChrome addSubview:self.searchBar];
    }

    self.filterHeaderView = [[UIView alloc] initWithFrame:CGRectZero];
    self.filterHeaderView.backgroundColor = [UIColor clearColor];
    self.filterScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    self.filterScrollView.backgroundColor = [UIColor clearColor];
    self.filterScrollView.showsHorizontalScrollIndicator = NO;
    self.filterScrollView.alwaysBounceHorizontal = YES;
    [self.filterHeaderView addSubview:self.filterScrollView];
    self.tableView.tableHeaderView = self.filterHeaderView;
    NSArray *filterTitles = @[@"All", @"Offline", @"Tracks", @"Albums", @"Playlists", @"Artists"];
    NSMutableArray *buttons = [NSMutableArray arrayWithCapacity:filterTitles.count];
    for (NSUInteger index = 0; index < filterTitles.count; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = index;
        button.titleLabel.font = [waTheme boldFontOfSize:15.0];
        button.layer.cornerRadius = 18.0;
        button.layer.borderWidth = 1.25;
        button.layer.masksToBounds = YES;
        [button setTitle:filterTitles[index] forState:UIControlStateNormal];
        [button addTarget:self action:@selector(filterButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [buttons addObject:button];
        [self.filterScrollView addSubview:button];
    }
    self.filterButtons = buttons;
    [self updateFilterButtonAppearance];
    [self applySearchBarStyle];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.stateView = [[UIView alloc] initWithFrame:self.tableView.bounds];
    self.stateView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.stateView.backgroundColor = [waTheme backgroundColor];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.stateLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 85, self.view.bounds.size.width - 20, 40)];
    self.stateLabel.textAlignment = NSTextAlignmentCenter;
    self.stateLabel.textColor = [waTheme secondaryTextColor];
    self.stateLabel.backgroundColor = [UIColor clearColor];
    [self.stateView addSubview:self.stateLabel];
    self.stateIconView = [[UIImageView alloc] initWithImage:[waTheme tintedIcon:[UIImage imageNamed:@"tab-wave-home"] withColor:[waTheme barColor]]];
    self.stateIconView.alpha = 0.18;
    self.stateIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.stateIconView.backgroundColor = [UIColor clearColor];
    [self.stateView addSubview:self.stateIconView];
    self.tableView.backgroundView = self.stateView;
    self.loadingOverlay = [[UIView alloc] initWithFrame:CGRectZero];
    self.loadingOverlay.backgroundColor = [UIColor clearColor];
    self.loadingOverlay.userInteractionEnabled = NO;
    self.loadingOverlay.hidden = YES;
    self.spinnerBackdrop = [waTheme circularBackdropForSpinner:self.spinner];
    [self.loadingOverlay addSubview:self.spinnerBackdrop];
    [self.loadingOverlay bringSubviewToFront:self.spinnerBackdrop];
    [self.view addSubview:self.loadingOverlay];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard:)];
    tap.cancelsTouchesInView = NO;
    [self.tableView addGestureRecognizer:tap];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.55;
    [self.tableView addGestureRecognizer:longPress];
    self.stateLabel.text = nil;
    self.stateLabel.hidden = YES;
    self.stateIconView.hidden = NO;
    [self layoutStateIcon];
    [self layoutSearchChrome];
    [waTheme applyToView:self.view];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadStateDidChange:) name:waDownloadManagerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(searchKeyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(searchKeyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    NSArray *savedRecents = [[NSUserDefaults standardUserDefaults] objectForKey:@"waSearch.recentQueries"];
    self.recentQueries = [savedRecents isKindOfClass:[NSArray class]] ? [savedRecents mutableCopy] : [NSMutableArray array];
    [self updateRecentsVisibility];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mediaLikeDidChange:) name:waMediaLikeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
}

- (void)reloadDownloadTable {
    self.downloadReloadScheduled = NO;
    if (self.selectedFilter == waSearchFilterOffline) [self reloadOfflineItems];
    else if (self.view.window) [self.tableView reloadData];
}
- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.filterButtonWidths = nil;
    [self applySearchBarStyle];
    [self updateFilterButtonAppearance];
    if (self.view.window) [self.tableView reloadData];
}
- (void)downloadStateDidChange:(NSNotification *)notification {
    if (!self.view.window) return;
    if (self.selectedFilter == waSearchFilterOffline) {
        [self reloadOfflineItems];
        return;
    }
    if ([notification.userInfo[@"event"] isEqualToString:@"progress"]) {
        if (self.downloadReloadScheduled) return;
        self.downloadReloadScheduled = YES;
        [self performSelector:@selector(reloadDownloadTable) withObject:nil afterDelay:0.4];
    } else [self.tableView reloadData];
}

- (void)mediaLikeDidChange:(NSNotification *)notification {
    NSNumber *type = notification.userInfo[waMediaLikeTypeKey];
    NSString *identifier = notification.userInfo[waMediaLikeIdentifierKey];
    if (!identifier.length || ![notification.object isKindOfClass:[waMediaItem class]]) return;
    if (type && type.integerValue != [(waMediaItem *)notification.object type]) return;

    BOOL liked = [notification.object isLiked];
    NSArray *sourceArrays = @[self.allSections ?: @[], self.sections ?: @[]];
    for (NSArray *sections in sourceArrays) {
        for (NSArray *items in sections) {
            for (waMediaItem *item in items) {
                if ([item isKindOfClass:[waMediaItem class]] && [item.identifier isEqualToString:identifier]) item.liked = liked;
            }
        }
    }
    [self refreshVisibleLikeState];
}

- (void)refreshVisibleLikeState {
    // The model is already updated; refresh just the visible cells. A full
    // reloadData reconfigures every carousel too, resetting its scroll
    // position, and rebuilds the whole table on each like tap.
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
        if ([cell isKindOfClass:[waArtworkCell class]]) [(waArtworkCell *)cell refreshLikeState];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    BOOL modern = [waTheme isModernSystem];
    [self.navigationController setNavigationBarHidden:!modern animated:animated];
    if (modern) self.navigationItem.titleView = self.searchBar;
    [self applySearchBarStyle];
    [self updateFilterButtonAppearance];
    if (self.selectedFilter == waSearchFilterOffline) [self reloadOfflineItems];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Keep nav visible for other tabs (Home will hide its own)
    if (![waTheme isModernSystem]) [self.navigationController setNavigationBarHidden:NO animated:animated];
    [self.timer invalidate];
    self.timer = nil;
    self.searchGeneration += 1;
    [[waAPIClient sharedClient] cancelSearchRequests];
    [self setLoading:NO];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [self layoutSearchChrome];
    [self layoutLoadingOverlay];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // layoutSearchChrome already ran in viewWillLayoutSubviews. Re-styling
    // the search bar (a full subview traversal) matters only when the view
    // size actually changed: iOS 6 rebuilds the embedded field on resize.
    if (!CGSizeEqualToSize(self.view.bounds.size, self.lastStyledViewSize)) {
        self.lastStyledViewSize = self.view.bounds.size;
        [self applySearchBarStyle];
    }
    [self layoutStateIcon];
    [self layoutLoadingOverlay];
}

- (void)layoutSearchChrome {
    if (!self.searchChrome) return;
    CGFloat width = self.view.bounds.size.width;
    BOOL modern = [waTheme isModernSystem];
    CGFloat filterHeight = 40.0;
    CGRect previousHeaderFrame = self.filterHeaderView.frame;
    if (modern) {
        // Native nav bar owns the search field — no custom chrome
        self.searchChrome.hidden = YES;
        self.searchChrome.frame = CGRectZero;
        if (self.searchBar.superview != self.navigationItem.titleView) {
            self.navigationItem.titleView = self.searchBar;
        }
        // Ensure nav bar search field has enough width
        self.searchBar.frame = CGRectMake(0, 0, MIN(260, width - 32), 44);
    } else {
        self.searchChrome.hidden = NO;
        CGFloat top = [waTheme statusBarHeight];
        CGFloat chromeHeight = 50.0;
        self.searchChrome.frame = CGRectMake(0.0, top, width, chromeHeight);
        self.searchBar.frame = CGRectMake(12.0, 0.0, MAX(0.0, width - 24.0), 50.0);
        CGFloat tableTop = top + chromeHeight;
        self.tableView.frame = CGRectMake(0.0, tableTop, width, MAX(0.0, self.view.bounds.size.height - tableTop));
        self.filterHeaderView.frame = CGRectMake(0.0, 0.0, width, filterHeight);
        self.filterScrollView.frame = self.filterHeaderView.bounds;
        CGFloat x = 12.0;
        for (UIButton *button in self.filterButtons) {
            CGFloat buttonWidth = [self cachedWidthForFilterButton:button];
            button.layer.cornerRadius = 15.0;
            button.frame = CGRectMake(x, 5.0, buttonWidth, 30.0);
            x += buttonWidth + 8.0;
        }
        self.filterScrollView.contentSize = CGSizeMake(MAX(width + 1.0, x + 4.0), self.filterScrollView.bounds.size.height);
        if (self.tableView.tableHeaderView != self.filterHeaderView ||
            !CGSizeEqualToSize(previousHeaderFrame.size, self.filterHeaderView.frame.size)) {
            self.tableView.tableHeaderView = self.filterHeaderView;
        }
        return;
    }
    self.filterHeaderView.frame = CGRectMake(0.0, 0.0, width, filterHeight);
    self.filterScrollView.frame = self.filterHeaderView.bounds;
    CGFloat x = 12.0;
    for (UIButton *button in self.filterButtons) {
        CGFloat buttonWidth = [self cachedWidthForFilterButton:button];
        button.layer.cornerRadius = 15.0;
        button.frame = CGRectMake(x, 5.0, buttonWidth, 30.0);
        x += buttonWidth + 8.0;
    }
    self.filterScrollView.contentSize = CGSizeMake(MAX(width + 1.0, x + 4.0), self.filterScrollView.bounds.size.height);
    // Modern: table starts at 0, under nav bar handled by system insets
    self.tableView.frame = self.view.bounds;
    // UITableView caches tableHeaderView's height. Reassign it only when its
    // size changes so the first result row cannot slide underneath the pills.
    if (self.tableView.tableHeaderView != self.filterHeaderView ||
        !CGSizeEqualToSize(previousHeaderFrame.size, self.filterHeaderView.frame.size)) {
        self.tableView.tableHeaderView = self.filterHeaderView;
    }
}

- (CGFloat)cachedWidthForFilterButton:(UIButton *)button {
    // Measured once per title: layout runs on every rotation/keyboard pass
    // and sizeWithFont is not free on A4. Font and titles never change except
    // on theme changes, which clear the cache.
    NSString *title = button.titleLabel.text ?: @"";
    NSNumber *cached = self.filterButtonWidths[title];
    if (cached) return cached.doubleValue;
    CGFloat width = MAX(58.0, [title sizeWithFont:button.titleLabel.font].width + 28.0);
    if (!self.filterButtonWidths) self.filterButtonWidths = [NSMutableDictionary dictionary];
    self.filterButtonWidths[title] = @(width);
    return width;
}

- (void)updateFilterButtonAppearance {
    for (UIButton *button in self.filterButtons) {
        BOOL selected = button.tag == self.selectedFilter;
        button.backgroundColor = selected ? [waTheme barColor] : [UIColor clearColor];
        button.layer.borderColor = (selected ? [waTheme barColor] : [waTheme secondaryTextColor]).CGColor;
        [button setTitleColor:selected ? [UIColor whiteColor] : [waTheme secondaryTextColor] forState:UIControlStateNormal];
    }
}

- (void)filterButtonTapped:(UIButton *)button {
    if (button.tag == self.selectedFilter) return;
    self.selectedFilter = (waSearchFilter)button.tag;
    [self updateFilterButtonAppearance];
    if (self.selectedFilter == waSearchFilterOffline) {
        [self.timer invalidate];
        self.timer = nil;
        self.searchGeneration += 1;
        [[waAPIClient sharedClient] cancelSearchRequests];
        self.searchFailed = NO;
        [self reloadOfflineItems];
        [self.tableView setContentOffset:CGPointZero animated:NO];
        return;
    }
    [self rebuildDisplaySections];
    [self.tableView setContentOffset:CGPointZero animated:NO];
    [self.tableView reloadData];
    // Filtered tabs show the whole response, not the 5-item preview. If
    // the preview budget truncated this type, upgrade it to 50 now.
    if (self.selectedFilter != waSearchFilterAll) {
        NSInteger type = self.selectedFilter == waSearchFilterTracks ? waMediaItemTypeSong : (self.selectedFilter == waSearchFilterAlbums ? waMediaItemTypeAlbum : (self.selectedFilter == waSearchFilterPlaylists ? waMediaItemTypePlaylist : waMediaItemTypeArtist));
        __weak waListViewController *weakSelf = self;
        [self ensureFullResultsForMediaType:type completion:^{
            waListViewController *controller = weakSelf;
            if (!controller) return;
            [controller rebuildDisplaySections];
            if (controller.view.window) [controller.tableView reloadData];
        }];
    }
}

- (BOOL)offlineItem:(waMediaItem *)item matchesQuery:(NSString *)query {
    if (!item) return NO;
    NSString *normalizedQuery = [self normalizedSearchText:query ?: @""];
    if (!normalizedQuery.length) return YES;
    NSString *fields = [self normalizedSearchText:[NSString stringWithFormat:@"%@ %@ %@", item.title ?: @"", item.artistName ?: item.subtitle ?: @"", item.albumName ?: @""]];
    NSArray *tokens = [normalizedQuery componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *token in tokens) {
        if (token.length && [fields rangeOfString:token].location == NSNotFound) return NO;
    }
    return YES;
}

- (void)reloadOfflineItems {
    NSMutableArray *items = [NSMutableArray array];
    NSArray *downloads = [[waDownloadManager sharedManager] downloadsForCategory:waDownloadCategorySong];
    for (waDownload *download in downloads) {
        if (download.state != waDownloadStateCompleted) continue;
        NSString *path = [[waDownloadManager sharedManager] localPathForIdentifier:download.identifier];
        if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        waMediaItem *item = waSearchItemFromDownload(download);
        if ([self offlineItem:item matchesQuery:self.query]) [items addObject:item];
    }
    [items sortUsingComparator:^NSComparisonResult(waMediaItem *a, waMediaItem *b) {
        NSString *left = a.title ?: @"";
        NSString *right = b.title ?: @"";
        NSComparisonResult result = [left localizedCaseInsensitiveCompare:right];
        return result == NSOrderedSame ? [a.identifier compare:b.identifier] : result;
    }];
    self.offlineItems = items;
    self.showingRecents = NO;
    [self rebuildDisplaySections];
    [self setLoading:NO];
    BOOL empty = items.count == 0;
    self.stateLabel.text = empty ? (self.query.length ? @"No offline matches" : @"No downloaded songs") : @"";
    self.stateLabel.hidden = !empty;
    self.stateIconView.hidden = !empty;
    [self.tableView reloadData];
}

- (void)ensureFullResultsForMediaType:(NSInteger)type completion:(void (^)(void))completion {
    NSString *query = [self.query copy];
    BOOL truncated = type >= 0 && type < self.allSections.count &&
        [self.allSections[type] count] >= self.searchFetchLimit &&
        self.searchFetchLimit < 50 && [query isEqualToString:self.lastSearchedQuery];
    if (!truncated || !query.length) {
        if (completion) completion();
        return;
    }
    NSArray *types = @[@"song", @"album", @"artist", @"playlist"];
    if (type < 0 || type >= (NSInteger)types.count) {
        if (completion) completion();
        return;
    }
    NSUInteger generation = self.searchGeneration;
    [self setLoading:YES];
    __weak waListViewController *weakSelf = self;
    [[waAPIClient sharedClient] searchQuery:query type:types[type] limit:50 completion:^(NSArray *rows, NSError *error) {
        waListViewController *controller = weakSelf;
        if (!controller || generation != controller.searchGeneration || ![query isEqualToString:controller.query]) return;
        [controller setLoading:NO];
        if (!error && [rows isKindOfClass:[NSArray class]]) {
            NSMutableArray *items = [NSMutableArray array];
            for (NSDictionary *dictionary in rows) {
                if (![dictionary isKindOfClass:[NSDictionary class]]) continue;
                waMediaItem *item = [waMediaItem itemWithDictionary:dictionary];
                if (!item) continue;
                item.type = (waMediaItemType)type;
                [items addObject:item];
            }
            NSArray *reranked = [controller rankedSearchItems:items query:query type:type];
            NSMutableArray *allSections = [controller.allSections mutableCopy];
            allSections[type] = [reranked mutableCopy];
            controller.allSections = allSections;
            NSMutableArray *sections = [controller.sections mutableCopy];
            sections[type] = [[reranked subarrayWithRange:NSMakeRange(0, MIN(5, reranked.count))] mutableCopy];
            controller.sections = sections;
            NSMutableArray *more = [controller.hasMore mutableCopy];
            if (type < (NSInteger)more.count) more[type] = @(reranked.count > 5);
            controller.hasMore = more;
        }
        if (completion) completion();
    }];
}

- (void)pushFullResultsForType:(NSInteger)type {
    if (type < 0 || type >= self.allSections.count) return;
    NSString *title = @[@"Tracks", @"Albums", @"Artists", @"Playlists"][type];
    __weak waListViewController *weakSelf = self;
    [self ensureFullResultsForMediaType:type completion:^{
        waListViewController *controller = weakSelf;
        if (!controller || type >= controller.allSections.count) return;
        NSArray *items = controller.allSections[type];
        if (!items.count) return;
        NSString *query = [controller.query copy];
        waMediaResultsViewController *results = [[waMediaResultsViewController alloc] initWithItems:items type:(waMediaItemType)type title:title query:query];
        [controller.navigationController pushViewController:results animated:YES];
    }];
}

- (void)moreButtonTapped:(UIButton *)button {
    NSInteger type = button.tag;
    if (type < waMediaItemTypeSong || type > waMediaItemTypePlaylist || type >= self.allSections.count) return;
    NSArray *items = self.allSections[type];
    if (!items.count) return;
    [self pushFullResultsForType:type];
}

- (void)layoutStateIcon {
    if (!self.stateIconView) return;
    CGFloat size = MIN(88.0, MAX(60.0, MIN(self.stateView.bounds.size.width, self.stateView.bounds.size.height) * 0.18));
    self.stateIconView.frame = CGRectMake((self.stateView.bounds.size.width - size) / 2.0, (self.stateView.bounds.size.height - size) / 2.0 - 12.0, size, size);
}

- (void)layoutLoadingOverlay {
    if (!self.loadingOverlay.superview) return;
    CGRect frame = [self.view convertRect:self.tableView.bounds fromView:self.tableView];
    self.loadingOverlay.frame = frame;
    self.spinnerBackdrop.center = CGPointMake(CGRectGetMidX(self.loadingOverlay.bounds), CGRectGetMidY(self.loadingOverlay.bounds));
}

- (void)setLoading:(BOOL)loading {
    self.loadingOverlay.hidden = !loading;
    if (loading) {
        [self layoutLoadingOverlay];
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }
}

- (void)dismissKeyboard:(id)sender {
    (void)sender;
    if ([self.searchBar isFirstResponder]) {
        [self.searchBar resignFirstResponder];
        return;
    }
    // Tap on the empty/error state retries a failed search.
    if (self.searchFailed && self.query.length >= 2) [self beginSearch:nil];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (self.showingRecents) return;
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:[gesture locationInView:self.tableView]];
    if (!path) return;
    if (path.section >= self.displaySections.count) return;
    if ([self isStaticTitleRow:path]) return;
    NSInteger displaySection = [self.displaySections[path.section] integerValue];
    if ([self isHorizontalDisplaySection:path.section]) return;
    NSArray *items = [self itemsForDisplaySection:path.section];
    BOOL hasStaticTitle = self.selectedFilter == waSearchFilterAll && displaySection == waSearchDisplayTracks;
    NSUInteger itemRow = hasStaticTitle ? path.row - 1 : path.row;
    if (itemRow >= items.count) return;
    waMediaItem *item = items[itemRow];
    if (item.type == waMediaItemTypeSong || item.type == waMediaItemTypeAlbum || item.type == waMediaItemTypePlaylist) [waMediaActionSheet presentForItem:item inViewController:self albumItems:nil];
}

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text {
    // No per-keystroke restyle: the embedded field is styled on
    // beginEditing/resize, and iOS 6 does not rebuild it while typing.
    [self.timer invalidate];
    self.query = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (self.selectedFilter == waSearchFilterOffline) {
        [[waAPIClient sharedClient] cancelSearchRequests];
        self.searchGeneration += 1;
        self.lastSearchedQuery = nil;
        self.searchFailed = NO;
        [self reloadOfflineItems];
        return;
    }
    // Single characters only produce noise against the Deezer index and
    // burn 4 requests per keystroke. Wait for a real prefix.
    if (self.query.length < 2) {
        [[waAPIClient sharedClient] cancelSearchRequests];
        self.searchGeneration += 1;
        self.lastSearchedQuery = nil;
        self.searchFailed = NO;
        self.sections = @[@[], @[], @[], @[]];
        self.allSections = @[@[], @[], @[], @[]];
        self.hasMore = @[@NO, @NO, @NO, @NO];
        [self rebuildDisplaySections];
        [self setLoading:NO];
        [self updateRecentsVisibility];
        if (self.query.length) {
            self.stateLabel.text = nil;
            self.stateLabel.hidden = YES;
            self.stateIconView.hidden = NO;
        }
        [self.tableView reloadData];
        return;
    }
    // Invalidate and hide results from the previous query immediately. The
    // older requests may still complete, but their generation is now stale.
    self.searchGeneration += 1;
    self.showingRecents = NO;
    self.sections = @[@[], @[], @[], @[]];
    self.allSections = @[@[], @[], @[], @[]];
    self.hasMore = @[@NO, @NO, @NO, @NO];
    [self rebuildDisplaySections];
    self.stateLabel.text = @"";
    self.stateLabel.hidden = YES;
    self.stateIconView.hidden = YES;
    [self setLoading:NO];
    [self.tableView reloadData];
    // Search only after the user has paused typing. A shorter interval fired
    // between normal keystrokes and produced unnecessary network requests.
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.75 target:self selector:@selector(beginSearch:) userInfo:nil repeats:NO];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)bar {
    [self.timer invalidate];
    self.timer = nil;
    self.query = [bar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [bar resignFirstResponder];
    [bar setShowsCancelButton:NO animated:YES];
    // Explicit user action bypasses the identical-query guard.
    self.lastSearchedQuery = nil;
    if (self.query.length) [self beginSearch:nil];
}

- (void)beginSearch:(id)sender {
    self.timer = nil;
    if (self.selectedFilter == waSearchFilterOffline) {
        [self reloadOfflineItems];
        return;
    }
    NSString *query = [self.query copy];
    if (query.length < 2) return;
    // Same text with live results: nothing to do (Search button clears
    // the guard explicitly, so manual retries still work).
    if ([query isEqualToString:self.lastSearchedQuery] && [self hasResults]) return;
    self.showingRecents = NO;
    // Revoke the previous keystroke's requests: their completions are
    // dropped and never burn parse time on the A4.
    [[waAPIClient sharedClient] cancelSearchRequests];
    NSUInteger generation = ++self.searchGeneration;
    self.searchFailed = NO;
    [self setLoading:YES];
    // Preview budget: only 5 items per section are shown in All, so fetch
    // 8 per type here. Filter tabs and "more" upgrade to 50 on demand
    // (see ensureFullResultsForMediaType:).
    NSUInteger limit = 8;
    self.searchFetchLimit = limit;
    NSString *normalized = [self normalizedSearchText:query];
    NSArray *rawTokens = [normalized componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *token in rawTokens) if (token.length) [tokens addObject:token];
    NSMutableArray *found = [NSMutableArray arrayWithObjects:[NSMutableArray array], [NSMutableArray array], [NSMutableArray array], [NSMutableArray array], nil];
    NSMutableArray *allFound = [NSMutableArray arrayWithObjects:[NSMutableArray array], [NSMutableArray array], [NSMutableArray array], [NSMutableArray array], nil];
    NSMutableArray *more = [NSMutableArray arrayWithObjects:@NO, @NO, @NO, @NO, nil];
    __block NSInteger pending = 4;
    __block BOOL failed = NO;
    __block BOOL songDone = NO;
    __block BOOL artistDone = NO;
    __block BOOL firstWaveRendered = NO;
    NSArray *types = @[@"song", @"album", @"artist", @"playlist"];
    for (NSInteger section = 0; section < 4; section++) {
        [[waAPIClient sharedClient] searchQuery:query type:types[section] limit:limit completion:^(NSArray *rows, NSError *error) {
            if (generation != self.searchGeneration || ![query isEqualToString:self.query]) return;
            if (section == waMediaItemTypeSong) songDone = YES;
            else if (section == waMediaItemTypeArtist) artistDone = YES;
            if (error) failed = YES;
            if ([rows isKindOfClass:[NSArray class]]) {
                for (NSDictionary *dictionary in rows) {
                    if (![dictionary isKindOfClass:[NSDictionary class]]) continue;
                    waMediaItem *item = [waMediaItem itemWithDictionary:dictionary];
                    if (!item) continue;
                    item.type = (waMediaItemType)section;
                    [allFound[section] addObject:item];
                }
            }
            pending--;
            // Wave 1: songs + artists land first and paint immediately while
            // albums are still in flight. The spinner stays until the end.
            if (songDone && artistDone && !firstWaveRendered && pending > 0) {
                firstWaveRendered = YES;
                [self publishSearchWaveWithFound:found allFound:allFound more:more limit:limit query:query];
            }
            if (!pending) {
                [self publishSearchWaveWithFound:found allFound:allFound more:more limit:limit query:query];
                // Deezer's album search never returns the searched album for
                // "artist + title" queries ("adele 19" omits the album "19").
                // The best artist's discography does contain it — merge it.
                waMediaItem *bestArtist = [self bestArtistForQuery:query artists:allFound[waMediaItemTypeArtist]];
                if (bestArtist.identifier.length) [self mergeArtistDiscographyForArtist:bestArtist query:query generation:generation];
                // Qualified + strict second wave for "artist + title" queries,
                // anchored on the matched artist (not token position).
                if (tokens.count >= 2) [self runExactSecondPassForQuery:query tokens:tokens artist:bestArtist generation:generation];
                // Keep the first five items for the compact All view, but
                // retain the complete response for every filtered tab.
                self.lastSearchedQuery = query;
                self.searchFailed = failed && ![self hasResults];
                if (!failed && [self hasResults]) [self saveRecentQuery:query];
                [[waDebugLog sharedLog] log:@"Search done: '%@' tracks=%lu albums=%lu artists=%lu playlists=%lu failed=%d", query, (unsigned long)[allFound[0] count], (unsigned long)[allFound[1] count], (unsigned long)[allFound[2] count], (unsigned long)[allFound[3] count], failed];
                [self rebuildDisplaySections];
                [self setLoading:NO];
                self.stateLabel.text = [self hasResults] ? @"" : (failed ? @"Search unavailable — tap to retry" : @"No results");
                self.stateLabel.hidden = self.stateLabel.text.length == 0;
                self.stateIconView.hidden = YES;
                [self.tableView reloadData];
            }
        }];
    }
}

- (void)publishSearchWaveWithFound:(NSMutableArray *)found allFound:(NSMutableArray *)allFound more:(NSMutableArray *)more limit:(NSUInteger)limit query:(NSString *)query {
    // Client re-rank: fuzzy API order buries exact artist+album
    // hits (e.g. "adele 19" -> Angele). Boost text matches first,
    // Deezer rank only tie-breaks, before truncating to five.
    for (NSInteger rankSection = 0; rankSection < 4; rankSection++) {
        NSArray *reranked = [self rankedSearchItems:allFound[rankSection] query:query type:rankSection];
        allFound[rankSection] = [reranked mutableCopy];
        // A full page means the server may hold more: the filter
        // tab and "more" then upgrade this type to limit 50.
        more[rankSection] = @([allFound[rankSection] count] > 5 || ([allFound[rankSection] count] >= limit && limit < 50));
        found[rankSection] = [[reranked subarrayWithRange:NSMakeRange(0, MIN(5, reranked.count))] mutableCopy];
    }
    self.sections = found;
    self.allSections = allFound;
    self.hasMore = more;
    [self rebuildDisplaySections];
    if (self.view.window) [self.tableView reloadData];
}

- (void)runExactSecondPassForQuery:(NSString *)query tokens:(NSArray *)tokens artist:(waMediaItem *)artist generation:(NSUInteger)generation {
    // Qualified + strict second wave, anchored on the matched artist name:
    // subtract the artist's own words from the query, what remains is the
    // title tail ("Adele 19" -> artist "adele" + "19"; "Pink Floyd Wish" ->
    // artist "pink floyd" + "wish"). Pure artist queries ("The Beatles")
    // leave no tail and are skipped: plain results already rule there.
    // Additive only — misses change nothing on screen.
    if (tokens.count < 2) return;
    NSString *artistName = [self normalizedSearchText:artist.title];
    if (!artistName.length) return;
    NSMutableArray *remaining = [tokens mutableCopy];
    for (NSString *word in [artistName componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (!word.length) continue;
        NSUInteger idx = [remaining indexOfObject:word];
        if (idx != NSNotFound) [remaining removeObjectAtIndex:idx];
    }
    if (!remaining.count) return;
    NSString *tail = [remaining componentsJoinedByString:@" "];
    NSCharacterSet *quoteSet = [NSCharacterSet characterSetWithCharactersInString:@"\""];
    NSString *artistPart = [[artistName componentsSeparatedByCharactersInSet:quoteSet] componentsJoinedByString:@""];
    tail = [[tail componentsSeparatedByCharactersInSet:quoteSet] componentsJoinedByString:@""];
    if (!artistPart.length || !tail.length) return;
    NSArray *specs = @[
        @{ @"q": [NSString stringWithFormat:@"artist:\"%@\" track:\"%@\"", artistPart, tail], @"type": @"song", @"section": @(waMediaItemTypeSong) },
        @{ @"q": [NSString stringWithFormat:@"artist:\"%@\" album:\"%@\"", artistPart, tail], @"type": @"album", @"section": @(waMediaItemTypeAlbum) }
    ];
    __weak waListViewController *weakSelf = self;
    for (NSDictionary *spec in specs) {
        NSString *exactQuery = spec[@"q"];
        NSString *exactType = spec[@"type"];
        NSInteger section = [spec[@"section"] integerValue];
        [[waAPIClient sharedClient] searchQuery:exactQuery type:exactType limit:10 index:0 strict:YES completion:^(NSArray *rows, NSError *error) {
            waListViewController *controller = weakSelf;
            if (!controller || error || ![rows isKindOfClass:[NSArray class]] || !rows.count) return;
            if (generation != controller.searchGeneration || ![query isEqualToString:controller.query]) return;
            NSMutableSet *known = [NSMutableSet set];
            for (waMediaItem *existing in controller.allSections[section]) {
                NSString *key = existing.trackId.length ? existing.trackId : existing.identifier;
                if (key.length) [known addObject:key];
            }
            NSMutableArray *extras = [NSMutableArray array];
            for (NSDictionary *dictionary in rows) {
                if (![dictionary isKindOfClass:[NSDictionary class]]) continue;
                waMediaItem *item = [waMediaItem itemWithDictionary:dictionary];
                if (!item) continue;
                item.type = (waMediaItemType)section;
                NSString *key = item.trackId.length ? item.trackId : item.identifier;
                if (key.length && [known containsObject:key]) continue;
                if (key.length) [known addObject:key];
                [extras addObject:item];
            }
            if (!extras.count) return;
            NSMutableArray *merged = [controller.allSections[section] mutableCopy] ?: [NSMutableArray array];
            [merged addObjectsFromArray:extras];
            NSArray *reranked = [controller rankedSearchItems:merged query:query type:section];
            NSMutableArray *allSections = [controller.allSections mutableCopy];
            allSections[section] = [reranked mutableCopy];
            controller.allSections = allSections;
            NSMutableArray *sections = [controller.sections mutableCopy];
            sections[section] = [[reranked subarrayWithRange:NSMakeRange(0, MIN(5, reranked.count))] mutableCopy];
            controller.sections = sections;
            NSMutableArray *more = [controller.hasMore mutableCopy];
            more[section] = @(reranked.count > 5);
            controller.hasMore = more;
            [controller rebuildDisplaySections];
            if (controller.view.window) [controller.tableView reloadData];
        }];
    }
}

- (BOOL)isStaticTitleRow:(NSIndexPath *)path {
    if (self.selectedFilter != waSearchFilterAll || path.section >= self.displaySections.count || path.row != 0) return NO;
    NSInteger displaySection = [self.displaySections[path.section] integerValue];
    return displaySection == waSearchDisplayTracks;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    if (self.showingRecents) return 1;
    return self.displaySections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (self.showingRecents) return self.recentQueries.count + 1;
    if (section >= self.displaySections.count) return 0;
    NSInteger displaySection = [self.displaySections[section] integerValue];
    if (displaySection == waSearchDisplayTracks && self.selectedFilter == waSearchFilterAll) return [self itemsForDisplaySection:section].count + 1;
    return [self isHorizontalDisplaySection:section] ? 1 : [self itemsForDisplaySection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView;
    UIView *spacer = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, self.tableView.bounds.size.width, 1.0)];
    spacer.backgroundColor = [UIColor clearColor];
    return spacer;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return 1.0;
}

- (NSString *)subtitleForSearchItem:(waMediaItem *)item {
    if (!item) return @"";
    NSString *artist = item.artistName.length ? item.artistName : item.subtitle;
    if (item.type == waMediaItemTypeSong && item.albumName.length && artist.length) return [NSString stringWithFormat:@"%@  •  %@", artist, item.albumName];
    if (item.type == waMediaItemTypeArtist) {
        id fans = item.metadata[@"fans"] ?: item.metadata[@"fansCount"] ?: item.metadata[@"nbFans"];
        if ([fans respondsToSelector:@selector(stringValue)]) return [NSString stringWithFormat:@"%@ fans", [fans stringValue]];
        if (artist.length && (!item.title.length || [artist caseInsensitiveCompare:item.title] != NSOrderedSame)) return artist;
        return @"";
    }
    if (item.type == waMediaItemTypePlaylist && artist.length) return [artist hasPrefix:@"by "] ? artist : [NSString stringWithFormat:@"by %@", artist];
    return artist ?: @"";
}

- (NSString *)songMetadataForSearchItem:(waMediaItem *)item {
    if (!item) return @"";
    NSString *artist = item.artistName.length ? item.artistName : (item.subtitle.length ? item.subtitle : @"Unknown artist");
    NSString *album = item.albumName.length ? item.albumName : @"Unknown album";
    NSString *duration = waSearchDurationString(item.duration);
    if (duration.length) album = [album stringByAppendingFormat:@" • %@", duration];
    return [NSString stringWithFormat:@"%@\n%@", artist, album];
}

- (void)updateRecentsVisibility {
    BOOL empty = self.query.length == 0;
    self.showingRecents = empty && self.recentQueries.count > 0;
    if (!empty) return;
    if (self.showingRecents) {
        self.stateLabel.text = nil;
        self.stateLabel.hidden = YES;
        self.stateIconView.hidden = YES;
    } else {
        self.stateLabel.text = @"Try an artist and album, e.g. adele 19";
        self.stateLabel.hidden = NO;
        self.stateIconView.hidden = NO;
    }
}

- (void)saveRecentQuery:(NSString *)query {
    if (!query.length) return;
    if (!self.recentQueries) self.recentQueries = [NSMutableArray array];
    [self.recentQueries removeObject:query];
    [self.recentQueries insertObject:query atIndex:0];
    while (self.recentQueries.count > 10) [self.recentQueries removeLastObject];
    [[NSUserDefaults standardUserDefaults] setObject:[self.recentQueries copy] forKey:@"waSearch.recentQueries"];
}

- (void)searchKeyboardWillShow:(NSNotification *)notification {
    CGRect frame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    frame = [self.view convertRect:frame fromView:self.view.window];
    CGFloat overlap = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(frame);
    if (overlap < 0.0 || !isfinite(overlap)) overlap = 0.0;
    UIEdgeInsets content = self.tableView.contentInset;
    content.bottom = overlap;
    self.tableView.contentInset = content;
    UIEdgeInsets indicators = self.tableView.scrollIndicatorInsets;
    indicators.bottom = overlap;
    self.tableView.scrollIndicatorInsets = indicators;
}

- (void)searchKeyboardWillHide:(NSNotification *)notification {
    (void)notification;
    UIEdgeInsets content = self.tableView.contentInset;
    content.bottom = 0.0;
    self.tableView.contentInset = content;
    UIEdgeInsets indicators = self.tableView.scrollIndicatorInsets;
    indicators.bottom = 0.0;
    self.tableView.scrollIndicatorInsets = indicators;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if (self.showingRecents) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"search-recent"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"search-recent"];
            cell.backgroundColor = [waTheme backgroundColor];
            cell.textLabel.font = [waTheme regularFontOfSize:16.0];
            UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
            selected.backgroundColor = [waTheme selectedSurfaceColor];
            cell.selectedBackgroundView = selected;
        }
        cell.backgroundColor = [waTheme backgroundColor];
        cell.imageView.image = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        if (path.row >= (NSInteger)self.recentQueries.count) {
            cell.textLabel.text = @"Clear recent searches";
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.textColor = [waTheme secondaryTextColor];
        } else {
            cell.textLabel.text = self.recentQueries[path.row];
            cell.textLabel.textAlignment = NSTextAlignmentLeft;
            cell.textLabel.textColor = [waTheme primaryTextColor];
        }
        return cell;
    }
    if (path.section >= self.displaySections.count) return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSInteger displaySection = [self.displaySections[path.section] integerValue];
    if ([self isStaticTitleRow:path]) {
        waSearchSectionTitleCell *cell = [tableView dequeueReusableCellWithIdentifier:@"search-section-title"];
        if (!cell) cell = [[waSearchSectionTitleCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"search-section-title"];
        [cell configureWithTitle:[self titleForDisplaySection:path.section]];
        return cell;
    }

    if ([self isHorizontalDisplaySection:path.section]) {
        waHomeSectionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"search-home-section"];
        if (!cell) cell = [[waHomeSectionCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"search-home-section"];
        NSInteger type = [self mediaTypeForDisplaySection:path.section];
        NSArray *items = [self itemsForDisplaySection:path.section];
        NSString *title = [self titleForDisplaySection:path.section];
        NSString *layout = type == waMediaItemTypeArtist ? @"circle" : @"square";
        // The All view is a compact preview; the filter pills are the way to
        // open a complete result set, so do not show trailing chevrons here.
        BOOL showsMore = NO;
        NSDictionary *section = @{ @"title": title, @"subtitle": @"", @"layout": layout, @"items": items, @"showsMore": @(showsMore) };
        __weak waListViewController *weakSelf = self;
        cell.sectionView.compact = YES;
        [cell.sectionView resetScrollPosition];
        [cell.sectionView configureWithSection:section selection:^(waMediaItem *item, NSArray *context) {
            waListViewController *controller = weakSelf;
            if (controller) [controller selectSearchItem:item context:context];
        }];
        if (type < self.hasMore.count && [self.hasMore[type] boolValue]) {
            cell.sectionView.moreAction = ^{
                waListViewController *controller = weakSelf;
                if (controller) [controller pushFullResultsForType:type];
            };
        } else {
            cell.sectionView.moreAction = nil;
        }
        cell.sectionView.longPress = ^(waMediaItem *item, NSArray *context) {
            waListViewController *controller = weakSelf;
            if (controller) [waMediaActionSheet presentForItem:item inViewController:controller albumItems:type == waMediaItemTypeAlbum ? context : nil];
        };
        return cell;
    }

    NSArray *items = [self itemsForDisplaySection:path.section];
    BOOL hasStaticTitle = self.selectedFilter == waSearchFilterAll && displaySection == waSearchDisplayTracks;
    NSUInteger itemRow = hasStaticTitle ? path.row - 1 : path.row;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"search-list"];
    if (!cell) {
        cell = [[waArtworkCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"search-list"];
        // Flat full-width rows: style once here, never walk the subtree per row.
        ((waArtworkCell *)cell).cardStyle = NO;
        cell.backgroundColor = [waTheme backgroundColor];
        UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
        selected.backgroundColor = [waTheme selectedSurfaceColor];
        cell.selectedBackgroundView = selected;
    }
    waArtworkCell *artworkCell = (waArtworkCell *)cell;
    artworkCell.cardStyle = NO;
    artworkCell.circleArtwork = [self.displaySections[path.section] integerValue] == waSearchDisplayArtists;
    artworkCell.multilineDetail = displaySection == waSearchDisplayTracks;
    [artworkCell setLikeItem:nil];
    [artworkCell setExplicit:NO];
    [artworkCell setGeniusRecommended:NO];
    [artworkCell setDownloadState:waDownloadStateNotFound progress:0.0f];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = waPlaceholderImage();
    cell.backgroundColor = [waTheme backgroundColor];
    cell.textLabel.textColor = [waTheme primaryTextColor];
    cell.detailTextLabel.textColor = [waTheme secondaryTextColor];
    if (itemRow >= items.count) return cell;
    waMediaItem *item = items[itemRow];
    cell.textLabel.text = item.title ?: @"";
    cell.detailTextLabel.text = item.type == waMediaItemTypeSong ? [self songMetadataForSearchItem:item] : [self subtitleForSearchItem:item];
    [artworkCell setLikeItem:item];
    [artworkCell setExplicit:item.isExplicit];
    NSString *downloadIdentifier = item.trackId.length ? item.trackId : item.identifier;
    waDownload *download = item.type == waMediaItemTypeSong ? [[waDownloadManager sharedManager] downloadForIdentifier:downloadIdentifier] : nil;
    [artworkCell setDownloadState:download ? download.state : waDownloadStateNotFound progress:download.progress];
    if (item.thumbnailURL.length) {
        NSString *expectedURL = [item.thumbnailURL copy];
        [[waImageLoader sharedLoader] loadThumbnailAtURL:expectedURL targetSize:CGSizeMake(112.0, 112.0) placeholder:waPlaceholderImage() completion:^(UIImage *image) {
            NSArray *currentItems = path.section < self.displaySections.count ? [self itemsForDisplaySection:path.section] : nil;
            waMediaItem *current = itemRow < currentItems.count ? currentItems[itemRow] : nil;
            NSIndexPath *currentPath = [tableView indexPathForCell:cell];
            if (current == item && [current.thumbnailURL isEqualToString:expectedURL] && [currentPath isEqual:path] && image) cell.imageView.image = image;
        }];
    }
    return cell;
}

- (CGFloat)heightForHorizontalSection:(NSInteger)section {
    return section == waMediaItemTypeArtist ? 230.0 : 295.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    (void)tableView;
    if (self.showingRecents) return 44.0;
    if (path.section >= self.displaySections.count) return 0.0;
    if ([self isStaticTitleRow:path]) return 38.0;
    NSInteger displaySection = [self.displaySections[path.section] integerValue];
    if ([self isHorizontalDisplaySection:path.section]) return [self heightForHorizontalSection:[self mediaTypeForDisplaySection:path.section]];
    return displaySection == waSearchDisplayTracks ? 68.0 : 58.0;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [self dismissKeyboard:nil];
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (self.showingRecents) {
        if (path.row >= (NSInteger)self.recentQueries.count) {
            [self.recentQueries removeAllObjects];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"waSearch.recentQueries"];
            [self updateRecentsVisibility];
            [tableView reloadData];
            return;
        }
        NSString *recent = self.recentQueries[path.row];
        if (!recent.length) return;
        self.searchBar.text = recent;
        self.query = recent;
        [self.searchBar setShowsCancelButton:NO animated:YES];
        [self beginSearch:nil];
        return;
    }
    if (path.section >= self.displaySections.count) return;
    if ([self isStaticTitleRow:path]) return;
    NSInteger displaySection = [self.displaySections[path.section] integerValue];
    if ([self isHorizontalDisplaySection:path.section]) return;
    NSArray *items = [self itemsForDisplaySection:path.section];
    BOOL hasStaticTitle = self.selectedFilter == waSearchFilterAll && displaySection == waSearchDisplayTracks;
    NSUInteger itemRow = hasStaticTitle ? path.row - 1 : path.row;
    if (itemRow >= items.count) return;
    waMediaItem *item = items[itemRow];
    [self selectSearchItem:item context:items];
}

- (void)selectSearchItem:(waMediaItem *)item context:(NSArray *)context {
    if (!item) return;
    if (item.type == waMediaItemTypeSong) {
        // A direct track selection starts a single-item queue. Genius then
        // owns the continuation instead of using the search results context.
        [[waAudioPlayer sharedPlayer] playItem:item];
    } else if (item.type == waMediaItemTypePlaylist) {
        NSDictionary *playlist = @{ @"id": item.identifier ?: @"", @"title": item.title ?: @"Playlist", @"name": item.title ?: @"Playlist", @"description": @"", @"thumbnailURL": item.thumbnailURL ?: @"", @"artwork": item.thumbnailURL ?: @"", @"liked": @(item.isLiked) };
        [self.navigationController pushViewController:[[waPlaylistViewController alloc] initWithPlaylist:playlist ownerIsCurrentUser:NO] animated:YES];
    } else {
        [self.navigationController pushViewController:[[waMediaDetailViewController alloc] initWithMediaItem:item] animated:YES];
    }
}
- (void)dealloc { [self.timer invalidate]; [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
#pragma clang diagnostic pop
