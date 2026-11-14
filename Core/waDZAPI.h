#import <Foundation/Foundation.h>

// Thin transport for the two Deezer surfaces the app talks to:
// 1. www.deezer.com/ajax/gw-light.php  (account, favorites, playlists, flow)
// 2. api.deezer.com                    (public catalog, pagination)
// 3. media.deezer.com/v1/get_url       (signed stream URLs, BF_CBC_STRIPE)
@interface waDZAPI : NSObject
+ (waDZAPI *)shared;

@property (nonatomic, copy) NSString *arl;
@property (nonatomic, copy) NSString *sessionID;
@property (nonatomic, copy) NSString *checkForm;
@property (nonatomic, copy) NSString *licenseToken;
@property (nonatomic, readonly) BOOL hasSession;

- (void)resetSession;

// gateway
- (void)callMethod:(NSString *)method
            params:(NSDictionary *)params
        completion:(void (^)(NSDictionary *result, NSError *error))completion;

// public catalog. path is like @"/search/track" plus a query dictionary.
- (void)getPath:(NSString *)path
         params:(NSDictionary *)params
     completion:(void (^)(NSDictionary *json, NSError *error))completion;
- (void)postPath:(NSString *)path
          params:(NSDictionary *)params
      completion:(void (^)(NSDictionary *json, NSError *error))completion;
- (void)deletePath:(NSString *)path
            params:(NSDictionary *)params
        completion:(void (^)(NSDictionary *json, NSError *error))completion;

// account bootstrap; also fills checkForm/sessionID/licenseToken
- (void)loadUserData:(void (^)(NSDictionary *user, NSError *error))completion;

// signed stream. quality is resolved by the caller; the completion reports the
// format the account actually granted so the UI can stay honest.
- (void)signedURLForTrackToken:(NSString *)trackToken
                       formats:(NSArray *)formats
                    completion:(void (^)(NSString *url, NSString *format, NSError *error))completion;

- (void)trackTokenForID:(NSString *)trackID completion:(void (^)(NSString *token, NSError *error))completion;
// Authenticated token plus the id the CDN file is keyed with. FALLBACK is used
// when the catalog id itself is not streamable. A public-API token is not enough:
// Deezer answers those with the 30-second preview.
- (void)resolveStreamForTrackID:(NSString *)trackID
                     completion:(void (^)(NSString *token, NSString *streamID, NSError *error))completion;
- (void)logListenForTrackID:(NSString *)trackID completion:(void (^)(NSError *error))completion;
@end
