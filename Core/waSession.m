#import "waSession.h"
#import "waDZAPI.h"
#import "waPlayer.h"
#import "waLog.h"
#import "waImageCache.h"
#import "waDownloader.h"
#import "waTLS.h"
#import "waLyrics.h"
#import "waStreamCache.h"
#import <Security/Security.h>

NSString * const waSessionDidChangeNotification = @"waSessionDidChangeNotification";
NSString * const waSessionAuthDidChangeNotification = @"waSessionAuthDidChangeNotification";

static NSString * const waService = @"com.sokubit.wave";
static NSString * const waAccount = @"arl";
static NSString * const waArlFallback = @"wave.arl";
static NSString * const waRecentKey = @"wave.recentSearches";
static NSString * const waHistoryKey = @"wave.history";
static NSString * const waQualityKey = @"wave.preferredQuality";

static NSString *waStr(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

static NSArray *waArray(NSDictionary *json, NSString *key) {
    if (![json isKindOfClass:[NSDictionary class]]) return @[];
    if (!key) {
        id data = json[@"data"];
        return [data isKindOfClass:[NSArray class]] ? data : @[];
    }
    id value = json[key][@"data"];
    if ([value isKindOfClass:[NSArray class]]) return value;
    value = json[key];
    if ([value isKindOfClass:[NSArray class]]) return value;
    return @[];
}

static NSError *waErr(NSString *message, NSInteger code) {
    return [NSError errorWithDomain:@"wave.deezer" code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"Deezer request failed."}];
}

@interface waSession ()
@property (nonatomic, readwrite) BOOL authenticated;
@property (nonatomic, readwrite) waUser *user;
@property (nonatomic, readwrite) BOOL busy;
@property (nonatomic, readwrite) waQuality maximumQuality;
@property (nonatomic, strong) NSString *userIdentifier;
@property (nonatomic, assign) BOOL losslessProbed;
@property (nonatomic, assign) NSUInteger lyricsGeneration;
@property (nonatomic, assign) dispatch_queue_t lyricsQueue;
@property (nonatomic, strong) NSMutableDictionary *lyricsCache;
- (void)finishHome:(NSMutableArray *)sections radios:(NSArray *)radios completion:(void (^)(NSArray *, NSError *))completion;
- (void)fetchExternalLyrics:(waTrack *)track generation:(NSUInteger)generation completion:(void (^)(waLyrics *, NSError *))completion;
- (NSString *)lyricsQueryEscape:(NSString *)value;
- (id)lyricsJSONAtURL:(NSString *)urlString generation:(NSUInteger)generation;
- (waLyrics *)lyricsFromLRCLIBRecord:(NSDictionary *)record;
- (NSDictionary *)bestLRCLIBRecord:(id)json duration:(NSTimeInterval)duration;
- (void)fetchDiscography:(NSString *)artistID start:(NSUInteger)start acc:(NSMutableArray *)acc seen:(NSMutableSet *)seen completion:(void (^)(NSArray *, NSError *))completion;
- (NSArray *)albumsFromGateway:(id)result;
@end

@implementation waSession

+ (waSession *)shared {
    static waSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ session = [[waSession alloc] init]; });
    return session;
}

- (id)init {
    if ((self = [super init])) {
        _maximumQuality = waQualityMP3320;
        _preferredQuality = (waQuality)[[NSUserDefaults standardUserDefaults] integerForKey:waQualityKey];
        _lyricsQueue = dispatch_queue_create("wave.lyrics", DISPATCH_QUEUE_SERIAL);
        _lyricsCache = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - keychain

- (NSString *)storedARL {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    query[(__bridge id)kSecAttrService] = waService;
    query[(__bridge id)kSecAttrAccount] = waAccount;
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

- (void)storeARL:(NSString *)arl {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    query[(__bridge id)kSecAttrService] = waService;
    query[(__bridge id)kSecAttrAccount] = waAccount;
    SecItemDelete((__bridge CFDictionaryRef)query);
    if (!arl.length) return;
    query[(__bridge id)kSecValueData] = [arl dataUsingEncoding:NSUTF8StringEncoding];
    SecItemAdd((__bridge CFDictionaryRef)query, NULL);
}

#pragma mark - auth

- (void)restoreWithCompletion:(void (^)(BOOL, NSError *))completion {
    NSString *arl = [self storedARL];
    if (!arl.length) arl = [[NSUserDefaults standardUserDefaults] stringForKey:waArlFallback];
    if (!arl.length) arl = [[NSUserDefaults standardUserDefaults] stringForKey:@"wa.deezerARLFallback"];
    if (!arl.length) {
        self.authenticated = NO;
        if (completion) completion(NO, nil);
        return;
    }
    self.busy = YES;
    [self loginWithARL:arl completion:^(waUser *user, NSError *error) {
        self.busy = NO;
        if (completion) completion(user != nil, error);
    }];
}

- (void)loginWithARL:(NSString *)arl completion:(void (^)(waUser *, NSError *))completion {
    NSString *trimmed = [arl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length < 20) {
        if (completion) completion(nil, waErr(@"That ARL is too short.", 400));
        return;
    }
    self.busy = YES;
    waDZAPI *api = [waDZAPI shared];
    api.arl = trimmed;
    [api resetSession];
    [[waLog shared] log:@"auth attempt"];
    [api loadUserData:^(NSDictionary *userDict, NSError *error) {
        self.busy = NO;
        if (error || !userDict) {
            [[waLog shared] log:@"auth failed %@", error.localizedDescription];
            if (completion) completion(nil, error ?: waErr(@"Deezer rejected the ARL.", 401));
            return;
        }
        waUser *user = [[waUser alloc] init];
        [user fillWithData:userDict];
        self.user = user;
        self.userIdentifier = user.identifier ?: waStr(userDict[@"USER_ID"]);
        [self storeARL:trimmed];
        [[NSUserDefaults standardUserDefaults] setObject:trimmed forKey:waArlFallback];
        [[NSUserDefaults standardUserDefaults] synchronize];
        self.authenticated = YES;
        [self recomputeQualityFrom:userDict];
        [[waLog shared] log:@"auth ok user=%@ maxq=%d", user.name, (int)self.maximumQuality];
        [self probeLosslessSupport];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:waSessionAuthDidChangeNotification object:self];
            [[NSNotificationCenter defaultCenter] postNotificationName:waSessionDidChangeNotification object:self];
            if (completion) completion(user, nil);
        });
    }];
}

- (void)logout {
    [self storeARL:nil];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:waArlFallback];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[waDZAPI shared] resetSession];
    [[waDZAPI shared] setArl:nil];
    self.user = nil;
    self.userIdentifier = nil;
    self.authenticated = NO;
    self.maximumQuality = waQualityMP3128;
    [[waPlayer shared] stop];
    [[NSNotificationCenter defaultCenter] postNotificationName:waSessionAuthDidChangeNotification object:self];
    [[NSNotificationCenter defaultCenter] postNotificationName:waSessionDidChangeNotification object:self];
}

- (void)recomputeQualityFrom:(NSDictionary *)userDict {
    waQuality quality = waQualityMP3128;
    NSArray *options = nil;
    id optionsValue = userDict[@"OPTIONS"];
    if ([optionsValue isKindOfClass:[NSArray class]]) options = optionsValue;
    BOOL lossless = [userDict[@"canStreamLossless"] boolValue];
    BOOL hifi = [userDict[@"canStreamHifi"] boolValue];
    for (id option in options) {
        NSString *value = waStr(option);
        if (!value) continue;
        if ([value isEqualToString:@"lossless"]) lossless = YES;
        if ([value isEqualToString:@"hifi"]) hifi = YES;
    }
    if (self.user.canStreamLossless) lossless = YES;
    if (self.user.canStreamHifi) hifi = YES;
    if (hifi) quality = waQualityHIFI;
    else if (lossless) quality = waQualityFLAC;
    else if (self.authenticated) quality = waQualityMP3320;
    self.maximumQuality = quality;
    if ((NSInteger)self.preferredQuality > (NSInteger)quality) self.preferredQuality = quality;
}

- (void)probeLosslessSupport {
    if (self.losslessProbed) return;
    self.losslessProbed = YES;
    [[waDZAPI shared] getPath:@"/chart" params:nil completion:^(NSDictionary *json, NSError *error) {
        NSArray *tracks = waArray(json, @"tracks");
        NSString *trackID = tracks.count ? waStr([tracks objectAtIndex:0][@"id"]) : nil;
        if (!trackID.length) return;
        [[waDZAPI shared] trackTokenForID:trackID completion:^(NSString *token, NSError *tokenError) {
            if (!token.length) return;
            [[waDZAPI shared] signedURLForTrackToken:token formats:@[@"FLAC"] completion:^(NSString *url, NSString *format, NSString *cipher, NSError *losslessError) {
                if (url.length && !losslessError) {
                    [[waLog shared] log:@"lossless available"];
                    [[NSNotificationCenter defaultCenter] postNotificationName:waSessionDidChangeNotification object:self];
                    return;
                }
                        [[waDZAPI shared] signedURLForTrackToken:token formats:@[@"MP3_320"] completion:^(NSString *mp3URL, NSString *mp3Format, NSString *cipher, NSError *mp3Error) {
                    waQuality cap = (mp3URL.length && !mp3Error) ? waQualityMP3320 : waQualityMP3128;
                    self.maximumQuality = cap;
                    if ((NSInteger)self.preferredQuality > (NSInteger)cap) self.preferredQuality = cap;
                    [[waLog shared] log:@"account capped at %@", [self qualityName:cap]];
                    [[NSNotificationCenter defaultCenter] postNotificationName:waSessionDidChangeNotification object:self];
                }];
            }];
        }];
    }];
}

