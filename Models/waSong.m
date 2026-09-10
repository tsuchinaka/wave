#import "waSong.h"
@implementation waSong
- (id)initWithIdentifier:(NSString *)identifier title:(NSString *)title artist:(NSString *)artist albumIdentifier:(NSString *)albumIdentifier duration:(NSTimeInterval)duration { if ((self = [super initWithIdentifier:identifier title:title subtitle:artist type:waMediaItemTypeSong])) { self.albumIdentifier = albumIdentifier; self.duration = duration; } return self; }
- (NSDictionary *)dictionaryRepresentation { NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithDictionary:[super dictionaryRepresentation]]; [dictionary setObject:self.albumIdentifier ?: @"" forKey:@"albumIdentifier"]; [dictionary setObject:[NSNumber numberWithDouble:self.duration] forKey:@"duration"]; return dictionary; }
@end
