#import "waModel.h"

NSString * const waTrackType = @"track";
NSString * const waAlbumType = @"album";
NSString * const waArtistType = @"artist";
NSString * const waPlaylistType = @"playlist";
NSString * const waRadioType = @"radio";
NSString * const waPodcastType = @"podcast";
NSString * const waEpisodeType = @"episode";
NSString * const waUserType = @"user";

static NSString *waString(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

static NSInteger waInteger(id value) {
    if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
    return 0;
}

static BOOL waBool(id value) {
    if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
    return NO;
}

static NSDictionary *waDict(id value) {
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

static NSString *waHTTPArtwork(NSString *url) {
    if (!url.length) return nil;
    if ([url hasPrefix:@"https://"]) return [@"http://" stringByAppendingString:[url substringFromIndex:8]];
    return url;
}

static NSInteger waCDNEdge(NSInteger edge) {
    if (edge <= 300) return 250;
    if (edge <= 600) return 500;
    return 1000;
}

static NSString *waCDNArtwork(NSString *hash, NSString *kind, NSInteger edge) {
    if (!hash.length || [hash hasPrefix:@"http"]) return waHTTPArtwork(hash);
    edge = waCDNEdge(edge);
    if (!kind.length) kind = @"cover";
    return [NSString stringWithFormat:@"http://cdn-images.dzcdn.net/images/%@/%@/%ldx%ld-000000-80-0-0.jpg",
            kind, hash, (long)edge, (long)edge];
}

static NSString *waPickCover(NSDictionary *dict) {
    if (!dict) return nil;
    NSArray *keys = [NSArray arrayWithObjects:
                     @"cover_big", @"picture_big", @"cover_medium", @"picture_medium",
                     @"cover_xl", @"picture_xl",
                     @"cover_small", @"picture_small",
                     @"cover", @"picture", @"artwork", nil];
    for (NSString *key in keys) {
        NSString *value = waString(dict[key]);
        if (value.length) return waHTTPArtwork(value);
    }
    NSString *hash = waString(dict[@"md5_image"]) ?: waString(dict[@"ALB_PICTURE"]) ?: waString(dict[@"ART_PICTURE"]) ?: waString(dict[@"PLAYLIST_PICTURE"]);
    if (!hash.length) return nil;
    NSString *kind = @"cover";
    if (waString(dict[@"ART_PICTURE"]) || waString(dict[@"picture_big"]) || waString(dict[@"picture_xl"])) kind = @"artist";
    if (waString(dict[@"PLAYLIST_PICTURE"])) kind = @"playlist";
    return waCDNArtwork(hash, kind, 500);
}

@implementation waItem

+ (id)itemWithDictionary:(NSDictionary *)dict kind:(NSString *)kind {
    id item = nil;
    if ([kind isEqualToString:waTrackType]) item = [[waTrack alloc] init];
    else if ([kind isEqualToString:waAlbumType]) item = [[waAlbum alloc] init];
    else if ([kind isEqualToString:waArtistType]) item = [[waArtist alloc] init];
    else if ([kind isEqualToString:waPlaylistType]) item = [[waPlaylist alloc] init];
    else if ([kind isEqualToString:waRadioType]) item = [[waRadio alloc] init];
    else if ([kind isEqualToString:waPodcastType]) item = [[waPodcast alloc] init];
    else if ([kind isEqualToString:waEpisodeType]) item = [[waEpisode alloc] init];
    else item = [[waItem alloc] init];
    [(waItem *)item fillWithDictionary:dict kind:kind];
    return item;
}

- (void)fillWithDictionary:(NSDictionary *)dict kind:(NSString *)kind {
    if (![dict isKindOfClass:[NSDictionary class]]) return;
    self.kind = kind;
    self.identifier = waString(dict[@"id"]) ?: waString(dict[@"identifier"]) ?: waString(dict[@"SNG_ID"]) ?: waString(dict[@"ALB_ID"]) ?: waString(dict[@"ART_ID"]) ?: waString(dict[@"PLAYLIST_ID"]);
    self.title = waString(dict[@"title"]) ?: waString(dict[@"name"]) ?: waString(dict[@"SNG_TITLE"]) ?: waString(dict[@"ALB_TITLE"]) ?: waString(dict[@"ART_NAME"]) ?: waString(dict[@"TITLE"]);
    self.subtitle = waString(dict[@"subtitle"]);
    self.explicitLyrics = waBool(dict[@"explicit_lyrics"]) || waBool(dict[@"EXPLICIT_LYRICS"]);
    self.artworkXLURL = waHTTPArtwork(waString(dict[@"cover_xl"]) ?: waString(dict[@"picture_xl"]));
    self.artworkSmallURL = waHTTPArtwork(waString(dict[@"cover_small"]) ?: waString(dict[@"picture_small"]));
    self.artworkURL = waPickCover(dict);
    if (!self.artworkSmallURL.length) self.artworkSmallURL = self.artworkURL;
    if (!self.artworkXLURL.length) self.artworkXLURL = self.artworkURL;
}

- (NSString *)bestArtworkURL {
    if (self.artworkXLURL.length) return self.artworkXLURL;
    if (self.artworkURL.length) return self.artworkURL;
    return self.artworkSmallURL;
}

- (NSString *)artworkURLForSide:(CGFloat)side {
    if (side <= 250.0) {
        if (self.artworkURL.length) return self.artworkURL;
        if (self.artworkXLURL.length) return self.artworkXLURL;
        return self.artworkSmallURL;
    }
    if (self.artworkXLURL.length) return self.artworkXLURL;
    if (self.artworkURL.length) return self.artworkURL;
    return self.artworkSmallURL;
}

- (NSDictionary *)dictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (self.identifier) dict[@"id"] = self.identifier;
    if (self.title) dict[@"title"] = self.title;
    if (self.kind) dict[@"kind"] = self.kind;
    if (self.artworkURL) dict[@"artwork"] = self.artworkURL;
    return dict;
}

@end

@implementation waTrack

- (void)fillWithDictionary:(NSDictionary *)dict kind:(NSString *)kind {
    [super fillWithDictionary:dict kind:waTrackType];
    NSDictionary *album = waDict(dict[@"album"]);
    NSDictionary *artist = waDict(dict[@"artist"]);
    self.title = waString(dict[@"title"]) ?: waString(dict[@"SNG_TITLE"]) ?: self.title;
    self.albumTitle = waString(album[@"title"]) ?: waString(dict[@"ALB_TITLE"]);
    self.albumIdentifier = waString(album[@"id"]) ?: waString(dict[@"ALB_ID"]);
    self.artistName = waString(artist[@"name"]) ?: waString(dict[@"ART_NAME"]);
    if (!self.artistName.length && [dict[@"artist"] isKindOfClass:[NSString class]]) self.artistName = dict[@"artist"];
    self.artistIdentifier = waString(artist[@"id"]) ?: waString(dict[@"ART_ID"]);
    self.isrc = waString(dict[@"isrc"]) ?: waString(dict[@"ISRC"]);
    self.trackToken = waString(dict[@"track_token"]) ?: waString(dict[@"TRACK_TOKEN"]);
    self.md5 = waString(dict[@"md5_image"]) ?: waString(album[@"md5_image"]) ?: waString(dict[@"ALB_PICTURE"]);
    self.releaseDate = waString(dict[@"release_date"]);
    self.duration = (NSTimeInterval)waInteger(dict[@"duration"] ?: dict[@"DURATION"]);
    self.trackPosition = waInteger(dict[@"track_position"] ?: dict[@"TRACK_NUMBER"] ?: dict[@"trackNumber"]);
    self.diskNumber = waInteger(dict[@"disk_number"] ?: dict[@"DISK_NUMBER"] ?: dict[@"disc_number"] ?: dict[@"DISC_NUMBER"]);
    if (self.diskNumber < 1) self.diskNumber = 1;
    self.bpm = waInteger(dict[@"bpm"]);
    self.readable = dict[@"readable"] ? waBool(dict[@"readable"]) : YES;
    self.streamable = dict[@"streamable"] ? waBool(dict[@"streamable"]) : YES;
    self.previewURL = waString(dict[@"preview"]);
    self.preview = self.previewURL.length > 0;
    if ([dict[@"contributors"] isKindOfClass:[NSArray class]]) self.contributors = dict[@"contributors"];
    NSString *cover = waPickCover(album);
    if (!cover.length && self.md5.length) cover = waCDNArtwork(self.md5, @"cover", 500);
    if (!cover.length) cover = waPickCover(dict);
    if (cover.length) {
        self.artworkURL = cover;
        if (!self.artworkXLURL.length) {
            self.artworkXLURL = self.md5.length ? waCDNArtwork(self.md5, @"cover", 1000) : cover;
        }
        if (!self.artworkSmallURL.length) {
            self.artworkSmallURL = self.md5.length ? waCDNArtwork(self.md5, @"cover", 56) : cover;
        }
    }
    self.subtitle = self.artistName;
}

- (NSString *)subtitle {
    if (self.artistName.length) return self.artistName;
    return [super subtitle];
}

- (NSString *)bestArtworkURL {
    NSString *url = [super bestArtworkURL];
    if (url.length) return url;
    if (self.md5.length) return waCDNArtwork(self.md5, @"cover", 500);
    return nil;
}

- (NSString *)artworkURLForSide:(CGFloat)side {
    NSString *url = [super artworkURLForSide:side];
    if (url.length) return url;
    if (self.md5.length) {
        NSInteger edge = 500;
        if (side <= 250.0) edge = 250;
        else if (side > 500.0) edge = 1000;
        return waCDNArtwork(self.md5, @"cover", edge);
    }
    return nil;
}

- (NSDictionary *)dictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (self.identifier.length) dict[@"id"] = self.identifier;
    if (self.title.length) dict[@"title"] = self.title;
    dict[@"kind"] = waTrackType;
    dict[@"duration"] = @(self.duration);
    dict[@"track_position"] = @(self.trackPosition);
    dict[@"disk_number"] = @(self.diskNumber);
    dict[@"bpm"] = @(self.bpm);
    dict[@"explicit_lyrics"] = @(self.explicitLyrics);
    dict[@"readable"] = @(self.readable);
    dict[@"streamable"] = @(self.streamable);
    dict[@"liked"] = @(self.liked);
    if (self.isrc.length) dict[@"isrc"] = self.isrc;
    if (self.md5.length) dict[@"md5_image"] = self.md5;
    if (self.releaseDate.length) dict[@"release_date"] = self.releaseDate;
    if (self.previewURL.length) dict[@"preview"] = self.previewURL;
    if (self.artworkURL.length) dict[@"cover"] = self.artworkURL;
    if (self.artworkSmallURL.length) dict[@"cover_small"] = self.artworkSmallURL;
    if (self.artworkXLURL.length) dict[@"cover_xl"] = self.artworkXLURL;
    NSMutableDictionary *artist = [NSMutableDictionary dictionary];
    if (self.artistIdentifier.length) artist[@"id"] = self.artistIdentifier;
    if (self.artistName.length) artist[@"name"] = self.artistName;
    if (artist.count) dict[@"artist"] = artist;
    NSMutableDictionary *album = [NSMutableDictionary dictionary];
    if (self.albumIdentifier.length) album[@"id"] = self.albumIdentifier;
    if (self.albumTitle.length) album[@"title"] = self.albumTitle;
    if (self.artworkURL.length) album[@"cover"] = self.artworkURL;
    if (album.count) dict[@"album"] = album;
    return dict;
}

