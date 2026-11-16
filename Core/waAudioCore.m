#import "waAudioCore.h"
#import "waCrypto.h"
#import "waAudioProbe.h"
#import "waLog.h"
#import "../../Vendor/OrigamiEngine/ORGMInputUnit.h"
#import <pthread.h>
#import <math.h>

#define WA_RING_FRAMES (44100 * 4)
#define WA_NEXT_FRAMES (44100 * 6)
#define WA_QUEUE_BUFFERS 3
#define WA_QUEUE_FRAMES 2048

typedef struct {
    float *data;
    size_t capacity;   // frames
    size_t write;
    size_t read;
    size_t count;
    pthread_mutex_t lock;
} waRing;

static void waRingInit(waRing *ring, size_t frames) {
    ring->data = (float *)calloc(frames * 2, sizeof(float));
    ring->capacity = frames;
    ring->write = ring->read = ring->count = 0;
    pthread_mutex_init(&ring->lock, NULL);
}

static void waRingFree(waRing *ring) {
    pthread_mutex_destroy(&ring->lock);
    free(ring->data);
    ring->data = NULL;
    ring->capacity = 0;
}

// Interleaved stereo, so a run of frames is one contiguous block. At most two
// spans when the run wraps, never a frame-by-frame copy with a modulo each.
static size_t waRingWrite(waRing *ring, const float *source, size_t frames) {
    pthread_mutex_lock(&ring->lock);
    size_t freeFrames = ring->capacity - ring->count;
    size_t toWrite = MIN(frames, freeFrames);
    if (toWrite) {
        size_t first = MIN(toWrite, ring->capacity - ring->write);
        memcpy(&ring->data[ring->write * 2], source, first * 2 * sizeof(float));
        size_t rest = toWrite - first;
        if (rest) memcpy(&ring->data[0], source + first * 2, rest * 2 * sizeof(float));
        ring->write = (ring->write + toWrite) % ring->capacity;
        ring->count += toWrite;
    }
    pthread_mutex_unlock(&ring->lock);
    return toWrite;
}

static size_t waRingRead(waRing *ring, float *dest, size_t frames) {
    pthread_mutex_lock(&ring->lock);
    size_t toRead = MIN(frames, ring->count);
    if (toRead) {
        size_t first = MIN(toRead, ring->capacity - ring->read);
        memcpy(dest, &ring->data[ring->read * 2], first * 2 * sizeof(float));
        size_t rest = toRead - first;
        if (rest) memcpy(dest + first * 2, &ring->data[0], rest * 2 * sizeof(float));
        ring->read = (ring->read + toRead) % ring->capacity;
        ring->count -= toRead;
    }
    pthread_mutex_unlock(&ring->lock);
    return toRead;
}

static size_t waRingCount(waRing *ring) {
    pthread_mutex_lock(&ring->lock);
    size_t count = ring->count;
    pthread_mutex_unlock(&ring->lock);
    return count;
}

static void waRingClear(waRing *ring) {
    pthread_mutex_lock(&ring->lock);
    ring->read = ring->write = ring->count = 0;
    pthread_mutex_unlock(&ring->lock);
}

// One peaking biquad per band per channel. Ten bands, ISO octave centers.
typedef struct {
    float b0, b1, b2, a1, a2;
    float x1, x2, y1, y2;
} waBiquad;

// Lookahead lets the gain drop before a peak reaches the DAC instead of
// rounding that peak off as it passes. 128 frames is about 3 ms at 44.1 kHz.
#define WA_LIMIT_LOOKAHEAD 128

typedef struct {
    float delay[2][WA_LIMIT_LOOKAHEAD];
    int index;
    float envelope;
    float gain;
} waLimiter;

typedef struct {
    waBiquad bands[WA_EQ_BANDS][2];
    waBiquad highpass[2];
    float gains[WA_EQ_BANDS];
    float preGain;
    float sampleRate;
    BOOL active;
    BOOL limiter;
    waLimiter level;
} waEQState;

@interface waAudioCore () {
    waRing _ring;
    waRing _nextRing;
    waEQState _eq;
    AudioQueueRef _queue;
    AudioQueueBufferRef _buffers[WA_QUEUE_BUFFERS];
    AudioStreamBasicDescription _format;
    ORGMInputUnit *_input;
    ORGMInputUnit *_nextInput;
    dispatch_queue_t _decodeQueue;
    dispatch_queue_t _nextDecodeQueue;
    BOOL _running;
    BOOL _paused;
    BOOL _opened;
    BOOL _finished;
    BOOL _nextOpened;
    BOOL _nextFinished;
    BOOL _overlapping;
    NSTimeInterval _duration;
    NSTimeInterval _nextDuration;
    NSTimeInterval _seekBase;
    double _framesRendered;
    double _nextFramesRendered;
    double _bitrate;
    double _nextBitrate;
    float _volume;
    float _preamp;
    float _fadeFrom;
    float _fadeTo;
    size_t _fadeTotal;
    size_t _fadeDone;
    BOOL _fading;
    BOOL _finishNotified;
    BOOL _pendingPlay;
    BOOL _nextRingReady;
    size_t _overlapTotal;
    size_t _overlapDone;
    NSUInteger _pumpGeneration;
    NSUInteger _nextPumpGeneration;
    BOOL _overlapEligible;
    BOOL _outputStampValid;
    Float64 _outputStampSample;
    NSTimeInterval _outputStampRendered;
    pthread_mutex_t _stateLock;
    pthread_mutex_t _renderLock;
    void *_pumpScratch;
    float *_pumpFloats;
    void *_nextPumpScratch;
    float *_nextPumpFloats;
    float *_crossMix;
    float _crossFromGain, _crossToGain;
    float _crossFromStep, _crossToStep;
}
- (void)renderInto:(AudioQueueBufferRef)buffer;
- (void)maybeFinish;
- (void)startDecoding;
- (void)pumpStep:(NSUInteger)generation;
- (void)pumpNext:(NSUInteger)generation;
- (BOOL)setupWithURL:(NSURL *)url error:(NSError **)error;
- (void)promoteNext;
- (void)promoteNextNotify:(BOOL)notify;
- (void)ensureScratch;
@end

