#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "waModel.h"

@class waTrack;

@interface waCell : UITableViewCell
+ (waCell *)cellForTable:(UITableView *)table;
+ (waCell *)cellForTable:(UITableView *)table subtitle:(BOOL)subtitle;
- (void)setItem:(waItem *)item;
- (void)setTrack:(waTrack *)track showAlbum:(BOOL)showAlbum;
- (void)setTrack:(waTrack *)track showAlbum:(BOOL)showAlbum showsArtwork:(BOOL)showsArtwork;
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, strong) UILabel *indexLabel;
@property (nonatomic, copy) NSString *indexText;
@property (nonatomic, copy) NSString *expectedArtworkURL;
@property (nonatomic, assign) BOOL downloadedMark;
- (void)setDownloaded:(BOOL)downloaded;
- (void)loadArtworkForURL:(NSString *)url size:(CGSize)size;
// Grouped tables on iOS 5 drop their rounded fill if the cell's background
// color is touched. This draws that fill and installs it as backgroundView.
+ (void)applyGroupedBackground:(UITableViewCell *)cell rows:(NSInteger)rows row:(NSInteger)row;
@end

@interface waSectionHeader : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *actionButton;
@end

@interface waEmptyState : UIView
- (id)initWithTitle:(NSString *)title message:(NSString *)message;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@end
