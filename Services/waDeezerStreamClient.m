#import "waDeezerStreamClient.h"
#import "waKeychainStore.h"
#import "../Models/waPreferences.h"
#import "waDebugLog.h"

static NSString * const waStreamGateway = @"https://www.deezer.com/ajax/gw-light.php";
static NSString * const waStreamMediaURL = @"https://media.deezer.com/v1/get_url";
static NSString * const waStreamErrorDomain = @"com.bytebox.wave.deezerstream";

static NSOperationQueue *waStreamParseQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 2;
    });
    return queue;
}

static NSString *waStreamEscape(NSString *value) {
    if (!value.length) return @"";
    CFStringRef escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)value, NULL, CFSTR(":/?#[]@!$&'()*+,;="), kCFStringEncodingUTF8);
    NSString *result = escaped ? [(__bridge NSString *)escaped copy] : [value copy];
    if (escaped) CFRelease(escaped);
    return result;
}

static NSString *waStreamString(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

@interface waDeezerStreamClient ()
@property (nonatomic, copy) NSString *apiToken;
@property (nonatomic, copy) NSString *sessionID;
@property (nonatomic, copy) NSString *licenseToken;
+ (NSString *)formatForQuality:(NSUInteger)quality;
+ (NSUInteger)qualityForFormat:(NSString *)format;
+ (NSString *)extensionForQuality:(NSUInteger)quality;
- (void)signedURLForTrackToken:(NSString *)trackToken formatsFrom:(NSUInteger)quality completion:(void (^)(NSString *signedURL, NSUInteger resolvedQuality, NSError *error))completion;
@end

@implementation waDeezerStreamClient

+ (waDeezerStreamClient *)sharedClient {
    static waDeezerStreamClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ client = [[self alloc] init]; });
    return client;
}

- (NSString *)rawIdentifier:(NSString *)trackID {
    if ([trackID hasPrefix:@"deezer:"]) return [trackID substringFromIndex:7];
    return trackID ?: @"";
}

- (NSError *)errorWithMessage:(NSString *)message code:(NSInteger)code {
    return [NSError errorWithDomain:waStreamErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Deezer stream failed."}];
}

- (NSMutableURLRequest *)gatewayRequestForMethod:(NSString *)method token:(NSString *)token body:(NSDictionary *)body {
    NSString *urlString = [NSString stringWithFormat:@"%@?method=%@&api_version=1.0&input=3&api_token=%@", waStreamGateway, waStreamEscape(method ?: @""), waStreamEscape(token.length ? token : @"null")];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30.0];
    request.HTTPMethod = @"POST";
    request.allowsCellularAccess = [waPreferences sharedPreferences].cellularDataAllowed;
    [request setValue:@"application/json;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://www.deezer.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://www.deezer.com/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    NSString *arl = [waKeychainStore deezerARL];
    NSString *sid = nil;
    @synchronized (self) { sid = [self.sessionID copy]; }
    if (arl.length && sid.length) [request setValue:[NSString stringWithFormat:@"arl=%@; sid=%@", arl, sid] forHTTPHeaderField:@"Cookie"];
    else if (arl.length) [request setValue:[NSString stringWithFormat:@"arl=%@", arl] forHTTPHeaderField:@"Cookie"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body ?: @{} options:0 error:NULL];
    return request;
}

- (void)ensureUserDataWithCompletion:(void (^)(NSError *error))completion {
    NSString *token = nil, *sid = nil, *license = nil;
    @synchronized (self) {
        token = [self.apiToken copy];
        sid = [self.sessionID copy];
        license = [self.licenseToken copy];
    }
    if (token.length && sid.length && license.length) {
        if (completion) completion(nil);
        return;
    }
    NSString *arl = [waKeychainStore deezerARL];
    if (!arl.length) {
        if (completion) completion([self errorWithMessage:@"Connect a Deezer account first." code:401]);
        return;
    }
    // Same call Minuga uses: empty body, token in query left empty.
    NSString *urlString = [NSString stringWithFormat:@"%@?method=deezer.getUserData&api_version=1.0&api_token=", waStreamGateway];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30.0];
    request.HTTPMethod = @"POST";
    request.allowsCellularAccess = [waPreferences sharedPreferences].cellularDataAllowed;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    [request setValue:[NSString stringWithFormat:@"arl=%@", arl] forHTTPHeaderField:@"Cookie"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{} options:0 error:NULL];
    __weak typeof(self) weakSelf = self;
    [NSURLConnection sendAsynchronousRequest:request queue:waStreamParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
        waDeezerStreamClient *strongSelf = weakSelf;
        if (!strongSelf) return;
        NSError *error = networkError;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (!error && (![response isKindOfClass:[NSHTTPURLResponse class]] || [(NSHTTPURLResponse *)response statusCode] < 200 || [(NSHTTPURLResponse *)response statusCode] >= 300)) {
            error = [strongSelf errorWithMessage:@"Deezer login could not be validated." code:500];
        }
        NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
        NSDictionary *user = [results[@"USER"] isKindOfClass:[NSDictionary class]] ? results[@"USER"] : nil;
        NSDictionary *options = [user[@"OPTIONS"] isKindOfClass:[NSDictionary class]] ? user[@"OPTIONS"] : nil;
        NSString *checkForm = waStreamString(results[@"checkForm"]) ?: waStreamString(results[@"CHECK_FORM"]);
        NSString *session = waStreamString(results[@"SESSION_ID"]);
        NSString *licenseToken = waStreamString(options[@"license_token"]);
        if (!error && (!checkForm.length || !session.length || !licenseToken.length)) {
            [[waDebugLog sharedLog] log:@"Deezer stream userData missing fields (token=%lu sid=%lu license=%lu)", (unsigned long)checkForm.length, (unsigned long)session.length, (unsigned long)licenseToken.length];
            error = [strongSelf errorWithMessage:@"Deezer login could not be validated." code:401];
        }
        if (!error) {
            @synchronized (strongSelf) {
                strongSelf.apiToken = checkForm;
                strongSelf.sessionID = session;
                strongSelf.licenseToken = licenseToken;
            }
        }
        if (completion) completion(error);
    }];
}

