#import "waDetailController.h"
#import "waSession.h"
#import "waPlayer.h"
#import "waRootController.h"
#import "waDiscographyController.h"
#import "../Core/waDownloader.h"
#import "../Skin/waCell.h"
#import <QuartzCore/QuartzCore.h>

typedef enum {
    waDetailKindAlbum = 0,
    waDetailKindArtist,
    waDetailKindPlaylist
} waDetailKind;

// Horizontal header: artwork left, text right, actions below side by side.
@interface waDetailHeader : UIView
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIButton *radioButton;
@property (nonatomic, assign) BOOL artistStyle;
@property (nonatomic, copy) NSString *artworkURL;
- (CGFloat)layoutForWidth:(CGFloat)width;
@end

@implementation waDetailHeader

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor whiteColor];

        _artworkView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.opaque = YES;
        _artworkView.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        [self addSubview:_artworkView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.backgroundColor = [UIColor clearColor];
        _titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
        _titleLabel.textColor = [UIColor blackColor];
        _titleLabel.numberOfLines = 2;
        _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        [self addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subtitleLabel.backgroundColor = [UIColor clearColor];
        _subtitleLabel.font = [UIFont systemFontOfSize:14.0];
        _subtitleLabel.textColor = [UIColor colorWithRed:0.0 green:0.32 blue:0.60 alpha:1.0];
        _subtitleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        [self addSubview:_subtitleLabel];

        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel.backgroundColor = [UIColor clearColor];
        _detailLabel.font = [UIFont systemFontOfSize:12.0];
        _detailLabel.textColor = [UIColor grayColor];
        _detailLabel.numberOfLines = 2;
        _detailLabel.lineBreakMode = UILineBreakModeTailTruncation;
        [self addSubview:_detailLabel];

        _playButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [_playButton setTitle:@"Play" forState:UIControlStateNormal];
        _playButton.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
        [self addSubview:_playButton];

        _shuffleButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [_shuffleButton setTitle:@"Shuffle" forState:UIControlStateNormal];
        _shuffleButton.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
        [self addSubview:_shuffleButton];

        _radioButton = [UIButton buttonWithType:UIButtonTypeRoundedRect];
        [_radioButton setTitle:@"Radio" forState:UIControlStateNormal];
        _radioButton.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
        _radioButton.hidden = YES;
        [self addSubview:_radioButton];
    }
    return self;
}

- (CGFloat)layoutForWidth:(CGFloat)width {
    CGFloat m = 10.0;
    if (self.artistStyle) {
        self.backgroundColor = [UIColor groupTableViewBackgroundColor];
        self.titleLabel.hidden = YES;
        self.detailLabel.hidden = YES;
        self.playButton.hidden = YES;
        self.shuffleButton.hidden = YES;
        self.radioButton.hidden = YES;
        self.subtitleLabel.hidden = NO;
        self.subtitleLabel.textAlignment = UITextAlignmentCenter;
        self.subtitleLabel.textColor = [UIColor colorWithWhite:0.33 alpha:1.0];
        self.subtitleLabel.font = [UIFont systemFontOfSize:13.0];
        self.subtitleLabel.shadowColor = [UIColor colorWithWhite:1.0 alpha:0.75];
        self.subtitleLabel.shadowOffset = CGSizeMake(0.0, 1.0);
        CGFloat art = 90.0;
        self.artworkView.frame = CGRectMake((width - art) / 2.0, 16.0, art, art);
        self.artworkView.layer.borderWidth = 1.0;
        self.artworkView.layer.borderColor = [UIColor colorWithWhite:0.55 alpha:1.0].CGColor;
        self.artworkView.layer.cornerRadius = 0.0;
        CGFloat y = 16.0 + art + 8.0;
        self.subtitleLabel.frame = CGRectMake(m, y, width - m * 2.0, 16.0);
        return y + 16.0 + 10.0;
    }
    self.titleLabel.hidden = NO;
    self.detailLabel.hidden = NO;
    self.playButton.hidden = NO;
    self.shuffleButton.hidden = NO;
    self.radioButton.hidden = YES;
    self.subtitleLabel.hidden = NO;
    self.subtitleLabel.shadowColor = nil;
    self.subtitleLabel.shadowOffset = CGSizeZero;
    self.subtitleLabel.font = [UIFont systemFontOfSize:14.0];
    self.subtitleLabel.textColor = [UIColor colorWithRed:0.0 green:0.32 blue:0.60 alpha:1.0];
    self.artworkView.layer.borderWidth = 0.0;
    self.backgroundColor = [UIColor whiteColor];
    self.titleLabel.textAlignment = UITextAlignmentLeft;
    self.subtitleLabel.textAlignment = UITextAlignmentLeft;
    self.detailLabel.textAlignment = UITextAlignmentLeft;
    CGFloat art = 118.0;
    if (width > 360.0) art = 140.0;
    self.artworkView.frame = CGRectMake(m, m, art, art);
    CGFloat x = m + art + 10.0;
    CGFloat colW = width - x - m;
    self.titleLabel.frame = CGRectMake(x, m, colW, 44.0);
    self.subtitleLabel.frame = CGRectMake(x, m + 46.0, colW, 20.0);
    self.detailLabel.frame = CGRectMake(x, m + 68.0, colW, 32.0);
    CGFloat y = m + art + 10.0;
    CGFloat buttonW = (width - m * 3.0) / 2.0;
    self.playButton.frame = CGRectMake(m, y, buttonW, 34.0);
    self.shuffleButton.frame = CGRectMake(m * 2.0 + buttonW, y, buttonW, 34.0);
    return y + 34.0 + 10.0;
}

