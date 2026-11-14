#import <Foundation/Foundation.h>
#import "waModel.h"
#import "waLyrics.h"

@class waPlaylist, waTrack, waAlbum, waArtist, waRadio, waGenre, waChart, waUser, waSection, waPodcast, waEpisode;

typedef enum {
    waSearchAll = 0,
    waSearchTracks,
    waSearchAlbums,
    waSearchArtists,
    waSearchPlaylists
} waSearchKind;

typedef enum {
    waQualityMP3128 = 0,
    waQualityMP3320 = 1,
    waQualityFLAC = 2,
    waQualityHIFI = 3
} waQuality;

extern NSString * const waSessionDidChangeNotification;
extern NSString * const waSessionAuthDidChangeNotification;

@interface waSession : NSObject
+ (waSession *)shared;

// auth
@property (nonatomic, readonly) BOOL authenticated;
@property (nonatomic, readonly) waUser *user;
@property (nonatomic, readonly) BOOL busy;
- (void)restoreWithCompletion:(void (^)(BOOL ok, NSError *error))completion;
- (void)loginWithARL:(NSString *)arl completion:(void (^)(waUser *user, NSError *error))completion;
- (void)logout;

// quality: computed from the account, never above what the ARL grants
@property (nonatomic, readonly) waQuality maximumQuality;
@property (nonatomic, assign) waQuality preferredQuality;
- (waQuality)downloadQuality;
- (NSString *)qualityName:(waQuality)quality;
- (NSString *)qualityShortName:(waQuality)quality;
+ (NSArray *)formatsForQuality:(waQuality)quality;
+ (NSString *)extensionForFormat:(NSString *)format;

// catalog
- (void)homeWithCompletion:(void (^)(NSArray *sections, NSError *error))completion;
- (void)search:(NSString *)query kind:(waSearchKind)kind index:(NSUInteger)index completion:(void (^)(NSArray *items, NSUInteger total, NSError *error))completion;
- (void)searchSuggestions:(NSString *)query completion:(void (^)(NSArray *items))completion;
- (void)chartWithCompletion:(void (^)(waChart *chart, NSError *error))completion;
- (void)editorialWithCompletion:(void (^)(NSArray *albums, NSError *error))completion;
- (void)genresWithCompletion:(void (^)(NSArray *genres, NSError *error))completion;
- (void)artistsForGenre:(NSString *)genreID completion:(void (^)(NSArray *artists, NSError *error))completion;
- (void)album:(NSString *)albumID completion:(void (^)(waAlbum *album, NSError *error))completion;
- (void)artist:(NSString *)artistID completion:(void (^)(waArtist *artist, NSError *error))completion;
- (void)artistTop:(NSString *)artistID completion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)artistAlbums:(NSString *)artistID completion:(void (^)(NSArray *albums, NSError *error))completion;
- (void)artistRelated:(NSString *)artistID completion:(void (^)(NSArray *artists, NSError *error))completion;
- (void)playlist:(NSString *)playlistID completion:(void (^)(waPlaylist *playlist, NSError *error))completion;
- (void)track:(NSString *)trackID completion:(void (^)(waTrack *track, NSError *error))completion;
- (void)radioListWithCompletion:(void (^)(NSArray *radios, NSError *error))completion;
- (void)radioTracks:(NSString *)radioID completion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)flowWithCompletion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)recommendationsWithCompletion:(void (^)(NSArray *albums, NSArray *artists, NSError *error))completion;
- (void)historyWithCompletion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)lyricsForTrack:(waTrack *)track completion:(void (^)(waLyrics *lyrics, NSError *error))completion;
- (void)streamURLForTrack:(waTrack *)track completion:(void (^)(NSURL *url, waQuality granted, NSError *error))completion;

// library / account mutations
- (void)setLiked:(BOOL)liked track:(waTrack *)track completion:(void (^)(BOOL ok, NSError *error))completion;
- (void)setLiked:(BOOL)liked album:(waAlbum *)album completion:(void (^)(BOOL ok, NSError *error))completion;
- (void)setLiked:(BOOL)liked artist:(waArtist *)artist completion:(void (^)(BOOL ok, NSError *error))completion;
- (void)setLiked:(BOOL)liked playlist:(waPlaylist *)playlist completion:(void (^)(BOOL ok, NSError *error))completion;
- (void)lovedTracksWithCompletion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)lovedAlbumsWithCompletion:(void (^)(NSArray *albums, NSError *error))completion;
- (void)lovedArtistsWithCompletion:(void (^)(NSArray *artists, NSError *error))completion;
- (void)userPlaylistsWithCompletion:(void (^)(NSArray *playlists, NSError *error))completion;
- (void)createPlaylistNamed:(NSString *)name completion:(void (^)(waPlaylist *playlist, NSError *error))completion;
- (void)deletePlaylist:(waPlaylist *)playlist completion:(void (^)(BOOL ok, NSError *error))completion;
- (void)renamePlaylist:(waPlaylist *)playlist to:(NSString *)name completion:(void (^)(BOOL ok, NSError *error))completion;
- (void)addTrack:(waTrack *)track toPlaylist:(waPlaylist *)playlist completion:(void (^)(BOOL ok, NSError *error))completion;
- (void)removeTrack:(waTrack *)track fromPlaylist:(waPlaylist *)playlist completion:(void (^)(BOOL ok, NSError *error))completion;
- (void)historyLogTrack:(waTrack *)track completion:(void (^)(NSError *error))completion;
- (void)rememberTrack:(waTrack *)track;

