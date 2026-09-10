#import <UIKit/UIKit.h>
#import "../Models/waMediaItem.h"

@class waCatalogInfoCard;

@protocol waCatalogInfoCardDelegate <NSObject>
- (void)catalogInfoCardDidPressLike:(waCatalogInfoCard *)card;
- (void)catalogInfoCardDidPressDownload:(waCatalogInfoCard *)card;
- (void)catalogInfoCardDidPressPlayAll:(waCatalogInfoCard *)card;
@end

@interface waCatalogInfoCard : UIView
@property (nonatomic, weak) id<waCatalogInfoCardDelegate> delegate;
@property (nonatomic, strong, readonly) UIImageView *coverView;
@property (nonatomic, strong, readonly) UIButton *likeButton;
@property (nonatomic, strong, readonly) UIButton *downloadButton;
@property (nonatomic, strong, readonly) UIButton *playAllButton;
@property (nonatomic, strong, readonly) UILabel *stateLabel;
- (void)configureWithItem:(waMediaItem *)item listenerText:(NSString *)listenerText detailText:(NSString *)detailText;
- (void)applyTheme;
- (CGFloat)preferredHeightForWidth:(CGFloat)width landscape:(BOOL)landscape;
@end
