#import "waAudioEngine.h"
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import "waPCMTrack.h"
#import "waPCMMixer.h"
#import "../Services/waAudioPlayer.h"
#import "../Services/waDebugLog.h"

NSString * const waAudioEngineStateDidChangeNotification = @"waAudioEngineStateDidChangeNotification";
NSString * const waAudioEngineDidFailNotification = @"waAudioEngineDidFailNotification";
NSString * const waAudioEngineDidFinishNotification = @"waAudioEngineDidFinishNotification";
NSString * const waAudioEngineCrossfadeCancelledNotification = @"waAudioEngineCrossfadeCancelledNotification";
NSString * const waAudioEngineSeekNotification = @"waAudioEngineSeekNotification";
NSString * const waAudioEngineDidStallNotification = @"waAudioEngineDidStallNotification";

@interface waAudioEngine () <waPCMMixerDelegate>
@property (nonatomic, strong) waPCMMixer *mixer;
@property (nonatomic, strong) NSMutableArray *queue;
@property (nonatomic, strong) waPCMTrack *pendingTrack;
@property (nonatomic, strong) waPCMTrack *preparingCrossfadeTrack;
@property (nonatomic, assign) NSUInteger crossfadePreparationGeneration;
@property (nonatomic, strong) NSTimer *crossfadeTimer;
@property (nonatomic, copy) void (^crossfadeCompletion)(BOOL);
@property (nonatomic, assign) NSTimeInterval pendingCrossfadeDuration;
@property (nonatomic, assign) NSUInteger pendingCrossfadeGeneration;
@property (nonatomic, assign, getter=isPlaying) BOOL playing;
@property (nonatomic, strong, readwrite) NSError *lastError;
@property (nonatomic, assign) NSUInteger loadGeneration;
@property (nonatomic, assign) BOOL wasPlayingBeforeInterruption;
@property (nonatomic, assign) BOOL wantsToPlay;
@end

@implementation waAudioEngine

@synthesize crossfadeEnabled = _crossfadeEnabled;
@synthesize crossfadeDuration = _crossfadeDuration;

- (id)init {
    if ((self = [super init])) {
        _queue = [[NSMutableArray alloc] init];
        _crossfadeDuration = 2.0;

        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback error:NULL];
        [session setPreferredSampleRate:44100.0 error:NULL];
        [session setActive:YES error:NULL];

        _mixer = [[waPCMMixer alloc] init];
        _mixer.delegate = self;
        if (_mixer.lastError) self.lastError = _mixer.lastError;

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                  selector:@selector(audioSessionInterruption:)
                                                      name:AVAudioSessionInterruptionNotification
                                                    object:session];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
            [self setupRemoteCommands];
        });
    }
    return self;
}

- (MPRemoteCommandHandlerStatus)handlePlayCommand:(id)event { (void)event; [self resume]; return (MPRemoteCommandHandlerStatus)0; }
- (MPRemoteCommandHandlerStatus)handlePauseCommand:(id)event { (void)event; [self pause]; return (MPRemoteCommandHandlerStatus)0; }
- (MPRemoteCommandHandlerStatus)handleToggleCommand:(id)event { (void)event; [self togglePlayPause]; return (MPRemoteCommandHandlerStatus)0; }
- (MPRemoteCommandHandlerStatus)handleNextCommand:(id)event { (void)event; dispatch_async(dispatch_get_main_queue(), ^{ [[waAudioPlayer sharedPlayer] playNext]; }); return (MPRemoteCommandHandlerStatus)0; }
- (MPRemoteCommandHandlerStatus)handlePreviousCommand:(id)event { (void)event; dispatch_async(dispatch_get_main_queue(), ^{ [[waAudioPlayer sharedPlayer] playPrevious]; }); return (MPRemoteCommandHandlerStatus)0; }
- (MPRemoteCommandHandlerStatus)handleSeekForwardCommand:(id)event { (void)event; dispatch_async(dispatch_get_main_queue(), ^{ NSTimeInterval t = self.currentTime + 15.0; [self seekToTime:MIN(t, self.duration)]; }); return (MPRemoteCommandHandlerStatus)0; }
- (MPRemoteCommandHandlerStatus)handleSeekBackwardCommand:(id)event { (void)event; dispatch_async(dispatch_get_main_queue(), ^{ NSTimeInterval t = self.currentTime - 15.0; [self seekToTime:MAX(t, 0.0)]; }); return (MPRemoteCommandHandlerStatus)0; }

