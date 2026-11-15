#import "waLog.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static NSString *waLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *candidates = [NSMutableArray array];
        NSArray *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (documents.count) [candidates addObject:[[documents objectAtIndex:0] stringByAppendingPathComponent:@"wave.log"]];
        NSArray *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        if (caches.count) [candidates addObject:[[caches objectAtIndex:0] stringByAppendingPathComponent:@"wave.log"]];
        [candidates addObject:@"/tmp/wave.log"];
        NSFileManager *manager = [NSFileManager defaultManager];
        for (NSString *candidate in candidates) {
            if ([manager fileExistsAtPath:candidate]) { path = candidate; break; }
            if ([manager createFileAtPath:candidate contents:nil attributes:nil]) { path = candidate; break; }
        }
    });
    return path ?: @"/tmp/wave.log";
}

@interface waLog ()
@property (nonatomic, strong) NSMutableArray *entries;
@property (nonatomic, assign) dispatch_queue_t queue;
@end

// One descriptor for the life of the process. Opening, seeking and closing a
// handle per line was hundreds of flash operations per minute on the 3GS.
static int waLogFD = -1;

static int waLogDescriptor(void) {
    if (waLogFD >= 0) return waLogFD;
    const char *path = [waLogPath() fileSystemRepresentation];
    if (!path) return -1;
    waLogFD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    return waLogFD;
}

static void waLogWriteLine(NSString *line) {
    if (!line.length) return;
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    int fd = waLogDescriptor();
    if (fd < 0) return;
    const char *bytes = (const char *)data.bytes;
    size_t left = (size_t)data.length;
    while (left) {
        ssize_t wrote = write(fd, bytes, left);
        if (wrote < 0) {
            if (errno == EINTR) continue;
            close(fd);
            waLogFD = -1;
            return;
        }
        bytes += wrote;
        left -= (size_t)wrote;
    }
}

static void waLogCloseDescriptor(void) {
    if (waLogFD >= 0) close(waLogFD);
    waLogFD = -1;
}

@implementation waLog

+ (waLog *)shared {
    static waLog *log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = [[waLog alloc] init]; });
    return log;
}

- (id)init {
    if ((self = [super init])) {
        _entries = [NSMutableArray array];
        _queue = dispatch_queue_create("wave.log", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)log:(NSString *)format, ... {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@", [NSDate date], message ?: @""];
    dispatch_async(self.queue, ^{
        [self.entries addObject:line];
        if (self.entries.count > 400) [self.entries removeObjectAtIndex:0];
        waLogWriteLine(line);
    });
}

- (NSArray *)lines {
    __block NSArray *copy = nil;
    dispatch_sync(self.queue, ^{ copy = [self.entries copy]; });
    return copy;
}

- (NSString *)text {
    return [[self lines] componentsJoinedByString:@"\n"];
}

- (void)clear {
    dispatch_async(self.queue, ^{
        [self.entries removeAllObjects];
        waLogCloseDescriptor();
        [[NSFileManager defaultManager] removeItemAtPath:waLogPath() error:NULL];
    });
}

@end
