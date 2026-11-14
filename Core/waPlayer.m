#import "waPlayer.h"
#import "waSession.h"
#import "waAudioCore.h"
#import "waLog.h"
#import "waDownloader.h"
#import "waAudioProbe.h"
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>

NSString * const waPlayerTrackDidChangeNotification = @"waPlayerTrackDidChange";
NSString * const waPlayerStateDidChangeNotification = @"waPlayerStateDidChange";
NSString * const waPlayerQueueDidChangeNotification = @"waPlayerQueueDidChange";
NSString * const waPlayerProgressNotification = @"waPlayerProgressDidChange";
NSString * const waPlayerDidFailNotification = @"waPlayerDidFail";

static NSString * const waShuffleKey = @"wave.shuffle";
static NSString * const waRepeatKey = @"wave.repeat";
static NSString * const waCrossfadeKey = @"wave.crossfade";
static NSString * const waCrossfadeDurationKey = @"wave.crossfadeDuration";
static NSString * const waEQKey = @"wave.eq";
static NSString * const waLimiterKey = @"wave.compressor";
static NSString * const waVolumeKey = @"wave.volume";

@interface waPlayer () <waAudioCoreDelegate>
@property (nonatomic, strong) waAudioCore *core;
@property (nonatomic, strong) NSMutableArray *items;
@property (nonatomic, strong) NSMutableArray *shuffleHistory;
@property (nonatomic, assign) NSUInteger cursor;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) BOOL seekingNow;
@property (nonatomic, strong) NSTimer *ticker;
@property (nonatomic, strong) NSError *lastError;
@property (nonatomic, copy) NSString *contextName;
@property (nonatomic, copy) NSString *contextArtworkURL;
@property (nonatomic, assign) waQuality activeQuality;
@property (nonatomic, assign) double bitrateKbps;
@property (nonatomic, strong) NSString *presetName;
@property (nonatomic, assign) BOOL audioSessionReady;
@property (nonatomic, assign) NSUInteger loadGeneration;
@property (nonatomic, assign) NSUInteger upcomingIndex;
@property (nonatomic, assign) BOOL upcomingValid;
@property (nonatomic, copy) NSString *nowPlayingArtworkKey;
@property (nonatomic, strong) MPMediaItemArtwork *nowPlayingArtwork;
@property (nonatomic, assign) NSTimeInterval resumePosition;
@property (nonatomic, assign) BOOL persistPending;
@property (nonatomic, assign) NSTimeInterval lastPersistTime;
@property (nonatomic, assign) dispatch_queue_t persistQueue;
@end

@implementation waPlayer {
    float _gains[5];
}

+ (waPlayer *)shared {
    static waPlayer *player;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ player = [[waPlayer alloc] init]; });
    return player;
}

- (id)init {
    if ((self = [super init])) {
        _items = [[NSMutableArray alloc] init];
        _shuffleHistory = [[NSMutableArray alloc] init];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        _shuffleEnabled = [defaults boolForKey:waShuffleKey];
        _repeatMode = (waRepeatMode)[defaults integerForKey:waRepeatKey];
        _crossfadeEnabled = [defaults boolForKey:waCrossfadeKey];
        _crossfadeDuration = [defaults objectForKey:waCrossfadeDurationKey] ? [defaults doubleForKey:waCrossfadeDurationKey] : 4.0;
        _volume = [defaults objectForKey:waVolumeKey] ? [defaults floatForKey:waVolumeKey] : 1.0f;
        _presetName = [defaults stringForKey:waEQKey] ?: @"Flat";
        [self gainsForPreset:_presetName];
        _persistQueue = dispatch_queue_create("wave.player.persist", DISPATCH_QUEUE_SERIAL);
        [self restoreQueue];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(persistNow) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:self selector:@selector(persistNow) name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(persistNow) name:UIApplicationWillTerminateNotification object:nil];
    }
    return self;
}

#pragma mark - accessors

