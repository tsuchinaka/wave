#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class waItem;

// Horizontal strip: title row + UIScrollView of tiles + optional UIPageControl.
// The only Apple horizontal pattern on iOS 5.1: scroll view + page control.
@interface waCarouselView : UIView <UIScrollViewDelegate>
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *seeAllButton;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIPageControl *pageControl;
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, assign) BOOL paging;
- (id)initWithFrame:(CGRect)frame title:(NSString *)title;
- (void)setItems:(NSArray *)items
     artworkSide:(CGFloat)side
          target:(id)target
          action:(SEL)action
    seeAllTarget:(id)seeAllTarget
    seeAllAction:(SEL)seeAllAction;
+ (CGFloat)heightForArtworkSide:(CGFloat)side paged:(BOOL)paged;
+ (CGFloat)heightForArtworkSide:(CGFloat)side paged:(BOOL)paged showsHeader:(BOOL)showsHeader;
@end
