#import "waPCMTrack.h"
#import <libkern/OSAtomic.h>
#import <limits.h>
#import <math.h>
#import <unistd.h>
#import "../Vendor/OrigamiEngine/ORGMInputUnit.h"
#import "../Services/waDebugLog.h"

static const UInt32 kwaPCMTrackRingCapacityFrames = 131072; // 512KB @16-bit stereo (was 1MB): 32x the 4096-frame mixer buffer, plenty
static const UInt32 kwaPCMTrackConversionFrames = 4096;
// Keep only one output buffer ready before starting. The source is progressive;
// waiting for a large window here turns a direct pipe into an artificial warmup.
static const UInt32 kwaPCMTrackPrimeFrames = 2048;

@interface waPCMTrack ()
- (void)openAndPump;
- (void)pump;
- (void)schedulePump;
- (void)completePreparationIfPossible;
- (UInt32)provideInputToBufferList:(AudioBufferList *)bufferList packetCount:(UInt32 *)packetCount;
- (UInt32)writeFrames:(UInt32)frames fromBuffer:(const void *)buffer;
- (UInt32)convertFrames:(UInt32)frames;
- (void)setErrorAndStop:(NSError *)error;
@end

static OSStatus waPCMTrackConverterInputProc(AudioConverterRef converter,
                                              UInt32 *packetCount,
                                              AudioBufferList *bufferList,
                                              AudioStreamPacketDescription **packetDescriptions,
                                              void *userData) {
    (void)converter;
    (void)packetDescriptions;
    waPCMTrack *track = (__bridge waPCMTrack *)userData;
    UInt32 provided = [track provideInputToBufferList:bufferList packetCount:packetCount];
    if (provided == 0) {
        *packetCount = 0;
        bufferList->mNumberBuffers = 1;
        bufferList->mBuffers[0].mData = NULL;
        bufferList->mBuffers[0].mDataByteSize = 0;
        bufferList->mBuffers[0].mNumberChannels = 0;
    }
    return noErr;
}

@implementation waPCMTrack