- (NSArray *)queue { return [self.items copy]; }
- (NSUInteger)index { return self.cursor; }
- (waTrack *)currentTrack { return self.cursor < self.items.count ? [self.items objectAtIndex:self.cursor] : nil; }
- (BOOL)seekable { return self.core.ready && !self.loading; }
- (NSTimeInterval)currentTime {
    if (self.core) return self.core.position;
    return self.resumePosition;
}
- (NSTimeInterval)outputTime {
    if (self.core) return self.core.outputPosition;
    return self.resumePosition;
}
- (NSTimeInterval)duration {
    NSTimeInterval value = self.core ? self.core.duration : 0.0;
    if (value <= 0.0 && self.currentTrack) value = self.currentTrack.duration;
    return value;
}
- (BOOL)lossless { return self.activeQuality >= waQualityFLAC; }

- (void)setRepeatMode:(waRepeatMode)repeatMode {
    _repeatMode = repeatMode;
    [[NSUserDefaults standardUserDefaults] setInteger:repeatMode forKey:waRepeatKey];
    if (repeatMode == waRepeatOne) {
        self.upcomingValid = NO;
        [self.core cancelNext];
        self.core.autoOverlap = 0.0;
    } else if (self.core && !self.upcomingValid && !self.core.overlapping) {
        [self prefetchNext];
    } else {
        [self updateAutoOverlap];
    }
    [self notifyState];
}

- (void)setShuffleEnabled:(BOOL)shuffleEnabled {
    _shuffleEnabled = shuffleEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:shuffleEnabled forKey:waShuffleKey];
    [self.shuffleHistory removeAllObjects];
    if (self.core && !self.core.overlapping) {
        self.upcomingValid = NO;
        [self.core cancelNext];
        [self prefetchNext];
    }
    [self notifyState];
}

- (void)setCrossfadeEnabled:(BOOL)crossfadeEnabled {
    _crossfadeEnabled = crossfadeEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:crossfadeEnabled forKey:waCrossfadeKey];
    [self updateAutoOverlap];
}

- (void)setCrossfadeDuration:(NSTimeInterval)crossfadeDuration {
    _crossfadeDuration = MAX(0.0, MIN(12.0, crossfadeDuration));
    [[NSUserDefaults standardUserDefaults] setDouble:_crossfadeDuration forKey:waCrossfadeDurationKey];
    [self updateAutoOverlap];
}

- (void)setVolume:(float)volume {
    _volume = MAX(0.0f, MIN(1.0f, volume));
    self.core.volume = _volume;
    [[NSUserDefaults standardUserDefaults] setFloat:_volume forKey:waVolumeKey];
}

- (void)setActiveQuality:(waQuality)quality {
    _activeQuality = quality;
}

#pragma mark - playback

- (void)playTracks:(NSArray *)tracks startAt:(NSUInteger)index context:(NSString *)context {
    if (!tracks.count) return;
    self.resumePosition = 0.0;
    [self stop];
    [self.items setArray:tracks];
    self.cursor = MIN(index, tracks.count - 1);
    self.contextName = context;
    NSString *art = nil;
    for (id obj in tracks) {
        if (![obj isKindOfClass:[waTrack class]]) continue;
        art = [(waTrack *)obj bestArtworkURL];
        if (art.length) break;
    }
    self.contextArtworkURL = art;
    [self.shuffleHistory removeAllObjects];
    [self notifyQueue];
    [self startCurrentTrack];
}

- (void)playTrack:(waTrack *)track {
    [self playTracks:@[track] startAt:0 context:track.albumTitle];
}

- (void)appendTracks:(NSArray *)tracks next:(BOOL)next {
    if (!tracks.count) return;
    NSUInteger insert = next ? self.cursor + 1 : self.items.count;
    NSMutableArray *copy = [self.items mutableCopy];
    for (waTrack *track in tracks) [copy insertObject:track atIndex:MIN(insert++, copy.count)];
    self.items = copy;
    if (self.core && !self.core.overlapping && (next || !self.upcomingValid)) {
        self.upcomingValid = NO;
        [self.core cancelNext];
        [self prefetchNext];
    }
    [self notifyQueue];
}

