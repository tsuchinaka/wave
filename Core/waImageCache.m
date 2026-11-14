#import "waImageCache.h"
#import <CommonCrypto/CommonDigest.h>
#import <ImageIO/ImageIO.h>
#import <sys/sysctl.h>

// Integer ImageIO path only. No NEON, no vImage: 3GS has no NEON,
// A4/A5 keep the same C path so behaviour stays identical.

static NSString *waImageDirectory(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [[paths objectAtIndex:0] stringByAppendingPathComponent:@"Artwork"];
}

static NSString *waImageHash(NSString *url) {
    const char *bytes = [url UTF8String];
    if (!bytes) return @"none";
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(bytes, (CC_LONG)strlen(bytes), digest);
    NSMutableString *name = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [name appendFormat:@"%02x", digest[i]];
    return name;
}

static NSString *waLocalPath(NSString *url) {
    if (!url.length) return nil;
    if ([url hasPrefix:@"file://"]) {
        NSString *path = [[NSURL URLWithString:url] path];
        return path.length ? path : [url substringFromIndex:7];
    }
    if ([url hasPrefix:@"/"] && [url rangeOfString:@"://"].location == NSNotFound) return url;
    return nil;
}

static NSString *waNormalizeURL(NSString *url) {
    if (!url.length) return url;
    if (waLocalPath(url)) return url;
    if ([url hasPrefix:@"https://"]) url = [@"http://" stringByAppendingString:[url substringFromIndex:8]];
    static NSString * const kCDN = @"cdn-images.dzcdn.net";
    NSArray *hosts = [NSArray arrayWithObjects:
                      @"e-cdns-images.dzcdn.net",
                      @"cdns-images.dzcdn.net",
                      @"e-cdns-images.deezer.com",
                      @"cdn-images.deezer.com",
                      nil];
    for (NSString *host in hosts) {
        if ([url rangeOfString:host].location != NSNotFound) {
            url = [url stringByReplacingOccurrencesOfString:host withString:kCDN];
            break;
        }
    }
    return url;
}

static NSInteger waEdgeForPixel(NSInteger pixel) {
    if (pixel <= 280) return 250;
    if (pixel <= 560) return 500;
    return 1000;
}

static NSString *waRewriteCDNSize(NSString *url, NSInteger pixel) {
    if (!url.length) return url;
    if ([url rangeOfString:@"dzcdn.net"].location == NSNotFound && [url rangeOfString:@"deezer.com"].location == NSNotFound) return url;
    NSRange slash = [url rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound) return url;
    NSString *file = [url substringFromIndex:slash.location + 1];
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    NSUInteger i = 0;
    while (i < file.length && [digits characterIsMember:[file characterAtIndex:i]]) i++;
    if (i < 1 || i >= file.length || [file characterAtIndex:i] != 'x') return url;
    NSUInteger j = i + 1;
    while (j < file.length && [digits characterIsMember:[file characterAtIndex:j]]) j++;
    if (j <= i + 1) return url;
    NSInteger edge = waEdgeForPixel(pixel);
    NSString *repl = [NSString stringWithFormat:@"%ldx%ld%@", (long)edge, (long)edge, [file substringFromIndex:j]];
    return [[url substringToIndex:slash.location + 1] stringByAppendingString:repl];
}

static NSString *waPrepareURL(NSString *url, NSInteger pixel) {
    url = waNormalizeURL(url);
    if (waLocalPath(url)) return url;
    return waRewriteCDNSize(url, pixel);
}

static NSString *waMemoryKey(NSString *url, NSInteger pixel) {
    return [NSString stringWithFormat:@"%@-%ld", url, (long)pixel];
}

static UIImage *waRasterizeOpaque(CGImageRef image, CGFloat scale) {
    if (!image) return nil;
    size_t w = CGImageGetWidth(image);
    size_t h = CGImageGetHeight(image);
    if (w < 1 || h < 1) return nil;
    if (scale < 1.0) scale = 1.0;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, space,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    UIImage *result = nil;
    if (ctx) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
        CGContextDrawImage(ctx, CGRectMake(0.0, 0.0, (CGFloat)w, (CGFloat)h), image);
        CGImageRef baked = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        if (baked) {
            result = [UIImage imageWithCGImage:baked scale:scale orientation:UIImageOrientationUp];
            CGImageRelease(baked);
        }
    }
    CGColorSpaceRelease(space);
    if (!result) result = [UIImage imageWithCGImage:image scale:scale orientation:UIImageOrientationUp];
    return result;
}