- (void)setArtworkURL:(NSString *)artworkURL {
    _artworkURL = [artworkURL copy];
    self.artworkView.image = nil;
    if (!artworkURL.length) return;
    UIImage *cached = [[waSession shared] cachedArtwork:artworkURL size:CGSizeMake(240.0, 240.0)];
    if (cached) {
        self.artworkView.image = cached;
        return;
    }
    __weak waDetailHeader *weakSelf = self;
    [[waSession shared] loadArtwork:artworkURL size:CGSizeMake(240.0, 240.0) completion:^(UIImage *image) {
        if (weakSelf && [weakSelf.artworkURL isEqualToString:artworkURL]) weakSelf.artworkView.image = image;
    }];
}

@end

@interface waDetailController ()
@property (nonatomic, assign) BOOL downloaded;
@property (nonatomic, assign) waDetailKind kind;
@property (nonatomic, strong) waAlbum *album;
@property (nonatomic, strong) waArtist *artist;
@property (nonatomic, strong) waPlaylist *playlist;
@property (nonatomic, strong) NSMutableArray *tracks;
@property (nonatomic, strong) NSArray *albums;
@property (nonatomic, strong) NSArray *related;
@property (nonatomic, strong) NSArray *playlists;
@property (nonatomic, strong) NSArray *diskTracks;
@property (nonatomic, strong) NSArray *diskNumbers;
@property (nonatomic, strong) waDetailHeader *header;
@end

@implementation waDetailController

- (id)initWithAlbum:(waAlbum *)album {
    return [self initWithAlbum:album downloaded:NO];
}

- (id)initWithAlbum:(waAlbum *)album downloaded:(BOOL)downloaded {
    if ((self = [super initWithGroupedStyle:NO])) {
        _kind = waDetailKindAlbum;
        _album = album;
        _downloaded = downloaded;
        self.title = @"Album";
        _tracks = [NSMutableArray arrayWithArray:album.tracks ?: [NSArray array]];
        self.emptyTitle = @"Album";
        self.emptyMessage = @"No songs.";
    }
    return self;
}

- (id)initWithPlaylist:(waPlaylist *)playlist downloaded:(BOOL)downloaded {
    if ((self = [super initWithGroupedStyle:NO])) {
        _kind = waDetailKindPlaylist;
        _playlist = playlist;
        _downloaded = downloaded;
        self.title = playlist.title.length ? playlist.title : @"Playlist";
        _tracks = [NSMutableArray arrayWithArray:playlist.tracks ?: [NSArray array]];
        if (playlist.owned && !downloaded) self.navigationItem.rightBarButtonItem = self.editButtonItem;
    }
    return self;
}

- (id)initWithArtist:(waArtist *)artist {
    if ((self = [super initWithGroupedStyle:YES])) {
        _kind = waDetailKindArtist;
        _artist = artist;
        self.title = artist.title.length ? artist.title : @"Artist";
        _tracks = [NSMutableArray array];
        _albums = [NSArray array];
        _related = [NSArray array];
        _playlists = [NSArray array];
    }
    return self;
}

