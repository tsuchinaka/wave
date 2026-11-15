#include "waCrypto.h"
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdlib.h>
#include <string.h>

#define WA_BLOCK 8u

struct waCryptor {
    CCCryptorRef ref;
    waCipher cipher;
    uint8_t iv[16];
    size_t ivLength;
    size_t block;
};

static const char waSecret[16] = "g4el58wc0zvf9na1";
static const uint8_t waBlowfishIV[8] = {0, 1, 2, 3, 4, 5, 6, 7};

waCipher waCipherFromName(const char *name) {
    if (!name || !name[0]) return waCipherBlowfishStripe;
    if (strcasecmp(name, "BF_CBC_STRIPE") == 0) return waCipherBlowfishStripe;
    if (strcasecmp(name, "AES_CTR") == 0) return waCipherAESCTR;
    if (strcasecmp(name, "AES_CBC_STRIPE") == 0) return waCipherAESCBCStripe;
    if (strcasecmp(name, "NONE") == 0) return waCipherNone;
    return waCipherBlowfishStripe;
}

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

static void waCipherParams(waCipher cipher, CCAlgorithm *algorithm, CCMode *mode, const uint8_t **iv, size_t *ivLength, size_t *block) {
    switch (cipher) {
        case waCipherAESCTR:
            *algorithm = kCCAlgorithmAES128;
            *mode = kCCModeCTR;
            *iv = waBlowfishIV;
            *ivLength = sizeof(waBlowfishIV);
            *block = 16;
            return;
        case waCipherAESCBCStripe:
            *algorithm = kCCAlgorithmAES128;
            *mode = kCCModeCBC;
            *iv = waBlowfishIV;
            *ivLength = sizeof(waBlowfishIV);
            *block = 16;
            return;
        case waCipherNone:
        case waCipherBlowfishStripe:
        default:
            *algorithm = kCCAlgorithmBlowfish;
            *mode = kCCModeCBC;
            *iv = waBlowfishIV;
            *ivLength = sizeof(waBlowfishIV);
            *block = WA_BLOCK;
            return;
    }
}

waCryptor *waCryptorCreateCipher(const char *trackID, waCipher cipher) {
    if (cipher == waCipherNone) {
        waCryptor *plain = (waCryptor *)calloc(1, sizeof(*plain));
        if (plain) plain->cipher = waCipherNone;
        return plain;
    }
    uint8_t key[16];
    waKeyForTrack(trackID, key);
    CCAlgorithm algorithm;
    CCMode mode;
    const uint8_t *iv;
    size_t ivLength, block;
    waCipherParams(cipher, &algorithm, &mode, &iv, &ivLength, &block);

    CCCryptorRef ref = NULL;
    CCCryptorStatus status = CCCryptorCreateWithMode(kCCDecrypt, mode, algorithm, ccNoPadding, iv, key, sizeof(key), NULL, 0, 0, 0, &ref);
    if (status != kCCSuccess || !ref) return NULL;

    waCryptor *c = (waCryptor *)calloc(1, sizeof(*c));
    if (!c) {
        CCCryptorRelease(ref);
        return NULL;
    }
    c->ref = ref;
    c->cipher = cipher;
    c->block = block;
    c->ivLength = ivLength;
    if (iv && ivLength) memcpy(c->iv, iv, ivLength);
    return c;
}

waCryptor *waCryptorCreate(const char *trackID) {
    return waCryptorCreateCipher(trackID, waCipherBlowfishStripe);
}

void waCryptorFree(waCryptor *c) {
    if (!c) return;
    if (c->ref) CCCryptorRelease(c->ref);
    free(c);
}

int waCryptorStripe(waCryptor *c, unsigned long index, uint8_t *data, size_t length) {
    if (!data || !length) return 0;
    if ((index % 3) != 0) return 0;
    if (!c) return -1;
    if (c->cipher == waCipherNone) return 0;
    if (!c->ref) return -1;
    size_t block = c->block ? c->block : WA_BLOCK;
    size_t aligned = length - (length % block);
    if (!aligned) return 0;
    if (aligned > WA_STRIPE) return -1;
    if (CCCryptorReset(c->ref, c->iv) != kCCSuccess) return -1;
    size_t moved = 0;
    CCCryptorStatus status = CCCryptorUpdate(c->ref, data, aligned, data, aligned, &moved);
    if (status != kCCSuccess || moved != aligned) return -1;
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
