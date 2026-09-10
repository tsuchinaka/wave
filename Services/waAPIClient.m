#import "waAPIClient.h"
#import "waKeychainStore.h"
#import "waDeezerClient.h"
#import "waDeezerStreamClient.h"
#import "../Models/waPreferences.h"
#import <UIKit/UIKit.h>

static NSString * const waAPIErrorDomain = @"com.bytebox.wave.api";

static dispatch_queue_t waAPIWorkQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.bytebox.wave.api", DISPATCH_QUEUE_CONCURRENT);
    });
    return queue;
}

static NSOperationQueue *waAPICompletionQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 4;
    });
    return queue;
}

static NSInteger waNetworkActivityCount = 0;
void waNetworkActivityBegin(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        waNetworkActivityCount += 1;
        [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    });
}
void waNetworkActivityEnd(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        waNetworkActivityCount = MAX(0, waNetworkActivityCount - 1);
        [UIApplication sharedApplication].networkActivityIndicatorVisible = waNetworkActivityCount > 0;
    });
}

__attribute__((unused)) static NSString *waBase64String(NSData *data) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *bytes = data.bytes;
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger index = 0; index < data.length; index += 3) {
        NSUInteger remaining = data.length - index;
        unsigned int value = bytes[index] << 16;
        if (remaining > 1) value |= bytes[index + 1] << 8;
        if (remaining > 2) value |= bytes[index + 2];
        [result appendFormat:@"%c%c%c%c", alphabet[(value >> 18) & 0x3f], alphabet[(value >> 12) & 0x3f], remaining > 1 ? alphabet[(value >> 6) & 0x3f] : '=', remaining > 2 ? alphabet[value & 0x3f] : '='];
    }
    return result;
}

