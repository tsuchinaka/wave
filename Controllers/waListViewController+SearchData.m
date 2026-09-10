#import "waListViewController.h"
#import "waListViewController+SearchPrivate.h"
#import "../Models/waMediaItem.h"
#import "../Services/waAPIClient.h"

#ifndef WA_SEARCH_DATA_TYPES
#define WA_SEARCH_DATA_TYPES
typedef NS_ENUM(NSInteger, waSearchFilter) {
    waSearchFilterAll = 0,
    waSearchFilterOffline,
    waSearchFilterTracks,
    waSearchFilterAlbums,
    waSearchFilterPlaylists,
    waSearchFilterArtists
};
typedef NS_ENUM(NSInteger, waSearchDisplaySection) {
    waSearchDisplayTracks = waMediaItemTypeSong,
    waSearchDisplayAlbums = waMediaItemTypeAlbum,
    waSearchDisplayArtists = waMediaItemTypeArtist,
    waSearchDisplayPlaylists = waMediaItemTypePlaylist
};
#endif

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

// Word-boundary hit: match at the start or right after a separator, so
// "hell" boosts "Hello" but not "Othello".
static BOOL waTokenAtWordBoundary(NSString *field, NSRange found) {
    if (found.location == 0) return YES;
    if (found.location == NSNotFound || found.location >= field.length) return NO;
    unichar prev = [field characterAtIndex:found.location - 1];
    return prev == ' ' || prev == '-' || prev == '_' || prev == '(' || prev == '/' || prev == '.';
}

// Bounded Levenshtein returning 0, 1 or 2+. Two rows, tiny strings only.
static NSUInteger waCappedEditDistance(NSString *a, NSString *b) {
    NSUInteger m = a.length, n = b.length;
    if (m > n) { NSString *t = a; a = b; b = t; NSUInteger u = m; m = n; n = u; }
    if (n - m > 1 || n >= 48) return 2;
    NSUInteger prev[48], cur[48];
    for (NSUInteger j = 0; j <= n; j++) prev[j] = j;
    for (NSUInteger i = 1; i <= m; i++) {
        cur[0] = i;
        unichar ca = [a characterAtIndex:i - 1];
        NSUInteger rowMin = cur[0];
        for (NSUInteger j = 1; j <= n; j++) {
            NSUInteger cost = (ca == [b characterAtIndex:j - 1]) ? 0 : 1;
            NSUInteger deletion = prev[j] + 1;
            NSUInteger insertion = cur[j - 1] + 1;
            NSUInteger substitution = prev[j - 1] + cost;
            NSUInteger best = MIN(deletion, MIN(insertion, substitution));
            cur[j] = best;
            if (best < rowMin) rowMin = best;
        }
        if (rowMin > 1) return 2;
        for (NSUInteger j = 0; j <= n; j++) prev[j] = cur[j];
    }
    return MIN((NSUInteger)2, prev[n]);
}

// 1-edit typo of the token against any single word of the field.
// Tokens under 4 chars are too ambiguous for fuzzy matching.
static BOOL waTokenTypoInField(NSString *field, NSString *token) {
    if (token.length < 4) return NO;
    NSArray *words = [field componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSString *word in words) {
        if (word.length < 4) continue;
        if (ABS((NSInteger)word.length - (NSInteger)token.length) > 1) continue;
        if (waCappedEditDistance(word, token) <= 1) return YES;
    }
    return NO;
}

// exactW for equality, containsW+150 for a word-boundary hit,
// containsW for a plain contains, containsW/2 for a 1-edit typo.
static NSInteger waFieldTokenScore(NSString *field, NSString *token, NSInteger exactW, NSInteger containsW) {
    if (!field.length || !token.length) return 0;
    if ([field isEqualToString:token]) return exactW;
    NSRange found = [field rangeOfString:token];
    if (found.location != NSNotFound) {
        if (waTokenAtWordBoundary(field, found)) return MIN(exactW - 1, containsW + 150);
        return containsW;
    }
    if (waTokenTypoInField(field, token)) return containsW / 2;
    return 0;
}

@implementation waListViewController (SearchData)

- (BOOL)hasResults {
    if (self.selectedFilter == waSearchFilterOffline) return self.offlineItems.count > 0;
    for (NSArray *section in self.sections) if (section.count) return YES;
    return NO;
}

- (NSInteger)mediaTypeForDisplaySection:(NSInteger)section {
    if (section < 0 || section >= self.displaySections.count) return NSNotFound;
    return [self.displaySections[section] integerValue];
}

- (NSArray *)itemsForDisplaySection:(NSInteger)section {
    NSInteger mediaType = [self mediaTypeForDisplaySection:section];
    if (self.selectedFilter == waSearchFilterOffline) return mediaType == waMediaItemTypeSong ? (self.offlineItems ?: @[]) : @[];
    if (mediaType == NSNotFound || mediaType < 0 || mediaType >= self.sections.count) return @[];
    // All uses compact Home-like previews. A selected filter must expose the
    // full API response instead of the preview array.
    return self.selectedFilter == waSearchFilterAll ? self.sections[mediaType] : self.allSections[mediaType];
}

