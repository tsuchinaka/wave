#import "../Core/waLog.h"
#import "waRootController.h"
#import "waHomeController.h"
#import "waSearchController.h"
#import "waLibraryController.h"
#import "waSettingsController.h"
#import "waPlayerController.h"
#import "../Skin/waSkin.h"
#import "../Core/waSession.h"
#import "../Core/waPlayer.h"
#import "../Core/waDownloader.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

NSString * const waMiniPlayerLayoutDidChangeNotification = @"waMiniPlayerLayoutDidChangeNotification";

static waRootController *waLiveRoot = nil;
static CGFloat waMiniPlayerCoverHeight = 0.0;

@interface waRootController () <UITabBarControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) NSMutableArray *controllers;
@property (nonatomic, strong) waMiniPlayerBar *miniBar;
@property (nonatomic, strong) waPlayerController *player;
@end

@implementation waRootController

+ (waRootController *)shared {
    if (waLiveRoot) return waLiveRoot;
    UIViewController *root = [[[UIApplication sharedApplication] keyWindow] rootViewController];
    if ([root isKindOfClass:[self class]]) return (waRootController *)root;
    if ([root isKindOfClass:[UINavigationController class]]) {
        NSArray *stack = ((UINavigationController *)root).viewControllers;
        UIViewController *top = stack.count ? [stack objectAtIndex:0] : nil;
        if ([top isKindOfClass:[self class]]) return (waRootController *)top;
    }
    return nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    waLiveRoot = self;
    self.delegate = self;
    self.view.backgroundColor = [waSkin tableBackground];
    [waSkin styleTabBar:self.tabBar];

    waHomeController *home = [[waHomeController alloc] init];
    waSearchController *search = [[waSearchController alloc] init];
    waLibraryController *library = [[waLibraryController alloc] init];
    waSettingsController *settings = [[waSettingsController alloc] initWithStyle:UITableViewStyleGrouped];

    NSArray *roots = @[home, search, library, settings];
    NSArray *titles = @[@"Home", @"Search", @"Library", @"Settings"];
    NSArray *icons = @[@"tab-wave-home.png", @"tab-wave-search.png", @"tab-wave-library.png", @"tab-wave-settings.png"];
    NSMutableArray *navs = [NSMutableArray array];
    for (NSUInteger index = 0; index < roots.count; index++) {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[roots objectAtIndex:index]];
        nav.navigationBar.tintColor = [waSkin barTint];
        [waSkin styleNavigationBar:nav.navigationBar];
        UITabBarItem *item = [[UITabBarItem alloc] initWithTitle:[titles objectAtIndex:index]
                                                          image:[UIImage imageNamed:[icons objectAtIndex:index]]
                                                            tag:(NSInteger)index];
        item.titlePositionAdjustment = UIOffsetMake(0, 0);
        item.imageInsets = UIEdgeInsetsMake(1.0, 0.0, -1.0, 0.0);
        nav.tabBarItem = item;
        nav.delegate = self;
        [navs addObject:nav];
    }
    self.viewControllers = navs;
    self.controllers = navs;

    self.miniBar = [[waMiniPlayerBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44.0)];
    self.miniBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.miniBar.hidden = YES;
    [self.view addSubview:self.miniBar];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerChanged:) name:waPlayerStateDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerChanged:) name:waPlayerTrackDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerChanged:) name:waPlayerQueueDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloaderChanged:) name:waDownloaderDidChangeNotification object:nil];
    [self layoutMiniBar];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshDownloadBadge];
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshMiniPlayer];
}

- (void)dealloc {
    if (waLiveRoot == self) waLiveRoot = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutMiniBar];
}

- (CGFloat)miniPlayerHeight {
    return waMiniPlayerCoverHeight;
}

+ (CGFloat)miniPlayerCoverHeight {
    return waMiniPlayerCoverHeight;
}

- (void)applyMiniPlayerInsetsToView:(UIView *)view {
    if (!view) return;
    CGFloat height = [self miniPlayerHeight];
    [self applyMiniInset:height toView:view];
}

