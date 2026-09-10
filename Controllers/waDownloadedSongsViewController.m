#import "waDownloadedSongsViewController.h"
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

@interface waDownloadedSongsViewController () <UIActionSheetDelegate>
@property (nonatomic, strong) NSArray *downloads;
@property (nonatomic, strong) NSArray *rowSnapshots;
// waMediaItems built once per data load so cellForRow never allocs per row.
@property (nonatomic, strong) NSArray *cachedLikeItems;
@property (nonatomic, strong) waEmptyView *emptyView;
@property (nonatomic, assign) BOOL downloadReloadScheduled;
@property (nonatomic, copy) NSString *pendingStopIdentifier;
@end

static waMediaItem *waDownloadedSongItem(waDownload *download) {
    if (!download) return nil;
    waMediaItem *item = [waMediaItem itemWithDictionary:@{
        @"trackId": download.identifier ?: @"",
        @"title": download.title ?: @"Downloaded Song",
        @"artist": download.artist ?: @"",
        @"thumbnail": download.thumbnailURL ?: @"",
         @"albumName": download.albumName ?: @"",
         @"explicit": @(download.isExplicit)
    }];
    item.duration = download.duration;
    return item;
}

@implementation waDownloadedSongsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Downloaded Songs";
    UIBarButtonItem *playAll = [[UIBarButtonItem alloc] initWithTitle:@"Play All" style:UIBarButtonItemStyleBordered target:self action:@selector(playAll:)];
    UIBarButtonItem *shuffleAll = [[UIBarButtonItem alloc] initWithTitle:@"Shuffle" style:UIBarButtonItemStyleBordered target:self action:@selector(shuffleAll:)];
    self.navigationItem.rightBarButtonItems = @[shuffleAll, playAll];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    UIView *tableBackground = [[UIView alloc] initWithFrame:CGRectZero];
    tableBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableBackground.backgroundColor = [waTheme backgroundColor];
    self.emptyView = [[waEmptyView alloc] initWithFrame:tableBackground.bounds];
    self.emptyView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [tableBackground addSubview:self.emptyView];
    self.tableView.backgroundView = tableBackground;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadsChanged:) name:waDownloadManagerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    [self.tableView addGestureRecognizer:longPress];
    [waTheme applyToView:self.view];
    [self reloadData];
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadData]; }
- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.view.backgroundColor = [waTheme backgroundColor];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.separatorColor = [UIColor clearColor];
    [self.emptyView applyTheme];
    [self.tableView reloadData];
}
- (void)reloadDownloadData { self.downloadReloadScheduled = NO; if (self.view.window) [self reloadData]; }
- (void)downloadsChanged:(NSNotification *)notification {
    if (!self.view.window) return;
    if ([notification.userInfo[@"event"] isEqualToString:@"progress"]) {
        if (self.downloadReloadScheduled) return;
        self.downloadReloadScheduled = YES;
        [self performSelector:@selector(reloadDownloadData) withObject:nil afterDelay:0.4];
    } else {
        if (self.downloadReloadScheduled) return;
        self.downloadReloadScheduled = YES;
        [self performSelector:@selector(reloadDownloadData) withObject:nil afterDelay:0.12];
    }
}
- (void)reloadData {
    self.downloads = [[waDownloadManager sharedManager] downloadsForCategory:waDownloadCategorySong];
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:self.downloads.count];
    NSMutableArray *likeItems = [NSMutableArray arrayWithCapacity:self.downloads.count];
    for (waDownload *download in self.downloads) {
        [rows addObject:@{ @"identifier": download.identifier ?: @"",
                          @"title": download.title.length ? download.title : @"Downloaded Song",
                          @"detail": download.artist ?: @"",
                          @"artworkPath": download.artworkFilePath ?: @"",
                          @"thumbnailURL": download.thumbnailURL ?: @"" }];
        waMediaItem *likeItem = waDownloadedSongItem(download);
        [likeItems addObject:likeItem ?: [NSNull null]];
    }
    self.rowSnapshots = rows;
    self.cachedLikeItems = likeItems;
    [self.emptyView configureWithIcon:[UIImage imageNamed:@"wave-downloaded"]
                                title:@"No downloaded songs"
                             subtitle:@"Songs you download will appear here."
                          actionTitle:nil
                               target:nil
                               action:NULL];
    self.emptyView.hidden = self.downloads.count > 0;
    [self.emptyView applyTheme];
    [self.tableView reloadData];
}

