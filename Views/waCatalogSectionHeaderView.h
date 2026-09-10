#import <UIKit/UIKit.h>

@interface waCatalogSectionHeaderView : UIView
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *actionTitle;
@property (nonatomic, copy) void (^action)(void);
- (id)initWithTitle:(NSString *)title actionTitle:(NSString *)actionTitle action:(void (^)(void))action;
@end
