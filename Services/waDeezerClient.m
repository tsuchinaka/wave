#import "waDeezerClient.h"
#import "waDeezerClient+Private.h"
#import "waKeychainStore.h"
#import "waDebugLog.h"
#import "../Models/waPreferences.h"

static NSString * const waDeezerEndpoint = @"https://www.deezer.com/ajax/gw-light.php";
static NSString * const waDeezerErrorDomain = @"com.bytebox.wave.deezer";
NSString * const waDeezerAuthenticationDidChangeNotification = @"waDeezerAuthenticationDidChangeNotification";

NSMutableURLRequest *waDeezerRequest(NSURL *url, NSURLRequestCachePolicy policy) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:policy timeoutInterval:30.0];
    request.allowsCellularAccess = [waPreferences sharedPreferences].cellularDataAllowed;
    return request;
}

// JSON decoding and Deezer response normalization can involve hundreds of
// objects. Keep that work away from the main run loop on legacy devices, but
// continue delivering the public client callbacks on the main thread.
static NSOperationQueue *waDeezerParseQueue(void) {
    static NSOperationQueue *queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 2;
    });
    return queue;
}

static dispatch_queue_t waDeezerParseDispatchQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ queue = dispatch_queue_create("com.bytebox.wave.deezer.parse", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static void waDeezerDispatchMain(void (^block)(void)) {
    if (!block) return;
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

static NSError *waDZResponseError(NSURLResponse *response, NSError *networkError, NSString *message) {
    if (networkError) return networkError;
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    if (status < 200 || status >= 300) return [NSError errorWithDomain:waDeezerErrorDomain code:status ?: 500 userInfo:@{NSLocalizedDescriptionKey:message ?: @"Deezer request failed."}];
    return nil;
}

static NSString *waDZString(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

static BOOL waDZLiked(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return NO;
    for (NSString *key in @[@"liked", @"likedByMe", @"user_liked", @"is_favorite", @"favorite", @"FAVORITE", @"IS_FAVORITE"]) {
        id value = dictionary[key];
        if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    }
    return NO;
}

static NSString *waDZRawIdentifier(NSString *identifier) {
    if ([identifier hasPrefix:@"deezer:"]) return [identifier substringFromIndex:7];
    return identifier;
}

// Gateway IDs exceed 32 bits and armv7 NSInteger is 32-bit: parse as 64-bit
// and round-trip before emitting a JSON number, else keep the string.
static NSNumber *waDZGatewayNumber(NSString *identifier) {
    if (!identifier.length) return nil;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([identifier rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return nil;
    long long value = [identifier longLongValue];
    // Round-trip: rejects overflow wrap and leading zeros ("007" -> 7).
    if (![[@(value) stringValue] isEqualToString:identifier]) return nil;
    return @(value);
}

// getAllFeedbacks returns favorites oldest-first. Reorder items newest-first
// by reversed identifier position (song.getListData order is not trusted).
static NSArray *waDZOrderNewestFirst(NSArray *items, NSArray *identifiers) {
    if (!items.count || !identifiers.count) return items;
    NSArray *reversed = [[identifiers reverseObjectEnumerator] allObjects];
    NSMutableDictionary *rank = [NSMutableDictionary dictionaryWithCapacity:reversed.count];
    NSUInteger index = 0;
    for (NSString *identifier in reversed) {
        if ([identifier isKindOfClass:[NSString class]] && identifier.length && !rank[identifier]) {
            rank[identifier] = @(index);
        }
        index += 1;
    }
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *keyA = waDZRawIdentifier(waDZString(a[@"trackId"]) ?: waDZString(a[@"id"]) ?: @"") ?: @"";
        NSString *keyB = waDZRawIdentifier(waDZString(b[@"trackId"]) ?: waDZString(b[@"id"]) ?: @"") ?: @"";
        NSNumber *rankA = rank[keyA];
        NSNumber *rankB = rank[keyB];
        if (!rankA && !rankB) return NSOrderedSame;
        if (!rankA) return NSOrderedDescending;
        if (!rankB) return NSOrderedAscending;
        return [rankA compare:rankB];
    }];
}

static NSString *waDZQueryEscape(NSString *value) {
    if (!value.length) return @"";
    CFStringRef escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)value, NULL, CFSTR(":/?#[]@!$&'()*+,;="), kCFStringEncodingUTF8);
    NSString *result = escaped ? [(__bridge NSString *)escaped copy] : [value copy];
    if (escaped) CFRelease(escaped);
    return result;
}

// Search response cache TTL in seconds. Short enough that catalogue
// changes surface quickly, long enough to cover re-types and tab switches.
static const NSTimeInterval waDZSearchCacheTTL = 300.0;

static NSString *waDZSearchCacheKey(NSString *normalizedType, NSString *query, NSUInteger limit, NSUInteger index, BOOL strict) {
    NSString *folded = [[[query ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString] copy];
    return [NSString stringWithFormat:@"%@|%@|%lu|%lu|%d", normalizedType ?: @"song", folded, (unsigned long)limit, (unsigned long)index, strict ? 1 : 0];
}

static void waDZInstallARLCookie(NSString *arl) {
    if (!arl.length) return;
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSURL *url = [NSURL URLWithString:@"https://www.deezer.com/"];
    for (NSHTTPCookie *cookie in [storage cookiesForURL:url]) {
        if ([cookie.name isEqualToString:@"arl"]) [storage deleteCookie:cookie];
    }
    NSDictionary *properties = @{ NSHTTPCookieName: @"arl", NSHTTPCookieValue: arl,
                                  NSHTTPCookieDomain: @".deezer.com", NSHTTPCookiePath: @"/" };
    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
    if (cookie) [storage setCookie:cookie];
}

static void waDZClearCookies(void) {
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSURL *url = [NSURL URLWithString:@"https://www.deezer.com/"];
    for (NSHTTPCookie *cookie in [storage cookiesForURL:url]) [storage deleteCookie:cookie];
}

static NSDictionary *waDZNestedDictionary(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static id waDZFirstValue(NSArray *dictionaries, NSArray *keys) {
    for (NSDictionary *dictionary in dictionaries) {
        if (![dictionary isKindOfClass:[NSDictionary class]]) continue;
        for (NSString *key in keys) {
            id value = dictionary[key];
            if ([value isKindOfClass:[NSString class]] && [value length]) return value;
            if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
        }
    }
    return nil;
}

static NSDictionary *waDZSongDetails(NSDictionary *song) {
    for (NSString *key in @[@"SONG", @"SNG", @"TRACK", @"DATA", @"data", @"track", @"song"]) {
        NSDictionary *nested = waDZNestedDictionary(song, key);
        if (nested) return nested;
    }
    return nil;
}

static NSArray *waDZArrayFromContainer(id container) {
    if ([container isKindOfClass:[NSArray class]]) return container;
    if (![container isKindOfClass:[NSDictionary class]]) return @[];
    NSDictionary *dictionary = container;
    for (NSString *key in @[@"data", @"DATA", @"items", @"ITEMS", @"songs", @"SONGS", @"tracks", @"TRACKS"]) {
        id value = dictionary[key];
        NSArray *array = waDZArrayFromContainer(value);
        if (array.count) return array;
    }
    return @[];
}

static NSDictionary *waDZFirstArtist(NSDictionary *dictionary) {
    NSDictionary *artist = waDZNestedDictionary(dictionary, @"ARTIST");
    if (artist) return artist;
    artist = waDZNestedDictionary(dictionary, @"artist");
    if (artist) return artist;
    artist = waDZNestedDictionary(dictionary, @"artists");
    if (artist) return artist;
    NSArray *artists = [dictionary[@"ARTISTS"] isKindOfClass:[NSArray class]] ? dictionary[@"ARTISTS"] : nil;
    id first = artists.count ? artists[0] : nil;
    return [first isKindOfClass:[NSDictionary class]] ? first : nil;
}

static NSString *waDZImageURL(id value, NSString *type) {
    NSString *image = waDZString(value);
    if (!image.length) return nil;
    if ([image rangeOfString:@"://"].location != NSNotFound) return image;
    return [NSString stringWithFormat:@"https://e-cdns-images.dzcdn.net/images/%@/%@/1000x1000-000000-80-0-0.jpg", type ?: @"cover", image];
}

static NSDictionary *waDZUser(NSDictionary *user) {
    if (![user isKindOfClass:[NSDictionary class]]) return @{};
    NSString *first = waDZString(user[@"FIRSTNAME"]) ?: waDZString(user[@"firstName"]);
    NSString *last = waDZString(user[@"LASTNAME"]) ?: waDZString(user[@"lastName"]);
    NSString *fullName = [NSString stringWithFormat:@"%@%@%@", first ?: @"", first.length && last.length ? @" " : @"", last ?: @""];
    NSString *name = waDZString(user[@"BLOG_NAME"]) ?: waDZString(user[@"name"]) ?: fullName;
    NSString *avatar = waDZString(user[@"PICTURE_XL"]) ?: waDZString(user[@"PICTURE_BIG"]) ?: waDZString(user[@"PICTURE_MEDIUM"]) ?: waDZString(user[@"PICTURE_SMALL"]) ?: waDZString(user[@"PICTURE"]) ?: waDZString(user[@"USER_PICTURE"]) ?: waDZString(user[@"USER_PICTURE_URL"]) ?: waDZString(user[@"picture_xl"]) ?: waDZString(user[@"picture_big"]) ?: waDZString(user[@"picture_medium"]) ?: waDZString(user[@"picture_small"]) ?: waDZString(user[@"picture"]) ?: waDZString(user[@"user_picture"]);
    NSString *avatarURL = waDZImageURL(avatar, @"user") ?: avatar;
    NSString *country = waDZString(user[@"COUNTRY"]) ?: waDZString(user[@"country"]) ?: waDZString(user[@"COUNTRY_NAME"]) ?: waDZString(user[@"country_name"]) ?: waDZString(user[@"COUNTRY_CODE"]) ?: waDZString(user[@"country_code"]) ?: waDZString(user[@"USER_COUNTRY"]) ?: waDZString(user[@"COUNTRY_ID"]) ?: @"";
    return @{ @"id": waDZString(user[@"USER_ID"]) ?: waDZString(user[@"id"]) ?: @"",
              @"userId": waDZString(user[@"USER_ID"]) ?: @"",
              @"username": waDZString(user[@"BLOG_NAME"]) ?: waDZString(user[@"username"]) ?: @"",
              @"name": name ?: @"Deezer listener",
              @"displayName": name ?: @"Deezer listener",
              @"firstname": first ?: @"",
              @"lastname": last ?: @"",
              @"avatar": avatarURL ?: @"",
              @"picture": avatarURL ?: @"",
              @"picture_medium": avatarURL ?: @"",
              @"picture_big": avatarURL ?: @"",
              @"picture_xl": avatarURL ?: @"",
              @"country": country,
              @"fans": user[@"NB_FAN"] ?: user[@"nb_fan"] ?: @0,
              @"nb_fan": user[@"NB_FAN"] ?: user[@"nb_fan"] ?: @0,
              @"role": waDZString(user[@"TYPE"]) ?: @"user",
              @"deezerRaw": user };
}

static NSDictionary *waDZSong(NSDictionary *song) {
    if (![song isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *details = waDZSongDetails(song);
    NSArray *sources = details ? @[song, details] : @[song];
    NSDictionary *artist = waDZFirstArtist(song) ?: (details ? waDZFirstArtist(details) : nil);
    NSDictionary *album = waDZNestedDictionary(song, @"ALBUM") ?: waDZNestedDictionary(song, @"album") ?: (details ? waDZNestedDictionary(details, @"ALBUM") : nil);
    NSString *identifier = waDZRawIdentifier(waDZFirstValue(sources, @[@"SNG_ID", @"SONG_ID", @"TRACK_ID", @"id", @"ID"]));
    NSString *artistName = waDZFirstValue(sources, @[@"ART_NAME", @"ARTIST_NAME", @"artistName", @"artist", @"AUTHOR", @"author"]);
    if (!artistName.length) artistName = waDZFirstValue(@[artist ?: @{}], @[@"ART_NAME", @"ARTIST_NAME", @"name", @"NAME"]);
    NSString *albumName = waDZFirstValue(sources, @[@"ALB_TITLE", @"ALBUM_TITLE", @"albumName", @"album"]);
    if (!albumName.length) albumName = waDZFirstValue(@[album ?: @{}], @[@"ALB_TITLE", @"ALBUM_TITLE", @"title", @"TITLE", @"name"]);
    NSString *isrc = waDZFirstValue(sources, @[@"ISRC", @"isrc", @"SNG_ISRC", @"isrc_code"]);
    NSString *thumbnail = waDZFirstValue(sources, @[@"ALB_PICTURE_XL", @"ALB_PICTURE_BIG", @"ALB_PICTURE"]);
    thumbnail = waDZImageURL(thumbnail, @"cover") ?: waDZImageURL(album[@"cover_xl"], @"cover") ?: waDZImageURL(album[@"cover_big"], @"cover");
    NSString *title = waDZFirstValue(sources, @[@"SNG_TITLE", @"SONG_TITLE", @"TRACK_TITLE", @"TITLE", @"title", @"NAME", @"name", @"title_short"]);
    NSMutableDictionary *result = [@{ @"id": identifier ?: @"",
                                      @"identifier": identifier ?: @"",
                                       @"trackId": identifier.length ? [@"deezer:" stringByAppendingString:identifier] : @"",
                                      @"title": title ?: @"",
                                      @"artistName": artistName ?: @"",
                                      @"subtitle": artistName ?: @"",
                                      @"artistIdentifier": waDZString(song[@"ART_ID"]) ?: waDZString(artist[@"ART_ID"]) ?: waDZString(artist[@"id"]) ?: @"",
                                       @"albumName": albumName ?: @"",
                                       @"isrc": isrc ?: @"",
                                       @"albumIdentifier": waDZString(song[@"ALB_ID"]) ?: waDZString(album[@"ALB_ID"]) ?: waDZString(album[@"id"]) ?: @"",
                                      @"thumbnailURL": thumbnail ?: @"",
                                      @"duration": waDZFirstValue(sources, @[@"DURATION", @"duration", @"DURATION_SEC"]) ?: @0,
                                      @"explicit": song[@"EXPLICIT_LYRICS"] ?: song[@"explicit"] ?: details[@"EXPLICIT_LYRICS"] ?: @NO,
                                       @"rank": song[@"rank"] ?: details[@"rank"] ?: @0,
                                       @"liked": @(waDZLiked(song) || waDZLiked(details)) } mutableCopy];
    result[@"deezerRaw"] = song;
    return result;
}

static NSDictionary *waDZAlbum(NSDictionary *album) {
    if (![album isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *artist = waDZFirstArtist(album);
    NSString *identifier = waDZRawIdentifier(waDZString(album[@"ALB_ID"]) ?: waDZString(album[@"id"]));
    NSString *title = waDZString(album[@"ALB_TITLE"]) ?: waDZString(album[@"title"]) ?: @"Untitled album";
    NSString *artistName = waDZString(album[@"ART_NAME"]) ?: waDZString(artist[@"ART_NAME"]) ?: waDZString(artist[@"name"]);
    NSString *picture = waDZImageURL(album[@"ALB_PICTURE_XL"], @"cover") ?: waDZImageURL(album[@"ALB_PICTURE_BIG"], @"cover") ?: waDZImageURL(album[@"ALB_PICTURE"], @"cover") ?: waDZImageURL(album[@"cover_xl"], @"cover");
    NSString *recordType = waDZString(album[@"record_type"]) ?: waDZString(album[@"recordType"]) ?: waDZString(album[@"ALB_TYPE"]) ?: waDZString(album[@"RECORD_TYPE"]) ?: waDZString(album[@"TYPE"]);
    return @{ @"id": identifier ?: @"", @"identifier": identifier ?: @"", @"title": title,
              @"artistName": artistName ?: @"", @"subtitle": artistName ?: @"",
              @"thumbnailURL": picture ?: @"", @"trackCount": album[@"NB_SONG"] ?: album[@"nb_tracks"] ?: @0,
              @"releaseYear": waDZString(album[@"DATE"]) ?: waDZString(album[@"release_date"]) ?: @"", @"recordType": recordType ?: @"album",
              @"artistIdentifier": waDZString(album[@"ART_ID"]) ?: waDZString(artist[@"ART_ID"]) ?: waDZString(artist[@"id"]) ?: @"",
              @"link": waDZString(album[@"link"]) ?: @"", @"explicit": album[@"EXPLICIT_LYRICS"] ?: album[@"explicit_lyrics"] ?: @NO, @"type": @1,
               @"liked": @(waDZLiked(album)), @"deezerRaw": album };
}

static NSDictionary *waDZAlbumSections(NSArray *albums) {
    NSMutableArray *standard = [NSMutableArray array];
    NSMutableArray *live = [NSMutableArray array];
    NSMutableArray *eps = [NSMutableArray array];
    NSMutableArray *singles = [NSMutableArray array];
    NSMutableArray *compilations = [NSMutableArray array];
    NSMutableArray *other = [NSMutableArray array];
    for (NSDictionary *album in albums) {
        if (![album isKindOfClass:[NSDictionary class]]) continue;
        NSString *type = [ (waDZString(album[@"recordType"]) ?: waDZString(album[@"record_type"]) ?: waDZString(album[@"ALB_TYPE"]) ?: @"album") lowercaseString];
        NSString *title = [ (waDZString(album[@"title"]) ?: @"") lowercaseString];
        if ([type rangeOfString:@"single"].location != NSNotFound || ([type isEqualToString:@"album"] && [title hasSuffix:@" single"])) [singles addObject:album];
        else if ([type rangeOfString:@"ep"].location != NSNotFound) [eps addObject:album];
        else if ([type rangeOfString:@"compilation"].location != NSNotFound) [compilations addObject:album];
        else if ([type rangeOfString:@"live"].location != NSNotFound || [title rangeOfString:@"live"].location != NSNotFound || [title rangeOfString:@"concert"].location != NSNotFound) [live addObject:album];
        else if ([type isEqualToString:@"album"] || !type.length) [standard addObject:album];
        else [other addObject:album];
    }
    return @{ @"albums": standard, @"liveAlbums": live, @"eps": eps, @"singles": singles, @"compilations": compilations, @"otherAlbums": other };
}

// The public artist albums endpoint is paginated even when limit=100 is
// requested. Fetch every page and follow Deezer's `next` URL when present.
// The index fallback handles older responses that omit `next` but still
// expose a full page.
static void waDZFetchArtistAlbumsPage(NSURL *url, NSUInteger fallbackIndex, NSMutableArray *albums, NSMutableSet *visited, void (^completion)(NSError *)) {
    if (!url || [visited containsObject:url.absoluteString ?: @""]) {
        if (completion) completion(nil);
        return;
    }
    [visited addObject:url.absoluteString ?: @""];
    [NSURLConnection sendAsynchronousRequest:waDeezerRequest(url, NSURLRequestUseProtocolCachePolicy) queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSError *error = waDZResponseError(response, networkError, @"Unable to load the complete artist discography.");
        if (!error && [json[@"error"] isKindOfClass:[NSDictionary class]]) error = [NSError errorWithDomain:waDeezerErrorDomain code:404 userInfo:@{NSLocalizedDescriptionKey:@"Unable to load the complete artist discography."}];
        if (error || ![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(error);
            return;
        }
        NSArray *page = [json[@"data"] isKindOfClass:[NSArray class]] ? json[@"data"] : @[];
        for (NSDictionary *object in page) if ([object isKindOfClass:[NSDictionary class]]) [albums addObject:object];

        NSString *nextString = waDZString(json[@"next"]);
        NSURL *nextURL = nextString.length ? [NSURL URLWithString:nextString] : nil;
        if (nextURL && ![visited containsObject:nextURL.absoluteString]) {
            waDZFetchArtistAlbumsPage(nextURL, fallbackIndex + page.count, albums, visited, completion);
        } else if (page.count >= 100) {
            NSArray *ampParts = [url.absoluteString componentsSeparatedByString:@"&index="];
            NSString *base = ampParts.count ? ampParts[0] : nil;
            if (!base.length) {
                NSArray *questionParts = [url.absoluteString componentsSeparatedByString:@"?index="];
                base = questionParts.count ? questionParts[0] : nil;
            }
            NSURL *indexedURL = [NSURL URLWithString:[NSString stringWithFormat:@"%@%@limit=100&index=%lu", base ?: @"", [base rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&", (unsigned long)(fallbackIndex + page.count)]];
            waDZFetchArtistAlbumsPage(indexedURL, fallbackIndex + page.count, albums, visited, completion);
        } else if (completion) completion(nil);
    }];
}

// pageArtist has changed the shape of its release buckets a few times. Some
// accounts receive one ALBUMS bucket while others receive separate ALBUMS,
// SINGLES, EPS, LIVE_ALBUMS and COMPILATIONS buckets. Preserve every bucket
// and annotate entries whose payload omitted record_type so Artist View can
// build the complete discography instead of silently showing only albums.
static NSArray *waDZArtistReleaseObjects(NSDictionary *results) {
    NSDictionary *bucketTypes = @{
        @"ALBUMS": @"album", @"albums": @"album",
        @"SINGLES": @"single", @"singles": @"single",
        @"EPS": @"ep", @"EP": @"ep", @"eps": @"ep",
        @"LIVE_ALBUMS": @"live", @"liveAlbums": @"live", @"LIVE": @"live",
        @"COMPILATIONS": @"compilation", @"compilations": @"compilation",
        @"RELEASES": @"", @"releases": @""
    };
    NSMutableArray *objects = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *key in bucketTypes) {
        NSString *defaultType = bucketTypes[key];
        for (NSDictionary *object in waDZArrayFromContainer(results[key])) {
            if (![object isKindOfClass:[NSDictionary class]]) continue;
            NSString *identifier = waDZRawIdentifier(waDZString(object[@"ALB_ID"]) ?: waDZString(object[@"id"]) ?: waDZString(object[@"title"]) ?: key);
            if ([seen containsObject:identifier]) continue;
            [seen addObject:identifier];
            NSMutableDictionary *copy = [object mutableCopy];
            if (!waDZString(copy[@"record_type"]) && !waDZString(copy[@"recordType"]) && defaultType.length) copy[@"record_type"] = defaultType;
            [objects addObject:copy];
        }
    }
    return objects;
}

static NSDictionary *waDZArtist(NSDictionary *artist) {
    if (![artist isKindOfClass:[NSDictionary class]]) return nil;
    NSString *identifier = waDZRawIdentifier(waDZString(artist[@"ART_ID"]) ?: waDZString(artist[@"id"]));
    NSString *name = waDZString(artist[@"ART_NAME"]) ?: waDZString(artist[@"name"]) ?: @"Untitled artist";
    NSString *picture = waDZImageURL(artist[@"ART_PICTURE_XL"], @"artist") ?: waDZImageURL(artist[@"ART_PICTURE_BIG"], @"artist") ?: waDZImageURL(artist[@"ART_PICTURE"], @"artist") ?: waDZImageURL(artist[@"picture_xl"], @"artist");
    return @{ @"id": identifier ?: @"", @"identifier": identifier ?: @"", @"title": name,
              @"artistName": name, @"subtitle": @"Artist", @"thumbnailURL": picture ?: @"",
               @"type": @2, @"liked": @(waDZLiked(artist)), @"fans": artist[@"nb_fan"] ?: artist[@"fans"] ?: @0, @"nb_fan": artist[@"nb_fan"] ?: artist[@"fans"] ?: @0, @"deezerRaw": artist };
}

static NSDictionary *waDZPlaylist(NSDictionary *playlist) {
    if (![playlist isKindOfClass:[NSDictionary class]]) return nil;
    NSString *identifier = waDZRawIdentifier(waDZString(playlist[@"PLAYLIST_ID"]) ?: waDZString(playlist[@"PARENT_PLAYLIST_ID"]) ?: waDZString(playlist[@"id"]));
    NSString *title = waDZString(playlist[@"TITLE"]) ?: waDZString(playlist[@"title"]) ?: waDZString(playlist[@"name"]);
    NSDictionary *user = waDZNestedDictionary(playlist, @"USER") ?: waDZNestedDictionary(playlist, @"user");
    NSString *owner = waDZString(user[@"BLOG_NAME"]) ?: waDZString(user[@"name"]) ?: waDZString(playlist[@"USER_NAME"]);
    NSString *picture = waDZString(playlist[@"PICTURE_XL"]) ?: waDZString(playlist[@"PICTURE_BIG"]) ?: waDZString(playlist[@"PICTURE"]) ?: waDZString(playlist[@"picture_xl"]) ?: waDZString(playlist[@"picture_big"]) ?: waDZString(playlist[@"picture"]);
    picture = waDZImageURL(picture, @"playlist") ?: waDZString(playlist[@"picture_xl"]) ?: waDZString(playlist[@"picture"]);
    id trackCount = playlist[@"NB_SONG"] ?: playlist[@"NB_SONGS"] ?: playlist[@"nb_songs"] ?: playlist[@"nb_tracks"] ?: playlist[@"trackCount"];
    NSString *subtitle = owner.length ? owner : (trackCount ? [NSString stringWithFormat:@"%@ songs", trackCount] : @"Playlist");
    BOOL liked = waDZLiked(playlist);
    return @{ @"id": identifier ?: @"", @"identifier": identifier ?: @"", @"title": title ?: @"Playlist",
              @"name": title ?: @"Playlist", @"subtitle": subtitle ?: @"Playlist", @"artistName": owner ?: @"",
              @"trackCount": trackCount ?: @0,
              @"thumbnailURL": picture ?: @"", @"type": @3, @"public": @YES, @"liked": @(liked), @"deezerRaw": playlist };
}

static NSDictionary *waDZHomeItem(NSDictionary *object) {
    if (![object isKindOfClass:[NSDictionary class]]) return nil;
    NSString *type = [[(waDZString(object[@"type"]) ?: waDZString(object[@"TYPE"]) ?: waDZString(object[@"kind"])) lowercaseString] copy];
    NSDictionary *data = [object[@"data"] isKindOfClass:[NSDictionary class]] ? object[@"data"] : ([object[@"DATA"] isKindOfClass:[NSDictionary class]] ? object[@"DATA"] : object);
    if ([type isEqualToString:@"track"] || [type isEqualToString:@"song"]) return waDZSong(data);
    if ([type isEqualToString:@"album"]) return waDZAlbum(data);
    if ([type isEqualToString:@"artist"]) return waDZArtist(data);
    if ([type isEqualToString:@"playlist"]) return waDZPlaylist(data);
    if ([type isEqualToString:@"smarttracklist"] || [type isEqualToString:@"flow"] || [type isEqualToString:@"flow_mood"] || [type isEqualToString:@"mood"] || [type isEqualToString:@"radio"] || [type isEqualToString:@"channel"] || [type isEqualToString:@"category"] || [type isEqualToString:@"editorial"] || [type isEqualToString:@"genre"]) {
        NSString *identifier = waDZRawIdentifier(waDZString(data[@"PLAYLIST_ID"]) ?: waDZString(data[@"FLOW_ID"]) ?: waDZString(data[@"CHANNEL_ID"]) ?: waDZString(data[@"id"]) ?: waDZString(data[@"ID"]));
        NSString *title = waDZString(data[@"TITLE"]) ?: waDZString(data[@"title"]) ?: waDZString(data[@"NAME"]) ?: waDZString(data[@"name"]) ?: type.capitalizedString;
        NSString *picture = waDZImageURL(data[@"PICTURE_XL"], @"playlist") ?: waDZImageURL(data[@"PICTURE_BIG"], @"playlist") ?: waDZImageURL(data[@"PICTURE"], @"playlist") ?: waDZString(data[@"cover_xl"]);
        return @{ @"id": identifier ?: @"", @"identifier": identifier ?: @"", @"title": title, @"name": title, @"subtitle": waDZString(data[@"DESCRIPTION"]) ?: @"", @"thumbnailURL": picture ?: @"", @"type": @3, @"homeKind": type, @"deezerRaw": data };
    }
    return nil;
}

@class waDeezerClient;
@interface waDeezerClient (SearchTasks)
- (void)wa_removeSearchTask:(id)task;
- (NSError *)errorWithMessage:(NSString *)message code:(NSInteger)code;
@property (nonatomic, strong, readonly) NSCache *searchCache;
@end

static NSArray *waDZNormalizedSearchItems(NSArray *dataArray, NSString *normalizedType) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *object in dataArray) {
        if (![object isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *normalized = [normalizedType isEqualToString:@"song"] || [normalizedType isEqualToString:@"track"] ? waDZSong(object) : ([normalizedType isEqualToString:@"album"] ? waDZAlbum(object) : ([normalizedType isEqualToString:@"artist"] ? waDZArtist(object) : waDZPlaylist(object)));
        if (normalized) [items addObject:normalized];
    }
    // Deezer ranks by popularity (track.rank, artist.nb_fan). The API
    // usually returns relevance order, but re-assert it after
    // normalization so a slow/gateway response can never scramble hits.
    if ([normalizedType isEqualToString:@"song"] || [normalizedType isEqualToString:@"track"]) {
        [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            long long ra = [a[@"rank"] respondsToSelector:@selector(longLongValue)] ? [a[@"rank"] longLongValue] : 0;
            long long rb = [b[@"rank"] respondsToSelector:@selector(longLongValue)] ? [b[@"rank"] longLongValue] : 0;
            if (ra != rb) return ra > rb ? NSOrderedAscending : NSOrderedDescending;
            return NSOrderedSame;
        }];
    } else if ([normalizedType isEqualToString:@"artist"]) {
        [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            long long fa = [a[@"nb_fan"] respondsToSelector:@selector(longLongValue)] ? [a[@"nb_fan"] longLongValue] : 0;
            long long fb = [b[@"nb_fan"] respondsToSelector:@selector(longLongValue)] ? [b[@"nb_fan"] longLongValue] : 0;
            if (fa != fb) return fa > fb ? NSOrderedAscending : NSOrderedDescending;
            return NSOrderedSame;
        }];
    }
    return items;
}

// Delegate-based search request so it can actually be cancelled.
// sendAsynchronousRequest cannot be revoked: stale keystrokes kept burning
// radio and A4 parse time even though the UI already discarded them.
@interface waDZSearchTask : NSObject <NSURLConnectionDelegate>
@property (nonatomic, copy) NSString *coalescingKey;
@property (nonatomic, copy) NSString *cacheKey;
@property (nonatomic, copy) NSString *normalizedType;
@property (nonatomic, strong) NSURLConnection *connection;
@property (nonatomic, strong) NSMutableData *receivedData;
@property (nonatomic, assign) NSInteger statusCode;
@property (nonatomic, strong) NSMutableArray *completions;
@property (nonatomic, weak) waDeezerClient *client;
@property (nonatomic, assign) BOOL finished;
- (void)addCompletion:(void (^)(NSArray *items, NSError *error))completion;
- (void)completeWithItems:(NSArray *)items error:(NSError *)error;
@end

@implementation waDZSearchTask
- (id)init {
    if ((self = [super init])) {
        _receivedData = [NSMutableData data];
        _completions = [NSMutableArray array];
    }
    return self;
}
- (void)addCompletion:(void (^)(NSArray *items, NSError *error))completion {
    if (!completion) return;
    @synchronized (self) { [_completions addObject:[completion copy]]; }
}
- (void)completeWithItems:(NSArray *)items error:(NSError *)error {
    NSArray *blocks = nil;
    @synchronized (self) {
        if (_finished) return;
        _finished = YES;
        blocks = [_completions copy];
        [_completions removeAllObjects];
    }
    // Break the client -> task -> connection -> task retain loop first.
    [[self client] wa_removeSearchTask:self];
    self.connection = nil;
    waDeezerDispatchMain(^{
        for (void (^block)(NSArray *, NSError *) in blocks) block(items, error);
    });
}
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    [_receivedData setLength:0];
    _statusCode = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
}
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [_receivedData appendData:data];
}
- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    [[waDebugLog sharedLog] log:@"Deezer search HTTP done: %@ (%ld bytes, status %ld)", self.coalescingKey ?: @"", (long)self.receivedData.length, (long)self.statusCode];
    NSString *type = [self.normalizedType copy];
    NSData *payload = [self.receivedData copy];
    NSInteger status = self.statusCode;
    waDeezerClient *client = self.client;
    // Retain self until the parse block runs; the client set may already
    // have dropped us via cancelSearchRequests (cancelled tasks never
    // reach this delegate, but coalesced completions must still fire).
    [waDeezerParseQueue() addOperationWithBlock:^{
        NSDictionary *json = payload.length ? [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL] : nil;
        NSError *error = nil;
        if (status < 200 || status >= 300) error = [client errorWithMessage:@"Deezer search failed." code:status ?: 500];
        if (!error && [json[@"error"] isKindOfClass:[NSDictionary class]]) error = [client errorWithMessage:waDZString(json[@"error"][@"message"]) ?: @"Deezer search failed." code:403];
        NSArray *dataArray = [json[@"data"] isKindOfClass:[NSArray class]] ? json[@"data"] : @[];
        NSArray *items = waDZNormalizedSearchItems(dataArray, type);
        if (!error && self.cacheKey.length && client) {
            NSCache *cache = client.searchCache;
            if (cache) [cache setObject:@{ @"items": items ?: @[], @"date": [NSDate date] } forKey:self.cacheKey];
        }
        [self completeWithItems:items error:error];
    }];
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [[waDebugLog sharedLog] log:@"Deezer search HTTP failed: %@ (%@)", self.coalescingKey ?: @"", error.localizedDescription ?: error];
    [self completeWithItems:nil error:error];
}
@end

@interface waDeezerClient ()
@property (nonatomic, copy, readwrite) NSString *userIdentifier;
@property (nonatomic, copy, readwrite) NSString *userName;
@property (nonatomic, copy, readwrite) NSString *favoritesPlaylistIdentifier;
@property (nonatomic, copy) NSString *csrfToken;
@property (nonatomic, copy) NSString *pipeJWT;
@property (nonatomic, copy) NSDictionary *cachedUser;
@property (nonatomic, strong) NSMutableArray *authorizationCompletions;
@property (nonatomic, assign) BOOL authorizationInFlight;
@property (nonatomic, strong) NSMutableArray *pipeJWTCompletions;
@property (nonatomic, assign) BOOL pipeJWTInFlight;
@property (nonatomic, strong) NSCache *artistCatalogCache;
@property (nonatomic, strong) NSMutableSet *searchTasks;
// Short-lived search response cache: re-typed queries, tab switches and
// pagination refetch the same (type, query, limit, index). Entries expire
// after WA_SEARCH_CACHE_TTL so results never go stale for long.
@property (nonatomic, strong) NSCache *searchCache;
- (void)wa_removeSearchTask:(id)task;
- (void)callMethod:(NSString *)method parameters:(NSDictionary *)parameters retry:(BOOL)retry completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)authenticatePipeWithCompletion:(void (^)(NSError *error))completion;
- (void)hydratePublicSongs:(NSArray *)items identifiers:(NSArray *)identifiers completion:(void (^)(NSArray *))completion;
- (void)publicPlaylistWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)publicAlbumWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)publicArtistWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation waDeezerClient

+ (waDeezerClient *)sharedClient { static waDeezerClient *client; static dispatch_once_t onceToken; dispatch_once(&onceToken, ^{ client = [[self alloc] init]; }); return client; }

- (id)init {
    if ((self = [super init])) {
        _csrfToken = nil;
        _userIdentifier = nil;
        _userName = nil;
        _favoritesPlaylistIdentifier = nil;
        _cachedUser = nil;
        _authorizationCompletions = [NSMutableArray array];
        _pipeJWTCompletions = [NSMutableArray array];
        _artistCatalogCache = [[NSCache alloc] init];
        _artistCatalogCache.totalCostLimit = 4 * 1024 * 1024;
        _searchCache = [[NSCache alloc] init];
        _searchCache.countLimit = 60;
        _searchTasks = [NSMutableSet set];
    }
    return self;
}

- (BOOL)isAuthenticated { return [waKeychainStore deezerARL].length > 0; }

// Private adapters used by feature categories. Keeping the transport and
// response normalizers here avoids making those implementation details part
// of the public client contract.
- (void)wa_callMethod:(NSString *)method parameters:(NSDictionary *)parameters retry:(BOOL)retry completion:(void (^)(NSDictionary *, NSError *))completion { [self callMethod:method parameters:parameters retry:retry completion:completion]; }
- (void)wa_dispatchMain:(void (^)(void))block { waDeezerDispatchMain(block); }
- (NSString *)wa_rawIdentifier:(NSString *)identifier { return waDZRawIdentifier(identifier); }
- (NSString *)wa_string:(id)value { return waDZString(value); }
- (NSDictionary *)wa_playlistFromDictionary:(NSDictionary *)dictionary { return waDZPlaylist(dictionary); }
- (NSDictionary *)wa_songFromDictionary:(NSDictionary *)dictionary { return waDZSong(dictionary); }
- (NSError *)wa_responseError:(NSURLResponse *)response networkError:(NSError *)networkError message:(NSString *)message { return waDZResponseError(response, networkError, message); }
- (NSOperationQueue *)wa_parseQueue { return waDeezerParseQueue(); }

- (NSError *)errorWithMessage:(NSString *)message code:(NSInteger)code {
    return [NSError errorWithDomain:waDeezerErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message ?: @"Deezer request failed."}];
}

