#import "waDZAPI.h"
#import "waTLS.h"
#import "waLog.h"
#import <SystemConfiguration/SystemConfiguration.h>

static NSString * const waGatewayURL = @"https://www.deezer.com/ajax/gw-light.php";
static NSString * const waMediaURL = @"https://media.deezer.com/v1/get_url";
static NSString * const waAPIURL = @"https://api.deezer.com";
static NSString * const waAPIErrorDomain = @"wave.deezer.api";

static NSString *waEsc(NSString *value) {
    if (!value.length) return @"";
    CFStringRef escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)value, NULL, CFSTR(":/?#[]@!$&'()*+,;="), kCFStringEncodingUTF8);
    NSString *result = escaped ? [(__bridge NSString *)escaped copy] : value;
    if (escaped) CFRelease(escaped);
    return result;
}

static NSString *waStr(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

static NSError *waError(NSString *message, NSInteger code) {
    return [NSError errorWithDomain:waAPIErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Deezer request failed."}];
}

static BOOL waWifiOnlyEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"wave.wifiOnly"];
}

static BOOL waOnCellular(void) {
    static NSTimeInterval lastCheck = 0;
    static BOOL cached = NO;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - lastCheck < 5.0) return cached;
    lastCheck = now;
    SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(NULL, "api.deezer.com");
    if (!reachability) { cached = NO; return NO; }
    SCNetworkReachabilityFlags flags = 0;
    BOOL onCellular = NO;
    if (SCNetworkReachabilityGetFlags(reachability, &flags)) {
        onCellular = (flags & kSCNetworkReachabilityFlagsIsWWAN) != 0;
    }
    CFRelease(reachability);
    cached = onCellular;
    return onCellular;
}

static NSError *waNetworkGateError(void) {
    return waError(@"Wi-Fi only is on. Connect to Wi-Fi to stream.", 9001);
}

// gw-light.php reports success as "error": [] or "error": {}. Only a populated
// payload is a failure. Treating {} as an error made every gateway lookup fail
// and the player substituted the 30-second preview.
static BOOL waGatewayFailed(id errorObject, NSString **message) {
    if (!errorObject || errorObject == [NSNull null]) return NO;
    if ([errorObject isKindOfClass:[NSArray class]]) return [(NSArray *)errorObject count] > 0;
    if ([errorObject isKindOfClass:[NSString class]]) {
        if (message && [(NSString *)errorObject length]) *message = errorObject;
        return [(NSString *)errorObject length] > 0;
    }
    if (![errorObject isKindOfClass:[NSDictionary class]]) return NO;
    NSDictionary *dict = errorObject;
    if (!dict.count) return NO;
    NSString *text = waStr(dict[@"message"]) ?: waStr(dict[@"DATA_ERROR"]) ?: waStr(dict[@"error"]);
    id code = dict[@"code"] ?: dict[@"error_code"];
    if (!text.length && (!code || [code integerValue] == 0)) return NO;
    if (message) *message = text;
    return YES;
}

static BOOL waPreviewURL(NSString *url) {
    if (!url.length) return NO;
    NSString *lower = url.lowercaseString;
    return [lower rangeOfString:@"preview"].location != NSNotFound;
}

@interface waDZAPI ()
@property (nonatomic, strong) NSMutableDictionary *getCache;
@property (nonatomic, strong) NSMutableDictionary *inflight;
- (void)sendURL:(NSURL *)url
         method:(NSString *)method
        headers:(NSDictionary *)headers
           body:(NSData *)body
     completion:(void (^)(NSData *data, id json, NSInteger status, NSError *error))completion;
- (void)requestPath:(NSString *)path method:(NSString *)method params:(NSDictionary *)params completion:(void (^)(NSDictionary *json, NSError *error))completion;
- (NSString *)cookieHeader;
- (NSString *)cacheKeyForPath:(NSString *)path params:(NSDictionary *)params;
@end

@implementation waDZAPI

+ (waDZAPI *)shared {
    static waDZAPI *api;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ api = [[waDZAPI alloc] init]; });
    return api;
}

