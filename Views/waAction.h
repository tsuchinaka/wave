#import <Foundation/Foundation.h>

typedef BOOL (^waActionAvailabilityBlock)(id object);
typedef void (^waActionHandler)(id object);

@interface waAction : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign, getter=isDestructive) BOOL destructive;
@property (nonatomic, copy) waActionAvailabilityBlock availability;
@property (nonatomic, copy) waActionHandler handler;

+ (instancetype)actionWithIdentifier:(NSString *)identifier
                                title:(NSString *)title
                              handler:(waActionHandler)handler;
+ (instancetype)actionWithIdentifier:(NSString *)identifier
                                title:(NSString *)title
                          destructive:(BOOL)destructive
                         availability:(waActionAvailabilityBlock)availability
                              handler:(waActionHandler)handler;
- (BOOL)isAvailableForObject:(id)object;
- (void)performWithObject:(id)object;
@end
