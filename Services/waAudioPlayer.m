#import "waAudioPlayer.h"
#import <UIKit/UIKit.h>
#import <math.h>
#import "../Audio/waAudioEngine.h"
#import "waAPIClient.h" // for waNetworkActivity helpers (serverless shim)
#import "waDownloadManager.h"
#import "waImageLoader.h"
#import "../Models/waPreferences.h"
#import "waLastFMClient.h"
#import "waDeezerClient.h"
#import "waDeezerStreamClient.h"
#import "waRPCClient.h"
#import "waDebugLog.h"
#import <sys/sysctl.h>

NSString * const waAudioPlayerDidChangeNotification = @"waAudioPlayerDidChangeNotification";

static NSString * const waAudioPlayerQueueDefaultsKey = @"waAudioPlayer.persistedQueue";
static NSString * const waAudioPlayerQueueStateDefaultsKey = @"waAudioPlayer.persistedQueueState";

@interface waAudioPlayer ()
@property (nonatomic, strong, readwrite) waMediaItem *currentItem;
@property (nonatomic, assign, readwrite, getter=isLoading) BOOL loading;
@property (nonatomic, assign) NSUInteger requestNumber;
@property (nonatomic, strong, readwrite) NSError *lastError;
@property (nonatomic, copy, readwrite) NSArray *queueItems;
@property (nonatomic, assign, readwrite) NSUInteger queueIndex;
@property (nonatomic, copy, readwrite) NSString *queueContextTitle;
@property (nonatomic, copy) NSString *geniusLoadingTrackID;
@property (nonatomic, assign) BOOL waitingForGenius;
@property (nonatomic, assign) BOOL geniusAutoplayAllowed;
@property (nonatomic, strong) NSTimer *prefetchTimer;
@property (nonatomic, strong) NSMutableSet *prefetchRequestedIDs;
@property (nonatomic, assign) BOOL crossfadePreparing;
@property (nonatomic, assign) BOOL networkPlaybackActive;
@property (nonatomic, assign) NSUInteger crossfadeGeneration;
@property (nonatomic, assign) NSUInteger crossfadePrepFailures;
@property (nonatomic, assign) BOOL scrobbleSubmitted;
@property (nonatomic, assign) BOOL scrobbleInFlight;
@property (nonatomic, strong) NSDate *scrobbleStartDate;
@property (nonatomic, strong) NSDate *scrobbleRetryDate;
// Deezer log.listen mirrors the scrobble lifecycle: one gateway call per
// played track, gated by the same played-seconds threshold, no extra timers.
@property (nonatomic, assign) BOOL deezerListenLogged;
@property (nonatomic, assign) BOOL deezerListenInFlight;
@property (nonatomic, strong) NSDate *deezerListenRetryDate;
@property (nonatomic, copy, readwrite) NSString *qualityLabel;
@property (nonatomic, strong) NSMutableDictionary *localPathsByIdentifier;
@property (nonatomic, strong) NSMutableSet *shufflePlayedItems;
@property (nonatomic, strong) NSMutableArray *shuffleHistory;
@property (nonatomic, assign) NSTimeInterval lastPlaybackPositionSentAt;
@property (nonatomic, assign) NSTimeInterval lastPlaybackPosition;
@property (nonatomic, assign) BOOL hasSentPlaybackPosition;
@property (nonatomic, assign) BOOL nowPlayingSubmitted;
@property (nonatomic, assign) NSTimeInterval scrobblePlayedSeconds;
@property (nonatomic, assign) NSTimeInterval lastScrobbleSamplePosition;
@property (nonatomic, assign) BOOL hasScrobbleSample;
@property (nonatomic, assign) BOOL rpcPlayingPublished;
@property (nonatomic, assign, readwrite) NSTimeInterval persistedPlaybackPosition;
@property (nonatomic, assign) NSTimeInterval lastPersistenceDate;
@property (nonatomic, assign) NSUInteger geniusRequestGeneration;
@property (nonatomic, assign) BOOL resumePositionPending;
@property (nonatomic, assign) BOOL persistingNewItem;
@property (nonatomic, assign) NSUInteger activeQuality;
@property (nonatomic, assign) BOOL qualityFallbackInProgress;
@property (nonatomic, assign) NSTimeInterval qualityFallbackPosition;
@property (nonatomic, strong) NSTimer *playbackStartTimer;
@property (nonatomic, copy) NSString *qualityCodecLabel;
@property (nonatomic, strong) NSTimer *sleepTimer;
@property (nonatomic, strong) NSDate *sleepEndDate;
- (void)invalidatePendingCrossfadeForQueueMutation;
- (void)startPrefetchTimer;
- (void)stopPrefetchTimer;
- (void)armPlaybackStartTimer;
- (void)cancelPlaybackStartTimer;
- (void)fallbackToLowQuality;
- (BOOL)shouldFallbackFromAudioError:(NSError *)error;
- (void)setQualityLabelForQuality:(NSUInteger)quality localFile:(BOOL)hasLocalFile;
- (void)refreshQualityLabel;
- (void)persistQueue;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation waAudioPlayer
@synthesize geniusEnabled = _geniusEnabled;
- (id)init {
    if ((self = [super init])) {
        self.queueItems = @[];
        self.prefetchRequestedIDs = [NSMutableSet set];
        self.localPathsByIdentifier = [NSMutableDictionary dictionary];
        self.shufflePlayedItems = [NSMutableSet set];
         self.shuffleHistory = [NSMutableArray array];
        self.geniusEnabled = YES;
        self.geniusAutoplayAllowed = YES;
         self.repeatMode = waRepeatModeOff;
        NSDictionary *savedState = [[NSUserDefaults standardUserDefaults] objectForKey:waAudioPlayerQueueStateDefaultsKey];
        NSDictionary *state = [savedState isKindOfClass:[NSDictionary class]] ? savedState : @{};
        NSArray *savedQueue = [state[@"items"] isKindOfClass:[NSArray class]] ? state[@"items"] : [[NSUserDefaults standardUserDefaults] objectForKey:waAudioPlayerQueueDefaultsKey];
        if ([savedQueue isKindOfClass:[NSArray class]]) {
            NSMutableArray *restored = [NSMutableArray array];
            for (NSDictionary *dictionary in savedQueue) {
                waMediaItem *item = [waMediaItem itemWithDictionary:dictionary];
                if (item.identifier.length || item.trackId.length) [restored addObject:item];
            }
            self.queueItems = restored;
            NSInteger savedIndex = [state[@"queueIndex"] integerValue];
            NSString *savedIdentifier = [state[@"currentIdentifier"] isKindOfClass:[NSString class]] ? state[@"currentIdentifier"] : nil;
            if (savedIdentifier.length) {
                for (NSUInteger index = 0; index < restored.count; index++) {
                    waMediaItem *candidate = restored[index];
                    NSString *candidateIdentifier = candidate.trackId.length ? candidate.trackId : candidate.identifier;
                    if ([candidateIdentifier isEqualToString:savedIdentifier]) { self.queueIndex = index; self.currentItem = candidate; break; }
                }
            } else if (savedIndex >= 0 && (NSUInteger)savedIndex < restored.count && [state[@"hasCurrentItem"] boolValue]) {
                self.queueIndex = savedIndex;
                self.currentItem = restored[savedIndex];
            }
            if (self.currentItem) {
                double pos = MAX(0.0, [state[@"position"] doubleValue]);
                double dur = self.currentItem.duration;
                // Clamp: if saved near end (> dur-5s) or beyond, start from 0 to avoid seek crash on stale cache
                if (dur > 10 && pos > dur - 5.0) pos = 0.0;
                // Also clamp if pos > 10min beyond plausible (corrupt)
                if (pos > 6000) pos = 0.0;
                self.persistedPlaybackPosition = pos;
                self.resumePositionPending = (pos > 5.0 && dur > 0 && pos < dur - 2.0);
                if (self.resumePositionPending) [[waDebugLog sharedLog] log:@"Restore queue with resume %0.1fs / %0.1fs", pos, dur];
            }
            self.queueContextTitle = [state[@"contextTitle"] isKindOfClass:[NSString class]] ? state[@"contextTitle"] : nil;
        }
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(engineStateDidChange:) name:waAudioEngineStateDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(engineDidFinish:) name:waAudioEngineDidFinishNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(crossfadeWasCancelled:) name:waAudioEngineCrossfadeCancelledNotification object:nil];
         [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playbackDidSeek:) name:waAudioEngineSeekNotification object:nil];
         [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(engineDidStall:) name:waAudioEngineDidStallNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationStateChanged:) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationStateChanged:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationStateChanged:) name:UIApplicationWillTerminateNotification object:nil];
    }
    return self;
}
+ (waAudioPlayer *)sharedPlayer {
    static waAudioPlayer *player;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ player = [[self alloc] init]; });
    return player;
}

