#import "waDownloader.h"
#import "waDZAPI.h"
#import "waCrypto.h"
#import "waLog.h"
#import "waSession.h"
#import "waImageCache.h"
#import "waLyrics.h"
#import "waTags.h"
#import <UIKit/UIKit.h>
#import <ImageIO/ImageIO.h>

NSString * const waDownloaderDidChangeNotification = @"waDownloaderDidChangeNotification";
static NSString * const waDownloadSortKey = @"wave.downloadSort";

@interface waDownload ()
- (NSDictionary *)plist;
+ (waDownload *)downloadFromPlist:(NSDictionary *)dict;
- (NSDictionary *)manifestEntry;
+ (waDownload *)downloadFromManifestEntry:(NSDictionary *)entry;
- (void)applyTags:(NSDictionary *)tags;
- (NSDictionary *)tagFields;
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

// The JSON form: only what the library needs to describe the file. State that
// the tags already carry stays in the tags, not here.
- (NSDictionary *)manifestEntry {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    if (self.trackID.length) entry[@"id"] = self.trackID;
    if (self.fileName.length) entry[@"file"] = [@"media/" stringByAppendingString:self.fileName];
    waTrack *track = self.track;
    if (track.title.length) entry[@"title"] = track.title;
    if (track.artistName.length) entry[@"artist"] = track.artistName;
    if (track.artistIdentifier.length) entry[@"artistID"] = track.artistIdentifier;
    if (track.albumTitle.length) entry[@"album"] = track.albumTitle;
    if (track.albumIdentifier.length) entry[@"albumID"] = track.albumIdentifier;
    if (track.trackPosition > 0) entry[@"track"] = [NSNumber numberWithInteger:track.trackPosition];
    if (track.diskNumber > 0) entry[@"disc"] = [NSNumber numberWithInteger:track.diskNumber];
    if (track.releaseDate.length) entry[@"year"] = track.releaseDate;
    if (track.duration > 0.0) entry[@"duration"] = [NSNumber numberWithDouble:track.duration];
    if (self.format.length) entry[@"format"] = self.format;
    if (self.bytesExpected > 0) entry[@"bytes"] = [NSNumber numberWithUnsignedLongLong:self.bytesExpected];
    entry[@"added"] = [NSNumber numberWithLongLong:(long long)self.addedAt];
    if (self.hasLyrics) entry[@"lyrics"] = [NSNumber numberWithBool:YES];
    return entry;
}

+ (waDownload *)downloadFromManifestEntry:(NSDictionary *)entry {
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    waDownload *download = [[waDownload alloc] init];
    download.trackID = [entry[@"id"] isKindOfClass:[NSString class]] ? entry[@"id"] : nil;
    if (!download.trackID.length) return nil;
    NSString *file = [entry[@"file"] isKindOfClass:[NSString class]] ? entry[@"file"] : nil;
    if (file.length) download.fileName = [file lastPathComponent];
    download.format = [entry[@"format"] isKindOfClass:[NSString class]] ? entry[@"format"] : nil;
    download.bytesExpected = [entry[@"bytes"] unsignedLongLongValue];
    download.addedAt = (NSTimeInterval)[entry[@"added"] longLongValue];
    download.hasLyrics = [entry[@"lyrics"] boolValue];
    download.state = waDownloadCompleted;
    download.progress = 1.0f;
    waTrack *track = [[waTrack alloc] init];
    track.identifier = download.trackID;
    if ([entry[@"title"] isKindOfClass:[NSString class]]) track.title = entry[@"title"];
    if ([entry[@"artist"] isKindOfClass:[NSString class]]) track.artistName = entry[@"artist"];
    if ([entry[@"artistID"] isKindOfClass:[NSString class]]) track.artistIdentifier = entry[@"artistID"];
    if ([entry[@"album"] isKindOfClass:[NSString class]]) track.albumTitle = entry[@"album"];
    if ([entry[@"albumID"] isKindOfClass:[NSString class]]) track.albumIdentifier = entry[@"albumID"];
    if ([entry[@"year"] isKindOfClass:[NSString class]]) track.releaseDate = entry[@"year"];
    if ([entry[@"track"] isKindOfClass:[NSNumber class]]) track.trackPosition = [entry[@"track"] integerValue];
    if ([entry[@"disc"] isKindOfClass:[NSNumber class]]) track.diskNumber = [entry[@"disc"] integerValue];
    if ([entry[@"duration"] isKindOfClass:[NSNumber class]]) track.duration = [entry[@"duration"] doubleValue];
    download.track = track;
    return download;
}

