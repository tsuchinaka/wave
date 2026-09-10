#import <UIKit/UIKit.h>
#import "../Models/waMediaItem.h"

@interface waMediaDetailViewController : UIViewController
- (id)initWithMediaItem:(waMediaItem *)mediaItem;
- (id)initWithMediaItem:(waMediaItem *)mediaItem tracks:(NSArray *)tracks;
- (id)initWithMediaItem:(waMediaItem *)mediaItem tracks:(NSArray *)tracks artworkPath:(NSString *)artworkPath;
@end
