#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "waModel.h"

// Gloss, bevel and reflection used by Home and the screens it pushes.
// Search keeps waTileView / waCarouselView.

@interface waChrome : NSObject
+ (UIColor *)headerInk;
+ (UIColor *)linkBlue;
+ (UIImage *)buttonImagePressed:(BOOL)pressed;
+ (void)styleButton:(UIButton *)button title:(NSString *)title;
+ (UIView *)embossedHeaderWithTitle:(NSString *)title width:(CGFloat)width;
@end

@interface waChromeBar : UIView
@property (nonatomic, strong) NSArray *buttons;
@end

@interface waCoverView : UIControl
@property (nonatomic, strong) waItem *item;
@property (nonatomic, assign) CGFloat artworkSide;
+ (CGFloat)heightForSide:(CGFloat)side;
- (void)configureWithItem:(waItem *)item side:(CGFloat)side;
@end

@interface waCoverStrip : UIView
+ (CGFloat)heightForSide:(CGFloat)side;
- (void)setItems:(NSArray *)items side:(CGFloat)side target:(id)target action:(SEL)action;
@end

@interface waCoverGrid : UIView
+ (CGFloat)heightForCount:(NSUInteger)count width:(CGFloat)width;
- (void)setItems:(NSArray *)items target:(id)target action:(SEL)action;
@end

@interface waPageDots : UIView
@property (nonatomic, assign) NSInteger numberOfPages;
@property (nonatomic, assign) NSInteger currentPage;
@property (nonatomic, copy) void (^pageChanged)(NSInteger page);
@end
