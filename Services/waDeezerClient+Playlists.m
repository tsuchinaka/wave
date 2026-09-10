#import "waDeezerClient.h"
#import "waDeezerClient+Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation waDeezerClient (Playlists)

- (void)setLiked:(BOOL)liked playlistIdentifier:(NSString *)identifier completion:(void (^)(NSError *))completion {
    NSString *rawIdentifier = [self wa_rawIdentifier:identifier] ?: @"";
    NSString *parameter = liked ? @"parent_playlist_id" : @"playlist_id";
    NSDictionary *parameters = @{ parameter: rawIdentifier };
    [self wa_callMethod:liked ? @"playlist.addFavorite" : @"playlist.deleteFavorite" parameters:parameters retry:YES completion:^(NSDictionary *json, NSError *error) {
        (void)json;
        [self wa_dispatchMain:^{ if (completion) completion(error); }];
    }];
}

- (void)playlistsWithCompletion:(void (^)(NSArray *, NSError *))completion {
    // Resolve userIdentifier before constructing pageProfile parameters.
    // Otherwise first launch sends user_id="" and the Library playlist shelf
    // is empty until a later manual reload.
    [self authorizeWithCompletion:^(NSDictionary *user, NSError *authorizationError) {
        (void)user;
        if (authorizationError || !self.userIdentifier.length) {
            [self wa_dispatchMain:^{ if (completion) completion(@[], authorizationError); }];
            return;
        }
        NSDictionary *parameters = @{ @"nb": @100, @"tab": @"playlists", @"user_id": self.userIdentifier };
        [self wa_callMethod:@"deezer.pageProfile" parameters:parameters retry:YES completion:^(NSDictionary *json, NSError *error) {
            NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : @{};
            NSDictionary *tab = [results[@"TAB"] isKindOfClass:[NSDictionary class]] ? results[@"TAB"] : @{};
            NSDictionary *section = [tab[@"playlists"] isKindOfClass:[NSDictionary class]] ? tab[@"playlists"] : @{};
            NSArray *data = [section[@"data"] isKindOfClass:[NSArray class]] ? section[@"data"] : @[];
            NSMutableArray *items = [NSMutableArray array];
            for (NSDictionary *object in data) {
                NSMutableDictionary *playlist = [NSMutableDictionary dictionaryWithDictionary:[self wa_playlistFromDictionary:object] ?: @{}];
                NSString *identifier = [self wa_string:object[@"PLAYLIST_ID"]] ?: [self wa_string:object[@"PARENT_PLAYLIST_ID"]] ?: [self wa_string:object[@"id"]];
                NSString *title = [self wa_string:object[@"TITLE"]] ?: [self wa_string:object[@"title"]] ?: [self wa_string:object[@"name"]];
                if (identifier.length) playlist[@"id"] = identifier;
                if (title.length) { playlist[@"title"] = title; playlist[@"name"] = title; }
                playlist[@"public"] = object[@"STATUS"] ? @([object[@"STATUS"] integerValue] != 1) : @YES;
                id explicitOwner = object[@"owned"] ?: object[@"is_owner"] ?: object[@"isOwner"];
                NSDictionary *owner = [object[@"USER"] isKindOfClass:[NSDictionary class]] ? object[@"USER"] : ([object[@"user"] isKindOfClass:[NSDictionary class]] ? object[@"user"] : nil);
                NSString *ownerID = [self wa_string:owner[@"ID"]] ?: [self wa_string:owner[@"id"]] ?: [self wa_string:object[@"USER_ID"]] ?: [self wa_string:object[@"user_id"]];
                BOOL owned = explicitOwner ? [explicitOwner boolValue] : (!ownerID.length || [ownerID isEqualToString:self.userIdentifier]);
                playlist[@"owned"] = @(owned);
                [items addObject:playlist];
            }
            [self wa_dispatchMain:^{ if (completion) completion(items, error); }];
        }];
    }];
}

