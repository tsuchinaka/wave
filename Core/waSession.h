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
+ (NSArray *)formatsForQuality:(waQuality)quality;
+ (NSString *)extensionForFormat:(NSString *)format;

// catalog
- (void)homeWithCompletion:(void (^)(NSArray *sections, NSError *error))completion;
- (void)search:(NSString *)query kind:(waSearchKind)kind index:(NSUInteger)index completion:(void (^)(NSArray *items, NSUInteger total, NSError *error))completion;
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
- (void)artistPlaylists:(NSString *)artistID completion:(void (^)(NSArray *playlists, NSError *error))completion;
- (void)artistRadio:(NSString *)artistID completion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)geniusForTrack:(waTrack *)track completion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)radioTopWithCompletion:(void (^)(NSArray *radios, NSError *error))completion;
- (void)user:(NSString *)userID completion:(void (^)(NSDictionary *user, NSError *error))completion;
- (void)recommendAlbumsWithCompletion:(void (^)(NSArray *albums, NSError *error))completion;
- (void)recommendArtistsWithCompletion:(void (^)(NSArray *artists, NSError *error))completion;
- (void)albumTracks:(NSString *)albumID completion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)playlistTracks:(NSString *)playlistID completion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)searchAll:(NSString *)query completion:(void (^)(NSArray *tracks, NSArray *albums, NSArray *artists, NSArray *playlists, NSError *error))completion;
- (void)searchSuggest:(NSString *)query completion:(void (^)(NSArray *artists, NSArray *tracks, NSArray *albums, NSArray *playlists, NSError *error))completion;
- (void)commentsForPath:(NSString *)path completion:(void (^)(NSArray *comments, NSError *error))completion;
@end
