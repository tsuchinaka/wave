#import "waSession.h"
#import "waDZAPI.h"
#import "waPlayer.h"
#import "waLog.h"
#import "waImageCache.h"
#import "waDownloader.h"
#import "waTLS.h"
#import "waLyrics.h"
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
- (void)finishHome:(NSMutableArray *)sections radios:(NSArray *)radios completion:(void (^)(NSArray *, NSError *))completion;
- (void)fetchExternalLyrics:(waTrack *)track fallback:(waLyrics *)fallback completion:(void (^)(waLyrics *, NSError *))completion;
- (NSString *)lyricsQueryEscape:(NSString *)value;
- (id)lyricsJSONAtURL:(NSString *)urlString;
- (waLyrics *)lyricsFromLRCLIBJSON:(id)json;
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
            [[waDZAPI shared] signedURLForTrackToken:token formats:@[@"FLAC"] completion:^(NSString *url, NSString *format, NSError *losslessError) {
                if (url.length && !losslessError) {
                    [[waLog shared] log:@"lossless available"];
                    [[NSNotificationCenter defaultCenter] postNotificationName:waSessionDidChangeNotification object:self];
                    return;
                }
                        [[waDZAPI shared] signedURLForTrackToken:token formats:@[@"MP3_320"] completion:^(NSString *mp3URL, NSString *mp3Format, NSError *mp3Error) {
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

- (NSString *)qualityShortName:(waQuality)quality {
    switch (quality) {
        case waQualityHIFI: return @"FLAC";
        case waQualityFLAC: return @"FLAC";
        case waQualityMP3320: return @"320";
        default: return @"128";
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

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (chartError && !chartJSON) {
            if (completion) completion(nil, chartError);
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
        if (completion) completion(sections, nil);
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

- (void)searchSuggestions:(NSString *)query completion:(void (^)(NSArray *))completion {
    if (!query.length) { if (completion) completion(@[]); return; }
    [[waDZAPI shared] getPath:@"/search/artist" params:@{@"q": query, @"limit": @"6"} completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(@[]); return; }
        if (completion) completion([self itemsFrom:waArray(json, nil) kind:waArtistType]);
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

- (void)recommendationsWithCompletion:(void (^)(NSArray *, NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/editorial/0/releases" params:@{@"limit": @"25"} completion:^(NSDictionary *albumsJSON, NSError *albumsError) {
        NSArray *albums = albumsError ? @[] : [self itemsFrom:waArray(albumsJSON, nil) kind:waAlbumType];
        [[waDZAPI shared] getPath:@"/chart" params:nil completion:^(NSDictionary *chartJSON, NSError *chartError) {
            NSArray *artists = chartError ? @[] : [self itemsFrom:waArray(chartJSON, @"artists") kind:waArtistType];
            if (completion) completion(albums, artists, nil);
        }];
    }];
}

- (void)historyWithCompletion:(void (^)(NSArray *, NSError *))completion {
    NSArray *raw = [[NSUserDefaults standardUserDefaults] arrayForKey:waHistoryKey];
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSDictionary *dict in raw) [tracks addObject:[waItem itemWithDictionary:dict kind:waTrackType]];
    if (completion) completion(tracks, nil);
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

- (id)lyricsJSONAtURL:(NSString *)urlString {
    if (!urlString.length) return nil;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;
    NSDictionary *headers = @{@"User-Agent": @"Wave/1.0 (iOS 5.1; lyrics)"};
    NSError *error = nil;
    NSDictionary *response = [waTLS requestURL:url method:@"GET" headers:headers body:nil timeout:14.0 verify:YES error:&error];
    if (!response) {
        [[waLog shared] log:@"lyrics tls retry %@", error.localizedDescription];
        error = nil;
        response = [waTLS requestURL:url method:@"GET" headers:headers body:nil timeout:14.0 verify:NO error:&error];
    }
    NSInteger status = [response[@"status"] integerValue];
    NSData *body = response[@"body"];
    [[waLog shared] log:@"lyrics http %ld bytes=%lu %@", (long)status, (unsigned long)body.length, url.host];
    if (status == 404 || !body.length) return nil;
    return [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
}

- (waLyrics *)lyricsFromLRCLIBJSON:(id)json {
    NSMutableArray *records = [NSMutableArray array];
    if ([json isKindOfClass:[NSDictionary class]]) [records addObject:json];
    else if ([json isKindOfClass:[NSArray class]]) [records addObjectsFromArray:json];
    waLyrics *plainOnly = nil;
    waLyrics *instrumental = nil;
    for (id record in records) {
        if (![record isKindOfClass:[NSDictionary class]]) continue;
        id flag = record[@"instrumental"];
        BOOL marked = [flag respondsToSelector:@selector(boolValue)] && [flag boolValue];
        NSString *synced = record[@"syncedLyrics"];
        NSString *plain = [record[@"plainLyrics"] isKindOfClass:[NSString class]] ? record[@"plainLyrics"] : nil;
        if (marked || [waLyrics textIsInstrumentalOnly:synced] || [waLyrics textIsInstrumentalOnly:plain]) {
            if (!instrumental) {
                instrumental = [[waLyrics alloc] init];
                instrumental.source = @"lrclib";
                [instrumental markInstrumental];
            }
            continue;
        }
        if ([synced isKindOfClass:[NSString class]] && synced.length) {
            waLyrics *parsed = [waLyrics lyricsFromLRC:synced];
            if (parsed.lines.count) return parsed;
        }
        if (plain.length && !plainOnly) {
            plainOnly = [waLyrics lyricsFromLRC:plain];
            if (!plainOnly.lines.count) {
                plainOnly = [[waLyrics alloc] init];
                plainOnly.plain = plain;
            }
        }
    }
    return plainOnly ?: instrumental;
}

- (void)fetchExternalLyrics:(waTrack *)track fallback:(waLyrics *)fallback completion:(void (^)(waLyrics *, NSError *))completion {
    NSString *artist = [self lyricsQueryEscape:track.artistName];
    NSString *title = [self lyricsQueryEscape:track.title];
    NSString *album = [self lyricsQueryEscape:track.albumTitle];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        waLyrics *parsed = nil;
        NSString *search = [NSString stringWithFormat:@"https://lrclib.net/api/search?track_name=%@&artist_name=%@", title, artist];
        parsed = [self lyricsFromLRCLIBJSON:[self lyricsJSONAtURL:search]];
        if (!parsed.lines.count && !parsed.plain.length && !parsed.instrumental) {
            NSString *q = [NSString stringWithFormat:@"https://lrclib.net/api/search?q=%@%%20%@", artist, title];
            parsed = [self lyricsFromLRCLIBJSON:[self lyricsJSONAtURL:q]];
        }
        if (!parsed.lines.count && !parsed.plain.length && !parsed.instrumental) {
            NSMutableString *getURL = [NSMutableString stringWithFormat:@"https://lrclib.net/api/get?artist_name=%@&track_name=%@", artist, title];
            if (album.length) [getURL appendFormat:@"&album_name=%@", album];
            parsed = [self lyricsFromLRCLIBJSON:[self lyricsJSONAtURL:getURL]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (parsed.lines.count || parsed.plain.length || parsed.instrumental) {
                if (completion) completion(parsed, nil);
            } else if (fallback.lines.count || fallback.plain.length || fallback.instrumental) {
                if (completion) completion(fallback, nil);
            } else if (completion) {
                completion(nil, waErr(@"Lyrics not available.", 404));
            }
        });
    });
}

- (void)lyricsForTrack:(waTrack *)track completion:(void (^)(waLyrics *, NSError *))completion {
    if (!track.title.length && !track.identifier.length) {
        if (completion) completion(nil, waErr(@"No track id.", 400));
        return;
    }
    waLyrics *local = [[waDownloader shared] localLyricsForTrackID:track.identifier];
    if (local.lines.count || local.plain.length || local.instrumental) {
        if (completion) completion(local, nil);
        return;
    }
    __block waLyrics *fromDeezer = nil;
    __block waLyrics *fromBackup = nil;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    [self fetchExternalLyrics:track fallback:nil completion:^(waLyrics *lyrics, NSError *error) {
        (void)error;
        fromBackup = lyrics;
        dispatch_group_leave(group);
    }];
    if (track.identifier.length) {
        dispatch_group_enter(group);
        [[waDZAPI shared] callMethod:@"song.getLyrics" params:@{@"sng_id": track.identifier} completion:^(NSDictionary *result, NSError *error) {
            if (!error) fromDeezer = [waLyrics lyricsFromDeezer:result];
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        waLyrics *best = nil;
        if (fromBackup.wordTimed && fromBackup.lines.count) best = fromBackup;
        else if (fromDeezer.wordTimed && fromDeezer.lines.count) best = fromDeezer;
        else if (fromDeezer.lines.count) best = fromDeezer;
        else if (fromBackup.lines.count) best = fromBackup;
        else if (fromDeezer.instrumental) best = fromDeezer;
        else if (fromBackup.instrumental) best = fromBackup;
        else if (fromBackup.plain.length) best = fromBackup;
        else if (fromDeezer.plain.length) best = fromDeezer;
        if (best && track.identifier.length && [[waDownloader shared] isDownloadedTrackID:track.identifier]) {
            [[waDownloader shared] storeLyrics:best forTrackID:track.identifier];
        }
        if (completion) completion(best, best ? nil : waErr(@"Lyrics not available.", 404));
#if !OS_OBJECT_USE_OBJC
        dispatch_release(group);
#endif
    });
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

- (void)renamePlaylist:(waPlaylist *)playlist to:(NSString *)name completion:(void (^)(BOOL, NSError *))completion {
    [[waDZAPI shared] callMethod:@"playlist.update" params:@{@"playlist_id": playlist.identifier ?: @"", @"title": name ?: @""} completion:^(NSDictionary *result, NSError *error) {
        if (!error) playlist.title = name;
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
    if (!track.identifier.length) { if (completion) completion(nil, 0, waErr(@"No track.", 400)); return; }

    NSString *local = [[waDownloader shared] localPathForTrackID:track.identifier];
    if (local.length) {
        if (completion) completion([NSURL fileURLWithPath:local], self.preferredQuality, nil);
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
        [[waDZAPI shared] signedURLForTrackToken:token formats:formats completion:^(NSString *url, NSString *format, NSError *urlError) {
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
            NSString *schemeURL = [NSString stringWithFormat:@"deezer://stream/%@.%@?u=%@&c=BF",
                                   keyID, extension, escaped ?: @""];
            NSURL *streamURL = [NSURL URLWithString:schemeURL];
            if (!streamURL) {
                if (completion) completion(nil, 0, waErr(@"Could not build the stream URL.", 500));
                return;
            }
            [[waLog shared] log:@"stream full %@ as %@ %@", track.identifier, keyID, format ?: @"MP3_128"];
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

- (void)albumFans:(NSString *)albumID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/album/%@/fans", albumID] params:@{@"limit": @"100"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waUserType], error);
    }];
}

- (void)artistFans:(NSString *)artistID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/artist/%@/fans", artistID] params:@{@"limit": @"100"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waUserType], error);
    }];
}

- (void)artistPlaylists:(NSString *)artistID completion:(void (^)(NSArray *, NSError *))completion {
    [self fetchList:[NSString stringWithFormat:@"/artist/%@/playlists", artistID] kind:waPlaylistType completion:completion];
}

- (void)artistRadio:(NSString *)artistID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/artist/%@/radio", artistID] params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waTrackType], error);
    }];
}

- (void)artistComments:(NSString *)artistID completion:(void (^)(NSArray *, NSError *))completion {
    [self commentsForPath:[NSString stringWithFormat:@"/artist/%@/comments", artistID] completion:completion];
}

- (void)chartWithIdentifier:(NSString *)chartID completion:(void (^)(waChart *, NSError *))completion {
    NSString *path = chartID.length ? [NSString stringWithFormat:@"/chart/%@", chartID] : @"/chart";
    [[waDZAPI shared] getPath:path params:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        waChart *chart = [[waChart alloc] init];
        chart.tracks = [self itemsFrom:waArray(json, @"tracks") kind:waTrackType];
        chart.albums = [self itemsFrom:waArray(json, @"albums") kind:waAlbumType];
        chart.artists = [self itemsFrom:waArray(json, @"artists") kind:waArtistType];
        chart.playlists = [self itemsFrom:waArray(json, @"playlists") kind:waPlaylistType];
        if (completion) completion(chart, nil);
    }];
}

- (void)editorialsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/editorial" params:nil completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waAlbumType], error);
    }];
}

- (void)editorialSelection:(NSString *)editorialID completion:(void (^)(NSArray *, NSError *))completion {
    NSString *ident = editorialID.length ? editorialID : @"0";
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/editorial/%@/selection", ident] params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waAlbumType], error);
    }];
}