// Rebuild the track from what the file says about itself. Used when the
// manifest is gone and the audio is the only source left.
- (void)applyTags:(NSDictionary *)tags {
    if (![tags isKindOfClass:[NSDictionary class]] || !tags.count) return;
    waTrack *track = self.track ?: [[waTrack alloc] init];
    NSString *identifier = tags[@"trackID"];
    if (identifier.length) {
        track.identifier = identifier;
        if (!self.trackID.length) self.trackID = identifier;
    }
    if ([tags[@"title"] isKindOfClass:[NSString class]]) track.title = tags[@"title"];
    if ([tags[@"artist"] isKindOfClass:[NSString class]]) track.artistName = tags[@"artist"];
    if ([tags[@"album"] isKindOfClass:[NSString class]]) track.albumTitle = tags[@"album"];
    if ([tags[@"albumID"] isKindOfClass:[NSString class]]) track.albumIdentifier = tags[@"albumID"];
    if ([tags[@"year"] isKindOfClass:[NSString class]]) track.releaseDate = tags[@"year"];
    NSString *trackNumber = tags[@"track"];
    if ([trackNumber isKindOfClass:[NSString class]]) {
        NSArray *parts = [trackNumber componentsSeparatedByString:@"/"];
        if (parts.count) track.trackPosition = [[parts objectAtIndex:0] integerValue];
    }
    NSString *discNumber = tags[@"disc"];
    if ([discNumber isKindOfClass:[NSString class]]) {
        NSArray *parts = [discNumber componentsSeparatedByString:@"/"];
        if (parts.count) track.diskNumber = [[parts objectAtIndex:0] integerValue];
    }
    self.track = track;
}

- (NSDictionary *)tagFields {
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    waTrack *track = self.track;
    if (track.title.length) fields[@"title"] = track.title;
    if (track.artistName.length) fields[@"artist"] = track.artistName;
    if (track.albumTitle.length) fields[@"album"] = track.albumTitle;
    if (track.trackPosition > 0) fields[@"track"] = [NSString stringWithFormat:@"%ld", (long)track.trackPosition];
    if (track.diskNumber > 0) fields[@"disc"] = [NSString stringWithFormat:@"%ld", (long)track.diskNumber];
    if (track.releaseDate.length >= 4) fields[@"year"] = [track.releaseDate substringToIndex:4];
    if (self.trackID.length) fields[@"trackID"] = self.trackID;
    if (track.albumIdentifier.length) fields[@"albumID"] = track.albumIdentifier;
    if (track.artistIdentifier.length) fields[@"artistID"] = track.artistIdentifier;
    return fields;
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
- (void)downloadDidComplete:(waDownload *)download;
- (NSString *)tagAndRename:(waDownload *)download;
- (void)tagDownload:(waDownload *)download;
- (NSString *)readableFileNameForTrack:(waTrack *)track extension:(NSString *)extension currentPath:(NSString *)currentPath;
- (NSString *)sanitizedComponent:(NSString *)text;
- (NSData *)coverDataForDownload:(waDownload *)download;
- (void)migrateToTaggedStorage;
- (void)migrateLyricsForDownload:(waDownload *)download;
- (void)syncLyricsSidecarsForDownload:(waDownload *)download;
- (NSString *)lyricsPathForDownload:(waDownload *)download;
- (NSString *)lyricsPathForFileName:(NSString *)fileName;
- (NSString *)lrcPathForFileName:(NSString *)fileName;
- (void)fetchArtworkForDownload:(waDownload *)download completion:(void (^)(void))completion;
- (NSString *)hiresArtworkURLForTrack:(waTrack *)track;
- (BOOL)needsStorageMigration;
- (void)pruneLegacySidecarForTrackID:(NSString *)trackID;
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
    [[waDZAPI shared] signedURLForTrackToken:token formats:formats completion:^(NSString *url, NSString *format, NSString *cipher, NSError *error) {
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
        [strongSelf beginWithURL:[NSURL URLWithString:playable] extension:extension cipher:cipher];
    }];
}

