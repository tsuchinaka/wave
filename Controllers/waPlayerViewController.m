#import "waPlayerViewController.h"
#import "../Views/waPlaceholder.h"
#import "../Services/waTheme.h"
#import "../Services/waAudioPlayer.h"
#import "../Services/waDownloadManager.h"
#import "../Services/waAPIClient.h"
#import "../Views/waMediaActionSheet.h"
#import "../Services/waImageLoader.h"
#import "waQueueViewController.h"
#import "waLyricsViewController.h"
#import "../Audio/waAudioEngine.h"
#import "../Models/waPreferences.h"
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVAudioSession.h>
#import <objc/runtime.h>

static UIColor *waPlayerChromeColor(void) {
    // Fixed near-black chrome (toolbar + info panel), Hype Machine style.
    // Deliberately not themed: the dark panel is the look.
    return [UIColor colorWithWhite:0.10 alpha:1.0];
}

static UIColor *waPlayerSoftTextColor(void) {
    return [UIColor colorWithWhite:0.62 alpha:1.0];
}

static UIColor *waPlayerIconColor(void) {
    return [UIColor colorWithWhite:0.88 alpha:1.0];
}

static UIImage *waSizedImage(UIImage *image, CGSize size) {
    if (!image) return nil;
    // Render at the device's native scale. The lyrics artwork is a 60px
    // source used at 30pt, and using image.scale here produced a 30px bitmap
    // that Retina devices had to enlarge again.
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    [image drawInRect:CGRectMake(0.0, 0.0, size.width, size.height)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

static UIImage *waLyricsImage(UIColor *color) {
    return waSizedImage([waTheme tintedIcon:[UIImage imageNamed:@"icons-wave/wave-lyrics"] withColor:color], CGSizeMake(24.0, 24.0));
}

@interface waPlayerViewController ()
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, copy) NSString *navSongText;
@property (nonatomic, copy) NSString *navArtistText;
@property (nonatomic, strong) UIView *titleView;
@property (nonatomic, strong) UILabel *titleSongLabel;
@property (nonatomic, strong) UILabel *titleArtistLabel;
@property (nonatomic, strong) UILabel *qualityLabel;
@property (nonatomic, strong) UILabel *explicitIconLabel;
@property (nonatomic, strong) UIButton *likeButton;
@property (nonatomic, strong) UIButton *lyricsButton;
@property (nonatomic, strong) UIButton *moreButton;
@property (nonatomic, strong) UIProgressView *downloadQualityProgressView;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *durationLabel;
@property (nonatomic, strong) UISlider *progressSlider;
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *nextUpButton;
@property (nonatomic, strong) UIView *infoPanel;
@property (nonatomic, strong) UIView *seekOverlay;
@property (nonatomic, strong) NSTimer *overlayHideTimer;
@property (nonatomic, strong) MPVolumeView *airplayView;
@property (nonatomic, strong) UIButton *airplayButton;
@property (nonatomic, strong) UIActivityIndicatorView *loadingSpinner;
@property (nonatomic, strong) UIView *loadingBackdrop;
@property (nonatomic, strong) NSTimer *updateTimer;
@property (nonatomic, copy) NSString *loadedArtworkURL;
@property (nonatomic, assign) unsigned long artworkGeneration;
@end

static void waUnhideRouteButtonsInView(UIView *view) {
    for (UIView *subview in view.subviews) {
        // MPVolumeView hides the route button two ways: hidden=YES and
        // alpha=0 (no wireless routes). Clear both.
        if ([subview isKindOfClass:[UIButton class]]) { subview.hidden = NO; subview.alpha = 1.0; }
        waUnhideRouteButtonsInView(subview);
    }
}

static UIButton *waFirstRouteButtonInView(UIView *view) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UIButton class]]) return (UIButton *)subview;
        UIButton *nested = waFirstRouteButtonInView(subview);
        if (nested) return nested;
    }
    return nil;
}

// MPVolumeView re-hides its route button in its own layout pass, which the
// nav bar runs after our viewDidLayoutSubviews — win the race permanently
// by unhiding after every internal layout instead of once per runloop.
@interface waAirPlayVolumeView : MPVolumeView
@end

@implementation waAirPlayVolumeView

- (void)layoutSubviews {
    [super layoutSubviews];
    waUnhideRouteButtonsInView(self);
    UIButton *route = waFirstRouteButtonInView(self);
    if (route && (route.bounds.size.width <= 0.0 || route.bounds.size.height <= 0.0)) {
        CGSize imageSize = route.currentImage.size;
        if (imageSize.width <= 0.0 || imageSize.height <= 0.0) imageSize = CGSizeMake(24.0, 18.0);
        route.frame = CGRectMake((self.bounds.size.width - imageSize.width) / 2.0,
                                 (self.bounds.size.height - imageSize.height) / 2.0,
                                 imageSize.width, imageSize.height);
    }
}

@end

