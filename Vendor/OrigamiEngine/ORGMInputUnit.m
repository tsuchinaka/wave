//
// ORGMInputUnit.m
//
// Copyright (c) 2012 ap4y (lod@pisem.net)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "ORGMInputUnit.h"
#import <math.h>

#import "ORGMPluginManager.h"

@interface ORGMInputUnit () {
    int bytesPerFrame;
    void *inputBuffer;

    BOOL _shouldSeek;
    volatile BOOL _cancelRequested;
    long seekFrame;
}

@property (retain, nonatomic) NSMutableData *data;
@property (retain, nonatomic) id<ORGMSource> source;
@property (retain, nonatomic) id<ORGMDecoder> decoder;
@property (assign, nonatomic) BOOL endOfInput;
@end

@implementation ORGMInputUnit

- (id)init {
    self = [super init];
    if (self) {
        self.data = [NSMutableData data];
        inputBuffer = malloc(CHUNK_SIZE);
        _endOfInput = NO;
        _cancelRequested = NO;
    }
    return self;
}

- (void)dealloc {
    [self close];
    free(inputBuffer);
    [_decoder release];
    [_source release];
    [_data release];
    [super dealloc];
}

#pragma mark - public

- (BOOL)openWithUrl:(NSURL *)url {
    return [self openWithUrl:url error:nil];
}

- (BOOL)openWithUrl:(NSURL *)url error:(NSError **)error {
    NSError *sourceError = nil;
    self.source = [[ORGMPluginManager sharedManager] sourceForURL:url error:&sourceError];
    if (_cancelRequested) {
        if (error) *error = [[[NSError alloc] initWithDomain:kErrorDomain
                                                        code:ORGMEngineErrorCodesSourceFailed
                                                    userInfo:@{NSLocalizedDescriptionKey: @"Playback was cancelled while opening the source."}] autorelease];
        return NO;
    }
    if (!_source) {
        [self close];
        if (error) {
            if (sourceError) *error = sourceError;
            else {
                NSString *scheme = [url scheme];
                if (!scheme) scheme = @"(null)";
                *error = [[[NSError alloc] initWithDomain:kErrorDomain
                                                    code:ORGMEngineErrorCodesSourceFailed
                                                userInfo:@{NSLocalizedDescriptionKey:
                                                           [NSString stringWithFormat:@"No source for URL scheme '%@'.", scheme]}] autorelease];
            }
        }
        return NO;
    }
    if (![_source open:url]) {
        NSError *openError = sourceError;
        [self close];
        if (_cancelRequested) {
            if (error) *error = [[[NSError alloc] initWithDomain:kErrorDomain
                                                            code:ORGMEngineErrorCodesSourceFailed
                                                        userInfo:@{NSLocalizedDescriptionKey: @"Playback was cancelled while opening the source."}] autorelease];
            return NO;
        }
        if (error) {
            if (openError) *error = openError;
            else {
                NSString *scheme = [url scheme];
                if (!scheme) scheme = @"(null)";
                *error = [[[NSError alloc] initWithDomain:kErrorDomain
                                                    code:ORGMEngineErrorCodesSourceFailed
                                                userInfo:@{NSLocalizedDescriptionKey:
                                                           [NSString stringWithFormat:@"Could not open %@ source.", scheme]}] autorelease];
            }
        }
        return NO;
    }
    if (_cancelRequested) {
        [_source close];
        if (error) *error = [[[NSError alloc] initWithDomain:kErrorDomain
                                                        code:ORGMEngineErrorCodesSourceFailed
                                                    userInfo:@{NSLocalizedDescriptionKey: @"Playback was cancelled while opening the source."}] autorelease];
        return NO;
    }
    NSError *decoderError = nil;
    self.decoder = [[ORGMPluginManager sharedManager] decoderForSource:_source error:&decoderError];
    if (!_decoder) {
        NSString *ext = [[[_source url] path] pathExtension];
        if (!ext) ext = @"";
        [self close];
        if (error) {
            if (decoderError) *error = decoderError;
            else *error = [[[NSError alloc] initWithDomain:kErrorDomain
                                                     code:ORGMEngineErrorCodesDecoderFailed
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"No decoder for extension '%@'.", ext]}] autorelease];
        }
        return NO;
    }
    if (![_decoder open:_source]) {
        NSString *lastComponent = [[_source url] lastPathComponent];
        if (!lastComponent) lastComponent = @"the source";
        NSString *detail = [NSString stringWithFormat:@"%@ could not decode %@.",
                            NSStringFromClass([_decoder class]),
                            lastComponent];
        [self close];
        if (error) *error = [[[NSError alloc] initWithDomain:kErrorDomain
                                                        code:ORGMEngineErrorCodesDecoderFailed
                                                    userInfo:@{NSLocalizedDescriptionKey: detail}] autorelease];
        return NO;
    }

    int bitsPerSample = [[_decoder.properties objectForKey:@"bitsPerSample"] intValue];
	int channels = [[_decoder.properties objectForKey:@"channels"] intValue];
    bytesPerFrame = (bitsPerSample/8) * channels;
    if (bytesPerFrame <= 0) {
        if (error) *error = [[[NSError alloc] initWithDomain:kErrorDomain
                                                        code:ORGMEngineErrorCodesDecoderFailed
                                                    userInfo:@{NSLocalizedDescriptionKey:
                                                               [NSString stringWithFormat:@"%@ returned an invalid format (bits=%d channels=%d).",
                                                                NSStringFromClass([_decoder class]), bitsPerSample, channels]}] autorelease];
        [self close];
        return NO;
    }

    return YES;
}

