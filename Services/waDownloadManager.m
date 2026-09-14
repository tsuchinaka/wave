#import "waDownloadManager.h"
#import "../Models/waPreferences.h"
#import "waDeezerStreamClient.h"
#import "../Models/waMediaItem.h"
#import "waAPIClient.h" // for waNetworkActivityBegin/End only (serverless shim)
#import "waDeezerBlowfish.h"
#import "waDebugLog.h"
#import <UIKit/UIKit.h>

NSString * const waDownloadManagerDidChangeNotification = @"waDownloadManagerDidChangeNotification";

NSString *waFileSizeString(unsigned long long bytes) {
    if (!bytes) return @"0 MB";
    static double const bytesPerMB = 1000.0 * 1000.0;
    static double const bytesPerGB = 1000.0 * 1000.0 * 1000.0;
    // Switch before one-decimal MB rounding could visibly produce "1000.0 MB".
    if ((double)bytes >= 999.95 * bytesPerMB) return [NSString stringWithFormat:@"%.1f GB", (double)bytes / bytesPerGB];
    return [NSString stringWithFormat:@"%.1f MB", (double)bytes / bytesPerMB];
}

// Connection callbacks run independently of the manager's main-thread state.
@interface waDownloadConnectionContext : NSObject
@property (nonatomic, strong) waDownload *download;
@property (nonatomic, strong) NSFileHandle *handle;
@property (nonatomic, strong) dispatch_queue_t fileQueue;
@property (nonatomic, copy) NSString *temporaryPath;
@property (nonatomic, copy) NSString *finalPath;
@property (nonatomic, assign) long long bytesExpected;
@property (nonatomic, assign) unsigned long long bytesReceived;
@property (nonatomic, assign) NSTimeInterval lastProgressDispatch;
@property (nonatomic, assign) BOOL finalized;
@property (nonatomic, assign) BOOL cancelled;
// Serverless Deezer decrypt (encrypted CDN -> plain MP3 on disk).
@property (nonatomic, assign) BOOL deezerDecrypt;
@property (nonatomic, assign) unsigned long long decryptOffset;
@property (nonatomic, strong) NSMutableData *decryptRemainder;
@property (nonatomic, strong) NSData *deezerKeyData;
- (BOOL)beginFinalization;
- (void)cancel;
- (BOOL)isCancelled;
@end

@implementation waDownloadConnectionContext
- (BOOL)beginFinalization { @synchronized (self) { if (self.finalized) return NO; self.finalized = YES; return YES; } }
- (void)cancel { @synchronized (self) { self.cancelled = YES; } }
- (BOOL)isCancelled { @synchronized (self) { return self.cancelled; } }
@end

@interface waDownloadManager () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableDictionary *downloads;
@property (nonatomic, strong) NSMutableDictionary *connections;
@property (nonatomic, strong) NSMutableArray *pendingIdentifiers;
@property (nonatomic, strong) NSMutableSet *resolvingIdentifiers;
@property (nonatomic, strong) NSMutableSet *soloSessionIdentifiers;
@property (nonatomic, strong) dispatch_queue_t persistenceQueue;
@property (nonatomic, strong) dispatch_queue_t fileQueue;
@property (nonatomic, strong) dispatch_queue_t statisticsQueue;
@property (nonatomic, strong) NSOperationQueue *artworkQueue;
@property (nonatomic, assign) unsigned long long downloadedBytesValue;
@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTask;
@property (nonatomic, strong) NSMutableDictionary *lastProgressNotifications;
@property (nonatomic, strong) NSURLSession *downloadSession;
@end

@implementation waDownloadManager

+ (id)sharedManager {
    static waDownloadManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ manager = [[self alloc] init]; });
    return manager;
}

- (NSString *)storePath {
    NSString *directory = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject];
    directory = [directory stringByAppendingPathComponent:@"Downloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    return directory;
}

