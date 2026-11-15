#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

// Octave bands, 31 Hz to 16 kHz. setGains: reads exactly this many floats.
#define WA_EQ_BANDS 10

// One band of the graphic EQ, without filter memory. Band 0 is a low shelf,
// band 9 a high shelf, the rest peaking. waEQBuild returns the linear
// pre-gain that holds the combined peak at -1 dBFS.
typedef struct {
    float b0, b1, b2, a1, a2;
} waEQCoeff;

float waEQBuild(const float *gains, float sampleRate, waEQCoeff coeffs[WA_EQ_BANDS]);
float waEQMagnitudeDB(const waEQCoeff *coeffs, float sampleRate, float frequency);

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
@end