- (void)setRepeatMode:(waRepeatMode)repeatMode {
    if (repeatMode > waRepeatModeOne && repeatMode != waRepeatModeAll) repeatMode = waRepeatModeOff;
    _repeatMode = repeatMode;
    _repeatEnabled = repeatMode != waRepeatModeOff;
    if (repeatMode != waRepeatModeOff) self.waitingForGenius = NO;
    if (self.currentItem) [self notifyChange];
}

- (void)setRepeatEnabled:(BOOL)enabled {
    _repeatEnabled = enabled;
    if (!enabled) _repeatMode = waRepeatModeOff;
    else if (_repeatMode == waRepeatModeOff) _repeatMode = waRepeatModeOne;
    if (self.currentItem) [self notifyChange];
}

- (void)setShuffleEnabled:(BOOL)enabled {
    _shuffleEnabled = enabled;
    [self.shufflePlayedItems removeAllObjects];
    [self.shuffleHistory removeAllObjects];
    if (enabled && self.currentItem) {
        [self.shufflePlayedItems addObject:self.currentItem];
        [self.shuffleHistory addObject:self.currentItem];
    }
    if (self.currentItem) [self notifyChange];
}

- (void)playSong:(NSString *)songIdentifier {
    if (!songIdentifier.length) return;
    NSString *deezerID = [songIdentifier hasPrefix:@"deezer:"] ? songIdentifier : [NSString stringWithFormat:@"deezer:%@", songIdentifier];
    waMediaItem *item = [[waMediaItem alloc] initWithIdentifier:deezerID title:@"Wave" subtitle:@"" type:waMediaItemTypeSong];
    item.trackId = deezerID;
    [self playItem:item];
}

- (void)playDownloadedSong:(NSString *)songIdentifier filePath:(NSString *)filePath {
    if (!songIdentifier.length || !filePath.length) return;
    NSString *deezerID = [songIdentifier hasPrefix:@"deezer:"] ? songIdentifier : [NSString stringWithFormat:@"deezer:%@", songIdentifier];
    NSString *resolved = filePath;
    if (![[NSFileManager defaultManager] fileExistsAtPath:resolved]) {
        NSString *managerPath = [[waDownloadManager sharedManager] localPathForIdentifier:deezerID];
        if (managerPath.length) resolved = managerPath;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:resolved]) { [self playSong:deezerID]; return; }
    self.localPathsByIdentifier[deezerID] = resolved;
    waDownload *download = [[waDownloadManager sharedManager] downloadForIdentifier:deezerID];
    NSString *title = download.title.length ? download.title : @"Downloaded Song";
    NSString *artist = download.artist.length ? download.artist : @"";
    waMediaItem *item = [[waMediaItem alloc] initWithIdentifier:deezerID title:title subtitle:artist type:waMediaItemTypeSong];
    item.trackId = deezerID;
    item.artistName = artist;
    item.thumbnailURL = download.thumbnailURL;
    [self playItem:item];
}

- (void)playItem:(waMediaItem *)item {
    [self playItem:item fromContext:@[item] title:nil];
}

- (void)playItem:(waMediaItem *)item fromContext:(NSArray *)context title:(NSString *)contextTitle {
    NSString *trackId = item.trackId.length ? item.trackId : item.identifier;
    if (trackId.length && ![trackId hasPrefix:@"deezer:"]) {
        trackId = [@"deezer:" stringByAppendingString:trackId];
        item.trackId = trackId;
    }
    if (!trackId.length || ![trackId hasPrefix:@"deezer:"]) return;
    NSMutableArray *validItems = [NSMutableArray array];
    for (id object in context) if ([object isKindOfClass:[waMediaItem class]]) {
        waMediaItem *contextItem = object;
        NSString *contextID = contextItem.trackId.length ? contextItem.trackId : contextItem.identifier;
        if (contextID.length && ![contextID hasPrefix:@"deezer:"]) {
            contextID = [@"deezer:" stringByAppendingString:contextID];
            contextItem.trackId = contextID;
        }
        if ([contextID hasPrefix:@"deezer:"]) [validItems addObject:contextItem];
    }
    if (!validItems.count) [validItems addObject:item];
    self.queueItems = validItems;
    [self.shufflePlayedItems removeAllObjects];
    [self.shuffleHistory removeAllObjects];
    [self.prefetchRequestedIDs removeAllObjects];
    self.crossfadePreparing = NO;
    [self stopPrefetchTimer];
    self.crossfadeGeneration += 1;
    self.queueContextTitle = contextTitle.length ? contextTitle : @"Wave";
    self.persistedPlaybackPosition = 0.0;
    self.resumePositionPending = NO;
    self.geniusAutoplayAllowed = YES;
    self.queueIndex = [validItems indexOfObject:item];
    if (self.queueIndex == NSNotFound) {
        NSString *selectedID = item.trackId.length ? item.trackId : item.identifier;
        self.queueIndex = 0;
        for (NSUInteger index = 0; index < validItems.count; index++) {
            waMediaItem *candidate = validItems[index];
            NSString *candidateID = candidate.trackId.length ? candidate.trackId : candidate.identifier;
            if (selectedID.length && [selectedID isEqualToString:candidateID]) { self.queueIndex = index; break; }
        }
    }
    if (self.shuffleEnabled) {
        [self.shufflePlayedItems addObject:item];
        [self.shuffleHistory addObject:item];
    }
     self.geniusLoadingTrackID = nil;
    self.waitingForGenius = NO;
    self.geniusRequestGeneration += 1;
    self.currentItem = item;
    self.persistingNewItem = YES;
    [self persistQueue];
    self.persistingNewItem = NO;
    [self beginCurrentItem];
}