#pragma mark - quality

- (void)setPreferredQuality:(waQuality)preferredQuality {
    if ((NSInteger)preferredQuality > (NSInteger)self.maximumQuality) preferredQuality = self.maximumQuality;
    _preferredQuality = preferredQuality;
    [[NSUserDefaults standardUserDefaults] setInteger:preferredQuality forKey:waQualityKey];
}

- (waQuality)downloadQuality {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    waQuality quality = self.preferredQuality;
    if ([defaults objectForKey:@"wave.downloadQuality"]) quality = (waQuality)[defaults integerForKey:@"wave.downloadQuality"];
    if ((NSInteger)quality > (NSInteger)self.maximumQuality) quality = self.maximumQuality;
    return quality;
}

- (NSString *)qualityName:(waQuality)quality {
    switch (quality) {
        case waQualityHIFI: return @"HiFi FLAC";
        case waQualityFLAC: return @"Lossless FLAC";
        case waQualityMP3320: return @"MP3 320 kbps";
        default: return @"MP3 128 kbps";
    }
}


+ (NSArray *)formatsForQuality:(waQuality)quality {
    switch (quality) {
        case waQualityHIFI:
        case waQualityFLAC:
            return @[@"FLAC", @"MP3_320", @"MP3_128"];
        case waQualityMP3320:
            return @[@"MP3_320", @"MP3_128"];
        default:
            return @[@"MP3_128"];
    }
}

+ (NSString *)extensionForFormat:(NSString *)format {
    return [format isEqualToString:@"FLAC"] ? @"flac" : @"mp3";
}

#pragma mark - helpers

- (void)notifyChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:waSessionDidChangeNotification object:self];
}

- (NSArray *)itemsFrom:(NSArray *)raw kind:(NSString *)kind {
    NSMutableArray *items = [NSMutableArray arrayWithCapacity:raw.count];
    for (id object in raw) {
        if (![object isKindOfClass:[NSDictionary class]]) continue;
        [items addObject:[waItem itemWithDictionary:object kind:kind]];
    }
    return items;
}

#pragma mark - catalog

- (void)homeWithCompletion:(void (^)(NSArray *, NSError *))completion {
    __block NSDictionary *chartJSON = nil;
    __block NSError *chartError = nil;
    __block NSDictionary *editorialJSON = nil;
    __block NSArray *radios = [NSArray array];
    __block NSArray *recoAlbums = [NSArray array];
    __block NSArray *recoArtists = [NSArray array];
    dispatch_group_t group = dispatch_group_create();

    dispatch_group_enter(group);
    [[waDZAPI shared] getPath:@"/chart" params:nil completion:^(NSDictionary *json, NSError *error) {
        chartJSON = json;
        chartError = error;
        dispatch_group_leave(group);
    }];
    dispatch_group_enter(group);
    [[waDZAPI shared] getPath:@"/editorial/0/releases" params:@{@"limit": @"30"} completion:^(NSDictionary *json, NSError *error) {
        if (!error) editorialJSON = json;
        dispatch_group_leave(group);
    }];
    dispatch_group_enter(group);
    [[waDZAPI shared] getPath:@"/radio/top" params:@{@"limit": @"30"} completion:^(NSDictionary *json, NSError *error) {
        NSArray *list = error ? [NSArray array] : [self itemsFrom:waArray(json, nil) kind:waRadioType];
        if (list.count) {
            radios = list;
            dispatch_group_leave(group);
            return;
        }
        [[waDZAPI shared] getPath:@"/radio" params:@{@"limit": @"30"} completion:^(NSDictionary *fallback, NSError *fallbackError) {
            radios = fallbackError ? [NSArray array] : [self itemsFrom:waArray(fallback, nil) kind:waRadioType];
            dispatch_group_leave(group);
        }];
    }];
    if (self.authenticated) {
        dispatch_group_enter(group);
        [self recommendAlbumsWithCompletion:^(NSArray *albums, NSError *error) {
            (void)error;
            recoAlbums = albums ? albums : [NSArray array];
            dispatch_group_leave(group);
        }];
        dispatch_group_enter(group);
        [self recommendArtistsWithCompletion:^(NSArray *artists, NSError *error) {
            (void)error;
            recoArtists = artists ? artists : [NSArray array];
            dispatch_group_leave(group);
        }];
    }

    // The model pass is pure JSON to objects, so it runs off the main thread;
    // only the hand-off touches UIKit.
    dispatch_group_notify(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (chartError && !chartJSON) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, chartError);
            });
#if !OS_OBJECT_USE_OBJC
            dispatch_release(group);
#endif
            return;
        }
        NSMutableArray *sections = [NSMutableArray array];
        NSArray *editorial = [self itemsFrom:waArray(editorialJSON, nil) kind:waAlbumType];
        if (editorial.count) {
            waSection *section = [[waSection alloc] init];
            section.title = @"New Releases";
            section.layout = @"square";
            section.items = editorial;
            section.identifier = @"editorial";
            section.showsMore = YES;
            [sections addObject:section];
        }
        if (recoAlbums.count) {
            waSection *section = [[waSection alloc] init];
            section.title = @"Recommended Albums";
            section.layout = @"square";
            section.items = recoAlbums;
            section.identifier = @"reco.albums";
            [sections addObject:section];
        }
        waChart *chart = [[waChart alloc] init];
        chart.tracks = [self itemsFrom:waArray(chartJSON, @"tracks") kind:waTrackType];
        chart.albums = [self itemsFrom:waArray(chartJSON, @"albums") kind:waAlbumType];
        chart.artists = [self itemsFrom:waArray(chartJSON, @"artists") kind:waArtistType];
        if (chart.tracks.count) {
            waSection *section = [[waSection alloc] init];
            section.title = @"Top Tracks";
            section.layout = @"list";
            section.items = chart.tracks;
            section.identifier = @"chart.tracks";
            section.showsMore = YES;
            [sections addObject:section];
        }
        if (chart.albums.count) {
            waSection *section = [[waSection alloc] init];
            section.title = @"Top Albums";
            section.layout = @"square";
            section.items = chart.albums;
            section.identifier = @"chart.albums";
            section.showsMore = YES;
            [sections addObject:section];
        }
        if (chart.artists.count) {
            waSection *section = [[waSection alloc] init];
            section.title = @"Top Artists";
            section.layout = @"circle";
            section.items = chart.artists;
            section.identifier = @"chart.artists";
            section.showsMore = YES;
            [sections addObject:section];
        }
        if (radios.count) {
            waSection *section = [[waSection alloc] init];
            section.title = @"Radios";
            section.layout = @"square";
            section.items = radios;
            section.identifier = @"radios";
            [sections addObject:section];
        }
        if (recoArtists.count) {
            waSection *section = [[waSection alloc] init];
            section.title = @"Recommended Artists";
            section.layout = @"circle";
            section.items = recoArtists;
            section.identifier = @"reco.artists";
            [sections addObject:section];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(sections, nil);
        });
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    });
}

- (void)search:(NSString *)query kind:(waSearchKind)kind index:(NSUInteger)index completion:(void (^)(NSArray *, NSUInteger, NSError *))completion {
    if (!query.length) { if (completion) completion(@[], 0, nil); return; }
    NSString *path = @"/search";
    NSString *itemKind = waTrackType;
    switch (kind) {
        case waSearchTracks: path = @"/search/track"; itemKind = waTrackType; break;
        case waSearchAlbums: path = @"/search/album"; itemKind = waAlbumType; break;
        case waSearchArtists: path = @"/search/artist"; itemKind = waArtistType; break;
        case waSearchPlaylists: path = @"/search/playlist"; itemKind = waPlaylistType; break;
        default: path = @"/search"; itemKind = waTrackType; break;
    }
    NSDictionary *params = @{@"q": query, @"limit": @"25", @"index": @(index).stringValue};
    [[waDZAPI shared] getPath:path params:params completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, 0, error); return; }
        NSUInteger total = [json[@"total"] respondsToSelector:@selector(unsignedIntegerValue)] ? [json[@"total"] unsignedIntegerValue] : 0;
        NSArray *raw = nil;
        if (kind == waSearchAll) {
            raw = waArray(json, nil);
            if (!raw.count) {
                NSMutableArray *combined = [NSMutableArray array];
                for (NSString *key in @[@"tracks", @"albums", @"artists", @"playlists"]) {
                    NSArray *part = waArray(json, key);
                    for (NSDictionary *object in part) {
                        NSMutableDictionary *copy = [object mutableCopy];
                        copy[@"__kind"] = key;
                        [combined addObject:copy];
                    }
                }
                raw = combined;
            }
        } else {
            raw = waArray(json, nil);
        }
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:raw.count];
        for (NSDictionary *object in raw) {
            NSString *objectKind = waStr(object[@"__kind"]);
            if ([objectKind isEqualToString:@"albums"]) objectKind = waAlbumType;
            else if ([objectKind isEqualToString:@"artists"]) objectKind = waArtistType;
            else if ([objectKind isEqualToString:@"playlists"]) objectKind = waPlaylistType;
            else if ([objectKind isEqualToString:@"tracks"]) objectKind = waTrackType;
            if (!objectKind) objectKind = itemKind;
            [items addObject:[waItem itemWithDictionary:object kind:objectKind]];
        }
        if (completion) completion(items, total, nil);
    }];
}


