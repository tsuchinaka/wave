#import "waLyricsViewController.h"
#import "../Services/waDeezerStreamClient.h"
#import "../Services/waTheme.h"
#import "../Services/waAudioPlayer.h"
#import "../Audio/waAudioEngine.h"

@interface waLyricsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *track;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic, copy) NSString *trackId;
@property (nonatomic, copy) NSString *isrc;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *spinnerBackdrop;
@property (nonatomic, strong) NSArray *lines;
@property (nonatomic, assign) BOOL hasWordSync;
@property (nonatomic, assign) NSInteger highlightedLine;
@property (nonatomic, assign) NSInteger highlightedWord;
@property (nonatomic, strong) NSTimer *syncTimer;
@property (nonatomic, assign) NSUInteger lyricsRequest;
@property (nonatomic, assign) BOOL lyricsVisible;
// Scroll-hot caches rebuilt once per lyrics/theme load so the highlight
// timer, heightForRow and cellForRow never walk payload dicts per frame.
@property (nonatomic, strong) NSArray *lineStartTimes;
@property (nonatomic, strong) NSArray *cachedHeights;
@property (nonatomic, assign) CGFloat cachedHeightsWidth;
@property (nonatomic, strong) NSArray *cachedInactiveAttributed;
@property (nonatomic, strong) NSArray *cachedActiveAttributed;
@property (nonatomic, copy) NSString *cachedLyricsThemeKey;
@end

@implementation waLyricsViewController

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:waAudioPlayerDidChangeNotification object:nil];
    [self.syncTimer invalidate];
}

- (id)initWithTrack:(NSString *)track artist:(NSString *)artist {
    return [self initWithTrack:track artist:artist album:nil duration:0.0];
}

- (id)initWithTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album duration:(NSTimeInterval)duration {
    return [self initWithTrack:track artist:artist album:album duration:duration trackId:nil isrc:nil];
}

