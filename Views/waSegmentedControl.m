#import "waSegmentedControl.h"
#import "../Services/waTheme.h"
#import <QuartzCore/QuartzCore.h>

static UIImage *waSegmentButtonImage(UIColor *baseColor, BOOL selected, BOOL highlighted) {
    NSString *key = [NSString stringWithFormat:@"segmented-control:%@:%d:%d", [waTheme renderCacheKeyForColor:baseColor], selected, highlighted];
    return [waTheme cachedImageForKey:key renderer:^UIImage *{
        CGSize size = CGSizeMake(100.0, 32.0);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
        CGContextRef context = UIGraphicsGetCurrentContext();
        if ([waTheme isModernSystem]) {
            UIColor *fill = selected ? baseColor : [UIColor colorWithWhite:1.0 alpha:0.08];
            if (highlighted) fill = selected ? [UIColor colorWithWhite:1.0 alpha:0.20] : [UIColor colorWithWhite:1.0 alpha:0.14];
            [fill setFill];
            CGContextFillRect(context, (CGRect){CGPointZero, size});
            UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0.0, 8.0, 0.0, 8.0)];
        }
        CGFloat hue = 0.0, saturation = 0.0, brightness = 0.0, alpha = 1.0;
        [baseColor getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
        CGFloat multiplier = selected ? 1.0 : 0.55;
        if (highlighted) multiplier = 0.70;
        UIColor *fill = [UIColor colorWithHue:hue saturation:saturation brightness:MIN(1.0, brightness * multiplier) alpha:1.0];
        UIColor *top = [UIColor colorWithHue:hue saturation:saturation brightness:MIN(1.0, brightness * MIN(1.0, multiplier * 1.16)) alpha:1.0];
        UIColor *bottom = [UIColor colorWithHue:hue saturation:saturation brightness:MAX(0.0, brightness * multiplier * 0.72) alpha:1.0];
        NSArray *colors = @[(id)top.CGColor, (id)fill.CGColor, (id)bottom.CGColor];
        CGFloat locations[] = {0.0, 0.48, 1.0};
        CGGradientRef gradient = CGGradientCreateWithColors(NULL, (__bridge CFArrayRef)colors, locations);
        CGContextDrawLinearGradient(context, gradient, CGPointMake(0.0, 0.0), CGPointMake(0.0, size.height), 0);
        CGGradientRelease(gradient);
        [[UIColor colorWithWhite:1.0 alpha:selected ? 0.18 : 0.10] setFill];
        CGContextFillRect(context, CGRectMake(0.0, 0.0, size.width, size.height * 0.42));
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0.0, 8.0, 0.0, 8.0)];
    }];
}

@interface waSegmentedControl ()
@property (nonatomic, copy) NSArray *items;
@property (nonatomic, strong) NSMutableArray *buttons;
@property (nonatomic, assign) NSInteger trackingIndex;
@end

@implementation waSegmentedControl

- (id)initWithItems:(NSArray *)items {
    if ((self = [super initWithFrame:CGRectZero])) {
        _items = [items copy];
        _buttons = [NSMutableArray arrayWithCapacity:_items.count];
        _selectedSegmentIndex = UISegmentedControlNoSegment;
        _trackingIndex = UISegmentedControlNoSegment;
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = 7.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = ([waTheme isModernSystem] ? [UIColor colorWithWhite:1.0 alpha:0.14] : [UIColor colorWithWhite:0.08 alpha:0.80]).CGColor;
        self.layer.masksToBounds = YES;
        for (NSUInteger index = 0; index < _items.count; index++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
            button.tag = index;
            button.titleLabel.font = [waTheme boldFontOfSize:14.0];
            button.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
            button.titleLabel.adjustsFontSizeToFitWidth = NO;
            [button setTitle:[_items[index] description] forState:UIControlStateNormal];
            [button addTarget:self action:@selector(segmentButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
            [self addSubview:button];
            [self.buttons addObject:button];
        }
        [self updateButtonAppearance];
    }
    return self;
}

- (void)setSelectedSegmentIndex:(NSInteger)index {
    NSInteger next = index >= 0 && index < (NSInteger)self.items.count ? index : UISegmentedControlNoSegment;
    if (_selectedSegmentIndex == next) return;
    _selectedSegmentIndex = next;
    [self updateButtonAppearance];
}

- (void)segmentButtonPressed:(UIButton *)button {
    self.selectedSegmentIndex = button.tag;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (void)updateButtonAppearance {
    UIColor *base = [waTheme barColor];
    for (UIButton *button in self.buttons) {
        BOOL selected = button.tag == self.selectedSegmentIndex;
        [button setTitleColor:selected ? [UIColor whiteColor] : [UIColor colorWithWhite:0.82 alpha:1.0] forState:UIControlStateNormal];
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
        [button setBackgroundImage:waSegmentButtonImage(base, selected, NO) forState:UIControlStateNormal];
        [button setBackgroundImage:waSegmentButtonImage(base, YES, YES) forState:UIControlStateHighlighted];
    }
    [self setNeedsLayout];
}

- (void)updateAppearance { [self updateButtonAppearance]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width / MAX(1, (CGFloat)self.buttons.count);
    for (NSUInteger index = 0; index < self.buttons.count; index++) {
        UIButton *button = self.buttons[index];
        button.frame = CGRectMake(index * width, 0.0, width + (index == self.buttons.count - 1 ? 0.5 : 0.0), self.bounds.size.height);
        if (index > 0) {
            UIView *separator = [button viewWithTag:9001];
            if (!separator) {
                separator = [[UIView alloc] initWithFrame:CGRectZero];
                separator.tag = 9001;
                separator.userInteractionEnabled = NO;
                separator.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.55];
                [button addSubview:separator];
            }
            separator.frame = CGRectMake(0.0, 3.0, 1.0, MAX(0.0, self.bounds.size.height - 6.0));
        }
    }
}

@end
