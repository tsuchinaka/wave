#import "waSearchController.h"
#import "waSession.h"
#import "waPlayer.h"
#import "waRootController.h"
#import "waDetailController.h"
#import "../Skin/waCell.h"
#import "../Skin/waCarouselView.h"
#import "../Skin/waTileView.h"

static NSString * const waRecentSearchesKey = @"waRecentSearches";

@interface waSearchController () <UISearchBarDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray *recents;
@property (nonatomic, copy) NSString *activeQuery;
@property (nonatomic, strong) NSArray *tracks;
@property (nonatomic, strong) NSArray *albums;
@property (nonatomic, strong) NSArray *artists;
@property (nonatomic, strong) NSArray *playlists;
@end

@implementation waSearchController

- (id)init {
    return [self initWithGroupedStyle:YES];
}

- (id)initWithGroupedStyle:(BOOL)grouped {
    (void)grouped;
    if ((self = [super initWithGroupedStyle:YES])) {
        self.title = @"Search";
        _recents = [NSArray array];
        _tracks = [NSArray array];
        _albums = [NSArray array];
        _artists = [NSArray array];
        _playlists = [NSArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.delegate = self;
    self.searchBar.barStyle = UIBarStyleDefault;
    self.searchBar.placeholder = @"Search";
    self.searchBar.showsCancelButton = YES;
    [self.searchBar sizeToFit];
    self.tableView.tableHeaderView = self.searchBar;
    [self loadRecents];
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    CGFloat w = CGRectGetWidth(self.tableView.bounds);
    if (w < 1.0) w = 320.0;
    self.searchBar.frame = CGRectMake(0.0, 0.0, w, 44.0);
    self.tableView.tableHeaderView = self.searchBar;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)loadRecents {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:waRecentSearchesKey];
    NSMutableArray *clean = [NSMutableArray array];
    for (id obj in saved) if ([obj isKindOfClass:[NSString class]]) [clean addObject:obj];
    self.recents = clean;
}

- (void)rememberQuery:(NSString *)query {
    if (!query.length) return;
    NSMutableArray *all = [NSMutableArray arrayWithArray:self.recents];
    [all removeObject:query];
    [all insertObject:query atIndex:0];
    while (all.count > 10) [all removeLastObject];
    self.recents = all;
    [[NSUserDefaults standardUserDefaults] setObject:all forKey:waRecentSearchesKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar; (void)searchText;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runSearch) object:nil];
    [self performSelector:@selector(runSearch) withObject:nil afterDelay:0.4];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self rememberQuery:searchBar.text];
    [self loadRecents];
    [self runSearch];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    self.activeQuery = nil;
    self.tracks = [NSArray array];
    self.albums = [NSArray array];
    self.artists = [NSArray array];
    self.playlists = [NSArray array];
    [self.tableView reloadData];
}

- (void)runSearch {
    NSString *query = [self.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.activeQuery = query;
    if (!query.length) {
        self.tracks = [NSArray array];
        self.albums = [NSArray array];
        self.artists = [NSArray array];
        self.playlists = [NSArray array];
        [self.tableView reloadData];
        return;
    }
    [self setLoading:YES];
    __weak waSearchController *weakSelf = self;
    [[waSession shared] searchAll:query completion:^(NSArray *tracks, NSArray *albums, NSArray *artists, NSArray *playlists, NSError *error) {
        waSearchController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setLoading:NO];
        if (error) {
            [strongSelf showError:error retry:@selector(runSearch)];
            return;
        }
        strongSelf.tracks = tracks ? tracks : [NSArray array];
        strongSelf.albums = albums ? albums : [NSArray array];
        strongSelf.artists = artists ? artists : [NSArray array];
        strongSelf.playlists = playlists ? playlists : [NSArray array];
        strongSelf.tableView.backgroundView = nil;
        [strongSelf.tableView reloadData];
    }];
}

#pragma mark - table

