#import "waPCMMixer.h"
#import <AVFoundation/AVFoundation.h>
#import <libkern/OSAtomic.h>
#import <math.h>
#import "waPCMTrack.h"
#import "waEqualizer.h"
#import "waCompressor.h"
#import "../Services/waDebugLog.h"

// 4 buffers x 4096 frames (~372ms @44.1k stereo int16) resists underruns.
static const UInt32 kwaPCMMixerBufferCount = 4;
static const UInt32 kwaPCMMixerBufferFrames = 4096;

// Immutable fade request published by main, claimed once by render.
// retainedTrack is a CFBridgingRetain'd waPCMTrack*.
typedef struct {
    void *retainedTrack;
    UInt32 totalFrames;
} waPendingFadeRequest;

static void waPendingFadeRelease(void *ptr) {
    if (!ptr) return;
    waPendingFadeRequest *req = (waPendingFadeRequest *)ptr;
    if (req->retainedTrack) CFRelease(req->retainedTrack);
    free(req);
}

@interface waPCMMixer ()
- (void)renderBuffer:(AudioQueueBufferRef)buffer;
- (void)renderBufferWithoutQueueing:(AudioQueueBufferRef)buffer;
- (void)finishOnMainThread;
- (void)notifyStallOnMainThread;
- (void)notifyFailureOnMainThread:(NSError *)error;
- (BOOL)enqueueInitialBuffers;
- (void)stopOnControlQueue;
- (void)seekOnControlQueue:(NSTimeInterval)time;
- (BOOL)claimFadeRequestIntoTrack:(waPCMTrack **)outTrack totalFrames:(UInt32 *)outTotal;
- (waPCMTrack *)takeUnclaimedFadeRequestWithTotal:(UInt32 *)outTotal;
@end

static void waPCMMixerOutputCallback(void *userData, AudioQueueRef audioQueue, AudioQueueBufferRef buffer) {
    (void)audioQueue;
    waPCMMixer *mixer = (__bridge waPCMMixer *)userData;
    [mixer renderBuffer:buffer];
}

@implementation waPCMMixer

- (id)init {
    self = [super init];
    if (self) {
        _controlQueue = dispatch_queue_create("com.bytebox.wave.mixer.control", DISPATCH_QUEUE_SERIAL);
        _pendingFadeRequest = NULL;
        _fadeFinishEarly = NO;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        double sampleRate = session.sampleRate;
        if (sampleRate <= 0.0) sampleRate = 44100.0;
        _outputFormat.mFormatID = kAudioFormatLinearPCM;
        _outputFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
        _outputFormat.mSampleRate = sampleRate;
        _outputFormat.mChannelsPerFrame = 2;
        _outputFormat.mBitsPerChannel = 16;
        _outputFormat.mFramesPerPacket = 1;
        _outputFormat.mBytesPerFrame = 4;
        _outputFormat.mBytesPerPacket = 4;

        _bufferFrames = kwaPCMMixerBufferFrames;
        waEQInit(&_eq, _outputFormat.mSampleRate);
        waCompInit(&_comp, _outputFormat.mSampleRate);
        _currentScratch = malloc((size_t)_bufferFrames * _outputFormat.mBytesPerFrame);
        _pendingScratch = malloc((size_t)_bufferFrames * _outputFormat.mBytesPerFrame);
        OSStatus status = AudioQueueNewOutput(&_outputFormat,
                                               waPCMMixerOutputCallback,
                                               (__bridge void *)self,
                                               NULL,
                                               NULL,
                                               0,
                                               &_audioQueue);
        if (status == noErr) {
            for (UInt32 index = 0; index < kwaPCMMixerBufferCount; index++) {
                status = AudioQueueAllocateBuffer(_audioQueue,
                                                  _bufferFrames * _outputFormat.mBytesPerFrame,
                                                  &_buffers[index]);
                if (status != noErr) break;
            }
        }
        if (status != noErr) {
            _lastError = [NSError errorWithDomain:@"com.bytebox.wave.audio"
                                             code:-20
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AudioQueue setup failed (%ld).", (long)status]}];
        }
    }
    return self;
}

- (void)dealloc {
    // Synchronous teardown: never dispatch_async from dealloc (self is dying).
    void *pending = _pendingFadeRequest;
    _pendingFadeRequest = NULL;
    waPendingFadeRelease(pending);
    if (_audioQueue) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueDispose(_audioQueue, true);
        _audioQueue = NULL;
    }
    free(_currentScratch);
    free(_pendingScratch);
}

