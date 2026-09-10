#import "waImageLoader.h"
#import "../Models/waPreferences.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>

// Main-run-loop connection with a bounded response and explicit cancellation.
@interface waImageDownload : NSObject <NSURLConnectionDataDelegate>
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, copy) void (^completion)(NSData *);
@property (nonatomic, assign) BOOL finished;
- (void)start;
- (void)finish:(BOOL)success;
@end

@implementation waImageDownload
- (void)start {
    self.data = [NSMutableData data];
    self.connection = [[NSURLConnection alloc] initWithRequest:self.request delegate:self startImmediately:NO];
    if (!self.connection) { [self finish:NO]; return; }
    [self.connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [self.connection start];
}
- (void)finish:(BOOL)success {
    if (self.finished) return;
    self.finished = YES;
    [self.connection cancel];
    self.connection = nil;
    NSData *data = success ? [self.data copy] : nil;
    self.data = nil;
    void (^completion)(NSData *) = self.completion;
    self.completion = nil;
    if (completion) completion(data);
}
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if (self.finished) return;
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    if (status < 200 || status >= 300 || response.expectedContentLength > 8 * 1024 * 1024) { [self finish:NO]; return; }
    [self.data setLength:0];
}
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (self.finished) return;
    if (data.length > 8 * 1024 * 1024 - self.data.length) { [self finish:NO]; return; }
    [self.data appendData:data];
}
- (void)connectionDidFinishLoading:(NSURLConnection *)connection { [self finish:YES]; }
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error { [self finish:NO]; }
@end

@interface waImageLoader ()
@property (nonatomic, strong) NSCache *memory;
@property (nonatomic, strong) NSString *directory;
@property (nonatomic, strong) NSMutableDictionary *pending;
@property (nonatomic, strong) NSOperationQueue *queue;
@property (nonatomic, strong) NSMutableArray *waitingDownloads;
@property (nonatomic, strong) NSMutableArray *activeDownloads;
@property (nonatomic, strong) dispatch_queue_t cacheIOQueue;
@property (nonatomic, assign) NSUInteger cacheGeneration;
@property (nonatomic, assign) unsigned long long cachedBytesValue;
@property (nonatomic, assign) NSUInteger appliedMemoryLimitMB;
@property (nonatomic, assign) BOOL didApplyMemoryLimit;
@property (nonatomic, strong) dispatch_queue_t trimQueue;
- (void)startWaitingDownloads;
@end

// iPhone 4 has a very small working set. Decoded bitmaps are much more
// expensive than their compressed files, so keep this cache deliberately
// conservative and let the disk cache carry the long tail.
static unsigned long long const waImageMemoryLimit = 16ULL * 1024ULL * 1024ULL;

// Fast scrolling can enqueue hundreds of decode/network operations faster
// than the two-slot queues drain them. Past this many distinct pending keys
// new requests fail fast to the placeholder instead of growing an unbounded
// backlog that would decode off-screen rows long after they scrolled away.
// (Duplicate URLs are already coalesced through the pending dictionary.)
static NSUInteger const waImageMaxPendingKeys = 256;

// The configured cache limit is a SHARED budget: stream audio takes 3/4,
// artwork takes 1/4. Each cache enforcing the full limit let the combined
// total reach 2x the setting (see Settings cache row = image + stream).
static unsigned long long waImageDiskCacheLimitBytes(void) {
    unsigned long long total = (unsigned long long)[waPreferences sharedPreferences].cacheSizeMB * 1024ULL * 1024ULL;
    return total / 4ULL;
}

static NSRegularExpression *waImageSizeExpression(void) {
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ expression = [[NSRegularExpression alloc] initWithPattern:@"=w[0-9]+-h[0-9]+" options:0 error:NULL]; });
    return expression;
}

static NSRegularExpression *waImageSquareExpression(void) {
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ expression = [[NSRegularExpression alloc] initWithPattern:@"=s[0-9]+" options:0 error:NULL]; });
    return expression;
}

static NSRegularExpression *waImageDimensionsExpression(void) {
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ expression = [[NSRegularExpression alloc] initWithPattern:@"[0-9]+x[0-9]+-" options:0 error:NULL]; });
    return expression;
}

