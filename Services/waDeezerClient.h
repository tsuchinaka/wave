#import <Foundation/Foundation.h>

extern NSString * const waDeezerAuthenticationDidChangeNotification;

@interface waDeezerClient : NSObject
@property (nonatomic, copy, readonly) NSString *userIdentifier;
@property (nonatomic, copy, readonly) NSString *userName;
@property (nonatomic, copy, readonly) NSString *favoritesPlaylistIdentifier;
+ (waDeezerClient *)sharedClient;
- (BOOL)isAuthenticated;
- (void)validateAuthenticationWithCompletion:(void (^)(BOOL valid, NSError *error))completion;
- (void)authorizeWithCompletion:(void (^)(NSDictionary *user, NSError *error))completion;
- (void)setARL:(NSString *)arl completion:(void (^)(NSError *error))completion;
- (void)logout;
- (void)userWithCompletion:(void (^)(NSDictionary *user, NSError *error))completion;
- (void)likedSongsWithCompletion:(void (^)(NSArray *songs, NSError *error))completion;
- (void)likedAlbumsWithCompletion:(void (^)(NSArray *albums, NSError *error))completion;
- (void)likedArtistsWithCompletion:(void (^)(NSArray *artists, NSError *error))completion;
- (void)searchQuery:(NSString *)query type:(NSString *)type completion:(void (^)(NSArray *items, NSError *error))completion;
- (void)searchQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit completion:(void (^)(NSArray *items, NSError *error))completion;
- (void)searchQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit index:(NSUInteger)index completion:(void (^)(NSArray *items, NSError *error))completion;
// Strict variant: appends strict=on so multi-token queries match exact
// phrases/fields instead of fuzzy ranking. Used as a second pass.
- (void)searchQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit index:(NSUInteger)index strict:(BOOL)strict completion:(void (^)(NSArray *items, NSError *error))completion;
// Search page preserving Deezer's pagination contract. The page dictionary
// contains `items`, `total`, and `next` so callers never have to guess the
// next offset from the number of rows returned.
- (void)searchPageForQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit index:(NSUInteger)index strict:(BOOL)strict completion:(void (^)(NSDictionary *page, NSError *error))completion;
// Cancels in-flight search requests. Their completions never fire.
- (void)cancelSearchRequests;
- (void)artistAlbumsWithID:(NSString *)artistID completion:(void (^)(NSArray *items, NSError *error))completion;
- (void)homeWithCompletion:(void (^)(NSDictionary *home, NSError *error))completion;
- (void)flowWithCompletion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)flowConfigWithIdentifier:(NSString *)identifier completion:(void (^)(NSArray *tracks, NSError *error))completion;
- (void)flowConfigsWithCompletion:(void (^)(NSArray *configs, NSError *error))completion;
- (void)smartTracklistWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *playlist, NSError *error))completion;
- (void)albumWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *album, NSError *error))completion;
- (void)artistWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *artist, NSError *error))completion;
- (void)setLiked:(BOOL)liked songIdentifier:(NSString *)identifier completion:(void (^)(NSError *error))completion;
- (void)setLiked:(BOOL)liked albumIdentifier:(NSString *)identifier completion:(void (^)(NSError *error))completion;
- (void)setLiked:(BOOL)liked artistIdentifier:(NSString *)identifier completion:(void (^)(NSError *error))completion;
- (void)setLiked:(BOOL)liked playlistIdentifier:(NSString *)identifier completion:(void (^)(NSError *error))completion;
- (void)logListenForSongIdentifier:(NSString *)identifier format:(NSString *)format listenedAt:(NSTimeInterval)timestamp completion:(void (^)(NSError *error))completion;
- (void)playlistsWithCompletion:(void (^)(NSArray *playlists, NSError *error))completion;
- (void)playlistWithIdentifier:(NSString *)identifier completion:(void (^)(NSDictionary *playlist, NSError *error))completion;
- (void)createPlaylistNamed:(NSString *)name completion:(void (^)(NSDictionary *playlist, NSError *error))completion;
- (void)updatePlaylistWithIdentifier:(NSString *)identifier changes:(NSDictionary *)changes completion:(void (^)(NSDictionary *playlist, NSError *error))completion;
- (void)addSongIdentifier:(NSString *)songIdentifier toPlaylistIdentifier:(NSString *)playlistIdentifier completion:(void (^)(NSError *error))completion;
- (void)removeSongIdentifier:(NSString *)songIdentifier fromPlaylistIdentifier:(NSString *)playlistIdentifier completion:(void (^)(NSError *error))completion;
- (void)deletePlaylistWithIdentifier:(NSString *)identifier completion:(void (^)(NSError *error))completion;
- (void)relatedForTrackID:(NSString *)trackID completion:(void (^)(NSArray *tracks, NSError *error))completion;
@end