- (void)callMethod:(NSString *)method parameters:(NSDictionary *)parameters retry:(BOOL)retry completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *arl = [waKeychainStore deezerARL];
    if (!arl.length) { waDeezerDispatchMain(^{ if (completion) completion(nil, [self errorWithMessage:@"Connect a Deezer account first." code:401]); }); return; }
    waDZInstallARLCookie(arl);
    if (![method isEqualToString:@"deezer.getUserData"] && !self.csrfToken.length) {
        [self authorizeWithCompletion:^(NSDictionary *user, NSError *error) {
            if (error) { if (completion) completion(nil, error); return; }
            [self callMethod:method parameters:parameters retry:retry completion:completion];
        }];
        return;
    }

    NSMutableDictionary *query = [NSMutableDictionary dictionaryWithDictionary:@{ @"api_version": @"1.0", @"input": @"3", @"method": method ?: @"", @"cid": [NSString stringWithFormat:@"%u", arc4random_uniform(1000000000)] }];
    NSMutableDictionary *bodyParameters = [NSMutableDictionary dictionaryWithDictionary:parameters ?: @{}];
    NSString *gatewayInput = waDZString(bodyParameters[@"gateway_input"]);
    [bodyParameters removeObjectForKey:@"gateway_input"];
    if (gatewayInput.length) query[@"gateway_input"] = gatewayInput;
    query[@"api_token"] = self.csrfToken.length ? self.csrfToken : @"null";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in query) {
        NSString *value = [query[key] description];
        NSString *escaped = waDZQueryEscape(value);
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, escaped ?: @""]];
    }
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@?%@", waDeezerEndpoint, [parts componentsJoinedByString:@"&"]]];
    NSMutableURLRequest *request = waDeezerRequest(url, NSURLRequestUseProtocolCachePolicy);
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 30.0;
    request.HTTPShouldHandleCookies = YES;
    // Deezer's gateway accepts the token for read calls with text/plain, but
    // mutation calls validate it only for a JSON request, like the web client.
    [request setValue:@"application/json;charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://www.deezer.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://www.deezer.com/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:bodyParameters options:0 error:NULL];
    [NSURLConnection sendAsynchronousRequest:request queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSError *jsonError = nil;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError] : nil;
        if (networkError || !http || http.statusCode < 200 || http.statusCode >= 300 || jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            NSError *error = networkError ?: [self errorWithMessage:(jsonError ? @"Deezer returned invalid JSON." : @"Deezer gateway request failed.") code:http.statusCode ?: 500];
            if (completion) completion(nil, error);
            return;
        }
        NSDictionary *errorDictionary = [json[@"error"] isKindOfClass:[NSDictionary class]] ? json[@"error"] : nil;
        if (errorDictionary.count) {
            if (retry && (errorDictionary[@"VALID_TOKEN_REQUIRED"] || [errorDictionary[@"VALID_TOKEN_REQUIRED"] boolValue])) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.csrfToken = nil;
                    [self authorizeWithCompletion:^(NSDictionary *user, NSError *error) {
                        if (error) { if (completion) completion(nil, error); return; }
                        [self callMethod:method parameters:parameters retry:NO completion:completion];
                    }];
                });
                return;
            }
            NSString *message = waDZString(errorDictionary[@"MESSAGE"]) ?: waDZString(errorDictionary[@"message"]) ?: [errorDictionary description];
            [[waDebugLog sharedLog] log:@"Deezer gateway %@ rejected request (csrf length=%lu): %@", method, (unsigned long)self.csrfToken.length, message];
            if (completion) completion(nil, [self errorWithMessage:message code:403]);
            return;
        }
        if (networkError || ![json isKindOfClass:[NSDictionary class]]) {
            NSError *error = networkError ?: [self errorWithMessage:@"Deezer returned an invalid response." code:500];
            if (completion) completion(nil, error);
            return;
        }
        if (completion) completion(json, nil);
    }];
}

