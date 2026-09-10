#import <UIKit/UIKit.h>
#import "../Models/waMediaItem.h"

typedef void (^waHomeSectionSelectionBlock)(waMediaItem *item, NSArray *context);

@interface waHomeSectionView : UIView
- (void)configureWithSection:(NSDictionary *)section selection:(waHomeSectionSelectionBlock)selection;
@property (nonatomic, copy) waHomeSectionSelectionBlock longPress;
@property (nonatomic, copy) void (^moreAction)(void);
@property (nonatomic, assign) BOOL compact;
// Detail catalog shelves use a shorter card geometry when the device is in
// landscape. Home and Search keep their existing geometry by default.
@property (nonatomic, assign) BOOL compactLandscape;
- (void)resetScrollPosition;
- (CGFloat)preferredHeight;
- (void)clearCallbacks;
@end
