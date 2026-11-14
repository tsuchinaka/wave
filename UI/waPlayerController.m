#import "waPlayerController.h"

#import "waQueueController.h"
#import "waRootController.h"
#import "waPlayer.h"
#import "waSession.h"
#import "waLastFM.h"
#import "waSkin.h"
#import "waLyricStage.h"
#import "waLyrics.h"

#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MediaPlayer.h>
#import <stdlib.h>

static NSString *waTimeString(NSTimeInterval seconds) {
    if (!isfinite(seconds) || seconds < 0.0) seconds = 0.0;
    NSInteger total = (NSInteger)seconds;
    NSInteger minutes = total / 60;
    NSInteger secs = total % 60;
    if (minutes > 99) return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)secs];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)secs];
}

static void waBoxBlur(unsigned char *px, int w, int h, int radius) {
    if (radius < 1 || w < 2 || h < 2) return;
    int n = w * h;
    unsigned char *tmp = malloc((size_t)n * 4);
    if (!tmp) return;
    int window = radius * 2 + 1;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            int a = 0, r = 0, g = 0, b = 0;
            for (int k = -radius; k <= radius; k++) {
                int xx = x + k;
                if (xx < 0) xx = 0;
                if (xx >= w) xx = w - 1;
                unsigned char *p = px + ((y * w + xx) * 4);
                r += p[0]; g += p[1]; b += p[2]; a += p[3];
            }
            unsigned char *o = tmp + ((y * w + x) * 4);
            o[0] = (unsigned char)(r / window);
            o[1] = (unsigned char)(g / window);
            o[2] = (unsigned char)(b / window);
            o[3] = (unsigned char)(a / window);
        }
    }
    for (int x = 0; x < w; x++) {
        for (int y = 0; y < h; y++) {
            int a = 0, r = 0, g = 0, b = 0;
            for (int k = -radius; k <= radius; k++) {
                int yy = y + k;
                if (yy < 0) yy = 0;
                if (yy >= h) yy = h - 1;
                unsigned char *p = tmp + ((yy * w + x) * 4);
                r += p[0]; g += p[1]; b += p[2]; a += p[3];
            }
            unsigned char *o = px + ((y * w + x) * 4);
            o[0] = (unsigned char)(r / window);
            o[1] = (unsigned char)(g / window);
            o[2] = (unsigned char)(b / window);
            o[3] = (unsigned char)(a / window);
        }
    }
    free(tmp);
}

enum {
    waPlayerSheetTrack = 1,
    waPlayerSheetLastFM = 2,
    waPlayerAlertLastFMLogin = 20
};

@interface waPlayerController () <UIActionSheetDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UIImageView *backdropView;
@property (nonatomic, strong) UIView *artWell;
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UIImageView *reflectionView;
@property (nonatomic, strong) CAGradientLayer *reflectionMask;
@property (nonatomic, strong) waLyricStage *lyricStage;
@property (nonatomic, strong) UIActivityIndicatorView *lyricsSpinner;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *artistLabel;
@property (nonatomic, strong) UILabel *albumLabel;
@property (nonatomic, strong) UILabel *elapsedLabel;
@property (nonatomic, strong) UILabel *remainingLabel;
@property (nonatomic, strong) UISlider *scrubber;
@property (nonatomic, strong) UIButton *shuffleButton;
@property (nonatomic, strong) UIButton *previousButton;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) UIButton *nextButton;
@property (nonatomic, strong) UIButton *repeatButton;
@property (nonatomic, strong) UIImageView *speakerLowView;
@property (nonatomic, strong) UIImageView *speakerHighView;
@property (nonatomic, strong) UISlider *volumeSlider;
@property (nonatomic, assign) BOOL volumeDragging;
@property (nonatomic, strong) UIBarButtonItem *likeItem;
@property (nonatomic, strong) UIBarButtonItem *queueItem;
@property (nonatomic, strong) UIBarButtonItem *lastFMItem;
@property (nonatomic, strong) UIButton *lastFMButton;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL scrubbing;
@property (nonatomic, assign) BOOL showingLyrics;
@property (nonatomic, copy) NSString *artworkURL;
@property (nonatomic, strong) UIImage *sourceArtwork;
@property (nonatomic, copy) NSString *lyricsTrackID;
@property (nonatomic, strong) waLyrics *parsedLyrics;
@property (nonatomic, assign) NSUInteger lyricsRequest;
@property (nonatomic, assign) dispatch_queue_t artQueue;
@property (nonatomic, assign) NSUInteger artGeneration;
@end

