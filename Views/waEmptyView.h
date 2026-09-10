#import <UIKit/UIKit.h>

@interface waEmptyView : UIView
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIView *spinnerBackdrop;

- (void)configureWithIcon:(UIImage *)icon title:(NSString *)title subtitle:(NSString *)subtitle actionTitle:(NSString *)actionTitle target:(id)target action:(SEL)action;
- (void)setLoading:(BOOL)loading;
- (void)applyTheme;
@end
