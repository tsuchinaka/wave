#import <Foundation/Foundation.h>

// TLS 1.2 client for the hosts the iOS 5.1 SecureTransport stack can no longer
// negotiate (media.deezer.com and, for symmetry, the Deezer gateway). Backed by
// the vendored mbedTLS 2.28 and the DigiCert Global Root G2 bundle.
@interface waTLS : NSObject
+ (NSDictionary *)requestURL:(NSURL *)url
                      method:(NSString *)method
                     headers:(NSDictionary *)headers
                        body:(NSData *)body
                     timeout:(NSTimeInterval)timeout
                       error:(NSError **)error;
+ (NSDictionary *)requestURL:(NSURL *)url
                      method:(NSString *)method
                     headers:(NSDictionary *)headers
                        body:(NSData *)body
                     timeout:(NSTimeInterval)timeout
                      verify:(BOOL)verify
                       error:(NSError **)error;
@end