@implementation waPlayerController

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    view.backgroundColor = [UIColor blackColor];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = nil;
    self.navigationItem.title = nil;
    [self applyChrome];

    self.backdropView = [[UIImageView alloc] initWithFrame:self.view.bounds];
    self.backdropView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backdropView.contentMode = UIViewContentModeScaleAspectFill;
    self.backdropView.clipsToBounds = YES;
    self.backdropView.backgroundColor = [UIColor blackColor];
    [self.view addSubview:self.backdropView];

    self.reflectionView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.reflectionView.contentMode = UIViewContentModeScaleAspectFill;
    self.reflectionView.clipsToBounds = YES;
    self.reflectionView.userInteractionEnabled = NO;
    self.reflectionMask = [CAGradientLayer layer];
    self.reflectionMask.colors = [NSArray arrayWithObjects:
                                   (id)[[UIColor colorWithWhite:1.0 alpha:0.50] CGColor],
                                   (id)[[UIColor colorWithWhite:1.0 alpha:0.0] CGColor],
                                   nil];
    self.reflectionMask.startPoint = CGPointMake(0.5, 0.0);
    self.reflectionMask.endPoint = CGPointMake(0.5, 1.0);
    self.reflectionView.layer.mask = self.reflectionMask;
    [self.view addSubview:self.reflectionView];

    self.artWell = [[UIView alloc] initWithFrame:CGRectZero];
    self.artWell.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    self.artWell.layer.borderWidth = 0.0;
    self.artWell.layer.shadowColor = [UIColor blackColor].CGColor;
    self.artWell.layer.shadowOpacity = 0.55;
    self.artWell.layer.shadowRadius = 8.0;
    self.artWell.layer.shadowOffset = CGSizeMake(0.0, 3.0);
    self.artWell.clipsToBounds = NO;
    [self.view addSubview:self.artWell];

    self.artworkView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.opaque = YES;
    self.artworkView.userInteractionEnabled = YES;
    [self.artWell addSubview:self.artworkView];
    UITapGestureRecognizer *artTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleLyrics)];
    [self.artworkView addGestureRecognizer:artTap];

    self.lyricStage = [[waLyricStage alloc] initWithFrame:CGRectZero];
    self.lyricStage.hidden = YES;
    self.lyricStage.userInteractionEnabled = YES;
    self.lyricStage.timeSource = ^{ return [waPlayer shared].outputTime; };
    [self.view addSubview:self.lyricStage];
    UITapGestureRecognizer *lyricsTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleLyrics)];
    [self.lyricStage addGestureRecognizer:lyricsTap];

    self.lyricsSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.lyricsSpinner.hidesWhenStopped = YES;
    [self.view addSubview:self.lyricsSpinner];

    self.titleLabel = [self labelWithSize:16.0 bold:YES alpha:1.0 align:UITextAlignmentCenter];
    self.artistLabel = [self labelWithSize:13.0 bold:NO alpha:0.92 align:UITextAlignmentCenter];
    self.albumLabel = [self labelWithSize:12.0 bold:NO alpha:0.62 align:UITextAlignmentCenter];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(titleHeld:)];
    [self.titleLabel addGestureRecognizer:hold];
    self.titleLabel.userInteractionEnabled = YES;
    [self.view addSubview:self.titleLabel];
    [self.view addSubview:self.artistLabel];
    [self.view addSubview:self.albumLabel];

    self.elapsedLabel = [self labelWithSize:11.0 bold:NO alpha:0.85 align:UITextAlignmentLeft];
    self.remainingLabel = [self labelWithSize:11.0 bold:NO alpha:0.85 align:UITextAlignmentRight];
    [self.view addSubview:self.elapsedLabel];
    [self.view addSubview:self.remainingLabel];

    self.scrubber = [[UISlider alloc] initWithFrame:CGRectZero];
    [self styleSlider:self.scrubber];
    [self.scrubber addTarget:self action:@selector(scrubBegan) forControlEvents:UIControlEventTouchDown];
    [self.scrubber addTarget:self action:@selector(scrubChanged) forControlEvents:UIControlEventValueChanged];
    [self.scrubber addTarget:self action:@selector(scrubEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.view addSubview:self.scrubber];

    self.shuffleButton = [self transportButton:@"WaveShuffleOff" action:@selector(toggleShuffle)];
    self.previousButton = [self transportButton:@"SystemMediaControl-Rewind" action:@selector(playPrevious)];
    self.playButton = [self transportButton:@"SystemMediaControl-Play" action:@selector(togglePlayback)];
    self.nextButton = [self transportButton:@"SystemMediaControl-Forward" action:@selector(playNext)];
    self.repeatButton = [self transportButton:@"WaveRepeatOff" action:@selector(toggleRepeat)];

    self.artQueue = dispatch_queue_create("wave.player.art", DISPATCH_QUEUE_SERIAL);

    self.speakerLowView = [[UIImageView alloc] initWithImage:[self speakerImageLoud:NO]];
    self.speakerHighView = [[UIImageView alloc] initWithImage:[self speakerImageLoud:YES]];
    [self.view addSubview:self.speakerLowView];
    [self.view addSubview:self.speakerHighView];

    [waPlayer shared].volume = 1.0f;
    self.volumeSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    [self styleSlider:self.volumeSlider];
    self.volumeSlider.minimumValue = 0.0f;
    self.volumeSlider.maximumValue = 1.0f;
    [self.volumeSlider addTarget:self action:@selector(volumeTouchDown) forControlEvents:UIControlEventTouchDown];
    [self.volumeSlider addTarget:self action:@selector(volumeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.volumeSlider addTarget:self action:@selector(volumeTouchUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.view addSubview:self.volumeSlider];
    MPMusicPlayerController *systemVolume = [MPMusicPlayerController iPodMusicPlayer];
    [systemVolume beginGeneratingPlaybackNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(systemVolumeChanged:) name:MPMusicPlayerControllerVolumeDidChangeNotification object:nil];
    [self syncSystemVolume];

    UIColor *barButtonTint = [UIColor colorWithWhite:0.18 alpha:1.0];
    self.likeItem = [[UIBarButtonItem alloc] initWithImage:[self heartImage] style:UIBarButtonItemStyleBordered target:self action:@selector(toggleLike)];
    self.likeItem.tintColor = barButtonTint;
    self.queueItem = [[UIBarButtonItem alloc] initWithImage:[self listGlyph] style:UIBarButtonItemStyleBordered target:self action:@selector(showQueue)];
    self.queueItem.tintColor = barButtonTint;
    self.navigationItem.leftBarButtonItems = [NSArray arrayWithObjects:self.likeItem, self.queueItem, nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleBordered target:self action:@selector(close)];
    done.tintColor = barButtonTint;
    self.lastFMButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.lastFMButton.frame = CGRectMake(0.0, 0.0, 34.0, 30.0);
    self.lastFMButton.showsTouchWhenHighlighted = YES;
    self.lastFMButton.adjustsImageWhenHighlighted = NO;
    [self.lastFMButton addTarget:self action:@selector(lastFMTapped) forControlEvents:UIControlEventTouchUpInside];
    self.lastFMItem = [[UIBarButtonItem alloc] initWithCustomView:self.lastFMButton];
    self.navigationItem.rightBarButtonItems = [NSArray arrayWithObjects:done, self.lastFMItem, nil];
    [self refreshLastFMButton];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(trackChanged:) name:waPlayerTrackDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(stateChanged:) name:waPlayerStateDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(progressChanged:) name:waPlayerProgressNotification object:nil];
    [center addObserver:self selector:@selector(lastFMChanged:) name:waLastFMDidChangeNotification object:nil];
    [self refreshTrack];
    [self refreshProgress];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyChrome];
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleBlackOpaque animated:animated];
    [self.navigationController setNavigationBarHidden:NO animated:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
    [self refreshTrack];
    [self refreshProgress];
    [self refreshLastFMButton];
    [self syncSystemVolume];
    [self startProgressTimer];
}

