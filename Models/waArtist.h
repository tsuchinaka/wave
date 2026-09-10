#import "waMediaItem.h"
@interface waArtist : waMediaItem
@property (nonatomic, assign) NSUInteger songCount;
- (id)initWithIdentifier:(NSString *)identifier title:(NSString *)title songCount:(NSUInteger)songCount;
@end