- (id)initWithURL:(NSURL *)url outputFormat:(AudioStreamBasicDescription)outputFormat {
    self = [super init];
    if (self) {
        _url = [url copy];
        _outputFormat = outputFormat;
        _ringCapacityFrames = kwaPCMTrackRingCapacityFrames;
        _convertedBufferFrames = kwaPCMTrackConversionFrames;
        _ringBuffer = malloc((size_t)_ringCapacityFrames * _outputFormat.mBytesPerFrame);
        _inputBuffer = malloc(CHUNK_SIZE * 8);
        _convertedBuffer = malloc((size_t)_convertedBufferFrames * _outputFormat.mBytesPerFrame);
        _decodeQueue = dispatch_queue_create("com.bytebox.wave.pcm.decode", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    _stopped = YES;
    [_inputUnit cancel];
    if (_converter) AudioConverterDispose(_converter);
    free(_inputBuffer);
    free(_convertedBuffer);
    free(_ringBuffer);
}

- (NSURL *)url { return _url; }
- (AudioStreamBasicDescription)outputFormat { return _outputFormat; }
- (BOOL)prepared { return _prepared; }
- (BOOL)endOfStream { return _endOfStream; }
- (NSTimeInterval)duration { return _duration; }
- (double)bitrateKbps { return _bitrateKbps; }
- (NSError *)error { return _error; }

- (void)prepareWithCompletion:(void (^)(BOOL success, NSError *error))completion {
    _prepareCompletion = [completion copy];
    dispatch_async(_decodeQueue, ^{ @autoreleasepool { [self openAndPump]; } });
}

- (void)openAndPump {
    if (_stopped) return;

    ORGMInputUnit *input = [[ORGMInputUnit alloc] init];
    _inputUnit = input;
    NSError *inputError = nil;
    if (![input openWithUrl:_url error:&inputError]) {
        NSString *underlyingReason = [inputError localizedDescription];
        if (!underlyingReason) underlyingReason = @"The audio decoder could not open the source.";
        NSString *reason = [NSString stringWithFormat:@"%@ (%@)", @"The audio decoder could not open the source.", underlyingReason];
        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:reason forKey:NSLocalizedDescriptionKey];
        if (inputError) [info setObject:inputError forKey:NSUnderlyingErrorKey];
        [self setErrorAndStop:[NSError errorWithDomain:@"com.bytebox.wave.audio"
                                                  code:-10
                                              userInfo:info]];
        NSString *scheme = _url.scheme;
        if (!scheme) scheme = @"(null)";
        NSString *ext = _url.path.pathExtension;
        if (!ext) ext = @"";
        NSString *urlString = _url.absoluteString;
        if (!urlString) urlString = @"(null)";
        NSString *underlyingDesc = inputError ? (NSString *)[inputError description] : @"(none)";
        [[waDebugLog sharedLog] log:@"PCM open failed scheme=%@ ext=%@ url=%@ underlying=%@",
         scheme, ext, urlString, underlyingDesc];
        [self completePreparationIfPossible];
        return;
    }

    AudioStreamBasicDescription inputFormat = [input format];
    _inputBytesPerFrame = inputFormat.mBytesPerFrame;
    BOOL validSampleRate = isfinite(inputFormat.mSampleRate) && inputFormat.mSampleRate > 0.0;
    BOOL validBits = inputFormat.mBitsPerChannel >= 8 &&
                     inputFormat.mBitsPerChannel <= 32 &&
                     (inputFormat.mBitsPerChannel % 8) == 0;
    BOOL validChannels = inputFormat.mChannelsPerFrame >= 1 &&
                         inputFormat.mChannelsPerFrame <= 2;
    if (_inputBytesPerFrame == 0 || !validSampleRate || !validBits || !validChannels) {
        [[waDebugLog sharedLog] log:@"Invalid PCM format for %@: id=%u flags=0x%lx rate=%.2f channels=%u bits=%u bytes/frame=%u frames/packet=%u",
         _url.absoluteString ?: @"(null)", (unsigned int)inputFormat.mFormatID,
         (unsigned long)inputFormat.mFormatFlags, inputFormat.mSampleRate,
         (unsigned int)inputFormat.mChannelsPerFrame, (unsigned int)inputFormat.mBitsPerChannel,
         (unsigned int)inputFormat.mBytesPerFrame, (unsigned int)inputFormat.mFramesPerPacket];
        [self setErrorAndStop:[NSError errorWithDomain:@"com.bytebox.wave.audio"
                                                   code:-11
                                               userInfo:@{NSLocalizedDescriptionKey: @"The decoder returned an invalid PCM format."}]];
        [input close];
        _inputUnit = nil;
        [self completePreparationIfPossible];
        return;
    }

    OSStatus status = AudioConverterNew(&inputFormat, &_outputFormat, &_converter);
    if (status != noErr) {
        NSString *reason = [NSString stringWithFormat:@"AudioConverterNew failed (%ld).", (long)status];
        [self setErrorAndStop:[NSError errorWithDomain:@"com.bytebox.wave.audio"
                                                   code:-12
                                               userInfo:@{NSLocalizedDescriptionKey: reason}]];
        [input close];
        _inputUnit = nil;
        [self completePreparationIfPossible];
        return;
    }

    // Fast path: decoder output already matches the mixer (the common MP3
    // 44.1kHz/16-bit/stereo case). Skip AudioConverterFillComplexBuffer per
    // 4K chunk — a big win on A4 — and memcpy straight into the ring.
    _converterPassthrough = (inputFormat.mFormatID == _outputFormat.mFormatID &&
                             inputFormat.mFormatFlags == _outputFormat.mFormatFlags &&
                             inputFormat.mSampleRate == _outputFormat.mSampleRate &&
                             inputFormat.mChannelsPerFrame == _outputFormat.mChannelsPerFrame &&
                             inputFormat.mBitsPerChannel == _outputFormat.mBitsPerChannel &&
                             inputFormat.mBytesPerFrame == _outputFormat.mBytesPerFrame &&
                             inputFormat.mFramesPerPacket == _outputFormat.mFramesPerPacket &&
                             _inputBytesPerFrame == _outputFormat.mBytesPerFrame);
    if (inputFormat.mChannelsPerFrame == 1 && _outputFormat.mChannelsPerFrame == 2) {
        SInt32 channelMap[2] = { 0, 0 };
        status = AudioConverterSetProperty(_converter, kAudioConverterChannelMap, sizeof(channelMap), channelMap);
        if (status != noErr) {
            NSString *reason = [NSString stringWithFormat:@"AudioConverterSetProperty channel map failed (%ld).", (long)status];
            [self setErrorAndStop:[NSError errorWithDomain:@"com.bytebox.wave.audio"
                                                       code:-13
                                                   userInfo:@{NSLocalizedDescriptionKey: reason}]];
            [input close];
            _inputUnit = nil;
            [self completePreparationIfPossible];
            return;
        }
    }

    double frames = [input framesCount];
    if (frames > 0.0) _duration = frames / inputFormat.mSampleRate;
    double bitrate = [input bitrate];
    if (bitrate > 0.0 && isfinite(bitrate)) _bitrateKbps = bitrate / 1000.0;
    _prepared = YES;
    [self pump];
}

- (void)pump {
    if (_stopped || !_prepared || _endOfStream) return;

    for (NSUInteger iteration = 0; iteration < 8 && !_stopped; iteration++) {
        @autoreleasepool {
        UInt32 available = [self availableFrames];
        if (available >= _ringCapacityFrames - _convertedBufferFrames) break;

        [_inputUnit process];
        UInt32 converted = [self convertFrames:_convertedBufferFrames];
        if (converted > 0) {
            [self writeFrames:converted fromBuffer:_convertedBuffer];
            continue;
        }

        if ([_inputUnit endOfInput]) {
            _endOfStream = YES;
            break;
        }
        break;
        }
    }

    [self completePreparationIfPossible];
    [self schedulePump];
}

- (void)schedulePump {
    if (_stopped || _endOfStream || _pumpScheduled) return;
    _pumpScheduled = YES;
    // Polling cadence: 10 ms while the ring is filling (preparation, stalls).
    // Once the ring is full the mixer drains one 4096-frame buffer per ~93 ms,
    // so back off to 60 ms instead of waking ~100x/s to do nothing (battery
    // and scheduler churn on single-core devices).
    UInt32 available = [self availableFrames];
    NSTimeInterval delay = available >= _ringCapacityFrames - _convertedBufferFrames ? 0.06 : 0.01;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _decodeQueue, ^{
        self->_pumpScheduled = NO;
        @autoreleasepool { [self pump]; }
    });
}