static void waAudioQueueCallback(void *user, AudioQueueRef queue, AudioQueueBufferRef buffer);

@implementation waAudioCore

- (id)init {
    if ((self = [super init])) {
        _decodeQueue = dispatch_queue_create("wave.audio.decode", DISPATCH_QUEUE_SERIAL);
        _nextDecodeQueue = dispatch_queue_create("wave.audio.decode.next", DISPATCH_QUEUE_SERIAL);
        _volume = 1.0f;
        _preamp = 1.0f;
        _fadeFrom = 1.0f;
        _fadeTo = 1.0f;
        _eq.sampleRate = 44100.0f;
        _eq.limiter = YES;
        _eq.preGain = 1.0f;
        pthread_mutex_init(&_stateLock, NULL);
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&_renderLock, &attr);
        pthread_mutexattr_destroy(&attr);
        [self ensureScratch];
        [self rebuildEQ];
    }
    return self;
}

- (void)dealloc {
    [self stop];
    waRingFree(&_ring);
    waRingFree(&_nextRing);
    free(_pumpScratch);
    free(_pumpFloats);
    free(_nextPumpScratch);
    free(_nextPumpFloats);
    free(_crossMix);
#if !OS_OBJECT_USE_OBJC
    if (_decodeQueue) dispatch_release(_decodeQueue);
    if (_nextDecodeQueue) dispatch_release(_nextDecodeQueue);
#endif
    pthread_mutex_destroy(&_stateLock);
    pthread_mutex_destroy(&_renderLock);
}

// One allocation per core, not two per 1024-frame block. 1024 frames of
// 16 bytes covers every container the decoder can hand back.
#define WA_PUMP_BYTES (1024 * 16)
#define WA_PUMP_FLOATS (1024 * 2 * sizeof(float))

- (void)ensureScratch {
    if (!_pumpScratch) _pumpScratch = calloc(1, WA_PUMP_BYTES);
    if (!_pumpFloats) _pumpFloats = (float *)calloc(1, WA_PUMP_FLOATS);
    if (!_nextPumpScratch) _nextPumpScratch = calloc(1, WA_PUMP_BYTES);
    if (!_nextPumpFloats) _nextPumpFloats = (float *)calloc(1, WA_PUMP_FLOATS);
    if (!_crossMix) _crossMix = (float *)calloc(WA_QUEUE_FRAMES * 2, sizeof(float));
}

#pragma mark - public

- (BOOL)playing { return _running && !_paused; }
- (BOOL)ready { return _opened; }
- (BOOL)endOfStream { return _finished && !_nextOpened && waRingCount(&_ring) == 0; }
- (BOOL)nextReady { return _nextOpened && waRingCount(&_nextRing) > 2048; }
- (BOOL)overlapping { return _overlapping; }
- (NSTimeInterval)duration { return _duration; }
- (NSTimeInterval)remaining {
    NSTimeInterval d = _duration;
    if (d <= 0.0) return -1.0;
    return MAX(0.0, d - self.position);
}
- (double)bitrateKbps { return _bitrate; }

- (NSTimeInterval)position {
    double frames = 0;
    pthread_mutex_lock(&_stateLock);
    frames = _framesRendered;
    pthread_mutex_unlock(&_stateLock);
    double sr = _format.mSampleRate > 0 ? _format.mSampleRate : 44100.0;
    return _seekBase + frames / sr;
}

- (NSTimeInterval)outputPosition {
    NSTimeInterval pos = self.position;
    if (!_queue) return pos;
    double sr = _format.mSampleRate > 0 ? _format.mSampleRate : 44100.0;
    AudioTimeStamp stamp;
    memset(&stamp, 0, sizeof(stamp));
    Boolean discontinuity = false;
    OSStatus err = AudioQueueGetCurrentTime(_queue, NULL, &stamp, &discontinuity);
    (void)discontinuity;
    if (err == noErr && (stamp.mFlags & kAudioTimeStampSampleTimeValid)) {
        if (!_outputStampValid) {
            _outputStampSample = stamp.mSampleTime;
            _outputStampRendered = pos;
            _outputStampValid = YES;
        }
        NSTimeInterval heard = _outputStampRendered + (stamp.mSampleTime - _outputStampSample) / sr;
        if (heard < 0.0) heard = 0.0;
        if (pos > 0.0 && heard > pos) heard = pos;
        return heard;
    }
    NSTimeInterval queued = ((NSTimeInterval)(WA_QUEUE_BUFFERS - 1) * (NSTimeInterval)WA_QUEUE_FRAMES) / sr;
    return MAX(0.0, pos - queued - 0.05);
}

- (void)openURL:(NSURL *)url {
    [self cancelNext];
    _opened = NO;
    _finished = NO;
    _finishNotified = NO;
    _paused = NO;
    _pendingPlay = NO;
    _duration = 0;
    _seekBase = 0;
    _framesRendered = 0;
    _outputStampValid = NO;
    pthread_mutex_lock(&_stateLock);
    _running = NO;
    pthread_mutex_unlock(&_stateLock);

    __weak waAudioCore *weakSelf = self;
    dispatch_async(_decodeQueue, ^{
        waAudioCore *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSError *error = nil;
        BOOL ok = [strongSelf setupWithURL:url error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            waAudioCore *core = weakSelf;
            if (!core) return;
            if (!ok) {
                [core failWithMessage:error.localizedDescription ?: @"Could not open stream."];
                return;
            }
            [core startDecoding];
            if ([core.delegate respondsToSelector:@selector(audioCoreDidLoad:duration:)]) {
                [core.delegate audioCoreDidLoad:core duration:core.duration];
            }
        });
    });
}

