#import "waLyricsController.h"
#import "waPlayer.h"
#import "waSession.h"
#import "waLyrics.h"
#import <QuartzCore/CADisplayLink.h>

@interface waLyricsController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) waTrack *track;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, copy) NSArray *lines;
@property (nonatomic, copy) NSArray *times;
@property (nonatomic, assign) NSInteger activeIndex;
@property (nonatomic, assign) NSUInteger requestID;
@property (nonatomic, assign) BOOL synced;
@property (nonatomic, strong) CADisplayLink *highlightLink;
@end

@implementation waLyricsController

- (id)init {
    return [self initWithTrack:[waPlayer shared].currentTrack];
}

- (id)initWithTrack:(waTrack *)track {
    if ((self = [super init])) {
        _track = track;
        _activeIndex = NSNotFound;
        _lines = [NSArray array];
        _times = [NSArray array];
        self.title = @"Lyrics";
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.highlightLink invalidate];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientation {
    return orientation != UIInterfaceOrientationPortraitUpsideDown;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor blackColor];
    self.tableView.hidden = YES;
    [self.view addSubview:self.tableView];

    self.messageLabel = [[UILabel alloc] initWithFrame:self.view.bounds];
    self.messageLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.messageLabel.backgroundColor = [UIColor clearColor];
    self.messageLabel.textAlignment = UITextAlignmentCenter;
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.font = [UIFont systemFontOfSize:15.0];
    self.messageLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    self.messageLabel.hidden = YES;
    [self.view addSubview:self.messageLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.spinner];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(trackDidChange:) name:waPlayerTrackDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(progressDidChange:) name:waPlayerProgressNotification object:nil];
    [self loadLyrics];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.highlightLink invalidate];
    self.highlightLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayFired:)];
    self.highlightLink.frameInterval = 2;
    [self.highlightLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.highlightLink invalidate];
    self.highlightLink = nil;
}

- (void)displayFired:(CADisplayLink *)link {
    (void)link;
    [self updateHighlight];
}

- (void)trackDidChange:(NSNotification *)note {
    (void)note;
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(trackDidChange:) withObject:note waitUntilDone:NO];
        return;
    }
    waTrack *current = [waPlayer shared].currentTrack;
    if (!current) {
        [self showMessage:@"No song is playing."];
        return;
    }
    NSString *next = [current.identifier description];
    NSString *have = [self.track.identifier description];
    BOOL same = NO;
    if (next.length && have.length) same = [next isEqualToString:have];
    else if (!next.length && !have.length) {
        same = [current.title ?: @"" isEqualToString:self.track.title ?: @""] && [current.artistName ?: @"" isEqualToString:self.track.artistName ?: @""];
    }
    if (same) return;
    self.track = current;
    [self loadLyrics];
}

- (void)progressDidChange:(NSNotification *)note {
    (void)note;
    [self updateHighlight];
}

- (void)showMessage:(NSString *)message {
    self.tableView.hidden = YES;
    self.messageLabel.hidden = NO;
    self.messageLabel.text = message;
    [self.spinner stopAnimating];
}

- (void)loadLyrics {
    waTrack *track = self.track;
    if (!track) {
        [self showMessage:@"No song is playing."];
        return;
    }
    NSUInteger request = ++self.requestID;
    self.lines = [NSArray array];
    self.times = [NSArray array];
    self.activeIndex = NSNotFound;
    self.synced = NO;
    self.tableView.hidden = YES;
    self.messageLabel.hidden = YES;
    [self.spinner startAnimating];
    __weak waLyricsController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        waLyricsController *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.requestID != request) return;
        if (!strongSelf.spinner.isAnimating) return;
        [strongSelf showMessage:@"Lyrics not available."];
    });
    [[waSession shared] lyricsForTrack:track completion:^(waLyrics *lyrics, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            waLyricsController *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.requestID != request) return;
            [strongSelf.spinner stopAnimating];
            if (error || !lyrics) {
                [strongSelf showMessage:@"Lyrics not available."];
                return;
            }
            if (lyrics.instrumental) {
                [strongSelf showMessage:@"Instrumental"];
                return;
            }
            @try { [strongSelf applyLyrics:lyrics]; }
            @catch (NSException *exception) {
                [strongSelf showMessage:@"Lyrics not available."];
            }
        });
    }];
}

- (void)applyLyrics:(waLyrics *)lyrics {
    NSMutableArray *texts = [NSMutableArray array];
    NSMutableArray *times = [NSMutableArray array];
    if (lyrics.lines.count) {
        for (waLyricLine *line in lyrics.lines) {
            [texts addObject:line.text ?: @""];
            [times addObject:[NSNumber numberWithDouble:line.start]];
        }
        self.synced = texts.count > 0;
    }
    if (!texts.count && lyrics.plain.length) {
        for (NSString *raw in [lyrics.plain componentsSeparatedByString:@"\n"]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!line.length) continue;
            [texts addObject:line];
            [times addObject:[NSNumber numberWithDouble:-1.0]];
        }
    }
    if (!texts.count) {
        [self showMessage:@"Lyrics not available."];
        return;
    }
    self.lines = texts;
    self.times = times;
    self.activeIndex = NSNotFound;
    self.tableView.hidden = NO;
    self.messageLabel.hidden = YES;
    [self.tableView reloadData];
    [self updateHighlight];
}

- (void)updateHighlight {
    if (!self.synced || !self.lines.count || self.times.count != self.lines.count) return;
    NSTimeInterval position = [waPlayer shared].outputTime;
    NSInteger best = NSNotFound;
    NSInteger count = (NSInteger)self.lines.count;
    for (NSUInteger i = 0; i < self.times.count; i++) {
        NSTimeInterval time = [[self.times objectAtIndex:i] doubleValue];
        if (time >= 0.0 && time <= position) best = (NSInteger)i;
    }
    if (best != self.activeIndex) {
        NSInteger previous = self.activeIndex;
        self.activeIndex = best;
        NSMutableArray *paths = [NSMutableArray array];
        if (previous != NSNotFound && previous >= 0 && previous < count) [paths addObject:[NSIndexPath indexPathForRow:previous inSection:0]];
        if (best != NSNotFound && best >= 0 && best < count) [paths addObject:[NSIndexPath indexPathForRow:best inSection:0]];
        if (paths.count) [self.tableView reloadRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationNone];
        if (best != NSNotFound && !self.tableView.dragging && !self.tableView.decelerating) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:best inSection:0];
            [self.tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
        }
    }
}

#pragma mark - table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)self.lines.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *text = [self.lines objectAtIndex:(NSUInteger)indexPath.row];
    CGSize max = CGSizeMake(CGRectGetWidth(tableView.bounds) - 40.0, 1000.0);
    CGSize size = [text sizeWithFont:[UIFont systemFontOfSize:15.0] constrainedToSize:max lineBreakMode:UILineBreakModeWordWrap];
    return MAX(36.0, size.height + 16.0);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *kID = @"lyric.cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kID];
        cell.backgroundColor = [UIColor blackColor];
        cell.textLabel.backgroundColor = [UIColor clearColor];
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.textAlignment = UITextAlignmentCenter;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    BOOL active = indexPath.row == self.activeIndex;
    cell.textLabel.text = [self.lines objectAtIndex:(NSUInteger)indexPath.row];
    cell.textLabel.font = active ? [UIFont boldSystemFontOfSize:16.0] : [UIFont systemFontOfSize:15.0];
    cell.textLabel.textColor = active ? [UIColor whiteColor] : [UIColor colorWithWhite:0.55 alpha:1.0];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

@end
