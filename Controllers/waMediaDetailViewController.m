#import "waMediaDetailViewController.h"
#import "../Services/waAPIClient.h"
#import "../Services/waAudioPlayer.h"
#import "../Services/waDownloadManager.h"
#import "../Services/waImageLoader.h"
#import "../Services/waTheme.h"
#import "../Views/waCatalogInfoCard.h"
#import "../Views/waCatalogTrackCell.h"
#import "../Views/waCatalogSectionHeaderView.h"
#import "../Views/waHomeSectionCell.h"
#import "../Views/waMediaActionSheet.h"
#import "../Views/waPlaceholder.h"
#import "../Models/waAlbum.h"
#import "../Models/waArtist.h"
#import "../Models/waDownload.h"

@interface waMediaDetailViewController () <UITableViewDataSource, UITableViewDelegate, waCatalogInfoCardDelegate, waCatalogTrackCellDelegate>
@property (nonatomic, strong) waMediaItem *mediaItem;
@property (nonatomic, strong) UITableView *catalogTableView;
@property (nonatomic, strong) waCatalogInfoCard *infoCard;
@property (nonatomic, strong) waCatalogSectionHeaderView *tracksHeader;
@property (nonatomic, strong) UIView *infoContainer;
@property (nonatomic, strong) UIActivityIndicatorView *navigationSpinner;
@property (nonatomic, strong) NSArray *tracks;
@property (nonatomic, strong) NSArray *shelves;
@property (nonatomic, strong) NSDictionary *catalogMetadata;
@property (nonatomic, copy) NSString *listenerText;
@property (nonatomic, copy) NSString *providedArtworkPath;
@property (nonatomic, assign) BOOL usesProvidedTracks;
@property (nonatomic, assign) BOOL tracksExpanded;
@property (nonatomic, assign) NSUInteger catalogTrackCount;
@property (nonatomic, assign) NSUInteger requestGeneration;
@property (nonatomic, assign) BOOL downloadReloadScheduled;
@property (nonatomic, assign) BOOL hasLaidOut;
@property (nonatomic, assign) BOOL lastLayoutLandscape;
@end

static NSString *waCatalogString(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    if ([value isKindOfClass:[NSDictionary class]]) return waCatalogString(value[@"name"]) ?: waCatalogString(value[@"title"]);
    return nil;
}

