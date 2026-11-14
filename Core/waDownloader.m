#import "waDownloader.h"
#import "waDZAPI.h"
#import "waCrypto.h"
#import "waLog.h"
#import "waSession.h"
#import "waImageCache.h"
#import "waLyrics.h"
#import <UIKit/UIKit.h>

NSString * const waDownloaderDidChangeNotification = @"waDownloaderDidChangeNotification";
static NSString * const waDownloadSortKey = @"wave.downloadSort";

@interface waDownload ()
- (NSDictionary *)plist;
+ (waDownload *)downloadFromPlist:(NSDictionary *)dict;
@end

@implementation waDownload

- (NSDictionary *)plist {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (self.trackID.length) dict[@"trackID"] = self.trackID;
    if (self.fileName.length) dict[@"fileName"] = self.fileName;
    else if (self.filePath.length) dict[@"fileName"] = [self.filePath lastPathComponent];
    dict[@"state"] = @(self.state);
    dict[@"quality"] = @(self.quality);
    dict[@"addedAt"] = @(self.addedAt);
    dict[@"hasLyrics"] = @(self.hasLyrics);
    if (self.format.length) dict[@"format"] = self.format;
    NSDictionary *track = [self.track dictionary];
    if (track) dict[@"track"] = track;
    return dict;
}

+ (waDownload *)downloadFromPlist:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    waDownload *download = [[waDownload alloc] init];
    download.trackID = [dict[@"trackID"] isKindOfClass:[NSString class]] ? dict[@"trackID"] : nil;
    download.fileName = [dict[@"fileName"] isKindOfClass:[NSString class]] ? dict[@"fileName"] : nil;
    if (!download.fileName.length && [dict[@"path"] isKindOfClass:[NSString class]]) {
        download.fileName = [dict[@"path"] lastPathComponent];
    }
    download.state = (waDownloadState)[dict[@"state"] integerValue];
    download.quality = (waQuality)[dict[@"quality"] integerValue];
    download.addedAt = [dict[@"addedAt"] doubleValue];
    download.hasLyrics = [dict[@"hasLyrics"] boolValue];
    download.format = [dict[@"format"] isKindOfClass:[NSString class]] ? dict[@"format"] : nil;
    NSDictionary *trackDict = dict[@"track"];
    if ([trackDict isKindOfClass:[NSDictionary class]]) {
        download.track = [waTrack itemWithDictionary:trackDict kind:waTrackType];
        if (!download.trackID.length) download.trackID = download.track.identifier;
    }
    return download;
}

@end

@implementation waDownloadCollection

- (NSDictionary *)plist {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (self.identifier.length) dict[@"id"] = self.identifier;
    if (self.kind.length) dict[@"kind"] = self.kind;
    if (self.title.length) dict[@"title"] = self.title;
    if (self.artistName.length) dict[@"artistName"] = self.artistName;
    if (self.artworkURL.length) dict[@"artworkURL"] = self.artworkURL;
    if (self.trackIDs.count) dict[@"trackIDs"] = self.trackIDs;
    return dict;
}

+ (waDownloadCollection *)collectionFromPlist:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    waDownloadCollection *collection = [[waDownloadCollection alloc] init];
    collection.identifier = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : nil;
    collection.kind = [dict[@"kind"] isKindOfClass:[NSString class]] ? dict[@"kind"] : @"album";
    collection.title = [dict[@"title"] isKindOfClass:[NSString class]] ? dict[@"title"] : nil;
    collection.artistName = [dict[@"artistName"] isKindOfClass:[NSString class]] ? dict[@"artistName"] : nil;
    collection.artworkURL = [dict[@"artworkURL"] isKindOfClass:[NSString class]] ? dict[@"artworkURL"] : nil;
    collection.trackIDs = [dict[@"trackIDs"] isKindOfClass:[NSArray class]] ? dict[@"trackIDs"] : [NSArray array];
    if (!collection.identifier.length) return nil;
    return collection;
}

@end

@interface waDownloadTask : NSObject <NSURLConnectionDataDelegate>
@property (nonatomic, strong) waDownload *download;
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, strong) NSFileHandle *handle;
@property (nonatomic, strong) NSString *temporaryPath;
@property (nonatomic, assign) waCryptor *cryptor;
@property (nonatomic, assign) unsigned long chunkIndex;
@property (nonatomic, assign) BOOL decrypting;
@property (nonatomic, strong) NSMutableData *remainder;
- (void)start;
- (void)cancel;
- (void)failWithMessage:(NSString *)message;
- (void)finishWithSuccess:(BOOL)success message:(NSString *)message;
@end

@interface waDownloadCollection (Plist)
- (NSDictionary *)plist;
+ (waDownloadCollection *)collectionFromPlist:(NSDictionary *)dict;
@end

@interface waDownloader ()
@property (nonatomic, strong) NSMutableArray *items;
@property (nonatomic, strong) NSMutableDictionary *itemByID;
@property (nonatomic, strong) NSMutableArray *tasks;
@property (nonatomic, strong) NSMutableArray *collections;
@property (nonatomic, strong) NSString *directory;
@property (nonatomic, strong) NSOperationQueue *storeQueue;
@property (nonatomic, strong) NSOperationQueue *ioQueue;
@property (nonatomic, assign) BOOL lyricsBackfillBusy;
@property (nonatomic, assign) BOOL progressCoalesce;
@property (nonatomic, assign) BOOL booted;
@property (nonatomic, assign) unsigned long long cachedBytes;
@property (nonatomic, assign) BOOL cachedBytesValid;
- (void)bootIfNeeded;
- (void)postChange;
- (void)postProgress;
- (void)cancelDownload:(waDownload *)download notify:(BOOL)notify;
- (void)removeDownload:(waDownload *)download notify:(BOOL)notify;
- (void)finishTask:(waDownloadTask *)task;
- (void)migrateLegacyDirectories;
- (NSString *)pathForDownload:(waDownload *)download;
- (void)writeSidecar:(waDownload *)download;
- (NSString *)metaPathForTrackID:(NSString *)trackID;
- (void)downloadDidComplete:(waDownload *)download;
- (NSString *)mediaDirectory;
- (void)runIO:(void (^)(void))block;
- (NSArray *)orderAlbumIDs:(NSArray *)ids;
@end

