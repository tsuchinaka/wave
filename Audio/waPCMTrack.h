#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <libkern/OSAtomic.h>

@class ORGMInputUnit;

@interface waPCMTrack : NSObject {
@private
    NSURL *_url;
    AudioStreamBasicDescription _outputFormat;
    ORGMInputUnit *_inputUnit;
    AudioConverterRef _converter;
    void *_inputBuffer;
    void *_convertedBuffer;
    unsigned char *_ringBuffer;
    UInt32 _ringCapacityFrames;
    volatile UInt32 _ringReadIndex;
    volatile UInt32 _ringWriteIndex;
    volatile UInt32 _consumedFrames;
    volatile BOOL _stopped;
    volatile BOOL _endOfStream;
    BOOL _prepared;
    BOOL _prepareCompletionSent;
    BOOL _pumpScheduled;
    UInt32 _inputBytesPerFrame;
    UInt32 _convertedBufferFrames;
    BOOL _converterPassthrough; // input already 16-bit stereo @ output rate: memcpy, no AudioConverter
    NSTimeInterval _duration;
    double _bitrateKbps;
    NSError *_error;
    dispatch_queue_t _decodeQueue;
    void (^_prepareCompletion)(BOOL success, NSError *error);
    volatile int32_t _seekGeneration;
}

@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly) AudioStreamBasicDescription outputFormat;
@property (nonatomic, readonly) BOOL prepared;
@property (nonatomic, readonly) BOOL endOfStream;
@property (nonatomic, readonly) NSTimeInterval duration;
@property (nonatomic, readonly) double bitrateKbps;
@property (nonatomic, readonly) NSTimeInterval currentTime;
@property (nonatomic, readonly) NSError *error;

- (id)initWithURL:(NSURL *)url outputFormat:(AudioStreamBasicDescription)outputFormat;
- (void)prepareWithCompletion:(void (^)(BOOL success, NSError *error))completion;
- (UInt32)readFrames:(UInt32)frames intoBuffer:(void *)buffer;
- (UInt32)availableFrames;
- (void)seekToTime:(NSTimeInterval)time;
- (void)seekToTime:(NSTimeInterval)time completion:(void (^)(void))completion;
- (void)stop;
@end