- (void)beginWithURL:(NSURL *)url extension:(NSString *)extension cipher:(NSString *)cipher {
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
        task.cryptor = waCryptorCreateCipher([task.download.trackID UTF8String], waCipherFromName(cipher.UTF8String));
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
        // Music is user data, not something a restore should pull back down.
        NSURL *rootURL = [NSURL fileURLWithPath:_directory];
        [rootURL setResourceValue:[NSNumber numberWithBool:YES] forKey:NSURLIsExcludedFromBackupKey error:NULL];
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
    [self migrateToTaggedStorage];
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

// The manifest is plain JSON so a copy of the folder explains itself on any
// machine, and so it can be rebuilt from the file tags when it goes missing.
- (NSString *)manifestPath {
    return [_directory stringByAppendingPathComponent:@"library.json"];
}

- (NSString *)legacyIndexPath {
    return [_directory stringByAppendingPathComponent:@"index.plist"];
}

// Lyrics sit next to the audio under the same base name: .lrc for other
// players, the word-timed plist for the karaoke stage.
- (NSString *)lyricsPathForFileName:(NSString *)fileName {
    NSString *base = [fileName stringByDeletingPathExtension];
    if (!base.length) return nil;
    return [[self mediaDirectory] stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"lyrics.plist"]];
}

- (NSString *)lrcPathForFileName:(NSString *)fileName {
    NSString *base = [fileName stringByDeletingPathExtension];
    if (!base.length) return nil;
    return [[self mediaDirectory] stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"lrc"]];
}

- (NSString *)lyricsPathForDownload:(waDownload *)download {
    NSString *name = download.fileName;
    if (!name.length) name = [download.trackID stringByAppendingPathExtension:(download.format ?: @"mp3")];
    return [self lyricsPathForFileName:name];
}

- (NSString *)lyricsPathForTrackID:(NSString *)trackID {
    if (!trackID.length) return nil;
    waDownload *download = [self itemForTrackID:trackID];
    if (download) return [self lyricsPathForDownload:download];
    return [self lyricsPathForFileName:[trackID stringByAppendingPathExtension:@"mp3"]];
}