- (BOOL)needsHydration {
    return !self.bestArtworkURL.length || !self.artistName.length || !self.albumTitle.length || self.duration < 1.0;
}

- (void)mergeFrom:(waTrack *)other {
    if (!other) return;
    if (other.title.length) self.title = other.title;
    if (other.artistName.length) self.artistName = other.artistName;
    if (other.artistIdentifier.length) self.artistIdentifier = other.artistIdentifier;
    if (other.albumTitle.length) self.albumTitle = other.albumTitle;
    if (other.albumIdentifier.length) self.albumIdentifier = other.albumIdentifier;
    if (other.artworkURL.length) self.artworkURL = other.artworkURL;
    if (other.artworkXLURL.length) self.artworkXLURL = other.artworkXLURL;
    if (other.artworkSmallURL.length) self.artworkSmallURL = other.artworkSmallURL;
    if (other.md5.length) self.md5 = other.md5;
    if (other.duration > 0) self.duration = other.duration;
    if (other.trackToken.length) self.trackToken = other.trackToken;
    if (other.previewURL.length) self.previewURL = other.previewURL;
    if (other.isrc.length) self.isrc = other.isrc;
    if (other.trackPosition > 0) self.trackPosition = other.trackPosition;
    if (other.diskNumber > 0) self.diskNumber = other.diskNumber;
    self.subtitle = self.artistName;
}

