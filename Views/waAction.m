#import "waAction.h"

@implementation waAction

+ (instancetype)actionWithIdentifier:(NSString *)identifier title:(NSString *)title handler:(waActionHandler)handler {
    return [self actionWithIdentifier:identifier title:title destructive:NO availability:nil handler:handler];
}

+ (instancetype)actionWithIdentifier:(NSString *)identifier title:(NSString *)title destructive:(BOOL)destructive availability:(waActionAvailabilityBlock)availability handler:(waActionHandler)handler {
    waAction *action = [[self alloc] init];
    action.identifier = identifier;
    action.title = title;
    action.destructive = destructive;
    action.availability = availability;
    action.handler = handler;
    return action;
}

- (BOOL)isAvailableForObject:(id)object {
    return self.title.length > 0 && (!self.availability || self.availability(object));
}

- (void)performWithObject:(id)object {
    if (self.handler) self.handler(object);
}

@end