static NSString *waCatalogCount(id value) {
    NSString *text = waCatalogString(value);
    if (!text.length) return nil;
    NSString *digits = [text stringByReplacingOccurrencesOfString:@"," withString:@""];
    if ([digits rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) return text;
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = YES;
    formatter.groupingSeparator = @",";
    formatter.groupingSize = 3;
    return [formatter stringFromNumber:@([digits longLongValue])];
}

static NSString *waCatalogYear(id value) {
    NSString *text = waCatalogString(value);
    if (!text.length) return nil;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    for (NSUInteger index = 0; index + 4 <= text.length; index++) {
        NSString *candidate = [text substringWithRange:NSMakeRange(index, 4)];
        if ([candidate rangeOfCharacterFromSet:nonDigits].location == NSNotFound) return candidate;
    }
    return nil;
}

static NSString *waCatalogRecordType(waMediaItem *item) {
    NSDictionary *raw = [item.metadata[@"deezerRaw"] isKindOfClass:[NSDictionary class]] ? item.metadata[@"deezerRaw"] : nil;
    NSString *type = waCatalogString(item.metadata[@"recordType"]) ?: waCatalogString(item.metadata[@"record_type"]) ?: waCatalogString(raw[@"record_type"]) ?: waCatalogString(raw[@"ALB_TYPE"]) ?: @"album";
    return [type lowercaseString];
}

static BOOL waCatalogTitleContains(NSString *title, NSString *term) {
    return [[title lowercaseString] rangeOfString:term].location != NSNotFound;
}

static BOOL waCatalogTracksAreDownloaded(NSArray *tracks) {
    if (![tracks isKindOfClass:[NSArray class]] || !tracks.count) return NO;
    waDownloadManager *manager = [waDownloadManager sharedManager];
    for (waMediaItem *track in tracks) {
        NSString *identifier = track.trackId.length ? track.trackId : track.identifier;
        waDownload *download = [manager downloadForIdentifier:identifier];
        if (!download || download.state != waDownloadStateCompleted || ![manager localPathForIdentifier:identifier].length) return NO;
    }
    return YES;
}

@implementation waMediaDetailViewController

- (id)initWithMediaItem:(waMediaItem *)mediaItem { return [self initWithMediaItem:mediaItem tracks:nil]; }
- (id)initWithMediaItem:(waMediaItem *)mediaItem tracks:(NSArray *)tracks { return [self initWithMediaItem:mediaItem tracks:tracks artworkPath:nil]; }

- (id)initWithMediaItem:(waMediaItem *)mediaItem tracks:(NSArray *)tracks artworkPath:(NSString *)artworkPath {
    if (![mediaItem isKindOfClass:[waMediaItem class]]) return nil;
    if ((self = [super init])) {
        _mediaItem = mediaItem;
        _tracks = [tracks copy] ?: (mediaItem.type == waMediaItemTypeSong ? @[mediaItem] : @[]);
        _shelves = @[];
        _catalogMetadata = @{};
        _providedArtworkPath = [artworkPath copy];
        _usesProvidedTracks = tracks != nil;
        _catalogTrackCount = _tracks.count;
        self.title = mediaItem.title;
    }
    return self;
}

- (BOOL)isLandscape { return self.view.bounds.size.width > self.view.bounds.size.height; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [waTheme backgroundColor];

    self.catalogTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.catalogTableView.delegate = self;
    self.catalogTableView.dataSource = self;
    self.catalogTableView.backgroundColor = [waTheme backgroundColor];
    self.catalogTableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.catalogTableView.separatorColor = [waTheme separatorColor];
    self.catalogTableView.showsVerticalScrollIndicator = NO;
    self.catalogTableView.sectionHeaderHeight = 0.0;
    self.catalogTableView.sectionFooterHeight = 0.0;
    UIView *background = [[UIView alloc] initWithFrame:CGRectZero];
    background.backgroundColor = [waTheme backgroundColor];
    background.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.catalogTableView.backgroundView = background;
    [self.view addSubview:self.catalogTableView];

    self.infoContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.infoContainer.backgroundColor = [UIColor clearColor];
    self.infoContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.infoCard = [[waCatalogInfoCard alloc] initWithFrame:CGRectZero];
    self.infoCard.delegate = self;
    [self.infoContainer addSubview:self.infoCard];
    self.tracksHeader = [[waCatalogSectionHeaderView alloc] initWithTitle:@"Tracks" actionTitle:nil action:nil];
    [self.infoContainer addSubview:self.tracksHeader];
    [self updateInfoCard];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.55;
    [self.catalogTableView addGestureRecognizer:longPress];
    UILongPressGestureRecognizer *artworkLongPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleHeaderLongPress:)];
    artworkLongPress.minimumPressDuration = 0.55;
    self.infoCard.coverView.userInteractionEnabled = YES;
    [self.infoCard.coverView addGestureRecognizer:artworkLongPress];

    self.navigationSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadStateDidChange:) name:waDownloadManagerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mediaLikeDidChange:) name:waMediaLikeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    [waTheme applyToView:self.view];

    if (self.usesProvidedTracks) {
        self.tracks = [self normalizedTracks:self.tracks albumContext:self.mediaItem.type == waMediaItemTypeAlbum ? self.mediaItem : nil];
        [self updateInfoCard];
        if (self.providedArtworkPath.length) [self loadLocalArtwork];
    } else if (self.mediaItem.type == waMediaItemTypeSong) {
        self.tracks = @[self.mediaItem];
        [self updateInfoCard];
    } else {
        [self loadCatalog];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.catalogTableView.frame = self.view.bounds;
    [self layoutInfoCard];
    BOOL landscape = [self isLandscape];
    if (self.hasLaidOut && landscape != self.lastLayoutLandscape && self.catalogTableView.window) {
        [self.catalogTableView beginUpdates];
        [self.catalogTableView endUpdates];
    }
    self.lastLayoutLandscape = landscape;
    self.hasLaidOut = YES;
}