- (void)chartWithCompletion:(void (^)(waChart *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/chart" params:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        waChart *chart = [[waChart alloc] init];
        chart.tracks = [self itemsFrom:waArray(json, @"tracks") kind:waTrackType];
        chart.albums = [self itemsFrom:waArray(json, @"albums") kind:waAlbumType];
        chart.artists = [self itemsFrom:waArray(json, @"artists") kind:waArtistType];
        chart.playlists = [self itemsFrom:waArray(json, @"playlists") kind:waPlaylistType];
        if (completion) completion(chart, nil);
    }];
}

- (void)editorialWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/editorial/0/releases" params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (completion) completion([self itemsFrom:waArray(json, nil) kind:waAlbumType], nil);
    }];
}

- (void)genresWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/genre" params:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (completion) completion([self itemsFrom:waArray(json, nil) kind:@"genre"], nil);
    }];
}

- (void)artistsForGenre:(NSString *)genreID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/genre/%@/artists", genreID] params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (completion) completion([self itemsFrom:waArray(json, nil) kind:waArtistType], nil);
    }];
}

- (void)album:(NSString *)albumID completion:(void (^)(waAlbum *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/album/%@", albumID] params:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        waAlbum *album = [waItem itemWithDictionary:json kind:waAlbumType];
        if (album.trackCount <= (NSInteger)album.tracks.count) {
            album.tracks = waSortedAlbumTracks(album.tracks);
            if (completion) completion(album, nil);
            return;
        }
        [self albumTracks:albumID completion:^(NSArray *tracks, NSError *tracksError) {
            if (!tracksError) album.tracks = waSortedAlbumTracks(tracks);
            if (completion) completion(album, nil);
        }];
    }];
}

- (void)artist:(NSString *)artistID completion:(void (^)(waArtist *, NSError *))completion {
    __block NSDictionary *artistJSON = nil;
    __block NSError *artistError = nil;
    __block NSDictionary *topJSON = nil;
    __block NSDictionary *albumsJSON = nil;
    __block NSDictionary *relatedJSON = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/artist/%@", artistID] params:nil completion:^(NSDictionary *json, NSError *error) {
        artistJSON = json;
        artistError = error;
        dispatch_group_leave(group);
    }];
    dispatch_group_enter(group);
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/artist/%@/top", artistID] params:@{@"limit": @"30"} completion:^(NSDictionary *json, NSError *error) {
        if (!error) topJSON = json;
        dispatch_group_leave(group);
    }];
    dispatch_group_enter(group);
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/artist/%@/albums", artistID] params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (!error) albumsJSON = json;
        dispatch_group_leave(group);
    }];
    dispatch_group_enter(group);
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/artist/%@/related", artistID] params:nil completion:^(NSDictionary *json, NSError *error) {
        if (!error) relatedJSON = json;
        dispatch_group_leave(group);
    }];
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (artistError || !artistJSON) {
            if (completion) completion(nil, artistError);
#if !OS_OBJECT_USE_OBJC
            dispatch_release(group);
#endif
            return;
        }
        waArtist *artist = [waItem itemWithDictionary:artistJSON kind:waArtistType];
        artist.topTracks = [self itemsFrom:waArray(topJSON, nil) kind:waTrackType];
        artist.albums = [self itemsFrom:waArray(albumsJSON, nil) kind:waAlbumType];
        artist.related = [self itemsFrom:waArray(relatedJSON, nil) kind:waArtistType];
        if (completion) completion(artist, nil);
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    });
}

- (void)artistTop:(NSString *)artistID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/artist/%@/top", artistID] params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (completion) completion([self itemsFrom:waArray(json, nil) kind:waTrackType], nil);
    }];
}

- (void)artistAlbums:(NSString *)artistID completion:(void (^)(NSArray *, NSError *))completion {
    [self fetchDiscography:artistID start:0 acc:[NSMutableArray array] seen:[NSMutableSet set] completion:completion];
}

- (NSArray *)albumsFromGateway:(id)result {
    NSArray *raw = nil;
    if ([result isKindOfClass:[NSDictionary class]]) {
        id data = result[@"data"];
        if ([data isKindOfClass:[NSArray class]]) raw = data;
        else raw = waArray(result, nil);
    } else if ([result isKindOfClass:[NSArray class]]) {
        raw = result;
    }
    return [self itemsFrom:raw kind:waAlbumType];
}

- (void)fetchDiscography:(NSString *)artistID start:(NSUInteger)start acc:(NSMutableArray *)acc seen:(NSMutableSet *)seen completion:(void (^)(NSArray *, NSError *))completion {
    if (!artistID.length) {
        if (completion) completion(acc, nil);
        return;
    }
    NSUInteger pageSize = 100;
    NSDictionary *params = @{
        @"art_id": @([artistID integerValue]),
        @"start": @(start),
        @"nb": @(pageSize),
        @"nb_songs": @0,
        @"filter_role_id": [NSArray arrayWithObject:@0],
        @"discography_mode": @"all"
    };
    [[waDZAPI shared] callMethod:@"album.getDiscography" params:params completion:^(NSDictionary *result, NSError *error) {
        if (error || !result) {
            if (acc.count) {
                if (completion) completion(acc, nil);
                return;
            }
            [self fetchList:[NSString stringWithFormat:@"/artist/%@/albums", artistID] kind:waAlbumType completion:completion];
            return;
        }
        NSArray *page = [self albumsFromGateway:result];
        if (!page.count && start == 0) {
            [self fetchList:[NSString stringWithFormat:@"/artist/%@/albums", artistID] kind:waAlbumType completion:completion];
            return;
        }
        for (waAlbum *album in page) {
            if (![album isKindOfClass:[waAlbum class]] || !album.identifier.length) continue;
            if ([seen containsObject:album.identifier]) continue;
            [seen addObject:album.identifier];
            [acc addObject:album];
        }
        NSUInteger total = 0;
        if ([result isKindOfClass:[NSDictionary class]]) {
            if ([result[@"total"] respondsToSelector:@selector(unsignedIntegerValue)]) total = [result[@"total"] unsignedIntegerValue];
            else if ([result[@"count"] respondsToSelector:@selector(unsignedIntegerValue)]) total = [result[@"count"] unsignedIntegerValue];
        }
        BOOL more = NO;
        if (page.count > 0) {
            more = (page.count >= pageSize);
            if (total > acc.count) more = YES;
        }
        if (more && acc.count < 2500) {
            [self fetchDiscography:artistID start:start + pageSize acc:acc seen:seen completion:completion];
            return;
        }
        if (completion) completion(acc, nil);
    }];
}

- (void)artistRelated:(NSString *)artistID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/artist/%@/related", artistID] params:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (completion) completion([self itemsFrom:waArray(json, nil) kind:waArtistType], nil);
    }];
}

- (void)playlist:(NSString *)playlistID completion:(void (^)(waPlaylist *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/playlist/%@", playlistID] params:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        waPlaylist *playlist = [waItem itemWithDictionary:json kind:waPlaylistType];
        [self playlistTracks:playlistID completion:^(NSArray *tracks, NSError *tracksError) {
            if (!tracksError) playlist.tracks = tracks;
            if (completion) completion(playlist, nil);
        }];
    }];
}

- (void)track:(NSString *)trackID completion:(void (^)(waTrack *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/track/%@", trackID] params:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (completion) completion([waItem itemWithDictionary:json kind:waTrackType], nil);
    }];
}

- (void)hydrateTrack:(waTrack *)track completion:(void (^)(waTrack *))completion {
    if (![track isKindOfClass:[waTrack class]] || !track.identifier.length) {
        if (completion) completion(track);
        return;
    }
    if (!track.needsHydration) {
        if (completion) completion(track);
        return;
    }
    [self track:track.identifier completion:^(waTrack *full, NSError *error) {
        (void)error;
        if (full) [track mergeFrom:full];
        if (completion) completion(track);
    }];
}

- (void)radioListWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/radio" params:@{@"limit": @"100"} completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (completion) completion([self itemsFrom:waArray(json, nil) kind:waRadioType], nil);
    }];
}

