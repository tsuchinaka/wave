#import "waLastFM.h"
#import "waTLS.h"
#import "waLog.h"
#import "waPlayer.h"
#import "waModel.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

NSString * const waLastFMDidChangeNotification = @"waLastFMDidChange";

static NSString * const waLastFMAPIKey = @"c024e3f25e4ac165951c2f1b1e25ee69";
static NSString * const waLastFMSecret = @"82e8209d21bccd47087118787d91cb40";
static NSString * const waLastFMEndpoint = @"https://ws.audioscrobbler.com/2.0/";
static NSString * const waLastFMService = @"com.sokubit.wave.lastfm";
static NSString * const waLastFMAccount = @"session";
static NSString * const waLastFMUserKey = @"wave.lastfm.username";
static NSString * const waLastFMLegacyUserKey = @"wa.lastfm.username";
static NSString * const waLastFMSessionDefaultsKey = @"wa.lastfm.sessionKey";
static NSString * const waLastFMScrobbleKey = @"wa.lastfm.scrobbling";
static NSString * const waLastFMPendingKey = @"wave.lastfm.pending";

static NSString *waLastFMMD5(NSString *string) {
    if (!string) string = @"";
    const char *bytes = [string UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(bytes, (CC_LONG)strlen(bytes), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *waLastFMEscape(NSString *value) {
    if (!value.length) return @"";
    CFStringRef escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)value, NULL, CFSTR(":/?#[]@!$&'()*+,;="), kCFStringEncodingUTF8);
    NSString *result = escaped ? [(__bridge NSString *)escaped copy] : value;
    if (escaped) CFRelease(escaped);
    return result;
}

static NSError *waLastFMError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"wave.lastfm" code:code userInfo:@{NSLocalizedDescriptionKey: message.length ? message : @"Last.fm failed."}];
}

@interface waLastFM ()
@property (nonatomic, copy) NSString *sessionKey;
@property (nonatomic, copy) NSString *username;
@property (nonatomic, assign) BOOL scrobblingEnabled;
@property (nonatomic, assign) dispatch_queue_t queue;
@property (nonatomic, copy) NSString *playID;
@property (nonatomic, copy) NSString *playTitle;
@property (nonatomic, copy) NSString *playArtist;
@property (nonatomic, copy) NSString *playAlbum;
@property (nonatomic, assign) NSTimeInterval playDuration;
@property (nonatomic, assign) NSTimeInterval playStartedAt;
@property (nonatomic, assign) NSTimeInterval playPosition;
@property (nonatomic, assign) BOOL playScrobbled;
@property (nonatomic, copy) NSString *nowPlayingID;
@property (nonatomic, strong) NSMutableArray *pending;
@end

@implementation waLastFM

+ (waLastFM *)shared {
    static waLastFM *client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ client = [[waLastFM alloc] init]; });
    return client;
}

- (id)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("wave.lastfm", DISPATCH_QUEUE_SERIAL);
        _sessionKey = [self storedSessionKey];
        _username = [[NSUserDefaults standardUserDefaults] stringForKey:waLastFMUserKey];
        if (!_username.length) _username = [[NSUserDefaults standardUserDefaults] stringForKey:waLastFMLegacyUserKey];
        _scrobblingEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:waLastFMScrobbleKey];
        [[waLog shared] log:@"last.fm restore user=%@ session=%d scrobble=%d", _username, (int)(_sessionKey.length > 0), (int)_scrobblingEnabled];
        NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:waLastFMPendingKey];
        _pending = stored.count ? [stored mutableCopy] : [NSMutableArray array];
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self selector:@selector(playerTrackChanged:) name:waPlayerTrackDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(playerStateChanged:) name:waPlayerStateDidChangeNotification object:nil];
        [center addObserver:self selector:@selector(playerProgress:) name:waPlayerProgressNotification object:nil];
        if (_sessionKey.length && _pending.count) {
            __weak waLastFM *weakSelf = self;
            dispatch_async(_queue, ^{ [weakSelf flushPending]; });
        }
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
#if !OS_OBJECT_USE_OBJC
    if (_queue) dispatch_release(_queue);
#endif
}

- (BOOL)signedIn {
    return self.sessionKey.length > 0;
}

- (BOOL)active {
    return self.signedIn && self.scrobblingEnabled;
}

#pragma mark - keychain

- (NSMutableDictionary *)keychainQuery {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    query[(__bridge id)kSecAttrService] = waLastFMService;
    query[(__bridge id)kSecAttrAccount] = waLastFMAccount;
    return query;
}

