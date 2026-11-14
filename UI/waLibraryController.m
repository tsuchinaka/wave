#import "waLibraryController.h"
#import "waSession.h"
#import "waPlayer.h"
#import "waRootController.h"
#import "waDetailController.h"
#import "waDownloadsController.h"
#import "waDownloader.h"
#import "../Skin/waCell.h"

enum {
    waLibrarySegmentSongs = 0,
    waLibrarySegmentAlbums,
    waLibrarySegmentArtists,
    waLibrarySegmentPlaylists
};

enum {
    waAlertCreatePlaylist = 1
};

@interface waLibraryController () <UIAlertViewDelegate>
@property (nonatomic, strong) UISegmentedControl *kindControl;
@property (nonatomic, strong) UIView *headerWrap;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, strong) NSArray *minePlaylists;
@property (nonatomic, strong) NSArray *deezerPlaylists;
@end

@implementation waLibraryController

- (id)init {
    return [self initWithGroupedStyle:YES];
}

- (id)initWithGroupedStyle:(BOOL)grouped {
    if ((self = [super initWithGroupedStyle:grouped])) {
        self.title = @"Library";
        self.emptyTitle = @"Library";
        self.emptyMessage = @"No music.";
        _items = [NSArray array];
        _minePlaylists = [NSArray array];
        _deezerPlaylists = [NSArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    [self buildHeader];
    [self syncBarItems];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloaderChanged:) name:waDownloaderDidChangeNotification object:nil];
    [self reload];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self layoutHeader];
    NSIndexPath *path = [self.tableView indexPathForSelectedRow];
    if (path) [self.tableView deselectRowAtIndexPath:path animated:animated];
    [self reload];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration {
    (void)orientation; (void)duration;
    [self layoutHeader];
}

- (NSInteger)currentSegment {
    return self.kindControl ? self.kindControl.selectedSegmentIndex : waLibrarySegmentSongs;
}

- (void)buildHeader {
    self.headerWrap = [[UIView alloc] initWithFrame:CGRectZero];
    self.headerWrap.backgroundColor = [UIColor clearColor];
    NSArray *titles = [NSArray arrayWithObjects:@"Songs", @"Albums", @"Artists", @"Playlists", nil];
    self.kindControl = [[UISegmentedControl alloc] initWithItems:titles];
    self.kindControl.segmentedControlStyle = UISegmentedControlStyleBar;
    self.kindControl.selectedSegmentIndex = waLibrarySegmentSongs;
    self.kindControl.tintColor = nil;
    [self.kindControl addTarget:self action:@selector(kindChanged:) forControlEvents:UIControlEventValueChanged];
    [self.headerWrap addSubview:self.kindControl];
    [self layoutHeader];
}

- (void)layoutHeader {
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w < 1.0) w = CGRectGetWidth(self.view.bounds);
    if (w < 1.0) w = 320.0;
    self.kindControl.frame = CGRectMake(10.0, 10.0, w - 20.0, 30.0);
    self.headerWrap.frame = CGRectMake(0.0, 0.0, w, 50.0);
    self.tableView.tableHeaderView = self.headerWrap;
}

- (void)kindChanged:(UISegmentedControl *)control {
    (void)control;
    if (self.editing) [self setEditing:NO animated:YES];
    [self syncBarItems];
    [self reload];
}

- (void)syncBarItems {
    if ([self currentSegment] == waLibrarySegmentPlaylists) {
        UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                             target:self
                                                                             action:@selector(createPlaylist)];
        self.navigationItem.rightBarButtonItem = add;
        self.navigationItem.leftBarButtonItem = self.editButtonItem;
    } else {
        self.navigationItem.rightBarButtonItem = nil;
        self.navigationItem.leftBarButtonItem = nil;
    }
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
    [super setEditing:editing animated:animated];
    [self.tableView setEditing:editing animated:animated];
}

- (void)downloaderChanged:(NSNotification *)note {
    if ([[note.userInfo objectForKey:@"progress"] boolValue]) return;
    if (!self.isViewLoaded) return;
    if ([self.tableView numberOfSections] < 1) return;
    [self.tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:[NSIndexPath indexPathForRow:0 inSection:0]]
                          withRowAnimation:UITableViewRowAnimationNone];
}

