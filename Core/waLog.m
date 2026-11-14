#import "waLog.h"

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
        NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:waLogPath()];
        if (!handle) [[NSFileManager defaultManager] createFileAtPath:waLogPath() contents:data attributes:nil];
        else {
            @try {
                [handle seekToEndOfFile];
                [handle writeData:data];
                [handle closeFile];
            } @catch (NSException *e) { (void)e; }
        }
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
        [[NSFileManager defaultManager] removeItemAtPath:waLogPath() error:NULL];
    });
}

@end
