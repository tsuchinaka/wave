#import "waLyrics.h"

@implementation waLyricWord
@end

@implementation waLyricLine
@end

static NSString *waLyricStr(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return nil;
}

static NSTimeInterval waLyricTime(id value) {
    if (!value || [value isKindOfClass:[NSNull class]]) return -1.0;
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = value;
        if (!text.length) return -1.0;
        return [text doubleValue] / 1000.0;
    }
    if ([value respondsToSelector:@selector(doubleValue)]) return [value doubleValue] / 1000.0;
    return -1.0;
}

static NSUInteger waSyllableWeight(NSString *text) {
    if (!text.length) return 1;
    NSString *lower = [text lowercaseString];
    NSCharacterSet *vowels = [NSCharacterSet characterSetWithCharactersInString:@"aeiouyáéíóúäëïöüàèìòùâêîôû"];
    NSUInteger groups = 0;
    BOOL inVowel = NO;
    for (NSUInteger i = 0; i < lower.length; i++) {
        BOOL vowel = [vowels characterIsMember:[lower characterAtIndex:i]];
        if (vowel && !inVowel) groups++;
        inVowel = vowel;
    }
    if (groups == 0) groups = MAX((NSUInteger)1, text.length / 3);
    return groups;
}

static BOOL waIsSustainToken(NSString *text) {
    if (!text.length) return NO;
    NSCharacterSet *marks = [NSCharacterSet characterSetWithCharactersInString:@"~-—–_"];
    BOOL any = NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == ' ' || c == '\t') continue;
        if (![marks characterIsMember:c]) return NO;
        any = YES;
    }
    return any;
}

static NSString *waStripSustainMarker(NSString *text, BOOL *outSustain) {
    if (outSustain) *outSustain = NO;
    if (!text.length) return text;
    NSString *trim = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!trim.length) return @"";
    if (waIsSustainToken(trim)) {
        if (outSustain) *outSustain = YES;
        return @"";
    }
    NSUInteger end = trim.length;
    while (end > 0 && [trim characterAtIndex:end - 1] == '~') end--;
    if (end < trim.length && end > 0) {
        if (outSustain) *outSustain = YES;
        return [[trim substringToIndex:end] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return trim;
}

static BOOL waAbsorbSustainToken(NSMutableArray *words, NSString *text, NSTimeInterval stamp) {
    BOOL sustain = NO;
    NSString *clean = waStripSustainMarker(text, &sustain);
    if (clean.length || !sustain || !words.count) return NO;
    waLyricWord *prev = [words lastObject];
    prev.sustain = YES;
    if (stamp > prev.start) prev.end = stamp;
    return YES;
}

static BOOL waIsVowelChar(unichar c) {
    if (c >= 'A' && c <= 'Z') c = (unichar)(c + 32);
    return (c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u' || c == 'y' ||
            c == 0xE1 || c == 0xE9 || c == 0xED || c == 0xF3 || c == 0xFA ||
            c == 0xE0 || c == 0xE8 || c == 0xEC || c == 0xF2 || c == 0xF9 ||
            c == 0xE4 || c == 0xEB || c == 0xEF || c == 0xF6 || c == 0xFC);
}

static NSArray *waSplitSyllables(NSString *text) {
    if (text.length <= 2) return [NSArray arrayWithObject:text ?: @""];
    NSMutableArray *parts = [NSMutableArray array];
    NSUInteger start = 0;
    BOOL hadVowel = NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        BOOL vowel = waIsVowelChar([text characterAtIndex:i]);
        if (vowel && hadVowel && i > 0 && !waIsVowelChar([text characterAtIndex:i - 1])) {
            NSUInteger cut = i - 1;
            if (cut > start) {
                [parts addObject:[text substringWithRange:NSMakeRange(start, cut - start)]];
                start = cut;
            }
        }
        if (vowel) hadVowel = YES;
    }
    if (start < text.length) [parts addObject:[text substringFromIndex:start]];
    if (!parts.count) [parts addObject:text];
    return parts;
}

