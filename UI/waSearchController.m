#import "waSearchController.h"
#import "waSession.h"
#import "waPlayer.h"
#import "waRootController.h"
#import "waDetailController.h"
#import "../Skin/waCell.h"
#import "../Skin/waCarouselView.h"
#import "../Skin/waTileView.h"

static NSString * const waRecentSearchesKey = @"wave.recentSearches";
static NSString * const waRecentSearchesLegacyKey = @"waRecentSearches";

typedef enum {
    waSearchScreenIdle = 0,
    waSearchScreenSuggest,
    waSearchScreenResults
} waSearchScreen;

// The search bar in a navigation titleView paints its own gray gradient over
// the bar. A one-pixel clear image is enough to make it disappear and leave
// only the field.
static UIImage *waClearBarImage(void) {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(1.0, 1.0), NO, 0.0);
        image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return image;
}

static UITextField *waSearchField(UIView *view) {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UITextField class]]) return (UITextField *)sub;
        UITextField *deep = waSearchField(sub);
        if (deep) return deep;
    }
    return nil;
}

static void waHideSearchBackground(UIView *view) {
    for (UIView *sub in view.subviews) {
        NSString *name = NSStringFromClass([sub class]);
        if ([sub isKindOfClass:[UIImageView class]] && [name rangeOfString:@"Background"].location != NSNotFound) {
            sub.hidden = YES;
        }
        waHideSearchBackground(sub);
    }
}

@interface waSearchController () <UISearchBarDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UIView *searchHost;
@property (nonatomic, strong) NSArray *recents;
@property (nonatomic, copy) NSString *activeQuery;
@property (nonatomic, strong) NSArray *tracks;
@property (nonatomic, strong) NSArray *albums;
@property (nonatomic, strong) NSArray *artists;
@property (nonatomic, strong) NSArray *playlists;
@property (nonatomic, strong) NSArray *suggestArtists;
@property (nonatomic, strong) NSArray *suggestTracks;
@property (nonatomic, strong) NSArray *suggestAlbums;
@property (nonatomic, strong) NSArray *suggestPlaylists;
@property (nonatomic, strong) NSArray *groups;
@property (nonatomic, assign) waSearchScreen screen;
@property (nonatomic, assign) NSUInteger suggestGeneration;
@property (nonatomic, assign) NSUInteger searchGeneration;
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
        _suggestArtists = [NSArray array];
        _suggestTracks = [NSArray array];
        _suggestAlbums = [NSArray array];
        _suggestPlaylists = [NSArray array];
        _groups = [NSArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];
    [self installSearchBar];
    [self loadRecents];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(keyboardFrameChanged:) name:UIKeyboardDidChangeFrameNotification object:nil];
    [center addObserver:self selector:@selector(keyboardFrameChanged:) name:UIKeyboardDidHideNotification object:nil];
    [self presentIdle];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self fitSearchBar];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if ([self.searchBar isFirstResponder]) [self.searchBar resignFirstResponder];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self fitSearchBar];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

#pragma mark - search bar

- (void)installSearchBar {
    UIView *host = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 256.0, 44.0)];
    host.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    host.backgroundColor = [UIColor clearColor];

    UISearchBar *bar = [[UISearchBar alloc] initWithFrame:CGRectMake(0.0, 7.0, CGRectGetWidth(host.bounds), 36.0)];
    bar.delegate = self;
    bar.placeholder = @"Search";
    bar.barStyle = UIBarStyleDefault;
    bar.translucent = YES;
    bar.showsCancelButton = NO;
    bar.autocorrectionType = UITextAutocorrectionTypeNo;
    bar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    bar.spellCheckingType = UITextSpellCheckingTypeNo;
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [bar setBackgroundImage:waClearBarImage()];
    waHideSearchBackground(bar);
    UITextField *field = waSearchField(bar);
    if (field) {
        field.returnKeyType = UIReturnKeySearch;
        field.enablesReturnKeyAutomatically = YES;
    }

    [host addSubview:bar];
    self.searchBar = bar;
    self.searchHost = host;
    self.navigationItem.titleView = host;
}

