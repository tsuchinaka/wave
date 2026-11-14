#import "waHomeController.h"
#import "waSession.h"
#import "waPlayer.h"
#import "waRootController.h"
#import "waDetailController.h"
#import "waChartsController.h"
#import "waRadioController.h"
#import "waGenresController.h"
#import "../Skin/waCell.h"
#import "../Skin/waCoverView.h"

@interface waBrowseListController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *listTitle;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) waCoverGrid *grid;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, assign) BOOL usesCovers;
@property (nonatomic, assign) CGFloat laidOutWidth;
- (id)initWithTitle:(NSString *)title items:(NSArray *)items;
@end

@implementation waBrowseListController

- (id)initWithTitle:(NSString *)title items:(NSArray *)items {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        self.listTitle = title;
        self.title = title;
        self.items = items;
        id first = items.count ? [items objectAtIndex:0] : nil;
        self.usesCovers = [first isKindOfClass:[waItem class]] && ![first isKindOfClass:[waTrack class]];
    }
    return self;
}

- (void)loadView {
    CGRect frame = [[UIScreen mainScreen] bounds];
    UIView *root = [[UIView alloc] initWithFrame:frame];
    root.backgroundColor = [UIColor groupTableViewBackgroundColor];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = root;
    if (self.usesCovers) {
        // A single grouped cell taller than the screen is clipped to nothing on iOS 5.
        UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:frame];
        scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        scroll.backgroundColor = [UIColor clearColor];
        scroll.alwaysBounceVertical = YES;
        self.scrollView = scroll;
        [root addSubview:scroll];
        self.grid = [[waCoverGrid alloc] initWithFrame:CGRectZero];
        [scroll addSubview:self.grid];
        self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.emptyLabel.backgroundColor = [UIColor clearColor];
        self.emptyLabel.font = [UIFont boldSystemFontOfSize:17.0];
        self.emptyLabel.textColor = [waChrome headerInk];
        self.emptyLabel.shadowColor = [UIColor whiteColor];
        self.emptyLabel.shadowOffset = CGSizeMake(0.0, 1.0);
        self.emptyLabel.textAlignment = UITextAlignmentCenter;
        self.emptyLabel.text = @"No releases.";
        self.emptyLabel.hidden = self.items.count > 0;
        [root addSubview:self.emptyLabel];
        return;
    }
    UITableView *table = [[UITableView alloc] initWithFrame:frame style:UITableViewStyleGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.backgroundColor = [UIColor groupTableViewBackgroundColor];
    table.separatorColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    table.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    table.dataSource = self;
    table.delegate = self;
    self.tableView = table;
    [root addSubview:table];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.barStyle = UIBarStyleDefault;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyMiniInset) name:waMiniPlayerLayoutDidChangeNotification object:nil];
    [self applyMiniInset];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applyMiniInset {
    CGFloat pad = [waRootController miniPlayerCoverHeight];
    UIEdgeInsets inset = UIEdgeInsetsMake(0.0, 0.0, pad, 0.0);
    if (self.scrollView) {
        self.scrollView.contentInset = inset;
        self.scrollView.scrollIndicatorInsets = inset;
    }
    if (self.tableView) {
        self.tableView.contentInset = inset;
        self.tableView.scrollIndicatorInsets = inset;
    }
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.usesCovers) return;
    CGFloat w = CGRectGetWidth(self.view.bounds);
    CGFloat h = CGRectGetHeight(self.view.bounds);
    if (w < 1.0) return;
    self.scrollView.frame = self.view.bounds;
    self.emptyLabel.frame = CGRectMake(20.0, 80.0, w - 40.0, 24.0);
    CGFloat gridH = [waCoverGrid heightForCount:self.items.count width:w];
    self.grid.frame = CGRectMake(0.0, 8.0, w, gridH);
    if (fabs(w - self.laidOutWidth) > 0.5) {
        [self.grid setItems:self.items target:self action:@selector(coverTapped:)];
    }
    self.scrollView.contentSize = CGSizeMake(w, MAX(gridH + 16.0, h + 1.0));
    self.laidOutWidth = w;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    if (self.usesCovers) return self.items.count ? 1 : 0;
    return (NSInteger)self.items.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)indexPath;
    if (!self.usesCovers) return 58.0;
    CGFloat w = CGRectGetWidth(tableView.bounds);
    if (w < 1.0) w = 320.0;
    return [waCoverGrid heightForCount:self.items.count width:w - 20.0];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.usesCovers) {
        static NSString *kGrid = @"browse.grid";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kGrid];
        waCoverGrid *grid = nil;
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kGrid];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.clipsToBounds = YES;
            grid = [[waCoverGrid alloc] initWithFrame:CGRectZero];
            grid.tag = 610;
            [cell.contentView addSubview:grid];
        } else {
            grid = (waCoverGrid *)[cell.contentView viewWithTag:610];
        }
        CGFloat w = CGRectGetWidth(tableView.bounds) - 20.0;
        CGFloat h = [waCoverGrid heightForCount:self.items.count width:w];
        grid.frame = CGRectMake(0.0, 0.0, w, h);
        grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [grid setItems:self.items target:self action:@selector(coverTapped:)];
        return cell;
    }
    waCell *cell = [waCell cellForTable:tableView subtitle:YES];
    waItem *item = [self.items objectAtIndex:(NSUInteger)indexPath.row];
    if ([item isKindOfClass:[waItem class]]) {
        [cell setItem:item];
        BOOL isTrack = [item isKindOfClass:[waTrack class]];
        cell.accessoryType = isTrack ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
        if (isTrack) cell.indexText = [NSString stringWithFormat:@"%ld", (long)indexPath.row + 1];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    waCoverGrid *grid = (waCoverGrid *)[cell.contentView viewWithTag:610];
    if (grid) grid.frame = cell.contentView.bounds;
}

