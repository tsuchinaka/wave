#import "waTableController.h"
#import "waSkin.h"
#import "waCell.h"
#import "../Core/waSession.h"
#import "../Core/waPlayer.h"
#import "../Core/waDownloader.h"
#import "../Core/waLog.h"
#import "waDetailController.h"
#import "waPlayerController.h"
#import "waQueueController.h"
#import "waLyricsController.h"
#import "waLoginController.h"
#import "waPlaylistEditController.h"
#import "waRootController.h"
#import <objc/runtime.h>

@interface waPaddedView : UIView
@property (nonatomic, assign) CGFloat bottomPad;
@end

@implementation waPaddedView
- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *wrap = [self viewWithTag:9043];
    if (!wrap) return;
    wrap.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    CGRect bounds = self.bounds;
    CGFloat pad = [waRootController miniPlayerCoverHeight];
    self.bottomPad = pad;
    CGFloat height = CGRectGetHeight(bounds) - pad;
    if (height < 1.0) height = 1.0;
    wrap.frame = CGRectMake(0.0, 0.0, CGRectGetWidth(bounds), height);
}
@end

@interface waTableController () <UIActionSheetDelegate>
@property (nonatomic, strong) UIView *stateView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation waTableController

- (id)initWithGroupedStyle:(BOOL)grouped {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _grouped = grouped;
    }
    return self;
}

- (void)loadView {
    CGRect frame = [[UIScreen mainScreen] bounds];
    waPaddedView *root = [[waPaddedView alloc] initWithFrame:frame];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.backgroundColor = self.grouped ? [UIColor groupTableViewBackgroundColor] : [UIColor whiteColor];
    self.view = root;

    UIView *wrap = [[UIView alloc] initWithFrame:frame];
    wrap.tag = 9043;
    wrap.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    wrap.backgroundColor = [UIColor clearColor];
    [root addSubview:wrap];

    UITableView *table = [[UITableView alloc] initWithFrame:wrap.bounds
                                                      style:self.grouped ? UITableViewStyleGrouped : UITableViewStylePlain];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = self;
    table.delegate = self;
    table.backgroundColor = self.grouped ? [UIColor groupTableViewBackgroundColor] : [UIColor whiteColor];
    table.separatorColor = [UIColor lightGrayColor];
    table.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView = table;
    [wrap addSubview:table];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.center = CGPointMake(frame.size.width / 2.0, frame.size.height / 2.0);
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [root addSubview:self.spinner];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if (!self.title.length) self.title = @"";
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (bar) {
        bar.barStyle = UIBarStyleDefault;
        bar.translucent = NO;
        bar.tintColor = nil;
        [bar setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyMiniPlayerLayout) name:waMiniPlayerLayoutDidChangeNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [[waRootController shared] refreshMiniPlayer];
}

- (void)applyMiniPlayerLayout {
    if (!self.isViewLoaded) return;
    [self.view setNeedsLayout];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)reload {
    [self.tableView reloadData];
}

- (void)setLoading:(BOOL)loading {
    if (loading) {
        [self clearStateView];
        self.tableView.backgroundView = nil;
        self.state = waPageStateLoading;
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }
}

- (void)clearStateView {
    [self.stateView removeFromSuperview];
    self.stateView = nil;
}

- (void)showEmpty:(NSString *)title message:(NSString *)message {
    [self clearStateView];
    self.state = waPageStateEmpty;
    self.emptyTitle = title;
    self.emptyMessage = message;
    waEmptyState *empty = [[waEmptyState alloc] initWithTitle:title message:message];
    empty.frame = self.tableView.bounds;
    empty.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    empty.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = empty;
    self.stateView = empty;
    [self.tableView reloadData];
}

- (void)showError:(NSError *)error retry:(SEL)retry {
    self.state = waPageStateError;
    [self showEmpty:@"Cannot Load" message:error.localizedDescription.length ? error.localizedDescription : @"Check your connection and try again."];
    if (retry && [self respondsToSelector:retry]) {
        UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"Retry"
                                                                 style:UIBarButtonItemStyleBordered
                                                                target:self
                                                                action:retry];
        self.navigationItem.rightBarButtonItem = item;
    }
}

#pragma mark - table defaults

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return 0; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)indexPath;
    return [waCell cellForTable:tableView];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

#pragma mark - navigation helpers

- (void)pushTrackList:(NSArray *)tracks title:(NSString *)title start:(NSUInteger)index {
    if (!tracks.count) return;
    [[waSession shared] playTracks:tracks startAt:index context:title];
    [[waRootController shared] showPlayer];
}

- (void)pushAlbum:(waAlbum *)album {
    if (!album.identifier.length) return;
    waDetailController *detail = [[waDetailController alloc] initWithAlbum:album];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)pushArtist:(waArtist *)artist {
    if (!artist.identifier.length) return;
    waDetailController *detail = [[waDetailController alloc] initWithArtist:artist];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)pushPlaylist:(waPlaylist *)playlist {
    if (!playlist.identifier.length) return;
    waDetailController *detail = [[waDetailController alloc] initWithPlaylist:playlist];
    [self.navigationController pushViewController:detail animated:YES];
}

#pragma mark - track actions (UIActionSheet, iOS 5 pattern)