- (void)trackTokenForRawID:(NSString *)rawID completion:(void (^)(NSString *trackToken, NSError *error))completion {
    __weak typeof(self) weakSelf = self;
    [self ensureUserDataWithCompletion:^(NSError *error) {
        waDeezerStreamClient *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) { if (completion) completion(nil, error); return; }
        NSString *token = nil;
        @synchronized (strongSelf) { token = [strongSelf.apiToken copy]; }
        NSMutableURLRequest *request = [strongSelf gatewayRequestForMethod:@"deezer.pageTrack" token:token body:@{@"sng_id": rawID ?: @""}];
        [NSURLConnection sendAsynchronousRequest:request queue:waStreamParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
            NSError *requestError = networkError;
            NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if (!requestError && (![response isKindOfClass:[NSHTTPURLResponse class]] || [(NSHTTPURLResponse *)response statusCode] < 200 || [(NSHTTPURLResponse *)response statusCode] >= 300)) {
                requestError = [weakSelf errorWithMessage:@"Deezer track lookup failed." code:500];
            }
            NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
            NSDictionary *trackData = [results[@"DATA"] isKindOfClass:[NSDictionary class]] ? results[@"DATA"] : results;
            NSString *trackToken = waStreamString(trackData[@"TRACK_TOKEN"]);
            if (!requestError && !trackToken.length) {
                requestError = [weakSelf errorWithMessage:@"Track is not streamable with this account." code:403];
            }
            if (completion) completion(trackToken, requestError);
        }];
    }];
}

- (void)signedURLForTrackToken:(NSString *)trackToken format:(NSString *)format completion:(void (^)(NSString *signedURL, NSError *error))completion {
    NSString *license = nil;
    @synchronized (self) { license = [self.licenseToken copy]; }
    if (!license.length) {
        if (completion) completion(nil, [self errorWithMessage:@"Connect a Deezer account first." code:401]);
        return;
    }
    NSDictionary *body = @{@"license_token": license,
                           @"media": @[@{@"type": @"FULL", @"formats": @[@{@"cipher": @"BF_CBC_STRIPE", @"format": format ?: @"MP3_320"}]}],
                           @"track_tokens": @[trackToken ?: @""]};
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:waStreamMediaURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30.0];
    request.HTTPMethod = @"POST";
    request.allowsCellularAccess = [waPreferences sharedPreferences].cellularDataAllowed;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    NSString *arl = [waKeychainStore deezerARL];
    NSString *sid = nil;
    @synchronized (self) { sid = [self.sessionID copy]; }
    if (arl.length && sid.length) [request setValue:[NSString stringWithFormat:@"arl=%@; sid=%@", arl, sid] forHTTPHeaderField:@"Cookie"];
    else if (arl.length) [request setValue:[NSString stringWithFormat:@"arl=%@", arl] forHTTPHeaderField:@"Cookie"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    __weak typeof(self) weakSelf = self;
    [NSURLConnection sendAsynchronousRequest:request queue:waStreamParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
        NSError *requestError = networkError;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (!requestError && (![response isKindOfClass:[NSHTTPURLResponse class]] || [(NSHTTPURLResponse *)response statusCode] < 200 || [(NSHTTPURLResponse *)response statusCode] >= 300)) {
            requestError = [weakSelf errorWithMessage:@"Deezer media URL failed." code:500];
        }
        NSString *signedURL = nil;
        id dataArray = json[@"data"];
        if ([dataArray isKindOfClass:[NSArray class]] && [(NSArray *)dataArray count]) {
            id media = [(NSArray *)dataArray objectAtIndex:0][@"media"];
            if ([media isKindOfClass:[NSArray class]] && [(NSArray *)media count]) {
                id sources = [(NSArray *)media objectAtIndex:0][@"sources"];
                if ([sources isKindOfClass:[NSArray class]] && [(NSArray *)sources count]) {
                    signedURL = waStreamString([(NSArray *)sources objectAtIndex:0][@"url"]);
                }
            }
        }
        if (!requestError && !signedURL.length) {
            requestError = [weakSelf errorWithMessage:@"Deezer did not return a stream URL for this quality." code:403];
        }
        if (completion) completion(signedURL, requestError);
    }];
}

+ (NSString *)formatForQuality:(NSUInteger)quality {
    if (quality >= 2) return @"FLAC";
    return quality == 0 ? @"MP3_128" : @"MP3_320";
}

+ (NSUInteger)qualityForFormat:(NSString *)format {
    if ([format isEqualToString:@"FLAC"]) return 2;
    if ([format isEqualToString:@"MP3_128"]) return 0;
    return 1;
}