- (void)startCurrentTrack {
    waTrack *track = self.currentTrack;
    if (!track) { [self stop]; return; }
    NSUInteger generation = ++self.loadGeneration;
    self.loading = YES;
    self.playing = NO;
    self.lastError = nil;
    [self notifyState];

    [self tearDownCore];
    waAudioCore *core = [[waAudioCore alloc] init];
    core.delegate = self;
    core.volume = self.volume;
    float gains[5];
    memcpy(gains, _gains, sizeof(gains));
    [core setGains:gains];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL limiter = [defaults objectForKey:waLimiterKey] ? [defaults boolForKey:waLimiterKey] : YES;
    [core setLimiterEnabled:limiter];
    self.core = core;

    [self applyRemoteCenter];
    [self notifyTrack];
    [[waLog shared] log:@"play %@ %@", track.identifier, track.title];
    if (track.needsHydration) {
        NSUInteger hydrateGeneration = generation;
        [[waSession shared] hydrateTrack:track completion:^(waTrack *full) {
            if (hydrateGeneration != self.loadGeneration) return;
            if (!self.contextArtworkURL.length) self.contextArtworkURL = [full bestArtworkURL];
            [self notifyTrack];
            [self updateNowPlaying];
        }];
    }
    [[waSession shared] streamURLForTrack:track completion:^(NSURL *url, waQuality granted, NSError *error) {
        if (generation != self.loadGeneration) return;
        if (error || !url) {
            // A signed-in account must not be silently downgraded to the
            // 30-second preview. That is what made every song come back as 0:30.
            if (![waSession shared].authenticated && track.previewURL.length) {
                [[waLog shared] log:@"stream denied, using preview"];
                self.activeQuality = waQualityMP3128;
                [self startCoreWithURL:[NSURL URLWithString:track.previewURL]];
                return;
            }
            [[waLog shared] log:@"stream failed %@", error.localizedDescription];
            self.loading = NO;
            self.lastError = error;
            [self notifyState];
            [[NSNotificationCenter defaultCenter] postNotificationName:waPlayerDidFailNotification object:self];
            [self handleTrackEnd:YES];
            return;
        }
        self.activeQuality = granted;
        [self startCoreWithURL:url];
    }];
}

- (NSTimeInterval)effectiveOverlapFrom:(waTrack *)current to:(waTrack *)next {
    if (!self.crossfadeEnabled || self.crossfadeDuration < 0.5) return 0.0;
    if (!current || !next) return 0.0;
    if (self.repeatMode == waRepeatOne) return 0.0;
    if (current.identifier.length && [current.identifier isEqualToString:next.identifier]) return 0.0;
    if (!self.shuffleEnabled && current.albumIdentifier.length && [current.albumIdentifier isEqualToString:next.albumIdentifier]) {
        BOOL consecutive = (current.trackPosition > 0 && next.trackPosition > 0)
            ? (next.trackPosition == current.trackPosition + 1 && current.diskNumber == next.diskNumber)
            : YES;
        if (consecutive) return 0.0;
    }
    NSTimeInterval curDur = self.duration > 0.0 ? self.duration : current.duration;
    NSTimeInterval nextDur = next.duration;
    if ((curDur > 0.0 && curDur < 12.0) || (nextDur > 0.0 && nextDur < 12.0)) return 0.0;
    NSTimeInterval overlap = self.crossfadeDuration;
    if (curDur > 0.0 && overlap > curDur * 0.35) overlap = curDur * 0.35;
    if (nextDur > 0.0 && overlap > nextDur * 0.35) overlap = nextDur * 0.35;
    if (overlap < 0.5) return 0.0;
    return overlap;
}

- (void)updateAutoOverlap {
    if (!self.core) return;
    waTrack *next = (self.upcomingValid && self.upcomingIndex < self.items.count)
        ? [self.items objectAtIndex:self.upcomingIndex]
        : nil;
    self.core.autoOverlap = [self effectiveOverlapFrom:self.currentTrack to:next];
}

- (void)startCoreWithURL:(NSURL *)url {
    self.upcomingValid = NO;
    self.core.autoOverlap = 0.0;
    [self.core openURL:url];
    [self prefetchNext];
}