static UIImage *waDecodeJPEG(NSData *data, NSInteger maxPixel, CGFloat scale) {
    if (!data.length || maxPixel < 16) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
                             (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailFromImageAlways,
                             (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailWithTransform,
                             (id)kCFBooleanFalse, (id)kCGImageSourceShouldCache,
                             [NSNumber numberWithInteger:maxPixel], (id)kCGImageSourceThumbnailMaxPixelSize,
                             nil];
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    if (!image) image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return nil;
    UIImage *result = waRasterizeOpaque(image, scale);
    CGImageRelease(image);
    return result;
}

@interface waImageWaiter : NSObject
@property (nonatomic, assign) NSInteger pixel;
@property (nonatomic, assign) void *owner;
@property (nonatomic, copy) void (^completion)(UIImage *);
@property (nonatomic, assign) BOOL cancelled;
@end

@implementation waImageWaiter
@end

@interface waImageJob : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *fallbackURL;
@property (nonatomic, copy) NSString *fileHash;
@property (nonatomic, strong) NSMutableArray *waiters;
@property (nonatomic, assign) BOOL downloading;
@property (nonatomic, assign) BOOL triedFallback;
@end

@implementation waImageJob
@end

@interface waImageCache ()
@property (nonatomic, strong) NSCache *memory;
@property (nonatomic, strong) NSMutableDictionary *jobs;
@property (nonatomic, strong) NSOperationQueue *networkQueue;
@property (nonatomic, strong) NSOperationQueue *decodeQueue;
@property (nonatomic, assign) dispatch_queue_t lockQueue;
@property (nonatomic, assign) NSInteger maxPixel;
@property (nonatomic, assign) unsigned long long diskCap;
@property (nonatomic, assign) NSUInteger writesSinceSweep;
@end

@implementation waImageCache

+ (waImageCache *)shared {
    static waImageCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[waImageCache alloc] init]; });
    return cache;
}

- (void)readProfileNet:(NSUInteger *)net decode:(NSUInteger *)decode memory:(NSUInteger *)memory {
    unsigned int ncpu = 1;
    size_t len = sizeof(ncpu);
    sysctlbyname("hw.ncpu", &ncpu, &len, NULL, 0);
    char machine[64];
    memset(machine, 0, sizeof(machine));
    len = sizeof(machine);
    sysctlbyname("hw.machine", machine, &len, NULL, 0);

    BOOL threeGS = (strncmp(machine, "iPhone2", 7) == 0) || (strncmp(machine, "iPod3", 5) == 0);
    BOOL a5 = (ncpu >= 2);

    if (threeGS) {
        *net = 4;
        *decode = 1;
        *memory = 64;
        self.maxPixel = 256;
        self.diskCap = 16ULL * 1024ULL * 1024ULL;
    } else if (a5) {
        *net = 6;
        *decode = 2;
        *memory = 160;
        self.maxPixel = 640;
        self.diskCap = 48ULL * 1024ULL * 1024ULL;
    } else {
        *net = 4;
        *decode = 2;
        *memory = 96;
        self.maxPixel = 512;
        self.diskCap = 24ULL * 1024ULL * 1024ULL;
    }
}

- (id)init {
    if ((self = [super init])) {
        NSUInteger net = 2, decode = 1, memory = 80;
        [self readProfileNet:&net decode:&decode memory:&memory];

        _memory = [[NSCache alloc] init];
        _memory.countLimit = memory * 3;
        _memory.totalCostLimit = 8ULL * 1024ULL * 1024ULL;
        _jobs = [[NSMutableDictionary alloc] init];

        _networkQueue = [[NSOperationQueue alloc] init];
        _networkQueue.name = @"wave.image.net";
        _networkQueue.maxConcurrentOperationCount = (NSInteger)net;

        _decodeQueue = [[NSOperationQueue alloc] init];
        _decodeQueue.name = @"wave.image.decode";
        _decodeQueue.maxConcurrentOperationCount = (NSInteger)decode;

        _lockQueue = dispatch_queue_create("wave.image.lock", DISPATCH_QUEUE_SERIAL);

        [[NSFileManager defaultManager] createDirectoryAtPath:waImageDirectory() withIntermediateDirectories:YES attributes:nil error:NULL];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(memoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_lockQueue) dispatch_release(_lockQueue);
}

- (void)memoryWarning {
    [self.memory removeAllObjects];
}

- (NSString *)sourcePathForHash:(NSString *)hash {
    return [waImageDirectory() stringByAppendingPathComponent:[@"src-" stringByAppendingString:hash]];
}

- (NSString *)sourcePathForURL:(NSString *)url {
    url = waNormalizeURL(url);
    if (!url.length) return nil;
    NSString *path = [self sourcePathForHash:waImageHash(url)];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    return nil;
}

- (NSInteger)pixelForSize:(CGSize)size {
    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale < 1.0) scale = 1.0;
    NSInteger pixel = (NSInteger)(MAX(size.width, size.height) * scale + 0.5);
    if (pixel < 32) pixel = 32;
    if (pixel > self.maxPixel) pixel = self.maxPixel;
    return pixel;
}