- (void)beginCurrentItem {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self beginCurrentItem]; }); return; }
    if (self.queueIndex >= self.queueItems.count) return;
    [self invalidatePendingCrossfadeForQueueMutation];
    waMediaItem *item = self.queueItems[self.queueIndex];
    NSString *trackId = item.trackId.length ? item.trackId : item.identifier;
    NSString *localPath = self.localPathsByIdentifier[trackId];
    if (!localPath.length) localPath = [[waDownloadManager sharedManager] localPathForIdentifier:trackId];
    // Legacy fallback: .audio extension
    if (localPath.length && ![[NSFileManager defaultManager] fileExistsAtPath:localPath]) {
        NSString *alt = [[localPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"audio"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:alt]) localPath = alt;
    }
    if (localPath.length && [[NSFileManager defaultManager] fileExistsAtPath:localPath]) self.localPathsByIdentifier[trackId] = localPath;
    else localPath = nil;
    BOOL hasLocalFile = localPath.length && [[NSFileManager defaultManager] fileExistsAtPath:localPath];
    self.currentItem = item;
    if (!self.resumePositionPending) self.persistedPlaybackPosition = 0.0;
    self.persistingNewItem = YES;
    [self persistQueue];
    self.persistingNewItem = NO;
    [self evictStaleLocalPaths];
    self.scrobbleSubmitted = NO;
    self.scrobbleInFlight = NO;
    self.scrobbleStartDate = nil;
    self.scrobbleRetryDate = nil;
    self.deezerListenLogged = NO;
    self.deezerListenInFlight = NO;
    self.deezerListenRetryDate = nil;
    self.nowPlayingSubmitted = NO;
    self.scrobblePlayedSeconds = 0.0;
    self.lastScrobbleSamplePosition = 0.0;
    self.hasScrobbleSample = NO;
    self.rpcPlayingPublished = NO;
    self.lastPlaybackPositionSentAt = 0.0;
    self.lastPlaybackPosition = 0.0;
    self.hasSentPlaybackPosition = NO;
    self.lastError = nil;
    self.loading = YES;
    if (hasLocalFile && self.networkPlaybackActive) {
        self.networkPlaybackActive = NO;
        waNetworkActivityEnd();
    } else if (!hasLocalFile && !self.networkPlaybackActive) {
        self.networkPlaybackActive = YES;
        waNetworkActivityBegin();
    }
    self.requestNumber += 1;
    NSUInteger request = self.requestNumber;
    waPreferences *preferences = [waPreferences sharedPreferences];
    // The selected Deezer quality is known before the stream starts. Do not
    // make the UI wait for a metadata request just to display a label.
     waDownload *localDownload = hasLocalFile ? [[waDownloadManager sharedManager] downloadForIdentifier:trackId] : nil;
     // Downloads are the authoritative source for explicit metadata when the
     // queue item was reconstructed without the original API dictionary.
     if (localDownload && localDownload.isExplicit) item.explicit = YES;
       NSUInteger quality = localDownload ? localDownload.downloadQuality : preferences.deezerQuality;
       self.activeQuality = MIN(2, quality);
       [self setQualityLabelForQuality:self.activeQuality localFile:hasLocalFile];
     self.qualityFallbackInProgress = NO;
     self.qualityFallbackPosition = 0.0;
    waAudioEngine *audioEngine = [waAudioEngine sharedEngine];
    // Crossfade is the user's choice on every device (the old <=512MB cap
    // made it silently dead on the 4s/5). The stall watchdog handles devices
    // that genuinely cannot keep up with two simultaneous decodes.
    NSTimeInterval preferredCrossfade = preferences.crossfadeDuration;
    audioEngine.crossfadeDuration = preferredCrossfade;
    audioEngine.crossfadeEnabled = preferredCrossfade > 0.0;
    NSArray *eqGains = preferences.equalizerGains;
    if ([eqGains count] == 5) {
        float gains[5];
        for (int band = 0; band < 5; band++) gains[band] = [[eqGains objectAtIndex:band] floatValue];
        [audioEngine setEqualizerGains:gains];
    }
    [audioEngine setCompressorEnabled:preferences.compressorEnabled];
    [audioEngine setCompressorStrength:preferences.compressorStrength];
    [[NSNotificationCenter defaultCenter] postNotificationName:waAudioPlayerDidChangeNotification object:self];
     void (^startPlayback)(NSURL *, BOOL) = ^(NSURL *playbackURL, BOOL authenticated) {
        if (request != self.requestNumber) return;
        if (!playbackURL) { self.loading = NO; self.lastError = [NSError errorWithDomain:@"com.bytebox.wave.audio" code:-2 userInfo:@{NSLocalizedDescriptionKey:@"The audio URL is invalid."}]; [self notifyChange]; return; }
          NSString *artistName = item.artistName.length ? item.artistName : item.subtitle;
         [[waAudioEngine sharedEngine] updateNowPlaying:item.title artist:artistName duration:item.duration];
          [[waAudioEngine sharedEngine] playURL:playbackURL];
          [self armPlaybackStartTimer];
         self.scrobbleStartDate = [NSDate date];
        NSString *artworkURL = item.thumbnailURL;
         if (artworkURL.length) [[waImageLoader sharedLoader] loadArtworkAtURL:artworkURL placeholder:nil completion:^(UIImage *image) { if (request == self.requestNumber && image) [[waAudioEngine sharedEngine] updateNowPlaying:item.title artist:artistName duration:item.duration artwork:image]; }];
                 (void)authenticated; // presence/activity serverless: no bytebox call
         [self requestGeniusIfNeededForItem:item];
    };

    void (^startNetworkPlayback)(void) = ^{
        NSUInteger requestedQuality = MIN(2, self.activeQuality);
        BOOL authenticated = [[waDeezerClient sharedClient] isAuthenticated];
        [[waDeezerStreamClient sharedClient] resolveStreamURLForTrackID:trackId quality:requestedQuality completion:^(NSURL *directURL, NSUInteger resolvedQuality, NSError *directError) {
            if (request != self.requestNumber) return;
            if (directURL) {
                if (resolvedQuality != requestedQuality) {
                    self.activeQuality = resolvedQuality;
                    [self setQualityLabelForQuality:resolvedQuality localFile:NO];
                    [self notifyChange];
                }
                startPlayback(directURL, authenticated);
                return;
            }
            [[waDebugLog sharedLog] log:@"Direct stream failed (%@), no server fallback (serverless)", directError.localizedDescription ?: @"unknown"];
            self.loading = NO;
            self.lastError = directError ?: [NSError errorWithDomain:@"com.bytebox.wave.audio" code:-3 userInfo:@{NSLocalizedDescriptionKey:@"Track not streamable with this account."}];
            [self notifyChange];
        }];
    };

     if (hasLocalFile) {
         startPlayback([NSURL fileURLWithPath:localPath], NO);
     } else if ([trackId hasPrefix:@"deezer:"]) {
         // Serverless: playback must not wait for the backend metadata call.
         // Enrich labels via the public Deezer API in parallel, best effort.
         [[waDeezerStreamClient sharedClient] fetchPublicTrackDetailsForTrackID:trackId completion:^(NSDictionary *details, NSError *error) {
             if (request != self.requestNumber || error || !details) return;
             if ([details[@"title"] isKindOfClass:[NSString class]] && [details[@"title"] length]) self.currentItem.title = details[@"title"];
             NSString *detailArtist = [details[@"artistName"] isKindOfClass:[NSString class]] ? details[@"artistName"] : details[@"author"];
             if (detailArtist.length) self.currentItem.artistName = detailArtist;
             if ([details[@"albumName"] isKindOfClass:[NSString class]]) self.currentItem.albumName = details[@"albumName"];
             NSNumber *detailDuration = [details[@"duration"] respondsToSelector:@selector(doubleValue)] ? details[@"duration"] : nil;
             if (detailDuration.doubleValue > 0.0) self.currentItem.duration = detailDuration.doubleValue;
             [self notifyChange];
         }];
         startNetworkPlayback();
     } else {
         startNetworkPlayback();
     }
}