- (BOOL)setupWithURL:(NSURL *)url error:(NSError **)error {
    _input = [[ORGMInputUnit alloc] init];
    NSError *openError = nil;
    if (![_input openWithUrl:url error:&openError]) {
        [[waLog shared] log:@"decode open failed %@", openError.localizedDescription];
        if (error) *error = openError ?: [NSError errorWithDomain:@"wave.audio" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Could not open stream."}];
        return NO;
    }
    _format = [_input format];
    if (_format.mSampleRate <= 0) _format.mSampleRate = 44100.0;
    if (_format.mChannelsPerFrame == 0) _format.mChannelsPerFrame = 2;
    _duration = _format.mSampleRate > 0 ? [_input framesCount] / _format.mSampleRate : 0.0;
    _bitrate = [_input bitrate] / 1000.0;
    _eq.sampleRate = (float)_format.mSampleRate;
    [self rebuildEQ];

    if (!_ring.data) waRingInit(&_ring, WA_RING_FRAMES);

    AudioStreamBasicDescription out = {0};
    out.mSampleRate = _format.mSampleRate;
    out.mFormatID = kAudioFormatLinearPCM;
    out.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    out.mFramesPerPacket = 1;
    out.mChannelsPerFrame = 2;
    out.mBitsPerChannel = 32;
    out.mBytesPerFrame = 8;
    out.mBytesPerPacket = 8;

    AudioSessionInitialize(NULL, NULL, NULL, NULL);
    UInt32 category = kAudioSessionCategory_MediaPlayback;
    AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(category), &category);
    // Ask the DAC to clock at the source rate so the mixer does not resample.
    // A 44.1 kHz stream on a 48 kHz converter is the usual cause of a dull,
    // slightly harsh top end on this hardware.
    Float64 wanted = _format.mSampleRate;
    Float64 current = 0;
    UInt32 size = sizeof(current);
    AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &current);
    AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareSampleRate, sizeof(wanted), &wanted);
    if (fabs(current - wanted) > 1.0) {
        AudioSessionSetActive(false);
        AudioSessionSetActive(true);
        size = sizeof(current);
        AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &current);
    }
    [[waLog shared] log:@"dac %.0f source %.0f", current, wanted];

    OSStatus status = AudioQueueNewOutput(&out, waAudioQueueCallback, (__bridge void *)self, NULL, NULL, 0, &_queue);
    if (status != noErr) {
        if (error) *error = [NSError errorWithDomain:@"wave.audio" code:(NSInteger)status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AudioQueue %ld", (long)status]}];
        return NO;
    }

    for (int i = 0; i < WA_QUEUE_BUFFERS; i++) {
        AudioQueueAllocateBuffer(_queue, WA_QUEUE_FRAMES * 8, &_buffers[i]);
        _buffers[i]->mAudioDataByteSize = _buffers[i]->mAudioDataBytesCapacity;
        memset(_buffers[i]->mAudioData, 0, _buffers[i]->mAudioDataByteSize);
        AudioQueueEnqueueBuffer(_queue, _buffers[i], 0, NULL);
    }
    AudioQueueSetParameter(_queue, kAudioQueueParam_Volume, 1.0f);
    _opened = YES;
    return YES;
}

- (void)startDecoding {
    pthread_mutex_lock(&_stateLock);
    _running = YES;
    NSUInteger generation = ++_pumpGeneration;
    pthread_mutex_unlock(&_stateLock);
    __weak waAudioCore *weakSelf = self;
    dispatch_async(_decodeQueue, ^{ [weakSelf pumpStep:generation]; });
}

- (void)prepareNextURL:(NSURL *)url {
    if (!url) return;
    pthread_mutex_lock(&_renderLock);
    [self cancelNext];
    NSUInteger generation = ++_nextPumpGeneration;
    pthread_mutex_unlock(&_renderLock);
    __weak waAudioCore *weakSelf = self;
    dispatch_async(_nextDecodeQueue, ^{
        waAudioCore *core = weakSelf;
        if (!core || generation != core->_nextPumpGeneration) return;
        ORGMInputUnit *input = [[ORGMInputUnit alloc] init];
        NSError *error = nil;
        if (![input openWithUrl:url error:&error]) {
            [[waLog shared] log:@"next open failed %@", error.localizedDescription];
            return;
        }
        AudioStreamBasicDescription format = [input format];
        if (format.mSampleRate <= 0) format.mSampleRate = 44100.0;
        if (core->_opened && fabs(format.mSampleRate - core->_format.mSampleRate) > 1.0) {
            [[waLog shared] log:@"next sample rate mismatch, skip prefetch"];
            [input close];
            return;
        }
        pthread_mutex_lock(&core->_renderLock);
        if (generation != core->_nextPumpGeneration) {
            pthread_mutex_unlock(&core->_renderLock);
            [input close];
            return;
        }
        if (!core->_nextRing.data) waRingInit(&core->_nextRing, WA_NEXT_FRAMES);
        else waRingClear(&core->_nextRing);
        core->_nextFramesRendered = 0;
        core->_nextInput = input;
        core->_nextDuration = format.mSampleRate > 0 ? [input framesCount] / format.mSampleRate : 0.0;
        core->_nextBitrate = [input bitrate] / 1000.0;
        core->_nextFinished = NO;
        core->_nextOpened = YES;
        pthread_mutex_unlock(&core->_renderLock);
        [[waLog shared] log:@"next primed dur=%.1f", core->_nextDuration];
        [core pumpNext:generation];
    });
}

