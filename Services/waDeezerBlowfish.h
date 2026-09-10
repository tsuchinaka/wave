#ifndef WA_DEEZER_BLOWFISH_H
#define WA_DEEZER_BLOWFISH_H

// Deezer BF_CBC_STRIPE helpers (Minuga-RC/deezer-tui port).
// Key: md5_hex(trackID)[0..16] XOR md5_hex(trackID)[16..32] XOR "g4el58wc0zvf9na1".
// Stream: every 3rd 2048-byte chunk CBC-decrypted, Blowfish, IV 0..7, no padding.
// Uses CommonCrypto (kCCAlgorithmBlowfish exists in iPhoneOS6.1.sdk).
// Pure C so both ARC (player/downloads) and MRC (HTTPSource) can share it.

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void waDeezerDeriveKey(const char *trackID, unsigned char outKey[16]);

// Decrypts floor(length/8)*8 bytes in place when (chunkIndex % 3 == 0).
// No-op otherwise. Returns 0 on success, non-zero on CCCrypt failure.
int waDeezerDecryptChunk(const unsigned char key[16], unsigned long chunkIndex,
                         unsigned char *data, unsigned long length);

#ifdef __cplusplus
}
#endif

#endif