- (void)setupRemoteCommands {
    Class centerClass = NSClassFromString(@"MPRemoteCommandCenter");
    if (!centerClass) return;
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    if (!center) return;
    @try {
        center.playCommand.enabled = YES;
        center.pauseCommand.enabled = YES;
        center.togglePlayPauseCommand.enabled = YES;
        center.nextTrackCommand.enabled = YES;
        center.previousTrackCommand.enabled = YES;
        center.seekForwardCommand.enabled = YES;
        center.seekBackwardCommand.enabled = YES;
        [center.playCommand addTarget:self action:@selector(handlePlayCommand:)];
        [center.pauseCommand addTarget:self action:@selector(handlePauseCommand:)];
        [center.togglePlayPauseCommand addTarget:self action:@selector(handleToggleCommand:)];
        [center.nextTrackCommand addTarget:self action:@selector(handleNextCommand:)];
        [center.previousTrackCommand addTarget:self action:@selector(handlePreviousCommand:)];
        [center.seekForwardCommand addTarget:self action:@selector(handleSeekForwardCommand:)];
        [center.seekBackwardCommand addTarget:self action:@selector(handleSeekBackwardCommand:)];
    } @catch (NSException *e) { (void)e; }
}

+ (waAudioEngine *)sharedEngine {
    static waAudioEngine *engine;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ engine = [[self alloc] init]; });
    return engine;
}

- (void)notifyStateChange {
    if (![NSThread isMainThread]) {
        __weak waAudioEngine *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf notifyStateChange]; });
        return;
    }
    [self updateNowPlayingPlaybackState];
    [[NSNotificationCenter defaultCenter] postNotificationName:waAudioEngineStateDidChangeNotification object:self];
}

- (void)updateNowPlayingPlaybackState {
    if (![NSThread isMainThread]) {
        __weak waAudioEngine *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf updateNowPlayingPlaybackState]; });
        return;
    }
    NSMutableDictionary *info = [[MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo mutableCopy];
    if (!info) return;
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(self.currentTime);
    if (self.duration > 0.0) info[MPMediaItemPropertyPlaybackDuration] = @(self.duration);
    info[MPNowPlayingInfoPropertyPlaybackRate] = self.isPlaying ? @1.0 : @0.0;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

- (void)audioSessionInterruption:(NSNotification *)notification {
    NSNumber *type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
    if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
        self.wasPlayingBeforeInterruption = self.isPlaying;
        if (self.isPlaying) [self pause];
    } else if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
        [[AVAudioSession sharedInstance] setActive:YES error:NULL];
        if (self.wasPlayingBeforeInterruption) [self resume];
        self.wasPlayingBeforeInterruption = NO;
    }
}

- (void)cancelPendingCrossfade {
    self.crossfadePreparationGeneration += 1;
    [self.preparingCrossfadeTrack stop];
    self.preparingCrossfadeTrack = nil;
    [self.crossfadeTimer invalidate];
    self.crossfadeTimer = nil;
    [self.pendingTrack stop];
    self.pendingTrack = nil;
    self.crossfadeCompletion = nil;
}

- (void)cancelCrossfade {
    BOOL hadCrossfade = self.preparingCrossfadeTrack || self.crossfadeTimer || self.pendingTrack || self.mixer.crossfading;
    [self cancelPendingCrossfade];
    [self.mixer cancelCrossfade];
    if (hadCrossfade) [[NSNotificationCenter defaultCenter] postNotificationName:waAudioEngineCrossfadeCancelledNotification object:self];
}