- (id)init {
    if ((self = [super init])) {
        _getCache = [NSMutableDictionary dictionary];
        _inflight = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)cacheKeyForPath:(NSString *)path params:(NSDictionary *)params {
    NSMutableString *key = [NSMutableString stringWithString:path ?: @""];
    NSArray *keys = [[params allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in keys) {
        [key appendFormat:@"&%@=%@", name, waStr(params[name]) ?: @""];
    }
    return key;
}

- (BOOL)hasSession {
    return self.checkForm.length > 0 && self.sessionID.length > 0;
}

- (void)resetSession {
    self.sessionID = nil;
    self.checkForm = nil;
    self.licenseToken = nil;
}

- (NSString *)cookieHeader {
    if (self.arl.length && self.sessionID.length) {
        return [NSString stringWithFormat:@"arl=%@; sid=%@", self.arl, self.sessionID];
    }
    if (self.arl.length) return [NSString stringWithFormat:@"arl=%@", self.arl];
    return nil;
}

- (void)sendURL:(NSURL *)url method:(NSString *)method headers:(NSDictionary *)headers body:(NSData *)body completion:(void (^)(NSData *, id, NSInteger, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        NSDictionary *response = [waTLS requestURL:url method:method headers:headers body:body timeout:20.0 error:&error];
        NSData *data = response[@"body"];
        NSInteger status = [response[@"status"] integerValue];
        id json = nil;
        if (data.length) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(data, json, status, error);
        });
    });
}

- (void)callMethod:(NSString *)method params:(NSDictionary *)params completion:(void (^)(NSDictionary *, NSError *))completion {
    if (waWifiOnlyEnabled() && waOnCellular()) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, waNetworkGateError()); });
        return;
    }
    NSString *token = self.checkForm.length ? self.checkForm : @"null";
    NSString *urlString = [NSString stringWithFormat:@"%@?method=%@&api_version=1.0&input=3&api_token=%@",
                           waGatewayURL, waEsc(method), waEsc(token)];
    NSData *body = [NSJSONSerialization dataWithJSONObject:params ?: @{} options:0 error:NULL];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    if (self.cookieHeader) headers[@"Cookie"] = self.cookieHeader;
    [self sendURL:[NSURL URLWithString:urlString] method:@"POST" headers:headers body:body completion:^(NSData *data, id parsed, NSInteger status, NSError *error) {
        (void)data;
        if (!error && (status < 200 || status >= 300)) error = waError(@"Deezer rejected the request.", 500);
        NSDictionary *json = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
        if (!error) {
            NSString *gatewayMessage = nil;
            if (waGatewayFailed(json[@"error"], &gatewayMessage)) {
                error = waError(gatewayMessage ?: @"Deezer returned an error.", 400);
            }
        }
        NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
        if (!results && [json isKindOfClass:[NSDictionary class]]) results = json;
        if (completion) completion(results, error);
    }];
}

- (void)getPath:(NSString *)path params:(NSDictionary *)params completion:(void (^)(NSDictionary *, NSError *))completion {
    [self requestPath:path method:@"GET" params:params completion:completion];
}

- (void)postPath:(NSString *)path params:(NSDictionary *)params completion:(void (^)(NSDictionary *, NSError *))completion {
    [self requestPath:path method:@"POST" params:params completion:completion];
}

- (void)deletePath:(NSString *)path params:(NSDictionary *)params completion:(void (^)(NSDictionary *, NSError *))completion {
    [self requestPath:path method:@"DELETE" params:params completion:completion];
}

- (BOOL)shouldCachePath:(NSString *)path method:(NSString *)method {
    if (![[method uppercaseString] isEqualToString:@"GET"]) return NO;
    if ([path rangeOfString:@"/search"].location != NSNotFound) return NO;
    return YES;
}

- (void)deliver:(NSDictionary *)dict error:(NSError *)error completion:(void (^)(NSDictionary *, NSError *))completion {
    if (!completion) return;
    if ([NSThread isMainThread]) completion(dict, error);
    else dispatch_async(dispatch_get_main_queue(), ^{ completion(dict, error); });
}