- (id)init {
    if ((self = [super init])) {
        _downloads = [[NSMutableDictionary alloc] init];
        _connections = [[NSMutableDictionary alloc] init];
        _pendingIdentifiers = [[NSMutableArray alloc] init];
        _resolvingIdentifiers = [[NSMutableSet alloc] init];
        _soloSessionIdentifiers = [[NSMutableSet alloc] init];
        _persistenceQueue = dispatch_queue_create("com.bytebox.wave.downloads.persistence", DISPATCH_QUEUE_SERIAL);
        _fileQueue = dispatch_queue_create("com.bytebox.wave.downloads.files", DISPATCH_QUEUE_SERIAL);
        _statisticsQueue = dispatch_queue_create("com.bytebox.wave.downloads.statistics", DISPATCH_QUEUE_SERIAL);
        _artworkQueue = [[NSOperationQueue alloc] init];
        _artworkQueue.maxConcurrentOperationCount = 2;
        _backgroundTask = UIBackgroundTaskInvalid;
        _lastProgressNotifications = [[NSMutableDictionary alloc] init];
        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 4;
        _downloadSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                          delegate:self
                                                     delegateQueue:delegateQueue];
        _maximumParallelDownloads = MAX(1, [waPreferences sharedPreferences].maximumParallelDownloads);

        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:[[self storePath] stringByAppendingPathComponent:@"downloads.plist"]];
        BOOL migrated = NO;
        for (NSString *key in saved) {
            NSDictionary *value = saved[key];
            if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSDictionary class]]) continue;
            NSString *storedPath = value[@"path"];
            // Migrate legacy .audio extension to .mp3 so the Core Audio decoder
            // can select the correct container.
            NSString *migratedPath = storedPath;
            if ([storedPath.pathExtension isEqualToString:@"audio"]) {
                NSString *mp3Path = [[storedPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"mp3"];
                if (![[NSFileManager defaultManager] fileExistsAtPath:mp3Path] && [[NSFileManager defaultManager] fileExistsAtPath:storedPath]) {
                    NSError *moveError = nil;
                    [[NSFileManager defaultManager] moveItemAtPath:storedPath toPath:mp3Path error:&moveError];
                    if (!moveError) migratedPath = mp3Path;
                } else if ([[NSFileManager defaultManager] fileExistsAtPath:mp3Path]) {
                    migratedPath = mp3Path;
                }
                if (![migratedPath isEqualToString:storedPath]) migrated = YES;
            }
            waDownload *download = [[waDownload alloc] initWithIdentifier:key filePath:migratedPath];
            NSInteger state = [value[@"state"] integerValue];
            download.state = state >= waDownloadStateQueued && state <= waDownloadStateCancelled ? (waDownloadState)state : waDownloadStateFailed;
            download.progress = [value[@"progress"] floatValue];
            download.ticketURL = value[@"ticket"];
            download.title = value[@"title"];
            download.artist = value[@"artist"];
            download.albumName = value[@"albumName"];
             download.thumbnailURL = value[@"thumbnailURL"];
             download.artworkFilePath = value[@"artworkFilePath"];
             download.metadata = [value[@"metadata"] isKindOfClass:[NSDictionary class]] ? value[@"metadata"] : nil;
             download.duration = [value[@"duration"] doubleValue];
             download.explicit = [value[@"explicit"] boolValue];
            download.downloadQuality = value[@"quality"] ? MIN(2, [value[@"quality"] unsignedIntegerValue]) : [waPreferences sharedPreferences].downloadQuality;
            download.bytesReceived = [value[@"bytesReceived"] unsignedLongLongValue];
            download.bytesExpected = [value[@"bytesExpected"] longLongValue];
            if ([value[@"contexts"] isKindOfClass:[NSDictionary class]]) download.categoryContexts = value[@"contexts"];
            else migrated = YES;
            NSInteger currentCategory = [value[@"currentCategory"] integerValue];
            download.currentCategory = currentCategory >= waDownloadCategorySong && currentCategory <= waDownloadCategoryPlaylist ? (waDownloadCategory)currentCategory : waDownloadCategorySong;
            download.currentContextIdentifier = [value[@"currentContext"] isKindOfClass:[NSString class]] ? value[@"currentContext"] : key;
            download.currentGroupTitle = [value[@"currentGroupTitle"] isKindOfClass:[NSString class]] ? value[@"currentGroupTitle"] : nil;
            [download addCategory:waDownloadCategorySong contextIdentifier:key];

            // Recover an interrupted transfer from the decrypted .part file.
            if (download.state == waDownloadStateDownloading) {
                download.state = waDownloadStateQueued;
                unsigned long long partBytes = [[[NSFileManager defaultManager] attributesOfItemAtPath:[download.filePath stringByAppendingString:@".part"] error:NULL] fileSize];
                download.bytesReceived = partBytes;
                if (download.bytesExpected > 0) download.progress = MIN(1.0f, (float)partBytes / (float)download.bytesExpected);
                else download.progress = 0.0f;
                migrated = YES;
            }
            if (download.state == waDownloadStateCompleted) {
                NSString *actualPath = download.filePath;
                if (![[NSFileManager defaultManager] fileExistsAtPath:actualPath]) {
                    NSString *legacy = [actualPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"audio"];
                    if ([[NSFileManager defaultManager] fileExistsAtPath:legacy]) { download.filePath = legacy; actualPath = legacy; migrated = YES; }
                }
                if ([[NSFileManager defaultManager] fileExistsAtPath:actualPath]) {
                    download.bytesReceived = [[[NSFileManager defaultManager] attributesOfItemAtPath:actualPath error:NULL] fileSize];
                    if (download.bytesExpected <= 0) download.bytesExpected = (long long)download.bytesReceived;
                    download.progress = 1.0f;
                } else {
                    download.state = waDownloadStateFailed;
                }
            }
            _downloads[key] = download;
            if (download.state == waDownloadStateQueued) [_pendingIdentifiers addObject:key];
            if ((download.state == waDownloadStateQueued || download.state == waDownloadStateDownloading) && download.currentCategory == waDownloadCategorySong) [_soloSessionIdentifiers addObject:key];
        }
        if (migrated) [self persist];
        [self promoteQueuedDownloads];
        [self refreshDownloadedBytes];
    }
    return self;
}

- (NSDictionary *)serializedDownloads {
    NSMutableDictionary *saved = [NSMutableDictionary dictionary];
    for (NSString *key in self.downloads) {
        waDownload *download = self.downloads[key];
        saved[key] = @{
            @"path": download.filePath ?: @"",
            @"state": @(download.state),
            @"progress": @(download.progress),
            @"ticket": download.ticketURL ?: @"",
            @"title": download.title ?: @"",
            @"artist": download.artist ?: @"",
            @"albumName": download.albumName ?: @"",
            @"thumbnailURL": download.thumbnailURL ?: @"",
             @"artworkFilePath": download.artworkFilePath ?: @"",
             @"metadata": download.metadata ?: @{},
             @"duration": @(download.duration),
             @"explicit": @(download.explicit),
            @"quality": @(download.downloadQuality),
            @"bytesReceived": @(download.bytesReceived),
            @"bytesExpected": @(download.bytesExpected),
            @"contexts": download.categoryContexts ?: @{},
            @"currentCategory": @(download.currentCategory),
            @"currentContext": download.currentContextIdentifier ?: @"",
            @"currentGroupTitle": download.currentGroupTitle ?: @""
        };
    }
    return saved;
}

- (void)persist {
    NSDictionary *saved = [self serializedDownloads];
    NSString *path = [[self storePath] stringByAppendingPathComponent:@"downloads.plist"];
    dispatch_async(self.persistenceQueue, ^{ [saved writeToFile:path atomically:YES]; });
}

