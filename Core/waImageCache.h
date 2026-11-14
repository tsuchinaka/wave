#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface waImageCache : NSObject
+ (waImageCache *)shared;
- (UIImage *)cachedImageForURL:(NSString *)url size:(CGSize)size;
- (void)loadImageAtURL:(NSString *)url size:(CGSize)size completion:(void (^)(UIImage *image))completion;
- (void)loadImageAtURL:(NSString *)url size:(CGSize)size owner:(id)owner completion:(void (^)(UIImage *image))completion;
- (void)cancelRequestsForOwner:(id)owner;
- (unsigned long long)diskBytes;
- (void)clearMemory;
- (void)clearDisk;
- (NSString *)sourcePathForURL:(NSString *)url;
@end