- (BOOL)showingRecents {
    return self.activeQuery.length == 0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    if ([self showingRecents]) return 1;
    return 4;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if ([self showingRecents]) return self.recents.count ? @"Recents" : nil;
    if (section == 0) return self.tracks.count ? @"Songs" : nil;
    if (section == 1) return self.albums.count ? @"Albums" : nil;
    if (section == 2) return self.artists.count ? @"Artists" : nil;
    return self.playlists.count ? @"Playlists" : nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if ([self showingRecents]) return (NSInteger)self.recents.count;
    if (section == 0) return (NSInteger)self.tracks.count;
    if (section == 1) return self.albums.count ? 1 : 0;
    if (section == 2) return self.artists.count ? 1 : 0;
    return self.playlists.count ? 1 : 0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if ([self showingRecents] || indexPath.section == 0) return 44.0;
    return [waCarouselView heightForArtworkSide:80.0 paged:NO showsHeader:NO] + 8.0;
}

- (UITableViewCell *)carouselCell:(UITableView *)tableView tag:(NSInteger)tag items:(NSArray *)items action:(SEL)action {
    NSString *ident = [NSString stringWithFormat:@"search.car.%ld", (long)tag];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ident];
    waCarouselView *carousel = nil;
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ident];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.clipsToBounds = YES;
        cell.contentView.clipsToBounds = YES;
        carousel = [[waCarouselView alloc] initWithFrame:CGRectZero title:@""];
        carousel.tag = tag;
        carousel.backgroundColor = [UIColor clearColor];
        carousel.clipsToBounds = YES;
        carousel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cell.contentView addSubview:carousel];
    } else {
        carousel = (waCarouselView *)[cell.contentView viewWithTag:tag];
    }
    cell.clipsToBounds = YES;
    cell.contentView.clipsToBounds = YES;
    carousel.frame = cell.contentView.bounds;
    [carousel setItems:items artworkSide:80.0 target:self action:action seeAllTarget:nil seeAllAction:NULL];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if ([self showingRecents] || indexPath.section == 0) return;
    cell.clipsToBounds = YES;
    cell.contentView.clipsToBounds = YES;
    waCarouselView *carousel = nil;
    for (UIView *view in cell.contentView.subviews) {
        if ([view isKindOfClass:[waCarouselView class]]) { carousel = (waCarouselView *)view; break; }
    }
    if (!carousel) return;
    carousel.clipsToBounds = YES;
    carousel.frame = cell.contentView.bounds;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self showingRecents]) {
        static NSString *kRecent = @"search.recent";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kRecent];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kRecent];
            cell.textLabel.font = [UIFont systemFontOfSize:15.0];
            cell.textLabel.lineBreakMode = UILineBreakModeTailTruncation;
            cell.textLabel.numberOfLines = 1;
        }
        cell.textLabel.text = [self.recents objectAtIndex:(NSUInteger)indexPath.row];
        return cell;
    }
    if (indexPath.section == 1) return [self carouselCell:tableView tag:801 items:self.albums action:@selector(carouselTapped:)];
    if (indexPath.section == 2) return [self carouselCell:tableView tag:802 items:self.artists action:@selector(carouselTapped:)];
    if (indexPath.section == 3) return [self carouselCell:tableView tag:803 items:self.playlists action:@selector(carouselTapped:)];

    waTrack *track = [self.tracks objectAtIndex:(NSUInteger)indexPath.row];
    waCell *cell = [waCell cellForTable:tableView subtitle:YES];
    if ([track isKindOfClass:[waTrack class]]) [cell setTrack:track showAlbum:YES];
    else if ([track isKindOfClass:[waItem class]]) [cell setItem:(waItem *)track];
    cell.indexText = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (void)carouselTapped:(waTileView *)tile {
    if (tile.item) [self openItem:tile.item];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self showingRecents]) {
        self.searchBar.text = [self.recents objectAtIndex:(NSUInteger)indexPath.row];
        [self runSearch];
        return;
    }
    if (indexPath.section != 0) return;
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)self.tracks.count) return;
    [self openItem:[self.tracks objectAtIndex:(NSUInteger)indexPath.row]];
}

- (void)openItem:(waItem *)item {
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