- (id)initWithPlaylist:(waPlaylist *)playlist {
    return [self initWithPlaylist:playlist downloaded:NO];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.kind == waDetailKindArtist) {
        self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    } else {
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
        self.tableView.backgroundColor = [UIColor whiteColor];
    }
    self.header = [[waDetailHeader alloc] initWithFrame:CGRectMake(0.0, 0.0, 320.0, 200.0)];
    [self.header.playButton addTarget:self action:@selector(playAll) forControlEvents:UIControlEventTouchUpInside];
    [self.header.shuffleButton addTarget:self action:@selector(shuffleAll) forControlEvents:UIControlEventTouchUpInside];
    [self.header.radioButton addTarget:self action:@selector(playArtistRadio) forControlEvents:UIControlEventTouchUpInside];
    self.header.artistStyle = (self.kind == waDetailKindArtist);
    if (!self.downloaded && (self.kind == waDetailKindAlbum || self.kind == waDetailKindPlaylist)) {
        UIBarButtonItem *download = [[UIBarButtonItem alloc] initWithTitle:@"Download"
                                                                     style:UIBarButtonItemStyleBordered
                                                                    target:self
                                                                    action:@selector(downloadAll)];
        if (self.navigationItem.rightBarButtonItem) {
            self.navigationItem.rightBarButtonItems = [NSArray arrayWithObjects:self.navigationItem.rightBarButtonItem, download, nil];
        } else {
            self.navigationItem.rightBarButtonItem = download;
        }
    }
    self.tableView.tableHeaderView = self.header;
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSIndexPath *path = [self.tableView indexPathForSelectedRow];
    if (path) [self.tableView deselectRowAtIndexPath:path animated:animated];
    [self layoutTableHeader];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration {
    (void)orientation; (void)duration;
    [self layoutTableHeader];
}

- (void)layoutTableHeader {
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w < 1.0) w = CGRectGetWidth(self.view.bounds);
    if (w < 1.0) w = 320.0;
    CGFloat h = [self.header layoutForWidth:w];
    CGRect f = self.header.frame;
    if (fabs(h - CGRectGetHeight(f)) > 1.0 || fabs(w - CGRectGetWidth(f)) > 1.0) {
        self.header.frame = CGRectMake(0.0, 0.0, w, h);
        self.tableView.tableHeaderView = self.header;
    }
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
}

- (BOOL)trackIsLocal:(waTrack *)track {
    if (self.downloaded) return YES;
    return [[waDownloader shared] isDownloadedTrackID:track.identifier];
}

- (void)reload {
    self.tableView.backgroundView = nil;
    if (self.downloaded) {
        if (self.kind == waDetailKindAlbum) {
            [self.tracks setArray:self.album.tracks ?: [NSArray array]];
            [self rebuildDisks];
        } else if (self.kind == waDetailKindPlaylist) {
            [self.tracks setArray:self.playlist.tracks ?: [NSArray array]];
        }
        [self applyHeader];
        [self.tableView reloadData];
        if (!self.tracks.count) [self showEmpty:self.emptyTitle message:@"No downloaded songs."];
        return;
    }
    __weak waDetailController *weakSelf = self;
    if (self.kind == waDetailKindAlbum) {
        [[waSession shared] album:self.album.identifier completion:^(waAlbum *album, NSError *error) {
            waDetailController *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (album) strongSelf.album = album;
            [strongSelf.tracks setArray:strongSelf.album.tracks ? strongSelf.album.tracks : [NSArray array]];
            [strongSelf rebuildDisks];
            [strongSelf applyHeader];
            [strongSelf.tableView reloadData];
            if (error && strongSelf.tracks.count == 0) [strongSelf showError:error retry:@selector(reload)];
        }];
    } else if (self.kind == waDetailKindPlaylist) {
        [[waSession shared] playlist:self.playlist.identifier completion:^(waPlaylist *playlist, NSError *error) {
            waDetailController *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (playlist) strongSelf.playlist = playlist;
            [strongSelf.tracks setArray:strongSelf.playlist.tracks ? strongSelf.playlist.tracks : [NSArray array]];
            [strongSelf applyHeader];
            [strongSelf.tableView reloadData];
            if (error && strongSelf.tracks.count == 0) [strongSelf showError:error retry:@selector(reload)];
        }];
    } else {
        [[waSession shared] artist:self.artist.identifier completion:^(waArtist *artist, NSError *error) {
            waDetailController *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (artist) strongSelf.artist = artist;
            [strongSelf.tracks setArray:strongSelf.artist.topTracks ? strongSelf.artist.topTracks : [NSArray array]];
            strongSelf.albums = strongSelf.artist.albums ? strongSelf.artist.albums : [NSArray array];
            strongSelf.related = strongSelf.artist.related ? strongSelf.artist.related : [NSArray array];
            [strongSelf applyHeader];
            [strongSelf.tableView reloadData];
            [strongSelf.tableView setContentOffset:CGPointZero animated:NO];
            if (error && strongSelf.tracks.count == 0 && strongSelf.albums.count == 0) [strongSelf showError:error retry:@selector(reload)];
            [[waSession shared] artistPlaylists:strongSelf.artist.identifier completion:^(NSArray *playlists, NSError *playlistsError) {
                (void)playlistsError;
                if (playlists.count) {
                    strongSelf.playlists = playlists;
                    [strongSelf.tableView reloadData];
                }
            }];
        }];
    }
}