- (void)completePreparationIfPossible {
    if (_prepareCompletionSent || !_prepareCompletion) return;
    if (!_prepared && !_error) return;
    if (_prepared && [self availableFrames] < kwaPCMTrackPrimeFrames && !_endOfStream) return;

    _prepareCompletionSent = YES;
    void (^completion)(BOOL, NSError *) = _prepareCompletion;
    _prepareCompletion = nil;
    BOOL success = !_stopped && !_error;
    NSError *error = _error;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(success, error); });
}

- (UInt32)provideInputToBufferList:(AudioBufferList *)bufferList packetCount:(UInt32 *)packetCount {
    if (!_inputUnit || !_inputBytesPerFrame || !packetCount) return 0;
    UInt32 requestedBytes = (*packetCount) * _inputBytesPerFrame;
    UInt32 maxBytes = CHUNK_SIZE * 8;
    if (requestedBytes > maxBytes) requestedBytes = maxBytes;
    requestedBytes -= requestedBytes % _inputBytesPerFrame;
    if (!requestedBytes) return 0;

    int bytes = [_inputUnit shiftBytes:requestedBytes buffer:_inputBuffer];
    if (bytes <= 0) return 0;
    bytes -= bytes % _inputBytesPerFrame;
    bufferList->mNumberBuffers = 1;
    bufferList->mBuffers[0].mData = _inputBuffer;
    bufferList->mBuffers[0].mDataByteSize = (UInt32)bytes;
    AudioStreamBasicDescription inputFormat = [_inputUnit format];
    bufferList->mBuffers[0].mNumberChannels = inputFormat.mChannelsPerFrame;
    *packetCount = (UInt32)bytes / _inputBytesPerFrame;
    return *packetCount;
}

- (UInt32)convertFrames:(UInt32)frames {
    if (!frames) return 0;
    if (_converterPassthrough) {
        if (frames > _convertedBufferFrames) frames = _convertedBufferFrames;
        UInt32 wanted = frames * _outputFormat.mBytesPerFrame;
        int got = [_inputUnit shiftBytes:wanted buffer:_convertedBuffer];
        if (got <= 0) return 0;
        got -= got % _outputFormat.mBytesPerFrame;
        return (UInt32)got / _outputFormat.mBytesPerFrame;
    }
    if (!_converter) return 0;
    if (frames > _convertedBufferFrames) frames = _convertedBufferFrames;

    AudioBufferList output;
    output.mNumberBuffers = 1;
    output.mBuffers[0].mData = _convertedBuffer;
    output.mBuffers[0].mDataByteSize = frames * _outputFormat.mBytesPerFrame;
    output.mBuffers[0].mNumberChannels = _outputFormat.mChannelsPerFrame;
    UInt32 outputFrames = frames;
    OSStatus status = AudioConverterFillComplexBuffer(_converter,
                                                       waPCMTrackConverterInputProc,
                                                       (__bridge void *)self,
                                                       &outputFrames,
                                                       &output,
                                                       NULL);
    if (status != noErr && outputFrames == 0) {
        NSString *reason = [NSString stringWithFormat:@"AudioConverterFillComplexBuffer failed (%ld).", (long)status];
        [self setErrorAndStop:[NSError errorWithDomain:@"com.bytebox.wave.audio"
                                                   code:-14
                                               userInfo:@{NSLocalizedDescriptionKey: reason}]];
        return 0;
    }
    return outputFrames;
}

