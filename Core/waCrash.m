#import "waCrash.h"
#import <errno.h>
#import <execinfo.h>
#import <fcntl.h>
#import <signal.h>
#import <string.h>
#import <unistd.h>

static NSUncaughtExceptionHandler *waPrevException = NULL;
static struct sigaction waPrevSignals[32];
static volatile sig_atomic_t waCrashBusy = 0;
static const char * const waCrashPaths[] = {
    "/var/mobile/Documents/wave.crash",
    "/tmp/wave.crash",
    NULL
};
static const char * const waLogPaths[] = {
    "/var/mobile/Documents/wave.log",
    "/tmp/wave.log",
    NULL
};

static void waCrashWriteRaw(int fd, const char *bytes, size_t length) {
    if (fd < 0 || !bytes || !length) return;
    while (length) {
        ssize_t n = write(fd, bytes, length);
        if (n < 0) {
            if (errno == EINTR) continue;
            return;
        }
        bytes += (size_t)n;
        length -= (size_t)n;
    }
}

static void waCrashWriteC(int fd, const char *text) {
    if (!text) return;
    size_t n = 0;
    while (text[n]) n++;
    waCrashWriteRaw(fd, text, n);
}

static void waCrashWriteHex(int fd, uintptr_t value) {
    char buf[10];
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 7; i >= 0; i--) {
        unsigned digit = (unsigned)(value & 0xf);
        buf[2 + i] = (char)(digit < 10 ? '0' + digit : 'a' + (digit - 10));
        value >>= 4;
    }
    waCrashWriteRaw(fd, buf, 10);
}

static int waCrashOpenPath(const char *path, int extra) {
    if (!path) return -1;
    return open(path, O_WRONLY | O_CREAT | extra, 0644);
}

static void waCrashWriteAll(const char *text, size_t length, int truncateCrash) {
    for (const char * const *p = waCrashPaths; *p; p++) {
        int fd = waCrashOpenPath(*p, truncateCrash ? O_TRUNC : O_APPEND);
        if (fd < 0) continue;
        waCrashWriteRaw(fd, text, length);
        fsync(fd);
        close(fd);
        break;
    }
    for (const char * const *p = waLogPaths; *p; p++) {
        int fd = waCrashOpenPath(*p, O_APPEND);
        if (fd < 0) continue;
        waCrashWriteRaw(fd, text, length);
        fsync(fd);
        close(fd);
        break;
    }
}

static void waCrashDumpFrames(int fd) {
    void *frames[32];
    int count = backtrace(frames, 32);
    waCrashWriteC(fd, "frames ");
    char nbuf[8];
    int n = count;
    int i = 0;
    if (n < 0) n = 0;
    do {
        nbuf[i++] = (char)('0' + (n % 10));
        n /= 10;
    } while (n && i < 7);
    while (i > 0) {
        i--;
        waCrashWriteRaw(fd, &nbuf[i], 1);
    }
    waCrashWriteC(fd, "\n");
    for (int f = 0; f < count; f++) {
        waCrashWriteC(fd, "  ");
        waCrashWriteHex(fd, (uintptr_t)frames[f]);
        waCrashWriteC(fd, "\n");
    }
}

