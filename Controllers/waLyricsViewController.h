#import <UIKit/UIKit.h>

@interface waLyricsViewController : UIViewController
- (id)initWithTrack:(NSString *)track artist:(NSString *)artist;
- (id)initWithTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album duration:(NSTimeInterval)duration;
- (id)initWithTrack:(NSString *)track artist:(NSString *)artist album:(NSString *)album duration:(NSTimeInterval)duration trackId:(NSString *)trackId isrc:(NSString *)isrc;
@end
