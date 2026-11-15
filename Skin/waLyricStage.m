#import "waLyricStage.h"
#import <sys/sysctl.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/CADisplayLink.h>

typedef enum {
    waLyricProfile3GS = 0,
    waLyricProfileA4,
    waLyricProfileA5
} waLyricProfile;

static waLyricProfile waLyricCurrentProfile(void) {
    static waLyricProfile profile;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsigned int ncpu = 1;
        size_t len = sizeof(ncpu);
        sysctlbyname("hw.ncpu", &ncpu, &len, NULL, 0);
        char machine[64];
        memset(machine, 0, sizeof(machine));
        len = sizeof(machine);
        sysctlbyname("hw.machine", machine, &len, NULL, 0);
        if (strncmp(machine, "iPhone2", 7) == 0 || strncmp(machine, "iPod3", 5) == 0) {
            profile = waLyricProfile3GS;
        } else if (ncpu >= 2) {
            profile = waLyricProfileA5;
        } else {
            profile = waLyricProfileA4;
        }
    });
    return profile;
}

@interface waKaraokeLane : UIView {
    CTFrameRef _frame;
    CTFramesetterRef _setter;
}
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic, assign) UITextAlignment alignment;
@property (nonatomic, assign) CGFloat sungChars;
@property (nonatomic, assign) waLyricLine *line;
@property (nonatomic, assign) CGFloat lastWidth;
@property (nonatomic, assign) CGFloat lastHeight;
- (void)setText:(NSString *)text font:(UIFont *)font alignment:(UITextAlignment)alignment;
- (CGFloat)heightForWidth:(CGFloat)width;
@end

@implementation waKaraokeLane

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
        _lastWidth = -1.0;
        _lastHeight = -1.0;
        _alignment = UITextAlignmentCenter;
    }
    return self;
}

- (void)dealloc {
    if (_frame) { CFRelease(_frame); _frame = NULL; }
    if (_setter) { CFRelease(_setter); _setter = NULL; }
}

- (void)clearFrame {
    if (_frame) { CFRelease(_frame); _frame = NULL; }
    if (_setter) { CFRelease(_setter); _setter = NULL; }
}

- (void)setText:(NSString *)text font:(UIFont *)font alignment:(UITextAlignment)alignment {
    BOOL sameFont = (_font && font && fabs(_font.pointSize - font.pointSize) < 0.1);
    if ([text isEqualToString:_text] && sameFont && alignment == _alignment) return;
    _text = [text copy];
    _font = font;
    _alignment = alignment;
    _lastWidth = -1.0;
    _lastHeight = -1.0;
    [self clearFrame];
    [self setNeedsDisplay];
}

- (void)setSungChars:(CGFloat)sungChars {
    if (fabs(_sungChars - sungChars) < 0.02) return;
    _sungChars = sungChars;
    [self setNeedsDisplay];
}

- (void)rebuildIfNeeded {
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    NSString *text = _text.length ? _text : @"";
    if (width < 2.0 || height < 2.0 || !text.length || !_font) return;
    if (_frame && _setter && fabs(_lastWidth - width) < 0.5 && fabs(_lastHeight - height) < 0.5) return;
    [self clearFrame];
    _lastWidth = width;
    _lastHeight = height;
    @try {
        CTFontRef ctFont = CTFontCreateWithName((__bridge CFStringRef)(_font.fontName ?: @"Helvetica-Bold"), _font.pointSize, NULL);
        if (!ctFont) ctFont = CTFontCreateWithName(CFSTR("Helvetica-Bold"), _font.pointSize, NULL);
        CTTextAlignment align = kCTCenterTextAlignment;
        if (_alignment == UITextAlignmentLeft) align = kCTLeftTextAlignment;
        else if (_alignment == UITextAlignmentRight) align = kCTRightTextAlignment;
        CTParagraphStyleSetting setting = { kCTParagraphStyleSpecifierAlignment, sizeof(CTTextAlignment), &align };
        CTParagraphStyleRef style = CTParagraphStyleCreate(&setting, 1);
        NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
                               (__bridge id)ctFont, (id)kCTFontAttributeName,
                               (__bridge id)style, (id)kCTParagraphStyleAttributeName,
                               (id)kCFBooleanTrue, (id)kCTForegroundColorFromContextAttributeName,
                               nil];
        NSAttributedString *attr = [[NSAttributedString alloc] initWithString:text attributes:attrs];
        if (attr) _setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
        if (_setter) {
            CGMutablePathRef path = CGPathCreateMutable();
            CGPathAddRect(path, NULL, CGRectMake(0.0, 0.0, width, height));
            _frame = CTFramesetterCreateFrame(_setter, CFRangeMake(0, (CFIndex)text.length), path, NULL);
            CGPathRelease(path);
        }
        if (style) CFRelease(style);
        if (ctFont) CFRelease(ctFont);
    } @catch (NSException *exception) {
        (void)exception;
        [self clearFrame];
    }
}