- (void)presentActionsForTrack:(waTrack *)track {
    if (!track) return;
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:track.title
                                                       delegate:self
                                              cancelButtonTitle:@"Cancel"
                                         destructiveButtonTitle:nil
                                              otherButtonTitles:@"Play", @"Play Next", @"Like", @"Add to Playlist", @"Download", @"Share", nil];
    sheet.tag = 7001;
    objc_setAssociatedObject(sheet, "waTrack", track, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (sheet.tag != 7001) return;
    waTrack *track = objc_getAssociatedObject(sheet, "waTrack");
    if (!track) return;
    if (buttonIndex == 0) {
        [[waSession shared] playTrack:track];
        [[waRootController shared] showPlayer];
    } else if (buttonIndex == 1) {
        [[waPlayer shared] appendTracks:[NSArray arrayWithObject:track] next:YES];
    } else if (buttonIndex == 2) {
        [[waSession shared] setLiked:!track.liked track:track completion:^(BOOL ok, NSError *error) {
            if (!ok) {
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Like"
                                                                message:error.localizedDescription
                                                               delegate:nil
                                                      cancelButtonTitle:@"OK"
                                                      otherButtonTitles:nil];
                [alert show];
            }
        }];
    } else if (buttonIndex == 3) {
        [self presentPlaylistPickerForTrack:track];
    } else if (buttonIndex == 4) {
        [[waDownloader shared] enqueueTrack:track quality:[[waSession shared] downloadQuality]];
    } else if (buttonIndex == 5) {
        [self presentShareForItem:track];
    }
}

- (void)presentPlaylistPickerForTrack:(waTrack *)track {
    waPlaylistEditController *editor = [[waPlaylistEditController alloc] initWithTrack:track];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
    nav.navigationBar.barStyle = UIBarStyleDefault;
    nav.navigationBar.translucent = NO;
    [self presentModalViewController:nav animated:YES];
}

- (void)presentShareForItem:(waItem *)item {
    NSString *link = nil;
    if ([item.kind isEqualToString:waTrackType]) link = [NSString stringWithFormat:@"https://www.deezer.com/track/%@", item.identifier];
    else if ([item.kind isEqualToString:waAlbumType]) link = [NSString stringWithFormat:@"https://www.deezer.com/album/%@", item.identifier];
    else if ([item.kind isEqualToString:waArtistType]) link = [NSString stringWithFormat:@"https://www.deezer.com/artist/%@", item.identifier];
    else if ([item.kind isEqualToString:waPlaylistType]) link = [NSString stringWithFormat:@"https://www.deezer.com/playlist/%@", item.identifier];
    if (!link.length) return;
    [[UIPasteboard generalPasteboard] setString:link];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Link Copied"
                                                    message:link
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
}

@end

@implementation waArtworkHeader

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        _artworkView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _artworkView.contentMode = UIViewContentModeScaleAspectFill;
        _artworkView.clipsToBounds = YES;
        _artworkView.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        [self addSubview:_artworkView];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.backgroundColor = [UIColor clearColor];
        _titleLabel.font = [UIFont boldSystemFontOfSize:17.0];
        _titleLabel.textColor = [UIColor blackColor];
        _titleLabel.textAlignment = UITextAlignmentCenter;
        _titleLabel.numberOfLines = 2;
        _titleLabel.lineBreakMode = UILineBreakModeTailTruncation;
        [self addSubview:_titleLabel];
        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subtitleLabel.backgroundColor = [UIColor clearColor];
        _subtitleLabel.font = [UIFont systemFontOfSize:13.0];
        _subtitleLabel.textColor = [UIColor grayColor];
        _subtitleLabel.textAlignment = UITextAlignmentCenter;
        [self addSubview:_subtitleLabel];
        _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _detailLabel.backgroundColor = [UIColor clearColor];
        _detailLabel.font = [UIFont systemFontOfSize:13.0];
        _detailLabel.textColor = [UIColor grayColor];
        _detailLabel.textAlignment = UITextAlignmentCenter;
        [self addSubview:_detailLabel];
    }
    return self;
}

- (CGFloat)layoutForWidth:(CGFloat)width {
    CGFloat art = width - 80.0;
    if (art > 160.0) art = 160.0;
    if (art < 120.0) art = 120.0;
    self.artworkView.frame = CGRectMake((width - art) / 2.0, 12.0, art, art);
    CGFloat y = CGRectGetMaxY(self.artworkView.frame) + 10.0;
    self.titleLabel.frame = CGRectMake(12.0, y, width - 24.0, 42.0);
    y += 42.0;
    self.subtitleLabel.frame = CGRectMake(12.0, y, width - 24.0, 18.0);
    y += 18.0;
    self.detailLabel.frame = CGRectMake(12.0, y, width - 24.0, 18.0);
    return y + 18.0 + 8.0;
}

@end

@implementation waActionGrid

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _buttons = [NSArray array];
    }
    return self;
}

- (void)addActionWithTitle:(NSString *)title target:(id)target action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeRoundedRect];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:14.0];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:button];
    NSMutableArray *all = [NSMutableArray arrayWithArray:self.buttons];
    [all addObject:button];
    _buttons = [all copy];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    NSUInteger count = self.buttons.count;
    if (!count) return;
    CGFloat gap = 8.0;
    CGFloat buttonWidth = (w - gap * (count - 1)) / (CGFloat)count;
    NSUInteger i = 0;
    for (UIButton *button in self.buttons) {
        button.frame = CGRectMake(i * (buttonWidth + gap), 0.0, buttonWidth, h);
        i++;
    }
}

@end