- (void)editorialCharts:(NSString *)editorialID completion:(void (^)(waChart *, NSError *))completion {
    NSString *ident = editorialID.length ? editorialID : @"0";
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/editorial/%@/charts", ident] params:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        waChart *chart = [[waChart alloc] init];
        chart.tracks = [self itemsFrom:waArray(json, @"tracks") kind:waTrackType];
        chart.albums = [self itemsFrom:waArray(json, @"albums") kind:waAlbumType];
        chart.artists = [self itemsFrom:waArray(json, @"artists") kind:waArtistType];
        chart.playlists = [self itemsFrom:waArray(json, @"playlists") kind:waPlaylistType];
        if (completion) completion(chart, nil);
    }];
}

- (void)genreRadios:(NSString *)genreID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/genre/%@/radios", genreID] params:nil completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waRadioType], error);
    }];
}

- (void)playlistFans:(NSString *)playlistID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/playlist/%@/fans", playlistID] params:@{@"limit": @"100"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waUserType], error);
    }];
}

- (void)playlistComments:(NSString *)playlistID completion:(void (^)(NSArray *, NSError *))completion {
    [self commentsForPath:[NSString stringWithFormat:@"/playlist/%@/comments", playlistID] completion:completion];
}

- (void)podcastsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/podcast" params:@{@"limit": @"100"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waPodcastType], error);
    }];
}