static UIImageOrientation waImageOrientationFromProperties(NSDictionary *properties) {
    NSInteger value = [properties[(NSString *)kCGImagePropertyOrientation] integerValue];
    switch (value) {
        case 2: return UIImageOrientationUpMirrored;
        case 3: return UIImageOrientationDown;
        case 4: return UIImageOrientationDownMirrored;
        case 5: return UIImageOrientationLeftMirrored;
        case 6: return UIImageOrientationRight;
        case 7: return UIImageOrientationRightMirrored;
        case 8: return UIImageOrientationLeft;
        default: return UIImageOrientationUp;
    }
}

static UIImage *waImageDownsampledFromData(NSData *data, NSUInteger maxPixelSize) {
    if (!data.length) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;

    NSDictionary *properties = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    NSDictionary *options = maxPixelSize ? @{ (id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                                               (id)kCGImageSourceCreateThumbnailWithTransform:@YES,
                                               (id)kCGImageSourceThumbnailMaxPixelSize:@(maxPixelSize) } : nil;
    CGImageRef imageRef = maxPixelSize ? CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options) : CGImageSourceCreateImageAtIndex(source, 0, NULL);
    // ThumbnailWithTransform has already applied the source orientation.
    UIImageOrientation orientation = maxPixelSize ? UIImageOrientationUp : waImageOrientationFromProperties(properties);
    UIImage *image = imageRef ? [[UIImage alloc] initWithCGImage:imageRef scale:1.0 orientation:orientation] : nil;
    if (imageRef) CGImageRelease(imageRef);
    CFRelease(source);
    return image;
}

@implementation waImageLoader

+ (id)sharedLoader { static waImageLoader *loader; static dispatch_once_t onceToken; dispatch_once(&onceToken, ^{ loader = [[self alloc] init]; }); return loader; }

- (id)init {
    if ((self = [super init])) {
        _memory = [[NSCache alloc] init];
        _pending = [[NSMutableDictionary alloc] init];
        _queue = [[NSOperationQueue alloc] init];
        // Four simultaneous JPEG decodes make scrolling visibly fight the
        // audio/UI threads on A4 devices. Two keeps scrolling responsive.
        _queue.maxConcurrentOperationCount = 2;
        _waitingDownloads = [NSMutableArray array];
        _activeDownloads = [NSMutableArray array];
        _cacheIOQueue = dispatch_queue_create("com.bytebox.wave.images.cache", DISPATCH_QUEUE_SERIAL);
        // Trimming scans and stats the whole directory. Run it away from the
        // read/write queue so an in-progress decode is never blocked behind it.
        _trimQueue = dispatch_queue_create("com.bytebox.wave.images.trim", DISPATCH_QUEUE_SERIAL);
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        _directory = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"wa.images.v2"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:NULL];
        [self updateMemoryLimit];
        dispatch_async(_trimQueue, ^{ [self trimDiskCache]; });
    }
    return self;
}

- (void)updateMemoryLimit {
    NSUInteger megabytes = [waPreferences sharedPreferences].cacheSizeMB;
    // Reassigning totalCostLimit on every artwork load made NSCache re-scan
    // its cost bookkeeping during scrolling. Only apply real changes.
    if (self.didApplyMemoryLimit && megabytes == self.appliedMemoryLimitMB) return;
    self.appliedMemoryLimitMB = megabytes;
    self.didApplyMemoryLimit = YES;
    unsigned long long bytes = (unsigned long long)megabytes * 1024ULL * 1024ULL;
    // Keep the disk cache configurable, but cap decoded images in RAM for
    // legacy devices with small working sets.
    bytes = MIN(bytes, waImageMemoryLimit);
    self.memory.totalCostLimit = bytes > NSUIntegerMax ? NSUIntegerMax : (NSUInteger)bytes;
}

- (NSString *)pathForURL:(NSString *)url {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([url UTF8String], (CC_LONG)[url lengthOfBytesUsingEncoding:NSUTF8StringEncoding], digest);
    NSMutableString *name = [NSMutableString string];
    for (int index = 0; index < CC_SHA1_DIGEST_LENGTH; index++) [name appendFormat:@"%02x", digest[index]];
    return [self.directory stringByAppendingPathComponent:name];
}

