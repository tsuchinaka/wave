#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface waImageCache : NSObject
+ (waImageCache *)shared;
- (UIImage *)cachedImageForURL:(NSString *)url size:(CGSize)size;
- (void)loadImageAtURL:(NSString *)url size:(CGSize)size completion:(void (^)(UIImage *image))completion;
- (void)loadImageAtURL:(NSString *)url size:(CGSize)size owner:(id)owner completion:(void (^)(UIImage *image))completion;
- (void)cancelRequestsForOwner:(id)owner;
// A ticket is cancelled by flag, not by the view's address. Reusing that
// address for the next screen was marking the new load as already cancelled.
- (id)artworkTicket;
- (void)cancelTicket:(id)ticket;
- (void)loadImageAtURL:(NSString *)url size:(CGSize)size ticket:(id)ticket completion:(void (^)(UIImage *image))completion;
- (void)clearMemory;
- (NSString *)sourcePathForURL:(NSString *)url;
@end