- (void)requestGeniusIfNeededForItem:(waMediaItem *)item {
    [[waDebugLog sharedLog] log:@"[Genius] request check item=%@ queue=%lu index=%lu", item.trackId ?: item.identifier, (unsigned long)self.queueItems.count, (unsigned long)self.queueIndex];
    if (!self.geniusEnabled || !self.geniusAutoplayAllowed || !item) { [[waDebugLog sharedLog] log:@"[Genius] disabled/conditions"]; return; }
    if (self.queueItems.count > self.queueIndex && self.queueItems.count - self.queueIndex > 2) return;
     NSString *trackID = item.trackId.length ? item.trackId : item.identifier;
     if (!trackID.length || ![trackID hasPrefix:@"deezer:"] || [trackID isEqualToString:self.geniusLoadingTrackID]) return;
     self.geniusLoadingTrackID = trackID;
    NSUInteger geniusGeneration = ++self.geniusRequestGeneration;
    NSUInteger request = self.requestNumber;
     [[waDeezerClient sharedClient] relatedForTrackID:trackID completion:^(NSArray *rows, NSError *error) {
         if (request != self.requestNumber || geniusGeneration != self.geniusRequestGeneration || ![trackID isEqualToString:self.currentItem.trackId.length ? self.currentItem.trackId : self.currentItem.identifier]) return;
         self.geniusLoadingTrackID = nil;
        if (error || !rows.count || !self.geniusEnabled || !self.geniusAutoplayAllowed) {
            BOOL shouldAdvance = self.waitingForGenius && self.queueIndex + 1 < self.queueItems.count;
            self.waitingForGenius = NO;
            if (shouldAdvance) [self playNext]; else [self notifyChange];
            return;
        }
        NSMutableArray *items = [self.queueItems mutableCopy];
        NSMutableSet *known = [NSMutableSet set];
         for (waMediaItem *knownItem in items) { NSString *knownID = knownItem.trackId.length ? knownItem.trackId : knownItem.identifier; if (knownID.length) [known addObject:knownID]; }
        for (NSDictionary *dictionary in rows) {
            waMediaItem *related = [waMediaItem itemWithDictionary:dictionary];
             NSString *relatedID = related.trackId.length ? related.trackId : related.identifier;
            if (!related || ![relatedID hasPrefix:@"deezer:"] || [known containsObject:relatedID]) continue;
            related.type = waMediaItemTypeSong;
            related.geniusRecommended = YES;
            [known addObject:relatedID];
            [items addObject:related];
        }
        // Cap endless Genius growth: keep at most 200 entries, trimming
        // played history from the front so queueIndex stays valid and the
        // O(n) persist/serialize below never grows without bound.
        NSUInteger geniusIndex = self.queueIndex;
        while (items.count > 200 && geniusIndex > 50) {
            [items removeObjectAtIndex:0];
            geniusIndex -= 1;
        }
        self.queueIndex = geniusIndex;
        self.queueItems = items;
        [self evictStaleLocalPaths];
        [self persistQueue];
        [self notifyChange];
        if (self.waitingForGenius && items.count > self.queueIndex + 1) { self.waitingForGenius = NO; [self playNext]; }
    }];
}

// Non-mutating mirror of playNext for the crossfade prefetch path: resolves
// which item automatic advance must land on, honoring repeat/shuffle.
// Returns NO when playback must stop (or fall through to Genius) instead.
- (BOOL)resolveAutoAdvanceTargetIndex:(NSUInteger *)outIndex item:(waMediaItem **)outItem {
    if (!self.queueItems.count || self.queueIndex >= self.queueItems.count) return NO;
    if (self.repeatMode == waRepeatModeOne) {
        if (outIndex) *outIndex = self.queueIndex;
        if (outItem) *outItem = self.queueItems[self.queueIndex];
        return YES;
    }
    if (self.shuffleEnabled && self.queueItems.count > 1) {
        NSMutableArray *candidates = [NSMutableArray array];
        for (waMediaItem *item in self.queueItems) if (![self.shufflePlayedItems containsObject:item]) [candidates addObject:item];
        if (!candidates.count) {
            if (self.repeatMode != waRepeatModeAll) return NO;
            waMediaItem *current = self.queueItems[self.queueIndex];
            for (waMediaItem *item in self.queueItems) if (item != current) [candidates addObject:item];
            if (!candidates.count) return NO;
        }
        waMediaItem *pick = candidates[(NSUInteger)arc4random_uniform((u_int32_t)candidates.count)];
        NSUInteger index = [self.queueItems indexOfObjectIdenticalTo:pick];
        if (index == NSNotFound) return NO;
        if (outIndex) *outIndex = index;
        if (outItem) *outItem = pick;
        return YES;
    }
    NSUInteger index = self.queueIndex;
    if (index + 1 < self.queueItems.count) index += 1;
    else if (self.repeatMode == waRepeatModeAll) index = 0;
    else return NO;
    if (outIndex) *outIndex = index;
    if (outItem) *outItem = self.queueItems[index];
    return YES;
}