- (void)playlistWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion {
    [self wa_callMethod:@"deezer.pagePlaylist" parameters:@{ @"playlist_id": identifier ?: @"", @"lang": @"en", @"header": @YES, @"tab": @0, @"nb": @100, @"tags": @YES, @"start": @0 } retry:YES completion:^(NSDictionary *json, NSError *error) {
        NSDictionary *results = [json[@"results"] isKindOfClass:[NSDictionary class]] ? json[@"results"] : @{};
        NSDictionary *data = [results[@"DATA"] isKindOfClass:[NSDictionary class]] ? results[@"DATA"] : @{};
        NSArray *songs = [results[@"SONGS"] isKindOfClass:[NSDictionary class]] && [results[@"SONGS"][@"data"] isKindOfClass:[NSArray class]] ? results[@"SONGS"][@"data"] : @[];
        NSMutableDictionary *playlist = [NSMutableDictionary dictionaryWithDictionary:data];
        playlist[@"id"] = [self wa_string:data[@"PLAYLIST_ID"]] ?: identifier ?: @"";
        NSString *title = [self wa_string:data[@"TITLE"]] ?: [self wa_string:data[@"title"]] ?: @"Playlist";
        playlist[@"title"] = title; playlist[@"name"] = title; playlist[@"description"] = [self wa_string:data[@"DESCRIPTION"]] ?: @""; playlist[@"public"] = data[@"STATUS"] ? @([data[@"STATUS"] integerValue] != 1) : @YES;
        NSMutableArray *normalizedSongs = [NSMutableArray array];
        for (NSDictionary *song in songs) { NSDictionary *item = [self wa_songFromDictionary:song]; if (item) [normalizedSongs addObject:item]; }
        playlist[@"tracks"] = normalizedSongs;
        if (error || !data.count) {
            [self publicPlaylistWithIdentifier:identifier completion:^(NSDictionary *publicPlaylist, NSError *publicError) {
                if (publicPlaylist) [self wa_dispatchMain:^{ if (completion) completion(publicPlaylist, nil); }];
                else [self wa_dispatchMain:^{ if (completion) completion(playlist, error ?: publicError); }];
            }];
        } else [self wa_dispatchMain:^{ if (completion) completion(playlist, nil); }];
    }];
}