- (void)coverTapped:(waCoverView *)cover {
    [self openItem:cover.item];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.usesCovers) return;
    waItem *item = [self.items objectAtIndex:(NSUInteger)indexPath.row];
    [self openItem:item];
}

- (void)openItem:(waItem *)item {
    if (![item isKindOfClass:[waItem class]]) return;
    if ([item isKindOfClass:[waTrack class]]) {
        [[waSession shared] playTrack:(waTrack *)item];
        [[waRootController shared] showPlayer];
    } else if ([item isKindOfClass:[waAlbum class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithAlbum:(waAlbum *)item] animated:YES];
    } else if ([item isKindOfClass:[waArtist class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithArtist:(waArtist *)item] animated:YES];
    } else if ([item isKindOfClass:[waPlaylist class]]) {
        [self.navigationController pushViewController:[[waDetailController alloc] initWithPlaylist:(waPlaylist *)item] animated:YES];
    }
}

@end

@interface waHomeController ()
@property (nonatomic, strong) NSArray *sections;
@property (nonatomic, strong) waChromeBar *shortcutBar;
@end

@implementation waHomeController

- (id)init {
    return [self initWithGroupedStyle:YES];
}

- (id)initWithGroupedStyle:(BOOL)grouped {
    if ((self = [super initWithGroupedStyle:YES])) {
        self.title = @"Home";
        self.emptyTitle = @"Home";
        self.emptyMessage = @"No music.";
        _sections = [NSArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView.separatorColor = [UIColor colorWithWhite:0.78 alpha:1.0];
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                             target:self
                                                                             action:@selector(reload)];
    self.navigationItem.rightBarButtonItem = refresh;
    [self buildShortcutBar];
    [self reload];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSIndexPath *path = [self.tableView indexPathForSelectedRow];
    if (path) [self.tableView deselectRowAtIndexPath:path animated:animated];
}

- (void)buildShortcutBar {
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w < 1.0) w = 320.0;
    waChromeBar *bar = [[waChromeBar alloc] initWithFrame:CGRectMake(0.0, 0.0, w, 46.0)];
    self.shortcutBar = bar;

    NSArray *names = [NSArray arrayWithObjects:@"Flow", @"Charts", @"New", @"Radio", @"Genre", nil];
    NSMutableArray *buttons = [NSMutableArray arrayWithCapacity:names.count];
    for (NSUInteger i = 0; i < names.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        [waChrome styleButton:button title:[names objectAtIndex:i]];
        button.tag = (NSInteger)i;
        [button addTarget:self action:@selector(shortcutTapped:) forControlEvents:UIControlEventTouchUpInside];
        [bar addSubview:button];
        [buttons addObject:button];
    }
    bar.buttons = buttons;
    self.tableView.tableHeaderView = bar;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w < 1.0) return;
    UIView *header = self.tableView.tableHeaderView;
    if (header && fabs(CGRectGetWidth(header.frame) - w) > 0.5) {
        CGRect frame = header.frame;
        frame.size.width = w;
        header.frame = frame;
        self.tableView.tableHeaderView = header;
    }
}