@implementation waDownloadTask

- (void)start {
    waDownload *download = self.download;
    NSString *trackID = download.trackID;
    if (!trackID.length) { [self failWithMessage:@"Missing track id."]; return; }
    download.state = waDownloadResolving;
    [[waDownloader shared] postChange];

    __weak waDownloadTask *weakSelf = self;
    waTrack *track = download.track;
    if (!track.trackToken.length) {
        [[waSession shared] track:trackID completion:^(waTrack *resolved, NSError *error) {
            waDownloadTask *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error || !resolved.trackToken.length) { [strongSelf failWithMessage:@"Track unavailable."]; return; }
            if (strongSelf.download.track) [strongSelf.download.track mergeFrom:resolved];
            else strongSelf.download.track = resolved;
            [strongSelf resolveWithToken:resolved.trackToken];
        }];
    } else {
        [self resolveWithToken:track.trackToken];
    }
}

- (void)resolveWithToken:(NSString *)token {
    NSArray *formats = [waSession formatsForQuality:self.download.quality];
    __weak waDownloadTask *weakSelf = self;
    [[waDZAPI shared] signedURLForTrackToken:token formats:formats completion:^(NSString *url, NSString *format, NSError *error) {
        waDownloadTask *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error || !url.length) { [strongSelf failWithMessage:error.localizedDescription ?: @"No stream URL."]; return; }
        NSString *extension = [format isEqualToString:@"FLAC"] ? @"flac" : @"mp3";
        NSString *fileName = [NSString stringWithFormat:@"%@.%@", strongSelf.download.trackID, extension];
        NSString *finalPath = [[[waDownloader shared] mediaDirectory] stringByAppendingPathComponent:fileName];
        strongSelf.download.fileName = fileName;
        strongSelf.download.filePath = finalPath;
        strongSelf.download.format = extension;
        strongSelf.download.state = waDownloadDownloading;
        strongSelf.download.bytesReceived = 0;
        strongSelf.download.bytesExpected = 0;
        NSString *playable = [url hasPrefix:@"https://"] ? [@"http://" stringByAppendingString:[url substringFromIndex:8]] : url;
        [strongSelf beginWithURL:[NSURL URLWithString:playable] extension:extension];
    }];
}

- (void)beginWithURL:(NSURL *)url extension:(NSString *)extension {
    NSString *temp = [self.download.filePath stringByAppendingString:@".part"];
    self.temporaryPath = temp;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60.0];
    [request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    __weak waDownloadTask *weakSelf = self;
    [[waDownloader shared] runIO:^{
        waDownloadTask *task = weakSelf;
        if (!task || task.cancelledFlag) return;
        [[NSFileManager defaultManager] removeItemAtPath:temp error:NULL];
        if (![[NSFileManager defaultManager] createFileAtPath:temp contents:nil attributes:nil]) {
            [task failWithMessage:@"Could not create file."];
            return;
        }
        task.handle = [NSFileHandle fileHandleForWritingAtPath:temp];
        task.remainder = [NSMutableData data];
        task.chunkIndex = 0;
        task.cryptor = waCryptorCreate([task.download.trackID UTF8String]);
        task.decrypting = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            waDownloadTask *armed = weakSelf;
            if (!armed || armed.cancelledFlag) return;
            armed.connection = [[NSURLConnection alloc] initWithRequest:request delegate:armed startImmediately:YES];
            [[waLog shared] log:@"download start %@ (%@)", armed.download.trackID, extension];
        });
    }];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    (void)connection;
    NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSInteger code = http ? http.statusCode : 200;
    long long expected = response.expectedContentLength;
    __weak waDownloadTask *weakSelf = self;
    [[waDownloader shared] runIO:^{
        waDownloadTask *task = weakSelf;
        if (!task || task.cancelledFlag) return;
        if (code < 200 || code >= 300) {
            [task failWithMessage:[NSString stringWithFormat:@"HTTP %d", (int)code]];
            return;
        }
        if (expected > 0) task.download.bytesExpected = (unsigned long long)expected;
    }];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    (void)connection;
    if (!data.length) return;
    NSData *chunk = [data copy];
    __weak waDownloadTask *weakSelf = self;
    [[waDownloader shared] runIO:^{
        [weakSelf consumeChunk:chunk];
    }];
}

- (void)consumeChunk:(NSData *)data {
    if (self.cancelledFlag || !self.handle || !data.length) return;
    [self.remainder appendData:data];
    NSUInteger offset = 0;
    NSUInteger length = self.remainder.length;
    NSMutableData *plain = [NSMutableData dataWithCapacity:length];
    while (length - offset >= WA_STRIPE) {
        uint8_t stripe[WA_STRIPE];
        [self.remainder getBytes:stripe range:NSMakeRange(offset, WA_STRIPE)];
        if (self.decrypting && waCryptorStripe(self.cryptor, self.chunkIndex, stripe, WA_STRIPE) != 0) {
            [self failWithMessage:@"Decrypt failed."];
            return;
        }
        [plain appendBytes:stripe length:WA_STRIPE];
        offset += WA_STRIPE;
        self.chunkIndex++;
    }
    if (offset) [self.remainder replaceBytesInRange:NSMakeRange(0, offset) withBytes:NULL length:0];
    if (!plain.length) return;
    @try { [self.handle writeData:plain]; } @catch (NSException *e) { [self failWithMessage:e.reason]; return; }
    self.download.bytesReceived += plain.length;
    if (self.download.bytesExpected > 0) {
        self.download.progress = (float)((double)self.download.bytesReceived / (double)self.download.bytesExpected);
        [[waDownloader shared] postProgress];
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    (void)connection;
    __weak waDownloadTask *weakSelf = self;
    [[waDownloader shared] runIO:^{
        waDownloadTask *task = weakSelf;
        if (!task || task.cancelledFlag) return;
        if (task.remainder.length && task.decrypting) {
            NSMutableData *tail = [NSMutableData dataWithData:task.remainder];
            waCryptorStripe(task.cryptor, task.chunkIndex, tail.mutableBytes, tail.length);
            @try { [task.handle writeData:tail]; } @catch (NSException *e) { (void)e; }
            task.download.bytesReceived += tail.length;
            [task.remainder setLength:0];
        }
        [task finishWithSuccess:YES message:nil];
    }];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    (void)connection;
    NSString *message = error.localizedDescription.length ? error.localizedDescription : @"Network error.";
    __weak waDownloadTask *weakSelf = self;
    [[waDownloader shared] runIO:^{
        [weakSelf failWithMessage:message];
    }];
}

- (void)finishWithSuccess:(BOOL)success message:(NSString *)message {
    if (self.handle) { @try { [self.handle closeFile]; } @catch (NSException *e) { (void)e; } self.handle = nil; }
    if (success) {
        [[NSFileManager defaultManager] removeItemAtPath:self.download.filePath error:NULL];
        NSError *moveError = nil;
        if ([[NSFileManager defaultManager] moveItemAtPath:self.temporaryPath toPath:self.download.filePath error:&moveError]) {
            self.download.state = waDownloadCompleted;
            self.download.progress = 1.0f;
        } else {
            self.download.state = waDownloadFailed;
            self.download.errorMessage = moveError.localizedDescription;
        }
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:self.temporaryPath error:NULL];
        self.download.state = waDownloadFailed;
        self.download.errorMessage = message;
    }
    if (self.cryptor) { waCryptorFree(self.cryptor); self.cryptor = NULL; }
    [[waDownloader shared] finishTask:self];
}

