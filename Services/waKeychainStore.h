#import <Foundation/Foundation.h>
@interface waKeychainStore : NSObject
+ (NSString *)token;
+ (BOOL)setToken:(NSString *)token;
+ (void)clearToken;
+ (NSString *)deezerARL;
+ (BOOL)setDeezerARL:(NSString *)arl;
+ (void)clearDeezerARL;
@end