- (void)prefetchTick:(NSTimer *)timer {
    if (!self.currentItem || self.loading) return;
    waAudioEngine *engine = [waAudioEngine sharedEngine];
    if (!engine.isPlaying) return;
    waPreferences *preferences = [waPreferences sharedPreferences];
    if (self.crossfadePreparing && engine.crossfadeDuration != preferences.crossfadeDuration) {
        [engine cancelCrossfade];
        self.crossfadeGeneration += 1;
        self.crossfadePreparing = NO;
    }
    NSTimeInterval preferredCrossfade = preferences.crossfadeDuration;
    engine.crossfadeEnabled = preferredCrossfade > 0.0;
    engine.crossfadeDuration = preferredCrossfade;
    NSTimeInterval duration = engine.duration > 0.0 ? engine.duration : self.currentItem.duration;
    NSTimeInterval elapsed = engine.currentTime;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    BOOL positionJumped = self.hasSentPlaybackPosition && fabs(elapsed - self.lastPlaybackPosition) >= 2.0;
    if (!self.hasSentPlaybackPosition || positionJumped || now - self.lastPlaybackPositionSentAt >= 2.0) {
        [[waRPCClient sharedClient] updatePlaybackPosition:elapsed duration:duration];
        self.lastPlaybackPositionSentAt = now;
        self.lastPlaybackPosition = elapsed;
        self.hasSentPlaybackPosition = YES;
    }
    if (now - self.lastPersistenceDate >= (self.queueItems.count > 100 ? 10.0 : 2.0)) [self persistQueue];
    [self recordScrobblePlaybackProgress];
    [self submitListenReportsIfEligibleAtTime:elapsed duration:duration];
    // Keep lockscreen elapsed scrub alive on iOS 7 (MPNowPlayingInfoCenter needs rate+time refreshed)
    [[waAudioEngine sharedEngine] updateNowPlayingPlaybackState];
    NSTimeInterval remaining = duration - elapsed;
    if (duration <= 0.0 || remaining < 0.0) return;

    // The user's value is the actual overlap. Prepare the next PCM decoder
    // well before the handoff so the server can resolve/cache the stream and
    // the mixer has enough decoded audio for a gapless transition.
    NSTimeInterval crossfade = MIN(preferredCrossfade, MAX(0.0, duration - 0.5));
    NSTimeInterval lead = crossfade + 45.0;
    if (remaining > lead) return;

    // Resolve the automatic-advance target honoring repeat/shuffle states,
    // mirroring playNext. Without this the crossfade path always advanced to
    // queueIndex+1, ignoring Repeat-One (must replay) and Shuffle (must pick
    // a random unplayed item), and never wrapping on Repeat-All.
    NSUInteger targetIndex = self.queueIndex;
    waMediaItem *target = nil;
    if (![self resolveAutoAdvanceTargetIndex:&targetIndex item:&target] || !target) {
        [self requestGeniusIfNeededForItem:self.currentItem];
        return;
    }
    // Repeat-One replays via engineDidFinish; crossfading a track into itself
    // would overlap the same audio, so skip preparation here.
    if (targetIndex == self.queueIndex) return;

    waMediaItem *next = target;
    NSString *previousTrackID = self.currentItem.trackId.length ? self.currentItem.trackId : self.currentItem.identifier;
    NSString *trackID = next.trackId.length ? next.trackId : next.identifier;
    if (!trackID.length) return;
    if (crossfade > 0.0 && !self.crossfadePreparing) {
        // A failed preparation backs off one tick and the retry falls back to
        // MP3 for the pending track: a FLAC->MP3 fade still beats the hard
        // switch when the lossless endpoint rejects streams for a while
        // (seen as "audio decoder could not open the source" in wave.log).
        if (self.crossfadePrepFailures == 1) { self.crossfadePrepFailures = 2; return; }
        NSUInteger prepQuality = self.crossfadePrepFailures >= 2 ? 0 : MIN(2, [waPreferences sharedPreferences].deezerQuality);
        self.crossfadePreparing = YES;
        NSUInteger crossfadeGeneration = ++self.crossfadeGeneration;
        // At the handoff the old item is still current. This covers the
        // narrow timer/network race where the final prefetch tick was missed.
        [self submitListenReportsIfEligibleAtTime:elapsed duration:duration];
        NSUInteger request = self.requestNumber;
        NSUInteger crossfadeIndex = targetIndex;
        if (self.crossfadePrepFailures) [[waDebugLog sharedLog] log:@"Crossfade retry with MP3 pending track after %lu failed prep attempt(s)", (unsigned long)self.crossfadePrepFailures];
        [self requestStreamURLForItem:next quality:prepQuality completion:^(NSURL *url, BOOL authenticated) {
            if (request != self.requestNumber || crossfadeGeneration != self.crossfadeGeneration) return;
            if (!url || crossfadeIndex >= self.queueItems.count || self.queueItems[crossfadeIndex] != target) { self.crossfadePreparing = NO; return; }
            [[waAudioEngine sharedEngine] crossfadeToURL:url duration:crossfade completion:^(BOOL started) {
                if (crossfadeGeneration != self.crossfadeGeneration) return;
                self.crossfadePreparing = NO;
                if (!started || request != self.requestNumber || crossfadeIndex >= self.queueItems.count || self.queueItems[crossfadeIndex] != target) {
                    if (!started && request == self.requestNumber) {
                        self.crossfadePrepFailures = MIN(self.crossfadePrepFailures + 1, (NSUInteger)2);
                        [[waDebugLog sharedLog] log:@"Crossfade preparation failed; retry will use MP3 pending track"];
                    }
                    return;
                }
                self.crossfadePrepFailures = 0;
                // The engine has already switched clocks at this point, so
                // explicitly complete the old track before replacing it.
                [self submitListenReportsIfEligibleAtTime:duration duration:duration];
                waMediaItem *nextItem = self.queueItems[crossfadeIndex];
                  self.queueIndex = crossfadeIndex;
                  self.currentItem = nextItem;
                  if (self.shuffleEnabled) {
                      [self.shufflePlayedItems addObject:nextItem];
                      [self.shuffleHistory addObject:nextItem];
                  }
                    [self markPlaybackStartedIfNeeded];
                 self.scrobbleSubmitted = NO;
                 self.scrobbleInFlight = NO;
                 self.scrobbleStartDate = [NSDate date];
                  self.scrobbleRetryDate = nil;
                  self.deezerListenLogged = NO;
                  self.deezerListenInFlight = NO;
                  self.deezerListenRetryDate = nil;
                  self.nowPlayingSubmitted = NO;
                  self.scrobblePlayedSeconds = 0.0;
                  self.lastScrobbleSamplePosition = 0.0;
                  self.hasScrobbleSample = NO;
                  self.lastPlaybackPositionSentAt = 0.0;
                  self.lastPlaybackPosition = 0.0;
                  self.hasSentPlaybackPosition = NO;
                self.requestNumber += 1;
                self.loading = NO;
                 NSString *nextArtistName = nextItem.artistName.length ? nextItem.artistName : nextItem.subtitle;
                 [[waAudioEngine sharedEngine] updateNowPlaying:nextItem.title artist:nextArtistName duration:nextItem.duration];
                NSUInteger nextRequest = self.requestNumber;
                  if (nextItem.thumbnailURL.length) [[waImageLoader sharedLoader] loadArtworkAtURL:nextItem.thumbnailURL placeholder:nil completion:^(UIImage *image) { if (nextRequest == self.requestNumber && image) [[waAudioEngine sharedEngine] updateNowPlaying:nextItem.title artist:nextArtistName duration:nextItem.duration artwork:image]; }];
                 (void)authenticated; // serverless: presence/activity disabled
                  NSString *nextTrackID = nextItem.trackId.length ? nextItem.trackId : nextItem.identifier;
                   self.rpcPlayingPublished = NO;
                   [self markPlaybackStartedIfNeeded];
                   [[waRPCClient sharedClient] publishCrossfadeToTrackID:nextTrackID fromTrackID:previousTrackID duration:crossfade position:0.0];
                  [self persistQueue];
                  [self notifyChange];
                [self requestGeniusIfNeededForItem:nextItem];
            }];
        }];
    }
}