- (void)cancelNext {
    pthread_mutex_lock(&_renderLock);
    _nextPumpGeneration++;
    _overlapping = NO;
    _overlapEligible = NO;
    _nextOpened = NO;
    _nextFinished = NO;
    _nextFramesRendered = 0;
    _overlapDone = 0;
    _overlapTotal = 0;
    ORGMInputUnit *input = _nextInput;
    _nextInput = nil;
    if (_nextRing.data) waRingClear(&_nextRing);
    pthread_mutex_unlock(&_renderLock);
    if (input) {
        dispatch_async(_nextDecodeQueue, ^{
            [input close];
        });
    }
}

- (BOOL)skipToNextImmediate {
    pthread_mutex_lock(&_renderLock);
    if (!_nextOpened || waRingCount(&_nextRing) == 0) {
        pthread_mutex_unlock(&_renderLock);
        return NO;
    }
    BOOL wasOverlapping = _overlapping;
    [self promoteNextNotify:NO];
    if (!wasOverlapping) {
        double sr = _format.mSampleRate > 0 ? _format.mSampleRate : 44100.0;
        _fadeFrom = _volume * 0.25f;
        _fadeTo = _volume;
        _fadeTotal = MAX((size_t)256, (size_t)(sr * 0.012));
        _fadeDone = 0;
        _fading = YES;
    }
    pthread_mutex_unlock(&_renderLock);
    return YES;
}

- (void)beginCrossfade:(NSTimeInterval)duration {
    if (!_nextOpened) return;
    double sr = _format.mSampleRate > 0 ? _format.mSampleRate : 44100.0;
    if (duration < 0.02) duration = 0.02;
    _overlapTotal = (size_t)(duration * sr);
    if (_overlapTotal < 512) _overlapTotal = 512;
    _overlapDone = 0;
    _overlapping = YES;
    // Equal-power crossfade as a rotation: one sin/cos per fade, not two per
    // sample. Each frame multiplies the pair by a fixed 2x2 step matrix.
    float step = (float)M_PI * 0.5f / (float)_overlapTotal;
    _crossFromGain = 1.0f;
    _crossToGain = 0.0f;
    _crossFromStep = cosf(step);
    _crossToStep = sinf(step);
    // Called from the audio callback: no formatting, no allocation here.
    dispatch_async(_decodeQueue, ^{ [[waLog shared] log:@"crossfade %.2fs", duration]; });
}

- (void)pumpNext:(NSUInteger)generation {
    if (generation != _nextPumpGeneration || !_nextInput) return;
    const size_t chunkFrames = 1024;
    AudioStreamBasicDescription nf = [_nextInput format];
    size_t bytesPerFrame = nf.mBytesPerFrame;
    if (bytesPerFrame == 0) bytesPerFrame = 4;
    if (bytesPerFrame > 16) bytesPerFrame = 16;
    [self ensureScratch];
    if (waRingCount(&_nextRing) > _nextRing.capacity - chunkFrames) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), _nextDecodeQueue, ^{ [self pumpNext:generation]; });
        return;
    }
    void *scratch = _nextPumpScratch;
    float *floats = _nextPumpFloats;
    int moved = [_nextInput shiftBytes:chunkFrames * bytesPerFrame buffer:scratch];
    if (moved <= 0) {
        if (_nextInput.endOfInput) _nextFinished = YES;
        else {
            [_nextInput process];
            moved = [_nextInput shiftBytes:chunkFrames * bytesPerFrame buffer:scratch];
        }
    }
    if (moved > 0) {
        size_t frames = (size_t)moved / bytesPerFrame;
        [self convertScratch:scratch frames:frames toFloat:floats format:nf.mSampleRate > 0 ? nf : _format];
        size_t written = 0;
        while (written < frames && generation == _nextPumpGeneration) {
            size_t wrote = waRingWrite(&_nextRing, floats + written * 2, frames - written);
            if (!wrote) { [NSThread sleepForTimeInterval:0.02]; continue; }
            written += wrote;
        }
    }
    if (_nextFinished && waRingCount(&_nextRing) == 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.012 * NSEC_PER_SEC)), _nextDecodeQueue, ^{ [self pumpNext:generation]; });
}

- (void)promoteNext {
    [self promoteNextNotify:YES];
}

- (void)promoteNextNotify:(BOOL)notify {
    if (!_nextOpened) return;
    ORGMInputUnit *old = _input;
    pthread_mutex_lock(&_ring.lock);
    pthread_mutex_lock(&_nextRing.lock);
    pthread_mutex_lock(&_stateLock);
    _pumpGeneration++;
    _nextPumpGeneration++;
    _input = _nextInput;
    _nextInput = nil;
    float *data = _ring.data;
    size_t cap = _ring.capacity;
    _ring.data = _nextRing.data;
    _ring.capacity = _nextRing.capacity;
    _ring.write = _nextRing.write;
    _ring.read = _nextRing.read;
    _ring.count = _nextRing.count;
    _nextRing.data = data;
    _nextRing.capacity = cap;
    _nextRing.write = 0;
    _nextRing.read = 0;
    _nextRing.count = 0;
    _duration = _nextDuration;
    _bitrate = _nextBitrate;
    _seekBase = 0;
    _outputStampValid = NO;
    _framesRendered = _nextFramesRendered;
    _nextFramesRendered = 0;
    _finished = _nextFinished;
    _nextOpened = NO;
    _nextFinished = NO;
    _overlapping = NO;
    _overlapEligible = NO;
    _overlapDone = _overlapTotal = 0;
    _finishNotified = NO;
    pthread_mutex_unlock(&_stateLock);
    pthread_mutex_unlock(&_nextRing.lock);
    pthread_mutex_unlock(&_ring.lock);
    NSTimeInterval duration = _duration;
    __weak waAudioCore *weakSelf = self;
    dispatch_async(_decodeQueue, ^{
        [[waLog shared] log:@"promoted next"];
        [old close];
        waAudioCore *core = weakSelf;
        if (core) [core startDecoding];
    });
    if (notify) {
        dispatch_async(dispatch_get_main_queue(), ^{
            waAudioCore *core = weakSelf;
            if (core && [core.delegate respondsToSelector:@selector(audioCoreDidPromoteNext:duration:)]) {
                [core.delegate audioCoreDidPromoteNext:core duration:duration];
            }
        });
    }
}