- (CGFloat)artworkSide {
    return 100.0;
}

- (void)reload {
    self.tableView.backgroundView = nil;
    [self setLoading:YES];
    __weak waHomeController *weakSelf = self;
    [[waSession shared] homeWithCompletion:^(NSArray *sections, NSError *error) {
        waHomeController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setLoading:NO];
        if (error) {
            [strongSelf showError:error retry:@selector(reload)];
            return;
        }
        NSMutableArray *clean = [NSMutableArray array];
        for (id obj in sections) if ([obj isKindOfClass:[waSection class]]) [clean addObject:obj];
        strongSelf.sections = clean;
        strongSelf.state = waPageStateLoaded;
        [strongSelf.tableView reloadData];
    }];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section < 0 || section >= (NSInteger)self.sections.count) return 0;
    waSection *sec = [self.sections objectAtIndex:(NSUInteger)section];
    return sec.showsMore ? 2 : 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return 34.0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) return nil;
    waSection *sec = [self.sections objectAtIndex:(NSUInteger)section];
    CGFloat width = CGRectGetWidth(tableView.bounds);
    return [waChrome embossedHeaderWithTitle:sec.title width:width];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.row == 1) return 44.0;
    return [waCoverStrip heightForSide:[self artworkSide]];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    waSection *sec = [self.sections objectAtIndex:(NSUInteger)indexPath.section];
    if (indexPath.row == 1) {
        static NSString *kMore = @"home.seeall";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kMore];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kMore];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:17.0];
            cell.textLabel.highlightedTextColor = [UIColor whiteColor];
        }
        cell.textLabel.text = @"See All";
        cell.textLabel.textColor = [waChrome linkBlue];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }
    static NSString *kStrip = @"home.strip";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kStrip];
    waCoverStrip *strip = nil;
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kStrip];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.clipsToBounds = YES;
        strip = [[waCoverStrip alloc] initWithFrame:CGRectZero];
        strip.tag = 600;
        [cell.contentView addSubview:strip];
    } else {
        strip = (waCoverStrip *)[cell.contentView viewWithTag:600];
    }
    CGFloat h = [waCoverStrip heightForSide:[self artworkSide]];
    CGFloat w = CGRectGetWidth(cell.contentView.bounds);
    if (w < 1.0) w = CGRectGetWidth(tableView.bounds) - 20.0;
    strip.frame = CGRectMake(0.0, 0.0, w, h);
    strip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [strip setItems:sec.items side:[self artworkSide] target:self action:@selector(coverTapped:)];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.row == 1) {
        cell.textLabel.textColor = [waChrome linkBlue];
        return;
    }
    waCoverStrip *strip = (waCoverStrip *)[cell.contentView viewWithTag:600];
    if (strip) strip.frame = cell.contentView.bounds;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row != 1) return;
    if (indexPath.section < 0 || indexPath.section >= (NSInteger)self.sections.count) return;
    waSection *sec = [self.sections objectAtIndex:(NSUInteger)indexPath.section];
    waBrowseListController *list = [[waBrowseListController alloc] initWithTitle:sec.title items:sec.items];
    [self.navigationController pushViewController:list animated:YES];
}

- (void)coverTapped:(waCoverView *)cover {
    if (cover.item) [self openItem:cover.item];
}

