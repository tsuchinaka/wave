#import <Foundation/Foundation.h>
#import "waContracts.h"
@class waMediaItem;

extern NSString * const waDownloadManagerDidChangeNotification;
extern NSString *waFileSizeString(unsigned long long bytes);

@interface waDownloadManager : NSObject <waDownloadContract>
@property (nonatomic, assign) NSUInteger maximumParallelDownloads;
+ (waDownloadManager *)sharedManager;
- (void)enqueueDownloadWithIdentifier:(NSString *)identifier;
- (void)enqueueDownloadWithIdentifier:(NSString *)identifier ticketURL:(NSString *)ticketURL;
- (void)enqueueDownloadWithIdentifier:(NSString *)identifier category:(waDownloadCategory)category contextIdentifier:(NSString *)contextIdentifier title:(NSString *)title artist:(NSString *)artist;
- (void)enqueueDownloadWithIdentifier:(NSString *)identifier ticketURL:(NSString *)ticketURL category:(waDownloadCategory)category contextIdentifier:(NSString *)contextIdentifier title:(NSString *)title artist:(NSString *)artist;
- (void)enqueueDownloadWithItem:(waMediaItem *)item category:(waDownloadCategory)category contextIdentifier:(NSString *)contextIdentifier;
- (void)enqueueDownloadWithItem:(waMediaItem *)item category:(waDownloadCategory)category contextIdentifier:(NSString *)contextIdentifier groupTitle:(NSString *)groupTitle;
- (void)cancelDownloadWithIdentifier:(NSString *)identifier;
- (void)deleteDownloadWithIdentifier:(NSString *)identifier completion:(void (^)(NSError *error))completion;
- (waDownload *)downloadForIdentifier:(NSString *)identifier;
- (waDownloadState)stateForIdentifier:(NSString *)identifier;
- (NSString *)localPathForIdentifier:(NSString *)identifier;
- (NSUInteger)completedCount;
- (NSArray *)allDownloads;
- (NSArray *)downloadsForCategory:(waDownloadCategory)category;
- (NSDictionary *)downloadsByCategory;
- (unsigned long long)downloadedBytes;
- (void)deleteDownloadsWithCompletion:(void (^)(NSError *error))completion;
// Compatibility wrapper; deletion itself remains asynchronous.
- (void)deleteDownloads;
@end