- (void)startPrefetchTimer {
    if (![NSThread isMainThread] || self.prefetchTimer || !self.currentItem || ![waAudioEngine sharedEngine].isPlaying) return;
    // Position/scrobble persistence does not need sub-second polling on iOS
    // 6, and this timer competes with the PCM mixer on older devices.
    self.prefetchTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(prefetchTick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.prefetchTimer forMode:NSRunLoopCommonModes];
}
- (void)stopPrefetchTimer { [self.prefetchTimer invalidate]; self.prefetchTimer = nil; }

- (void)requestStreamURLForItem:(waMediaItem *)item completion:(void (^)(NSURL *, BOOL))completion {
    [self requestStreamURLForItem:item quality:[waPreferences sharedPreferences].deezerQuality completion:completion];
}

- (void)requestStreamURLForItem:(waMediaItem *)item quality:(NSUInteger)quality completion:(void (^)(NSURL *, BOOL))completion {
    NSString *trackID = item.trackId.length ? item.trackId : item.identifier;
    if (!trackID.length) { if (completion) completion(nil, NO); return; }
    NSString *localPath = self.localPathsByIdentifier[trackID];
    if (!localPath.length) localPath = [[waDownloadManager sharedManager] localPathForIdentifier:trackID];
    if (localPath.length && [[NSFileManager defaultManager] fileExistsAtPath:localPath]) {
        self.localPathsByIdentifier[trackID] = localPath;
        if (completion) completion([NSURL fileURLWithPath:localPath], NO); return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL authenticated = [[waDeezerClient sharedClient] isAuthenticated];
        NSUInteger resolvedQuality = MIN((NSUInteger)2, quality);
        [[waDeezerStreamClient sharedClient] resolveStreamURLForTrackID:trackID quality:resolvedQuality completion:^(NSURL *directURL, NSUInteger grantedQuality, NSError *directError) {
            (void)grantedQuality;
            if (directURL) { if (completion) completion(directURL, authenticated); return; }
            [[waDebugLog sharedLog] log:@"Direct prefetch failed (%@), serverless - no fallback", directError.localizedDescription ?: @"unknown"];
            if (completion) completion(nil, authenticated);
        }];
    });
}

- (double)bitrateKbps {
    return [waAudioEngine sharedEngine].bitrateKbps;
}

- (void)setQualityLabelForQuality:(NSUInteger)quality localFile:(BOOL)hasLocalFile {
    NSUInteger normalizedQuality = MIN(2, quality);
    if (normalizedQuality == 2) self.qualityCodecLabel = hasLocalFile ? @"ALAC" : @"FLAC";
    else self.qualityCodecLabel = @"MP3";
    [self refreshQualityLabel];
}

- (void)refreshQualityLabel {
    if (!self.qualityCodecLabel.length) {
        self.qualityLabel = nil;
        return;
    }

    double bitrate = self.bitrateKbps;
    if (bitrate > 0.0 && isfinite(bitrate)) {
        NSUInteger roundedBitrate = (NSUInteger)MAX(1.0, floor(bitrate + 0.5));
        BOOL lossless = [self.qualityCodecLabel isEqualToString:@"FLAC"] || [self.qualityCodecLabel isEqualToString:@"ALAC"];
        self.qualityLabel = lossless
            ? [NSString stringWithFormat:@"%@ • %lu kbps avg", self.qualityCodecLabel, (unsigned long)roundedBitrate]
            : [NSString stringWithFormat:@"%@ • %lu kbps", self.qualityCodecLabel, (unsigned long)roundedBitrate];
    } else {
        self.qualityLabel = [NSString stringWithFormat:@"%@ • Detecting bitrate…", self.qualityCodecLabel];
    }
}

- (void)notifyChange { [[NSNotificationCenter defaultCenter] postNotificationName:waAudioPlayerDidChangeNotification object:self]; }

- (void)recordScrobblePlaybackProgress {
    waAudioEngine *engine = [waAudioEngine sharedEngine];
    NSTimeInterval position = engine.currentTime;
    if (!engine.isPlaying || !isfinite(position) || position < 0.0) return;
    if (self.hasScrobbleSample) {
        NSTimeInterval delta = position - self.lastScrobbleSamplePosition;
        // A large jump is a seek, not listened time. Small backward jumps are
        // also excluded, while normal timer jitter is retained.
        if (delta > 0.0 && delta <= 2.0) self.scrobblePlayedSeconds += delta;
    }
    self.lastScrobbleSamplePosition = position;
    self.hasScrobbleSample = YES;
}

- (void)markPlaybackStartedIfNeeded {
    if (!self.currentItem || ![waAudioEngine sharedEngine].isPlaying) return;
    if (!self.nowPlayingSubmitted) {
        self.nowPlayingSubmitted = YES;
        self.scrobbleStartDate = [NSDate date];
        self.lastScrobbleSamplePosition = [waAudioEngine sharedEngine].currentTime;
        self.hasScrobbleSample = YES;
        NSString *artist = self.currentItem.artistName.length ? self.currentItem.artistName : self.currentItem.subtitle;
        [[waLastFMClient sharedClient] updateNowPlayingArtist:artist title:self.currentItem.title duration:[waAudioEngine sharedEngine].duration > 0.0 ? [waAudioEngine sharedEngine].duration : self.currentItem.duration completion:nil];
    }
    if (!self.rpcPlayingPublished) {
        self.rpcPlayingPublished = YES;
         NSString *trackID = self.currentItem.trackId.length ? self.currentItem.trackId : self.currentItem.identifier;
        NSString *artist = self.currentItem.artistName.length ? self.currentItem.artistName : self.currentItem.subtitle;
        waAudioEngine *engine = [waAudioEngine sharedEngine];
         [[waRPCClient sharedClient] publishPlaybackWithTrackID:trackID title:self.currentItem.title artist:artist album:self.currentItem.albumName state:@"playing" position:engine.currentTime duration:engine.duration > 0.0 ? engine.duration : self.currentItem.duration artworkURL:self.currentItem.thumbnailURL];
    }
}

- (void)invalidatePendingCrossfadeForQueueMutation {
    NSUInteger generation = self.crossfadeGeneration;
    [[waAudioEngine sharedEngine] cancelCrossfade];
    if (self.crossfadeGeneration == generation) self.crossfadeGeneration += 1;
    self.crossfadePreparing = NO;
}
- (void)submitScrobbleIfEligibleAtTime:(NSTimeInterval)elapsed duration:(NSTimeInterval)duration {
    waPreferences *preferences = [waPreferences sharedPreferences];
    waMediaItem *item = self.currentItem;
    if (!preferences.lastFMScrobblingEnabled || self.scrobbleSubmitted || self.scrobbleInFlight || ![waLastFMClient sharedClient].isAuthenticated || !item || duration <= 30.0) return;
    if (self.scrobbleRetryDate && [[NSDate date] compare:self.scrobbleRetryDate] == NSOrderedAscending) return;
    NSTimeInterval threshold = MIN(duration * 0.5, 240.0);
    if (self.scrobblePlayedSeconds < threshold) return;
    self.scrobbleInFlight = YES;
    NSString *artist = item.artistName.length ? item.artistName : item.subtitle;
    NSDate *startDate = self.scrobbleStartDate ?: [NSDate date];
    [[waLastFMClient sharedClient] scrobbleArtist:artist title:item.title album:item.albumName duration:duration timestamp:[startDate timeIntervalSince1970] completion:^(NSError *error) {
        if (self.currentItem != item) return;
        self.scrobbleInFlight = NO;
        if (error) self.scrobbleRetryDate = [NSDate dateWithTimeIntervalSinceNow:15.0];
        else {
            self.scrobbleSubmitted = YES;
            self.scrobbleRetryDate = nil;
        }
    }];
}