+ (NSString *)extensionForQuality:(NSUInteger)quality {
    return quality >= 2 ? @"flac" : @"mp3";
}

- (void)resolveCDNURLForTrackID:(NSString *)trackID quality:(NSUInteger)quality completion:(void (^)(NSURL *, NSUInteger, NSError *))completion {
    NSString *rawID = [self rawIdentifier:trackID];
    NSUInteger requested = MIN(2, quality);
    if (!rawID.length) {
        if (completion) completion(nil, requested, [self errorWithMessage:@"Missing Deezer track id." code:400]);
        return;
    }
    __weak typeof(self) weakSelf = self;
    void (^finishOnMain)(NSURL *, NSUInteger, NSError *) = ^(NSURL *url, NSUInteger resolved, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(url, resolved, error); });
    };
    [self trackTokenForRawID:rawID completion:^(NSString *trackToken, NSError *error) {
        if (error) { finishOnMain(nil, requested, error); return; }
        [weakSelf signedURLForTrackToken:trackToken formatsFrom:requested completion:^(NSString *signedURL, NSUInteger resolved, NSError *urlError) {
            if (signedURL.length) finishOnMain([NSURL URLWithString:signedURL], resolved, nil);
            else finishOnMain(nil, requested, urlError);
        }];
    }];
}

// Steps down FLAC->320->128 until the account grants a format.
- (void)signedURLForTrackToken:(NSString *)trackToken formatsFrom:(NSUInteger)quality completion:(void (^)(NSString *signedURL, NSUInteger resolvedQuality, NSError *error))completion {
    NSString *format = [[self class] formatForQuality:quality];
    __weak typeof(self) weakSelf = self;
    [self signedURLForTrackToken:trackToken format:format completion:^(NSString *signedURL, NSError *urlError) {
        if (!urlError && signedURL.length) {
            if (completion) completion(signedURL, quality, nil);
            return;
        }
        if (quality > 0) {
            [[waDebugLog sharedLog] log:@"Deezer stream denied, retry %@", [waDeezerStreamClient formatForQuality:quality - 1]];
            [weakSelf signedURLForTrackToken:trackToken formatsFrom:quality - 1 completion:completion];
            return;
        }
        if (completion) completion(nil, 0, urlError);
    }];
}

- (void)resolveStreamURLForTrackID:(NSString *)trackID quality:(NSUInteger)quality completion:(void (^)(NSURL *, NSUInteger, NSError *))completion {
    NSString *rawID = [self rawIdentifier:trackID];
    [self resolveCDNURLForTrackID:trackID quality:quality completion:^(NSURL *cdnURL, NSUInteger resolved, NSError *error) {
        if (error || !cdnURL) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, resolved, error); });
            return;
        }
        NSString *ext = [[self class] extensionForQuality:resolved];
        NSString *wrapped = [NSString stringWithFormat:@"deezer://stream/%@.%@?q=%lu&u=%@", waStreamEscape(rawID), ext, (unsigned long)resolved, waStreamEscape(cdnURL.absoluteString)];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion([NSURL URLWithString:wrapped], resolved, nil); });
    }];
}

- (void)fetchPublicTrackDetailsForTrackID:(NSString *)trackID completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *rawID = [self rawIdentifier:trackID];
    if (!rawID.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, [self errorWithMessage:@"Missing Deezer track id." code:400]); });
        return;
    }
    NSString *urlString = [NSString stringWithFormat:@"https://api.deezer.com/track/%@", waStreamEscape(rawID)];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:30.0];
    request.allowsCellularAccess = [waPreferences sharedPreferences].cellularDataAllowed;
    [request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    __weak typeof(self) weakSelf = self;
    [NSURLConnection sendAsynchronousRequest:request queue:waStreamParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
        NSError *requestError = networkError;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (!requestError && (![response isKindOfClass:[NSHTTPURLResponse class]] || [(NSHTTPURLResponse *)response statusCode] < 200 || [(NSHTTPURLResponse *)response statusCode] >= 300)) {
            requestError = [weakSelf errorWithMessage:@"Deezer track details failed." code:500];
        }
        NSDictionary *details = nil;
        if (!requestError && [json isKindOfClass:[NSDictionary class]] && !json[@"error"]) {
            NSString *title = waStreamString(json[@"title"]);
            NSDictionary *artist = [json[@"artist"] isKindOfClass:[NSDictionary class]] ? json[@"artist"] : nil;
            NSDictionary *album = [json[@"album"] isKindOfClass:[NSDictionary class]] ? json[@"album"] : nil;
            double duration = [json[@"duration"] respondsToSelector:@selector(doubleValue)] ? [json[@"duration"] doubleValue] : 0.0;
            details = @{@"title": title ?: @"",
                        @"artistName": waStreamString(artist[@"name"]) ?: @"",
                        @"author": waStreamString(artist[@"name"]) ?: @"",
                        @"albumName": waStreamString(album[@"title"]) ?: @"",
                        @"duration": @(duration),
                        @"resolvedQuality": @1};
        }
        if (!requestError && !details) requestError = [weakSelf errorWithMessage:@"Deezer track details failed." code:500];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(details, requestError); });
    }];
}

