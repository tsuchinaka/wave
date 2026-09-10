#import "waLastFMClient.h"
#import "../Models/waPreferences.h"
#import "waDebugLog.h"
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>

@interface NSString (waLastFMCompatibility)
- (NSString *)stringByRemovingPercentEncoding;
@end

@implementation NSString (waLastFMCompatibility)
- (NSString *)stringByRemovingPercentEncoding { return [self stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]; }
@end

NSString * const waLastFMAuthenticationDidChangeNotification = @"waLastFMAuthenticationDidChangeNotification";
static NSString * const waLastFMAPIKey = @"c024e3f25e4ac165951c2f1b1e25ee69";
static NSString * const waLastFMAPISecret = @"82e8209d21bccd47087118787d91cb40";
static NSString * const waLastFMEndpoint = @"https://ws.audioscrobbler.com/2.0/";
static NSString * const waLastFMCallbackScheme = @"wave://lastfm/callback";

static NSOperationQueue *waLastFMNetworkQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 2;
    });
    return queue;
}

@interface waLastFMClient () <NSURLConnectionDataDelegate>
@property (nonatomic, copy) NSString *pendingToken;
@property (nonatomic, copy) void (^pendingCompletion)(NSError *error);
@end

static NSString *waLastFMMD5(NSString *value) { const char *bytes = value.UTF8String; unsigned char digest[CC_MD5_DIGEST_LENGTH]; CC_MD5(bytes, (CC_LONG)strlen(bytes), digest); NSMutableString *result = [NSMutableString stringWithCapacity:32]; for (NSUInteger i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [result appendFormat:@"%02x", digest[i]]; return result; }
static NSString *waLastFMEncode(NSString *value) { return [value stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @""; }
static NSString *waLastFMSign(NSDictionary *params) {
    NSArray *keys = [[params allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *plain = [NSMutableString string];
    for (NSString *key in keys) {
        // Last.fm's authentication spec explicitly excludes format and
        // callback from api_sig calculation.
        if ([key isEqualToString:@"format"] || [key isEqualToString:@"callback"] || [key isEqualToString:@"api_sig"]) continue;
        [plain appendFormat:@"%@%@", key, params[key]];
    }
    [plain appendString:waLastFMAPISecret];
    return waLastFMMD5(plain);
}
static void waLastFMAuthenticatedRequest(NSString *method, NSDictionary *parameters, void (^completion)(NSError *error)) {
    NSString *sessionKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"wa.lastfm.sessionKey"];
    if (!sessionKey.length) {
        [[waDebugLog sharedLog] log:@"Last.fm %@ skipped: no session key", method];
        if (completion) completion([NSError errorWithDomain:@"com.bytebox.wave.lastfm" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Last.fm is not connected."}]);
        return;
    }
    NSMutableDictionary *params = [parameters mutableCopy];
    params[@"api_key"] = waLastFMAPIKey;
    params[@"method"] = method;
    params[@"sk"] = sessionKey;
    params[@"format"] = @"json";
    params[@"api_sig"] = waLastFMSign(params);
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in params) [parts addObject:[NSString stringWithFormat:@"%@=%@", waLastFMEncode(key), waLastFMEncode([params[key] description])]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:waLastFMEndpoint]];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 30.0;
    request.allowsCellularAccess = [waPreferences sharedPreferences].cellularDataAllowed;
    request.HTTPBody = [[parts componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [[waDebugLog sharedLog] log:@"Last.fm %@ request queued (session present)", method];
    [NSURLConnection sendAsynchronousRequest:request queue:waLastFMNetworkQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSError *result = error;
        if (!result && (!http || http.statusCode < 200 || http.statusCode >= 300)) result = [NSError errorWithDomain:@"com.bytebox.wave.lastfm" code:http.statusCode userInfo:@{NSLocalizedDescriptionKey:@"Last.fm returned an invalid response."}];
        if (!result && [json isKindOfClass:[NSDictionary class]] && json[@"error"]) {
            NSInteger code = [json[@"error"] respondsToSelector:@selector(integerValue)] ? [json[@"error"] integerValue] : 6;
            NSString *message = [json[@"message"] isKindOfClass:[NSString class]] ? json[@"message"] : @"Last.fm rejected the request.";
            result = [NSError errorWithDomain:@"com.bytebox.wave.lastfm" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
            if (code == 9) {
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"wa.lastfm.sessionKey"];
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"wa.lastfm.username"];
                [[NSNotificationCenter defaultCenter] postNotificationName:waLastFMAuthenticationDidChangeNotification object:[waLastFMClient class]];
            }
        }
        // HTTP 200 does not mean the scrobble was accepted: Last.fm answers
        // 200 with scrobbles.@attr.accepted=0 and an ignoredMessage when it
        // drops a submission (bad metadata, invalid timestamp, rate limit).
        if (!result && [json isKindOfClass:[NSDictionary class]] && [json[@"scrobbles"] isKindOfClass:[NSDictionary class]]) {
            NSDictionary *attr = json[@"scrobbles"][@"@attr"] ?: json[@"scrobbles"][@"attr"];
            NSInteger accepted = [attr[@"accepted"] respondsToSelector:@selector(integerValue)] ? [attr[@"accepted"] integerValue] : 1;
            if (accepted == 0) {
                NSDictionary *scrobble = [json[@"scrobbles"][@"scrobble"] isKindOfClass:[NSDictionary class]] ? json[@"scrobbles"][@"scrobble"] : nil;
                NSString *ignored = [scrobble[@"ignoredMessage"][@"#text"] isKindOfClass:[NSString class]] ? scrobble[@"ignoredMessage"][@"#text"] : nil;
                result = [NSError errorWithDomain:@"com.bytebox.wave.lastfm" code:30 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Scrobble ignored: %@", ignored.length ? ignored : @"no reason given"]}];
            }
        }
        [[waDebugLog sharedLog] log:@"Last.fm %@ response HTTP %ld (%@)", method, (long)(http ? http.statusCode : 0), result ? result.localizedDescription : @"OK"];
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(result); });
    }];
}

@implementation waLastFMClient
- (void)loginWithUsername:(NSString *)username password:(NSString *)password completion:(void (^)(NSError *))completion {
    if (!username.length || !password.length) { if (completion) completion([NSError errorWithDomain:@"com.bytebox.wave.lastfm" code:5 userInfo:@{NSLocalizedDescriptionKey:@"Enter both your username and password."}]); return; }
    [[waDebugLog sharedLog] log:@"Last.fm auth.getMobileSession request queued (username length %lu)", (unsigned long)username.length];
    NSDictionary *params = @{ @"api_key":waLastFMAPIKey, @"method":@"auth.getMobileSession", @"username":username, @"password":password };
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:waLastFMEndpoint]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [[NSString stringWithFormat:@"api_key=%@&method=%@&username=%@&password=%@&api_sig=%@&format=json", waLastFMEncode(waLastFMAPIKey), waLastFMEncode(@"auth.getMobileSession"), waLastFMEncode(username), waLastFMEncode(password), waLastFMSign(params)] dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSString *key = json[@"session"][@"key"];
        NSError *result = error;
         if (!result && ![key isKindOfClass:[NSString class]]) { id errorValue = json[@"error"]; NSString *message = [json[@"message"] isKindOfClass:[NSString class]] ? json[@"message"] : nil; NSInteger code = [errorValue respondsToSelector:@selector(integerValue)] ? [errorValue integerValue] : 6; if (!code) code = 6; NSString *description = message.length ? [NSString stringWithFormat:@"Last.fm error %ld: %@", (long)code, message] : @"Last.fm rejected the login without an error message."; result = [NSError errorWithDomain:@"com.bytebox.wave.lastfm" code:code userInfo:@{NSLocalizedDescriptionKey:description}]; }
         [[waDebugLog sharedLog] log:@"Last.fm auth.getMobileSession response HTTP %ld (%@)", (long)([response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0), result ? result.localizedDescription : @"OK"];
         if (!result) { [[NSUserDefaults standardUserDefaults] setObject:key forKey:@"wa.lastfm.sessionKey"]; [[NSUserDefaults standardUserDefaults] setObject:json[@"session"][@"name"] ?: username forKey:@"wa.lastfm.username"]; // Logging in is an explicit scrobbling intent: enable it so a fresh
         // install does not silently keep the scrobble switch off.
         [waPreferences sharedPreferences].lastFMScrobblingEnabled = YES; [[waDebugLog sharedLog] log:@"Last.fm scrobbling enabled by login"]; [[NSNotificationCenter defaultCenter] postNotificationName:waLastFMAuthenticationDidChangeNotification object:self]; }
        if (completion) completion(result);
    }];
}
+ (waLastFMClient *)sharedClient { static waLastFMClient *client; if (!client) client = [[self alloc] init]; return client; }
- (BOOL)isAuthenticated { return [[NSUserDefaults standardUserDefaults] stringForKey:@"wa.lastfm.sessionKey"].length > 0; }
- (BOOL)hasPendingLogin { return self.pendingToken.length > 0; }
- (void)beginLoginWithCompletion:(void (^)(NSError *))completion { if ([waLastFMAPIKey hasPrefix:@"YOUR_"] || [waLastFMAPISecret hasPrefix:@"YOUR_"]) { if (completion) completion([NSError errorWithDomain:@"com.bytebox.wave.lastfm" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Configure the Last.fm API key and secret in waLastFMClient.m first."}]); return; } NSDictionary *p = @{ @"api_key":waLastFMAPIKey, @"method":@"auth.getToken" }; NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:waLastFMEndpoint]]; request.HTTPMethod = @"POST"; NSString *body = [NSString stringWithFormat:@"api_key=%@&method=%@&api_sig=%@&format=json", waLastFMEncode(p[@"api_key"]), waLastFMEncode(p[@"method"]), waLastFMSign(p)]; request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding]; [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"]; self.pendingCompletion = completion; [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) { NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil; NSString *token = json[@"token"]; if (error || !token.length) { void (^done)(NSError *) = self.pendingCompletion; self.pendingCompletion = nil; if (done) done(error ?: [NSError errorWithDomain:@"com.bytebox.wave.lastfm" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Last.fm did not return an authorization token."}]); return; } self.pendingToken = token; NSString *url = [NSString stringWithFormat:@"https://www.last.fm/api/auth/?api_key=%@&token=%@", waLastFMEncode(waLastFMAPIKey), waLastFMEncode(token)]; [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]]; }]; }
- (void)completeLoginWithCompletion:(void (^)(NSError *))completion { if (!self.pendingToken.length) { if (completion) completion([NSError errorWithDomain:@"com.bytebox.wave.lastfm" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Authorize Wave in Safari first, then tap Last.fm again."}]); return; } self.pendingCompletion = completion; NSURL *callback = [NSURL URLWithString:[NSString stringWithFormat:@"%@?token=%@", waLastFMCallbackScheme, waLastFMEncode(self.pendingToken)]]; [self handleCallbackURL:callback]; }
- (BOOL)handleCallbackURL:(NSURL *)url { if (![[url.scheme lowercaseString] isEqualToString:@"wave"] || ![[url.host lowercaseString] isEqualToString:@"lastfm"]) return NO; NSString *query = url.query ?: @""; NSString *token = nil; for (NSString *part in [query componentsSeparatedByString:@"&"]) { NSArray *pair = [part componentsSeparatedByString:@"="]; if (pair.count == 2 && [pair[0] isEqualToString:@"token"]) token = [pair[1] stringByRemovingPercentEncoding]; } if (!token.length) return NO; NSDictionary *p = @{ @"api_key":waLastFMAPIKey, @"method":@"auth.getSession", @"token":token }; NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:waLastFMEndpoint]]; request.HTTPMethod = @"POST"; request.HTTPBody = [[NSString stringWithFormat:@"api_key=%@&method=%@&token=%@&api_sig=%@&format=json", waLastFMEncode(waLastFMAPIKey), waLastFMEncode(@"auth.getSession"), waLastFMEncode(token), waLastFMSign(p)] dataUsingEncoding:NSUTF8StringEncoding]; [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"]; [NSURLConnection sendAsynchronousRequest:request queue:[NSOperationQueue mainQueue] completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) { NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil; NSDictionary *session = json[@"session"]; NSError *result = error; if (!result && ![session[@"key"] isKindOfClass:[NSString class]]) result = [NSError errorWithDomain:@"com.bytebox.wave.lastfm" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Last.fm session confirmation failed."}]; if (!result) { [[NSUserDefaults standardUserDefaults] setObject:session[@"key"] forKey:@"wa.lastfm.sessionKey"]; [[NSUserDefaults standardUserDefaults] setObject:session[@"name"] ?: @"" forKey:@"wa.lastfm.username"]; } void (^done)(NSError *) = self.pendingCompletion; self.pendingCompletion = nil; self.pendingToken = nil; if (done) done(result); [[NSNotificationCenter defaultCenter] postNotificationName:waLastFMAuthenticationDidChangeNotification object:self]; }]; return YES; }
- (void)logout { [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"wa.lastfm.sessionKey"]; [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"wa.lastfm.username"]; [[NSNotificationCenter defaultCenter] postNotificationName:waLastFMAuthenticationDidChangeNotification object:self]; }
- (void)updateNowPlayingArtist:(NSString *)artist title:(NSString *)title duration:(NSTimeInterval)duration completion:(void (^)(NSError *))completion { if ([waPreferences sharedPreferences].privateSession || !artist.length || !title.length) { [[waDebugLog sharedLog] log:@"Last.fm Now Playing skipped: private session or incomplete metadata"]; if (completion) completion(nil); return; } [[waDebugLog sharedLog] log:@"Last.fm Now Playing requested: %@ — %@", artist, title]; NSMutableDictionary *params = [@{ @"artist":artist, @"track":title } mutableCopy]; if (duration > 0.0) params[@"duration"] = @((NSInteger)duration); waLastFMAuthenticatedRequest(@"track.updateNowPlaying", params, completion); }
- (void)scrobbleArtist:(NSString *)artist title:(NSString *)title album:(NSString *)album duration:(NSTimeInterval)duration timestamp:(NSTimeInterval)timestamp completion:(void (^)(NSError *))completion { if ([waPreferences sharedPreferences].privateSession || !artist.length || !title.length || timestamp <= 0.0) { [[waDebugLog sharedLog] log:@"Last.fm scrobble skipped: private session or incomplete metadata"]; if (completion) completion(nil); return; } [[waDebugLog sharedLog] log:@"Last.fm scrobble requested: %@ — %@", artist, title]; NSMutableDictionary *params = [@{ @"artist":artist, @"track":title, @"timestamp":@((NSInteger)timestamp) } mutableCopy]; if (album.length) params[@"album"] = album; if (duration > 0.0) params[@"duration"] = @((NSInteger)duration); waLastFMAuthenticatedRequest(@"track.scrobble", params, completion); }
@end
