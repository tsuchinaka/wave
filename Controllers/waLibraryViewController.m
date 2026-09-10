#import "waLibraryViewController.h"
#import "../Services/waAPIClient.h"
#import "../Services/waTheme.h"
#import "../Services/waAudioPlayer.h"
#import "../Services/waImageLoader.h"
#import "../Views/waHomeSectionView.h"
#import "../Views/waArtworkCell.h"
#import "../Views/waEmptyView.h"
#import "../Views/waSegmentedControl.h"
#import "../Views/waMediaActionSheet.h"
#import "../Views/waPlaceholder.h"
#import "waMediaDetailViewController.h"
#import "waPlaylistViewController.h"
#import "waLikedSongsViewController.h"
#import "waDownloadsViewController.h"
#import "waDeezerLoginViewController.h"
#import "../Models/waMediaItem.h"

typedef NS_ENUM(NSInteger, waLibraryFilter) {
    waLibraryFilterAll = 0,
    waLibraryFilterTracks,
    waLibraryFilterAlbums,
    waLibraryFilterArtists,
    waLibraryFilterPlaylists
};

static const NSInteger waCreatePlaylistAlertTag = 101;

@interface waLibraryViewController () <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIView *filterBar;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) waSegmentedControl *segmentedControl;
@property (nonatomic, strong) UIView *shortcutsContainer;
@property (nonatomic, strong) NSMutableArray *shortcutButtons;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, strong) UITableView *resultsTableView;
@property (nonatomic, strong) waEmptyView *emptyView;
@property (nonatomic, strong) NSMutableArray *shelves;
@property (nonatomic, strong) NSArray *albums;
@property (nonatomic, strong) NSArray *artists;
@property (nonatomic, strong) NSArray *playlists;
@property (nonatomic, strong) NSArray *songs;
@property (nonatomic, assign) BOOL songsLoaded;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) NSUInteger loadGeneration;
@property (nonatomic, strong) NSArray *filteredItems;
@end

@implementation waLibraryViewController