- (void)failWithMessage:(NSString *)message {
    if (self.cancelledFlag) return;
    [self finishWithSuccess:NO message:message];
}

- (BOOL)cancelledFlag { return self.download.state == waDownloadCancelled; }

- (void)cancel {
    [self.connection cancel];
    self.connection = nil;
    self.download.state = waDownloadCancelled;
    NSString *temp = self.temporaryPath;
    __weak waDownloadTask *weakSelf = self;
    [[waDownloader shared] runIO:^{
        waDownloadTask *task = weakSelf;
        if (task.handle) { @try { [task.handle closeFile]; } @catch (NSException *e) { (void)e; } task.handle = nil; }
        if (temp.length) [[NSFileManager defaultManager] removeItemAtPath:temp error:NULL];
        if (task.cryptor) { waCryptorFree(task.cryptor); task.cryptor = NULL; }
    }];
}

@end

@implementation waDownloader

+ (waDownloader *)shared {
    static waDownloader *downloader;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ downloader = [[waDownloader alloc] init]; });
    [downloader bootIfNeeded];
    return downloader;
}

- (id)init {
    if ((self = [super init])) {
        _items = [[NSMutableArray alloc] init];
        _itemByID = [[NSMutableDictionary alloc] init];
        _tasks = [[NSMutableArray alloc] init];
        _collections = [[NSMutableArray alloc] init];
        _storeQueue = [[NSOperationQueue alloc] init];
        _storeQueue.name = @"wave.download.store";
        _storeQueue.maxConcurrentOperationCount = 1;
        _ioQueue = [[NSOperationQueue alloc] init];
        _ioQueue.name = @"wave.download.io";
        _ioQueue.maxConcurrentOperationCount = 1;
        NSInteger stored = [[NSUserDefaults standardUserDefaults] integerForKey:@"wave.downloadParallel"];
        _maximumParallel = stored > 0 ? (NSUInteger)stored : 2;
        _sort = (waDownloadSort)[[NSUserDefaults standardUserDefaults] integerForKey:waDownloadSortKey];
        NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        _directory = [[docs objectAtIndex:0] stringByAppendingPathComponent:@"WaveDownloads"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:NULL];
        [self ensureLayout];
        [self migrateLegacyDirectories];
        [self migrateFlatIntoLayout];
        [self load];
        [self rebuildAlbumCollections];
    }
    return self;
}

- (void)bootIfNeeded {
    if (self.booted) return;
    self.booted = YES;
    [self refreshActivity];
    [self startQueued];
    [self backfillLyricsIfIdle];
}

- (NSString *)directory { return _directory; }

- (NSString *)mediaDirectory { return [_directory stringByAppendingPathComponent:@"media"]; }
- (NSString *)metaDirectory { return [_directory stringByAppendingPathComponent:@"meta"]; }
- (NSString *)artDirectory { return [_directory stringByAppendingPathComponent:@"art"]; }
- (NSString *)lyricsDirectory { return [_directory stringByAppendingPathComponent:@"lyrics"]; }
- (NSString *)collectionsDirectory { return [_directory stringByAppendingPathComponent:@"collections"]; }

- (void)ensureLayout {
    NSFileManager *manager = [NSFileManager defaultManager];
    [manager createDirectoryAtPath:[self mediaDirectory] withIntermediateDirectories:YES attributes:nil error:NULL];
    [manager createDirectoryAtPath:[self metaDirectory] withIntermediateDirectories:YES attributes:nil error:NULL];
    [manager createDirectoryAtPath:[self artDirectory] withIntermediateDirectories:YES attributes:nil error:NULL];
    [manager createDirectoryAtPath:[self lyricsDirectory] withIntermediateDirectories:YES attributes:nil error:NULL];
    [manager createDirectoryAtPath:[self collectionsDirectory] withIntermediateDirectories:YES attributes:nil error:NULL];
}

- (NSArray *)downloads { return [self.items copy]; }

- (NSString *)plistPath {
    return [_directory stringByAppendingPathComponent:@"index.plist"];
}