- (void)pumpStep:(NSUInteger)generation {
    if (!_input) return;
    const size_t chunkFrames = 1024;
    size_t bytesPerFrame = _format.mBytesPerFrame;
    if (bytesPerFrame == 0) bytesPerFrame = 4;
    if (bytesPerFrame > 16) bytesPerFrame = 16;
    [self ensureScratch];

    if (generation != _pumpGeneration) return;

    if (waRingCount(&_ring) > _ring.capacity - chunkFrames) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), _decodeQueue, ^{ [self pumpStep:generation]; });
        return;
    }

    void *scratch = _pumpScratch;
    float *floats = _pumpFloats;
    int moved = [_input shiftBytes:chunkFrames * bytesPerFrame buffer:scratch];
    if (moved <= 0) {
        if (_input.endOfInput) {
            if (!_finished) [[waLog shared] log:@"decode end of stream"];
            _finished = YES;
        } else {
            [_input process];
            moved = [_input shiftBytes:chunkFrames * bytesPerFrame buffer:scratch];
        }
    }
    if (moved > 0) {
        size_t frames = (size_t)moved / bytesPerFrame;
        [self convertScratch:scratch frames:frames toFloat:floats format:_format];
        size_t written = 0;
        while (written < frames && generation == _pumpGeneration && _running) {
            size_t wrote = waRingWrite(&_ring, floats + written * 2, frames - written);
            if (!wrote) { [NSThread sleepForTimeInterval:0.02]; continue; }
            written += wrote;
        }
    }

    if (_finished && waRingCount(&_ring) == 0 && !_nextOpened) {
        pthread_mutex_lock(&_stateLock);
        _running = NO;
        pthread_mutex_unlock(&_stateLock);
        [self maybeFinish];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.012 * NSEC_PER_SEC)), _decodeQueue, ^{ [self pumpStep:generation]; });
}

- (void)convertScratch:(void *)scratch frames:(size_t)frames toFloat:(float *)out format:(AudioStreamBasicDescription)format {
    BOOL isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL isSigned = (format.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    UInt32 channels = format.mChannelsPerFrame ? format.mChannelsPerFrame : 2;
    UInt32 bits = format.mBitsPerChannel ? format.mBitsPerChannel : 16;
    for (size_t i = 0; i < frames; i++) {
        float left = 0.0f, right = 0.0f;
        if (isFloat) {
            const float *src = (const float *)scratch;
            left = src[i * channels];
            right = channels > 1 ? src[i * channels + 1] : left;
        } else if (bits == 16) {
            const int16_t *src = (const int16_t *)scratch;
            left = src[i * channels] / 32768.0f;
            right = channels > 1 ? src[i * channels + 1] / 32768.0f : left;
        } else if (bits == 24) {
            const uint8_t *src = (const uint8_t *)scratch;
            for (int c = 0; c < 2; c++) {
                int channel = MIN((int)channels - 1, c);
                const uint8_t *p = src + (i * channels + channel) * 3;
                int32_t value = (p[0] << 8) | (p[1] << 16) | (p[2] << 24);
                float sample = (float)(value >> 8) / 8388608.0f;
                if (c == 0) left = sample; else right = sample;
            }
            if (channels == 1) right = left;
        } else if (bits == 32 && isSigned) {
            const int32_t *src = (const int32_t *)scratch;
            left = (float)(src[i * channels] / 2147483648.0);
            right = channels > 1 ? (float)(src[i * channels + 1] / 2147483648.0) : left;
        }
        out[i * 2] = left;
        out[i * 2 + 1] = right;
    }
}

- (void)play {
    if (!_queue) { _pendingPlay = YES; return; }
    AudioQueueStart(_queue, NULL);
    _paused = NO;
    if (_finished) {
        [self seekTo:0];
        [self startDecoding];
    }
}

- (void)pause {
    if (!_queue) return;
    AudioQueuePause(_queue);
    _paused = YES;
}

- (void)stop {
    pthread_mutex_lock(&_stateLock);
    _running = NO;
    _pumpGeneration++;
    _nextPumpGeneration++;
    pthread_mutex_unlock(&_stateLock);
    [self cancelNext];
    dispatch_sync(_decodeQueue, ^{});
    dispatch_sync(_nextDecodeQueue, ^{});
    if (_queue) {
        AudioQueueStop(_queue, YES);
        for (int i = 0; i < WA_QUEUE_BUFFERS; i++) if (_buffers[i]) AudioQueueFreeBuffer(_queue, _buffers[i]);
        AudioQueueDispose(_queue, YES);
        _queue = NULL;
        memset(_buffers, 0, sizeof(_buffers));
    }
    [_input close];
    _input = nil;
    _opened = NO;
    _paused = NO;
    _finished = NO;
    _finishNotified = NO;
    _overlapping = NO;
}

- (void)seekTo:(NSTimeInterval)time {
    if (!_input) return;
    pthread_mutex_lock(&_renderLock);
    if (_overlapping) [self cancelNext];
    _overlapEligible = NO;
    _seekBase = MAX(0.0, MIN(time, _duration > 0 ? _duration : time));
    waRingClear(&_ring);
    pthread_mutex_lock(&_stateLock);
    _framesRendered = 0;
    _outputStampValid = NO;
    pthread_mutex_unlock(&_stateLock);
    _finished = NO;
    BOOL restart = !_running;
    pthread_mutex_unlock(&_renderLock);
    __weak waAudioCore *weakSelf = self;
    dispatch_async(_decodeQueue, ^{
        waAudioCore *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_input seek:strongSelf->_seekBase withDataFlush:YES];
        if (restart) [strongSelf startDecoding];
    });
}

