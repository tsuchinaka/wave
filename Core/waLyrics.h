#import <Foundation/Foundation.h>

typedef struct {
    NSInteger line;
    NSUInteger prefixChars;
    NSUInteger unitChars;
    CGFloat fraction;
} waLyricCursor;

@interface waLyricWord : NSObject
@property (nonatomic, assign) NSTimeInterval start;
@property (nonatomic, assign) NSTimeInterval end;
@property (nonatomic, assign) NSUInteger location;
@property (nonatomic, assign) BOOL sustain;
@property (nonatomic, copy) NSString *text;
@end

@interface waLyricLine : NSObject
@property (nonatomic, assign) NSTimeInterval start;
@property (nonatomic, assign) NSTimeInterval end;
@property (nonatomic, assign) NSInteger voice;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSArray *words;
@end

@interface waLyrics : NSObject
@property (nonatomic, assign) BOOL instrumental;
@property (nonatomic, assign) BOOL wordTimed;
@property (nonatomic, assign) BOOL duet;
@property (nonatomic, copy) NSString *plain;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, strong) NSArray *lines;
+ (BOOL)textIsInstrumentalOnly:(NSString *)text;
- (void)markInstrumental;
- (NSInteger)lineIndexAtTime:(NSTimeInterval)time;
- (NSInteger)lineIndexAtTime:(NSTimeInterval)time from:(NSInteger)hint;
- (NSInteger)wordIndexInLine:(NSInteger)line atTime:(NSTimeInterval)time;
- (NSInteger)wordIndexInLine:(NSInteger)line atTime:(NSTimeInterval)time from:(NSInteger)hint;
- (NSTimeInterval)nextBoundaryAfter:(NSTimeInterval)time line:(NSInteger)line word:(NSInteger)word;
- (waLyricCursor)cursorAtTime:(NSTimeInterval)time fromLine:(NSInteger)hint;
- (waLyricCursor)cursorForLine:(waLyricLine *)line atTime:(NSTimeInterval)time;
- (NSArray *)linesAtTime:(NSTimeInterval)time;
- (NSDictionary *)plist;
+ (waLyrics *)lyricsFromDeezer:(NSDictionary *)result;
+ (waLyrics *)lyricsFromLRC:(NSString *)lrc;
+ (waLyrics *)lyricsFromPlist:(NSDictionary *)plist;
@end