- (NSUInteger)indexAfterCurrent {
    if (self.items.count < 2) return NSNotFound;
    if (self.repeatMode == waRepeatOne) return NSNotFound;
    if (self.shuffleEnabled) {
        if (self.upcomingValid && self.upcomingIndex < self.items.count && self.upcomingIndex != self.cursor) return self.upcomingIndex;
        NSUInteger next = arc4random() % self.items.count;
        if (next == self.cursor) next = (next + 1) % self.items.count;
        self.upcomingIndex = next;
        self.upcomingValid = YES;
        return next;
    }
    NSUInteger next = self.cursor + 1;
    if (next >= self.items.count) {
        if (self.repeatMode == waRepeatAll) return 0;
        return NSNotFound;
    }
    return next;
}

- (void)prefetchNext {
    NSUInteger next = [self indexAfterCurrent];
    if (next == NSNotFound || !self.core) return;
    self.upcomingIndex = next;
    self.upcomingValid = YES;
    [self updateAutoOverlap];
    waTrack *track = [self.items objectAtIndex:next];
    if (![track isKindOfClass:[waTrack class]]) return;
    NSUInteger generation = self.loadGeneration;
    NSUInteger upcoming = next;
    [[waSession shared] streamURLForTrack:track completion:^(NSURL *url, waQuality granted, NSError *error) {
        (void)granted;
        if (generation != self.loadGeneration) return;
        if (!self.upcomingValid || self.upcomingIndex != upcoming) return;
        if (error || !url) return;
        [self.core prepareNextURL:url];
    }];
}

- (void)logHistory {
    waTrack *track = self.currentTrack;
    if (!track) return;
    [[waSession shared] historyLogTrack:track completion:^(NSError *error) { (void)error; }];
    if ([track.identifier respondsToSelector:@selector(length)]) [[waSession shared] rememberTrack:track];
}

- (void)tearDownCore {
    [self.ticker invalidate];
    self.ticker = nil;
    [self.core stop];
    self.core.delegate = nil;
    self.core = nil;
}

- (void)stop {
    [self tearDownCore];
    self.playing = NO;
    self.loading = NO;
    [self notifyState];
}

- (void)pause {
    if (!self.core) return;
    [self.core pause];
    self.playing = NO;
    self.resumePosition = self.core.position;
    [self notifyState];
    [self updateNowPlaying];
    [self persistNow];
}

- (void)resume {
    if (!self.core) { [self startCurrentTrack]; return; }
    [self.core play];
    self.playing = YES;
    [self beginTicker];
    [self notifyState];
    [self updateNowPlaying];
}

- (void)toggle {
    if (self.playing) [self pause];
    else [self resume];
}

- (void)seekTo:(NSTimeInterval)time {
    if (!self.core.ready) return;
    BOOL wasOverlapping = self.core.overlapping;
    self.seekingNow = YES;
    [self.core seekTo:time];
    self.seekingNow = NO;
    if (wasOverlapping) {
        self.upcomingValid = NO;
        [self prefetchNext];
    }
    [self notifyProgress];
    [self updateNowPlaying];
    [self schedulePersist];
}

- (void)playNext { [self advanceBy:1 manual:YES]; }
- (void)playPrevious { [self advanceBy:-1 manual:YES]; }

- (void)jumpToIndex:(NSUInteger)index {
    if (index >= self.items.count) return;
    self.resumePosition = 0.0;
    self.upcomingValid = NO;
    self.cursor = index;
    [self startCurrentTrack];
}

