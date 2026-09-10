#import "waDownloadedAlbumDetailViewController.h"
#import "../Services/waDownloadManager.h"
#import "../Models/waDownload.h"
#import "../Models/waMediaItem.h"
#import "../Services/waAudioPlayer.h"
#import "../Services/waTheme.h"
#import "../Services/waImageLoader.h"
#import "../Views/waPlaceholder.h"
#import "../Services/waAPIClient.h"
#import "../Views/waArtworkCell.h"
#import "../Views/waMediaActionSheet.h"

static NSString *waDetailSizeString(unsigned long long bytes) {
    return waFileSizeString(bytes);
}

static waMediaItem *waMediaItemFromDownload(waDownload *download) {
    if (!download) return nil;
    NSString *identifier = download.identifier ?: @"";
    NSDictionary *dict = @{ @"trackId": identifier,
                            @"title": download.title ?: @"Downloaded Song",
                            @"artist": download.artist ?: @"",
                            @"thumbnail": download.thumbnailURL ?: @"",
                             @"albumName": download.albumName ?: @"",
                             @"explicit": @(download.isExplicit) };
    waMediaItem *item = [waMediaItem itemWithDictionary:dict];
    item.duration = download.duration;
    return item;
}

@interface waDownloadedAlbumDetailViewController () <UIActionSheetDelegate>
@property (nonatomic, copy) NSString *albumIdentifier;
@property (nonatomic, copy) NSArray *downloads;
@property (nonatomic, assign) BOOL downloadReloadScheduled;
@property (nonatomic, strong) NSArray *rowSnapshots;
@property (nonatomic, assign) NSUInteger dataGeneration;
// waMediaItems built once per data load so cellForRow never allocs per row.
@property (nonatomic, strong) NSArray *cachedLikeItems;
@property (nonatomic, copy) NSString *pendingStopIdentifier;
@end

@implementation waDownloadedAlbumDetailViewController

- (id)initWithAlbumIdentifier:(NSString *)identifier title:(NSString *)title downloads:(NSArray *)downloads {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _albumIdentifier = [identifier copy];
        _downloads = [downloads copy];
        self.title = title.length ? title : @"Album";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadsChanged:) name:waDownloadManagerDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
        [waTheme applyToView:self.view];
        UIBarButtonItem *playAll = [[UIBarButtonItem alloc] initWithTitle:@"Play All" style:UIBarButtonItemStyleBordered target:self action:@selector(playAll:)];
        UIBarButtonItem *shuffleAll = [[UIBarButtonItem alloc] initWithTitle:@"Shuffle" style:UIBarButtonItemStyleBordered target:self action:@selector(shuffleAll:)];
        self.navigationItem.rightBarButtonItems = @[shuffleAll, playAll];
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        [self.tableView addGestureRecognizer:longPress];
        [self reloadData];
}