- (void)radioTracks:(NSString *)radioID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/radio/%@/tracks", radioID] params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (completion) completion([self itemsFrom:waArray(json, nil) kind:waTrackType], nil);
    }];
}

- (void)flowWithCompletion:(void (^)(NSArray *, NSError *))completion {
    NSDictionary *params = @{@"user_id": self.userIdentifier ?: @""};
    [[waDZAPI shared] callMethod:@"radio.getUserRadio" params:params completion:^(NSDictionary *result, NSError *error) {
        NSArray *raw = nil;
        if (!error) {
            id data = result[@"data"] ?: result[@"DATA"] ?: result[@"results"];
            if ([data isKindOfClass:[NSArray class]]) raw = data;
        }
        if (!raw.count) {
            [[waDZAPI shared] getPath:@"/chart" params:nil completion:^(NSDictionary *json, NSError *chartError) {
                if (chartError) { if (completion) completion(nil, chartError); return; }
                if (completion) completion([self itemsFrom:waArray(json, @"tracks") kind:waTrackType], nil);
            }];
            return;
        }
        if (completion) completion([self itemsFrom:raw kind:waTrackType], nil);
    }];
}



- (void)rememberTrack:(waTrack *)track {
    if (!track.identifier.length) return;
    NSMutableArray *history = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:waHistoryKey] ?: @[]];
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *dict in history) {
        if (![waStr(dict[@"id"]) isEqualToString:track.identifier]) [filtered addObject:dict];
    }
    [filtered insertObject:[track dictionary] atIndex:0];
    while (filtered.count > 50) [filtered removeLastObject];
    [[NSUserDefaults standardUserDefaults] setObject:filtered forKey:waHistoryKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (NSString *)lyricsQueryEscape:(NSString *)value {
    if (!value.length) return @"";
    CFStringRef escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)value, NULL, CFSTR(":/?#[]@!$&'()*+,;="), kCFStringEncodingUTF8);
    NSString *result = escaped ? [(__bridge NSString *)escaped copy] : value;
    if (escaped) CFRelease(escaped);
    return result;
}

- (id)lyricsJSONAtURL:(NSString *)urlString generation:(NSUInteger)generation {
    if (!urlString.length) return nil;
    if (generation != self.lyricsGeneration) return nil;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    NSDictionary *headers = @{@"User-Agent": @"wave/0.3.54 (https://github.com/tsuchinaka/wave)",
                              @"X-User-Agent": @"wave/0.3.54 (https://github.com/tsuchinaka/wave)"};
    NSError *error = nil;
    NSDictionary *response = [waTLS requestURL:url method:@"GET" headers:headers body:nil timeout:6.0 verify:YES error:&error];
    if (!response && error.code == 9) {
        if (generation != self.lyricsGeneration) return nil;
        [[waLog shared] log:@"lyrics tls retry %@", error.localizedDescription];
        error = nil;
        response = [waTLS requestURL:url method:@"GET" headers:headers body:nil timeout:6.0 verify:NO error:&error];
    }
    if (generation != self.lyricsGeneration) return nil;
    if (![response isKindOfClass:[NSDictionary class]]) return nil;
    NSInteger status = [response[@"status"] integerValue];
    NSData *body = [response[@"body"] isKindOfClass:[NSData class]] ? response[@"body"] : nil;
    [[waLog shared] log:@"lyrics http %ld bytes=%lu %@", (long)status, (unsigned long)body.length, url.host];
    if (status == 404 || status < 200 || status >= 300 || !body.length) return nil;
    id json = nil;
    @try { json = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL]; }
    @catch (NSException *exception) {
        [[waLog shared] log:@"lyrics json %@", exception.reason];
        return nil;
    }
    return json;
}

- (waLyrics *)parseLyricsSafely:(waLyrics *(^)(void))block {
    if (!block) return nil;
    waLyrics *parsed = nil;
    @try { parsed = block(); }
    @catch (NSException *exception) {
        [[waLog shared] log:@"lyrics parse %@", exception.reason];
        parsed = nil;
    }
    return parsed;
}

- (waLyrics *)lyricsFromLRCLIBRecord:(NSDictionary *)record {
    if (![record isKindOfClass:[NSDictionary class]]) return nil;
    id flag = record[@"instrumental"];
    BOOL marked = [flag respondsToSelector:@selector(boolValue)] && [flag boolValue];
    NSString *file = [record[@"lyricsfile"] isKindOfClass:[NSString class]] ? record[@"lyricsfile"] : nil;
    NSString *synced = [record[@"syncedLyrics"] isKindOfClass:[NSString class]] ? record[@"syncedLyrics"] : nil;
    NSString *plain = [record[@"plainLyrics"] isKindOfClass:[NSString class]] ? record[@"plainLyrics"] : nil;
    if (file.length && file.length < 400000) {
        waLyrics *parsed = [self parseLyricsSafely:^{ return [waLyrics lyricsFromLyricsfile:file]; }];
        if (parsed.wordTimed && parsed.lines.count) return parsed;
        if (parsed.lines.count || parsed.instrumental) return parsed;
    }
    if (marked || [waLyrics textIsInstrumentalOnly:synced] || [waLyrics textIsInstrumentalOnly:plain]) {
        waLyrics *instrumental = [[waLyrics alloc] init];
        instrumental.source = @"lrclib";
        [instrumental markInstrumental];
        return instrumental;
    }
    if (synced.length) {
        waLyrics *parsed = [self parseLyricsSafely:^{ return [waLyrics lyricsFromLRC:synced]; }];
        if (parsed.lines.count) return parsed;
    }
    if (plain.length) {
        waLyrics *parsed = [self parseLyricsSafely:^{ return [waLyrics lyricsFromLRC:plain]; }];
        if (!parsed.lines.count) {
            parsed = [[waLyrics alloc] init];
            parsed.plain = plain;
            parsed.source = @"lrclib";
        }
        return parsed;
    }
    return nil;
}

- (NSDictionary *)bestLRCLIBRecord:(id)json duration:(NSTimeInterval)duration {
    NSArray *records = nil;
    if ([json isKindOfClass:[NSDictionary class]]) records = [NSArray arrayWithObject:json];
    else if ([json isKindOfClass:[NSArray class]]) records = json;
    NSDictionary *best = nil;
    NSInteger bestScore = NSIntegerMin;
    for (id record in records) {
        if (![record isKindOfClass:[NSDictionary class]]) continue;
        BOOL word = [record[@"hasWordSync"] boolValue];
        BOOL synced = [record[@"hasSyncedLyrics"] boolValue] || ([record[@"syncedLyrics"] isKindOfClass:[NSString class]] && [record[@"syncedLyrics"] length]);
        BOOL plain = [record[@"hasPlainLyrics"] boolValue] || ([record[@"plainLyrics"] isKindOfClass:[NSString class]] && [record[@"plainLyrics"] length]);
        BOOL file = [record[@"lyricsfile"] isKindOfClass:[NSString class]] && [record[@"lyricsfile"] length];
        NSInteger score = word || file ? 100 : (synced ? 40 : (plain ? 10 : 0));
        double recDur = [record[@"duration"] doubleValue];
        if (duration > 1.0 && recDur > 0.0) {
            double delta = fabs(recDur - duration);
            if (delta <= 2.0) score += 80;
            else if (delta <= 5.0) score += 20;
            else score -= 40;
            score -= (NSInteger)delta;
        }
        if (score > bestScore) {
            best = record;
            bestScore = score;
        }
    }
    return best;
}

