#import "waHomeViewController.h"
#import "../Services/waAPIClient.h"
#import "../Services/waTheme.h"
#import "../Services/waAudioPlayer.h"
#import "../Audio/waAudioEngine.h"
#import "../Views/waHomeSectionView.h"
#import "../Views/waMediaActionSheet.h"
#import "waMediaDetailViewController.h"
#import "waMediaResultsViewController.h"
#import "../Views/waEmptyView.h"
#import "waPlaylistViewController.h"
#import "../Models/waMediaItem.h"

@interface waHomeViewController ()
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIRefreshControl *refreshControl;
@property (nonatomic, strong) waEmptyView *emptyView;
@property (nonatomic, strong) UIView *homeHeaderView;
@property (nonatomic, strong) UILabel *greetingLabel;
@property (nonatomic, strong) UILabel *headerTitleLabel;
@property (nonatomic, strong) UILabel *headerSubtitleLabel;
@property (nonatomic, strong) UIButton *headerActionButton;
@property (nonatomic, strong) NSArray *sections;
@property (nonatomic, strong) NSMutableArray *sectionViews;
@property (nonatomic, strong) NSTimer *renderTimer;
@property (nonatomic, assign) NSUInteger loadGeneration;
@property (nonatomic, assign) BOOL loadingHome;
@property (nonatomic, assign) BOOL renderingSections;
@property (nonatomic, assign) BOOL headerActionLoading;
@property (nonatomic, assign) NSInteger headerActionMode;
@end

typedef NS_ENUM(NSInteger, waHomeHeaderActionMode) {
    waHomeHeaderActionPlayFlow = 0,
    waHomeHeaderActionResume = 1,
    waHomeHeaderActionOpenPlayer = 2
};

static CGFloat waHomeHeaderHeight(void) { return 84.0; }
static CGFloat waHomeSectionOriginY(void) { return 12.0 + waHomeHeaderHeight() + 10.0; }

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
    [self buildHomeHeader];
    self.refreshControl = [[UIRefreshControl alloc] init];
    self.refreshControl.tintColor = [waTheme barColor];
    [self.refreshControl addTarget:self action:@selector(refreshHome:) forControlEvents:UIControlEventValueChanged];
    [self.scrollView addSubview:self.refreshControl];
    self.emptyView = [[waEmptyView alloc] initWithFrame:self.view.bounds];
    self.emptyView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.emptyView.hidden = YES;
    [self.view addSubview:self.emptyView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerDidChange:) name:waAudioPlayerDidChangeNotification object:nil];
    [self loadHome];
}

- (void)buildHomeHeader {
    self.homeHeaderView = [[UIView alloc] initWithFrame:CGRectZero];
    self.homeHeaderView.backgroundColor = [UIColor clearColor];
    [self.scrollView addSubview:self.homeHeaderView];

    self.greetingLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.greetingLabel.backgroundColor = [UIColor clearColor];
    self.greetingLabel.font = [waTheme secondaryMediumFontOfSize:13.0];
    self.greetingLabel.textColor = [waTheme secondaryTextColor];
    self.greetingLabel.numberOfLines = 1;
    [self.homeHeaderView addSubview:self.greetingLabel];

    self.headerTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.headerTitleLabel.backgroundColor = [UIColor clearColor];
    self.headerTitleLabel.font = [waTheme extraBoldFontOfSize:24.0];
    self.headerTitleLabel.textColor = [waTheme primaryTextColor];
    self.headerTitleLabel.numberOfLines = 1;
    self.headerTitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.homeHeaderView addSubview:self.headerTitleLabel];

    self.headerSubtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.headerSubtitleLabel.backgroundColor = [UIColor clearColor];
    self.headerSubtitleLabel.font = [waTheme secondaryRegularFontOfSize:13.0];
    self.headerSubtitleLabel.textColor = [waTheme secondaryTextColor];
    self.headerSubtitleLabel.numberOfLines = 1;
    self.headerSubtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.homeHeaderView addSubview:self.headerSubtitleLabel];

    self.headerActionButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.headerActionButton.titleLabel.font = [waTheme mediumFontOfSize:13.0];
    self.headerActionButton.accessibilityTraits = UIAccessibilityTraitButton;
    [self.headerActionButton addTarget:self action:@selector(headerActionPressed:) forControlEvents:UIControlEventTouchUpInside];
    [self.homeHeaderView addSubview:self.headerActionButton];
    [self updateHomeHeader];
}

