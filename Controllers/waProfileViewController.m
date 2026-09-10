#import "waProfileViewController.h"
#import "../Services/waAPIClient.h"
#import "../Services/waTheme.h"
#import "../Views/waPlaceholder.h"
#import "../Services/waImageLoader.h"
#import "../Views/waArtworkCell.h"
#import "../Views/waMediaActionSheet.h"
#import "../Views/waActions.h"
#import "../Views/waAction.h"
#import "waMediaDetailViewController.h"
#import "waDeezerLoginViewController.h"
#import "waPlaylistViewController.h"
#import "../Views/waSettingsCell.h"

@interface waProfileViewController ()
@property (nonatomic, strong) NSDictionary *user;
@property (nonatomic, strong) NSArray *likedArtists;
@property (nonatomic, strong) NSArray *likedAlbums;
@property (nonatomic, strong) NSArray *playlists;
@property (nonatomic, assign) BOOL artistsExpanded;
@property (nonatomic, strong) UIView *stateView;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *spinnerBackdrop;
@property (nonatomic, assign) BOOL loadingProfile;
@property (nonatomic, assign) NSUInteger loadGeneration;
// waMediaItems built once per data load so cellForRow never allocs per row.
@property (nonatomic, strong) NSArray *cachedArtistItems;
@property (nonatomic, strong) NSArray *cachedAlbumItems;
@property (nonatomic, strong) NSArray *cachedPlaylistItems;
- (waMediaItem *)itemForImageAtIndexPath:(NSIndexPath *)path;
- (void)refreshVisibleLikeState;
@end

@implementation waProfileViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Profile";
    self.likedArtists = @[];
    self.likedAlbums = @[];
    self.playlists = @[];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView.separatorColor = [waTheme separatorColor];
    self.tableView.backgroundColor = [waTheme backgroundColor];

    self.stateView = [[UIView alloc] initWithFrame:self.tableView.bounds];
    self.stateView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.stateView.backgroundColor = [waTheme backgroundColor];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.spinner.center = CGPointMake(self.view.bounds.size.width / 2.0, 58.0);
    self.stateLabel = [[UILabel alloc] initWithFrame:CGRectMake(15.0, 78.0, self.view.bounds.size.width - 30.0, 42.0)];
    self.stateLabel.textAlignment = NSTextAlignmentCenter;
    self.stateLabel.textColor = [waTheme secondaryTextColor];
    self.stateLabel.numberOfLines = 2;
    self.stateLabel.backgroundColor = [UIColor clearColor];
    [self.stateView addSubview:self.spinner];
    self.spinnerBackdrop = [waTheme circularBackdropForSpinner:self.spinner];
    [self.stateView addSubview:self.spinnerBackdrop];
    [self.stateView bringSubviewToFront:self.spinnerBackdrop];
    [self.stateView addSubview:self.stateLabel];
    self.tableView.backgroundView = self.stateView;
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.55;
    [self.tableView addGestureRecognizer:longPress];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(mediaLikeDidChange:) name:waMediaLikeDidChangeNotification object:nil];
    [waTheme applyToView:self.view];
}

- (void)clearProfileData {
    self.user = nil;
    self.likedArtists = @[];
    self.likedAlbums = @[];
    self.playlists = @[];
    self.cachedArtistItems = @[];
    self.cachedAlbumItems = @[];
    self.cachedPlaylistItems = @[];
}

