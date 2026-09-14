#import "waMediaResultsViewController.h"
#import "waMediaDetailViewController.h"
#import "waPlaylistViewController.h"
#import "../Services/waAPIClient.h"
#import "../Services/waAudioPlayer.h"
#import "../Services/waImageLoader.h"
#import "../Services/waTheme.h"
#import "../Views/waArtworkCell.h"
#import "../Views/waHomeSectionCell.h"
#import "../Views/waMediaActionSheet.h"
#import "../Views/waPlaceholder.h"
#import "../Services/waDownloadManager.h"

static NSUInteger waSearchNextIndexFromURL(NSString *nextURL, NSUInteger fallback) {
    if (!nextURL.length) return fallback;
    NSRange marker = [nextURL rangeOfString:@"index="];
    if (marker.location == NSNotFound) return fallback;
    NSString *value = [nextURL substringFromIndex:NSMaxRange(marker)];
    NSRange ampersand = [value rangeOfString:@"&"];
    if (ampersand.location != NSNotFound) value = [value substringToIndex:ampersand.location];
    long long parsed = [value longLongValue];
    return parsed >= 0 ? (NSUInteger)parsed : fallback;
}

@interface waMediaResultsViewController ()
@property (nonatomic, copy) NSArray *items;
@property (nonatomic, assign) waMediaItemType mediaType;
@property (nonatomic, copy) NSString *query;
@property (nonatomic, assign) BOOL loadingMore;
@property (nonatomic, assign) BOOL exhausted;
@property (nonatomic, copy) NSString *nextURL;
@property (nonatomic, assign) NSUInteger nextIndex;
@property (nonatomic, assign) NSUInteger totalCount;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, assign) BOOL downloadReloadScheduled;
- (BOOL)usesHorizontalSection;
- (CGFloat)horizontalSectionHeight;
- (void)selectResultItem:(waMediaItem *)item context:(NSArray *)context;
- (void)loadMoreResults:(id)sender;
- (void)updateMoreFooter;
@end

@implementation waMediaResultsViewController

- (id)initWithItems:(NSArray *)items type:(waMediaItemType)type title:(NSString *)title {
    return [self initWithItems:items type:type title:title query:nil];
}

- (id)initWithItems:(NSArray *)items type:(waMediaItemType)type title:(NSString *)title query:(NSString *)query {
    return [self initWithItems:items type:type title:title query:query nextURL:nil totalCount:0];
}

- (id)initWithItems:(NSArray *)items type:(waMediaItemType)type title:(NSString *)title query:(NSString *)query nextURL:(NSString *)nextURL totalCount:(NSUInteger)totalCount {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _items = [items copy] ?: @[];
        _mediaType = type;
        _query = [query copy];
        _nextURL = [nextURL copy];
        _nextIndex = waSearchNextIndexFromURL(_nextURL, _items.count);
        _totalCount = totalCount;
        _exhausted = !_query.length || (!_nextURL.length && (!_totalCount || _items.count >= _totalCount));
        self.title = [title copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView.backgroundColor = [waTheme backgroundColor];
    UIView *tableBackground = [[UIView alloc] initWithFrame:CGRectZero];
    tableBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableBackground.backgroundColor = [waTheme backgroundColor];
    self.tableView.backgroundView = tableBackground;
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.55;
    [self.tableView addGestureRecognizer:longPress];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadDidChange:) name:waDownloadManagerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    [self updateMoreFooter];
    [waTheme applyToView:self.view];
}