- (void)applyHeader {
    NSString *title = @"";
    NSString *subtitle = @"";
    NSString *detail = @"";
    NSString *artwork = nil;
    if (self.kind == waDetailKindAlbum) {
        title = self.album.title;
        subtitle = self.album.artistName;
        artwork = [self.album bestArtworkURL];
        NSMutableArray *bits = [NSMutableArray array];
        if (self.tracks.count) [bits addObject:[NSString stringWithFormat:@"%ld songs", (long)self.tracks.count]];
        if (self.diskNumbers.count > 1) [bits addObject:[NSString stringWithFormat:@"%ld discs", (long)self.diskNumbers.count]];
        if (self.album.releaseDate.length) [bits addObject:self.album.releaseDate];
        if (self.album.label.length) [bits addObject:self.album.label];
        detail = [bits componentsJoinedByString:@" · "];
        self.title = self.album.title.length ? self.album.title : @"Album";
    } else if (self.kind == waDetailKindPlaylist) {
        title = self.playlist.title;
        subtitle = self.playlist.creatorName;
        artwork = [self.playlist bestArtworkURL];
        NSInteger count = self.tracks.count ? (NSInteger)self.tracks.count : self.playlist.trackCount;
        detail = count > 0 ? [NSString stringWithFormat:@"%ld songs", (long)count] : @"Playlist";
        self.title = self.playlist.title.length ? self.playlist.title : @"Playlist";
    } else {
        title = self.artist.title;
        if (self.artist.fanCount > 0) {
            NSNumberFormatter *fmt = [[NSNumberFormatter alloc] init];
            fmt.numberStyle = NSNumberFormatterDecimalStyle;
            subtitle = [NSString stringWithFormat:@"%@ fans", [fmt stringFromNumber:@(self.artist.fanCount)]];
        } else {
            subtitle = @"";
        }
        artwork = [self.artist bestArtworkURL];
        detail = @"";
        self.title = self.artist.title.length ? self.artist.title : @"Artist";
    }
    self.header.titleLabel.text = title;
    self.header.subtitleLabel.text = subtitle;
    self.header.detailLabel.text = detail;
    self.header.artworkURL = artwork;
    [self layoutTableHeader];
}

- (BOOL)hasContent {
    if (self.kind == waDetailKindArtist) return self.tracks.count + self.albums.count + self.playlists.count + self.related.count > 0;
    return self.tracks.count > 0;
}

- (void)playAll {
    if (!self.tracks.count) return;
    [[waPlayer shared] playTracks:self.tracks startAt:0 context:self.title];
    [[waRootController shared] showPlayer];
}

- (void)shuffleAll {
    if (!self.tracks.count) return;
    [waPlayer shared].shuffleEnabled = YES;
    NSUInteger start = (NSUInteger)(arc4random() % (uint32_t)self.tracks.count);
    [[waPlayer shared] playTracks:self.tracks startAt:start context:self.title];
    [[waRootController shared] showPlayer];
}

