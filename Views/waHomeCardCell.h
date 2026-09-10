#import <UIKit/UIKit.h>
#import "../Models/waMediaItem.h"

@interface waHomeCardCell : UICollectionViewCell
- (void)configureWithItem:(waMediaItem *)item layout:(NSString *)layout;
@end