- (CGFloat)heightForWidth:(CGFloat)width {
    if (width < 2.0 || !_text.length || !_font) return _font ? _font.lineHeight + 8.0 : 24.0;
    CGFloat h = _font.lineHeight * 2.4 + 8.0;
    if (h > 160.0) h = 160.0;
    return h;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    if (fabs(w - self.lastWidth) > 0.5 || fabs(h - self.lastHeight) > 0.5) {
        [self rebuildIfNeeded];
        [self setNeedsDisplay];
    }
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    [self rebuildIfNeeded];
    if (!_frame) return;
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, 0.0, CGRectGetHeight(self.bounds));
    CGContextScaleCTM(ctx, 1.0, -1.0);
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);

    NSArray *lines = (__bridge NSArray *)CTFrameGetLines(_frame);
    NSUInteger count = lines.count;
    if (!count) {
        CGContextRestoreGState(ctx);
        return;
    }
    if (count > 8) count = 8;
    CGPoint origins[8];
    CTFrameGetLineOrigins(_frame, CFRangeMake(0, (CFIndex)count), origins);
    CGFloat sung = self.sungChars;
    UIColor *dim = [UIColor colorWithWhite:1.0 alpha:0.34];
    UIColor *lit = [UIColor whiteColor];

    for (NSUInteger i = 0; i < count; i++) {
        CTLineRef line = (__bridge CTLineRef)[lines objectAtIndex:i];
        CFRange range = CTLineGetStringRange(line);
        CGFloat ascent = 0, descent = 0, leading = 0;
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        CGPoint origin = origins[i];
        CGContextSetFillColorWithColor(ctx, dim.CGColor);
        CGContextSetTextPosition(ctx, origin.x, origin.y);
        CTLineDraw(line, ctx);

        CGFloat start = (CGFloat)range.location;
        CGFloat end = (CGFloat)(range.location + range.length);
        if (sung <= start + 0.01) continue;
        CGFloat local = sung;
        if (local > end) local = end;
        CFIndex i0 = (CFIndex)local;
        CGFloat frac = local - (CGFloat)i0;
        CGFloat x0 = CTLineGetOffsetForStringIndex(line, range.location, NULL);
        CGFloat x1 = CTLineGetOffsetForStringIndex(line, i0, NULL);
        if (frac > 0.01 && i0 + 1 <= range.location + range.length) {
            CGFloat x2 = CTLineGetOffsetForStringIndex(line, i0 + 1, NULL);
            x1 += frac * (x2 - x1);
        }
        CGFloat width = x1 - x0;
        if (width < 0.5) continue;
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, CGRectMake(origin.x + x0, origin.y - descent, width, ascent + descent + 1.0));
        CGContextSetFillColorWithColor(ctx, lit.CGColor);
        CGContextSetTextPosition(ctx, origin.x, origin.y);
        CTLineDraw(line, ctx);
        CGContextRestoreGState(ctx);
    }
    CGContextRestoreGState(ctx);
}

@end

@interface waLyricStage ()
@property (nonatomic, strong) UILabel *prevLabel;
@property (nonatomic, strong) UIView *currentHost;
@property (nonatomic, strong) waKaraokeLane *leadLane;
@property (nonatomic, strong) waKaraokeLane *altLane;
@property (nonatomic, strong) UILabel *nextLabel;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) NSInteger lineIndex;
@property (nonatomic, assign) NSInteger hintIndex;
@property (nonatomic, assign) BOOL duetLayout;
@property (nonatomic, assign) waLyricProfile profile;
@property (nonatomic, assign) NSTimeInterval lastTime;
@property (nonatomic, assign) BOOL hasTime;
@end