- (void)fetchExternalLyrics:(waTrack *)track generation:(NSUInteger)generation completion:(void (^)(waLyrics *, NSError *))completion {
    if (!track.title.length && !track.artistName.length) {
        if (completion) completion(nil, waErr(@"Lyrics not available.", 404));
        return;
    }
    NSString *artist = [self lyricsQueryEscape:track.artistName];
    NSString *title = [self lyricsQueryEscape:track.title];
    NSString *album = [self lyricsQueryEscape:track.albumTitle];
    NSInteger duration = (NSInteger)(track.duration + 0.5);
    if (duration < 1 || duration > 3600) duration = 0;
    dispatch_async(self.lyricsQueue, ^{
        waLyrics *parsed = nil;
        @try {
            if (generation != self.lyricsGeneration) return;
            NSMutableString *getURL = [NSMutableString stringWithFormat:@"https://lrclib.net/api/get?artist_name=%@&track_name=%@", artist, title];
            if (album.length) [getURL appendFormat:@"&album_name=%@", album];
            if (duration) [getURL appendFormat:@"&duration=%ld", (long)duration];
            parsed = [self lyricsFromLRCLIBRecord:[self bestLRCLIBRecord:[self lyricsJSONAtURL:getURL generation:generation] duration:track.duration]];
            if (generation != self.lyricsGeneration) return;
            if (!parsed.wordTimed && !parsed.lines.count && !parsed.plain.length && !parsed.instrumental) {
                NSString *search = [NSString stringWithFormat:@"https://lrclib.net/api/v2/search?track_name=%@&artist_name=%@", title, artist];
                NSDictionary *summary = [self bestLRCLIBRecord:[self lyricsJSONAtURL:search generation:generation] duration:track.duration];
                if (generation != self.lyricsGeneration) return;
                NSString *recordID = [summary[@"id"] respondsToSelector:@selector(stringValue)] ? [summary[@"id"] stringValue] : nil;
                if (recordID.length) {
                    NSString *byID = [NSString stringWithFormat:@"https://lrclib.net/api/get/%@", recordID];
                    waLyrics *full = [self lyricsFromLRCLIBRecord:[self lyricsJSONAtURL:byID generation:generation]];
                    if (full.wordTimed || full.lines.count || full.plain.length || full.instrumental) parsed = full;
                }
            }
            if (parsed.wordTimed) {
                NSUInteger words = 0;
                for (waLyricLine *line in parsed.lines) {
                    if ([line isKindOfClass:[waLyricLine class]]) words += line.words.count;
                }
                [[waLog shared] log:@"lyrics word-sync lines=%lu words=%lu", (unsigned long)parsed.lines.count, (unsigned long)words];
            }
        } @catch (NSException *exception) {
            [[waLog shared] log:@"lyrics fetch %@", exception.reason];
            parsed = nil;
        }
        if (generation != self.lyricsGeneration) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.lyricsGeneration) return;
            if (completion) completion(parsed, parsed ? nil : waErr(@"Lyrics not available.", 404));
        });
    });
}

- (waLyrics *)bestLyricsFromDeezer:(waLyrics *)deezer backup:(waLyrics *)backup {
    if (backup.wordTimed && backup.lines.count) return backup;
    if (deezer.wordTimed && deezer.lines.count) return deezer;
    if (deezer.lines.count) return deezer;
    if (backup.lines.count) return backup;
    if (deezer.instrumental) return deezer;
    if (backup.instrumental) return backup;
    if (backup.plain.length) return backup;
    if (deezer.plain.length) return deezer;
    return nil;
}

- (void)lyricsForTrack:(waTrack *)track completion:(void (^)(waLyrics *, NSError *))completion {
    if (!track || (!track.title.length && !track.identifier.length && !track.artistName.length)) {
        if (completion) completion(nil, waErr(@"No track.", 400));
        return;
    }
    NSString *cacheKey = track.identifier.length ? track.identifier : [NSString stringWithFormat:@"%@|%@", track.artistName ?: @"", track.title ?: @""];
    waLyrics *memory = cacheKey.length ? self.lyricsCache[cacheKey] : nil;
    waLyrics *local = memory ?: [[waDownloader shared] localLyricsForTrackID:track.identifier];
    BOOL cached = local.lines.count || local.plain.length || local.instrumental;
    if (cached && completion) completion(local, nil);
    if (cached && local.wordTimed) return;
    NSUInteger generation = ++self.lyricsGeneration;
    NSMutableDictionary *gate = [NSMutableDictionary dictionary];
    gate[@"done"] = @NO;
    void (^finish)(waLyrics *) = ^(waLyrics *lyrics) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.lyricsGeneration) return;
            if ([gate[@"done"] boolValue]) return;
            gate[@"done"] = @YES;
            waLyrics *best = lyrics;
            if (best && cacheKey.length) {
                self.lyricsCache[cacheKey] = best;
                while (self.lyricsCache.count > 24) {
                    NSString *first = self.lyricsCache.allKeys[0];
                    if (first) [self.lyricsCache removeObjectForKey:first];
                    else break;
                }
            }
            if (best && track.identifier.length && [[waDownloader shared] isDownloadedTrackID:track.identifier]) {
                [[waDownloader shared] storeLyrics:best forTrackID:track.identifier];
            }
            if (completion) completion(best, best ? nil : waErr(@"Lyrics not available.", 404));
        });
    };
    void (^consider)(void) = ^{
        if (generation != self.lyricsGeneration) return;
        if ([gate[@"done"] boolValue]) return;
        waLyrics *best = [self bestLyricsFromDeezer:gate[@"deezer"] backup:gate[@"lrclib"]];
        BOOL word = best.wordTimed && best.lines.count;
        BOOL both = [gate[@"deezerDone"] boolValue] && [gate[@"lrclibDone"] boolValue];
        if (word || both) finish(best);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.lyricsGeneration) return;
        if ([gate[@"done"] boolValue]) return;
        [[waLog shared] log:@"lyrics timeout"];
        finish([self bestLyricsFromDeezer:gate[@"deezer"] backup:gate[@"lrclib"]]);
    });
    [self fetchExternalLyrics:track generation:generation completion:^(waLyrics *lyrics, NSError *error) {
        (void)error;
        if (generation != self.lyricsGeneration) return;
        if (lyrics) gate[@"lrclib"] = lyrics;
        gate[@"lrclibDone"] = @YES;
        consider();
    }];
    if (track.identifier.length) {
        [[waDZAPI shared] callMethod:@"song.getLyrics" params:@{@"sng_id": track.identifier} completion:^(NSDictionary *result, NSError *error) {
            if (generation != self.lyricsGeneration) return;
            dispatch_async(self.lyricsQueue, ^{
                waLyrics *parsed = nil;
                if (!error) parsed = [self parseLyricsSafely:^{ return [waLyrics lyricsFromDeezer:result]; }];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self.lyricsGeneration) return;
                    if (parsed) gate[@"deezer"] = parsed;
                    gate[@"deezerDone"] = @YES;
                    consider();
                });
            });
        }];
    } else {
        gate[@"deezerDone"] = @YES;
        consider();
    }
}

#pragma mark - library

- (void)setLiked:(BOOL)liked track:(waTrack *)track completion:(void (^)(BOOL, NSError *))completion {
    NSString *method = liked ? @"favorite_song.add" : @"favorite_song.remove";
    [[waDZAPI shared] callMethod:method params:@{@"SNG_ID": track.identifier ?: @""} completion:^(NSDictionary *result, NSError *error) {
        if (!error) track.liked = liked;
        if (completion) completion(!error, error);
    }];
}

- (void)setLiked:(BOOL)liked album:(waAlbum *)album completion:(void (^)(BOOL, NSError *))completion {
    NSString *method = liked ? @"album.addFavorite" : @"album.deleteFavorite";
    [[waDZAPI shared] callMethod:method params:@{@"ALB_ID": album.identifier ?: @""} completion:^(NSDictionary *result, NSError *error) {
        if (!error) album.liked = liked;
        if (completion) completion(!error, error);
    }];
}

- (void)setLiked:(BOOL)liked artist:(waArtist *)artist completion:(void (^)(BOOL, NSError *))completion {
    NSString *method = liked ? @"artist.addFavorite" : @"artist.deleteFavorite";
    [[waDZAPI shared] callMethod:method params:@{@"ART_ID": artist.identifier ?: @""} completion:^(NSDictionary *result, NSError *error) {
        if (!error) artist.liked = liked;
        if (completion) completion(!error, error);
    }];
}

- (void)setLiked:(BOOL)liked playlist:(waPlaylist *)playlist completion:(void (^)(BOOL, NSError *))completion {
    NSString *method = liked ? @"playlist.addFavorite" : @"playlist.deleteFavorite";
    [[waDZAPI shared] callMethod:method params:@{@"playlist_id": playlist.identifier ?: @""} completion:^(NSDictionary *result, NSError *error) {
        if (completion) completion(!error, error);
    }];
}