- (void)podcast:(NSString *)podcastID completion:(void (^)(waPodcast *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/podcast/%@", podcastID] params:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        waPodcast *podcast = [waPodcast itemWithDictionary:json kind:waPodcastType];
        [[waSession shared] podcastEpisodes:podcastID completion:^(NSArray *episodes, NSError *episodesError) {
            (void)episodesError;
            podcast.episodes = episodes;
            if (completion) completion(podcast, nil);
        }];
    }];
}

- (void)podcastEpisodes:(NSString *)podcastID completion:(void (^)(NSArray *, NSError *))completion {
    [self fetchList:[NSString stringWithFormat:@"/podcast/%@/episodes", podcastID] kind:waEpisodeType completion:completion];
}

- (void)episode:(NSString *)episodeID completion:(void (^)(waEpisode *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/episode/%@", episodeID] params:nil completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [waEpisode itemWithDictionary:json kind:waEpisodeType], error);
    }];
}

- (void)radioGenresWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/radio/genres" params:nil completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:@"genre"], error);
    }];
}

- (void)radioTopWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/radio/top" params:@{@"limit": @"100"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waRadioType], error);
    }];
}

- (void)radioListsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/radio/lists" params:@{@"limit": @"100"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waRadioType], error);
    }];
}

- (void)searchPodcasts:(NSString *)query completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/search/podcast" params:@{@"q": query ?: @"", @"limit": @"40"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waPodcastType], error);
    }];
}

