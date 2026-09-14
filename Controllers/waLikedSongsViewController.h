#import <UIKit/UIKit.h>

@interface waLikedSongsViewController : UITableViewController
- (id)initWithSongs:(NSArray *)songs;
// Fill the list after the async liked-songs fetch lands, and toggle a spinner
// while it is still in flight (caller pushes the screen immediately).
- (void)updateSongs:(NSArray *)songs;
- (void)setLoadingActive:(BOOL)active;
@end