- (void)lovedTracksWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] callMethod:@"user.getAllFeedbacks" params:@{@"checksums": [NSNull null]} completion:^(NSDictionary *result, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        id favorites = result[@"FAVORITES"] ?: result[@"favorites"] ?: result;
        id songs = [favorites isKindOfClass:[NSDictionary class]] ? (favorites[@"SONGS"] ?: favorites[@"songs"]) : favorites;
        NSArray *entries = nil;
        if ([songs isKindOfClass:[NSDictionary class]]) entries = songs[@"data"];
        else if ([songs isKindOfClass:[NSArray class]]) entries = songs;
        if (![entries isKindOfClass:[NSArray class]]) { if (completion) completion(@[], nil); return; }

        NSMutableArray *identifiers = [NSMutableArray array];
        for (id object in entries) {
            NSString *identifier = nil;
            if ([object isKindOfClass:[NSDictionary class]]) identifier = waStr(object[@"SNG_ID"]) ?: waStr(object[@"id"]);
            else identifier = waStr(object);
            if (identifier.length) [identifiers addObject:identifier];
        }
        if (!identifiers.count) { if (completion) completion(@[], nil); return; }

        [[waDZAPI shared] callMethod:@"song.getListData" params:@{@"SNG_IDS": identifiers} completion:^(NSDictionary *listResult, NSError *listError) {
            if (listError) { if (completion) completion(nil, listError); return; }
            id raw = listResult[@"data"] ?: listResult[@"DATA"] ?: listResult;
            NSMutableArray *objects = [NSMutableArray array];
            if ([raw isKindOfClass:[NSArray class]]) {
                for (id object in raw) if ([object isKindOfClass:[NSDictionary class]] && object[@"SNG_ID"]) [objects addObject:object];
            } else if ([raw isKindOfClass:[NSDictionary class]]) {
                for (id value in [raw allValues]) if ([value isKindOfClass:[NSDictionary class]] && value[@"SNG_ID"]) [objects addObject:value];
            }
            NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:objects.count];
            for (NSDictionary *object in objects) {
                NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
                normalized[@"id"] = waStr(object[@"SNG_ID"]) ?: @"";
                normalized[@"title"] = waStr(object[@"SNG_TITLE"]) ?: waStr(object[@"TITLE"]) ?: @"";
                normalized[@"duration"] = object[@"DURATION"] ?: @0;
                normalized[@"isrc"] = waStr(object[@"ISRC"]) ?: @"";
                normalized[@"explicit_lyrics"] = @([object[@"EXPLICIT_LYRICS"] integerValue] != 0);
                NSMutableDictionary *album = [NSMutableDictionary dictionary];
                if (waStr(object[@"ALB_ID"])) album[@"id"] = waStr(object[@"ALB_ID"]);
                if (waStr(object[@"ALB_TITLE"])) album[@"title"] = waStr(object[@"ALB_TITLE"]);
                NSString *cover = [self cdnURLForHash:waStr(object[@"ALB_PICTURE"]) kind:@"cover"];
                if (cover) album[@"cover"] = cover;
                if (album.count) normalized[@"album"] = album;
                NSDictionary *firstArtist = nil;
                if ([object[@"ARTISTS"] isKindOfClass:[NSArray class]] && [object[@"ARTISTS"] count]) firstArtist = [object[@"ARTISTS"] objectAtIndex:0];
                NSMutableDictionary *artist = [NSMutableDictionary dictionary];
                NSString *artistName = waStr(object[@"ART_NAME"]) ?: waStr(firstArtist[@"ART_NAME"]);
                NSString *artistID = waStr(object[@"ART_ID"]) ?: waStr(firstArtist[@"ART_ID"]);
                if (artistName) artist[@"name"] = artistName;
                if (artistID) artist[@"id"] = artistID;
                if (artist.count) normalized[@"artist"] = artist;
                [tracks addObject:[waTrack itemWithDictionary:normalized kind:waTrackType]];
            }
            if (completion) completion(tracks, nil);
        }];
    }];
}

- (void)lovedAlbumsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [self favoritesForTab:@"albums" completion:completion];
}

- (void)lovedArtistsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [self favoritesForTab:@"artists" completion:completion];
}

- (NSString *)cdnURLForHash:(NSString *)hash kind:(NSString *)kind {
    if (!hash.length) return nil;
    return [NSString stringWithFormat:@"http://cdn-images.dzcdn.net/images/%@/%@/500x500-000000-80-0-0.jpg", kind, hash];
}

- (void)favoritesForTab:(NSString *)tab completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] callMethod:@"deezer.pageProfile" params:@{@"nb": @500, @"tab": tab, @"user_id": self.userIdentifier ?: @""} completion:^(NSDictionary *result, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSDictionary *tabs = [result[@"TAB"] isKindOfClass:[NSDictionary class]] ? result[@"TAB"] : result;
        NSDictionary *section = [tabs[tab] isKindOfClass:[NSDictionary class]] ? tabs[tab] : nil;
        NSArray *data = [section[@"data"] isKindOfClass:[NSArray class]] ? section[@"data"] : @[];
        NSMutableArray *items = [NSMutableArray array];
        for (NSDictionary *object in data) {
            if (![object isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
            if ([tab isEqualToString:@"albums"]) {
                normalized[@"id"] = waStr(object[@"ALB_ID"]) ?: @"";
                normalized[@"title"] = waStr(object[@"ALB_TITLE"]) ?: @"";
                normalized[@"cover"] = [self cdnURLForHash:waStr(object[@"ALB_PICTURE"]) kind:@"cover"];
                NSMutableDictionary *artist = [NSMutableDictionary dictionary];
                if (waStr(object[@"ART_NAME"])) artist[@"name"] = waStr(object[@"ART_NAME"]);
                if (waStr(object[@"ART_ID"])) artist[@"id"] = waStr(object[@"ART_ID"]);
                normalized[@"artist"] = artist;
                normalized[@"release_date"] = waStr(object[@"PHYSICAL_RELEASE_DATE"]);
                [items addObject:[waItem itemWithDictionary:normalized kind:waAlbumType]];
            } else if ([tab isEqualToString:@"artists"]) {
                normalized[@"id"] = waStr(object[@"ART_ID"]) ?: @"";
                normalized[@"name"] = waStr(object[@"ART_NAME"]) ?: @"";
                normalized[@"picture"] = [self cdnURLForHash:waStr(object[@"ART_PICTURE"]) kind:@"artist"];
                normalized[@"nb_fan"] = object[@"NB_FAN"] ?: @0;
                [items addObject:[waItem itemWithDictionary:normalized kind:waArtistType]];
            }
        }
        if (completion) completion(items, nil);
    }];
}

- (void)userPlaylistsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] callMethod:@"deezer.pageProfile" params:@{@"nb": @500, @"tab": @"playlists", @"user_id": self.userIdentifier ?: @""} completion:^(NSDictionary *result, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSDictionary *tabs = [result[@"TAB"] isKindOfClass:[NSDictionary class]] ? result[@"TAB"] : result;
        NSDictionary *section = [tabs[@"playlists"] isKindOfClass:[NSDictionary class]] ? tabs[@"playlists"] : nil;
        NSArray *data = [section[@"data"] isKindOfClass:[NSArray class]] ? section[@"data"] : @[];
        NSMutableArray *playlists = [NSMutableArray array];
        for (NSDictionary *object in data) {
            if (![object isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
            normalized[@"id"] = waStr(object[@"PLAYLIST_ID"]) ?: @"";
            normalized[@"title"] = waStr(object[@"TITLE"]) ?: @"";
            normalized[@"nb_tracks"] = object[@"NB_SONG"] ?: @0;
            normalized[@"picture"] = [self cdnURLForHash:waStr(object[@"PLAYLIST_PICTURE"]) kind:@"playlist"];
            NSMutableDictionary *creator = [NSMutableDictionary dictionary];
            if (waStr(object[@"PARENT_USERNAME"])) creator[@"name"] = waStr(object[@"PARENT_USERNAME"]);
            if (waStr(object[@"PARENT_USER_ID"])) creator[@"id"] = waStr(object[@"PARENT_USER_ID"]);
            normalized[@"creator"] = creator;
            NSString *parentID = waStr(object[@"PARENT_USER_ID"]);
            BOOL mine = parentID.length && self.userIdentifier.length && [parentID isEqualToString:self.userIdentifier];
            if (!mine && self.user.identifier.length && parentID.length) mine = [parentID isEqualToString:self.user.identifier];
            normalized[@"owned"] = @(mine);
            waPlaylist *playlist = (waPlaylist *)[waItem itemWithDictionary:normalized kind:waPlaylistType];
            playlist.owned = mine;
            [playlists addObject:playlist];
        }
        if (completion) completion(playlists, nil);
    }];
}

- (void)createPlaylistNamed:(NSString *)name completion:(void (^)(waPlaylist *, NSError *))completion {
    [[waDZAPI shared] callMethod:@"playlist.create" params:@{@"title": name ?: @"New Playlist"} completion:^(NSDictionary *result, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        NSString *identifier = waStr(result[@"PLAYLIST_ID"]) ?: waStr(result[@"id"]);
        waPlaylist *playlist = [[waPlaylist alloc] init];
        playlist.identifier = identifier;
        playlist.title = name;
        playlist.owned = YES;
        playlist.creatorIdentifier = self.user.identifier;
        playlist.creatorName = self.user.name;
        if (completion) completion(playlist, nil);
    }];
}

- (void)deletePlaylist:(waPlaylist *)playlist completion:(void (^)(BOOL, NSError *))completion {
    [[waDZAPI shared] callMethod:@"playlist.delete" params:@{@"playlist_id": playlist.identifier ?: @""} completion:^(NSDictionary *result, NSError *error) {
        if (completion) completion(!error, error);
    }];
}


- (void)addTrack:(waTrack *)track toPlaylist:(waPlaylist *)playlist completion:(void (^)(BOOL, NSError *))completion {
    NSDictionary *params = @{@"playlist_id": playlist.identifier ?: @"",
                             @"songs": @[@[track.identifier ?: @"", @0]],
                             @"offset": @-1};
    [[waDZAPI shared] callMethod:@"playlist.addSongs" params:params completion:^(NSDictionary *result, NSError *error) {
        if (completion) completion(!error, error);
    }];
}