- (void)authorizeWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
    NSDictionary *cachedUser = nil;
    @synchronized (self) {
        if (self.csrfToken.length && self.userIdentifier.length && self.cachedUser) cachedUser = self.cachedUser;
    }
    if (cachedUser) {
        waDeezerDispatchMain(^{ if (completion) completion(cachedUser, nil); });
        return;
    }
    BOOL start = NO;
    @synchronized (self) {
        if (completion) [self.authorizationCompletions addObject:[completion copy]];
        if (!self.authorizationInFlight) { self.authorizationInFlight = YES; start = YES; }
    }
    if (!start) return;
    [self callMethod:@"deezer.getUserData" parameters:@{} retry:NO completion:^(NSDictionary *json, NSError *error) {
        NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : json;
        NSDictionary *user = [results[@"USER"] isKindOfClass:[NSDictionary class]] ? results[@"USER"] : ([results[@"user"] isKindOfClass:[NSDictionary class]] ? results[@"user"] : nil);
        NSString *identifier = waDZString(user[@"USER_ID"]) ?: waDZString(user[@"id"]);
        NSDictionary *normalizedUser = waDZUser(user);
        NSArray *resultsKeys = [results isKindOfClass:[NSDictionary class]] ? [[results allKeys] sortedArrayUsingSelector:@selector(compare:)] : @[];
        NSArray *userKeys = [user isKindOfClass:[NSDictionary class]] ? [[user allKeys] sortedArrayUsingSelector:@selector(compare:)] : @[];
        [[waDebugLog sharedLog] log:@"Deezer getUserData results keys: %@", [resultsKeys componentsJoinedByString:@","] ?: @""];
        [[waDebugLog sharedLog] log:@"Deezer getUserData USER keys: %@", [userKeys componentsJoinedByString:@","] ?: @""];
        NSMutableArray *avatarHits = [NSMutableArray array];
        for (NSString *candidate in @[@"PICTURE", @"PICTURE_SMALL", @"PICTURE_MEDIUM", @"PICTURE_BIG", @"PICTURE_XL", @"USER_PICTURE", @"USER_PICTURE_URL", @"picture", @"picture_small", @"picture_medium", @"picture_big", @"picture_xl"]) {
            NSString *hit = waDZString(user[candidate]);
            if (hit.length) [avatarHits addObject:[NSString stringWithFormat:@"%@=%@", candidate, hit.length > 120 ? [hit substringToIndex:120] : hit]];
        }
        NSMutableArray *countryHits = [NSMutableArray array];
        for (NSString *candidate in @[@"COUNTRY", @"country", @"COUNTRY_NAME", @"country_name", @"COUNTRY_CODE", @"country_code", @"USER_COUNTRY", @"COUNTRY_ID"]) {
            NSString *hit = waDZString(user[candidate]);
            if (hit.length) [countryHits addObject:[NSString stringWithFormat:@"%@=%@", candidate, hit]];
        }
        [[waDebugLog sharedLog] log:@"Deezer getUserData avatar candidates: %@", avatarHits.count ? [avatarHits componentsJoinedByString:@"; "] : @"(none)"];
        [[waDebugLog sharedLog] log:@"Deezer getUserData country candidates: %@", countryHits.count ? [countryHits componentsJoinedByString:@"; "] : @"(none)"];
        [[waDebugLog sharedLog] log:@"Deezer user normalized avatar=%@ country=%@", normalizedUser[@"avatar"] ?: @"(nil)", normalizedUser[@"country"] ?: @"(nil)"];
        waDeezerDispatchMain(^{
            NSArray *waiters = nil;
            NSDictionary *resultUser = nil;
            NSError *resultError = nil;
            @synchronized (self) {
                if (!error && identifier.length) {
                    self.csrfToken = waDZString(results[@"checkForm"]) ?: waDZString(results[@"CHECK_FORM"]);
                    self.userIdentifier = identifier;
                    self.userName = waDZString(user[@"BLOG_NAME"]) ?: waDZString(user[@"name"]);
                    self.favoritesPlaylistIdentifier = waDZString(user[@"LOVEDTRACKS_ID"]);
                    self.cachedUser = normalizedUser;
                    resultUser = normalizedUser;
                } else {
                    self.csrfToken = nil;
                    self.cachedUser = nil;
                    resultError = error ?: [self errorWithMessage:@"Deezer login could not be validated." code:401];
                }
                self.authorizationInFlight = NO;
                waiters = [self.authorizationCompletions copy];
                [self.authorizationCompletions removeAllObjects];
            }
            if (error || !identifier.length) {
                resultUser = nil;
            }
            [[waDebugLog sharedLog] log:@"Deezer authorization succeeded (csrf length=%lu, cookie count=%lu)", (unsigned long)self.csrfToken.length, (unsigned long)[[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:[NSURL URLWithString:@"https://www.deezer.com/"]].count];
            for (void (^waiter)(NSDictionary *, NSError *) in waiters) waiter(resultUser, resultError);
        });
    }];
}

