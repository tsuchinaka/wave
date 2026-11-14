#include "waCrypto.h"
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdlib.h>
#include <string.h>

#define WA_BLOCK 8u

struct waCryptor {
    CCCryptorRef ref;
};

static const char waSecret[16] = "g4el58wc0zvf9na1";
static const uint8_t waIV[8] = {0, 1, 2, 3, 4, 5, 6, 7};

void waKeyForTrack(const char *trackID, uint8_t outKey[16]) {
    uint8_t digest[CC_MD5_DIGEST_LENGTH];
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
        outKey[i] = (uint8_t)((uint8_t)hex[i] ^ (uint8_t)hex[i + 16] ^ (uint8_t)waSecret[i]);
    }
}

waCryptor *waCryptorCreate(const char *trackID) {
    uint8_t key[16];
    waKeyForTrack(trackID, key);
    CCCryptorRef ref = NULL;
    if (CCCryptorCreate(kCCDecrypt, kCCAlgorithmBlowfish, 0, key, sizeof(key), waIV, &ref) != kCCSuccess || !ref) {
        return NULL;
    }
    waCryptor *c = (waCryptor *)calloc(1, sizeof(*c));
    if (!c) {
        CCCryptorRelease(ref);
        return NULL;
    }
    c->ref = ref;
    return c;
}

void waCryptorFree(waCryptor *c) {
    if (!c) return;
    if (c->ref) CCCryptorRelease(c->ref);
    free(c);
}

int waCryptorStripe(waCryptor *c, unsigned long index, uint8_t *data, size_t length) {
    if (!data || !length) return 0;
    if ((index % 3) != 0) return 0;
    if (!c || !c->ref) return -1;
    size_t aligned = length - (length % WA_BLOCK);
    if (!aligned) return 0;
    if (aligned > WA_STRIPE) return -1;
    if (CCCryptorReset(c->ref, waIV) != kCCSuccess) return -1;
    uint8_t scratch[WA_STRIPE];
    size_t moved = 0;
    CCCryptorStatus status = CCCryptorUpdate(c->ref, data, aligned, scratch, sizeof(scratch), &moved);
    if (status != kCCSuccess || moved != aligned) return -1;
    memcpy(data, scratch, aligned);
    return 0;
}

long waCryptorConsume(waCryptor *c, unsigned long *index, uint8_t *data, size_t length, int *audioOK) {
    if (audioOK) *audioOK = 1;
    if (!data || !index) return -1;
    size_t consumed = 0;
    while (length - consumed >= WA_STRIPE) {
        unsigned long current = *index;
        if (waCryptorStripe(c, current, data + consumed, WA_STRIPE) != 0) return -1;
        if (current == 0 && waSniffAudio(data, 16) == 0) {
            if (audioOK) *audioOK = 0;
            return -1;
        }
        consumed += WA_STRIPE;
        (*index)++;
    }
    return (long)consumed;
}

int waSniffAudio(const uint8_t *data, size_t length) {
    if (!data || length < 4) return 0;
    if (data[0] == 'I' && data[1] == 'D' && data[2] == '3') return 3;
    if (data[0] == 'f' && data[1] == 'L' && data[2] == 'a' && data[3] == 'C') return 2;
    if (data[0] == 0xFF && (data[1] & 0xE0) == 0xE0 && (data[1] & 0x18) != 0x08 && (data[1] & 0x06) != 0x00) return 1;
    return 0;
}
