#import "waDownloadsController.h"
#import "waDownloader.h"
#import "waPlayer.h"
#import "waRootController.h"
#import "waSession.h"
#import "waDetailController.h"
#import "../Skin/waCell.h"

static NSString *waByteString(unsigned long long bytes) {
    if (bytes < 1024ULL) return [NSString stringWithFormat:@"%llu B", bytes];
    if (bytes < 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.0f KB", (double)bytes / 1024.0];
    if (bytes < 1024ULL * 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1f MB", (double)bytes / 1048576.0];
    return [NSString stringWithFormat:@"%.1f GB", (double)bytes / 1073741824.0];
}

static NSString *waStateText(waDownload *download) {
    switch (download.state) {
        case waDownloadQueued: return @"Queued";
        case waDownloadResolving: return @"Preparing…";
        case waDownloadDownloading: {
            NSInteger pct = (NSInteger)(download.progress * 100.0f);
            if (pct < 0) pct = 0;
            if (pct > 99) pct = 99;
            return [NSString stringWithFormat:@"Downloading %ld%%", (long)pct];
        }
        case waDownloadFailed: return download.errorMessage.length ? download.errorMessage : @"Failed";
        case waDownloadCancelled: return @"Cancelled";
        default: break;
    }
    NSInteger seconds = (NSInteger)(download.track.duration + 0.5);
    if (seconds > 0) return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
    return @"Downloaded";
}

@interface waDownloadsController ()
@property (nonatomic, strong) UISegmentedControl *sortControl;
@property (nonatomic, strong) UIView *headerWrap;
@property (nonatomic, strong) NSArray *active;
@property (nonatomic, strong) NSArray *albums;
@property (nonatomic, strong) NSArray *playlists;
@property (nonatomic, strong) NSArray *completed;
@end

@implementation waDownloadsController

- (id)init {
    return [self initWithGroupedStyle:YES];
}

- (id)initWithGroupedStyle:(BOOL)grouped {
    if ((self = [super initWithGroupedStyle:grouped])) {
        self.title = @"Downloads";
        self.emptyTitle = @"Downloads";
        self.emptyMessage = @"No downloads.";
        _active = [NSArray array];
        _albums = [NSArray array];
        _playlists = [NSArray array];
        _completed = [NSArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.navigationItem.rightBarButtonItem = self.editButtonItem;
    self.headerWrap = [[UIView alloc] initWithFrame:CGRectZero];
    self.sortControl = [[UISegmentedControl alloc] initWithItems:[NSArray arrayWithObjects:@"Recent", @"Title", @"Artist", nil]];
    self.sortControl.segmentedControlStyle = UISegmentedControlStyleBar;
    self.sortControl.selectedSegmentIndex = (NSInteger)[waDownloader shared].sort;
    [self.sortControl addTarget:self action:@selector(sortChanged:) forControlEvents:UIControlEventValueChanged];
    [self.headerWrap addSubview:self.sortControl];
    self.tableView.tableHeaderView = self.headerWrap;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloaderChanged:) name:waDownloaderDidChangeNotification object:nil];
    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self layoutHeader];
    [self reload];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration {
    (void)orientation; (void)duration;
    [self layoutHeader];
}

- (void)layoutHeader {
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w < 1.0) w = 320.0;
    self.sortControl.frame = CGRectMake(10.0, 10.0, w - 20.0, 30.0);
    self.headerWrap.frame = CGRectMake(0.0, 0.0, w, 50.0);
    self.tableView.tableHeaderView = self.headerWrap;
}

- (void)sortChanged:(UISegmentedControl *)control {
    [waDownloader shared].sort = (waDownloadSort)control.selectedSegmentIndex;
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
}

- (void)downloaderChanged:(NSNotification *)note {
    if ([[note.userInfo objectForKey:@"progress"] boolValue]) {
        [self refreshProgress];
        return;
    }
    [self reload];
}

- (void)refreshProgress {
    NSArray *active = [[waDownloader shared] activeDownloads];
    if (active.count != self.active.count) {
        [self reload];
        return;
    }
    self.active = active;
    for (NSIndexPath *path in self.tableView.indexPathsForVisibleRows) {
        if (path.section != 0) continue;
        waDownload *download = [self downloadAtIndexPath:path];
        waCell *cell = (waCell *)[self.tableView cellForRowAtIndexPath:path];
        if (!download || ![cell isKindOfClass:[waCell class]]) continue;
        cell.detailTextLabel.text = waStateText(download);
        if (download.state == waDownloadDownloading) {
            cell.badgeLabel.text = [NSString stringWithFormat:@"%ld%%", (long)(download.progress * 100.0f)];
        }
        [cell setNeedsLayout];
    }
}

- (void)reload {
    self.active = [[waDownloader shared] activeDownloads];
    self.albums = [[waDownloader shared] albumCollections];
    self.playlists = [[waDownloader shared] playlistCollections];
    self.completed = [[waDownloader shared] completedDownloads];
    self.tableView.backgroundView = nil;
    [self.tableView reloadData];
}

- (BOOL)isEmpty {
    return !self.active.count && !self.albums.count && !self.playlists.count && !self.completed.count;
}

- (waDownload *)downloadAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *list = nil;
    if (indexPath.section == 0) list = self.active;
    else if (indexPath.section == 3) list = self.completed;
    if (!list || indexPath.row < 0 || indexPath.row >= (NSInteger)list.count) return nil;
    return [list objectAtIndex:(NSUInteger)indexPath.row];
}