- (void)layoutInfoCard {
    if (!self.infoCard || !self.infoContainer || !self.catalogTableView) return;
    CGFloat width = self.catalogTableView.bounds.size.width;
    if (width <= 0.0) return;
    CGFloat cardHeight = [self.infoCard preferredHeightForWidth:width landscape:[self isLandscape]];
    CGFloat headerHeight = 42.0;
    CGRect oldHeaderFrame = self.infoContainer.frame;
    CGRect newHeaderFrame = CGRectMake(0.0, 0.0, width, cardHeight + headerHeight);
    BOOL headerChanged = !CGRectEqualToRect(oldHeaderFrame, newHeaderFrame) || self.catalogTableView.tableHeaderView != self.infoContainer;
    self.infoContainer.frame = newHeaderFrame;
    self.infoCard.frame = CGRectMake(0.0, 0.0, width, cardHeight);
    self.tracksHeader.frame = CGRectMake(0.0, cardHeight, width, headerHeight);
    [self.infoCard setNeedsLayout];
    [self.infoCard layoutIfNeeded];
    // UITableView reads tableHeaderView's height from its frame on iOS 6.
    if (headerChanged) self.catalogTableView.tableHeaderView = self.infoContainer;
}

- (void)updateCatalogTrackHeader {
    if (!self.tracksHeader) return;
    self.tracksHeader.title = self.mediaItem.type == waMediaItemTypeArtist ? @"Top Tracks" : @"Tracks";
    // The expandable control belongs to the final row below Top Tracks. The
    // section header remains a static title so Artist View has one clear
    // "See more top tracks" affordance.
    self.tracksHeader.actionTitle = nil;
    [self.tracksHeader setNeedsLayout];
}

- (void)updateInfoCard {
    NSString *detail = nil;
    if (self.mediaItem.type == waMediaItemTypeAlbum) {
        NSUInteger count = self.catalogTrackCount;
        if (!count && [self.mediaItem isKindOfClass:[waAlbum class]]) count = [(waAlbum *)self.mediaItem trackCount];
        NSString *year = waCatalogYear(self.mediaItem.releaseYear);
        NSString *type = waCatalogRecordType(self.mediaItem);
        NSString *prettyType = [type isEqualToString:@"ep"] ? @"EP" : ([type isEqualToString:@"single"] ? @"Single" : ([type isEqualToString:@"compilation"] ? @"Compilation" : ([type isEqualToString:@"live"] ? @"Live album" : @"Album")));
        NSMutableArray *parts = [NSMutableArray array];
        if (year.length) [parts addObject:year];
        if (count) [parts addObject:[NSString stringWithFormat:@"%lu songs", (unsigned long)count]];
        if (prettyType.length) [parts addObject:prettyType];
        detail = [parts componentsJoinedByString:@" • "];
    } else if (self.mediaItem.type == waMediaItemTypeArtist) {
        NSMutableArray *parts = [NSMutableArray array];
        if (self.listenerText.length) [parts addObject:self.listenerText];
        id albumCount = self.catalogMetadata[@"albumCount"] ?: self.catalogMetadata[@"nb_album"];
        NSString *albums = waCatalogCount(albumCount);
        if (albums.length) [parts addObject:[NSString stringWithFormat:@"%@ releases", albums]];
        detail = [parts componentsJoinedByString:@" • "];
    }
    [self.infoCard configureWithItem:self.mediaItem listenerText:self.listenerText detailText:detail];
    self.infoCard.playAllButton.enabled = self.tracks.count > 0;
    [self.infoCard.downloadButton setTitle:waCatalogTracksAreDownloaded(self.tracks) ? @"Downloaded" : @"Download" forState:UIControlStateNormal];
    [self updateCatalogTrackHeader];
    self.title = self.mediaItem.title ?: @"Catalog";
    [self layoutInfoCard];
}

