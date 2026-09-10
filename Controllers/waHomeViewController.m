#import "waHomeViewController.h"
#import "../Services/waAPIClient.h"
#import "../Services/waTheme.h"
#import "../Services/waAudioPlayer.h"
#import "../Views/waHomeSectionView.h"
#import "../Views/waMediaActionSheet.h"
#import "waMediaDetailViewController.h"
#import "../Views/waEmptyView.h"
#import "waPlaylistViewController.h"
#import "../Models/waMediaItem.h"

@interface waHomeViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, strong) waEmptyView *emptyView;
@property (nonatomic, strong) NSArray *sections;
@property (nonatomic, strong) NSMutableArray *sectionViews;
@property (nonatomic, strong) NSTimer *renderTimer;
@property (nonatomic, assign) NSUInteger loadGeneration;
@property (nonatomic, assign) BOOL loadingHome;
@property (nonatomic, assign) BOOL renderingSections;
@end

// Home payload cache. Written off-main as a plist file: NSUserDefaults
// serializes on the calling thread and this payload can be large.
static NSString *waHomeCachePath(void) {
    static NSString *path;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        path = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"wa.home.cache"];
    });
    return path;
}

static dispatch_queue_t waHomeCacheQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.bytebox.wave.home.cache", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@implementation waHomeViewController

- (id)init {
    if ((self = [super init])) {
        _sections = @[];
        _sectionViews = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Home";
    self.view.backgroundColor = [waTheme backgroundColor];
    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.backgroundColor = [waTheme backgroundColor];
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];
    self.refreshControl = [[UIRefreshControl alloc] init];
    self.refreshControl.tintColor = [waTheme barColor];
    [self.refreshControl addTarget:self action:@selector(refreshHome:) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.refreshControl];
    self.emptyView = [[waEmptyView alloc] initWithFrame:self.view.bounds];
    self.emptyView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.emptyView.hidden = YES;
    [self.view addSubview:self.emptyView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    [self loadHome];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
    [self applyTheme];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Player is modal (tab), not a push on Home nav — don't animate bar back
    BOOL presentingPlayerModal = self.tabBarController.selectedIndex == 4 || self.tabBarController.presentedViewController != nil;
    if (presentingPlayerModal) return;
    [self.navigationController setNavigationBarHidden:NO animated:animated];
}

- (void)refreshHome:(id)sender { (void)sender; [self loadHome]; }

- (NSArray *)mediaItemsFromSection:(NSDictionary *)section {
    NSArray *objects = [section[@"items"] isKindOfClass:[NSArray class]] ? section[@"items"] : @[];
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:objects.count];
    for (NSDictionary *object in objects) {
        waMediaItem *item = [waMediaItem itemWithDictionary:object];
        if (item) [items addObject:item];
    }
    return items;
}

- (void)renderSections {
    if (![NSThread isMainThread]) {
        __weak waHomeViewController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf renderSections]; });
        return;
    }
    if (self.renderingSections) {
        if (!self.renderTimer) self.renderTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(renderSectionsRetry:) userInfo:nil repeats:NO];
        return;
    }
    self.renderingSections = YES;
    @try {
    for (waHomeSectionView *view in self.sectionViews) { [view clearCallbacks]; [view removeFromSuperview]; }
    [self.sectionViews removeAllObjects];
    __weak waHomeViewController *weakSelf = self;
    CGFloat y = 30.0 + [waTheme statusBarHeight];
    CGFloat width = self.view.bounds.size.width;
    for (NSDictionary *section in self.sections) {
        waHomeSectionView *view = [[waHomeSectionView alloc] initWithFrame:CGRectMake(0.0, y, width, 270.0)];
        NSMutableDictionary *displaySection = [section mutableCopy];
        displaySection[@"items"] = [self mediaItemsFromSection:section];
         [view configureWithSection:displaySection selection:^(waMediaItem *item, NSArray *context) {
             waHomeViewController *controller = weakSelf;
             if (controller) [controller selectHomeItem:item context:context];
         }];
         view.longPress = ^(waMediaItem *item, NSArray *context) {
             waHomeViewController *controller = weakSelf;
             if (controller && (item.type == waMediaItemTypeSong || item.type == waMediaItemTypeAlbum || item.type == waMediaItemTypeArtist || item.type == waMediaItemTypePlaylist)) [waMediaActionSheet presentForItem:item inViewController:controller albumItems:context];
         };
        [self.scrollView addSubview:view];
        [self.sectionViews addObject:view];
        y += [view preferredHeight] + 18.0;
    }
    [self layoutSectionViews];
    self.scrollView.contentSize = CGSizeMake(width, MAX(y, self.scrollView.bounds.size.height + 1.0));
    self.emptyView.hidden = self.sections.count > 0;
    } @finally {
        self.renderingSections = NO;
    }
}

