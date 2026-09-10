#import "waAudioPlayer+QueuePrivate.h"

@interface waAudioPlayer (EnginePrivate)
@property (nonatomic, strong, readwrite) NSError *lastError;
@property (nonatomic, assign, readwrite, getter=isLoading) BOOL loading;
@property (nonatomic, assign) BOOL networkPlaybackActive;
@property (nonatomic, assign) NSUInteger activeQuality;
@property (nonatomic, assign) BOOL qualityFallbackInProgress;
@property (nonatomic, assign) NSTimeInterval qualityFallbackPosition;
@property (nonatomic, strong) NSTimer *playbackStartTimer;
@property (nonatomic, assign) NSUInteger crossfadeGeneration;
@property (nonatomic, assign) BOOL crossfadePreparing;
@property (nonatomic, assign) NSTimeInterval lastScrobbleSamplePosition;
@property (nonatomic, assign) BOOL hasScrobbleSample;
@property (nonatomic, assign) NSTimeInterval scrobblePlayedSeconds;
@property (nonatomic, assign) BOOL geniusAutoplayAllowed;
- (void)refreshQualityLabel;
- (void)setQualityLabelForQuality:(NSUInteger)quality localFile:(BOOL)hasLocalFile;
- (BOOL)shouldFallbackFromAudioError:(NSError *)error;
- (void)fallbackToLowQuality;
- (void)cancelPlaybackStartTimer;
- (void)markPlaybackStartedIfNeeded;
- (void)startPrefetchTimer;
- (void)stopPrefetchTimer;
- (void)submitScrobbleIfEligibleAtTime:(NSTimeInterval)elapsed duration:(NSTimeInterval)duration;
@end