- (void)notifyChangeForDownload:(waDownload *)download event:(NSString *)event {
    NSDictionary *userInfo = download ? @{ @"download": download, @"identifier": download.identifier ?: @"", @"event": event ?: @"state" } : nil;
    void (^post)(void) = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:waDownloadManagerDidChangeNotification object:self userInfo:userInfo];
    };
    if ([NSThread isMainThread]) post();
    else dispatch_async(dispatch_get_main_queue(), post);
}

- (void)notifyChangeForDownload:(waDownload *)download { [self notifyChangeForDownload:download event:@"state"]; }

- (void)endNetworkActivityForContext:(NSDictionary *)context {
    if ([context[@"networkActivity"] boolValue]) waNetworkActivityEnd();
}

- (void)setMaximumParallelDownloads:(NSUInteger)value {
    // Respect device cap: A4→2, others→5 — playback path untouched
    NSUInteger cap = [[waPreferences sharedPreferences] waMaximumParallelCap];
    if (cap < 1) cap = 5;
    if (value < 1) value = 1;
    if (value > cap) value = cap;
    _maximumParallelDownloads = value;
    if ([NSThread isMainThread]) [self promoteQueuedDownloads];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self promoteQueuedDownloads]; });
}

- (void)enqueueDownloadWithIdentifier:(NSString *)identifier {
    [self enqueueDownloadWithIdentifier:identifier ticketURL:nil];
}

- (void)enqueueDownloadWithIdentifier:(NSString *)identifier ticketURL:(NSString *)ticketURL {
    [self enqueueDownloadWithIdentifier:identifier ticketURL:ticketURL category:waDownloadCategorySong contextIdentifier:identifier title:nil artist:nil];
}

- (void)enqueueDownloadWithIdentifier:(NSString *)identifier category:(waDownloadCategory)category contextIdentifier:(NSString *)contextIdentifier title:(NSString *)title artist:(NSString *)artist {
    [self enqueueDownloadWithIdentifier:identifier ticketURL:nil category:category contextIdentifier:contextIdentifier title:title artist:artist];
}

- (void)enqueueDownloadWithIdentifier:(NSString *)identifier ticketURL:(NSString *)ticketURL category:(waDownloadCategory)category contextIdentifier:(NSString *)contextIdentifier title:(NSString *)title artist:(NSString *)artist {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self enqueueDownloadWithIdentifier:identifier ticketURL:ticketURL category:category contextIdentifier:contextIdentifier title:title artist:artist]; });
        return;
    }
    if (!identifier.length) return;
    if (![identifier hasPrefix:@"deezer:"]) identifier = [@"deezer:" stringByAppendingString:identifier];

    waDownload *download = self.downloads[identifier];
    BOOL isNewDownload = download == nil;
    if (!download) {
        NSString *name = [identifier stringByReplacingOccurrencesOfString:@":" withString:@"_"];
        // Use mp3 as the initial extension; lossless downloads are renamed to
        // m4a when the requested container is known.
        download = [[waDownload alloc] initWithIdentifier:identifier filePath:[[[self storePath] stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"mp3"]];
        self.downloads[identifier] = download;
    }
    [download addCategory:category contextIdentifier:contextIdentifier];
    download.currentCategory = category;
    download.currentContextIdentifier = contextIdentifier.length ? contextIdentifier : (category == waDownloadCategorySong ? download.identifier : nil);
    if (title.length) download.title = title;
    if (artist.length) download.artist = artist;

    BOOL active = download.state == waDownloadStateQueued || download.state == waDownloadStateDownloading;
    BOOL available = download.state == waDownloadStateCompleted && [[NSFileManager defaultManager] fileExistsAtPath:download.filePath];
    if (category == waDownloadCategorySong && !available) {
        if (![self hasActiveSoloSessionDownload]) [self.soloSessionIdentifiers removeAllObjects];
        [self.soloSessionIdentifiers addObject:identifier];
    }
    // waDownload is initialized as Queued so restored downloads can keep that
    // state. A newly created object is not yet in pendingIdentifiers, though,
    // and must still be added before it can be promoted and started.
    if ((isNewDownload || !active) && !available) {
        // Keep a valid partial file so a retry can resume it with Range.
        if (![[NSFileManager defaultManager] fileExistsAtPath:[download.filePath stringByAppendingString:@".part"]]) {
            [[NSFileManager defaultManager] createFileAtPath:[download.filePath stringByAppendingString:@".part"] contents:nil attributes:nil];
        }
        download.ticketURL = ticketURL;
        download.downloadQuality = [waPreferences sharedPreferences].downloadQuality;
        download.state = waDownloadStateQueued;
        unsigned long long partBytes = [[[NSFileManager defaultManager] attributesOfItemAtPath:[download.filePath stringByAppendingString:@".part"] error:NULL] fileSize];
        download.bytesReceived = partBytes;
        if (download.bytesExpected <= 0 || partBytes == 0) download.bytesExpected = 0;
        download.progress = download.bytesExpected > 0 ? MIN(1.0f, (float)partBytes / (float)download.bytesExpected) : 0.0f;
        if (![self.pendingIdentifiers containsObject:identifier]) [self.pendingIdentifiers addObject:identifier];
    }
    [self persist];
    [self notifyChangeForDownload:download];
    [self promoteQueuedDownloads];
}

- (BOOL)hasActiveSoloSessionDownload {
    for (NSString *identifier in self.soloSessionIdentifiers) {
        waDownload *download = self.downloads[identifier];
        if (download.state == waDownloadStateQueued || download.state == waDownloadStateDownloading) return YES;
    }
    return NO;
}

- (void)enqueueDownloadWithItem:(waMediaItem *)item category:(waDownloadCategory)category contextIdentifier:(NSString *)contextIdentifier {
    [self enqueueDownloadWithItem:item category:category contextIdentifier:contextIdentifier groupTitle:nil];
}