- (AudioStreamBasicDescription)outputFormat { return _outputFormat; }
- (BOOL)playing { return _playing; }
- (BOOL)hasLoadedTrack { return _activeTrack != nil; }
- (BOOL)crossfading { return _fadeActive; }
- (NSTimeInterval)currentTime { return _logicalTrack ? _logicalTrack.currentTime : 0.0; }
- (NSTimeInterval)duration { return _logicalTrack ? _logicalTrack.duration : 0.0; }
- (double)bitrateKbps { return _logicalTrack ? _logicalTrack.bitrateKbps : 0.0; }
- (NSError *)lastError { return _lastError; }

- (void)playTrack:(waPCMTrack *)track {
    if (!track || !_audioQueue) return;
    // Flush pending async stop/seek work so the synchronous start below
    // cannot race with it. All public enqueues originate on main, so after
    // this barrier the control queue is idle.
    if (_controlQueue) dispatch_sync(_controlQueue, ^{ });
    [self stopOnControlQueue];
    if (_lastError) {
        [self notifyFailureOnMainThread:_lastError];
        return;
    }
    _activeTrack = track;
    _logicalTrack = track;
    _finishRequested = NO;
    _finishNotificationSent = NO;
    _stalled = NO;
    waEQReset(&_eq);
    waCompReset(&_comp);
    AudioQueueReset(_audioQueue);
    if (![self enqueueInitialBuffers]) return;
    // Mark the queue active before starting it. AudioQueue may invoke the
    // callback immediately from AudioQueueStart on older iOS releases.
    _queueStarted = YES;
    _playing = YES;
    OSStatus status = AudioQueueStart(_audioQueue, NULL);
    if (status != noErr) {
        _queueStarted = NO;
        _playing = NO;
        [self notifyFailureOnMainThread:[NSError errorWithDomain:@"com.bytebox.wave.audio"
                                                               code:-21
                                                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AudioQueueStart failed (%ld).", (long)status]}]];
        return;
    }
}

- (BOOL)enqueueInitialBuffers {
    if (!_audioQueue || !_activeTrack) return NO;
    // Prime at least 2 of the 4x4096 buffers (~372ms) to resist underruns.
    // Local files normally have all four ready; a live HTTP pipe starts with
    // the decoded window and lets callbacks refill without full prewarm.
    UInt32 available = [_activeTrack availableFrames];
    UInt32 bufferCount = available / _bufferFrames;
    bufferCount = MIN(kwaPCMMixerBufferCount, MAX(2, bufferCount));
    for (UInt32 index = 0; index < bufferCount; index++) {
        [self renderBufferWithoutQueueing:_buffers[index]];
        OSStatus status = AudioQueueEnqueueBuffer(_audioQueue, _buffers[index], 0, NULL);
        if (status != noErr) {
            [self notifyFailureOnMainThread:[NSError errorWithDomain:@"com.bytebox.wave.audio"
                                                                  code:-22
                                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AudioQueueEnqueueBuffer failed (%ld).", (long)status]}]];
            return NO;
        }
    }
    return YES;
}

- (void)renderBufferWithoutQueueing:(AudioQueueBufferRef)buffer {
    UInt32 frames = buffer->mAudioDataBytesCapacity / _outputFormat.mBytesPerFrame;
    memset(buffer->mAudioData, 0, buffer->mAudioDataBytesCapacity);
    buffer->mAudioDataByteSize = frames * _outputFormat.mBytesPerFrame;
    if (!_activeTrack) return;

    // Adopt any published fade request exactly once (lock-free handoff).
    // Main publishes via atomic store; render claims via CAS and owns it.
    if (!_fadeActive) {
        waPCMTrack *claimed = nil;
        UInt32 total = 0;
        if ([self claimFadeRequestIntoTrack:&claimed totalFrames:&total]) {
            if (claimed && total > 0) {
                _pendingTrack = claimed;
                _fadeTotalFrames = total;
                _fadePositionFrames = 0;
                _fadeActive = YES;
            }
        }
    } else if (_fadeFinishEarly) {
        // Main requested early finish (cancel). Never blocks.
        OSMemoryBarrier();
        if (_fadeFinishEarly) _fadePositionFrames = _fadeTotalFrames;
    }

    UInt32 activeRead = [_activeTrack readFrames:frames intoBuffer:_currentScratch];
    if (!_fadeActive || !_pendingTrack) {
        memcpy(buffer->mAudioData, _currentScratch, activeRead * _outputFormat.mBytesPerFrame);
        waEQProcess(&_eq, (SInt16 *)buffer->mAudioData, frames);
        waCompProcess(&_comp, (SInt16 *)buffer->mAudioData, frames);
        if (activeRead == 0 && _activeTrack.endOfStream && _activeTrack.availableFrames == 0) {
            _finishRequested = YES;
        } else if (activeRead == 0) {
            [self notifyStallOnMainThread];
        }
        return;
    }

    UInt32 pendingRead = [_pendingTrack readFrames:frames intoBuffer:_pendingScratch];
    SInt16 *destination = (SInt16 *)buffer->mAudioData;
    SInt16 *oldSamples = (SInt16 *)_currentScratch;
    SInt16 *newSamples = (SInt16 *)_pendingScratch;
    for (UInt32 frame = 0; frame < frames; frame++) {
        float progress = _fadeTotalFrames ? (float)(_fadePositionFrames + frame) / (float)_fadeTotalFrames : 1.0f;
        if (progress > 1.0f) progress = 1.0f;
        float oldGain = 1.0f - progress;
        float newGain = progress;
        if (frame < activeRead || frame < pendingRead) {
            SInt32 left = (SInt32)((frame < activeRead ? oldSamples[frame * 2] : 0) * oldGain) +
                          (SInt32)((frame < pendingRead ? newSamples[frame * 2] : 0) * newGain);
            SInt32 right = (SInt32)((frame < activeRead ? oldSamples[frame * 2 + 1] : 0) * oldGain) +
                          (SInt32)((frame < pendingRead ? newSamples[frame * 2 + 1] : 0) * newGain);
            destination[frame * 2] = (SInt16)MAX(-32768, MIN(32767, left));
            destination[frame * 2 + 1] = (SInt16)MAX(-32768, MIN(32767, right));
        }
    }
    _fadePositionFrames += frames;
    waEQProcess(&_eq, destination, frames);
    waCompProcess(&_comp, destination, frames);
    if (_fadePositionFrames >= _fadeTotalFrames) {
        waPCMTrack *oldTrack = _activeTrack;
        _activeTrack = _pendingTrack;
        _logicalTrack = _activeTrack;
        _pendingTrack = nil;
        _fadeActive = NO;
        _fadePositionFrames = 0;
        _fadeTotalFrames = 0;
        _fadeFinishEarly = NO;
        OSMemoryBarrier();
        dispatch_async(dispatch_get_main_queue(), ^{ [oldTrack stop]; });
    }
}

- (void)renderBuffer:(AudioQueueBufferRef)buffer {
    if (!_queueStarted || !_playing || !_activeTrack) return;
    [self renderBufferWithoutQueueing:buffer];
    if (_finishRequested) {
        if (!_finishNotificationSent) {
            _finishNotificationSent = YES;
            __weak waPCMMixer *weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf finishOnMainThread]; });
        }
        return;
    }
    AudioQueueEnqueueBuffer(_audioQueue, buffer, 0, NULL);
}

- (waPCMTrack *)takeUnclaimedFadeRequestWithTotal:(UInt32 *)outTotal {
    void *p = _pendingFadeRequest;
    OSMemoryBarrier();
    if (!p) return nil;
    if (!OSAtomicCompareAndSwapPtr(p, NULL, &_pendingFadeRequest)) return nil;
    OSMemoryBarrier();
    waPendingFadeRequest *req = (waPendingFadeRequest *)p;
    waPCMTrack *track = (__bridge_transfer waPCMTrack *)req->retainedTrack;
    UInt32 total = req->totalFrames;
    free(req);
    if (outTotal) *outTotal = total;
    return track;
}

- (BOOL)claimFadeRequestIntoTrack:(waPCMTrack **)outTrack totalFrames:(UInt32 *)outTotal {
    UInt32 total = 0;
    waPCMTrack *track = [self takeUnclaimedFadeRequestWithTotal:&total];
    if (!track) return NO;
    if (outTrack) *outTrack = track;
    if (outTotal) *outTotal = total;
    return YES;
}

- (void)crossfadeToTrack:(waPCMTrack *)track duration:(NSTimeInterval)duration completion:(void (^)(BOOL started))completion {
    if (!track || !_activeTrack || !_playing || duration <= 0.0 || track.error) {
        if (completion) completion(NO);
        return;
    }
    UInt32 total = MAX(1, (UInt32)MIN((double)UINT_MAX, duration * _outputFormat.mSampleRate));
    waPendingFadeRequest *req = malloc(sizeof(waPendingFadeRequest));
    if (!req) {
        if (completion) completion(NO);
        return;
    }
    // Fully initialize before publish; render only dereferences after CAS win.
    req->retainedTrack = (void *)CFBridgingRetain(track);
    req->totalFrames = total;
    OSMemoryBarrier();
    _fadeFinishEarly = NO;
    OSMemoryBarrier();
    void *old = NULL;
    do {
        old = _pendingFadeRequest;
        OSMemoryBarrier();
    } while (!OSAtomicCompareAndSwapPtr(old, req, &_pendingFadeRequest));
    // Replaced an unclaimed request: render never dereferenced it (it only
    // dereferences after a successful CAS), so freeing here is safe.
    if (old) waPendingFadeRelease(old);
    _logicalTrack = track;
    if (completion) completion(YES);
}

- (void)cancelCrossfade {
    void *before = _pendingFadeRequest;
    OSMemoryBarrier();
    UInt32 dummy = 0;
    waPCMTrack *unclaimed = [self takeUnclaimedFadeRequestWithTotal:&dummy];
    if (unclaimed) [unclaimed stop];
    // Concurrent claim by render between load and CAS: treat as active.
    BOOL concurrentClaim = (before != NULL && unclaimed == nil);
    if (!_fadeActive && !concurrentClaim) return;
    if (!_queueStarted || !_playing) {
        // Queue halted: no concurrent render, promote synchronously.
        if (_fadeActive && _pendingTrack) {
            waPCMTrack *oldTrack = _activeTrack;
            _activeTrack = _pendingTrack;
            _logicalTrack = _activeTrack;
            _pendingTrack = nil;
            _fadeActive = NO;
            _fadePositionFrames = 0;
            _fadeTotalFrames = 0;
            _fadeFinishEarly = NO;
            OSMemoryBarrier();
            if (oldTrack) dispatch_async(dispatch_get_main_queue(), ^{ [oldTrack stop]; });
        } else {
            _fadeFinishEarly = NO;
            OSMemoryBarrier();
        }
    } else {
        // Queue running: ask render to finish early next buffer. Never blocks.
        _fadeFinishEarly = YES;
        OSMemoryBarrier();
    }
}

- (void)pause {
    dispatch_sync(_controlQueue, ^{
        if (!self->_audioQueue || !self->_playing) return;
        if (!self->_seekPending) AudioQueuePause(self->_audioQueue);
        self->_playing = NO;
    });
}

- (void)resume {
    dispatch_sync(_controlQueue, ^{
        if (!self->_audioQueue || !self->_activeTrack || self->_playing) return;
        // During seek this is intent only; its completion primes the queue.
        self->_playing = YES;
        if (self->_seekPending) return;
        if (!self->_queueStarted) {
            if (![self enqueueInitialBuffers]) { self->_playing = NO; return; }
            self->_queueStarted = YES;
        }
        OSMemoryBarrier();
        OSStatus status = AudioQueueStart(self->_audioQueue, NULL);
        if (status != noErr) {
            self->_playing = NO;
            [self notifyFailureOnMainThread:[NSError errorWithDomain:@"com.bytebox.wave.audio" code:-23 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AudioQueue resume failed (%ld).", (long)status]}]];
        }
    });
}

- (void)stop {
    // Route blocking AudioQueue ops off the caller (main) thread.
    if (!_controlQueue) return;
    dispatch_async(_controlQueue, ^{ [self stopOnControlQueue]; });
}

- (void)stopOnControlQueue {
    _seekGeneration += 1;
    _seekPending = NO;
    // Discard any not-yet-adopted fade (render never saw it).
    UInt32 dummy = 0;
    waPCMTrack *unclaimed = [self takeUnclaimedFadeRequestWithTotal:&dummy];
    if (unclaimed) [unclaimed stop];
    _playing = NO;
    _queueStarted = NO;
    OSMemoryBarrier();
    if (_audioQueue) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueReset(_audioQueue);
    }
    // Queue halted: safe to clear render-owned fade/track state.
    _finishRequested = NO;
    _finishNotificationSent = NO;
    _fadeActive = NO;
    _fadeFinishEarly = NO;
    _fadePositionFrames = 0;
    _fadeTotalFrames = 0;
    [_activeTrack stop];
    [_pendingTrack stop];
    _activeTrack = nil;
    _pendingTrack = nil;
    _logicalTrack = nil;
}

- (void)seekToTime:(NSTimeInterval)time {
    if (!isfinite(time) || time < 0.0) return;
    if (!_controlQueue) return;
    NSTimeInterval captured = time;
    dispatch_async(_controlQueue, ^{ [self seekOnControlQueue:captured]; });
}

- (void)seekOnControlQueue:(NSTimeInterval)time {
    if (!_activeTrack || !isfinite(time) || time < 0.0) return;
    NSUInteger generation = ++_seekGeneration;
    _seekPending = YES;
    _queueStarted = NO;
    OSMemoryBarrier();
    if (_audioQueue) {
        AudioQueueStop(_audioQueue, true);
        AudioQueueReset(_audioQueue);
    }
    // Queue halted: resolve any in-flight fade synchronously (promote, since
    // the engine already cancelled and expects the logical track to survive).
    UInt32 dummy = 0;
    waPCMTrack *unclaimed = [self takeUnclaimedFadeRequestWithTotal:&dummy];
    if (unclaimed) [unclaimed stop];
    _fadeFinishEarly = NO;
    OSMemoryBarrier();
    if (_fadeActive && _pendingTrack) {
        waPCMTrack *oldTrack = _activeTrack;
        _activeTrack = _pendingTrack;
        _logicalTrack = _activeTrack;
        _pendingTrack = nil;
        _fadeActive = NO;
        _fadePositionFrames = 0;
        _fadeTotalFrames = 0;
        if (oldTrack) {
            waPCMTrack *toStop = oldTrack;
            dispatch_async(dispatch_get_main_queue(), ^{ [toStop stop]; });
        }
    }
    _finishRequested = NO;
    _finishNotificationSent = NO;
    _stalled = NO;
    waPCMTrack *track = _activeTrack;
    if (!track) return;
    __weak waPCMMixer *weakSelf = self;
    // Async track seek (generation-guarded); completion hops via main back
    // to the control queue to prime/restart, preserving finish callbacks.
    [track seekToTime:time completion:^{
        waPCMMixer *strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf->_controlQueue, ^{
            if (strongSelf->_activeTrack != track || generation != strongSelf->_seekGeneration) return;
            waEQReset(&strongSelf->_eq);
            waCompReset(&strongSelf->_comp);
            strongSelf->_finishRequested = NO;
            strongSelf->_finishNotificationSent = NO;
            strongSelf->_seekPending = NO;
            // A paused seek must also leave buffers ready for the next resume.
            if (![strongSelf enqueueInitialBuffers]) { strongSelf->_playing = NO; return; }
            strongSelf->_queueStarted = YES;
            OSMemoryBarrier();
            if (strongSelf->_playing) {
                OSStatus status = AudioQueueStart(strongSelf->_audioQueue, NULL);
                if (status != noErr) {
                    strongSelf->_playing = NO;
                    [strongSelf notifyFailureOnMainThread:[NSError errorWithDomain:@"com.bytebox.wave.audio" code:-23 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"AudioQueue seek restart failed (%ld).", (long)status]}]];
                }
            }
        });
    }];
}

