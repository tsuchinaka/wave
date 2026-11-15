#import "waTags.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static NSUInteger waSyncSafe32(const uint8_t *bytes) {
    return ((NSUInteger)(bytes[0] & 0x7F) << 21) |
           ((NSUInteger)(bytes[1] & 0x7F) << 14) |
           ((NSUInteger)(bytes[2] & 0x7F) << 7) |
           (NSUInteger)(bytes[3] & 0x7F);
}

static void waWriteSyncSafe(uint8_t *out, NSUInteger value) {
    out[0] = (uint8_t)((value >> 21) & 0x7F);
    out[1] = (uint8_t)((value >> 14) & 0x7F);
    out[2] = (uint8_t)((value >> 7) & 0x7F);
    out[3] = (uint8_t)(value & 0x7F);
}

static uint32_t waBigEndian32(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static uint32_t waLittleEndian32(const uint8_t *bytes) {
    return ((uint32_t)bytes[3] << 24) | ((uint32_t)bytes[2] << 16) |
           ((uint32_t)bytes[1] << 8) | (uint32_t)bytes[0];
}

static NSError *waTagError(NSString *message) {
    return [NSError errorWithDomain:@"wave.tags" code:1 userInfo:
            [NSDictionary dictionaryWithObject:message ?: @"Tag write failed." forKey:NSLocalizedDescriptionKey]];
}

#pragma mark - writing

// Encoding 1: UTF-16 with a BOM, which every player from the era reads.
static NSData *waTextPayload(NSString *text) {
    NSMutableData *data = [NSMutableData data];
    uint8_t encoding = 1;
    [data appendBytes:&encoding length:1];
    uint8_t bom[2] = {0xFF, 0xFE};
    [data appendBytes:bom length:2];
    NSData *body = [text dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    if (body.length) [data appendData:body];
    uint8_t terminator[2] = {0x00, 0x00};
    [data appendBytes:terminator length:2];
    return data;
}

static NSData *waUserTextPayload(NSString *description, NSString *value) {
    NSMutableData *data = [NSMutableData data];
    uint8_t encoding = 1;
    [data appendBytes:&encoding length:1];
    uint8_t bom[2] = {0xFF, 0xFE};
    [data appendBytes:bom length:2];
    NSData *desc = [description dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    if (desc.length) [data appendData:desc];
    uint8_t terminator[2] = {0x00, 0x00};
    [data appendBytes:terminator length:2];
    [data appendBytes:bom length:2];
    NSData *val = [value dataUsingEncoding:NSUTF16LittleEndianStringEncoding];
    if (val.length) [data appendData:val];
    [data appendBytes:terminator length:2];
    return data;
}

static NSData *waPicturePayload(NSData *cover) {
    NSMutableData *data = [NSMutableData data];
    uint8_t encoding = 0;
    [data appendBytes:&encoding length:1];
    const char *mime = "image/jpeg";
    [data appendBytes:mime length:strlen(mime) + 1];
    uint8_t pictureType = 3; // front cover
    [data appendBytes:&pictureType length:1];
    uint8_t empty = 0;
    [data appendBytes:&empty length:1];
    [data appendData:cover];
    return data;
}

static NSData *waFrame(NSString *identifier, NSData *payload) {
    if (identifier.length != 4 || !payload) return nil;
    NSMutableData *frame = [NSMutableData data];
    uint8_t header[10];
    memcpy(header, [identifier UTF8String], 4);
    uint32_t size = (uint32_t)payload.length;
    header[4] = (uint8_t)((size >> 24) & 0xFF);
    header[5] = (uint8_t)((size >> 16) & 0xFF);
    header[6] = (uint8_t)((size >> 8) & 0xFF);
    header[7] = (uint8_t)(size & 0xFF);
    header[8] = 0;
    header[9] = 0;
    [frame appendBytes:header length:10];
    [frame appendData:payload];
    return frame;
}

#pragma mark - reading

static NSString *waDecodedText(NSData *data) {
    if (data.length < 1) return nil;
    const uint8_t *bytes = data.bytes;
    uint8_t encoding = bytes[0];
    NSData *body = [data subdataWithRange:NSMakeRange(1, data.length - 1)];
    NSString *text = nil;
    switch (encoding) {
        case 0: text = [[NSString alloc] initWithData:body encoding:NSISOLatin1StringEncoding]; break;
        case 1: text = [[NSString alloc] initWithData:body encoding:NSUTF16StringEncoding]; break;
        case 2: text = [[NSString alloc] initWithData:body encoding:NSUTF16BigEndianStringEncoding]; break;
        case 3: text = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding]; break;
        default: break;
    }
    if (!text) return nil;
    NSRange terminator = [text rangeOfString:@"\0"];
    if (terminator.location != NSNotFound) text = [text substringToIndex:terminator.location];
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// Description then value, each with its own encoding rule.
static void waSplitUserText(NSData *data, NSString **description, NSString **value) {
    if (description) *description = nil;
    if (value) *value = nil;
    if (data.length < 2) return;
    const uint8_t *bytes = data.bytes;
    uint8_t encoding = bytes[0];
    NSUInteger start = 1;
    NSUInteger cursor = start;
    BOOL wide = (encoding == 1 || encoding == 2);
    while (cursor + 1 < data.length) {
        if (wide) {
            if (bytes[cursor] == 0 && bytes[cursor + 1] == 0) break;
            cursor += 2;
        } else {
            if (bytes[cursor] == 0) break;
            cursor += 1;
        }
    }
    NSUInteger separator = cursor;
    NSUInteger valueStart = separator + (wide ? 2 : 1);
    NSData *head = [data subdataWithRange:NSMakeRange(start, separator - start)];
    NSMutableData *headFrame = [NSMutableData dataWithBytes:&encoding length:1];
    [headFrame appendData:head];
    if (description) *description = waDecodedText(headFrame);
    if (valueStart < data.length) {
        NSData *tail = [data subdataWithRange:NSMakeRange(valueStart, data.length - valueStart)];
        NSMutableData *tailFrame = [NSMutableData dataWithBytes:&encoding length:1];
        [tailFrame appendData:tail];
        if (value) *value = waDecodedText(tailFrame);
    }
}

// Undo the ID3 unsynchronisation scheme: FF 00 becomes FF.
static NSData *waDeunsynchronised(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSMutableData *out = [NSMutableData dataWithCapacity:data.length];
    for (NSUInteger i = 0; i < data.length; i++) {
        uint8_t byte = bytes[i];
        [out appendBytes:&byte length:1];
        if (byte == 0xFF && i + 1 < data.length && bytes[i + 1] == 0x00) i++;
    }
    return out;
}

static void waApplyFrame(NSString *identifier, NSData *payload, NSMutableDictionary *result) {
    if (!identifier.length || !payload.length) return;
    if ([identifier isEqualToString:@"TXXX"]) {
        NSString *description = nil;
        NSString *value = nil;
        waSplitUserText(payload, &description, &value);
        if (!description.length || !value.length) return;
        NSString *key = [description uppercaseString];
        if ([key isEqualToString:@"DEEZER_TRACK_ID"]) result[@"trackID"] = value;
        else if ([key isEqualToString:@"DEEZER_ALBUM_ID"]) result[@"albumID"] = value;
        else if ([key isEqualToString:@"DEEZER_ARTIST_ID"]) result[@"artistID"] = value;
        return;
    }
    NSString *text = waDecodedText(payload);
    if (!text.length) return;
    if ([identifier isEqualToString:@"TIT2"]) result[@"title"] = text;
    else if ([identifier isEqualToString:@"TPE1"]) result[@"artist"] = text;
    else if ([identifier isEqualToString:@"TALB"]) result[@"album"] = text;
    else if ([identifier isEqualToString:@"TRCK"]) result[@"track"] = text;
    else if ([identifier isEqualToString:@"TPOS"]) result[@"disc"] = text;
    else if ([identifier isEqualToString:@"TYER"] || [identifier isEqualToString:@"TDRC"]) result[@"year"] = text;
}

@implementation waTags

+ (NSDictionary *)id3TagsAtPath:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    @try {
        NSData *header = [handle readDataOfLength:10];
        if (header.length < 10) return nil;
        const uint8_t *bytes = header.bytes;
        if (bytes[0] != 'I' || bytes[1] != 'D' || bytes[2] != '3') return nil;
        uint8_t version = bytes[3];
        if (version < 3 || version > 4) return nil;
        uint8_t flags = bytes[5];
        NSUInteger tagSize = waSyncSafe32(bytes + 6);
        if (tagSize < 10 || tagSize > 32 * 1024 * 1024) return nil;

        NSMutableDictionary *result = [NSMutableDictionary dictionary];

        if (flags & 0x80) {
            // Unsynchronised tag: offsets shift, so take the whole block.
            [handle seekToFileOffset:10];
            NSData *body = waDeunsynchronised([handle readDataOfLength:tagSize]);
            NSUInteger offset = 0;
            if ((flags & 0x40) && body.length >= 4) offset = 4 + waBigEndian32(body.bytes);
            while (offset + 10 <= body.length) {
                const uint8_t *frame = (const uint8_t *)body.bytes + offset;
                if (frame[0] == 0) break;
                NSString *identifier = [[NSString alloc] initWithBytes:frame length:4 encoding:NSISOLatin1StringEncoding];
                NSUInteger size = (version == 4) ? waSyncSafe32(frame + 4) : waBigEndian32(frame + 4);
                if (!size || offset + 10 + size > body.length) break;
                waApplyFrame(identifier, [body subdataWithRange:NSMakeRange(offset + 10, size)], result);
                offset += 10 + size;
            }
            return result.count ? result : nil;
        }

        NSUInteger offset = 10;
        if (flags & 0x40) {
            [handle seekToFileOffset:10];
            NSData *extended = [handle readDataOfLength:4];
            if (extended.length < 4) return nil;
            offset = 10 + 4 + waBigEndian32(extended.bytes);
        }
        NSUInteger end = 10 + tagSize;
        while (offset + 10 <= end) {
            [handle seekToFileOffset:offset];
            NSData *frameHeader = [handle readDataOfLength:10];
            if (frameHeader.length < 10) break;
            const uint8_t *frame = frameHeader.bytes;
            if (frame[0] == 0) break;
            NSString *identifier = [[NSString alloc] initWithBytes:frame length:4 encoding:NSISOLatin1StringEncoding];
            NSUInteger size = (version == 4) ? waSyncSafe32(frame + 4) : waBigEndian32(frame + 4);
            if (!size || offset + 10 + size > end) break;
            // Only the small text frames are read; artwork is skipped in place.
            if ([identifier hasPrefix:@"T"] && size <= 8192) {
                [handle seekToFileOffset:offset + 10];
                NSData *payload = [handle readDataOfLength:size];
                waApplyFrame(identifier, payload, result);
            }
            offset += 10 + size;
        }
        return result.count ? result : nil;
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    } @finally {
        [handle closeFile];
    }
}

+ (NSDictionary *)flacTagsAtPath:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    @try {
        NSData *magic = [handle readDataOfLength:4];
        if (magic.length < 4 || memcmp(magic.bytes, "fLaC", 4) != 0) return nil;
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        BOOL last = NO;
        NSUInteger offset = 4;
        while (!last) {
            [handle seekToFileOffset:offset];
            NSData *blockHeader = [handle readDataOfLength:4];
            if (blockHeader.length < 4) break;
            const uint8_t *bytes = blockHeader.bytes;
            last = (bytes[0] & 0x80) != 0;
            uint8_t type = bytes[0] & 0x7F;
            NSUInteger length = ((NSUInteger)bytes[1] << 16) | ((NSUInteger)bytes[2] << 8) | bytes[3];
            if (type == 4 && length > 8 && length < 1024 * 1024) {
                NSData *block = [handle readDataOfLength:length];
                const uint8_t *blockBytes = block.bytes;
                NSUInteger cursor = 0;
                if (block.length < 8) break;
                uint32_t vendorLength = waLittleEndian32(blockBytes + cursor);
                cursor += 4 + vendorLength;
                if (cursor + 4 > block.length) break;
                uint32_t count = waLittleEndian32(blockBytes + cursor);
                cursor += 4;
                for (uint32_t index = 0; index < count && cursor + 4 <= block.length; index++) {
                    uint32_t itemLength = waLittleEndian32(blockBytes + cursor);
                    cursor += 4;
                    if (cursor + itemLength > block.length) break;
                    NSData *itemData = [block subdataWithRange:NSMakeRange(cursor, itemLength)];
                    cursor += itemLength;
                    NSString *item = [[NSString alloc] initWithData:itemData encoding:NSUTF8StringEncoding];
                    NSRange equals = [item rangeOfString:@"="];
                    if (equals.location == NSNotFound) continue;
                    NSString *key = [[item substringToIndex:equals.location] uppercaseString];
                    NSString *value = [item substringFromIndex:equals.location + 1];
                    if ([key isEqualToString:@"TITLE"]) result[@"title"] = value;
                    else if ([key isEqualToString:@"ARTIST"]) result[@"artist"] = value;
                    else if ([key isEqualToString:@"ALBUM"]) result[@"album"] = value;
                    else if ([key isEqualToString:@"TRACKNUMBER"]) result[@"track"] = value;
                    else if ([key isEqualToString:@"DISCNUMBER"]) result[@"disc"] = value;
                    else if ([key isEqualToString:@"DATE"]) result[@"year"] = value;
                    else if ([key isEqualToString:@"DEEZER_TRACK_ID"]) result[@"trackID"] = value;
                    else if ([key isEqualToString:@"DEEZER_ALBUM_ID"]) result[@"albumID"] = value;
                    else if ([key isEqualToString:@"DEEZER_ARTIST_ID"]) result[@"artistID"] = value;
                }
            }
            offset += 4 + length;
        }
        return result.count ? result : nil;
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    } @finally {
        [handle closeFile];
    }
}

+ (NSDictionary *)tagsAtPath:(NSString *)path format:(NSString *)format {
    if (!path.length) return nil;
    if ([format isEqualToString:@"flac"]) return [self flacTagsAtPath:path];
    return [self id3TagsAtPath:path];
}

+ (BOOL)writeID3v23ToPath:(NSString *)path fields:(NSDictionary *)fields cover:(NSData *)cover error:(NSError **)error {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSDictionary *attributes = [manager attributesOfItemAtPath:path error:error];
    if (!attributes) return NO;
    unsigned long long originalSize = [attributes fileSize];
    if (originalSize < 4) {
        if (error) *error = waTagError(@"File is too small to tag.");
        return NO;
    }

    NSMutableData *body = [NSMutableData data];
    NSArray *textFrames = [NSArray arrayWithObjects:@"TIT2", @"TPE1", @"TALB", @"TRCK", @"TPOS", @"TYER", nil];
    NSArray *textKeys = [NSArray arrayWithObjects:@"title", @"artist", @"album", @"track", @"disc", @"year", nil];
    for (NSUInteger index = 0; index < textFrames.count; index++) {
        id value = [fields objectForKey:[textKeys objectAtIndex:index]];
        if (![value isKindOfClass:[NSString class]] || ![value length]) continue;
        NSData *frame = waFrame([textFrames objectAtIndex:index], waTextPayload(value));
        if (frame) [body appendData:frame];
    }
    NSArray *userKeys = [NSArray arrayWithObjects:@"trackID", @"albumID", @"artistID", nil];
    NSArray *userNames = [NSArray arrayWithObjects:@"DEEZER_TRACK_ID", @"DEEZER_ALBUM_ID", @"DEEZER_ARTIST_ID", nil];
    for (NSUInteger index = 0; index < userKeys.count; index++) {
        id value = [fields objectForKey:[userKeys objectAtIndex:index]];
        if (![value isKindOfClass:[NSString class]] || ![value length]) continue;
        NSData *frame = waFrame(@"TXXX", waUserTextPayload([userNames objectAtIndex:index], value));
        if (frame) [body appendData:frame];
    }
    if (cover.length > 64) {
        NSData *frame = waFrame(@"APIC", waPicturePayload(cover));
        if (frame) [body appendData:frame];
    }

    NSMutableData *tag = [NSMutableData dataWithCapacity:body.length + 10];
    uint8_t header[10] = {'I', 'D', '3', 3, 0, 0, 0, 0, 0, 0};
    waWriteSyncSafe(header + 6, body.length);
    [tag appendBytes:header length:10];
    [tag appendData:body];

    NSFileHandle *source = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!source) {
        if (error) *error = waTagError(@"Cannot open the file.");
        return NO;
    }
    unsigned long long skip = 0;
    @try {
        NSData *existing = [source readDataOfLength:10];
        if (existing.length == 10) {
            const uint8_t *bytes = existing.bytes;
            if (bytes[0] == 'I' && bytes[1] == 'D' && bytes[2] == '3') {
                unsigned long long tagged = 10 + waSyncSafe32(bytes + 6);
                if (tagged < originalSize) skip = tagged;
            }
        }
    } @catch (NSException *exception) {
        (void)exception;
    }

    NSString *temporary = [path stringByAppendingString:@".tag"];
    [manager removeItemAtPath:temporary error:NULL];
    if (![manager createFileAtPath:temporary contents:tag attributes:nil]) {
        [source closeFile];
        if (error) *error = waTagError(@"Cannot create the tagged copy.");
        return NO;
    }
    NSFileHandle *destination = [NSFileHandle fileHandleForWritingAtPath:temporary];
    if (!destination) {
        [source closeFile];
        [manager removeItemAtPath:temporary error:NULL];
        if (error) *error = waTagError(@"Cannot write the tagged copy.");
        return NO;
    }

    BOOL copied = YES;
    @try {
        [destination seekToEndOfFile];
        [source seekToFileOffset:skip];
        while (YES) {
            @autoreleasepool {
                NSData *chunk = [source readDataOfLength:262144];
                if (!chunk.length) break;
                [destination writeData:chunk];
            }
        }
        [destination synchronizeFile];
    } @catch (NSException *exception) {
        copied = NO;
        if (error) *error = waTagError(exception.reason ?: @"Cannot copy the audio.");
    }
    [destination closeFile];
    [source closeFile];

    unsigned long long expected = tag.length + (originalSize - skip);
    unsigned long long written = [[manager attributesOfItemAtPath:temporary error:NULL] fileSize];
    if (!copied || written != expected) {
        [manager removeItemAtPath:temporary error:NULL];
        if (error && !*error) *error = waTagError(@"The tagged copy came out the wrong size.");
        return NO;
    }

    // rename(2) replaces in one step on the same filesystem.
    int moved = rename([temporary fileSystemRepresentation], [path fileSystemRepresentation]);
    if (moved == 0) return YES;
    NSError *replaceError = nil;
    [manager removeItemAtPath:path error:NULL];
    if ([manager moveItemAtPath:temporary toPath:path error:&replaceError]) return YES;
    [manager removeItemAtPath:temporary error:NULL];
    if (error) *error = replaceError ?: waTagError(@"Cannot replace the file.");
    return NO;
}

@end