@end

@implementation waAlbum

static BOOL waAlbumLooksDeluxe(NSString *title, NSString *version) {
    NSString *blob = [[NSString stringWithFormat:@"%@ %@", title ?: @"", version ?: @""] lowercaseString];
    NSArray *marks = [NSArray arrayWithObjects:@"deluxe", @"remaster", @"anniversary", @"expanded", @"super deluxe", @"collector", @"box set", @"edition", nil];
    for (NSString *mark in marks) {
        if ([blob rangeOfString:mark].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *waAlbumNamedRecordType(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *text = [[(NSString *)value lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([text isEqualToString:@"ep"]) return @"ep";
    if ([text isEqualToString:@"single"]) return @"single";
    if ([text isEqualToString:@"compile"] || [text isEqualToString:@"compilation"]) return @"compile";
    if ([text isEqualToString:@"album"]) return @"album";
    return nil;
}

static NSString *waAlbumClassify(NSString *named, NSInteger typeCode, NSInteger tracks, NSString *title, NSString *version) {
    BOOL deluxe = waAlbumLooksDeluxe(title, version);
    if ([named isEqualToString:@"compile"]) return @"compile";
    if ([named isEqualToString:@"album"]) return @"album";
    if ([named isEqualToString:@"single"] && (deluxe || tracks >= 7)) return @"album";
    if ([named isEqualToString:@"ep"] && (deluxe || tracks >= 8)) return @"album";
    if ([named isEqualToString:@"ep"]) return @"ep";
    if ([named isEqualToString:@"single"]) return @"single";
    if (typeCode == 2) return @"compile";
    if (deluxe || tracks >= 7) return @"album";
    if (typeCode == 3 || (tracks >= 4 && tracks <= 6)) return @"ep";
    if (typeCode == 1 || (tracks > 0 && tracks <= 3)) return @"single";
    return @"album";
}

- (void)fillWithDictionary:(NSDictionary *)dict kind:(NSString *)kind {
    [super fillWithDictionary:dict kind:waAlbumType];
    NSDictionary *artist = waDict(dict[@"artist"]);
    self.artistName = waString(artist[@"name"]) ?: waString(dict[@"ART_NAME"]);
    self.artistIdentifier = waString(artist[@"id"]) ?: waString(dict[@"ART_ID"]);
    self.label = waString(dict[@"label"]);
    self.upc = waString(dict[@"upc"]);
    self.releaseDate = waString(dict[@"release_date"]) ?: waString(dict[@"PHYSICAL_RELEASE_DATE"]) ?: waString(dict[@"DIGITAL_RELEASE_DATE"]) ?: waString(dict[@"ORIGINAL_RELEASE_DATE"]);
    self.version = waString(dict[@"version"]) ?: waString(dict[@"VERSION"]);
    self.roleId = waInteger(dict[@"ROLE_ID"] ?: dict[@"role_id"]);
    self.trackCount = waInteger(dict[@"nb_tracks"] ?: dict[@"NUMBER_TRACK"] ?: dict[@"NUMBER_TRACKS"]);
    self.recordType = waAlbumClassify(waAlbumNamedRecordType(dict[@"record_type"]), waInteger(dict[@"TYPE"]), self.trackCount, self.title, self.version);
    self.duration = (NSTimeInterval)waInteger(dict[@"duration"]);
    self.liked = waBool(dict[@"liked"]);
    if (self.version.length && self.title.length && [self.title rangeOfString:self.version options:NSCaseInsensitiveSearch].location == NSNotFound) {
        self.subtitle = self.version;
    } else if (self.releaseDate.length >= 4) {
        self.subtitle = [self.releaseDate substringToIndex:4];
    }
    if ([dict[@"tracks"][@"data"] isKindOfClass:[NSArray class]]) {
        NSMutableArray *tracks = [NSMutableArray array];
        for (NSDictionary *raw in dict[@"tracks"][@"data"]) [tracks addObject:[waTrack itemWithDictionary:raw kind:waTrackType]];
        self.tracks = waSortedAlbumTracks(tracks);
    }
}

@end

@implementation waArtist

- (void)fillWithDictionary:(NSDictionary *)dict kind:(NSString *)kind {
    [super fillWithDictionary:dict kind:waArtistType];
    self.albumCount = waInteger(dict[@"nb_album"]);
    self.fanCount = waInteger(dict[@"nb_fan"]);
    self.role = waString(dict[@"role"]);
    self.liked = waBool(dict[@"liked"]);
    if ([dict[@"data"] isKindOfClass:[NSArray class]]) {
        NSMutableArray *tracks = [NSMutableArray array];
        for (NSDictionary *raw in dict[@"data"]) {
            if ([raw[@"title"] isKindOfClass:[NSString class]]) [tracks addObject:[waTrack itemWithDictionary:raw kind:waTrackType]];
        }
        if (tracks.count) self.topTracks = tracks;
    }
}

@end

@implementation waPlaylist

- (void)fillWithDictionary:(NSDictionary *)dict kind:(NSString *)kind {
    [super fillWithDictionary:dict kind:waPlaylistType];
    self.playlistDescription = waString(dict[@"description"]);
    self.creatorName = waString(dict[@"creator"][@"name"]);
    self.creatorIdentifier = waString(dict[@"creator"][@"id"]);
    self.trackCount = waInteger(dict[@"nb_tracks"]);
    self.duration = (NSTimeInterval)waInteger(dict[@"duration"]);
    self.publicPlaylist = waBool(dict[@"public"]);
    self.owned = waBool(dict[@"owned"]);
    if ([dict[@"tracks"][@"data"] isKindOfClass:[NSArray class]]) {
        NSMutableArray *tracks = [NSMutableArray array];
        for (NSDictionary *raw in dict[@"tracks"][@"data"]) [tracks addObject:[waTrack itemWithDictionary:raw kind:waTrackType]];
        self.tracks = tracks;
    }
}

@end

@implementation waRadio

- (void)fillWithDictionary:(NSDictionary *)dict kind:(NSString *)kind {
    [super fillWithDictionary:dict kind:waRadioType];
    self.radioDescription = waString(dict[@"description"]);
}

@end

@implementation waGenre
@end

@implementation waPodcast

- (void)fillWithDictionary:(NSDictionary *)dict kind:(NSString *)kind {
    [super fillWithDictionary:dict kind:waPodcastType];
    self.podcastDescription = waString(dict[@"description"]);
    self.fans = waInteger(dict[@"fans"]);
    self.available = dict[@"available"] ? waBool(dict[@"available"]) : YES;
}

@end

@implementation waEpisode

- (void)fillWithDictionary:(NSDictionary *)dict kind:(NSString *)kind {
    [super fillWithDictionary:dict kind:waEpisodeType];
    self.podcastTitle = waString(dict[@"podcast"][@"title"]);
    self.podcastIdentifier = waString(dict[@"podcast"][@"id"]);
    self.duration = (NSTimeInterval)waInteger(dict[@"duration"]);
    self.releaseDate = waString(dict[@"release_date"]);
    if (!self.subtitle.length) self.subtitle = self.podcastTitle;
}

@end

@implementation waComment
@end

@implementation waChart

- (id)init {
    if ((self = [super init])) {
        _tracks = @[];
        _albums = @[];
        _artists = @[];
        _playlists = @[];
    }
    return self;
}

@end

@implementation waSection

- (id)init {
    if ((self = [super init])) _items = @[];
    return self;
}

@end

@implementation waUser

- (void)fillWithData:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return;
    self.identifier = waString(dict[@"USER_ID"]) ?: waString(dict[@"id"]);
    self.name = waString(dict[@"BLOG_NAME"]) ?: waString(dict[@"name"]);
    self.email = waString(dict[@"EMAIL"]) ?: waString(dict[@"email"]);
    self.pictureURL = waString(dict[@"USER_PICTURE"]) ?: waString(dict[@"picture"]);
    self.country = waString(dict[@"COUNTRY"]) ?: waString(dict[@"country"]);
    self.verified = waBool(dict[@"verified"]);
    NSArray *options = dict[@"OPTIONS"];
    if ([options isKindOfClass:[NSArray class]]) self.offers = options;
    self.canStreamLossless = waBool(dict[@"canStreamLossless"]);
    self.canStreamHifi = waBool(dict[@"canStreamHifi"]);
}

@end

@implementation waHomePayload
@end

NSInteger waAlbumDiskNumber(waTrack *track) {
    if (![track isKindOfClass:[waTrack class]]) return 1;
    return track.diskNumber > 0 ? track.diskNumber : 1;
}

BOOL waAlbumHasMultipleDisks(NSArray *tracks) {
    NSInteger seen = 0;
    for (id obj in tracks) {
        if (![obj isKindOfClass:[waTrack class]]) continue;
        NSInteger disk = waAlbumDiskNumber(obj);
        if (seen == 0) seen = disk;
        else if (disk != seen) return YES;
    }
    return NO;
}

NSArray *waSortedAlbumTracks(NSArray *tracks) {
    if (tracks.count < 2) return tracks ?: [NSArray array];
    NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:tracks.count];
    NSUInteger index = 0;
    for (id obj in tracks) {
        if ([obj isKindOfClass:[waTrack class]]) {
            [pairs addObject:[NSArray arrayWithObjects:obj, @(index), nil]];
        }
        index++;
    }
    [pairs sortUsingComparator:^NSComparisonResult(NSArray *left, NSArray *right) {
        waTrack *a = [left objectAtIndex:0];
        waTrack *b = [right objectAtIndex:0];
        NSInteger da = waAlbumDiskNumber(a);
        NSInteger db = waAlbumDiskNumber(b);
        if (da != db) return da < db ? NSOrderedAscending : NSOrderedDescending;
        if (a.trackPosition > 0 && b.trackPosition > 0 && a.trackPosition != b.trackPosition) {
            return a.trackPosition < b.trackPosition ? NSOrderedAscending : NSOrderedDescending;
        }
        NSUInteger ia = [[left objectAtIndex:1] unsignedIntegerValue];
        NSUInteger ib = [[right objectAtIndex:1] unsignedIntegerValue];
        if (ia < ib) return NSOrderedAscending;
        if (ia > ib) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    NSMutableArray *sorted = [NSMutableArray arrayWithCapacity:pairs.count];
    for (NSArray *pair in pairs) [sorted addObject:[pair objectAtIndex:0]];
    return sorted;
}
