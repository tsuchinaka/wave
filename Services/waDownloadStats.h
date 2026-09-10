#import <Foundation/Foundation.h>

@interface waDownloadStats : NSObject
+ (unsigned long long)bytesForDownloads:(NSArray *)downloads;
@end
