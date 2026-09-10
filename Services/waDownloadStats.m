#import "waDownloadStats.h"
#import "waDownloadManager.h"
#import "../Models/waDownload.h"

@implementation waDownloadStats

+ (unsigned long long)bytesForDownloads:(NSArray *)downloads {
    unsigned long long bytes = 0;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    waDownloadManager *manager = [waDownloadManager sharedManager];
    for (waDownload *download in downloads) {
        if (download.state != waDownloadStateCompleted) continue;
        NSString *path = [manager localPathForIdentifier:download.identifier] ?: download.filePath;
        if (path.length) bytes += [[fileManager attributesOfItemAtPath:path error:NULL] fileSize];
    }
    return bytes;
}

@end