- (NSString *)highQualityURL:(NSString *)url {
    if (!url.length) return url;
    url = [waImageSizeExpression() stringByReplacingMatchesInString:url options:0 range:NSMakeRange(0, url.length) withTemplate:@"=w540-h540"];
    url = [waImageSquareExpression() stringByReplacingMatchesInString:url options:0 range:NSMakeRange(0, url.length) withTemplate:@"=s540"];
    if ([url rangeOfString:@"images/cover/"].location != NSNotFound) {
        url = [waImageDimensionsExpression() stringByReplacingMatchesInString:url options:0 range:NSMakeRange(0, url.length) withTemplate:@"1000x1000-"];
        url = [url stringByReplacingOccurrencesOfString:@"/cover_medium/" withString:@"/cover_xl/"];
        url = [url stringByReplacingOccurrencesOfString:@"/cover_big/" withString:@"/cover_xl/"];
    }
    return url;
}

- (NSString *)thumbnailURL:(NSString *)url maxPixelSize:(NSUInteger)maxPixelSize {
    if (!url.length) return url;
    NSString *size = [NSString stringWithFormat:@"%lu", (unsigned long)maxPixelSize];
    NSString *widthAndHeight = [NSString stringWithFormat:@"=w%1$@-h%1$@", size];
    NSString *square = [NSString stringWithFormat:@"=s%@", size];
    NSString *dimensions = [NSString stringWithFormat:@"%1$@x%1$@-", size];
    url = [waImageSizeExpression() stringByReplacingMatchesInString:url options:0 range:NSMakeRange(0, url.length) withTemplate:widthAndHeight];
    url = [waImageSquareExpression() stringByReplacingMatchesInString:url options:0 range:NSMakeRange(0, url.length) withTemplate:square];
    if ([url rangeOfString:@"cdns-images.dzcdn.net/images/cover/"].location != NSNotFound) {
        url = [waImageDimensionsExpression() stringByReplacingMatchesInString:url options:0 range:NSMakeRange(0, url.length) withTemplate:dimensions];
        url = [url stringByReplacingOccurrencesOfString:@"/cover_xl/" withString:@"/cover_medium/"];
        url = [url stringByReplacingOccurrencesOfString:@"/cover_big/" withString:@"/cover_medium/"];
    }
    return url;
}

- (void)loadThumbnailAtURL:(NSString *)url placeholder:(UIImage *)placeholder completion:(void (^)(UIImage *))completion {
    [self loadThumbnailAtURL:url targetSize:CGSizeMake(44.0, 44.0) placeholder:placeholder completion:completion];
}

- (void)loadThumbnailAtURL:(NSString *)url targetSize:(CGSize)targetSize placeholder:(UIImage *)placeholder completion:(void (^)(UIImage *))completion {
    CGFloat points = MAX(targetSize.width, targetSize.height);
    CGFloat scale = [UIScreen mainScreen].scale;
    NSUInteger maxPixelSize = MAX((NSUInteger)1, (NSUInteger)ceil(points * scale));
    [self loadURL:[self thumbnailURL:url maxPixelSize:maxPixelSize] placeholder:placeholder allowHighQualityFallback:NO maxPixelSize:maxPixelSize completion:completion];
}

- (void)loadLocalImageAtPath:(NSString *)path targetSize:(CGSize)targetSize completion:(void (^)(UIImage *))completion {
    if (!path.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil); });
        return;
    }
    NSUInteger maxPixelSize = MAX((NSUInteger)1, (NSUInteger)ceil(MAX(targetSize.width, targetSize.height) * [UIScreen mainScreen].scale));
    NSString *key = [NSString stringWithFormat:@"local:%lu:%@", (unsigned long)maxPixelSize, path];
    UIImage *cached = [self.memory objectForKey:key];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(cached); });
        return;
    }
    void (^callback)(UIImage *) = [completion copy];
    BOOL shouldStart = NO;
    NSUInteger generation = 0;
    BOOL overBudget = NO;
    @synchronized (self) {
        NSMutableArray *callbacks = self.pending[key];
        if (!callbacks) {
            if (self.pending.count >= waImageMaxPendingKeys) overBudget = YES;
            else {
                callbacks = [NSMutableArray array];
                self.pending[key] = callbacks;
                shouldStart = YES;
                generation = self.cacheGeneration;
            }
        }
        if (callback && !overBudget) [callbacks addObject:callback];
    }
    if (overBudget) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil); });
        return;
    }
    if (!shouldStart) return;
    [self.queue addOperationWithBlock:^{
        if (![self isCurrentGeneration:generation]) return;
        // This is deliberately performed off the main thread; artwork may be
        // absent while a download is being finalized, which is a valid miss.
        NSData *data = [NSData dataWithContentsOfFile:path];
        UIImage *image = waImageDownsampledFromData(data, maxPixelSize);
        [self finishURL:key image:image generation:generation];
    }];
}

