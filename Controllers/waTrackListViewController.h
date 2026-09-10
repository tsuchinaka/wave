#import <UIKit/UIKit.h>
@class waMediaItem;

@interface waTrackListViewController : UITableViewController

// Designated: generic list for LikedSongs, Downloads, or album/playlist detail
- (id)initWithTitle:(NSString *)title
              items:(NSArray *)items // array of waMediaItem or waDownload
         itemSource:(NSArray *(^)(void))itemSource // optional live source, called on reload
          deletable:(BOOL)deletable
        deleteBlock:(void (^)(waMediaItem *item, NSIndexPath *ip))deleteBlock;

@property (nonatomic, copy) NSString *contextTitle;

@end
