#import <Foundation/Foundation.h>

@interface waCrash : NSObject
+ (void)install;
// Best-effort breadcrumb, copied into a fixed buffer so it survives a signal.
+ (void)markScreen:(NSString *)screen action:(NSString *)action;
+ (NSString *)lastReport;
+ (NSString *)reportPath;
@end