- (void)enqueueDownloadWithItem:(waMediaItem *)item category:(waDownloadCategory)category contextIdentifier:(NSString *)contextIdentifier groupTitle:(NSString *)groupTitle {
    if (!item) return;
    NSString *identifier = item.trackId.length ? item.trackId : item.identifier;
    NSString *title = item.title;
    NSString *artist = item.artistName.length ? item.artistName : item.subtitle;
    NSString *album = item.albumName;
    NSString *thumb = item.thumbnailURL;
    NSTimeInterval duration = item.duration;
    [self enqueueDownloadWithIdentifier:identifier ticketURL:nil category:category contextIdentifier:contextIdentifier title:title artist:artist];
    // Enrich with extended metadata
    waDownload *download = [self downloadForIdentifier:identifier];
    if (download) {
        download.currentGroupTitle = category == waDownloadCategorySong ? nil : groupTitle;
        if (album.length) download.albumName = album;
        download.metadata = item.metadata ?: item.dictionaryRepresentation;
        download.explicit = item.isExplicit;
        if (thumb.length) download.thumbnailURL = thumb;
        if (duration > 0) download.duration = duration;
        // Prepare local artwork path
        if (thumb.length) {
            NSString *name = [identifier stringByReplacingOccurrencesOfString:@":" withString:@"_"];
            download.artworkFilePath = [[[self storePath] stringByAppendingPathComponent:[name stringByAppendingString:@"_artwork"]] stringByAppendingPathExtension:@"jpg"];
        }
        [self persist];
        [self notifyChangeForDownload:download];
        if (thumb.length && ![[NSFileManager defaultManager] fileExistsAtPath:download.artworkFilePath]) {
            NSURL *url = [NSURL URLWithString:thumb];
            if (!url.scheme.length) url = nil;
            if (!url) return; // serverless: skip relative artwork (needs absolute dzcdn.net)
            NSURLRequest *request = [NSURLRequest requestWithURL:url];
            NSString *artworkPath = [download.artworkFilePath copy];
            [self.artworkQueue addOperationWithBlock:^{
                NSURLResponse *response = nil;
                NSError *error = nil;
                NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
                NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
                if (error || !data.length || status < 200 || status >= 300) return;
                if (![data writeToFile:artworkPath atomically:YES]) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.downloads[download.identifier] != download || download.state == waDownloadStateCancelled) return;
                    [self persist];
                    [self notifyChangeForDownload:download];
                });
            }];
        }
    }
}

- (void)promoteQueuedDownloads {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self promoteQueuedDownloads]; });
        return;
    }
    while (self.connections.count + self.resolvingIdentifiers.count < self.maximumParallelDownloads && self.pendingIdentifiers.count) {
        NSString *identifier = self.pendingIdentifiers[0];
        [self.pendingIdentifiers removeObjectAtIndex:0];
        waDownload *download = self.downloads[identifier];
        if (download && download.state == waDownloadStateQueued) [self start:download];
    }
    [self persist];
}

- (void)failDownloadBeforeConnection:(waDownload *)download {
    download.state = waDownloadStateFailed;
    [self notifyChangeForDownload:download];
}

- (void)start:(waDownload *)download {
    // Serverless direct: MP3 (.mp3) or FLAC (.flac), decrypted on-device from
    // the signed Deezer CDN. Extension follows the requested container so the
    // decoder picks CoreAudio vs FlacDecoder correctly.
    if (download.downloadQuality > 2) download.downloadQuality = 2;
    NSString *extension = download.downloadQuality >= 2 ? @"flac" : @"mp3";
    if (![download.filePath.pathExtension.lowercaseString isEqualToString:extension]) {
        download.filePath = [[download.filePath stringByDeletingPathExtension] stringByAppendingPathExtension:extension];
    }
    download.state = waDownloadStateDownloading;
    [self.resolvingIdentifiers addObject:download.identifier ?: @""];
    [self persist];
    [self notifyChangeForDownload:download];
    __weak typeof(self) weakSelf = self;
    [[waDeezerStreamClient sharedClient] resolveCDNURLForTrackID:download.identifier quality:download.downloadQuality completion:^(NSURL *cdnURL, NSUInteger resolvedQuality, NSError *error) {
        waDownloadManager *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.resolvingIdentifiers removeObject:download.identifier ?: @""];
        if (strongSelf.downloads[download.identifier] != download || download.state != waDownloadStateDownloading) {
            [strongSelf promoteQueuedDownloads];
            return;
        }
        if (cdnURL) {
            if (resolvedQuality != download.downloadQuality) {
                download.downloadQuality = resolvedQuality;
                NSString *grantedExtension = resolvedQuality >= 2 ? @"flac" : @"mp3";
                if (![download.filePath.pathExtension.lowercaseString isEqualToString:grantedExtension]) {
                    download.filePath = [[download.filePath stringByDeletingPathExtension] stringByAppendingPathExtension:grantedExtension];
                }
            }
            NSString *rawID = [[waDeezerStreamClient sharedClient] rawIdentifier:download.identifier];
            [strongSelf beginConnectionToURL:cdnURL download:download deezerDecrypt:YES rawID:rawID];
            // Open the resolved connection before filling the freed slot. This
            // keeps connections + URL resolutions within the configured cap.
            [strongSelf promoteQueuedDownloads];
            return;
        }
        [[waDebugLog sharedLog] log:@"Direct download failed (%@), serverless - no fallback", error.localizedDescription ?: @"unknown"];
        [strongSelf failDownloadBeforeConnection:download];
        [strongSelf promoteQueuedDownloads];
    }];
}

