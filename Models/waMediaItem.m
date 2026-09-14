#import "waMediaItem.h"
#import "waAlbum.h"
#import "waArtist.h"

@implementation waMediaItem

static NSString *waMediaString(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

static NSString *waMediaFirstString(NSDictionary *dictionary, NSArray *keys) {
    for (NSString *key in keys) {
        NSString *value = waMediaString(dictionary[key]);
        if (value.length) return value;
    }
    return nil;
}

static NSString *waDeezerArtworkURL(NSDictionary *raw) {
    if (![raw isKindOfClass:[NSDictionary class]]) return nil;
    NSString *playlistPicture = waMediaString(raw[@"PLAYLIST_PICTURE"]);
    if (playlistPicture.length) return [NSString stringWithFormat:@"https://e-cdns-images.dzcdn.net/images/playlist/%@/1000x1000-000000-80-0-0.jpg", playlistPicture];
    NSDictionary *cover = [raw[@"COVER"] isKindOfClass:[NSDictionary class]] ? raw[@"COVER"] : nil;
    NSString *coverType = waMediaString(cover[@"TYPE"]);
    NSString *coverMD5 = waMediaString(cover[@"MD5"]);
    if (coverType.length && coverMD5.length) return [NSString stringWithFormat:@"https://e-cdns-images.dzcdn.net/images/%@/%@/1000x1000-000000-80-0-0.jpg", coverType, coverMD5];
    return nil;
}

static BOOL waMediaLooksLikeYear(NSString *value) {
    if (value.length != 4) return NO;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound;
}

static NSUInteger waMediaCountValue(NSDictionary *dictionary, NSArray *keys) {
    for (NSString *key in keys) {
        id value = dictionary[key];
        if ([value respondsToSelector:@selector(unsignedIntegerValue)]) return [value unsignedIntegerValue];
        if ([value isKindOfClass:[NSArray class]]) return [value count];
    }
    return 0;
}

static NSTimeInterval waMediaDurationValue(id value) {
    if ([value respondsToSelector:@selector(doubleValue)] && ![value isKindOfClass:[NSString class]]) return [value doubleValue];
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = value;
        return waMediaDurationValue(dictionary[@"seconds"] ?: dictionary[@"duration"] ?: dictionary[@"value"]);
    }
    if (![value isKindOfClass:[NSString class]]) return 0.0;
    NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *parts = [text componentsSeparatedByString:@":"];
    if (parts.count == 2 || parts.count == 3) {
        NSTimeInterval total = 0.0;
        for (NSString *part in parts) {
            if (!part.length || [part rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) return 0.0;
            total = total * 60.0 + [part doubleValue];
        }
        return total;
    }
    return [text doubleValue];
}

- (id)initWithIdentifier:(NSString *)identifier title:(NSString *)title subtitle:(NSString *)subtitle type:(waMediaItemType)type {
    if ((self = [super init])) { _identifier = [identifier copy]; _title = [title copy]; _subtitle = [subtitle copy]; _type = type; }
    return self;
}
- (NSDictionary *)dictionaryRepresentation {
    return @{ @"identifier": self.identifier ?: @"",
              @"title": self.title ?: @"",
              @"subtitle": self.subtitle ?: @"",
              @"type": @(self.type),
                @"thumbnailURL": self.thumbnailURL ?: @"",
                @"trackId": self.trackId ?: @"",
                @"isrc": self.isrc ?: @"",
                @"artistIdentifier": self.artistIdentifier ?: @"",
               @"albumIdentifier": self.albumIdentifier ?: @"",
               @"artistName": self.artistName ?: @"",
               @"albumName": self.albumName ?: @"",
               @"releaseYear": self.releaseYear ?: @"",
               @"liked": @(self.liked),
                @"explicit": @(self.explicit),
                @"geniusRecommended": @(self.geniusRecommended),
                 @"duration": @(self.duration) };
}

+ (id)itemWithDictionary:(NSDictionary *)dictionary {
    if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;

    id rawType = dictionary[@"type"];
    waMediaItemType type = waMediaItemTypeSong;
    if ([rawType isKindOfClass:[NSNumber class]]) type = [rawType integerValue];
    else {
        NSString *kind = [[waMediaString(rawType) lowercaseString] copy];
        type = [kind isEqualToString:@"album"] ? waMediaItemTypeAlbum : ([kind isEqualToString:@"artist"] ? waMediaItemTypeArtist : ([kind isEqualToString:@"playlist"] ? waMediaItemTypePlaylist : waMediaItemTypeSong));
    }
    NSString *identifier = waMediaFirstString(dictionary, @[@"trackId", @"browseId", @"browse_id", @"identifier", @"id"]);
    NSString *title = waMediaFirstString(dictionary, @[@"title", @"name"]);
    NSString *subtitle = waMediaFirstString(dictionary, @[@"subtitle", @"artist", @"author", @"artistName"]);
    NSUInteger albumTrackCount = waMediaCountValue(dictionary, @[@"trackCount", @"track_count", @"tracksCount", @"tracks_count", @"totalTracks", @"total_tracks", @"tracks"]);
    NSUInteger artistSongCount = waMediaCountValue(dictionary, @[@"songCount", @"song_count", @"trackCount", @"track_count", @"totalSongs", @"total_songs", @"songs"]);
    waMediaItem *item = nil;
    if (type == waMediaItemTypeAlbum) {
        item = [[waAlbum alloc] initWithIdentifier:identifier title:title ?: @"Untitled" artist:subtitle trackCount:albumTrackCount];
    } else if (type == waMediaItemTypeArtist) {
        item = [[waArtist alloc] initWithIdentifier:identifier title:title ?: @"Untitled" songCount:artistSongCount];
    } else {
        item = [[self alloc] initWithIdentifier:identifier title:title ?: @"Untitled" subtitle:subtitle type:type];
    }
    // Slim metadata: drop the nested deezerRaw blob (full Deezer JSON)
    // after hoisting the few raw-only keys readers need. Keeps per-item
    // RAM small across queue/Home/Profile/Downloads.
    NSDictionary *rawDeezer = [dictionary[@"deezerRaw"] isKindOfClass:[NSDictionary class]] ? dictionary[@"deezerRaw"] : nil;
    NSMutableDictionary *slim = [dictionary mutableCopy];
    if (rawDeezer) {
        if (!slim[@"recordType"] && !slim[@"record_type"]) {
            NSString *recordType = waMediaFirstString(rawDeezer, @[@"record_type", @"ALB_TYPE"]);
            if (recordType.length) slim[@"record_type"] = recordType;
        }
        [slim removeObjectForKey:@"deezerRaw"];
    }
    item.metadata = [slim copy];
    item.trackId = waMediaFirstString(dictionary, @[@"trackId"]);
    item.isrc = waMediaFirstString(dictionary, @[@"isrc", @"ISRC", @"isrc_code"]);
    if (!item.isrc.length) item.isrc = waMediaFirstString(rawDeezer, @[@"isrc", @"ISRC", @"isrc_code"]);
    // waDZSong/waDZAlbum emit "artistIdentifier"/"albumIdentifier"; without
    // these keys the IDs are dropped and the context actions (Go to Artist /
    // Go to Album) never appear.
    item.artistIdentifier = waMediaFirstString(dictionary, @[@"artistIdentifier", @"artistId", @"artist_id", @"artistBrowseId", @"artist_browse_id"]);
    item.albumIdentifier = waMediaFirstString(dictionary, @[@"albumIdentifier", @"albumId", @"album_id", @"albumBrowseId", @"album_browse_id"]);
    item.artistName = waMediaFirstString(dictionary, @[@"artistName", @"artist", @"author"]);
    item.albumName = waMediaFirstString(dictionary, @[@"albumName", @"album"]);
    item.releaseYear = waMediaFirstString(dictionary, @[@"releaseYear", @"release_year", @"year", @"releaseDate", @"release_date"]);
    if (type == waMediaItemTypeAlbum && [item.artistName caseInsensitiveCompare:@"Album"] == NSOrderedSame) item.artistName = nil;
    if (type == waMediaItemTypeAlbum && [subtitle hasPrefix:@"Album • "]) {
        NSArray *parts = [subtitle componentsSeparatedByString:@" • "];
        if (parts.count > 2) {
            if (!item.artistName.length || [item.artistName caseInsensitiveCompare:@"Album"] == NSOrderedSame) item.artistName = parts[1];
            if (!item.releaseYear.length && waMediaLooksLikeYear([parts lastObject])) item.releaseYear = [parts lastObject];
        } else if (parts.count == 2) {
            if (!item.releaseYear.length && waMediaLooksLikeYear(parts[1])) item.releaseYear = parts[1];
            else if (!item.artistName.length) item.artistName = parts[1];
        }
    }
    if (type == waMediaItemTypeAlbum) item.subtitle = item.artistName ?: @"";
    if (type == waMediaItemTypeArtist) item.subtitle = @"Artist";
    id liked = dictionary[@"liked"];
    id likedByMe = dictionary[@"likedByMe"];
    item.liked = ([liked respondsToSelector:@selector(boolValue)] && [liked boolValue]) || ([likedByMe respondsToSelector:@selector(boolValue)] && [likedByMe boolValue]);
    id explicit = dictionary[@"explicit"] ?: dictionary[@"explicitLyrics"] ?: rawDeezer[@"explicit_lyrics"];
    item.explicit = [explicit respondsToSelector:@selector(boolValue)] && [explicit boolValue];
    item.geniusRecommended = [dictionary[@"geniusRecommended"] respondsToSelector:@selector(boolValue)] && [dictionary[@"geniusRecommended"] boolValue];
    id rawThumbs = dictionary[@"thumbnails"];
    NSArray *thumbs = [rawThumbs isKindOfClass:[NSArray class]] ? rawThumbs : nil;
    id thumbnail = thumbs.count ? [thumbs objectAtIndex:0] : nil;
    NSString *thumbnailURL = [thumbnail isKindOfClass:[NSDictionary class]] ? waMediaString(thumbnail[@"url"]) : waMediaString(thumbnail);
    if (!thumbnailURL.length) thumbnailURL = waMediaString(dictionary[@"thumbnailURL"]);
    if (!thumbnailURL.length) thumbnailURL = waMediaString(dictionary[@"thumbnail"]);
    if (!thumbnailURL.length) thumbnailURL = waMediaString(dictionary[@"artwork"]);
    if (!thumbnailURL.length) thumbnailURL = waDeezerArtworkURL(rawDeezer);
    item.thumbnailURL = thumbnailURL;
    NSTimeInterval durationValue = 0.0;
    NSArray *durationKeys = @[@"duration", @"durationSeconds", @"duration_seconds", @"lengthSeconds", @"length_seconds", @"length", @"durationMs", @"duration_ms"];
    for (NSString *key in durationKeys) {
        id duration = dictionary[key];
        if (!duration) continue;
        durationValue = waMediaDurationValue(duration);
        if ([key rangeOfString:@"ms" options:NSCaseInsensitiveSearch].location != NSNotFound) durationValue /= 1000.0;
        if (durationValue > 0.0) break;
    }
    item.duration = MAX(0.0, durationValue);
    return item;
}
static NSString *waMediaNumericID(NSString *value) {
    if (!value.length) return nil;
    // Identifiers travel as "deezer:<id>"; keep whatever follows the last
    // colon so bare numeric ids keep working too.
    NSRange colon = [value rangeOfString:@":" options:NSBackwardsSearch];
    NSString *candidate = colon.location == NSNotFound ? value : [value substringFromIndex:colon.location + 1];
    if (!candidate.length) return nil;
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([candidate rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return nil;
    return candidate;
}

- (NSURL *)deezerURL {
    NSString *rawID = nil;
    NSString *path = nil;
    if (self.type == waMediaItemTypeSong) {
        rawID = self.trackId.length ? self.trackId : self.identifier;
        path = @"track";
    } else if (self.type == waMediaItemTypeAlbum) {
        rawID = self.albumIdentifier.length ? self.albumIdentifier : self.identifier;
        path = @"album";
    } else if (self.type == waMediaItemTypeArtist) {
        rawID = self.artistIdentifier.length ? self.artistIdentifier : self.identifier;
        path = @"artist";
    } else {
        rawID = self.identifier;
        path = @"playlist";
    }
    NSString *numericID = waMediaNumericID(rawID);
    if (!numericID.length) return nil;
    return [NSURL URLWithString:[NSString stringWithFormat:@"https://www.deezer.com/%@/%@", path, numericID]];
}

@end