- (void)advanceBy:(NSInteger)delta manual:(BOOL)manual {
    if (!self.items.count) return;
    if (manual && delta < 0 && self.core.ready && self.currentTime > 3.0) {
        [self seekTo:0];
        [self resume];
        return;
    }
    if (!manual && self.repeatMode == waRepeatOne) {
        [self seekTo:0];
        [self resume];
        return;
    }
    NSUInteger target = NSNotFound;
    if (self.shuffleEnabled) {
        if (delta < 0 && self.shuffleHistory.count) {
            NSUInteger prev = [[self.shuffleHistory lastObject] unsignedIntegerValue];
            [self.shuffleHistory removeLastObject];
            if (prev < self.items.count) target = prev;
        }
        if (target == NSNotFound) {
            if (delta > 0 && self.upcomingValid && self.upcomingIndex < self.items.count && self.upcomingIndex != self.cursor) {
                target = self.upcomingIndex;
            } else {
                NSUInteger next = arc4random() % self.items.count;
                if (self.items.count > 1 && next == self.cursor) next = (next + 1) % self.items.count;
                target = next;
            }
        }
    } else {
        NSInteger next = (NSInteger)self.cursor + delta;
        if (next >= (NSInteger)self.items.count) {
            if (self.repeatMode == waRepeatAll) next = 0;
            else { [self stop]; return; }
        }
        if (next < 0) {
            if (self.repeatMode == waRepeatAll) next = (NSInteger)self.items.count - 1;
            else next = 0;
        }
        target = (NSUInteger)next;
    }
    if (delta > 0 && self.upcomingValid && self.upcomingIndex == target && [self.core skipToNextImmediate]) {
        self.resumePosition = 0.0;
        if (self.shuffleEnabled) [self.shuffleHistory addObject:@(self.cursor)];
        self.cursor = target;
        self.upcomingValid = NO;
        self.loading = NO;
        self.playing = YES;
        [self.core play];
        [self beginTicker];
        [self notifyTrack];
        [self notifyState];
        [self updateNowPlaying];
        [self logHistory];
        [self notifyProgress];
        [self prefetchNext];
        return;
    }
    if (self.shuffleEnabled && delta > 0) [self.shuffleHistory addObject:@(self.cursor)];
    self.resumePosition = 0.0;
    self.upcomingValid = NO;
    self.cursor = target;
    [self startCurrentTrack];
}

- (void)handleTrackEnd:(BOOL)failed {
    if (failed) return;
    [self advanceBy:1 manual:NO];
}

- (void)removeAtIndex:(NSUInteger)index {
    if (index >= self.items.count) return;
    NSMutableArray *copy = [self.items mutableCopy];
    [copy removeObjectAtIndex:index];
    self.items = copy;
    if (index < self.cursor) self.cursor--;
    else if (index == self.cursor) {
        if (self.items.count) {
            self.cursor = MIN(self.cursor, self.items.count - 1);
            [self startCurrentTrack];
        } else [self stop];
        [self notifyQueue];
        return;
    }
    if (self.core && !self.core.overlapping) {
        self.upcomingValid = NO;
        [self.core cancelNext];
        [self prefetchNext];
    }
    [self notifyQueue];
}

- (void)moveFrom:(NSUInteger)from to:(NSUInteger)to {
    if (from >= self.items.count || to >= self.items.count) return;
    waTrack *track = [self.items objectAtIndex:from];
    [self.items removeObjectAtIndex:from];
    [self.items insertObject:track atIndex:to];
    if (self.cursor == from) self.cursor = to;
    else if (from < self.cursor && to >= self.cursor) self.cursor--;
    else if (from > self.cursor && to <= self.cursor) self.cursor++;
    if (self.core && !self.core.overlapping) {
        self.upcomingValid = NO;
        [self.core cancelNext];
        [self prefetchNext];
    }
    [self notifyQueue];
}

- (void)clearQueue {
    [self stop];
    [self.items removeAllObjects];
    self.cursor = 0;
    self.resumePosition = 0.0;
    [self notifyQueue];
    [self notifyTrack];
    [self persistNow];
}

#pragma mark - core delegate

- (void)audioCoreDidLoad:(waAudioCore *)core duration:(NSTimeInterval)duration {
    if (core != self.core) return;
    self.loading = NO;
    self.playing = YES;
    NSTimeInterval seek = self.resumePosition;
    self.resumePosition = 0.0;
    NSTimeInterval dur = duration > 0.0 ? duration : self.duration;
    if (seek > 1.0 && dur > 0.0) {
        if (seek > dur - 1.0) seek = MAX(0.0, dur - 1.0);
        [self.core seekTo:seek];
    }
    [self updateAutoOverlap];
    [[waLog shared] log:@"playback ready q=%d", (int)self.activeQuality];
    [self.core play];
    [self beginTicker];
    [self notifyState];
    [self notifyTrack];
    [self updateNowPlaying];
    [self logHistory];
    [self notifyProgress];
}

