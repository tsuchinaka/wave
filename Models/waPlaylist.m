#import "waPlaylist.h"
@implementation waPlaylist
- (id)initWithIdentifier:(NSString *)identifier title:(NSString *)title songIdentifiers:(NSArray *)songIdentifiers { if ((self = [super initWithIdentifier:identifier title:title subtitle:@"Playlist" type:waMediaItemTypePlaylist])) _songIdentifiers = [songIdentifiers copy]; return self; }
@end