- (void)loadArtworkAtURL:(NSString *)url placeholder:(UIImage *)placeholder completion:(void (^)(UIImage *))completion {
    // Now Playing and detail artwork do not need a full 768px decoded bitmap
    // on legacy devices; the view will scale it without visible loss.
    [self loadURL:[self highQualityURL:url] placeholder:placeholder allowHighQualityFallback:NO maxPixelSize:512 completion:completion];
}

- (void)loadImageAtURL:(NSString *)url placeholder:(UIImage *)placeholder completion:(void (^)(UIImage *))completion {
    [self loadURL:url placeholder:placeholder allowHighQualityFallback:YES maxPixelSize:768 completion:completion];
}

- (NSString *)cacheKeyForURL:(NSString *)url maxPixelSize:(NSUInteger)maxPixelSize {
    return [NSString stringWithFormat:@"p%lu:%@", (unsigned long)maxPixelSize, url];
}

- (void)loadURL:(NSString *)url placeholder:(UIImage *)placeholder allowHighQualityFallback:(BOOL)allowFallback maxPixelSize:(NSUInteger)maxPixelSize completion:(void (^)(UIImage *))completion {
    if (!url.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(placeholder); });
        return;
    }
    [self updateMemoryLimit];
    NSString *cacheKey = [self cacheKeyForURL:url maxPixelSize:maxPixelSize];
    UIImage *cached = [self.memory objectForKey:cacheKey];
    if (cached) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(cached); });
        return;
    }

    void (^callback)(UIImage *) = [completion copy];
    BOOL shouldStart = NO;
    NSUInteger generation = 0;
    BOOL overBudget = NO;
    @synchronized (self) {
        NSMutableArray *callbacks = self.pending[cacheKey];
        if (!callbacks) {
            if (self.pending.count >= waImageMaxPendingKeys) overBudget = YES;
            else {
                callbacks = [NSMutableArray array];
                self.pending[cacheKey] = callbacks;
                shouldStart = YES;
                generation = self.cacheGeneration;
            }
        }
        if (callback && !overBudget) [callbacks addObject:^(UIImage *image) { callback(image ?: placeholder); }];
    }
    if (overBudget) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(placeholder); });
        return;
    }
    if (!shouldStart) return;

    // Rewriting the URL is 3 regex passes plus string allocations. It is only
    // useful when a high-quality fallback is allowed, so skip it for the
    // common thumbnail path.
    NSString *highQualityURL = allowFallback ? [self highQualityURL:url] : url;
    NSArray *candidates = (allowFallback && ![highQualityURL isEqualToString:url]) ? @[url, highQualityURL] : @[url];
    [self loadCandidateAtIndex:0 candidates:candidates originalURL:cacheKey maxPixelSize:maxPixelSize generation:generation loadedData:nil sourceURL:nil];
}

- (BOOL)isCurrentGeneration:(NSUInteger)generation {
    @synchronized (self) { return generation == self.cacheGeneration; }
}

- (void)startWaitingDownloads {
    // These arrays and all connection lifecycle operations belong to main.
    while (self.activeDownloads.count < 2 && self.waitingDownloads.count) {
        waImageDownload *download = self.waitingDownloads[0];
        [self.waitingDownloads removeObjectAtIndex:0];
        [self.activeDownloads addObject:download];
        [download start];
    }
}

