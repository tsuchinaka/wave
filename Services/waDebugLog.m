#import "waDebugLog.h"
#import <stdarg.h>

NSString * const waDebugLogDidChangeNotification = @"waDebugLogDidChangeNotification";
static NSUInteger const waDebugLogMaximumEntries = 300;

@interface waDebugLog ()
@property (nonatomic, strong) NSMutableArray *mutableEntries;
@property (nonatomic, strong) NSDateFormatter *formatter;
@property (nonatomic, strong) dispatch_queue_t storageQueue;
- (void)appendEntryToFile:(NSString *)entry;
@end

@implementation waDebugLog

+ (waDebugLog *)sharedLog {
    static waDebugLog *log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ log = [[self alloc] init]; });
    return log;
}

- (id)init {
    if ((self = [super init])) {
        _mutableEntries = [NSMutableArray array];
        _formatter = [[NSDateFormatter alloc] init];
        _formatter.dateFormat = @"HH:mm:ss.SSS";
        _storageQueue = dispatch_queue_create("com.bytebox.wave.debug-log", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSArray *)entries {
    __block NSArray *snapshot = nil;
    dispatch_sync(self.storageQueue, ^{ snapshot = [self.mutableEntries copy]; });
    return snapshot ?: @[];
}

- (void)log:(NSString *)format, ... {
    if (!format.length) return;

    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    if (!message.length) return;

    dispatch_async(self.storageQueue, ^{
        NSString *entry = [NSString stringWithFormat:@"[%@] %@", [self.formatter stringFromDate:[NSDate date]], message];
        [self.mutableEntries addObject:entry];
        while (self.mutableEntries.count > waDebugLogMaximumEntries) [self.mutableEntries removeObjectAtIndex:0];
        // Mirror to the system console and to Documents/wave.log so failures
        // can be pulled off the device over SSH (there is no syslogd). Both
        // run inside the async block so I/O never stalls the caller thread.
        NSLog(@"[Wave] %@", entry);
        [self appendEntryToFile:[entry stringByAppendingString:@"\n"]];
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:waDebugLogDidChangeNotification object:self];
    });
}

- (void)clear {
    dispatch_sync(self.storageQueue, ^{ [self.mutableEntries removeAllObjects]; });
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:waDebugLogDidChangeNotification object:self];
    });
}

- (void)appendEntryToFile:(NSString *)entry {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        path = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"wave.log"];
    });
    NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *manager = [NSFileManager defaultManager];
    unsigned long long size = [[manager attributesOfItemAtPath:path error:NULL][NSFileSize] unsignedLongLongValue];
    if (size > 256 * 1024) {
        // Bounded file: keep only the newest tail when it grows past the cap.
        NSFileHandle *reader = [NSFileHandle fileHandleForReadingAtPath:path];
        if (reader) {
            [reader seekToFileOffset:size - 64 * 1024];
            NSString *tail = [[NSString alloc] initWithData:[reader readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
            [reader closeFile];
            NSRange firstLine = [tail rangeOfString:@"\n"];
            if (firstLine.location != NSNotFound && firstLine.location + 1 < tail.length) tail = [tail substringFromIndex:firstLine.location + 1];
            NSMutableData *kept = [NSMutableData dataWithData:[tail dataUsingEncoding:NSUTF8StringEncoding]];
            [kept appendData:data];
            [kept writeToFile:path atomically:YES];
        }
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [manager createFileAtPath:path contents:data attributes:nil];
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle closeFile];
}

@end
