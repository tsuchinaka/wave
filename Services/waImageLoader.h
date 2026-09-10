#import <UIKit/UIKit.h>
@interface waImageLoader : NSObject
+ (id)sharedLoader;
- (void)loadImageAtURL:(NSString *)url placeholder:(UIImage *)placeholder completion:(void (^)(UIImage *image))completion;
- (void)loadArtworkAtURL:(NSString *)url placeholder:(UIImage *)placeholder completion:(void (^)(UIImage *image))completion;
- (void)loadThumbnailAtURL:(NSString *)url targetSize:(CGSize)targetSize placeholder:(UIImage *)placeholder completion:(void (^)(UIImage *image))completion;
- (void)loadThumbnailAtURL:(NSString *)url placeholder:(UIImage *)placeholder completion:(void (^)(UIImage *image))completion;
- (void)loadLocalImageAtPath:(NSString *)path targetSize:(CGSize)targetSize completion:(void (^)(UIImage *image))completion;
- (void)clearCache;
- (void)clearCacheWithCompletion:(void (^)(void))completion;
- (void)trimCache;
- (unsigned long long)cachedBytes;
@end