- (void)setVolume:(float)volume {
    _volume = MAX(0.0f, MIN(1.0f, volume));
}


#pragma mark - EQ

static const float waEQFrequencies[WA_EQ_BANDS] = {31.0f, 62.0f, 125.0f, 250.0f, 500.0f, 1000.0f, 2000.0f, 4000.0f, 8000.0f, 16000.0f};
static const float waEQQ = 1.41421356f;
static const float waEQCeiling = 0.891250938f;

static void waEQUnity(waEQCoeff *coeff) {
    coeff->b0 = 1.0f; coeff->b1 = 0.0f; coeff->b2 = 0.0f;
    coeff->a1 = 0.0f; coeff->a2 = 0.0f;
}

static void waEQStore(waEQCoeff *coeff, float b0, float b1, float b2, float a0, float a1, float a2) {
    float inv = 1.0f / a0;
    coeff->b0 = b0 * inv; coeff->b1 = b1 * inv; coeff->b2 = b2 * inv;
    coeff->a1 = a1 * inv; coeff->a2 = a2 * inv;
}

static void waEQPeaking(waEQCoeff *coeff, float gainDb, float freq, float sr) {
    float amplitude = powf(10.0f, gainDb / 40.0f);
    float omega = 2.0f * (float)M_PI * freq / sr;
    float alpha = sinf(omega) / (2.0f * waEQQ);
    float cosw = cosf(omega);
    waEQStore(coeff,
              1.0f + alpha * amplitude, -2.0f * cosw, 1.0f - alpha * amplitude,
              1.0f + alpha / amplitude, -2.0f * cosw, 1.0f - alpha / amplitude);
}

static void waEQLowShelf(waEQCoeff *coeff, float gainDb, float freq, float sr) {
    float amplitude = powf(10.0f, gainDb / 40.0f);
    float omega = 2.0f * (float)M_PI * freq / sr;
    float cosw = cosf(omega);
    float boost = 2.0f * sqrtf(amplitude) * sinf(omega) / sqrtf(2.0f);
    float upper = amplitude + 1.0f;
    float lower = amplitude - 1.0f;
    waEQStore(coeff,
              amplitude * (upper - lower * cosw + boost),
              2.0f * amplitude * (lower - upper * cosw),
              amplitude * (upper - lower * cosw - boost),
              upper + lower * cosw + boost,
              -2.0f * (lower + upper * cosw),
              upper + lower * cosw - boost);
}

static void waEQHighShelf(waEQCoeff *coeff, float gainDb, float freq, float sr) {
    float amplitude = powf(10.0f, gainDb / 40.0f);
    float omega = 2.0f * (float)M_PI * freq / sr;
    float cosw = cosf(omega);
    float boost = 2.0f * sqrtf(amplitude) * sinf(omega) / sqrtf(2.0f);
    float upper = amplitude + 1.0f;
    float lower = amplitude - 1.0f;
    waEQStore(coeff,
              amplitude * (upper + lower * cosw + boost),
              -2.0f * amplitude * (lower + upper * cosw),
              amplitude * (upper + lower * cosw - boost),
              upper - lower * cosw + boost,
              2.0f * (lower - upper * cosw),
              upper - lower * cosw - boost);
}

static float waEQCoeffMag(const waEQCoeff *coeff, float omega) {
    float cw = cosf(omega), sw = sinf(omega);
    float c2 = cosf(2.0f * omega), s2 = sinf(2.0f * omega);
    float numRe = coeff->b0 + coeff->b1 * cw + coeff->b2 * c2;
    float numIm = -(coeff->b1 * sw + coeff->b2 * s2);
    float denRe = 1.0f + coeff->a1 * cw + coeff->a2 * c2;
    float denIm = -(coeff->a1 * sw + coeff->a2 * s2);
    float den = denRe * denRe + denIm * denIm;
    if (den < 1.0e-12f) return 1.0f;
    return sqrtf((numRe * numRe + numIm * numIm) / den);
}

float waEQBuild(const float *gains, float sampleRate, waEQCoeff coeffs[WA_EQ_BANDS]) {
    float sr = sampleRate > 0 ? sampleRate : 44100.0f;
    for (int band = 0; band < WA_EQ_BANDS; band++) {
        float freq = waEQFrequencies[band];
        float gain = gains ? gains[band] : 0.0f;
        if (freq >= sr * 0.49f || fabsf(gain) < 0.05f) {
            waEQUnity(&coeffs[band]);
            continue;
        }
        if (band == 0) waEQLowShelf(&coeffs[band], gain, freq, sr);
        else if (band == WA_EQ_BANDS - 1) waEQHighShelf(&coeffs[band], gain, freq, sr);
        else waEQPeaking(&coeffs[band], gain, freq, sr);
    }
    float peak = 1.0f;
    for (int step = 0; step < 64; step++) {
        float freq = 10.0f * powf(2000.0f, step / 63.0f);
        if (freq >= sr * 0.49f) break;
        float omega = 2.0f * (float)M_PI * freq / sr;
        float mag = 1.0f;
        for (int band = 0; band < WA_EQ_BANDS; band++) mag *= waEQCoeffMag(&coeffs[band], omega);
        if (mag > peak) peak = mag;
    }
    // Only a boost is pulled back, and only to -1 dBFS. A flat or cut curve
    // passes at unity so a mastered track still reaches the DAC full scale.
    return peak > 1.0f ? waEQCeiling / peak : 1.0f;
}