// The bar is the title. Its width comes from what the bar still has free once
// Cancel is up, so the field never slides under the button.
- (void)fitSearchBar {
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (!bar || !self.searchHost) return;
    CGFloat width = CGRectGetWidth(bar.bounds) - 12.0;
    if (self.navigationItem.rightBarButtonItem) width -= 70.0;
    if (self.navigationItem.leftBarButtonItem) width -= 70.0;
    if (width < 140.0) width = 140.0;
    if (fabs(CGRectGetWidth(self.searchHost.frame) - width) < 0.5) return;
    self.searchHost.frame = CGRectMake(0.0, 0.0, width, 44.0);
    self.searchBar.frame = CGRectMake(0.0, 7.0, width, 36.0);
    // Resizing in place keeps the field first responder. Reassigning
    // titleView is what dismisses the keyboard on iOS 5.
    [bar setNeedsLayout];
}

- (void)setCancelVisible:(BOOL)visible {
    if (visible) {
        if (!self.navigationItem.rightBarButtonItem) {
            self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                                    target:self
                                                                                                    action:@selector(cancelSearch)];
        }
    } else if (self.navigationItem.rightBarButtonItem) {
        self.navigationItem.rightBarButtonItem = nil;
    }
    [self fitSearchBar];
}

#pragma mark - recents

- (void)loadRecents {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *saved = [defaults arrayForKey:waRecentSearchesKey];
    if (!saved.count) saved = [defaults arrayForKey:waRecentSearchesLegacyKey];
    NSMutableArray *clean = [NSMutableArray array];
    for (id obj in saved) if ([obj isKindOfClass:[NSString class]] && [obj length]) [clean addObject:obj];
    self.recents = clean;
}

- (void)storeRecents {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:self.recents forKey:waRecentSearchesKey];
    [defaults removeObjectForKey:waRecentSearchesLegacyKey];
    [defaults synchronize];
}

- (void)rememberQuery:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return;
    NSMutableArray *all = [NSMutableArray arrayWithArray:self.recents];
    NSString *existing = nil;
    for (NSString *item in all) {
        if ([item caseInsensitiveCompare:trimmed] == NSOrderedSame) { existing = item; break; }
    }
    if (existing) [all removeObject:existing];
    [all insertObject:trimmed atIndex:0];
    while (all.count > 10) [all removeLastObject];
    self.recents = all;
    [self storeRecents];
}

- (void)removeRecentAtIndex:(NSUInteger)index {
    if (index >= self.recents.count) return;
    NSMutableArray *all = [NSMutableArray arrayWithArray:self.recents];
    [all removeObjectAtIndex:index];
    self.recents = all;
    [self storeRecents];
}

- (NSArray *)matchingRecents {
    NSString *query = [[self typedQuery] lowercaseString];
    if (!query.length) return self.recents;
    NSMutableArray *matched = [NSMutableArray array];
    for (NSString *item in self.recents) {
        if ([item.lowercaseString rangeOfString:query].location != NSNotFound) [matched addObject:item];
    }
    return matched;
}

#pragma mark - keyboard

- (void)keyboardFrameChanged:(NSNotification *)note {
    if (!self.isViewLoaded) return;
    CGRect end = CGRectZero;
    NSValue *value = [note.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey];
    if (value) end = [value CGRectValue];
    if ([[note name] isEqualToString:UIKeyboardDidHideNotification] || CGRectIsEmpty(end)) {
        UIEdgeInsets inset = self.tableView.contentInset;
        inset.bottom = 0.0;
        self.tableView.contentInset = inset;
        self.tableView.scrollIndicatorInsets = inset;
        return;
    }
    CGRect local = [self.tableView.superview convertRect:end fromView:nil];
    CGFloat overlap = CGRectGetMaxY(self.tableView.frame) - CGRectGetMinY(local);
    if (overlap < 0.0) overlap = 0.0;
    UIEdgeInsets inset = self.tableView.contentInset;
    inset.bottom = overlap;
    self.tableView.contentInset = inset;
    self.tableView.scrollIndicatorInsets = inset;
}

#pragma mark - search

