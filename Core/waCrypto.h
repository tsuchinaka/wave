#ifndef WA_CRYPTO_H
#define WA_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WA_STRIPE 2048u

// Cipher the CDN applied to a stripe. BF_CBC_STRIPE is the only one Deezer
// serves today; the rest are the published media ciphers so a new grant is
// a one-line addition here instead of a parser change.
typedef enum {
    waCipherNone = 0,
    waCipherBlowfishStripe = 1,   // BF_CBC_STRIPE: 2048-byte stripes, every third
    waCipherAESCTR = 2,           // AES_CTR
    waCipherAESCBCStripe = 3      // AES_CBC_STRIPE
} waCipher;

// Case-insensitive. Unknown names fall back to Blowfish stripe, which is
// what every stream has been until now.
waCipher waCipherFromName(const char *name);

typedef struct waCryptor waCryptor;

// Deezer ARL key: md5_hex(trackID)[0..16] XOR md5_hex(trackID)[16..32] XOR secret.
void waKeyForTrack(const char *trackID, uint8_t outKey[16]);

// One persistent context per track. The key schedule is built once; only
// the IV is reset per stripe.
waCryptor *waCryptorCreate(const char *trackID);
waCryptor *waCryptorCreateCipher(const char *trackID, waCipher cipher);
void waCryptorFree(waCryptor *c);

// Decrypts one stripe in place when (index % 3 == 0). Length may be a
// partial tail; only the block-aligned prefix is transformed.
int waCryptorStripe(waCryptor *c, unsigned long index, uint8_t *data, size_t length);

// Consumes whole stripes from a buffer, advancing *index. in-place.
// Returns bytes consumed, or -1. *audioOK reports whether stripe 0 looked
// like a real MP3/FLAC payload (catches a wrong ARL/track pair early).
long waCryptorConsume(waCryptor *c, unsigned long *index, uint8_t *data, size_t length, int *audioOK);

// 0 unknown, 1 MPEG audio, 2 FLAC, 3 ID3-tagged MPEG.
int waSniffAudio(const uint8_t *data, size_t length);

#ifdef __cplusplus
}
#endif

#endif
