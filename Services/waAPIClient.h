#import <Foundation/Foundation.h>
#import "../Models/waMediaItem.h"

void waNetworkActivityBegin(void);
void waNetworkActivityEnd(void);

@interface waAPIClient : NSObject
@property (nonatomic, copy) NSString *baseURL;
@property (nonatomic, assign) NSUInteger port;
+ (waAPIClient *)sharedClient;
- (BOOL)isAuthenticated;
- (void)requestPath:(NSString *)path method:(NSString *)method body:(NSDictionary *)body authenticated:(BOOL)authenticated completion:(void (^)(NSData *, NSHTTPURLResponse *, NSError *))completion;
- (void)logoutWithCompletion:(void (^)(NSError *))completion;
- (void)meWithCompletion:(void (^)(NSDictionary *, NSError *))completion;
- (void)updateCurrentUser:(NSDictionary *)changes completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)recordActivityForTrackId:(NSString *)trackId completion:(void (^)(NSError *))completion;
- (void)uploadAvatarJPEGData:(NSData *)data completion:(void (^)(NSError *))completion;
- (NSURL *)URLForPath:(NSString *)path;
- (void)searchQuery:(NSString *)query type:(NSString *)type completion:(void (^)(NSArray *, NSError *))completion;
- (void)searchQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit completion:(void (^)(NSArray *, NSError *))completion;
- (void)searchQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit index:(NSUInteger)index completion:(void (^)(NSArray *, NSError *))completion;
- (void)searchQuery:(NSString *)query type:(NSString *)type limit:(NSUInteger)limit index:(NSUInteger)index strict:(BOOL)strict completion:(void (^)(NSArray *, NSError *))completion;
- (void)cancelSearchRequests;
- (void)artistAlbumsWithID:(NSString *)artistID completion:(void (^)(NSArray *, NSError *))completion;
- (void)homeWithCompletion:(void (^)(NSDictionary *, NSError *))completion;
- (void)flowWithCompletion:(void (^)(NSArray *, NSError *))completion;
- (void)flowConfigWithIdentifier:(NSString *)identifier completion:(void (^)(NSArray *, NSError *))completion;
- (void)flowConfigsWithCompletion:(void (^)(NSArray *, NSError *))completion;
- (void)pingWithLatencyCompletion:(void (^)(NSTimeInterval, NSError *))completion;
- (void)likedSongsWithCompletion:(void (^)(NSDictionary *, NSError *))completion;
- (void)setLiked:(BOOL)liked song:(waMediaItem *)song completion:(void (^)(BOOL, NSError *))completion;
- (void)likedAlbumsWithCompletion:(void (^)(NSDictionary *, NSError *))completion;
- (void)likedArtistsWithCompletion:(void (^)(NSDictionary *, NSError *))completion;
- (void)setLiked:(BOOL)liked artist:(waMediaItem *)artist completion:(void (^)(BOOL, NSError *))completion;
- (void)setLiked:(BOOL)liked album:(waMediaItem *)album completion:(void (^)(BOOL, NSError *))completion;
- (void)setLiked:(BOOL)liked playlist:(waMediaItem *)playlist completion:(void (^)(BOOL, NSError *))completion;
- (void)playlistsWithCompletion:(void (^)(NSArray *, NSError *))completion;
- (void)playlistWithID:(NSString *)playlistID completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)updatePlaylistWithID:(NSString *)playlistID changes:(NSDictionary *)changes completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)createPlaylistNamed:(NSString *)name completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)addSong:(NSDictionary *)song toPlaylist:(NSString *)playlistID completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)removeSong:(NSString *)trackId fromPlaylist:(NSString *)playlistID completion:(void (^)(NSError *))completion;
- (void)deletePlaylist:(NSString *)playlistID completion:(void (^)(NSError *error))completion;
- (void)catalogType:(NSString *)type identifier:(NSString *)identifier completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)trackDetailsForTrackId:(NSString *)trackId completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)relatedForTrackId:(NSString *)trackId completion:(void (^)(NSArray *, NSError *))completion;
- (void)prefetchTrackForTrackId:(NSString *)trackId;
- (NSURL *)streamURLForTrackId:(NSString *)trackId ticketURL:(NSString *)ticketURL quality:(NSUInteger)quality;
- (NSURL *)flacStreamURLForTrackId:(NSString *)trackId;
// Compatibility wrapper using the current preference.
- (NSURL *)streamURLForTrackId:(NSString *)trackId ticketURL:(NSString *)ticketURL;
- (void)healthWithCompletion:(void (^)(NSDictionary *, NSError *))completion;
- (void)updatePresenceForItem:(waMediaItem *)item state:(NSString *)state completion:(void (^)(NSError *))completion;
- (void)clearPresenceWithCompletion:(void (^)(NSError *))completion;
- (void)lyricsForTrack:(NSString *)track artist:(NSString *)artist completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)lyricsForTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album length:(NSTimeInterval)length completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)lyricsForTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album length:(NSTimeInterval)length trackId:(NSString *)trackId isrc:(NSString *)isrc completion:(void (^)(NSDictionary *, NSError *))completion;
@end
