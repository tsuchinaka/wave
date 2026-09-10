#import <UIKit/UIKit.h>
#import "../Models/waDownload.h"
#import "../Models/waMediaItem.h"

typedef NS_ENUM(NSInteger, waCellCornerStyle) {
    waCellCornerStyleNone = 0,
    waCellCornerStyleTop,
    waCellCornerStyleBottom,
    waCellCornerStyleAll
};

@interface waArtworkCell : UITableViewCell
@property (nonatomic, copy) NSString *artworkIdentifier;
@property (nonatomic, assign) BOOL reserveAccessorySpace;
@property (nonatomic, assign) BOOL cardStyle;
@property (nonatomic, assign) BOOL circleArtwork;
@property (nonatomic, assign) BOOL multilineDetail;
@property (nonatomic, assign) waCellCornerStyle cornerStyle;
- (void)setLikeItem:(waMediaItem *)item;
- (void)refreshLikeState;
- (void)setDownloadState:(waDownloadState)state progress:(float)progress;
- (void)setExplicit:(BOOL)explicit;
- (void)setGeniusRecommended:(BOOL)recommended;
@end