- (NSString *)metaPathForTrackID:(NSString *)trackID {
    if (!trackID.length) return nil;
    return [[self metaDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", trackID]];
}

- (NSString *)lyricsPathForTrackID:(NSString *)trackID {
    if (!trackID.length) return nil;
    return [[self lyricsDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", trackID]];
}

- (NSString *)artPathForAlbumID:(NSString *)albumID {
    if (!albumID.length) return nil;
    return [[self artDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.jpg", albumID]];
}

- (NSString *)artPathForTrackID:(NSString *)trackID {
    if (!trackID.length) return nil;
    return [[self artDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"track-%@.jpg", trackID]];
}

- (NSString *)pathForDownload:(waDownload *)download {
    if (download.filePath.length && [[NSFileManager defaultManager] fileExistsAtPath:download.filePath]) return download.filePath;
    if (download.fileName.length) {
        NSString *media = [[self mediaDirectory] stringByAppendingPathComponent:download.fileName];
        if ([[NSFileManager defaultManager] fileExistsAtPath:media]) {
            download.filePath = media;
            return media;
        }
        NSString *legacy = [_directory stringByAppendingPathComponent:download.fileName];
        if ([[NSFileManager defaultManager] fileExistsAtPath:legacy]) {
            download.filePath = legacy;
            return legacy;
        }
        download.filePath = media;
        return media;
    }
    return download.filePath;
}

- (void)migrateLegacyDirectories {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableArray *oldDirs = [NSMutableArray array];
    NSArray *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (caches.count) [oldDirs addObject:[[caches objectAtIndex:0] stringByAppendingPathComponent:@"Downloads"]];
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.count) [oldDirs addObject:[[docs objectAtIndex:0] stringByAppendingPathComponent:@"Downloads"]];
    for (NSString *oldDir in oldDirs) {
        if ([oldDir isEqualToString:_directory]) continue;
        BOOL isDir = NO;
        if (![manager fileExistsAtPath:oldDir isDirectory:&isDir] || !isDir) continue;
        NSArray *names = [manager contentsOfDirectoryAtPath:oldDir error:NULL];
        for (NSString *name in names) {
            if (![name isKindOfClass:[NSString class]] || [name hasPrefix:@"."]) continue;
            NSString *from = [oldDir stringByAppendingPathComponent:name];
            NSString *to = [_directory stringByAppendingPathComponent:name];
            if ([manager fileExistsAtPath:to]) continue;
            [manager moveItemAtPath:from toPath:to error:NULL];
        }
    }
}

- (void)migrateFlatIntoLayout {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *names = [manager contentsOfDirectoryAtPath:_directory error:NULL];
    for (NSString *name in names) {
        if (![name isKindOfClass:[NSString class]]) continue;
        NSString *from = [_directory stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if ([manager fileExistsAtPath:from isDirectory:&isDir] && isDir) continue;
        NSString *lower = [name lowercaseString];
        if ([lower hasSuffix:@".mp3"] || [lower hasSuffix:@".flac"]) {
            NSString *to = [[self mediaDirectory] stringByAppendingPathComponent:name];
            if (![manager fileExistsAtPath:to]) [manager moveItemAtPath:from toPath:to error:NULL];
        } else if ([lower hasSuffix:@".meta.plist"]) {
            NSString *trackID = [[name stringByDeletingPathExtension] stringByDeletingPathExtension];
            if (!trackID.length) continue;
            NSString *to = [self metaPathForTrackID:trackID];
            if (![manager fileExistsAtPath:to]) [manager moveItemAtPath:from toPath:to error:NULL];
            else [manager removeItemAtPath:from error:NULL];
        }
    }
}

- (void)writeSidecar:(waDownload *)download {
    NSDictionary *plist = [download plist];
    NSString *path = [self metaPathForTrackID:download.trackID];
    if (!path || !plist) return;
    [self.storeQueue addOperationWithBlock:^{
        [plist writeToFile:path atomically:YES];
    }];
}

- (NSString *)collectionPath:(waDownloadCollection *)collection {
    if (!collection.identifier.length) return nil;
    NSString *kind = [collection.kind isEqualToString:@"playlist"] ? @"playlist" : @"album";
    return [[self collectionsDirectory] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.plist", kind, collection.identifier]];
}

- (void)writeCollection:(waDownloadCollection *)collection {
    NSString *path = [self collectionPath:collection];
    NSDictionary *plist = [collection plist];
    if (!path || !plist) return;
    [self.storeQueue addOperationWithBlock:^{
        [plist writeToFile:path atomically:YES];
    }];
}

- (void)loadCollections {
    [self.collections removeAllObjects];
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *names = [manager contentsOfDirectoryAtPath:[self collectionsDirectory] error:NULL];
    for (NSString *name in names) {
        if (![name isKindOfClass:[NSString class]] || ![[name lowercaseString] hasSuffix:@".plist"]) continue;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[[self collectionsDirectory] stringByAppendingPathComponent:name]];
        waDownloadCollection *collection = [waDownloadCollection collectionFromPlist:dict];
        if (collection) [self.collections addObject:collection];
    }
}

- (void)load {
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];
    NSArray *stored = [NSArray arrayWithContentsOfFile:[self plistPath]];
    for (NSDictionary *dict in stored) {
        waDownload *download = [waDownload downloadFromPlist:dict];
        if (!download.trackID.length) continue;
        [self pathForDownload:download];
        byID[download.trackID] = download;
    }

    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *metaNames = [manager contentsOfDirectoryAtPath:[self metaDirectory] error:NULL];
    for (NSString *name in metaNames) {
        if (![name isKindOfClass:[NSString class]] || ![[name lowercaseString] hasSuffix:@".plist"]) continue;
        NSString *trackID = [name stringByDeletingPathExtension];
        if (!trackID.length || byID[trackID]) continue;
        NSDictionary *sidecar = [NSDictionary dictionaryWithContentsOfFile:[[self metaDirectory] stringByAppendingPathComponent:name]];
        waDownload *download = [waDownload downloadFromPlist:sidecar];
        if (!download) continue;
        if (!download.trackID.length) download.trackID = trackID;
        byID[trackID] = download;
    }

    NSMutableArray *audioDirs = [NSMutableArray arrayWithObject:[self mediaDirectory]];
    [audioDirs addObject:_directory];
    for (NSString *dir in audioDirs) {
        NSArray *names = [manager contentsOfDirectoryAtPath:dir error:NULL];
        for (NSString *name in names) {
            if (![name isKindOfClass:[NSString class]]) continue;
            NSString *lower = [name lowercaseString];
            if (![lower hasSuffix:@".mp3"] && ![lower hasSuffix:@".flac"]) continue;
            NSString *trackID = [name stringByDeletingPathExtension];
            if (!trackID.length) continue;
            waDownload *download = byID[trackID];
            if (!download) {
                download = [[waDownload alloc] init];
                download.trackID = trackID;
                waTrack *track = [[waTrack alloc] init];
                track.identifier = trackID;
                track.title = trackID;
                download.track = track;
                byID[trackID] = download;
            }
            download.fileName = name;
            download.filePath = [dir stringByAppendingPathComponent:name];
            download.format = [lower hasSuffix:@".flac"] ? @"flac" : @"mp3";
            download.state = waDownloadCompleted;
            download.progress = 1.0f;
        }
    }

    [self.items removeAllObjects];
    [self.itemByID removeAllObjects];
    for (waDownload *download in [byID allValues]) {
        NSString *path = [self pathForDownload:download];
        BOOL exists = path.length && [manager fileExistsAtPath:path];
        if (download.state == waDownloadCompleted && !exists) download.state = waDownloadFailed;
        if (download.state == waDownloadDownloading || download.state == waDownloadResolving) download.state = waDownloadQueued;
        if (download.state == waDownloadCancelled && !exists) continue;
        NSString *lyricsPath = [self lyricsPathForTrackID:download.trackID];
        download.hasLyrics = lyricsPath.length && [manager fileExistsAtPath:lyricsPath];
        [self.items addObject:download];
        if (download.trackID.length) self.itemByID[download.trackID] = download;
    }
    [self loadCollections];
    [self persist];
}

- (void)runIO:(void (^)(void))block {
    if (!block) return;
    [self.ioQueue addOperationWithBlock:^{
        [NSThread setThreadPriority:0.2];
        block();
    }];
}

- (void)persist {
    NSMutableArray *list = [NSMutableArray arrayWithCapacity:self.items.count];
    for (waDownload *download in self.items) {
        NSDictionary *plist = [download plist];
        if (plist) [list addObject:plist];
    }
    NSString *path = [self plistPath];
    [self.storeQueue addOperationWithBlock:^{
        [list writeToFile:path atomically:YES];
    }];
}

- (void)refreshActivity {
    BOOL busy = [self pendingCount] > 0;
    dispatch_block_t apply = ^{
        [UIApplication sharedApplication].networkActivityIndicatorVisible = busy;
    };
    if ([NSThread isMainThread]) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

- (void)emitChange:(BOOL)progressOnly {
    [self refreshActivity];
    NSDictionary *info = progressOnly ? [NSDictionary dictionaryWithObject:@YES forKey:@"progress"] : nil;
    [[NSNotificationCenter defaultCenter] postNotificationName:waDownloaderDidChangeNotification object:self userInfo:info];
}

- (void)postChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.progressCoalesce = NO;
        [self emitChange:NO];
    });
}

- (void)postProgress {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressCoalesce) return;
        self.progressCoalesce = YES;
        __weak waDownloader *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            waDownloader *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.progressCoalesce = NO;
            [strongSelf emitChange:YES];
        });
    });
}