static id waJSONObjectFromData(NSData *data) {
    if (!data.length) return nil;
    @try {
        return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

static NSString *waStringValue(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

typedef id (^waAPIResponseProcessor)(NSData *data, NSHTTPURLResponse *response, NSError **processingError);

@interface waAPIClient ()
@property (nonatomic, strong) NSMutableDictionary *pendingGETCompletions;
@end

@implementation waAPIClient
+ (waAPIClient *)sharedClient { static waAPIClient *client; static dispatch_once_t onceToken; dispatch_once(&onceToken, ^{ client = [[self alloc] init]; }); return client; }
- (id)init {
    if ((self = [super init])) _pendingGETCompletions = [NSMutableDictionary dictionary];
    return self;
}
- (BOOL)isAuthenticated { return [[waDeezerClient sharedClient] isAuthenticated]; }
- (NSString *)pathWithSelectedSource:(NSString *)path {
    if (!path.length) return path;
    // Use a dummy base to parse query items reliably on iOS 6.
    NSURL *dummy = [NSURL URLWithString:[NSString stringWithFormat:@"http://localhost%@", [path hasPrefix:@"/"] ? path : [@"/" stringByAppendingString:path]]];
    NSString *query = dummy.query;
    if (query.length) {
        for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
            NSArray *parts = [pair componentsSeparatedByString:@"="];
            NSString *key = parts.count ? [parts objectAtIndex:0] : nil;
            if ([key isEqualToString:@"source"]) return path;
        }
    }
    NSString *source = @"deezer";
    NSString *separator = [path rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&";
    return [NSString stringWithFormat:@"%@%@source=%@", path, separator, source];
}
- (NSURL *)urlForPath:(NSString *)path {
    NSString *base = self.baseURL.length ? self.baseURL : [waPreferences sharedPreferences].apiURL;
    if (!base.length) base = @"http://192.168.1.17";
    NSURL *u = [NSURL URLWithString:base];
    if (!u.scheme.length || !u.host.length) return nil;
    NSString *host = u.host;
    if ([host rangeOfString:@":"].location != NSNotFound && ![host hasPrefix:@"["]) host = [NSString stringWithFormat:@"[%@]", host];
    NSString *authority = [NSString stringWithFormat:@"%@://%@", u.scheme, host];
    // An explicit port in the URL wins; the separate Port setting is omitted then.
    NSNumber *port = u.port ?: (self.port ? @(self.port) : nil);
    if (port.unsignedIntegerValue) authority = [authority stringByAppendingFormat:@":%lu", (unsigned long)port.unsignedIntegerValue];
    NSString *basePath = u.path ?: @"";
    while ([basePath hasSuffix:@"/"] && basePath.length) basePath = [basePath substringToIndex:basePath.length - 1];
    NSString *relativePath = [path hasPrefix:@"/"] ? path : [@"/" stringByAppendingString:path ?: @""];
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@%@%@", authority, basePath, relativePath]];
}
- (NSURL *)URLForPath:(NSString *)path { return [self urlForPath:path]; }
- (void)requestPath:(NSString *)path method:(NSString *)method body:(NSDictionary *)body authenticated:(BOOL)authenticated process:(waAPIResponseProcessor)processor completion:(void (^)(id result, NSError *error))completion {
    [self requestPathInBackground:path method:method body:body authenticated:authenticated completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        NSError *processingError = nil;
        id result = processor ? processor(data, response, &processingError) : nil;
        NSError *finalError = error ?: processingError;
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(result, finalError); });
    }];
}
- (void)requestPathInBackground:(NSString *)path method:(NSString *)method body:(NSDictionary *)body authenticated:(BOOL)authenticated completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
    dispatch_async(waAPIWorkQueue(), ^{
         NSString *selectedPath = [self pathWithSelectedSource:path];
         NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self urlForPath:selectedPath]];
        NSString *requestMethod = method ?: @"GET";
        request.HTTPMethod = requestMethod;
        request.timeoutInterval = 30;
        request.cachePolicy = [requestMethod isEqualToString:@"GET"] ? NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringLocalCacheData;
        request.allowsCellularAccess = [waPreferences sharedPreferences].cellularDataAllowed;
        [request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        if (body) {
            request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
            [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        }
        NSString *token = authenticated ? [waKeychainStore token] : nil;
        if (token.length) [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
        NSString *coalescingKey = nil;
        if ([requestMethod isEqualToString:@"GET"] && request.URL) {
            coalescingKey = [NSString stringWithFormat:@"%@|%@|%@", request.URL.absoluteString, authenticated ? @"auth" : @"public", token ?: @""];
        }
        if (coalescingKey.length) {
            @synchronized (self) {
                NSMutableArray *waiters = self.pendingGETCompletions[coalescingKey];
                if (waiters) {
                    if (completion) [waiters addObject:[completion copy]];
                    return;
                }
                NSMutableArray *initialWaiters = [NSMutableArray array];
                if (completion) [initialWaiters addObject:[completion copy]];
                self.pendingGETCompletions[coalescingKey] = initialWaiters;
            }
        }
        waNetworkActivityBegin();
        [NSURLConnection sendAsynchronousRequest:request queue:waAPICompletionQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            NSError *requestError = error;
            // On iOS 6, CFNetwork can surface an HTTP 401 as
            // NSURLErrorUserCancelledAuthentication before the application
            // gets a chance to expose the server's JSON error message.
            if (http.statusCode == 401 && [requestError.domain isEqualToString:NSURLErrorDomain] && requestError.code == NSURLErrorUserCancelledAuthentication) requestError = nil;
            if (!requestError && !http) {
                requestError = [NSError errorWithDomain:waAPIErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey:@"The server returned an invalid response."}];
            }
            if (!requestError && (http.statusCode < 200 || http.statusCode >= 300)) {
                id json = waJSONObjectFromData(data);
                NSString *message = [json isKindOfClass:[NSDictionary class]] ? waStringValue(json[@"error"]) : nil;
                requestError = [NSError errorWithDomain:waAPIErrorDomain code:http.statusCode userInfo:@{NSLocalizedDescriptionKey: message ?: @"HTTP request failed"}];
                if (http.statusCode == 401) {
                    [waKeychainStore clearToken];
                }
            }
            waNetworkActivityEnd();
            if (coalescingKey.length) {
                NSArray *waiters = nil;
                @synchronized (self) {
                    waiters = [self.pendingGETCompletions[coalescingKey] copy];
                    [self.pendingGETCompletions removeObjectForKey:coalescingKey];
                }
                for (void (^waiter)(NSData *, NSHTTPURLResponse *, NSError *) in waiters) waiter(data, http, requestError);
            } else if (completion) completion(data, http, requestError);
        }];
    });
}
- (void)requestPath:(NSString *)path method:(NSString *)method body:(NSDictionary *)body authenticated:(BOOL)authenticated completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion {
    [self requestPathInBackground:path method:method body:body authenticated:authenticated completion:^(NSData *data, NSHTTPURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(data, response, error); });
    }];
}
- (void)homeWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
    [[waDeezerClient sharedClient] homeWithCompletion:completion];
}
- (void)flowWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDeezerClient sharedClient] flowWithCompletion:completion];
}
- (void)flowConfigWithIdentifier:(NSString *)identifier completion:(void (^)(NSArray *, NSError *))completion {
    [[waDeezerClient sharedClient] flowConfigWithIdentifier:identifier completion:completion];
}
- (void)flowConfigsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDeezerClient sharedClient] flowConfigsWithCompletion:completion];
}
- (void)pingWithLatencyCompletion:(void (^)(NSTimeInterval, NSError *))completion {
    // Serverless: ping Deezer directly instead of bytebox
    CFTimeInterval started = CFAbsoluteTimeGetCurrent();
    NSURL *url = [NSURL URLWithString:@"https://api.deezer.com"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
    [NSURLConnection sendAsynchronousRequest:request queue:waAPICompletionQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        (void)data; (void)response;
        NSTimeInterval milliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000.0;
        if (completion) completion(milliseconds, error);
    }];
}
- (void)likedSongsWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
    [[waDeezerClient sharedClient] likedSongsWithCompletion:^(NSArray *songs, NSError *error) { if (completion) completion(@{ @"songs": songs ?: @[] }, error); }];
}
- (void)setLiked:(BOOL)liked song:(waMediaItem *)song completion:(void (^)(BOOL, NSError *))completion {
    NSString *sourceIdentifier = song.trackId.length ? song.trackId : song.identifier;
    if (!sourceIdentifier.length) { NSError *error = [NSError errorWithDomain:waAPIErrorDomain code:400 userInfo:@{NSLocalizedDescriptionKey:@"Missing song id"}]; dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO, error); }); return; }
    NSString *identifier = [sourceIdentifier hasPrefix:@"deezer:"] ? [sourceIdentifier substringFromIndex:7] : sourceIdentifier;
    [[waDeezerClient sharedClient] setLiked:liked songIdentifier:identifier completion:^(NSError *error) { if (completion) completion(!error, error); }];
}