- (NSArray *)completedItems {
    NSMutableArray *items = [NSMutableArray array];
    for (waDownload *download in self.downloads) {
        NSString *path = [[waDownloadManager sharedManager] localPathForIdentifier:download.identifier] ?: download.filePath;
        if (download.state != waDownloadStateCompleted || !path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        waMediaItem *item = waDownloadedSongItem(download);
        if (item) [items addObject:item];
    }
    return items;
}

- (void)playAll:(id)sender {
    (void)sender;
    NSArray *snapshot = [self.downloads copy];
    NSString *title = [self.title copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *items = [NSMutableArray array];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        waDownloadManager *manager = [waDownloadManager sharedManager];
        for (waDownload *download in snapshot) {
            NSString *path = [manager localPathForIdentifier:download.identifier] ?: download.filePath;
            if (download.state != waDownloadStateCompleted || !path.length || ![fileManager fileExistsAtPath:path]) continue;
            waMediaItem *item = waDownloadedSongItem(download);
            if (item) [items addObject:item];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            waDownloadedSongsViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [waAudioPlayer sharedPlayer].shuffleEnabled = NO;
            if (items.count) [[waAudioPlayer sharedPlayer] playItem:items[0] fromContext:items title:title];
        });
    });
}

- (void)shuffleAll:(id)sender {
    (void)sender;
    NSArray *snapshot = [self.downloads copy];
    NSString *title = [self.title copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *items = [NSMutableArray array];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        waDownloadManager *manager = [waDownloadManager sharedManager];
        for (waDownload *download in snapshot) {
            NSString *path = [manager localPathForIdentifier:download.identifier] ?: download.filePath;
            if (download.state != waDownloadStateCompleted || !path.length || ![fileManager fileExistsAtPath:path]) continue;
            waMediaItem *item = waDownloadedSongItem(download);
            if (item) [items addObject:item];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            waDownloadedSongsViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [waAudioPlayer sharedPlayer].shuffleEnabled = YES;
            if (items.count) [[waAudioPlayer sharedPlayer] playItem:items[0] fromContext:items title:title];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.downloads.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return [waTheme standardRowHeight]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    waArtworkCell *cell = [tableView dequeueReusableCellWithIdentifier:@"offlineSong"];
    if (!cell) {
        cell = [[waArtworkCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"offlineSong"];
        // Flat full-width rows: style once here, never walk the subtree per row.
        cell.cardStyle = NO;
        cell.backgroundColor = [waTheme backgroundColor];
        UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
        selected.backgroundColor = [waTheme selectedSurfaceColor];
        cell.selectedBackgroundView = selected;
    }
     waDownload *download = self.downloads[indexPath.row];
     id cached = indexPath.row < (NSInteger)self.cachedLikeItems.count ? self.cachedLikeItems[indexPath.row] : nil;
     [(waArtworkCell *)cell setLikeItem:[cached isKindOfClass:[waMediaItem class]] ? cached : nil];
    NSDictionary *row = self.rowSnapshots[indexPath.row];
    cell.backgroundColor = [waTheme backgroundColor];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.textColor = [waTheme primaryTextColor];
    cell.multilineDetail = NO;
    cell.detailTextLabel.text = row[@"detail"];
    cell.detailTextLabel.textColor = [waTheme secondaryTextColor];
    cell.accessoryType = UITableViewCellAccessoryNone;
    [(waArtworkCell *)cell setDownloadState:download.state progress:download.progress];
    [(waArtworkCell *)cell setExplicit:download.isExplicit];
    cell.imageView.image = waPlaceholderImage();
    NSString *cellIdentifier = row[@"identifier"];
    cell.artworkIdentifier = cellIdentifier;
    cell.imageView.image = waPlaceholderImage();
    void (^loadRemote)(void) = ^{
        NSString *thumbnail = row[@"thumbnailURL"];
        if (!thumbnail.length) return;
        NSURL *url = [NSURL URLWithString:thumbnail];
        if (!url.scheme.length) url = [[waAPIClient sharedClient] URLForPath:download.thumbnailURL];
        [[waImageLoader sharedLoader] loadThumbnailAtURL:url.absoluteString placeholder:waPlaceholderImage() completion:^(UIImage *image) {
            if (image && [cell.artworkIdentifier isEqualToString:cellIdentifier] && [cell isDescendantOfView:tableView]) cell.imageView.image = image;
        }];
    };
    if ([row[@"artworkPath"] length]) {
        CGFloat artworkSize = [waTheme standardArtworkSize];
        [[waImageLoader sharedLoader] loadLocalImageAtPath:row[@"artworkPath"] targetSize:CGSizeMake(artworkSize, artworkSize) completion:^(UIImage *image) {
            if (image && [cell.artworkIdentifier isEqualToString:cellIdentifier] && [cell isDescendantOfView:tableView]) cell.imageView.image = image;
            else if (!image) loadRemote();
        }];
    } else loadRemote();
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= self.downloads.count) return;
    waDownload *selectedDownload = self.downloads[indexPath.row];
    // Active downloads can't play yet: offer an explicit stop instead.
    if (selectedDownload.state == waDownloadStateDownloading || selectedDownload.state == waDownloadStateQueued) {
        self.pendingStopIdentifier = [selectedDownload.identifier copy];
        NSString *title = selectedDownload.title.length ? selectedDownload.title : @"This download";
        UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:[NSString stringWithFormat:@"%@ is still downloading.", title] delegate:self cancelButtonTitle:@"Keep Downloading" destructiveButtonTitle:@"Stop Download" otherButtonTitles:nil];
        [sheet showInView:self.view];
        return;
    }
    NSString *selectedIdentifier = [selectedDownload.identifier copy];
    NSArray *snapshot = [self.downloads copy];
    NSString *title = [self.title copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *items = [NSMutableArray array];
        NSUInteger selectedIndex = NSNotFound;
        NSFileManager *fileManager = [NSFileManager defaultManager];
        waDownloadManager *manager = [waDownloadManager sharedManager];
        for (waDownload *download in snapshot) {
            NSString *path = [manager localPathForIdentifier:download.identifier] ?: download.filePath;
            if (download.state != waDownloadStateCompleted || !path.length || ![fileManager fileExistsAtPath:path]) continue;
            waMediaItem *item = waDownloadedSongItem(download);
            if ([download.identifier isEqualToString:selectedIdentifier]) selectedIndex = items.count;
            if (item) [items addObject:item];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            waDownloadedSongsViewController *strongSelf = weakSelf;
            (void)strongSelf;
            if (selectedIndex != NSNotFound && items.count) [[waAudioPlayer sharedPlayer] playItem:items[selectedIndex] fromContext:items title:title];
        });
    });
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    (void)actionSheet;
    // Destructive "Stop Download" is index 0; cancel dismisses.
    if (buttonIndex == 0 && self.pendingStopIdentifier.length) {
        [[waDownloadManager sharedManager] cancelDownloadWithIdentifier:self.pendingStopIdentifier];
    }
    self.pendingStopIdentifier = nil;
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:[gesture locationInView:self.tableView]];
    if (!indexPath || indexPath.row >= self.downloads.count) return;
    waDownload *download = self.downloads[indexPath.row];
    waMediaItem *item = waDownloadedSongItem(download);
    if (item) [waMediaActionSheet presentForItem:item inViewController:self albumItems:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath { return UITableViewCellEditingStyleDelete; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    waDownload *download = self.downloads[indexPath.row];
    if (download.state == waDownloadStateDownloading || download.state == waDownloadStateQueued) [[waDownloadManager sharedManager] cancelDownloadWithIdentifier:download.identifier];
    else [[waDownloadManager sharedManager] deleteDownloadWithIdentifier:download.identifier completion:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