- (void)fetchLrclibLyricsForRawID:(NSString *)rawID title:(NSString *)preTitle artist:(NSString *)preArtist album:(NSString *)preAlbum duration:(double)preDuration completion:(void (^)(NSDictionary *, NSError *))completion {
    __weak typeof(self) weakSelf = self;
    void (^finishLrclib)(NSString *, NSString *, NSString *, double) = ^(NSString *title, NSString *artist, NSString *album, double duration) {
        if (!title.length || !artist.length) {
            if (completion) completion(nil, [weakSelf errorWithMessage:@"Lyrics unavailable." code:404]);
            return;
        }
        NSString *lrclibURL = [NSString stringWithFormat:@"https://lrclib.net/api/get?artist_name=%@&track_name=%@&album_name=%@&duration=%.0f",
                               waStreamEscape(artist), waStreamEscape(title), waStreamEscape(album ?: @""), duration];
        NSMutableURLRequest *lrReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:lrclibURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
        [lrReq setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
        [NSURLConnection sendAsynchronousRequest:lrReq queue:waStreamParseQueue() completionHandler:^(NSURLResponse *lrResp, NSData *lrData, NSError *lrErr) {
            NSDictionary *lrJson = lrData.length ? [NSJSONSerialization JSONObjectWithData:lrData options:0 error:NULL] : nil;
            NSString *synced = waStreamString(lrJson[@"syncedLyrics"]);
            NSString *plainLR = waStreamString(lrJson[@"plainLyrics"]);
            BOOL instrumental = [lrJson[@"instrumental"] boolValue];
            NSInteger status = [lrResp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)lrResp statusCode] : 0;
            if (!lrErr && status == 200 && (synced.length || plainLR.length || instrumental)) {
                NSMutableArray *lrLines = [NSMutableArray array];
                if (synced.length) {
                    for (NSString *rawLine in [synced componentsSeparatedByString:@"\n"]) {
                        if (!rawLine.length) continue;
                        NSRange r = [rawLine rangeOfString:@"]"];
                        if (r.location == NSNotFound || ![rawLine hasPrefix:@"["]) continue;
                        NSString *ts = [rawLine substringWithRange:NSMakeRange(1, r.location-1)];
                        NSString *txt = [[rawLine substringFromIndex:r.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if (!txt.length) continue;
                        NSArray *parts = [ts componentsSeparatedByString:@":"];
                        double m = 0, s = 0;
                        if (parts.count == 2) { m = [parts[0] doubleValue]; s = [parts[1] doubleValue]; }
                        else s = [ts doubleValue];
                        [lrLines addObject:@{@"time": @(m*60 + s), @"text": txt}];
                    }
                }
                if (instrumental && !lrLines.count && !plainLR.length) {
                    NSDictionary *p = @{@"instrumental": @YES, @"plain": @"", @"lineSynced": @[], @"wordSynced": @[], @"source": @"lrclib"};
                    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(p, nil); });
                    return;
                }
                if (lrLines.count || plainLR.length) {
                    NSDictionary *p = @{@"plain": plainLR ?: @"", @"lineSynced": lrLines, @"wordSynced": @[], @"instrumental": @NO, @"source": @"lrclib"};
                    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(p, nil); });
                    return;
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, [weakSelf errorWithMessage:@"Lyrics unavailable." code:404]); });
        }];
    };
    if (preTitle.length && preArtist.length) {
        finishLrclib(preTitle, preArtist, preAlbum ?: @"", preDuration);
        return;
    }
    NSString *metaURL = [NSString stringWithFormat:@"https://api.deezer.com/track/%@", waStreamEscape(rawID)];
    NSMutableURLRequest *metaReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:metaURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
    [metaReq setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    [NSURLConnection sendAsynchronousRequest:metaReq queue:waStreamParseQueue() completionHandler:^(NSURLResponse *metaResp, NSData *metaData, NSError *metaErr) {
        (void)metaResp;
        NSDictionary *meta = metaData.length ? [NSJSONSerialization JSONObjectWithData:metaData options:0 error:NULL] : nil;
        NSString *title = waStreamString(meta[@"title_short"]) ?: waStreamString(meta[@"title"]);
        NSDictionary *artistObj = [meta[@"artist"] isKindOfClass:[NSDictionary class]] ? meta[@"artist"] : nil;
        NSString *artist = waStreamString(artistObj[@"name"]);
        NSDictionary *albumObj = [meta[@"album"] isKindOfClass:[NSDictionary class]] ? meta[@"album"] : nil;
        NSString *album = waStreamString(albumObj[@"title"]);
        double duration = [meta[@"duration"] respondsToSelector:@selector(doubleValue)] ? [meta[@"duration"] doubleValue] : 0;
        if (metaErr || !title.length || !artist.length) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, [weakSelf errorWithMessage:@"Lyrics unavailable." code:404]); });
            return;
        }
        finishLrclib(title, artist, album ?: @"", duration);
    }];
}