@implementation waPlayerViewController

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation { (void)orientation; return YES; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Now Playing";
    self.view.backgroundColor = [waTheme backgroundColor];
    self.navigationController.view.backgroundColor = [waTheme backgroundColor];
    [waTheme applyToView:self.navigationController.navigationBar];
    // Hype Machine style: visible bar, artist as title, native Back.
    // AirPlay takes the right slot (set where it is created below).
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Back" style:UIBarButtonItemStyleBordered target:self action:@selector(closePlayer:)];
    // Original two-line stacked title (song over artist): the SDK has no
    // native title+subtitle API for nav bars (only prompt, which doubles
    // the bar height), so this custom 190x44 titleView is the look.
    self.titleView = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 190.0, 44.0)];

    self.titleView.backgroundColor = [UIColor clearColor];
    // Fixed size, assigned once: the bar owns centering. Flexible margins
    // keep it centered if the bar resizes (e.g. 32pt landscape bar).
    // Never reset frame or re-assign titleView elsewhere — that fights
    // the bar's own layout pass and the title visibly drifts/jumps.
    self.titleView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.titleSongLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 5.0, 190.0, 19.0)];
    self.titleSongLabel.font = [waTheme boldFontOfSize:14.0];
    self.titleSongLabel.textColor = [UIColor whiteColor];
    if (![waTheme isModernSystem]) {
        self.titleSongLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.5];
        self.titleSongLabel.shadowOffset = CGSizeMake(0.0, -1.0);
    }
    self.titleSongLabel.textAlignment = NSTextAlignmentCenter;
    self.titleSongLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.titleSongLabel.backgroundColor = [UIColor clearColor];
    [self.titleView addSubview:self.titleSongLabel];
    self.titleArtistLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 24.0, 190.0, 15.0)];
    self.titleArtistLabel.font = [waTheme regularFontOfSize:11.0];
    self.titleArtistLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    if (![waTheme isModernSystem]) {
        self.titleArtistLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.5];
        self.titleArtistLabel.shadowOffset = CGSizeMake(0.0, -1.0);
    }
    self.titleArtistLabel.textAlignment = NSTextAlignmentCenter;
    self.titleArtistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.titleArtistLabel.backgroundColor = [UIColor clearColor];
    [self.titleView addSubview:self.titleArtistLabel];
    self.navigationItem.titleView = self.titleView;

    self.contentView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.contentView.backgroundColor = waPlayerChromeColor();
    [self.view addSubview:self.contentView];

    // Dark info panel under the artwork (next-up + title + artist).
    self.infoPanel = [[UIView alloc] initWithFrame:CGRectZero];
    self.infoPanel.backgroundColor = waPlayerChromeColor();
    [self.contentView addSubview:self.infoPanel];

    self.artworkView = [[UIImageView alloc] initWithImage:waPlaceholderImage()];
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.userInteractionEnabled = YES;
    self.artworkView.isAccessibilityElement = YES;
    self.artworkView.accessibilityLabel = @"Album artwork, double-tap to toggle seek bar";
    UITapGestureRecognizer *artTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(artworkTapped:)];
    [self.artworkView addGestureRecognizer:artTap];
    // Full-bleed edge-to-edge artwork (native Music.app style): no frame,
    // no rounded corners.
    self.artworkView.layer.cornerRadius = 0.0;
    self.artworkView.layer.masksToBounds = YES;
    self.artworkView.layer.borderWidth = 0.0;
    [self.contentView addSubview:self.artworkView];

    self.loadingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    self.loadingSpinner.hidesWhenStopped = YES;
    self.loadingBackdrop = [waTheme circularBackdropForSpinner:self.loadingSpinner];
    self.loadingBackdrop.hidden = YES;
    [self.contentView addSubview:self.loadingBackdrop];
    [self.contentView bringSubviewToFront:self.loadingBackdrop];

    // "Next: <song> ›" context row (Hype Machine style): opens the Queue.
    self.nextUpButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.nextUpButton.titleLabel.font = [waTheme secondaryMediumFontOfSize:13.0];
    [self.nextUpButton setTitleColor:waPlayerSoftTextColor() forState:UIControlStateNormal];
    [self.nextUpButton setTitleColor:[waTheme barColor] forState:UIControlStateHighlighted];
    self.nextUpButton.backgroundColor = [UIColor clearColor];
    self.nextUpButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.nextUpButton.accessibilityLabel = @"Next up, open queue";
    [self.nextUpButton addTarget:self action:@selector(showQueue:) forControlEvents:UIControlEventTouchUpInside];
    [self.infoPanel addSubview:self.nextUpButton];

    self.qualityLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.qualityLabel.textAlignment = NSTextAlignmentRight;
    self.qualityLabel.font = [waTheme secondaryBoldFontOfSize:10.0];
    self.qualityLabel.textColor = waPlayerSoftTextColor();
    self.qualityLabel.backgroundColor = [UIColor clearColor];
    [self.infoPanel addSubview:self.qualityLabel];
    // Explicit: system glyph instead of Deezer font "z"
    UIImage *expBase = [UIImage imageNamed:@"explicit-glyph-small"];
    if (expBase) {
        UIImageView *expView = [[UIImageView alloc] initWithImage:[waTheme tintedIcon:expBase withColor:[UIColor whiteColor]]];
        expView.contentMode = UIViewContentModeScaleAspectFit;
        expView.backgroundColor = [UIColor clearColor];
        expView.accessibilityLabel = @"Explicit content";
        expView.hidden = YES;
        objc_setAssociatedObject(self, "waExplicitImageView", expView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.infoPanel addSubview:expView];
    }
    self.explicitIconLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.explicitIconLabel.text = @"z";
    self.explicitIconLabel.font = [UIFont fontWithName:@"Deezer-Font-Icon" size:14.0] ?: [waTheme boldFontOfSize:9.0];
    self.explicitIconLabel.textColor = [UIColor whiteColor];
    self.explicitIconLabel.textAlignment = NSTextAlignmentCenter;
    self.explicitIconLabel.backgroundColor = [UIColor clearColor];
    self.explicitIconLabel.accessibilityLabel = @"Explicit content";
    self.explicitIconLabel.hidden = YES;
    [self.infoPanel addSubview:self.explicitIconLabel];

    // Seek overlay: tap the artwork to reveal the seek bar over the art.
    self.seekOverlay = [[UIView alloc] initWithFrame:CGRectZero];
    self.seekOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
    self.seekOverlay.hidden = YES;
    [self.contentView addSubview:self.seekOverlay];

    self.progressSlider = [[UISlider alloc] init];
    self.progressSlider.minimumTrackTintColor = [waTheme barColor];
    self.progressSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    if (![waTheme isModernSystem]) self.progressSlider.thumbTintColor = [waTheme barColor];
    // Seek commits on release only (Book 25:665 — continuous=NO reports
    // Value Changed when the thumb is released, not while dragging).
    self.progressSlider.continuous = NO;
    [self.progressSlider addTarget:self action:@selector(progressChanged:) forControlEvents:UIControlEventValueChanged];
    [self.seekOverlay addSubview:self.progressSlider];

    self.elapsedLabel = [[UILabel alloc] init];
    self.elapsedLabel.text = @"0:00";
    self.elapsedLabel.font = [waTheme secondaryRegularFontOfSize:12.0];
    self.elapsedLabel.textColor = [UIColor whiteColor];
    self.elapsedLabel.backgroundColor = [UIColor clearColor];
    [self.seekOverlay addSubview:self.elapsedLabel];

    self.durationLabel = [[UILabel alloc] init];
    self.durationLabel.text = @"0:00";
    self.durationLabel.font = [waTheme secondaryRegularFontOfSize:12.0];
    self.durationLabel.textColor = [UIColor whiteColor];
    self.durationLabel.textAlignment = NSTextAlignmentRight;
    self.durationLabel.backgroundColor = [UIColor clearColor];
    [self.seekOverlay addSubview:self.durationLabel];

    // Transport row: prev | PLAY | next (Deezer artwork). Shuffle/repeat live in Queue only.
    self.previousButton = [self controlButtonWithTitle:nil];
    self.previousButton.adjustsImageWhenHighlighted = NO;
    [self.previousButton setImage:[UIImage imageNamed:@"Player_Previous_Normal"] forState:UIControlStateNormal];
    [self.previousButton setImage:[UIImage imageNamed:@"Player_Previous_Highlighted"] forState:UIControlStateHighlighted];
    self.previousButton.accessibilityLabel = @"Previous track";
    [self.previousButton addTarget:self action:@selector(previous:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.previousButton];

    self.playButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.playButton.adjustsImageWhenHighlighted = NO;
    self.playButton.accessibilityLabel = @"Play or pause";
    [self.playButton addTarget:self action:@selector(togglePlayback:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.playButton];

    self.nextButton = [self controlButtonWithTitle:nil];
    self.nextButton.adjustsImageWhenHighlighted = NO;
    [self.nextButton setImage:[UIImage imageNamed:@"Player_Next_Normal"] forState:UIControlStateNormal];
    [self.nextButton setImage:[UIImage imageNamed:@"Player_Next_Highlighted"] forState:UIControlStateHighlighted];
    self.nextButton.accessibilityLabel = @"Next track";
    [self.nextButton addTarget:self action:@selector(next:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.nextButton];

    // Transport companions: lyrics + like live in the transport row now.
    // Queue is redundant (the Next-up row opens it); AirPlay is a nav item.
    self.lyricsButton = [self controlButtonWithTitle:nil];
    [self.lyricsButton setImage:waLyricsImage(waPlayerIconColor()) forState:UIControlStateNormal];
    self.lyricsButton.accessibilityLabel = @"Lyrics";
    [self.lyricsButton addTarget:self action:@selector(lyricsPressed:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.lyricsButton];

    self.likeButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.likeButton.accessibilityLabel = @"Like song";
    self.likeButton.adjustsImageWhenHighlighted = YES;
    self.likeButton.hidden = YES;
    [self.likeButton setImage:[waTheme tintedIcon:[UIImage imageNamed:@"wave-love"] withColor:waPlayerIconColor()] forState:UIControlStateNormal];
    [self.likeButton setImage:[waTheme tintedIcon:[UIImage imageNamed:@"wave-love"] withColor:[waTheme likeSelectedColor]] forState:UIControlStateSelected];
    [self.likeButton addTarget:self action:@selector(likePressed:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.likeButton];

    self.moreButton = [self controlButtonWithTitle:nil];
    self.moreButton.adjustsImageWhenHighlighted = NO;
    // Use ellipsis as More glyph (no asset needed) — white normal, barColor hover
    [self.moreButton setTitle:@"⋯" forState:UIControlStateNormal];
    self.moreButton.titleLabel.font = [waTheme boldFontOfSize:24.0];
    [self.moreButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.moreButton setTitleColor:[waTheme barColor] forState:UIControlStateHighlighted];
    self.moreButton.accessibilityLabel = @"More options";
    [self.moreButton addTarget:self action:@selector(morePressed:) forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.moreButton];

    self.downloadQualityProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
    self.downloadQualityProgressView.progressTintColor = [waTheme barColor];
    self.downloadQualityProgressView.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    self.downloadQualityProgressView.hidden = YES;
    self.downloadQualityProgressView.progress = 0.0f;
    [self.infoPanel addSubview:self.downloadQualityProgressView];

    // Route-only AirPlay picker lives in the nav bar, right of the title.
    // Plan B: our own button, always visible even with no devices around.
    // A hidden MPVolumeView stays in the hierarchy purely as the picker
    // trigger — taps are forwarded to its internal route button.
    UIView *airplayContainer = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 40.0, 32.0)];
    self.airplayView = [[waAirPlayVolumeView alloc] initWithFrame:airplayContainer.bounds];
    self.airplayView.showsVolumeSlider = NO;
    self.airplayView.showsRouteButton = YES;
    self.airplayView.alpha = 0.0;
    self.airplayView.userInteractionEnabled = NO;
    [airplayContainer addSubview:self.airplayView];
    self.airplayButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.airplayButton.frame = airplayContainer.bounds;
    self.airplayButton.adjustsImageWhenHighlighted = YES;
    self.airplayButton.accessibilityLabel = @"AirPlay";
    [self.airplayButton addTarget:self action:@selector(airplayPressed:) forControlEvents:UIControlEventTouchUpInside];
    [airplayContainer addSubview:self.airplayButton];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:airplayContainer];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerDidChange:) name:waAudioPlayerDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerDidChange:) name:waAudioEngineStateDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerDidFail:) name:waAudioEngineDidFailNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeDidChange:) name:waThemeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(audioRouteDidChange:) name:AVAudioSessionRouteChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(downloadDidChange:) name:waDownloadManagerDidChangeNotification object:nil];
    [waTheme applyToView:self.view];
    [self applyThemeToControls];
    [self refreshPlayerUI];
}

