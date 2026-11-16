#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class waItem, waTrack;

// The menu behind a long press on a row. One place decides which actions make
// sense for an item, so Search, Library, Queue, Downloads and Detail all get
// the same wording and the same behavior.
@interface waRowActions : NSObject
// Returns { title: NSString, actions: NSArray of waAction } or nil.
+ (NSDictionary *)menuForItem:(waItem *)item tracks:(NSArray *)tracks presenter:(UIViewController *)presenter;
+ (void)presentPlaylistPickerForTrack:(waTrack *)track from:(UIViewController *)presenter;
@end