- (BOOL)isHorizontalDisplaySection:(NSInteger)section {
    if (self.selectedFilter != waSearchFilterAll || section >= self.displaySections.count) return NO;
    NSInteger displaySection = [self.displaySections[section] integerValue];
    return displaySection == waSearchDisplayAlbums || displaySection == waSearchDisplayArtists || displaySection == waSearchDisplayPlaylists;
}

- (NSString *)normalizedSearchText:(NSString *)text {
    NSString *value = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [[value lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:[NSLocale currentLocale]];
}

- (waMediaItem *)bestArtistForQuery:(NSString *)query artists:(NSArray *)artists {
    if (!artists.count) return nil;
    NSString *normalizedQuery = [self normalizedSearchText:query];
    waMediaItem *best = nil;
    NSInteger bestScore = NSIntegerMin;
    long long bestFans = -1;
    for (waMediaItem *artist in artists) {
        if (![artist isKindOfClass:[waMediaItem class]]) continue;
        NSString *name = [self normalizedSearchText:artist.title];
        if (!name.length) continue;
        NSInteger score = 0;
        if ([name isEqualToString:normalizedQuery]) score = 1000;
        else if ([name hasPrefix:normalizedQuery]) score = 800;
        else if ([normalizedQuery hasPrefix:name]) score = 700;
        else if ([name rangeOfString:normalizedQuery].location != NSNotFound) score = 500;
        else score = 100;
        // Tie-break by Deezer popularity so an obscure "contains" match
        // never beats the famous artist (e.g. Metallica 8M fans vs tribute).
        id fansValue = artist.metadata[@"nb_fan"] ?: artist.metadata[@"fans"];
        long long fans = [fansValue respondsToSelector:@selector(longLongValue)] ? [fansValue longLongValue] : 0;
        if (!best || score > bestScore || (score == bestScore && fans > bestFans)) { best = artist; bestScore = score; bestFans = fans; }
    }
    return best;
}

- (NSArray *)rankedSearchItems:(NSArray *)items query:(NSString *)query type:(NSInteger)type {
    if (!items.count || !query.length) return items;
    NSString *normalizedQuery = [self normalizedSearchText:query];
    NSArray *rawTokens = [normalizedQuery componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *token in rawTokens) if (token.length) [tokens addObject:token];
    if (!tokens.count) return items;
    NSMutableArray *decorated = [NSMutableArray arrayWithCapacity:items.count];
    NSUInteger position = 0;
    for (waMediaItem *item in items) {
        if (![item isKindOfClass:[waMediaItem class]]) continue;
        NSInteger score = 0;
        NSString *artist = [self normalizedSearchText:item.artistName.length ? item.artistName : item.subtitle];
        NSString *title = [self normalizedSearchText:item.title];
        NSString *album = [self normalizedSearchText:item.albumName];
        // Fixed: each token can match any field (artist/title/album) - no head/tail split.
        // This fixes "Sorry Justin Bieber" where head="sorry" doesn't match artist "justin bieber".
        for (NSString *token in tokens) {
            NSInteger best = 0;
            if (type == waMediaItemTypeSong) {
                best = MAX(waFieldTokenScore(artist, token, 1000, 500),
                       MAX(waFieldTokenScore(title, token, 900, 400),
                           waFieldTokenScore(album, token, 800, 300)));
            } else if (type == waMediaItemTypeAlbum) {
                best = MAX(waFieldTokenScore(title, token, 1000, 500),
                           waFieldTokenScore(artist, token, 800, 300));
            } else if (type == waMediaItemTypeArtist) {
                best = waFieldTokenScore(title.length ? title : artist, token, 1000, 500);
            } else if (type == waMediaItemTypePlaylist) {
                best = waFieldTokenScore(title, token, 900, 400);
            }
            score += best;
        }
        // Tie-break: songs by Deezer rank, artists by fan count so duplicated
        // names (an obscure "Adele" vs the 15M-fan one) resolve sensibly.
        long long secondary;
        if (type == waMediaItemTypeArtist) {
            id fansValue = item.metadata[@"nb_fan"] ?: item.metadata[@"fans"];
            secondary = [fansValue respondsToSelector:@selector(longLongValue)] ? [fansValue longLongValue] : 0;
        } else {
            id rankValue = item.metadata[@"rank"];
            secondary = [rankValue respondsToSelector:@selector(longLongValue)] ? [rankValue longLongValue] : 0;
        }
        [decorated addObject:@{ @"item": item, @"score": @(score), @"secondary": @(secondary), @"index": @(position) }];
        position += 1;
    }
    [decorated sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger sa = [a[@"score"] integerValue], sb = [b[@"score"] integerValue];
        if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
        long long ra = [a[@"secondary"] longLongValue], rb = [b[@"secondary"] longLongValue];
        if (ra != rb) return ra > rb ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"index"] compare:b[@"index"]];
    }];
    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:decorated.count];
    for (NSDictionary *entry in decorated) [ordered addObject:entry[@"item"]];
    return ordered;
}