@implementation waLyricStage

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = YES;
        _lineIndex = NSNotFound;
        _hintIndex = NSNotFound;
        _profile = waLyricCurrentProfile();

        _prevLabel = [self lineLabel:15.0 color:[UIColor colorWithWhite:1.0 alpha:0.38]];
        _nextLabel = [self lineLabel:15.0 color:[UIColor colorWithWhite:1.0 alpha:0.38]];
        [self addSubview:_prevLabel];
        [self addSubview:_nextLabel];

        _currentHost = [[UIView alloc] initWithFrame:CGRectZero];
        _currentHost.backgroundColor = [UIColor clearColor];
        _currentHost.clipsToBounds = YES;
        [self addSubview:_currentHost];

        _leadLane = [[waKaraokeLane alloc] initWithFrame:CGRectZero];
        _altLane = [[waKaraokeLane alloc] initWithFrame:CGRectZero];
        _altLane.hidden = YES;
        [_currentHost addSubview:_leadLane];
        [_currentHost addSubview:_altLane];

        _emptyLabel = [self lineLabel:16.0 color:[UIColor colorWithWhite:1.0 alpha:0.78]];
        _emptyLabel.numberOfLines = 0;
        _emptyLabel.text = @"";
        _emptyLabel.hidden = YES;
        [self addSubview:_emptyLabel];
    }
    return self;
}

- (void)dealloc {
    [self.link invalidate];
    self.link = nil;
}

- (UILabel *)lineLabel:(CGFloat)size color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.backgroundColor = [UIColor clearColor];
    label.textAlignment = UITextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:size];
    label.textColor = color;
    label.numberOfLines = 3;
    label.lineBreakMode = UILineBreakModeWordWrap;
    return label;
}

- (CGFloat)maxCurrentSize {
    if (self.profile == waLyricProfileA5) return 22.0;
    if (self.profile == waLyricProfileA4) return 18.0;
    return 16.0;
}

- (void)stopPulse {
    self.link.paused = YES;
}

- (void)armClock {
    if (self.hidden || self.loading || !self.lyrics.lines.count) {
        [self stopPulse];
        return;
    }
    if (!self.link) {
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayFired:)];
        self.link.frameInterval = self.profile == waLyricProfileA5 ? 1 : 2;
        [self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
    self.link.paused = NO;
    [self renderAtTime:[self heardTime:nil]];
}

- (NSTimeInterval)heardTime:(CADisplayLink *)link {
    NSTimeInterval time = self.timeSource ? self.timeSource() : 0.0;
    // One frame of lead: the pixels land as the syllable is heard, not after.
    CFTimeInterval frame = link ? link.duration : 0.0;
    if (frame < 0.008 || frame > 0.05) frame = self.profile == waLyricProfileA5 ? (1.0 / 60.0) : (1.0 / 30.0);
    return time + frame;
}

- (void)displayFired:(CADisplayLink *)link {
    if (self.hidden || self.loading || !self.lyrics.lines.count) {
        link.paused = YES;
        return;
    }
    @try { [self renderAtTime:[self heardTime:link]]; }
    @catch (NSException *exception) { (void)exception; }
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    if (hidden) [self stopPulse];
    else [self armClock];
}

- (void)setLoading:(BOOL)loading {
    _loading = loading;
    if (loading) {
        [self stopPulse];
        self.emptyLabel.hidden = YES;
        self.emptyLabel.text = @"";
        self.prevLabel.text = @"";
        self.nextLabel.text = @"";
        self.currentHost.hidden = YES;
        self.prevLabel.hidden = YES;
        self.nextLabel.hidden = YES;
    } else {
        BOOL has = self.lyrics.lines.count > 0;
        self.currentHost.hidden = !has;
        self.prevLabel.hidden = !has;
        self.nextLabel.hidden = !has;
        [self armClock];
    }
    [self setNeedsLayout];
}