- (void)playArtistRadio {
    if (!self.artist.identifier.length) return;
    __weak waDetailController *weakSelf = self;
    [[waSession shared] artistRadio:self.artist.identifier completion:^(NSArray *tracks, NSError *error) {
        if (error || !tracks.count) {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Radio"
                                                            message:error.localizedDescription.length ? error.localizedDescription : @"No radio for this artist."
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
            return;
        }
        [[waPlayer shared] playTracks:tracks startAt:0 context:weakSelf.artist.title];
        [[waRootController shared] showPlayer];
    }];
}

- (void)downloadAll {
    if (!self.tracks.count) return;
    waQuality quality = [[waSession shared] downloadQuality];
    waDownloadCollection *collection = [[waDownloadCollection alloc] init];
    if (self.kind == waDetailKindAlbum && self.album.identifier.length) {
        collection.kind = @"album";
        collection.identifier = self.album.identifier;
        collection.title = self.album.title;
        collection.artistName = self.album.artistName;
        collection.artworkURL = [self.album bestArtworkURL];
    } else if (self.kind == waDetailKindPlaylist && self.playlist.identifier.length) {
        collection.kind = @"playlist";
        collection.identifier = self.playlist.identifier;
        collection.title = self.playlist.title;
        collection.artistName = self.playlist.creatorName;
        collection.artworkURL = [self.playlist bestArtworkURL];
    } else {
        collection = nil;
    }
    [[waDownloader shared] enqueueTracks:self.tracks quality:quality collection:collection];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Downloads"
                                                    message:[NSString stringWithFormat:@"Queued %ld songs.", (long)self.tracks.count]
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
}

- (void)rebuildDisks {
    self.diskTracks = nil;
    self.diskNumbers = nil;
    if (self.kind != waDetailKindAlbum) return;
    NSArray *sorted = waSortedAlbumTracks(self.tracks);
    [self.tracks setArray:sorted];
    if (!sorted.count) return;
    if (!waAlbumHasMultipleDisks(sorted)) {
        self.diskTracks = [NSArray arrayWithObject:sorted];
        self.diskNumbers = [NSArray arrayWithObject:@(waAlbumDiskNumber([sorted objectAtIndex:0]))];
        return;
    }
    NSMutableArray *sections = [NSMutableArray array];
    NSMutableArray *numbers = [NSMutableArray array];
    NSMutableArray *current = nil;
    NSInteger currentDisk = -1;
    for (waTrack *track in sorted) {
        NSInteger disk = waAlbumDiskNumber(track);
        if (disk != currentDisk) {
            current = [NSMutableArray array];
            [sections addObject:current];
            [numbers addObject:@(disk)];
            currentDisk = disk;
        }
        [current addObject:track];
    }
    self.diskTracks = sections;
    self.diskNumbers = numbers;
}

- (waTrack *)trackAtIndexPath:(NSIndexPath *)indexPath {
    if (self.kind == waDetailKindAlbum && self.diskTracks.count) {
        if (indexPath.section < 0 || indexPath.section >= (NSInteger)self.diskTracks.count) return nil;
        NSArray *list = [self.diskTracks objectAtIndex:(NSUInteger)indexPath.section];
        if (indexPath.row < 0 || indexPath.row >= (NSInteger)list.count) return nil;
        return [list objectAtIndex:(NSUInteger)indexPath.row];
    }
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.tracks.count) return nil;
    return [self.tracks objectAtIndex:(NSUInteger)indexPath.row];
}

- (NSUInteger)flatIndexForIndexPath:(NSIndexPath *)indexPath {
    if (self.kind != waDetailKindAlbum || self.diskTracks.count < 2) return (NSUInteger)indexPath.row;
    NSUInteger index = 0;
    for (NSInteger section = 0; section < indexPath.section; section++) {
        index += [[self.diskTracks objectAtIndex:(NSUInteger)section] count];
    }
    return index + (NSUInteger)indexPath.row;
}

- (NSInteger)previewCount:(NSArray *)items cap:(NSInteger)cap {
    NSInteger n = (NSInteger)items.count;
    return n > cap ? cap : n;
}

