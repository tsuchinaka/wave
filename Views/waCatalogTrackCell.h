#import <UIKit/UIKit.h>
#import "../Models/waMediaItem.h"
#import "../Models/waDownload.h"

@class waCatalogTrackCell;

@protocol waCatalogTrackCellDelegate <NSObject>
- (void)catalogTrackCellDidPressLike:(waCatalogTrackCell *)cell item:(waMediaItem *)item;
@end

@interface waCatalogTrackCell : UITableViewCell
@property (nonatomic, weak) id<waCatalogTrackCellDelegate> delegate;
@property (nonatomic, strong, readonly) waMediaItem *trackItem;
- (void)configureWithItem:(waMediaItem *)item artistName:(NSString *)artistName albumName:(NSString *)albumName trackNumber:(NSUInteger)trackNumber;
- (void)configureForPlaylistItem:(waMediaItem *)item artistName:(NSString *)artistName;
- (void)setDownloadState:(waDownloadState)state progress:(float)progress;
- (void)refreshLikeState;
- (void)applyTheme;
@end