- (void)playURL:(NSURL *)url {
    if (!url) return;
    if (![NSThread isMainThread]) {
        __weak waAudioEngine *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf playURL:url]; });
        return;
    }

    NSUInteger generation = ++self.loadGeneration;
    [self cancelCrossfade];
    [self.mixer stop];
    self.lastError = nil;
    self.playing = NO;
    self.wantsToPlay = YES;
    [self notifyStateChange];

    waPCMTrack *track = [[waPCMTrack alloc] initWithURL:url outputFormat:self.mixer.outputFormat];
    __weak waAudioEngine *weakSelf = self;
    [track prepareWithCompletion:^(BOOL success, NSError *error) {
        waAudioEngine *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.loadGeneration) {
            [track stop];
            return;
        }
        if (!success) {
            strongSelf.lastError = error ?: [NSError errorWithDomain:@"com.bytebox.wave.audio"
                                                                 code:-30
                                                             userInfo:@{NSLocalizedDescriptionKey: @"The audio source could not be decoded."}];
            strongSelf.playing = NO;
            [[waDebugLog sharedLog] log:@"PCM playback failed: %@", strongSelf.lastError.localizedDescription ?: @"unknown error"];
            [[NSNotificationCenter defaultCenter] postNotificationName:waAudioEngineDidFailNotification object:strongSelf];
            [strongSelf notifyStateChange];
            return;
        }
        strongSelf.lastError = nil;
        [strongSelf.mixer playTrack:track];
        strongSelf.playing = strongSelf.mixer.playing;
        [strongSelf notifyStateChange];
    }];
}

- (void)beginPendingCrossfade:(NSTimer *)timer {
    if (timer != self.crossfadeTimer || !self.pendingTrack) return;
    if (self.pendingCrossfadeGeneration != self.loadGeneration) {
        [self cancelPendingCrossfade];
        return;
    }

    NSTimeInterval remaining = self.mixer.duration - self.mixer.currentTime;
    if (!isfinite(remaining) || remaining <= 0.0) {
        void (^completion)(BOOL) = self.crossfadeCompletion;
        [self cancelPendingCrossfade];
        if (completion) completion(NO);
        return;
    }

    NSTimeInterval duration = MIN(self.pendingCrossfadeDuration, remaining);
    waPCMTrack *track = self.pendingTrack;
    self.pendingTrack = nil;
    self.crossfadeTimer = nil;
    void (^completion)(BOOL) = self.crossfadeCompletion;
    self.crossfadeCompletion = nil;

    [self.mixer crossfadeToTrack:track duration:duration completion:^(BOOL started) {
        if (!started) [track stop];
        if (completion) completion(started);
        if (started) [self notifyStateChange];
    }];
}