- (void)removeTrack:(waTrack *)track fromPlaylist:(waPlaylist *)playlist completion:(void (^)(BOOL, NSError *))completion {
    NSDictionary *params = @{@"playlist_id": playlist.identifier ?: @"",
                             @"songs": @[@[track.identifier ?: @"", @0]],
                             @"offset": @-1};
    [[waDZAPI shared] callMethod:@"playlist.deleteSongs" params:params completion:^(NSDictionary *result, NSError *error) {
        if (completion) completion(!error, error);
    }];
}

- (void)historyLogTrack:(waTrack *)track completion:(void (^)(NSError *))completion {
    [self rememberTrack:track];
    [[waDZAPI shared] logListenForTrackID:track.identifier completion:completion];
}

#pragma mark - streaming

- (void)streamURLForTrack:(waTrack *)track completion:(void (^)(NSURL *, waQuality, NSError *))completion {
    [self streamURLForTrack:track attempt:0 completion:completion];
}

// Auth runs at launch. Pressing play before it lands used to fail with
// "Connect your Deezer account first."; hold the request instead of losing it.
- (void)streamURLForTrack:(waTrack *)track attempt:(NSInteger)attempt completion:(void (^)(NSURL *, waQuality, NSError *))completion {
    if (!track.identifier.length) { if (completion) completion(nil, 0, waErr(@"No track.", 400)); return; }

    NSString *local = [[waDownloader shared] localPathForTrackID:track.identifier];
    if (local.length) {
        if (completion) completion([NSURL fileURLWithPath:local], self.preferredQuality, nil);
        return;
    }

    // A track that played to the end is already decrypted on disk. Start there:
    // no license, no token, no CDN, and the first note lands immediately.
    NSString *cachedStream = [waStreamCache completePathForTrackID:track.identifier];
    if (cachedStream.length) {
        waQuality cachedQuality = [[cachedStream pathExtension].lowercaseString isEqualToString:@"flac"]
            ? self.maximumQuality : self.preferredQuality;
        if ((NSInteger)cachedQuality > (NSInteger)self.maximumQuality) cachedQuality = self.maximumQuality;
        [[waLog shared] log:@"resume cache %@", track.identifier];
        if (completion) completion([NSURL fileURLWithPath:cachedStream], cachedQuality, nil);
        return;
    }

    if (!self.authenticated && self.busy && attempt < 20) {
        __weak waSession *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf streamURLForTrack:track attempt:attempt + 1 completion:completion];
        });
        return;
    }
    // Always resolve through the authenticated gateway. A token that arrived
    // with a public catalog object only unlocks the 30-second preview.
    [[waDZAPI shared] resolveStreamForTrackID:track.identifier completion:^(NSString *token, NSString *streamID, NSError *error) {
        if (error || !token.length) {
            if (completion) completion(nil, 0, error ?: waErr(@"Track is not streamable.", 403));
            return;
        }
        track.trackToken = token;
        NSString *keyID = streamID.length ? streamID : track.identifier;
        waQuality quality = self.preferredQuality;
        NSArray *formats = [waSession formatsForQuality:quality];
        [[waDZAPI shared] signedURLForTrackToken:token formats:formats completion:^(NSString *url, NSString *format, NSString *cipher, NSError *urlError) {
            if (urlError || !url.length) {
                if (completion) completion(nil, 0, urlError ?: waErr(@"Deezer did not return a full stream.", 403));
                return;
            }
            waQuality granted = waQualityMP3128;
            if ([format isEqualToString:@"FLAC"]) granted = self.maximumQuality;
            else if ([format isEqualToString:@"MP3_320"]) granted = waQualityMP3320;
            if ((NSInteger)granted > (NSInteger)self.maximumQuality) granted = self.maximumQuality;
            NSString *extension = [waSession extensionForFormat:format];
            // The CDN serves the same signed object over plain HTTP and iOS 5.1
            // cannot negotiate modern TLS with the HTTPS edge.
            if ([url hasPrefix:@"https://"]) url = [@"http://" stringByAppendingString:[url substringFromIndex:8]];
            NSString *escaped = (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)url, NULL, CFSTR(":/?#[]@!$&'()*+,;="), kCFStringEncodingUTF8);
            NSString *schemeURL = [NSString stringWithFormat:@"deezer://stream/%@.%@?u=%@&c=%@",
                                   keyID, extension, escaped ?: @"", cipher.length ? cipher : @"BF_CBC_STRIPE"];
            NSURL *streamURL = [NSURL URLWithString:schemeURL];
            if (!streamURL) {
                if (completion) completion(nil, 0, waErr(@"Could not build the stream URL.", 500));
                return;
            }
            [[waLog shared] log:@"stream full %@ as %@ %@ %@", track.identifier, keyID, format ?: @"MP3_128", cipher ?: @"BF_CBC_STRIPE"];
            if (completion) completion(streamURL, granted, nil);
        }];
    }];
}

#pragma mark - playback facade

- (void)playTracks:(NSArray *)tracks startAt:(NSUInteger)index context:(NSString *)context {
    [[waPlayer shared] playTracks:tracks startAt:index context:context];
}

- (void)playTrack:(waTrack *)track {
    [[waPlayer shared] playTracks:@[track] startAt:0 context:track.albumTitle];
}

- (void)playRadio:(waRadio *)radio completion:(void (^)(NSError *))completion {
    [self radioTracks:radio.identifier completion:^(NSArray *tracks, NSError *error) {
        if (error || !tracks.count) {
            if (completion) completion(error ?: waErr(@"Radio has no tracks.", 404));
            return;
        }
        [[waPlayer shared] playTracks:tracks startAt:0 context:radio.title];
        if (completion) completion(nil);
    }];
}

- (void)playFlowWithCompletion:(void (^)(NSError *))completion {
    [self flowWithCompletion:^(NSArray *tracks, NSError *error) {
        if (!error && tracks.count) [[waPlayer shared] playTracks:tracks startAt:0 context:@"Flow"];
        if (completion) completion(error);
    }];
}

- (void)finishHome:(NSMutableArray *)sections radios:(NSArray *)radios completion:(void (^)(NSArray *, NSError *))completion {
    if (radios.count) {
        waSection *section = [[waSection alloc] init];
        section.title = @"Radios";
        section.layout = @"square";
        section.items = radios;
        section.identifier = @"radios";
        [sections addObject:section];
    }
    if (!self.authenticated) {
        if (completion) completion(sections, nil);
        return;
    }
    [self recommendAlbumsWithCompletion:^(NSArray *albums, NSError *albumsError) {
        (void)albumsError;
        if (albums.count) {
            waSection *section = [[waSection alloc] init];
            section.title = @"Recommended Albums";
            section.layout = @"square";
            section.items = albums;
            section.identifier = @"reco.albums";
            [sections insertObject:section atIndex:MIN(1, sections.count)];
        }
        [self recommendArtistsWithCompletion:^(NSArray *artists, NSError *artistsError) {
            (void)artistsError;
            if (artists.count) {
                waSection *section = [[waSection alloc] init];
                section.title = @"Recommended Artists";
                section.layout = @"circle";
                section.items = artists;
                section.identifier = @"reco.artists";
                [sections addObject:section];
            }
            if (completion) completion(sections, nil);
        }];
    }];
}

#pragma mark - full catalog

- (void)fetchList:(NSString *)path kind:(NSString *)kind completion:(void (^)(NSArray *, NSError *))completion {
    [self fetchList:path kind:kind index:0 acc:[NSMutableArray array] completion:completion];
}

- (void)fetchList:(NSString *)path kind:(NSString *)kind index:(NSUInteger)index acc:(NSMutableArray *)acc completion:(void (^)(NSArray *, NSError *))completion {
    NSDictionary *params = @{@"index": [NSString stringWithFormat:@"%lu", (unsigned long)index], @"limit": @"100"};
    [[waDZAPI shared] getPath:path params:params completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(acc, error); return; }
        NSArray *page = [self itemsFrom:waArray(json, nil) kind:kind];
        if (page.count) [acc addObjectsFromArray:page];
        NSUInteger total = [json[@"total"] respondsToSelector:@selector(unsignedIntegerValue)] ? [json[@"total"] unsignedIntegerValue] : acc.count;
        if (page.count == 100 && acc.count < total && acc.count < 2000) {
            [self fetchList:path kind:kind index:index + 100 acc:acc completion:completion];
            return;
        }
        if (completion) completion(acc, nil);
    }];
}

- (NSArray *)commentsFrom:(NSDictionary *)json {
    NSMutableArray *comments = [NSMutableArray array];
    for (NSDictionary *raw in waArray(json, nil)) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        waComment *comment = [[waComment alloc] init];
        comment.identifier = waStr(raw[@"id"]);
        comment.text = waStr(raw[@"text"]);
        comment.authorName = waStr(raw[@"author"][@"name"]);
        comment.authorIdentifier = waStr(raw[@"author"][@"id"]);
        comment.date = [raw[@"date"] respondsToSelector:@selector(doubleValue)] ? [raw[@"date"] doubleValue] : 0;
        [comments addObject:comment];
    }
    return comments;
}



- (void)artistPlaylists:(NSString *)artistID completion:(void (^)(NSArray *, NSError *))completion {
    [self fetchList:[NSString stringWithFormat:@"/artist/%@/playlists", artistID] kind:waPlaylistType completion:completion];
}