- (NSString *)homeGreeting {
    NSInteger hour = [[[NSCalendar currentCalendar] components:NSHourCalendarUnit fromDate:[NSDate date]] hour];
    NSString *greeting = hour < 12 ? @"Good morning" : (hour < 18 ? @"Good afternoon" : @"Good evening");
    NSString *name = [[waAPIClient sharedClient] authenticatedUserName];
    return name.length ? [NSString stringWithFormat:@"%@, %@", greeting, name] : greeting;
}

- (void)updateHomeHeader {
    if (!self.headerActionButton) return;
    waAudioPlayer *player = [waAudioPlayer sharedPlayer];
    waMediaItem *item = player.currentItem;
    BOOL playing = [waAudioEngine sharedEngine].isPlaying;
    self.headerActionMode = waHomeHeaderActionPlayFlow;
    if (item.title.length) {
        self.greetingLabel.text = playing ? @"Now playing" : @"Continue listening";
        self.headerTitleLabel.text = item.title;
        NSString *artist = item.artistName.length ? item.artistName : item.subtitle;
        self.headerSubtitleLabel.text = artist.length ? artist : (player.queueContextTitle.length ? player.queueContextTitle : @"Your Deezer queue");
        self.headerActionMode = playing ? waHomeHeaderActionOpenPlayer : waHomeHeaderActionResume;
    } else {
        self.greetingLabel.text = [self homeGreeting];
        self.headerTitleLabel.text = @"Made for you";
        self.headerSubtitleLabel.text = @"Play your Flow or discover something new.";
    }
    if (self.headerActionLoading) {
        [self.headerActionButton setTitle:@"Loading…" forState:UIControlStateNormal];
        self.headerActionButton.enabled = NO;
    } else {
        NSString *title = self.headerActionMode == waHomeHeaderActionResume ? @"Resume" : (self.headerActionMode == waHomeHeaderActionOpenPlayer ? @"Open player" : @"Play Flow");
        [self.headerActionButton setTitle:title forState:UIControlStateNormal];
        self.headerActionButton.enabled = YES;
    }
    NSString *actionTitle = self.headerActionMode == waHomeHeaderActionResume ? @"Resume playback" : (self.headerActionMode == waHomeHeaderActionOpenPlayer ? @"Open player" : @"Play your Flow");
    self.headerActionButton.accessibilityLabel = actionTitle;
    self.headerActionButton.accessibilityHint = @"Starts playback or opens the player.";
}