- (void)rebuildCachedItems {
    // Normalize dictionaries to waMediaItems once per load, not per row.
    NSMutableArray *artists = [NSMutableArray arrayWithCapacity:self.likedArtists.count];
    for (id object in self.likedArtists) {
        waMediaItem *artist = [object isKindOfClass:[waMediaItem class]] ? object : ([object isKindOfClass:[NSDictionary class]] ? [waMediaItem itemWithDictionary:object] : nil);
        if (!artist) { [artists addObject:[NSNull null]]; continue; }
        artist.type = waMediaItemTypeArtist;
        artist.artistIdentifier = artist.identifier;
        artist.artistName = artist.title;
        artist.liked = YES;
        [artists addObject:artist];
    }
    self.cachedArtistItems = artists;
    NSMutableArray *albums = [NSMutableArray arrayWithCapacity:self.likedAlbums.count];
    for (id object in self.likedAlbums) {
        waMediaItem *album = [object isKindOfClass:[waMediaItem class]] ? object : ([object isKindOfClass:[NSDictionary class]] ? [waMediaItem itemWithDictionary:object] : nil);
        if (!album) { [albums addObject:[NSNull null]]; continue; }
        album.type = waMediaItemTypeAlbum;
        album.liked = YES;
        [albums addObject:album];
    }
    self.cachedAlbumItems = albums;
    NSMutableArray *playlistItems = [NSMutableArray arrayWithCapacity:self.playlists.count];
    for (id object in self.playlists) {
        waMediaItem *item = [object isKindOfClass:[waMediaItem class]] ? object : ([object isKindOfClass:[NSDictionary class]] ? [waMediaItem itemWithDictionary:object] : nil);
        [playlistItems addObject:item ?: [NSNull null]];
    }
    self.cachedPlaylistItems = playlistItems;
    // Release raw API payloads (full JSON incl. deezerRaw); rows use the
    // normalized cached items from here on. Playlists raw stay for owner ids.
    self.likedArtists = @[];
    self.likedAlbums = @[];
}

- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.view.backgroundColor = [waTheme backgroundColor];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.separatorColor = [waTheme separatorColor];
    self.stateView.backgroundColor = [waTheme backgroundColor];
    self.stateLabel.textColor = [waTheme secondaryTextColor];
    if (self.view.window) [self.tableView reloadData];
}

- (void)mediaLikeDidChange:(NSNotification *)notification {
    NSString *identifier = notification.userInfo[waMediaLikeIdentifierKey];
    if (!identifier.length || ![notification.object isKindOfClass:[waMediaItem class]]) return;
    BOOL liked = [notification.object isLiked];
    for (NSArray *items in @[self.cachedArtistItems ?: @[], self.cachedAlbumItems ?: @[], self.cachedPlaylistItems ?: @[]]) {
        for (waMediaItem *item in items) {
            if ([item isKindOfClass:[waMediaItem class]] && [item.identifier isEqualToString:identifier]) item.liked = liked;
        }
    }
    [self refreshVisibleLikeState];
}

- (void)refreshVisibleLikeState {
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
        if ([cell isKindOfClass:[waArtworkCell class]]) [(waArtworkCell *)cell refreshLikeState];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [waTheme applyToView:self.view];
    [self loadProfile];
}

