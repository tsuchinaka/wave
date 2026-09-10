#include "waDeezerBlowfish.h"
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <string.h>

static const char waDeezerSecret[16] = "g4el58wc0zvf9na1";
static const unsigned char waDeezerIV[8] = {0, 1, 2, 3, 4, 5, 6, 7};

void waDeezerDeriveKey(const char *trackID, unsigned char outKey[16]) {
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    char hex[32];
    static const char nibble[] = "0123456789abcdef";
    size_t len = trackID ? strlen(trackID) : 0;
    if (len) CC_MD5(trackID, (CC_LONG)len, digest);
    else memset(digest, 0, sizeof(digest));
    for (int i = 0; i < 16; i++) {
        hex[i * 2] = nibble[(digest[i] >> 4) & 0xF];
        hex[i * 2 + 1] = nibble[digest[i] & 0xF];
    }
    for (int i = 0; i < 16; i++) {
        outKey[i] = ((unsigned char)hex[i] ^ (unsigned char)hex[i + 16] ^
                     (unsigned char)waDeezerSecret[i]);
    }
}

int waDeezerDecryptChunk(const unsigned char key[16], unsigned long chunkIndex,
                         unsigned char *data, unsigned long length) {
    if (!data || !length || !key) return 0;
    if (chunkIndex % 3 != 0) return 0;
    size_t aligned = (size_t)(length - (length % 8));
    if (!aligned) return 0;
    // CCCrypt one-shot, CBC, no padding. IV resets per chunk (Deezer spec).
    unsigned char tmp[2048];
    size_t remaining = aligned;
    unsigned char *cursor = data;
    while (remaining) {
        size_t step = remaining > sizeof(tmp) ? sizeof(tmp) : remaining;
        size_t moved = 0;
        CCCryptorStatus status =
            CCCrypt(kCCDecrypt, kCCAlgorithmBlowfish, 0, key, 16, waDeezerIV,
                    cursor, step, tmp, sizeof(tmp), &moved);
        if (status != kCCSuccess || moved != step) return -1;
        memcpy(cursor, tmp, step);
        cursor += step;
        remaining -= step;
    }
    return 0;
}