- (void)loadLocalArtwork {
    NSUInteger generation = self.requestGeneration;
    [[waImageLoader sharedLoader] loadLocalImageAtPath:self.providedArtworkPath targetSize:CGSizeMake(256.0, 256.0) completion:^(UIImage *image) {
        if (generation == self.requestGeneration && image) self.infoCard.coverView.image = image;
    }];
}

- (void)loadArtworkFromURLString:(NSString *)artworkURL generation:(NSUInteger)generation {
    if (!artworkURL.length) return;
    NSURL *url = [NSURL URLWithString:artworkURL];
    if (!url.scheme.length) url = [[waAPIClient sharedClient] URLForPath:artworkURL];
    if (!url) return;
    [[waImageLoader sharedLoader] loadThumbnailAtURL:url.absoluteString targetSize:CGSizeMake(320.0, 320.0) placeholder:waPlaceholderImage() completion:^(UIImage *image) {
        if (generation == self.requestGeneration && image) self.infoCard.coverView.image = image;
    }];
}

- (NSArray *)normalizedTracks:(NSArray *)rawTracks albumContext:(waMediaItem *)albumContext {
    if (![rawTracks isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:rawTracks.count];
    for (id object in rawTracks) {
        waMediaItem *item = [object isKindOfClass:[waMediaItem class]] ? object : ([object isKindOfClass:[NSDictionary class]] ? [waMediaItem itemWithDictionary:object] : nil);
        if (!item) continue;
        item.type = waMediaItemTypeSong;
        if (albumContext) {
            if (!item.artistName.length) item.artistName = albumContext.artistName ?: albumContext.subtitle;
            if (!item.albumName.length) item.albumName = albumContext.title;
            if (!item.thumbnailURL.length) item.thumbnailURL = albumContext.thumbnailURL;
        }
        if (!item.subtitle.length) item.subtitle = item.artistName;
        [items addObject:item];
    }
    return items;
}

- (NSArray *)albumObjectsFromCatalog:(NSDictionary *)catalog {
    id all = catalog[@"allAlbums"] ?: catalog[@"albums"];
    if (![all isKindOfClass:[NSArray class]]) all = @[];
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:[all count]];
    for (id object in all) {
        waMediaItem *item = [object isKindOfClass:[waMediaItem class]] ? object : ([object isKindOfClass:[NSDictionary class]] ? [waMediaItem itemWithDictionary:object] : nil);
        if (item) { item.type = waMediaItemTypeAlbum; [items addObject:item]; }
    }
    return items;
}

- (NSArray *)shelvesFromCatalog:(NSDictionary *)catalog {
    NSArray *allAlbums = [self albumObjectsFromCatalog:catalog];
    NSMutableArray *albums = [NSMutableArray array], *live = [NSMutableArray array], *eps = [NSMutableArray array], *singles = [NSMutableArray array], *compilations = [NSMutableArray array], *other = [NSMutableArray array];
    for (waMediaItem *item in allAlbums) {
        NSString *type = waCatalogRecordType(item);
        NSString *title = item.title ?: @"";
        if ([type rangeOfString:@"single"].location != NSNotFound) [singles addObject:item];
        else if ([type rangeOfString:@"ep"].location != NSNotFound) [eps addObject:item];
        else if ([type rangeOfString:@"compilation"].location != NSNotFound) [compilations addObject:item];
        else if ([type rangeOfString:@"live"].location != NSNotFound || waCatalogTitleContains(title, @"live") || waCatalogTitleContains(title, @"concert")) [live addObject:item];
        else if ([type isEqualToString:@"album"] || !type.length) [albums addObject:item];
        else [other addObject:item];
    }
    NSArray *groups = @[
        @{ @"title": @"Albums", @"items": albums },
        @{ @"title": @"Live Albums", @"items": live },
        @{ @"title": @"EPs", @"items": eps },
        @{ @"title": @"Singles", @"items": singles },
        @{ @"title": @"Compilations", @"items": compilations },
        @{ @"title": @"Other Releases", @"items": other }
    ];
    NSMutableArray *usable = [NSMutableArray array];
    for (NSDictionary *group in groups) if ([group[@"items"] count]) [usable addObject:@{ @"title": group[@"title"], @"layout": @"square", @"items": group[@"items"] }];
    return usable;
}

