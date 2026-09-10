#import <UIKit/UIKit.h>

@interface waPlaylistViewController : UIViewController
- (id)initWithTitle:(NSString *)title items:(NSArray *)items;
- (id)initWithPlaylist:(NSDictionary *)playlist ownerIsCurrentUser:(BOOL)isOwner;
@end