- (void)dealloc {
    self.loadGeneration += 1;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isAuthenticated {
    return [[waAPIClient sharedClient] isAuthenticated];
}

- (void)loadProfile {
    if (![self isAuthenticated]) {
        self.loadingProfile = NO;
        self.loadGeneration += 1;
        [self clearProfileData];
        [self.spinner stopAnimating];
         self.stateLabel.text = @"Sign in to see your Deezer profile.";
        [self.tableView reloadData];
        return;
    }

    if (self.loadingProfile) return;
    self.loadingProfile = YES;
    NSUInteger generation = ++self.loadGeneration;

    self.stateLabel.text = @"Loading profile…";
    [self.spinner startAnimating];
    __block NSInteger pending = 4;
    __weak typeof(self) weakSelf = self;
    void (^finishRequest)(void) = ^{
        waProfileViewController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.loadGeneration) return;
        pending -= 1;
        if (pending == 0) {
            strongSelf.loadingProfile = NO;
            [strongSelf.spinner stopAnimating];
            strongSelf.stateLabel.text = strongSelf.user ? @"" : @"Unable to load profile.";
            [strongSelf rebuildCachedItems];
            [strongSelf.tableView reloadData];
        }
    };

    [[waAPIClient sharedClient] meWithCompletion:^(NSDictionary *user, NSError *error) {
        waProfileViewController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.loadGeneration) return;
        strongSelf.user = [user[@"user"] isKindOfClass:[NSDictionary class]] ? user[@"user"] : user;
        if (error) strongSelf.user = nil;
        finishRequest();
    }];
    [[waAPIClient sharedClient] likedArtistsWithCompletion:^(NSDictionary *result, NSError *error) {
        (void)error;
        waProfileViewController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.loadGeneration) return;
        id artists = result[@"artists"] ?: result[@"items"];
        strongSelf.likedArtists = [artists isKindOfClass:[NSArray class]] ? artists : @[];
        finishRequest();
    }];
    [[waAPIClient sharedClient] likedAlbumsWithCompletion:^(NSDictionary *result, NSError *error) {
        (void)error;
        waProfileViewController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.loadGeneration) return;
        id albums = result[@"albums"] ?: result[@"items"];
        strongSelf.likedAlbums = [albums isKindOfClass:[NSArray class]] ? albums : @[];
        finishRequest();
    }];
    [[waAPIClient sharedClient] playlistsWithCompletion:^(NSArray *playlists, NSError *error) {
        (void)error;
        waProfileViewController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.loadGeneration) return;
        strongSelf.playlists = [playlists isKindOfClass:[NSArray class]] ? playlists : @[];
        finishRequest();
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [self isAuthenticated] ? 4 : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (![self isAuthenticated]) return 1;
    if (section == 0) return 3;
    if (section == 1) return MIN(self.artistsExpanded ? self.cachedArtistItems.count : 4, self.cachedArtistItems.count) + (self.cachedArtistItems.count > 4 && !self.artistsExpanded);
    if (section == 2) return self.cachedAlbumItems.count;
    return self.playlists.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {
    return [waTheme standardRowHeight];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (![self isAuthenticated]) return @"Account";
    return @[@"Account", @"Artists liked", @"Albums liked", @"My playlists"][section];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView;
    waSettingsHeader *header = [[waSettingsHeader alloc] initWithReuseIdentifier:@"profile-header"];
    header.textLabel.text = [self tableView:self.tableView titleForHeaderInSection:section];
    header.textLabel.font = [waTheme boldFontOfSize:14.0];
    return header;
}

- (NSString *)displayName {
    for (NSString *key in @[@"name", @"firstname"]) {
        id value = self.user[key];
        if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    }
    return @"Deezer listener";
}

- (NSString *)stringValueForUserKey:(NSString *)key {
    id value = self.user[key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) {
        NSString *converted = [value stringValue];
        if (converted.length) return converted;
    }
    NSDictionary *raw = [self.user[@"deezerRaw"] isKindOfClass:[NSDictionary class]] ? self.user[@"deezerRaw"] : nil;
    NSArray *rawKeys = nil;
    if ([key isEqualToString:@"country"]) {
        rawKeys = @[@"country", @"COUNTRY", @"COUNTRY_NAME", @"country_name", @"COUNTRY_CODE", @"country_code", @"USER_COUNTRY", @"COUNTRY_ID", @"country_id"];
    } else if ([key isEqualToString:@"avatar"]) {
        rawKeys = @[@"avatar", @"AVATAR", @"picture", @"PICTURE", @"PICTURE_SMALL", @"PICTURE_MEDIUM", @"PICTURE_BIG", @"PICTURE_XL", @"picture_small", @"picture_medium", @"picture_big", @"picture_xl", @"USER_PICTURE", @"USER_PICTURE_URL", @"user_picture", @"userPicture"];
    } else {
        rawKeys = @[key, [key uppercaseString]];
    }
    for (NSString *rawKey in rawKeys) {
        id rawValue = raw[rawKey];
        if ([rawValue isKindOfClass:[NSString class]] && [(NSString *)rawValue length]) {
            if ([key isEqualToString:@"avatar"] && [rawValue rangeOfString:@"://"].location == NSNotFound) {
                return [NSString stringWithFormat:@"https://e-cdns-images.dzcdn.net/images/user/%@/1000x1000-000000-80-0-0.jpg", rawValue];
            }
            return rawValue;
        }
        if ([rawValue respondsToSelector:@selector(stringValue)]) {
            NSString *converted = [rawValue stringValue];
            if (converted.length) return converted;
        }
    }
    return nil;
}

- (NSString *)stringValueForDictionary:(NSDictionary *)dictionary keys:(NSArray *)keys {
    for (NSString *key in keys) {
        id value = dictionary[key];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
        if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    }
    return nil;
}

- (NSString *)handle {
    NSString *identifier = [self stringValueForUserKey:@"id"];
    return identifier.length ? [NSString stringWithFormat:@"Deezer ID %@", identifier] : @"Signed in to Deezer";
}

- (waMediaItem *)artistAtIndex:(NSUInteger)index {
    if (index >= self.cachedArtistItems.count) return nil;
    id cached = self.cachedArtistItems[index];
    return [cached isKindOfClass:[waMediaItem class]] ? cached : nil;
}

- (waMediaItem *)albumAtIndex:(NSUInteger)index {
    if (index >= self.cachedAlbumItems.count) return nil;
    id cached = self.cachedAlbumItems[index];
    return [cached isKindOfClass:[waMediaItem class]] ? cached : nil;
}

- (void)loadImageForItem:(waMediaItem *)item cell:(UITableViewCell *)cell tableView:(UITableView *)tableView indexPath:(NSIndexPath *)path {
    if (!item.thumbnailURL.length) return;
    NSURL *url = [NSURL URLWithString:item.thumbnailURL];
    if (!url.scheme.length) url = [[waAPIClient sharedClient] URLForPath:item.thumbnailURL];
    NSString *expected = [url.absoluteString copy];
    __weak UITableViewCell *weakCell = cell;
    __weak waProfileViewController *weakSelf = self;
    [[waImageLoader sharedLoader] loadThumbnailAtURL:expected targetSize:CGSizeMake(112.0, 112.0) placeholder:waPlaceholderImage() completion:^(UIImage *image) {
        UITableViewCell *strongCell = weakCell;
        waProfileViewController *controller = weakSelf;
        if (!strongCell || !controller || !image) return;
        // The row may have been reused while the thumbnail was loading.
        NSIndexPath *current = [tableView indexPathForCell:strongCell];
        if (!current || ![current isEqual:path]) return;
        if ([controller itemForImageAtIndexPath:path] != item) return;
        strongCell.imageView.image = image;
    }];
}

- (waMediaItem *)itemForImageAtIndexPath:(NSIndexPath *)path {
    if (path.section == 1) return [self artistAtIndex:path.row];
    if (path.section == 2) return [self albumAtIndex:path.row];
    if (path.section == 3) {
        id cached = path.row < (NSInteger)self.cachedPlaylistItems.count ? self.cachedPlaylistItems[path.row] : nil;
        return [cached isKindOfClass:[waMediaItem class]] ? cached : nil;
    }
    return nil;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:[gesture locationInView:self.tableView]];
    if (!path) return;
    waMediaItem *item = [self itemForImageAtIndexPath:path];
    if (item) [waMediaActionSheet presentForItem:item inViewController:self albumItems:nil];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    waArtworkCell *cell = [tableView dequeueReusableCellWithIdentifier:@"profile"];
    if (!cell) {
        cell = [[waArtworkCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"profile"];
        // Flat full-width rows like Search, styled once here.
        cell.cardStyle = NO;
        cell.backgroundColor = [waTheme backgroundColor];
        UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
        selected.backgroundColor = [waTheme selectedSurfaceColor];
        cell.selectedBackgroundView = selected;
    }
    cell.cardStyle = NO;
    cell.circleArtwork = (path.section == 1);
    cell.multilineDetail = NO;
    [cell setLikeItem:nil];
    [cell setExplicit:NO];
    [cell setGeniusRecommended:NO];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.imageView.image = waPlaceholderImage();
    cell.backgroundColor = [waTheme backgroundColor];
    cell.textLabel.textColor = [waTheme primaryTextColor];
    cell.detailTextLabel.textColor = [waTheme secondaryTextColor];

    if (![self isAuthenticated]) {
        cell.textLabel.text = @"Sign in";
         cell.detailTextLabel.text = @"Connect your Deezer account";
        cell.imageView.image = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if (path.section == 0 && path.row == 0) {
        cell.textLabel.text = [self displayName];
        id verified = self.user[@"verified"];
        id isVerified = self.user[@"isVerified"];
        if (([verified respondsToSelector:@selector(boolValue)] && [verified boolValue]) || ([isVerified respondsToSelector:@selector(boolValue)] && [isVerified boolValue])) cell.textLabel.text = [NSString stringWithFormat:@"%@ ✓", cell.textLabel.text];
        cell.detailTextLabel.text = [self handle];
        cell.imageView.image = waPlaceholderImage();
        NSString *avatar = [self stringValueForUserKey:@"avatar"];
        if ([avatar isKindOfClass:[NSString class]] && avatar.length) {
            NSURL *avatarURL = [NSURL URLWithString:avatar];
            if (!avatarURL.scheme.length) avatarURL = [[waAPIClient sharedClient] URLForPath:avatar];
            NSString *expectedAvatar = [avatarURL.absoluteString copy];
            __weak UITableViewCell *weakAvatarCell = cell;
            [[waImageLoader sharedLoader] loadThumbnailAtURL:expectedAvatar targetSize:CGSizeMake(112.0, 112.0) placeholder:waPlaceholderImage() completion:^(UIImage *image) {
                UITableViewCell *strongCell = weakAvatarCell;
                if (!strongCell || !image) return;
                NSIndexPath *current = [tableView indexPathForCell:strongCell];
                if (current && [current isEqual:path]) strongCell.imageView.image = image;
            }];
        }
    } else if (path.section == 0 && path.row == 1) {
        cell.textLabel.text = @"Country";
        cell.detailTextLabel.text = [self stringValueForUserKey:@"country"] ?: @"Not provided";
        cell.imageView.image = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if (path.section == 0 && path.row == 2) {
        cell.textLabel.text = @"Log out";
        cell.detailTextLabel.text = @"Disconnect Deezer";
        cell.imageView.image = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if (path.section == 1) {
        if (path.row == MIN(self.artistsExpanded ? self.cachedArtistItems.count : 4, self.cachedArtistItems.count) && self.cachedArtistItems.count > 4 && !self.artistsExpanded) {
            cell.textLabel.text = @"See More";
            cell.detailTextLabel.text = nil;
            cell.imageView.image = nil;
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            waMediaItem *artist = [self artistAtIndex:path.row];
            if (!artist) { cell.textLabel.text = @"Unavailable artist"; cell.detailTextLabel.text = nil; cell.imageView.image = nil; cell.accessoryType = UITableViewCellAccessoryNone; return cell; }
            cell.textLabel.text = artist.title;
            cell.detailTextLabel.text = @"Artist";
            cell.imageView.image = waPlaceholderImage();
            [cell setLikeItem:artist];
            [self loadImageForItem:artist cell:cell tableView:tableView indexPath:path];
        }
    } else if (path.section == 2) {
        waMediaItem *album = [self albumAtIndex:path.row];
        if (!album) { cell.textLabel.text = @"Unavailable album"; cell.detailTextLabel.text = nil; cell.imageView.image = nil; cell.accessoryType = UITableViewCellAccessoryNone; return cell; }
        cell.textLabel.text = album.title;
        cell.detailTextLabel.text = album.artistName.length ? album.artistName : (album.releaseYear.length ? album.releaseYear : (album.subtitle.length ? album.subtitle : @"Album"));
        cell.imageView.image = waPlaceholderImage();
        [cell setLikeItem:album];
        [cell setExplicit:album.isExplicit];
        [self loadImageForItem:album cell:cell tableView:tableView indexPath:path];
    } else {
        NSDictionary *playlist = path.row < self.playlists.count ? self.playlists[path.row] : nil;
        id playlistCached = path.row < (NSInteger)self.cachedPlaylistItems.count ? self.cachedPlaylistItems[path.row] : nil;
        waMediaItem *item = [playlistCached isKindOfClass:[waMediaItem class]] ? playlistCached : nil;
        if (!item) { cell.textLabel.text = @"Unavailable playlist"; cell.detailTextLabel.text = nil; cell.imageView.image = nil; cell.accessoryType = UITableViewCellAccessoryNone; return cell; }
        cell.textLabel.text = item.title;
        NSUInteger trackCount = [playlist[@"nb_tracks"] respondsToSelector:@selector(unsignedIntegerValue)] ? [playlist[@"nb_tracks"] unsignedIntegerValue] : 0;
        cell.detailTextLabel.text = trackCount ? [NSString stringWithFormat:@"%lu songs", (unsigned long)trackCount] : @"Playlist";
        cell.imageView.image = waPlaceholderImage();
        [cell setLikeItem:item];
        [self loadImageForItem:item cell:cell tableView:tableView indexPath:path];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if (![self isAuthenticated]) {
        [self showLogin];
    } else if (path.section == 0 && path.row == 0) {
        [self showProfileActions];
    } else if (path.section == 0 && path.row == 2) {
        [self showProfileActions];
    } else if (path.section == 1) {
        if (path.row == MIN(self.artistsExpanded ? self.cachedArtistItems.count : 4, self.cachedArtistItems.count) && self.cachedArtistItems.count > 4 && !self.artistsExpanded) {
            self.artistsExpanded = YES;
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationAutomatic];
        } else {
            waMediaItem *artist = [self artistAtIndex:path.row];
            if (artist) {
                waMediaDetailViewController *detail = [[waMediaDetailViewController alloc] initWithMediaItem:artist];
                if (detail) [self.navigationController pushViewController:detail animated:YES];
            }
        }
    } else if (path.section == 2) {
        waMediaItem *album = [self albumAtIndex:path.row];
        if (album) {
            waMediaDetailViewController *detail = [[waMediaDetailViewController alloc] initWithMediaItem:album];
            if (detail) [self.navigationController pushViewController:detail animated:YES];
        }
    } else if (path.section == 3 && path.row < self.playlists.count) {
        NSDictionary *playlist = self.playlists[path.row];
        NSString *ownerID = [self stringValueForDictionary:playlist keys:@[@"user_id", @"userId", @"PARENT_USER_ID"]];
        NSString *userID = [self stringValueForUserKey:@"id"];
        BOOL owner = ownerID.length && [ownerID isEqualToString:userID];
        [self.navigationController pushViewController:[[waPlaylistViewController alloc] initWithPlaylist:playlist ownerIsCurrentUser:owner] animated:YES];
    }
}

- (void)showProfileActions {
    __weak waProfileViewController *weakSelf = self;
    waAction *logout = [waAction actionWithIdentifier:@"profile.logout" title:@"Log out" destructive:YES availability:nil handler:^(id object) { (void)object; [[waAPIClient sharedClient] logoutWithCompletion:^(NSError *error) { (void)error; [weakSelf loadProfile]; }]; }];
    [[waActions sharedActions] presentTitle:[self displayName] actions:@[logout] object:nil fromViewController:self];
}

- (void)showLogin {
    __weak waProfileViewController *weakSelf = self;
    waDeezerLoginViewController *login = [[waDeezerLoginViewController alloc] initWithCompletion:^(NSError *error) {
        if (error && error.code != NSUserCancelledError) [[[UIAlertView alloc] initWithTitle:@"Deezer Login" message:error.localizedDescription delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        if (!error) { [weakSelf loadProfile]; }
    }];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:login];
    [self presentViewController:navigation animated:YES completion:nil];
}

@end