- (NSString *)catalogArtworkURL:(NSDictionary *)catalog {
    NSString *url = waCatalogString(catalog[@"thumbnail"]) ?: waCatalogString(catalog[@"thumbnailURL"]);
    if (!url.length && [catalog[@"thumbnails"] isKindOfClass:[NSArray class]] && [catalog[@"thumbnails"] count]) {
        id first = catalog[@"thumbnails"][0];
        url = [first isKindOfClass:[NSDictionary class]] ? waCatalogString(first[@"url"]) : waCatalogString(first);
    }
    return url;
}

- (void)loadCatalog {
    if (!self.mediaItem.identifier.length) {
        self.infoCard.stateLabel.text = @"This item has no catalog identifier.";
        [self updateInfoCard];
        return;
    }
    NSUInteger generation = ++self.requestGeneration;
    self.infoCard.stateLabel.text = @"Loading catalog…";
    self.navigationItem.titleView = self.navigationSpinner;
    [self.navigationSpinner startAnimating];
    NSString *type = self.mediaItem.type == waMediaItemTypeAlbum ? @"albums" : @"artists";
    [[waAPIClient sharedClient] catalogType:type identifier:self.mediaItem.identifier completion:^(NSDictionary *catalog, NSError *error) {
        if (generation != self.requestGeneration) return;
        [self.navigationSpinner stopAnimating];
        self.navigationItem.titleView = nil;
        self.catalogMetadata = [catalog isKindOfClass:[NSDictionary class]] ? catalog : @{};
        if (error || !catalog.count) {
            self.infoCard.stateLabel.text = @"Unable to load catalog information";
            [self updateInfoCard];
            return;
        }

        NSString *catalogTitle = waCatalogString(catalog[@"title"]) ?: waCatalogString(catalog[@"name"]);
        if (catalogTitle.length) self.mediaItem.title = catalogTitle;
        if (self.mediaItem.type == waMediaItemTypeAlbum) {
            NSString *artist = waCatalogString(catalog[@"artist"]) ?: waCatalogString(catalog[@"author"]) ?: waCatalogString(catalog[@"artistName"]);
            if (artist.length) { self.mediaItem.artistName = artist; self.mediaItem.subtitle = artist; }
            NSString *year = waCatalogYear(catalog[@"releaseDate"] ?: catalog[@"release_date"] ?: catalog[@"releaseYear"]);
            if (year.length) self.mediaItem.releaseYear = year;
            id count = catalog[@"trackCount"] ?: catalog[@"track_count"] ?: catalog[@"nb_tracks"];
            if ([count respondsToSelector:@selector(unsignedIntegerValue)]) self.catalogTrackCount = [count unsignedIntegerValue];
            else if ([count isKindOfClass:[NSArray class]]) self.catalogTrackCount = [count count];
            NSArray *raw = [catalog[@"tracks"] isKindOfClass:[NSArray class]] ? catalog[@"tracks"] : catalog[@"songs"];
            self.tracks = [self normalizedTracks:raw albumContext:self.mediaItem];
            if (!self.catalogTrackCount) self.catalogTrackCount = self.tracks.count;
            self.shelves = @[];
        } else {
            NSString *name = waCatalogString(catalog[@"name"]) ?: waCatalogString(catalog[@"title"]);
            if (name.length) self.mediaItem.title = name;
            id fans = catalog[@"fans"] ?: catalog[@"fanCount"] ?: catalog[@"nb_fan"] ?: catalog[@"monthlyListeners"];
            NSString *fanCount = waCatalogCount(fans);
            self.listenerText = fanCount.length ? [NSString stringWithFormat:@"%@ fans", fanCount] : @"";
            NSArray *raw = [catalog[@"tracks"] isKindOfClass:[NSArray class]] ? catalog[@"tracks"] : catalog[@"songs"];
            self.tracks = [self normalizedTracks:raw albumContext:nil];
            self.shelves = [self shelvesFromCatalog:catalog];
        }
        self.infoCard.stateLabel.text = (self.tracks.count || self.shelves.count) ? @"" : @"No catalog items found";
        NSString *artworkURL = self.mediaItem.thumbnailURL.length ? self.mediaItem.thumbnailURL : [self catalogArtworkURL:catalog];
        if (artworkURL.length) self.mediaItem.thumbnailURL = artworkURL;
        [self updateInfoCard];
        [self loadArtworkFromURLString:artworkURL generation:generation];
        [self.catalogTableView reloadData];
    }];
}

