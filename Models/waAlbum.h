#import "waMediaItem.h"
@interface waAlbum : waMediaItem
@property (nonatomic, assign) NSUInteger trackCount;
- (id)initWithIdentifier:(NSString *)identifier title:(NSString *)title artist:(NSString *)artist trackCount:(NSUInteger)trackCount;
@end
