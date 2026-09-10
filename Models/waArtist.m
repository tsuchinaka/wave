#import "waArtist.h"
@implementation waArtist
- (id)initWithIdentifier:(NSString *)identifier title:(NSString *)title songCount:(NSUInteger)songCount { if ((self = [super initWithIdentifier:identifier title:title subtitle:@"Artist" type:waMediaItemTypeArtist])) _songCount = songCount; return self; }
@end