- (void)beginConnectionToURL:(NSURL *)url download:(waDownload *)download deezerDecrypt:(BOOL)deezerDecrypt rawID:(NSString *)rawID {
    if (!url) { [self failDownloadBeforeConnection:download]; return; }
    NSString *temp = [download.filePath stringByAppendingString:@".part"];
    unsigned long long existingBytes = [[[NSFileManager defaultManager] attributesOfItemAtPath:temp error:NULL] fileSize];
    // Deezer's cipher resets at 2048-byte boundaries. Never resume from a
    // partial cipher block; truncate the decrypted file to a safe boundary.
    unsigned long long resumeBytes = existingBytes - (existingBytes % 2048);
    if (resumeBytes != existingBytes) {
        NSFileHandle *truncateHandle = [NSFileHandle fileHandleForWritingAtPath:temp];
        [truncateHandle truncateFileAtOffset:resumeBytes];
        [truncateHandle closeFile];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:temp] && ![[NSFileManager defaultManager] createFileAtPath:temp contents:nil attributes:nil]) { [self failDownloadBeforeConnection:download]; return; }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:temp];
    if (!handle) { [[NSFileManager defaultManager] removeItemAtPath:temp error:NULL]; [self failDownloadBeforeConnection:download]; return; }
    [handle seekToEndOfFile];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    request.allowsCellularAccess = [waPreferences sharedPreferences].cellularDataAllowed;
    if (resumeBytes > 0) [request setValue:[NSString stringWithFormat:@"bytes=%llu-", resumeBytes] forHTTPHeaderField:@"Range"];
    download.state = waDownloadStateDownloading;
    waDownloadConnectionContext *context = [[waDownloadConnectionContext alloc] init];
    context.download = download;
    context.handle = handle;
    context.fileQueue = dispatch_queue_create("com.bytebox.wave.download.file", DISPATCH_QUEUE_SERIAL);
    context.temporaryPath = temp;
    context.finalPath = download.filePath;
    context.deezerDecrypt = deezerDecrypt;
    context.decryptOffset = resumeBytes;
    context.bytesReceived = resumeBytes;
    context.decryptRemainder = [NSMutableData data];
    if (deezerDecrypt && rawID.length) {
        unsigned char key[16];
        waDeezerDeriveKey([rawID UTF8String], key);
        context.deezerKeyData = [NSData dataWithBytes:key length:16];
    }
    NSURLSessionDataTask *task = [self.downloadSession dataTaskWithRequest:request];
    if (!task) { [handle closeFile]; [self failDownloadBeforeConnection:download]; return; }
    NSNumber *taskKey = @(task.taskIdentifier);
    self.connections[taskKey] = @{ @"download": download, @"handle": handle, @"task": task, @"context": context, @"networkActivity": @YES };
    if (self.backgroundTask == UIBackgroundTaskInvalid) {
        __weak waDownloadManager *weakSelf = self;
        self.backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            waDownloadManager *manager = weakSelf;
            if (!manager) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (manager.backgroundTask != UIBackgroundTaskInvalid) {
                    [[UIApplication sharedApplication] endBackgroundTask:manager.backgroundTask];
                    manager.backgroundTask = UIBackgroundTaskInvalid;
                }
            });
        }];
    }
    waNetworkActivityBegin();
    [self persist];
    [self notifyChangeForDownload:download];
    [task resume];
}

- (NSNumber *)keyForTask:(NSURLSessionTask *)task { return @(task.taskIdentifier); }
- (waDownloadConnectionContext *)contextForTask:(NSURLSessionTask *)task { return self.connections[[self keyForTask:task]][@"context"]; }