- (UInt32)availableFrames {
    OSMemoryBarrier();
    return _ringWriteIndex - _ringReadIndex;
}

- (UInt32)writeFrames:(UInt32)frames fromBuffer:(const void *)buffer {
    if (!frames) return 0;
    UInt32 available = [self availableFrames];
    UInt32 freeFrames = _ringCapacityFrames - available;
    if (frames > freeFrames) frames = freeFrames;
    UInt32 first = MIN(frames, _ringCapacityFrames - (_ringWriteIndex % _ringCapacityFrames));
    UInt32 second = frames - first;
    UInt32 bytesPerFrame = _outputFormat.mBytesPerFrame;
    memcpy(_ringBuffer + (_ringWriteIndex % _ringCapacityFrames) * bytesPerFrame, buffer, first * bytesPerFrame);
    if (second) memcpy(_ringBuffer, (const unsigned char *)buffer + first * bytesPerFrame, second * bytesPerFrame);
    OSMemoryBarrier();
    _ringWriteIndex += frames;
    return frames;
}

- (UInt32)readFrames:(UInt32)frames intoBuffer:(void *)buffer {
    if (!frames || !buffer) return 0;
    OSMemoryBarrier();
    UInt32 available = _ringWriteIndex - _ringReadIndex;
    if (frames > available) frames = available;
    UInt32 first = MIN(frames, _ringCapacityFrames - (_ringReadIndex % _ringCapacityFrames));
    UInt32 second = frames - first;
    UInt32 bytesPerFrame = _outputFormat.mBytesPerFrame;
    memcpy(buffer, _ringBuffer + (_ringReadIndex % _ringCapacityFrames) * bytesPerFrame, first * bytesPerFrame);
    if (second) memcpy((unsigned char *)buffer + first * bytesPerFrame, _ringBuffer, second * bytesPerFrame);
    OSMemoryBarrier();
    _ringReadIndex += frames;
    _consumedFrames += frames;
    return frames;
}

- (NSTimeInterval)currentTime {
    if (_outputFormat.mSampleRate <= 0.0) return 0.0;
    return ((double)_consumedFrames / _outputFormat.mSampleRate);
}

- (void)seekToTime:(NSTimeInterval)time {
    [self seekToTime:time completion:nil];
}

- (void)seekToTime:(NSTimeInterval)time completion:(void (^)(void))completion {
    if (!isfinite(time) || time < 0.0) return;
    // Generation-guarded async seek: stale seeks are ignored, never blocks.
    int32_t generation = OSAtomicIncrement32Barrier((int32_t *)&_seekGeneration);
    void (^completionCopy)(void) = [completion copy];
    dispatch_async(_decodeQueue, ^{
        OSMemoryBarrier();
        if (generation != self->_seekGeneration) return;
        if (self->_inputUnit) {
            [self->_inputUnit seek:time withDataFlush:YES];
            if (self->_converter) AudioConverterReset(self->_converter);
            self->_ringReadIndex = 0;
            self->_ringWriteIndex = 0;
            self->_consumedFrames = (UInt32)MIN((double)UINT_MAX, time * self->_outputFormat.mSampleRate);
            self->_endOfStream = NO;
            [self pump];
        }
        OSMemoryBarrier();
        if (generation != self->_seekGeneration) return;
        if (completionCopy) dispatch_async(dispatch_get_main_queue(), ^{
            OSMemoryBarrier();
            if (generation == self->_seekGeneration) completionCopy();
        });
    });
}

- (void)setErrorAndStop:(NSError *)error {
    if (!_error) _error = error;
    _stopped = YES;
}

- (void)stop {
    _stopped = YES;
    if (_inputUnit) {
        [_inputUnit cancel];
        dispatch_async(_decodeQueue, ^{
            [self->_inputUnit close];
            self->_inputUnit = nil;
        });
    }
}

@end