- (void)startProgressTimer {
    if (self.timer && fabs(self.timer.timeInterval - 0.5) < 0.001) return;
    [self.timer invalidate];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.timer invalidate];
    self.timer = nil;
    [self.lyricStage stopPulse];
    if (self.navigationController.topViewController == self) {
        [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleDefault animated:animated];
    }
}

- (void)dealloc {
    [[MPMusicPlayerController iPodMusicPlayer] endGeneratingPlaybackNotifications];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.timer invalidate];
    [self.lyricStage stopPulse];
#if !OS_OBJECT_USE_OBJC
    if (self.artQueue) dispatch_release(self.artQueue);
#endif
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)applyChrome {
    UINavigationBar *bar = self.navigationController.navigationBar;
    if (!bar) return;
    bar.barStyle = UIBarStyleBlack;
    bar.translucent = NO;
    bar.tintColor = nil;
    [bar setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
    [bar setBackgroundImage:nil forBarMetrics:UIBarMetricsLandscapePhone];
}

#pragma mark - chrome pieces

- (UILabel *)labelWithSize:(CGFloat)size bold:(BOOL)bold alpha:(CGFloat)alpha align:(UITextAlignment)align {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.backgroundColor = [UIColor clearColor];
    label.font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    label.textColor = [UIColor colorWithWhite:1.0 alpha:alpha];
    label.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.75];
    label.shadowOffset = CGSizeMake(0.0, 1.0);
    label.textAlignment = align;
    label.lineBreakMode = UILineBreakModeTailTruncation;
    label.numberOfLines = 1;
    return label;
}

- (UIImage *)whiteImageNamed:(NSString *)name {
    if (!name.length) return nil;
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSMutableDictionary alloc] init]; });
    UIImage *hit = [cache objectForKey:name];
    if (hit) return hit;
    UIImage *source = [UIImage imageNamed:name];
    if (!source.CGImage) return source;
    CGSize size = source.size;
    UIGraphicsBeginImageContextWithOptions(size, NO, source.scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(ctx, 0.0, size.height);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    CGContextClipToMask(ctx, CGRectMake(0.0, 0.0, size.width, size.height), source.CGImage);
    [[UIColor whiteColor] setFill];
    CGContextFillRect(ctx, CGRectMake(0.0, 0.0, size.width, size.height));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (image) [cache setObject:image forKey:name];
    return image;
}

- (UIButton *)transportButton:(NSString *)imageName action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    UIImage *image = [self whiteImageNamed:imageName];
    if (image) [button setImage:image forState:UIControlStateNormal];
    button.showsTouchWhenHighlighted = YES;
    button.adjustsImageWhenHighlighted = NO;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    return button;
}

- (UIImage *)trackImage:(UIColor *)color {
    CGSize size = CGSizeMake(8.0, 4.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [color setFill];
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0.0, 1.0, size.width, 2.0) cornerRadius:1.0];
    [path fill];
    (void)ctx;
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0.0, 3.0, 0.0, 3.0)];
}