- (void)cancelDownloadWithIdentifier:(NSString *)identifier {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self cancelDownloadWithIdentifier:identifier]; });
        return;
    }
    if (identifier.length && ![identifier hasPrefix:@"deezer:"]) identifier = [@"deezer:" stringByAppendingString:identifier];
    waDownload *download = self.downloads[identifier];
    if (!download) return;
    [self.pendingIdentifiers removeObject:identifier];
    [self.resolvingIdentifiers removeObject:identifier];
    [self.soloSessionIdentifiers removeObject:identifier];
    for (NSNumber *key in [self.connections allKeys]) {
        NSURLSessionDataTask *task = self.connections[key][@"task"];
        NSDictionary *context = self.connections[key];
        if (context[@"download"] != download) continue;
        [task cancel];
        [self endNetworkActivityForContext:context];
        [context[@"context"] cancel];
        NSFileHandle *handle = context[@"handle"];
        dispatch_sync([context[@"context"] fileQueue], ^{
            [handle closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:[download.filePath stringByAppendingString:@".part"] error:NULL];
        });
        [self.connections removeObjectForKey:key];
    }
    download.state = waDownloadStateCancelled;
    [self.lastProgressNotifications removeObjectForKey:download.identifier];
    if (!self.connections.count && self.backgroundTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
    }
    [self persist];
    [self notifyChangeForDownload:download];
    [self promoteQueuedDownloads];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    (void)session;
    waDownloadConnectionContext *context = [self contextForTask:task];
    if (!context || [context isCancelled]) {
        if (completionHandler) completionHandler(NSURLSessionResponseCancel);
        return;
    }
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    BOOL resuming = context.bytesReceived > 0;
    if (resuming && status == 200) {
        dispatch_sync(context.fileQueue, ^{
            [context.handle truncateFileAtOffset:0];
            [context.handle seekToFileOffset:0];
        });
        context.bytesReceived = 0;
        context.decryptOffset = 0;
        resuming = NO;
    }
    if (status < 200 || status >= 300 || (resuming && status != 206)) {
        [task cancel];
        if (completionHandler) completionHandler(NSURLSessionResponseCancel);
        [self URLSession:session task:task didCompleteWithError:nil];
        return;
    }
    long long contentLength = response.expectedContentLength > 0 ? response.expectedContentLength : 0;
    context.bytesExpected = contentLength > 0 ? (long long)context.bytesReceived + contentLength : 0;
    [context.decryptRemainder setLength:0];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([context isCancelled] || self.downloads[context.download.identifier] != context.download) return;
        NSString *servedQuality = [(NSHTTPURLResponse *)response allHeaderFields][@"X-Audio-Quality"];
        if ([servedQuality isEqualToString:@"128"]) context.download.downloadQuality = 0;
        else if ([servedQuality isEqualToString:@"320"]) context.download.downloadQuality = 1;
        else if ([servedQuality.lowercaseString isEqualToString:@"lossless"]) context.download.downloadQuality = 2;
        context.download.bytesReceived = context.bytesReceived;
        context.download.bytesExpected = context.bytesExpected;
        context.download.progress = 0.0f;
        [self.lastProgressNotifications removeObjectForKey:context.download.identifier];
        [self persist];
        [self notifyChangeForDownload:context.download];
    });
    if (completionHandler) completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session;
    waDownloadConnectionContext *context = [self contextForTask:task];
    if (!context || [context isCancelled]) return;
    __block BOOL wrote = YES;
    // The delegate's NSData stays valid for the duration of this call and the
    // file write below is synchronous, so only the decrypt path needs to
    // allocate a replacement buffer.
    NSData *chunk = data;
    if (context.deezerDecrypt && context.deezerKeyData.length == 16) {
        [context.decryptRemainder appendData:data];
        NSMutableData *plain = [NSMutableData data];
        const unsigned char *key = (const unsigned char *)context.deezerKeyData.bytes;
        while (context.decryptRemainder.length >= 2048) {
            unsigned char chunkBytes[2048];
            [context.decryptRemainder getBytes:chunkBytes range:NSMakeRange(0, 2048)];
            unsigned long chunkIndex = (unsigned long)(context.decryptOffset / 2048);
            if (waDeezerDecryptChunk(key, chunkIndex, chunkBytes, 2048) != 0) {
                [[waDebugLog sharedLog] log:@"Download decrypt failed at chunk %lu", chunkIndex];
                [task cancel];
                [self URLSession:session task:task didCompleteWithError:nil];
                return;
            }
            [plain appendBytes:chunkBytes length:2048];
            [context.decryptRemainder replaceBytesInRange:NSMakeRange(0, 2048) withBytes:NULL length:0];
            context.decryptOffset += 2048;
        }
        if (!plain.length) return;
        chunk = plain;
    }
    dispatch_sync(context.fileQueue, ^{
        if ([context isCancelled]) { wrote = NO; return; }
        @try { [context.handle writeData:chunk]; }
        @catch (NSException *exception) { (void)exception; wrote = NO; }
    });
    if (!wrote) { [task cancel]; [self URLSession:session task:task didCompleteWithError:nil]; return; }
    context.bytesReceived += chunk.length;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - context.lastProgressDispatch < 0.25) return;
    context.lastProgressDispatch = now;
    unsigned long long bytes = context.bytesReceived;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([context isCancelled] || self.downloads[context.download.identifier] != context.download) return;
        context.download.bytesReceived = bytes;
        context.download.bytesExpected = context.bytesExpected;
        context.download.progress = context.bytesExpected > 0 ? MIN(1.0f, (float)bytes / (float)context.bytesExpected) : 0.0f;
        [self notifyChangeForDownload:context.download event:@"progress"];
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    waDownloadConnectionContext *context = [self contextForTask:task];
    if (!context || ![context beginFinalization]) return;
    if (error) {
        dispatch_sync(context.fileQueue, ^{ [context.handle closeFile]; });
        dispatch_async(dispatch_get_main_queue(), ^{ [self finishContext:context task:task succeeded:NO]; });
        return;
    }
    if (context.deezerDecrypt && context.decryptRemainder.length && context.deezerKeyData.length == 16) {
        NSUInteger rest = context.decryptRemainder.length;
        NSMutableData *tail = [NSMutableData dataWithData:context.decryptRemainder];
        waDeezerDecryptChunk((const unsigned char *)context.deezerKeyData.bytes, (unsigned long)(context.decryptOffset / 2048), tail.mutableBytes, rest);
        [context.decryptRemainder setLength:0];
        context.decryptOffset += rest;
        dispatch_sync(context.fileQueue, ^{
            if (![context isCancelled]) {
                @try { [context.handle writeData:tail]; context.bytesReceived += tail.length; }
                @catch (NSException *exception) { (void)exception; }
            }
        });
    }
    NSString *filePath = context.finalPath;
    __block BOOL moved = NO;
    dispatch_sync(context.fileQueue, ^{
        [context.handle closeFile];
        if (![context isCancelled]) {
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:NULL];
            moved = [[NSFileManager defaultManager] moveItemAtPath:context.temporaryPath toPath:filePath error:NULL];
        }
        if (!moved) [[NSFileManager defaultManager] removeItemAtPath:context.temporaryPath error:NULL];
    });
    dispatch_async(dispatch_get_main_queue(), ^{ [self finishContext:context task:task succeeded:moved]; });
}

- (void)finishContext:(waDownloadConnectionContext *)context task:(NSURLSessionTask *)task succeeded:(BOOL)succeeded {
    if (!context || [context isCancelled]) return;
    waDownload *download = context.download;
    if (self.downloads[download.identifier] != download) return;
    download.bytesReceived = context.bytesReceived;
    download.bytesExpected = context.bytesExpected;
    download.state = succeeded ? waDownloadStateCompleted : waDownloadStateFailed;
    if (succeeded) download.progress = 1.0f;
    if (download.bytesExpected <= 0) download.bytesExpected = (long long)download.bytesReceived;
    [self endNetworkActivityForContext:self.connections[[self keyForTask:task]]];
    [self.connections removeObjectForKey:[self keyForTask:task]];
    [self.lastProgressNotifications removeObjectForKey:download.identifier];
    if (!self.connections.count && self.backgroundTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
    }
    [self persist];
    [self notifyChangeForDownload:download];
    [self refreshDownloadedBytes];
    [self promoteQueuedDownloads];
}