- (void)enqueueTrack:(waTrack *)track quality:(waQuality)quality {
    [self enqueueTracks:track ? [NSArray arrayWithObject:track] : nil quality:quality collection:nil];
}

- (void)enqueueTracks:(NSArray *)tracks quality:(waQuality)quality collection:(waDownloadCollection *)collection {
    if (!tracks.count) return;
    BOOL albumOrder = [collection.kind isEqualToString:@"album"];
    NSArray *source = albumOrder ? waSortedAlbumTracks(tracks) : tracks;
    if (collection.identifier.length) {
        NSMutableArray *ids = [NSMutableArray array];
        for (waTrack *track in source) {
            if (![track isKindOfClass:[waTrack class]] || !track.identifier.length) continue;
            [ids addObject:track.identifier];
        }
        collection.trackIDs = ids;
        [self upsertCollection:collection];
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    for (waTrack *track in source) {
        if (![track isKindOfClass:[waTrack class]] || !track.identifier.length) continue;
        waDownload *existing = self.itemByID[track.identifier];
        if (existing) {
            if (existing.state == waDownloadCompleted) {
                [self attachTrack:track toAlbumCollection:YES];
                continue;
            }
            if (existing.state != waDownloadFailed && existing.state != waDownloadCancelled) continue;
        }
        waDownload *download = existing;
        if (!download) {
            download = [[waDownload alloc] init];
            download.trackID = track.identifier;
            [self.items addObject:download];
            self.itemByID[track.identifier] = download;
        }
        download.track = track;
        download.quality = quality;
        download.state = waDownloadQueued;
        download.progress = 0.0f;
        download.errorMessage = nil;
        download.addedAt = now;
        [self writeSidecar:download];
        if (!collection) [self attachTrack:track toAlbumCollection:NO];
    }
    [self persist];
    [self postChange];
    [self startQueued];
}

- (void)upsertCollection:(waDownloadCollection *)collection {
    if (!collection.identifier.length) return;
    for (NSUInteger i = 0; i < self.collections.count; i++) {
        waDownloadCollection *existing = [self.collections objectAtIndex:i];
        if ([existing.identifier isEqualToString:collection.identifier] && [existing.kind isEqualToString:collection.kind]) {
            if (collection.title.length) existing.title = collection.title;
            if (collection.artistName.length) existing.artistName = collection.artistName;
            if (collection.artworkURL.length) existing.artworkURL = collection.artworkURL;
            NSMutableArray *ids = [NSMutableArray arrayWithArray:existing.trackIDs ?: [NSArray array]];
            for (NSString *trackID in collection.trackIDs) {
                if ([trackID isKindOfClass:[NSString class]] && ![ids containsObject:trackID]) [ids addObject:trackID];
            }
            existing.trackIDs = [existing.kind isEqualToString:@"album"] ? [self orderAlbumIDs:ids] : ids;
            [self writeCollection:existing];
            return;
        }
    }
    [self.collections addObject:collection];
    [self writeCollection:collection];
}

- (void)attachTrack:(waTrack *)track toAlbumCollection:(BOOL)requireExisting {
    if (!track.albumIdentifier.length) return;
    waDownloadCollection *found = nil;
    for (waDownloadCollection *collection in self.collections) {
        if ([collection.kind isEqualToString:@"playlist"]) continue;
        if ([collection.identifier isEqualToString:track.albumIdentifier]) { found = collection; break; }
    }
    if (!found) {
        if (requireExisting) return;
        NSUInteger peers = 0;
        for (waDownload *download in self.items) {
            if ([download.track.albumIdentifier isEqualToString:track.albumIdentifier]) peers++;
        }
        if (peers < 2) return;
        found = [[waDownloadCollection alloc] init];
        found.identifier = track.albumIdentifier;
        found.kind = @"album";
        found.title = track.albumTitle;
        found.artistName = track.artistName;
        found.artworkURL = [track bestArtworkURL];
        found.trackIDs = [NSArray array];
        [self.collections addObject:found];
    }
    NSMutableArray *ids = [NSMutableArray arrayWithArray:found.trackIDs ?: [NSArray array]];
    if (track.identifier.length && ![ids containsObject:track.identifier]) [ids addObject:track.identifier];
    found.trackIDs = [self orderAlbumIDs:ids];
    if (!found.title.length) found.title = track.albumTitle;
    if (!found.artistName.length) found.artistName = track.artistName;
    if (!found.artworkURL.length) found.artworkURL = [track bestArtworkURL];
    [self writeCollection:found];
}

- (void)rebuildAlbumCollections {
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    NSMutableDictionary *sample = [NSMutableDictionary dictionary];
    for (waDownload *download in self.items) {
        if (download.state != waDownloadCompleted) continue;
        NSString *albumID = download.track.albumIdentifier;
        if (!albumID.length) continue;
        NSMutableArray *ids = groups[albumID];
        if (!ids) {
            ids = [NSMutableArray array];
            groups[albumID] = ids;
            sample[albumID] = download.track;
        }
        if (download.trackID.length && ![ids containsObject:download.trackID]) [ids addObject:download.trackID];
    }
    for (NSString *albumID in groups) {
        NSArray *ids = groups[albumID];
        if (ids.count < 2) continue;
        waTrack *track = sample[albumID];
        waDownloadCollection *collection = [[waDownloadCollection alloc] init];
        collection.identifier = albumID;
        collection.kind = @"album";
        collection.title = track.albumTitle;
        collection.artistName = track.artistName;
        collection.artworkURL = [track bestArtworkURL];
        collection.trackIDs = [self orderAlbumIDs:ids];
        [self upsertCollection:collection];
    }
}

- (void)startQueued {
    NSUInteger active = 0;
    for (waDownloadTask *task in self.tasks) if (task.download.state == waDownloadDownloading || task.download.state == waDownloadResolving) active++;
    for (waDownload *download in self.items) {
        if (active >= self.maximumParallel) break;
        if (download.state != waDownloadQueued) continue;
        waDownloadTask *task = [[waDownloadTask alloc] init];
        task.download = download;
        [self.tasks addObject:task];
        active++;
        [task start];
    }
}

- (void)finishTask:(waDownloadTask *)task {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishTask:task]; });
        return;
    }
    waDownload *download = task.download;
    [self.tasks removeObject:task];
    [self writeSidecar:download];
    [self persist];
    self.cachedBytesValid = NO;
    if (download.state == waDownloadCompleted) [self downloadDidComplete:download];
    [self postChange];
    [self startQueued];
    [self backfillLyricsIfIdle];
}