// artwork cache (thumbnails are decoded off the main thread; callbacks main)
- (void)loadArtwork:(NSString *)url size:(CGSize)size completion:(void (^)(UIImage *image))completion;
- (void)loadArtwork:(NSString *)url size:(CGSize)size owner:(id)owner completion:(void (^)(UIImage *image))completion;
- (void)cancelArtworkForOwner:(id)owner;
- (UIImage *)cachedArtwork:(NSString *)url size:(CGSize)size;
- (NSString *)localArtworkPathForTrack:(waTrack *)track;
- (void)hydrateTrack:(waTrack *)track completion:(void (^)(waTrack *track))completion;

// playback facade
- (void)playTracks:(NSArray *)tracks startAt:(NSUInteger)index context:(NSString *)context;
- (void)playTrack:(waTrack *)track;
- (void)playRadio:(waRadio *)radio completion:(void (^)(NSError *error))completion;
- (void)playFlowWithCompletion:(void (^)(NSError *error))completion;

// Full public REST catalog (api.deezer.com) + ARL gateway.
- (void)albumFans:(NSString *)albumID completion:(void (^)(NSArray *users, NSError *error))completion;
- (void)artistFans:(NSString *)artistID completion:(void (^)(NSArray *users, NSError *error))completion;
- (void)artistPlaylists:(NSString *)artistID completion:(void (^)(NSArray *playlists, NSError *error))completion;
- (void)artistRadio:(NSString *)artistID completion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)artistComments:(NSString *)artistID completion:(void (^)(NSArray *comments, NSError *error))completion;
- (void)chartWithIdentifier:(NSString *)chartID completion:(void (^)(waChart *chart, NSError *error))completion;
- (void)editorialsWithCompletion:(void (^)(NSArray *editorials, NSError *error))completion;
- (void)editorialSelection:(NSString *)editorialID completion:(void (^)(NSArray *albums, NSError *error))completion;
- (void)editorialCharts:(NSString *)editorialID completion:(void (^)(waChart *chart, NSError *error))completion;
- (void)genreRadios:(NSString *)genreID completion:(void (^)(NSArray *radios, NSError *error))completion;
- (void)playlistFans:(NSString *)playlistID completion:(void (^)(NSArray *users, NSError *error))completion;
- (void)playlistComments:(NSString *)playlistID completion:(void (^)(NSArray *comments, NSError *error))completion;
- (void)podcastsWithCompletion:(void (^)(NSArray *podcasts, NSError *error))completion;
- (void)podcast:(NSString *)podcastID completion:(void (^)(waPodcast *podcast, NSError *error))completion;
- (void)podcastEpisodes:(NSString *)podcastID completion:(void (^)(NSArray *episodes, NSError *error))completion;
- (void)episode:(NSString *)episodeID completion:(void (^)(waEpisode *episode, NSError *error))completion;
- (void)radioGenresWithCompletion:(void (^)(NSArray *genres, NSError *error))completion;
- (void)radioTopWithCompletion:(void (^)(NSArray *radios, NSError *error))completion;
- (void)radioListsWithCompletion:(void (^)(NSArray *radios, NSError *error))completion;
- (void)searchPodcasts:(NSString *)query completion:(void (^)(NSArray *podcasts, NSError *error))completion;
- (void)searchRadio:(NSString *)query completion:(void (^)(NSArray *radios, NSError *error))completion;
- (void)searchUsers:(NSString *)query completion:(void (^)(NSArray *users, NSError *error))completion;
- (void)user:(NSString *)userID completion:(void (^)(NSDictionary *user, NSError *error))completion;
- (void)userPlaylists:(NSString *)userID completion:(void (^)(NSArray *playlists, NSError *error))completion;
- (void)userAlbums:(NSString *)userID completion:(void (^)(NSArray *albums, NSError *error))completion;
- (void)userArtists:(NSString *)userID completion:(void (^)(NSArray *artists, NSError *error))completion;
- (void)userTracks:(NSString *)userID completion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)userFollowings:(NSString *)userID completion:(void (^)(NSArray *users, NSError *error))completion;
- (void)userFollowers:(NSString *)userID completion:(void (^)(NSArray *users, NSError *error))completion;
- (void)userChart:(NSString *)userID completion:(void (^)(waChart *chart, NSError *error))completion;
- (void)userFlow:(NSString *)userID completion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)recommendTracksWithCompletion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)recommendAlbumsWithCompletion:(void (^)(NSArray *albums, NSError *error))completion;
- (void)recommendArtistsWithCompletion:(void (^)(NSArray *artists, NSError *error))completion;
- (void)recommendPlaylistsWithCompletion:(void (^)(NSArray *playlists, NSError *error))completion;
- (void)recommendRadiosWithCompletion:(void (^)(NSArray *radios, NSError *error))completion;
- (void)optionsWithCompletion:(void (^)(NSDictionary *options, NSError *error))completion;
- (void)albumTracks:(NSString *)albumID completion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)playlistTracks:(NSString *)playlistID completion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)searchAll:(NSString *)query completion:(void (^)(NSArray *tracks, NSArray *albums, NSArray *artists, NSArray *playlists, NSError *error))completion;
- (void)commentsForPath:(NSString *)path completion:(void (^)(NSArray *comments, NSError *error))completion;
@end