- (void)artistRadio:(NSString *)artistID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/artist/%@/radio", artistID] params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waTrackType], error);
    }];
}

- (void)geniusForTrack:(waTrack *)track completion:(void (^)(NSArray *, NSError *))completion {
    if (!track.identifier.length) {
        if (completion) completion(nil, waErr(@"No track.", 400));
        return;
    }
    if (!track.artistIdentifier.length) {
        [self track:track.identifier completion:^(waTrack *full, NSError *error) {
            if (full) [track mergeFrom:full];
            if (!track.artistIdentifier.length) {
                if (completion) completion(nil, error ?: waErr(@"No artist.", 404));
                return;
            }
            [self geniusForTrack:track completion:completion];
        }];
        return;
    }
    NSString *artistID = track.artistIdentifier;
    NSString *seedID = track.identifier;
    [self artistRadio:artistID completion:^(NSArray *radio, NSError *error) {
        NSMutableArray *batch = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet setWithObject:seedID];
        for (waTrack *item in radio) {
            if (![item isKindOfClass:[waTrack class]] || !item.identifier.length) continue;
            if ([seen containsObject:item.identifier]) continue;
            item.genius = YES;
            [seen addObject:item.identifier];
            [batch addObject:item];
            if (batch.count >= 12) break;
        }
        if (batch.count >= 8) {
            if (completion) completion(batch, nil);
            return;
        }
        [self artistRelated:artistID completion:^(NSArray *artists, NSError *relatedError) {
            (void)relatedError;
            NSMutableArray *ids = [NSMutableArray array];
            for (id obj in artists) {
                if (![obj isKindOfClass:[waArtist class]]) continue;
                NSString *relatedID = [(waArtist *)obj identifier];
                if (!relatedID.length || [relatedID isEqualToString:artistID]) continue;
                [ids addObject:relatedID];
                if (ids.count >= 4) break;
            }
            if (!ids.count) {
                if (completion) completion(batch.count ? batch : nil, batch.count ? nil : error);
                return;
            }
            __block NSUInteger left = ids.count;
            NSMutableArray *tops = [NSMutableArray arrayWithCapacity:ids.count];
            for (NSUInteger i = 0; i < ids.count; i++) [tops addObject:[NSArray array]];
            for (NSUInteger i = 0; i < ids.count; i++) {
                [[waSession shared] artistTop:[ids objectAtIndex:i] completion:^(NSArray *top, NSError *topError) {
                    (void)topError;
                    if (top) [tops replaceObjectAtIndex:i withObject:top];
                    if (--left > 0) return;
                    NSUInteger row = 0;
                    BOOL grew = YES;
                    while (grew && batch.count < 15) {
                        grew = NO;
                        for (NSArray *list in tops) {
                            if (row >= list.count) continue;
                            waTrack *item = [list objectAtIndex:row];
                            if (![item isKindOfClass:[waTrack class]] || !item.identifier.length) continue;
                            if ([seen containsObject:item.identifier]) continue;
                            item.genius = YES;
                            [seen addObject:item.identifier];
                            [batch addObject:item];
                            grew = YES;
                            if (batch.count >= 15) break;
                        }
                        row++;
                    }
                    if (completion) completion(batch.count ? batch : nil, batch.count ? nil : error);
                }];
            }
        }];
    }];
}














- (void)radioTopWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/radio/top" params:@{@"limit": @"100"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waRadioType], error);
    }];
}





- (void)user:(NSString *)userID completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *ident = userID.length ? userID : @"me";
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/user/%@", ident] params:nil completion:completion];
}










- (void)recommendAlbumsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/user/me/recommendations/albums" params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waAlbumType], error);
    }];
}

- (void)recommendArtistsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/user/me/recommendations/artists" params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waArtistType], error);
    }];
}




- (void)albumTracks:(NSString *)albumID completion:(void (^)(NSArray *, NSError *))completion {
    [self fetchList:[NSString stringWithFormat:@"/album/%@/tracks", albumID] kind:waTrackType completion:^(NSArray *tracks, NSError *error) {
        if (completion) completion(error ? tracks : waSortedAlbumTracks(tracks), error);
    }];
}

- (void)playlistTracks:(NSString *)playlistID completion:(void (^)(NSArray *, NSError *))completion {
    [self fetchList:[NSString stringWithFormat:@"/playlist/%@/tracks", playlistID] kind:waTrackType completion:completion];
}

- (void)searchAll:(NSString *)query completion:(void (^)(NSArray *, NSArray *, NSArray *, NSArray *, NSError *))completion {
    NSString *q = query ?: @"";
    __block NSDictionary *tracksJSON = nil;
    __block NSDictionary *albumsJSON = nil;
    __block NSDictionary *artistsJSON = nil;
    __block NSDictionary *playlistsJSON = nil;
    __block NSError *firstError = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    [[waDZAPI shared] getPath:@"/search/track" params:@{@"q": q, @"limit": @"8"} completion:^(NSDictionary *json, NSError *error) {
        if (error && !firstError) firstError = error;
        else tracksJSON = json;
        dispatch_group_leave(group);
    }];
    dispatch_group_enter(group);
    [[waDZAPI shared] getPath:@"/search/album" params:@{@"q": q, @"limit": @"15"} completion:^(NSDictionary *json, NSError *error) {
        if (!error) albumsJSON = json;
        dispatch_group_leave(group);
    }];
    dispatch_group_enter(group);
    [[waDZAPI shared] getPath:@"/search/artist" params:@{@"q": q, @"limit": @"15"} completion:^(NSDictionary *json, NSError *error) {
        if (!error) artistsJSON = json;
        dispatch_group_leave(group);
    }];
    dispatch_group_enter(group);
    [[waDZAPI shared] getPath:@"/search/playlist" params:@{@"q": q, @"limit": @"15"} completion:^(NSDictionary *json, NSError *error) {
        if (!error) playlistsJSON = json;
        dispatch_group_leave(group);
    }];
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSArray *tracks = [self itemsFrom:waArray(tracksJSON, nil) kind:waTrackType];
        NSArray *albums = [self itemsFrom:waArray(albumsJSON, nil) kind:waAlbumType];
        NSArray *artists = [self itemsFrom:waArray(artistsJSON, nil) kind:waArtistType];
        NSArray *playlists = [self itemsFrom:waArray(playlistsJSON, nil) kind:waPlaylistType];
        if (firstError && !tracks.count && !albums.count && !artists.count && !playlists.count) {
            if (completion) completion(nil, nil, nil, nil, firstError);
        } else if (completion) {
            completion(tracks, albums, artists, playlists, nil);
        }
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    });
}

- (void)searchSuggest:(NSString *)query completion:(void (^)(NSArray *, NSArray *, NSArray *, NSArray *, NSError *))completion {
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) {
        if (completion) completion([NSArray array], [NSArray array], [NSArray array], [NSArray array], nil);
        return;
    }
    [[waDZAPI shared] getPath:@"/search/autocomplete" params:@{@"q": q, @"limit": @"5"} completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            if (completion) completion(nil, nil, nil, nil, error);
            return;
        }
        if (completion) {
            completion([self itemsFrom:waArray(json, @"artists") kind:waArtistType],
                       [self itemsFrom:waArray(json, @"tracks") kind:waTrackType],
                       [self itemsFrom:waArray(json, @"albums") kind:waAlbumType],
                       [self itemsFrom:waArray(json, @"playlists") kind:waPlaylistType],
                       nil);
        }
    }];
}

- (void)commentsForPath:(NSString *)path completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:path params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self commentsFrom:json], error);
    }];
}

#pragma mark - artwork

- (void)loadArtwork:(NSString *)url size:(CGSize)size completion:(void (^)(UIImage *))completion {
    [[waImageCache shared] loadImageAtURL:url size:size owner:nil completion:completion];
}

- (void)loadArtwork:(NSString *)url size:(CGSize)size owner:(id)owner completion:(void (^)(UIImage *))completion {
    [[waImageCache shared] loadImageAtURL:url size:size owner:owner completion:completion];
}

- (void)cancelArtworkForOwner:(id)owner {
    [[waImageCache shared] cancelRequestsForOwner:owner];
}

- (id)artworkTicket {
    return [[waImageCache shared] artworkTicket];
}

- (void)cancelArtworkTicket:(id)ticket {
    [[waImageCache shared] cancelTicket:ticket];
}

- (void)loadArtwork:(NSString *)url size:(CGSize)size ticket:(id)ticket completion:(void (^)(UIImage *))completion {
    [[waImageCache shared] loadImageAtURL:url size:size ticket:ticket completion:completion];
}

- (UIImage *)cachedArtwork:(NSString *)url size:(CGSize)size {
    return [[waImageCache shared] cachedImageForURL:url size:size];
}

- (NSString *)localArtworkPathForTrack:(waTrack *)track {
    return [[waDownloader shared] localArtworkPathForTrack:track];
}

@end