- (NSString *)keychainSessionKey {
    NSMutableDictionary *query = [self keychainQuery];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result) {
        NSData *data = (__bridge_transfer NSData *)result;
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    return nil;
}

- (void)writeKeychainSessionKey:(NSString *)key {
    NSMutableDictionary *query = [self keychainQuery];
    SecItemDelete((__bridge CFDictionaryRef)query);
    if (!key.length) return;
    query[(__bridge id)kSecValueData] = [key dataUsingEncoding:NSUTF8StringEncoding];
    query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
    if (status != errSecSuccess) [[waLog shared] log:@"last.fm keychain add %d", (int)status];
}

- (NSString *)storedSessionKey {
    NSString *stored = [[NSUserDefaults standardUserDefaults] stringForKey:waLastFMSessionDefaultsKey];
    if (stored.length) return stored;
    return [self keychainSessionKey];
}

- (void)storeSessionKey:(NSString *)key {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (key.length) [defaults setObject:key forKey:waLastFMSessionDefaultsKey];
    else [defaults removeObjectForKey:waLastFMSessionDefaultsKey];
    [defaults synchronize];
    [self writeKeychainSessionKey:key];
}

- (void)persistPending {
    [[NSUserDefaults standardUserDefaults] setObject:self.pending forKey:waLastFMPendingKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)postChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:waLastFMDidChangeNotification object:self];
    });
}

#pragma mark - auth

- (void)loginWithUsername:(NSString *)username password:(NSString *)password completion:(void (^)(BOOL, NSError *))completion {
    NSString *user = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *pass = password ?: @"";
    if (!user.length || !pass.length) {
        if (completion) completion(NO, waLastFMError(400, @"Enter a Last.fm username and password."));
        return;
    }
    __weak waLastFM *weakSelf = self;
    dispatch_async(self.queue, ^{
        NSError *error = nil;
        NSDictionary *json = [weakSelf callMethod:@"auth.getMobileSession"
                                           params:@{@"username": user, @"password": pass}
                                         session:NO
                                            error:&error];
        NSDictionary *session = [json isKindOfClass:[NSDictionary class]] ? json[@"session"] : nil;
        NSString *key = [session isKindOfClass:[NSDictionary class]] ? session[@"key"] : nil;
        NSString *name = [session isKindOfClass:[NSDictionary class]] ? session[@"name"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            waLastFM *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!key.length) {
                [[waLog shared] log:@"last.fm login failed %@", error.localizedDescription];
                if (completion) completion(NO, error ?: waLastFMError(401, @"Last.fm rejected the login."));
                return;
            }
            strongSelf.sessionKey = key;
            strongSelf.username = name.length ? name : user;
            strongSelf.scrobblingEnabled = YES;
            [strongSelf storeSessionKey:key];
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults setObject:strongSelf.username forKey:waLastFMUserKey];
            [defaults setObject:strongSelf.username forKey:waLastFMLegacyUserKey];
            [defaults setBool:YES forKey:waLastFMScrobbleKey];
            [defaults synchronize];
            [[waLog shared] log:@"last.fm login ok user=%@", strongSelf.username];
            [strongSelf postChange];
            if (completion) completion(YES, nil);
            waPlayer *player = [waPlayer shared];
            if (player.currentTrack && player.playing) {
                strongSelf.nowPlayingID = nil;
                [strongSelf sendNowPlaying:player.currentTrack];
            }
            dispatch_async(strongSelf.queue, ^{ [strongSelf flushPending]; });
        });
    });
}

- (void)logout {
    self.sessionKey = nil;
    self.username = nil;
    self.scrobblingEnabled = NO;
    self.nowPlayingID = nil;
    [self storeSessionKey:nil];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults removeObjectForKey:waLastFMUserKey];
    [defaults removeObjectForKey:waLastFMLegacyUserKey];
    [defaults setBool:NO forKey:waLastFMScrobbleKey];
    [defaults synchronize];
    [[waLog shared] log:@"last.fm logout"];
    [self postChange];
}

- (void)setScrobblingEnabled:(BOOL)enabled {
    if (!self.signedIn) enabled = NO;
    if (_scrobblingEnabled == enabled) return;
    _scrobblingEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:waLastFMScrobbleKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[waLog shared] log:@"last.fm scrobbling %d", (int)enabled];
    [self postChange];
    if (enabled) {
        waPlayer *player = [waPlayer shared];
        if (player.currentTrack && player.playing) {
            self.nowPlayingID = nil;
            [self sendNowPlaying:player.currentTrack];
        }
    }
}