- (void)publicPlaylistWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion {
    NSString *escaped = [identifier stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.deezer.com/playlist/%@", escaped ?: identifier ?: @""]];
    [NSURLConnection sendAsynchronousRequest:waDeezerRequest(url, NSURLRequestUseProtocolCachePolicy) queue:[self wa_parseQueue] completionHandler:^(NSURLResponse *response, NSData *data, NSError *networkError) {
        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSError *responseError = [self wa_responseError:response networkError:networkError message:@"Unable to load Deezer playlist."];
        if (responseError || ![json isKindOfClass:[NSDictionary class]] || [json[@"error"] isKindOfClass:[NSDictionary class]] || !json[@"id"]) {
            [self wa_dispatchMain:^{ if (completion) completion(nil, responseError ?: [self errorWithMessage:@"Unable to load Deezer playlist." code:http.statusCode ?: 404]); }];
            return;
        }
        NSMutableDictionary *playlist = [NSMutableDictionary dictionary];
        NSString *title = [self wa_string:json[@"title"]] ?: @"Playlist";
        playlist[@"id"] = [self wa_string:json[@"id"]] ?: identifier ?: @""; playlist[@"title"] = title; playlist[@"name"] = title;
        playlist[@"description"] = [self wa_string:json[@"description"]] ?: @""; playlist[@"public"] = @(![json[@"public"] respondsToSelector:@selector(boolValue)] || [json[@"public"] boolValue]);
        playlist[@"thumbnailURL"] = [self wa_string:json[@"picture_xl"]] ?: [self wa_string:json[@"picture_big"]] ?: @"";
        NSArray *tracks = [json[@"tracks"] isKindOfClass:[NSDictionary class]] && [json[@"tracks"][@"data"] isKindOfClass:[NSArray class]] ? json[@"tracks"][@"data"] : @[];
        NSMutableArray *normalized = [NSMutableArray arrayWithCapacity:tracks.count];
        for (NSDictionary *track in tracks) { NSDictionary *item = [self wa_songFromDictionary:track]; if (item) [normalized addObject:item]; }
        playlist[@"tracks"] = normalized;
        [self wa_dispatchMain:^{ if (completion) completion(playlist, nil); }];
    }];
}

- (void)createPlaylistNamed:(NSString *)name completion:(void (^)(NSDictionary *, NSError *))completion {
    [self wa_callMethod:@"playlist.create" parameters:@{ @"title": name ?: @"Playlist", @"description": @"", @"songs": @[], @"status": @1 } retry:YES completion:^(NSDictionary *json, NSError *error) {
        id identifier = json[@"results"] ?: json[@"id"];
        NSDictionary *playlist = @{ @"id": [self wa_string:identifier] ?: @"", @"title": name ?: @"Playlist", @"name": name ?: @"Playlist", @"public": @NO };
        [self wa_dispatchMain:^{ if (completion) completion(playlist, error); }];
    }];
}

- (void)updatePlaylistWithIdentifier:(NSString *)identifier changes:(NSDictionary *)changes completion:(void (^)(NSDictionary *, NSError *))completion {
    NSMutableDictionary *parameters = [NSMutableDictionary dictionaryWithDictionary:changes ?: @{}];
    parameters[@"playlist_id"] = [self wa_rawIdentifier:identifier] ?: @"";
    if (!parameters[@"title"] && parameters[@"name"]) parameters[@"title"] = parameters[@"name"];
    if (!parameters[@"description"]) parameters[@"description"] = @"";
    if (!parameters[@"status"]) parameters[@"status"] = @1;
    parameters[@"songs"] = @[];
    [self wa_callMethod:@"playlist.update" parameters:parameters retry:YES completion:^(NSDictionary *json, NSError *error) { [self wa_dispatchMain:^{ if (completion) completion(json, error); }]; }];
}

- (void)addSongIdentifier:(NSString *)songIdentifier toPlaylistIdentifier:(NSString *)playlistIdentifier completion:(void (^)(NSError *))completion {
    NSString *songID = [self wa_rawIdentifier:songIdentifier] ?: @"";
    NSString *playlistID = [self wa_rawIdentifier:playlistIdentifier] ?: @"";
    [self wa_callMethod:@"playlist.addSongs" parameters:@{ @"playlist_id": playlistID, @"songs": @[@[songID, @0]], @"offset": @-1 } retry:YES completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            NSString *msg = [error.localizedDescription lowercaseString];
            if ([msg rangeOfString:@"already"].location != NSNotFound || [msg rangeOfString:@"exist"].location != NSNotFound || json[@"error"] || json[@"errors"]) {
                NSString *jsonMsg = [NSString stringWithFormat:@"%@ %@ %@", json[@"error"][@"message"]?:@"", json[@"errors"]?:@"", json[@"results"]?:@""].lowercaseString;
                if ([jsonMsg rangeOfString:@"already"].location != NSNotFound || [jsonMsg rangeOfString:@"exist"].location != NSNotFound || [msg rangeOfString:@"already"].location != NSNotFound) {
                    [self wa_dispatchMain:^{ if (completion) completion(nil); }];
                    return;
                }
            }
        }
        (void)json; [self wa_dispatchMain:^{ if (completion) completion(error); }];
    }];
}

- (void)removeSongIdentifier:(NSString *)songIdentifier fromPlaylistIdentifier:(NSString *)playlistIdentifier completion:(void (^)(NSError *))completion {
    NSString *songID = [self wa_rawIdentifier:songIdentifier] ?: @"";
    NSString *playlistID = [self wa_rawIdentifier:playlistIdentifier] ?: @"";
    [self wa_callMethod:@"playlist.deleteSongs" parameters:@{ @"playlist_id": playlistID, @"songs": @[@[songID, @0]] } retry:YES completion:^(NSDictionary *json, NSError *error) { (void)json; [self wa_dispatchMain:^{ if (completion) completion(error); }]; }];
}

- (void)deletePlaylistWithIdentifier:(NSString *)identifier completion:(void (^)(NSError *))completion {
    [self wa_callMethod:@"playlist.delete" parameters:@{ @"PLAYLIST_ID": [self wa_rawIdentifier:identifier] ?: @"" } retry:YES completion:^(NSDictionary *json, NSError *error) { (void)json; [self wa_dispatchMain:^{ if (completion) completion(error); }]; }];
}

@end
#pragma clang diagnostic pop