- (void)layoutSectionViews {
    CGFloat y = 30.0 + [waTheme statusBarHeight];
    CGFloat width = self.view.bounds.size.width;
    for (waHomeSectionView *view in self.sectionViews) {
        view.frame = CGRectMake(0.0, y, width, [view preferredHeight]);
        y += view.preferredHeight + 18.0;
    }
    self.scrollView.contentSize = CGSizeMake(width, MAX(y, self.scrollView.bounds.size.height + 1.0));
}

- (void)loadHome {
    if (self.loadingHome) return;
    NSUInteger generation = ++self.loadGeneration;
    self.loadingHome = YES;
    [self.emptyView setLoading:YES];
    self.emptyView.hidden = NO;
    [self.refreshControl endRefreshing];
    [[waAPIClient sharedClient] homeWithCompletion:^(NSDictionary *home, NSError *error) {
        if (generation != self.loadGeneration) return;
        if (!error && home) {
            [self applyHomeSource:home failedWithError:NO];
            dispatch_async(waHomeCacheQueue(), ^{
                // One-time purge of the legacy NSUserDefaults copy: it was
                // re-serialized on the main thread on every successful load.
                static dispatch_once_t purgeOnce;
                dispatch_once(&purgeOnce, ^{ [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"com.bytebox.wave.home.cache"]; });
                [home writeToFile:waHomeCachePath() atomically:YES];
            });
            return;
        }
        // Network failed. Fall back to the on-disk cache, reading it off the
        // main thread so parsing the full payload never blocks first paint.
        dispatch_async(waHomeCacheQueue(), ^{
            NSDictionary *cached = [NSDictionary dictionaryWithContentsOfFile:waHomeCachePath()];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.loadGeneration) return;
                [self applyHomeSource:cached failedWithError:YES];
            });
        });
    }];
}

- (void)applyHomeSource:(NSDictionary *)source failedWithError:(BOOL)failed {
    NSArray *sections = [source[@"sections"] isKindOfClass:[NSArray class]] ? source[@"sections"] : @[];
    NSMutableArray *usable = [NSMutableArray array];
    // Only test for presence here. Building the waMediaItem array just to
    // discard it doubled the model conversion on every Home load.
    for (NSDictionary *section in sections) {
        if (![section isKindOfClass:[NSDictionary class]]) continue;
        NSArray *items = [section[@"items"] isKindOfClass:[NSArray class]] ? section[@"items"] : nil;
        if (items.count) [usable addObject:section];
    }
    self.sections = usable;
    self.loadingHome = NO;
    [self.emptyView setLoading:NO];
    if (self.sections.count) {
        self.emptyView.hidden = YES;
    } else {
        NSString *subtitle = failed ? @"Unable to load Deezer Home." : @"No recommendations available.";
        [self.emptyView configureWithIcon:[UIImage imageNamed:@"tab-wave-home"] title:@"Home" subtitle:subtitle actionTitle:@"Retry" target:self action:@selector(refreshHome:)];
        self.emptyView.hidden = NO;
    }
    [[waAPIClient sharedClient] flowConfigsWithCompletion:^(NSArray *configs, NSError *flowError) {
        if (flowError || !configs.count) return;
        NSMutableArray *updated = [self.sections mutableCopy];
        NSInteger flowSectionIndex = NSNotFound;
        for (NSUInteger index = 0; index < updated.count; index++) {
             NSDictionary *section = updated[index];
             if ([[section[@"title"] lowercaseString] rangeOfString:@"flow"].location != NSNotFound) { flowSectionIndex = (NSInteger)index; break; }
         }
        if (flowSectionIndex != NSNotFound) {
             NSMutableDictionary *section = [updated[flowSectionIndex] mutableCopy];
             section[@"subtitle"] = @"";
              NSMutableArray *items = [section[@"items"] mutableCopy] ?: [NSMutableArray array];
              NSIndexSet *defaultFlowIndexes = [items indexesOfObjectsPassingTest:^BOOL(NSDictionary *object, NSUInteger idx, BOOL *stop) {
                  NSString *identifier = object[@"identifier"];
                  NSString *title = [object[@"title"] lowercaseString];
                  return [identifier isEqualToString:@"default"] || [title isEqualToString:@"flow"];
              }];
              if (defaultFlowIndexes.count) [items removeObjectsAtIndexes:defaultFlowIndexes];
             for (NSDictionary *config in configs) {
                 NSString *identifier = config[@"identifier"];
                 NSInteger existingIndex = NSNotFound;
                 for (NSUInteger itemIndex = 0; itemIndex < items.count; itemIndex++) {
                     if ([items[itemIndex][@"identifier"] isEqualToString:identifier]) { existingIndex = (NSInteger)itemIndex; break; }
                 }
                 if (existingIndex != NSNotFound) [items replaceObjectAtIndex:existingIndex withObject:config];
                 else [items addObject:config];
             }
             section[@"items"] = items;
             updated[flowSectionIndex] = section;
         } else {
             [updated addObject:@{@"title": @"Flow: play how you feel", @"subtitle": @"Choose your mood", @"layout": @"circle", @"items": configs}];
         }
        self.sections = updated;
        [self renderSections];
    }];
    [self renderSections];
}

