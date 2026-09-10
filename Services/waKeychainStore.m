#import "waKeychainStore.h"
#import <Security/Security.h>
static NSString * const waKeychainService = @"com.bytebox.wave.auth";
// Some jailbreak environments deny Keychain writes for root-installed
// applications. Keep the legacy fallback so login remains usable there.
static NSString * const waFallbackTokenKey = @"wa.keychainFallbackToken";
static NSString * const waDeezerARLFallbackKey = @"wa.deezerARLFallback";
// In-memory cache avoids SecItemCopyMatching IPC on the caller thread
// (often main). Populated on read, updated/cleared on write/delete.
static NSMutableDictionary *waKeychainMemoryCache(void) {
    static NSMutableDictionary *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cache = [[NSMutableDictionary alloc] init]; });
    return cache;
}
@implementation waKeychainStore
+ (NSMutableDictionary *)query { return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:waKeychainService,(__bridge id)kSecAttrAccount:@"token"} mutableCopy]; }
+ (NSString *)token {
    @synchronized (waKeychainMemoryCache()) {
        NSString *cached = waKeychainMemoryCache()[@"token"];
        if (cached.length) return cached;
    }
    NSMutableDictionary *q = [self query]; q[(__bridge id)kSecReturnData] = @YES; q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne; CFTypeRef result = NULL; OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result); NSString *value = nil; if (status == errSecSuccess && result) value = [[NSString alloc] initWithData:(__bridge_transfer NSData *)result encoding:NSUTF8StringEncoding]; if (!value.length) value = [[NSUserDefaults standardUserDefaults] stringForKey:waFallbackTokenKey]; if (value.length) @synchronized (waKeychainMemoryCache()) { waKeychainMemoryCache()[@"token"] = value; } return value;
}
+ (BOOL)setToken:(NSString *)token { if (!token.length) return NO; NSData *data = [token dataUsingEncoding:NSUTF8StringEncoding]; [self clearToken]; NSMutableDictionary *q = [self query]; q[(__bridge id)kSecValueData] = data; OSStatus status = SecItemAdd((__bridge CFDictionaryRef)q, NULL); if (status == errSecSuccess) { [[NSUserDefaults standardUserDefaults] removeObjectForKey:waFallbackTokenKey]; @synchronized (waKeychainMemoryCache()) { waKeychainMemoryCache()[@"token"] = token; } return YES; } NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithObject:data forKey:(__bridge id)kSecValueData]; status = SecItemUpdate((__bridge CFDictionaryRef)[self query], (__bridge CFDictionaryRef)attributes); if (status == errSecSuccess) { [[NSUserDefaults standardUserDefaults] removeObjectForKey:waFallbackTokenKey]; @synchronized (waKeychainMemoryCache()) { waKeychainMemoryCache()[@"token"] = token; } return YES; } NSLog(@"[Wave] Keychain token unavailable (%d); using jailbreak fallback", (int)status); [[NSUserDefaults standardUserDefaults] setObject:token forKey:waFallbackTokenKey]; @synchronized (waKeychainMemoryCache()) { waKeychainMemoryCache()[@"token"] = token; } return YES; }
+ (void)clearToken { SecItemDelete((__bridge CFDictionaryRef)[self query]); [[NSUserDefaults standardUserDefaults] removeObjectForKey:waFallbackTokenKey]; @synchronized (waKeychainMemoryCache()) { [waKeychainMemoryCache() removeObjectForKey:@"token"]; } }
+ (NSMutableDictionary *)queryForDeezerARL { return [@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService:waKeychainService, (__bridge id)kSecAttrAccount:@"deezerARL"} mutableCopy]; }
+ (NSString *)deezerARL {
    @synchronized (waKeychainMemoryCache()) {
        NSString *cached = waKeychainMemoryCache()[@"deezerARL"];
        if (cached.length) return cached;
    }
    NSMutableDictionary *q = [self queryForDeezerARL]; q[(__bridge id)kSecReturnData] = @YES; q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne; CFTypeRef result = NULL; OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result); NSString *value = nil; if (status == errSecSuccess && result) value = [[NSString alloc] initWithData:(__bridge_transfer NSData *)result encoding:NSUTF8StringEncoding]; if (!value.length) value = [[NSUserDefaults standardUserDefaults] stringForKey:waDeezerARLFallbackKey]; if (value.length) @synchronized (waKeychainMemoryCache()) { waKeychainMemoryCache()[@"deezerARL"] = value; } return value;
}
+ (BOOL)setDeezerARL:(NSString *)arl { if (!arl.length) return NO; NSData *data = [arl dataUsingEncoding:NSUTF8StringEncoding]; [self clearDeezerARL]; NSMutableDictionary *q = [self queryForDeezerARL]; q[(__bridge id)kSecValueData] = data; OSStatus status = SecItemAdd((__bridge CFDictionaryRef)q, NULL); if (status == errSecSuccess) { [[NSUserDefaults standardUserDefaults] removeObjectForKey:waDeezerARLFallbackKey]; @synchronized (waKeychainMemoryCache()) { waKeychainMemoryCache()[@"deezerARL"] = arl; } return YES; } NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithObject:data forKey:(__bridge id)kSecValueData]; status = SecItemUpdate((__bridge CFDictionaryRef)[self queryForDeezerARL], (__bridge CFDictionaryRef)attributes); if (status == errSecSuccess) { [[NSUserDefaults standardUserDefaults] removeObjectForKey:waDeezerARLFallbackKey]; @synchronized (waKeychainMemoryCache()) { waKeychainMemoryCache()[@"deezerARL"] = arl; } return YES; } NSLog(@"[Wave] Keychain Deezer session unavailable (%d); using jailbreak fallback", (int)status); [[NSUserDefaults standardUserDefaults] setObject:arl forKey:waDeezerARLFallbackKey]; @synchronized (waKeychainMemoryCache()) { waKeychainMemoryCache()[@"deezerARL"] = arl; } return YES; }
+ (void)clearDeezerARL { SecItemDelete((__bridge CFDictionaryRef)[self queryForDeezerARL]); [[NSUserDefaults standardUserDefaults] removeObjectForKey:waDeezerARLFallbackKey]; @synchronized (waKeychainMemoryCache()) { [waKeychainMemoryCache() removeObjectForKey:@"deezerARL"]; } }
@end