- (void)searchRadio:(NSString *)query completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/search/radio" params:@{@"q": query ?: @"", @"limit": @"40"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waRadioType], error);
    }];
}

- (void)searchUsers:(NSString *)query completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/search/user" params:@{@"q": query ?: @"", @"limit": @"40"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waUserType], error);
    }];
}

- (void)user:(NSString *)userID completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *ident = userID.length ? userID : @"me";
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/user/%@", ident] params:nil completion:completion];
}

- (void)userPlaylists:(NSString *)userID completion:(void (^)(NSArray *, NSError *))completion {
    [self fetchList:[NSString stringWithFormat:@"/user/%@/playlists", userID.length ? userID : @"me"] kind:waPlaylistType completion:completion];
}

- (void)userAlbums:(NSString *)userID completion:(void (^)(NSArray *, NSError *))completion {
    [self fetchList:[NSString stringWithFormat:@"/user/%@/albums", userID.length ? userID : @"me"] kind:waAlbumType completion:completion];
}

- (void)userArtists:(NSString *)userID completion:(void (^)(NSArray *, NSError *))completion {
    [self fetchList:[NSString stringWithFormat:@"/user/%@/artists", userID.length ? userID : @"me"] kind:waArtistType completion:completion];
}

- (void)userTracks:(NSString *)userID completion:(void (^)(NSArray *, NSError *))completion {
    [self fetchList:[NSString stringWithFormat:@"/user/%@/tracks", userID.length ? userID : @"me"] kind:waTrackType completion:completion];
}

