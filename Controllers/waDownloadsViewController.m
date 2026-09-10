#import "waDownloadsViewController.h"
#import "../Services/waDownloadManager.h"
#import "../Models/waDownload.h"
#import "../Models/waMediaItem.h"
#import "../Services/waAudioPlayer.h"
#import "../Services/waTheme.h"
#import "../Views/waArtworkCell.h"
#import "../Views/waPlaceholder.h"
#import "../Views/waMediaActionSheet.h"
#import "../Views/waEmptyView.h"
#import "../Services/waImageLoader.h"
#import "../Services/waAPIClient.h"
#import <QuartzCore/QuartzCore.h>

static waMediaItem *waItemFromDownload(waDownload *d) {
    if (!d) return nil;
    waMediaItem *item = [waMediaItem itemWithDictionary:@{
        @"trackId": d.identifier ?: @"",
        @"title": d.title ?: @"Downloaded Song",
        @"artist": d.artist ?: @"",
        @"thumbnail": d.thumbnailURL ?: @"",
        @"albumName": d.albumName ?: @"",
        @"explicit": @(d.isExplicit)
    }];
    item.duration = d.duration;
    return item;
}

// Pushed controllers can be created after launch, so the app delegate has not
// necessarily applied the iOS 7 edge compatibility fix yet. When UIKit still
// lets a table reach behind the tab bar, reserve only the actual overlap. This
// keeps iOS 6's normal layout unchanged and avoids adding a needless blank
// footer when the table already ends above the tab bar.
static void waApplyDownloadsTabBarInset(UITableView *tableView, UIViewController *viewController) {
    if (!tableView || !viewController.view.window) return;
    UITabBar *tabBar = viewController.tabBarController.tabBar;
    UIWindow *window = viewController.view.window;
    CGFloat overlap = 0.0;
    if (tabBar && !tabBar.hidden) {
        CGRect tableFrame = [tableView convertRect:tableView.bounds toView:window];
        CGRect tabBarFrame = [tabBar convertRect:tabBar.bounds toView:window];
        overlap = MAX(0.0, CGRectGetMaxY(tableFrame) - CGRectGetMinY(tabBarFrame));
    }
    UIEdgeInsets contentInsets = tableView.contentInset;
    contentInsets.bottom = overlap;
    tableView.contentInset = contentInsets;
    UIEdgeInsets indicatorInsets = tableView.scrollIndicatorInsets;
    indicatorInsets.bottom = overlap;
    tableView.scrollIndicatorInsets = indicatorInsets;
}

typedef NS_ENUM(NSInteger, waDownloadsFilter) {
    waDownloadsFilterSongs = 0,
    waDownloadsFilterArtists,
    waDownloadsFilterAlbums,
    waDownloadsFilterPlaylists
};

// Detail list for artist/album/playlist group — shows songs, tap to play
@interface waDownloadDetailListViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
- (id)initWithDownloads:(NSArray *)downloads title:(NSString *)title;
@end

