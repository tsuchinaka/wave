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
// Return { title: NSString, actions: NSArray of waAction } for a held row.
// The base class owns the gesture and the presenter; screens only supply the
// menu for the item at that index path. Nil means no menu on that row.
- (NSDictionary *)contextMenuForRowAtIndexPath:(NSIndexPath *)indexPath;
@end
