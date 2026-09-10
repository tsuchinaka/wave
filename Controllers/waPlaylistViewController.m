#import "waPlaylistViewController.h"
#import "../Models/waMediaItem.h"
#import "../Services/waAPIClient.h"
#import "../Services/waAudioPlayer.h"
#import "../Services/waDownloadManager.h"
#import "../Services/waImageLoader.h"
#import "../Services/waTheme.h"
#import "../Views/waMediaActionSheet.h"
#import "../Views/waCatalogInfoCard.h"
#import "../Views/waCatalogSectionHeaderView.h"
#import "../Views/waCatalogTrackCell.h"
#import "../Views/waPlaceholder.h"
#import "../Models/waDownload.h"

@interface waPlaylistViewController () <UITableViewDataSource, UITableViewDelegate, UIActionSheetDelegate, waCatalogInfoCardDelegate, waCatalogTrackCellDelegate>
@property (nonatomic, strong) UITableView *tracksTableView;
@property (nonatomic, strong) waCatalogInfoCard *infoCard;
@property (nonatomic, strong) waCatalogSectionHeaderView *tracksHeader;
@property (nonatomic, strong) UIView *infoContainer;
@property (nonatomic, strong) UIActivityIndicatorView *navigationSpinner;
@property (nonatomic, strong) NSDictionary *playlist;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, assign) BOOL downloadReloadScheduled;
@property (nonatomic, strong) NSNumber *tracksDownloadedFlag;
@property (nonatomic, copy) NSString *pendingProgressDownloadIdentifier;
@property (nonatomic, assign) NSUInteger requestGeneration;
@property (nonatomic, assign) BOOL ownerIsCurrentUser;
@property (nonatomic, strong) waMediaItem *pendingRemovalItem;
@end

static NSString *waPlaylistString(NSDictionary *dictionary, NSArray *keys) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
    for (NSString *key in keys) {
        id value = dictionary[key];
        if ([value isKindOfClass:[NSString class]] && [value length]) return value;
        if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    }
    return nil;
}

static BOOL waPlaylistBool(NSDictionary *dictionary, NSArray *keys, BOOL fallback) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return fallback;
    for (NSString *key in keys) {
        id value = dictionary[key];
        if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    }
    return fallback;
}

static BOOL waPlaylistTracksAreDownloaded(NSArray *tracks) {
    if (![tracks isKindOfClass:[NSArray class]] || !tracks.count) return NO;
    waDownloadManager *manager = [waDownloadManager sharedManager];
    for (waMediaItem *track in tracks) {
        NSString *identifier = track.trackId.length ? track.trackId : track.identifier;
        waDownload *download = [manager downloadForIdentifier:identifier];
        if (!download || download.state != waDownloadStateCompleted || ![manager localPathForIdentifier:identifier].length) return NO;
    }
    return YES;
}

@implementation waPlaylistViewController

- (id)initWithTitle:(NSString *)title items:(NSArray *)items {
    if ((self = [super init])) {
        _playlist = @{};
        _items = [self mediaItemsFromObjects:items ?: @[]];
        self.title = title.length ? title : @"Playlist";
    }
    return self;
}

- (id)initWithPlaylist:(NSDictionary *)playlist ownerIsCurrentUser:(BOOL)isOwner {
    if ((self = [super init])) {
        _playlist = [playlist isKindOfClass:[NSDictionary class]] ? [playlist copy] : @{};
        _ownerIsCurrentUser = isOwner;
        _items = [self mediaItemsFromObjects:[self tracksValueFromPlaylist:_playlist] ?: @[]];
        self.title = waPlaylistString(_playlist, @[@"name", @"title"]) ?: @"Playlist";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [waTheme backgroundColor];

    // Use the same custom catalog architecture as Album and Artist views.
    self.tracksTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tracksTableView.delegate = self;
    self.tracksTableView.dataSource = self;
    self.tracksTableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tracksTableView.separatorColor = [waTheme separatorColor];
    self.tracksTableView.backgroundColor = [waTheme backgroundColor];
    self.tracksTableView.showsVerticalScrollIndicator = NO;
    self.tracksTableView.sectionHeaderHeight = 0.0;
    self.tracksTableView.sectionFooterHeight = 0.0;
    UIView *tableBackground = [[UIView alloc] initWithFrame:CGRectZero];
    tableBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableBackground.backgroundColor = [waTheme backgroundColor];
    self.tracksTableView.backgroundView = tableBackground;
    [self.view addSubview:self.tracksTableView];

    [self buildInfoCard];
    self.navigationSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.55;
    [self.tracksTableView addGestureRecognizer:longPress];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadStateDidChange:) name:waDownloadManagerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mediaLikeDidChange:) name:waMediaLikeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    [waTheme applyToView:self.view];
    [self loadPlaylistIfNeeded];
    if (self.ownerIsCurrentUser) self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Edit" style:UIBarButtonItemStyleBordered target:self action:@selector(editPlaylistMenu)];
}