- (id)init {
    if ((self = [super init])) {
        _albums = @[];
        _artists = @[];
        _playlists = @[];
        _songs = @[];
        _shelves = [NSMutableArray array];
        _shortcutButtons = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Library";
    self.view.backgroundColor = [waTheme backgroundColor];

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.backgroundColor = [waTheme backgroundColor];
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];

    self.refreshControl = [[UIRefreshControl alloc] init];
    self.refreshControl.tintColor = [waTheme barColor];
    [self.refreshControl addTarget:self action:@selector(loadLibrary) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.refreshControl];

    // Filter bar: search field + category segmented control.
    self.filterBar = [[UIView alloc] initWithFrame:CGRectZero];
    self.filterBar.backgroundColor = [waTheme backgroundColor];
    [self.view addSubview:self.filterBar];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search your library";
    // Keep the idle search field full-width. Showing the cancel button before
    // editing reserves its width on iOS 6/7 even when the button is not drawn.
    self.searchBar.showsCancelButton = NO;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    [self.filterBar addSubview:self.searchBar];

    self.segmentedControl = [[waSegmentedControl alloc] initWithItems:@[@"All", @"Tracks", @"Albums", @"Artists", @"Playlists"]];
    self.segmentedControl.selectedSegmentIndex = waLibraryFilterAll;
    [self.segmentedControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    [self.filterBar addSubview:self.segmentedControl];

    // Shortcut buttons (Liked Songs / Downloads / New Playlist).
    self.shortcutsContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.shortcutsContainer.backgroundColor = [UIColor clearColor];
    [self.scrollView addSubview:self.shortcutsContainer];
    [self buildShortcuts];

    // Results table (used while filtering).
    self.resultsTableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.resultsTableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.resultsTableView.delegate = self;
    self.resultsTableView.dataSource = self;
    self.resultsTableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.resultsTableView.separatorColor = [waTheme separatorColor];
    self.resultsTableView.backgroundColor = [waTheme backgroundColor];
    self.resultsTableView.showsVerticalScrollIndicator = NO;
    self.resultsTableView.hidden = YES;
    UIView *tableBackground = [[UIView alloc] initWithFrame:CGRectZero];
    tableBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableBackground.backgroundColor = [waTheme backgroundColor];
    self.resultsTableView.backgroundView = tableBackground;
    [self.view addSubview:self.resultsTableView];

    self.emptyView = [[waEmptyView alloc] initWithFrame:self.view.bounds];
    self.emptyView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.emptyView.hidden = YES;
    [self.view addSubview:self.emptyView];

    [self applyTheme];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    [self applyTheme];
    if (![[waAPIClient sharedClient] isAuthenticated]) {
        [self showAuthRequired];
        return;
    }
    if (self.albums.count == 0 && self.artists.count == 0 && self.playlists.count == 0) {
        [self loadLibrary];
    } else {
        [self updateContent];
    }
}

#pragma mark - Shortcuts

- (void)buildShortcuts {
    NSArray *defs = @[
        @{@"title": @"♥ Liked Songs", @"action": NSStringFromSelector(@selector(showLikedSongs))},
        @{@"title": @"↓ Downloads", @"action": NSStringFromSelector(@selector(showDownloads))},
        @{@"title": @"+ New Playlist", @"action": NSStringFromSelector(@selector(createPlaylist))},
    ];
    for (NSDictionary *def in defs) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        [button setTitle:def[@"title"] forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.titleLabel.font = [waTheme mediumFontOfSize:14.0];
        button.backgroundColor = [waTheme barColor];
        button.layer.cornerRadius = 8.0;
        button.clipsToBounds = YES;
        [button addTarget:self action:NSSelectorFromString(def[@"action"]) forControlEvents:UIControlEventTouchUpInside];
        [self.shortcutsContainer addSubview:button];
        [self.shortcutButtons addObject:button];
    }
}

- (void)showLikedSongs {
    [self ensureSongsLoaded:^{
        waLikedSongsViewController *controller = [[waLikedSongsViewController alloc] initWithSongs:self.songs ?: @[]];
        [self.navigationController pushViewController:controller animated:YES];
    }];
}

- (void)showDownloads {
    [self.navigationController pushViewController:[[waDownloadsViewController alloc] init] animated:YES];
}

#pragma mark - Loading

- (void)loadLibrary {
    if (![[waAPIClient sharedClient] isAuthenticated]) {
        [self.refreshControl endRefreshing];
        [self showAuthRequired];
        return;
    }
    NSUInteger generation = ++self.loadGeneration;
    self.loading = YES;
    __weak typeof(self) weakSelf = self;
    void (^wrap)(void (^block)(void)) = ^(void (^block)(void)) { if (block) block(); };
    (void)wrap;

    [[waAPIClient sharedClient] likedAlbumsWithCompletion:^(NSDictionary *result, NSError *error) {
        if (!weakSelf || generation != weakSelf.loadGeneration) return;
        if (!error && result) weakSelf.albums = [weakSelf itemsFromDictionaries:result[@"albums"]];
        [weakSelf finishLoad];
    }];
    [[waAPIClient sharedClient] likedArtistsWithCompletion:^(NSDictionary *result, NSError *error) {
        if (!weakSelf || generation != weakSelf.loadGeneration) return;
        if (!error && result) weakSelf.artists = [weakSelf itemsFromDictionaries:result[@"artists"]];
        [weakSelf finishLoad];
    }];
    [[waAPIClient sharedClient] playlistsWithCompletion:^(NSArray *list, NSError *error) {
        if (!weakSelf || generation != weakSelf.loadGeneration) return;
        if (!error && list) weakSelf.playlists = [weakSelf itemsFromDictionaries:list];
        [weakSelf finishLoad];
    }];
}

- (void)finishLoad {
    [self.refreshControl endRefreshing];
    self.loading = NO;
    [self updateContent];
}

- (void)ensureSongsLoaded:(void (^)(void))completion {
    if (self.songsLoaded) { if (completion) completion(); return; }
    __weak typeof(self) weakSelf = self;
    [[waAPIClient sharedClient] likedSongsWithCompletion:^(NSDictionary *result, NSError *error) {
        waLibraryViewController *self2 = weakSelf;
        if (!self2) { if (completion) completion(); return; }
        if (!error && result) {
            self2.songs = [self2 itemsFromDictionaries:result[@"songs"]];
            self2.songsLoaded = YES;
        }
        if (completion) completion();
    }];
}

- (NSArray *)itemsFromDictionaries:(NSArray *)dictionaries {
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:dictionaries.count];
    for (id object in dictionaries) {
        waMediaItem *item = [object isKindOfClass:[waMediaItem class]] ? object
                            : ([object isKindOfClass:[NSDictionary class]] ? [waMediaItem itemWithDictionary:object] : nil);
        if (item) [items addObject:item];
    }
    return items;
}

