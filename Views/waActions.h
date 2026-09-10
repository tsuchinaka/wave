#import <UIKit/UIKit.h>
#import "waAction.h"

typedef NSArray *(^waActionsProvider)(id object);

@interface waActions : NSObject
+ (instancetype)sharedActions;

- (void)registerProvider:(waActionsProvider)provider forContext:(NSString *)context;
- (void)removeProvidersForContext:(NSString *)context;
- (NSArray *)actionsForContext:(NSString *)context object:(id)object;

- (void)presentTitle:(NSString *)title
             actions:(NSArray *)actions
              object:(id)object
fromViewController:(UIViewController *)viewController;

- (void)presentActionsForContext:(NSString *)context
                           title:(NSString *)title
                          object:(id)object
             fromViewController:(UIViewController *)viewController;
@end
