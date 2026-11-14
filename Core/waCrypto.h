#ifndef WA_CRYPTO_H
#define WA_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WA_STRIPE 2048u

typedef struct waCryptor waCryptor;

// Deezer ARL key: md5_hex(trackID)[0..16] XOR md5_hex(trackID)[16..32] XOR secret.
void waKeyForTrack(const char *trackID, uint8_t outKey[16]);

// One persistent Blowfish context per track. The key schedule is built once;
// only the IV is reset per stripe, which is where the old code burned time.
waCryptor *waCryptorCreate(const char *trackID);
void waCryptorFree(waCryptor *c);

// Decrypts one 2048-byte stripe in place when (index % 3 == 0).
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