- (void)requestPath:(NSString *)path method:(NSString *)method params:(NSDictionary *)params completion:(void (^)(NSDictionary *, NSError *))completion {
    if (waWifiOnlyEnabled() && waOnCellular()) {
        [self deliver:nil error:waNetworkGateError() completion:completion];
        return;
    }
    NSString *verb = method.length ? method : @"GET";
    NSString *cacheKey = nil;
    if ([self shouldCachePath:path method:verb]) {
        cacheKey = [self cacheKeyForPath:path params:params];
        NSDictionary *entry = self.getCache[cacheKey];
        NSTimeInterval expires = [entry[@"expires"] doubleValue];
        NSDictionary *cached = entry[@"json"];
        if (cached && expires > CFAbsoluteTimeGetCurrent()) {
            [self deliver:cached error:nil completion:completion];
            return;
        }
        NSMutableArray *waiters = self.inflight[cacheKey];
        if (waiters) {
            if (completion) [waiters addObject:[completion copy]];
            return;
        }
        NSMutableArray *fresh = [NSMutableArray array];
        if (completion) [fresh addObject:[completion copy]];
        self.inflight[cacheKey] = fresh;
    }
    NSMutableString *urlString = [NSMutableString stringWithFormat:@"%@%@", waAPIURL, path ?: @""];
    BOOL first = YES;
    for (NSString *key in params) {
        NSString *value = waStr(params[key]);
        if (!value.length) continue;
        [urlString appendFormat:@"%@%@=%@", first ? @"?" : @"&", waEsc(key), waEsc(value)];
        first = NO;
    }
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    if (self.cookieHeader) headers[@"Cookie"] = self.cookieHeader;
    [self sendURL:[NSURL URLWithString:urlString] method:verb headers:headers body:nil completion:^(NSData *data, id parsed, NSInteger status, NSError *error) {
        (void)data;
        if (!error && (status < 200 || status >= 300)) error = waError(@"Deezer catalog is unavailable.", 500);
        if (!error && !parsed) error = waError(@"Deezer returned an unreadable response.", 500);
        NSDictionary *dict = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
        if (!dict && [parsed isKindOfClass:[NSArray class]]) dict = @{@"data": parsed};
        if (!error && dict[@"error"]) error = waError(waStr(dict[@"error"][@"message"]) ?: @"Deezer catalog error.", 400);
        if (cacheKey) {
            NSArray *waiters = [self.inflight[cacheKey] copy];
            [self.inflight removeObjectForKey:cacheKey];
            if (!error && dict) {
                if (self.getCache.count > 40) [self.getCache removeAllObjects];
                self.getCache[cacheKey] = @{@"json": dict, @"expires": @(CFAbsoluteTimeGetCurrent() + 70.0)};
            }
            if (!waiters.count) {
                if (completion) completion(dict, error);
                return;
            }
            for (void (^block)(NSDictionary *, NSError *) in waiters) {
                if (block) block(dict, error);
            }
            return;
        }
        if (completion) completion(dict, error);
    }];
}

- (void)loadUserData:(void (^)(NSDictionary *, NSError *))completion {
    NSString *urlString = [NSString stringWithFormat:@"%@?method=deezer.getUserData&api_version=1.0&api_token=", waGatewayURL];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    if (self.arl.length) headers[@"Cookie"] = [NSString stringWithFormat:@"arl=%@", self.arl];
    NSData *body = [NSJSONSerialization dataWithJSONObject:@{} options:0 error:NULL];
    [self sendURL:[NSURL URLWithString:urlString] method:@"POST" headers:headers body:body completion:^(NSData *data, id parsed, NSInteger status, NSError *error) {
        (void)data;
        if (!error && (status < 200 || status >= 300)) error = waError(@"Deezer login could not be validated.", 500);
        NSDictionary *json = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
        NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
        NSDictionary *user = [results[@"USER"] isKindOfClass:[NSDictionary class]] ? results[@"USER"] : nil;
        NSDictionary *options = [user[@"OPTIONS"] isKindOfClass:[NSDictionary class]] ? user[@"OPTIONS"] : nil;
        NSString *checkForm = waStr(results[@"checkForm"]) ?: waStr(results[@"CHECK_FORM"]);
        NSString *session = waStr(results[@"SESSION_ID"]) ?: waStr(user[@"SESSION_ID"]);
        NSString *license = waStr(options[@"license_token"]) ?: waStr(user[@"LICENSE_TOKEN"]);
        if (!error && (!user || !checkForm.length)) error = waError(@"The ARL was rejected. Paste a fresh one.", 401);
        if (!error) {
            self.sessionID = session;
            self.checkForm = checkForm;
            self.licenseToken = license;
            [[waLog shared] log:@"deezer session ok user=%@ license=%d", waStr(user[@"BLOG_NAME"]), license.length > 0];
        }
        if (completion) completion(user, error);
    }];
}