- (NSString *)lrcPathForTrackID:(NSString *)trackID {
    if (!trackID.length) return nil;
    waDownload *download = [self itemForTrackID:trackID];
    NSString *name = download.fileName;
    if (!name.length) name = [trackID stringByAppendingPathExtension:@"mp3"];
    return [self lrcPathForFileName:name];
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
            NSString *to = [[self metaDirectory] stringByAppendingPathComponent:[trackID stringByAppendingPathExtension:@"plist"]];
            if (![manager fileExistsAtPath:to]) [manager moveItemAtPath:from toPath:to error:NULL];
            else [manager removeItemAtPath:from error:NULL];
        }
    }
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
    NSFileManager *manager = [NSFileManager defaultManager];
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];

    NSDictionary *manifest = nil;
    NSData *data = [NSData dataWithContentsOfFile:[self manifestPath]];
    if (data.length) {
        id json = nil;
        @try { json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]; }
        @catch (NSException *exception) { [[waLog shared] log:@"manifest parse %@", exception.reason]; }
        if ([json isKindOfClass:[NSDictionary class]]) manifest = json;
    }
    NSArray *entries = [manifest[@"tracks"] isKindOfClass:[NSArray class]] ? manifest[@"tracks"] : nil;
    for (NSDictionary *entry in entries) {
        waDownload *download = [waDownload downloadFromManifestEntry:entry];
        if (!download) continue;
        byID[download.trackID] = download;
    }

    // Storage from before tags: index.plist plus one sidecar per track.
    if (!entries.count) {
        NSArray *stored = [NSArray arrayWithContentsOfFile:[self legacyIndexPath]];
        for (NSDictionary *dict in stored) {
            waDownload *download = [waDownload downloadFromPlist:dict];
            if (!download.trackID.length) continue;
            byID[download.trackID] = download;
        }
        NSArray *metaNames = [manager contentsOfDirectoryAtPath:[self metaDirectory] error:NULL];
        for (NSString *name in metaNames) {
            if (![name isKindOfClass:[NSString class]] || ![[name lowercaseString] hasSuffix:@".plist"]) continue;
            NSString *trackID = [name stringByDeletingPathExtension];
            if (!trackID.length || byID[trackID]) continue;
            NSDictionary *sidecar = [NSDictionary dictionaryWithContentsOfFile:
                                     [[self metaDirectory] stringByAppendingPathComponent:name]];
            waDownload *download = [waDownload downloadFromPlist:sidecar];
            if (!download) continue;
            if (!download.trackID.length) download.trackID = trackID;
            byID[trackID] = download;
        }
    }

    // Every path the manifest claims, so the scan below only touches files the
    // manifest does not know: a rename or a drop from outside.
    NSMutableSet *knownPaths = [NSMutableSet set];
    for (waDownload *download in [byID allValues]) {
        NSString *path = [self pathForDownload:download];
        if (path.length) [knownPaths addObject:path];
    }

    NSArray *names = [manager contentsOfDirectoryAtPath:[self mediaDirectory] error:NULL];
    for (NSString *name in names) {
        if (![name isKindOfClass:[NSString class]]) continue;
        NSString *lower = [name lowercaseString];
        if (![lower hasSuffix:@".mp3"] && ![lower hasSuffix:@".flac"]) continue;
        NSString *path = [[self mediaDirectory] stringByAppendingPathComponent:name];
        if ([knownPaths containsObject:path]) continue;
        NSString *format = [lower hasSuffix:@".flac"] ? @"flac" : @"mp3";
        NSDictionary *tags = [waTags tagsAtPath:path format:format];
        NSString *trackID = [tags[@"trackID"] isKindOfClass:[NSString class]] ? tags[@"trackID"] : nil;
        if (!trackID.length) trackID = [name stringByDeletingPathExtension];
        if (!trackID.length) continue;
        waDownload *download = byID[trackID];
        if (!download) {
            download = [[waDownload alloc] init];
            download.trackID = trackID;
            download.addedAt = [[NSDate date] timeIntervalSince1970];
            byID[trackID] = download;
        }
        download.fileName = name;
        download.filePath = path;
        download.format = format;
        download.state = waDownloadCompleted;
        download.progress = 1.0f;
        if (!download.track.title.length) [download applyTags:tags];
    }

    [self.items removeAllObjects];
    [self.itemByID removeAllObjects];
    for (waDownload *download in [byID allValues]) {
        NSString *path = [self pathForDownload:download];
        BOOL exists = path.length && [manager fileExistsAtPath:path];
        if (download.state == waDownloadCompleted && !exists) download.state = waDownloadFailed;
        if (download.state == waDownloadDownloading || download.state == waDownloadResolving) download.state = waDownloadQueued;
        if (download.state == waDownloadCancelled && !exists) continue;
        if (exists) {
            NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];
            unsigned long long size = [attributes fileSize];
            if (size > 0) {
                if (download.bytesExpected > 0 && download.bytesExpected != size) {
                    [[waLog shared] log:@"download size drift %@ %llu != %llu", download.trackID, download.bytesExpected, size];
                }
                download.bytesExpected = size;
            }
        }
        [self migrateLyricsForDownload:download];
        NSString *lyricsPath = [self lyricsPathForDownload:download];
        download.hasLyrics = lyricsPath.length && [manager fileExistsAtPath:lyricsPath];
        if (!download.hasLyrics && download.format.length) {
            NSDictionary *tags = [waTags tagsAtPath:path format:download.format];
            if (!download.track.title.length && tags) [download applyTags:tags];
        }
        [self.items addObject:download];
        if (download.trackID.length) self.itemByID[download.trackID] = download;
    }
    [self loadCollections];
    [self persist];
}

// Older builds kept lyrics in their own folder keyed by track id. Move them
// next to the audio once, so the folder stays self-describing.
- (void)migrateLyricsForDownload:(waDownload *)download {
    if (!download.fileName.length) return;
    NSString *target = [self lyricsPathForDownload:download];
    if (!target.length) return;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *sources = [NSArray arrayWithObjects:
                        [[self lyricsDirectory] stringByAppendingPathComponent:
                         [download.trackID stringByAppendingPathExtension:@"plist"]],
                        [[self mediaDirectory] stringByAppendingPathComponent:
                         [download.trackID stringByAppendingPathExtension:@"lyrics.plist"]],
                        nil];
    for (NSString *source in sources) {
        if ([source isEqualToString:target] || ![manager fileExistsAtPath:source]) continue;
        if ([manager fileExistsAtPath:target]) {
            [manager removeItemAtPath:source error:NULL];
            continue;
        }
        [manager moveItemAtPath:source toPath:target error:NULL];
    }
}