- (void)reloadDownloadData { self.downloadReloadScheduled = NO; if (self.view.window) [self reloadData]; }
- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.view.backgroundColor = [waTheme backgroundColor];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.separatorColor = [waTheme separatorColor];
    if (self.view.window) [self.tableView reloadData];
}
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
    NSUInteger generation = ++self.dataGeneration;
    // Refresh from manager to reflect deletions
    NSMutableArray *filtered = [NSMutableArray array];
    for (waDownload *d in [[waDownloadManager sharedManager] downloadsForCategory:waDownloadCategoryAlbum]) {
        NSArray *contexts = [d contextIdentifiersForCategory:waDownloadCategoryAlbum];
        if ([contexts containsObject:self.albumIdentifier]) [filtered addObject:d];
    }
    self.downloads = filtered;
    NSMutableArray *rows = [NSMutableArray arrayWithCapacity:self.downloads.count];
    for (waDownload *d in self.downloads) {
        NSString *duration = d.duration > 0 ? [NSString stringWithFormat:@"%ld:%02ld • ", (long)(d.duration/60), (long)((NSInteger)d.duration%60)] : @"";
        NSString *quality = @[@"128k", @"320k", @"Lossless"][MIN(2, d.downloadQuality)];
        [rows addObject:@{ @"identifier": d.identifier ?: @"",
                          @"title": d.title.length ? d.title : d.identifier,
                          @"detailPrefix": duration,
                          @"artist": d.artist ?: @"",
                          @"quality": quality,
                          @"bytes": @(d.state == waDownloadStateCompleted ? 0 : d.bytesReceived),
                          @"state": @(d.state),
                          @"received": @(d.bytesReceived),
                          @"filePath": d.filePath ?: @"",
                          @"artworkPath": d.artworkFilePath ?: @"",
                          @"thumbnailURL": d.thumbnailURL ?: @"" }];
    }
    self.rowSnapshots = rows;
    NSMutableArray *likeItems = [NSMutableArray arrayWithCapacity:self.downloads.count];
    for (waDownload *d in self.downloads) {
        waMediaItem *likeItem = [[waMediaItem alloc] initWithIdentifier:d.identifier title:d.title ?: @"Downloaded Song" subtitle:d.artist ?: @"" type:waMediaItemTypeSong];
        likeItem.trackId = d.identifier;
        likeItem.albumName = d.albumName;
        likeItem.duration = d.duration;
        likeItem.explicit = d.isExplicit;
        [likeItems addObject:likeItem];
    }
    self.cachedLikeItems = likeItems;
    [self.tableView reloadData];
    if (self.downloads.count == 0 && self.navigationController) [self.navigationController popViewControllerAnimated:YES];
    NSArray *rowSnapshot = [self.rowSnapshots copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
        for (NSDictionary *row in rowSnapshot) {
            unsigned long long bytes = [row[@"state"] integerValue] == waDownloadStateCompleted ? 0 : [row[@"received"] unsignedLongLongValue];
            NSString *path = row[@"filePath"];
            if ([row[@"state"] integerValue] == waDownloadStateCompleted && path.length) {
                NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
                if (!attributes) {
                    NSString *legacy = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"audio"];
                    attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:legacy error:NULL];
                }
                bytes = [attributes[NSFileSize] unsignedLongLongValue];
            }
            sizes[row[@"identifier"] ?: @""] = @(bytes);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.dataGeneration) return;
            NSMutableArray *updated = [NSMutableArray arrayWithCapacity:self.rowSnapshots.count];
            for (NSDictionary *row in self.rowSnapshots) {
                NSMutableDictionary *copy = [row mutableCopy];
                copy[@"bytes"] = sizes[row[@"identifier"]] ?: @0;
                [updated addObject:copy];
            }
            self.rowSnapshots = updated;
            [self.tableView reloadData];
        });
    });
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
        for (waDownload *d in snapshot) {
            NSString *path = [manager localPathForIdentifier:d.identifier] ?: d.filePath;
            if (d.state == waDownloadStateCompleted && path.length && [fileManager fileExistsAtPath:path]) {
                waMediaItem *media = waMediaItemFromDownload(d);
                if (media) {
                    media.duration = d.duration;
                    [items addObject:media];
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            waDownloadedAlbumDetailViewController *strongSelf = weakSelf;
            (void)strongSelf;
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
        for (waDownload *d in snapshot) {
            NSString *path = [manager localPathForIdentifier:d.identifier] ?: d.filePath;
            if (d.state != waDownloadStateCompleted || !path.length || ![fileManager fileExistsAtPath:path]) continue;
            waMediaItem *media = waMediaItemFromDownload(d);
            if (media) [items addObject:media];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            waDownloadedAlbumDetailViewController *strongSelf = weakSelf;
            (void)strongSelf;
            [waAudioPlayer sharedPlayer].shuffleEnabled = YES;
            if (items.count) [[waAudioPlayer sharedPlayer] playItem:items[0] fromContext:items title:title];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.downloads.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return [waTheme standardRowHeight]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"dlTrack"];
    if (!cell) {
        cell = [[waArtworkCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"dlTrack"];
        // Flat full-width rows: style once here, never walk the subtree per row.
        ((waArtworkCell *)cell).cardStyle = NO;
        cell.backgroundColor = [waTheme backgroundColor];
        UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
        selected.backgroundColor = [waTheme selectedSurfaceColor];
        cell.selectedBackgroundView = selected;
    }
    ((waArtworkCell *)cell).cardStyle = NO;
     waDownload *d = self.downloads[indexPath.row];
     id cached = indexPath.row < (NSInteger)self.cachedLikeItems.count ? self.cachedLikeItems[indexPath.row] : nil;
     [(waArtworkCell *)cell setLikeItem:[cached isKindOfClass:[waMediaItem class]] ? cached : nil];
    NSDictionary *row = indexPath.row < self.rowSnapshots.count ? self.rowSnapshots[indexPath.row] : nil;
    cell.backgroundColor = [waTheme backgroundColor];
    cell.textLabel.textColor = [waTheme primaryTextColor];
    cell.detailTextLabel.textColor = [waTheme secondaryTextColor];
    cell.textLabel.text = row[@"title"];
    if (!cell.textLabel.text.length) cell.textLabel.text = d.title.length ? d.title : d.identifier;
    NSString *quality = [row[@"quality"] isKindOfClass:[NSString class]] ? row[@"quality"] : @[@"128k", @"320k", @"Lossless"][MIN(2, d.downloadQuality)];
    NSString *duration = [row[@"detailPrefix"] isKindOfClass:[NSString class]] ? row[@"detailPrefix"] : @"";
    unsigned long long bytes = [row[@"bytes"] unsignedLongLongValue];
    NSString *state = @"Downloaded";
    if (d.state == waDownloadStateQueued) state = @"Queued";
    else if (d.state == waDownloadStateDownloading) state = [NSString stringWithFormat:@"Downloading %.0f%%", d.progress*100.0f];
    else if (d.state == waDownloadStateFailed) state = @"Failed";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@ • %@ • %@", duration, d.artist ?: @"", quality, waDetailSizeString(bytes)];
    cell.accessoryType = UITableViewCellAccessoryNone;
    [(waArtworkCell *)cell setDownloadState:d.state progress:d.progress];
    [(waArtworkCell *)cell setExplicit:d.isExplicit];
    cell.imageView.image = waPlaceholderImage();
    NSString *cellIdentifier = row[@"identifier"];
    [(waArtworkCell *)cell setArtworkIdentifier:cellIdentifier];
    void (^loadRemote)(void) = ^{
        NSString *thumbnail = row[@"thumbnailURL"];
        if (!thumbnail.length) return;
        NSURL *url = [NSURL URLWithString:thumbnail];
        if (!url.scheme.length) url = [[waAPIClient sharedClient] URLForPath:d.thumbnailURL];
        [[waImageLoader sharedLoader] loadThumbnailAtURL:url.absoluteString placeholder:waPlaceholderImage() completion:^(UIImage *image) {
            if (image && [((waArtworkCell *)cell).artworkIdentifier isEqualToString:cellIdentifier] && [cell isDescendantOfView:tableView]) cell.imageView.image = image;
        }];
    };
    if ([row[@"artworkPath"] length]) {
        CGFloat artworkSize = [waTheme standardArtworkSize];
        [[waImageLoader sharedLoader] loadLocalImageAtPath:row[@"artworkPath"] targetSize:CGSizeMake(artworkSize, artworkSize) completion:^(UIImage *image) {
            if (image && [((waArtworkCell *)cell).artworkIdentifier isEqualToString:cellIdentifier] && [cell isDescendantOfView:tableView]) cell.imageView.image = image;
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
        for (waDownload *d in snapshot) {
            NSString *path = [manager localPathForIdentifier:d.identifier] ?: d.filePath;
            if (d.state != waDownloadStateCompleted || !path.length || ![fileManager fileExistsAtPath:path]) continue;
            waMediaItem *item = waMediaItemFromDownload(d);
            if (!item) continue;
            if ([d.identifier isEqualToString:selectedIdentifier]) selectedIndex = items.count;
            [items addObject:item];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            waDownloadedAlbumDetailViewController *strongSelf = weakSelf;
            (void)strongSelf;
            if (selectedIndex != NSNotFound && items.count) {
                waMediaItem *selected = items[selectedIndex];
                [[waAudioPlayer sharedPlayer] playItem:selected fromContext:items title:title];
            }
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
    if (download.state != waDownloadStateCompleted) return;
    waMediaItem *item = waMediaItemFromDownload(download);
    if (item) [waMediaActionSheet presentForItem:item inViewController:self albumItems:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath { return UITableViewCellEditingStyleDelete; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    waDownload *d = self.downloads[indexPath.row];
    if (d.state == waDownloadStateDownloading || d.state == waDownloadStateQueued) [[waDownloadManager sharedManager] cancelDownloadWithIdentifier:d.identifier];
    else [[waDownloadManager sharedManager] deleteDownloadWithIdentifier:d.identifier completion:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