- (void)selectHomeItem:(waMediaItem *)item context:(NSArray *)context {
    if (!item) return;
    NSString *homeKind = [item.metadata[@"homeKind"] lowercaseString];
    BOOL flowKind = [@[@"flow", @"flow_mood", @"mood", @"radio", @"channel"] containsObject:homeKind];
    if (flowKind) {
        [self.emptyView setLoading:YES];
        self.emptyView.hidden = NO;
        NSString *flowConfigID = item.metadata[@"flowConfigID"];
        void (^flowCompletion)(NSArray *, NSError *) = ^(NSArray *tracks, NSError *error) {
            [self.emptyView setLoading:NO];
            NSMutableArray *mediaTracks = [NSMutableArray arrayWithCapacity:tracks.count];
            for (id object in tracks) {
                waMediaItem *mediaItem = [object isKindOfClass:[waMediaItem class]] ? object : ([object isKindOfClass:[NSDictionary class]] ? [waMediaItem itemWithDictionary:object] : nil);
                if (mediaItem) [mediaTracks addObject:mediaItem];
            }
            if (error || !mediaTracks.count) {
                [[[UIAlertView alloc] initWithTitle:@"Flow" message:error.localizedDescription ?: @"No Flow tracks available." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
                return;
            }
            [[waAudioPlayer sharedPlayer] playItem:mediaTracks[0] fromContext:mediaTracks title:item.title.length ? item.title : @"Flow"];
        };
        if (flowConfigID.length && ![flowConfigID isEqualToString:@"default"]) {
            [[waAPIClient sharedClient] flowConfigWithIdentifier:flowConfigID completion:flowCompletion];
        } else {
            [[waAPIClient sharedClient] flowWithCompletion:flowCompletion];
        }
        return;
    }
    if (item.type == waMediaItemTypeSong) {
        [[waAudioPlayer sharedPlayer] playItem:item fromContext:context title:item.title ?: @"Deezer"];
    } else if (item.type == waMediaItemTypePlaylist) {
        if (!item.identifier.length) return;
        NSDictionary *playlist = @{ @"id": item.identifier ?: @"", @"title": item.title ?: @"Playlist", @"name": item.title ?: @"Playlist", @"description": @"", @"thumbnailURL": item.thumbnailURL ?: @"", @"artwork": item.thumbnailURL ?: @"" };
        [self.navigationController pushViewController:[[waPlaylistViewController alloc] initWithPlaylist:playlist ownerIsCurrentUser:NO] animated:YES];
    } else {
        [self.navigationController pushViewController:[[waMediaDetailViewController alloc] initWithMediaItem:item] animated:YES];
    }
}

- (void)applyTheme {
    self.view.backgroundColor = [waTheme backgroundColor];
    self.scrollView.backgroundColor = [waTheme backgroundColor];
    [self.emptyView applyTheme];
    self.refreshControl.tintColor = [waTheme barColor];
}

- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    [self applyTheme];
    if (self.view.window) [self renderSections];
}

// Home cards carry no download state, so download notifications require no
// visual refresh at all. Rebuilding the sections here (the previous behavior,
// ~4x/second during active downloads) was wasted work that also reset every
// carousel's scroll position.
- (void)renderSectionsRetry:(NSTimer *)timer {
    (void)timer;
    self.renderTimer = nil;
    if (self.view.window && !self.loadingHome) [self renderSections];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat top = [waTheme statusBarHeight];
    CGRect bounds = self.view.bounds;
    if (top > 0) {
        self.scrollView.frame = CGRectMake(0, top, bounds.size.width, bounds.size.height - top);
    } else {
        self.scrollView.frame = bounds;
    }
    self.emptyView.frame = self.view.bounds;
    if (!self.loadingHome) [self layoutSectionViews];
}

- (void)dealloc { [self.renderTimer invalidate]; for (waHomeSectionView *view in self.sectionViews) [view clearCallbacks]; [[NSNotificationCenter defaultCenter] removeObserver:self]; }

@end