- (void)fetchSyncLrcLyricsForRawID:(NSString *)rawID title:(NSString *)preTitle artist:(NSString *)preArtist album:(NSString *)preAlbum duration:(double)preDuration completion:(void (^)(NSDictionary *, NSError *))completion {
    __weak typeof(self) weakSelf = self;
    void (^finishSync)(NSString *, NSString *, NSString *, double) = ^(NSString *title, NSString *artist, NSString *album, double duration) {
        if (!title.length || !artist.length) {
            if (completion) completion(nil, [weakSelf errorWithMessage:@"Lyrics unavailable." code:404]);
            return;
        }
        NSString *urlString = [NSString stringWithFormat:@"https://api.synclrc.dev/lyrics?track=%@&artist=%@&album=%@&duration=%.0f",
                               waStreamEscape(title), waStreamEscape(artist), waStreamEscape(album ?: @""), duration];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:12.0];
        [req setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [NSURLConnection sendAsynchronousRequest:req queue:waStreamParseQueue() completionHandler:^(NSURLResponse *resp, NSData *data, NSError *netErr) {
            NSDictionary *j = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
            NSString *synced = waStreamString(j[@"synced"]);
            NSString *plain = waStreamString(j[@"plain"]);
            NSString *karaoke = waStreamString(j[@"karaoke"]);
            BOOL instrumental = [j[@"instrumental"] boolValue];
            if (!netErr && status == 200 && (synced.length || plain.length || karaoke.length || instrumental)) {
                if (instrumental && !synced.length && !plain.length && !karaoke.length) {
                    NSDictionary *p = @{@"instrumental": @YES, @"plain": @"", @"lineSynced": @[], @"wordSynced": @[], @"source": @"synclrc"};
                    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(p, nil); });
                    return;
                }
                NSMutableArray *lineSynced = [NSMutableArray array];
                if (synced.length) {
                    for (NSString *rawLine in [synced componentsSeparatedByString:@"\n"]) {
                        if (!rawLine.length) continue;
                        NSRange r = [rawLine rangeOfString:@"]"];
                        if (r.location == NSNotFound || ![rawLine hasPrefix:@"["]) continue;
                        NSString *ts = [rawLine substringWithRange:NSMakeRange(1, r.location-1)];
                        NSString *txt = [[rawLine substringFromIndex:r.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if (!txt.length) continue;
                        NSArray *parts = [ts componentsSeparatedByString:@":"];
                        double m = 0, s = 0;
                        if (parts.count == 2) { m = [parts[0] doubleValue]; s = [parts[1] doubleValue]; }
                        else s = [ts doubleValue];
                        [lineSynced addObject:@{@"time": @(m*60 + s), @"text": txt}];
                    }
                }
                // Parse karaoke enhanced LRC into wordSynced lines: [lineStart]<wStart>word ...
                NSMutableArray *wordSynced = [NSMutableArray array];
                if (karaoke.length) {
                    for (NSString *rawLine in [karaoke componentsSeparatedByString:@"\n"]) {
                        if (!rawLine.length) continue;
                        if (![rawLine hasPrefix:@"["]) continue;
                        NSRange r = [rawLine rangeOfString:@"]"];
                        if (r.location == NSNotFound) continue;
                        NSString *lineTs = [rawLine substringWithRange:NSMakeRange(1, r.location-1)];
                        NSArray *lp = [lineTs componentsSeparatedByString:@":"];
                        double lm = 0, ls = 0;
                        if (lp.count == 2) { lm = [lp[0] doubleValue]; ls = [lp[1] doubleValue]; }
                        else ls = [lineTs doubleValue];
                        double lineStart = lm*60 + ls;
                        NSString *rest = [rawLine substringFromIndex:r.location+1];
                        // Split by <timestamp> chunks
                        NSMutableArray *words = [NSMutableArray array];
                        NSMutableString *lineText = [NSMutableString string];
                        NSArray *chunks = [rest componentsSeparatedByString:@"<"];
                        for (NSString *chunk in chunks) {
                            if (!chunk.length) continue;
                            NSRange er = [chunk rangeOfString:@">"];
                            if (er.location == NSNotFound) {
                                // trailing text without timestamp
                                NSString *t = [chunk stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                                if (t.length) {
                                    [lineText appendString:t];
                                    [lineText appendString:@" "];
                                    [words addObject:@{@"text": t, @"time": @([words count] ? [[words lastObject][@"time"] doubleValue] : 0)}];
                                }
                                continue;
                            }
                            NSString *wts = [chunk substringToIndex:er.location];
                            NSString *wtext = [[chunk substringFromIndex:er.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                            NSArray *wp = [wts componentsSeparatedByString:@":"];
                            double wm = 0, ws = 0;
                            if (wp.count == 2) { wm = [wp[0] doubleValue]; ws = [wp[1] doubleValue]; }
                            else ws = [wts doubleValue];
                            double wabs = wm*60 + ws;
                            if (wtext.length) {
                                [lineText appendString:wtext];
                                [lineText appendString:@" "];
                                [words addObject:@{@"text": wtext, @"time": @(MAX(0, wabs - lineStart))}];
                            }
                        }
                        NSString *trimmed = [lineText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if (!trimmed.length && words.count == 0) continue;
                        [wordSynced addObject:@{@"time": @(lineStart), @"text": trimmed.length ? trimmed : @"", @"words": words, @"syncedLyric": words}];
                        // Also ensure lineSynced has this line if synced missed it
                        BOOL hasLine = NO;
                        for (NSDictionary *el in lineSynced) {
                            if (fabs([el[@"time"] doubleValue] - lineStart) < 0.05) { hasLine = YES; break; }
                        }
                        if (!hasLine && trimmed.length) [lineSynced addObject:@{@"time": @(lineStart), @"text": trimmed}];
                    }
                    [lineSynced sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                        double ta = [a[@"time"] doubleValue], tb = [b[@"time"] doubleValue];
                        if (ta < tb) return NSOrderedAscending;
                        if (ta > tb) return NSOrderedDescending;
                        return NSOrderedSame;
                    }];
                }
                if (wordSynced.count || lineSynced.count || plain.length) {
                    NSDictionary *p = @{@"plain": plain ?: @"", @"lineSynced": lineSynced, @"wordSynced": wordSynced, @"instrumental": @NO, @"source": @"synclib"};
                    // fix source typo guard
                    NSMutableDictionary *mp = [p mutableCopy];
                    mp[@"source"] = @"synclrc";
                    dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(mp, nil); });
                    return;
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, [weakSelf errorWithMessage:@"Lyrics unavailable." code:404]); });
        }];
    };
    if (preTitle.length && preArtist.length) {
        finishSync(preTitle, preArtist, preAlbum ?: @"", preDuration);
        return;
    }
    NSString *metaURL = [NSString stringWithFormat:@"https://api.deezer.com/track/%@", waStreamEscape(rawID)];
    NSMutableURLRequest *metaReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:metaURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
    [metaReq setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    [NSURLConnection sendAsynchronousRequest:metaReq queue:waStreamParseQueue() completionHandler:^(NSURLResponse *metaResp, NSData *metaData, NSError *metaErr) {
        (void)metaResp;
        NSDictionary *meta = metaData.length ? [NSJSONSerialization JSONObjectWithData:metaData options:0 error:NULL] : nil;
        NSString *title = waStreamString(meta[@"title_short"]) ?: waStreamString(meta[@"title"]);
        NSDictionary *artistObj = [meta[@"artist"] isKindOfClass:[NSDictionary class]] ? meta[@"artist"] : nil;
        NSString *artist = waStreamString(artistObj[@"name"]);
        NSDictionary *albumObj = [meta[@"album"] isKindOfClass:[NSDictionary class]] ? meta[@"album"] : nil;
        NSString *album = waStreamString(albumObj[@"title"]);
        double duration = [meta[@"duration"] respondsToSelector:@selector(doubleValue)] ? [meta[@"duration"] doubleValue] : 0;
        if (metaErr || !title.length || !artist.length) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, [weakSelf errorWithMessage:@"Lyrics unavailable." code:404]); });
            return;
        }
        finishSync(title, artist, album ?: @"", duration);
    }];
}