- (void)reload {
    self.tableView.backgroundView = nil;
    NSInteger segment = [self currentSegment];
    __weak waLibraryController *weakSelf = self;
    void (^done)(NSArray *, NSString *) = ^(NSArray *items, NSString *empty) {
        waLibraryController *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSMutableArray *clean = [NSMutableArray array];
        for (id obj in items) if ([obj isKindOfClass:[waItem class]]) [clean addObject:obj];
        strongSelf.items = clean;
        [strongSelf splitPlaylists];
        strongSelf.emptyMessage = empty;
        strongSelf.state = waPageStateLoaded;
        [strongSelf syncBarItems];
        [strongSelf.tableView reloadData];
    };
    if (segment == waLibrarySegmentSongs) {
        [[waSession shared] lovedTracksWithCompletion:^(NSArray *tracks, NSError *error) {
            (void)error;
            done(tracks, @"No liked songs.");
        }];
    } else if (segment == waLibrarySegmentAlbums) {
        [[waSession shared] lovedAlbumsWithCompletion:^(NSArray *albums, NSError *error) {
            (void)error;
            done(albums, @"No liked albums.");
        }];
    } else if (segment == waLibrarySegmentArtists) {
        [[waSession shared] lovedArtistsWithCompletion:^(NSArray *artists, NSError *error) {
            (void)error;
            done(artists, @"No liked artists.");
        }];
    } else {
        [[waSession shared] userPlaylistsWithCompletion:^(NSArray *playlists, NSError *error) {
            (void)error;
            done(playlists, @"No playlists.");
        }];
    }
}

- (BOOL)showingPlaylists {
    return [self currentSegment] == waLibrarySegmentPlaylists;
}

- (BOOL)playlistIsMine:(waPlaylist *)playlist {
    if (![playlist isKindOfClass:[waPlaylist class]]) return NO;
    if (playlist.owned) return YES;
    NSString *me = [waSession shared].user.identifier;
    return me.length && [playlist.creatorIdentifier isEqualToString:me];
}

- (void)splitPlaylists {
    NSMutableArray *mine = [NSMutableArray array];
    NSMutableArray *deezer = [NSMutableArray array];
    for (id obj in self.items) {
        if (![obj isKindOfClass:[waPlaylist class]]) continue;
        waPlaylist *playlist = (waPlaylist *)obj;
        if ([self playlistIsMine:playlist]) {
            playlist.owned = YES;
            [mine addObject:playlist];
        } else {
            [deezer addObject:playlist];
        }
    }
    self.minePlaylists = mine;
    self.deezerPlaylists = deezer;
}

- (NSArray *)playlistsInSection:(NSInteger)section {
    if (section == 1) return self.minePlaylists;
    return self.deezerPlaylists;
}