- (NSString *)typedQuery {
    return [self.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    (void)searchBar;
    [self setCancelVisible:YES];
    if (self.screen == waSearchScreenIdle && [self typedQuery].length) [self scheduleSuggest];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runSuggest) object:nil];
    if (![self typedQuery].length) {
        self.suggestGeneration++;
        [self presentIdle];
        return;
    }
    self.screen = waSearchScreenSuggest;
    [self scheduleSuggest];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    (void)searchBar;
    [self submitSearch];
}

- (void)cancelSearch {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runSuggest) object:nil];
    self.suggestGeneration++;
    self.searchGeneration++;
    self.searchBar.text = @"";
    [self.searchBar resignFirstResponder];
    [self setCancelVisible:NO];
    [self presentIdle];
}

// Typing rebuilds the layout at once with what is already known, then the
// request fills it in. Waiting for the network with an empty table makes the
// field feel dead on a slow connection.
- (void)scheduleSuggest {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runSuggest) object:nil];
    [self performSelector:@selector(runSuggest) withObject:nil afterDelay:0.28];
    [self rebuildGroups];
    self.tableView.backgroundView = nil;
    [self.tableView reloadData];
}

- (void)runSuggest {
    NSString *query = [self typedQuery];
    if (!query.length) {
        [self presentIdle];
        return;
    }
    NSUInteger generation = ++self.suggestGeneration;
    __weak waSearchController *weakSelf = self;
    [[waSession shared] searchSuggest:query completion:^(NSArray *artists, NSArray *tracks, NSArray *albums, NSArray *playlists, NSError *error) {
        waSearchController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.suggestGeneration) return;
        if (strongSelf.screen != waSearchScreenSuggest) return;
        (void)error;
        strongSelf.suggestArtists = artists ?: [NSArray array];
        strongSelf.suggestTracks = tracks ?: [NSArray array];
        strongSelf.suggestAlbums = albums ?: [NSArray array];
        strongSelf.suggestPlaylists = playlists ?: [NSArray array];
        [strongSelf rebuildGroups];
        strongSelf.tableView.backgroundView = nil;
        [strongSelf.tableView reloadData];
    }];
}

- (void)submitSearch {
    NSString *query = [self typedQuery];
    if (!query.length) return;
    [self.searchBar resignFirstResponder];
    [self setCancelVisible:NO];
    [self rememberQuery:query];
    [self runSearch:query];
}

- (void)runSearch:(NSString *)query {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runSuggest) object:nil];
    self.suggestGeneration++;
    self.activeQuery = query;
    self.screen = waSearchScreenResults;
    // Drop the previous query's rows: if this request fails, the error must be
    // visible instead of hiding behind the old results.
    self.tracks = [NSArray array];
    self.albums = [NSArray array];
    self.artists = [NSArray array];
    self.playlists = [NSArray array];
    [self rebuildGroups];
    self.tableView.backgroundView = nil;
    [self.tableView reloadData];
    [self setLoading:YES];
    NSUInteger generation = ++self.searchGeneration;
    __weak waSearchController *weakSelf = self;
    [[waSession shared] searchAll:query completion:^(NSArray *tracks, NSArray *albums, NSArray *artists, NSArray *playlists, NSError *error) {
        waSearchController *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.searchGeneration) return;
        [strongSelf setLoading:NO];
        if (error) {
            [strongSelf showError:error retry:NULL];
            return;
        }
        strongSelf.tracks = tracks ?: [NSArray array];
        strongSelf.albums = albums ?: [NSArray array];
        strongSelf.artists = artists ?: [NSArray array];
        strongSelf.playlists = playlists ?: [NSArray array];
        [strongSelf presentResults];
    }];
}

// The base class puts Retry in the right bar item, which would land on top of
// Cancel. Here the message lives in the table only.
- (void)showError:(NSError *)error retry:(SEL)retry {
    (void)retry;
    [self setLoading:NO];
    NSString *message = error.localizedDescription.length ? error.localizedDescription : @"Check your connection and try again.";
    [self showEmpty:@"Cannot Search" message:message];
}

#pragma mark - groups