- (void)unhideRouteButtonsInView:(UIView *)view {
    // MPVolumeView hides its route button when no wireless routes exist —
    // and re-hides it in its own layout pass, which runs after ours and
    // nests the button deeper than direct subviews.
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[UIButton class]]) subview.hidden = NO;
        [self unhideRouteButtonsInView:subview];
    }
}

- (void)unhideAirPlayNow {
    [self unhideRouteButtonsInView:self.airplayView];
}

- (void)forceAirPlayVisible {
    // Run now and once more on the next runloop: MPVolumeView.layoutSubviews
    // runs after our viewDidLayoutSubviews and would re-hide the button.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(unhideAirPlayNow) object:nil];
    [self unhideRouteButtonsInView:self.airplayView];
    [self performSelector:@selector(unhideAirPlayNow) withObject:nil afterDelay:0.0];
}

- (void)audioRouteDidChange:(NSNotification *)notification {
    (void)notification;
    [self forceAirPlayVisible];
    [self updateAirPlaySelection];
}

- (void)airplayPressed:(UIButton *)sender {
    (void)sender;
    // Forward to the hidden picker's route button (works with no routes too).
    UIButton *route = waFirstRouteButtonInView(self.airplayView);
    [route sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (void)updateAirPlaySelection {
    // Mirror the internal route button: selected = AirPlay route active.
    UIButton *route = waFirstRouteButtonInView(self.airplayView);
    self.airplayButton.selected = route ? route.selected : NO;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Navigation bar stays visible (Hype Machine style): artist as title.
    if (!self.updateTimer) self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateProgress:) userInfo:nil repeats:YES];
    [self refreshPlayerUI];
    [self forceAirPlayVisible];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.view setNeedsLayout];
    [self updateAirPlaySelection];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.updateTimer invalidate];
    self.updateTimer = nil;
    [self.overlayHideTimer invalidate];
    self.overlayHideTimer = nil;
}

