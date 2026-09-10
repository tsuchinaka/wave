#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, waMediaItemType) {
    waMediaItemTypeSong,
    waMediaItemTypeAlbum,
    waMediaItemTypeArtist,
    waMediaItemTypePlaylist
};

@interface waMediaItem : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *thumbnailURL;
@property (nonatomic, copy) NSString *trackId;
@property (nonatomic, copy) NSString *isrc;
@property (nonatomic, copy) NSString *artistIdentifier;
@property (nonatomic, copy) NSString *albumIdentifier;
@property (nonatomic, copy) NSString *artistName;
@property (nonatomic, copy) NSString *albumName;
@property (nonatomic, copy) NSString *releaseYear;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) waMediaItemType type;
@property (nonatomic, assign, getter=isLiked) BOOL liked;
@property (nonatomic, assign, getter=isExplicit) BOOL explicit;
@property (nonatomic, assign, getter=isGeniusRecommended) BOOL geniusRecommended;
@property (nonatomic, copy) NSDictionary *metadata;
- (id)initWithIdentifier:(NSString *)identifier title:(NSString *)title subtitle:(NSString *)subtitle type:(waMediaItemType)type;
- (NSDictionary *)dictionaryRepresentation;
+ (id)itemWithDictionary:(NSDictionary *)dictionary;
// Canonical https://www.deezer.com/{track,album,artist,playlist}/{id} link,
// or nil when no numeric Deezer identifier is available.
- (NSURL *)deezerURL;
@end