- (BOOL)showsSeeAllFor:(NSArray *)items cap:(NSInteger)cap {
    return (NSInteger)items.count > cap;
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    if (self.kind == waDetailKindArtist) return 5;
    if (self.kind == waDetailKindAlbum && self.diskTracks.count) return (NSInteger)self.diskTracks.count;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (self.kind == waDetailKindArtist) {
        if (section == 0) return 3;
        if (section == 1) {
            NSInteger n = [self previewCount:self.tracks cap:5];
            return n;
        }
        if (section == 2) {
            NSInteger n = [self previewCount:self.albums cap:5];
            if ([self showsSeeAllFor:self.albums cap:5]) n += 1;
            return n;
        }
        if (section == 3) return [self previewCount:self.playlists cap:5];
        return [self previewCount:self.related cap:5];
    }
    if (self.kind == waDetailKindAlbum && self.diskTracks.count) {
        if (section < 0 || section >= (NSInteger)self.diskTracks.count) return 0;
        return (NSInteger)[[self.diskTracks objectAtIndex:(NSUInteger)section] count];
    }
    return (NSInteger)self.tracks.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (self.kind == waDetailKindAlbum && self.diskNumbers.count > 1 && section >= 0 && section < (NSInteger)self.diskNumbers.count) {
        return [NSString stringWithFormat:@"Disc %ld", (long)[[self.diskNumbers objectAtIndex:(NSUInteger)section] integerValue]];
    }
    if (self.kind != waDetailKindArtist) return nil;
    if (section == 0) return nil;
    if (section == 1) return self.tracks.count ? @"Top Songs" : nil;
    if (section == 2) return self.albums.count ? @"Albums" : nil;
    if (section == 3) return self.playlists.count ? @"Playlists" : nil;
    return self.related.count ? @"Similar Artists" : nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (self.kind == waDetailKindArtist && indexPath.section >= 2) return 58.0;
    return 44.0;
}

- (UITableViewCell *)actionCell:(UITableView *)tableView title:(NSString *)title {
    static NSString *kAction = @"artist.action";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kAction];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kAction];
        cell.textLabel.textAlignment = UITextAlignmentCenter;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:17.0];
        cell.textLabel.textColor = [UIColor colorWithRed:0.196 green:0.309 blue:0.521 alpha:1.0];
    }
    cell.textLabel.text = title;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (UITableViewCell *)seeAllCell:(UITableView *)tableView {
    static NSString *kSee = @"artist.seeall";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kSee];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kSee];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:17.0];
        cell.textLabel.textColor = [UIColor colorWithRed:0.196 green:0.309 blue:0.521 alpha:1.0];
    }
    cell.textLabel.text = @"See All";
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.kind == waDetailKindArtist) {
        if (indexPath.section == 0) {
            NSArray *titles = [NSArray arrayWithObjects:@"Play Top Songs", @"Shuffle", @"Artist Radio", nil];
            NSString *title = indexPath.row < (NSInteger)titles.count ? [titles objectAtIndex:(NSUInteger)indexPath.row] : @"";
            return [self actionCell:tableView title:title];
        }
        if (indexPath.section == 1) {
            waCell *cell = [waCell cellForTable:tableView subtitle:NO];
            if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.tracks.count) return cell;
            waTrack *track = [self.tracks objectAtIndex:(NSUInteger)indexPath.row];
            [cell setTrack:track showAlbum:NO showsArtwork:NO];
            cell.textLabel.text = track.title.length ? track.title : @"";
            cell.indexText = [NSString stringWithFormat:@"%ld", (long)indexPath.row + 1];
            NSInteger seconds = (NSInteger)(track.duration + 0.5);
            if (seconds > 0) cell.badgeLabel.text = [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
            else cell.badgeLabel.text = nil;
            [cell setDownloaded:[self trackIsLocal:track]];
            cell.accessoryType = UITableViewCellAccessoryNone;
            [cell setNeedsLayout];
            return cell;
        }
        if (indexPath.section == 2) {
            NSInteger preview = [self previewCount:self.albums cap:5];
            if (indexPath.row >= preview) return [self seeAllCell:tableView];
            waAlbum *album = [self.albums objectAtIndex:(NSUInteger)indexPath.row];
            waCell *cell = [waCell cellForTable:tableView subtitle:YES];
            [cell setItem:album];
            NSMutableArray *bits = [NSMutableArray array];
            if (album.releaseDate.length >= 4) [bits addObject:[album.releaseDate substringToIndex:4]];
            if (album.version.length) [bits addObject:album.version];
            if (bits.count) cell.detailTextLabel.text = [bits componentsJoinedByString:@" · "];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            [cell setNeedsLayout];
            return cell;
        }
        if (indexPath.section == 3) {
            waPlaylist *playlist = [self.playlists objectAtIndex:(NSUInteger)indexPath.row];
            waCell *cell = [waCell cellForTable:tableView subtitle:YES];
            [cell setItem:playlist];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            [cell setNeedsLayout];
            return cell;
        }
        waArtist *related = [self.related objectAtIndex:(NSUInteger)indexPath.row];
        waCell *cell = [waCell cellForTable:tableView subtitle:YES];
        [cell setItem:related];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        [cell setNeedsLayout];
        return cell;
    }
    waCell *cell = [waCell cellForTable:tableView subtitle:NO];
    waTrack *track = [self trackAtIndexPath:indexPath];
    if (!track) return cell;
    [cell setTrack:track showAlbum:NO showsArtwork:NO];
    cell.textLabel.text = track.title.length ? track.title : @"";
    NSInteger number = track.trackPosition > 0 ? track.trackPosition : (indexPath.row + 1);
    cell.indexText = [NSString stringWithFormat:@"%ld", (long)number];
    NSInteger seconds = (NSInteger)(track.duration + 0.5);
    if (seconds > 0) cell.badgeLabel.text = [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
    else cell.badgeLabel.text = nil;
    [cell setDownloaded:[self trackIsLocal:track]];
    cell.accessoryType = UITableViewCellAccessoryNone;
    [cell setNeedsLayout];
    return cell;
}