- (void)artworkTapped:(UITapGestureRecognizer *)tap {
    (void)tap;
    [self.overlayHideTimer invalidate];
    self.overlayHideTimer = nil;
    self.seekOverlay.hidden = !self.seekOverlay.hidden;
}

- (void)showSeekOverlayTemporarily {
    // New track: reveal the seek bar briefly, then get out of the art's way.
    [self.overlayHideTimer invalidate];
    self.seekOverlay.hidden = NO;
    self.overlayHideTimer = [NSTimer scheduledTimerWithTimeInterval:4.0 target:self selector:@selector(hideSeekOverlay:) userInfo:nil repeats:NO];
}

- (void)hideSeekOverlay:(NSTimer *)timer {
    (void)timer;
    self.overlayHideTimer = nil;
    self.seekOverlay.hidden = YES;
}

- (void)themeDidChange:(NSNotification *)notification {
    (void)notification;
    self.view.backgroundColor = [waTheme backgroundColor];
    self.elapsedLabel.textColor = [UIColor whiteColor];
    self.durationLabel.textColor = [UIColor whiteColor];
    self.qualityLabel.textColor = waPlayerSoftTextColor();
    self.explicitIconLabel.textColor = [UIColor whiteColor];
    [self.nextUpButton setTitleColor:waPlayerSoftTextColor() forState:UIControlStateNormal];
    self.progressSlider.minimumTrackTintColor = [waTheme barColor];
    self.progressSlider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    if (![waTheme isModernSystem]) self.progressSlider.thumbTintColor = [waTheme barColor];
    else self.progressSlider.thumbTintColor = nil;
    self.progressSlider.continuous = NO;
    self.downloadQualityProgressView.progressTintColor = [waTheme barColor];
    [self.moreButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.moreButton setTitleColor:[waTheme barColor] forState:UIControlStateHighlighted];
    [self applyThemeToControls];
    [self refreshPlayerUI];
}
- (void)downloadDidChange:(NSNotification *)n {
    (void)n;
    if (!self.view.window) return;
    [self refreshPlayerUI];
}