- (void)fetchLyricsForTrackID:(NSString *)trackID completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *rawID = [self rawIdentifier:trackID];
    if (!rawID.length) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, [self errorWithMessage:@"Missing Deezer track id." code:400]); });
        return;
    }
    __weak typeof(self) weakSelf = self;
    // SyncLRC priority, LRCLIB fallback, Deezer hidden last
    [self fetchSyncLrcLyricsForRawID:rawID title:nil artist:nil album:nil duration:0 completion:^(NSDictionary *syncPayload, NSError *syncError) {
        if (syncPayload) { if (completion) completion(syncPayload, nil); return; }
        [[waDebugLog sharedLog] log:@"SyncLRC miss (%@), LRCLIB fallback", syncError.localizedDescription ?: @"unknown"];
        [self fetchLrclibLyricsForRawID:rawID title:nil artist:nil album:nil duration:0 completion:^(NSDictionary *lrPayload, NSError *lrError) {
            if (lrPayload) { if (completion) completion(lrPayload, nil); return; }
            [[waDebugLog sharedLog] log:@"LRCLIB miss (%@), Deezer fallback", lrError.localizedDescription ?: @"unknown"];
    [self ensureUserDataWithCompletion:^(NSError *error) {
        waDeezerStreamClient *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error) { dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, error); }); return; }
        NSString *token = nil;
        @synchronized (strongSelf) { token = [strongSelf.apiToken copy]; }
        if (!token.length) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, [strongSelf errorWithMessage:@"Deezer not authenticated." code:401]); });
            return;
        }
        NSDictionary *body = @{@"sng_id": rawID};
        NSMutableURLRequest *request = [strongSelf gatewayRequestForMethod:@"song.getLyrics" token:token body:body];
        // song.getLyrics needs JSON body exactly {"sng_id": "<id>"} with same session cookies already in gatewayRequest
        [NSURLConnection sendAsynchronousRequest:request queue:waStreamParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
            NSError *requestError = networkError;
            NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if (!requestError && (![response isKindOfClass:[NSHTTPURLResponse class]] || [(NSHTTPURLResponse *)response statusCode] < 200 || [(NSHTTPURLResponse *)response statusCode] >= 300)) {
                requestError = [weakSelf errorWithMessage:@"Deezer lyrics failed." code:500];
            }
            NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
            if (!requestError && !results) requestError = [weakSelf errorWithMessage:@"Lyrics unavailable." code:404];
            if (requestError) { dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, requestError); }); return; }
            NSString *text = waStreamString(results[@"LYRICS_TEXT"]);
            NSString *syncJSON = waStreamString(results[@"LYRICS_SYNC_JSON"]);
            // LYRICS_TEXT may be empty for instrumental
            BOOL instrumental = (text.length == 0 && (syncJSON.length == 0 || [syncJSON isEqualToString:@"[]"])) || [results[@"LYRICS_ID"] integerValue] == 0;
            // Parse LYRICS_SYNC_JSON -> array of {milliseconds, line} -> {time, text}
            NSArray *lines = @[];
            if (syncJSON.length) {
                NSData *syncData = [syncJSON dataUsingEncoding:NSUTF8StringEncoding];
                NSArray *syncArray = syncData.length ? [NSJSONSerialization JSONObjectWithData:syncData options:0 error:NULL] : nil;
                if ([syncArray isKindOfClass:[NSArray class]] && syncArray.count) {
                    NSMutableArray *parsed = [NSMutableArray arrayWithCapacity:syncArray.count];
                    for (NSDictionary *entry in syncArray) {
                        if (![entry isKindOfClass:[NSDictionary class]]) continue;
                        NSString *line = waStreamString(entry[@"line"]);
                        if (!line.length) continue;
                        double ms = [entry[@"milliseconds"] respondsToSelector:@selector(doubleValue)] ? [entry[@"milliseconds"] doubleValue] : -1;
                        if (ms < 0) ms = [entry[@"lrc_timestamp"] isKindOfClass:[NSString class]] ? 0 : -1; // fallback
                        // lrc_timestamp like [00:51.48] if milliseconds missing, parse roughly
                        if (ms < 0 && [entry[@"lrc_timestamp"] isKindOfClass:[NSString class]]) {
                            NSString *ts = entry[@"lrc_timestamp"];
                            // [mm:ss.xx]
                            NSScanner *scanner = [NSScanner scannerWithString:ts];
                            [scanner scanString:@"[" intoString:NULL];
                            double m = 0, s = 0;
                            [scanner scanDouble:&m]; [scanner scanString:@":" intoString:NULL]; [scanner scanDouble:&s];
                            ms = (m * 60 + s) * 1000;
                        }
                        if (ms < 0) ms = 0;
                        [parsed addObject:@{@"time": @(ms/1000.0), @"text": line}];
                    }
                    lines = parsed;
                }
            }
            // Normalize instrumental
            if (instrumental && text.length == 0 && lines.count == 0) {
                NSDictionary *payload = @{@"instrumental": @YES, @"plain": @"", @"lineSynced": @[], @"wordSynced": @[], @"source": @"deezer"};
                dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(payload, nil); });
                return;
            }
            if (text.length == 0 && lines.count == 0) {
                // Deezer has nothing -> try LRCLIB as fallback before failing
                NSString *metaURL = [NSString stringWithFormat:@"https://api.deezer.com/track/%@", waStreamEscape(rawID)];
                NSMutableURLRequest *metaReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:metaURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
                [metaReq setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
                [NSURLConnection sendAsynchronousRequest:metaReq queue:waStreamParseQueue() completionHandler:^(NSURLResponse *metaResp, NSData *metaData, NSError *metaErr) {
                    NSDictionary *meta = metaData.length ? [NSJSONSerialization JSONObjectWithData:metaData options:0 error:NULL] : nil;
                    NSString *title = waStreamString(meta[@"title_short"]) ?: waStreamString(meta[@"title"]);
                    NSDictionary *artistObj = [meta[@"artist"] isKindOfClass:[NSDictionary class]] ? meta[@"artist"] : nil;
                    NSString *artist = waStreamString(artistObj[@"name"]);
                    NSDictionary *albumObj = [meta[@"album"] isKindOfClass:[NSDictionary class]] ? meta[@"album"] : nil;
                    NSString *album = waStreamString(albumObj[@"title"]);
                    double duration = [meta[@"duration"] respondsToSelector:@selector(doubleValue)] ? [meta[@"duration"] doubleValue] : 0;
                    if (metaErr || !title.length || !artist.length) {
                        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, [weakSelf errorWithMessage:@"Lyrics unavailable." code:404]); });
                        return;
                    }
                    NSString *lrclibURL = [NSString stringWithFormat:@"https://lrclib.net/api/get?artist_name=%@&track_name=%@&album_name=%@&duration=%.0f",
                                           waStreamEscape(artist), waStreamEscape(title), waStreamEscape(album ?: @""), duration];
                    NSMutableURLRequest *lrReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:lrclibURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
                    [lrReq setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
                    [NSURLConnection sendAsynchronousRequest:lrReq queue:waStreamParseQueue() completionHandler:^(NSURLResponse *lrResp, NSData *lrData, NSError *lrErr) {
                        NSDictionary *lrJson = lrData.length ? [NSJSONSerialization JSONObjectWithData:lrData options:0 error:NULL] : nil;
                        NSString *synced = waStreamString(lrJson[@"syncedLyrics"]);
                        NSString *plainLR = waStreamString(lrJson[@"plainLyrics"]);
                        if (!lrErr && [lrResp isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse *)lrResp statusCode] == 200 && (synced.length || plainLR.length)) {
                            NSMutableArray *lrLines = [NSMutableArray array];
                            if (synced.length) {
                                for (NSString *rawLine in [synced componentsSeparatedByString:@"\n"]) {
                                    if (!rawLine.length) continue;
                                    NSRange r = [rawLine rangeOfString:@"]"];
                                    if (r.location == NSNotFound || ![rawLine hasPrefix:@"["]) continue;
                                    NSString *ts = [rawLine substringWithRange:NSMakeRange(1, r.location-1)];
                                    NSString *txt = [[rawLine substringFromIndex:r.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                                    if (!txt.length) continue;
                                    NSArray *parts = [ts componentsSeparatedByString:@":"];
                                    double m = 0, s = 0;
                                    if (parts.count == 2) { m = [parts[0] doubleValue]; s = [parts[1] doubleValue]; }
                                    else s = [ts doubleValue];
                                    [lrLines addObject:@{@"time": @(m*60 + s), @"text": txt}];
                                }
                            }
                            NSDictionary *lrPayload = @{
                                @"plain": plainLR ?: @"",
                                @"lineSynced": lrLines,
                                @"wordSynced": @[],
                                @"instrumental": @NO,
                                @"source": @"lrclib"
                            };
                            if (lrLines.count || plainLR.length) {
                                dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(lrPayload, nil); });
                                return;
                            }
                        }
                        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, [weakSelf errorWithMessage:@"Lyrics unavailable." code:404]); });
                    }];
                }];
                return;
            }
            // Build lineSynced LRC-like array for Wave: @{@"text":..., @"time":@(seconds)}
            NSMutableArray *lineSynced = [NSMutableArray array];
            if (lines.count) {
                for (NSDictionary *l in lines) [lineSynced addObject:l];
            } else if (text.length) {
                // No sync, return plain will be used as fallback
            }
            NSDictionary *payload = @{
                @"plain": text ?: @"",
                @"lineSynced": lineSynced,
                @"wordSynced": @[],
                @"instrumental": @(instrumental),
                @"source": @"deezer",
                @"LYRICS_TEXT": text ?: @"",
                @"LYRICS_SYNC_JSON": syncJSON ?: @""
            };
            // Deezer often returns plain-only (no sync) even when LRCLIB has line-sync.
            // Fallback serverless to LRCLIB directly for line-by-line sync.
            if (lineSynced.count == 0 && text.length > 0) {
                // Fetch track metadata for LRCLIB query (title/artist/album/duration)
                NSString *metaURL = [NSString stringWithFormat:@"https://api.deezer.com/track/%@", waStreamEscape(rawID)];
                NSMutableURLRequest *metaReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:metaURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
                [metaReq setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
                [NSURLConnection sendAsynchronousRequest:metaReq queue:waStreamParseQueue() completionHandler:^(NSURLResponse *metaResp, NSData *metaData, NSError *metaErr) {
                    NSDictionary *meta = metaData.length ? [NSJSONSerialization JSONObjectWithData:metaData options:0 error:NULL] : nil;
                    NSString *title = waStreamString(meta[@"title_short"]) ?: waStreamString(meta[@"title"]);
                    NSDictionary *artistObj = [meta[@"artist"] isKindOfClass:[NSDictionary class]] ? meta[@"artist"] : nil;
                    NSString *artist = waStreamString(artistObj[@"name"]);
                    NSDictionary *albumObj = [meta[@"album"] isKindOfClass:[NSDictionary class]] ? meta[@"album"] : nil;
                    NSString *album = waStreamString(albumObj[@"title"]);
                    double duration = [meta[@"duration"] respondsToSelector:@selector(doubleValue)] ? [meta[@"duration"] doubleValue] : 0;
                    if (metaErr || !title.length || !artist.length) {
                        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(payload, nil); });
                        return;
                    }
                    NSString *lrclibURL = [NSString stringWithFormat:@"https://lrclib.net/api/get?artist_name=%@&track_name=%@&album_name=%@&duration=%.0f",
                                           waStreamEscape(artist), waStreamEscape(title), waStreamEscape(album ?: @""), duration];
                    NSMutableURLRequest *lrReq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:lrclibURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10.0];
                    [lrReq setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
                    [NSURLConnection sendAsynchronousRequest:lrReq queue:waStreamParseQueue() completionHandler:^(NSURLResponse *lrResp, NSData *lrData, NSError *lrErr) {
                        NSDictionary *lrJson = lrData.length ? [NSJSONSerialization JSONObjectWithData:lrData options:0 error:NULL] : nil;
                        NSString *synced = waStreamString(lrJson[@"syncedLyrics"]);
                        NSString *plainLR = waStreamString(lrJson[@"plainLyrics"]);
                        if (!lrErr && [lrResp isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse *)lrResp statusCode] == 200 && synced.length) {
                            // Parse LRC: [mm:ss.xx]text
                            NSMutableArray *lrLines = [NSMutableArray array];
                            for (NSString *rawLine in [synced componentsSeparatedByString:@"\n"]) {
                                if (!rawLine.length) continue;
                                // LRC may have multiple timestamps per line, take first
                                NSRange r = [rawLine rangeOfString:@"]"];
                                if (r.location == NSNotFound || ![rawLine hasPrefix:@"["]) continue;
                                NSString *ts = [rawLine substringWithRange:NSMakeRange(1, r.location-1)]; // mm:ss.xx
                                NSString *txt = [[rawLine substringFromIndex:r.location+1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                                if (!txt.length) continue;
                                NSArray *parts = [ts componentsSeparatedByString:@":"];
                                double m = 0, s = 0;
                                if (parts.count == 2) { m = [parts[0] doubleValue]; s = [parts[1] doubleValue]; }
                                else s = [ts doubleValue];
                                double sec = m*60 + s;
                                [lrLines addObject:@{@"time": @(sec), @"text": txt}];
                            }
                            if (lrLines.count) {
                                NSDictionary *lrPayload = @{
                                    @"plain": plainLR.length ? plainLR : text ?: @"",
                                    @"lineSynced": lrLines,
                                    @"wordSynced": @[],
                                    @"instrumental": @NO,
                                    @"source": @"lrclib",
                                    @"LYRICS_TEXT": plainLR ?: text ?: @""
                                };
                                dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(lrPayload, nil); });
                                return;
                            }
                        }
                        // LRCLIB miss -> return original Deezer plain
                        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(payload, nil); });
                    }];
                }];
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(payload, nil); });
        }];
    }];
    }];
    }];
}

@end