- (UIImage *)cachedImageForURL:(NSString *)url size:(CGSize)size {
    if (!url.length) return nil;
    NSInteger pixel = [self pixelForSize:size];
    url = waPrepareURL(url, pixel);
    if (!url.length) return nil;
    return [self.memory objectForKey:waMemoryKey(url, pixel)];
}

- (void)loadImageAtURL:(NSString *)url size:(CGSize)size completion:(void (^)(UIImage *))completion {
    [self loadImageAtURL:url size:size owner:nil completion:completion];
}

- (void)loadImageAtURL:(NSString *)url size:(CGSize)size owner:(id)owner completion:(void (^)(UIImage *image))completion {
    NSInteger pixel = [self pixelForSize:size];
    NSString *normalized = waNormalizeURL(url);
    url = waPrepareURL(url, pixel);
    if (!url.length) {
        if (completion) completion(nil);
        return;
    }
    UIImage *hit = [self.memory objectForKey:waMemoryKey(url, pixel)];
    if (hit) {
        if (completion) completion(hit);
        return;
    }

    waImageWaiter *waiter = [[waImageWaiter alloc] init];
    waiter.pixel = pixel;
    waiter.owner = (__bridge void *)owner;
    waiter.completion = completion;

    NSString *hash = waImageHash(url);
    NSString *fallback = (normalized.length && ![normalized isEqualToString:url]) ? normalized : nil;
    __weak waImageCache *weakSelf = self;
    dispatch_async(self.lockQueue, ^{
        waImageCache *strongSelf = weakSelf;
        if (!strongSelf) return;
        waImageJob *job = [strongSelf.jobs objectForKey:url];
        if (job) {
            [job.waiters addObject:waiter];
            return;
        }
        job = [[waImageJob alloc] init];
        job.key = url;
        job.url = url;
        job.fallbackURL = fallback;
        job.fileHash = hash;
        job.waiters = [NSMutableArray arrayWithObject:waiter];
        [strongSelf.jobs setObject:job forKey:url];
        [strongSelf startJob:job];
    });
}

- (void)startJob:(waImageJob *)job {
    NSString *local = waLocalPath(job.url);
    __weak waImageCache *weakSelf = self;
    if (local) {
        [self.decodeQueue addOperationWithBlock:^{
            NSData *data = [NSData dataWithContentsOfFile:local options:NSDataReadingMappedIfSafe error:NULL];
            [weakSelf finishJob:job data:data.length > 64 ? data : nil];
        }];
        return;
    }
    NSString *path = [self sourcePathForHash:job.fileHash];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self.decodeQueue addOperationWithBlock:^{
            NSData *existing = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
            if (existing.length > 64) {
                [weakSelf finishJob:job data:existing];
                return;
            }
            [weakSelf downloadJob:job];
        }];
        return;
    }
    [self downloadJob:job];
}

- (void)downloadJob:(waImageJob *)job {
    NSURL *nsurl = [NSURL URLWithString:job.url];
    if (!nsurl) {
        [self finishJob:job data:nil];
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:nsurl
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:12.0];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"image/jpeg,image/png,image/*;q=0.8" forHTTPHeaderField:@"Accept"];
    __weak waImageCache *weakSelf = self;
    void (^handler)(NSURLResponse *, NSData *, NSError *) = ^(NSURLResponse *response, NSData *data, NSError *error) {
        BOOL ok = (error == nil && data.length > 64 && data.length <= 6 * 1024 * 1024);
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            if (status < 200 || status >= 300) ok = NO;
        }
        if (!ok && job.fallbackURL.length && !job.triedFallback) {
            job.triedFallback = YES;
            job.url = job.fallbackURL;
            job.fileHash = waImageHash(job.url);
            [weakSelf downloadJob:job];
            return;
        }
        if (ok) {
            NSString *path = [weakSelf sourcePathForHash:job.fileHash];
            [weakSelf.decodeQueue addOperationWithBlock:^{
                [data writeToFile:path atomically:YES];
                [weakSelf sweepDiskIfNeeded];
            }];
        }
        [weakSelf finishJob:job data:ok ? data : nil];
    };
    NSOperationQueue *queue = self.networkQueue ?: [NSOperationQueue mainQueue];
    if ([NSThread isMainThread]) {
        [NSURLConnection sendAsynchronousRequest:request queue:queue completionHandler:handler];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSURLConnection sendAsynchronousRequest:request queue:queue completionHandler:handler];
        });
    }
}