- (void)authenticatePipeWithCompletion:(void (^)(NSError *))completion {
    BOOL start = NO;
    @synchronized (self) {
        if (completion) [self.pipeJWTCompletions addObject:[completion copy]];
        if (!self.pipeJWTInFlight) { self.pipeJWTInFlight = YES; start = YES; }
    }
    if (!start) return;
    NSString *arl = [waKeychainStore deezerARL];
    NSURL *authURL = [NSURL URLWithString:@"https://auth.deezer.com/login/arl?jo=p&rto=c&i=c"];
    NSMutableURLRequest *authRequest = waDeezerRequest(authURL, NSURLRequestReloadIgnoringLocalCacheData);
    authRequest.HTTPMethod = @"POST";
    [authRequest setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [authRequest setValue:[NSString stringWithFormat:@"arl=%@", arl ?: @""] forHTTPHeaderField:@"Cookie"];
    [NSURLConnection sendAsynchronousRequest:authRequest queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
        NSDictionary *authJSON = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSString *jwt = [authJSON isKindOfClass:[NSDictionary class]] ? authJSON[@"jwt"] : nil;
        NSError *error = networkError;
        if (!error && (![response isKindOfClass:[NSHTTPURLResponse class]] || [(NSHTTPURLResponse *)response statusCode] < 200 || [(NSHTTPURLResponse *)response statusCode] >= 300 || !jwt.length)) error = [self errorWithMessage:@"Deezer JWT authentication failed." code:401];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSArray *waiters = nil;
            @synchronized (self) {
                if (!error) { self.pipeJWT = jwt; waDZInstallARLCookie(arl); }
                else self.pipeJWT = nil;
                self.pipeJWTInFlight = NO;
                waiters = [self.pipeJWTCompletions copy];
                [self.pipeJWTCompletions removeAllObjects];
            }
            for (void (^waiter)(NSError *) in waiters) waiter(error);
        });
    }];
}

- (void)setARL:(NSString *)arl completion:(void (^)(NSError *))completion {
    NSString *value = [arl stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!value.length || ![waKeychainStore setDeezerARL:value]) { waDeezerDispatchMain(^{ if (completion) completion([self errorWithMessage:@"Unable to save the Deezer session." code:1]); }); return; }
    [waKeychainStore clearToken];
    waDZInstallARLCookie(value);
    self.csrfToken = nil;
    self.cachedUser = nil;
    [self authorizeWithCompletion:^(NSDictionary *user, NSError *error) {
        if (error) { [waKeychainStore clearDeezerARL]; self.csrfToken = nil; }
        else [[NSNotificationCenter defaultCenter] postNotificationName:waDeezerAuthenticationDidChangeNotification object:self];
        if (completion) completion(error);
    }];
}

- (void)logout {
    [waKeychainStore clearDeezerARL];
    [waKeychainStore clearToken];
    self.csrfToken = nil;
    self.cachedUser = nil;
    self.userIdentifier = nil;
    self.userName = nil;
    self.favoritesPlaylistIdentifier = nil;
    waDZClearCookies();
    [[NSNotificationCenter defaultCenter] postNotificationName:waDeezerAuthenticationDidChangeNotification object:self];
}

- (void)userWithCompletion:(void (^)(NSDictionary *, NSError *))completion { [self authorizeWithCompletion:^(NSDictionary *user, NSError *error) { if (completion) completion(user, error); }]; }