- (void)crossfadeToURL:(NSURL *)url duration:(NSTimeInterval)duration completion:(void (^)(BOOL started))completion {
    if (!url || duration <= 0.0 || !self.mixer.hasLoadedTrack || !self.isPlaying || self.currentTime < 1.0) {
        if (completion) completion(NO);
        return;
    }
    if (![NSThread isMainThread]) {
        __weak waAudioEngine *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf crossfadeToURL:url duration:duration completion:completion]; });
        return;
    }

    [self cancelPendingCrossfade];
    self.pendingCrossfadeDuration = MIN(15.0, duration);
    self.pendingCrossfadeGeneration = self.loadGeneration;
    self.crossfadeCompletion = [completion copy];
    NSUInteger generation = self.loadGeneration;
    NSUInteger preparationGeneration = self.crossfadePreparationGeneration;
    waPCMTrack *track = [[waPCMTrack alloc] initWithURL:url outputFormat:self.mixer.outputFormat];
    self.preparingCrossfadeTrack = track;
    __weak waAudioEngine *weakSelf = self;
    [track prepareWithCompletion:^(BOOL success, NSError *error) {
        waAudioEngine *strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf.loadGeneration || preparationGeneration != strongSelf.crossfadePreparationGeneration || strongSelf.preparingCrossfadeTrack != track || !strongSelf.mixer.hasLoadedTrack) {
            [track stop];
            return;
        }
        strongSelf.preparingCrossfadeTrack = nil;
        if (!success) {
            [[waDebugLog sharedLog] log:@"PCM crossfade preparation failed: %@", error.localizedDescription ?: @"unknown error"];
            void (^callback)(BOOL) = strongSelf.crossfadeCompletion;
            [strongSelf cancelPendingCrossfade];
            if (callback) callback(NO);
            return;
        }
        strongSelf.pendingTrack = track;
        NSTimeInterval remaining = strongSelf.mixer.duration - strongSelf.mixer.currentTime;
        NSTimeInterval delay = MAX(0.0, remaining - strongSelf.pendingCrossfadeDuration);
        strongSelf.crossfadeTimer = [NSTimer timerWithTimeInterval:delay
                                                              target:strongSelf
                                                            selector:@selector(beginPendingCrossfade:)
                                                            userInfo:nil
                                                             repeats:NO];
        [[NSRunLoop mainRunLoop] addTimer:strongSelf.crossfadeTimer forMode:NSRunLoopCommonModes];
    }];
}

- (void)pause {
    [self cancelCrossfade];
    self.wantsToPlay = NO;
    [self.mixer pause];
    self.playing = NO;
    [self notifyStateChange];
}

- (void)resume {
    self.wantsToPlay = YES;
    [self.mixer resume];
    self.playing = self.mixer.playing;
    [self notifyStateChange];
}

- (void)stop {
    self.loadGeneration += 1;
    self.wantsToPlay = NO;
    if (![NSThread isMainThread]) {
        __weak waAudioEngine *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf stop]; });
        return;
    }
    [self cancelCrossfade];
    [self.mixer stop];
    self.playing = NO;
    self.lastError = nil;
    [self notifyStateChange];
}

- (void)togglePlayPause { if (self.isPlaying) [self pause]; else [self resume]; }

- (void)seekToTime:(NSTimeInterval)time {
    if (![NSThread isMainThread]) {
        __weak waAudioEngine *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf seekToTime:time]; });
        return;
    }
    if (!isfinite(time) || time < 0.0 || !self.mixer.hasLoadedTrack) return;
    [self cancelCrossfade];
    [self.mixer seekToTime:MIN(time, self.duration > 0.0 ? self.duration : time)];
    [[NSNotificationCenter defaultCenter] postNotificationName:waAudioEngineSeekNotification object:self];
    [self notifyStateChange];
}

- (BOOL)isPlaying { return _playing; }
- (BOOL)hasLoadedPlaybackItem { return self.mixer.hasLoadedTrack; }
- (NSTimeInterval)currentTime { return self.mixer.currentTime; }
- (NSTimeInterval)duration { return self.mixer.duration; }
- (double)bitrateKbps { return self.mixer.bitrateKbps; }

- (void)setEqualizerGains:(const float *)gains { [self.mixer setEqualizerGains:gains]; }

- (void)equalizerGains:(float *)gains { [self.mixer equalizerGains:gains]; }

- (void)setCompressorEnabled:(BOOL)enabled { [self.mixer setCompressorEnabled:enabled]; }

- (void)setCompressorStrength:(float)strength { [self.mixer setCompressorStrength:strength]; }

- (BOOL)compressorEnabled { return self.mixer.compressorEnabled; }

- (float)compressorStrength { return self.mixer.compressorStrength; }

- (void)enqueueURL:(NSURL *)url {
    if (!url) return;
    if (!self.mixer.hasLoadedTrack) [self playURL:url];
    else [self.queue addObject:url];
}

- (void)removeAllQueuedItems {
    [self.queue removeAllObjects];
    [self stop];
}