static void waCrashSignal(int sig, siginfo_t *info, void *context) {
    (void)context;
    if (waCrashBusy) {
        signal(sig, SIG_DFL);
        raise(sig);
        _exit(128 + sig);
    }
    waCrashBusy = 1;
    int fd = -1;
    for (const char * const *p = waCrashPaths; *p && fd < 0; p++) {
        fd = waCrashOpenPath(*p, O_TRUNC);
    }
    if (fd >= 0) {
        waCrashWriteC(fd, "\n=== CRASH ===\nsignal ");
        if (sig >= 0 && sig < 100) {
            char c1 = (char)('0' + (sig / 10));
            char c0 = (char)('0' + (sig % 10));
            if (sig >= 10) waCrashWriteRaw(fd, &c1, 1);
            waCrashWriteRaw(fd, &c0, 1);
        }
        const char *name = "unknown";
        if (sig == SIGSEGV) name = "SIGSEGV";
        else if (sig == SIGBUS) name = "SIGBUS";
        else if (sig == SIGILL) name = "SIGILL";
        else if (sig == SIGABRT) name = "SIGABRT";
        else if (sig == SIGFPE) name = "SIGFPE";
        else if (sig == SIGTRAP) name = "SIGTRAP";
        else if (sig == SIGSYS) name = "SIGSYS";
        waCrashWriteC(fd, " ");
        waCrashWriteC(fd, name);
        waCrashWriteC(fd, "\n");
        if (info) {
            waCrashWriteC(fd, "code ");
            waCrashWriteHex(fd, (uintptr_t)info->si_code);
            waCrashWriteC(fd, "\naddr ");
            waCrashWriteHex(fd, (uintptr_t)info->si_addr);
            waCrashWriteC(fd, "\n");
        }
        waCrashDumpFrames(fd);
        fsync(fd);
        close(fd);
        fd = -1;
        for (const char * const *p = waLogPaths; *p && fd < 0; p++) {
            fd = waCrashOpenPath(*p, O_APPEND);
        }
        if (fd >= 0) {
            waCrashWriteC(fd, "crash signal ");
            waCrashWriteC(fd, name);
            waCrashWriteC(fd, "\n");
            fsync(fd);
            close(fd);
        }
    }
    struct sigaction prev;
    memset(&prev, 0, sizeof(prev));
    if (sig >= 0 && sig < 32) prev = waPrevSignals[sig];
    if (prev.sa_handler == SIG_DFL || prev.sa_handler == SIG_IGN || (!prev.sa_handler && !prev.sa_sigaction)) {
        signal(sig, SIG_DFL);
        raise(sig);
        _exit(128 + sig);
    }
    if (prev.sa_flags & SA_SIGINFO) {
        if (prev.sa_sigaction) prev.sa_sigaction(sig, info, context);
    } else if (prev.sa_handler) {
        prev.sa_handler(sig);
    }
    signal(sig, SIG_DFL);
    raise(sig);
    _exit(128 + sig);
}

static void waCrashException(NSException *exception) {
    if (waCrashBusy) {
        if (waPrevException) waPrevException(exception);
        return;
    }
    waCrashBusy = 1;
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"\n=== CRASH ===\n"];
    [out appendFormat:@"time %@\n", [NSDate date]];
    [out appendFormat:@"exception %@\n", exception.name ?: @"NSException"];
    [out appendFormat:@"reason %@\n", exception.reason ?: @""];
    NSDictionary *info = exception.userInfo;
    if (info.count) [out appendFormat:@"info %@\n", info];
    [out appendFormat:@"thread %@\n", [NSThread currentThread]];
    NSArray *symbols = exception.callStackSymbols;
    if (symbols.count) {
        [out appendString:@"stack\n"];
        NSUInteger cap = symbols.count;
        if (cap > 40) cap = 40;
        for (NSUInteger i = 0; i < cap; i++) {
            [out appendFormat:@"  %@\n", [symbols objectAtIndex:i]];
        }
    } else {
        NSArray *addrs = exception.callStackReturnAddresses;
        if (addrs.count) {
            [out appendString:@"addresses\n"];
            NSUInteger cap = addrs.count;
            if (cap > 40) cap = 40;
            for (NSUInteger i = 0; i < cap; i++) {
                [out appendFormat:@"  %@\n", [addrs objectAtIndex:i]];
            }
        }
    }
    NSData *data = [out dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length) waCrashWriteAll((const char *)data.bytes, data.length, 1);
    if (waPrevException) waPrevException(exception);
    else abort();
}

static void waCrashCatch(int sig) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = waCrashSignal;
    action.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&action.sa_mask);
    if (sig >= 0 && sig < 32) {
        memset(&waPrevSignals[sig], 0, sizeof(waPrevSignals[sig]));
        sigaction(sig, &action, &waPrevSignals[sig]);
    } else {
        sigaction(sig, &action, NULL);
    }
}

@implementation waCrash

+ (NSString *)reportPath {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docs.count) return [[docs objectAtIndex:0] stringByAppendingPathComponent:@"wave.crash"];
    return @"/var/mobile/Documents/wave.crash";
}

+ (NSString *)lastReport {
    NSArray *paths = [NSArray arrayWithObjects:[self reportPath], @"/var/mobile/Documents/wave.crash", @"/tmp/wave.crash", nil];
    for (NSString *path in paths) {
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (text.length) return text;
    }
    return nil;
}

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        waPrevException = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&waCrashException);
        signal(SIGPIPE, SIG_IGN);
        waCrashCatch(SIGSEGV);
        waCrashCatch(SIGBUS);
        waCrashCatch(SIGILL);
        waCrashCatch(SIGABRT);
        waCrashCatch(SIGFPE);
        waCrashCatch(SIGTRAP);
        waCrashCatch(SIGSYS);
    });
}

@end
