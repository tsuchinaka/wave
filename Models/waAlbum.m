#import "waAlbum.h"
@implementation waAlbum
- (id)initWithIdentifier:(NSString *)identifier title:(NSString *)title artist:(NSString *)artist trackCount:(NSUInteger)trackCount { if ((self = [super initWithIdentifier:identifier title:title subtitle:artist type:waMediaItemTypeAlbum])) _trackCount = trackCount; return self; }
@end
