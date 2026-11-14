#import "waAudioProbe.h"
#include "waCrypto.h"
#include <stdint.h>
#include <string.h>

static const int waMP3Bitrates[2][16] = {
    // MPEG 1
    {0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0},
    // MPEG 2 / 2.5
    {0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0}
};

static const int waMP3Rates[4] = {44100, 48000, 32000, 0};

@implementation waAudioProbe

+ (double)bitrateKbpsFromMP3Data:(NSData *)data {
    if (data.length < 4) return 0.0;
    const uint8_t *bytes = data.bytes;
    NSUInteger limit = MIN(data.length - 4, (NSUInteger)65536);
    for (NSUInteger i = 0; i + 4 <= limit; i++) {
        if (bytes[i] != 0xFF) continue;
        uint8_t b1 = bytes[i + 1];
        uint8_t b2 = bytes[i + 2];
        if ((b1 & 0xE0) != 0xE0) continue;
        int version = (b1 >> 3) & 0x03;   // 3 = MPEG1, 2 = MPEG2, 0 = 2.5
        int layer = (b1 >> 1) & 0x03;     // 1 = layer III
        if (layer == 0 || version == 1) continue;
        int table = (version == 3) ? 0 : 1;
        int index = (b2 >> 4) & 0x0F;
        if (index == 0 || index == 15) continue;
        int rateIndex = (b2 >> 2) & 0x03;
        int sampleRate = waMP3Rates[rateIndex];
        if (version == 2) sampleRate /= 2;
        else if (version == 0) sampleRate /= 4;
        if (!sampleRate) continue;
        return (double)waMP3Bitrates[table][index];
    }
    return 0.0;
}

+ (BOOL)readFLACInfo:(NSData *)data bitrate:(double *)bitrate duration:(double *)duration {
    if (data.length < 42) return NO;
    const uint8_t *b = data.bytes;
    if (!(b[0] == 'f' && b[1] == 'L' && b[2] == 'a' && b[3] == 'C')) return NO;
    NSUInteger offset = 4;
    while (offset + 4 <= data.length) {
        uint8_t header = b[offset];
        BOOL last = (header & 0x80) != 0;
        uint8_t type = header & 0x7F;
        NSUInteger length = ((NSUInteger)b[offset + 1] << 16) | ((NSUInteger)b[offset + 2] << 8) | (NSUInteger)b[offset + 3];
        offset += 4;
        if (offset + length > data.length) return NO;
        if (type == 0 && length >= 34) {
            const uint8_t *info = b + offset;
            uint32_t sampleRate = ((uint32_t)info[10] << 12) | ((uint32_t)info[11] << 4) | ((uint32_t)info[12] >> 4);
            uint64_t totalSamples = ((uint64_t)(info[13] & 0x0F) << 32) | ((uint64_t)info[14] << 24) |
                                    ((uint64_t)info[15] << 16) | ((uint64_t)info[16] << 8) | (uint64_t)info[17];
            if (sampleRate > 0) {
                if (duration) *duration = (double)totalSamples / (double)sampleRate;
                if (bitrate && duration && *duration > 0.0) *bitrate = ((double)data.length * 8.0) / (*duration * 1000.0);
            }
            return YES;
        }
        offset += length;
        if (last) break;
    }
    return NO;
}

+ (double)bitrateKbpsForFile:(NSString *)path {
    if (!path.length) return 0.0;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return 0.0;
    NSData *head = [handle readDataOfLength:256 * 1024];
    [handle closeFile];
    if (!head.length) return 0.0;
    if (waSniffAudio(head.bytes, 4) == 2 || (head.length >= 4 && memcmp(head.bytes, "fLaC", 4) == 0)) {
        double kbps = 0.0, seconds = 0.0;
        if ([self readFLACInfo:head bitrate:&kbps duration:&seconds]) return kbps;
        return 0.0;
    }
    return [self bitrateKbpsFromMP3Data:head];
}

@end
