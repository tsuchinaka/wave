#import "waTableController.h"

@class waAlbum, waArtist, waPlaylist;

@interface waDetailController : waTableController
- (id)initWithAlbum:(waAlbum *)album;
- (id)initWithArtist:(waArtist *)artist;
- (id)initWithPlaylist:(waPlaylist *)playlist;
- (id)initWithAlbum:(waAlbum *)album downloaded:(BOOL)downloaded;
- (id)initWithPlaylist:(waPlaylist *)playlist downloaded:(BOOL)downloaded;
@property (nonatomic, readonly) BOOL downloaded;
@end