- (void)setLyrics:(waLyrics *)lyrics {
    _lyrics = lyrics;
    _lineIndex = NSNotFound;
    _hintIndex = NSNotFound;
    [self stopPulse];
    BOOL hasLines = lyrics.lines.count > 0;
    self.currentHost.hidden = !hasLines || self.loading;
    self.prevLabel.hidden = !hasLines || self.loading;
    self.nextLabel.hidden = !hasLines || self.loading;
    if (self.loading) {
        self.emptyLabel.hidden = YES;
    } else if (lyrics.instrumental) {
        self.emptyLabel.hidden = NO;
        self.emptyLabel.numberOfLines = 1;
        self.emptyLabel.font = [UIFont boldSystemFontOfSize:22.0];
        self.emptyLabel.text = @"Instrumental";
    } else if (!hasLines) {
        self.emptyLabel.hidden = NO;
        self.emptyLabel.text = lyrics.plain.length ? lyrics.plain : @"No lyrics";
    } else {
        self.emptyLabel.hidden = YES;
        self.emptyLabel.text = @"";
    }
    if (!self.loading) [self armClock];
    [self setNeedsLayout];
}

- (UIFont *)fontFittingText:(NSString *)text width:(CGFloat)width {
    CGFloat size = [self maxCurrentSize];
    if (self.duetLayout && size > 16.0) size = 16.0;
    UIFont *font = [UIFont boldSystemFontOfSize:size];
    if (!text.length) return font;
    while (size > 13.0) {
        CGSize box = [text sizeWithFont:font constrainedToSize:CGSizeMake(width, 160.0) lineBreakMode:UILineBreakModeWordWrap];
        if (box.height <= font.lineHeight * 3.4) break;
        size -= 1.0;
        font = [UIFont boldSystemFontOfSize:size];
    }
    return font;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = CGRectGetWidth(self.bounds);
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat lineH = MAX(22.0, h / 7.0);
    BOOL duet = self.duetLayout;
    CGFloat prevH = duet ? lineH * 1.2 : lineH * 1.5;
    CGFloat nextH = prevH;
    CGFloat y = 6.0;
    self.prevLabel.frame = CGRectMake(12.0, y, w - 24.0, prevH);
    y += prevH;
    CGFloat currentH = h - y - nextH - 6.0;
    if (currentH < 48.0) currentH = 48.0;
    self.currentHost.frame = CGRectMake(8.0, y, w - 16.0, currentH);
    y += currentH;
    self.nextLabel.frame = CGRectMake(12.0, y, w - 24.0, nextH);
    if (self.lyrics.instrumental) {
        self.emptyLabel.frame = CGRectMake(16.0, (h - 28.0) / 2.0, w - 32.0, 28.0);
    } else {
        self.emptyLabel.frame = CGRectMake(16.0, 12.0, w - 32.0, h - 24.0);
    }
    [self layoutLanes];
}

- (void)layoutLanes {
    CGFloat w = CGRectGetWidth(self.currentHost.bounds);
    CGFloat h = CGRectGetHeight(self.currentHost.bounds);
    if (w < 2.0) return;
    if (self.duetLayout && !self.altLane.hidden) {
        CGFloat gap = 8.0;
        CGFloat col = (w - gap) / 2.0;
        CGFloat lh = [self.leadLane heightForWidth:col];
        CGFloat ah = [self.altLane heightForWidth:col];
        if (lh > h) lh = h;
        if (ah > h) ah = h;
        self.leadLane.frame = CGRectMake(0.0, (h - lh) / 2.0, col, lh);
        self.altLane.frame = CGRectMake(col + gap, (h - ah) / 2.0, col, ah);
    } else {
        CGFloat lh = [self.leadLane heightForWidth:w];
        if (lh > h) lh = h;
        self.leadLane.frame = CGRectMake(0.0, (h - lh) / 2.0, w, lh);
        self.altLane.frame = CGRectZero;
    }
}

