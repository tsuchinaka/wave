#import "waLikedSongsViewController.h"
#import "../Models/waMediaItem.h"
#import "../Models/waDownload.h"
#import "../Services/waAPIClient.h"
#import "../Services/waAudioPlayer.h"
#import "../Services/waDownloadManager.h"
#import "../Services/waImageLoader.h"
#import "../Services/waTheme.h"
#import "../Views/waArtworkCell.h"
#import "../Views/waMediaActionSheet.h"
#import "../Views/waPlaceholder.h"

@interface waLikedSongsViewController ()
@property (nonatomic, strong) NSArray *songs;
@property (nonatomic, assign) BOOL downloadReloadScheduled;
@end

@implementation waLikedSongsViewController

- (id)initWithSongs:(NSArray *)songs {
    if ((self = [super initWithStyle:UITableViewStylePlain])) {
        _songs = [songs copy] ?: @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Liked Songs";
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.separatorColor = [UIColor clearColor];
    UIBarButtonItem *playAll = [[UIBarButtonItem alloc] initWithTitle:@"Play All" style:UIBarButtonItemStyleBordered target:self action:@selector(playAll:)];
    UIBarButtonItem *shuffle = [[UIBarButtonItem alloc] initWithTitle:@"Shuffle" style:UIBarButtonItemStyleBordered target:self action:@selector(shuffle:)];
    self.navigationItem.rightBarButtonItems = @[shuffle, playAll];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.55;
    [self.tableView addGestureRecognizer:longPress];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(likesChanged:) name:waMediaLikeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadsChanged:) name:waDownloadManagerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    [waTheme applyToView:self.view];
}

- (NSArray *)playableSongs {
    NSMutableArray *result = [NSMutableArray array];
    for (waMediaItem *item in self.songs) {
        NSString *path = [[waDownloadManager sharedManager] localPathForIdentifier:item.trackId.length ? item.trackId : item.identifier];
        (void)path;
        [result addObject:item];
    }
    return result;
}

- (void)playAll:(id)sender {
    (void)sender;
    NSArray *items = [self playableSongs];
    if (items.count) [[waAudioPlayer sharedPlayer] playItem:items[0] fromContext:items title:self.title];
}

- (void)shuffle:(id)sender {
    (void)sender;
    NSArray *items = [self playableSongs];
    [waAudioPlayer sharedPlayer].shuffleEnabled = YES;
    if (items.count) [[waAudioPlayer sharedPlayer] playItem:items[0] fromContext:items title:self.title];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return self.songs.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { (void)tableView; (void)indexPath; return 64.0; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    waArtworkCell *cell = [tableView dequeueReusableCellWithIdentifier:@"liked-song"];
    if (!cell) {
        cell = [[waArtworkCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"liked-song"];
        // Flat full-width rows: style once here, never walk the subtree per row.
        cell.cardStyle = NO;
        cell.backgroundColor = [waTheme backgroundColor];
        UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
        selected.backgroundColor = [waTheme selectedSurfaceColor];
        cell.selectedBackgroundView = selected;
    }
    NSArray *songs = self.songs;
    waMediaItem *item = indexPath.row < songs.count ? songs[indexPath.row] : nil;
    cell.backgroundColor = [waTheme backgroundColor];
    cell.textLabel.text = item.title ?: @"";
    cell.textLabel.textColor = [waTheme primaryTextColor];
    cell.multilineDetail = NO;
    cell.detailTextLabel.text = item.artistName.length ? item.artistName : (item.subtitle ?: @"");
    cell.detailTextLabel.textColor = [waTheme secondaryTextColor];
    cell.imageView.image = waPlaceholderImage();
    cell.artworkIdentifier = item.thumbnailURL ?: item.identifier;
    [(waArtworkCell *)cell setLikeItem:item];
    [(waArtworkCell *)cell setExplicit:item.isExplicit];
    NSString *identifier = item.trackId.length ? item.trackId : item.identifier;
    waDownload *download = [[waDownloadManager sharedManager] downloadForIdentifier:identifier];
    [(waArtworkCell *)cell setDownloadState:download ? download.state : waDownloadStateNotFound progress:download.progress];
    if (item.thumbnailURL.length) {
        NSURL *url = [NSURL URLWithString:item.thumbnailURL];
        if (!url.scheme.length) url = [[waAPIClient sharedClient] URLForPath:item.thumbnailURL];
        NSString *expected = [cell.artworkIdentifier copy];
        waMediaItem *captured = item;
        NSString *expectedURL = [item.thumbnailURL copy];
        __weak waLikedSongsViewController *weakSelf = self;
        [[waImageLoader sharedLoader] loadThumbnailAtURL:url.absoluteString targetSize:CGSizeMake(96.0, 96.0) placeholder:waPlaceholderImage() completion:^(UIImage *image) {
            NSIndexPath *currentPath = [tableView indexPathForCell:cell];
            if (!currentPath || ![cell.artworkIdentifier isEqualToString:expected] || !image) return;
            NSArray *latest = weakSelf ? weakSelf.songs : songs;
            waMediaItem *current = currentPath.row < latest.count ? latest[currentPath.row] : nil;
            if (current == captured && [current.thumbnailURL isEqualToString:expectedURL]) cell.imageView.image = image;
        }];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < self.songs.count) [[waAudioPlayer sharedPlayer] playItem:self.songs[indexPath.row] fromContext:self.songs title:self.title];
}

- (void)likesChanged:(NSNotification *)notification { (void)notification; if (self.view.window) [self.tableView reloadData]; }
- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.tableView.backgroundColor = [waTheme backgroundColor];
    if (self.view.window) [self.tableView reloadData];
}
- (void)reloadDownloadTable { self.downloadReloadScheduled = NO; if (self.view.window) [self updateVisibleDownloadStates]; }
- (void)updateVisibleDownloadStates {
    NSArray *paths = [self.tableView indexPathsForVisibleRows];
    if (!paths.count) return;
    NSArray *songs = self.songs;
    for (NSIndexPath *path in paths) {
        if (path.row >= songs.count) continue;
        waArtworkCell *cell = (waArtworkCell *)[self.tableView cellForRowAtIndexPath:path];
        if (![cell isKindOfClass:[waArtworkCell class]]) continue;
        waMediaItem *item = songs[path.row];
        NSString *downloadIdentifier = item.trackId.length ? item.trackId : item.identifier;
        waDownload *download = [[waDownloadManager sharedManager] downloadForIdentifier:downloadIdentifier];
        [cell setDownloadState:download ? download.state : waDownloadStateNotFound progress:download.progress];
    }
}
- (void)downloadsChanged:(NSNotification *)notification {
    if (!self.view.window) return;
    if ([notification.userInfo[@"event"] isEqualToString:@"progress"]) {
        if (self.downloadReloadScheduled) return;
        self.downloadReloadScheduled = YES;
        [self performSelector:@selector(reloadDownloadTable) withObject:nil afterDelay:0.4];
    } else [self.tableView reloadData];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:[gesture locationInView:self.tableView]];
    if (path && path.row < self.songs.count) [waMediaActionSheet presentForItem:self.songs[path.row] inViewController:self albumItems:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { (void)tableView; (void)indexPath; return YES; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete || indexPath.row >= self.songs.count) return;
    waMediaItem *item = self.songs[indexPath.row];
    NSMutableArray *mutable = [self.songs mutableCopy];
    [mutable removeObjectAtIndex:indexPath.row];
    self.songs = mutable;
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    [[waAPIClient sharedClient] setLiked:NO song:item completion:nil];
}

- (void)dealloc { [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reloadDownloadTable) object:nil]; [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