- (void)trackTokenForID:(NSString *)trackID completion:(void (^)(NSString *, NSError *))completion {
    [self resolveStreamForTrackID:trackID completion:^(NSString *token, NSString *streamID, NSError *error) {
        (void)streamID;
        if (completion) completion(token, error);
    }];
}

- (NSDictionary *)songPayload:(NSDictionary *)result {
    if (![result isKindOfClass:[NSDictionary class]]) return nil;
    if ([result[@"DATA"] isKindOfClass:[NSDictionary class]] && (result[@"DATA"][@"SNG_ID"] || result[@"DATA"][@"TRACK_TOKEN"])) {
        return result[@"DATA"];
    }
    if (result[@"SNG_ID"] || result[@"TRACK_TOKEN"]) return result;
    return result;
}

- (void)token:(NSString **)token streamID:(NSString **)streamID fromSong:(NSDictionary *)song fallbackID:(NSString *)fallbackID {
    if (![song isKindOfClass:[NSDictionary class]]) return;
    NSString *foundToken = waStr(song[@"TRACK_TOKEN"]) ?: waStr(song[@"track_token"]);
    NSString *foundID = waStr(song[@"SNG_ID"]) ?: fallbackID;
    NSDictionary *fallback = [song[@"FALLBACK"] isKindOfClass:[NSDictionary class]] ? song[@"FALLBACK"] : nil;
    BOOL readable = YES;
    if (song[@"READABLE"]) {
        id readableValue = song[@"READABLE"];
        readable = [readableValue respondsToSelector:@selector(boolValue)] ? [readableValue boolValue] : YES;
    }
    if ((!foundToken.length || !readable) && fallback) {
        NSString *fallbackToken = waStr(fallback[@"TRACK_TOKEN"]) ?: waStr(fallback[@"track_token"]);
        NSString *fallbackSongID = waStr(fallback[@"SNG_ID"]);
        if (fallbackToken.length) {
            foundToken = fallbackToken;
            if (fallbackSongID.length) foundID = fallbackSongID;
        }
    }
    if (token) *token = foundToken;
    if (streamID) *streamID = foundID;
}

- (void)resolveStreamForTrackID:(NSString *)trackID completion:(void (^)(NSString *, NSString *, NSError *))completion {
    if (!trackID.length) {
        if (completion) completion(nil, nil, waError(@"Missing track id.", 400));
        return;
    }
    [self callMethod:@"song.getData" params:@{@"sng_id": trackID} completion:^(NSDictionary *result, NSError *error) {
        NSString *token = nil;
        NSString *streamID = nil;
        [self token:&token streamID:&streamID fromSong:[self songPayload:result] fallbackID:trackID];
        if (token.length) {
            if (completion) completion(token, streamID.length ? streamID : trackID, nil);
            return;
        }
        [self callMethod:@"deezer.pageTrack" params:@{@"sng_id": trackID} completion:^(NSDictionary *page, NSError *pageError) {
            NSString *pageToken = nil;
            NSString *pageID = nil;
            [self token:&pageToken streamID:&pageID fromSong:[self songPayload:page] fallbackID:trackID];
            if (!pageToken.length) {
                if (completion) completion(nil, nil, pageError ?: error ?: waError(@"Track is not streamable with this account.", 403));
                return;
            }
            if (completion) completion(pageToken, pageID.length ? pageID : trackID, nil);
        }];
    }];
}