- (void)audioCoreDidFinish:(waAudioCore *)core {
    if (core != self.core) return;
    [[waLog shared] log:@"core finished"];
    [self handleTrackEnd:NO];
}

- (void)audioCoreDidPromoteNext:(waAudioCore *)core duration:(NSTimeInterval)duration {
    if (core != self.core) return;
    (void)duration;
    if (self.upcomingValid && self.upcomingIndex < self.items.count) {
        if (self.shuffleEnabled) [self.shuffleHistory addObject:@(self.cursor)];
        self.cursor = self.upcomingIndex;
    }
    self.upcomingValid = NO;
    self.loading = NO;
    self.playing = YES;
    self.core.autoOverlap = 0.0;
    [self notifyTrack];
    [self notifyState];
    [self updateNowPlaying];
    [self logHistory];
    [self prefetchNext];
}

- (void)audioCore:(waAudioCore *)core didFail:(NSError *)error {
    (void)core;
    [[waLog shared] log:@"audio fail %@", error.localizedDescription];
    self.lastError = error;
    self.loading = NO;
    self.playing = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:waPlayerDidFailNotification object:self];
    [self notifyState];
}

#pragma mark - ticker / notifications

- (void)beginTicker {
    [self.ticker invalidate];
    self.ticker = [NSTimer scheduledTimerWithTimeInterval:0.15 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.ticker forMode:NSRunLoopCommonModes];
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    [self notifyProgress];
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (self.playing && now - self.lastPersistTime > 5.0) {
        self.lastPersistTime = now;
        [self schedulePersist];
    }
    if (!self.loading && self.playing && !self.core.overlapping && self.core.endOfStream) {
        NSTimeInterval duration = self.duration;
        if (duration <= 0.0 || self.core.position + 0.6 >= duration) {
            [self handleTrackEnd:NO];
        }
    }
}

- (void)notifyState {
    [self schedulePersist];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:waPlayerStateDidChangeNotification object:self];
    });
}

- (void)notifyTrack {
    [self schedulePersist];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:waPlayerTrackDidChangeNotification object:self];
    });
}

- (void)notifyQueue {
    [self schedulePersist];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:waPlayerQueueDidChangeNotification object:self];
    });
}

- (void)notifyProgress {
    [[NSNotificationCenter defaultCenter] postNotificationName:waPlayerProgressNotification object:self];
}

- (void)updateNowPlaying {
    waTrack *track = self.currentTrack;
    if (!track) return;
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle] = track.title ?: @"";
    info[MPMediaItemPropertyArtist] = track.artistName ?: @"";
    if (track.albumTitle.length) info[MPMediaItemPropertyAlbumTitle] = track.albumTitle;
    if (self.duration > 0) info[MPMediaItemPropertyPlaybackDuration] = @(self.duration);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(self.currentTime);
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.playing ? 1.0 : 0.0);
    info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = @(self.cursor);
    info[MPNowPlayingInfoPropertyPlaybackQueueCount] = @(self.items.count);
    NSString *local = [[waSession shared] localArtworkPathForTrack:track];
    NSString *art = local.length ? local : ([track bestArtworkURL] ?: self.contextArtworkURL);
    if (art.length) {
        if (self.nowPlayingArtwork && [self.nowPlayingArtworkKey isEqualToString:art]) {
            info[MPMediaItemPropertyArtwork] = self.nowPlayingArtwork;
        } else {
            UIImage *cached = [[waSession shared] cachedArtwork:art size:CGSizeMake(320, 320)];
            if (cached) {
                self.nowPlayingArtworkKey = art;
                self.nowPlayingArtwork = [[MPMediaItemArtwork alloc] initWithImage:cached];
                info[MPMediaItemPropertyArtwork] = self.nowPlayingArtwork;
            } else {
                NSString *url = [art copy];
                NSString *trackID = [track.identifier copy];
                __weak waPlayer *weakSelf = self;
                [[waSession shared] loadArtwork:url size:CGSizeMake(320, 320) completion:^(UIImage *image) {
                    waPlayer *strongSelf = weakSelf;
                    if (!strongSelf || !image) return;
                    if (trackID.length && ![strongSelf.currentTrack.identifier isEqualToString:trackID]) return;
                    strongSelf.nowPlayingArtworkKey = url;
                    strongSelf.nowPlayingArtwork = [[MPMediaItemArtwork alloc] initWithImage:image];
                    NSMutableDictionary *current = [[MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo mutableCopy];
                    if (!current) current = [NSMutableDictionary dictionary];
                    current[MPMediaItemPropertyArtwork] = strongSelf.nowPlayingArtwork;
                    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = current;
                }];
            }
        }
    }
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

#pragma mark - remote / audio session

- (void)applyRemoteCenter {
    if (self.audioSessionReady) return;
    self.audioSessionReady = YES;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback error:NULL];
}

