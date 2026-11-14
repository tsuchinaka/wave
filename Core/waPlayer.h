#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "waModel.h"
#import "waSession.h"

@class waTrack;

typedef enum {
    waRepeatOff = 0,
    waRepeatAll,
    waRepeatOne
} waRepeatMode;

extern NSString * const waPlayerTrackDidChangeNotification;
extern NSString * const waPlayerStateDidChangeNotification;
extern NSString * const waPlayerQueueDidChangeNotification;
extern NSString * const waPlayerProgressNotification;
extern NSString * const waPlayerDidFailNotification;

@interface waPlayer : NSObject
+ (waPlayer *)shared;

@property (nonatomic, readonly) NSArray *queue;
@property (nonatomic, readonly) NSUInteger index;
@property (nonatomic, readonly) waTrack *currentTrack;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) BOOL loading;
@property (nonatomic, readonly) BOOL seekable;
@property (nonatomic, readonly) NSTimeInterval currentTime;
@property (nonatomic, readonly) NSTimeInterval outputTime;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) waQuality activeQuality;
@property (nonatomic, readonly) double bitrateKbps;
@property (nonatomic, readonly) BOOL lossless;
@property (nonatomic, readonly) NSError *lastError;
@property (nonatomic, readonly) NSString *contextName;
@property (nonatomic, readonly) NSString *contextArtworkURL;

@property (nonatomic, assign) waRepeatMode repeatMode;
@property (nonatomic, assign) BOOL shuffleEnabled;
@property (nonatomic, assign) BOOL crossfadeEnabled;
@property (nonatomic, assign) NSTimeInterval crossfadeDuration;
@property (nonatomic, assign) float volume;
- (void)handleRemoteControl:(UIEvent *)event;

- (void)playTracks:(NSArray *)tracks startAt:(NSUInteger)index context:(NSString *)context;
- (void)playTrack:(waTrack *)track;
- (void)appendTracks:(NSArray *)tracks next:(BOOL)next;
- (void)playNext;
- (void)playPrevious;
- (void)pause;
- (void)resume;
- (void)toggle;
- (void)stop;
- (void)seekTo:(NSTimeInterval)time;

- (void)removeAtIndex:(NSUInteger)index;
- (void)moveFrom:(NSUInteger)from to:(NSUInteger)to;
- (void)clearQueue;
- (void)jumpToIndex:(NSUInteger)index;

// 5-band EQ, values in dB (-12..12). Presets are named, no custom UI needed.
- (void)setGain:(float)gain forBand:(NSUInteger)band;
- (float)gainForBand:(NSUInteger)band;
- (NSArray *)equalizerPresets;
- (NSString *)equalizerPresetName;
- (void)applyPresetNamed:(NSString *)name;
- (BOOL)compressorEnabled;
- (void)setCompressorEnabled:(BOOL)enabled;
@end