#pragma mark - player

- (void)playerTrackChanged:(NSNotification *)note {
    (void)note;
    [self syncFromPlayer];
}

- (void)playerStateChanged:(NSNotification *)note {
    (void)note;
    [self syncFromPlayer];
}

- (void)playerProgress:(NSNotification *)note {
    (void)note;
    if (!self.active) return;
    waPlayer *player = [waPlayer shared];
    self.playPosition = player.currentTime;
    if (player.duration > 0.0) self.playDuration = player.duration;
    [self considerScrobble];
}

- (void)syncFromPlayer {
    waPlayer *player = [waPlayer shared];
    waTrack *track = player.currentTrack;
    NSString *identifier = track.identifier ?: @"";
    BOOL restart = identifier.length && [identifier isEqualToString:self.playID] && self.playPosition > 8.0 && player.currentTime < 5.0;
    if (![identifier isEqualToString:self.playID] || restart) {
        [self considerScrobble];
        self.playID = identifier.length ? identifier : nil;
        self.playTitle = track.title;
        self.playArtist = track.artistName;
        self.playAlbum = track.albumTitle;
        self.playDuration = player.duration > 0.0 ? player.duration : track.duration;
        self.playStartedAt = [[NSDate date] timeIntervalSince1970];
        self.playPosition = player.currentTime;
        self.playScrobbled = NO;
        self.nowPlayingID = nil;
    } else {
        self.playPosition = player.currentTime;
        if (player.duration > 0.0) self.playDuration = player.duration;
        if (track.title.length) self.playTitle = track.title;
        if (track.artistName.length) self.playArtist = track.artistName;
        if (track.albumTitle.length) self.playAlbum = track.albumTitle;
    }
    if (self.active && player.playing && track) [self sendNowPlaying:track];
}

- (BOOL)playMeetsScrobbleRule {
    if (self.playScrobbled) return NO;
    if (!self.playTitle.length || !self.playArtist.length) return NO;
    NSTimeInterval duration = self.playDuration;
    NSTimeInterval position = self.playPosition;
    if (duration > 0.0 && duration < 30.0) return NO;
    if (position < 30.0) return NO;
    NSTimeInterval threshold = 240.0;
    if (duration > 0.0) threshold = MIN(duration * 0.5, 240.0);
    return position >= threshold;
}

- (void)considerScrobble {
    if (!self.active) return;
    if (![self playMeetsScrobbleRule]) return;
    NSDictionary *item = [self currentScrobblePayload];
    if (!item) return;
    self.playScrobbled = YES;
    __weak waLastFM *weakSelf = self;
    dispatch_async(self.queue, ^{
        waLastFM *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.pending addObject:item];
        [strongSelf persistPending];
        [strongSelf flushPending];
    });
}

- (NSDictionary *)currentScrobblePayload {
    if (!self.playTitle.length || !self.playArtist.length) return nil;
    NSTimeInterval started = self.playStartedAt;
    if (started < 1.0) started = [[NSDate date] timeIntervalSince1970] - MAX(self.playPosition, 0.0);
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"artist"] = self.playArtist;
    item[@"track"] = self.playTitle;
    item[@"timestamp"] = [NSString stringWithFormat:@"%.0f", started];
    if (self.playAlbum.length) item[@"album"] = self.playAlbum;
    if (self.playDuration >= 1.0) item[@"duration"] = [NSString stringWithFormat:@"%.0f", self.playDuration];
    return item;
}

- (void)sendNowPlaying:(waTrack *)track {
    if (!self.active || !track) return;
    NSString *title = track.title;
    NSString *artist = track.artistName;
    if (!title.length || !artist.length) return;
    NSString *token = track.identifier.length ? track.identifier : [NSString stringWithFormat:@"%@\n%@", artist, title];
    if ([token isEqualToString:self.nowPlayingID]) return;
    self.nowPlayingID = token;
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"artist"] = artist;
    params[@"track"] = title;
    if (track.albumTitle.length) params[@"album"] = track.albumTitle;
    NSTimeInterval duration = self.playDuration > 0.0 ? self.playDuration : track.duration;
    if (duration >= 1.0) params[@"duration"] = [NSString stringWithFormat:@"%.0f", duration];
    __weak waLastFM *weakSelf = self;
    dispatch_async(self.queue, ^{
        NSError *error = nil;
        NSDictionary *json = [weakSelf callMethod:@"track.updateNowPlaying" params:params session:YES error:&error];
        if (json) [[waLog shared] log:@"last.fm nowplaying %@ - %@", artist, title];
        else [[waLog shared] log:@"last.fm nowplaying fail %@", error.localizedDescription];
        [weakSelf handleSessionError:error];
    });
}