// After the audio is renamed the lyrics have to follow it, and the portable
// .lrc is written from the word-timed copy the first time.
- (void)syncLyricsSidecarsForDownload:(waDownload *)download {
    [self migrateLyricsForDownload:download];
    NSString *plist = [self lyricsPathForTrackID:download.trackID];
    NSString *lrc = [self lrcPathForTrackID:download.trackID];
    if (!plist.length || !lrc.length) return;
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL hasPlist = [manager fileExistsAtPath:plist];
    download.hasLyrics = hasPlist;
    if (!hasPlist || [manager fileExistsAtPath:lrc]) return;
    NSString *text = [self lrcTextForLyrics:[self localLyricsForTrackID:download.trackID]];
    if (text.length) [text writeToFile:lrc atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
        NSDictionary *entry = [download manifestEntry];
        if (entry) [list addObject:entry];
    }
    NSDictionary *manifest = [NSDictionary dictionaryWithObjectsAndKeys:
                              [NSNumber numberWithInt:1], @"version",
                              [NSNumber numberWithLongLong:(long long)[[NSDate date] timeIntervalSince1970]], @"generated",
                              list, @"tracks",
                              nil];
    NSString *path = [self manifestPath];
    [self.storeQueue addOperationWithBlock:^{
        NSData *data = nil;
        @try { data = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:NULL]; }
        @catch (NSException *exception) { [[waLog shared] log:@"manifest write %@", exception.reason]; }
        if (data.length) [data writeToFile:path atomically:YES];
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
    [self persist];
    self.cachedBytesValid = NO;
    if (download.state == waDownloadCompleted) [self downloadDidComplete:download];
    [self postChange];
    [self startQueued];
    [self backfillLyricsIfIdle];
}

- (void)downloadDidComplete:(waDownload *)download {
    [self attachTrack:download.track toAlbumCollection:NO];
    __weak waDownloader *weakSelf = self;
    [self fetchArtworkForDownload:download completion:^{
        waDownloader *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf tagDownload:download];
    }];
    [self fetchLyricsForDownload:download];
}

// Largest square the CDN serves. The manifest and the tag both want it, so it
// is fetched once per album before the track is tagged.
- (NSString *)hiresArtworkURLForTrack:(waTrack *)track {
    NSString *url = [track bestArtworkURL];
    if (!url.length) return nil;
    NSRange slash = [url rangeOfString:@"/" options:NSBackwardsSearch];
    if (slash.location == NSNotFound) return url;
    NSString *file = [url substringFromIndex:slash.location + 1];
    NSRange cross = [file rangeOfString:@"x"];
    if (cross.location == NSNotFound || cross.location == 0) return url;
    NSString *rest = [file substringFromIndex:cross.location + 1];
    NSString *replacement = [NSString stringWithFormat:@"1920x1920%@", rest];
    NSString *base = [url substringToIndex:slash.location + 1];
    return [base stringByAppendingString:replacement];
}

static NSInteger waArtworkPixelWidth(NSString *path) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!source) return 0;
    NSDictionary *properties = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    CFRelease(source);
    return [[properties objectForKey:(id)kCGImagePropertyPixelWidth] integerValue];
}

- (void)fetchArtworkForDownload:(waDownload *)download completion:(void (^)(void))completion {
    waTrack *track = download.track;
    NSString *albumID = track.albumIdentifier;
    NSString *dest = albumID.length ? [self artPathForAlbumID:albumID] : [self artPathForTrackID:download.trackID];
    if (!dest.length) { if (completion) completion(); return; }
    if ([[NSFileManager defaultManager] fileExistsAtPath:dest] && waArtworkPixelWidth(dest) >= 1200) {
        if (completion) completion();
        return;
    }
    NSString *url = [self hiresArtworkURLForTrack:track];
    if (!url.length) { if (completion) completion(); return; }
    NSString *cached = [[waImageCache shared] sourcePathForURL:url];
    if (cached.length) {
        [[NSFileManager defaultManager] copyItemAtPath:cached toPath:dest error:NULL];
        if (completion) completion();
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                           cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                       timeoutInterval:18.0];
    [request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    [NSURLConnection sendAsynchronousRequest:request queue:self.storeQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        (void)response;
        if (!error && data.length >= 64) [data writeToFile:dest atomically:YES];
        if (completion) completion();
    }];
}