- (id)initWithTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album duration:(NSTimeInterval)duration trackId:(NSString *)trackId isrc:(NSString *)isrc {
    if ((self = [super init])) {
        _track = [track copy];
        _artist = [artist copy];
        _album = [album copy];
        _trackId = [trackId copy];
        _isrc = [isrc copy];
        _duration = duration;
        _highlightedLine = NSNotFound;
        _highlightedWord = NSNotFound;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Lyrics";
    self.view.backgroundColor = [waTheme backgroundColor];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = [waTheme backgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.hidden = YES;
    [self.view addSubview:self.tableView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    self.spinnerBackdrop = [waTheme circularBackdropForSpinner:self.spinner];
    [self.view addSubview:self.spinnerBackdrop];
    [self.view bringSubviewToFront:self.spinnerBackdrop];
    [self layoutSpinner];
}

- (void)loadLyrics {
    if (!self.lyricsVisible) return;
    [self.syncTimer invalidate];
    self.syncTimer = nil;
    self.lines = nil;
    self.lineStartTimes = nil;
    self.cachedHeights = nil;
    self.cachedInactiveAttributed = nil;
    self.cachedActiveAttributed = nil;
    self.hasWordSync = NO;
    self.highlightedLine = NSNotFound;
    self.highlightedWord = NSNotFound;
    self.tableView.hidden = YES;
    [self.tableView reloadData];
    [self.spinner startAnimating];
    self.spinnerBackdrop.hidden = NO;
    NSUInteger request = ++self.lyricsRequest;

    // Serverless: Deezer hidden song.getLyrics direct (fallback to "unavailable" message)
    NSString *deezerId = self.trackId.length ? self.trackId : nil;
    if (deezerId.length) {
        [[waDeezerStreamClient sharedClient] fetchLyricsForTrackID:deezerId completion:^(NSDictionary *payload, NSError *error) {
            if (request != self.lyricsRequest || !self.lyricsVisible) return;
            if (!error && payload) {
                BOOL instrumental = [payload[@"instrumental"] boolValue];
                if (instrumental) {
                    self.lines = @[ @{ @"text": @"🎵" } ];
                    self.hasWordSync = NO;
                    [self.spinner stopAnimating];
                    self.spinnerBackdrop.hidden = YES;
                    self.tableView.hidden = NO;
                    [self rebuildLyricCaches];
                    [self.tableView reloadData];
                    return;
                }
                NSArray *lineSynced = [payload[@"lineSynced"] isKindOfClass:[NSArray class]] ? payload[@"lineSynced"] : @[];
                NSString *plain = [payload[@"plain"] isKindOfClass:[NSString class]] ? payload[@"plain"] : nil;
                if (lineSynced.count) {
                    // lineSynced already [{time, text}] from Deezer milliseconds
                    NSMutableArray *converted = [NSMutableArray arrayWithCapacity:lineSynced.count];
                    for (NSDictionary *l in lineSynced) {
                        if (![l isKindOfClass:[NSDictionary class]]) continue;
                        [converted addObject:@{@"time": l[@"time"] ?: @(-1), @"text": l[@"text"] ?: @""}];
                    }
                    self.lines = converted;
                    self.hasWordSync = NO;
                    [self.spinner stopAnimating];
                    self.spinnerBackdrop.hidden = YES;
                    self.tableView.hidden = NO;
                    [self rebuildLyricCaches];
                    [self.tableView reloadData];
                    [self startSyncTimer];
                    [self updateHighlight:nil];
                    return;
                } else if (plain.length) {
                    // Plain unsynced: show all lines static, no karaoke highlight/scroll
                    NSMutableArray *fallback = [NSMutableArray array];
                    // Deezer TEXT uses \r\n -> split on \n and trim \r
                    for (NSString *rawLine in [plain componentsSeparatedByString:@"\n"]) {
                        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\r"]];
                        if (line.length) [fallback addObject:@{ @"time": @(-1), @"text": line }];
                    }
                    self.lines = fallback.count ? fallback : @[ @{ @"text": plain } ];
                    self.hasWordSync = NO;
                    [self.spinner stopAnimating];
                    self.spinnerBackdrop.hidden = YES;
                    self.tableView.hidden = NO;
                    [self rebuildLyricCaches];
                    [self.tableView reloadData];
                    // Do NOT start sync timer for unsynced plain lyrics - would highlight last line
                    self.highlightedLine = NSNotFound;
                    return;
                }
            }
            // Deezer miss or error -> show unavailable (LRCLIB fallback could be added here)
            [self showError:error.localizedDescription ?: @"Lyrics unavailable."];
        }];
        return;
    }
    // No deezerId -> fallback to old path (should not happen, but keep)
    [[waDeezerStreamClient sharedClient] fetchLyricsForTrackID:self.trackId ?: @"" completion:^(NSDictionary *payload, NSError *error) {
        // A previous request may finish after the song changed. Never let its
        // lyrics replace the result for the current track.
        if (request != self.lyricsRequest || !self.lyricsVisible) return;
        if (error) {
            [self showError:error.localizedDescription];
            return;
        }
        NSDictionary *lyrics = [payload[@"lyrics"] isKindOfClass:[NSDictionary class]] ? payload[@"lyrics"] : payload;
        if ([payload[@"instrumental"] boolValue] || [lyrics[@"instrumental"] boolValue]) {
            self.lines = @[ @{ @"text": @"🎵" } ];
            self.hasWordSync = NO;
        }
        NSArray *wordLines = [self linesFromPayload:lyrics[@"wordSynced"]];
        if (!wordLines.count) wordLines = [self linesFromPayload:payload[@"wordSynced"]];
        NSArray *lineLines = [self linesFromPayload:lyrics[@"lineSynced"]];
        if (!lineLines.count) lineLines = [self linesFromPayload:payload[@"lineSynced"]];
        if (!self.lines.count && wordLines.count) {
            self.lines = wordLines;
            self.hasWordSync = YES;
        } else if (!self.lines.count && lineLines.count) {
            self.lines = lineLines;
            self.hasWordSync = NO;
        } else if (!self.lines.count) {
            NSString *plain = [lyrics[@"plain"] isKindOfClass:[NSDictionary class]] ? lyrics[@"plain"][@"text"] : nil;
            if (!plain.length && [lyrics[@"plain"] isKindOfClass:[NSString class]]) plain = lyrics[@"plain"];
            if ([plain isKindOfClass:[NSString class]] && plain.length) {
                NSMutableArray *fallback = [NSMutableArray array];
                for (NSString *line in [plain componentsSeparatedByString:@"\n"]) [fallback addObject:@{ @"time": @(-1), @"text": line }];
                self.lines = fallback;
                self.hasWordSync = NO;
            }
        }
        if (!self.lines.count) {
            [self showError:@"Lyrics unavailable."];
            return;
        }
        [self.spinner stopAnimating];
        self.tableView.hidden = NO;
        [self rebuildLyricCaches];
        [self.tableView reloadData];
        [self startSyncTimer];
        [self updateHighlight:nil];
    }];
}

- (void)playerDidChange:(NSNotification *)notification {
    (void)notification;
    if (!self.lyricsVisible) return;
    waMediaItem *item = [waAudioPlayer sharedPlayer].currentItem;
    if (!item) return;
    NSString *track = item.title ?: @"";
    NSString *artist = item.artistName.length ? item.artistName : item.subtitle;
    NSString *trackId = [self canonicalTrackIdentifierForItem:item];
    NSString *isrc = item.isrc;
    if ([track isEqualToString:self.track] && [artist isEqualToString:self.artist] && [item.albumName isEqualToString:self.album] && [trackId isEqualToString:self.trackId] && [isrc isEqualToString:self.isrc] && fabs(item.duration - self.duration) < 0.5) return;
    self.track = track;
    self.artist = artist;
    self.album = item.albumName;
    self.trackId = trackId;
    self.isrc = isrc;
    self.duration = item.duration;
    [self loadLyrics];
}

- (NSString *)canonicalTrackIdentifierForItem:(waMediaItem *)item {
    NSString *trackId = item.trackId;
    return [trackId hasPrefix:@"deezer:"] ? trackId : nil;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutSpinner];
}

- (void)layoutSpinner {
    self.spinnerBackdrop.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
}

- (NSArray *)linesFromPayload:(id)value {
    if ([value isKindOfClass:[NSArray class]]) return value;
    if ([value isKindOfClass:[NSDictionary class]] && [value[@"lines"] isKindOfClass:[NSArray class]]) return value[@"lines"];
    return @[];
}

- (void)showError:(NSString *)message {
    [self.spinner stopAnimating];
    self.spinnerBackdrop.hidden = YES;
    self.tableView.hidden = NO;
    self.lines = @[ @{ @"error": message.length ? message : @"Lyrics unavailable." } ];
    [self rebuildLyricCaches];
    [self.tableView reloadData];
}

- (NSTimeInterval)timeForLine:(NSDictionary *)line {
    id value = line[@"time"] ?: line[@"start"];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : -1.0;
}

- (NSArray *)wordsForLine:(NSDictionary *)line {
    id words = line[@"syncedLyric"] ?: line[@"words"] ?: line[@"wordSynced"];
    if ([words isKindOfClass:[NSDictionary class]]) words = words[@"words"];
    return [words isKindOfClass:[NSArray class]] ? words : @[];
}

- (NSString *)textForLine:(NSDictionary *)line {
    if ([line[@"text"] isKindOfClass:[NSString class]]) return line[@"text"];
    if ([line[@"lyric"] isKindOfClass:[NSString class]]) return line[@"lyric"];
    NSMutableString *text = [NSMutableString string];
    for (NSDictionary *word in [self wordsForLine:line]) {
        if (![word isKindOfClass:[NSDictionary class]]) continue;
        NSString *wordText = [word[@"text"] isKindOfClass:[NSString class]] ? word[@"text"] : word[@"character"];
        if ([wordText isKindOfClass:[NSString class]]) [text appendString:wordText];
    }
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

- (void)startSyncTimer {
    [self.syncTimer invalidate];
    // Default runloop mode pauses mid-scroll so highlighting never fights
    // the scroll render loop. 0.25s is plenty for line-level changes; word
    // updates inside the active line patch its label directly.
    self.syncTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(updateHighlight:) userInfo:nil repeats:YES];
}

- (NSInteger)wordIndexForLine:(NSDictionary *)line atTime:(NSTimeInterval)now {
    NSInteger currentWord = NSNotFound;
    NSTimeInterval lineStart = [self timeForLine:line];
    NSArray *words = [self wordsForLine:line];
    for (NSInteger index = 0; index < (NSInteger)words.count; index++) {
        NSDictionary *word = words[index];
        NSTimeInterval wordTime = [word[@"time"] doubleValue];
        if (lineStart + wordTime <= now) currentWord = index;
        else break;
    }
    return currentWord;
}

- (NSAttributedString *)attributedTextForLine:(NSDictionary *)line active:(BOOL)isActive atTime:(NSTimeInterval)now {
    NSString *text = line[@"error"] ?: [self textForLine:line];
    UIColor *normal = [waTheme primaryTextColor];
    UIColor *color = isActive ? [UIColor whiteColor] : (line[@"error"] ? [UIColor redColor] : normal);
    UIFont *font = isActive ? [waTheme boldFontOfSize:18.0] : [waTheme regularFontOfSize:17.0];
    NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString:text attributes:@{ NSForegroundColorAttributeName:color, NSFontAttributeName:font }];
    if (!isActive || !self.hasWordSync) return attributed;

    NSTimeInterval lineStart = [self timeForLine:line];
    NSUInteger offset = 0;
    for (NSDictionary *word in [self wordsForLine:line]) {
        NSString *wordText = [word[@"text"] isKindOfClass:[NSString class]] ? word[@"text"] : word[@"character"];
        if (![wordText isKindOfClass:[NSString class]]) continue;
        NSRange range = NSMakeRange(offset, MIN(wordText.length, text.length - MIN(offset, text.length)));
        if (lineStart + [word[@"time"] doubleValue] > now && NSMaxRange(range) <= attributed.length) {
            [attributed addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithWhite:1.0 alpha:0.55] range:range];
        }
        offset = MIN(text.length, offset + wordText.length);
    }
    return attributed;
}