- (void)reloadDownloadTable { self.downloadReloadScheduled = NO; if (self.view.window) [self.tableView reloadData]; }
- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.tableView.backgroundColor = [waTheme backgroundColor];
    [self updateMoreFooter];
    if (self.view.window) [self.tableView reloadData];
}
- (void)downloadDidChange:(NSNotification *)notification {
    if (!self.view.window) return;
    if ([notification.userInfo[@"event"] isEqualToString:@"progress"]) {
        if (self.downloadReloadScheduled) return;
        self.downloadReloadScheduled = YES;
        [self performSelector:@selector(reloadDownloadTable) withObject:nil afterDelay:0.4];
    } else [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self usesHorizontalSection] ? (self.items.count ? 1 : 0) : self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    if ([self usesHorizontalSection]) {
        waHomeSectionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"media-results-home-section"];
        if (!cell) cell = [[waHomeSectionCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"media-results-home-section"];
        NSString *layout = self.mediaType == waMediaItemTypeArtist ? @"circle" : @"square";
        NSDictionary *section = @{
            @"title": self.title ?: @"Results",
            @"subtitle": @"",
            @"layout": layout,
            @"items": self.items
        };
        __weak waMediaResultsViewController *weakSelf = self;
        [cell.sectionView resetScrollPosition];
        [cell.sectionView configureWithSection:section selection:^(waMediaItem *item, NSArray *context) {
            waMediaResultsViewController *controller = weakSelf;
            if (controller) [controller selectResultItem:item context:context];
        }];
        cell.sectionView.longPress = ^(waMediaItem *item, NSArray *context) {
            waMediaResultsViewController *controller = weakSelf;
            if (controller) [waMediaActionSheet presentForItem:item inViewController:controller albumItems:context];
        };
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"media-result"];
    if (!cell) {
        cell = [[waArtworkCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"media-result"];
        // Flat full-width rows: style once here, never walk the subtree per row.
        ((waArtworkCell *)cell).cardStyle = NO;
        cell.backgroundColor = [waTheme backgroundColor];
        UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
        selected.backgroundColor = [waTheme selectedSurfaceColor];
        cell.selectedBackgroundView = selected;
    }
    waMediaItem *item = path.row < self.items.count ? self.items[path.row] : nil;
    cell.backgroundColor = [waTheme backgroundColor];
    cell.textLabel.textColor = [waTheme primaryTextColor];
    cell.detailTextLabel.textColor = [waTheme secondaryTextColor];
    [(waArtworkCell *)cell setLikeItem:item];
    cell.textLabel.text = item.title;
    cell.detailTextLabel.text = item.subtitle;
    cell.imageView.image = waPlaceholderImage();
     NSString *downloadIdentifier = item.trackId.length ? item.trackId : item.identifier;
    waDownload *download = self.mediaType == waMediaItemTypeSong ? [[waDownloadManager sharedManager] downloadForIdentifier:downloadIdentifier] : nil;
    [(waArtworkCell *)cell setDownloadState:download ? download.state : waDownloadStateNotFound progress:download.progress];
    [(waArtworkCell *)cell setExplicit:item.isExplicit];
    cell.accessoryType = self.mediaType == waMediaItemTypeSong ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    if (item.thumbnailURL.length) {
        NSString *expectedURL = [item.thumbnailURL copy];
        NSURL *url = [NSURL URLWithString:expectedURL];
        if (!url.scheme.length) url = [[waAPIClient sharedClient] URLForPath:expectedURL];
        [[waImageLoader sharedLoader] loadThumbnailAtURL:url.absoluteString targetSize:CGSizeMake(112.0, 112.0) placeholder:waPlaceholderImage() completion:^(UIImage *image) {
            waMediaItem *current = path.row < self.items.count ? self.items[path.row] : nil;
            NSIndexPath *currentPath = [tableView indexPathForCell:cell];
            if (current == item && [current.thumbnailURL isEqualToString:expectedURL] && [currentPath isEqual:path]) cell.imageView.image = image;
        }];
    }
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    return [self usesHorizontalSection] ? [self horizontalSectionHeight] : 56.0;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.row >= self.items.count) return;
    if ([self usesHorizontalSection]) return;
    waMediaItem *item = self.items[path.row];
    if (self.mediaType == waMediaItemTypeSong) {
        [[waAudioPlayer sharedPlayer] playItem:item fromContext:self.items title:self.title];
    } else if (self.mediaType == waMediaItemTypePlaylist) {
         NSDictionary *playlist = @{ @"id": item.identifier ?: @"", @"title": item.title ?: @"Playlist", @"name": item.title ?: @"Playlist", @"description": @"", @"thumbnailURL": item.thumbnailURL ?: @"", @"artwork": item.thumbnailURL ?: @"", @"liked": @(item.isLiked) };
        [self.navigationController pushViewController:[[waPlaylistViewController alloc] initWithPlaylist:playlist ownerIsCurrentUser:NO] animated:YES];
    } else {
        [self.navigationController pushViewController:[[waMediaDetailViewController alloc] initWithMediaItem:item] animated:YES];
    }
}

- (BOOL)usesHorizontalSection {
    return self.mediaType == waMediaItemTypeAlbum || self.mediaType == waMediaItemTypeArtist;
}

- (CGFloat)horizontalSectionHeight {
    return self.mediaType == waMediaItemTypeArtist ? 282.0 : 357.0;
}