- (waDownloadCollection *)collectionAtIndexPath:(NSIndexPath *)indexPath {
    NSArray *list = nil;
    if (indexPath.section == 1) list = self.albums;
    else if (indexPath.section == 2) list = self.playlists;
    if (!list || indexPath.row < 0 || indexPath.row >= (NSInteger)list.count) return nil;
    return [list objectAtIndex:(NSUInteger)indexPath.row];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return self.active.count ? @"Downloading" : nil;
    if (section == 1) return self.albums.count ? @"Albums" : nil;
    if (section == 2) return self.playlists.count ? @"Playlists" : nil;
    if (self.completed.count) {
        return [NSString stringWithFormat:@"Songs · %@", waByteString([[waDownloader shared] downloadedBytes])];
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if ([self isEmpty]) return section == 0 ? 1 : 0;
    if (section == 0) return (NSInteger)self.active.count;
    if (section == 1) return (NSInteger)self.albums.count;
    if (section == 2) return (NSInteger)self.playlists.count;
    return (NSInteger)self.completed.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self isEmpty]) {
        static NSString *kEmpty = @"downloads.empty";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kEmpty];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kEmpty];
            cell.textLabel.font = [UIFont systemFontOfSize:14.0];
            cell.textLabel.textColor = [UIColor grayColor];
        }
        cell.textLabel.text = @"No downloads.";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    waDownloadCollection *collection = [self collectionAtIndexPath:indexPath];
    if (collection) {
        waCell *cell = [waCell cellForTable:tableView subtitle:YES];
        waAlbum *album = [[waAlbum alloc] init];
        album.identifier = collection.identifier;
        album.title = collection.title.length ? collection.title : @"Album";
        album.artistName = collection.artistName;
        album.artworkURL = collection.artworkURL;
        NSString *local = [[waDownloader shared] localArtworkPathForAlbumID:collection.identifier];
        if (local.length) album.artworkURL = local;
        album.trackCount = (NSInteger)collection.trackIDs.count;
        [cell setItem:album];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld songs", (long)collection.trackIDs.count];
        [cell setDownloaded:YES];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        [cell setNeedsLayout];
        return cell;
    }

    waDownload *download = [self downloadAtIndexPath:indexPath];
    waCell *cell = [waCell cellForTable:tableView subtitle:YES];
    waTrack *track = download.track;
    if ([track isKindOfClass:[waTrack class]]) [cell setTrack:track showAlbum:YES];
    else {
        cell.textLabel.text = download.trackID.length ? download.trackID : @"Track";
        cell.detailTextLabel.text = waStateText(download);
    }
    cell.detailTextLabel.text = waStateText(download);
    cell.badgeLabel.text = nil;
    if (download.state == waDownloadDownloading) {
        cell.badgeLabel.text = [NSString stringWithFormat:@"%ld%%", (long)(download.progress * 100.0f)];
    } else if (download.state == waDownloadCompleted) {
        NSInteger seconds = (NSInteger)(track.duration + 0.5);
        if (seconds > 0) cell.badgeLabel.text = [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
        [cell setDownloaded:YES];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    [cell setNeedsLayout];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return [self downloadAtIndexPath:indexPath] != nil || [self collectionAtIndexPath:indexPath] != nil;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    waDownloadCollection *collection = [self collectionAtIndexPath:indexPath];
    if (collection) {
        [[waDownloader shared] removeCollection:collection];
        return;
    }
    waDownload *download = [self downloadAtIndexPath:indexPath];
    if (!download) return;
    [[waDownloader shared] removeDownload:download];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    waDownloadCollection *collection = [self collectionAtIndexPath:indexPath];
    if (collection) {
        if ([collection.kind isEqualToString:@"playlist"]) {
            waPlaylist *playlist = [[waDownloader shared] playlistForCollection:collection];
            [self.navigationController pushViewController:[[waDetailController alloc] initWithPlaylist:playlist downloaded:YES] animated:YES];
        } else {
            waAlbum *album = [[waDownloader shared] albumForCollection:collection];
            [self.navigationController pushViewController:[[waDetailController alloc] initWithAlbum:album downloaded:YES] animated:YES];
        }
        return;
    }
    waDownload *download = [self downloadAtIndexPath:indexPath];
    if (!download) return;
    if (download.state == waDownloadFailed || download.state == waDownloadCancelled) {
        [[waDownloader shared] retryDownload:download];
        return;
    }
    if (download.state != waDownloadCompleted) return;
    NSArray *tracks = [[waDownloader shared] completedTracks];
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < tracks.count; i++) {
        waTrack *track = [tracks objectAtIndex:i];
        if ([track.identifier isEqualToString:download.trackID]) { start = i; break; }
    }
    if (!tracks.count) return;
    [[waPlayer shared] playTracks:tracks startAt:start context:@"Downloads"];
    [[waRootController shared] showPlayer];
}

@end
