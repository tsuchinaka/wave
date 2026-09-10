#import <UIKit/UIKit.h>

@interface waSegmentedControl : UIControl
- (id)initWithItems:(NSArray *)items;
@property (nonatomic, assign) NSInteger selectedSegmentIndex;
- (void)updateAppearance;
@end