- (waDownload *)downloadForIdentifier:(NSString *)identifier {
    if (!identifier.length) return nil;
    NSString *key = [identifier hasPrefix:@"deezer:"] ? identifier : [@"deezer:" stringByAppendingString:identifier];
    return self.downloads[key];
}
- (waDownloadState)stateForIdentifier:(NSString *)identifier { waDownload *download = [self downloadForIdentifier:identifier]; return download ? download.state : waDownloadStateNotFound; }
- (NSString *)localPathForIdentifier:(NSString *)identifier {
    waDownload *download = [self downloadForIdentifier:identifier];
    if (!download || download.state != waDownloadStateCompleted) return nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:download.filePath]) return download.filePath;
    // Fallback for legacy .audio files
    NSString *legacy = [[download.filePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"audio"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:legacy]) return legacy;
    NSString *mp3 = [[download.filePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"mp3"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:mp3]) return mp3;
    return nil;
}

- (NSUInteger)completedCount {
    NSUInteger count = 0;
    for (waDownload *download in self.downloads.allValues) if ([self localPathForIdentifier:download.identifier]) count++;
    return count;
}

- (NSUInteger)activeDownloadCount {
    NSUInteger count = 0;
    for (waDownload *download in self.downloads.allValues) {
        if (download.state == waDownloadStateQueued || download.state == waDownloadStateDownloading) count++;
    }
    return count;
}

- (NSDictionary *)preferredActiveDownloadGroup {
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    NSUInteger ungroupedActiveCount = 0;
    for (waDownload *download in self.downloads.allValues) {
        if (download.state != waDownloadStateQueued && download.state != waDownloadStateDownloading) continue;
        BOOL isGroup = (download.currentCategory == waDownloadCategoryAlbum || download.currentCategory == waDownloadCategoryPlaylist) && download.currentContextIdentifier.length && download.currentGroupTitle.length;
        if (!isGroup) {
            ungroupedActiveCount++;
            continue;
        }
        NSString *key = [NSString stringWithFormat:@"%ld|%@|%@", (long)download.currentCategory, download.currentContextIdentifier, download.currentGroupTitle];
        NSMutableDictionary *group = groups[key];
        if (!group) {
            group = [@{ @"category": @(download.currentCategory),
                        @"context": download.currentContextIdentifier,
                        @"title": download.currentGroupTitle,
                        @"activeCount": @0 } mutableCopy];
            groups[key] = group;
        }
        group[@"activeCount"] = @([group[@"activeCount"] unsignedIntegerValue] + 1);
    }
    // Only expose a group title when the active queue represents one complete
    // album/playlist batch. If the user starts unrelated downloads together,
    // keep the neutral Library title and use the global aggregate instead.
    if (ungroupedActiveCount || groups.count != 1) return nil;
    return [groups.allValues objectAtIndex:0];
}

- (NSArray *)downloadsForProgressGroup:(NSDictionary *)group {
    if (!group) return @[];
    waDownloadCategory category = [group[@"category"] integerValue];
    NSString *context = group[@"context"];
    if (!context.length) return @[];
    NSMutableArray *downloads = [NSMutableArray array];
    for (waDownload *download in self.downloads.allValues) {
        if (download.state == waDownloadStateCancelled) continue;
        if ([[download contextIdentifiersForCategory:category] containsObject:context]) [downloads addObject:download];
    }
    return downloads;
}

- (float)progressForDownloads:(NSArray *)downloads {
    if (!downloads.count) return 0.0f;

    // Weight by bytes when every item has a known size. If a CDN does not
    // provide Content-Length, use a per-item average so an unknown queued item
    // cannot make the bar jump to 100% while it is still pending.
    unsigned long long totalExpected = 0;
    unsigned long long totalReceived = 0;
    BOOL hasUnknownSize = NO;
    float perItemTotal = 0.0f;
    for (waDownload *download in downloads) {
        float itemProgress = MAX(0.0f, MIN(1.0f, download.progress));
        if (download.state == waDownloadStateFailed) itemProgress = 0.0f;
        if (download.bytesExpected > 0) {
            unsigned long long expected = (unsigned long long)download.bytesExpected;
            unsigned long long received = MIN(expected, download.bytesReceived);
            totalExpected += expected;
            totalReceived += received;
            itemProgress = MIN(1.0f, (float)received / (float)expected);
        } else {
            hasUnknownSize = YES;
        }
        perItemTotal += itemProgress;
    }
    if (!hasUnknownSize && totalExpected > 0) return MIN(1.0f, (float)totalReceived / (float)totalExpected);
    return MIN(1.0f, perItemTotal / (float)downloads.count);
}

- (NSString *)activeDownloadGroupTitle {
    return [self preferredActiveDownloadGroup][@"title"];
}

- (float)overallDownloadProgress {
    NSDictionary *group = [self preferredActiveDownloadGroup];
    if (group) return [self progressForDownloads:[self downloadsForProgressGroup:group]];

    NSMutableArray *active = [NSMutableArray array];
    for (waDownload *download in self.downloads.allValues) {
        if (download.state == waDownloadStateQueued || download.state == waDownloadStateDownloading) [active addObject:download];
    }
    // Keep completed/failed members of the current solo-song session in the
    // denominator so a multi-song queue also advances once from 0 to 100%.
    for (NSString *identifier in self.soloSessionIdentifiers) {
        waDownload *download = self.downloads[identifier];
        if (!download || download.state == waDownloadStateCancelled || [active containsObject:download]) continue;
        [active addObject:download];
    }
    return [self progressForDownloads:active];
}

- (NSArray *)allDownloads {
    return [self.downloads.allValues sortedArrayUsingComparator:^NSComparisonResult(waDownload *a, waDownload *b) {
        return [a.identifier compare:b.identifier];
    }];
}

