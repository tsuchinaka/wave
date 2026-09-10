#import <UIKit/UIKit.h>

extern NSString * const waThemeDidChangeNotification;

@interface waTheme : NSObject
+ (NSArray *)availableThemes;
+ (void)invalidateThemeCache;
+ (UIColor *)backgroundColor;
+ (UIColor *)barColor;
+ (UIColor *)primaryTextColor;
+ (UIColor *)secondaryTextColor;
+ (UIColor *)surfaceColor;
+ (UIColor *)selectedSurfaceColor;
+ (UIColor *)separatorColor;
+ (UIColor *)destructiveColor;
+ (CGFloat)standardMargin;
+ (CGFloat)compactMargin;
+ (CGFloat)standardRowHeight;
+ (CGFloat)compactRowHeight;
+ (CGFloat)standardArtworkSize;
+ (CGFloat)cornerRadius;
+ (UIFont *)regularFontOfSize:(CGFloat)size;
+ (UIFont *)lightFontOfSize:(CGFloat)size;
+ (UIFont *)mediumFontOfSize:(CGFloat)size;
+ (UIFont *)boldFontOfSize:(CGFloat)size;
+ (UIFont *)extraBoldFontOfSize:(CGFloat)size;
+ (UIFont *)secondaryRegularFontOfSize:(CGFloat)size;
+ (UIFont *)secondaryMediumFontOfSize:(CGFloat)size;
+ (UIFont *)secondaryBoldFontOfSize:(CGFloat)size;
+ (void)configureGlobalAppearance;
+ (BOOL)isModernSystem;
+ (void)applyToView:(UIView *)view;
+ (void)applyToWindow:(UIWindow *)window;
+ (void)applyPrimaryTextStyleToLabel:(UILabel *)label;
+ (void)applySecondaryTextStyleToLabel:(UILabel *)label;
+ (void)applySectionHeaderStyleToLabel:(UILabel *)label;
+ (void)applySkeuomorphicStyleToButton:(UIButton *)button;
+ (void)applySkeuomorphicStyleToSegmentedControl:(UISegmentedControl *)control;
+ (UIImage *)tintedIcon:(UIImage *)image withColor:(UIColor *)color;
+ (UIView *)circularBackdropForSpinner:(UIActivityIndicatorView *)spinner;
+ (void)applyLayoutCompatibilityToViewController:(UIViewController *)viewController;
+ (void)applyStatusBarAppearance;
+ (CGFloat)statusBarHeight;
+ (UIColor *)likeSelectedColor;
+ (NSString *)renderCacheKeyForColor:(UIColor *)color;
+ (UIImage *)cachedImageForKey:(NSString *)key renderer:(UIImage *(^)(void))renderer;
@end
