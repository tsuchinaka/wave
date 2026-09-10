//
// HTTPSource.m
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

#import "HTTPSource.h"
#import "../../../Models/waPreferences.h"
#import "../../../Services/waDebugLog.h"
#import "../../../Services/waDeezerBlowfish.h"

static NSString *waStreamCacheDirectory(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:@"StreamCache"];
}

static unsigned long long waStreamCacheLimitBytes(void) {
    NSUInteger configured = [waPreferences sharedPreferences].cacheSizeMB;
    unsigned long long total = (unsigned long long)MIN((NSUInteger)1024, configured) * 1024ULL * 1024ULL;
    // Shared budget with artwork (see waImageDiskCacheLimitBytes): stream
    // takes 3/4, images 1/4, so the combined total respects the setting.
    return total - total / 4ULL;
}

static NSTimeInterval const waHTTPSourceOpenTimeout = 15.0;
static NSTimeInterval const waHTTPSourceReadTimeout = 15.0;

static NSMutableSet *waActiveStreamCachePaths(void) {
    static NSMutableSet *paths;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ paths = [[NSMutableSet alloc] init]; });
    return paths;
}

static unsigned long long waStreamCacheBytesAtPath(NSString *directory) {
    unsigned long long total = 0;
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:directory];
    for (NSString *file in enumerator) {
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[directory stringByAppendingPathComponent:file] error:NULL];
        if ([attributes fileType] == NSFileTypeRegular) total += [attributes fileSize];
    }
    return total;
}

static void waTrimStreamCache(void) {
    NSString *directory = waStreamCacheDirectory();
    NSFileManager *fileManager = [NSFileManager defaultManager];
    [fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    unsigned long long limit = waStreamCacheLimitBytes();
    unsigned long long total = waStreamCacheBytesAtPath(directory);
    if (total <= limit) return;
    NSMutableArray *files = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [fileManager enumeratorAtPath:directory];
    for (NSString *file in enumerator) {
        NSString *path = [directory stringByAppendingPathComponent:file];
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:NULL];
        BOOL active = NO;
        @synchronized(waActiveStreamCachePaths()) { active = [waActiveStreamCachePaths() containsObject:path]; }
        if (!active && [attributes fileType] == NSFileTypeRegular) [files addObject:@{ @"path": path, @"date": attributes[NSFileModificationDate] ?: [NSDate distantPast], @"size": attributes[NSFileSize] ?: @0 }];
    }
    [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"date"] compare:b[@"date"]]; }];
    for (NSDictionary *file in files) {
        if (total <= limit) break;
        [fileManager removeItemAtPath:file[@"path"] error:NULL];
        unsigned long long size = [file[@"size"] unsignedLongLongValue];
        total = total > size ? total - size : 0;
    }
}
@interface HTTPSource () {
    long _byteCount;
    long _bytesRead;
    long long _bytesExpected; // 0 = unknown (chunked / no Content-Length)
    long long _bytesWaitingFromCache;
    dispatch_semaphore_t _downloadingSemaphore;

    BOOL _connectionDidFail;
    BOOL _invalidResponse;
    BOOL _temporaryCacheFile;
    volatile BOOL _cancelled;
    volatile BOOL _downloadComplete;
    // Serverless Deezer decrypt (deezer:// URLs, BF_CBC_STRIPE).
    BOOL _deezerDecrypt;
    unsigned char _deezerKey[16];
    long long _decryptOffset;
    NSMutableData *_decryptRemainder;
    NSURL *_sourceURL;
}
@property (retain, nonatomic) NSURLConnection *urlConnection;
@property (retain, nonatomic) NSMutableURLRequest *request;
@property (retain, nonatomic) NSFileHandle *fileHandle;
@property (copy, nonatomic) NSString *cachePath;
@end

@implementation HTTPSource

const NSTimeInterval readTimeout = 1.0;

+ (NSThread *)wa_networkThread {
    static NSThread *thread = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        thread = [[NSThread alloc] initWithTarget:self
                                         selector:@selector(wa_networkThreadMain)
                                           object:nil];
        [thread setName:@"com.bytebox.wave.http"];
        [thread start];
    });
    return thread;
}