#pragma mark - tags

- (NSData *)coverDataForDownload:(waDownload *)download {
    waTrack *track = download.track;
    NSString *path = track.albumIdentifier.length ? [self artPathForAlbumID:track.albumIdentifier]
                                                  : [self artPathForTrackID:download.trackID];
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    return [NSData dataWithContentsOfFile:path];
}

- (NSString *)sanitizedComponent:(NSString *)text {
    if (!text.length) return nil;
    NSString *value = [text stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    value = [value stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    value = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"-"];
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableString *clean = [NSMutableString stringWithCapacity:value.length];
    for (NSUInteger index = 0; index < value.length; index++) {
        unichar character = [value characterAtIndex:index];
        if (character < 0x20) continue;
        [clean appendFormat:@"%C", character];
    }
    return clean.length ? clean : nil;
}

- (NSString *)readableFileNameForTrack:(waTrack *)track extension:(NSString *)extension currentPath:(NSString *)currentPath {
    NSString *format = extension.length ? extension : @"mp3";
    NSString *artist = [self sanitizedComponent:track.artistName];
    NSString *title = [self sanitizedComponent:track.title];
    NSString *base = nil;
    if (artist.length && title.length) base = [NSString stringWithFormat:@"%@ - %@", artist, title];
    else if (title.length) base = title;
    else if (artist.length) base = artist;
    if (!base.length) base = [[currentPath lastPathComponent] stringByDeletingPathExtension];
    if (!base.length) base = @"track";
    if (base.length > 90) base = [base substringToIndex:90];
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *name = [base stringByAppendingPathExtension:format];
    NSString *target = [[self mediaDirectory] stringByAppendingPathComponent:name];
    if ([target isEqualToString:currentPath] || ![manager fileExistsAtPath:target]) return name;
    for (NSUInteger suffix = 2; suffix < 500; suffix++) {
        NSString *candidate = [NSString stringWithFormat:@"%@ (%lu).%@", base, (unsigned long)suffix, format];
        NSString *candidatePath = [[self mediaDirectory] stringByAppendingPathComponent:candidate];
        if ([candidatePath isEqualToString:currentPath]) return candidate;
        if (![manager fileExistsAtPath:candidatePath]) return candidate;
    }
    return name;
}

// Runs on the store queue. Returns the final file name, or nil when the file
// could not be tagged; the audio is never left half written.
- (NSString *)tagAndRename:(waDownload *)download {
    if (download.state != waDownloadCompleted) return nil;
    if (![download.format isEqualToString:@"mp3"]) return download.fileName; // FLAC blocks land later
    NSString *path = download.filePath.length ? download.filePath : [self pathForDownload:download];
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    NSString *wanted = [self readableFileNameForTrack:download.track extension:download.format currentPath:path];
    NSDictionary *existing = [waTags tagsAtPath:path format:@"mp3"];
    BOOL tagged = [[existing objectForKey:@"trackID"] isEqualToString:download.trackID];
    BOOL named = [[path lastPathComponent] isEqualToString:wanted];
    if (tagged && named) return download.fileName;

    NSError *error = nil;
    if (![waTags writeID3v23ToPath:path fields:[download tagFields] cover:[self coverDataForDownload:download] error:&error]) {
        [[waLog shared] log:@"tag failed %@ %@", download.trackID, error.localizedDescription];
        return nil;
    }
    NSString *target = [[self mediaDirectory] stringByAppendingPathComponent:wanted];
    if (![target isEqualToString:path]) {
        [[NSFileManager defaultManager] removeItemAtPath:target error:NULL];
        if (![[NSFileManager defaultManager] moveItemAtPath:path toPath:target error:&error]) {
            [[waLog shared] log:@"rename failed %@ %@", download.trackID, error.localizedDescription];
            return [path lastPathComponent];
        }
    }
    [[waLog shared] log:@"tagged %@ as %@", download.trackID, wanted];
    return wanted;
}

- (void)tagDownload:(waDownload *)download {
    __weak waDownloader *weakSelf = self;
    [self.storeQueue addOperationWithBlock:^{
        waDownloader *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *name = [strongSelf tagAndRename:download];
        dispatch_async(dispatch_get_main_queue(), ^{
            waDownloader *mainSelf = weakSelf;
            if (!mainSelf) return;
            if (name.length) {
                download.fileName = name;
                download.filePath = [[mainSelf mediaDirectory] stringByAppendingPathComponent:name];
                NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:download.filePath error:NULL];
                if ([attributes fileSize] > 0) download.bytesExpected = [attributes fileSize];
                [mainSelf syncLyricsSidecarsForDownload:download];
                [mainSelf pruneLegacySidecarForTrackID:download.trackID];
            }
            [mainSelf persist];
            [mainSelf postChange];
        });
    }];
}