- (void)clearHits {
    self.activeQuery = nil;
    self.tracks = [NSArray array];
    self.albums = [NSArray array];
    self.artists = [NSArray array];
    self.playlists = [NSArray array];
    self.suggestArtists = [NSArray array];
    self.suggestTracks = [NSArray array];
    self.suggestAlbums = [NSArray array];
    self.suggestPlaylists = [NSArray array];
}

- (void)presentIdle {
    self.screen = waSearchScreenIdle;
    [self clearHits];
    [self rebuildGroups];
    if (!self.groups.count) {
        [self showEmpty:@"Search" message:@"Find artists, songs, albums, and playlists."];
        return;
    }
    self.tableView.backgroundView = nil;
    [self.tableView reloadData];
}

- (void)presentResults {
    self.screen = waSearchScreenResults;
    [self rebuildGroups];
    if (!self.groups.count) {
        NSString *query = self.activeQuery.length ? self.activeQuery : @"that";
        [self showEmpty:@"No Results" message:[NSString stringWithFormat:@"Nothing matched \u201c%@\u201d.", query]];
        return;
    }
    self.tableView.backgroundView = nil;
    [self.tableView reloadData];
    [self.tableView setContentOffset:CGPointMake(0.0, -self.tableView.contentInset.top) animated:NO];
}

- (NSDictionary *)groupTitle:(NSString *)title kind:(NSString *)kind items:(NSArray *)items {
    return [NSDictionary dictionaryWithObjectsAndKeys:
            title.length ? title : @"", @"title",
            kind, @"kind",
            items ?: [NSArray array], @"items",
            nil];
}

- (void)rebuildGroups {
    NSMutableArray *groups = [NSMutableArray array];
    if (self.screen == waSearchScreenIdle) {
        if (self.recents.count) [groups addObject:[self groupTitle:@"Recents" kind:@"recent" items:self.recents]];
    } else if (self.screen == waSearchScreenSuggest) {
        NSString *query = [self typedQuery];
        if (query.length) [groups addObject:[self groupTitle:@"" kind:@"query" items:[NSArray arrayWithObject:query]]];
        NSArray *matched = [self matchingRecents];
        if (matched.count) [groups addObject:[self groupTitle:@"Recents" kind:@"recent" items:matched]];
        if (self.suggestArtists.count) [groups addObject:[self groupTitle:@"Artists" kind:@"item" items:self.suggestArtists]];
        if (self.suggestTracks.count) [groups addObject:[self groupTitle:@"Songs" kind:@"item" items:self.suggestTracks]];
        if (self.suggestAlbums.count) [groups addObject:[self groupTitle:@"Albums" kind:@"item" items:self.suggestAlbums]];
        if (self.suggestPlaylists.count) [groups addObject:[self groupTitle:@"Playlists" kind:@"item" items:self.suggestPlaylists]];
    } else {
        if (self.tracks.count) [groups addObject:[self groupTitle:@"Songs" kind:@"track" items:self.tracks]];
        if (self.albums.count) [groups addObject:[self groupTitle:@"Albums" kind:@"carousel" items:self.albums]];
        if (self.artists.count) [groups addObject:[self groupTitle:@"Artists" kind:@"carousel" items:self.artists]];
        if (self.playlists.count) [groups addObject:[self groupTitle:@"Playlists" kind:@"carousel" items:self.playlists]];
    }
    self.groups = groups;
}