- (NSArray *)downloadsForCategory:(waDownloadCategory)category {
    NSMutableArray *result = [NSMutableArray array];
    for (waDownload *download in [self allDownloads]) if ([download belongsToCategory:category]) [result addObject:download];
    return result;
}

- (NSDictionary *)downloadsByCategory {
    return @{
        @(waDownloadCategorySong): [self downloadsForCategory:waDownloadCategorySong],
        @(waDownloadCategoryAlbum): [self downloadsForCategory:waDownloadCategoryAlbum],
        @(waDownloadCategoryPlaylist): [self downloadsForCategory:waDownloadCategoryPlaylist]
    };
}

- (void)refreshDownloadedBytes {
    NSArray *downloads = [self.downloads.allValues copy];
    dispatch_async(self.statisticsQueue, ^{
        unsigned long long total = 0;
        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (waDownload *download in downloads) {
            if ([fileManager fileExistsAtPath:download.filePath]) total += [[fileManager attributesOfItemAtPath:download.filePath error:NULL] fileSize];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ self.downloadedBytesValue = total; });
    });
}

- (unsigned long long)downloadedBytes { return self.downloadedBytesValue; }

- (void)deleteDownloadsWithCompletion:(void (^)(NSError *error))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self deleteDownloadsWithCompletion:completion]; });
        return;
    }
    NSArray *contexts = [self.connections.allValues copy];
    for (NSNumber *key in [self.connections allKeys]) {
        NSURLSessionDataTask *task = self.connections[key][@"task"];
        [self.connections[key][@"context"] cancel];
        [task cancel];
        [self endNetworkActivityForContext:self.connections[key]];
    }
    [self.connections removeAllObjects];
    [self.pendingIdentifiers removeAllObjects];
    NSArray *downloads = [self.downloads.allValues copy];
    [self.downloads removeAllObjects];
    self.downloadedBytesValue = 0;
    [self notifyChangeForDownload:nil];

    NSString *plistPath = [[self storePath] stringByAppendingPathComponent:@"downloads.plist"];
    dispatch_async(self.fileQueue, ^{
        __block NSError *deletionError = nil;
        NSFileManager *fileManager = [NSFileManager defaultManager];
        for (NSDictionary *context in contexts) [context[@"handle"] closeFile];
        for (waDownload *download in downloads) {
            NSArray *paths = @[download.filePath ?: @"", [download.filePath stringByAppendingString:@".part"] ?: @""];
            for (NSString *path in paths) {
                if (!path.length || ![fileManager fileExistsAtPath:path]) continue;
                NSError *error = nil;
                if (![fileManager removeItemAtPath:path error:&error] && !deletionError) deletionError = error;
            }
        }
        dispatch_async(self.persistenceQueue, ^{
            if (![@{} writeToFile:plistPath atomically:YES] && !deletionError) deletionError = [NSError errorWithDomain:@"com.bytebox.wave.downloads" code:1 userInfo:@{ NSLocalizedDescriptionKey: @"Unable to update the download store." }];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(deletionError); });
        });
    });
}

- (void)deleteDownloads { [self deleteDownloadsWithCompletion:nil]; }

- (void)deleteDownloadWithIdentifier:(NSString *)identifier completion:(void (^)(NSError *error))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self deleteDownloadWithIdentifier:identifier completion:completion]; });
        return;
    }
    if (!identifier.length) { if (completion) completion(nil); return; }
    if (![identifier hasPrefix:@"deezer:"]) identifier = [@"deezer:" stringByAppendingString:identifier];
    waDownload *download = self.downloads[identifier];
    if (!download) { if (completion) completion(nil); return; }
    // Cancel active connection if any
    for (NSNumber *key in [self.connections allKeys]) {
        NSDictionary *context = self.connections[key];
        if (context[@"download"] != download) continue;
        NSURLSessionDataTask *task = context[@"task"];
        [context[@"context"] cancel];
        [task cancel];
        [self endNetworkActivityForContext:context];
        NSFileHandle *handle = context[@"handle"];
        dispatch_sync(self.fileQueue, ^{
            [handle closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:[download.filePath stringByAppendingString:@".part"] error:NULL];
        });
        [self.connections removeObjectForKey:key];
    }
    [self.pendingIdentifiers removeObject:identifier];
    [self.soloSessionIdentifiers removeObject:identifier];
    [self.downloads removeObjectForKey:identifier];
    [self refreshDownloadedBytes];
    [self notifyChangeForDownload:nil];
    NSString *filePath = download.filePath;
    NSString *artworkPath = download.artworkFilePath;
    NSString *plistPath = [[self storePath] stringByAppendingPathComponent:@"downloads.plist"];
    NSDictionary *saved = [self serializedDownloads];
    dispatch_async(self.fileQueue, ^{
        __block NSError *deletionError = nil;
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *path in @[filePath ?: @"", [filePath stringByAppendingString:@".part"] ?: @"", artworkPath ?: @""]) {
            if (!path.length || ![fm fileExistsAtPath:path]) continue;
            NSError *error = nil;
            if (![fm removeItemAtPath:path error:&error] && !deletionError) deletionError = error;
        }
        // Also try legacy .audio
        NSString *legacy = [[filePath stringByDeletingPathExtension] stringByAppendingPathExtension:@"audio"];
        if (legacy.length && ![legacy isEqualToString:filePath] && [fm fileExistsAtPath:legacy]) {
            NSError *error = nil;
            if (![fm removeItemAtPath:legacy error:&error] && !deletionError) deletionError = error;
        }
        dispatch_async(self.persistenceQueue, ^{
            if (![saved writeToFile:plistPath atomically:YES] && !deletionError) deletionError = [NSError errorWithDomain:@"com.bytebox.wave.downloads" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Unable to update store."}];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(deletionError); });
        });
    });
}

@end