- (void)downloadRequest:(NSURLRequest *)request generation:(NSUInteger)generation completion:(void (^)(NSData *))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self isCurrentGeneration:generation]) return;
        waImageDownload *download = [[waImageDownload alloc] init];
        download.request = request;
        __weak waImageLoader *weakSelf = self;
        __weak waImageDownload *weakDownload = download;
        download.completion = ^(NSData *data) {
            waImageLoader *loader = weakSelf;
            waImageDownload *finished = weakDownload;
            if (finished) [loader.activeDownloads removeObjectIdenticalTo:finished];
            if ([loader isCurrentGeneration:generation] && completion) completion(data);
            [loader startWaitingDownloads];
        };
        [self.waitingDownloads addObject:download];
        [self startWaitingDownloads];
    });
}

- (UIImage *)imageFromDiskForURL:(NSString *)url maxPixelSize:(NSUInteger)maxPixelSize {
    __block UIImage *image = nil;
    dispatch_sync(self.cacheIOQueue, ^{
        NSData *data = [NSData dataWithContentsOfFile:[self pathForURL:url]];
        image = waImageDownsampledFromData(data, maxPixelSize);
    });
    return image;
}

- (void)loadCandidateAtIndex:(NSUInteger)index candidates:(NSArray *)candidates originalURL:(NSString *)originalURL maxPixelSize:(NSUInteger)maxPixelSize generation:(NSUInteger)generation loadedData:(NSData *)loadedData sourceURL:(NSString *)sourceURL {
    if (![self isCurrentGeneration:generation]) return;
    if (index >= candidates.count) { [self finishURL:originalURL image:nil generation:generation]; return; }
    NSString *candidate = candidates[index];
    [self.queue addOperationWithBlock:^{
        if (![self isCurrentGeneration:generation]) return;
        NSString *candidateKey = [self cacheKeyForURL:candidate maxPixelSize:maxPixelSize];
        UIImage *diskImage = [self imageFromDiskForURL:candidateKey maxPixelSize:maxPixelSize];
        if (diskImage) {
            [self finishURL:originalURL image:diskImage generation:generation];
            return;
        }
        NSURL *candidateURL = [NSURL URLWithString:candidate];
        if (!candidateURL) {
            [self loadCandidateAtIndex:index + 1 candidates:candidates originalURL:originalURL maxPixelSize:maxPixelSize generation:generation loadedData:nil sourceURL:nil];
            return;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:candidateURL];
        request.timeoutInterval = 15.0;
        request.cachePolicy = NSURLRequestUseProtocolCachePolicy;
        request.allowsCellularAccess = [waPreferences sharedPreferences].cellularDataAllowed;
        [self downloadRequest:request generation:generation completion:^(NSData *data) {
            if (!data.length || ![self isCurrentGeneration:generation]) {
                [self loadCandidateAtIndex:index + 1 candidates:candidates originalURL:originalURL maxPixelSize:maxPixelSize generation:generation loadedData:nil sourceURL:nil];
                return;
            }
            [self.queue addOperationWithBlock:^{
                if (![self isCurrentGeneration:generation]) return;
                UIImage *image = waImageDownsampledFromData(data, maxPixelSize);
                if (!image) {
                    [self loadCandidateAtIndex:index + 1 candidates:candidates originalURL:originalURL maxPixelSize:maxPixelSize generation:generation loadedData:nil sourceURL:nil];
                    return;
                }
                [self storeData:data forURL:candidateKey generation:generation];
                [self finishURL:originalURL image:image generation:generation];
            }];
        }];
    }];
}

- (void)finishURL:(NSString *)url image:(UIImage *)image generation:(NSUInteger)generation {
    NSArray *callbacks = nil;
    @synchronized (self) {
        if (generation != self.cacheGeneration) return;
        if (image) [self.memory setObject:image forKey:url cost:MAX((NSUInteger)1, image.size.width * image.size.height * 4)];
        callbacks = [self.pending[url] copy];
        [self.pending removeObjectForKey:url];
    }
    if (!callbacks.count) return;
    dispatch_async(dispatch_get_main_queue(), ^{ for (void (^callback)(UIImage *) in callbacks) callback(image); });
}

