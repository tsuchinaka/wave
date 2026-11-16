#import <UIKit/UIKit.h>

// One entry of a UIActionSheet: title, weight, and what it does. The block is
// captured when the sheet is built, so a handler never reads a live model that
// may have grown since the buttons were laid out.
@interface waAction : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) BOOL destructive;
@property (nonatomic, copy) void (^handler)(void);
+ (waAction *)actionWithTitle:(NSString *)title destructive:(BOOL)destructive handler:(void (^)(void))handler;
@end

// The only way the app shows an action sheet.
//
// UIActionSheet keeps its delegate unowned and reports a popover dismissal as
// a tap on the cancel button, so both have to be handled in one place instead
// of six. Cancelling is the default here, and every handler runs after the
// sheet is gone, which is what lets a handler present something else.
@interface waActions : NSObject
+ (void)showInView:(UIView *)view title:(NSString *)title actions:(NSArray *)actions;
// iPad: anchored to the item it came from. Falls back to showInView: on phone.
+ (void)showFromBarButtonItem:(UIBarButtonItem *)item inView:(UIView *)view title:(NSString *)title actions:(NSArray *)actions;
+ (BOOL)isShowingInView:(UIView *)view;
@end