- (void)editPlaylistMenu {
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:self.title delegate:self cancelButtonTitle:@"Cancel" destructiveButtonTitle:@"Delete Playlist" otherButtonTitles:@"Rename Playlist", nil];
    sheet.tag = 9001;
    [sheet showInView:self.view];
}

- (void)editPlaylist {
    NSString *playlistID = waPlaylistString(self.playlist, @[@"id", @"playlist_id", @"browseId", @"PLAYLIST_ID"]);
    if (!playlistID.length) return;
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Edit Playlist" message:@"Enter a new playlist name" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Save", nil];
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    [alert textFieldAtIndex:0].text = waPlaylistString(self.playlist, @[@"name", @"title"]);
    [alert show];
}

- (void)deletePlaylist {
    NSString *playlistID = waPlaylistString(self.playlist, @[@"id", @"playlist_id", @"browseId", @"PLAYLIST_ID"]);
    if (!playlistID.length) return;
    [[waAPIClient sharedClient] deletePlaylist:playlistID completion:^(NSError *error) {
        if (error) {
            [[[UIAlertView alloc] initWithTitle:@"Playlist" message:error.localizedDescription delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        } else {
            [self.navigationController popViewControllerAnimated:YES];
        }
    }];
}

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    if (actionSheet.tag == 9001) {
        if (buttonIndex == actionSheet.destructiveButtonIndex) [self deletePlaylist];
        else [self editPlaylist];
    } else if (actionSheet.tag == 9002 && self.pendingRemovalItem) {
        NSString *playlistID = waPlaylistString(self.playlist, @[@"id", @"playlist_id", @"browseId", @"PLAYLIST_ID"]);
        NSString *trackID = self.pendingRemovalItem.trackId.length ? self.pendingRemovalItem.trackId : self.pendingRemovalItem.identifier;
        waMediaItem *item = self.pendingRemovalItem;
        self.pendingRemovalItem = nil;
        [[waAPIClient sharedClient] removeSong:trackID fromPlaylist:playlistID completion:^(NSError *error) {
            if (error) {
                [[[UIAlertView alloc] initWithTitle:@"Playlist" message:error.localizedDescription delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
            } else {
                NSMutableArray *updated = [self.items mutableCopy];
                [updated removeObjectIdenticalTo:item];
                self.items = updated;
                [self updateInfoCard];
                [self.tracksTableView reloadData];
            }
        }];
    }
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex != 1) return;
    NSString *name = [[alertView textFieldAtIndex:0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *playlistID = waPlaylistString(self.playlist, @[@"id", @"playlist_id", @"browseId", @"PLAYLIST_ID"]);
    if (!name.length || !playlistID.length) return;
    [[waAPIClient sharedClient] updatePlaylistWithID:playlistID changes:@{@"title": name} completion:^(NSDictionary *playlist, NSError *error) {
        if (error) {
            [[[UIAlertView alloc] initWithTitle:@"Playlist" message:error.localizedDescription delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
            return;
        }
        if ([playlist isKindOfClass:[NSDictionary class]]) self.playlist = [self playlistByMergingDictionary:playlist];
        self.title = name;
        [self updateInfoCard];
    }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.tracksTableView.frame = self.view.bounds;
    [self layoutInfoCard];
}

- (NSArray *)tracksValueFromPlaylist:(NSDictionary *)dictionary {
    for (NSString *key in @[@"tracks", @"songs", @"items"]) {
        id value = dictionary[key];
        if ([value isKindOfClass:[NSArray class]]) return value;
    }
    id data = dictionary[@"data"];
    if ([data isKindOfClass:[NSArray class]]) return data;
    if ([data isKindOfClass:[NSDictionary class]]) return [self tracksValueFromPlaylist:data];
    return @[];
}

- (NSArray *)mediaItemsFromObjects:(NSArray *)objects {
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:objects.count];
    for (id object in objects) {
        waMediaItem *item = [object isKindOfClass:[waMediaItem class]] ? object : ([object isKindOfClass:[NSDictionary class]] ? [waMediaItem itemWithDictionary:object] : nil);
        if (item) [items addObject:item];
    }
    return items;
}

- (NSDictionary *)playlistByMergingDictionary:(NSDictionary *)update {
    NSMutableDictionary *merged = [self.playlist mutableCopy] ?: [NSMutableDictionary dictionary];
    if ([update isKindOfClass:[NSDictionary class]]) [merged addEntriesFromDictionary:update];
    return merged;
}

- (waMediaItem *)playlistInfoItem {
    NSString *identifier = waPlaylistString(self.playlist, @[@"id", @"playlist_id", @"browseId", @"PLAYLIST_ID", @"PARENT_PLAYLIST_ID"]);
    NSString *title = waPlaylistString(self.playlist, @[@"name", @"title", @"TITLE"]) ?: self.title ?: @"Playlist";
    NSString *description = waPlaylistString(self.playlist, @[@"description", @"DESCRIPTION"]);
    waMediaItem *item = [[waMediaItem alloc] initWithIdentifier:identifier title:title subtitle:description.length ? description : @"Playlist" type:waMediaItemTypePlaylist];
    item.liked = waPlaylistBool(self.playlist, @[@"liked", @"likedByMe", @"favorite", @"FAVORITE", @"is_favorite", @"IS_FAVORITE"], NO);
    item.thumbnailURL = [self playlistArtworkURL];
    return item;
}

- (NSString *)playlistArtworkURL {
    NSString *url = waPlaylistString(self.playlist, @[@"artwork", @"thumbnail", @"thumbnailURL", @"picture_xl", @"picture_big", @"picture", @"PICTURE_XL", @"PICTURE_BIG", @"PICTURE"]);
    NSDictionary *raw = [self.playlist[@"deezerRaw"] isKindOfClass:[NSDictionary class]] ? self.playlist[@"deezerRaw"] : nil;
    if (!url.length) url = waPlaylistString(raw, @[@"PLAYLIST_PICTURE", @"PICTURE_XL", @"PICTURE_BIG", @"PICTURE"]);
    if (url.length && [url rangeOfString:@"://"].location == NSNotFound) url = [NSString stringWithFormat:@"https://e-cdns-images.dzcdn.net/images/playlist/%@/1000x1000-000000-80-0-0.jpg", url];
    if (!url.length && self.items.count) url = [self.items[0] thumbnailURL];
    return url;
}

- (BOOL)isLandscape { return self.view.bounds.size.width > self.view.bounds.size.height; }

- (void)buildInfoCard {
    self.infoContainer = [[UIView alloc] initWithFrame:CGRectZero];
    self.infoContainer.backgroundColor = [UIColor clearColor];
    self.infoContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.infoCard = [[waCatalogInfoCard alloc] initWithFrame:CGRectZero];
    self.infoCard.delegate = self;
    [self.infoContainer addSubview:self.infoCard];
    __weak waPlaylistViewController *weakSelf = self;
    self.tracksHeader = [[waCatalogSectionHeaderView alloc] initWithTitle:@"Tracks" actionTitle:nil action:^{
        (void)weakSelf;
    }];
    [self.infoContainer addSubview:self.tracksHeader];
    [self updateInfoCard];
}

- (void)updateInfoCard {
    waMediaItem *item = [self playlistInfoItem];
    [self.infoCard configureWithItem:item listenerText:nil detailText:[NSString stringWithFormat:@"%lu songs", (unsigned long)self.items.count]];
    self.infoCard.downloadButton.hidden = NO;
    self.infoCard.playAllButton.hidden = NO;
    self.infoCard.playAllButton.enabled = self.items.count > 0;
    if (!self.tracksDownloadedFlag) self.tracksDownloadedFlag = @(waPlaylistTracksAreDownloaded(self.items));
    [self.infoCard.downloadButton setTitle:self.tracksDownloadedFlag.boolValue ? @"Downloaded" : @"Download" forState:UIControlStateNormal];
    [self loadPlaylistArtworkForItem:item];
    [self layoutInfoCard];
}

- (void)loadPlaylistArtworkForItem:(waMediaItem *)item {
    NSURL *url = [NSURL URLWithString:item.thumbnailURL];
    if (!url.scheme.length) url = [[waAPIClient sharedClient] URLForPath:item.thumbnailURL];
    if (!url) return;
    NSUInteger generation = self.requestGeneration;
    [[waImageLoader sharedLoader] loadThumbnailAtURL:url.absoluteString targetSize:CGSizeMake(176.0, 176.0) placeholder:waPlaceholderImage() completion:^(UIImage *image) {
        if (generation == self.requestGeneration && image) self.infoCard.coverView.image = image;
    }];
}

- (void)layoutInfoCard {
    if (!self.tracksTableView || !self.infoCard || !self.infoContainer) return;
    CGFloat width = self.tracksTableView.bounds.size.width;
    if (width <= 0.0) width = self.view.bounds.size.width;
    if (width <= 0.0) return;
    CGFloat cardHeight = [self.infoCard preferredHeightForWidth:width landscape:[self isLandscape]];
    CGFloat headerHeight = 42.0;
    CGRect oldHeaderFrame = self.infoContainer.frame;
    CGRect newHeaderFrame = CGRectMake(0.0, 0.0, width, cardHeight + headerHeight);
    BOOL headerChanged = !CGRectEqualToRect(oldHeaderFrame, newHeaderFrame) || self.tracksTableView.tableHeaderView != self.infoContainer;
    self.infoContainer.frame = newHeaderFrame;
    self.infoCard.frame = CGRectMake(0.0, 0.0, width, cardHeight);
    self.tracksHeader.frame = CGRectMake(0.0, cardHeight, width, headerHeight);
    [self.infoCard setNeedsLayout];
    [self.infoCard layoutIfNeeded];
    [self.tracksHeader setNeedsLayout];
    [self.tracksHeader layoutIfNeeded];
    // Reassigning is required by iOS 6 after rotation, exactly as in Album View.
    if (headerChanged) self.tracksTableView.tableHeaderView = self.infoContainer;
}

- (void)loadPlaylistIfNeeded {
    NSString *playlistID = waPlaylistString(self.playlist, @[@"id", @"playlist_id", @"browseId", @"PLAYLIST_ID", @"PARENT_PLAYLIST_ID"]);
    if (!playlistID.length) {
        self.infoCard.stateLabel.text = self.items.count ? @"" : @"No songs found";
        [self layoutInfoCard];
        return;
    }
    NSUInteger generation = ++self.requestGeneration;
    self.navigationItem.titleView = self.navigationSpinner;
    [self.navigationSpinner startAnimating];
    self.infoCard.stateLabel.text = @"Loading playlist…";
    [self layoutInfoCard];
    [[waAPIClient sharedClient] playlistWithID:playlistID completion:^(NSDictionary *playlist, NSError *error) {
        if (generation != self.requestGeneration) return;
        [self.navigationSpinner stopAnimating];
        self.navigationItem.titleView = nil;
        if (error || ![playlist isKindOfClass:[NSDictionary class]]) {
            self.infoCard.stateLabel.text = @"Unable to load playlist";
            [self layoutInfoCard];
            return;
        }
        NSArray *tracks = [self tracksValueFromPlaylist:playlist];
        self.playlist = [self playlistByMergingDictionary:playlist];
        if (tracks) self.items = [self mediaItemsFromObjects:tracks];
        self.title = waPlaylistString(self.playlist, @[@"name", @"title"]) ?: self.title;
        self.infoCard.stateLabel.text = self.items.count ? @"" : @"No songs found";
        [self updateInfoCard];
        [self.tracksTableView reloadData];
    }];
}

- (void)catalogInfoCardDidPressLike:(waCatalogInfoCard *)card {
    if (![[waAPIClient sharedClient] isAuthenticated]) {
        [[[UIAlertView alloc] initWithTitle:@"Like" message:@"Sign in to save playlists to your library." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        return;
    }
    waMediaItem *item = [self playlistInfoItem];
    BOOL liked = !item.isLiked;
    item.liked = liked;
    card.likeButton.selected = liked;
    [card.likeButton setTitle:liked ? @"Unlike" : @"Like" forState:UIControlStateNormal];
    card.likeButton.enabled = NO;
    [[waAPIClient sharedClient] setLiked:liked playlist:item completion:^(BOOL success, NSError *error) {
        card.likeButton.enabled = YES;
        if (success) {
            NSMutableDictionary *updated = [self.playlist mutableCopy] ?: [NSMutableDictionary dictionary];
            updated[@"liked"] = @(liked);
            self.playlist = updated;
            card.likeButton.selected = liked;
            [[NSNotificationCenter defaultCenter] postNotificationName:waMediaLikeDidChangeNotification object:item userInfo:@{waMediaLikeIdentifierKey: item.identifier ?: @"", waMediaLikeTypeKey: @(item.type)}];
            [card.likeButton setTitle:liked ? @"Unlike" : @"Like" forState:UIControlStateNormal];
        } else {
            item.liked = !liked;
             card.likeButton.selected = item.isLiked;
             [card.likeButton setTitle:item.isLiked ? @"Unlike" : @"Like" forState:UIControlStateNormal];
             [[[UIAlertView alloc] initWithTitle:@"Like" message:error.localizedDescription ?: @"Unable to update likes." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        }
    }];
}

- (void)catalogInfoCardDidPressDownload:(waCatalogInfoCard *)card {
    (void)card;
    NSString *context = waPlaylistString(self.playlist, @[@"id", @"browseId"]) ?: self.title;
    for (waMediaItem *item in self.items) [[waDownloadManager sharedManager] enqueueDownloadWithItem:item category:waDownloadCategoryPlaylist contextIdentifier:context groupTitle:self.title];
}

- (void)catalogInfoCardDidPressPlayAll:(waCatalogInfoCard *)card {
    (void)card;
    if (self.items.count) [[waAudioPlayer sharedPlayer] playItem:self.items[0] fromContext:self.items title:self.title];
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
        } else {
            [[NSNotificationCenter defaultCenter] postNotificationName:waMediaLikeDidChangeNotification object:item userInfo:@{waMediaLikeIdentifierKey: item.identifier ?: @"", waMediaLikeTypeKey: @(item.type)}];
        }
        [cell refreshLikeState];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.items.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section { (void)tableView; (void)section; return 0.0; }
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section { (void)tableView; (void)section; return 0.0; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"playlist-track"];
    if (!cell) cell = [[waCatalogTrackCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"playlist-track"];
    waMediaItem *track = path.row < self.items.count ? self.items[path.row] : nil;
    waCatalogTrackCell *trackCell = (waCatalogTrackCell *)cell;
    trackCell.delegate = self;
    [trackCell configureForPlaylistItem:track artistName:track.artistName.length ? track.artistName : track.subtitle];
    NSString *downloadIdentifier = track.trackId.length ? track.trackId : track.identifier;
    waDownload *download = track ? [[waDownloadManager sharedManager] downloadForIdentifier:downloadIdentifier] : nil;
    [trackCell setDownloadState:download ? download.state : waDownloadStateNotFound progress:download.progress];
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path { (void)tableView; (void)path; return [self isLandscape] ? 56.0 : 60.0; }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (path.section == 0 && path.row < self.items.count) [[waAudioPlayer sharedPlayer] playItem:self.items[path.row] fromContext:self.items title:self.title];
}

- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.view.backgroundColor = [waTheme backgroundColor];
    self.tracksTableView.backgroundColor = [waTheme backgroundColor];
    self.tracksTableView.separatorColor = [waTheme separatorColor];
    [self.infoCard applyTheme];
    if (self.view.window) [self.tracksTableView reloadData];
}

- (void)mediaLikeDidChange:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSString *identifier = userInfo[waMediaLikeIdentifierKey];
    NSNumber *type = userInfo[waMediaLikeTypeKey];
    NSString *playlistID = waPlaylistString(self.playlist, @[@"id", @"browseId", @"PLAYLIST_ID"]);
    if (type && type.integerValue != waMediaItemTypePlaylist) return;
    if (identifier.length && playlistID.length && ![identifier isEqualToString:playlistID]) return;
    waMediaItem *item = [self playlistInfoItem];
    item.liked = [notification.object isKindOfClass:[waMediaItem class]] ? [notification.object isLiked] : item.isLiked;
    NSMutableDictionary *updated = [self.playlist mutableCopy] ?: [NSMutableDictionary dictionary];
    updated[@"liked"] = @(item.isLiked);
    self.playlist = updated;
    [self updateInfoCard];
}

- (void)downloadStateDidChange:(NSNotification *)notification {
    if (!self.view.window || self.downloadReloadScheduled) return;
    self.downloadReloadScheduled = YES;
    self.pendingProgressDownloadIdentifier = notification.userInfo[@"identifier"] ?: @"";
    BOOL progress = [notification.userInfo[@"event"] isEqualToString:@"progress"];
    NSTimeInterval delay = progress ? 0.4 : 0.12;
    [self performSelector:@selector(reloadDownloadTable) withObject:nil afterDelay:delay];
}

// Refresh only the row whose download changed instead of reloading the whole
// playlist on every download event.
- (void)refreshDownloadRowForIdentifier:(NSString *)identifier {
    if (!identifier.length) { [self.tracksTableView reloadData]; return; }
    NSString *clean = [identifier hasPrefix:@"deezer:"] ? [identifier substringFromIndex:7] : identifier;
    NSInteger row = NSNotFound;
    for (NSUInteger index = 0; index < self.items.count; index++) {
        waMediaItem *track = self.items[index];
        NSString *trackID = track.trackId.length ? track.trackId : track.identifier;
        if ([trackID isEqualToString:clean] || [trackID isEqualToString:identifier]) { row = (NSInteger)index; break; }
    }
    if (row == NSNotFound) return;
    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
    waCatalogTrackCell *cell = (waCatalogTrackCell *)[self.tracksTableView cellForRowAtIndexPath:path];
    if (![cell isKindOfClass:[waCatalogTrackCell class]]) return;
    waDownload *download = [[waDownloadManager sharedManager] downloadForIdentifier:clean];
    [cell setDownloadState:download ? download.state : waDownloadStateNotFound progress:download.progress];
}

- (void)reloadDownloadTable {
    self.downloadReloadScheduled = NO;
    if (!self.view.window) return;
    self.tracksDownloadedFlag = nil;
    [self downloadButtonRefreshTitle];
    [self refreshDownloadRowForIdentifier:self.pendingProgressDownloadIdentifier];
    self.pendingProgressDownloadIdentifier = nil;
}

- (void)downloadButtonRefreshTitle {
    if (!self.tracksDownloadedFlag) self.tracksDownloadedFlag = @(waPlaylistTracksAreDownloaded(self.items));
    [self.infoCard.downloadButton setTitle:self.tracksDownloadedFlag.boolValue ? @"Downloaded" : @"Download" forState:UIControlStateNormal];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *path = [self.tracksTableView indexPathForRowAtPoint:[gesture locationInView:self.tracksTableView]];
    if (path && path.section == 0 && path.row < self.items.count) {
        waMediaItem *item = self.items[path.row];
        if (self.ownerIsCurrentUser) {
            self.pendingRemovalItem = item;
            UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:item.title delegate:self cancelButtonTitle:@"Cancel" destructiveButtonTitle:@"Remove from Playlist" otherButtonTitles:nil];
            sheet.tag = 9002;
            [sheet showInView:self.view];
        } else {
            [waMediaActionSheet presentForItem:item inViewController:self albumItems:nil];
        }
    }
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadDownloadTable) object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
