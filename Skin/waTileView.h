#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "waModel.h"

// Horizontal tile for carousels. UIControl with artwork on top and two
// labels below. iOS 5.1 only: frames + autoresizing, no Auto Layout,
// no collection view.
@interface waTileView : UIControl
@property (nonatomic, strong) waItem *item;
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, assign) CGFloat artworkSide;
- (id)initWithFrame:(CGRect)frame item:(waItem *)item artworkSide:(CGFloat)side;
- (void)configureWithItem:(waItem *)item;
+ (CGFloat)heightForArtworkSide:(CGFloat)side;
@end