- (void)applyLine:(waLyricLine *)line toLane:(waKaraokeLane *)lane alignment:(UITextAlignment)alignment time:(NSTimeInterval)time {
    if (!lane) return;
    if (!line) {
        lane.line = nil;
        lane.hidden = YES;
        [lane setText:@"" font:[UIFont boldSystemFontOfSize:16.0] alignment:alignment];
        return;
    }
    lane.hidden = NO;
    if (lane.line != line || lane.alignment != alignment) {
        lane.line = line;
        CGFloat colW = self.duetLayout ? (CGRectGetWidth(self.currentHost.bounds) - 8.0) / 2.0 : CGRectGetWidth(self.currentHost.bounds);
        if (colW < 40.0) colW = 140.0;
        UIFont *font = [self fontFittingText:line.text.length ? line.text : @" " width:colW];
        [lane setText:line.text.length ? line.text : @"" font:font alignment:alignment];
    }
    waLyricCursor cursor = [self.lyrics cursorForLine:line atTime:time];
    CGFloat sung = (CGFloat)cursor.prefixChars + cursor.fraction * (CGFloat)cursor.unitChars;
    lane.sungChars = sung;
}

- (void)setTime:(NSTimeInterval)time {
    [self renderAtTime:time];
}

- (void)renderAtTime:(NSTimeInterval)time {
    if (!self.lyrics.lines.count) {
        self.prevLabel.text = @"";
        self.nextLabel.text = @"";
        [self stopPulse];
        self.hasTime = NO;
        return;
    }
    waLyricLine *lead = nil;
    waLyricLine *alt = nil;
    NSInteger leadIndex = [self.lyrics activeLinesAtTime:time from:self.hintIndex lead:&lead alt:&alt];
    if (leadIndex != NSNotFound) self.hintIndex = leadIndex;
    if (lead == alt) alt = nil;
    BOOL duet = (self.lyrics.duet || alt != nil);
    self.duetLayout = duet;

    NSInteger count = (NSInteger)self.lyrics.lines.count;
    BOOL lineChanged = (leadIndex != self.lineIndex);
    self.lineIndex = leadIndex;
    if (lineChanged) {
        NSString *prev = @"";
        NSString *next = @"";
        if (leadIndex != NSNotFound) {
            for (NSInteger i = leadIndex - 1; i >= 0; i--) {
                waLyricLine *line = [self.lyrics.lines objectAtIndex:(NSUInteger)i];
                if (line.voice == (lead ? lead.voice : 0) && line.text.length) { prev = line.text; break; }
            }
            for (NSInteger i = leadIndex + 1; i < count; i++) {
                waLyricLine *line = [self.lyrics.lines objectAtIndex:(NSUInteger)i];
                if (line.voice == (lead ? lead.voice : 0) && line.text.length) { next = line.text; break; }
            }
        }
        self.prevLabel.text = prev;
        self.nextLabel.text = next;
        self.prevLabel.textAlignment = duet ? UITextAlignmentLeft : UITextAlignmentCenter;
        self.nextLabel.textAlignment = duet ? UITextAlignmentLeft : UITextAlignmentCenter;
        NSTimeInterval jumped = self.hasTime ? fabs(time - self.lastTime) : 0.0;
        NSTimeInterval duration = self.profile == waLyricProfileA5 ? 0.22 : 0.16;
        if (jumped <= 3.0) {
            self.currentHost.alpha = 0.0;
            self.currentHost.transform = self.profile == waLyricProfileA5 ? CGAffineTransformMakeTranslation(0.0, 8.0) : CGAffineTransformIdentity;
            [UIView beginAnimations:@"lyric.line" context:NULL];
            [UIView setAnimationDuration:duration];
            [UIView setAnimationCurve:UIViewAnimationCurveEaseOut];
            self.currentHost.alpha = 1.0;
            self.currentHost.transform = CGAffineTransformIdentity;
            [UIView commitAnimations];
        }
        self.lastTime = time;
        self.hasTime = YES;
    }

    UITextAlignment leadAlign = duet ? UITextAlignmentLeft : UITextAlignmentCenter;
    [self applyLine:lead toLane:self.leadLane alignment:leadAlign time:time];
    if (duet && alt) {
        [self applyLine:alt toLane:self.altLane alignment:UITextAlignmentRight time:time];
    } else {
        self.altLane.hidden = YES;
        self.altLane.line = nil;
    }
    if (lineChanged) [self setNeedsLayout];
}

@end
