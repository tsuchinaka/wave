#import "waMediaItem.h"
@interface waSong : waMediaItem
- (id)initWithIdentifier:(NSString *)identifier title:(NSString *)title artist:(NSString *)artist albumIdentifier:(NSString *)albumIdentifier duration:(NSTimeInterval)duration;
@end