- (void)finishJob:(waImageJob *)job data:(NSData *)data {
    __weak waImageCache *weakSelf = self;
    dispatch_async(self.lockQueue, ^{
        waImageCache *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSArray *waiters = [job.waiters copy];
        [strongSelf.jobs removeObjectForKey:job.key.length ? job.key : job.url];
        if (!data.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                for (waImageWaiter *waiter in waiters) {
                    if (!waiter.cancelled && waiter.completion) waiter.completion(nil);
                }
            });
            return;
        }
        NSMutableDictionary *byPixel = [NSMutableDictionary dictionary];
        for (waImageWaiter *waiter in waiters) {
            if (waiter.cancelled) continue;
            NSNumber *key = [NSNumber numberWithInteger:waiter.pixel];
            NSMutableArray *group = [byPixel objectForKey:key];
            if (!group) {
                group = [NSMutableArray array];
                [byPixel setObject:group forKey:key];
            }
            [group addObject:waiter];
        }
        CGFloat scale = [UIScreen mainScreen].scale;
        if (scale < 1.0) scale = 1.0;
        [byPixel enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSArray *group, BOOL *stop) {
            (void)stop;
            [strongSelf.decodeQueue addOperationWithBlock:^{
                NSInteger pixel = [key integerValue];
                UIImage *image = waDecodeJPEG(data, pixel, scale);
                if (image) {
                    NSString *memKey = waMemoryKey(job.key.length ? job.key : job.url, pixel);
                    NSInteger iw = (NSInteger)(image.size.width * image.scale);
                    NSInteger ih = (NSInteger)(image.size.height * image.scale);
                    NSInteger cost = MAX((NSInteger)1, iw * ih * 4);
                    [strongSelf.memory setObject:image forKey:memKey cost:(NSUInteger)cost];
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    for (waImageWaiter *waiter in group) {
                        if (!waiter.cancelled && waiter.completion) waiter.completion(image);
                    }
                });
            }];
        }];
    });
}

- (void)cancelRequestsForOwner:(id)owner {
    if (!owner) return;
    __weak waImageCache *weakSelf = self;
    dispatch_async(self.lockQueue, ^{
        waImageCache *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSArray *jobs = [strongSelf.jobs allValues];
        for (waImageJob *job in jobs) {
            if (![job isKindOfClass:[waImageJob class]]) continue;
            NSArray *waiters = [job.waiters copy];
            for (waImageWaiter *waiter in waiters) {
                if (![waiter isKindOfClass:[waImageWaiter class]]) continue;
                if (waiter.owner == (__bridge void *)owner) waiter.cancelled = YES;
            }
        }
    });
}

- (void)sweepDiskIfNeeded {
    self.writesSinceSweep++;
    if (self.writesSinceSweep < 8) return;
    self.writesSinceSweep = 0;
    unsigned long long cap = self.diskCap;
    NSString *dir = waImageDirectory();
    [self.decodeQueue addOperationWithBlock:^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:NULL];
        if (files.count < 12) return;
        unsigned long long total = 0;
        NSMutableArray *entries = [NSMutableArray array];
        for (NSString *name in files) {
            NSString *path = [dir stringByAppendingPathComponent:name];
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
            unsigned long long size = [attrs fileSize];
            NSDate *date = [attrs fileModificationDate];
            total += size;
            [entries addObject:[NSDictionary dictionaryWithObjectsAndKeys:path, @"path", date ?: [NSDate distantPast], @"date", [NSNumber numberWithUnsignedLongLong:size], @"size", nil]];
        }
        if (total <= cap) return;
        [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [[a objectForKey:@"date"] compare:[b objectForKey:@"date"]];
        }];
        for (NSDictionary *entry in entries) {
            if (total <= cap) break;
            unsigned long long size = [[entry objectForKey:@"size"] unsignedLongLongValue];
            [fm removeItemAtPath:[entry objectForKey:@"path"] error:NULL];
            if (total > size) total -= size;
            else total = 0;
        }
    }];
}

- (unsigned long long)diskBytes {
    unsigned long long total = 0;
    NSString *dir = waImageDirectory();
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    for (NSString *name in files) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:[dir stringByAppendingPathComponent:name] error:NULL];
        total += [attrs fileSize];
    }
    return total;
}

- (void)clearMemory {
    [self.memory removeAllObjects];
}

- (void)clearDisk {
    [self.memory removeAllObjects];
    NSString *dir = waImageDirectory();
    [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
}

@end