float waEQMagnitudeDB(const waEQCoeff *coeffs, float sampleRate, float frequency) {
    float sr = sampleRate > 0 ? sampleRate : 44100.0f;
    if (frequency < 1.0f || frequency >= sr * 0.49f) return 0.0f;
    float omega = 2.0f * (float)M_PI * frequency / sr;
    float mag = 1.0f;
    for (int band = 0; band < WA_EQ_BANDS; band++) mag *= waEQCoeffMag(&coeffs[band], omega);
    return 20.0f * log10f(mag > 1.0e-8f ? mag : 1.0e-8f);
}

// Coefficients only. The filter memory is left untouched so a live gain
// change does not click; a sample-rate change is the one case that must
// drop it, because the old state was computed against a different clock.
static void waHighpass(waBiquad *filter, float freq, float sr) {
    float omega = 2.0f * (float)M_PI * freq / sr;
    float cosw = cosf(omega);
    float alpha = sinf(omega) / (2.0f * 0.70710678f);
    waEQCoeff coeff;
    waEQStore(&coeff,
              (1.0f + cosw) * 0.5f, -(1.0f + cosw), (1.0f + cosw) * 0.5f,
              1.0f + alpha, -2.0f * cosw, 1.0f - alpha);
    filter->b0 = coeff.b0; filter->b1 = coeff.b1; filter->b2 = coeff.b2;
    filter->a1 = coeff.a1; filter->a2 = coeff.a2;
}

- (void)resetLimiter {
    memset(&_eq.level, 0, sizeof(_eq.level));
    _eq.level.gain = 1.0f;
}

- (void)rebuildEQResettingState:(BOOL)resetState {
    waEQCoeff coeffs[WA_EQ_BANDS];
    float sr = _eq.sampleRate > 0 ? _eq.sampleRate : 44100.0f;
    _eq.preGain = waEQBuild(_eq.gains, sr, coeffs);
    float hpfHz = 40.0f;
    if (hpfHz >= sr * 0.2f) hpfHz = sr * 0.2f;
    for (int ch = 0; ch < 2; ch++) {
        waHighpass(&_eq.highpass[ch], hpfHz, sr);
        if (resetState) {
            _eq.highpass[ch].x1 = _eq.highpass[ch].x2 = 0.0f;
            _eq.highpass[ch].y1 = _eq.highpass[ch].y2 = 0.0f;
        }
    }
    if (resetState) [self resetLimiter];
    BOOL active = NO;
    for (int band = 0; band < WA_EQ_BANDS; band++) {
        if (fabsf(_eq.gains[band]) > 0.05f) active = YES;
        for (int ch = 0; ch < 2; ch++) {
            waBiquad *filter = &_eq.bands[band][ch];
            filter->b0 = coeffs[band].b0;
            filter->b1 = coeffs[band].b1;
            filter->b2 = coeffs[band].b2;
            filter->a1 = coeffs[band].a1;
            filter->a2 = coeffs[band].a2;
            if (resetState) filter->x1 = filter->x2 = filter->y1 = filter->y2 = 0.0f;
        }
    }
    _eq.active = active;
}

- (void)rebuildEQ {
    [self rebuildEQResettingState:YES];
}

- (void)setGains:(const float *)gains {
    if (!gains) return;
    for (int i = 0; i < WA_EQ_BANDS; i++) _eq.gains[i] = gains[i];
    [self rebuildEQResettingState:NO];
}

- (void)setPreampDB:(float)db {
    if (db < -12.0f) db = -12.0f;
    if (db > 12.0f) db = 12.0f;
    _preamp = powf(10.0f, db / 20.0f);
}

- (void)setLimiterEnabled:(BOOL)enabled {
    _eq.limiter = enabled;
}

static inline float waProcessBiquad(waBiquad *q, float x) {
    float y = q->b0 * x + q->b1 * q->x1 + q->b2 * q->x2 - q->a1 * q->y1 - q->a2 * q->y2;
    q->x2 = q->x1; q->x1 = x;
    q->y2 = q->y1; q->y1 = y;
    return y;
}

// Exact below full scale, so a hot master is not rounded. Only a sample that
// already exceeds the DAC range is eased back, and it never squares off.
static inline float waSoftCeiling(float x) {
    float ax = fabsf(x);
    if (ax <= 1.0f) return x;
    float shaped = 1.0f + 0.02f * tanhf((ax - 1.0f) / 0.02f);
    return x < 0.0f ? -shaped : shaped;
}