- (void)headerActionPressed:(id)sender {
    (void)sender;
    if (self.headerActionLoading) return;
    if (self.headerActionMode == waHomeHeaderActionResume) {
        [[waAudioPlayer sharedPlayer] resume];
        return;
    }
    if (self.headerActionMode == waHomeHeaderActionOpenPlayer) {
        self.tabBarController.selectedIndex = 4;
        return;
    }

    self.headerActionLoading = YES;
    [self updateHomeHeader];
    __weak waHomeViewController *weakSelf = self;
    [[waAPIClient sharedClient] flowWithCompletion:^(NSArray *tracks, NSError *error) {
        waHomeViewController *controller = weakSelf;
        if (!controller) return;
        controller.headerActionLoading = NO;
        NSMutableArray *mediaTracks = [NSMutableArray arrayWithCapacity:tracks.count];
        for (id object in tracks) {
            waMediaItem *mediaItem = [object isKindOfClass:[waMediaItem class]] ? object : ([object isKindOfClass:[NSDictionary class]] ? [waMediaItem itemWithDictionary:object] : nil);
            if (mediaItem) [mediaTracks addObject:mediaItem];
        }
        if (error || !mediaTracks.count) {
            [controller updateHomeHeader];
            [[[UIAlertView alloc] initWithTitle:@"Flow" message:error.localizedDescription ?: @"No Flow tracks available." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
            return;
        }
        [[waAudioPlayer sharedPlayer] playItem:mediaTracks[0] fromContext:mediaTracks title:@"Flow"];
        [controller updateHomeHeader];
    }];
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

- (void)configureSectionView:(waHomeSectionView *)view withSection:(NSDictionary *)section {
    if (!view || !section) return;
    __weak waHomeViewController *weakSelf = self;
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
    view.moreAction = nil;
    if ([section[@"showsMore"] boolValue]) {
        view.moreAction = ^{
            waHomeViewController *controller = weakSelf;
            NSArray *items = controller ? [controller mediaItemsFromSection:section] : @[];
            if (!controller || !items.count) return;
            waMediaItem *first = items[0];
            [controller.navigationController pushViewController:[[waMediaResultsViewController alloc] initWithItems:items type:first.type title:section[@"title"] ?: @"More"] animated:YES];
        };
    }
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
    BOOL reuseViews = self.sectionViews.count == self.sections.count;
    if (!reuseViews) {
        for (waHomeSectionView *view in self.sectionViews) { [view clearCallbacks]; [view removeFromSuperview]; }
        [self.sectionViews removeAllObjects];
    }
    CGFloat y = waHomeSectionOriginY();
    CGFloat width = self.view.bounds.size.width;
    for (NSUInteger index = 0; index < self.sections.count; index++) {
        NSDictionary *section = self.sections[index];
        waHomeSectionView *view = reuseViews ? self.sectionViews[index] : [[waHomeSectionView alloc] initWithFrame:CGRectMake(0.0, y, width, 270.0)];
        [self configureSectionView:view withSection:section];
        if (!reuseViews) {
            [self.scrollView addSubview:view];
            [self.sectionViews addObject:view];
        }
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
    CGFloat y = waHomeSectionOriginY();
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
    [[waAPIClient sharedClient] homeWithCompletion:^(NSDictionary *home, NSError *error) {
        if (generation != self.loadGeneration) return;
        if (!error && home) {
            [self.refreshControl endRefreshing];
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
                [self.refreshControl endRefreshing];
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
        if (!items.count) continue;
        NSString *sectionTitle = [section[@"title"] isKindOfClass:[NSString class]] ? section[@"title"] : @"";
        NSString *sectionTitleKey = [sectionTitle lowercaseString];
        if ([sectionTitleKey rangeOfString:@"your top genres"].location != NSNotFound) continue;
        BOOL isFlowSection = [sectionTitleKey rangeOfString:@"flow"].location != NSNotFound;
        if (!isFlowSection) {
            [usable addObject:section];
            continue;
        }

        // Deezer's Home flow shelf contains moods and genre flows in the same
        // module. Keep them as separate shelves so a genre card is never
        // treated as a normal playlist by the UI.
        NSMutableArray *moods = [NSMutableArray array];
        NSMutableArray *genres = [NSMutableArray array];
        for (NSDictionary *item in items) {
            NSString *homeKindValue = [item[@"homeKind"] isKindOfClass:[NSString class]] ? item[@"homeKind"] : @"";
            NSString *homeKind = [homeKindValue lowercaseString];
            if ([homeKind isEqualToString:@"genre"] || [homeKind hasPrefix:@"genre-"]) [genres addObject:item];
            else [moods addObject:item];
        }
        if (moods.count) {
            NSMutableDictionary *moodSection = [section mutableCopy];
            moodSection[@"title"] = @"Your Flow";
            moodSection[@"subtitle"] = @"Play by mood";
            moodSection[@"layout"] = @"circle";
            moodSection[@"items"] = moods;
            [usable addObject:moodSection];
        }
        if (genres.count) {
            NSMutableDictionary *genreSection = [section mutableCopy];
            genreSection[@"title"] = @"Top genres";
            genreSection[@"subtitle"] = @"Based on your listening";
            genreSection[@"layout"] = @"circle";
            genreSection[@"items"] = genres;
            [usable addObject:genreSection];
        }
    }
    [usable sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
        NSString *leftTitle = [left[@"title"] isKindOfClass:[NSString class]] ? [left[@"title"] lowercaseString] : @"";
        NSString *rightTitle = [right[@"title"] isKindOfClass:[NSString class]] ? [right[@"title"] lowercaseString] : @"";
        BOOL leftFlow = [leftTitle rangeOfString:@"flow"].location != NSNotFound;
        BOOL rightFlow = [rightTitle rangeOfString:@"flow"].location != NSNotFound;
        if (leftFlow != rightFlow) return leftFlow ? NSOrderedAscending : NSOrderedDescending;
        BOOL leftRecent = [leftTitle rangeOfString:@"recent"].location != NSNotFound;
        BOOL rightRecent = [rightTitle rangeOfString:@"recent"].location != NSNotFound;
        if (leftRecent != rightRecent) return leftRecent ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    }];
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
        NSMutableArray *moodConfigs = [NSMutableArray array];
        NSMutableArray *genreConfigs = [NSMutableArray array];
        for (NSDictionary *config in configs) {
            if (![config isKindOfClass:[NSDictionary class]]) continue;
            NSString *kindValue = [config[@"homeKind"] isKindOfClass:[NSString class]] ? config[@"homeKind"] : @"";
            NSString *kind = [kindValue lowercaseString];
            if ([kind isEqualToString:@"genre"] || [kind hasPrefix:@"genre-"]) [genreConfigs addObject:config];
            else [moodConfigs addObject:config];
        }
        NSMutableArray *updated = [self.sections mutableCopy];
        NSInteger flowSectionIndex = NSNotFound;
        NSInteger genreSectionIndex = NSNotFound;
        for (NSUInteger index = 0; index < updated.count; index++) {
            NSDictionary *section = updated[index];
            NSString *titleValue = [section[@"title"] isKindOfClass:[NSString class]] ? section[@"title"] : @"";
            NSString *title = [titleValue lowercaseString];
            if (flowSectionIndex == NSNotFound && [title rangeOfString:@"flow"].location != NSNotFound) flowSectionIndex = (NSInteger)index;
            if (genreSectionIndex == NSNotFound && [title rangeOfString:@"genre"].location != NSNotFound) genreSectionIndex = (NSInteger)index;
        }

        void (^mergeConfigs)(NSMutableArray *, NSArray *) = ^(NSMutableArray *items, NSArray *newConfigs) {
            for (NSDictionary *config in newConfigs) {
                NSString *identifier = config[@"identifier"];
                if (!identifier.length) continue;
                NSInteger existingIndex = NSNotFound;
                for (NSUInteger itemIndex = 0; itemIndex < items.count; itemIndex++) {
                    if ([items[itemIndex][@"identifier"] isEqualToString:identifier]) { existingIndex = (NSInteger)itemIndex; break; }
                }
                if (existingIndex != NSNotFound) [items replaceObjectAtIndex:existingIndex withObject:config];
                else [items addObject:config];
            }
        };

        if (moodConfigs.count) {
            if (flowSectionIndex == NSNotFound) {
                [updated insertObject:@{@"title": @"Your Flow", @"subtitle": @"Play by mood", @"layout": @"circle", @"items": moodConfigs} atIndex:0];
                if (genreSectionIndex != NSNotFound) genreSectionIndex += 1;
                flowSectionIndex = 0;
            } else {
                NSMutableDictionary *section = [updated[flowSectionIndex] mutableCopy];
                NSMutableArray *items = [NSMutableArray array];
                for (NSDictionary *item in section[@"items"]) {
                    NSString *kindValue = [item[@"homeKind"] isKindOfClass:[NSString class]] ? item[@"homeKind"] : @"";
                    NSString *kind = [kindValue lowercaseString];
                    NSString *identifier = item[@"identifier"];
                    if ([kind isEqualToString:@"genre"] || [kind hasPrefix:@"genre-"] || [identifier hasPrefix:@"genre-"]) continue;
                    if ([identifier isEqualToString:@"default"] || [[item[@"title"] lowercaseString] isEqualToString:@"flow"]) continue;
                    [items addObject:item];
                }
                section[@"title"] = @"Your Flow";
                section[@"subtitle"] = @"Play by mood";
                section[@"layout"] = @"circle";
                mergeConfigs(items, moodConfigs);
                section[@"items"] = items;
                updated[flowSectionIndex] = section;
            }
        }

        if (genreConfigs.count) {
            if (genreSectionIndex == NSNotFound) {
                NSUInteger insertIndex = flowSectionIndex == NSNotFound ? 0 : (NSUInteger)flowSectionIndex + 1;
                [updated insertObject:@{@"title": @"Top genres", @"subtitle": @"Based on your listening", @"layout": @"circle", @"items": genreConfigs} atIndex:MIN(insertIndex, updated.count)];
            } else {
                NSMutableDictionary *section = [updated[genreSectionIndex] mutableCopy];
                NSMutableArray *items = [NSMutableArray array];
                for (NSDictionary *item in section[@"items"]) {
                    NSString *kindValue = [item[@"homeKind"] isKindOfClass:[NSString class]] ? item[@"homeKind"] : @"";
                    NSString *kind = [kindValue lowercaseString];
                    NSString *identifier = item[@"identifier"];
                    if ([kind isEqualToString:@"genre"] || [kind hasPrefix:@"genre-"] || [identifier hasPrefix:@"genre-"]) [items addObject:item];
                }
                section[@"title"] = @"Top genres";
                section[@"subtitle"] = @"Based on your listening";
                section[@"layout"] = @"circle";
                mergeConfigs(items, genreConfigs);
                section[@"items"] = items;
                updated[genreSectionIndex] = section;
            }
        }
        [updated sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            NSString *leftTitle = [left[@"title"] isKindOfClass:[NSString class]] ? [left[@"title"] lowercaseString] : @"";
            NSString *rightTitle = [right[@"title"] isKindOfClass:[NSString class]] ? [right[@"title"] lowercaseString] : @"";
            BOOL leftFlow = [leftTitle rangeOfString:@"flow"].location != NSNotFound;
            BOOL rightFlow = [rightTitle rangeOfString:@"flow"].location != NSNotFound;
            if (leftFlow != rightFlow) return leftFlow ? NSOrderedAscending : NSOrderedDescending;
            BOOL leftRecent = [leftTitle rangeOfString:@"recent"].location != NSNotFound;
            BOOL rightRecent = [rightTitle rangeOfString:@"recent"].location != NSNotFound;
            if (leftRecent != rightRecent) return leftRecent ? NSOrderedAscending : NSOrderedDescending;
            return NSOrderedSame;
        }];
        self.sections = updated;
        [self renderSections];
    }];
    [self renderSections];
}

- (void)selectHomeItem:(waMediaItem *)item context:(NSArray *)context {
    if (!item) return;
    NSString *homeKind = [item.metadata[@"homeKind"] lowercaseString];
    BOOL flowKind = [@[@"flow", @"flow_mood", @"mood", @"radio", @"channel", @"genre"] containsObject:homeKind];
    BOOL smartTracklistKind = [homeKind isEqualToString:@"smarttracklist"];
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
                self.emptyView.hidden = YES;
                NSString *title = [homeKind isEqualToString:@"genre"] ? @"Top genre" : @"Flow";
                [[[UIAlertView alloc] initWithTitle:title message:error.localizedDescription ?: @"No tracks available." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
                return;
            }
            self.emptyView.hidden = YES;
            [[waAudioPlayer sharedPlayer] playItem:mediaTracks[0] fromContext:mediaTracks title:item.title.length ? item.title : @"Flow"];
        };
        if (flowConfigID.length && ![flowConfigID isEqualToString:@"default"]) {
            [[waAPIClient sharedClient] flowConfigWithIdentifier:flowConfigID completion:flowCompletion];
        } else {
            [[waAPIClient sharedClient] flowWithCompletion:flowCompletion];
        }
        return;
    }
    if (smartTracklistKind) {
        if (!item.identifier.length) return;
        [self.emptyView setLoading:YES];
        self.emptyView.hidden = NO;
        [[waAPIClient sharedClient] smartTracklistWithIdentifier:item.identifier completion:^(NSDictionary *playlist, NSError *error) {
            [self.emptyView setLoading:NO];
            self.emptyView.hidden = YES;
            if (error || ![playlist isKindOfClass:[NSDictionary class]]) {
                [[[UIAlertView alloc] initWithTitle:@"Made for you" message:error.localizedDescription ?: @"Unable to load this playlist." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
                return;
            }
            [self.navigationController pushViewController:[[waPlaylistViewController alloc] initWithPlaylist:playlist ownerIsCurrentUser:NO] animated:YES];
        }];
        return;
    }
    if (item.type == waMediaItemTypeSong) {
        [[waAudioPlayer sharedPlayer] playItem:item fromContext:context title:item.title ?: @"Deezer"];
    } else if (item.type == waMediaItemTypePlaylist) {
        if (!item.identifier.length) return;
        NSMutableDictionary *playlist = [@{ @"id": item.identifier ?: @"", @"identifier": item.identifier ?: @"", @"title": item.title ?: @"Playlist", @"name": item.title ?: @"Playlist", @"description": @"", @"thumbnailURL": item.thumbnailURL ?: @"", @"artwork": item.thumbnailURL ?: @"" } mutableCopy];
        if (homeKind.length) playlist[@"homeKind"] = homeKind;
        if (item.metadata[@"smartTracklistID"]) playlist[@"smartTracklistID"] = item.metadata[@"smartTracklistID"];
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
    self.greetingLabel.textColor = [waTheme secondaryTextColor];
    self.headerTitleLabel.textColor = [waTheme primaryTextColor];
    self.headerSubtitleLabel.textColor = [waTheme secondaryTextColor];
    [waTheme applySkeuomorphicStyleToButton:self.headerActionButton];
    [self updateHomeHeader];
}

- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    [self applyTheme];
    if (self.view.window) [self renderSections];
}

- (void)playerDidChange:(NSNotification *)notification {
    (void)notification;
    if (![NSThread isMainThread]) {
        __weak waHomeViewController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf playerDidChange:nil]; });
        return;
    }
    [self updateHomeHeader];
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
    self.homeHeaderView.frame = CGRectMake(16.0, 12.0, MAX(0.0, self.scrollView.bounds.size.width - 32.0), waHomeHeaderHeight());
    CGFloat actionWidth = 106.0;
    CGFloat textWidth = MAX(0.0, self.homeHeaderView.bounds.size.width - actionWidth - 12.0);
    self.greetingLabel.frame = CGRectMake(0.0, 0.0, textWidth, 20.0);
    self.headerTitleLabel.frame = CGRectMake(0.0, 18.0, textWidth, 30.0);
    self.headerSubtitleLabel.frame = CGRectMake(0.0, 51.0, textWidth, 20.0);
    self.headerActionButton.frame = CGRectMake(self.homeHeaderView.bounds.size.width - actionWidth, 23.0, actionWidth, 36.0);
    self.emptyView.frame = self.view.bounds;
    if (!self.loadingHome) [self layoutSectionViews];
}

- (void)dealloc { [self.renderTimer invalidate]; for (waHomeSectionView *view in self.sectionViews) [view clearCallbacks]; [[NSNotificationCenter defaultCenter] removeObserver:self]; }

@end
