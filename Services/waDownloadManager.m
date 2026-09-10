#import "waDownloadManager.h"
#import "../Models/waPreferences.h"
#import "waDeezerStreamClient.h"
#import "../Models/waMediaItem.h"
#import "waAPIClient.h" // for waNetworkActivityBegin/End only (serverless shim)
#import "waDeezerBlowfish.h"
#import "waDebugLog.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

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

@interface waDownloadManager ()
@property (nonatomic, strong) NSMutableDictionary *downloads;
@property (nonatomic, strong) NSMutableDictionary *connections;
@property (nonatomic, strong) NSMutableArray *pendingIdentifiers;
@property (nonatomic, strong) NSMutableSet *resolvingIdentifiers;
@property (nonatomic, strong) dispatch_queue_t persistenceQueue;
@property (nonatomic, strong) dispatch_queue_t fileQueue;
@property (nonatomic, strong) dispatch_queue_t statisticsQueue;
@property (nonatomic, strong) NSOperationQueue *artworkQueue;
@property (nonatomic, assign) unsigned long long downloadedBytesValue;
@property (nonatomic, assign) UIBackgroundTaskIdentifier backgroundTask;
@property (nonatomic, strong) NSMutableDictionary *lastProgressNotifications;
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
        _persistenceQueue = dispatch_queue_create("com.bytebox.wave.downloads.persistence", DISPATCH_QUEUE_SERIAL);
        _fileQueue = dispatch_queue_create("com.bytebox.wave.downloads.files", DISPATCH_QUEUE_SERIAL);
        _statisticsQueue = dispatch_queue_create("com.bytebox.wave.downloads.statistics", DISPATCH_QUEUE_SERIAL);
        _artworkQueue = [[NSOperationQueue alloc] init];
        _artworkQueue.maxConcurrentOperationCount = 2;
        _backgroundTask = UIBackgroundTaskInvalid;
        _lastProgressNotifications = [[NSMutableDictionary alloc] init];
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

            if (download.state == waDownloadStateDownloading) download.state = waDownloadStateQueued;
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
    // waDownload is initialized as Queued so restored downloads can keep that
    // state. A newly created object is not yet in pendingIdentifiers, though,
    // and must still be added before it can be promoted and started.
    if ((isNewDownload || !active) && !available) {
        [[NSFileManager defaultManager] removeItemAtPath:[download.filePath stringByAppendingString:@".part"] error:NULL];
        download.ticketURL = ticketURL;
        download.downloadQuality = [waPreferences sharedPreferences].downloadQuality;
        download.state = waDownloadStateQueued;
        download.progress = 0.0f;
        download.bytesReceived = 0;
        download.bytesExpected = 0;
        if (![self.pendingIdentifiers containsObject:identifier]) [self.pendingIdentifiers addObject:identifier];
    }
    [self persist];
    [self notifyChangeForDownload:download];
    [self promoteQueuedDownloads];
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
        [strongSelf promoteQueuedDownloads];
        if (strongSelf.downloads[download.identifier] != download || download.state != waDownloadStateDownloading) return;
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
            return;
        }
        [[waDebugLog sharedLog] log:@"Direct download failed (%@), serverless - no fallback", error.localizedDescription ?: @"unknown"];
        [strongSelf failDownloadBeforeConnection:download];
    }];
}

