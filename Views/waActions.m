#import "waActions.h"

@class waActions;

@interface waActionSheetSession : NSObject <UIActionSheetDelegate>
@property (nonatomic, weak) waActions *manager;
@property (nonatomic, weak) UIViewController *viewController;
@property (nonatomic, strong) UIActionSheet *sheet;
@property (nonatomic, strong) NSDictionary *actionsByButtonIndex;
@property (nonatomic, strong) id object;
@property (nonatomic, strong) waAction *pendingAction;
@end

@interface waActions ()
@property (nonatomic, strong) NSMutableDictionary *providers;
@property (nonatomic, strong) NSMutableArray *sessions;
- (void)removeSession:(waActionSheetSession *)session;
@end

@implementation waActions

+ (instancetype)sharedActions {
    static waActions *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (id)init {
    self = [super init];
    if (self) {
        _providers = [[NSMutableDictionary alloc] init];
        _sessions = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)registerProvider:(waActionsProvider)provider forContext:(NSString *)context {
    if (!provider || !context.length) return;
    NSMutableArray *list = self.providers[context];
    if (!list) { list = [NSMutableArray array]; self.providers[context] = list; }
    [list addObject:[provider copy]];
}

- (void)removeProvidersForContext:(NSString *)context {
    if (context.length) [self.providers removeObjectForKey:context];
}

- (NSArray *)actionsForContext:(NSString *)context object:(id)object {
    NSMutableArray *result = [NSMutableArray array];
    for (waActionsProvider provider in self.providers[context]) {
        NSArray *actions = provider(object);
        for (waAction *action in actions) if ([action isKindOfClass:[waAction class]] && [action isAvailableForObject:object]) [result addObject:action];
    }
    return result;
}

- (void)presentActionsForContext:(NSString *)context title:(NSString *)title object:(id)object fromViewController:(UIViewController *)viewController {
    [self presentTitle:title actions:[self actionsForContext:context object:object] object:object fromViewController:viewController];
}

- (void)presentTitle:(NSString *)title actions:(NSArray *)actions object:(id)object fromViewController:(UIViewController *)viewController {
    if (!viewController || !actions.count) return;
    NSMutableArray *available = [NSMutableArray array];
    waAction *destructive = nil;
    for (waAction *action in actions) {
        if (![action isKindOfClass:[waAction class]] || ![action isAvailableForObject:object]) continue;
        if (action.isDestructive && !destructive) destructive = action;
        else [available addObject:action];
    }
    if (!available.count && !destructive) return;

    waActionSheetSession *session = [[waActionSheetSession alloc] init];
    session.manager = self;
    session.viewController = viewController;
    session.object = object;
    // Destructive goes in at init (index 0) and cancel is added last. HI keeps
    // both in place, so the indices returned by addButtonWithTitle: stay
    // aligned with clickedButtonAtIndex: (moving the destructive afterwards
    // reindexes the sheet and every button triggers the wrong action).
    session.sheet = [[UIActionSheet alloc] initWithTitle:title delegate:session cancelButtonTitle:nil destructiveButtonTitle:destructive.title otherButtonTitles:nil];
    // addButtonWithTitle: returns the actual index. Keep that index instead of
    // matching titles, because two different actions may share a title.
    NSMutableDictionary *actionsByIndex = [NSMutableDictionary dictionary];
    for (waAction *action in available) {
        NSInteger index = [session.sheet addButtonWithTitle:action.title];
        actionsByIndex[@(index)] = action;
    }
    if (destructive) actionsByIndex[@(session.sheet.destructiveButtonIndex)] = destructive;
    // Added after every other button, so it is genuinely the last index/HI slot.
    session.sheet.cancelButtonIndex = [session.sheet addButtonWithTitle:@"Cancel"];

    session.actionsByButtonIndex = actionsByIndex;
    [self.sessions addObject:session];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        CGRect anchor = CGRectMake(CGRectGetMidX(viewController.view.bounds), CGRectGetMidY(viewController.view.bounds), 1.0, 1.0);
        [session.sheet showFromRect:anchor inView:viewController.view animated:YES];
    } else {
        UIView *presentationView = viewController.tabBarController ? viewController.tabBarController.view : viewController.view;
        [session.sheet showInView:presentationView];
    }
}

- (void)removeSession:(waActionSheetSession *)session { [self.sessions removeObjectIdenticalTo:session]; }

@end

@implementation waActionSheetSession

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index {
    if (index == sheet.cancelButtonIndex) return;
    self.pendingAction = self.actionsByButtonIndex[@(index)];
}

- (void)actionSheet:(UIActionSheet *)sheet didDismissWithButtonIndex:(NSInteger)index {
    waAction *action = self.pendingAction;
    self.pendingAction = nil;
    if (action && index != sheet.cancelButtonIndex) [action performWithObject:self.object];
    [self.manager removeSession:self];
}

- (void)actionSheetCancel:(UIActionSheet *)sheet {
    (void)sheet;
    self.pendingAction = nil;
    [self.manager removeSession:self];
}

@end