- (void)hydratePublicSongs:(NSArray *)items identifiers:(NSArray *)identifiers completion:(void (^)(NSArray *))completion {
    if (!identifiers.count) { waDeezerDispatchMain(^{ if (completion) completion(items ?: @[]); }); return; }
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary *hydrated = [NSMutableDictionary dictionary];
    __block NSUInteger failures = 0;
    for (NSString *identifier in identifiers) {
        if (!identifier.length) continue;
        dispatch_group_enter(group);
        NSString *escapedIdentifier = [identifier stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/track/%@", escapedIdentifier ?: identifier]];
        NSURLRequest *request = waDeezerRequest(url, NSURLRequestUseProtocolCachePolicy);
        [NSURLConnection sendAsynchronousRequest:request queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *error) {
            NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            if (!error && [json isKindOfClass:[NSDictionary class]] && ![json[@"error"] isKindOfClass:[NSDictionary class]] && waDZString(json[@"title"]).length) {
                @synchronized (hydrated) { hydrated[identifier] = json; }
            } else {
                @synchronized (hydrated) { failures += 1; }
            }
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, waDeezerParseDispatchQueue(), ^{
        NSMutableArray *merged = [NSMutableArray arrayWithCapacity:items.count];
        for (NSDictionary *item in items) {
            NSString *identifier = waDZString(item[@"identifier"]) ?: waDZString(item[@"id"]);
            NSDictionary *json = identifier.length ? hydrated[identifier] : nil;
            [merged addObject:json ? waDZSong(json) : item];
        }
        [[waDebugLog sharedLog] log:@"Deezer public song metadata: returned=%lu failed=%lu", (unsigned long)hydrated.count, (unsigned long)failures];
        waDeezerDispatchMain(^{ if (completion) completion(merged); });
    });
}

- (void)profileTab:(NSString *)tab completion:(void (^)(NSArray *, NSError *))completion {
    // Profile requests need user_id from authenticated user data. Building
    // parameters before authorizeWithCompletion leaves an empty user_id on
    // cold start, so albums and artists silently return no sections.
    [self authorizeWithCompletion:^(NSDictionary *user, NSError *authorizationError) {
        (void)user;
        if (authorizationError || !self.userIdentifier.length) {
            waDeezerDispatchMain(^{ if (completion) completion(@[], authorizationError); });
            return;
        }
        NSDictionary *parameters = @{ @"nb": @100, @"tab": tab ?: @"", @"user_id": self.userIdentifier };
        [self callMethod:@"deezer.pageProfile" parameters:parameters retry:YES completion:^(NSDictionary *json, NSError *error) {
            NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : @{};
            NSDictionary *tabData = [results[@"TAB"] isKindOfClass:[NSDictionary class]] ? results[@"TAB"] : @{};
            NSDictionary *section = [tabData[tab] isKindOfClass:[NSDictionary class]] ? tabData[tab] : nil;
            NSArray *data = [section[@"data"] isKindOfClass:[NSArray class]] ? section[@"data"] : ([results[tab] isKindOfClass:[NSArray class]] ? results[tab] : @[]);
            NSMutableArray *items = [NSMutableArray array];
            for (NSDictionary *object in data) {
                NSDictionary *normalized = [tab isEqualToString:@"albums"] ? waDZAlbum(object) : ([tab isEqualToString:@"artists"] ? waDZArtist(object) : waDZSong(object));
                if (normalized) {
                    if ([tab isEqualToString:@"albums"] || [tab isEqualToString:@"artists"]) {
                        NSMutableDictionary *likedItem = [normalized mutableCopy];
                        likedItem[@"liked"] = @YES;
                        normalized = likedItem;
                    }
                    [items addObject:normalized];
                }
            }
            waDeezerDispatchMain(^{ if (completion) completion(items, error); });
        }];
    }];
}

- (void)likedSongsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    // getAllFeedbacks is the endpoint that has already proven compatible with
    // this Deezer account; song.getFavoriteIds is not available on every GW
    // account/session. Use it only for the IDs, then hydrate the full tracks.
    [self callMethod:@"user.getAllFeedbacks" parameters:@{ @"checksums": [NSNull null] } retry:YES completion:^(NSDictionary *json, NSError *error) {
        NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : @{};
        id favorites = results[@"FAVORITES"] ?: results[@"favorites"] ?: results;
        id songs = [favorites isKindOfClass:[NSDictionary class]] ? (((NSDictionary *)favorites)[@"SONGS"] ?: ((NSDictionary *)favorites)[@"songs"] ?: favorites) : favorites;
        NSArray *data = waDZArrayFromContainer(songs);
        NSMutableArray *items = [NSMutableArray array];
        NSMutableArray *identifiers = [NSMutableArray array];
        for (NSDictionary *object in data) {
            NSDictionary *item = waDZSong(object);
            if (item) [items addObject:item];
            NSDictionary *details = waDZSongDetails(object);
            NSString *identifier = waDZFirstValue(details ? @[object, details] : @[object], @[@"SNG_ID", @"SONG_ID", @"TRACK_ID", @"id", @"ID"]);
            if (identifier.length) [identifiers addObject:identifier];
        }
        [[waDebugLog sharedLog] log:@"Deezer favorite IDs: raw=%lu normalized=%lu", (unsigned long)data.count, (unsigned long)items.count];
        if (identifiers.count && !error) {
            [self callMethod:@"song.getListData" parameters:@{ @"SNG_IDS": identifiers } retry:YES completion:^(NSDictionary *hydratedJSON, NSError *hydrationError) {
                NSDictionary *hydratedResults = [hydratedJSON[@"results"] isKindOfClass:[NSDictionary class]] ? hydratedJSON[@"results"] : @{};
                NSArray *hydratedData = waDZArrayFromContainer(hydratedResults);
                if (hydratedData.count) {
                    [items removeAllObjects];
                    for (NSDictionary *object in hydratedData) { NSDictionary *item = waDZSong(object); if (item) [items addObject:item]; }
                }
                [[waDebugLog sharedLog] log:@"Deezer private song metadata: returned=%lu normalized=%lu error=%@", (unsigned long)hydratedData.count, (unsigned long)items.count, hydrationError.localizedDescription ?: @"none"];
                if (hydrationError && !hydratedData.count) {
                    [self hydratePublicSongs:items identifiers:identifiers completion:^(NSArray *publicItems) {
                        if (completion) completion(waDZOrderNewestFirst(publicItems, identifiers), error);
                    }];
                } else waDeezerDispatchMain(^{ if (completion) completion(waDZOrderNewestFirst(items, identifiers), hydrationError ?: error); });
            }];
            return;
        }
        waDeezerDispatchMain(^{ if (completion) completion(waDZOrderNewestFirst(items, identifiers), error); });
    }];
}

- (void)likedAlbumsWithCompletion:(void (^)(NSArray *, NSError *))completion { [self profileTab:@"albums" completion:completion]; }
- (void)likedArtistsWithCompletion:(void (^)(NSArray *, NSError *))completion { [self profileTab:@"artists" completion:completion]; }

- (void)wa_removeSearchTask:(id)task {
    if (!task) return;
    @synchronized (self) { [_searchTasks removeObject:task]; }
}

- (void)cancelSearchRequests {
    NSArray *tasks = nil;
    @synchronized (self) {
        tasks = [_searchTasks allObjects];
        [_searchTasks removeAllObjects];
    }
    // Cancelled connections never call back; their completions are dropped.
    for (waDZSearchTask *task in tasks) [task.connection cancel];
}

- (void)searchQuery:(NSString *)query type:(NSString *)type completion:(void (^)(NSArray *, NSError *))completion {
    [self searchQuery:query type:type limit:50 index:0 completion:completion];
}

- (void)searchQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit completion:(void (^)(NSArray *, NSError *))completion {
    [self searchQuery:query type:type limit:limit index:0 completion:completion];
}

- (void)searchQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit index:(NSUInteger)index completion:(void (^)(NSArray *, NSError *))completion {
    [self searchQuery:query type:type limit:limit index:index strict:NO completion:completion];
}

- (void)searchQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit index:(NSUInteger)index strict:(BOOL)strict completion:(void (^)(NSArray *, NSError *))completion {
    if (![NSThread isMainThread]) {
        __weak waDeezerClient *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf searchQuery:query type:type limit:limit index:index strict:strict completion:completion]; });
        return;
    }
    NSString *normalizedType = [[type ?: @"song" lowercaseString] copy];
    NSString *endpointType = [normalizedType isEqualToString:@"song"] ? @"track" : normalizedType;
    NSString *escapedQuery = waDZQueryEscape(query ?: @"");
    NSUInteger clampedLimit = MIN(MAX(limit, (NSUInteger)1), (NSUInteger)100);
    NSString *urlString = [NSString stringWithFormat:@"https://api.deezer.com/search/%@?q=%@&limit=%lu&index=%lu&order=RANKING%@",
                           endpointType, escapedQuery ?: @"", (unsigned long)clampedLimit, (unsigned long)index,
                           strict ? @"&strict=on" : @""];
    NSURL *url = [NSURL URLWithString:urlString];
    NSString *cacheKey = waDZSearchCacheKey(normalizedType, query, clampedLimit, index, strict);
    NSDictionary *cached = [self.searchCache objectForKey:cacheKey];
    if ([cached isKindOfClass:[NSDictionary class]]) {
        NSArray *cachedItems = cached[@"items"];
        NSDate *cachedDate = cached[@"date"];
        if ([cachedItems isKindOfClass:[NSArray class]] && [cachedDate isKindOfClass:[NSDate class]] &&
            [[NSDate date] timeIntervalSinceDate:cachedDate] < waDZSearchCacheTTL) {
            NSArray *hit = [cachedItems copy];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(hit, nil); });
            return;
        } else if (cached) {
            [self.searchCache removeObjectForKey:cacheKey];
        }
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@|%lu|%lu|%d", normalizedType, query ?: @"", (unsigned long)clampedLimit, (unsigned long)index, strict ? 1 : 0];
    waDZSearchTask *task = nil;
    @synchronized (self) {
        for (waDZSearchTask *existing in _searchTasks) {
            if ([existing.coalescingKey isEqualToString:key]) { task = existing; break; }
        }
        if (task) {
            [task addCompletion:completion];
            return;
        }
        task = [[waDZSearchTask alloc] init];
        task.coalescingKey = key;
        task.cacheKey = cacheKey;
        task.normalizedType = normalizedType;
        task.client = self;
        [task addCompletion:completion];
        [_searchTasks addObject:task];
    }
    task.connection = [[NSURLConnection alloc] initWithRequest:waDeezerRequest(url, NSURLRequestUseProtocolCachePolicy) delegate:task startImmediately:YES];
    if (!task.connection) {
        [[waDebugLog sharedLog] log:@"Deezer search could not start: %@", key];
        [task completeWithItems:nil error:[self errorWithMessage:@"Deezer search failed." code:500]];
    } else {
        [[waDebugLog sharedLog] log:@"Deezer search started: %@", key];
    }
}

- (void)artistAlbumsWithID:(NSString *)artistID completion:(void (^)(NSArray *, NSError *))completion {
    // Official discography endpoint: the album search index omits famous
    // albums (see waListViewController mergeArtistDiscographyForArtist).
    if (!artistID.length) { waDeezerDispatchMain(^{ if (completion) completion(@[], nil); }); return; }
    NSString *cleanID = [artistID hasPrefix:@"deezer:"] ? [artistID substringFromIndex:7] : artistID;
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/artist/%@/albums?limit=100", waDZQueryEscape(cleanID ?: @"")]];
    [NSURLConnection sendAsynchronousRequest:waDeezerRequest(url, NSURLRequestUseProtocolCachePolicy) queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSError *error = networkError;
        if (!error && (!http || http.statusCode < 200 || http.statusCode >= 300)) error = [self errorWithMessage:@"Deezer discography failed." code:http.statusCode ?: 500];
        if (!error && [json[@"error"] isKindOfClass:[NSDictionary class]]) error = [self errorWithMessage:waDZString(json[@"error"][@"message"]) ?: @"Deezer discography failed." code:403];
        NSArray *dataArray = [json[@"data"] isKindOfClass:[NSArray class]] ? json[@"data"] : @[];
        NSMutableArray *items = [NSMutableArray array];
        for (NSDictionary *object in dataArray) {
            NSDictionary *normalized = waDZAlbum(object);
            if (normalized) [items addObject:normalized];
        }
        waDeezerDispatchMain(^{ if (completion) completion(items, error); });
    }];
}

- (void)flowConfigWithIdentifier:(NSString *)identifier completion:(void (^)(NSArray *, NSError *))completion {
    if (!identifier.length || [identifier isEqualToString:@"default"]) { [self flowWithCompletion:completion]; return; }
    if (!self.pipeJWT.length) {
        [self flowConfigsWithCompletion:^(NSArray *configs, NSError *error) {
            if (error) { if (completion) completion(@[], error); return; }
            [self flowConfigWithIdentifier:identifier completion:completion];
        }];
        return;
    }
    NSString *query = @"query GetFlowConfigTracks($flowConfigId:String!){flowConfig(flowConfigId:$flowConfigId){tracks{track{id title duration isExplicit isFavorite album{id displayTitle cover{urls(pictureRequest:{width:320,height:320})}} contributors(first:1,roles:[MAIN]){edges{node{... on Artist{id name}}}}}}}}";
    NSDictionary *body = @{ @"query": query, @"operationName": @"GetFlowConfigTracks", @"variables": @{ @"flowConfigId": identifier } };
    NSMutableURLRequest *request = waDeezerRequest([NSURL URLWithString:@"https://pipe.deezer.com/api"], NSURLRequestUseProtocolCachePolicy);
    request.HTTPMethod = @"POST";
    request.HTTPShouldHandleCookies = YES;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.pipeJWT] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"https://www.deezer.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://www.deezer.com/" forHTTPHeaderField:@"Referer"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    [NSURLConnection sendAsynchronousRequest:request queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSDictionary *config = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"][@"flowConfig"] : nil;
        NSArray *entries = [config[@"tracks"] isKindOfClass:[NSArray class]] ? config[@"tracks"] : @[];
        NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:entries.count];
        for (NSDictionary *entry in entries) {
            NSDictionary *track = [entry[@"track"] isKindOfClass:[NSDictionary class]] ? entry[@"track"] : nil;
            if (!track) continue;
            NSMutableDictionary *raw = [track mutableCopy];
            NSDictionary *album = [track[@"album"] isKindOfClass:[NSDictionary class]] ? track[@"album"] : nil;
            raw[@"ALB_ID"] = album[@"id"] ?: @"";
            raw[@"ALB_TITLE"] = album[@"displayTitle"] ?: @"";
            NSDictionary *cover = [album[@"cover"] isKindOfClass:[NSDictionary class]] ? album[@"cover"] : nil;
            NSArray *urls = [cover[@"urls"] isKindOfClass:[NSArray class]] ? cover[@"urls"] : @[];
            if (urls.count) raw[@"ALB_PICTURE_XL"] = [urls[0] isKindOfClass:[NSDictionary class]] ? urls[0][@"url"] : urls[0];
            NSDictionary *edge = [track[@"contributors"][@"edges"] isKindOfClass:[NSArray class]] && [track[@"contributors"][@"edges"] count] ? track[@"contributors"][@"edges"][0] : nil;
            NSDictionary *artist = [edge[@"node"] isKindOfClass:[NSDictionary class]] ? edge[@"node"] : nil;
            raw[@"ART_NAME"] = artist[@"name"] ?: @"";
            NSDictionary *normalized = waDZSong(raw);
            if (normalized) [tracks addObject:normalized];
        }
        NSError *error = networkError;
        if (!error && [json[@"errors"] isKindOfClass:[NSArray class]] && [json[@"errors"] count]) error = [self errorWithMessage:json[@"errors"][0][@"message"] ?: @"Unable to load Flow." code:500];
        waDeezerDispatchMain(^{ if (completion) completion(tracks, error); });
    }];
}