- (void)downloadDidComplete:(waDownload *)download {
    [self attachTrack:download.track toAlbumCollection:NO];
    [self fetchArtworkForDownload:download];
    [self fetchLyricsForDownload:download];
}

- (void)fetchArtworkForDownload:(waDownload *)download {
    waTrack *track = download.track;
    NSString *albumID = track.albumIdentifier;
    NSString *dest = albumID.length ? [self artPathForAlbumID:albumID] : [self artPathForTrackID:download.trackID];
    if (!dest.length) return;
    if ([[NSFileManager defaultManager] fileExistsAtPath:dest]) return;
    NSString *url = [track bestArtworkURL];
    if (!url.length) return;
    NSString *cached = [[waImageCache shared] sourcePathForURL:url];
    if (cached.length) {
        [[NSFileManager defaultManager] copyItemAtPath:cached toPath:dest error:NULL];
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                           cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                       timeoutInterval:18.0];
    [request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    [NSURLConnection sendAsynchronousRequest:request queue:self.storeQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        (void)response;
        if (error || data.length < 64) return;
        [data writeToFile:dest atomically:YES];
    }];
}

- (void)fetchLyricsForDownload:(waDownload *)download {
    if (download.hasLyrics) return;
    waTrack *track = download.track;
    if (!track) return;
    __weak waDownloader *weakSelf = self;
    [[waSession shared] lyricsForTrack:track completion:^(waLyrics *lyrics, NSError *error) {
        (void)error;
        waDownloader *strongSelf = weakSelf;
        if (!strongSelf || !lyrics) return;
        [strongSelf storeLyrics:lyrics forTrackID:download.trackID];
    }];
}

- (void)backfillLyricsIfIdle {
    if (self.lyricsBackfillBusy) return;
    if (self.tasks.count) return;
    waDownload *next = nil;
    for (waDownload *download in self.items) {
        if (download.state != waDownloadCompleted) continue;
        if (download.hasLyrics) continue;
        NSString *path = [self lyricsPathForTrackID:download.trackID];
        if (path.length && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            download.hasLyrics = YES;
            continue;
        }
        next = download;
        break;
    }
    if (!next) return;
    self.lyricsBackfillBusy = YES;
    __weak waDownloader *weakSelf = self;
    [[waSession shared] lyricsForTrack:next.track completion:^(waLyrics *lyrics, NSError *error) {
        (void)error;
        dispatch_async(dispatch_get_main_queue(), ^{
            waDownloader *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (lyrics) [strongSelf storeLyrics:lyrics forTrackID:next.trackID];
            else next.hasLyrics = YES;
            strongSelf.lyricsBackfillBusy = NO;
            [strongSelf backfillLyricsIfIdle];
        });
    }];
}