+ (void)wa_networkThreadMain {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
    // Keep the runloop alive so scheduled connections always fire here.
    [runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
    while (![[NSThread currentThread] isCancelled]) {
        NSAutoreleasePool *inner = [[NSAutoreleasePool alloc] init];
        [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        [inner drain];
    }
    [pool drain];
}

- (void)wa_startConnectionOnNetworkThread {
    [_urlConnection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [_urlConnection start];
}

- (void)dealloc {
    [self close];
    if (_downloadingSemaphore) { dispatch_release(_downloadingSemaphore); _downloadingSemaphore = NULL; }
    [_decryptRemainder release];
    _decryptRemainder = nil;
    [_sourceURL release];
    _sourceURL = nil;
    [_fileHandle closeFile];
    [_fileHandle release];
    [_cachePath release];
    [_urlConnection release];
    [_request release];

    [super dealloc];
}

#pragma mark - ORGMSource

+ (NSString *)scheme {
    return @"http";
}

- (NSURL *)url {
    // For deezer:// URLs report the original URL (with the real .mp3/.flac
    // extension) so the plugin manager picks CoreAudioDecoder vs FlacDecoder.
    // The CDN fetch URL is extensionless and would force the wrong fallback.
    if (_sourceURL) return _sourceURL;
    return [_request URL];
}

- (long)size {
    // Unknown length (chunked encoding) reports 0 so AudioFile callbacks
    // don't see a bogus -1 size; decoders sniff the header progressively.
    if (_bytesExpected <= 0) return 0;
    return (long)_bytesExpected;
}

- (BOOL)open:(NSURL *)url {
    // openAndPump runs on waPCMTrack's decodeQueue (see prepareWithCompletion);
    // never block or hop to main here.
    NSAssert(![NSThread isMainThread], @"HTTPSource open must not run on main thread");
    if ([NSThread isMainThread]) return NO;
    NSURL *fetchURL = url;
    _deezerDecrypt = NO;
    _decryptOffset = 0;
    [_decryptRemainder release];
    _decryptRemainder = [[NSMutableData alloc] init];
    [_sourceURL release];
    _sourceURL = nil;
    memset(_deezerKey, 0, sizeof(_deezerKey));
    if ([[url scheme] isEqualToString:@"deezer"]) {
        // deezer://stream/<rawID>.mp3|flac?q=<0|1|2>&u=<escaped https CDN>
        _sourceURL = [url copy];
        NSString *query = [url query] ?: @"";
        NSString *escapedCDN = nil;
        for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
            if ([pair hasPrefix:@"u="]) { escapedCDN = [pair substringFromIndex:2]; break; }
        }
        NSString *cdnString = [escapedCDN stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSURL *cdnURL = [NSURL URLWithString:cdnString];
        NSString *rawID = [[url lastPathComponent] stringByDeletingPathExtension];
        if (!cdnURL || !rawID.length) return NO;
        waDeezerDeriveKey([rawID UTF8String], _deezerKey);
        _deezerDecrypt = YES;
        fetchURL = cdnURL;
        [[waDebugLog sharedLog] log:@"HTTPSource deezer decrypt on for track %@", rawID];
    }
    self.request = [NSMutableURLRequest requestWithURL:fetchURL];
    [self.request addValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [self.request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:_request
                                                                  delegate:self
                                                          startImmediately:NO];
    self.urlConnection = connection;
    [connection release];

    _cancelled = NO;
    _downloadComplete = NO;
    _bytesExpected = 0;
    _bytesRead    = 0;
    _byteCount     = 0;
    _bytesWaitingFromCache = 0;
    _connectionDidFail = NO;
    _invalidResponse = NO;
    if (_downloadingSemaphore) { dispatch_release(_downloadingSemaphore); _downloadingSemaphore = NULL; }
    _downloadingSemaphore = dispatch_semaphore_create(0);
    [self prepareCache:[NSString stringWithFormat:@"%lx.%@",
                        (unsigned long)[[url absoluteString] hash],
                        url.pathExtension]];

    // Start the connection on a dedicated runloop thread, never main.
    // The delegate callbacks then fire there; the 15s semaphore deadline below
    // preserves the original timeout semantics.
    [self performSelector:@selector(wa_startConnectionOnNetworkThread)
                 onThread:[[self class] wa_networkThread]
               withObject:nil
            waitUntilDone:YES];

    long waitResult = dispatch_semaphore_wait(_downloadingSemaphore,
                                               dispatch_time(DISPATCH_TIME_NOW,
                                                             (int64_t)(waHTTPSourceOpenTimeout * NSEC_PER_SEC)));
    if (waitResult != 0) {
        _connectionDidFail = YES;
        [_urlConnection cancel];
        return NO;
    }

    return !_connectionDidFail && !_invalidResponse;
}

- (BOOL)seekable {
    return YES;
}

- (BOOL)seek:(long)position whence:(int)whence {
    switch (whence) {
        case SEEK_SET:
            if (position < 0) return NO;
            if (_bytesExpected > 0 && position > _bytesExpected) return NO;
            _bytesRead = position;
            break;
        case SEEK_CUR:
            if (_bytesRead + position < 0) return NO;
            if (_bytesExpected > 0 && _bytesRead + position > _bytesExpected) return NO;
            _bytesRead += position;
            break;
        case SEEK_END:
            // Without a Content-Length there is no END to seek from.
            if (_bytesExpected <= 0) return NO;
            if (position < 0 || position > _bytesExpected) return NO;
            _bytesRead = (long)_bytesExpected - position;
            break;
        default:
            return NO;
    }
    return YES;
}

- (long)tell {
    return _bytesRead;
}

- (int)read:(void *)buffer amount:(int)amount {
    if (!buffer || amount <= 0) return 0;
    BOOL knownLength = _bytesExpected > 0;
    if (knownLength && _bytesRead >= _bytesExpected)
        return 0;

    // With a known length, clamp to the remaining bytes and return the
    // final partial chunk instead of EOF. With an unknown (chunked)
    // length there is nothing to clamp against — the download-complete
    // flag below terminates the wait at true EOF.
    long long remaining = knownLength ? _bytesExpected - _bytesRead : (long long)amount;
    if (knownLength && (long long)amount > remaining) amount = (int)remaining;
    long long target = _bytesRead + amount;

    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + waHTTPSourceReadTimeout;
    while(_byteCount < target) {
        if (_connectionDidFail || _cancelled) return 0;
        // Download finished before the requested window filled: return
        // whatever arrived (0 = true EOF) instead of stalling to timeout.
        if (_downloadComplete) break;
        if ([NSDate timeIntervalSinceReferenceDate] >= deadline) {
            _connectionDidFail = YES;
            [_urlConnection cancel];
            return 0;
        }
        _bytesWaitingFromCache = target;
        dispatch_semaphore_wait(_downloadingSemaphore, dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC));
    }

    // Cap the file read at what actually arrived (matters at EOF on
    // chunked streams, where target overshoots the total).
    long long available = _byteCount - _bytesRead;
    if (available <= 0) return 0;
    if ((long long)amount > available) amount = (int)available;

    int result = 0;
    @autoreleasepool {
        __block NSData *data = nil;
        NSFileHandle *fileHandle = [_fileHandle retain];
        long long readOffset = _bytesRead;
        dispatch_sync([HTTPSource cachingQueue], ^{
            @synchronized(fileHandle) {
                @try { [fileHandle seekToFileOffset:readOffset]; } @catch (NSException *e) { [[waDebugLog sharedLog] log:@"HTTPSource read seek failed: %@", e.reason]; data = [NSData data]; return; }
                @try { data = [fileHandle readDataOfLength:amount]; } @catch (NSException *e) { [[waDebugLog sharedLog] log:@"HTTPSource read failed: %@", e.reason]; data = [NSData data]; }
            }
        });
        [fileHandle release];
        [data getBytes:buffer length:data.length];
        _bytesRead += data.length;

        result = data.length;
    }

    return result;
}

- (void)close {
    _cancelled = YES;
    [_urlConnection cancel];
    if (_downloadingSemaphore) dispatch_semaphore_signal(_downloadingSemaphore);
    NSFileHandle *fileHandle = [self.fileHandle retain];
    self.fileHandle = nil;
    // Wait for queued writes before closing or deleting the file. This keeps
    // a late NSURLConnection callback from writing into a closed handle.
    if (fileHandle) {
        dispatch_sync([HTTPSource cachingQueue], ^{
            [fileHandle synchronizeFile];
            [fileHandle closeFile];
        });
    }
    [fileHandle release];
    NSString *cachePath = [self.cachePath copy];
    if (cachePath.length) {
        @synchronized(waActiveStreamCachePaths()) {
            [waActiveStreamCachePaths() removeObject:cachePath];
        }
        if (_temporaryCacheFile) [[NSFileManager defaultManager] removeItemAtPath:cachePath error:NULL];
    }
    [cachePath release];
    [HTTPSource trimStreamCache];
}

#pragma mark - private

+ (dispatch_queue_t)cachingQueue {
    static dispatch_queue_t _cachingQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _cachingQueue = dispatch_queue_create("com.origami.httpcache",
                                              DISPATCH_QUEUE_SERIAL);
    });
    return _cachingQueue;
}

+ (unsigned long long)streamCacheBytes {
    __block unsigned long long bytes = 0;
    dispatch_sync([HTTPSource cachingQueue], ^{ bytes = waStreamCacheBytesAtPath(waStreamCacheDirectory()); });
    return bytes;
}

+ (void)trimStreamCache {
    dispatch_async([HTTPSource cachingQueue], ^{ waTrimStreamCache(); });
}

+ (void)clearStreamCacheWithCompletion:(void (^)(void))completion {
    dispatch_async([HTTPSource cachingQueue], ^{
        NSString *directory = waStreamCacheDirectory();
        NSFileManager *fileManager = [NSFileManager defaultManager];
        [fileManager removeItemAtPath:directory error:NULL];
        [fileManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (void)prepareCache:(NSString*)fileName {
    NSString *dataPath = waStreamCacheDirectory();
    [HTTPSource trimStreamCache];
    NSFileManager *defaultFileManger = [NSFileManager defaultManager];
    if (![defaultFileManger fileExistsAtPath:dataPath]) {
        if (![defaultFileManger createDirectoryAtPath:dataPath
                          withIntermediateDirectories:NO
                                           attributes:nil
                                                error:nil]) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                           reason:NSLocalizedString(@"Unable create cache directory", nil)
                                         userInfo:nil];
        }
    }

    NSString *filePath = [dataPath stringByAppendingPathComponent:fileName];
    @synchronized(waActiveStreamCachePaths()) {
        if ([waActiveStreamCachePaths() containsObject:filePath]) {
            _temporaryCacheFile = YES;
            filePath = [dataPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%p.part", fileName, self]];
        }
        [waActiveStreamCachePaths() addObject:filePath];
    }
    self.cachePath = filePath;
    if (![defaultFileManger fileExistsAtPath:filePath]) {
        if (![defaultFileManger createFileAtPath:filePath
                                        contents:nil
                                      attributes:nil]) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                           reason:NSLocalizedString(@"Unable create cache file", nil)
                                         userInfo:nil];
        }
    }

    self.fileHandle = [NSFileHandle fileHandleForUpdatingAtPath:filePath];
    if (!self.fileHandle) {
        @synchronized(waActiveStreamCachePaths()) { [waActiveStreamCachePaths() removeObject:filePath]; }
        self.cachePath = nil;
        _connectionDidFail = YES;
    }
}

#pragma mark - NSURLConnection delegate

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]] &&
        [(NSHTTPURLResponse *)response statusCode] >= 400) {
        // Surface the server's answer: a failing lossless endpoint here is
        // what kills crossfade preparation silently otherwise.
        [[waDebugLog sharedLog] log:@"HTTPSource open rejected: HTTP %ld for %@",
            (long)[(NSHTTPURLResponse *)response statusCode], [_request.URL absoluteString] ?: @""];
        _invalidResponse = YES;
        _connectionDidFail = YES;
        [_urlConnection cancel];
        dispatch_semaphore_signal(_downloadingSemaphore);
        return;
    }
    _bytesExpected = response.expectedContentLength > 0 ? response.expectedContentLength : 0;
    dispatch_semaphore_signal(_downloadingSemaphore);

    // Resume check only applies when the total is known. With chunked
    // encoding expectedContentLength is NSURLResponseUnknownLength (-1),
    // stored above as 0 = unknown.
    @try {
        if (_bytesExpected > 0 && [_fileHandle seekToEndOfFile] == _bytesExpected) {
            [_urlConnection cancel];
            _byteCount = (long)_bytesExpected;
            _downloadComplete = YES;
        }
    } @catch (NSException *e) { [[waDebugLog sharedLog] log:@"HTTPSource seekToEnd failed: %@", e.reason]; }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (data && _fileHandle) {
        // Backend .flac streams arrive in the clear; deezer:// payloads are
        // still encrypted on the wire here (decrypt happens below), so the
        // magic check only applies to the non-decrypt path.
        if (!_deezerDecrypt && [[[self url] pathExtension].lowercaseString isEqualToString:@"flac"] && _byteCount == 0) {
            const unsigned char *bytes = data.bytes;
            if (data.length < 4 || bytes[0] != 'f' || bytes[1] != 'L' || bytes[2] != 'a' || bytes[3] != 'C') {
                [[waDebugLog sharedLog] log:@"HTTPSource: non-FLAC payload on .flac stream (%@)", [_request.URL absoluteString] ?: @""];
                _invalidResponse = YES;
                _connectionDidFail = YES;
                [_urlConnection cancel];
                dispatch_semaphore_signal(_downloadingSemaphore);
                return;
            }
        }
        NSFileHandle *fileHandle = [_fileHandle retain];
        NSData *payload = data;
        if (_deezerDecrypt) {
            [_decryptRemainder appendData:data];
            NSMutableData *plain = [NSMutableData data];
            while ([_decryptRemainder length] >= 2048) {
                unsigned char chunk[2048];
                [_decryptRemainder getBytes:chunk range:NSMakeRange(0, 2048)];
                unsigned long chunkIndex = (unsigned long)(_decryptOffset / 2048);
                if (waDeezerDecryptChunk(_deezerKey, chunkIndex, chunk, 2048) != 0) {
                    [[waDebugLog sharedLog] log:@"HTTPSource deezer decrypt failed at chunk %lu", chunkIndex];
                    _invalidResponse = YES;
                    _connectionDidFail = YES;
                    [_urlConnection cancel];
                    dispatch_semaphore_signal(_downloadingSemaphore);
                    [fileHandle release];
                    return;
                }
                [plain appendBytes:chunk length:2048];
                [_decryptRemainder replaceBytesInRange:NSMakeRange(0, 2048) withBytes:NULL length:0];
                _decryptOffset += 2048;
            }
            if (![plain length]) { [fileHandle release]; return; }
            payload = plain;
        }
        dispatch_async([HTTPSource cachingQueue], ^{
            @synchronized(fileHandle) {
                @try { [fileHandle seekToFileOffset:_byteCount]; } @catch (NSException *e) { [[waDebugLog sharedLog] log:@"HTTPSource write seek failed: %@", e.reason]; [fileHandle release]; return; }
                @try { [fileHandle writeData:payload]; } @catch (NSException *e) { [[waDebugLog sharedLog] log:@"HTTPSource write failed: %@", e.reason]; [fileHandle release]; return; }
            }
            _byteCount += payload.length;
            if (_byteCount >= _bytesWaitingFromCache) {
                dispatch_semaphore_signal(_downloadingSemaphore);
            }
            [fileHandle release];
        });
    }
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    dispatch_semaphore_signal(_downloadingSemaphore);
    _connectionDidFail = YES;
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    if (_deezerDecrypt && [_decryptRemainder length]) {
        NSUInteger rest = [_decryptRemainder length];
        unsigned char *buf = malloc(rest);
        if (buf) {
            [_decryptRemainder getBytes:buf length:rest];
            unsigned long chunkIndex = (unsigned long)(_decryptOffset / 2048);
            waDeezerDecryptChunk(_deezerKey, chunkIndex, buf, rest);
            NSData *tail = [NSData dataWithBytes:buf length:rest];
            free(buf);
            NSFileHandle *fh = [_fileHandle retain];
            dispatch_sync([HTTPSource cachingQueue], ^{
                @synchronized(fh) {
                    @try { [fh seekToFileOffset:_byteCount]; } @catch (NSException *e) { [[waDebugLog sharedLog] log:@"HTTPSource tail seek failed: %@", e.reason]; return; }
                    @try { [fh writeData:tail]; } @catch (NSException *e) { [[waDebugLog sharedLog] log:@"HTTPSource tail write failed: %@", e.reason]; return; }
                }
                _byteCount += tail.length;
            });
            [fh release];
            _decryptOffset += rest;
        }
        [_decryptRemainder setLength:0];
    }
    // Normal EOF: unblock any pending read and snap an unknown length to
    // the actual total so size/tell/seek stay consistent from here on.
    if (_bytesExpected <= 0) _bytesExpected = _byteCount;
    _downloadComplete = YES;
    dispatch_semaphore_signal(_downloadingSemaphore);
}

@end