- (UIImage *)thumbImage {
    CGSize size = CGSizeMake(18.0, 18.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetShadowWithColor(ctx, CGSizeZero, 1.0, [UIColor colorWithWhite:0.0 alpha:0.4].CGColor);
    [[UIColor colorWithWhite:0.97 alpha:1.0] setFill];
    CGContextFillEllipseInRect(ctx, CGRectMake(3.0, 3.0, 12.0, 12.0));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)styleSlider:(UISlider *)slider {
    static UIImage *min;
    static UIImage *max;
    static UIImage *thumb;
    if (!min) {
        min = [self trackImage:[UIColor colorWithWhite:1.0 alpha:0.92]];
        max = [self trackImage:[UIColor colorWithWhite:1.0 alpha:0.28]];
        thumb = [self thumbImage];
    }
    [slider setMinimumTrackImage:min forState:UIControlStateNormal];
    [slider setMaximumTrackImage:max forState:UIControlStateNormal];
    [slider setMinimumTrackImage:min forState:UIControlStateHighlighted];
    [slider setMaximumTrackImage:max forState:UIControlStateHighlighted];
    [slider setThumbImage:thumb forState:UIControlStateNormal];
    [slider setThumbImage:thumb forState:UIControlStateHighlighted];
}

- (UIImage *)heartImage {
    UIImage *source = [UIImage imageNamed:@"wave-love"];
    CGSize size = CGSizeMake(18.0, 18.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (source.CGImage) {
        CGContextTranslateCTM(ctx, 0.0, size.height);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        CGContextClipToMask(ctx, CGRectMake(0.0, 0.0, size.width, size.height), source.CGImage);
        [[UIColor whiteColor] setFill];
        CGContextFillRect(ctx, CGRectMake(0.0, 0.0, size.width, size.height));
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (void)applyLikeState:(BOOL)liked {
    self.likeItem.tintColor = liked ? [UIColor redColor] : [UIColor colorWithWhite:0.18 alpha:1.0];
}

- (UIImage *)listGlyph {
    CGSize size = CGSizeMake(22.0, 16.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor whiteColor] setFill];
    CGContextMoveToPoint(ctx, 1.0, 1.5);
    CGContextAddLineToPoint(ctx, 1.0, 6.5);
    CGContextAddLineToPoint(ctx, 5.5, 4.0);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    CGContextFillRect(ctx, CGRectMake(8.0, 1.0, 13.0, 1.6));
    CGContextFillRect(ctx, CGRectMake(8.0, 7.2, 13.0, 1.6));
    CGContextFillRect(ctx, CGRectMake(8.0, 13.4, 13.0, 1.6));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (UIImage *)speakerImageLoud:(BOOL)loud {
    CGSize size = CGSizeMake(16.0, 16.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    [[UIColor colorWithWhite:1.0 alpha:0.85] setFill];
    [[UIColor colorWithWhite:1.0 alpha:0.85] setStroke];
    CGContextSetLineWidth(ctx, 1.2);
    CGContextFillRect(ctx, CGRectMake(1.0, 6.0, 3.0, 4.0));
    CGContextMoveToPoint(ctx, 4.0, 6.0);
    CGContextAddLineToPoint(ctx, 8.0, 3.0);
    CGContextAddLineToPoint(ctx, 8.0, 13.0);
    CGContextAddLineToPoint(ctx, 4.0, 10.0);
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    if (loud) {
        CGContextAddArc(ctx, 8.5, 8.0, 3.2, -0.8, 0.8, 0);
        CGContextStrokePath(ctx);
        CGContextAddArc(ctx, 8.5, 8.0, 5.4, -0.7, 0.7, 0);
        CGContextStrokePath(ctx);
    } else {
        CGContextAddArc(ctx, 8.5, 8.0, 3.0, -0.7, 0.7, 0);
        CGContextStrokePath(ctx);
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

- (UIImage *)verticalMirror:(UIImage *)image {
    if (!image.CGImage) return nil;
    return [UIImage imageWithCGImage:image.CGImage scale:image.scale orientation:UIImageOrientationDownMirrored];
}

- (UIImage *)blurredBackdrop:(UIImage *)image size:(CGSize)size {
    int outW = (int)size.width;
    int outH = (int)size.height;
    if (outW < 2 || outH < 2) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    if (!image) {
        CGContextRef solid = CGBitmapContextCreate(NULL, 1, 1, 8, 4, space, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        if (solid) {
            CGContextSetRGBFillColor(solid, 0, 0, 0, 1);
            CGContextFillRect(solid, CGRectMake(0, 0, 1, 1));
            CGImageRef black = CGBitmapContextCreateImage(solid);
            CGContextRelease(solid);
            UIImage *blank = black ? [UIImage imageWithCGImage:black scale:1.0 orientation:UIImageOrientationUp] : nil;
            if (black) CGImageRelease(black);
            CGColorSpaceRelease(space);
            return blank;
        }
        CGColorSpaceRelease(space);
        return nil;
    }
    int w = 36;
    int h = 48;
    size_t bytes = (size_t)w * (size_t)h * 4;
    unsigned char *buf = calloc(1, bytes);
    if (!buf) {
        CGColorSpaceRelease(space);
        return nil;
    }
    CGContextRef tiny = CGBitmapContextCreate(buf, w, h, 8, w * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (image.CGImage) CGContextDrawImage(tiny, CGRectMake(0, 0, w, h), image.CGImage);
    waBoxBlur(buf, w, h, 2);
    waBoxBlur(buf, w, h, 2);
    CGImageRef cg = CGBitmapContextCreateImage(tiny);
    CGContextRelease(tiny);

    unsigned char *outBuf = calloc(1, (size_t)outW * (size_t)outH * 4);
    CGContextRef ctx = outBuf ? CGBitmapContextCreate(outBuf, outW, outH, 8, outW * 4, space, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little) : NULL;
    UIImage *backdrop = nil;
    if (ctx) {
        CGContextTranslateCTM(ctx, 0.0, (CGFloat)outH);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
        if (cg) CGContextDrawImage(ctx, CGRectMake(0, 0, outW, outH), cg);
        CGFloat components[] = {
            0.0, 0.0, 0.0, 0.28,
            0.0, 0.0, 0.0, 0.55
        };
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, NULL, 2);
        CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, 0), CGPointMake(0, outH), 0);
        CGGradientRelease(gradient);
        CGImageRef outCG = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        if (outCG) {
            backdrop = [UIImage imageWithCGImage:outCG scale:1.0 orientation:UIImageOrientationUp];
            CGImageRelease(outCG);
        }
    }
    if (cg) CGImageRelease(cg);
    CGColorSpaceRelease(space);
    free(buf);
    free(outBuf);
    return backdrop;
}

- (void)rebuildBackdrop {
    CGSize size = self.view.bounds.size;
    if (size.width < 2.0) size = [UIScreen mainScreen].bounds.size;
    UIImage *source = self.sourceArtwork;
    NSUInteger gen = self.artGeneration;
    __weak waPlayerController *weakSelf = self;
    dispatch_queue_t queue = self.artQueue;
    if (!queue) {
        self.backdropView.image = [self blurredBackdrop:source size:size];
        return;
    }
    dispatch_async(queue, ^{
        UIImage *backdrop = [weakSelf blurredBackdrop:source size:size];
        dispatch_async(dispatch_get_main_queue(), ^{
            waPlayerController *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.artGeneration != gen) return;
            strongSelf.backdropView.image = backdrop;
        });
    });
}

#pragma mark - layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutChrome];
}

- (void)layoutChrome {
    CGRect bounds = self.view.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width < 2.0 || height < 2.0) return;
    self.backdropView.frame = bounds;
    if (self.sourceArtwork && fabs(self.backdropView.image.size.width - width) > 2.0) [self rebuildBackdrop];

    BOOL landscape = width > height + 40.0;
    if (landscape) [self layoutLandscape:bounds];
    else [self layoutPortrait:bounds];

    self.artworkView.frame = self.artWell.bounds;
    if (self.showingLyrics) {
        self.lyricsSpinner.center = CGPointMake(CGRectGetMidX(self.lyricStage.frame), CGRectGetMidY(self.lyricStage.frame));
    } else {
        self.lyricsSpinner.center = CGPointMake(CGRectGetMidX(self.artWell.frame), CGRectGetMidY(self.artWell.frame));
    }
    self.artWell.layer.shadowPath = [UIBezierPath bezierPathWithRect:self.artWell.bounds].CGPath;
    self.reflectionMask.frame = self.reflectionView.bounds;
}

- (void)layoutPortrait:(CGRect)bounds {
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat bottom = 12.0;
    CGFloat volumeH = 22.0;
    CGFloat transportH = 42.0;
    CGFloat scrubH = 22.0;
    CGFloat titleH = 18.0;
    CGFloat artistH = 16.0;
    CGFloat albumH = self.albumLabel.text.length ? 14.0 : 0.0;
    CGFloat reflectionH = 20.0;
    CGFloat fixed = bottom + volumeH + 8.0 + transportH + 6.0 + scrubH + 8.0 + albumH + artistH + titleH + 6.0 + reflectionH + 6.0;
    CGFloat art = height - fixed;
    CGFloat maxArt = width - 52.0;
    if (art > maxArt) art = maxArt;
    if (art < 132.0) {
        reflectionH = 0.0;
        albumH = 0.0;
        fixed = bottom + volumeH + 6.0 + transportH + 4.0 + scrubH + 4.0 + artistH + titleH + 4.0;
        art = height - fixed;
        if (art > maxArt) art = maxArt;
        if (art < 96.0) art = 96.0;
    }
    self.albumLabel.hidden = albumH < 1.0;
    self.reflectionView.hidden = self.showingLyrics || reflectionH < 1.0 || self.sourceArtwork == nil;
    self.artWell.hidden = self.showingLyrics;

    CGFloat y = 6.0;
    CGFloat extra = height - fixed - art;
    if (extra > 0.0) y += extra * 0.35;
    self.artWell.frame = CGRectMake((width - art) / 2.0, y, art, art);
    if (self.showingLyrics) {
        CGFloat lyricsH = art + reflectionH;
        self.lyricStage.frame = CGRectMake(0.0, y, width, lyricsH);
        y += lyricsH + 6.0;
    } else {
        y = CGRectGetMaxY(self.artWell.frame);
        self.reflectionView.frame = CGRectMake(CGRectGetMinX(self.artWell.frame), y, art, reflectionH);
        y += reflectionH + 6.0;
    }
    self.titleLabel.frame = CGRectMake(16.0, y, width - 32.0, titleH);
    y += titleH;
    self.artistLabel.frame = CGRectMake(16.0, y, width - 32.0, artistH);
    y += artistH;
    if (albumH > 0.0) {
        self.albumLabel.frame = CGRectMake(16.0, y, width - 32.0, albumH);
        y += albumH;
    }
    y += 8.0;
    [self placeScrubberAtY:y width:width];
    y += scrubH + 6.0;
    [self placeTransportAtY:y height:transportH width:width];
    y += transportH + 8.0;
    [self placeVolumeAtY:y width:width];
}

- (void)layoutLandscape:(CGRect)bounds {
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGFloat reflectionH = 16.0;
    CGFloat side = height - 12.0 - reflectionH;
    if (side > 220.0) side = 220.0;
    if (side > width * 0.42) side = width * 0.42;
    CGFloat artY = 6.0;
    self.artWell.frame = CGRectMake(8.0, artY, side, side);
    self.artWell.hidden = self.showingLyrics;
    self.reflectionView.hidden = self.showingLyrics || self.sourceArtwork == nil;
    self.reflectionView.frame = CGRectMake(8.0, artY + side, side, reflectionH);
    self.albumLabel.hidden = NO;

    CGFloat x = CGRectGetMaxX(self.artWell.frame) + 14.0;
    if (self.showingLyrics) {
        CGFloat lyricsW = MAX(side + 8.0, width * 0.56);
        if (lyricsW > width - 168.0) lyricsW = width - 168.0;
        self.lyricStage.frame = CGRectMake(0.0, 0.0, lyricsW, height);
        x = lyricsW + 8.0;
    }
    CGFloat colW = width - x - 8.0;
    CGFloat titleH = 18.0;
    CGFloat artistH = 15.0;
    CGFloat albumH = 14.0;
    CGFloat scrubH = 22.0;
    CGFloat transportH = 40.0;
    CGFloat volumeH = 22.0;
    CGFloat stack = titleH + artistH + albumH + 6.0 + scrubH + 6.0 + transportH + 6.0 + volumeH;
    CGFloat y = MAX(6.0, (height - stack) / 2.0);
    self.titleLabel.frame = CGRectMake(x, y, colW, titleH);
    y += titleH;
    self.artistLabel.frame = CGRectMake(x, y, colW, artistH);
    y += artistH;
    self.albumLabel.frame = CGRectMake(x, y, colW, albumH);
    y += albumH + 6.0;
    self.elapsedLabel.frame = CGRectMake(x, y, 44.0, scrubH);
    self.elapsedLabel.textAlignment = UITextAlignmentRight;
    self.remainingLabel.frame = CGRectMake(x + colW - 44.0, y, 44.0, scrubH);
    self.remainingLabel.textAlignment = UITextAlignmentLeft;
    self.scrubber.frame = CGRectMake(x + 52.0, y, colW - 104.0, scrubH);
    y += scrubH + 6.0;
    [self placeTransportInRect:CGRectMake(x, y, colW, transportH)];
    y += transportH + 6.0;
    self.speakerLowView.frame = CGRectMake(x, y + 4.0, 16.0, 16.0);
    self.speakerHighView.frame = CGRectMake(x + colW - 16.0, y + 4.0, 16.0, 16.0);
    self.volumeSlider.frame = CGRectMake(x + 24.0, y, colW - 48.0, volumeH);
}

- (void)placeScrubberAtY:(CGFloat)y width:(CGFloat)width {
    CGFloat timeW = 46.0;
    self.elapsedLabel.frame = CGRectMake(16.0, y, timeW, 22.0);
    self.elapsedLabel.textAlignment = UITextAlignmentRight;
    self.remainingLabel.frame = CGRectMake(width - 16.0 - timeW, y, timeW, 22.0);
    self.remainingLabel.textAlignment = UITextAlignmentLeft;
    self.scrubber.frame = CGRectMake(16.0 + timeW + 10.0, y, width - 32.0 - timeW * 2.0 - 20.0, 22.0);
}

- (void)placeTransportAtY:(CGFloat)y height:(CGFloat)height width:(CGFloat)width {
    [self placeTransportInRect:CGRectMake(6.0, y, width - 12.0, height)];
}

- (void)placeTransportInRect:(CGRect)rect {
    NSArray *buttons = [NSArray arrayWithObjects:self.shuffleButton, self.previousButton, self.playButton, self.nextButton, self.repeatButton, nil];
    CGFloat count = (CGFloat)buttons.count;
    CGFloat slot = CGRectGetWidth(rect) / count;
    for (NSUInteger i = 0; i < buttons.count; i++) {
        UIButton *button = [buttons objectAtIndex:i];
        button.frame = CGRectMake(CGRectGetMinX(rect) + slot * i, CGRectGetMinY(rect), slot, CGRectGetHeight(rect));
    }
}

- (void)placeVolumeAtY:(CGFloat)y width:(CGFloat)width {
    self.speakerLowView.frame = CGRectMake(16.0, y + 4.0, 16.0, 16.0);
    self.speakerHighView.frame = CGRectMake(width - 32.0, y + 4.0, 16.0, 16.0);
    self.volumeSlider.frame = CGRectMake(40.0, y, width - 80.0, 22.0);
}

#pragma mark - refresh

- (void)refreshTrack {
    waPlayer *player = [waPlayer shared];
    waTrack *track = player.currentTrack;
    self.titleLabel.text = track.title.length ? track.title : @"Not Playing";
    self.artistLabel.text = track.artistName ?: @"";
    self.albumLabel.text = track.albumTitle ?: @"";
    BOOL hasTrack = track != nil;
    self.playButton.enabled = hasTrack;
    self.previousButton.enabled = hasTrack;
    self.nextButton.enabled = hasTrack;
    self.scrubber.enabled = hasTrack;
    self.likeItem.enabled = hasTrack;
    [self applyLikeState:track.liked];

    NSString *playName = player.playing ? @"SystemMediaControl-Pause" : @"SystemMediaControl-Play";
    [self.playButton setImage:[self whiteImageNamed:playName] forState:UIControlStateNormal];
    [self.shuffleButton setImage:[UIImage imageNamed:player.shuffleEnabled ? @"WaveShuffleOn" : @"WaveShuffleOff"] forState:UIControlStateNormal];
    NSString *repeatName = @"WaveRepeatOff";
    if (player.repeatMode == waRepeatAll) repeatName = @"WaveRepeatOn";
    else if (player.repeatMode == waRepeatOne) repeatName = @"WaveRepeatOne";
    [self.repeatButton setImage:[UIImage imageNamed:repeatName] forState:UIControlStateNormal];

    NSString *localArt = [[waSession shared] localArtworkPathForTrack:track];
    NSString *art = localArt.length ? localArt : ([track artworkURLForSide:320.0] ?: [waPlayer shared].contextArtworkURL);
    if (art.length) {
        BOOL same = [self.artworkURL isEqualToString:art];
        if (!same || !self.sourceArtwork) {
            self.artworkURL = [art copy];
            UIImage *cached = [[waSession shared] cachedArtwork:art size:CGSizeMake(320.0, 320.0)];
            if (cached) [self applyArtwork:cached];
            else if (!same) [self applyArtwork:nil];
            __weak waPlayerController *weakSelf = self;
            NSString *url = self.artworkURL;
            [[waSession shared] loadArtwork:url size:CGSizeMake(320.0, 320.0) completion:^(UIImage *image) {
                waPlayerController *strongSelf = weakSelf;
                if (!strongSelf || ![strongSelf.artworkURL isEqualToString:url]) return;
                if (image) [strongSelf applyArtwork:image];
            }];
        }
    } else if (self.artworkURL != nil || self.sourceArtwork != nil) {
        self.artworkURL = nil;
        [self applyArtwork:nil];
    }
    [self syncLyricsToCurrentTrack];
    [self updateLyricsVisibility];
    [self.view setNeedsLayout];
}

- (void)applyArtwork:(UIImage *)image {
    self.sourceArtwork = image;
    self.artworkView.image = image;
    self.artGeneration++;
    if (!image) {
        self.reflectionView.image = nil;
        self.reflectionView.hidden = YES;
        self.backdropView.image = nil;
        self.backdropView.backgroundColor = [UIColor blackColor];
        return;
    }
    self.reflectionView.image = [self verticalMirror:image];
    self.reflectionView.hidden = self.showingLyrics;
    [self rebuildBackdrop];
}

- (void)refreshProgress {
    waPlayer *player = [waPlayer shared];
    NSTimeInterval current = player.currentTime;
    NSTimeInterval duration = player.duration;
    self.elapsedLabel.text = waTimeString(current);
    self.remainingLabel.text = [NSString stringWithFormat:@"-%@", waTimeString(MAX(0.0, duration - current))];
    if (!self.scrubbing && duration > 0.0) {
        self.scrubber.maximumValue = (float)duration;
        self.scrubber.value = (float)MIN(current, duration);
    } else if (!self.scrubbing) {
        self.scrubber.maximumValue = 1.0;
        self.scrubber.value = 0.0;
    }
    if (self.showingLyrics) [self.lyricStage setTime:player.outputTime];
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    [self refreshProgress];
    [self syncSystemVolume];
}

- (void)trackChanged:(NSNotification *)note {
    (void)note;
    [self performSelectorOnMainThread:@selector(refreshTrack) withObject:nil waitUntilDone:NO];
}

- (void)stateChanged:(NSNotification *)note {
    (void)note;
    [self performSelectorOnMainThread:@selector(refreshTrack) withObject:nil waitUntilDone:NO];
}

- (void)progressChanged:(NSNotification *)note {
    (void)note;
    [self performSelectorOnMainThread:@selector(refreshProgress) withObject:nil waitUntilDone:NO];
}

#pragma mark - lyrics

- (void)updateLyricsVisibility {
    BOOL show = self.showingLyrics;
    if (!show) [self.lyricStage stopPulse];
    self.lyricStage.hidden = !show;
    self.artworkView.hidden = show;
    self.artWell.hidden = show;
    self.reflectionView.hidden = show || self.sourceArtwork == nil;
    [self.view setNeedsLayout];
    [self layoutChrome];
    if (self.isViewLoaded && self.view.window) [self startProgressTimer];
}

- (void)toggleLyrics {
    if (![waPlayer shared].currentTrack) return;
    self.showingLyrics = !self.showingLyrics;
    [self updateLyricsVisibility];
    if (self.showingLyrics) [self syncLyricsToCurrentTrack];
}

- (void)syncLyricsToCurrentTrack {
    if (!self.showingLyrics) return;
    waTrack *track = [waPlayer shared].currentTrack;
    if (!track) {
        self.lyricsTrackID = nil;
        self.parsedLyrics = nil;
        self.lyricStage.lyrics = nil;
        return;
    }
    if ([self.lyricsTrackID isEqualToString:track.identifier] && self.parsedLyrics) {
        [self.lyricStage setTime:[waPlayer shared].outputTime];
        return;
    }
    [self loadLyricsForTrack:track];
}

- (void)loadLyricsForTrack:(waTrack *)track {
    NSUInteger request = ++self.lyricsRequest;
    self.lyricsTrackID = track.identifier;
    self.parsedLyrics = nil;
    self.lyricStage.loading = YES;
    self.lyricStage.lyrics = nil;
    [self.lyricsSpinner startAnimating];
    __weak waPlayerController *weakSelf = self;
    [[waSession shared] lyricsForTrack:track completion:^(waLyrics *lyrics, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            waPlayerController *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.lyricsRequest != request) return;
            [strongSelf.lyricsSpinner stopAnimating];
            strongSelf.lyricStage.loading = NO;
            waLyrics *ready = lyrics;
            if (ready.instrumental) [ready markInstrumental];
            else if (error || !ready) {
                ready = [[waLyrics alloc] init];
                ready.plain = @"Lyrics not available.";
            }
            strongSelf.parsedLyrics = ready;
            strongSelf.lyricStage.lyrics = ready;
            if (strongSelf.showingLyrics) [strongSelf.lyricStage setTime:[waPlayer shared].outputTime];
        });
    }];
}