- (void)likedAlbumsWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
    [[waDeezerClient sharedClient] likedAlbumsWithCompletion:^(NSArray *albums, NSError *error) { if (completion) completion(@{ @"albums": albums ?: @[] }, error); }];
}

- (void)likedArtistsWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
    [[waDeezerClient sharedClient] likedArtistsWithCompletion:^(NSArray *artists, NSError *error) { if (completion) completion(@{ @"artists": artists ?: @[] }, error); }];
}

- (void)setLiked:(BOOL)liked artist:(waMediaItem *)artist completion:(void (^)(BOOL, NSError *))completion {
    NSString *identifier = artist.artistIdentifier.length ? artist.artistIdentifier : artist.identifier;
    if ([identifier hasPrefix:@"deezer:"]) identifier = [identifier substringFromIndex:7];
    if (!identifier.length) {
        NSError *error = [NSError errorWithDomain:waAPIErrorDomain code:400 userInfo:@{NSLocalizedDescriptionKey:@"Missing artist id"}];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO, error); });
        return;
    }
    [[waDeezerClient sharedClient] setLiked:liked artistIdentifier:identifier completion:^(NSError *error) { if (completion) completion(!error, error); }];
}

- (void)setLiked:(BOOL)liked album:(waMediaItem *)album completion:(void (^)(BOOL, NSError *))completion {
    NSString *identifier = album.albumIdentifier.length ? album.albumIdentifier : album.identifier;
    if ([identifier hasPrefix:@"deezer:"]) identifier = [identifier substringFromIndex:7];
    if (!identifier.length) {
        NSError *error = [NSError errorWithDomain:waAPIErrorDomain code:400 userInfo:@{NSLocalizedDescriptionKey:@"Missing album id"}];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO, error); });
        return;
    }
    [[waDeezerClient sharedClient] setLiked:liked albumIdentifier:identifier completion:^(NSError *error) { if (completion) completion(!error, error); }];
}
- (void)setLiked:(BOOL)liked playlist:(waMediaItem *)playlist completion:(void (^)(BOOL, NSError *))completion {
    NSString *identifier = playlist.identifier.length ? playlist.identifier : playlist.metadata[@"browseId"];
    if ([identifier hasPrefix:@"deezer:"]) identifier = [identifier substringFromIndex:7];
    if (!identifier.length) {
        NSError *error = [NSError errorWithDomain:waAPIErrorDomain code:400 userInfo:@{NSLocalizedDescriptionKey:@"Missing playlist id"}];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO, error); });
        return;
    }
    [[waDeezerClient sharedClient] setLiked:liked playlistIdentifier:identifier completion:^(NSError *error) { if (completion) completion(!error, error); }];
}

