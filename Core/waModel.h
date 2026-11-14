#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern NSString * const waTrackType;
extern NSString * const waAlbumType;
extern NSString * const waArtistType;
extern NSString * const waPlaylistType;
extern NSString * const waRadioType;
extern NSString * const waPodcastType;
extern NSString * const waEpisodeType;
extern NSString * const waUserType;

@interface waItem : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *kind;          // track|album|artist|playlist|radio
@property (nonatomic, copy) NSString *artworkURL;    // cover / picture (big)
@property (nonatomic, copy) NSString *artworkSmallURL;
@property (nonatomic, copy) NSString *artworkXLURL;
@property (nonatomic, assign) BOOL explicitLyrics;
+ (id)itemWithDictionary:(NSDictionary *)dict kind:(NSString *)kind;
- (NSDictionary *)dictionary;
- (NSString *)bestArtworkURL;
- (NSString *)artworkURLForSide:(CGFloat)side;
@end

@interface waTrack : waItem
@property (nonatomic, copy) NSString *albumTitle;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy) NSString *albumIdentifier;
@property (nonatomic, copy) NSString *artistIdentifier;
@property (nonatomic, copy) NSString *isrc;
@property (nonatomic, copy) NSString *trackToken;
@property (nonatomic, copy) NSString *md5;
@property (nonatomic, copy) NSString *releaseDate;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) NSInteger trackPosition;
@property (nonatomic, assign) NSInteger diskNumber;
@property (nonatomic, assign) NSInteger bpm;
@property (nonatomic, assign) BOOL readable;
@property (nonatomic, assign) BOOL streamable;
@property (nonatomic, assign) BOOL preview;
@property (nonatomic, copy) NSString *previewURL;
@property (nonatomic, strong) NSArray *contributors;
@property (nonatomic, assign) BOOL liked;
- (void)mergeFrom:(waTrack *)other;
- (BOOL)needsHydration;
@end

@interface waAlbum : waItem
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy) NSString *artistIdentifier;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *upc;
@property (nonatomic, copy) NSString *releaseDate;
@property (nonatomic, copy) NSString *recordType;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, assign) NSInteger roleId;
@property (nonatomic, assign) NSInteger trackCount;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, strong) NSArray *tracks;
@property (nonatomic, assign) BOOL liked;
@end

@interface waArtist : waItem
@property (nonatomic, assign) NSInteger albumCount;
@property (nonatomic, assign) NSInteger fanCount;
@property (nonatomic, copy) NSString *role;
@property (nonatomic, strong) NSArray *topTracks;
@property (nonatomic, strong) NSArray *albums;
@property (nonatomic, strong) NSArray *related;
@property (nonatomic, assign) BOOL liked;
@end

@interface waPlaylist : waItem
@property (nonatomic, copy) NSString *playlistDescription;
@property (nonatomic, copy) NSString *creatorName;
@property (nonatomic, copy) NSString *creatorIdentifier;
@property (nonatomic, assign) NSInteger trackCount;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) BOOL publicPlaylist;
@property (nonatomic, assign) BOOL owned;
@property (nonatomic, strong) NSArray *tracks;
@end

@interface waRadio : waItem
@property (nonatomic, copy) NSString *radioDescription;
@end

@interface waGenre : waItem
@end

@interface waPodcast : waItem
@property (nonatomic, copy) NSString *podcastDescription;
@property (nonatomic, assign) NSInteger fans;
@property (nonatomic, assign) BOOL available;
@property (nonatomic, strong) NSArray *episodes;
@end

@interface waEpisode : waItem
@property (nonatomic, copy) NSString *podcastTitle;
@property (nonatomic, copy) NSString *podcastIdentifier;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, copy) NSString *releaseDate;
@end

@interface waComment : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *authorName;
@property (nonatomic, copy) NSString *authorIdentifier;
@property (nonatomic, assign) NSTimeInterval date;
@end

@interface waChart : NSObject
@property (nonatomic, strong) NSArray *tracks;
@property (nonatomic, strong) NSArray *albums;
@property (nonatomic, strong) NSArray *artists;
@property (nonatomic, strong) NSArray *playlists;
@end

@interface waSection : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *layout;   // hero|square|circle|list|grid
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, assign) BOOL showsMore;
@end

@interface waUser : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *email;
@property (nonatomic, copy) NSString *pictureURL;
@property (nonatomic, copy) NSString *country;
@property (nonatomic, assign) BOOL verified;
@property (nonatomic, assign) BOOL canStreamLossless;
@property (nonatomic, assign) BOOL canStreamHifi;
@property (nonatomic, strong) NSArray *offers;
- (void)fillWithData:(NSDictionary *)dict;
@end

@interface waHomePayload : NSObject
@property (nonatomic, strong) NSArray *sections;
@end

NSInteger waAlbumDiskNumber(waTrack *track);
BOOL waAlbumHasMultipleDisks(NSArray *tracks);
NSArray *waSortedAlbumTracks(NSArray *tracks);