#pragma mark - actions

- (void)close {
    [[UIApplication sharedApplication] setStatusBarStyle:UIStatusBarStyleDefault animated:YES];
    [[waRootController shared] hidePlayer];
}

- (void)togglePlayback {
    [[waPlayer shared] toggle];
    [self refreshTrack];
}

- (void)playNext { [[waPlayer shared] playNext]; }
- (void)playPrevious { [[waPlayer shared] playPrevious]; }

- (void)toggleShuffle {
    waPlayer *player = [waPlayer shared];
    player.shuffleEnabled = !player.shuffleEnabled;
    [self refreshTrack];
}

- (void)toggleRepeat {
    waPlayer *player = [waPlayer shared];
    if (player.repeatMode == waRepeatOff) player.repeatMode = waRepeatAll;
    else if (player.repeatMode == waRepeatAll) player.repeatMode = waRepeatOne;
    else player.repeatMode = waRepeatOff;
    [self refreshTrack];
}

- (void)syncSystemVolume {
    if (self.volumeDragging || !self.volumeSlider) return;
    self.volumeSlider.value = [MPMusicPlayerController iPodMusicPlayer].volume;
}

- (void)volumeTouchDown {
    self.volumeDragging = YES;
}

- (void)volumeChanged:(UISlider *)slider {
    [MPMusicPlayerController iPodMusicPlayer].volume = slider.value;
}