- (void)storeData:(NSData *)data forURL:(NSString *)url generation:(NSUInteger)generation {
    dispatch_sync(self.cacheIOQueue, ^{
        if (![self isCurrentGeneration:generation]) return;
        NSString *path = [self pathForURL:url];
        NSDictionary *oldAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        unsigned long long oldSize = [oldAttributes[NSFileSize] unsignedLongLongValue];
        if (![data writeToFile:path atomically:YES]) return;
        unsigned long long current = [self cachedBytesValueSafe];
        current = current >= oldSize ? current - oldSize : 0;
        current += data.length;
        [self setCachedBytesValueSafe:current];
        unsigned long long limit = waImageDiskCacheLimitBytes();
        if (!limit) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
            [self setCachedBytesValueSafe:0];
            return;
        }
        unsigned long long threshold = limit + MAX((unsigned long long)1, limit / 10ULL);
        // Never trim inline: the scan/stat pass must not stall the decode queue.
        if (current > threshold) dispatch_async(self.trimQueue, ^{ [self trimDiskCache]; });
    });
}

- (unsigned long long)cachedBytesValueSafe {
    @synchronized (self) { return self.cachedBytesValue; }
}

- (void)setCachedBytesValueSafe:(unsigned long long)value {
    @synchronized (self) { self.cachedBytesValue = value; }
}

- (unsigned long long)diskBytes {
    unsigned long long total = 0;
    NSDirectoryEnumerator *files = [[NSFileManager defaultManager] enumeratorAtPath:self.directory];
    for (NSString *file in files) {
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[self.directory stringByAppendingPathComponent:file] error:NULL];
        if ([attributes fileType] == NSFileTypeRegular) total += [attributes fileSize];
    }
    return total;
}

- (void)trimDiskCache {
    unsigned long long limit = waImageDiskCacheLimitBytes();
    if (!limit) {
        [[NSFileManager defaultManager] removeItemAtPath:self.directory error:NULL];
        [[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];
        [self setCachedBytesValueSafe:0];
        return;
    }
    unsigned long long total = [self diskBytes];
    if (total <= limit) { [self setCachedBytesValueSafe:total]; return; }
    NSMutableArray *files = [NSMutableArray array];
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:self.directory];
    for (NSString *file in enumerator) {
        NSString *path = [self.directory stringByAppendingPathComponent:file];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        if ([attributes fileType] == NSFileTypeRegular) [files addObject:@{ @"path": path, @"date": attributes[NSFileModificationDate] ?: [NSDate distantPast], @"size": attributes[NSFileSize] ?: @0 }];
    }
    [files sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"date"] compare:b[@"date"]]; }];
    for (NSDictionary *file in files) {
        if (total <= limit) break;
        [[NSFileManager defaultManager] removeItemAtPath:file[@"path"] error:NULL];
        total = total > [file[@"size"] unsignedLongLongValue] ? total - [file[@"size"] unsignedLongLongValue] : 0;
    }
    [self setCachedBytesValueSafe:total];
}

- (void)clearCache {
    [self clearCacheWithCompletion:nil];
}

- (void)trimCache {
    dispatch_async(self.trimQueue, ^{ [self trimDiskCache]; });
}

- (void)clearCacheWithCompletion:(void (^)(void))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self clearCacheWithCompletion:completion]; });
        return;
    }
    NSMutableArray *callbacks = [NSMutableArray array];
    @synchronized (self) {
        self.cacheGeneration += 1;
        for (NSArray *pendingCallbacks in [self.pending allValues]) [callbacks addObjectsFromArray:pendingCallbacks];
        [self.pending removeAllObjects];
    }
    [self.memory removeAllObjects];
    [self.waitingDownloads removeAllObjects];
    for (waImageDownload *download in [self.activeDownloads copy]) [download finish:NO];
    if (callbacks.count) dispatch_async(dispatch_get_main_queue(), ^{ for (void (^callback)(UIImage *) in callbacks) callback(nil); });
    dispatch_async(self.cacheIOQueue, ^{
        [[NSFileManager defaultManager] removeItemAtPath:self.directory error:NULL];
        [[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL];
        [self setCachedBytesValueSafe:0];
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    });
}

- (unsigned long long)cachedBytes {
    return [self cachedBytesValueSafe];
}

@end