static void waLocateWords(waLyricLine *line) {
    NSString *text = line.text ?: @"";
    NSUInteger loc = 0;
    for (waLyricWord *word in line.words) {
        if (!word.text.length) {
            word.location = loc;
            continue;
        }
        NSUInteger left = text.length > loc ? text.length - loc : 0;
        NSRange r = left ? [text rangeOfString:word.text options:NSLiteralSearch range:NSMakeRange(loc, left)] : NSMakeRange(NSNotFound, 0);
        if (r.location == NSNotFound) {
            word.location = loc;
            loc += word.text.length;
        } else {
            word.location = r.location;
            loc = r.location + r.length;
        }
    }
}

static NSInteger waConsumeVoice(NSString **io) {
    if (!io || !*io) return 0;
    NSString *text = *io;
    NSString *low = [text lowercaseString];
    NSArray *alts = [NSArray arrayWithObjects:@"v2:", @"v3:", @"right:", @"duet:", @"chorus:", @"choir:", @"coro:", @"backing:", @"bg:", nil];
    for (NSString *prefix in alts) {
        if ([low hasPrefix:prefix]) {
            *io = [[text substringFromIndex:prefix.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            return 1;
        }
    }
    NSArray *leads = [NSArray arrayWithObjects:@"v1:", @"left:", nil];
    for (NSString *prefix in leads) {
        if ([low hasPrefix:prefix]) {
            *io = [[text substringFromIndex:prefix.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            return 0;
        }
    }
    return 0;
}

static BOOL waLinesOverlap(waLyricLine *a, waLyricLine *b) {
    if (!a || !b) return NO;
    return (a.start < b.end - 0.04 && b.start < a.end - 0.04);
}

static void waAssignDuetVoices(NSArray *lines) {
    for (NSUInteger i = 0; i < lines.count; i++) {
        waLyricLine *line = [lines objectAtIndex:i];
        if (line.voice != 0) continue;
        for (NSUInteger j = 0; j < i; j++) {
            waLyricLine *other = [lines objectAtIndex:j];
            if (other.voice != 0) continue;
            if (fabs(line.start - other.start) < 0.05 || waLinesOverlap(line, other)) {
                line.voice = 1;
                break;
            }
        }
    }
}

static void waStitchWordEnds(NSArray *lines) {
    for (NSUInteger i = 0; i < lines.count; i++) {
        waLyricLine *line = [lines objectAtIndex:i];
        NSTimeInterval lineEnd = line.end;
        NSTimeInterval sameVoice = -1.0;
        NSTimeInterval later = -1.0;
        for (NSUInteger j = i + 1; j < lines.count; j++) {
            waLyricLine *next = [lines objectAtIndex:j];
            if (next.start <= line.start + 0.02) continue;
            if (sameVoice < 0.0 && next.voice == line.voice) sameVoice = next.start;
            if (later < 0.0) later = next.start;
            if (sameVoice > 0.0) break;
        }
        if (lineEnd <= line.start) {
            if (sameVoice > line.start) lineEnd = sameVoice;
            else if (later > line.start) lineEnd = later;
            else lineEnd = line.start + 2.0;
        }
        line.end = lineEnd;
        NSArray *words = line.words;
        for (NSUInteger w = 0; w < words.count; w++) {
            waLyricWord *word = [words objectAtIndex:w];
            if (w + 1 < words.count) {
                waLyricWord *next = [words objectAtIndex:w + 1];
                if (next.start > word.start) word.end = next.start;
            } else if (lineEnd > word.start) {
                if (word.sustain) {
                    word.end = lineEnd;
                } else {
                    NSTimeInterval est = word.start + 0.16 * (NSTimeInterval)MAX((NSUInteger)1, waSyllableWeight(word.text));
                    NSTimeInterval gap = lineEnd - word.start;
                    if (gap > 0.45) word.end = MIN(lineEnd - 0.06, MAX(est, word.start + 0.10));
                    else word.end = lineEnd;
                }
            }
        }
        waLocateWords(line);
        for (waLyricWord *word in line.words) {
            NSTimeInterval d = word.end - word.start;
            NSUInteger n = word.text.length ? word.text.length : 1;
            if (d >= 0.65 || d / (NSTimeInterval)n >= 0.34) word.sustain = YES;
        }
    }
}

static void waFillWordTimings(NSArray *lines) {
    for (NSUInteger i = 0; i < lines.count; i++) {
        waLyricLine *line = [lines objectAtIndex:i];
        NSTimeInterval end = line.end;
        if (end <= line.start && i + 1 < lines.count) {
            waLyricLine *next = [lines objectAtIndex:i + 1];
            end = next.start;
        }
        if (end <= line.start) end = line.start + 2.0;
        line.end = end;
    }
    waAssignDuetVoices(lines);
    waStitchWordEnds(lines);
}

static NSTimeInterval waParseTimestamp(NSString *stamp) {
    if (!stamp.length) return -1.0;
    NSString *clean = [[stamp stringByReplacingOccurrencesOfString:@"[" withString:@""] stringByReplacingOccurrencesOfString:@"]" withString:@""];
    NSArray *parts = [clean componentsSeparatedByString:@":"];
    if (parts.count < 2) return -1.0;
    double minutes = [[parts objectAtIndex:0] doubleValue];
    double seconds = [[parts objectAtIndex:1] doubleValue];
    return minutes * 60.0 + seconds;
}

@implementation waLyrics

+ (BOOL)textIsInstrumentalOnly:(NSString *)text {
    if (!text.length) return NO;
    NSString *lower = [text lowercaseString];
    NSMutableString *clean = [NSMutableString string];
    BOOL spaced = NO;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if (c >= 'a' && c <= 'z') {
            [clean appendFormat:@"%C", c];
            spaced = NO;
            continue;
        }
        if (!clean.length || spaced) continue;
        [clean appendString:@" "];
        spaced = YES;
    }
    NSString *collapsed = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!collapsed.length) return NO;
    if ([collapsed isEqualToString:@"instrumental"]) return YES;
    if ([collapsed isEqualToString:@"this song is instrumental"]) return YES;
    if ([collapsed isEqualToString:@"this track is instrumental"]) return YES;
    if ([collapsed isEqualToString:@"instrumental track"]) return YES;
    if ([collapsed isEqualToString:@"instrumental song"]) return YES;
    NSArray *words = [collapsed componentsSeparatedByString:@" "];
    for (NSString *word in words) {
        if (word.length && ![word isEqualToString:@"instrumental"]) return NO;
    }
    return words.count > 0;
}

- (void)markInstrumental {
    self.instrumental = YES;
    self.wordTimed = NO;
    self.duet = NO;
    self.lines = [NSArray array];
    self.plain = @"Instrumental";
}

- (NSInteger)lineIndexAtTime:(NSTimeInterval)time {
    return [self lineIndexAtTime:time from:NSNotFound];
}

- (NSInteger)lineIndexAtTime:(NSTimeInterval)time from:(NSInteger)hint {
    NSInteger count = (NSInteger)self.lines.count;
    if (!count) return NSNotFound;
    NSInteger start = 0;
    if (hint >= 0 && hint < count) {
        waLyricLine *cur = [self.lines objectAtIndex:(NSUInteger)hint];
        if (time >= cur.start) start = hint;
    }
    NSInteger fallback = start;
    for (NSInteger i = start; i < count; i++) {
        waLyricLine *line = [self.lines objectAtIndex:(NSUInteger)i];
        NSTimeInterval end = line.end;
        if (end <= line.start && i + 1 < count) {
            end = ((waLyricLine *)[self.lines objectAtIndex:(NSUInteger)i + 1]).start;
        }
        if (end <= line.start) end = line.start + 2.0;
        if (time >= line.start && time < end) return i;
        if (time >= line.start) fallback = i;
        if (time < line.start) break;
    }
    return fallback;
}

- (NSInteger)wordIndexInLine:(NSInteger)line atTime:(NSTimeInterval)time {
    return [self wordIndexInLine:line atTime:time from:NSNotFound];
}

- (NSInteger)wordIndexForLine:(waLyricLine *)item atTime:(NSTimeInterval)time from:(NSInteger)hint {
    if (!item) return NSNotFound;
    NSInteger count = (NSInteger)item.words.count;
    if (!count) return NSNotFound;
    NSInteger start = 0;
    if (hint >= 0 && hint < count) {
        waLyricWord *cur = [item.words objectAtIndex:(NSUInteger)hint];
        if (time >= cur.start) start = hint;
    }
    NSInteger fallback = start;
    for (NSInteger i = start; i < count; i++) {
        waLyricWord *word = [item.words objectAtIndex:(NSUInteger)i];
        NSTimeInterval end = word.end;
        if (end <= word.start && i + 1 < count) {
            end = ((waLyricWord *)[item.words objectAtIndex:(NSUInteger)i + 1]).start;
        }
        if (end <= word.start) end = word.start + 0.2;
        if (time >= word.start && time < end) return i;
        if (time >= word.start) fallback = i;
        if (time < word.start) break;
    }
    return fallback;
}

- (NSInteger)wordIndexInLine:(NSInteger)line atTime:(NSTimeInterval)time from:(NSInteger)hint {
    if (line < 0 || line >= (NSInteger)self.lines.count) return NSNotFound;
    return [self wordIndexForLine:[self.lines objectAtIndex:(NSUInteger)line] atTime:time from:hint];
}

- (NSTimeInterval)nextBoundaryAfter:(NSTimeInterval)time line:(NSInteger)line word:(NSInteger)word {
    NSInteger count = (NSInteger)self.lines.count;
    if (!count) return time + 0.4;
    if (line < 0 || line >= count) {
        return MAX(time + 0.05, ((waLyricLine *)[self.lines objectAtIndex:0]).start);
    }
    if (word >= 0) {
        waLyricLine *item = [self.lines objectAtIndex:(NSUInteger)line];
        NSInteger words = (NSInteger)item.words.count;
        if (word < words) {
            if (word + 1 < words) {
                NSTimeInterval start = ((waLyricWord *)[item.words objectAtIndex:(NSUInteger)(word + 1)]).start;
                if (start > time) return start;
            }
            NSTimeInterval end = ((waLyricWord *)[item.words objectAtIndex:(NSUInteger)word]).end;
            if (end > time + 0.03) return end;
        }
    }
    if (line + 1 < count) {
        NSTimeInterval start = ((waLyricLine *)[self.lines objectAtIndex:(NSUInteger)(line + 1)]).start;
        if (start > time) return start;
    }
    return time + 0.4;
}

- (NSArray *)linesAtTime:(NSTimeInterval)time {
    NSMutableArray *active = [NSMutableArray array];
    NSInteger count = (NSInteger)self.lines.count;
    for (NSInteger i = 0; i < count; i++) {
        waLyricLine *line = [self.lines objectAtIndex:(NSUInteger)i];
        if (time >= line.start && time < line.end) [active addObject:line];
    }
    if (!active.count) {
        NSInteger index = [self lineIndexAtTime:time from:NSNotFound];
        if (index >= 0 && index < count) [active addObject:[self.lines objectAtIndex:(NSUInteger)index]];
    }
    return active;
}

- (waLyricCursor)cursorAtTime:(NSTimeInterval)time fromLine:(NSInteger)hint {
    waLyricCursor cursor;
    cursor.line = NSNotFound;
    cursor.prefixChars = 0;
    cursor.unitChars = 0;
    cursor.fraction = 0.0f;
    NSInteger count = (NSInteger)self.lines.count;
    if (!count) return cursor;
    NSInteger line = [self lineIndexAtTime:time from:hint];
    if (line < 0 || line >= count) return cursor;
    cursor = [self cursorForLine:[self.lines objectAtIndex:(NSUInteger)line] atTime:time];
    cursor.line = line;
    return cursor;
}

- (waLyricCursor)cursorForLine:(waLyricLine *)item atTime:(NSTimeInterval)time {
    waLyricCursor cursor;
    cursor.line = NSNotFound;
    cursor.prefixChars = 0;
    cursor.unitChars = 0;
    cursor.fraction = 0.0f;
    if (!item) return cursor;
    NSUInteger textLen = item.text.length;
    if (!textLen) return cursor;

    if (self.wordTimed && item.words.count) {
        NSInteger wordIndex = [self wordIndexForLine:item atTime:time from:NSNotFound];
        if (wordIndex < 0) wordIndex = 0;
        if (wordIndex >= (NSInteger)item.words.count) wordIndex = (NSInteger)item.words.count - 1;
        waLyricWord *word = [item.words objectAtIndex:(NSUInteger)wordIndex];
        NSTimeInterval span = word.end - word.start;
        if (span < 0.04) span = 0.04;
        NSTimeInterval local = time - word.start;
        if (local < 0.0) local = 0.0;
        if (local > span) local = span;
        if (word.sustain) {
            NSTimeInterval attack = MIN(0.26, MAX(0.10, span * 0.22));
            cursor.prefixChars = word.location;
            cursor.unitChars = word.text.length ? word.text.length : 1;
            cursor.fraction = local >= attack ? 1.0f : (CGFloat)(local / attack);
            return cursor;
        }
        NSArray *syllables = waSplitSyllables(word.text);
        NSUInteger countSyl = syllables.count;
        if (countSyl > 24) countSyl = 24;
        NSUInteger weights[24];
        NSUInteger total = 0;
        for (NSUInteger i = 0; i < countSyl; i++) {
            NSUInteger weight = waSyllableWeight([syllables objectAtIndex:i]);
            if (weight < 1) weight = 1;
            weights[i] = weight;
            total += weight;
        }
        if (total < 1) total = 1;
        NSTimeInterval acc = 0.0;
        NSUInteger offset = 0;
        for (NSUInteger i = 0; i < countSyl; i++) {
            NSString *part = [syllables objectAtIndex:i];
            NSTimeInterval share = span * ((double)weights[i] / (double)total);
            BOOL last = (i + 1 == countSyl);
            if (local < acc + share || last) {
                BOOL hold = last && share >= 0.50;
                cursor.prefixChars = word.location + offset;
                cursor.unitChars = part.length ? part.length : 1;
                if (hold) {
                    NSTimeInterval attack = MIN(0.22, MAX(0.10, share * 0.28));
                    NSTimeInterval inSyl = local - acc;
                    cursor.fraction = inSyl >= attack ? 1.0f : (CGFloat)(inSyl / attack);
                } else {
                    cursor.fraction = share > 0.01 ? (CGFloat)((local - acc) / share) : 1.0f;
                    if (cursor.fraction < 0.0f) cursor.fraction = 0.0f;
                    if (cursor.fraction > 1.0f) cursor.fraction = 1.0f;
                }
                return cursor;
            }
            acc += share;
            offset += part.length;
        }
        cursor.prefixChars = word.location;
        cursor.unitChars = word.text.length;
        cursor.fraction = 1.0f;
        return cursor;
    }

    cursor.prefixChars = 0;
    cursor.unitChars = textLen;
    cursor.fraction = (time >= item.start) ? 1.0f : 0.0f;
    return cursor;
}

+ (waLyrics *)lyricsFromDeezer:(NSDictionary *)result {
    if (![result isKindOfClass:[NSDictionary class]]) return nil;
    waLyrics *lyrics = [[waLyrics alloc] init];
    lyrics.source = @"deezer";
    lyrics.plain = waLyricStr(result[@"LYRICS_TEXT"]) ?: waLyricStr(result[@"lyrics"]) ?: @"";
    NSString *lyricsID = waLyricStr(result[@"LYRICS_ID"]);
    id synced = result[@"LYRICS_SYNC_JSON"] ?: result[@"sync"];
    NSMutableArray *lines = [NSMutableArray array];
    if ([synced isKindOfClass:[NSString class]]) {
        NSData *data = [synced dataUsingEncoding:NSUTF8StringEncoding];
        synced = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    }
    if ([synced isKindOfClass:[NSArray class]]) {
        for (id entry in synced) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            NSString *text = waLyricStr(entry[@"line"]) ?: waLyricStr(entry[@"text"]);
            if (!text.length) continue;
            waLyricLine *line = [[waLyricLine alloc] init];
            NSTimeInterval start = waLyricTime(entry[@"milliseconds"]);
            if (start < 0.0) start = waParseTimestamp(waLyricStr(entry[@"lrc_timestamp"]));
            if (start < 0.0) start = 0.0;
            line.start = start;
            NSTimeInterval duration = waLyricTime(entry[@"duration"]);
            line.end = duration > 0.0 ? start + duration : start;
            line.voice = waConsumeVoice(&text);
            line.text = text;
            NSMutableArray *words = [NSMutableArray array];
            id rawWords = entry[@"words"] ?: entry[@"syllables"];
            if ([rawWords isKindOfClass:[NSArray class]]) {
                for (id piece in rawWords) {
                    if (![piece isKindOfClass:[NSDictionary class]]) continue;
                    NSString *wordText = waLyricStr(piece[@"word"]) ?: waLyricStr(piece[@"text"]);
                    if (!wordText.length) continue;
                    NSTimeInterval ws = waLyricTime(piece[@"start"] ?: piece[@"milliseconds"]);
                    NSTimeInterval we = waLyricTime(piece[@"end"]);
                    if (ws < 0.0) ws = start;
                    if (we < 0.0) we = ws + 0.2;
                    NSTimeInterval wordStart = start + (ws > 10.0 ? 0.0 : ws);
                    if (ws >= start) wordStart = ws;
                    if (waAbsorbSustainToken(words, wordText, wordStart)) continue;
                    BOOL sustain = NO;
                    NSString *clean = waStripSustainMarker(wordText, &sustain);
                    if (!clean.length) continue;
                    waLyricWord *word = [[waLyricWord alloc] init];
                    word.text = clean;
                    word.sustain = sustain;
                    word.start = wordStart;
                    word.end = we > word.start ? we : word.start + 0.15;
                    [words addObject:word];
                }
            }
            if (words.count) lyrics.wordTimed = YES;
            line.words = words;
            [lines addObject:line];
        }
    }
    if (!lines.count && lyrics.plain.length && ![waLyrics textIsInstrumentalOnly:lyrics.plain]) {
        waLyrics *fromLRC = [self lyricsFromLRC:lyrics.plain];
        if (fromLRC.lines.count) {
            fromLRC.source = lyrics.source;
            return fromLRC;
        }
    }
    waFillWordTimings(lines);
    lyrics.lines = lines;
    for (waLyricLine *line in lines) if (line.voice != 0) { lyrics.duet = YES; break; }
    if (!lyrics.plain.length) {
        NSMutableArray *parts = [NSMutableArray array];
        for (waLyricLine *line in lines) if (line.text.length) [parts addObject:line.text];
        lyrics.plain = [parts componentsJoinedByString:@"\n"];
    }
    BOOL linesAreMarker = lines.count > 0;
    for (waLyricLine *line in lines) {
        if (![waLyrics textIsInstrumentalOnly:line.text]) { linesAreMarker = NO; break; }
    }
    BOOL marked = [lyricsID isEqualToString:@"0"] && !lines.count;
    id flag = result[@"instrumental"];
    if ([flag respondsToSelector:@selector(boolValue)] && [flag boolValue]) marked = YES;
    NSString *copyrights = [result[@"LYRICS_COPYRIGHTS"] description];
    if (!lines.count && copyrights.length && [copyrights rangeOfString:@"instrumental" options:NSCaseInsensitiveSearch].location != NSNotFound) marked = YES;
    if (marked || linesAreMarker || [waLyrics textIsInstrumentalOnly:lyrics.plain]) {
        [lyrics markInstrumental];
    }
    return lyrics;
}

+ (waLyrics *)lyricsFromLRC:(NSString *)lrc {
    if (!lrc.length) return nil;
    waLyrics *lyrics = [[waLyrics alloc] init];
    lyrics.source = @"lrclib";
    lyrics.plain = lrc;
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *rawLines = [lrc componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSRegularExpression *tag = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,2}):(\\d{2}(?:\\.\\d{1,3})?)\\]" options:0 error:NULL];
    NSRegularExpression *wordTag = [NSRegularExpression regularExpressionWithPattern:@"<(\\d{1,2}):(\\d{2}(?:\\.\\d{1,3})?)>" options:0 error:NULL];
    for (NSString *raw in rawLines) {
        if (!raw.length) continue;
        NSArray *tags = [tag matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];
        if (!tags.count) continue;
        NSTextCheckingResult *last = [tags lastObject];
        NSString *rest = [[raw substringFromIndex:NSMaxRange(last.range)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!rest.length) continue;
        for (NSTextCheckingResult *match in tags) {
            double minutes = [[raw substringWithRange:[match rangeAtIndex:1]] doubleValue];
            double seconds = [[raw substringWithRange:[match rangeAtIndex:2]] doubleValue];
            waLyricLine *line = [[waLyricLine alloc] init];
            line.start = minutes * 60.0 + seconds;
            line.voice = waConsumeVoice(&rest);
            line.text = rest;
            NSArray *wordMatches = [wordTag matchesInString:rest options:0 range:NSMakeRange(0, rest.length)];
            if (wordMatches.count) {
                NSMutableArray *words = [NSMutableArray array];
                NSMutableString *plain = [NSMutableString string];
                NSRange firstTag = [[wordMatches objectAtIndex:0] range];
                if (firstTag.location > 0) {
                    NSString *head = [[rest substringToIndex:firstTag.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (head.length) {
                        double firstMin = [[rest substringWithRange:[[wordMatches objectAtIndex:0] rangeAtIndex:1]] doubleValue];
                        double firstSec = [[rest substringWithRange:[[wordMatches objectAtIndex:0] rangeAtIndex:2]] doubleValue];
                        NSTimeInterval firstStamp = firstMin * 60.0 + firstSec;
                        if (!waAbsorbSustainToken(words, head, firstStamp)) {
                            BOOL sustain = NO;
                            NSString *clean = waStripSustainMarker(head, &sustain);
                            if (clean.length) {
                                waLyricWord *headWord = [[waLyricWord alloc] init];
                                headWord.text = clean;
                                headWord.sustain = sustain;
                                headWord.start = line.start;
                                headWord.end = firstStamp;
                                [words addObject:headWord];
                                [plain appendString:clean];
                            }
                        }
                    }
                }
                lyrics.wordTimed = YES;
                for (NSUInteger i = 0; i < wordMatches.count; i++) {
                    NSTextCheckingResult *wm = [wordMatches objectAtIndex:i];
                    NSUInteger startIdx = NSMaxRange(wm.range);
                    NSUInteger endIdx = (i + 1 < wordMatches.count) ? [[wordMatches objectAtIndex:i + 1] range].location : rest.length;
                    if (endIdx < startIdx) continue;
                    NSString *wordText = [[rest substringWithRange:NSMakeRange(startIdx, endIdx - startIdx)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (!wordText.length) continue;
                    double wmMin = [[rest substringWithRange:[wm rangeAtIndex:1]] doubleValue];
                    double wmSec = [[rest substringWithRange:[wm rangeAtIndex:2]] doubleValue];
                    NSTimeInterval stamp = wmMin * 60.0 + wmSec;
                    if (waAbsorbSustainToken(words, wordText, stamp)) continue;
                    BOOL sustain = NO;
                    NSString *clean = waStripSustainMarker(wordText, &sustain);
                    if (!clean.length) continue;
                    waLyricWord *word = [[waLyricWord alloc] init];
                    word.text = clean;
                    word.sustain = sustain;
                    word.start = stamp;
                    word.end = word.start + 0.2;
                    if (words.count) {
                        waLyricWord *prev = [words lastObject];
                        prev.end = word.start;
                    }
                    [words addObject:word];
                    if (plain.length) [plain appendString:@" "];
                    [plain appendString:clean];
                }
                if (plain.length) line.text = plain;
                line.words = words;
            }
            [lines addObject:line];
        }
    }
    [lines sortUsingComparator:^NSComparisonResult(waLyricLine *a, waLyricLine *b) {
        if (a.start < b.start) return NSOrderedAscending;
        if (a.start > b.start) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    waFillWordTimings(lines);
    lyrics.lines = lines;
    for (waLyricLine *line in lines) if (line.voice != 0) { lyrics.duet = YES; break; }
    return lyrics;
}

- (NSDictionary *)plist {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (self.plain.length) dict[@"plain"] = self.plain;
    dict[@"instrumental"] = @(self.instrumental);
    dict[@"wordTimed"] = @(self.wordTimed);
    if (self.source.length) dict[@"source"] = self.source;
    NSMutableArray *lines = [NSMutableArray array];
    for (waLyricLine *line in self.lines) {
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"start"] = @(line.start);
        entry[@"end"] = @(line.end);
        entry[@"voice"] = @(line.voice);
        if (line.text.length) entry[@"text"] = line.text;
        NSMutableArray *words = [NSMutableArray array];
        for (waLyricWord *word in line.words) {
            NSMutableDictionary *piece = [NSMutableDictionary dictionary];
            piece[@"start"] = @(word.start);
            piece[@"end"] = @(word.end);
            if (word.sustain) piece[@"sustain"] = @YES;
            if (word.text.length) piece[@"text"] = word.text;
            [words addObject:piece];
        }
        if (words.count) entry[@"words"] = words;
        [lines addObject:entry];
    }
    if (lines.count) dict[@"lines"] = lines;
    return dict;
}

+ (waLyrics *)lyricsFromPlist:(NSDictionary *)plist {
    if (![plist isKindOfClass:[NSDictionary class]]) return nil;
    waLyrics *lyrics = [[waLyrics alloc] init];
    lyrics.plain = waLyricStr(plist[@"plain"]) ?: @"";
    lyrics.source = waLyricStr(plist[@"source"]);
    lyrics.instrumental = [plist[@"instrumental"] boolValue];
    lyrics.wordTimed = [plist[@"wordTimed"] boolValue];
    NSMutableArray *lines = [NSMutableArray array];
    id rawLines = plist[@"lines"];
    if ([rawLines isKindOfClass:[NSArray class]]) {
        for (id entry in rawLines) {
            if (![entry isKindOfClass:[NSDictionary class]]) continue;
            waLyricLine *line = [[waLyricLine alloc] init];
            line.start = [entry[@"start"] respondsToSelector:@selector(doubleValue)] ? [entry[@"start"] doubleValue] : 0.0;
            line.end = [entry[@"end"] respondsToSelector:@selector(doubleValue)] ? [entry[@"end"] doubleValue] : line.start;
            line.voice = [entry[@"voice"] respondsToSelector:@selector(integerValue)] ? [entry[@"voice"] integerValue] : 0;
            line.text = waLyricStr(entry[@"text"]) ?: @"";
            NSMutableArray *words = [NSMutableArray array];
            id rawWords = entry[@"words"];
            if ([rawWords isKindOfClass:[NSArray class]]) {
                for (id piece in rawWords) {
                    if (![piece isKindOfClass:[NSDictionary class]]) continue;
                    waLyricWord *word = [[waLyricWord alloc] init];
                    word.text = waLyricStr(piece[@"text"]) ?: @"";
                    word.start = [piece[@"start"] respondsToSelector:@selector(doubleValue)] ? [piece[@"start"] doubleValue] : line.start;
                    word.end = [piece[@"end"] respondsToSelector:@selector(doubleValue)] ? [piece[@"end"] doubleValue] : word.start;
                    word.sustain = [piece[@"sustain"] boolValue];
                    [words addObject:word];
                }
            }
            line.words = words;
            [lines addObject:line];
        }
    }
    if (lyrics.instrumental || [waLyrics textIsInstrumentalOnly:lyrics.plain]) {
        [lyrics markInstrumental];
        return lyrics;
    }
    if (!lines.count && lyrics.plain.length) {
        waLyrics *fromLRC = [self lyricsFromLRC:lyrics.plain];
        if (fromLRC.lines.count) {
            fromLRC.source = lyrics.source;
            return fromLRC;
        }
    }
    waFillWordTimings(lines);
    lyrics.lines = lines;
    for (waLyricLine *line in lines) if (line.voice != 0) { lyrics.duet = YES; break; }
    return lyrics;
}

@end
