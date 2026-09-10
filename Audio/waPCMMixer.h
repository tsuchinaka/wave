#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "waEqualizer.h"
#import "waCompressor.h"

@class waPCMTrack;

@protocol waPCMMixerDelegate <NSObject>
- (void)pcmMixerDidFinish:(id)mixer;
- (void)pcmMixerDidStall:(id)mixer;
- (void)pcmMixerDidFail:(id)mixer error:(NSError *)error;
@end

@interface waPCMMixer : NSObject {
@private
    AudioQueueRef _audioQueue;
    AudioStreamBasicDescription _outputFormat;
    AudioQueueBufferRef _buffers[4];
    void *_currentScratch;
    void *_pendingScratch;
    UInt32 _bufferFrames;
    waPCMTrack *_activeTrack;
    waPCMTrack *_pendingTrack;
    // Lock-free fade handoff: main publishes a fully-initialized request,
    // render claims it exactly once via CAS. Never touch _pendingTrack /
    // _fadeActive / _fadeTotalFrames from main after publish.
    void * volatile _pendingFadeRequest;
    volatile BOOL _fadeFinishEarly; // main -> render: finish fade early
    dispatch_queue_t _controlQueue; // serializes stop/seek AudioQueue ops
    BOOL _queueStarted;
    BOOL _seekPending;
    NSUInteger _seekGeneration;
    BOOL _playing;
    BOOL _finishRequested;
    BOOL _finishNotificationSent;
    BOOL _stalled;
    BOOL _fadeActive;
    UInt32 _fadeTotalFrames;
    UInt32 _fadePositionFrames;
    waPCMTrack *_logicalTrack;
    NSError *_lastError;
    __unsafe_unretained id<waPCMMixerDelegate> _delegate;
    waEqualizer _eq;
    waCompressor _comp;
}

@property (nonatomic, assign) id<waPCMMixerDelegate> delegate;
@property (nonatomic, readonly) AudioStreamBasicDescription outputFormat;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) BOOL hasLoadedTrack;
@property (nonatomic, readonly) BOOL crossfading;
@property (nonatomic, readonly) NSTimeInterval currentTime;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) double bitrateKbps;
@property (nonatomic, readonly) NSError *lastError;

- (id)init;
- (void)playTrack:(waPCMTrack *)track;
- (void)crossfadeToTrack:(waPCMTrack *)track duration:(NSTimeInterval)duration completion:(void (^)(BOOL started))completion;
- (void)cancelCrossfade;
- (void)pause;
- (void)resume;
- (void)stop;
- (void)seekToTime:(NSTimeInterval)time;
- (void)setEqualizerGains:(const float *)gains; // WA_EQ_BANDS dB values
- (void)equalizerGains:(float *)gains;
- (void)setCompressorEnabled:(BOOL)enabled;
- (void)setCompressorStrength:(float)strength; // 0..100
- (BOOL)compressorEnabled;
- (float)compressorStrength;
@end