- (void)applyMiniInset:(CGFloat)height toView:(UIView *)view {
    if ([view isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scroll = (UIScrollView *)view;
        if (CGRectGetHeight(scroll.bounds) >= 160.0) {
            UIView *parent = scroll.superview;
            BOOL fillsParent = !parent || (CGRectGetMaxY(scroll.frame) >= CGRectGetHeight(parent.bounds) - 20.0);
            if (fillsParent) {
                UIEdgeInsets inset = scroll.contentInset;
                if (fabs(inset.bottom - height) > 0.5) {
                    inset.bottom = height;
                    scroll.contentInset = inset;
                    scroll.scrollIndicatorInsets = inset;
                }
            }
        }
    }
    for (UIView *subview in view.subviews) [self applyMiniInset:height toView:subview];
}

- (void)layoutMiniBar {
    CGRect tabRect = self.tabBar.frame;
    if (CGRectGetHeight(tabRect) < 1.0) return;
    BOOL show = !self.miniBar.hidden;
    CGFloat previous = waMiniPlayerCoverHeight;
    waMiniPlayerCoverHeight = show ? 44.0 : 0.0;
    if (show) {
        self.miniBar.frame = CGRectMake(0.0, CGRectGetMinY(tabRect) - 44.0, CGRectGetWidth(self.view.bounds), 44.0);
        [self.view bringSubviewToFront:self.miniBar];
    }
    [self.view bringSubviewToFront:self.tabBar];
    UIViewController *top = self.selectedViewController;
    if ([top isKindOfClass:[UINavigationController class]]) top = ((UINavigationController *)top).topViewController;
    if (top.isViewLoaded) {
        [self applyMiniPlayerInsetsToView:top.view];
        [top.view setNeedsLayout];
        [top.view layoutIfNeeded];
    }
    if (fabs(previous - waMiniPlayerCoverHeight) > 0.5) {
        [[NSNotificationCenter defaultCenter] postNotificationName:waMiniPlayerLayoutDidChangeNotification object:self];
    }
}

- (void)playerChanged:(NSNotification *)notification {
    (void)notification;
    [self refreshMiniPlayer];
}

- (void)downloaderChanged:(NSNotification *)notification {
    if ([[notification.userInfo objectForKey:@"progress"] boolValue]) return;
    [self refreshDownloadBadge];
}

- (void)refreshDownloadBadge {
    if (self.viewControllers.count < 3) return;
    UIViewController *library = [self.viewControllers objectAtIndex:2];
    NSUInteger pending = [[waDownloader shared] pendingCount];
    library.tabBarItem.badgeValue = pending ? [NSString stringWithFormat:@"%lu", (unsigned long)pending] : nil;
}

- (void)refreshMiniPlayer {
    waPlayer *player = [waPlayer shared];
    waTrack *track = player.currentTrack;
    BOOL visible = track != nil;
    BOOL wasHidden = self.miniBar.hidden;
    self.miniBar.hidden = !visible;
    if (visible) {
        self.miniBar.titleLabel.text = track.title;
        self.miniBar.subtitleLabel.text = track.artistName;
        NSString *local = [[waSession shared] localArtworkPathForTrack:track];
        NSString *art = local.length ? local : ([track artworkURLForSide:40.0] ?: player.contextArtworkURL);
        if (![self.miniBar.artworkKey isEqualToString:art]) {
            self.miniBar.artworkKey = [art copy];
            self.miniBar.artworkView.image = [[waSession shared] cachedArtwork:art size:CGSizeMake(40, 40)];
            if (!self.miniBar.artworkView.image && art.length) {
                __weak waMiniPlayerBar *bar = self.miniBar;
                NSString *url = [art copy];
                [[waSession shared] loadArtwork:url size:CGSizeMake(40, 40) owner:bar completion:^(UIImage *image) {
                    if ([bar.artworkKey isEqualToString:url]) bar.artworkView.image = image;
                }];
            }
        }
        [self.miniBar setPlaying:player.playing];
    }
    [self layoutMiniBar];
    if (wasHidden != self.miniBar.hidden) [self.view setNeedsLayout];
}

- (void)tabBarController:(UITabBarController *)tabBarController didSelectViewController:(UIViewController *)viewController {
    (void)tabBarController; (void)viewController;
    [self layoutMiniBar];
}

- (void)navigationController:(UINavigationController *)navigationController didShowViewController:(UIViewController *)viewController animated:(BOOL)animated {
    (void)navigationController; (void)viewController; (void)animated;
    [self layoutMiniBar];
}

- (BOOL)tabBarController:(UITabBarController *)tabBarController shouldSelectViewController:(UIViewController *)viewController {
    (void)tabBarController; (void)viewController;
    return YES;
}

- (void)showPlayer {
    if (self.modalViewController) return;
    waPlayerController *controller = [[waPlayerController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
    nav.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    nav.navigationBar.barStyle = UIBarStyleBlack;
    nav.navigationBar.translucent = NO;
    nav.navigationBar.tintColor = nil;
    [nav.navigationBar setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
    [nav.navigationBar setBackgroundImage:nil forBarMetrics:UIBarMetricsLandscapePhone];
    self.player = controller;
    [self presentModalViewController:nav animated:YES];
}

- (void)hidePlayer {
    self.player = nil;
    if (self.modalViewController) [self dismissModalViewControllerAnimated:YES];
}

@end

@interface waMiniPlayerBar ()
@property (nonatomic, strong) UIButton *infoButton;
@property (nonatomic, strong) UIBarButtonItem *playItem;
@property (nonatomic, strong) UIBarButtonItem *nextItem;
@property (nonatomic, assign) BOOL playing;
@end

@implementation waMiniPlayerBar

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.barStyle = UIBarStyleBlack;
        self.translucent = NO;

        _infoButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [_infoButton addTarget:self action:@selector(openPlayer:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_infoButton];

        _artworkView = [[UIImageView alloc] initWithFrame:CGRectMake(8.0, 6.0, 32.0, 32.0)];
        _artworkView.clipsToBounds = YES;
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.opaque = YES;
        _artworkView.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1.0];
        _artworkView.userInteractionEnabled = NO;
        [_infoButton addSubview:_artworkView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.backgroundColor = [UIColor clearColor];
        _titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        _titleLabel.numberOfLines = 1;
        _titleLabel.userInteractionEnabled = NO;
        [_infoButton addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subtitleLabel.backgroundColor = [UIColor clearColor];
        _subtitleLabel.font = [UIFont systemFontOfSize:11.0];
        _subtitleLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
        _subtitleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        _subtitleLabel.numberOfLines = 1;
        _subtitleLabel.userInteractionEnabled = NO;
        [_infoButton addSubview:_subtitleLabel];

        self.playItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemPlay target:self action:@selector(toggle:)];
        self.nextItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFastForward target:self action:@selector(next:)];
        [self rebuildItems];
    }
    return self;
}

- (void)rebuildItems {
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.items = [NSArray arrayWithObjects:flex, self.playItem, self.nextItem, nil];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat controls = 96.0;
    self.infoButton.frame = CGRectMake(0.0, 0.0, MAX(80.0, width - controls), height);
    self.artworkView.frame = CGRectMake(8.0, 6.0, 32.0, 32.0);
    CGFloat textX = 48.0;
    CGFloat textW = CGRectGetWidth(self.infoButton.bounds) - textX - 6.0;
    if (textW < 40.0) textW = 40.0;
    self.titleLabel.frame = CGRectMake(textX, 5.0, textW, 18.0);
    self.subtitleLabel.frame = CGRectMake(textX, 22.0, textW, 16.0);
    [self bringSubviewToFront:self.infoButton];
}

- (void)setPlaying:(BOOL)playing {
    if (_playing == playing && self.playItem) return;
    _playing = playing;
    UIBarButtonSystemItem kind = playing ? UIBarButtonSystemItemPause : UIBarButtonSystemItemPlay;
    self.playItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:kind target:self action:@selector(toggle:)];
    [self rebuildItems];
}

- (void)toggle:(id)sender {
    (void)sender;
    [[waPlayer shared] toggle];
}

- (void)next:(id)sender {
    (void)sender;
    [[waPlayer shared] playNext];
}

- (void)openPlayer:(id)sender {
    (void)sender;
    UIResponder *responder = self.nextResponder;
    while (responder) {
        if ([responder isKindOfClass:[waRootController class]]) {
            [(waRootController *)responder showPlayer];
            return;
        }
        responder = responder.nextResponder;
    }
}

@end