#pragma mark - Filtering

- (BOOL)isFiltering {
    return self.segmentedControl.selectedSegmentIndex != waLibraryFilterAll || self.searchBar.text.length > 0;
}

- (void)segmentChanged:(waSegmentedControl *)sender {
    (void)sender;
    [self applyFilter];
}

- (void)applyFilter {
    waLibraryFilter filter = self.segmentedControl.selectedSegmentIndex;
    BOOL needsSongs = (filter == waLibraryFilterTracks) || (filter == waLibraryFilterAll && self.searchBar.text.length > 0);
    if (needsSongs && !self.songsLoaded) {
        [self.emptyView configureWithIcon:[UIImage imageNamed:@"tab-wave-library"]
                                    title:@"Library"
                                 subtitle:@"Loading your songs…"
                              actionTitle:nil
                                   target:nil
                                   action:nil];
        [self.emptyView setLoading:YES];
        self.emptyView.hidden = NO;
        [self ensureSongsLoaded:^{ [self updateContent]; }];
        return;
    }
    [self updateContent];
}

- (NSArray *)computeFilteredItems {
    waLibraryFilter filter = self.segmentedControl.selectedSegmentIndex;
    NSString *query = [self.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL hasQuery = query.length > 0;
    NSMutableArray *pool = [NSMutableArray array];
    if (filter == waLibraryFilterTracks || (filter == waLibraryFilterAll && hasQuery)) [pool addObjectsFromArray:self.songs];
    if (filter == waLibraryFilterAlbums || (filter == waLibraryFilterAll && hasQuery)) [pool addObjectsFromArray:self.albums];
    if (filter == waLibraryFilterArtists || (filter == waLibraryFilterAll && hasQuery)) [pool addObjectsFromArray:self.artists];
    if (filter == waLibraryFilterPlaylists || (filter == waLibraryFilterAll && hasQuery)) [pool addObjectsFromArray:self.playlists];
    if (!hasQuery) return pool;
    NSMutableArray *matched = [NSMutableArray array];
    for (waMediaItem *item in pool) {
        if (item.title && [item.title rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [matched addObject:item];
        }
    }
    return matched;
}

- (void)updateContent {
    if (![[waAPIClient sharedClient] isAuthenticated]) { [self showAuthRequired]; return; }
    self.emptyView.hidden = YES;
    BOOL hasAny = (self.albums.count + self.artists.count + self.playlists.count) > 0;
    if (self.loading && !hasAny) {
        [self.emptyView configureWithIcon:[UIImage imageNamed:@"tab-wave-library"]
                                    title:@"Library"
                                 subtitle:@"Loading your music…"
                              actionTitle:nil
                                   target:nil
                                   action:nil];
        [self.emptyView setLoading:YES];
        self.emptyView.hidden = NO;
        self.scrollView.hidden = YES;
        self.resultsTableView.hidden = YES;
        return;
    }
    if (!hasAny) {
        [self.emptyView configureWithIcon:[UIImage imageNamed:@"tab-wave-library"]
                                    title:@"Your Library"
                                 subtitle:@"No saved albums, artists, or playlists yet."
                              actionTitle:@"Reload"
                                   target:self
                                   action:@selector(loadLibrary)];
        [self.emptyView setLoading:NO];
        self.emptyView.hidden = NO;
        self.scrollView.hidden = YES;
        self.resultsTableView.hidden = YES;
        return;
    }
    if (self.isFiltering) {
        self.filteredItems = [self computeFilteredItems];
        self.scrollView.hidden = YES;
        self.resultsTableView.hidden = NO;
        [self.resultsTableView reloadData];
    } else {
        self.filteredItems = nil;
        self.resultsTableView.hidden = YES;
        self.scrollView.hidden = NO;
        [self renderShelves];
    }
}

#pragma mark - Shelves

- (void)renderShelves {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self renderShelves]; }); return; }
    for (waHomeSectionView *shelf in self.shelves) { [shelf clearCallbacks]; [shelf removeFromSuperview]; }
    [self.shelves removeAllObjects];
    CGFloat width = self.scrollView.bounds.size.width;
    self.shortcutsContainer.frame = CGRectMake(0.0, 0.0, MAX(0.0, width), 52.0);
    if (self.shortcutsContainer.superview != self.scrollView) [self.scrollView addSubview:self.shortcutsContainer];

    NSArray *shelfDefs = @[
        @{@"title": @"Liked Albums", @"items": self.albums, @"layout": @"square", @"filter": @(waLibraryFilterAlbums)},
        @{@"title": @"Liked Artists", @"items": self.artists, @"layout": @"circle", @"filter": @(waLibraryFilterArtists)},
        @{@"title": @"Playlists", @"items": self.playlists, @"layout": @"square", @"filter": @(waLibraryFilterPlaylists)},
    ];
    __weak typeof(self) weakSelf = self;
    CGFloat y = 60.0;
    for (NSDictionary *def in shelfDefs) {
        NSArray *items = def[@"items"];
        if (![items isKindOfClass:[NSArray class]] || items.count == 0) continue;
        waHomeSectionView *shelf = [[waHomeSectionView alloc] initWithFrame:CGRectMake(0.0, y, MAX(0.0, width), 300.0)];
        NSMutableDictionary *section = [NSMutableDictionary dictionary];
        section[@"title"] = def[@"title"];
        section[@"items"] = items;
        section[@"layout"] = def[@"layout"];
        section[@"showsMore"] = @YES;
        [shelf configureWithSection:section selection:^(waMediaItem *item, NSArray *context) {
            [weakSelf selectItem:item context:context];
        }];
        shelf.longPress = ^(waMediaItem *item, NSArray *context) {
            [waMediaActionSheet presentForItem:item inViewController:weakSelf albumItems:context];
        };
        NSInteger targetFilter = [def[@"filter"] integerValue];
        shelf.moreAction = ^{
            weakSelf.segmentedControl.selectedSegmentIndex = targetFilter;
            [weakSelf applyFilter];
        };
        [self.scrollView addSubview:shelf];
        [self.shelves addObject:shelf];
        y += [shelf preferredHeight] + 10.0;
    }
    [self layoutShelves];
}

