#import <UIKit/UIKit.h>
#import "../Models/waMediaItem.h"

@class waMediaInfoCell;

@protocol waMediaInfoCellDelegate <NSObject>
- (void)mediaInfoCellDidPressLike:(waMediaInfoCell *)cell;
- (void)mediaInfoCellDidPressDownload:(waMediaInfoCell *)cell;
- (void)mediaInfoCellDidPressPlayAll:(waMediaInfoCell *)cell;
@end

@interface waMediaInfoCell : UITableViewCell
@property (nonatomic, weak) id<waMediaInfoCellDelegate> delegate;
@property (nonatomic, strong, readonly) UIImageView *coverView;
@property (nonatomic, strong, readonly) UILabel *titleLabel;
@property (nonatomic, strong, readonly) UILabel *subtitleLabel;
@property (nonatomic, strong, readonly) UILabel *yearLabel;
@property (nonatomic, strong, readonly) UILabel *countLabel;
@property (nonatomic, strong, readonly) UILabel *stateLabel;
@property (nonatomic, strong, readonly) UIButton *likeButton;
@property (nonatomic, strong, readonly) UIButton *downloadButton;
@property (nonatomic, strong, readonly) UIButton *playAllButton;
- (CGFloat)preferredHeight;
- (void)configureWithItem:(waMediaItem *)item year:(NSString *)year countText:(NSString *)countText listenerText:(NSString *)listenerText;
- (void)applyTheme;
@end