- (NSString *)downloadsSubtitle {
    NSUInteger active = [[waDownloader shared] activeCount];
    NSUInteger done = [[waDownloader shared] completedCount];
    if (active && done) return [NSString stringWithFormat:@"%lu downloading · %lu songs", (unsigned long)active, (unsigned long)done];
    if (active) return [NSString stringWithFormat:@"%lu downloading", (unsigned long)active];
    if (done) return [NSString stringWithFormat:@"%lu songs", (unsigned long)done];
    return @"No downloads";
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    if ([self showingPlaylists]) return 3;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 1;
    if ([self showingPlaylists]) {
        NSArray *list = [self playlistsInSection:section];
        return list.count ? (NSInteger)list.count : 1;
    }
    if (self.items.count == 0) return 1;
    return (NSInteger)self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return nil;
    if ([self showingPlaylists]) {
        if (section == 1) return @"My Playlists";
        return @"Deezer";
    }
    switch ([self currentSegment]) {
        case waLibrarySegmentAlbums: return @"Liked Albums";
        case waLibrarySegmentArtists: return @"Liked Artists";
        default: return @"Liked Songs";
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return 44.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        static NSString *kMenu = @"library.downloads";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kMenu];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kMenu];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:17.0];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0];
            cell.detailTextLabel.textColor = [UIColor grayColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.textLabel.text = @"Downloads";
        cell.detailTextLabel.text = [self downloadsSubtitle];
        return cell;
    }

    if ([self showingPlaylists]) {
        NSArray *list = [self playlistsInSection:indexPath.section];
        if (!list.count) {
            static NSString *kEmptyP = @"library.emptyP";
            UITableViewCell *empty = [tableView dequeueReusableCellWithIdentifier:kEmptyP];
            if (!empty) {
                empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kEmptyP];
                empty.textLabel.font = [UIFont systemFontOfSize:14.0];
                empty.textLabel.textColor = [UIColor grayColor];
            }
            empty.textLabel.text = (indexPath.section == 1) ? @"No playlists of yours." : @"No Deezer playlists.";
            empty.selectionStyle = UITableViewCellSelectionStyleNone;
            empty.accessoryType = UITableViewCellAccessoryNone;
            return empty;
        }
        waPlaylist *playlist = [list objectAtIndex:(NSUInteger)indexPath.row];
        waCell *cell = [waCell cellForTable:tableView subtitle:YES];
        [cell setItem:playlist];
        cell.indexText = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (self.items.count == 0) {
        static NSString *kEmpty = @"library.empty";
        UITableViewCell *empty = [tableView dequeueReusableCellWithIdentifier:kEmpty];
        if (!empty) {
            empty = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kEmpty];
            empty.textLabel.font = [UIFont systemFontOfSize:14.0];
            empty.textLabel.textColor = [UIColor grayColor];
        }
        empty.textLabel.text = self.emptyMessage.length ? self.emptyMessage : @"No music.";
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        empty.accessoryType = UITableViewCellAccessoryNone;
        return empty;
    }

    waItem *item = [self.items objectAtIndex:(NSUInteger)indexPath.row];
    waCell *cell = [waCell cellForTable:tableView subtitle:YES];
    if ([item isKindOfClass:[waTrack class]]) [cell setTrack:(waTrack *)item showAlbum:YES];
    else [cell setItem:item];
    cell.indexText = nil;
    cell.accessoryType = ([self currentSegment] == waLibrarySegmentSongs) ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (![self showingPlaylists] || indexPath.section != 1) return NO;
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.minePlaylists.count) return NO;
    waPlaylist *playlist = [self.minePlaylists objectAtIndex:(NSUInteger)indexPath.row];
    return [playlist isKindOfClass:[waPlaylist class]] && playlist.owned;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.minePlaylists.count) return;
    waPlaylist *playlist = [self.minePlaylists objectAtIndex:(NSUInteger)indexPath.row];
    if (![playlist isKindOfClass:[waPlaylist class]]) return;
    __weak waLibraryController *weakSelf = self;
    [[waSession shared] deletePlaylist:playlist completion:^(BOOL ok, NSError *error) {
        (void)error;
        if (ok) [weakSelf reload];
    }];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        [self.navigationController pushViewController:[[waDownloadsController alloc] init] animated:YES];
        return;
    }
    if ([self showingPlaylists]) {
        NSArray *list = [self playlistsInSection:indexPath.section];
        if (indexPath.row < 0 || indexPath.row >= (NSInteger)list.count) return;
        waPlaylist *playlist = [list objectAtIndex:(NSUInteger)indexPath.row];
        if ([playlist isKindOfClass:[waPlaylist class]]) {
            [self.navigationController pushViewController:[[waDetailController alloc] initWithPlaylist:playlist] animated:YES];
        }
        return;
    }
    if (self.items.count == 0) return;
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.items.count) return;
    waItem *item = [self.items objectAtIndex:(NSUInteger)indexPath.row];
    NSInteger segment = [self currentSegment];
    if (segment == waLibrarySegmentSongs) {
        [[waPlayer shared] playTracks:self.items startAt:(NSUInteger)indexPath.row context:@"Liked Songs"];
        [[waRootController shared] showPlayer];
    } else if (segment == waLibrarySegmentAlbums && [item isKindOfClass:[waAlbum class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithAlbum:(waAlbum *)item] animated:YES];
    } else if (segment == waLibrarySegmentArtists && [item isKindOfClass:[waArtist class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithArtist:(waArtist *)item] animated:YES];
    } else if (segment == waLibrarySegmentPlaylists && [item isKindOfClass:[waPlaylist class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithPlaylist:(waPlaylist *)item] animated:YES];
    }
}

- (void)createPlaylist {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"New Playlist"
                                                    message:nil
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Create", nil];
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    alert.tag = waAlertCreatePlaylist;
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == waAlertCreatePlaylist && buttonIndex == 1) {
        NSString *name = [alertView textFieldAtIndex:0].text;
        if (!name.length) return;
        __weak waLibraryController *weakSelf = self;
        [[waSession shared] createPlaylistNamed:name completion:^(waPlaylist *playlist, NSError *error) {
            if (playlist) [weakSelf reload];
            else {
                UIAlertView *err = [[UIAlertView alloc] initWithTitle:@"Playlist"
                                                              message:error.localizedDescription
                                                             delegate:nil
                                                    cancelButtonTitle:@"OK"
                                                    otherButtonTitles:nil];
                [err show];
            }
        }];
    }
}

@end
