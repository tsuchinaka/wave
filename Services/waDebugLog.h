#import <Foundation/Foundation.h>

extern NSString * const waDebugLogDidChangeNotification;

@interface waDebugLog : NSObject
+ (waDebugLog *)sharedLog;
- (NSArray *)entries;
- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
- (void)clear;
@end
