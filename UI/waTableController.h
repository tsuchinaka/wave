#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "waModel.h"

@class waTrack, waAlbum, waArtist, waPlaylist, waRadio, waGenre;

// Every browsing screen is a grouped/plain table pushed on a UINavigationController.
// The base class owns loading, empty and error states with the same native look
// so each screen only supplies rows.

typedef enum {
    waPageStateIdle = 0,
    waPageStateLoading,
    waPageStateLoaded,
    waPageStateEmpty,
    waPageStateError
} waPageState;

@interface waTableController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, assign) BOOL grouped;
@property (nonatomic, assign) waPageState state;
@property (nonatomic, copy) NSString *emptyTitle;
@property (nonatomic, copy) NSString *emptyMessage;
- (id)initWithGroupedStyle:(BOOL)grouped;
- (void)reload;
- (void)setLoading:(BOOL)loading;
- (void)showEmpty:(NSString *)title message:(NSString *)message;
- (void)showError:(NSError *)error retry:(SEL)retry;
- (void)pushTrackList:(NSArray *)tracks title:(NSString *)title start:(NSUInteger)index;
- (void)pushAlbum:(waAlbum *)album;
- (void)pushArtist:(waArtist *)artist;
- (void)pushPlaylist:(waPlaylist *)playlist;
- (void)presentActionsForTrack:(waTrack *)track;
- (void)presentShareForItem:(waItem *)item;
@end

@interface waArtworkHeader : UIView
@property (nonatomic, strong) UIImageView *artworkView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
- (CGFloat)layoutForWidth:(CGFloat)width;
@end

@interface waActionGrid : UIView
@property (nonatomic, strong) NSArray *buttons; // UIButton*
- (void)addActionWithTitle:(NSString *)title target:(id)target action:(SEL)action;
@end