- (void)applyThemeToControls {
    UIColor *icon = [UIColor whiteColor];
    UIColor *hover = [waTheme barColor];
    // White normal, barColor on hover — system glyphs tinted
    UIImage *prevBase = [UIImage imageNamed:@"SystemMediaControl-Rewind"];
    UIImage *nextBase = [UIImage imageNamed:@"SystemMediaControl-Forward"];
    [self.lyricsButton setImage:waLyricsImage(icon) forState:UIControlStateNormal];
    [self.lyricsButton setImage:waLyricsImage(hover) forState:UIControlStateHighlighted];
    [self.previousButton setImage:[waTheme tintedIcon:prevBase withColor:icon] forState:UIControlStateNormal];
    [self.previousButton setImage:[waTheme tintedIcon:prevBase withColor:hover] forState:UIControlStateHighlighted];
    [self.nextButton setImage:[waTheme tintedIcon:nextBase withColor:icon] forState:UIControlStateNormal];
    [self.nextButton setImage:[waTheme tintedIcon:nextBase withColor:hover] forState:UIControlStateHighlighted];
    [self updatePlayIcon];
    UIImage *airplayOff = waSizedImage([waTheme tintedIcon:[UIImage imageNamed:@"WaveAirPlayOff"] withColor:icon], CGSizeMake(24.0, 18.0));
    UIImage *airplayOn = waSizedImage([waTheme tintedIcon:[UIImage imageNamed:@"WaveAirPlayOn"] withColor:icon], CGSizeMake(24.0, 18.0));
    [self.airplayView setRouteButtonImage:airplayOff forState:UIControlStateNormal];
    [self.airplayView setRouteButtonImage:airplayOn forState:UIControlStateSelected];
    [self.airplayButton setImage:airplayOff forState:UIControlStateNormal];
    [self.airplayButton setImage:airplayOff forState:UIControlStateHighlighted];
    [self.airplayButton setImage:airplayOn forState:UIControlStateSelected];
    [self updateAirPlaySelection];
    // setRouteButtonImage triggers an internal layout that re-hides the
    // button when there are no routes — force it back.
    [self forceAirPlayVisible];
}

- (void)updatePlayIcon {
    BOOL playing = [waAudioEngine sharedEngine].isPlaying;
    UIImage *base = [UIImage imageNamed:playing ? @"SystemMediaControl-Pause" : @"SystemMediaControl-Play"];
    [self.playButton setImage:[waTheme tintedIcon:base withColor:[UIColor whiteColor]] forState:UIControlStateNormal];
    [self.playButton setImage:[waTheme tintedIcon:base withColor:[waTheme barColor]] forState:UIControlStateHighlighted];
}

