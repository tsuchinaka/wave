#import <UIKit/UIKit.h>
#import "../Models/waMediaItem.h"

@interface waMediaResultsViewController : UITableViewController
- (id)initWithItems:(NSArray *)items type:(waMediaItemType)type title:(NSString *)title;
- (id)initWithItems:(NSArray *)items type:(waMediaItemType)type title:(NSString *)title query:(NSString *)query;
- (id)initWithItems:(NSArray *)items type:(waMediaItemType)type title:(NSString *)title query:(NSString *)query nextURL:(NSString *)nextURL totalCount:(NSUInteger)totalCount;
@end