- (void)signedURLForTrackToken:(NSString *)trackToken formats:(NSArray *)formats completion:(void (^)(NSString *, NSString *, NSError *))completion {
    if (waWifiOnlyEnabled() && waOnCellular()) {
        if (completion) completion(nil, nil, waNetworkGateError());
        return;
    }
    if (!self.licenseToken.length) {
        if (completion) completion(nil, nil, waError(@"Connect your Deezer account first.", 401));
        return;
    }
    NSMutableArray *cipherFormats = [NSMutableArray arrayWithCapacity:formats.count];
    for (NSString *format in formats) {
        if (!format.length) continue;
        [cipherFormats addObject:@{@"cipher": @"BF_CBC_STRIPE", @"format": format}];
    }
    if (!cipherFormats.count) [cipherFormats addObject:@{@"cipher": @"BF_CBC_STRIPE", @"format": @"MP3_128"}];
    NSDictionary *bodyObject = @{@"license_token": self.licenseToken,
                                 @"media": @[@{@"type": @"FULL", @"formats": cipherFormats}],
                                 @"track_tokens": @[trackToken ?: @""]};
    NSData *body = [NSJSONSerialization dataWithJSONObject:bodyObject options:0 error:NULL];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    if (self.cookieHeader) headers[@"Cookie"] = self.cookieHeader;
    [self sendURL:[NSURL URLWithString:waMediaURL] method:@"POST" headers:headers body:body completion:^(NSData *data, id parsed, NSInteger status, NSError *error) {
        (void)data;
        if (!error && (status < 200 || status >= 300)) error = waError(@"Deezer media request failed.", 500);
        NSDictionary *json = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
        NSString *urlString = nil;
        NSString *grantedFormat = nil;
        id array = json[@"data"];
        if ([array isKindOfClass:[NSArray class]] && [array count]) {
            NSDictionary *entry = [array objectAtIndex:0];
            NSString *mediaError = nil;
            if (waGatewayFailed(entry[@"errors"], &mediaError) || ([entry[@"errors"] isKindOfClass:[NSArray class]] && [entry[@"errors"] count])) {
                id first = [entry[@"errors"] isKindOfClass:[NSArray class]] ? [entry[@"errors"] objectAtIndex:0] : entry[@"errors"];
                mediaError = waStr([first isKindOfClass:[NSDictionary class]] ? first[@"message"] : first) ?: mediaError;
                error = waError(mediaError ?: @"This track is not available for your account.", 403);
            }
            id mediaList = entry[@"media"];
            if ([mediaList isKindOfClass:[NSDictionary class]]) mediaList = @[mediaList];
            if ([mediaList isKindOfClass:[NSArray class]]) {
                for (NSDictionary *mediaEntry in mediaList) {
                    if (![mediaEntry isKindOfClass:[NSDictionary class]]) continue;
                    NSString *kind = waStr(mediaEntry[@"media_type"]) ?: waStr(mediaEntry[@"type"]);
                    if (kind.length && [kind caseInsensitiveCompare:@"PREVIEW"] == NSOrderedSame) continue;
                    id sources = mediaEntry[@"sources"];
                    if ([sources isKindOfClass:[NSDictionary class]]) sources = @[sources];
                    if (![sources isKindOfClass:[NSArray class]]) continue;
                    for (NSDictionary *source in sources) {
                        NSString *candidate = waStr([source isKindOfClass:[NSDictionary class]] ? source[@"url"] : nil);
                        if (!candidate.length || waPreviewURL(candidate)) continue;
                        urlString = candidate;
                        grantedFormat = waStr(mediaEntry[@"format"]) ?: grantedFormat;
                        error = nil;
                        break;
                    }
                    if (urlString.length) break;
                }
            }
        }
        if (!urlString.length && !error) error = waError(@"Deezer did not return a full stream URL.", 403);
        if (urlString.length && waPreviewURL(urlString)) {
            urlString = nil;
            error = waError(@"Deezer returned a 30-second preview.", 403);
        }
        if (completion) completion(urlString, grantedFormat, error);
    }];
}

- (void)logListenForTrackID:(NSString *)trackID completion:(void (^)(NSError *))completion {
    if (!trackID.length || !self.hasSession) {
        if (completion) completion(nil);
        return;
    }
    [self callMethod:@"log.listen" params:@{@"params": @{@"track_id": trackID, @"date": @([[NSDate date] timeIntervalSince1970])}} completion:^(NSDictionary *result, NSError *error) {
        if (completion) completion(error);
    }];
}

@end