- (void)userFollowings:(NSString *)userID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/user/%@/followings", userID.length ? userID : @"me"] params:@{@"limit": @"100"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waUserType], error);
    }];
}

- (void)userFollowers:(NSString *)userID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/user/%@/followers", userID.length ? userID : @"me"] params:@{@"limit": @"100"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waUserType], error);
    }];
}

- (void)userChart:(NSString *)userID completion:(void (^)(waChart *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/user/%@/charts", userID.length ? userID : @"me"] params:nil completion:^(NSDictionary *json, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        waChart *chart = [[waChart alloc] init];
        chart.tracks = [self itemsFrom:waArray(json, @"tracks") kind:waTrackType];
        if (!chart.tracks.count) chart.tracks = [self itemsFrom:waArray(json, nil) kind:waTrackType];
        if (completion) completion(chart, nil);
    }];
}

- (void)userFlow:(NSString *)userID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:[NSString stringWithFormat:@"/user/%@/flow", userID.length ? userID : @"me"] params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waTrackType], error);
    }];
}

- (void)recommendTracksWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/user/me/recommendations/tracks" params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waTrackType], error);
    }];
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

- (void)recommendPlaylistsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/user/me/recommendations/playlists" params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waPlaylistType], error);
    }];
}

- (void)recommendRadiosWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/user/me/recommendations/radios" params:@{@"limit": @"50"} completion:^(NSDictionary *json, NSError *error) {
        if (completion) completion(error ? nil : [self itemsFrom:waArray(json, nil) kind:waRadioType], error);
    }];
}

- (void)optionsWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
    [[waDZAPI shared] getPath:@"/options" params:nil completion:completion];
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

- (UIImage *)cachedArtwork:(NSString *)url size:(CGSize)size {
    return [[waImageCache shared] cachedImageForURL:url size:size];
}

- (NSString *)localArtworkPathForTrack:(waTrack *)track {
    return [[waDownloader shared] localArtworkPathForTrack:track];
}

@end