- (void)flushPending {
    if (!self.sessionKey.length) return;
    while (self.pending.count) {
        NSDictionary *item = [self.pending objectAtIndex:0];
        NSError *error = nil;
        NSDictionary *json = [self callMethod:@"track.scrobble" params:item session:YES error:&error];
        if (!json) {
            [[waLog shared] log:@"last.fm scrobble fail %@", error.localizedDescription];
            [self handleSessionError:error];
            return;
        }
        [[waLog shared] log:@"last.fm scrobble %@ - %@", item[@"artist"], item[@"track"]];
        [self.pending removeObjectAtIndex:0];
        [self persistPending];
    }
}

- (void)handleSessionError:(NSError *)error {
    if (![error.domain isEqualToString:@"wave.lastfm"] || error.code != 9) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self logout];
    });
}

#pragma mark - http

- (NSDictionary *)callMethod:(NSString *)method params:(NSDictionary *)params session:(BOOL)needsSession error:(NSError **)error {
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    [params enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        (void)stop;
        if (![key isKindOfClass:[NSString class]]) return;
        NSString *string = [value isKindOfClass:[NSString class]] ? value : [value description];
        if (string.length) fields[key] = string;
    }];
    fields[@"method"] = method ?: @"";
    fields[@"api_key"] = waLastFMAPIKey;
    if (needsSession) {
        if (!self.sessionKey.length) {
            if (error) *error = waLastFMError(9, @"Not signed in to Last.fm.");
            return nil;
        }
        fields[@"sk"] = self.sessionKey;
    }
    NSArray *keys = [[fields allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *sig = [NSMutableString string];
    for (NSString *key in keys) {
        [sig appendString:key];
        [sig appendString:fields[key]];
    }
    [sig appendString:waLastFMSecret];
    fields[@"api_sig"] = waLastFMMD5(sig);
    fields[@"format"] = @"json";

    NSMutableString *bodyString = [NSMutableString string];
    NSArray *bodyKeys = [fields allKeys];
    for (NSUInteger i = 0; i < bodyKeys.count; i++) {
        NSString *key = bodyKeys[i];
        if (i) [bodyString appendString:@"&"];
        [bodyString appendFormat:@"%@=%@", waLastFMEscape(key), waLastFMEscape(fields[key])];
    }
    NSData *body = [bodyString dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL URLWithString:waLastFMEndpoint];
    NSDictionary *headers = @{@"Content-Type": @"application/x-www-form-urlencoded"};
    NSError *tlsError = nil;
    NSDictionary *response = [waTLS requestURL:url method:@"POST" headers:headers body:body timeout:16.0 verify:YES error:&tlsError];
    if (!response) {
        tlsError = nil;
        response = [waTLS requestURL:url method:@"POST" headers:headers body:body timeout:16.0 verify:NO error:&tlsError];
    }
    NSInteger status = [response[@"status"] integerValue];
    NSData *payload = response[@"body"];
    if (!payload.length) {
        if (error) *error = tlsError ?: waLastFMError(status, @"Last.fm returned an empty response.");
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) {
        if (error) *error = waLastFMError(status, @"Last.fm returned invalid JSON.");
        return nil;
    }
    id code = json[@"error"];
    if (code) {
        NSInteger lastError = [code integerValue];
        NSString *message = [json[@"message"] isKindOfClass:[NSString class]] ? json[@"message"] : @"Last.fm error.";
        if (error) *error = waLastFMError(lastError, message);
        return nil;
    }
    return json;
}

#pragma mark - logo

+ (UIImage *)logoActive:(BOOL)active {
    UIColor *color = active ? [UIColor colorWithRed:0.835 green:0.063 blue:0.027 alpha:1.0]
                            : [UIColor colorWithWhite:0.58 alpha:1.0];
    CGSize size = CGSizeMake(24.0, 24.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    [color setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(1.0, 13.4, 6.2, 6.2)] fill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(8.0, 2.2, 4.6, 17.4) cornerRadius:2.3] fill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(13.3, 6.4, 4.6, 13.2) cornerRadius:2.3] fill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(18.6, 10.4, 4.6, 9.2) cornerRadius:2.3] fill];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@end
