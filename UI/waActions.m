#import "waActions.h"

@implementation waAction

+ (waAction *)actionWithTitle:(NSString *)title destructive:(BOOL)destructive handler:(void (^)(void))handler {
    waAction *action = [[waAction alloc] init];
    action.title = title;
    action.destructive = destructive;
    action.handler = handler;
    return action;
}

@end

@interface waSheetPresenter : NSObject <UIActionSheetDelegate>
@property (nonatomic, copy) NSArray *actions;
@property (nonatomic, weak) UIView *host;
@property (nonatomic, strong) UIActionSheet *sheet;
@end

// The presenter has to outlive the sheet: UIActionSheet holds its delegate
// unowned. It lives here only until the sheet dismisses.
static NSMutableSet *waLivePresenters(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

@implementation waSheetPresenter

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex {
    (void)actionSheet;
    waAction *action = nil;
    if (buttonIndex >= 0 && buttonIndex < (NSInteger)self.actions.count) {
        action = [self.actions objectAtIndex:(NSUInteger)buttonIndex];
    }
    void (^handler)(void) = [action.handler copy];
    self.sheet = nil;
    // Keep the presenter alive until this method returns, then let the set go.
    waSheetPresenter *keepAlive = self;
    [waLivePresenters() removeObject:self];
    if (handler) handler();
    (void)keepAlive;
}

@end

@implementation waActions

+ (void)showInView:(UIView *)view title:(NSString *)title actions:(NSArray *)actions {
    [self presentInView:view item:nil title:title actions:actions];
}

+ (void)showFromBarButtonItem:(UIBarButtonItem *)item inView:(UIView *)view title:(NSString *)title actions:(NSArray *)actions {
    [self presentInView:view item:item title:title actions:actions];
}

+ (BOOL)isShowingInView:(UIView *)view {
    for (waSheetPresenter *presenter in waLivePresenters()) {
        if (presenter.host == view) return YES;
    }
    return NO;
}

+ (void)presentInView:(UIView *)view item:(UIBarButtonItem *)item title:(NSString *)title actions:(NSArray *)actions {
    if (!view || !actions.count) return;
    if ([self isShowingInView:view]) return;

    // Button order is the action order, so the index the sheet reports maps
    // straight back. Filter first, never inside the loop.
    NSMutableArray *usable = [NSMutableArray arrayWithCapacity:actions.count];
    for (waAction *action in actions) {
        if ([action isKindOfClass:[waAction class]] && action.title.length) [usable addObject:action];
    }
    if (!usable.count) return;

    waSheetPresenter *presenter = [[waSheetPresenter alloc] init];
    presenter.actions = [usable copy];
    presenter.host = view;

    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:title
                                                      delegate:presenter
                                             cancelButtonTitle:nil
                                        destructiveButtonTitle:nil
                                             otherButtonTitles:nil];
    NSInteger destructive = -1;
    for (NSUInteger index = 0; index < presenter.actions.count; index++) {
        waAction *action = [presenter.actions objectAtIndex:index];
        [sheet addButtonWithTitle:action.title];
        if (action.destructive && destructive < 0) destructive = (NSInteger)index;
    }
    if (!sheet.numberOfButtons) return;
    sheet.destructiveButtonIndex = destructive;
    // Cancel last, so the index the delegate reports for it is the one stored.
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
    presenter.sheet = sheet;
    [waLivePresenters() addObject:presenter];

    BOOL pad = (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad);
    if (item && pad) [sheet showFromBarButtonItem:item animated:YES];
    else [sheet showInView:view];
}

@end
