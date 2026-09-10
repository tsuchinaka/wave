#import "waDownloadedAlbumsViewController.h"
#import "../Services/waDownloadManager.h"
#import "../Models/waDownload.h"
#import "../Services/waImageLoader.h"
#import "../Views/waArtworkCell.h"
#import "../Views/waPlaceholder.h"
#import "../Services/waAPIClient.h"
#import "../Services/waTheme.h"
#import "../Services/waAudioPlayer.h"
#import "waDownloadedAlbumDetailViewController.h"
#import "waMediaDetailViewController.h"
#import "../Models/waAlbum.h"
#import "../Views/waEmptyView.h"

static NSString *waAlbumSizeString(unsigned long long bytes) {
    return waFileSizeString(bytes);
}

@interface waDownloadedAlbumsViewController ()
@property (nonatomic, strong) NSArray *groups; // each dict: identifier, title, artist, count, bytes, artworkPath, thumbnailURL, downloads
@property (nonatomic, strong) waEmptyView *emptyView;
@property (nonatomic, assign) BOOL downloadReloadScheduled;
@property (nonatomic, assign) NSUInteger groupsGeneration;
@end

@implementation waDownloadedAlbumsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Downloaded Albums";
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.separatorColor = [UIColor clearColor];
    UIView *tableBackground = [[UIView alloc] initWithFrame:CGRectZero];
    tableBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableBackground.backgroundColor = [waTheme backgroundColor];
    self.emptyView = [[waEmptyView alloc] initWithFrame:tableBackground.bounds];
    self.emptyView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [tableBackground addSubview:self.emptyView];
    self.tableView.backgroundView = tableBackground;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadsChanged:) name:waDownloadManagerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    [waTheme applyToView:self.view];
    [self reloadGroups];
}

- (void)reloadDownloadGroups { self.downloadReloadScheduled = NO; if (self.view.window) [self reloadGroups]; }
- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.view.backgroundColor = [waTheme backgroundColor];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.separatorColor = [UIColor clearColor];
    [self.emptyView applyTheme];
    [self.tableView reloadData];
}
- (void)downloadsChanged:(NSNotification *)n {
    if (!self.view.window) return;
    if ([n.userInfo[@"event"] isEqualToString:@"progress"]) {
        if (self.downloadReloadScheduled) return;
        self.downloadReloadScheduled = YES;
        [self performSelector:@selector(reloadDownloadGroups) withObject:nil afterDelay:0.4];
    } else {
        if (self.downloadReloadScheduled) return;
        self.downloadReloadScheduled = YES;
        [self performSelector:@selector(reloadDownloadGroups) withObject:nil afterDelay:0.12];
    }
}