- (void)selectResultItem:(waMediaItem *)item context:(NSArray *)context {
    if (!item) return;
    if (self.mediaType == waMediaItemTypeSong) {
        [[waAudioPlayer sharedPlayer] playItem:item fromContext:context title:self.title];
    } else if (self.mediaType == waMediaItemTypePlaylist) {
        NSDictionary *playlist = @{ @"id": item.identifier ?: @"", @"title": item.title ?: @"Playlist", @"name": item.title ?: @"Playlist", @"description": @"", @"thumbnailURL": item.thumbnailURL ?: @"", @"artwork": item.thumbnailURL ?: @"", @"liked": @(item.isLiked) };
        [self.navigationController pushViewController:[[waPlaylistViewController alloc] initWithPlaylist:playlist ownerIsCurrentUser:NO] animated:YES];
    } else {
        [self.navigationController pushViewController:[[waMediaDetailViewController alloc] initWithMediaItem:item] animated:YES];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan || [self usesHorizontalSection]) return;
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:[gesture locationInView:self.tableView]];
    if (!path || path.row >= self.items.count) return;
    waMediaItem *item = self.items[path.row];
    if (item.type == waMediaItemTypeSong || item.type == waMediaItemTypeAlbum || item.type == waMediaItemTypePlaylist) {
        [waMediaActionSheet presentForItem:item inViewController:self albumItems:nil];
    }
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

#pragma mark - Pagination

- (void)updateMoreFooter {
    if (!self.query.length || self.exhausted) {
        self.tableView.tableFooterView = nil;
        return;
    }
    if (!self.moreButton) {
        self.moreButton = [UIButton buttonWithType:UIButtonTypeCustom];
        self.moreButton.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.moreButton.titleLabel.font = [waTheme boldFontOfSize:15.0];
        [self.moreButton addTarget:self action:@selector(loadMoreResults:) forControlEvents:UIControlEventTouchUpInside];
    }
    self.moreButton.frame = CGRectMake(0.0, 0.0, self.tableView.bounds.size.width, 44.0);
    [self.moreButton setTitle:self.loadingMore ? @"Loading…" : @"Load more results" forState:UIControlStateNormal];
    [self.moreButton setTitleColor:[waTheme barColor] forState:UIControlStateNormal];
    self.moreButton.enabled = !self.loadingMore;
    self.tableView.tableFooterView = self.moreButton;
}

- (void)loadMoreResults:(id)sender {
    (void)sender;
    if (self.loadingMore || self.exhausted || !self.query.length) return;
    NSArray *types = @[@"song", @"album", @"artist", @"playlist"];
    if (self.mediaType < 0 || self.mediaType >= (NSInteger)types.count) return;
    self.loadingMore = YES;
    [self updateMoreFooter];
    NSUInteger offset = self.nextURL.length ? self.nextIndex : self.items.count;
    NSString *query = [self.query copy];
    __weak waMediaResultsViewController *weakSelf = self;
    [[waAPIClient sharedClient] searchPageForQuery:query type:types[self.mediaType] limit:25 index:offset strict:NO completion:^(NSDictionary *page, NSError *error) {
        waMediaResultsViewController *controller = weakSelf;
        if (!controller || ![query isEqualToString:controller.query]) return;
        controller.loadingMore = NO;
        NSArray *rows = [page[@"items"] isKindOfClass:[NSArray class]] ? page[@"items"] : @[];
        if (!error && [page isKindOfClass:[NSDictionary class]]) {
            NSMutableArray *combined = [controller.items mutableCopy] ?: [NSMutableArray array];
            NSMutableSet *known = [NSMutableSet set];
            for (waMediaItem *existing in combined) {
                NSString *key = existing.identifier.length ? existing.identifier : existing.trackId;
                if (key.length) [known addObject:key];
            }
            NSUInteger before = combined.count;
            for (NSDictionary *dictionary in rows) {
                if (![dictionary isKindOfClass:[NSDictionary class]]) continue;
                waMediaItem *item = [waMediaItem itemWithDictionary:dictionary];
                if (!item) continue;
                item.type = controller.mediaType;
                NSString *key = item.identifier.length ? item.identifier : item.trackId;
                if (key.length && [known containsObject:key]) continue;
                if (key.length) [known addObject:key];
                [combined addObject:item];
            }
            controller.items = combined;
            NSString *nextURL = [page[@"next"] isKindOfClass:[NSString class]] ? page[@"next"] : @"";
            NSUInteger total = [page[@"total"] respondsToSelector:@selector(unsignedIntegerValue)] ? [page[@"total"] unsignedIntegerValue] : controller.totalCount;
            BOOL appended = combined.count > before;
            BOOL repeatedNext = nextURL.length && [nextURL isEqualToString:controller.nextURL];
            controller.nextURL = nextURL;
            controller.nextIndex = waSearchNextIndexFromURL(nextURL, offset + rows.count);
            controller.totalCount = total;
            controller.exhausted = !appended || repeatedNext || (!nextURL.length && (!total || combined.count >= total));
        } else if (error) {
            [[[UIAlertView alloc] initWithTitle:@"Search" message:error.localizedDescription ?: @"Unable to load more results." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        }
        [controller updateMoreFooter];
        if (controller.view.window) [controller.tableView reloadData];
    }];
}

@end
