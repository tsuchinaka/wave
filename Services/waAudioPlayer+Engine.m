#import "waAudioPlayer.h"
#import "waAudioPlayer+EnginePrivate.h"
#import "../Audio/waAudioEngine.h"
#import "waAPIClient.h" // waNetworkActivity helpers
#import "waDeezerStreamClient.h"
#import "waDebugLog.h"
#import "waRPCClient.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation waAudioPlayer (Engine)

- (void)applicationStateChanged:(NSNotification *)notification { (void)notification; [self persistQueue]; }
- (void)engineStateDidChange:(NSNotification *)notification {
    waAudioEngine *engine = [waAudioEngine sharedEngine];
    self.lastError = engine.lastError;
    if ([self shouldFallbackFromAudioError:self.lastError]) {
        [self fallbackToLowQuality];
        self.lastError = nil;
    }
    [self refreshQualityLabel];
    if (self.currentItem.duration <= 0.0 && engine.duration > 0.0) self.currentItem.duration = engine.duration;
    if (self.lastError || engine.isPlaying) self.loading = NO;
    if (self.resumePositionPending && !self.lastError && engine.hasLoadedPlaybackItem && engine.duration > 0.0) {
        NSTimeInterval position = MIN(self.persistedPlaybackPosition, engine.duration);
        self.resumePositionPending = NO;
        if (position > 0.0) [engine seekToTime:position];
    }
    if (self.qualityFallbackInProgress && !self.lastError && engine.hasLoadedPlaybackItem) {
        NSTimeInterval position = self.qualityFallbackPosition;
        self.qualityFallbackInProgress = NO;
        if (position > 0.0) [engine seekToTime:position];
    }
    if (self.networkPlaybackActive && (self.lastError || engine.isPlaying)) {
        self.networkPlaybackActive = NO;
        waNetworkActivityEnd();
    }
    if (engine.isPlaying) {
        [self cancelPlaybackStartTimer];
        [self markPlaybackStartedIfNeeded];
        [self startPrefetchTimer];
    }
    else [self stopPrefetchTimer];
    [self notifyChange];
}
- (BOOL)shouldFallbackFromAudioError:(NSError *)error {
    if (!error || self.activeQuality == 0 || self.qualityFallbackInProgress || !self.currentItem) return NO;
    if (![error.domain isEqualToString:@"com.bytebox.wave.audio"]) return NO;
    return error.code == -10 || error.code == -11 || error.code == -12 || error.code == -14 || error.code == -15;
}
- (void)armPlaybackStartTimer {
    [self cancelPlaybackStartTimer];
    NSString *trackID = self.currentItem.trackId.length ? self.currentItem.trackId : self.currentItem.identifier;
    NSDictionary *info = @{ @"track": trackID ?: @"", @"quality": @(self.activeQuality) };
    // Lossless frames are ~5-10x an MP3's: same 20s budget that fits 128k
    // starves FLAC on slow links and the fallback downgrades a healthy
    // stream. FLAC gets its own window before any downgrade is considered.
    NSTimeInterval timeout = self.activeQuality == 2 ? 45.0 : 20.0;
    self.playbackStartTimer = [NSTimer timerWithTimeInterval:timeout target:self selector:@selector(playbackStartTimedOut:) userInfo:info repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.playbackStartTimer forMode:NSRunLoopCommonModes];
}
- (void)cancelPlaybackStartTimer { [self.playbackStartTimer invalidate]; self.playbackStartTimer = nil; }
- (void)playbackStartTimedOut:(NSTimer *)timer {
    waAudioEngine *engine = [waAudioEngine sharedEngine];
    if (timer != self.playbackStartTimer || engine.isPlaying) return;
    if (self.qualityFallbackInProgress || self.activeQuality == 0 || !self.currentItem) return;
    // Stale timer from a previous track must never downgrade the new one.
    NSString *expected = timer.userInfo[@"track"];
    NSString *current = self.currentItem.trackId.length ? self.currentItem.trackId : self.currentItem.identifier;
    if (expected.length && ![expected isEqualToString:current ?: @""]) return;
    // Slow FLAC that already loaded its first frames is about to play.
    // Give it a short grace instead of throwing it away for MP3 at once.
    // The grace scales with the payload: a primed FLAC decoder only needs
    // the mixer to catch up, not a full re-download.
    if (engine.hasLoadedPlaybackItem) {
        [self cancelPlaybackStartTimer];
        NSTimeInterval grace = self.activeQuality == 2 ? 15.0 : 5.0;
        self.playbackStartTimer = [NSTimer timerWithTimeInterval:grace target:self selector:@selector(playbackStartTimedOut:) userInfo:timer.userInfo repeats:NO];
        [[NSRunLoop mainRunLoop] addTimer:self.playbackStartTimer forMode:NSRunLoopCommonModes];
        return;
    }
    [self cancelPlaybackStartTimer];
    [self fallbackToLowQuality];
}
- (void)fallbackToLowQuality {
    if (self.activeQuality == 0 || self.qualityFallbackInProgress || !self.currentItem) return;
    NSString *trackID = self.currentItem.trackId.length ? self.currentItem.trackId : self.currentItem.identifier;
    self.qualityFallbackInProgress = YES;
    self.qualityFallbackPosition = [waAudioEngine sharedEngine].currentTime;
    self.activeQuality = 0;
    [self setQualityLabelForQuality:0 localFile:NO];
    [self notifyChange];
    [[waDeezerStreamClient sharedClient] resolveStreamURLForTrackID:trackID quality:0 completion:^(NSURL *directURL, NSUInteger grantedQuality, NSError *directError) {
        (void)grantedQuality;
        if (directURL) { [[waAudioEngine sharedEngine] playURL:directURL]; return; }
        [[waDebugLog sharedLog] log:@"Direct fallback failed (%@), serverless - no fallback", directError.localizedDescription ?: @"unknown"];
        self.qualityFallbackInProgress = NO; [self notifyChange];
    }];
}
- (void)engineDidStall:(NSNotification *)notification {
     // Do not downgrade during startup; the watchdog handles a genuinely stuck
     // initial load. Only fall back after playback was active.
    waAudioEngine *engine = [waAudioEngine sharedEngine];
    // During the warm-up window currentTime remains at zero; it is not a real
    // mid-playback stall and must not downgrade every track.
    if (notification.object != engine || !engine.isPlaying || engine.currentTime < 1.0 || self.qualityFallbackInProgress || self.activeQuality == 0 || !self.currentItem) return;
    [self fallbackToLowQuality];
}
- (void)crossfadeWasCancelled:(NSNotification *)notification { self.crossfadeGeneration += 1; self.crossfadePreparing = NO; }
- (void)playbackDidSeek:(NSNotification *)notification { self.crossfadeGeneration += 1; self.crossfadePreparing = NO; self.lastScrobbleSamplePosition = [waAudioEngine sharedEngine].currentTime; self.hasScrobbleSample = YES; [[waRPCClient sharedClient] publishSeekToPosition:[waAudioEngine sharedEngine].currentTime duration:[waAudioEngine sharedEngine].duration]; }
- (void)engineDidFinish:(NSNotification *)notification {
    waAudioEngine *engine = [waAudioEngine sharedEngine];
    NSTimeInterval duration = engine.duration > 0.0 ? engine.duration : self.currentItem.duration;
    if (self.hasScrobbleSample && duration >= self.lastScrobbleSamplePosition && duration - self.lastScrobbleSamplePosition <= 2.0) self.scrobblePlayedSeconds += duration - self.lastScrobbleSamplePosition;
    [self submitScrobbleIfEligibleAtTime:duration duration:duration];
    if (self.repeatMode == waRepeatModeOne) { [self beginCurrentItem]; return; }
    if (self.repeatMode == waRepeatModeAll || self.queueIndex + 1 < self.queueItems.count) { [self playNext]; return; }
    self.waitingForGenius = NO;
    [self notifyChange];
}
@end
#pragma clang diagnostic pop
