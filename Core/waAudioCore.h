#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

@class waAudioCore;

@protocol waAudioCoreDelegate <NSObject>
- (void)audioCoreDidFinish:(waAudioCore *)core;
- (void)audioCore:(waAudioCore *)core didFail:(NSError *)error;
- (void)audioCoreDidLoad:(waAudioCore *)core duration:(NSTimeInterval)duration;
@optional
- (void)audioCoreDidPromoteNext:(waAudioCore *)core duration:(NSTimeInterval)duration;
@end

// One AudioQueue. Current and next tracks decode into rings; the output
// callback splices them (gapless) or equal-power mixes them (crossfade).
@interface waAudioCore : NSObject
@property (nonatomic, weak) id<waAudioCoreDelegate> delegate;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) BOOL ready;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) NSTimeInterval position;
@property (nonatomic, readonly) NSTimeInterval outputPosition;
@property (nonatomic, readonly) NSTimeInterval remaining;
@property (nonatomic, readonly) double bitrateKbps;
@property (nonatomic, assign) float volume;
@property (nonatomic, readonly) BOOL endOfStream;
@property (nonatomic, readonly) BOOL nextReady;
@property (nonatomic, readonly) BOOL overlapping;
@property (nonatomic, assign) NSTimeInterval autoOverlap; // 0 = gapless splice at EOS
- (void)openURL:(NSURL *)url;
- (void)prepareNextURL:(NSURL *)url;
- (void)cancelNext;
- (void)beginCrossfade:(NSTimeInterval)duration;
- (BOOL)skipToNextImmediate;
- (void)play;
- (void)pause;
- (void)stop;
- (void)seekTo:(NSTimeInterval)time;
- (void)setGains:(const float *)gains;
- (void)setLimiterEnabled:(BOOL)enabled;
- (void)fadeToVolume:(float)volume duration:(NSTimeInterval)duration completion:(void (^)(void))completion;
@end