- (void)layoutShelves {
    CGFloat width = self.scrollView.bounds.size.width;
    CGFloat y = 60.0;
    for (waHomeSectionView *shelf in self.shelves) {
        shelf.frame = CGRectMake(0.0, y, MAX(0.0, width), [shelf preferredHeight]);
        y += [shelf preferredHeight] + 10.0;
    }
    self.scrollView.contentSize = CGSizeMake(MAX(0.0, width), MAX(y, self.scrollView.bounds.size.height + 1.0));
}

#pragma mark - Selection

- (void)selectItem:(waMediaItem *)item context:(NSArray *)context {
    if (!item) return;
    if (item.type == waMediaItemTypeSong) {
        [[waAudioPlayer sharedPlayer] playItem:item fromContext:context ?: @[] title:item.title ?: @"Library"];
        return;
    }
    if (item.type == waMediaItemTypePlaylist) {
        NSDictionary *playlist = @{ @"id": item.identifier ?: @"",
                                    @"title": item.title ?: @"Playlist",
                                    @"name": item.title ?: @"Playlist",
                                    @"thumbnailURL": item.thumbnailURL ?: @"",
                                    @"artwork": item.thumbnailURL ?: @"" };
        [self.navigationController pushViewController:[[waPlaylistViewController alloc] initWithPlaylist:playlist ownerIsCurrentUser:YES] animated:YES];
        return;
    }
    [self.navigationController pushViewController:[[waMediaDetailViewController alloc] initWithMediaItem:item] animated:YES];
}

#pragma mark - Playlist creation