- (void)beginConnectionToURL:(NSURL *)url download:(waDownload *)download deezerDecrypt:(BOOL)deezerDecrypt rawID:(NSString *)rawID {
    if (!url) { [self failDownloadBeforeConnection:download]; return; }
    NSString *temp = [download.filePath stringByAppendingString:@".part"];
    [[NSFileManager defaultManager] removeItemAtPath:temp error:NULL];
    if (![[NSFileManager defaultManager] createFileAtPath:temp contents:nil attributes:nil]) { [self failDownloadBeforeConnection:download]; return; }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:temp];
    if (!handle) { [[NSFileManager defaultManager] removeItemAtPath:temp error:NULL]; [self failDownloadBeforeConnection:download]; return; }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    request.allowsCellularAccess = [waPreferences sharedPreferences].cellularDataAllowed;
    download.state = waDownloadStateDownloading;
    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    if (!connection) { [handle closeFile]; [self failDownloadBeforeConnection:download]; return; }
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.maxConcurrentOperationCount = 1;
    waDownloadConnectionContext *context = [[waDownloadConnectionContext alloc] init];
    context.download = download;
    context.handle = handle;
    context.temporaryPath = temp;
    context.finalPath = download.filePath;
    context.deezerDecrypt = deezerDecrypt;
    context.decryptOffset = 0;
    context.decryptRemainder = [NSMutableData data];
    if (deezerDecrypt && rawID.length) {
        unsigned char key[16];
        waDeezerDeriveKey([rawID UTF8String], key);
        context.deezerKeyData = [NSData dataWithBytes:key length:16];
    }
    objc_setAssociatedObject(connection, @selector(contextForConnection:), context, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [connection setDelegateQueue:delegateQueue];
    NSValue *connectionKey = [NSValue valueWithNonretainedObject:connection];
    self.connections[connectionKey] = @{ @"download": download, @"handle": handle, @"connection": connection, @"context": context, @"delegateQueue": delegateQueue, @"networkActivity": @YES };
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
    [connection start];
}

- (NSValue *)keyForConnection:(NSURLConnection *)connection { return [NSValue valueWithNonretainedObject:connection]; }
- (waDownloadConnectionContext *)contextForConnection:(NSURLConnection *)connection { return objc_getAssociatedObject(connection, @selector(contextForConnection:)); }

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
    for (NSValue *key in [self.connections allKeys]) {
        NSURLConnection *connection = [key nonretainedObjectValue];
        NSDictionary *context = self.connections[key];
        if (context[@"download"] != download) continue;
        [connection cancel];
        [self endNetworkActivityForContext:context];
        [context[@"context"] cancel];
        NSFileHandle *handle = context[@"handle"];
        dispatch_sync(self.fileQueue, ^{
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

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    waDownloadConnectionContext *context = [self contextForConnection:connection];
    if (!context || [context isCancelled]) return;
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (status < 200 || status >= 300) {
            [connection cancel];
            [self connection:connection didFailWithError:nil];
            return;
        }
    }
    context.bytesReceived = 0;
    context.bytesExpected = response.expectedContentLength > 0 ? response.expectedContentLength : 0;
    context.decryptOffset = 0;
    [context.decryptRemainder setLength:0];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([context isCancelled] || self.downloads[context.download.identifier] != context.download) return;
        NSString *servedQuality = [(NSHTTPURLResponse *)response allHeaderFields][@"X-Audio-Quality"];
        if ([servedQuality isEqualToString:@"128"]) context.download.downloadQuality = 0;
        else if ([servedQuality isEqualToString:@"320"]) context.download.downloadQuality = 1;
        else if ([servedQuality.lowercaseString isEqualToString:@"lossless"]) context.download.downloadQuality = 2;
        context.download.bytesReceived = 0;
        context.download.bytesExpected = context.bytesExpected;
        context.download.progress = 0.0f;
        [self.lastProgressNotifications removeObjectForKey:context.download.identifier];
        [self persist];
        [self notifyChangeForDownload:context.download];
    });
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    waDownloadConnectionContext *context = [self contextForConnection:connection];
    if (!context || [context isCancelled]) return;
    __block BOOL wrote = YES;
    NSData *chunk = [data copy];
    if (context.deezerDecrypt && context.deezerKeyData.length == 16) {
        [context.decryptRemainder appendData:chunk];
        NSMutableData *plain = [NSMutableData data];
        const unsigned char *key = (const unsigned char *)context.deezerKeyData.bytes;
        while (context.decryptRemainder.length >= 2048) {
            unsigned char chunkBytes[2048];
            [context.decryptRemainder getBytes:chunkBytes range:NSMakeRange(0, 2048)];
            unsigned long chunkIndex = (unsigned long)(context.decryptOffset / 2048);
            if (waDeezerDecryptChunk(key, chunkIndex, chunkBytes, 2048) != 0) {
                [[waDebugLog sharedLog] log:@"Download decrypt failed at chunk %lu", chunkIndex];
                [connection cancel];
                [self connection:connection didFailWithError:nil];
                return;
            }
            [plain appendBytes:chunkBytes length:2048];
            [context.decryptRemainder replaceBytesInRange:NSMakeRange(0, 2048) withBytes:NULL length:0];
            context.decryptOffset += 2048;
        }
        if (!plain.length) return;
        chunk = plain;
    }
    dispatch_sync(self.fileQueue, ^{
        if ([context isCancelled]) { wrote = NO; return; }
        @try { [context.handle writeData:chunk]; }
        @catch (NSException *exception) { (void)exception; wrote = NO; }
    });
    if (!wrote) { [connection cancel]; [self connection:connection didFailWithError:nil]; return; }
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

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    waDownloadConnectionContext *context = [self contextForConnection:connection];
    if (!context || ![context beginFinalization]) return;
    if (context.deezerDecrypt && context.decryptRemainder.length && context.deezerKeyData.length == 16) {
        NSUInteger rest = context.decryptRemainder.length;
        NSMutableData *tail = [NSMutableData dataWithData:context.decryptRemainder];
        waDeezerDecryptChunk((const unsigned char *)context.deezerKeyData.bytes, (unsigned long)(context.decryptOffset / 2048), tail.mutableBytes, rest);
        [context.decryptRemainder setLength:0];
        context.decryptOffset += rest;
        dispatch_sync(self.fileQueue, ^{
            if (![context isCancelled]) {
                @try { [context.handle writeData:tail]; context.bytesReceived += tail.length; }
                @catch (NSException *exception) { (void)exception; }
            }
        });
    }
    NSString *filePath = context.finalPath;
    __block BOOL moved = NO;
    dispatch_sync(self.fileQueue, ^{
        [context.handle closeFile];
        if (![context isCancelled]) {
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:NULL];
            moved = [[NSFileManager defaultManager] moveItemAtPath:context.temporaryPath toPath:filePath error:NULL];
        }
        if (!moved) [[NSFileManager defaultManager] removeItemAtPath:context.temporaryPath error:NULL];
    });
    dispatch_async(dispatch_get_main_queue(), ^{ [self finishContext:context connection:connection succeeded:moved]; });
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    (void)error;
    waDownloadConnectionContext *context = [self contextForConnection:connection];
    if (!context || ![context beginFinalization]) return;
    dispatch_sync(self.fileQueue, ^{
        [context.handle closeFile];
        [[NSFileManager defaultManager] removeItemAtPath:context.temporaryPath error:NULL];
    });
    dispatch_async(dispatch_get_main_queue(), ^{ [self finishContext:context connection:connection succeeded:NO]; });
}

