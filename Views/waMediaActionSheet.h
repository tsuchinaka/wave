#import <UIKit/UIKit.h>
#import "../Models/waMediaItem.h"

extern NSString * const waMediaLikeDidChangeNotification;
extern NSString * const waMediaLikeIdentifierKey;
extern NSString * const waMediaLikeTypeKey;

@interface waMediaActionSheet : NSObject <UIActionSheetDelegate>
+ (void)presentForItem:(waMediaItem *)item inViewController:(UIViewController *)viewController albumItems:(NSArray *)albumItems;
@end