- (void)close {
    if (_decoder) [_decoder close];
    else if (_source) [_source close];
}

- (void)cancel {
    _cancelRequested = YES;
    [_source close];
}

- (void)process {
    _isProcessing = YES;
    int amountInBuffer = 0;
    int framesRead = 0;

    do {
        if (_data.length >= BUFFER_SIZE) {
            framesRead = 1;
            break;
        }

        if (_shouldSeek) {
            [_decoder seek:seekFrame];
            _shouldSeek = NO;
        }
        int framesToRead = CHUNK_SIZE/bytesPerFrame;
        framesRead = [_decoder readAudio:inputBuffer frames:framesToRead];
        amountInBuffer = (framesRead * bytesPerFrame);

        dispatch_sync([ORGMQueues lock_queue], ^{
            [_data appendBytes:inputBuffer length:amountInBuffer];
        });
    } while (framesRead > 0);

    if (framesRead <= 0) {
        [self setEndOfInput:YES];
    }

    _isProcessing = NO;
}

- (double)framesCount {
    NSNumber *frames = [_decoder.properties objectForKey:@"totalFrames"];
    return [frames doubleValue];
}

- (double)bitrate {
    NSNumber *value = [_decoder.properties objectForKey:@"bitrate"];
    return [value doubleValue];
}

- (void)seek:(double)time withDataFlush:(BOOL)flush {
    if (!isfinite(time) || time < 0.0 || !_decoder) return;
    if (flush) {
        dispatch_sync([ORGMQueues lock_queue], ^{ self.data = [NSMutableData data]; });
    }
    seekFrame = time * [[_decoder.properties objectForKey:@"sampleRate"] floatValue];
    _shouldSeek = YES;
    _endOfInput = NO;
}

- (void)seek:(double)time {
    [self seek:time withDataFlush:NO];
}

- (AudioStreamBasicDescription)format {
    return propertiesToASBD(_decoder.properties);
}

- (NSDictionary *)metadata {
    return [_decoder metadata];
}

- (int)shiftBytes:(NSUInteger)amount buffer:(void *)buffer {
    int bytesToRead = MIN(amount, _data.length);

    dispatch_sync([ORGMQueues lock_queue], ^{
        memcpy(buffer, _data.bytes, bytesToRead);
        [_data replaceBytesInRange:NSMakeRange(0, bytesToRead) withBytes:NULL length:0];
    });

    return bytesToRead;
}

#pragma mark - private

@end