@implementation waDownloadDetailListViewController {
    NSArray *_downloads;
    UITableView *_tableView;
    waEmptyView *_emptyView;
}
- (id)initWithDownloads:(NSArray *)downloads title:(NSString *)title {
    if ((self = [super init])) {
        _downloads = [downloads copy];
        self.title = title ?: @"Downloads";
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [waTheme applyLayoutCompatibilityToViewController:self];
    self.view.backgroundColor = [waTheme backgroundColor];
    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _tableView.delegate = self; _tableView.dataSource = self;
    _tableView.backgroundColor = [waTheme backgroundColor];
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    UIView *bg = [[UIView alloc] initWithFrame:_tableView.bounds];
    bg.backgroundColor = [waTheme backgroundColor];
    _emptyView = [[waEmptyView alloc] initWithFrame:bg.bounds];
    _emptyView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [bg addSubview:_emptyView];
    _tableView.backgroundView = bg;
    [self.view addSubview:_tableView];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Shuffle" style:UIBarButtonItemStyleBordered target:self action:@selector(shuffleAll)];
    UIBarButtonItem *playAll = [[UIBarButtonItem alloc] initWithTitle:@"Play All" style:UIBarButtonItemStyleBordered target:self action:@selector(playAll)];
    self.navigationItem.rightBarButtonItems = @[playAll, self.navigationItem.rightBarButtonItem];
    // Shuffle handled via playAll with shuffleEnabled
    [waTheme applyToView:self.view];
    [self updateEmpty];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    waApplyDownloadsTabBarInset(_tableView, self);
}
- (void)updateEmpty {
    BOOL empty = _downloads.count==0;
    if (empty) {
        [_emptyView configureWithIcon:[UIImage imageNamed:@"wave-downloaded"] title:@"No songs" subtitle:@" " actionTitle:nil target:nil action:NULL];
        [_emptyView applyTheme];
    }
    _emptyView.hidden = !empty;
    [_tableView reloadData];
}
- (NSArray *)completedItems {
    NSMutableArray *items = [NSMutableArray array];
    for (waDownload *d in _downloads) {
        NSString *path = [[waDownloadManager sharedManager] localPathForIdentifier:d.identifier] ?: d.filePath;
        if (d.state==waDownloadStateCompleted && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            waMediaItem *it = waItemFromDownload(d);
            if (it) [items addObject:it];
        }
    }
    return items;
}
- (void)playAll { NSArray *items = [self completedItems]; if (items.count) { [waAudioPlayer sharedPlayer].shuffleEnabled=NO; [[waAudioPlayer sharedPlayer] playItem:items[0] fromContext:items title:self.title]; } }
- (void)shuffleAll { NSArray *items = [self completedItems]; if (items.count) { [waAudioPlayer sharedPlayer].shuffleEnabled=YES; [[waAudioPlayer sharedPlayer] playItem:items[0] fromContext:items title:self.title]; } }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { (void)tv;(void)s; return _downloads.count; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { (void)ip; return [waTheme standardRowHeight]; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    waArtworkCell *cell = [tv dequeueReusableCellWithIdentifier:@"dldetail"];
    if (!cell) { cell=[[waArtworkCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"dldetail"]; cell.cardStyle=NO; cell.backgroundColor=[waTheme backgroundColor]; UIView *sel=[[UIView alloc] initWithFrame:CGRectZero]; sel.backgroundColor=[waTheme selectedSurfaceColor]; cell.selectedBackgroundView=sel; }
    waDownload *d = _downloads[ip.row];
    cell.textLabel.text = d.title.length?d.title:@"Downloaded";
    cell.detailTextLabel.text = d.artist ?: @"";
    cell.imageView.image = waPlaceholderImage();
    NSString *imageToken = [NSString stringWithFormat:@"detail:%@:%@:%@", d.identifier ?: @"", d.artworkFilePath ?: @"", d.thumbnailURL ?: @""];
    cell.artworkIdentifier = imageToken;
    if (d.artworkFilePath.length) {
        NSString *expectedToken = [imageToken copy];
        [[waImageLoader sharedLoader] loadLocalImageAtPath:d.artworkFilePath targetSize:CGSizeMake(44,44) completion:^(UIImage *img){
            if (img && [cell.artworkIdentifier isEqualToString:expectedToken]) cell.imageView.image = img;
        }];
    } else if (d.thumbnailURL.length) {
        NSString *expectedToken = [imageToken copy];
        [[waImageLoader sharedLoader] loadThumbnailAtURL:d.thumbnailURL targetSize:CGSizeMake(112,112) placeholder:waPlaceholderImage() completion:^(UIImage *img){
            if (img && [cell.artworkIdentifier isEqualToString:expectedToken]) cell.imageView.image = img;
        }];
    }
    [cell setExplicit:d.isExplicit]; [cell setDownloadState:d.state progress:d.progress];
    cell.textLabel.textColor=[waTheme primaryTextColor]; cell.detailTextLabel.textColor=[waTheme secondaryTextColor];
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    waDownload *d = _downloads[ip.row];
    if (d.state==waDownloadStateDownloading||d.state==waDownloadStateQueued) return;
    NSString *path = [[waDownloadManager sharedManager] localPathForIdentifier:d.identifier] ?: d.filePath;
    if (d.state!=waDownloadStateCompleted || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    NSArray *items = [self completedItems];
    waMediaItem *sel = waItemFromDownload(d);
    NSUInteger idx = [items indexOfObjectPassingTest:^BOOL(waMediaItem *o,NSUInteger i,BOOL*s){ return [o.trackId isEqualToString:sel.trackId]; }];
    if (idx!=NSNotFound) [[waAudioPlayer sharedPlayer] playItem:items[idx] fromContext:items title:self.title];
    else if (sel) [[waAudioPlayer sharedPlayer] playItem:sel];
}
@end

@interface waDownloadsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UISegmentedControl *segmentedControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) waEmptyView *emptyView;
@property (nonatomic, assign) waDownloadsFilter currentFilter;
@property (nonatomic, strong) NSArray *displayDownloads; // songs flat
@property (nonatomic, strong) NSArray *displayArtists; // artists groups
@property (nonatomic, strong) NSArray *displayAlbums; // album groups @{@"id":...,@"title":...,@"downloads":@[]}
@property (nonatomic, strong) NSArray *displayPlaylists; // playlist groups
@property (nonatomic, assign) BOOL downloadReloadScheduled;
@end

@implementation waDownloadsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [waTheme applyLayoutCompatibilityToViewController:self];
    self.title = @"Downloads";
    self.view.backgroundColor = [waTheme backgroundColor];

    // Segmented native iOS 7
    self.segmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Songs", @"Artists", @"Albums", @"Playlists"]];
    self.segmentedControl.selectedSegmentIndex = 0;
    self.currentFilter = waDownloadsFilterSongs;
    [self.segmentedControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    [waTheme applySkeuomorphicStyleToSegmentedControl:self.segmentedControl];
    self.segmentedControl.tintColor = [waTheme barColor];
    [self.view addSubview:self.segmentedControl];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    UIView *bg = [[UIView alloc] initWithFrame:CGRectZero];
    bg.backgroundColor = [waTheme backgroundColor];
    self.emptyView = [[waEmptyView alloc] initWithFrame:bg.bounds];
    self.emptyView.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [bg addSubview:self.emptyView];
    self.tableView.backgroundView = bg;
    [self.view addSubview:self.tableView];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadsChanged:) name:waDownloadManagerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged:) name:waThemeDidChangeNotification object:nil];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    [self.tableView addGestureRecognizer:lp];

    [waTheme applyToView:self.view];
    [self reloadDataForFilter];
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadDataForFilter]; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat top = 8.0;
    CGFloat segH = 32.0;
    CGFloat w = self.view.bounds.size.width;
    self.segmentedControl.frame = CGRectMake(12.0, top, w - 24.0, segH);
    self.tableView.frame = CGRectMake(0.0, top + segH + 8.0, w, self.view.bounds.size.height - (top + segH + 8.0));
    self.emptyView.frame = self.tableView.backgroundView.bounds;
    waApplyDownloadsTabBarInset(self.tableView, self);
}

