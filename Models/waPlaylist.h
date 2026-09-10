#import "waMediaItem.h"
@interface waPlaylist : waMediaItem
@property (nonatomic, strong) NSArray *songIdentifiers;
- (id)initWithIdentifier:(NSString *)identifier title:(NSString *)title songIdentifiers:(NSArray *)songIdentifiers;
@end