- (BOOL)needsStorageMigration {
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([manager fileExistsAtPath:[self legacyIndexPath]]) return YES;
    NSArray *meta = [manager contentsOfDirectoryAtPath:[self metaDirectory] error:NULL];
    return meta.count > 0;
}

// One pass over what is already downloaded. Each track drops its old sidecar
// only after its own tag is written, so an interrupted pass loses nothing.
- (void)migrateToTaggedStorage {
    if (![self needsStorageMigration]) return;
    NSArray *items = [self.items copy];
    [[waLog shared] log:@"downloads migrate %lu", (unsigned long)items.count];
    for (waDownload *download in items) {
        if (download.state != waDownloadCompleted) continue;
        [self tagDownload:download];
    }
}

- (void)pruneLegacySidecarForTrackID:(NSString *)trackID {
    if (!trackID.length) return;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *sidecar = [[self metaDirectory] stringByAppendingPathComponent:[trackID stringByAppendingPathExtension:@"plist"]];
    if ([manager fileExistsAtPath:sidecar]) [manager removeItemAtPath:sidecar error:NULL];
    NSArray *left = [manager contentsOfDirectoryAtPath:[self metaDirectory] error:NULL];
    if (!left.count) {
        [manager removeItemAtPath:[self metaDirectory] error:NULL];
        [manager removeItemAtPath:[self legacyIndexPath] error:NULL];
    }
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

// The plist keeps the word timings the karaoke stage needs; the .lrc next to
// it is what another player can read.
- (NSString *)lrcTextForLyrics:(waLyrics *)lyrics {
    if (!lyrics) return nil;
    NSMutableString *text = [NSMutableString string];
    for (waLyricLine *line in lyrics.lines) {
        if (![line isKindOfClass:[waLyricLine class]] || !line.text.length) continue;
        double start = line.start > 0.0 ? line.start : 0.0;
        NSInteger minutes = (NSInteger)(start / 60.0);
        double seconds = start - minutes * 60.0;
        [text appendFormat:@"[%02ld:%05.2f]%@\n", (long)minutes, seconds, line.text];
    }
    if (!text.length && lyrics.plain.length) [text appendString:lyrics.plain];
    return text.length ? text : nil;
}

- (void)storeLyrics:(waLyrics *)lyrics forTrackID:(NSString *)trackID {
    if (!lyrics || !trackID.length) return;
    if (![self isDownloadedTrackID:trackID] && ![self itemForTrackID:trackID]) return;
    NSString *path = [self lyricsPathForTrackID:trackID];
    if (!path.length) return;
    [[lyrics plist] writeToFile:path atomically:YES];
    NSString *lrcPath = [self lrcPathForTrackID:trackID];
    NSString *lrc = [self lrcTextForLyrics:lyrics];
    if (lrcPath.length && lrc.length) [lrc writeToFile:lrcPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    waDownload *download = [self itemForTrackID:trackID];
    if (download) {
        download.hasLyrics = YES;
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
    NSString *lyrics = [self lyricsPathForTrackID:download.trackID];
    NSString *lrc = [self lrcPathForTrackID:download.trackID];
    [self.storeQueue addOperationWithBlock:^{
        NSFileManager *manager = [NSFileManager defaultManager];
        if (path.length) [manager removeItemAtPath:path error:NULL];
        if (lyrics.length) [manager removeItemAtPath:lyrics error:NULL];
        if (lrc.length) [manager removeItemAtPath:lrc error:NULL];
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
