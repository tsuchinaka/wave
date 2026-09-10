#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
@class UIImage;

extern NSString * const waAudioEngineStateDidChangeNotification;
extern NSString * const waAudioEngineDidFailNotification;
extern NSString * const waAudioEngineDidFinishNotification;
extern NSString * const waAudioEngineCrossfadeCancelledNotification;
extern NSString * const waAudioEngineSeekNotification;
extern NSString * const waAudioEngineDidStallNotification;
@protocol waAudioQueueContract <NSObject>
- (void)enqueueURL:(NSURL *)url;
- (void)removeAllQueuedItems;
@end
@protocol waAudioMixerContract <NSObject>
@property (nonatomic, assign) BOOL crossfadeEnabled;
@property (nonatomic, assign) NSTimeInterval crossfadeDuration;
@end
@interface waAudioEngine : NSObject <waAudioQueueContract, waAudioMixerContract>
+ (waAudioEngine *)sharedEngine;
- (void)playURL:(NSURL *)url;
- (void)crossfadeToURL:(NSURL *)url duration:(NSTimeInterval)duration completion:(void (^)(BOOL started))completion;
- (void)cancelPendingCrossfade;
- (void)cancelCrossfade;
- (void)pause;
- (void)resume;
- (void)stop;
- (void)togglePlayPause;
- (void)seekToTime:(NSTimeInterval)time;
- (void)setEqualizerGains:(const float *)gains; // 5 dB values, see waEqualizer.h
- (void)equalizerGains:(float *)gains;
- (void)setCompressorEnabled:(BOOL)enabled;
- (void)setCompressorStrength:(float)strength; // 0..100
- (BOOL)compressorEnabled;
- (float)compressorStrength;
- (BOOL)isPlaying;
- (BOOL)hasLoadedPlaybackItem;
- (NSTimeInterval)currentTime;
- (NSTimeInterval)duration;
@property (nonatomic, readonly) double bitrateKbps;
- (void)updateNowPlaying:(NSString *)title artist:(NSString *)artist duration:(NSTimeInterval)duration;
- (void)updateNowPlaying:(NSString *)title artist:(NSString *)artist duration:(NSTimeInterval)duration artwork:(UIImage *)artwork;
- (void)updateNowPlayingAlbum:(NSString *)album;
- (void)updateNowPlayingPlaybackState;
- (void)remoteControlReceivedWithEvent:(UIEvent *)event;
@property (nonatomic, strong, readonly) NSError *lastError;
@end