- (void)updateNowPlaying:(NSString *)title artist:(NSString *)artist duration:(NSTimeInterval)duration {
    [self updateNowPlaying:title artist:artist duration:duration artwork:nil];
}

- (void)updateNowPlaying:(NSString *)title artist:(NSString *)artist duration:(NSTimeInterval)duration artwork:(UIImage *)artwork {
    if (![NSThread isMainThread]) {
        __weak waAudioEngine *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf updateNowPlaying:title artist:artist duration:duration artwork:artwork]; });
        return;
    }
    NSMutableDictionary *info = [[[MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo mutableCopy] ?: [NSMutableDictionary dictionary] mutableCopy];
    info[MPMediaItemPropertyTitle] = title ?: @"";
    info[MPMediaItemPropertyArtist] = artist ?: @"";
    // Album title if available via currentItem (set by waAudioPlayer)
    info[MPMediaItemPropertyPlaybackDuration] = @(duration);
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(self.currentTime);
    info[MPNowPlayingInfoPropertyPlaybackRate] = self.isPlaying ? @1.0 : @0.0;
    if (artwork) info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithImage:artwork];
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

- (void)updateNowPlayingAlbum:(NSString *)album {
    if (!album.length) return;
    NSMutableDictionary *info = [[MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo mutableCopy];
    if (!info) return;
    info[MPMediaItemPropertyAlbumTitle] = album;
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = info;
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    if (event.type != UIEventTypeRemoteControl) return;
    // On iOS 7.1, MPRemoteCommandCenter handles Next/Previous — avoid double skip
    if (NSClassFromString(@"MPRemoteCommandCenter")) {
        if (event.subtype == UIEventSubtypeRemoteControlNextTrack ||
            event.subtype == UIEventSubtypeRemoteControlPreviousTrack ||
            event.subtype == UIEventSubtypeRemoteControlBeginSeekingForward ||
            event.subtype == UIEventSubtypeRemoteControlBeginSeekingBackward) return;
    }
    if (event.subtype == UIEventSubtypeRemoteControlPlay) [self resume];
    else if (event.subtype == UIEventSubtypeRemoteControlPause) [self pause];
    else if (event.subtype == UIEventSubtypeRemoteControlTogglePlayPause) [self togglePlayPause];
    else if (event.subtype == UIEventSubtypeRemoteControlNextTrack) {
        dispatch_async(dispatch_get_main_queue(), ^{ [[waAudioPlayer sharedPlayer] playNext]; });
    } else if (event.subtype == UIEventSubtypeRemoteControlPreviousTrack) {
        dispatch_async(dispatch_get_main_queue(), ^{ [[waAudioPlayer sharedPlayer] playPrevious]; });
    } else if (event.subtype == UIEventSubtypeRemoteControlBeginSeekingBackward) {
        [self seekToTime:MAX(0.0, self.currentTime - 15.0)];
    } else if (event.subtype == UIEventSubtypeRemoteControlBeginSeekingForward) {
        [self seekToTime:MIN(self.duration, self.currentTime + 15.0)];
    }
}

#pragma mark - waPCMMixerDelegate

- (void)pcmMixerDidFinish:(id)mixer {
    if (mixer != self.mixer) return;
    self.playing = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:waAudioEngineDidFinishNotification object:self];
    [self notifyStateChange];
}

- (void)pcmMixerDidStall:(id)mixer {
    if (mixer != self.mixer) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:waAudioEngineDidStallNotification object:self];
}

- (void)pcmMixerDidFail:(id)mixer error:(NSError *)error {
    if (mixer != self.mixer) return;
    self.lastError = error;
    self.playing = NO;
    [[waDebugLog sharedLog] log:@"PCM mixer failed: %@", error.localizedDescription ?: @"unknown error"];
    [[NSNotificationCenter defaultCenter] postNotificationName:waAudioEngineDidFailNotification object:self];
    [self notifyStateChange];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.mixer.delegate = nil;
}

@end