- (void)rebuildLyricCaches {
    // Precompute start times, row heights and static attributed strings once
    // per lyrics/theme load. The highlight timer then scans plain doubles
    // and cellForRow serves cached strings instead of rebuilding per frame.
    NSMutableArray *starts = [NSMutableArray arrayWithCapacity:self.lines.count];
    for (NSDictionary *line in self.lines) [starts addObject:@([self timeForLine:line])];
    self.lineStartTimes = starts;
    CGFloat width = self.tableView.bounds.size.width - 32.0;
    if (width <= 0.0) width = 288.0;
    self.cachedHeightsWidth = width + 32.0;
    UIFont *font = [waTheme regularFontOfSize:17.0];
    NSMutableArray *heights = [NSMutableArray arrayWithCapacity:self.lines.count];
    NSMutableArray *inactive = [NSMutableArray arrayWithCapacity:self.lines.count];
    NSMutableArray *active = [NSMutableArray arrayWithCapacity:self.lines.count];
    for (NSDictionary *line in self.lines) {
        NSString *text = line[@"error"] ?: [self textForLine:line];
        CGSize size = [text sizeWithFont:font constrainedToSize:CGSizeMake(width, CGFLOAT_MAX) lineBreakMode:NSLineBreakByWordWrapping];
        [heights addObject:@(MAX(44.0, size.height + 20.0))];
        [inactive addObject:[self attributedTextForLine:line active:NO atTime:0.0]];
        // Far-future time disables word dimming so the cached active string
        // is the static fully-highlighted form (used only when !hasWordSync).
        [active addObject:[self attributedTextForLine:line active:YES atTime:1e9]];
    }
    self.cachedHeights = heights;
    self.cachedInactiveAttributed = inactive;
    self.cachedActiveAttributed = active;
    self.cachedLyricsThemeKey = [waTheme renderCacheKeyForColor:[waTheme barColor]];
}