- (void)openDiscography {
    if (!self.artist.identifier.length) return;
    [self.navigationController pushViewController:[[waDiscographyController alloc] initWithArtist:self.artist] animated:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.kind == waDetailKindArtist) {
        if (indexPath.section == 0) {
            if (indexPath.row == 0) [self playAll];
            else if (indexPath.row == 1) [self shuffleAll];
            else [self playArtistRadio];
            return;
        }
        if (indexPath.section == 1) {
            if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.tracks.count) return;
            [[waPlayer shared] playTracks:self.tracks startAt:(NSUInteger)indexPath.row context:self.title];
            [[waRootController shared] showPlayer];
            return;
        }
        if (indexPath.section == 2) {
            if (indexPath.row >= [self previewCount:self.albums cap:5]) {
                [self openDiscography];
                return;
            }
            waAlbum *album = [self.albums objectAtIndex:(NSUInteger)indexPath.row];
            [self.navigationController pushViewController:[[waDetailController alloc] initWithAlbum:album] animated:YES];
            return;
        }
        if (indexPath.section == 3) {
            waPlaylist *playlist = [self.playlists objectAtIndex:(NSUInteger)indexPath.row];
            [self.navigationController pushViewController:[[waDetailController alloc] initWithPlaylist:playlist] animated:YES];
            return;
        }
        waArtist *related = [self.related objectAtIndex:(NSUInteger)indexPath.row];
        [self.navigationController pushViewController:[[waDetailController alloc] initWithArtist:related] animated:YES];
        return;
    }
    if (!self.tracks.count) return;
    waTrack *track = [self trackAtIndexPath:indexPath];
    if (!track) return;
    NSUInteger start = [self flatIndexForIndexPath:indexPath];
    if (start >= self.tracks.count) start = 0;
    [[waPlayer shared] playTracks:self.tracks startAt:start context:self.title];
    [[waRootController shared] showPlayer];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.downloaded) return NO;
    if (self.kind != waDetailKindPlaylist || !self.playlist.owned) return NO;
    if (indexPath.section != 0) return NO;
    return tableView.editing;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (self.kind != waDetailKindPlaylist) return;
    waTrack *track = [self.tracks objectAtIndex:(NSUInteger)indexPath.row];
    __weak waDetailController *weakSelf = self;
    [[waSession shared] removeTrack:track fromPlaylist:self.playlist completion:^(BOOL ok, NSError *error) {
        waDetailController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!ok) {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Playlist"
                                                            message:error.localizedDescription.length ? error.localizedDescription : @"Could not remove the song."
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
            return;
        }
        [strongSelf.tracks removeObjectAtIndex:(NSUInteger)indexPath.row];
        [strongSelf.tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
        [strongSelf applyHeader];
    }];
}

@end