- (void)volumeTouchUp {
    self.volumeDragging = NO;
    [self volumeChanged:self.volumeSlider];
}

- (void)systemVolumeChanged:(NSNotification *)note {
    (void)note;
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(systemVolumeChanged:) withObject:note waitUntilDone:NO];
        return;
    }
    [self syncSystemVolume];
}

- (void)scrubBegan { self.scrubbing = YES; }

- (void)scrubChanged {
    self.elapsedLabel.text = waTimeString(self.scrubber.value);
    self.remainingLabel.text = [NSString stringWithFormat:@"-%@", waTimeString(MAX(0.0, [waPlayer shared].duration - self.scrubber.value))];
}

- (void)scrubEnded {
    [[waPlayer shared] seekTo:self.scrubber.value];
    self.scrubbing = NO;
}

- (void)showQueue {
    [self.navigationController pushViewController:[[waQueueController alloc] init] animated:YES];
}

- (void)toggleLike {
    waTrack *track = [waPlayer shared].currentTrack;
    if (!track) return;
    __weak waPlayerController *weakSelf = self;
    BOOL liked = !track.liked;
    [[waSession shared] setLiked:liked track:track completion:^(BOOL ok, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) {
                NSString *message = error.localizedDescription ?: @"Could not update the like.";
                [[[UIAlertView alloc] initWithTitle:@"Like" message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
                return;
            }
            track.liked = liked;
            [weakSelf applyLikeState:liked];
        });
    }];
}

