#import "waDeezerClient.h"

// Shared request policy for gateway, public API and authentication requests.
FOUNDATION_EXPORT NSMutableURLRequest *waDeezerRequest(NSURL *url, NSURLRequestCachePolicy policy);

@interface waDeezerClient (Private)
- (void)wa_callMethod:(NSString *)method parameters:(NSDictionary *)parameters retry:(BOOL)retry completion:(void (^)(NSDictionary *, NSError *))completion;
- (void)wa_dispatchMain:(void (^)(void))block;
- (NSString *)wa_rawIdentifier:(NSString *)identifier;
- (NSString *)wa_string:(id)value;
- (NSDictionary *)wa_playlistFromDictionary:(NSDictionary *)dictionary;
- (NSDictionary *)wa_songFromDictionary:(NSDictionary *)dictionary;
- (NSError *)wa_responseError:(NSURLResponse *)response networkError:(NSError *)networkError message:(NSString *)message;
- (NSOperationQueue *)wa_parseQueue;
- (NSError *)errorWithMessage:(NSString *)message code:(NSInteger)code;
@end
