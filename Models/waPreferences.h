#import <Foundation/Foundation.h>

@interface waPreferences : NSObject
+ (waPreferences *)sharedPreferences;
// Optional legacy bridge configuration. Serverless Deezer paths do not use
// these values, and no default bridge endpoint is supplied.
@property (nonatomic, copy) NSString *apiURL;
@property (nonatomic, assign) NSUInteger apiPort;
@property (nonatomic, assign) NSUInteger maximumParallelDownloads;
- (NSUInteger)waMaximumParallelCap;
@property (nonatomic, assign) BOOL crossfadeEnabled;
@property (nonatomic, assign) NSTimeInterval crossfadeDuration;
@property (nonatomic, assign) NSUInteger cacheSizeMB;
@property (nonatomic, copy) NSString *theme;
@property (nonatomic, assign) BOOL cellularDataAllowed;
@property (nonatomic, assign) BOOL privateSession;
@property (nonatomic, assign) NSUInteger downloadQuality;
// Streaming/playback quality, kept separate from downloadQuality.
@property (nonatomic, assign) NSUInteger deezerQuality;
@property (nonatomic, assign) BOOL lastFMScrobblingEnabled;
@property (nonatomic, copy) NSArray *equalizerGains; // 5 NSNumbers (dB)
@property (nonatomic, copy) NSString *equalizerPreset;
@property (nonatomic, assign) BOOL compressorEnabled;
@property (nonatomic, assign) float compressorStrength; // 0..100
@end