- (void)updateHighlight:(id)sender {
    (void)sender;
    if (!self.lyricsVisible || !self.lines.count || self.lines[0][@"error"]) return;
    if (self.lineStartTimes.count != self.lines.count) [self rebuildLyricCaches];
    // Unsynced plain lyrics (all times < 0) -> no karaoke highlight at all
    BOOL hasSync = NO;
    for (NSNumber *t in self.lineStartTimes) if ([t doubleValue] >= 0) { hasSync = YES; break; }
    if (!hasSync) return;
    NSTimeInterval now = [waAudioEngine sharedEngine].currentTime;
    NSInteger lineIndex = NSNotFound;
    for (NSInteger index = 0; index < (NSInteger)self.lineStartTimes.count; index++) {
        NSTimeInterval start = [self.lineStartTimes[index] doubleValue];
        if (start < 0.0 || start <= now) lineIndex = index;
        else break;
    }
    if (lineIndex == NSNotFound) return;
    NSInteger previousLine = self.highlightedLine;
    BOOL lineChanged = lineIndex != previousLine;
    self.highlightedLine = lineIndex;
    NSIndexPath *path = [NSIndexPath indexPathForRow:lineIndex inSection:0];
    if (lineChanged) {
        self.highlightedWord = self.hasWordSync ? [self wordIndexForLine:self.lines[lineIndex] atTime:now] : NSNotFound;
        NSMutableArray *paths = [NSMutableArray arrayWithObject:path];
        if (previousLine != NSNotFound && previousLine >= 0 && previousLine < (NSInteger)self.lines.count) {
            [paths addObject:[NSIndexPath indexPathForRow:previousLine inSection:0]];
        }
        [self.tableView reloadRowsAtIndexPaths:paths withRowAnimation:UITableViewRowAnimationNone];
        // Karaoke follow: keep the active line centered as the song
        // advances. Hands off while the user is touching the list so a
        // manual read is never yanked away; the next line change recenters.
        BOOL userScrolling = self.tableView.dragging || self.tableView.decelerating || self.tableView.tracking;
        if (!userScrolling && [self.tableView numberOfRowsInSection:0] > lineIndex) {
            [self.tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
        }
    } else if (self.hasWordSync && [self.tableView numberOfRowsInSection:0] > lineIndex) {
        NSInteger word = [self wordIndexForLine:self.lines[lineIndex] atTime:now];
        if (word == self.highlightedWord) return;
        self.highlightedWord = word;
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
        if (cell) cell.textLabel.attributedText = [self attributedTextForLine:self.lines[lineIndex] active:YES atTime:now];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return self.lines.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"lyrics"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"lyrics"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSDictionary *line = self.lines[indexPath.row];
    UIColor *normal = [waTheme primaryTextColor];
    BOOL isActiveLine = indexPath.row == self.highlightedLine && !line[@"error"];
    UIColor *active = [UIColor whiteColor];
    UIColor *background = isActiveLine ? [waTheme barColor] : [waTheme backgroundColor];
    cell.backgroundColor = background;
    cell.contentView.backgroundColor = background;
    cell.textLabel.backgroundColor = [UIColor clearColor];
    cell.textLabel.textColor = isActiveLine ? active : normal;
    if (isActiveLine && self.hasWordSync) {
        cell.textLabel.attributedText = [self attributedTextForLine:line active:YES atTime:[waAudioEngine sharedEngine].currentTime];
    } else if (indexPath.row < (NSInteger)self.cachedInactiveAttributed.count && indexPath.row < (NSInteger)self.cachedActiveAttributed.count) {
        cell.textLabel.attributedText = isActiveLine ? self.cachedActiveAttributed[indexPath.row] : self.cachedInactiveAttributed[indexPath.row];
    } else {
        cell.textLabel.attributedText = [self attributedTextForLine:line active:isActiveLine atTime:[waAudioEngine sharedEngine].currentTime];
    }
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row < (NSInteger)self.cachedHeights.count &&
        fabs(self.cachedHeightsWidth - tableView.bounds.size.width) < 0.5) {
        return [self.cachedHeights[indexPath.row] doubleValue];
    }
    // Width changed (rotation): rebuild once, then serve from cache again.
    if (self.lines.count) [self rebuildLyricCaches];
    if (indexPath.row < (NSInteger)self.cachedHeights.count) return [self.cachedHeights[indexPath.row] doubleValue];
    NSString *text = self.lines[indexPath.row][@"error"] ?: [self textForLine:self.lines[indexPath.row]];
    CGSize size = [text sizeWithFont:[waTheme regularFontOfSize:17.0] constrainedToSize:CGSizeMake(tableView.bounds.size.width - 32.0, CGFLOAT_MAX) lineBreakMode:NSLineBreakByWordWrapping];
    return MAX(44.0, size.height + 20.0);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    self.lyricsVisible = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerDidChange:) name:waAudioPlayerDidChangeNotification object:nil];
    self.view.backgroundColor = [waTheme backgroundColor];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    // Cached attributed strings embed theme colors/fonts; rebuild once when
    // the theme changed while the view was hidden.
    if (self.lines.count && ![self.cachedLyricsThemeKey isEqualToString:[waTheme renderCacheKeyForColor:[waTheme barColor]]]) {
        [self rebuildLyricCaches];
        [self.tableView reloadData];
    }
    waMediaItem *item = [waAudioPlayer sharedPlayer].currentItem;
    if (item) {
        NSString *track = item.title ?: @"";
        NSString *artist = item.artistName.length ? item.artistName : item.subtitle;
        NSString *trackId = [self canonicalTrackIdentifierForItem:item];
        NSString *isrc = item.isrc;
        if (![track isEqualToString:self.track] || ![artist isEqualToString:self.artist] || ![item.albumName isEqualToString:self.album] || ![trackId isEqualToString:self.trackId] || ![isrc isEqualToString:self.isrc] || fabs(item.duration - self.duration) >= 0.5) {
            self.track = track;
            self.artist = artist;
            self.album = item.albumName;
            self.trackId = trackId;
            self.isrc = isrc;
            self.duration = item.duration;
            [self loadLyrics];
        } else if (!self.lines.count) {
            [self.spinner startAnimating];
            [self loadLyrics];
        } else if (!self.syncTimer) {
            [self startSyncTimer];
            [self updateHighlight:nil];
        }
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.lyricsVisible = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self name:waAudioPlayerDidChangeNotification object:nil];
    [self.syncTimer invalidate];
    self.syncTimer = nil;
    self.lyricsRequest += 1;
}

@end