- (void)handleRemoteControl:(UIEvent *)event {
    if (event.type != UIEventTypeRemoteControl) return;
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlPlay:
        case UIEventSubtypeRemoteControlPause:
        case UIEventSubtypeRemoteControlTogglePlayPause:
            [self toggle];
            break;
        case UIEventSubtypeRemoteControlNextTrack:
            [self playNext];
            break;
        case UIEventSubtypeRemoteControlPreviousTrack:
            [self playPrevious];
            break;
        case UIEventSubtypeRemoteControlBeginSeekingForward:
            self.seekingNow = YES;
            break;
        case UIEventSubtypeRemoteControlEndSeekingForward:
            self.seekingNow = NO;
            [self seekTo:MIN(self.duration, self.currentTime + 15.0)];
            break;
        case UIEventSubtypeRemoteControlBeginSeekingBackward:
            self.seekingNow = YES;
            break;
        case UIEventSubtypeRemoteControlEndSeekingBackward:
            self.seekingNow = NO;
            [self seekTo:MAX(0.0, self.currentTime - 15.0)];
            break;
        default:
            break;
    }
}

#pragma mark - EQ

- (void)setGain:(float)gain forBand:(NSUInteger)band {
    if (band >= 5) return;
    _gains[band] = MAX(-12.0f, MIN(12.0f, gain));
    [self.core setGains:_gains];
}

- (float)gainForBand:(NSUInteger)band {
    return band < 5 ? _gains[band] : 0.0f;
}

- (NSArray *)equalizerPresets {
    return @[@"Flat", @"Bass Booster", @"Rock", @"Pop", @"Vocal", @"Treble"];
}

- (NSString *)equalizerPresetName { return self.presetName; }

- (void)applyPresetNamed:(NSString *)name {
    self.presetName = name ?: @"Flat";
    [self gainsForPreset:self.presetName];
    [self.core setGains:_gains];
    [[NSUserDefaults standardUserDefaults] setObject:self.presetName forKey:waEQKey];
}

- (void)gainsForPreset:(NSString *)name {
    float flat[5] = {0, 0, 0, 0, 0};
    float bass[5] = {7, 4, 0, 0, -1};
    float rock[5] = {5, 2, -1, 1, 3};
    float pop[5] = {-1, 2, 5, 2, -1};
    float vocal[5] = {-2, 0, 4, 4, 1};
    float treble[5] = {-2, -1, 0, 3, 6};
    const float *source = flat;
    if ([name isEqualToString:@"Bass Booster"]) source = bass;
    else if ([name isEqualToString:@"Rock"]) source = rock;
    else if ([name isEqualToString:@"Pop"]) source = pop;
    else if ([name isEqualToString:@"Vocal"]) source = vocal;
    else if ([name isEqualToString:@"Treble"]) source = treble;
    memcpy(_gains, source, sizeof(_gains));
}