- (void)submitListenReportsIfEligibleAtTime:(NSTimeInterval)elapsed duration:(NSTimeInterval)duration {
    // Single funnel for both report sinks: Last.fm scrobble + Deezer
    // log.listen. Each has its own once-per-track gate; until the shared
    // played-seconds threshold is reached the Deezer check is a few
    // property reads — no extra timers, no extra wakeups.
    [self submitScrobbleIfEligibleAtTime:elapsed duration:duration];
    [self submitDeezerListenIfEligibleWithDuration:duration];
}
- (void)submitDeezerListenIfEligibleWithDuration:(NSTimeInterval)duration {
    waPreferences *preferences = [waPreferences sharedPreferences];
    waMediaItem *item = self.currentItem;
    if (preferences.privateSession) return;
    if (self.deezerListenLogged || self.deezerListenInFlight) return;
    if (![[waDeezerClient sharedClient] isAuthenticated] || !item || duration <= 30.0) return;
    NSString *trackID = item.trackId.length ? item.trackId : item.identifier;
    if (![trackID hasPrefix:@"deezer:"]) return; // only catalogue plays count
    if (self.deezerListenRetryDate && [[NSDate date] compare:self.deezerListenRetryDate] == NSOrderedAscending) return;
    // Native parity: the web player reports after ~30s of playback, not at
    // half duration (Last.fm keeps its own rule). Short tracks under 30s of
    // audio never qualify — same floor as scrobbles.
    if (self.scrobblePlayedSeconds < 30.0) return;
    self.deezerListenInFlight = YES;
    NSDate *startDate = self.scrobbleStartDate ?: [NSDate date];
    NSString *format = self.activeQuality == 2 ? @"FLAC" : (self.activeQuality == 1 ? @"MP3_320" : @"MP3_128");
    [[waDeezerClient sharedClient] logListenForSongIdentifier:trackID format:format listenedAt:[startDate timeIntervalSince1970] completion:^(NSError *error) {
        if (self.currentItem != item) return;
        self.deezerListenInFlight = NO;
        if (error) self.deezerListenRetryDate = [NSDate dateWithTimeIntervalSinceNow:15.0];
        else {
            self.deezerListenLogged = YES;
            self.deezerListenRetryDate = nil;
        }
    }];
}

- (void)pause {
    [[waAudioEngine sharedEngine] pause];
    [self stopPrefetchTimer];
    if (self.networkPlaybackActive) {
        self.networkPlaybackActive = NO;
        waNetworkActivityEnd();
    }
    waMediaItem *item = self.currentItem;
    [self persistQueue];
    if (item) {
         NSString *trackID = item.trackId.length ? item.trackId : item.identifier;
        NSString *artist = item.artistName.length ? item.artistName : item.subtitle;
         [[waRPCClient sharedClient] publishPlaybackWithTrackID:trackID title:item.title artist:artist album:item.albumName state:@"paused" position:[waAudioEngine sharedEngine].currentTime duration:item.duration artworkURL:item.thumbnailURL];
    }
    // Serverless: presence/activity disabled (no bytebox)
}

- (void)resume {
    if (self.currentItem && ![[waAudioEngine sharedEngine] hasLoadedPlaybackItem]) {
        self.resumePositionPending = self.persistedPlaybackPosition > 0.0;
        self.loading = YES;
        [self beginCurrentItem];
        return;
    }
     NSString *trackID = self.currentItem.trackId.length ? self.currentItem.trackId : self.currentItem.identifier;
     NSString *localPath = self.localPathsByIdentifier[trackID];
    BOOL hasLocalFile = localPath.length && [[NSFileManager defaultManager] fileExistsAtPath:localPath];
    if (!hasLocalFile && !self.networkPlaybackActive) {
        self.networkPlaybackActive = YES;
        waNetworkActivityBegin();
    }
     self.rpcPlayingPublished = NO;
     [[waAudioEngine sharedEngine] resume];
     self.hasSentPlaybackPosition = NO;
     // Serverless: presence disabled
}

- (void)togglePlayPause {
    if (self.loading) return;
    if ([waAudioEngine sharedEngine].isPlaying) [self pause];
    else [self resume];
}

- (void)setSleepTimerWithInterval:(NSTimeInterval)interval {
    [self cancelSleepTimer];
    if (interval <= 0.0) return;
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf setSleepTimerWithInterval:interval]; });
        return;
    }
    self.sleepEndDate = [NSDate dateWithTimeIntervalSinceNow:interval];
    self.sleepTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(sleepTimerTick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.sleepTimer forMode:NSRunLoopCommonModes];
    [self notifyChange];
}

- (void)cancelSleepTimer {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf cancelSleepTimer]; });
        return;
    }
    BOOL hadTimer = self.sleepTimer != nil;
    [self.sleepTimer invalidate];
    self.sleepTimer = nil;
    self.sleepEndDate = nil;
    if (hadTimer) [self notifyChange];
}

- (NSTimeInterval)sleepTimeRemaining {
    if (!self.sleepEndDate) return 0.0;
    return MAX(0.0, [self.sleepEndDate timeIntervalSinceNow]);
}

- (void)sleepTimerTick:(NSTimer *)timer {
    if (timer != self.sleepTimer) return;
    if (self.sleepTimeRemaining <= 0.0) {
        [self cancelSleepTimer];
        [self pause];
        return;
    }
    [self notifyChange];
}
- (void)stop {
    [self cancelSleepTimer];
    [self persistQueue];
    self.requestNumber += 1;
    [self stopPrefetchTimer];
    if (self.networkPlaybackActive) {
        self.networkPlaybackActive = NO;
        waNetworkActivityEnd();
    }
    self.waitingForGenius = NO;
     self.geniusLoadingTrackID = nil;
    self.geniusRequestGeneration += 1;
    [[waAudioEngine sharedEngine] stop];
    [[waRPCClient sharedClient] shutdown];
    // Serverless: clearPresence disabled
}

- (void)evictStaleLocalPaths {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self evictStaleLocalPaths]; }); return; }
    if (self.localPathsByIdentifier.count <= self.queueItems.count + 20) return;
    NSMutableSet *live = [NSMutableSet setWithCapacity:self.queueItems.count + 1];
    for (waMediaItem *item in self.queueItems) {
        NSString *key = item.trackId.length ? item.trackId : item.identifier;
        if (key.length) [live addObject:key];
    }
    NSString *currentKey = self.currentItem.trackId.length ? self.currentItem.trackId : self.currentItem.identifier;
    if (currentKey.length) [live addObject:currentKey];
    for (NSString *key in [self.localPathsByIdentifier.allKeys copy]) {
        if (![live containsObject:key]) [self.localPathsByIdentifier removeObjectForKey:key];
    }
}