- (void)storeLyrics:(waLyrics *)lyrics forTrackID:(NSString *)trackID {
    if (!lyrics || !trackID.length) return;
    if (![self isDownloadedTrackID:trackID] && ![self itemForTrackID:trackID]) return;
    NSString *path = [self lyricsPathForTrackID:trackID];
    if (!path.length) return;
    [[lyrics plist] writeToFile:path atomically:YES];
    waDownload *download = [self itemForTrackID:trackID];
    if (download) {
        download.hasLyrics = YES;
        [self writeSidecar:download];
        [self persist];
    }
}

- (waDownload *)itemForTrackID:(NSString *)trackID {
    if (!trackID.length) return nil;
    return self.itemByID[trackID];
}

- (waLyrics *)localLyricsForTrackID:(NSString *)trackID {
    NSString *path = [self lyricsPathForTrackID:trackID];
    if (!path.length) return nil;
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!plist) return nil;
    return [waLyrics lyricsFromPlist:plist];
}

- (NSString *)localArtworkPathForAlbumID:(NSString *)albumID {
    NSString *path = [self artPathForAlbumID:albumID];
    if (path.length && [[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    return nil;
}

- (NSString *)localArtworkPathForTrack:(waTrack *)track {
    if (!track) return nil;
    NSString *album = [self localArtworkPathForAlbumID:track.albumIdentifier];
    if (album.length) return album;
    NSString *path = [self artPathForTrackID:track.identifier];
    if (path.length && [[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    return nil;
}

- (void)cancelDownload:(waDownload *)download {
    [self cancelDownload:download notify:YES];
}

- (void)cancelDownload:(waDownload *)download notify:(BOOL)notify {
    for (waDownloadTask *task in [self.tasks copy]) {
        if (task.download == download) {
            [task cancel];
            [self.tasks removeObject:task];
        }
    }
    download.state = waDownloadCancelled;
    if (notify) {
        [self persist];
        [self postChange];
        [self startQueued];
    }
}

- (void)removeDownload:(waDownload *)download {
    [self removeDownload:download notify:YES];
}

- (void)removeDownload:(waDownload *)download notify:(BOOL)notify {
    [self cancelDownload:download notify:NO];
    NSString *path = [self pathForDownload:download];
    NSString *meta = [self metaPathForTrackID:download.trackID];
    NSString *lyrics = [self lyricsPathForTrackID:download.trackID];
    [self.storeQueue addOperationWithBlock:^{
        NSFileManager *manager = [NSFileManager defaultManager];
        if (path.length) [manager removeItemAtPath:path error:NULL];
        if (meta.length) [manager removeItemAtPath:meta error:NULL];
        if (lyrics.length) [manager removeItemAtPath:lyrics error:NULL];
    }];
    NSString *albumID = download.track.albumIdentifier;
    if (download.trackID.length) [self.itemByID removeObjectForKey:download.trackID];
    [self.items removeObject:download];
    self.cachedBytesValid = NO;
    [self dropTrackID:download.trackID fromCollectionsAndPruneArt:albumID trackArt:download.trackID];
    if (notify) {
        [self persist];
        [self postChange];
        [self startQueued];
    }
}

- (void)dropTrackID:(NSString *)trackID fromCollectionsAndPruneArt:(NSString *)albumID trackArt:(NSString *)artTrackID {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableArray *dead = [NSMutableArray array];
    for (waDownloadCollection *collection in self.collections) {
        if (![collection.trackIDs containsObject:trackID]) continue;
        NSMutableArray *ids = [NSMutableArray array];
        for (NSString *item in collection.trackIDs) if (![item isEqualToString:trackID]) [ids addObject:item];
        collection.trackIDs = ids;
        if (!ids.count) {
            [dead addObject:collection];
            NSString *path = [self collectionPath:collection];
            if (path.length) [manager removeItemAtPath:path error:NULL];
        } else {
            [self writeCollection:collection];
        }
    }
    [self.collections removeObjectsInArray:dead];
    if (artTrackID.length) {
        NSString *trackArt = [self artPathForTrackID:artTrackID];
        if (trackArt.length) [manager removeItemAtPath:trackArt error:NULL];
    }
    if (albumID.length && ![self albumIDStillReferenced:albumID]) {
        NSString *art = [self artPathForAlbumID:albumID];
        if (art.length) [manager removeItemAtPath:art error:NULL];
    }
}

- (BOOL)albumIDStillReferenced:(NSString *)albumID {
    for (waDownload *download in self.items) {
        if ([download.track.albumIdentifier isEqualToString:albumID]) return YES;
    }
    return NO;
}

- (void)removeCollection:(waDownloadCollection *)collection {
    if (!collection) return;
    NSArray *ids = [collection.trackIDs copy];
    for (NSString *trackID in ids) {
        waDownload *download = [self itemForTrackID:trackID];
        if (download) [self removeDownload:download notify:NO];
    }
    NSString *path = [self collectionPath:collection];
    if (path.length) {
        [self.storeQueue addOperationWithBlock:^{
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        }];
    }
    [self.collections removeObject:collection];
    [self persist];
    [self postChange];
    [self startQueued];
}

- (void)retryDownload:(waDownload *)download {
    download.state = waDownloadQueued;
    download.progress = 0.0f;
    download.errorMessage = nil;
    [self persist];
    [self postChange];
    [self startQueued];
}

- (BOOL)isDownloadedTrackID:(NSString *)trackID {
    if (!trackID.length) return NO;
    waDownload *download = self.itemByID[trackID];
    return download.state == waDownloadCompleted;
}

- (NSString *)localPathForTrackID:(NSString *)trackID {
    if (!trackID.length) return nil;
    waDownload *download = self.itemByID[trackID];
    if (download.state != waDownloadCompleted) return nil;
    NSString *path = [self pathForDownload:download];
    if (path.length && [[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    return nil;
}

- (unsigned long long)downloadedBytes {
    if (self.cachedBytesValid) return self.cachedBytes;
    unsigned long long total = 0;
    NSFileManager *manager = [NSFileManager defaultManager];
    for (waDownload *download in self.items) {
        if (download.state != waDownloadCompleted) continue;
        NSString *path = download.filePath.length ? download.filePath : [self pathForDownload:download];
        NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];
        total += [attributes fileSize];
    }
    self.cachedBytes = total;
    self.cachedBytesValid = YES;
    return total;
}

- (void)setSort:(waDownloadSort)sort {
    _sort = sort;
    [[NSUserDefaults standardUserDefaults] setInteger:sort forKey:waDownloadSortKey];
    [self postChange];
}

- (NSArray *)sortedCopies:(NSArray *)list {
    if (self.sort == waDownloadSortRecent) {
        return [list sortedArrayUsingComparator:^NSComparisonResult(waDownload *a, waDownload *b) {
            if (a.addedAt < b.addedAt) return NSOrderedDescending;
            if (a.addedAt > b.addedAt) return NSOrderedAscending;
            return NSOrderedSame;
        }];
    }
    return [list sortedArrayUsingComparator:^NSComparisonResult(waDownload *a, waDownload *b) {
        NSString *left = nil;
        NSString *right = nil;
        if (self.sort == waDownloadSortArtist) {
            left = a.track.artistName.length ? a.track.artistName : @"";
            right = b.track.artistName.length ? b.track.artistName : @"";
        } else {
            left = a.track.title.length ? a.track.title : a.trackID;
            right = b.track.title.length ? b.track.title : b.trackID;
        }
        NSComparisonResult order = [left localizedCaseInsensitiveCompare:right];
        if (order != NSOrderedSame) return order;
        NSString *lt = a.track.title.length ? a.track.title : @"";
        NSString *rt = b.track.title.length ? b.track.title : @"";
        return [lt localizedCaseInsensitiveCompare:rt];
    }];
}

- (NSArray *)activeDownloads {
    NSMutableArray *list = [NSMutableArray array];
    for (waDownload *download in self.items) {
        if (download.state == waDownloadQueued || download.state == waDownloadResolving || download.state == waDownloadDownloading || download.state == waDownloadFailed) {
            [list addObject:download];
        }
    }
    return list;
}

- (NSArray *)completedDownloads {
    NSMutableArray *list = [NSMutableArray array];
    for (waDownload *download in self.items) {
        if (download.state == waDownloadCompleted) [list addObject:download];
    }
    return [self sortedCopies:list];
}

- (NSArray *)completedTracks {
    NSMutableArray *tracks = [NSMutableArray array];
    for (waDownload *download in [self completedDownloads]) {
        if ([download.track isKindOfClass:[waTrack class]]) [tracks addObject:download.track];
    }
    return tracks;
}

- (NSArray *)collectionsOfKind:(NSString *)kind {
    NSMutableArray *list = [NSMutableArray array];
    for (waDownloadCollection *collection in self.collections) {
        if ([collection.kind isEqualToString:kind] && collection.trackIDs.count) [list addObject:collection];
    }
    return list;
}

- (NSArray *)albumCollections { return [self collectionsOfKind:@"album"]; }
- (NSArray *)playlistCollections { return [self collectionsOfKind:@"playlist"]; }

- (NSArray *)orderAlbumIDs:(NSArray *)ids {
    if (ids.count < 2) return ids ?: [NSArray array];
    NSMutableArray *known = [NSMutableArray array];
    NSMutableArray *unknown = [NSMutableArray array];
    for (NSString *trackID in ids) {
        if (![trackID isKindOfClass:[NSString class]] || !trackID.length) continue;
        waDownload *download = [self itemForTrackID:trackID];
        if ([download.track isKindOfClass:[waTrack class]]) [known addObject:download.track];
        else [unknown addObject:trackID];
    }
    NSArray *sorted = waSortedAlbumTracks(known);
    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:ids.count];
    for (waTrack *track in sorted) {
        if (track.identifier.length) [ordered addObject:track.identifier];
    }
    [ordered addObjectsFromArray:unknown];
    return ordered;
}

- (NSArray *)tracksForCollection:(waDownloadCollection *)collection {
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSString *trackID in collection.trackIDs) {
        waDownload *download = [self itemForTrackID:trackID];
        if (download.state == waDownloadCompleted && [download.track isKindOfClass:[waTrack class]]) [tracks addObject:download.track];
    }
    if ([collection.kind isEqualToString:@"album"]) return waSortedAlbumTracks(tracks);
    return tracks;
}

- (waAlbum *)albumForCollection:(waDownloadCollection *)collection {
    waAlbum *album = [[waAlbum alloc] init];
    album.identifier = collection.identifier;
    album.title = collection.title.length ? collection.title : @"Album";
    album.artistName = collection.artistName;
    album.artworkURL = collection.artworkURL;
    album.trackCount = (NSInteger)collection.trackIDs.count;
    album.tracks = [self tracksForCollection:collection];
    NSString *local = [self localArtworkPathForAlbumID:collection.identifier];
    if (local.length) album.artworkURL = local;
    return album;
}

- (waPlaylist *)playlistForCollection:(waDownloadCollection *)collection {
    waPlaylist *playlist = [[waPlaylist alloc] init];
    playlist.identifier = collection.identifier;
    playlist.title = collection.title.length ? collection.title : @"Playlist";
    playlist.creatorName = collection.artistName;
    playlist.artworkURL = collection.artworkURL;
    playlist.trackCount = (NSInteger)collection.trackIDs.count;
    playlist.tracks = [self tracksForCollection:collection];
    NSString *local = [self localArtworkPathForAlbumID:collection.identifier];
    if (local.length) playlist.artworkURL = local;
    return playlist;
}

- (NSUInteger)activeCount {
    NSUInteger count = 0;
    for (waDownload *download in self.items) {
        if (download.state == waDownloadQueued || download.state == waDownloadResolving || download.state == waDownloadDownloading || download.state == waDownloadFailed) count++;
    }
    return count;
}
- (NSUInteger)completedCount {
    NSUInteger count = 0;
    for (waDownload *download in self.items) if (download.state == waDownloadCompleted) count++;
    return count;
}
- (NSUInteger)pendingCount {
    NSUInteger count = 0;
    for (waDownload *download in self.items) {
        if (download.state == waDownloadQueued || download.state == waDownloadResolving || download.state == waDownloadDownloading) count++;
    }
    return count;
}

@end