- (void)flowConfigsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    if (!self.isAuthenticated) {
        waDeezerDispatchMain(^{ if (completion) completion(@[], [self errorWithMessage:@"Connect a Deezer account first." code:401]); });
        return;
    }
    if (!self.pipeJWT.length) {
        [self authenticatePipeWithCompletion:^(NSError *error) {
            if (error) { if (completion) completion(@[], error); return; }
            [self flowConfigsWithCompletion:completion];
        }];
        return;
    }
    waDZInstallARLCookie([waKeychainStore deezerARL]);
    NSString *query = @"query GetFlowConfigs($moodsFirst:Int=12,$genresFirst:Int=12){me{flowConfigs{moods(first:$moodsFirst){edges{node{id title visuals{hardwareSquareIcon{id urls(uiAssetRequest:{width:264,height:264})}}}}}genres(first:$genresFirst){edges{node{id title visuals{hardwareSquareIcon{id urls(uiAssetRequest:{width:264,height:264})}}}}}}}}";
    NSDictionary *body = @{ @"query": query, @"operationName": @"GetFlowConfigs", @"variables": @{ @"moodsFirst": @12, @"genresFirst": @12 } };
    NSMutableURLRequest *request = waDeezerRequest([NSURL URLWithString:@"https://pipe.deezer.com/api"], NSURLRequestUseProtocolCachePolicy);
    request.HTTPMethod = @"POST";
    request.HTTPShouldHandleCookies = YES;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.pipeJWT] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"https://www.deezer.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://www.deezer.com/" forHTTPHeaderField:@"Referer"];
    [request setValue:@"Wave/1.0" forHTTPHeaderField:@"User-Agent"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
     [NSURLConnection sendAsynchronousRequest:request queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
         NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
         NSError *responseError = waDZResponseError(response, networkError, @"Unable to load Flow configurations.");
         if (!responseError && ![json isKindOfClass:[NSDictionary class]]) responseError = [self errorWithMessage:@"Deezer returned invalid Flow configuration data." code:500];
         if (responseError) { waDeezerDispatchMain(^{ if (completion) completion(@[], responseError); }); return; }
         NSMutableArray *configs = [NSMutableArray array];
        NSDictionary *root = [json[@"data"] isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
        NSDictionary *flowConfigs = [root[@"me"] isKindOfClass:[NSDictionary class]] ? root[@"me"][@"flowConfigs"] : nil;
        for (NSString *kind in @[@"moods", @"genres"]) {
            NSArray *edges = [flowConfigs[kind][@"edges"] isKindOfClass:[NSArray class]] ? flowConfigs[kind][@"edges"] : @[];
            for (NSDictionary *edge in edges) {
                NSDictionary *node = [edge[@"node"] isKindOfClass:[NSDictionary class]] ? edge[@"node"] : nil;
                if (!node) continue;
                NSString *identifier = waDZString(node[@"id"]);
                NSString *title = waDZString(node[@"title"]);
                NSDictionary *icon = node[@"visuals"][@"hardwareSquareIcon"];
                NSArray *urls = [icon[@"urls"] isKindOfClass:[NSArray class]] ? icon[@"urls"] : @[];
                id firstURL = urls.count ? urls[0] : nil;
                NSString *picture = [firstURL isKindOfClass:[NSDictionary class]] ? waDZString(firstURL[@"url"]) : waDZString(firstURL);
                if ([picture rangeOfString:@"cdn-images.dzcdn.net"].location != NSNotFound) picture = [picture stringByReplacingOccurrencesOfString:@"cdn-images.dzcdn.net" withString:@"e-cdns-images.dzcdn.net"];
                if (identifier.length && title.length) [configs addObject:@{@"id": identifier, @"identifier": identifier, @"title": title, @"name": title, @"subtitle": [kind capitalizedString], @"thumbnailURL": picture ?: @"", @"type": @3, @"homeKind": @"flow_mood", @"flowConfigID": identifier}];
            }
        }
         waDeezerDispatchMain(^{ if (completion) completion(configs, nil); });
    }];
}

- (void)flowWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [self callMethod:@"radio.getUserRadio" parameters:@{ @"user_id": self.userIdentifier ?: @"" } retry:YES completion:^(NSDictionary *json, NSError *error) {
        NSDictionary *resultsDictionary = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : nil;
        id container = resultsDictionary ?: json[@"results"];
        NSArray *rawTracks = waDZArrayFromContainer(container);
        NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:rawTracks.count];
        for (NSDictionary *rawTrack in rawTracks) {
            NSDictionary *track = waDZSong(rawTrack);
            if (track) [tracks addObject:track];
        }
        waDeezerDispatchMain(^{ if (completion) completion(tracks, error); });
    }];
}

- (void)homeWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
    NSDictionary *support = @{ @"filterable-grid": @[@"flow"],
                               @"grid": @[@"album", @"artist", @"channel", @"flow", @"playlist", @"radio", @"show", @"smarttracklist", @"track", @"user"],
                               @"horizontal-grid": @[@"album", @"artist", @"channel", @"flow", @"playlist", @"radio", @"show", @"smarttracklist", @"track", @"user"],
                               @"large-card": @[@"album", @"playlist", @"show", @"video-link"],
                               @"ads": @[] };
    NSDictionary *gateway = @{ @"PAGE": @"home", @"VERSION": @"2.5", @"SUPPORT": support, @"LANG": @"en", @"OPTIONS": @[] };
    NSData *gatewayData = [NSJSONSerialization dataWithJSONObject:gateway options:0 error:NULL];
    NSString *gatewayInput = [[NSString alloc] initWithData:gatewayData encoding:NSUTF8StringEncoding];
    [self callMethod:@"page.get" parameters:@{ @"gateway_input": gatewayInput ?: @"" } retry:YES completion:^(NSDictionary *json, NSError *error) {
        NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : @{};
        NSArray *sections = [results[@"sections"] isKindOfClass:[NSArray class]] ? results[@"sections"] : @[];
        NSMutableArray *normalizedSections = [NSMutableArray array];
        for (NSDictionary *section in sections) {
            if (![section isKindOfClass:[NSDictionary class]]) continue;
            NSArray *objects = [section[@"items"] isKindOfClass:[NSArray class]] ? section[@"items"] : ([section[@"data"] isKindOfClass:[NSArray class]] ? section[@"data"] : @[]);
            NSMutableArray *items = [NSMutableArray array];
            for (NSDictionary *object in objects) { NSDictionary *item = waDZHomeItem(object); if (item) [items addObject:item]; }
            if (!items.count) continue;
            NSString *title = waDZString(section[@"title"]) ?: waDZString(section[@"label"]) ?: waDZString(section[@"name"]);
            NSString *subtitle = waDZString(section[@"subtitle"]) ?: waDZString(section[@"description"]);
            NSString *layoutValue = waDZString(section[@"layout"]) ?: waDZString(section[@"display_type"]) ?: @"square";
            NSString *layout = [layoutValue lowercaseString];
            NSString *titleKey = [title lowercaseString];
            if ([titleKey rangeOfString:@"flow"].location != NSNotFound || [titleKey rangeOfString:@"mood"].location != NSNotFound) layout = @"circle";
            else if ([titleKey rangeOfString:@"mix"].location != NSNotFound) layout = @"song-list";
            else if ([titleKey rangeOfString:@"explore"].location != NSNotFound) layout = @"explore-grid";
            [normalizedSections addObject:@{ @"title": title ?: @"", @"subtitle": subtitle ?: @"", @"layout": layout, @"items": items }];
        }
        NSDictionary *home = @{ @"sections": normalizedSections, @"user": waDZUser([results[@"USER"] isKindOfClass:[NSDictionary class]] ? results[@"USER"] : @{}) };
        waDeezerDispatchMain(^{ if (completion) completion(home, error); });
    }];
}

- (void)albumWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion {
    [self callMethod:@"deezer.pageAlbum" parameters:@{ @"alb_id": waDZRawIdentifier(identifier) ?: @"", @"header": @YES, @"lang": @"en" } retry:YES completion:^(NSDictionary *json, NSError *error) {
        NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : @{};
        NSDictionary *data = [results[@"DATA"] isKindOfClass:[NSDictionary class]] ? results[@"DATA"] : @{};
        NSArray *tracks = [results[@"SONGS"] isKindOfClass:[NSDictionary class]] ? waDZArrayFromContainer(results[@"SONGS"]) : @[];
        NSMutableDictionary *album = [NSMutableDictionary dictionaryWithDictionary:waDZAlbum(data) ?: @{}];
        album[@"id"] = waDZString(data[@"ALB_ID"]) ?: waDZRawIdentifier(identifier) ?: @"";
        album[@"artist"] = album[@"artistName"] ?: @"";
        NSMutableArray *normalizedTracks = [NSMutableArray arrayWithCapacity:tracks.count];
        for (NSDictionary *track in tracks) { NSDictionary *item = waDZSong(track); if (item) [normalizedTracks addObject:item]; }
        album[@"tracks"] = normalizedTracks;
        album[@"songs"] = normalizedTracks;
        if (error || !data.count || !normalizedTracks.count) {
            [self publicAlbumWithIdentifier:identifier completion:^(NSDictionary *publicAlbum, NSError *publicError) {
                if (publicAlbum) waDeezerDispatchMain(^{ if (completion) completion(publicAlbum, nil); });
                else waDeezerDispatchMain(^{ if (completion) completion(album, error ?: publicError); });
            }];
        } else waDeezerDispatchMain(^{ if (completion) completion(album, nil); });
    }];
}

- (void)publicAlbumWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *rawIdentifier = waDZRawIdentifier(identifier) ?: @"";
    NSString *escaped = [rawIdentifier stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/album/%@", escaped ?: rawIdentifier]];
     [NSURLConnection sendAsynchronousRequest:waDeezerRequest(url, NSURLRequestUseProtocolCachePolicy) queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
         NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
             NSError *responseError = waDZResponseError(response, networkError, @"Unable to load Deezer album.");
             if (responseError || ![json isKindOfClass:[NSDictionary class]] || [json[@"error"] isKindOfClass:[NSDictionary class]]) { waDeezerDispatchMain(^{ if (completion) completion(nil, responseError ?: [self errorWithMessage:@"Unable to load Deezer album." code:404]); }); return; }
        NSMutableDictionary *album = [NSMutableDictionary dictionaryWithDictionary:waDZAlbum(json) ?: @{}];
        NSArray *embeddedTracks = [json[@"tracks"] isKindOfClass:[NSDictionary class]] ? waDZArrayFromContainer(json[@"tracks"]) : @[];
        NSURL *tracksURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/album/%@/tracks?limit=100", escaped ?: rawIdentifier]];
        [NSURLConnection sendAsynchronousRequest:waDeezerRequest(tracksURL, NSURLRequestUseProtocolCachePolicy) queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *tracksResponse, NSData *tracksData, NSError *tracksError) {
            NSDictionary *tracksJSON = tracksData.length ? [NSJSONSerialization JSONObjectWithData:tracksData options:0 error:NULL] : nil;
            NSArray *tracks = [tracksJSON[@"data"] isKindOfClass:[NSArray class]] && [tracksJSON[@"data"] count] ? tracksJSON[@"data"] : embeddedTracks;
            NSMutableArray *normalizedTracks = [NSMutableArray arrayWithCapacity:tracks.count];
            for (NSDictionary *track in tracks) { NSDictionary *item = waDZSong(track); if (item) [normalizedTracks addObject:item]; }
            album[@"tracks"] = normalizedTracks; album[@"songs"] = normalizedTracks; album[@"artist"] = album[@"artistName"] ?: @"";
            (void)tracksResponse; (void)tracksError;
            waDeezerDispatchMain(^{ if (completion) completion(album, nil); });
        }];
    }];
}