- (void)setEqualizerGains:(const float *)gains {
    waEQSetGains(&_eq, gains);
}

- (void)equalizerGains:(float *)gains {
    if (!gains) return;
    for (int i = 0; i < WA_EQ_BANDS; i++) gains[i] = _eq.gains[i];
}

- (void)setCompressorEnabled:(BOOL)enabled {
    waCompSetEnabled(&_comp, enabled);
}

- (void)setCompressorStrength:(float)strength {
    waCompSetStrength(&_comp, strength);
}

- (BOOL)compressorEnabled {
    return _comp.enabled;
}

- (float)compressorStrength {
    return _comp.strength;
}

- (void)notifyStallOnMainThread {
    if (_stalled) return;
    _stalled = YES;
    __weak waPCMMixer *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        waPCMMixer *strongSelf = weakSelf;
        if (strongSelf && [strongSelf.delegate respondsToSelector:@selector(pcmMixerDidStall:)]) [strongSelf.delegate pcmMixerDidStall:strongSelf];
    });
}

- (void)notifyFailureOnMainThread:(NSError *)error {
    __weak waPCMMixer *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        waPCMMixer *strongSelf = weakSelf;
        if (strongSelf && [strongSelf.delegate respondsToSelector:@selector(pcmMixerDidFail:error:)]) [strongSelf.delegate pcmMixerDidFail:strongSelf error:error];
    });
}

- (void)finishOnMainThread {
    if (!_finishRequested) return;
    if (_audioQueue) AudioQueueStop(_audioQueue, false);
    _playing = NO;
    _queueStarted = NO;
    _finishRequested = NO;
    NSTimeInterval consumedTime = _logicalTrack ? _logicalTrack.currentTime : 0.0;
    if (consumedTime <= 0.0) {
        // End-of-stream with zero decoded frames is a starved track, not a
        // finished one (slow network latched EOS before audio flowed). Report
        // failure so the player retries at lower quality instead of skipping.
        [[waDebugLog sharedLog] log:@"PCM starved track: EOS with 0 frames consumed; failing instead of finishing"];
        [self notifyFailureOnMainThread:[NSError errorWithDomain:@"com.bytebox.wave.audio"
                                                            code:-15
                                                        userInfo:@{NSLocalizedDescriptionKey: @"The stream ended before any audio was decoded."}]];
        return;
    }
    if ([self.delegate respondsToSelector:@selector(pcmMixerDidFinish:)]) [self.delegate pcmMixerDidFinish:self];
}

@end