- (void)finishContext:(waDownloadConnectionContext *)context connection:(NSURLConnection *)connection succeeded:(BOOL)succeeded {
    if (!context || [context isCancelled]) return;
    waDownload *download = context.download;
    if (self.downloads[download.identifier] != download) return;
    download.bytesReceived = context.bytesReceived;
    download.bytesExpected = context.bytesExpected;
    download.state = succeeded ? waDownloadStateCompleted : waDownloadStateFailed;
    if (succeeded) download.progress = 1.0f;
    if (download.bytesExpected <= 0) download.bytesExpected = (long long)download.bytesReceived;
    [self endNetworkActivityForContext:self.connections[[self keyForConnection:connection]]];
    [self.connections removeObjectForKey:[self keyForConnection:connection]];
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
    for (NSValue *key in [self.connections allKeys]) {
        NSURLConnection *connection = [key nonretainedObjectValue];
        [self.connections[key][@"context"] cancel];
        [connection cancel];
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
    for (NSValue *key in [self.connections allKeys]) {
        NSDictionary *context = self.connections[key];
        if (context[@"download"] != download) continue;
        NSURLConnection *connection = [key nonretainedObjectValue];
        [context[@"context"] cancel];
        [connection cancel];
        [self endNetworkActivityForContext:context];
        NSFileHandle *handle = context[@"handle"];
        dispatch_sync(self.fileQueue, ^{
            [handle closeFile];
            [[NSFileManager defaultManager] removeItemAtPath:[download.filePath stringByAppendingString:@".part"] error:NULL];
        });
        [self.connections removeObjectForKey:key];
    }
    [self.pendingIdentifiers removeObject:identifier];
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