- (void)createPlaylist {
    if (![[waAPIClient sharedClient] isAuthenticated]) { [self presentLogin]; return; }
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"New Playlist"
                                                    message:@"Name your playlist"
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Create", nil];
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    alert.tag = waCreatePlaylistAlertTag;
    UITextField *field = [alert textFieldAtIndex:0];
    field.placeholder = @"Playlist name";
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag != waCreatePlaylistAlertTag) return;
    if (buttonIndex != 1) return;
    UITextField *field = [alertView textFieldAtIndex:0];
    NSString *name = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) return;
    [self createPlaylistWithName:name];
}

- (void)createPlaylistWithName:(NSString *)name {
    [self.emptyView configureWithIcon:[UIImage imageNamed:@"tab-wave-library"]
                                title:@"Library"
                             subtitle:@"Creating playlist…"
                          actionTitle:nil
                               target:nil
                               action:nil];
    [self.emptyView setLoading:YES];
    self.emptyView.hidden = NO;
    __weak typeof(self) weakSelf = self;
    [[waAPIClient sharedClient] createPlaylistNamed:name completion:^(NSDictionary *playlist, NSError *error) {
        waLibraryViewController *self2 = weakSelf;
        if (!self2) return;
        [self2.emptyView setLoading:NO];
        if (error) {
            [[[UIAlertView alloc] initWithTitle:@"Playlist"
                                        message:error.localizedDescription ?: @"Could not create the playlist."
                                       delegate:nil
                              cancelButtonTitle:@"OK"
                              otherButtonTitles:nil] show];
            [self2 updateContent];
            return;
        }
        [self2 reloadPlaylists];
    }];
}

- (void)reloadPlaylists {
    __weak typeof(self) weakSelf = self;
    [[waAPIClient sharedClient] playlistsWithCompletion:^(NSArray *list, NSError *error) {
        waLibraryViewController *self2 = weakSelf;
        if (!self2 || error || !list) { [self2 updateContent]; return; }
        self2.playlists = [self2 itemsFromDictionaries:list];
        [self2 updateContent];
    }];
}

#pragma mark - Auth

- (void)showAuthRequired {
    self.scrollView.hidden = YES;
    self.resultsTableView.hidden = YES;
    [self.emptyView configureWithIcon:[UIImage imageNamed:@"tab-wave-library"]
                                title:@"Library"
                             subtitle:@"Connect to Deezer to see your music."
                          actionTitle:@"Connect"
                               target:self
                               action:@selector(presentLogin)];
    [self.emptyView setLoading:NO];
    self.emptyView.hidden = NO;
}