- (UIButton *)controlButtonWithTitle:(NSString *)title {
    // Image-only transport controls should not paint a native button surface.
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = [UIColor clearColor];
    button.adjustsImageWhenHighlighted = YES;
    [button setTitle:title forState:UIControlStateNormal];
    return button;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self forceAirPlayVisible];
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    BOOL landscape = width > height;
    self.contentView.frame = self.view.bounds;

    // Hype Machine order: full-bleed art, dark info panel, compact
    // 5-icon transport. Panel children use container-local frames.
    CGFloat panelH = 54.0;
    CGFloat transportH = landscape ? 36.0 : 32.0;
    CGFloat gap = landscape ? 8.0 : 4.0;

    CGFloat panelX, panelWidth, controlsY;
    if (!landscape) {
        // Full-bleed art from under the nav bar; height is the leftover
        // minus a safety margin so the stack below can never clip.
        CGFloat artH = MIN(width, height - panelH - transportH - gap * 2.0 - 8.0);
        artH = MAX(120.0, artH);
        self.artworkView.frame = CGRectMake(0.0, 0.0, width, artH);
        self.infoPanel.frame = CGRectMake(0.0, artH, width, panelH);
        panelX = 12.0;
        panelWidth = width - 24.0;
        controlsY = artH + panelH + gap;
    } else {
        // Landscape: art takes all but a compact fixed side column.
        CGFloat sideW = 210.0;
        CGFloat artW = MIN(width - sideW, height);
        artW = MAX(0.0, artW);
        self.artworkView.frame = CGRectMake(0.0, 0.0, artW, height);
        CGFloat blockH = panelH + gap + transportH;
        CGFloat blockTop = MAX(0.0, (height - blockH) / 2.0);
        self.infoPanel.frame = CGRectMake(artW, blockTop, width - artW, panelH);
        panelX = artW + 8.0;
        panelWidth = width - artW - 16.0;
        controlsY = blockTop + panelH + gap;
    }
    self.loadingBackdrop.center = self.artworkView.center;
    [self.contentView bringSubviewToFront:self.loadingBackdrop];

    // Info panel inner (container-local): Next-up + quality only.
    // Song/artist live in the native nav title+prompt now (more room for art).
    CGFloat pw = self.infoPanel.bounds.size.width;
    self.nextUpButton.frame = CGRectMake(0.0, 6.0, pw, 18.0);
    NSString *qualityText = self.qualityLabel.text.length ? self.qualityLabel.text : @"Detecting bitrate…";
    // Dynamic explicit badge: system glyph instead of Deezer font "z"
    UIImageView *expView = objc_getAssociatedObject(self, "waExplicitImageView");
    BOOL showExplicit = expView ? !expView.hidden : !self.explicitIconLabel.hidden;
    CGFloat badgeReserve = showExplicit ? 24.0 : 0.0;
    CGFloat qualityTextWidth = MIN(pw - badgeReserve, MAX(48.0, [qualityText sizeWithFont:self.qualityLabel.font].width + 4.0));
    CGFloat qualityGroupWidth = qualityTextWidth + badgeReserve;
    CGFloat qualityGroupX = MAX(0.0, (pw - qualityGroupWidth) / 2.0);
    self.qualityLabel.textAlignment = showExplicit ? NSTextAlignmentRight : NSTextAlignmentCenter;
    self.qualityLabel.frame = CGRectMake(qualityGroupX, 28.0, qualityTextWidth, 16.0);
    if (expView) {
        expView.frame = showExplicit ? CGRectMake(qualityGroupX + qualityTextWidth + 2.0, 30.0, 20.0, 12.0) : CGRectZero;
        self.explicitIconLabel.frame = CGRectZero;
        self.explicitIconLabel.hidden = YES;
    } else {
        self.explicitIconLabel.frame = showExplicit ? CGRectMake(qualityGroupX + qualityTextWidth + 2.0, 28.0, 22.0, 16.0) : CGRectZero;
    }

    // Seek overlay floats over the artwork bottom (tap art to toggle).
    CGFloat overlayH = 44.0;
    CGRect artFrame = self.artworkView.frame;
    self.seekOverlay.frame = CGRectMake(artFrame.origin.x, artFrame.origin.y + artFrame.size.height - overlayH, artFrame.size.width, overlayH);
    CGFloat ow = artFrame.size.width;
    self.elapsedLabel.frame = CGRectMake(4.0, 0.0, 38.0, overlayH);
    self.progressSlider.frame = CGRectMake(46.0, 0.0, ow - 46.0 - 50.0, overlayH);
    self.durationLabel.frame = CGRectMake(ow - 46.0, 0.0, 42.0, overlayH);

    // Download progress replaces quality when downloading (themed bar)
    waMediaItem *cur = [waAudioPlayer sharedPlayer].currentItem;
    NSString *did = cur.trackId.length ? cur.trackId : cur.identifier;
    waDownload *d = did.length ? [[waDownloadManager sharedManager] downloadForIdentifier:did] : nil;
    BOOL isDownloading = d && (d.state==waDownloadStateDownloading || d.state==waDownloadStateQueued);
    self.downloadQualityProgressView.hidden = !isDownloading;
    self.qualityLabel.hidden = isDownloading;
    UIImageView *expV2 = objc_getAssociatedObject(self, "waExplicitImageView");
    if (expV2) expV2.hidden = isDownloading ? YES : !showExplicit;
    // keep explicitIconLabel hidden when downloading already handled above
    if (isDownloading) {
        self.downloadQualityProgressView.frame = CGRectMake(qualityGroupX, 28.0, qualityTextWidth + (showExplicit?24:0), 4.0);
        [self.downloadQualityProgressView setProgress:d.progress animated:YES];
    }

    // Transport: 6 icons centered: lyrics | prev | play | next | like | more
    UIButton *slots[] = { self.lyricsButton, self.previousButton, self.playButton, self.nextButton, self.likeButton, self.moreButton };
    NSUInteger visibleCount = 0;
    NSUInteger i;
    for (i = 0; i < 6; i++) if (!((UIButton *)slots[i]).hidden) visibleCount++;
    CGFloat slotW = landscape ? 38.0 : 44.0, slotH = 32.0;
    CGFloat sx = panelX + MAX(0.0, (panelWidth - visibleCount * slotW) / 2.0);
    CGFloat sy = controlsY + (transportH - slotH) / 2.0;
    for (i = 0; i < 6; i++) {
        if (!((UIButton *)slots[i]).hidden) {
            ((UIButton *)slots[i]).frame = CGRectMake(sx, sy, slotW, slotH);
            sx += slotW;
        } else {
            ((UIButton *)slots[i]).frame = CGRectZero;
        }
    }
}

- (void)playerDidChange:(NSNotification *)notification {
    (void)notification;
    [self refreshPlayerUI];
}

- (void)updateNavTitle {
    // TitleView assigned once in viewDidLoad: only mutate label texts here.
    // Re-assigning navigationItem.titleView forces the bar to re-layout and
    // the title jumps (Book 19:1342 — change contents, not the item itself).
    if (self.navSongText.length) {
        self.titleSongLabel.text = self.navSongText;
        self.titleArtistLabel.text = self.navArtistText;
        self.title = self.navArtistText.length ? self.navArtistText : self.navSongText;
    } else {
        self.titleSongLabel.text = @"Nothing playing";
        self.titleArtistLabel.text = @"Wave";
        self.title = @"Now Playing";
    }
}