- (BOOL)compressorEnabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    return [defaults objectForKey:waLimiterKey] ? [defaults boolForKey:waLimiterKey] : YES;
}

- (void)setCompressorEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:waLimiterKey];
    [self.core setLimiterEnabled:enabled];
}

#pragma mark - queue persistence

- (NSString *)queuePath {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *dir = [[dirs objectAtIndex:0] stringByAppendingPathComponent:@"Wave"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
        path = [dir stringByAppendingPathComponent:@"queue.plist"];
    });
    return path;
}

- (NSDictionary *)queueSnapshot {
    if (!self.items.count) return nil;
    NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:self.items.count];
    for (id obj in self.items) {
        if (![obj isKindOfClass:[waTrack class]]) continue;
        NSDictionary *dict = [(waTrack *)obj dictionary];
        if (dict.count) [tracks addObject:dict];
    }
    if (!tracks.count) return nil;
    NSMutableDictionary *snap = [NSMutableDictionary dictionary];
    snap[@"tracks"] = tracks;
    snap[@"index"] = @(self.cursor);
    snap[@"position"] = @(self.currentTime);
    if (self.contextName.length) snap[@"context"] = self.contextName;
    if (self.contextArtworkURL.length) snap[@"contextArt"] = self.contextArtworkURL;
    if (self.shuffleHistory.count) snap[@"shuffle"] = [self.shuffleHistory copy];
    return snap;
}

- (void)writeSnapshot:(NSDictionary *)snap {
    NSString *path = [self queuePath];
    dispatch_async(self.persistQueue, ^{
        if (!snap) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
            return;
        }
        [snap writeToFile:path atomically:YES];
    });
}

- (void)schedulePersist {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self schedulePersist]; });
        return;
    }
    if (self.persistPending) return;
    self.persistPending = YES;
    __weak waPlayer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        waPlayer *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.persistPending = NO;
        strongSelf.lastPersistTime = [NSDate timeIntervalSinceReferenceDate];
        [strongSelf writeSnapshot:[strongSelf queueSnapshot]];
    });
}

- (void)persistNow {
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{ [self persistNow]; });
        return;
    }
    self.persistPending = NO;
    self.lastPersistTime = [NSDate timeIntervalSinceReferenceDate];
    NSDictionary *snap = [self queueSnapshot];
    NSString *path = [self queuePath];
    dispatch_queue_t queue = self.persistQueue;
    if (!queue) {
        if (!snap) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        else [snap writeToFile:path atomically:YES];
        return;
    }
    dispatch_sync(queue, ^{
        if (!snap) [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        else [snap writeToFile:path atomically:YES];
    });
}

- (void)restoreQueue {
    NSDictionary *snap = [NSDictionary dictionaryWithContentsOfFile:[self queuePath]];
    if (![snap isKindOfClass:[NSDictionary class]]) return;
    NSArray *raw = snap[@"tracks"];
    if (![raw isKindOfClass:[NSArray class]] || !raw.count) return;
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in raw) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        waTrack *track = [waTrack itemWithDictionary:item kind:waTrackType];
        if (track.identifier.length) [tracks addObject:track];
    }
    if (!tracks.count) return;
    NSUInteger index = [snap[@"index"] unsignedIntegerValue];
    if (index >= tracks.count) index = tracks.count - 1;
    self.items = tracks;
    self.cursor = index;
    self.resumePosition = MAX(0.0, [snap[@"position"] doubleValue]);
    NSString *context = snap[@"context"];
    self.contextName = [context isKindOfClass:[NSString class]] ? context : nil;
    NSString *art = snap[@"contextArt"];
    self.contextArtworkURL = [art isKindOfClass:[NSString class]] ? art : nil;
    [self.shuffleHistory removeAllObjects];
    NSArray *history = snap[@"shuffle"];
    if ([history isKindOfClass:[NSArray class]]) {
        for (id value in history) {
            if ([value respondsToSelector:@selector(unsignedIntegerValue)]) {
                [self.shuffleHistory addObject:@([value unsignedIntegerValue])];
            }
        }
    }
}

@end