- (void)titleHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    waTrack *track = [waPlayer shared].currentTrack;
    if (!track.identifier.length) return;
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:track.title delegate:self cancelButtonTitle:@"Cancel" destructiveButtonTitle:nil otherButtonTitles:@"Lyrics", @"Copy Link", nil];
    sheet.tag = waPlayerSheetTrack;
    [sheet showInView:self.view];
}

- (void)refreshLastFMButton {
    BOOL active = [waLastFM shared].active;
    [self.lastFMButton setImage:[waLastFM logoActive:active] forState:UIControlStateNormal];
}

- (void)lastFMChanged:(NSNotification *)note {
    (void)note;
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(refreshLastFMButton) withObject:nil waitUntilDone:NO];
        return;
    }
    [self refreshLastFMButton];
}

- (void)lastFMTapped {
    waLastFM *fm = [waLastFM shared];
    if (!fm.signedIn) {
        [self showLastFMLogin];
        return;
    }
    NSString *toggle = fm.scrobblingEnabled ? @"Turn Off Scrobbling" : @"Turn On Scrobbling";
    NSString *title = fm.username.length ? fm.username : @"Last.fm";
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:title
                                                       delegate:self
                                              cancelButtonTitle:@"Cancel"
                                         destructiveButtonTitle:@"Log Out"
                                              otherButtonTitles:toggle, nil];
    sheet.tag = waPlayerSheetLastFM;
    UIView *host = self.navigationController.view ?: self.view;
    [sheet showInView:host];
}

