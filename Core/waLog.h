#import <Foundation/Foundation.h>

@interface waLog : NSObject
+ (waLog *)shared;
- (void)log:(NSString *)format, ...;
- (NSArray *)lines;
- (NSString *)text;
- (void)clear;
@end
