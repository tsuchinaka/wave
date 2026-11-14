#import "waTLS.h"
#import "waLog.h"

#include "mbedtls/config.h"
#include "mbedtls/ssl.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/error.h"
#include "mbedtls/x509_crt.h"

#include <sys/socket.h>
#include <sys/types.h>
#include <netdb.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>

static NSError *waTLSError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"wave.tls" code:code userInfo:@{NSLocalizedDescriptionKey: message ?: @"TLS failed."}];
}

static int waTLSBioSend(void *context, const unsigned char *buf, size_t len) {
    int fd = *(int *)context;
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, buf + sent, len - sent, 0);
        if (n <= 0) {
            if (errno == EINTR) continue;
            return MBEDTLS_ERR_SSL_WANT_WRITE;
        }
        sent += (size_t)n;
    }
    return (int)sent;
}

static int waTLSBioRecv(void *context, unsigned char *buf, size_t len) {
    int fd = *(int *)context;
    ssize_t n = recv(fd, buf, len, 0);
    if (n < 0) {
        if (errno == EINTR) return MBEDTLS_ERR_SSL_WANT_READ;
        return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    }
    return (int)n;
}

int mbedtls_hardware_poll(void *data, unsigned char *output, size_t len, size_t *olen) {
    (void)data;
    arc4random_buf(output, len);
    *olen = len;
    return 0;
}

@interface waTLS ()
+ (NSDictionary *)parseResponse:(NSData *)data;
+ (NSData *)dechunk:(NSData *)data;
+ (NSData *)rootCertificate;
+ (void)loadTrustStore:(mbedtls_x509_crt *)ca;
@end

@implementation waTLS

+ (NSData *)rootCertificate {
    static NSData *der = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"digicert-g2" ofType:@"der"];
        if (path.length) der = [NSData dataWithContentsOfFile:path];
        if (!der.length) {
            NSString *fallback = [[NSBundle mainBundle] pathForResource:@"digicert-g2" ofType:@"der" inDirectory:@"certs"];
            if (fallback.length) der = [NSData dataWithContentsOfFile:fallback];
        }
    });
    return der;
}

+ (void)loadTrustStore:(mbedtls_x509_crt *)ca {
    NSArray *names = [NSArray arrayWithObjects:@"digicert-g2", @"isrg-root-x1", @"gts-root-r4", @"gts-root-r1", nil];
    for (NSString *name in names) {
        NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:@"der"];
        if (!path.length) path = [[NSBundle mainBundle] pathForResource:name ofType:@"der" inDirectory:@"certs"];
        if (!path.length) continue;
        NSData *der = [NSData dataWithContentsOfFile:path];
        if (der.length) mbedtls_x509_crt_parse_der(ca, der.bytes, der.length);
    }
}

+ (NSDictionary *)requestURL:(NSURL *)url method:(NSString *)method headers:(NSDictionary *)headers body:(NSData *)body timeout:(NSTimeInterval)timeout error:(NSError **)error {
    return [self requestURL:url method:method headers:headers body:body timeout:timeout verify:YES error:error];
}