- (void)publicArtistWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *rawIdentifier = waDZRawIdentifier(identifier) ?: @"";
    NSString *cacheKey = rawIdentifier.length ? [NSString stringWithFormat:@"artist:%@", rawIdentifier] : nil;
    NSDictionary *cachedEntry = cacheKey ? [self.artistCatalogCache objectForKey:cacheKey] : nil;
    NSDate *cachedDate = cachedEntry[@"date"];
    NSDictionary *cachedArtist = cachedEntry[@"artist"];
    if ([cachedDate isKindOfClass:[NSDate class]] && [cachedArtist isKindOfClass:[NSDictionary class]] && [[NSDate date] timeIntervalSinceDate:cachedDate] < 600.0) {
        waDeezerDispatchMain(^{ if (completion) completion(cachedArtist, nil); });
        return;
    }
    NSString *escaped = [rawIdentifier stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSURL *artistURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/artist/%@", escaped ?: rawIdentifier]];
    NSURL *topURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/artist/%@/top?limit=100", escaped ?: rawIdentifier]];
    NSURL *albumsURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/artist/%@/albums?limit=100&index=0", escaped ?: rawIdentifier]];
    dispatch_group_t group = dispatch_group_create();
    __block NSDictionary *profile = nil;
    __block NSDictionary *top = nil;
    __block NSDictionary *albumsJSON = nil;
    __block NSError *requestError = nil;
    NSObject *responseLock = [[NSObject alloc] init];
    NSArray *urls = @[artistURL, topURL];
    for (NSUInteger index = 0; index < urls.count; index++) {
        dispatch_group_enter(group);
         [NSURLConnection sendAsynchronousRequest:waDeezerRequest(urls[index], NSURLRequestUseProtocolCachePolicy) queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
             NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
             @synchronized (responseLock) {
                 NSError *responseError = waDZResponseError(response, networkError, @"Unable to load Deezer artist.");
                 if (responseError && !requestError) requestError = responseError;
                if ([json isKindOfClass:[NSDictionary class]] && [json[@"error"] isKindOfClass:[NSDictionary class]] && !requestError) requestError = [self errorWithMessage:@"Unable to load Deezer artist." code:404];
                if (index == 0) profile = json;
                else if (index == 1) top = json;
                else albumsJSON = json;
            }
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_enter(group);
    NSMutableArray *allAlbums = [NSMutableArray array];
    waDZFetchArtistAlbumsPage(albumsURL, 0, allAlbums, [NSMutableSet set], ^(NSError *error) {
        @synchronized (responseLock) {
            albumsJSON = @{ @"data": allAlbums };
            if (error && !requestError) requestError = error;
        }
        dispatch_group_leave(group);
    });
    dispatch_group_notify(group, waDeezerParseDispatchQueue(), ^{
        NSDictionary *profileSnapshot = nil;
        NSDictionary *topSnapshot = nil;
        NSDictionary *albumsSnapshot = nil;
        NSError *errorSnapshot = nil;
        @synchronized (responseLock) {
            profileSnapshot = profile;
            topSnapshot = top;
            albumsSnapshot = albumsJSON;
            errorSnapshot = requestError;
        }
        NSMutableDictionary *artist = [NSMutableDictionary dictionaryWithDictionary:waDZArtist(profileSnapshot) ?: @{}];
        artist[@"id"] = waDZString(profileSnapshot[@"id"]) ?: rawIdentifier;
        artist[@"name"] = artist[@"title"] ?: @"Artist";
        NSArray *trackObjects = [topSnapshot[@"data"] isKindOfClass:[NSArray class]] ? topSnapshot[@"data"] : @[];
        NSArray *albumObjects = [albumsSnapshot[@"data"] isKindOfClass:[NSArray class]] ? albumsSnapshot[@"data"] : @[];
        NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:trackObjects.count];
        for (NSDictionary *object in trackObjects) { NSDictionary *item = waDZSong(object); if (item) [tracks addObject:item]; }
        NSMutableArray *albums = [NSMutableArray arrayWithCapacity:albumObjects.count];
        for (NSDictionary *object in albumObjects) { NSDictionary *item = waDZAlbum(object); if (item) [albums addObject:item]; }
        artist[@"tracks"] = tracks; artist[@"songs"] = tracks; artist[@"albums"] = albums; artist[@"allAlbums"] = albums;
        [artist addEntriesFromDictionary:waDZAlbumSections(albums)];
        artist[@"fans"] = profileSnapshot[@"nb_fan"] ?: profileSnapshot[@"fans"] ?: @0;
        artist[@"albumCount"] = profileSnapshot[@"nb_album"] ?: @0;
        artist[@"link"] = waDZString(profileSnapshot[@"link"]) ?: @"";
        if (profileSnapshot.count && (tracks.count || albums.count)) {
            if (cacheKey.length) [self.artistCatalogCache setObject:@{ @"artist": artist, @"date": [NSDate date] } forKey:cacheKey cost:MAX((NSUInteger)1, albums.count * 256)];
            waDeezerDispatchMain(^{ if (completion) completion(artist, nil); });
        }
        else waDeezerDispatchMain(^{ if (completion) completion(nil, errorSnapshot ?: [self errorWithMessage:@"Unable to load Deezer artist." code:404]); });
    });
}

- (void)artistWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion {
    [self callMethod:@"deezer.pageArtist" parameters:@{ @"art_id": waDZRawIdentifier(identifier) ?: @"", @"lang": @"en", @"header": @YES } retry:YES completion:^(NSDictionary *json, NSError *error) {
        NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : @{};
        NSDictionary *data = [results[@"DATA"] isKindOfClass:[NSDictionary class]] ? results[@"DATA"] : @{};
        NSMutableDictionary *artist = [NSMutableDictionary dictionaryWithDictionary:waDZArtist(data) ?: @{}];
        artist[@"id"] = waDZString(data[@"ART_ID"]) ?: waDZRawIdentifier(identifier) ?: @"";
        artist[@"name"] = artist[@"title"] ?: @"Artist";
        NSMutableArray *tracks = [NSMutableArray array];
        for (NSDictionary *track in @[results[@"TOP"], results[@"HIGHLIGHT"]]) for (NSDictionary *object in waDZArrayFromContainer(track)) { NSDictionary *item = waDZSong(object); if (item) [tracks addObject:item]; }
        NSMutableArray *albums = [NSMutableArray array];
        for (NSDictionary *object in waDZArtistReleaseObjects(results)) { NSDictionary *item = waDZAlbum(object); if (item) [albums addObject:item]; }
        artist[@"tracks"] = tracks; artist[@"songs"] = tracks; artist[@"albums"] = albums; artist[@"allAlbums"] = albums;
        [artist addEntriesFromDictionary:waDZAlbumSections(albums)];
        artist[@"fans"] = data[@"NB_FAN"] ?: @0;
        artist[@"albumCount"] = data[@"NB_ALBUM"] ?: @0;
        if (error || !data.count || (!tracks.count && !albums.count)) {
            [self publicArtistWithIdentifier:identifier completion:^(NSDictionary *publicArtist, NSError *publicError) {
                if (publicArtist) waDeezerDispatchMain(^{ if (completion) completion(publicArtist, nil); });
                else waDeezerDispatchMain(^{ if (completion) completion(artist, error ?: publicError); });
            }];
        } else {
            // pageArtist can expose only a featured subset. Merge it with
            // the fully paginated public discography before rendering.
            [self publicArtistWithIdentifier:identifier completion:^(NSDictionary *publicArtist, NSError *publicError) {
                if (publicArtist) {
                    NSMutableArray *merged = [NSMutableArray array];
                    NSMutableSet *seen = [NSMutableSet set];
                    for (NSArray *source in @[artist[@"allAlbums"] ?: @[], publicArtist[@"allAlbums"] ?: @[]]) {
                        for (NSDictionary *album in source) {
                            NSString *key = waDZRawIdentifier(waDZString(album[@"id"]) ?: waDZString(album[@"title"])) ?: @"";
                            if (key.length && [seen containsObject:key]) continue;
                            if (key.length) [seen addObject:key];
                            [merged addObject:album];
                        }
                    }
                    artist[@"albums"] = merged;
                    artist[@"allAlbums"] = merged;
                    [artist addEntriesFromDictionary:waDZAlbumSections(merged)];
                    if (!tracks.count && [publicArtist[@"tracks"] count]) { artist[@"tracks"] = publicArtist[@"tracks"]; artist[@"songs"] = publicArtist[@"tracks"]; }
                    if (![artist[@"fans"] integerValue] && publicArtist[@"fans"]) artist[@"fans"] = publicArtist[@"fans"];
                }
                waDeezerDispatchMain(^{ if (completion) completion(artist, publicError); });
            }];
        }
    }];
}

- (void)setLiked:(BOOL)liked songIdentifier:(NSString *)identifier completion:(void (^)(NSError *))completion { [self callMethod:liked ? @"favorite_song.add" : @"favorite_song.remove" parameters:@{ @"SNG_ID": waDZRawIdentifier(identifier) ?: @"" } retry:YES completion:^(NSDictionary *json, NSError *error) { (void)json; waDeezerDispatchMain(^{ if (completion) completion(error); }); }]; }
- (void)setLiked:(BOOL)liked albumIdentifier:(NSString *)identifier completion:(void (^)(NSError *))completion { [self callMethod:liked ? @"album.addFavorite" : @"album.deleteFavorite" parameters:@{ @"ALB_ID": identifier ?: @"" } retry:YES completion:^(NSDictionary *json, NSError *error) { (void)json; waDeezerDispatchMain(^{ if (completion) completion(error); }); }]; }
- (void)setLiked:(BOOL)liked artistIdentifier:(NSString *)identifier completion:(void (^)(NSError *))completion { [self callMethod:liked ? @"artist.addFavorite" : @"artist.deleteFavorite" parameters:@{ @"ART_ID": identifier ?: @"" } retry:YES completion:^(NSDictionary *json, NSError *error) { (void)json; waDeezerDispatchMain(^{ if (completion) completion(error); }); }]; }
- (void)logListenForSongIdentifier:(NSString *)identifier format:(NSString *)format listenedAt:(NSTimeInterval)timestamp completion:(void (^)(NSError *))completion {
    // Registers the play in the user's Deezer listening history (Flow, stats,
    // monthly playlists). Payload mirrors the web player (cf. deezer-tui
    // log_listen): numeric 64-bit id when exact, stream format, playback
    // stat block, plus ctxt echoing the track (t:song_id) — without it the
    // gateway accepts the call but files nothing into history.
    // Timestamp = playback start, like scrobbles.
    NSString *raw = waDZRawIdentifier(identifier);
    if (!raw.length) { if (completion) completion([self errorWithMessage:@"Missing song id" code:400]); return; }
    id mediaID = waDZGatewayNumber(raw) ?: raw;
    [self callMethod:@"log.listen" parameters:@{ @"media": @{ @"id": mediaID, @"type": @"song", @"format": format.length ? format : @"MP3_320" }, @"stat": @{ @"seek": @0, @"pause": @0, @"sync": @1 }, @"ts_listen": @((long long)timestamp), @"type": @0, @"ctxt": @{ @"id": mediaID, @"t": @"song_id" } } retry:YES completion:^(NSDictionary *json, NSError *error) { (void)json; waDeezerDispatchMain(^{ if (completion) completion(error); }); }];
}
#if 0
- (void)setLiked:(BOOL)liked playlistIdentifier:(NSString *)identifier completion:(void (^)(NSError *))completion {
    NSString *rawIdentifier = waDZRawIdentifier(identifier) ?: @"";
    // Deezer uses different parameter names for following and unfollowing a
    // playlist. The gateway silently ignores the legacy uppercase key and
    // reports that playlist_id is missing on deleteFavorite.
    NSString *parameter = liked ? @"parent_playlist_id" : @"playlist_id";
    NSDictionary *parameters = @{ parameter: rawIdentifier };
    [self callMethod:liked ? @"playlist.addFavorite" : @"playlist.deleteFavorite" parameters:parameters retry:YES completion:^(NSDictionary *json, NSError *error) {
        (void)json;
        waDeezerDispatchMain(^{ if (completion) completion(error); });
    }];
}

- (void)playlistsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    [self callMethod:@"deezer.pageProfile" parameters:@{ @"nb": @100, @"tab": @"playlists", @"user_id": self.userIdentifier ?: @"" } retry:YES completion:^(NSDictionary *json, NSError *error) {
        NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : @{};
        NSDictionary *tab = [results[@"TAB"] isKindOfClass:[NSDictionary class]] ? results[@"TAB"] : @{};
        NSDictionary *section = [tab[@"playlists"] isKindOfClass:[NSDictionary class]] ? tab[@"playlists"] : @{};
        NSArray *data = [section[@"data"] isKindOfClass:[NSArray class]] ? section[@"data"] : @[];
        NSMutableArray *items = [NSMutableArray array];
        for (NSDictionary *object in data) {
            NSMutableDictionary *playlist = [NSMutableDictionary dictionaryWithDictionary:waDZPlaylist(object) ?: @{}];
            NSString *identifier = waDZString(object[@"PLAYLIST_ID"]) ?: waDZString(object[@"PARENT_PLAYLIST_ID"]) ?: waDZString(object[@"id"]);
            NSString *title = waDZString(object[@"TITLE"]) ?: waDZString(object[@"title"]) ?: waDZString(object[@"name"]);
            if (identifier.length) playlist[@"id"] = identifier;
            if (title.length) { playlist[@"title"] = title; playlist[@"name"] = title; }
            playlist[@"public"] = object[@"STATUS"] ? @([object[@"STATUS"] integerValue] != 1) : @YES;
            // This endpoint is the current user's playlist tab, but newer
            // payloads can include followed/shared entries. Preserve an
            // explicit ownership flag when present and otherwise require the
            // owner id to match the authenticated profile when available.
            id explicitOwner = object[@"owned"] ?: object[@"is_owner"] ?: object[@"isOwner"];
            NSDictionary *owner = [object[@"USER"] isKindOfClass:[NSDictionary class]] ? object[@"USER"] : ([object[@"user"] isKindOfClass:[NSDictionary class]] ? object[@"user"] : nil);
            NSString *ownerID = waDZString(owner[@"ID"]) ?: waDZString(owner[@"id"]) ?: waDZString(object[@"USER_ID"]) ?: waDZString(object[@"user_id"]);
            BOOL owned = explicitOwner ? [explicitOwner boolValue] : (!ownerID.length || [ownerID isEqualToString:self.userIdentifier]);
            playlist[@"owned"] = @(owned);
            [items addObject:playlist];
        }
        waDeezerDispatchMain(^{ if (completion) completion(items, error); });
    }];
}

- (void)playlistWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion {
    [self callMethod:@"deezer.pagePlaylist" parameters:@{ @"playlist_id": identifier ?: @"", @"lang": @"en", @"header": @YES, @"tab": @0, @"nb": @100, @"tags": @YES, @"start": @0 } retry:YES completion:^(NSDictionary *json, NSError *error) {
        NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : @{};
        NSDictionary *data = [results[@"DATA"] isKindOfClass:[NSDictionary class]] ? results[@"DATA"] : @{};
        NSArray *songs = [results[@"SONGS"] isKindOfClass:[NSDictionary class]] && [results[@"SONGS"][@"data"] isKindOfClass:[NSArray class]] ? results[@"SONGS"][@"data"] : @[];
        NSMutableDictionary *playlist = [NSMutableDictionary dictionaryWithDictionary:data];
        playlist[@"id"] = waDZString(data[@"PLAYLIST_ID"]) ?: identifier ?: @"";
        NSString *title = waDZString(data[@"TITLE"]) ?: waDZString(data[@"title"]) ?: @"Playlist";
        playlist[@"title"] = title; playlist[@"name"] = title; playlist[@"description"] = waDZString(data[@"DESCRIPTION"]) ?: @""; playlist[@"public"] = data[@"STATUS"] ? @([data[@"STATUS"] integerValue] != 1) : @YES;
        NSMutableArray *normalizedSongs = [NSMutableArray array]; for (NSDictionary *song in songs) { NSDictionary *item = waDZSong(song); if (item) [normalizedSongs addObject:item]; } playlist[@"tracks"] = normalizedSongs;
        if (error || !data.count) {
            [self publicPlaylistWithIdentifier:identifier completion:^(NSDictionary *publicPlaylist, NSError *publicError) {
                if (publicPlaylist) waDeezerDispatchMain(^{ if (completion) completion(publicPlaylist, nil); });
                else waDeezerDispatchMain(^{ if (completion) completion(playlist, error ?: publicError); });
            }];
        } else waDeezerDispatchMain(^{ if (completion) completion(playlist, nil); });
    }];
}

