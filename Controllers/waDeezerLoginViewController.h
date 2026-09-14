#import <UIKit/UIKit.h>

@interface waDeezerLoginViewController : UIViewController
- (id)initWithCompletion:(void (^)(NSError *error))completion;
- (id)initWithCompletion:(void (^)(NSError *error))completion required:(BOOL)required;
@end