- (NSDictionary *)groupAt:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.groups.count) return nil;
    return [self.groups objectAtIndex:(NSUInteger)section];
}

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)self.groups.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    NSString *title = [[self groupAt:section] objectForKey:@"title"];
    return title.length ? title : nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    NSDictionary *group = [self groupAt:section];
    NSString *kind = [group objectForKey:@"kind"];
    NSArray *items = [group objectForKey:@"items"];
    if ([kind isEqualToString:@"carousel"]) return items.count ? 1 : 0;
    return (NSInteger)items.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *group = [self groupAt:indexPath.section];
    if ([[[group objectForKey:@"kind"] description] isEqualToString:@"carousel"]) {
        return [waCarouselView heightForArtworkSide:80.0 paged:NO showsHeader:NO] + 8.0;
    }
    return 44.0;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *group = [self groupAt:indexPath.section];
    return [[[group objectForKey:@"kind"] description] isEqualToString:@"recent"];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSDictionary *group = [self groupAt:indexPath.section];
    NSArray *items = [group objectForKey:@"items"];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)items.count) return;
    NSString *query = [items objectAtIndex:(NSUInteger)indexPath.row];
    NSUInteger index = [self.recents indexOfObject:query];
    if (index == NSNotFound) return;
    [self removeRecentAtIndex:index];
    [self rebuildGroups];
    if (!self.groups.count) {
        [self presentIdle];
        return;
    }
    [self.tableView reloadData];
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
    NSDictionary *group = [self groupAt:indexPath.section];
    if (![[[group objectForKey:@"kind"] description] isEqualToString:@"carousel"]) return;
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
    NSDictionary *group = [self groupAt:indexPath.section];
    NSString *kind = [group objectForKey:@"kind"];
    NSArray *items = [group objectForKey:@"items"];
    if ([kind isEqualToString:@"carousel"]) {
        return [self carouselCell:tableView tag:801 + indexPath.section items:items action:@selector(carouselTapped:)];
    }
    if ([kind isEqualToString:@"query"]) {
        static NSString *kQuery = @"search.query";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kQuery];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kQuery];
            cell.textLabel.font = [UIFont systemFontOfSize:17.0];
            cell.textLabel.textColor = [UIColor colorWithRed:0.16 green:0.33 blue:0.58 alpha:1.0];
            cell.textLabel.lineBreakMode = UILineBreakModeTailTruncation;
        }
        NSString *query = indexPath.row < (NSInteger)items.count ? [items objectAtIndex:(NSUInteger)indexPath.row] : @"";
        cell.textLabel.text = [NSString stringWithFormat:@"Search for \u201c%@\u201d", query];
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    if ([kind isEqualToString:@"recent"]) {
        static NSString *kRecent = @"search.recent";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kRecent];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kRecent];
            cell.textLabel.font = [UIFont systemFontOfSize:17.0];
            cell.textLabel.lineBreakMode = UILineBreakModeTailTruncation;
            cell.textLabel.numberOfLines = 1;
        }
        cell.textLabel.text = indexPath.row < (NSInteger)items.count ? [items objectAtIndex:(NSUInteger)indexPath.row] : @"";
        cell.accessoryType = UITableViewCellAccessoryNone;
        return cell;
    }
    id item = (indexPath.row >= 0 && indexPath.row < (NSInteger)items.count) ? [items objectAtIndex:(NSUInteger)indexPath.row] : nil;
    waCell *cell = [waCell cellForTable:tableView subtitle:YES];
    if ([item isKindOfClass:[waTrack class]]) {
        [cell setTrack:(waTrack *)item showAlbum:YES];
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if ([item isKindOfClass:[waItem class]]) {
        [cell setItem:(waItem *)item];
        // A suggestion opens a screen. A song starts playing, so no chevron.
        cell.accessoryType = [kind isEqualToString:@"item"] ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    }
    cell.indexText = nil;
    return cell;
}

- (void)carouselTapped:(waTileView *)tile {
    if (tile.item) [self openItem:tile.item];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *group = [self groupAt:indexPath.section];
    NSString *kind = [group objectForKey:@"kind"];
    NSArray *items = [group objectForKey:@"items"];
    if (indexPath.row < 0 || indexPath.row >= (NSInteger)items.count) return;
    if ([kind isEqualToString:@"query"] || [kind isEqualToString:@"recent"]) {
        NSString *query = [items objectAtIndex:(NSUInteger)indexPath.row];
        self.searchBar.text = query;
        [self submitSearch];
        return;
    }
    if ([kind isEqualToString:@"carousel"]) return;
    id item = [items objectAtIndex:(NSUInteger)indexPath.row];
    if (![item isKindOfClass:[waItem class]]) return;
    NSString *query = [self typedQuery];
    if (query.length) [self rememberQuery:query];
    [self.searchBar resignFirstResponder];
    [self setCancelVisible:NO];
    [self openItem:(waItem *)item];
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
