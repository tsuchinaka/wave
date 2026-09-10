#import <UIKit/UIKit.h>
@interface waDownloadedAlbumDetailViewController : UITableViewController
- (id)initWithAlbumIdentifier:(NSString *)identifier title:(NSString *)title downloads:(NSArray *)downloads;
@end