- (void)playlistsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDeezerClient sharedClient] playlistsWithCompletion:completion];
}
- (void)playlistWithID:(NSString *)playlistID completion:(void (^)(NSDictionary *, NSError *))completion {
    if (!playlistID.length) { dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, nil); }); return; }
    [[waDeezerClient sharedClient] playlistWithIdentifier:playlistID completion:completion];
}
- (void)updatePlaylistWithID:(NSString *)playlistID changes:(NSDictionary *)changes completion:(void (^)(NSDictionary *, NSError *))completion {
    if (!playlistID.length) { dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, nil); }); return; }
    [[waDeezerClient sharedClient] updatePlaylistWithIdentifier:playlistID changes:changes completion:completion];
}
- (void)createPlaylistNamed:(NSString *)name completion:(void (^)(NSDictionary *, NSError *))completion { [[waDeezerClient sharedClient] createPlaylistNamed:name completion:completion]; }
- (void)addSong:(NSDictionary *)song toPlaylist:(NSString *)playlistID completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *identifier = waStringValue(song[@"trackId"]) ?: waStringValue(song[@"id"]) ?: waStringValue(song[@"identifier"]);
    if (!playlistID.length || !identifier.length) { NSError *error = [NSError errorWithDomain:waAPIErrorDomain code:400 userInfo:@{NSLocalizedDescriptionKey:@"Missing playlist or song id"}]; dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, error); }); return; }
    [[waDeezerClient sharedClient] addSongIdentifier:identifier toPlaylistIdentifier:playlistID completion:^(NSError *error) { if (completion) completion(error ? nil : (song ?: @{}), error); }];
}
- (void)removeSong:(NSString *)trackId fromPlaylist:(NSString *)playlistID completion:(void (^)(NSError *))completion { [[waDeezerClient sharedClient] removeSongIdentifier:trackId fromPlaylistIdentifier:playlistID completion:completion]; }
- (void)deletePlaylist:(NSString *)playlistID completion:(void (^)(NSError *))completion { [[waDeezerClient sharedClient] deletePlaylistWithIdentifier:playlistID completion:completion]; }
- (void)logoutWithCompletion:(void (^)(NSError *))completion { [[waDeezerClient sharedClient] logout]; if (completion) completion(nil); }
- (void)meWithCompletion:(void (^)(NSDictionary *, NSError *))completion { [[waDeezerClient sharedClient] userWithCompletion:^(NSDictionary *user, NSError *error) { if (completion) completion(user ? @{ @"user": user } : nil, error); }]; }
- (void)updateCurrentUser:(NSDictionary *)changes completion:(void (^)(NSDictionary *, NSError *))completion { (void)changes; NSError *error = [NSError errorWithDomain:waAPIErrorDomain code:405 userInfo:@{NSLocalizedDescriptionKey:@"Deezer profile fields are read-only here."}]; dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, error); }); }
- (void)recordActivityForTrackId:(NSString *)trackId completion:(void (^)(NSError *))completion { (void)trackId; if (completion) completion(nil); }
- (void)uploadAvatarJPEGData:(NSData *)data completion:(void (^)(NSError *))completion { (void)data; if (completion) completion(nil); }
- (void)searchQuery:(NSString *)query type:(NSString *)type completion:(void (^)(NSArray *, NSError *))completion {
    [[waDeezerClient sharedClient] searchQuery:query type:type completion:completion];
}
- (void)searchQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit completion:(void (^)(NSArray *, NSError *))completion {
    [[waDeezerClient sharedClient] searchQuery:query type:type limit:limit completion:completion];
}
- (void)searchQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit index:(NSUInteger)index completion:(void (^)(NSArray *, NSError *))completion {
    [[waDeezerClient sharedClient] searchQuery:query type:type limit:limit index:index completion:completion];
}
- (void)searchQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit index:(NSUInteger)index strict:(BOOL)strict completion:(void (^)(NSArray *, NSError *))completion {
    [[waDeezerClient sharedClient] searchQuery:query type:type limit:limit index:index strict:strict completion:completion];
}
- (void)cancelSearchRequests {
    [[waDeezerClient sharedClient] cancelSearchRequests];
}
- (void)artistAlbumsWithID:(NSString *)artistID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDeezerClient sharedClient] artistAlbumsWithID:artistID completion:completion];
}
- (void)catalogType:(NSString *)type identifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion {
    if (!type.length || !identifier.length) {
        NSError *error = [NSError errorWithDomain:waAPIErrorDomain code:400 userInfo:@{NSLocalizedDescriptionKey:@"Missing catalog identifier"}];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, error); });
        return;
    }
    if ([type isEqualToString:@"albums"]) {
        [[waDeezerClient sharedClient] albumWithIdentifier:identifier completion:completion];
        return;
    }
    if ([type isEqualToString:@"artists"]) {
        [[waDeezerClient sharedClient] artistWithIdentifier:identifier completion:completion];
        return;
    }
    if (completion) completion(nil, [NSError errorWithDomain:waAPIErrorDomain code:400 userInfo:@{NSLocalizedDescriptionKey:@"Unsupported Deezer catalog type."}]);
}
- (void)trackDetailsForTrackId:(NSString *)trackId completion:(void (^)(NSDictionary *, NSError *))completion {
    // Serverless: use Deezer public API directly via waDeezerStreamClient
    if (!trackId.length) { NSError *error = [NSError errorWithDomain:waAPIErrorDomain code:400 userInfo:@{NSLocalizedDescriptionKey:@"Missing Deezer track id"}]; dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, error); }); return; }
    [[waDeezerStreamClient sharedClient] fetchPublicTrackDetailsForTrackID:trackId completion:^(NSDictionary *details, NSError *error) {
        if (completion) completion(details, error);
    }];
}
- (void)relatedForTrackId:(NSString *)trackId completion:(void (^)(NSArray *, NSError *))completion { (void)trackId; dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(@[], nil); }); }
- (void)prefetchTrackForTrackId:(NSString *)trackId { (void)trackId; }
- (NSURL *)streamURLForTrackId:(NSString *)trackId ticketURL:(NSString *)ticketURL quality:(NSUInteger)quality { (void)trackId; (void)ticketURL; (void)quality; return nil; }
- (NSURL *)flacStreamURLForTrackId:(NSString *)trackId { (void)trackId; return nil; }
- (NSURL *)streamURLForTrackId:(NSString *)trackId ticketURL:(NSString *)ticketURL { (void)trackId; (void)ticketURL; return nil; }
- (void)healthWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
    // Serverless: health is Deezer API reachability
    NSURL *url = [NSURL URLWithString:@"https://api.deezer.com"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
    [NSURLConnection sendAsynchronousRequest:request queue:waAPICompletionQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        (void)data; (void)response;
        NSDictionary *result = error ? nil : @{ @"ok": @YES, @"serverless": @YES };
        if (completion) completion(result, error);
    }];
}
- (void)updatePresenceForItem:(waMediaItem *)item state:(NSString *)state completion:(void (^)(NSError *))completion { (void)item; (void)state; if (completion) completion(nil); }
- (void)clearPresenceWithCompletion:(void (^)(NSError *))completion { if (completion) completion(nil); }
- (void)lyricsForTrack:(NSString *)track artist:(NSString *)artist completion:(void (^)(NSDictionary *, NSError *))completion { [self lyricsForTrack:track artist:artist album:nil length:0.0 trackId:nil isrc:nil completion:completion]; }
- (void)lyricsForTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album length:(NSTimeInterval)length completion:(void (^)(NSDictionary *, NSError *))completion { [self lyricsForTrack:track artist:artist album:album length:length trackId:nil isrc:nil completion:completion]; }
- (void)lyricsForTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album length:(NSTimeInterval)length trackId:(NSString *)trackId isrc:(NSString *)isrc completion:(void (^)(NSDictionary *, NSError *))completion {
    // Lyrics disabled serverless - return empty
    (void)track; (void)artist; (void)album; (void)length; (void)trackId; (void)isrc;
    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, [NSError errorWithDomain:waAPIErrorDomain code:503 userInfo:@{NSLocalizedDescriptionKey:@"Lyrics disabled serverless"}]); });
}
@end