- (void)showLastFMLogin {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Last.fm"
                                                    message:@"Sign in to scrobble what you play."
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Sign In", nil];
    alert.alertViewStyle = UIAlertViewStyleLoginAndPasswordInput;
    alert.tag = waPlayerAlertLastFMLogin;
    [alert textFieldAtIndex:0].placeholder = @"Username";
    [alert textFieldAtIndex:1].placeholder = @"Password";
    [alert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag != waPlayerAlertLastFMLogin) return;
    if (buttonIndex == alertView.cancelButtonIndex) return;
    NSString *username = [alertView textFieldAtIndex:0].text;
    NSString *password = [alertView textFieldAtIndex:1].text;
    __weak waPlayerController *weakSelf = self;
    [[waLastFM shared] loginWithUsername:username password:password completion:^(BOOL ok, NSError *error) {
        waPlayerController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf refreshLastFMButton];
        if (ok) return;
        NSString *message = error.localizedDescription.length ? error.localizedDescription : @"Could not sign in.";
        [[[UIAlertView alloc] initWithTitle:@"Last.fm" message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
    }];
}

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == actionSheet.cancelButtonIndex) return;
    if (actionSheet.tag == waPlayerSheetLastFM) {
        waLastFM *fm = [waLastFM shared];
        if (buttonIndex == actionSheet.destructiveButtonIndex) [fm logout];
        else [fm setScrobblingEnabled:!fm.scrobblingEnabled];
        [self refreshLastFMButton];
        return;
    }
    if (buttonIndex == 0) {
        if (!self.showingLyrics) [self toggleLyrics];
    } else if (buttonIndex == 1) {
        waTrack *track = [waPlayer shared].currentTrack;
        if (!track.identifier.length) return;
        NSString *link = [NSString stringWithFormat:@"https://www.deezer.com/track/%@", track.identifier];
        [[UIPasteboard generalPasteboard] setString:link];
    }
}

@end