- (void)mergeArtistDiscographyForArtist:(waMediaItem *)artist query:(NSString *)query generation:(NSUInteger)generation {
    // Deezer's album search index omits famous albums entirely ("adele 19"
    // never returns the album "19" under any query variant). The artist's
    // official discography endpoint does contain them, so for multi-token
    // queries fetch it and merge the titles matching the query tail into the
    // album section; the shared re-rank then orders the true hits first.
    if (!artist.identifier.length || !query.length) return;
    NSString *normalizedQuery = [self normalizedSearchText:query];
    NSArray *rawTokens = [normalizedQuery componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *token in rawTokens) if (token.length) [tokens addObject:token];
    if (tokens.count < 2) return;
    NSArray *tail = [tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)];
    __weak waListViewController *weakSelf = self;
    [[waAPIClient sharedClient] artistAlbumsWithID:artist.identifier completion:^(NSArray *albums, NSError *error) {
        waListViewController *controller = weakSelf;
        if (!controller || error || !albums.count) return;
        if (generation != controller.searchGeneration || ![query isEqualToString:controller.query]) return;
        NSMutableSet *known = [NSMutableSet set];
        for (waMediaItem *existing in controller.allSections[waMediaItemTypeAlbum]) {
            NSString *key = existing.trackId.length ? existing.trackId : existing.identifier;
            if (key.length) [known addObject:key];
        }
        NSMutableArray *extras = [NSMutableArray arrayWithCapacity:tail.count];
        for (waMediaItem *album in albums) {
            if (![album isKindOfClass:[waMediaItem class]]) continue;
            NSString *key = album.trackId.length ? album.trackId : album.identifier;
            if (key.length && [known containsObject:key]) continue;
            NSString *title = [controller normalizedSearchText:album.title];
            BOOL matches = NO;
            for (NSString *token in tail) {
                if (title.length && ([title isEqualToString:token] || [title rangeOfString:token].location != NSNotFound)) { matches = YES; break; }
            }
            if (!matches) continue;
            album.type = waMediaItemTypeAlbum;
            if (key.length) [known addObject:key];
            [extras addObject:album];
        }
        if (!extras.count) return;
        NSMutableArray *albumList = [controller.allSections[waMediaItemTypeAlbum] mutableCopy];
        [albumList addObjectsFromArray:extras];
        NSArray *reranked = [controller rankedSearchItems:albumList query:query type:waMediaItemTypeAlbum];
        NSMutableArray *allSections = [controller.allSections mutableCopy];
        allSections[waMediaItemTypeAlbum] = [reranked mutableCopy];
        controller.allSections = allSections;
        NSMutableArray *sections = [controller.sections mutableCopy];
        sections[waMediaItemTypeAlbum] = [[reranked subarrayWithRange:NSMakeRange(0, MIN(5, reranked.count))] mutableCopy];
        controller.sections = sections;
        NSMutableArray *more = [controller.hasMore mutableCopy];
        more[waMediaItemTypeAlbum] = @(reranked.count > 5);
        controller.hasMore = more;
        [controller.tableView reloadData];
    }];
}

- (void)rebuildDisplaySections {
    NSMutableArray *display = [NSMutableArray array];
    if (self.selectedFilter == waSearchFilterAll) {
        if ([self.sections[waMediaItemTypeSong] count]) [display addObject:@(waSearchDisplayTracks)];
        if ([self.sections[waMediaItemTypeAlbum] count]) [display addObject:@(waSearchDisplayAlbums)];
        if ([self.sections[waMediaItemTypePlaylist] count]) [display addObject:@(waSearchDisplayPlaylists)];
        if ([self.sections[waMediaItemTypeArtist] count]) [display addObject:@(waSearchDisplayArtists)];
    } else if (self.selectedFilter == waSearchFilterOffline) {
        if (self.offlineItems.count) [display addObject:@(waSearchDisplayTracks)];
    } else {
        NSInteger type = self.selectedFilter == waSearchFilterTracks ? waMediaItemTypeSong : (self.selectedFilter == waSearchFilterAlbums ? waMediaItemTypeAlbum : (self.selectedFilter == waSearchFilterPlaylists ? waMediaItemTypePlaylist : waMediaItemTypeArtist));
        if (type < self.sections.count && [self.sections[type] count]) [display addObject:@(type)];
    }
    self.displaySections = display;
}

- (NSString *)titleForDisplaySection:(NSInteger)section {
    NSInteger displaySection = section < self.displaySections.count ? [self.displaySections[section] integerValue] : NSNotFound;
    if (self.selectedFilter == waSearchFilterOffline && displaySection == waSearchDisplayTracks) return @"Offline";
    if (displaySection == waSearchDisplayTracks) return @"Tracks";
    if (displaySection == waSearchDisplayAlbums) return @"Albums";
    if (displaySection == waSearchDisplayPlaylists) return @"Playlists";
    if (displaySection == waSearchDisplayArtists) return @"Artists";
    return @"";
}

@end
#pragma clang diagnostic pop