- (void)refreshPlayerUI {
    waMediaItem *item = [waAudioPlayer sharedPlayer].currentItem;
    if (!item) {
        self.title = @"Now Playing";
        self.navSongText = nil;
        self.navArtistText = nil;
        self.qualityLabel.text = @"—";
        self.explicitIconLabel.hidden = YES;
        UIImageView *expV0 = objc_getAssociatedObject(self, "waExplicitImageView");
        if (expV0) expV0.hidden = YES;
        self.likeButton.hidden = YES;
        self.moreButton.hidden = YES;
        self.lyricsButton.enabled = NO;
        self.playButton.enabled = NO;
        [self setControlsDimmed:YES];
        self.artworkView.image = waPlaceholderImage();
        self.loadedArtworkURL = nil;
        self.artworkGeneration += 1;
        [self.loadingSpinner stopAnimating];
        self.loadingBackdrop.hidden = YES;
    } else {
        self.title = @"Now Playing";
        self.navSongText = [waAudioPlayer sharedPlayer].isLoading ? @"Loading…" : item.title;
        self.navArtistText = [waAudioPlayer sharedPlayer].lastError.localizedDescription ?: item.subtitle;
         self.qualityLabel.text = [waAudioPlayer sharedPlayer].qualityLabel ?: @"Detecting bitrate…";
         waDownload *download = [[waDownloadManager sharedManager] downloadForIdentifier:item.trackId.length ? item.trackId : item.identifier];
        BOOL isExplicit = item.isExplicit || download.isExplicit;
        UIImageView *expV = objc_getAssociatedObject(self, "waExplicitImageView");
        if (expV) {
            expV.hidden = !isExplicit;
            self.explicitIconLabel.hidden = YES;
        } else {
            self.explicitIconLabel.hidden = !isExplicit;
        }
        self.likeButton.hidden = NO;
        self.moreButton.hidden = NO;
        self.lyricsButton.enabled = YES;
        self.playButton.enabled = YES;
        [self setControlsDimmed:NO];
        self.likeButton.selected = item.isLiked;
        UIImage *likeImage = [waTheme tintedIcon:[UIImage imageNamed:@"wave-love"] withColor:waPlayerIconColor()];
        [self.likeButton setImage:likeImage forState:UIControlStateNormal];
        [self.likeButton setImage:[waTheme tintedIcon:[UIImage imageNamed:@"wave-love"] withColor:[waTheme likeSelectedColor]] forState:UIControlStateSelected];
        self.likeButton.accessibilityLabel = item.isLiked ? @"Unlike song" : @"Like song";
        NSString *localArtworkPath = download.artworkFilePath;
        // Cheap key only (no fileExists / decode here): existence check
        // and JPEG decode run on a background queue below.
        NSString *artworkKey = localArtworkPath.length ? [NSString stringWithFormat:@"local:%@", localArtworkPath] : item.thumbnailURL;
        if (![self.loadedArtworkURL isEqualToString:artworkKey]) {
            self.loadedArtworkURL = artworkKey;
            [self showSeekOverlayTemporarily];
            self.artworkView.image = waPlaceholderImage();
            unsigned long generation = ++self.artworkGeneration;
            NSString *pathCopy = [localArtworkPath copy];
            NSString *thumbnailCopy = [item.thumbnailURL copy];
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                UIImage *localArtwork = nil;
                BOOL hasLocalArtwork = NO;
                if (pathCopy.length && [[NSFileManager defaultManager] fileExistsAtPath:pathCopy]) {
                    hasLocalArtwork = YES;
                    UIImage *fullRes = [UIImage imageWithContentsOfFile:pathCopy];
                    // Downsample once off-main: download art can be 1000px+,
                    // the view shows ~320pt max. Keeps VM stable over sessions.
                    if (fullRes && MAX(fullRes.size.width, fullRes.size.height) > 480.0) {
                        localArtwork = waSizedImage(fullRes, CGSizeMake(480.0, 480.0));
                    } else {
                        localArtwork = fullRes;
                    }
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    waPlayerViewController *strongSelf = weakSelf;
                    if (!strongSelf || generation != strongSelf.artworkGeneration) return;
                    if (hasLocalArtwork) {
                        if (localArtwork) strongSelf.artworkView.image = localArtwork;
                    } else if (thumbnailCopy.length) {
                        NSString *artworkURL = thumbnailCopy;
                        [[waImageLoader sharedLoader] loadArtworkAtURL:artworkURL placeholder:waPlaceholderImage() completion:^(UIImage *image) {
                            if (generation == strongSelf.artworkGeneration && [strongSelf.loadedArtworkURL isEqualToString:artworkURL]) strongSelf.artworkView.image = image;
                        }];
                    }
                });
            });
        }
        if ([waAudioPlayer sharedPlayer].isLoading) {
            self.loadingBackdrop.hidden = NO;
            [self.contentView bringSubviewToFront:self.loadingBackdrop];
            [self.loadingSpinner startAnimating];
        } else {
            [self.loadingSpinner stopAnimating];
            self.loadingBackdrop.hidden = YES;
        }
        [self.view setNeedsLayout];
    }
    [self updateNextUpRow];
    [self updatePlayIcon];
    [self updateProgress:nil];
    [self updateNavTitle];
}