- (void)playCurrentItem {
    NSArray *context = self.mediaItem.type == waMediaItemTypeSong ? @[self.mediaItem] : self.tracks;
    if (context.count) [[waAudioPlayer sharedPlayer] playItem:context[0] fromContext:context title:self.mediaItem.title];
}

- (void)catalogInfoCardDidPressLike:(waCatalogInfoCard *)card {
    if (![[waAPIClient sharedClient] isAuthenticated]) {
        [[[UIAlertView alloc] initWithTitle:@"Like" message:@"Sign in to save this item." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        return;
    }
    BOOL liked = !self.mediaItem.isLiked;
    self.mediaItem.liked = liked;
    card.likeButton.selected = liked;
    card.likeButton.enabled = NO;
    void (^completion)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        card.likeButton.enabled = YES;
        if (!success) {
            self.mediaItem.liked = !liked;
            card.likeButton.selected = self.mediaItem.isLiked;
            [[[UIAlertView alloc] initWithTitle:@"Like" message:error.localizedDescription ?: @"Unable to update like." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
            return;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:waMediaLikeDidChangeNotification object:self.mediaItem userInfo:@{waMediaLikeIdentifierKey: self.mediaItem.identifier ?: @"", waMediaLikeTypeKey: @(self.mediaItem.type)}];
    };
    if (self.mediaItem.type == waMediaItemTypeAlbum) [[waAPIClient sharedClient] setLiked:liked album:self.mediaItem completion:completion];
    else if (self.mediaItem.type == waMediaItemTypeArtist) [[waAPIClient sharedClient] setLiked:liked artist:self.mediaItem completion:completion];
    else [[waAPIClient sharedClient] setLiked:liked song:self.mediaItem completion:completion];
}

- (void)catalogInfoCardDidPressDownload:(waCatalogInfoCard *)card {
    (void)card;
    if (self.mediaItem.type == waMediaItemTypeAlbum) {
        for (waMediaItem *track in self.tracks) {
            if (!track.albumName.length) track.albumName = self.mediaItem.title;
            if (!track.artistName.length) track.artistName = self.mediaItem.artistName;
            if (!track.thumbnailURL.length) track.thumbnailURL = self.mediaItem.thumbnailURL;
            [[waDownloadManager sharedManager] enqueueDownloadWithItem:track category:waDownloadCategoryAlbum contextIdentifier:self.mediaItem.identifier ?: self.mediaItem.title groupTitle:self.mediaItem.title];
        }
    } else if (self.mediaItem.type == waMediaItemTypeSong) {
        [[waDownloadManager sharedManager] enqueueDownloadWithItem:self.mediaItem category:waDownloadCategorySong contextIdentifier:self.mediaItem.trackId ?: self.mediaItem.identifier];
    }
}

- (void)catalogInfoCardDidPressPlayAll:(waCatalogInfoCard *)card {
    (void)card;
    [self playCurrentItem];
}

- (void)catalogTrackCellDidPressLike:(waCatalogTrackCell *)cell item:(waMediaItem *)item {
    if (!item) return;
    if (![[waAPIClient sharedClient] isAuthenticated]) {
        [[[UIAlertView alloc] initWithTitle:@"Like" message:@"Sign in to save songs to your library." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        return;
    }
    BOOL liked = !item.isLiked;
    item.liked = liked;
    cell.userInteractionEnabled = NO;
    [[waAPIClient sharedClient] setLiked:liked song:item completion:^(BOOL success, NSError *error) {
        cell.userInteractionEnabled = YES;
        if (!success) {
            item.liked = !liked;
            [[[UIAlertView alloc] initWithTitle:@"Like" message:error.localizedDescription ?: @"Unable to update like." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
            [self.catalogTableView reloadData];
            return;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:waMediaLikeDidChangeNotification object:item userInfo:@{waMediaLikeIdentifierKey: item.identifier ?: @"", waMediaLikeTypeKey: @(item.type)}];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.mediaItem.type == waMediaItemTypeArtist ? MAX(1, (NSInteger)self.shelves.count + 1) : 1;
}

- (NSUInteger)visibleTrackCount {
    if (self.mediaItem.type != waMediaItemTypeArtist || self.tracksExpanded) return self.tracks.count;
    return MIN((NSUInteger)5, self.tracks.count);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (self.mediaItem.type == waMediaItemTypeArtist && section > 0) return 1;
    NSUInteger count = [self visibleTrackCount];
    if (self.mediaItem.type == waMediaItemTypeArtist && self.tracks.count > count) count += 1;
    return count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return 0.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return 0.0;
}

- (CGFloat)shelfHeight { return [self isLandscape] ? 253.0 : 295.0; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.mediaItem.type == waMediaItemTypeArtist && indexPath.section > 0) {
        waHomeSectionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"catalog-shelf"];
        if (!cell) cell = [[waHomeSectionCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"catalog-shelf"];
        NSDictionary *section = self.shelves[indexPath.section - 1];
        cell.sectionView.compact = YES;
        cell.sectionView.compactLandscape = [self isLandscape];
        // Weak self: the section view holds this block while the cell lives in
        // the reusable pool, so a strong capture would leak the whole VC.
        __weak waMediaDetailViewController *weakSelf = self;
        [cell.sectionView configureWithSection:section selection:^(waMediaItem *item, NSArray *context) {
            (void)context;
            waMediaDetailViewController *controller = weakSelf;
            if (!item.identifier.length || !controller) return;
            [controller.navigationController pushViewController:[[waMediaDetailViewController alloc] initWithMediaItem:item] animated:YES];
        }];
        cell.sectionView.longPress = ^(waMediaItem *item, NSArray *context) {
            (void)context;
            waMediaDetailViewController *controller = weakSelf;
            if (controller && item) [waMediaActionSheet presentForItem:item inViewController:controller albumItems:nil];
        };
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    NSUInteger visible = [self visibleTrackCount];
    if (self.mediaItem.type == waMediaItemTypeArtist && indexPath.row >= visible) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"catalog-see-more"];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"catalog-see-more"];
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        cell.textLabel.text = self.tracksExpanded ? @"Show fewer top tracks" : @"See more top tracks";
        cell.textLabel.textColor = [waTheme barColor];
        cell.textLabel.font = [waTheme mediumFontOfSize:14.0];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        return cell;
    }

    waCatalogTrackCell *cell = [tableView dequeueReusableCellWithIdentifier:@"catalog-track"];
    if (!cell) cell = [[waCatalogTrackCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"catalog-track"];
    cell.delegate = self;
    waMediaItem *track = indexPath.row < self.tracks.count ? self.tracks[indexPath.row] : nil;
    [cell configureWithItem:track artistName:track.artistName.length ? track.artistName : track.subtitle albumName:track.albumName trackNumber:self.mediaItem.type == waMediaItemTypeAlbum ? indexPath.row + 1 : 0];
    NSString *downloadIdentifier = track.trackId.length ? track.trackId : track.identifier;
    waDownload *download = [[waDownloadManager sharedManager] downloadForIdentifier:downloadIdentifier];
    [cell setDownloadState:download ? download.state : waDownloadStateNotFound progress:download.progress];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (self.mediaItem.type == waMediaItemTypeArtist && indexPath.section > 0) return [self shelfHeight];
    NSUInteger visible = [self visibleTrackCount];
    if (self.mediaItem.type == waMediaItemTypeArtist && indexPath.row >= visible) return 44.0;
    if (self.mediaItem.type == waMediaItemTypeAlbum) return [self isLandscape] ? 52.0 : 56.0;
    return [self isLandscape] ? 64.0 : 72.0;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.mediaItem.type == waMediaItemTypeArtist && indexPath.section > 0) return;
    NSUInteger visible = [self visibleTrackCount];
    if (self.mediaItem.type == waMediaItemTypeArtist && indexPath.row >= visible) {
        self.tracksExpanded = !self.tracksExpanded;
        [tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationAutomatic];
        return;
    }
    if (indexPath.row < self.tracks.count) [[waAudioPlayer sharedPlayer] playItem:self.tracks[indexPath.row] fromContext:self.tracks title:self.mediaItem.title];
}

- (void)handleHeaderLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (self.mediaItem.type == waMediaItemTypeAlbum || self.mediaItem.type == waMediaItemTypeSong) [waMediaActionSheet presentForItem:self.mediaItem inViewController:self albumItems:self.mediaItem.type == waMediaItemTypeAlbum ? self.tracks : nil];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *path = [self.catalogTableView indexPathForRowAtPoint:[gesture locationInView:self.catalogTableView]];
    if (!path || (self.mediaItem.type == waMediaItemTypeArtist && path.section > 0)) return;
    NSUInteger visible = [self visibleTrackCount];
    if (path.row < visible && path.row < self.tracks.count) [waMediaActionSheet presentForItem:self.tracks[path.row] inViewController:self albumItems:nil];
}

- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.view.backgroundColor = [waTheme backgroundColor];
    self.catalogTableView.backgroundColor = [waTheme backgroundColor];
    self.catalogTableView.separatorColor = [waTheme separatorColor];
    [self.infoCard applyTheme];
    if (self.view.window) [self.catalogTableView reloadData];
}

- (void)downloadStateDidChange:(NSNotification *)notification {
    if (!self.view.window) return;
    if ([notification.userInfo[@"event"] isEqualToString:@"progress"]) {
        if (self.downloadReloadScheduled) return;
        self.downloadReloadScheduled = YES;
        [self performSelector:@selector(reloadCatalogTable) withObject:nil afterDelay:0.4];
    } else {
        [self.infoCard.downloadButton setTitle:waCatalogTracksAreDownloaded(self.tracks) ? @"Downloaded" : @"Download" forState:UIControlStateNormal];
        [self.catalogTableView reloadData];
    }
}

- (void)reloadCatalogTable {
    self.downloadReloadScheduled = NO;
    if (self.view.window) {
        [self.infoCard.downloadButton setTitle:waCatalogTracksAreDownloaded(self.tracks) ? @"Downloaded" : @"Download" forState:UIControlStateNormal];
        [self.catalogTableView reloadData];
    }
}

- (void)mediaLikeDidChange:(NSNotification *)notification {
    NSString *identifier = notification.userInfo[waMediaLikeIdentifierKey];
    NSNumber *type = notification.userInfo[waMediaLikeTypeKey];
    if (identifier.length && ![identifier isEqualToString:self.mediaItem.identifier]) {
        [self.catalogTableView reloadData];
        return;
    }
    if (type && type.integerValue != self.mediaItem.type) return;
    if ([notification.object isKindOfClass:[waMediaItem class]]) self.mediaItem.liked = [notification.object isLiked];
    self.infoCard.likeButton.selected = self.mediaItem.isLiked;
    [self.infoCard.likeButton setTitle:self.mediaItem.isLiked ? @"Unlike" : @"Like" forState:UIControlStateNormal];
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadCatalogTable) object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
