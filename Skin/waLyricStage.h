#import <UIKit/UIKit.h>
#import "../Core/waLyrics.h"

@interface waLyricStage : UIView
@property (nonatomic, strong) waLyrics *lyrics;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, copy) NSTimeInterval (^timeSource)(void);
- (void)setTime:(NSTimeInterval)time;
- (void)stopPulse;
@end