- (void)updateNextUpRow {
    // Hype Machine style context row: what plays next (tap opens Queue).
    waAudioPlayer *player = [waAudioPlayer sharedPlayer];
    NSArray *queue = player.queueItems;
    waMediaItem *next = nil;
    if (queue.count) {
        if (player.queueIndex + 1 < queue.count) next = [queue objectAtIndex:player.queueIndex + 1];
        else if (player.repeatMode == waRepeatModeAll) next = [queue objectAtIndex:0];
    }
    NSString *title = next.title.length ? [NSString stringWithFormat:@"Next: %@ ›", next.title] : @"Queue ›";
    [self.nextUpButton setTitle:title forState:UIControlStateNormal];
}

- (void)setControlsDimmed:(BOOL)dimmed {
    CGFloat alpha = dimmed ? 0.35 : 1.0;
    self.previousButton.alpha = alpha;
    self.playButton.alpha = alpha;
    self.nextButton.alpha = alpha;
    self.lyricsButton.alpha = alpha;
    self.likeButton.alpha = alpha;
    self.previousButton.enabled = !dimmed;
    self.nextButton.enabled = !dimmed;
}

- (void)playerDidFail:(NSNotification *)notification { (void)notification; [self refreshPlayerUI]; }

- (void)updateProgress:(id)sender {
    (void)sender;
    waAudioEngine *engine = [waAudioEngine sharedEngine];
    NSTimeInterval duration = engine.duration > 0.0 ? engine.duration : [waAudioPlayer sharedPlayer].currentItem.duration;
    NSTimeInterval elapsed = engine.hasLoadedPlaybackItem ? engine.currentTime : [waAudioPlayer sharedPlayer].persistedPlaybackPosition;
    float maximum = duration > 0.0 ? duration : 1.0;
    float value = MIN(maximum, MAX(0.0, elapsed));
    if (fabs(self.progressSlider.maximumValue - maximum) >= 0.5) self.progressSlider.maximumValue = maximum;
    if (!self.progressSlider.tracking && fabs(self.progressSlider.value - value) >= 0.5) self.progressSlider.value = value;
    // Freeze labels mid-drag so they don't tick under the user's thumb;
    // they refresh on release when the seek commits.
    if (self.progressSlider.tracking) return;
    NSString *elapsedText = [self timeString:elapsed];
    NSString *durationText = [self timeString:duration];
    if (![self.elapsedLabel.text isEqualToString:elapsedText]) self.elapsedLabel.text = elapsedText;
    if (![self.durationLabel.text isEqualToString:durationText]) self.durationLabel.text = durationText;
}

- (NSString *)timeString:(NSTimeInterval)time {
    if (!isfinite(time) || time < 0.0) time = 0.0;
    NSInteger seconds = (NSInteger)time;
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

- (void)progressChanged:(UISlider *)slider {
    [[waAudioEngine sharedEngine] seekToTime:slider.value];
}

- (void)togglePlayback:(id)sender {
    (void)sender;
    if (![waAudioPlayer sharedPlayer].currentItem) return;
    [[waAudioPlayer sharedPlayer] togglePlayPause];
}

- (void)previous:(id)sender {
    (void)sender;
    [[waAudioPlayer sharedPlayer] playPrevious];
}

- (void)next:(id)sender {
    (void)sender;
    [[waAudioPlayer sharedPlayer] playNext];
}

- (void)lyricsPressed:(id)sender {
    (void)sender;
    waMediaItem *item = [waAudioPlayer sharedPlayer].currentItem;
    if (!item) return;
    NSString *artist = item.artistName.length ? item.artistName : item.subtitle;
    [self.navigationController pushViewController:[[waLyricsViewController alloc] initWithTrack:item.title artist:artist album:item.albumName duration:item.duration trackId:item.trackId isrc:item.isrc] animated:YES];
}

- (void)likePressed:(id)sender {
    (void)sender;
    waMediaItem *item = [waAudioPlayer sharedPlayer].currentItem;
    if (!item || item.type != waMediaItemTypeSong || ![[waAPIClient sharedClient] isAuthenticated]) return;
    BOOL liked = !item.isLiked;
    item.liked = liked;
    self.likeButton.selected = liked;
    self.likeButton.enabled = NO;
    [[waAPIClient sharedClient] setLiked:liked song:item completion:^(BOOL success, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.likeButton.enabled = YES;
            if (!success) {
                item.liked = !liked;
                self.likeButton.selected = item.isLiked;
                [[[UIAlertView alloc] initWithTitle:@"Like" message:error.localizedDescription ?: @"Unable to update like." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
            } else {
                [[NSNotificationCenter defaultCenter] postNotificationName:waMediaLikeDidChangeNotification object:item userInfo:@{waMediaLikeIdentifierKey: item.identifier ?: @"", waMediaLikeTypeKey: @(item.type)}];
            }
            [self refreshPlayerUI];
        });
    }];
}
- (void)morePressed:(id)sender {
    (void)sender;
    waMediaItem *item = [waAudioPlayer sharedPlayer].currentItem;
    if (!item) return;
    [waMediaActionSheet presentForItem:item inViewController:self albumItems:nil];
}

- (void)showQueue:(id)sender {
    (void)sender;
    [self.navigationController pushViewController:[[waQueueViewController alloc] initWithStyle:UITableViewStylePlain] animated:YES];
}

- (void)closePlayer:(id)sender {
    (void)sender;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)dealloc {
    [self.updateTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