- (void)persistQueue {
    if (![NSThread isMainThread]) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf persistQueue]; });
        return;
    }
    // Capture one coherent snapshot before the caller changes track state.
    self.lastPersistenceDate = [NSDate timeIntervalSinceReferenceDate];
    // For huge Genius queues (200), only persist window around current to avoid 256MB OOM on 3GS and stale cache
    NSArray *queueToSave = self.queueItems;
    NSUInteger saveIndex = self.queueIndex;
    if (queueToSave.count > 50) {
        NSUInteger start = saveIndex > 20 ? saveIndex - 20 : 0;
        NSUInteger end = MIN(queueToSave.count, start + 60);
        // Adjust start if near end
        if (end - start < 60 && start > 0) start = end > 60 ? end - 60 : 0;
        queueToSave = [queueToSave subarrayWithRange:NSMakeRange(start, end - start)];
        saveIndex = saveIndex - start;
    }
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:queueToSave.count];
    for (waMediaItem *item in queueToSave) {
        if ([item isKindOfClass:[waMediaItem class]]) [items addObject:item.dictionaryRepresentation];
    }
    NSArray *saved = [items copy];
    NSTimeInterval position = self.persistedPlaybackPosition;
    if (!self.persistingNewItem && !self.loading && self.currentItem && [waAudioEngine sharedEngine].hasLoadedPlaybackItem) position = [waAudioEngine sharedEngine].currentTime;
    if (!isfinite(position) || position < 0.0) position = 0.0;
    // Don't persist near-end position (would seek to EOF on restore and crash via HTTPSource)
    NSTimeInterval dur = [waAudioEngine sharedEngine].duration > 0 ? [waAudioEngine sharedEngine].duration : self.currentItem.duration;
    if (dur > 10 && position > dur - 3.0) position = 0.0;
    self.persistedPlaybackPosition = position;
    // Adjust queueIndex for windowed save
    NSUInteger stateIndex = saveIndex;
    NSString *currentIdentifier = self.currentItem.trackId.length ? self.currentItem.trackId : self.currentItem.identifier;
    NSDictionary *state = @{ @"items": saved,
                             @"hasCurrentItem": @(self.currentItem != nil),
                             @"currentIdentifier": [currentIdentifier copy] ?: @"",
                             @"queueIndex": @(stateIndex),
                             @"position": @(position),
                             @"contextTitle": [self.queueContextTitle copy] ?: @"" };
    static dispatch_queue_t waPersistQueue;
    static dispatch_once_t persistOnceToken;
    dispatch_once(&persistOnceToken, ^{ waPersistQueue = dispatch_queue_create("com.bytebox.wave.audio-persist", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(waPersistQueue, ^{
        [[NSUserDefaults standardUserDefaults] setObject:state forKey:waAudioPlayerQueueStateDefaultsKey];
        [[NSUserDefaults standardUserDefaults] setObject:saved forKey:waAudioPlayerQueueDefaultsKey];
        // No synchronize here: autosync covers; synchronize is blocking disk I/O.
    });
}
#if 0
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
        NSTimeInterval raw = self.persistedPlaybackPosition;
        // Clamp to safe window: not at 0, not at very end where cache may be trimmed
        NSTimeInterval position = MIN(raw, engine.duration - 2.0);
        if (position < 5.0 || position >= engine.duration - 2.0) {
            [[waDebugLog sharedLog] log:@"Resume skip invalid pos %0.1f dur %0.1f", raw, engine.duration];
            self.resumePositionPending = NO;
        } else {
            self.resumePositionPending = NO;
            [[waDebugLog sharedLog] log:@"Resuming at %0.1fs / %0.1fs", position, engine.duration];
            @try { [engine seekToTime:position]; } @catch (NSException *e) { [[waDebugLog sharedLog] log:@"Resume seek crash: %@", e.reason]; }
        }
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
    return error.code == -10 || error.code == -11 || error.code == -12 || error.code == -14;
}
- (void)armPlaybackStartTimer {
    [self cancelPlaybackStartTimer];
    self.playbackStartTimer = [NSTimer timerWithTimeInterval:20.0 target:self selector:@selector(playbackStartTimedOut:) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.playbackStartTimer forMode:NSRunLoopCommonModes];
}
- (void)cancelPlaybackStartTimer { [self.playbackStartTimer invalidate]; self.playbackStartTimer = nil; }
- (void)playbackStartTimedOut:(NSTimer *)timer {
    if (timer != self.playbackStartTimer || [waAudioEngine sharedEngine].isPlaying) return;
    [self cancelPlaybackStartTimer];
    [self fallbackToLowQuality];
}
- (void)fallbackToLowQuality {
    if (self.activeQuality == 0 || !self.currentItem) return;
    NSString *trackID = self.currentItem.trackId.length ? self.currentItem.trackId : self.currentItem.identifier;
    NSURL *fallbackURL = [[waAPIClient sharedClient] streamURLForTrackId:trackID ticketURL:nil quality:0];
    if (!fallbackURL) return;
    self.qualityFallbackInProgress = YES;
    self.qualityFallbackPosition = [waAudioEngine sharedEngine].currentTime;
    self.activeQuality = 0;
    [self setQualityLabelForQuality:0 localFile:NO];
    [[waAudioEngine sharedEngine] playURL:fallbackURL];
    [self notifyChange];
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
- (void)engineDidFinish:(NSNotification *)notification { waAudioEngine *engine = [waAudioEngine sharedEngine]; NSTimeInterval duration = engine.duration > 0.0 ? engine.duration : self.currentItem.duration; if (self.hasScrobbleSample && duration >= self.lastScrobbleSamplePosition && duration - self.lastScrobbleSamplePosition <= 2.0) self.scrobblePlayedSeconds += duration - self.lastScrobbleSamplePosition; [self submitListenReportsIfEligibleAtTime:duration duration:duration]; if (self.repeatMode == waRepeatModeOne) { [self beginCurrentItem]; return; } if (self.repeatMode == waRepeatModeAll || self.queueIndex + 1 < self.queueItems.count) { [self playNext]; return; } self.waitingForGenius = NO; [self notifyChange]; }
#endif
- (void)setGeniusEnabled:(BOOL)enabled {
    _geniusEnabled = enabled;
    if (!enabled) {
        // Disabling Genius must also cancel any "wait for recommendation"
        // state. Re-enabling it must never advance the current song by itself.
        self.waitingForGenius = NO;
     self.geniusLoadingTrackID = nil;
    } else {
        self.geniusAutoplayAllowed = YES;
        if (self.currentItem && self.queueIndex + 1 >= self.queueItems.count && !self.loading) {
            [self requestGeniusIfNeededForItem:self.currentItem];
        }
    }
}
- (void)dealloc { [self.prefetchTimer invalidate]; [self.playbackStartTimer invalidate]; [[NSNotificationCenter defaultCenter] removeObserver:self]; }
@end
#pragma clang diagnostic pop