- (void)presentLogin {
    waDeezerLoginViewController *login = [[waDeezerLoginViewController alloc] initWithCompletion:^(NSError *error) {
        (void)error;
        [self loadLibrary];
    }];
    [self presentViewController:login animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource / Delegate (results)

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.filteredItems.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return 64.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    waArtworkCell *cell = [tableView dequeueReusableCellWithIdentifier:@"wa-library-result"];
    if (!cell) {
        cell = [[waArtworkCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"wa-library-result"];
        cell.cardStyle = NO;
        cell.backgroundColor = [waTheme backgroundColor];
        UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
        selected.backgroundColor = [waTheme selectedSurfaceColor];
        cell.selectedBackgroundView = selected;
    }
    NSArray *items = self.filteredItems;
    waMediaItem *item = indexPath.row < items.count ? items[indexPath.row] : nil;
    cell.backgroundColor = [waTheme backgroundColor];
    cell.textLabel.text = item.title ?: @"";
    cell.textLabel.textColor = [waTheme primaryTextColor];
    cell.multilineDetail = NO;
    cell.detailTextLabel.text = [self subtitleForItem:item];
    cell.detailTextLabel.textColor = [waTheme secondaryTextColor];
    cell.imageView.image = waPlaceholderImage();
    cell.artworkIdentifier = item.thumbnailURL ?: item.identifier;
    [cell setLikeItem:item];
    [cell setExplicit:item.isExplicit];
    if (item.thumbnailURL.length) {
        NSURL *url = [NSURL URLWithString:item.thumbnailURL];
        if (!url.scheme.length) url = [[waAPIClient sharedClient] URLForPath:item.thumbnailURL];
        NSString *expected = [cell.artworkIdentifier copy];
        waMediaItem *captured = item;
        NSString *expectedURL = [item.thumbnailURL copy];
        [[waImageLoader sharedLoader] loadThumbnailAtURL:url.absoluteString targetSize:CGSizeMake(96.0, 96.0) placeholder:waPlaceholderImage() completion:^(UIImage *image) {
            NSIndexPath *currentPath = [tableView indexPathForCell:cell];
            if (!currentPath || ![cell.artworkIdentifier isEqualToString:expected] || !image) return;
            if (currentPath.row < items.count && items[currentPath.row] == captured && [captured.thumbnailURL isEqualToString:expectedURL]) {
                cell.imageView.image = image;
            }
        }];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray *items = self.filteredItems;
    if (indexPath.row < items.count) [self selectItem:items[indexPath.row] context:items];
}

- (NSString *)subtitleForItem:(waMediaItem *)item {
    if (item.type == waMediaItemTypeArtist) return item.subtitle.length ? item.subtitle : @"Artist";
    if (item.type == waMediaItemTypeAlbum) return item.artistName.length ? item.artistName : (item.subtitle ?: @"");
    if (item.type == waMediaItemTypePlaylist) return item.subtitle.length ? item.subtitle : @"Playlist";
    return item.artistName.length ? item.artistName : (item.subtitle ?: @"");
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar; (void)searchText;
    [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    searchBar.showsCancelButton = YES;
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar {
    searchBar.showsCancelButton = NO;
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    searchBar.showsCancelButton = NO;
    [searchBar resignFirstResponder];
    [self applyFilter];
}

#pragma mark - Theme / layout

- (void)applyTheme {
    self.view.backgroundColor = [waTheme backgroundColor];
    self.scrollView.backgroundColor = [waTheme backgroundColor];
    self.resultsTableView.backgroundColor = [waTheme backgroundColor];
    self.resultsTableView.separatorColor = [waTheme separatorColor];
    self.filterBar.backgroundColor = [waTheme backgroundColor];
    if ([waTheme isModernSystem] && [self.searchBar respondsToSelector:@selector(setBarTintColor:)]) {
        self.searchBar.barTintColor = [waTheme backgroundColor];
    }
    self.searchBar.tintColor = [waTheme barColor];
    [self.segmentedControl updateAppearance];
    for (UIButton *button in self.shortcutButtons) button.backgroundColor = [waTheme barColor];
    [self.emptyView applyTheme];
}

- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    [self applyTheme];
    if (self.view.window) {
        [self renderShelves];
        if (self.isFiltering) [self.resultsTableView reloadData];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat width = self.view.bounds.size.width;
    CGFloat filterHeight = 88.0;
    self.filterBar.frame = CGRectMake(0.0, 0.0, width, filterHeight);
    self.searchBar.frame = CGRectMake(0.0, 0.0, width, 44.0);
    self.segmentedControl.frame = CGRectMake(10.0, 48.0, MAX(0.0, width - 20.0), 32.0);
    CGFloat contentY = filterHeight;
    CGFloat contentHeight = MAX(0.0, self.view.bounds.size.height - filterHeight);
    self.scrollView.frame = CGRectMake(0.0, contentY, width, contentHeight);
    self.resultsTableView.frame = CGRectMake(0.0, contentY, width, contentHeight);
    self.emptyView.frame = self.view.bounds;
    [self layoutShortcuts];
    [self layoutShelves];
}

- (void)layoutShortcuts {
    CGFloat width = self.scrollView.bounds.size.width;
    self.shortcutsContainer.frame = CGRectMake(0.0, 0.0, MAX(0.0, width), 52.0);
    CGFloat pad = 10.0;
    CGFloat gap = 8.0;
    CGFloat buttonWidth = (width - pad * 2.0 - gap * 2.0) / 3.0;
    for (NSUInteger index = 0; index < self.shortcutButtons.count; index++) {
        UIButton *button = self.shortcutButtons[index];
        button.frame = CGRectMake(pad + index * (buttonWidth + gap), 4.0, buttonWidth, 44.0);
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    for (waHomeSectionView *shelf in self.shelves) [shelf clearCallbacks];
}

@end