- (void)themeChanged:(NSNotification *)n {
    self.view.backgroundColor = [waTheme backgroundColor];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    [waTheme applySkeuomorphicStyleToSegmentedControl:self.segmentedControl];
    [waTheme applyToView:self.view];
    [self.tableView reloadData];
}
- (void)segmentChanged:(UISegmentedControl *)seg {
    self.currentFilter = (waDownloadsFilter)seg.selectedSegmentIndex;
    [self reloadDataForFilter];
    [self.tableView setContentOffset:CGPointZero animated:NO];
}
- (void)downloadsChanged:(NSNotification *)n {
    if (!self.view.window) return;
    if ([n.userInfo[@"event"] isEqualToString:@"progress"]) {
        if (self.downloadReloadScheduled) return;
        self.downloadReloadScheduled = YES;
        [self performSelector:@selector(reloadForDownload) withObject:nil afterDelay:0.4];
    } else [self reloadDataForFilter];
}
- (void)reloadForDownload { self.downloadReloadScheduled = NO; [self reloadDataForFilter]; }

- (void)reloadDataForFilter {
    NSArray *songs = [[waDownloadManager sharedManager] downloadsForCategory:waDownloadCategorySong];
    NSArray *albums = [[waDownloadManager sharedManager] downloadsForCategory:waDownloadCategoryAlbum];
    NSArray *playlists = [[waDownloadManager sharedManager] downloadsForCategory:waDownloadCategoryPlaylist];
    switch (self.currentFilter) {
        case waDownloadsFilterSongs:
            self.displayDownloads = songs;
            self.displayArtists = nil; self.displayAlbums=nil; self.displayPlaylists=nil;
            break;
        case waDownloadsFilterAlbums: {
            NSMutableDictionary *byAlbum = [NSMutableDictionary dictionary];
            for (waDownload *d in albums) {
                NSArray *ctx = [d contextIdentifiersForCategory:waDownloadCategoryAlbum];
                NSString *aid = ctx.count ? ctx[0] : d.identifier;
                if (!aid.length) aid = d.identifier;
                NSMutableArray *arr = byAlbum[aid];
                if (!arr) { arr=[NSMutableArray array]; byAlbum[aid]=arr; }
                [arr addObject:d];
            }
            NSMutableArray *groups=[NSMutableArray array];
            for (NSString *aid in byAlbum) {
                NSArray *arr=byAlbum[aid];
                waDownload *first=arr.count ? [arr objectAtIndex:0] : nil;
                NSString *title = first.currentGroupTitle.length?first.currentGroupTitle:(first.albumName.length?first.albumName:first.title);
                [groups addObject:@{@"id":aid, @"title":title?:@"Album", @"downloads":arr, @"count":@(arr.count), @"sample":first}];
            }
            self.displayAlbums = [groups sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){ return [a[@"title"] compare:b[@"title"]]; }];
            self.displayArtists=nil; self.displayDownloads=nil; self.displayPlaylists=nil;
            break;
        }
        case waDownloadsFilterPlaylists: {
            NSMutableDictionary *byPl = [NSMutableDictionary dictionary];
            for (waDownload *d in playlists) {
                NSArray *ctx = [d contextIdentifiersForCategory:waDownloadCategoryPlaylist];
                NSString *pid = ctx.count ? ctx[0] : d.currentContextIdentifier;
                if (!pid.length) pid = d.identifier;
                NSMutableArray *arr = byPl[pid];
                if (!arr) { arr=[NSMutableArray array]; byPl[pid]=arr; }
                [arr addObject:d];
            }
            // Also include currentGroupTitle metadata
            NSMutableArray *groups=[NSMutableArray array];
            for (NSString *pid in byPl) {
                NSArray *arr=byPl[pid];
                waDownload *first=arr.count ? [arr objectAtIndex:0] : nil;
                NSString *title = first.currentGroupTitle.length?first.currentGroupTitle:(first.title.length?first.title:@"Playlist");
                // Include metadata: if first has metadata playlist title, use it
                if (first.metadata[@"title"] && [first.metadata[@"title"] isKindOfClass:[NSString class]]) title = first.metadata[@"title"];
                [groups addObject:@{@"id":pid, @"title":title, @"downloads":arr, @"count":@(arr.count), @"sample":first}];
            }
            self.displayPlaylists = [groups sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){ return [a[@"title"] compare:b[@"title"]]; }];
            self.displayArtists=nil; self.displayDownloads=nil; self.displayAlbums=nil;
            break;
        }
        case waDownloadsFilterArtists: {
            NSMutableDictionary *byArtist = [NSMutableDictionary dictionary];
            for (waDownload *d in songs) {
                NSString *artist = d.artist.length ? d.artist : @"Unknown Artist";
                NSMutableArray *arr = byArtist[artist];
                if (!arr) { arr = [NSMutableArray array]; byArtist[artist] = arr; }
                [arr addObject:d];
            }
            NSMutableArray *groups = [NSMutableArray array];
            for (NSString *name in byArtist) {
                NSArray *arr = byArtist[name];
                [groups addObject:@{@"name": name, @"downloads": arr, @"count": @(arr.count)}];
            }
            self.displayArtists = [groups sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){ return [b[@"count"] compare:a[@"count"]]; }];
            self.displayDownloads=nil; self.displayAlbums=nil; self.displayPlaylists=nil;
            break;
        }
    }
    BOOL empty = NO;
    if (self.currentFilter==waDownloadsFilterSongs) empty=self.displayDownloads.count==0;
    else if (self.currentFilter==waDownloadsFilterArtists) empty=self.displayArtists.count==0;
    else if (self.currentFilter==waDownloadsFilterAlbums) empty=self.displayAlbums.count==0;
    else empty=self.displayPlaylists.count==0;
    if (empty) {
        NSString *title = @[@"No downloaded songs",@"No artists",@"No albums",@"No playlists"][(NSInteger)self.currentFilter];
        NSString *sub = @"Downloads you make will appear here.";
        [self.emptyView configureWithIcon:[UIImage imageNamed:@"wave-downloaded"] title:title subtitle:sub actionTitle:nil target:nil action:NULL];
        [self.emptyView applyTheme];
    }
    self.emptyView.hidden = !empty;
    [self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView;(void)section; if (self.currentFilter==waDownloadsFilterArtists) return self.displayArtists.count; if (self.currentFilter==waDownloadsFilterAlbums) return self.displayAlbums.count; if (self.currentFilter==waDownloadsFilterPlaylists) return self.displayPlaylists.count; return self.displayDownloads.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)ip { (void)ip; return [waTheme standardRowHeight]; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    waArtworkCell *cell = [tableView dequeueReusableCellWithIdentifier:@"dl"];
    if (!cell) {
        cell = [[waArtworkCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"dl"];
        cell.cardStyle = NO;
        cell.backgroundColor = [waTheme backgroundColor];
        UIView *sel = [[UIView alloc] initWithFrame:CGRectZero];
        sel.backgroundColor = [waTheme selectedSurfaceColor];
        cell.selectedBackgroundView = sel;
    }
    if (self.currentFilter==waDownloadsFilterArtists) {
        cell.circleArtwork = YES;
        NSDictionary *group = self.displayArtists[ip.row];
        NSString *name = group[@"name"];
        NSArray *arr = group[@"downloads"];
        waDownload *first = arr.count ? [arr objectAtIndex:0] : nil;
        cell.textLabel.text = name;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu songs", (unsigned long)arr.count];
        cell.imageView.image = waPlaceholderImage();
        NSString *imageToken = [NSString stringWithFormat:@"artist:%@:%@", name ?: @"", first.thumbnailURL ?: @""];
        cell.artworkIdentifier = imageToken;
        if (first.thumbnailURL.length) {
            NSString *url = first.thumbnailURL;
            NSString *expectedToken = [imageToken copy];
            [[waImageLoader sharedLoader] loadThumbnailAtURL:url targetSize:CGSizeMake(112,112) placeholder:waPlaceholderImage() completion:^(UIImage *img){
                if (img && [cell.artworkIdentifier isEqualToString:expectedToken]) cell.imageView.image = img;
            }];
        }
        [cell setExplicit:NO];
        [cell setDownloadState:waDownloadStateNotFound progress:0];
    } else if (self.currentFilter==waDownloadsFilterAlbums) {
        cell.circleArtwork = NO;
        NSDictionary *group = self.displayAlbums[ip.row];
        waDownload *first = group[@"sample"];
        cell.textLabel.text = group[@"title"];
        NSArray *arr = group[@"downloads"];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu songs • %@", (unsigned long)arr.count, first.artist ?: @""];
        cell.imageView.image = waPlaceholderImage();
        NSString *imageToken = [NSString stringWithFormat:@"album:%@:%@:%@", group[@"id"] ?: @"", first.artworkFilePath ?: @"", first.thumbnailURL ?: @""];
        cell.artworkIdentifier = imageToken;
        NSString *art = first.artworkFilePath.length ? first.artworkFilePath : nil;
        if (art.length) {
            NSString *expectedToken = [imageToken copy];
            [[waImageLoader sharedLoader] loadLocalImageAtPath:art targetSize:CGSizeMake(44,44) completion:^(UIImage *img){
                if (img && [cell.artworkIdentifier isEqualToString:expectedToken]) cell.imageView.image = img;
            }];
        } else if (first.thumbnailURL.length) {
            NSString *expectedToken = [imageToken copy];
            [[waImageLoader sharedLoader] loadThumbnailAtURL:first.thumbnailURL targetSize:CGSizeMake(112,112) placeholder:waPlaceholderImage() completion:^(UIImage *img){
                if (img && [cell.artworkIdentifier isEqualToString:expectedToken]) cell.imageView.image = img;
            }];
        }
        [cell setExplicit:first.isExplicit];
        [cell setDownloadState:waDownloadStateNotFound progress:0];
    } else if (self.currentFilter==waDownloadsFilterPlaylists) {
        cell.circleArtwork = NO;
        NSDictionary *group = self.displayPlaylists[ip.row];
        waDownload *first = group[@"sample"];
        cell.textLabel.text = group[@"title"];
        NSArray *arr = group[@"downloads"];
        // Metadata for playlist: use groupTitle + count, include explicit if any
        BOOL anyExplicit = NO; for (waDownload *d in arr) if (d.isExplicit) { anyExplicit=YES; break; }
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu songs", (unsigned long)arr.count];
        cell.imageView.image = waPlaceholderImage();
        NSString *imageToken = [NSString stringWithFormat:@"playlist:%@:%@:%@", group[@"id"] ?: @"", first.artworkFilePath ?: @"", first.thumbnailURL ?: @""];
        cell.artworkIdentifier = imageToken;
        NSString *art = first.artworkFilePath.length ? first.artworkFilePath : nil;
        if (art.length) {
            NSString *expectedToken = [imageToken copy];
            [[waImageLoader sharedLoader] loadLocalImageAtPath:art targetSize:CGSizeMake(44,44) completion:^(UIImage *img){
                if (img && [cell.artworkIdentifier isEqualToString:expectedToken]) cell.imageView.image = img;
            }];
        } else if (first.thumbnailURL.length) {
            NSString *expectedToken = [imageToken copy];
            [[waImageLoader sharedLoader] loadThumbnailAtURL:first.thumbnailURL targetSize:CGSizeMake(112,112) placeholder:waPlaceholderImage() completion:^(UIImage *img){
                if (img && [cell.artworkIdentifier isEqualToString:expectedToken]) cell.imageView.image = img;
            }];
        }
        [cell setExplicit:anyExplicit];
        [cell setDownloadState:waDownloadStateNotFound progress:0];
    } else {
        cell.circleArtwork = NO;
        waDownload *d = self.displayDownloads[ip.row];
        cell.textLabel.text = d.title.length ? d.title : @"Downloaded";
        cell.detailTextLabel.text = d.artist ?: @"";
        cell.imageView.image = waPlaceholderImage();
        NSString *imageToken = [NSString stringWithFormat:@"song:%@:%@:%@", d.identifier ?: @"", d.artworkFilePath ?: @"", d.thumbnailURL ?: @""];
        cell.artworkIdentifier = imageToken;
        NSString *art = d.artworkFilePath.length ? d.artworkFilePath : nil;
        if (art.length) {
            NSString *expectedToken = [imageToken copy];
            [[waImageLoader sharedLoader] loadLocalImageAtPath:art targetSize:CGSizeMake(44,44) completion:^(UIImage *img){
                if (img && [cell.artworkIdentifier isEqualToString:expectedToken]) cell.imageView.image = img;
            }];
        } else if (d.thumbnailURL.length) {
            NSString *expectedToken = [imageToken copy];
            [[waImageLoader sharedLoader] loadThumbnailAtURL:d.thumbnailURL targetSize:CGSizeMake(112,112) placeholder:waPlaceholderImage() completion:^(UIImage *img){
                if (img && [cell.artworkIdentifier isEqualToString:expectedToken]) cell.imageView.image = img;
            }];
        }
        [cell setExplicit:d.isExplicit];
        [cell setDownloadState:d.state progress:d.progress];
    }
    cell.textLabel.textColor = [waTheme primaryTextColor];
    cell.detailTextLabel.textColor = [waTheme secondaryTextColor];
    [cell setLikeItem:nil];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (self.currentFilter==waDownloadsFilterArtists) {
        NSDictionary *group = self.displayArtists[ip.row];
        NSArray *downloads = group[@"downloads"];
        NSString *title = group[@"name"];
        waDownloadDetailListViewController *vc = [[waDownloadDetailListViewController alloc] initWithDownloads:downloads title:title];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    } else if (self.currentFilter==waDownloadsFilterAlbums) {
        NSDictionary *group = self.displayAlbums[ip.row];
        NSArray *downloads = group[@"downloads"];
        NSString *title = group[@"title"];
        waDownloadDetailListViewController *vc = [[waDownloadDetailListViewController alloc] initWithDownloads:downloads title:title];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    } else if (self.currentFilter==waDownloadsFilterPlaylists) {
        NSDictionary *group = self.displayPlaylists[ip.row];
        NSArray *downloads = group[@"downloads"];
        NSString *title = group[@"title"];
        // Metadata: playlist downloads carry groupTitle + explicit etc, shown in detail
        waDownloadDetailListViewController *vc = [[waDownloadDetailListViewController alloc] initWithDownloads:downloads title:title];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    waDownload *d = self.displayDownloads[ip.row];
    if (d.state==waDownloadStateDownloading || d.state==waDownloadStateQueued) {
        return;
    }
    NSString *path = [[waDownloadManager sharedManager] localPathForIdentifier:d.identifier] ?: d.filePath;
    if (d.state!=waDownloadStateCompleted || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    // Build context of current filter's completed items
    NSMutableArray *ctx = [NSMutableArray array];
    for (waDownload *dl in self.displayDownloads) {
        if (dl.state!=waDownloadStateCompleted) continue;
        NSString *p = [[waDownloadManager sharedManager] localPathForIdentifier:dl.identifier] ?: dl.filePath;
        if (!p.length || ![[NSFileManager defaultManager] fileExistsAtPath:p]) continue;
        [ctx addObject:waItemFromDownload(dl)];
    }
    waMediaItem *selected = waItemFromDownload(d);
    NSUInteger idx = [ctx indexOfObjectPassingTest:^BOOL(waMediaItem *obj, NSUInteger i, BOOL *s){ return [obj.trackId isEqualToString:selected.trackId]; }];
    if (idx!=NSNotFound) [[waAudioPlayer sharedPlayer] playItem:ctx[idx] fromContext:ctx title:[self.segmentedControl titleForSegmentAtIndex:self.segmentedControl.selectedSegmentIndex]];
    else if (selected) [[waAudioPlayer sharedPlayer] playItem:selected];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state!=UIGestureRecognizerStateBegan) return;
    NSIndexPath *ip = [self.tableView indexPathForRowAtPoint:[g locationInView:self.tableView]];
    NSInteger count = 0;
    if (self.currentFilter==waDownloadsFilterArtists) count=self.displayArtists.count;
    else if (self.currentFilter==waDownloadsFilterAlbums) count=self.displayAlbums.count;
    else if (self.currentFilter==waDownloadsFilterPlaylists) count=self.displayPlaylists.count;
    else count=self.displayDownloads.count;
    if (!ip || ip.row >= count) return;
    waDownload *d = nil;
    if (self.currentFilter==waDownloadsFilterArtists) {
        NSArray *downloads = self.displayArtists[ip.row][@"downloads"];
        d = downloads.count ? [downloads objectAtIndex:0] : nil;
    } else if (self.currentFilter==waDownloadsFilterAlbums) {
        d = self.displayAlbums[ip.row][@"sample"];
        if (!d) {
            NSArray *downloads = self.displayAlbums[ip.row][@"downloads"];
            d = downloads.count ? [downloads objectAtIndex:0] : nil;
        }
    } else if (self.currentFilter==waDownloadsFilterPlaylists) {
        d = self.displayPlaylists[ip.row][@"sample"];
        if (!d) {
            NSArray *downloads = self.displayPlaylists[ip.row][@"downloads"];
            d = downloads.count ? [downloads objectAtIndex:0] : nil;
        }
    }
    else d = self.displayDownloads[ip.row];
    if (!d) return;
    waMediaItem *it = waItemFromDownload(d);
    if (it) [waMediaActionSheet presentForItem:it inViewController:self albumItems:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)ip { (void)ip; return YES; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)ip { (void)ip; return UITableViewCellEditingStyleDelete; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    if (style!=UITableViewCellEditingStyleDelete) return;
    if (self.currentFilter==waDownloadsFilterArtists) {
        NSArray *arr = self.displayArtists[ip.row][@"downloads"];
        for (waDownload *dl in arr) [[waDownloadManager sharedManager] deleteDownloadWithIdentifier:dl.identifier completion:nil];
    } else if (self.currentFilter==waDownloadsFilterAlbums) {
        NSArray *arr = self.displayAlbums[ip.row][@"downloads"];
        for (waDownload *dl in arr) [[waDownloadManager sharedManager] deleteDownloadWithIdentifier:dl.identifier completion:nil];
    } else if (self.currentFilter==waDownloadsFilterPlaylists) {
        NSArray *arr = self.displayPlaylists[ip.row][@"downloads"];
        for (waDownload *dl in arr) [[waDownloadManager sharedManager] deleteDownloadWithIdentifier:dl.identifier completion:nil];
    } else {
        waDownload *d = self.displayDownloads[ip.row];
        if (d) [[waDownloadManager sharedManager] deleteDownloadWithIdentifier:d.identifier completion:nil];
    }
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