+ (NSDictionary *)requestURL:(NSURL *)url method:(NSString *)method headers:(NSDictionary *)headers body:(NSData *)body timeout:(NSTimeInterval)timeout verify:(BOOL)verify error:(NSError **)error {
    if (!url.host.length) {
        if (error) *error = waTLSError(1, @"Missing host.");
        return nil;
    }
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"https"]) {
        if (error) *error = waTLSError(2, @"TLS requires https.");
        return nil;
    }

    struct addrinfo hints;
    struct addrinfo *result = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    NSString *service = url.port ? url.port.stringValue : @"443";
    int gai = getaddrinfo(url.host.UTF8String, service.UTF8String, &hints, &result);
    if (gai != 0 || !result) {
        if (error) *error = waTLSError(3, @"Could not resolve host.");
        return nil;
    }

    int fd = -1;
    for (struct addrinfo *ai = result; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int connected = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (connected < 0 && errno == EINPROGRESS) {
            fd_set writeSet;
            FD_ZERO(&writeSet);
            FD_SET(fd, &writeSet);
            struct timeval tv = { (long)timeout, 0 };
            int selected = select(fd + 1, NULL, &writeSet, NULL, &tv);
            if (selected > 0) {
                int soError = 0;
                socklen_t len = sizeof(soError);
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len);
                connected = soError == 0 ? 0 : -1;
            } else {
                connected = -1;
            }
        }
        if (connected == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(result);
    if (fd < 0) {
        if (error) *error = waTLSError(4, @"Could not connect to the host.");
        return nil;
    }
    fcntl(fd, F_SETFL, 0);
    struct timeval ioTimeout = { (long)timeout, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &ioTimeout, sizeof(ioTimeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &ioTimeout, sizeof(ioTimeout));

    NSData *parsed = nil;
    NSInteger statusCode = 0;
    NSDictionary *parsedHeaders = nil;
    NSMutableData *response = [NSMutableData data];
    NSMutableString *head = [NSMutableString string];
    NSMutableDictionary *allHeaders = [NSMutableDictionary dictionary];
    NSMutableData *requestData = nil;
    NSString *path = nil;
    NSDictionary *parsedResponse = nil;

    NSData *rootDER = [self rootCertificate];
    if (!rootDER.length && verify) {
        close(fd);
        if (error) *error = waTLSError(5, @"Trust store missing.");
        return nil;
    }

    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_x509_crt ca;
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&drbg);
    mbedtls_x509_crt_init(&ca);

    [self loadTrustStore:&ca];
    if (rootDER.length) mbedtls_x509_crt_parse_der(&ca, rootDER.bytes, rootDER.length);
    const char *personal = "wave";
    int status = mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy, (const unsigned char *)personal, strlen(personal));
    if (status != 0) {
        if (error) *error = waTLSError(6, @"Random source failed.");
        goto cleanup;
    }
    status = mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    if (status != 0) {
        if (error) *error = waTLSError(7, @"TLS config failed.");
        goto cleanup;
    }
    mbedtls_ssl_conf_authmode(&conf, verify ? MBEDTLS_SSL_VERIFY_REQUIRED : MBEDTLS_SSL_VERIFY_NONE);
    mbedtls_ssl_conf_ca_chain(&conf, &ca, NULL);
    mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);
    mbedtls_ssl_conf_min_version(&conf, MBEDTLS_SSL_MAJOR_VERSION_3, MBEDTLS_SSL_MINOR_VERSION_3);

    status = mbedtls_ssl_setup(&ssl, &conf);
    if (status != 0) {
        if (error) *error = waTLSError(8, @"TLS setup failed.");
        goto cleanup;
    }
    mbedtls_ssl_set_hostname(&ssl, url.host.UTF8String);
    int socketFD = fd;
    mbedtls_ssl_set_bio(&ssl, &socketFD, waTLSBioSend, waTLSBioRecv, NULL);

    while ((status = mbedtls_ssl_handshake(&ssl)) != 0) {
        if (status != MBEDTLS_ERR_SSL_WANT_READ && status != MBEDTLS_ERR_SSL_WANT_WRITE) break;
    }
    if (status != 0) {
        char buffer[160];
        mbedtls_strerror(status, buffer, sizeof(buffer));
        if (error) *error = waTLSError(9, [NSString stringWithFormat:@"TLS handshake: %s", buffer]);
        goto cleanup;
    }
    if (verify && mbedtls_ssl_get_verify_result(&ssl) != 0) {
        if (error) *error = waTLSError(10, @"Certificate verification failed.");
        goto cleanup;
    }

    path = url.path.length ? url.path : @"/";
    if (url.query.length) path = [path stringByAppendingFormat:@"?%@", url.query];
    [head appendFormat:@"%@ %@ HTTP/1.1\r\n", method ?: @"GET", path];
    [head appendFormat:@"Host: %@\r\n", url.host];
    [head appendString:@"Connection: close\r\n"];
    [head appendString:@"User-Agent: Wave/1.0 (iOS 5.1; lyrics)\r\n"];
    [head appendString:@"Accept: application/json,*/*\r\n"];
    [head appendString:@"Accept-Encoding: identity\r\n"];
    if (body.length) [allHeaders setObject:@"application/json" forKey:@"Content-Type"];
    if (headers) [allHeaders addEntriesFromDictionary:headers];
    for (NSString *key in allHeaders) {
        id value = allHeaders[key];
        if (![value isKindOfClass:[NSString class]]) continue;
        if ([key caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
        [head appendFormat:@"%@: %@\r\n", key, value];
    }
    if (body.length) [head appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [head appendString:@"\r\n"];

    requestData = [NSMutableData dataWithData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    if (body.length) [requestData appendData:body];
    size_t written = 0;
    const unsigned char *bytes = requestData.bytes;
    while (written < requestData.length) {
        int n = mbedtls_ssl_write(&ssl, bytes + written, requestData.length - written);
        if (n > 0) { written += (size_t)n; continue; }
        if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        if (error) *error = waTLSError(11, @"TLS write failed.");
        goto cleanup;
    }

    unsigned char chunk[4096];
    while (YES) {
        int n = mbedtls_ssl_read(&ssl, chunk, sizeof(chunk));
        if (n > 0) { [response appendBytes:chunk length:(NSUInteger)n]; continue; }
        if (n == 0 || n == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) break;
        if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        break;
    }

    parsedResponse = [self parseResponse:response];
    if (!parsedResponse) {
        if (error) *error = waTLSError(12, @"Malformed HTTP response.");
        goto cleanup;
    }
    statusCode = [parsedResponse[@"status"] integerValue];
    parsedHeaders = parsedResponse[@"headers"];
    parsed = parsedResponse[@"body"];
    mbedtls_ssl_close_notify(&ssl);

cleanup:
    mbedtls_ssl_free(&ssl);
    mbedtls_ssl_config_free(&conf);
    mbedtls_ctr_drbg_free(&drbg);
    mbedtls_entropy_free(&entropy);
    mbedtls_x509_crt_free(&ca);
    close(fd);

    if (!parsed) return nil;
    return @{@"status": [NSNumber numberWithInteger:statusCode],
             @"body": parsed,
             @"headers": parsedHeaders ?: @{}};
}

+ (NSDictionary *)parseResponse:(NSData *)data {
    if (data.length < 12) return nil;
    const char *bytes = data.bytes;
    NSRange headerRange = [data rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, data.length)];
    if (headerRange.location == NSNotFound) return nil;
    NSString *head = [[NSString alloc] initWithBytes:bytes length:headerRange.location encoding:NSUTF8StringEncoding];
    if (!head.length) return nil;
    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    NSString *statusLine = lines.count ? lines[0] : @"";
    NSArray *parts = [statusLine componentsSeparatedByString:@" "];
    NSInteger code = parts.count > 1 ? [parts[1] integerValue] : 0;
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = [[line substringToIndex:colon.location] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (key.length) map[key] = value;
    }
    NSUInteger bodyStart = headerRange.location + headerRange.length;
    NSData *payload = [data subdataWithRange:NSMakeRange(bodyStart, data.length - bodyStart)];
    NSString *transfer = map[@"transfer-encoding"];
    if (transfer.length && [transfer.lowercaseString rangeOfString:@"chunked"].location != NSNotFound) {
        payload = [self dechunk:payload];
    } else {
        NSString *lengthValue = map[@"content-length"];
        if (lengthValue.length) {
            NSUInteger expected = (NSUInteger)[lengthValue integerValue];
            if (payload.length > expected) payload = [payload subdataWithRange:NSMakeRange(0, expected)];
        }
    }
    NSData *finalPayload = payload ?: [NSData data];
    return @{@"status": [NSNumber numberWithInteger:code],
             @"headers": map,
             @"body": finalPayload};
}

+ (NSData *)dechunk:(NSData *)data {
    NSMutableData *result = [NSMutableData data];
    const char *bytes = data.bytes;
    NSUInteger length = data.length;
    NSUInteger offset = 0;
    while (offset + 2 < length) {
        const char *window = bytes + offset;
        NSUInteger remaining = length - offset;
        NSInteger found = -1;
        for (NSUInteger i = 0; i + 1 < remaining; i++) {
            if (window[i] == '\r' && window[i + 1] == '\n') { found = (NSInteger)i; break; }
        }
        if (found < 0) break;
        NSUInteger lineLength = (NSUInteger)found;
        char sizeBuffer[32] = {0};
        if (lineLength >= sizeof(sizeBuffer)) break;
        memcpy(sizeBuffer, bytes + offset, lineLength);
        char *semicolon = strchr(sizeBuffer, ';');
        if (semicolon) *semicolon = 0;
        long size = strtol(sizeBuffer, NULL, 16);
        offset += lineLength + 2;
        if (size <= 0) break;
        if (offset + (NSUInteger)size > length) break;
        [result appendBytes:bytes + offset length:(NSUInteger)size];
        offset += (NSUInteger)size + 2;
    }
    return result;
}

@end