- (void)shortcutTapped:(id)sender {
    NSInteger tag = [sender tag];
    if (tag == 0) {
        [self setLoading:YES];
        __weak waHomeController *weakSelf = self;
        [[waSession shared] playFlowWithCompletion:^(NSError *error) {
            [weakSelf setLoading:NO];
            if (error) {
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Flow"
                                                                message:error.localizedDescription
                                                               delegate:nil
                                                      cancelButtonTitle:@"OK"
                                                      otherButtonTitles:nil];
                [alert show];
                return;
            }
            [[waRootController shared] showPlayer];
        }];
    } else if (tag == 1) {
        [self.navigationController pushViewController:[[waChartsController alloc] init] animated:YES];
    } else if (tag == 2) {
        for (waSection *sec in self.sections) {
            if (![sec isKindOfClass:[waSection class]]) continue;
            if (([sec.identifier isEqualToString:@"editorial"] || [sec.title isEqualToString:@"New Releases"]) && sec.items.count) {
                waBrowseListController *list = [[waBrowseListController alloc] initWithTitle:@"New Releases" items:sec.items];
                [self.navigationController pushViewController:list animated:YES];
                return;
            }
        }
        [self setLoading:YES];
        __weak waHomeController *weakSelf = self;
        [[waSession shared] editorialWithCompletion:^(NSArray *albums, NSError *error) {
            waHomeController *strongSelf = weakSelf;
            [strongSelf setLoading:NO];
            if (error || !albums.count) {
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"New Releases"
                                                                message:error.localizedDescription ?: @"No releases."
                                                               delegate:nil
                                                      cancelButtonTitle:@"OK"
                                                      otherButtonTitles:nil];
                [alert show];
                return;
            }
            waBrowseListController *list = [[waBrowseListController alloc] initWithTitle:@"New Releases" items:albums];
            [strongSelf.navigationController pushViewController:list animated:YES];
        }];
    } else if (tag == 3) {
        [self.navigationController pushViewController:[[waRadioController alloc] init] animated:YES];
    } else {
        [self.navigationController pushViewController:[[waGenresController alloc] init] animated:YES];
    }
}

- (void)openItem:(waItem *)item {
    if ([item isKindOfClass:[waTrack class]]) {
        [[waSession shared] playTrack:(waTrack *)item];
        [[waRootController shared] showPlayer];
        return;
    }
    if ([item.kind isEqualToString:waTrackType] && item.identifier.length) {
        [[waSession shared] track:item.identifier completion:^(waTrack *track, NSError *error) {
            if (track) {
                [[waSession shared] playTrack:track];
                [[waRootController shared] showPlayer];
            } else {
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Track"
                                                                message:error.localizedDescription
                                                               delegate:nil
                                                      cancelButtonTitle:@"OK"
                                                      otherButtonTitles:nil];
                [alert show];
            }
        }];
        return;
    }
    if ([item isKindOfClass:[waAlbum class]] || [item.kind isEqualToString:waAlbumType]) {
        waAlbum *album = [item isKindOfClass:[waAlbum class]] ? (waAlbum *)item : nil;
        if (!album) {
            album = [[waAlbum alloc] init];
            album.identifier = item.identifier;
            album.title = item.title;
            album.artworkURL = item.artworkURL;
        }
        [self.navigationController pushViewController:[[waDetailController alloc] initWithAlbum:album] animated:YES];
    } else if ([item isKindOfClass:[waArtist class]] || [item.kind isEqualToString:waArtistType]) {
        waArtist *artist = [item isKindOfClass:[waArtist class]] ? (waArtist *)item : nil;
        if (!artist) {
            artist = [[waArtist alloc] init];
            artist.identifier = item.identifier;
            artist.title = item.title;
            artist.artworkURL = item.artworkURL;
        }
        [self.navigationController pushViewController:[[waDetailController alloc] initWithArtist:artist] animated:YES];
    } else if ([item isKindOfClass:[waPlaylist class]] || [item.kind isEqualToString:waPlaylistType]) {
        waPlaylist *playlist = [item isKindOfClass:[waPlaylist class]] ? (waPlaylist *)item : nil;
        if (!playlist) {
            playlist = [[waPlaylist alloc] init];
            playlist.identifier = item.identifier;
            playlist.title = item.title;
            playlist.artworkURL = item.artworkURL;
        }
        [self.navigationController pushViewController:[[waDetailController alloc] initWithPlaylist:playlist] animated:YES];
    } else if ([item isKindOfClass:[waRadio class]] || [item.kind isEqualToString:waRadioType]) {
        waRadio *radio = [[waRadio alloc] init];
        radio.identifier = item.identifier;
        radio.title = item.title;
        [[waSession shared] playRadio:radio completion:^(NSError *error) {
            if (error) {
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Radio"
                                                                message:error.localizedDescription
                                                               delegate:nil
                                                      cancelButtonTitle:@"OK"
                                                      otherButtonTitles:nil];
                [alert show];
            } else {
                [[waRootController shared] showPlayer];
            }
        }];
    }
}

@end
