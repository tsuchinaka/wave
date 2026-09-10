#import <Foundation/Foundation.h>
#import "../Models/waDownload.h"
@protocol waPlayerContract <NSObject>
- (void)playSong:(NSString *)songIdentifier;
- (void)pause;
@end
@protocol waDownloadContract <NSObject>
- (void)enqueueDownloadWithIdentifier:(NSString *)identifier;
- (void)enqueueDownloadWithIdentifier:(NSString *)identifier ticketURL:(NSString *)ticketURL category:(waDownloadCategory)category contextIdentifier:(NSString *)contextIdentifier title:(NSString *)title artist:(NSString *)artist;
- (void)cancelDownloadWithIdentifier:(NSString *)identifier;
- (waDownload *)downloadForIdentifier:(NSString *)identifier;
- (NSArray *)downloadsForCategory:(waDownloadCategory)category;
@end