- (void)reloadGroups {
    NSUInteger generation = ++self.groupsGeneration;
    NSArray *downloads = [[waDownloadManager sharedManager] downloadsForCategory:waDownloadCategoryAlbum];
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    for (waDownload *d in downloads) {
        NSArray *contexts = [d contextIdentifiersForCategory:waDownloadCategoryAlbum];
        NSString *albumId = contexts.count ? contexts[0] : d.identifier;
        if (!albumId.length) albumId = d.identifier;
        NSMutableArray *arr = map[albumId];
        if (!arr) { arr = [NSMutableArray array]; map[albumId] = arr; meta[albumId] = d; }
        [arr addObject:d];
    }
    NSMutableArray *groups = [NSMutableArray array];
    for (NSString *albumId in map) {
        NSArray *arr = map[albumId];
        waDownload *first = meta[albumId];
        BOOL hasExplicit = NO;
        for (waDownload *d in arr) if (d.isExplicit) { hasExplicit = YES; break; }
        NSString *title = first.albumName.length ? first.albumName : (first.title.length ? first.title : albumId);
        // If title is track title but not album title, fallback to albumId. Try to use context as title if albumName empty
        if ([title isEqualToString:first.title] && first.albumName.length == 0) {
            // use albumId as title if track title equals first title but no albumName
            // keep as is, but we may have better title from another download's albumName
            for (waDownload *d in arr) if (d.albumName.length) { title = d.albumName; break; }
            if (!title.length) title = albumId;
        }
        unsigned long long totalBytes = 0;
        NSMutableArray *fileEntries = [NSMutableArray arrayWithCapacity:arr.count];
        for (waDownload *d in arr) {
            unsigned long long size = 0;
            size = d.bytesReceived;
            totalBytes += size;
            [fileEntries addObject:@{ @"state": @(d.state), @"received": @(d.bytesReceived), @"path": d.filePath ?: @"" }];
        }
        NSString *artist = first.artist.length ? first.artist : @"";
        [groups addObject:@{
            @"identifier": albumId,
            @"title": title ?: @"Untitled Album",
            @"artist": artist ?: @"",
            @"count": @(arr.count),
            @"bytes": @(totalBytes),
            @"artworkPath": first.artworkFilePath ?: @"",
             @"thumbnailURL": first.thumbnailURL ?: @"",
             @"explicit": @(hasExplicit),
             @"downloads": arr,
             @"fileEntries": fileEntries,
             @"detail": [NSString stringWithFormat:@"%@\n%@", artist.length ? artist : @"Album", waAlbumSizeString(totalBytes)]
        }];
    }
    // Sort by title
    self.groups = [groups sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"title"] caseInsensitiveCompare:b[@"title"]];
    }];
    [self.emptyView configureWithIcon:[UIImage imageNamed:@"wave-downloaded"]
                                title:@"No downloaded albums"
                             subtitle:@"Albums you download will appear here."
                          actionTitle:nil
                               target:nil
                               action:NULL];
    self.emptyView.hidden = self.groups.count > 0;
    [self.emptyView applyTheme];
    [self.tableView reloadData];
    NSArray *snapshot = self.groups;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
        for (NSDictionary *group in snapshot) {
            unsigned long long total = 0;
            for (NSDictionary *entry in group[@"fileEntries"]) {
                if ([entry[@"state"] integerValue] != waDownloadStateCompleted) { total += [entry[@"received"] unsignedLongLongValue]; continue; }
                NSString *path = entry[@"path"];
                NSDictionary *attributes = path.length ? [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL] : nil;
                if (!attributes && path.length) {
                    NSString *legacy = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"audio"];
                    attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:legacy error:NULL];
                }
                total += [attributes[NSFileSize] unsignedLongLongValue];
            }
            sizes[group[@"identifier"]] = @(total);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.groupsGeneration) return;
            NSMutableArray *updated = [NSMutableArray arrayWithCapacity:self.groups.count];
            for (NSDictionary *group in self.groups) {
                NSMutableDictionary *copy = [group mutableCopy];
                unsigned long long bytes = [sizes[group[@"identifier"]] unsignedLongLongValue];
                copy[@"bytes"] = @(bytes);
                copy[@"detail"] = [NSString stringWithFormat:@"%@\n%@", group[@"artist"] && [group[@"artist"] length] ? group[@"artist"] : @"Album", waAlbumSizeString(bytes)];
                [updated addObject:copy];
            }
            self.groups = updated;
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.groups.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return [waTheme standardRowHeight]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"dlAlbum"];
    if (!cell) {
        cell = [[waArtworkCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"dlAlbum"];
        // Flat full-width rows: style once here, never walk the subtree per row.
        ((waArtworkCell *)cell).cardStyle = NO;
        cell.backgroundColor = [waTheme backgroundColor];
        UIView *selected = [[UIView alloc] initWithFrame:CGRectZero];
        selected.backgroundColor = [waTheme selectedSurfaceColor];
        cell.selectedBackgroundView = selected;
    }
    ((waArtworkCell *)cell).cardStyle = NO;
    NSDictionary *g = self.groups[indexPath.row];
    cell.backgroundColor = [waTheme backgroundColor];
    cell.textLabel.textColor = [waTheme primaryTextColor];
    cell.detailTextLabel.textColor = [waTheme secondaryTextColor];
    cell.textLabel.text = g[@"title"];
    [(waArtworkCell *)cell setMultilineDetail:YES];
    NSString *detail = g[@"detail"];
    cell.detailTextLabel.text = detail;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    [(waArtworkCell *)cell setExplicit:[g[@"explicit"] boolValue]];
    cell.imageView.image = waPlaceholderImage();
    NSString *artPath = g[@"artworkPath"];
    NSString *thumb = g[@"thumbnailURL"];
    NSString *cellIdentifier = g[@"identifier"];
    [(waArtworkCell *)cell setArtworkIdentifier:cellIdentifier];
    void (^loadRemote)(void) = ^{
        if (!thumb.length) return;
        NSURL *url = [NSURL URLWithString:thumb];
        if (!url.scheme.length) url = [[waAPIClient sharedClient] URLForPath:thumb];
        [[waImageLoader sharedLoader] loadThumbnailAtURL:url.absoluteString placeholder:waPlaceholderImage() completion:^(UIImage *image) {
            if (image && [((waArtworkCell *)cell).artworkIdentifier isEqualToString:cellIdentifier] && [cell isDescendantOfView:tableView]) cell.imageView.image = image;
        }];
    };
    if (artPath.length) {
        CGFloat artworkSize = [waTheme standardArtworkSize];
        [[waImageLoader sharedLoader] loadLocalImageAtPath:artPath targetSize:CGSizeMake(artworkSize, artworkSize) completion:^(UIImage *image) {
            if (image && [((waArtworkCell *)cell).artworkIdentifier isEqualToString:cellIdentifier] && [cell isDescendantOfView:tableView]) cell.imageView.image = image;
            else if (!image) loadRemote();
        }];
    } else loadRemote();
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *g = self.groups[indexPath.row];
    NSArray *downloads = g[@"downloads"];
    NSString *albumId = g[@"identifier"];
    NSString *title = g[@"title"];
    NSString *artist = g[@"artist"] ?: @"";
    waDownload *firstDownload = [downloads count] ? downloads[0] : nil;
    NSDictionary *albumMetadata = [firstDownload.metadata[@"albumMetadata"] isKindOfClass:[NSDictionary class]] ? firstDownload.metadata[@"albumMetadata"] : firstDownload.metadata;
    waAlbum *album = [[waAlbum alloc] initWithIdentifier:albumId title:title artist:artist trackCount:downloads.count];
    album.metadata = albumMetadata;
    id artistIdentifier = albumMetadata[@"artistIdentifier"] ?: albumMetadata[@"artistId"];
    if ([artistIdentifier isKindOfClass:[NSString class]]) album.artistIdentifier = artistIdentifier;
    id releaseYear = albumMetadata[@"releaseYear"] ?: albumMetadata[@"releaseDate"];
    if ([releaseYear isKindOfClass:[NSString class]]) album.releaseYear = releaseYear;
    id savedThumbnail = albumMetadata[@"thumbnailURL"] ?: albumMetadata[@"thumbnail"] ?: albumMetadata[@"artwork"];
    album.thumbnailURL = [savedThumbnail isKindOfClass:[NSString class]] ? savedThumbnail : g[@"thumbnailURL"];
    id savedArtist = albumMetadata[@"artistName"] ?: albumMetadata[@"artist"];
    if ([savedArtist isKindOfClass:[NSString class]] && [savedArtist length]) album.artistName = savedArtist;
    id savedLiked = albumMetadata[@"liked"] ?: albumMetadata[@"likedByMe"];
    album.liked = [savedLiked respondsToSelector:@selector(boolValue)] && [savedLiked boolValue];
    NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:downloads.count];
    for (waDownload *download in downloads) {
        waMediaItem *track = [waMediaItem itemWithDictionary:download.metadata];
        if (!track || track.type == waMediaItemTypeAlbum || track.type == waMediaItemTypeArtist) {
            track = [[waMediaItem alloc] initWithIdentifier:download.identifier title:download.title ?: @"Downloaded Song" subtitle:download.artist ?: @"" type:waMediaItemTypeSong];
        }
        track.type = waMediaItemTypeSong;
        track.metadata = download.metadata;
        track.identifier = download.identifier;
        if (download.title.length) track.title = download.title;
        if (download.artist.length) {
            track.artistName = download.artist;
            track.subtitle = download.artist;
        }
        track.trackId = download.identifier;
        if (download.thumbnailURL.length) track.thumbnailURL = download.thumbnailURL;
        track.albumName = title;
        if (download.duration > 0.0) track.duration = download.duration;
        track.explicit = download.isExplicit;
        track.albumIdentifier = albumId;
        [tracks addObject:track];
    }
    waMediaDetailViewController *detail = [[waMediaDetailViewController alloc] initWithMediaItem:album tracks:tracks artworkPath:g[@"artworkPath"]];
    [self.navigationController pushViewController:detail animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath { return YES; }
- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath { return UITableViewCellEditingStyleDelete; }
- (NSString *)tableView:(UITableView *)tableView titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath { return @"Delete"; }
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSDictionary *g = self.groups[indexPath.row];
    NSArray *downloads = g[@"downloads"];
    for (waDownload *d in downloads) {
        [[waDownloadManager sharedManager] deleteDownloadWithIdentifier:d.identifier completion:nil];
    }
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