- (void)publicPlaylistWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *escaped = [identifier stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/playlist/%@", escaped ?: identifier ?: @""]];
      [NSURLConnection sendAsynchronousRequest:waDeezerRequest(url, NSURLRequestUseProtocolCachePolicy) queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
         NSError *responseError = waDZResponseError(response, networkError, @"Unable to load Deezer playlist.");
         if (responseError || ![json isKindOfClass:[NSDictionary class]] || [json[@"error"] isKindOfClass:[NSDictionary class]] || !json[@"id"]) {
             waDeezerDispatchMain(^{ if (completion) completion(nil, responseError ?: [self errorWithMessage:@"Unable to load Deezer playlist." code:http.statusCode ?: 404]); });
            return;
        }
        NSMutableDictionary *playlist = [NSMutableDictionary dictionary];
        NSString *title = waDZString(json[@"title"]) ?: @"Playlist";
        playlist[@"id"] = waDZString(json[@"id"]) ?: identifier ?: @"";
        playlist[@"title"] = title;
        playlist[@"name"] = title;
        playlist[@"description"] = waDZString(json[@"description"]) ?: @"";
        playlist[@"public"] = @(![json[@"public"] respondsToSelector:@selector(boolValue)] || [json[@"public"] boolValue]);
        playlist[@"thumbnailURL"] = waDZString(json[@"picture_xl"]) ?: waDZString(json[@"picture_big"]) ?: @"";
        NSArray *tracks = [json[@"tracks"] isKindOfClass:[NSDictionary class]] && [json[@"tracks"][@"data"] isKindOfClass:[NSArray class]] ? json[@"tracks"][@"data"] : @[];
        NSMutableArray *normalized = [NSMutableArray arrayWithCapacity:tracks.count];
        for (NSDictionary *track in tracks) { NSDictionary *item = waDZSong(track); if (item) [normalized addObject:item]; }
        playlist[@"tracks"] = normalized;
        waDeezerDispatchMain(^{ if (completion) completion(playlist, nil); });
    }];
}

- (void)createPlaylistNamed:(NSString *)name completion:(void (^)(NSDictionary *, NSError *))completion {
    [self callMethod:@"playlist.create" parameters:@{ @"title": name ?: @"Playlist", @"description": @"", @"songs": @[], @"status": @1 } retry:YES completion:^(NSDictionary *json, NSError *error) {
        id identifier = json[@"results"] ?: json[@"id"]; NSDictionary *playlist = @{ @"id": waDZString(identifier) ?: @"", @"title": name ?: @"Playlist", @"name": name ?: @"Playlist", @"public": @NO };
        waDeezerDispatchMain(^{ if (completion) completion(playlist, error); });
    }];
}

- (void)updatePlaylistWithIdentifier:(NSString *)identifier changes:(NSDictionary *)changes completion:(void (^)(NSDictionary *, NSError *))completion {
    NSMutableDictionary *parameters = [NSMutableDictionary dictionaryWithDictionary:changes ?: @{}];
    // Playlist identifiers can exceed NSInteger on the 32-bit armv7 target.
    // Keep them as strings so they are not truncated to INT_MAX (2147483647).
    parameters[@"playlist_id"] = waDZRawIdentifier(identifier) ?: @"";
    if (!parameters[@"title"] && parameters[@"name"]) parameters[@"title"] = parameters[@"name"];
    if (!parameters[@"description"]) parameters[@"description"] = @"";
    if (!parameters[@"status"]) parameters[@"status"] = @1;
    parameters[@"songs"] = @[];
    [self callMethod:@"playlist.update" parameters:parameters retry:YES completion:^(NSDictionary *json, NSError *error) { waDeezerDispatchMain(^{ if (completion) completion(json, error); }); }];
}

- (void)addSongIdentifier:(NSString *)songIdentifier toPlaylistIdentifier:(NSString *)playlistIdentifier completion:(void (^)(NSError *))completion {
    NSString *songID = waDZRawIdentifier(songIdentifier) ?: @"";
    NSString *playlistID = waDZRawIdentifier(playlistIdentifier) ?: @"";
    [self callMethod:@"playlist.addSongs" parameters:@{ @"playlist_id": playlistID, @"songs": @[@[songID, @0]], @"offset": @-1 } retry:YES completion:^(NSDictionary *json, NSError *error) { (void)json; waDeezerDispatchMain(^{ if (completion) completion(error); }); }];
}
- (void)removeSongIdentifier:(NSString *)songIdentifier fromPlaylistIdentifier:(NSString *)playlistIdentifier completion:(void (^)(NSError *))completion {
    NSString *songID = waDZRawIdentifier(songIdentifier) ?: @"";
    NSString *playlistID = waDZRawIdentifier(playlistIdentifier) ?: @"";
    [self callMethod:@"playlist.deleteSongs" parameters:@{ @"playlist_id": playlistID, @"songs": @[@[songID, @0]] } retry:YES completion:^(NSDictionary *json, NSError *error) { (void)json; waDeezerDispatchMain(^{ if (completion) completion(error); }); }];
}
- (void)deletePlaylistWithIdentifier:(NSString *)identifier completion:(void (^)(NSError *))completion { [self callMethod:@"playlist.delete" parameters:@{ @"PLAYLIST_ID": waDZRawIdentifier(identifier) ?: @"" } retry:YES completion:^(NSDictionary *json, NSError *error) { (void)json; waDeezerDispatchMain(^{ if (completion) completion(error); }); }]; }
#endif

- (void)relatedForTrackID:(NSString *)trackID completion:(void (^)(NSArray *, NSError *))completion {
    [[waDebugLog sharedLog] log:@"[Genius] relatedForTrackID start id=%@ raw=%@", trackID, waDZRawIdentifier(trackID)];
    NSString *rawID = waDZRawIdentifier(trackID);
    if (!rawID.length) { [[waDebugLog sharedLog] log:@"[Genius] missing rawID"]; waDeezerDispatchMain(^{ if (completion) completion(@[], [self errorWithMessage:@"Missing track id" code:400]); }); return; }
    NSURL *trackURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/track/%@", waDZQueryEscape(rawID)]];
    __weak typeof(self) weakSelf = self;
    [NSURLConnection sendAsynchronousRequest:waDeezerRequest(trackURL, NSURLRequestUseProtocolCachePolicy) queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *trackResp, NSData *trackData, NSError *trackErr) {
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { [[waDebugLog sharedLog] log:@"[Genius] strongSelf nil"]; waDeezerDispatchMain(^{ if (completion) completion(@[], nil); }); return; }
        NSDictionary *trackJson = trackData.length ? [NSJSONSerialization JSONObjectWithData:trackData options:0 error:NULL] : nil;
        NSError *trackError = waDZResponseError(trackResp, trackErr, @"Unable to load Deezer track.");
        if (!trackError && [trackJson[@"error"] isKindOfClass:[NSDictionary class]]) trackError = [strongSelf errorWithMessage:waDZString(trackJson[@"error"][@"message"]) ?: @"Deezer track not found." code:404];
        NSString *artistID = waDZString([trackJson[@"artist"] isKindOfClass:[NSDictionary class]] ? trackJson[@"artist"][@"id"] : nil);
        [[waDebugLog sharedLog] log:@"[Genius] track response artistID=%@ err=%@", artistID ?: @"(nil)", trackError.localizedDescription ?: @"none"];
        if (trackError || !artistID.length) { [[waDebugLog sharedLog] log:@"[Genius] abort no artist"]; waDeezerDispatchMain(^{ if (completion) completion(@[], trackError ?: [strongSelf errorWithMessage:@"Deezer artist not found." code:404]); }); return; }
        NSURL *topURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/artist/%@/top?limit=25", waDZQueryEscape(artistID)]];
        NSURL *relatedURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/artist/%@/related?limit=12", waDZQueryEscape(artistID)]];
        dispatch_group_t group = dispatch_group_create();
        __block NSArray *topData = @[];
        __block NSArray *relatedData = @[];
        __block NSError *fetchError = nil;
        dispatch_group_enter(group);
        [NSURLConnection sendAsynchronousRequest:waDeezerRequest(topURL, NSURLRequestUseProtocolCachePolicy) queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
            NSDictionary *j = d.length ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
            if (!e && [r isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse *)r statusCode] >= 200 && [(NSHTTPURLResponse *)r statusCode] < 300) topData = [j[@"data"] isKindOfClass:[NSArray class]] ? j[@"data"] : @[];
            else if (e) fetchError = e;
            [[waDebugLog sharedLog] log:@"[Genius] top %lu related will fetch", (unsigned long)topData.count];
            dispatch_group_leave(group);
        }];
        dispatch_group_enter(group);
        [NSURLConnection sendAsynchronousRequest:waDeezerRequest(relatedURL, NSURLRequestUseProtocolCachePolicy) queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
            NSDictionary *j = d.length ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
            if (!e && [r isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse *)r statusCode] >= 200 && [(NSHTTPURLResponse *)r statusCode] < 300) relatedData = [j[@"data"] isKindOfClass:[NSArray class]] ? j[@"data"] : @[];
            else if (e) fetchError = e;
            [[waDebugLog sharedLog] log:@"[Genius] related %lu", (unsigned long)relatedData.count];
            dispatch_group_leave(group);
        }];
        dispatch_group_notify(group, waDeezerParseDispatchQueue(), ^{
            @try {
                NSArray *relatedSlice = relatedData.count > 5 ? [relatedData subarrayWithRange:NSMakeRange(0, 5)] : relatedData;
                // Pre-allocate ordered array to keep genre interleave stable
                NSMutableArray *relatedTops = [NSMutableArray arrayWithCapacity:relatedSlice.count];
                for (NSUInteger i=0;i<relatedSlice.count;i++) [relatedTops addObject:@[]];
                if (relatedSlice.count==0) {
                    // No related -> just use topData
                    NSMutableSet *seen = [NSMutableSet setWithObject:rawID];
                    NSMutableArray *rows = [NSMutableArray array];
                    for (NSDictionary *item in topData) {
                        NSString *iid = waDZString(item[@"id"]);
                        if (!iid.length || [seen containsObject:iid]) continue;
                        [seen addObject:iid];
                        NSDictionary *n = waDZSong(item);
                        if (n) [rows addObject:n];
                        if (rows.count>=20) break;
                    }
                    [[waDebugLog sharedLog] log:@"[Genius] rows built %lu (top only) will callback", (unsigned long)rows.count];
                    waDeezerDispatchMain(^{ if (completion) completion(rows, fetchError); });
                    return;
                }
                dispatch_group_t rtGroup = dispatch_group_create();
                for (NSUInteger idx=0; idx<relatedSlice.count; idx++) {
                    NSDictionary *artist = relatedSlice[idx];
                    NSString *rid = waDZString(artist[@"id"]);
                    if (!rid.length) continue;
                    dispatch_group_enter(rtGroup);
                    NSURL *rtURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/artist/%@/top?limit=4", waDZQueryEscape(rid)]];
                    [NSURLConnection sendAsynchronousRequest:waDeezerRequest(rtURL, NSURLRequestUseProtocolCachePolicy) queue:waDeezerParseQueue() completionHandler:^(NSURLResponse *r, NSData *d, NSError *e) {
                        NSDictionary *j = d.length ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
                        NSArray *arr = (!e && [r isKindOfClass:[NSHTTPURLResponse class]] && [(NSHTTPURLResponse *)r statusCode] >= 200 && [(NSHTTPURLResponse *)r statusCode] < 300 && [j[@"data"] isKindOfClass:[NSArray class]]) ? j[@"data"] : @[];
                        @synchronized (relatedTops) { relatedTops[idx] = arr; }
                        dispatch_group_leave(rtGroup);
                    }];
                }
                dispatch_group_notify(rtGroup, waDeezerParseDispatchQueue(), ^{
                    @try {
                        NSMutableArray *candidates = [NSMutableArray array];
                        for (NSUInteger i=0; i<25; i++) {
                            if (i < topData.count) [candidates addObject:topData[i]];
                            for (NSArray *rt in relatedTops) if (i < rt.count) [candidates addObject:rt[i]];
                        }
                        NSMutableSet *seenIDs = [NSMutableSet setWithObject:rawID];
                        NSMutableSet *seenKeys = [NSMutableSet set];
                        NSMutableArray *rows = [NSMutableArray array];
                        for (NSDictionary *item in candidates) {
                            @try {
                                NSString *iid = waDZString(item[@"id"]);
                                if (!iid.length || [seenIDs containsObject:iid]) continue;
                                NSString *title = [waDZString(item[@"title"]) ?: @"" lowercaseString];
                                NSString *artist = [waDZString([item[@"artist"] isKindOfClass:[NSDictionary class]] ? item[@"artist"][@"name"] : @"") lowercaseString];
                                NSString *key = [NSString stringWithFormat:@"%@|%@", artist, title];
                                if ([seenKeys containsObject:key]) continue;
                                [seenIDs addObject:iid];
                                [seenKeys addObject:key];
                                NSDictionary *n = waDZSong(item);
                                if (n) [rows addObject:n];
                                if (rows.count>=30) break;
                            } @catch (NSException *ex) { [[waDebugLog sharedLog] log:@"[Genius] candidate exception: %@", ex.reason]; }
                        }
                        NSArray *result = rows.count>20 ? [rows subarrayWithRange:NSMakeRange(0,20)] : rows;
                        [[waDebugLog sharedLog] log:@"[Genius] genre-mix rows built %lu will callback", (unsigned long)result.count];
                        waDeezerDispatchMain(^{ if (completion) completion(result, fetchError); });
                    } @catch (NSException *ex) {
                        [[waDebugLog sharedLog] log:@"[Genius] mix exception: %@ %@", ex.name, ex.reason];
                        waDeezerDispatchMain(^{ if (completion) completion(@[], fetchError); });
                    }
                });
            } @catch (NSException *ex) {
                [[waDebugLog sharedLog] log:@"[Genius] group exception: %@ %@", ex.name, ex.reason];
                waDeezerDispatchMain(^{ if (completion) completion(@[], fetchError); });
            }
        });
    }];
}

#pragma clang diagnostic pop
@end