- (void)processBuffer:(float *)samples frames:(size_t)frames {
    for (size_t i = 0; i < frames; i++) {
        float volume = _volume;
        if (_fading && _fadeTotal > 0) {
            float t = (float)_fadeDone / (float)_fadeTotal;
            if (t > 1.0f) t = 1.0f;
            volume = _fadeFrom + (_fadeTo - _fadeFrom) * t;
            _fadeDone++;
            if (_fadeDone >= _fadeTotal) {
                _volume = _fadeTo;
                _fading = NO;
            }
        }
        // Auto makeup stays before the bands so they never see a hot input.
        // The user's Gain belongs after them: before, it just undid the
        // headroom the makeup had bought.
        float left = samples[i * 2] * _eq.preGain;
        float right = samples[i * 2 + 1] * _eq.preGain;
        left = waProcessBiquad(&_eq.highpass[0], left);
        right = waProcessBiquad(&_eq.highpass[1], right);
        if (_eq.active) {
            for (int band = 0; band < WA_EQ_BANDS; band++) {
                left = waProcessBiquad(&_eq.bands[band][0], left);
                right = waProcessBiquad(&_eq.bands[band][1], right);
            }
        }
        left *= _preamp * volume;
        right *= _preamp * volume;

        if (_eq.limiter) {
            waLimiter *lim = &_eq.level;
            float peak = fabsf(left);
            if (fabsf(right) > peak) peak = fabsf(right);
            // Instant attack, ~120 ms release, linked across channels.
            if (peak > lim->envelope) lim->envelope = peak;
            else lim->envelope += (peak - lim->envelope) * 0.00025f;
            float wanted = lim->envelope > waEQCeiling ? waEQCeiling / lim->envelope : 1.0f;
            float step = wanted < lim->gain ? 0.35f : 0.015f;
            lim->gain += (wanted - lim->gain) * step;
            float delayedL = lim->delay[0][lim->index];
            float delayedR = lim->delay[1][lim->index];
            lim->delay[0][lim->index] = left;
            lim->delay[1][lim->index] = right;
            lim->index = (lim->index + 1) % WA_LIMIT_LOOKAHEAD;
            left = waSoftCeiling(delayedL * lim->gain);
            right = waSoftCeiling(delayedR * lim->gain);
        } else {
            // Without the limiter there is no lookahead delay, so the output
            // is still the current sample.
            if (left > 1.0f) left = 1.0f; else if (left < -1.0f) left = -1.0f;
            if (right > 1.0f) right = 1.0f; else if (right < -1.0f) right = -1.0f;
        }
        samples[i * 2] = left;
        samples[i * 2 + 1] = right;
    }
}

- (void)renderInto:(AudioQueueBufferRef)buffer {
    pthread_mutex_lock(&_renderLock);
    size_t frames = buffer->mAudioDataBytesCapacity / 8;
    if (frames > WA_QUEUE_FRAMES) frames = WA_QUEUE_FRAMES;
    float *dest = (float *)buffer->mAudioData;
    double sr = _format.mSampleRate > 0 ? _format.mSampleRate : 44100.0;
    NSTimeInterval rem = self.remaining;
    if (!_overlapping && _nextOpened && !_paused && self.autoOverlap >= 0.5 && _duration >= 12.0 && (_nextDuration <= 0.0 || _nextDuration >= 12.0)) {
        if (rem > self.autoOverlap + 0.25) _overlapEligible = YES;
        size_t needed = (size_t)(MIN(1.5, self.autoOverlap) * sr);
        if (_overlapEligible && (waRingCount(&_nextRing) >= needed || _nextFinished) && rem > 0.05 && rem <= self.autoOverlap) {
            [self beginCrossfade:MAX(0.5, MIN(self.autoOverlap, rem))];
        }
    }
    size_t got = waRingRead(&_ring, dest, frames);
    pthread_mutex_lock(&_stateLock);
    _framesRendered += got;
    pthread_mutex_unlock(&_stateLock);
    if (_overlapping && _nextOpened) {
        float *mix = _crossMix;
        size_t nextGot = waRingRead(&_nextRing, mix, frames);
        _nextFramesRendered += nextGot;
        float from = _crossFromGain, to = _crossToGain;
        float cs = _crossFromStep, sn = _crossToStep;
        for (size_t i = 0; i < frames; i++) {
            float cl = i < got ? dest[i * 2] : 0.0f;
            float cr = i < got ? dest[i * 2 + 1] : 0.0f;
            float nl = i < nextGot ? mix[i * 2] : 0.0f;
            float nr = i < nextGot ? mix[i * 2 + 1] : 0.0f;
            dest[i * 2] = cl * from + nl * to;
            dest[i * 2 + 1] = cr * from + nr * to;
            float nf = from * cs - to * sn;
            to = to * cs + from * sn;
            from = nf;
        }
        _crossFromGain = from;
        _crossToGain = to;
        _overlapDone += frames;
        if (_overlapDone >= _overlapTotal) [self promoteNext];
    } else if (got < frames && _finished && _nextOpened && waRingCount(&_nextRing) > 0) {
        size_t spliced = waRingRead(&_nextRing, dest + got * 2, frames - got);
        _nextFramesRendered += spliced;
        if (got + spliced < frames) {
            memset(dest + (got + spliced) * 2, 0, (frames - got - spliced) * 8);
        }
        if (waRingCount(&_ring) == 0) [self promoteNext];
    } else if (got < frames) {
        memset(dest + got * 2, 0, (frames - got) * 8);
    }
    [self processBuffer:dest frames:frames];
    buffer->mAudioDataByteSize = (UInt32)(frames * 8);
    pthread_mutex_unlock(&_renderLock);
}

- (void)maybeFinish {
    if (!_opened || _finishNotified) return;
    if (_nextOpened || _overlapping) return;
    if (!_finished || waRingCount(&_ring) > 0) return;
    _finishNotified = YES;
    [[waLog shared] log:@"core eos"];
    __weak waAudioCore *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        waAudioCore *core = weakSelf;
        if (core && [core.delegate respondsToSelector:@selector(audioCoreDidFinish:)]) {
            [core.delegate audioCoreDidFinish:core];
        }
    });
}

- (void)failWithMessage:(NSString *)message {
    NSError *error = [NSError errorWithDomain:@"wave.audio" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Playback failed."}];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(audioCore:didFail:)]) [self.delegate audioCore:self didFail:error];
    });
}

@end

static void waAudioQueueCallback(void *user, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    (void)queue;
    waAudioCore *core = (__bridge waAudioCore *)user;
    [core renderInto:buffer];
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    [core maybeFinish];
}
