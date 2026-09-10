#import "waTheme.h"
#import "../Models/waPreferences.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

NSString * const waThemeDidChangeNotification = @"waThemeDidChange";

@interface waTheme ()
+ (UIFont *)fontWithPostScriptName:(NSString *)name size:(CGFloat)size fallback:(UIFont *)fallback;
+ (UIFont *)secondaryFontWithWeight:(NSString *)weight size:(CGFloat)size fallback:(UIFont *)fallback;
@end

static NSCache *waThemeFontCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 64;
    });
    return cache;
}

static NSCache *waThemeImageCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 128;
    });
    return cache;
}

static void *waThemeAppliedKey = &waThemeAppliedKey;
static void *waThemeButtonKey = &waThemeButtonKey;

static UIColor *waThemeAdjustedColor(UIColor *color, CGFloat brightnessMultiplier, CGFloat alpha) {
    CGFloat hue = 0.0, saturation = 0.0, brightness = 0.0, sourceAlpha = 1.0;
    if ([color getHue:&hue saturation:&saturation brightness:&brightness alpha:&sourceAlpha]) {
        return [UIColor colorWithHue:hue saturation:saturation brightness:MIN(1.0, MAX(0.0, brightness * brightnessMultiplier)) alpha:alpha];
    }

    CGFloat white = 0.0;
    if ([color getWhite:&white alpha:&sourceAlpha]) {
        return [UIColor colorWithWhite:MIN(1.0, MAX(0.0, white * brightnessMultiplier)) alpha:alpha];
    }
    return [color colorWithAlphaComponent:alpha];
}

static BOOL waThemeViewCanCacheApplication(UIView *view) {
    return [view isKindOfClass:[UITableViewCell class]] ||
           [view isKindOfClass:[UISearchBar class]] ||
           [view isKindOfClass:[UISegmentedControl class]] ||
           [view isKindOfClass:[UISwitch class]] ||
           [view isKindOfClass:[UIActionSheet class]] ||
           ([view isKindOfClass:[UIButton class]] && objc_getAssociatedObject(view, waThemeButtonKey) != nil);
}

@implementation waTheme

+ (BOOL)isModernSystem {
    static BOOL checked = NO;
    static BOOL modern = NO;
    if (!checked) {
        checked = YES;
        // setBarTintColor: exists from iOS 7. Runtime check keeps the 6.1
        // deployment working: binary built with 7.1 SDK still runs on 6.1.
        modern = [UITabBar instancesRespondToSelector:NSSelectorFromString(@"setBarTintColor:")];
    }
    return modern;
}

// Sets an iOS 7+ property via KVC, guarded by the setter check so
// iOS 6 never sees an unknown key.
static void waSetGuardedProperty(id object, NSString *setterName, NSString *key, id value) {
    if (!object || !key) return;
    if ([object respondsToSelector:NSSelectorFromString(setterName)]) {
        @try { [object setValue:value forKey:key]; } @catch (NSException *exception) { (void)exception; }
    }
}

static void waSetGuardedBarColor(id bar, NSString *setterName, id color) {
    waSetGuardedProperty(bar, setterName, @"barTintColor", color);
}

+ (CGFloat)statusBarHeight { return [self isModernSystem] ? 20.0 : 0.0; }

+ (void)applyLayoutCompatibilityToViewController:(UIViewController *)viewController {
    if (!viewController || ![self isModernSystem]) return;
    // iOS 7+: translucent bars + extended layout would put content under
    // the nav/tab bars. We want the iOS 6 opaque layout: frames start
    // below the bars, no inset fudging.
    if ([viewController respondsToSelector:NSSelectorFromString(@"setEdgesForExtendedLayout:")]) {
        @try { [viewController setValue:@(0) forKey:@"edgesForExtendedLayout"]; } @catch (NSException *exception) { (void)exception; }
    }
    if ([viewController respondsToSelector:NSSelectorFromString(@"setExtendedLayoutIncludesOpaqueBars:")]) {
        @try { [viewController setValue:@(NO) forKey:@"extendedLayoutIncludesOpaqueBars"]; } @catch (NSException *exception) { (void)exception; }
    }
    // Keep automatic insets ON for hidden-nav VCs (home/search) so the
    // 20pt status bar is accounted for. For nav-visible VCs it just adds
    // 64pt under the opaque/nav bar, which we don't want — but those VCs
    // have edges=0 already, so set to NO only where we manage insets.
    // For simplicity, leave system default (YES) and fix hidden-nav with
    // explicit statusBar offset below. So we do NOT force NO here.
    // if ([viewController respondsToSelector:NSSelectorFromString(@"setAutomaticallyAdjustsScrollViewInsets:")]) {
    //     @try { [viewController setValue:@(NO) forKey:@"automaticallyAdjustsScrollViewInsets"]; } @catch (NSException *exception) { (void)exception; }
    // }
}

+ (void)applyStatusBarAppearance {
    if (![self isModernSystem]) return;
    // UIStatusBarStyleLightContent == 1 (no 6.1 SDK symbol; numeric literal).
    // Honored on iOS 7 because Info.plist opts out of VC-based appearance.
    [[UIApplication sharedApplication] setStatusBarStyle:(UIStatusBarStyle)1 animated:NO];
}

+ (UIFont *)fontWithPostScriptName:(NSString *)name size:(CGFloat)size fallback:(UIFont *)fallback {
    NSString *key = [NSString stringWithFormat:@"%@-%.2f", name ?: @"", size];
    UIFont *cached = [waThemeFontCache() objectForKey:key];
    if (cached) return cached;
    UIFont *font = [UIFont fontWithName:name size:size] ?: fallback;
    if (font) [waThemeFontCache() setObject:font forKey:key];
    return font;
}

+ (UIFont *)regularFontOfSize:(CGFloat)size {
    return [self fontWithPostScriptName:@"DeezerProduct-Regular" size:size fallback:[UIFont systemFontOfSize:size]];
}

+ (UIFont *)lightFontOfSize:(CGFloat)size {
    return [self fontWithPostScriptName:@"DeezerProduct-Light" size:size fallback:[UIFont systemFontOfSize:size]];
}

+ (UIFont *)mediumFontOfSize:(CGFloat)size {
    return [self fontWithPostScriptName:@"DeezerProduct-Medium" size:size fallback:[UIFont systemFontOfSize:size]];
}

+ (UIFont *)boldFontOfSize:(CGFloat)size {
    return [self fontWithPostScriptName:@"DeezerProduct-Bold" size:size fallback:[UIFont boldSystemFontOfSize:size]];
}

+ (UIFont *)extraBoldFontOfSize:(CGFloat)size {
    return [self fontWithPostScriptName:@"DeezerProduct-Extrabold" size:size fallback:[UIFont boldSystemFontOfSize:size]];
}

+ (UIFont *)secondaryFontWithWeight:(NSString *)weight size:(CGFloat)size fallback:(UIFont *)fallback {
    NSUInteger opticalSize = size <= 18.0 ? 18 : (size <= 24.0 ? 24 : 28);
    NSString *name = [NSString stringWithFormat:@"Inter%lupt-%@", (unsigned long)opticalSize, weight];
    return [self fontWithPostScriptName:name size:size fallback:fallback];
}
+ (UIFont *)secondaryRegularFontOfSize:(CGFloat)size { return [self secondaryFontWithWeight:@"Regular" size:size fallback:[UIFont systemFontOfSize:size]]; }
+ (UIFont *)secondaryMediumFontOfSize:(CGFloat)size { return [self secondaryFontWithWeight:@"Medium" size:size fallback:[UIFont systemFontOfSize:size]]; }
+ (UIFont *)secondaryBoldFontOfSize:(CGFloat)size { return [self secondaryFontWithWeight:@"Bold" size:size fallback:[UIFont boldSystemFontOfSize:size]]; }

+ (void)configureGlobalAppearance {
    NSDictionary *normal;
    NSDictionary *highlighted;
    if ([self isModernSystem]) {
        // iOS 7 native: flat text, no shadow
        normal = @{ NSFontAttributeName: [self mediumFontOfSize:14.0], NSForegroundColorAttributeName: [UIColor whiteColor] };
        highlighted = @{ NSFontAttributeName: [self boldFontOfSize:14.0], NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.65] };
    } else {
        normal = @{ UITextAttributeFont: [self mediumFontOfSize:14.0], UITextAttributeTextColor: [UIColor whiteColor], UITextAttributeTextShadowColor: [UIColor colorWithWhite:0.0 alpha:0.55], UITextAttributeTextShadowOffset: [NSValue valueWithUIOffset:UIOffsetMake(0, 1)] };
        highlighted = @{ UITextAttributeFont: [self boldFontOfSize:14.0], UITextAttributeTextColor: [UIColor colorWithWhite:1.0 alpha:0.65], UITextAttributeTextShadowColor: [UIColor colorWithWhite:0.0 alpha:0.55], UITextAttributeTextShadowOffset: [NSValue valueWithUIOffset:UIOffsetMake(0, 1)] };
    }
    UIBarButtonItem *appearance = [UIBarButtonItem appearanceWhenContainedIn:[UINavigationBar class], nil];
    [appearance setTitleTextAttributes:normal forState:UIControlStateNormal];
    [appearance setTitleTextAttributes:highlighted forState:UIControlStateHighlighted];
    [appearance setTitleTextAttributes:highlighted forState:UIControlStateSelected];
}

static UIImage *waButtonImage(UIColor *baseColor, BOOL highlighted, BOOL selected, BOOL disabled) {
    NSString *key = [NSString stringWithFormat:@"theme-button:%@:%d:%d:%d", [waTheme renderCacheKeyForColor:baseColor], highlighted, selected, disabled];
    return [waTheme cachedImageForKey:key renderer:^UIImage *{
        // Keep enough horizontal pixels for the cap insets. On iOS 6 the
        // left and right cap insets cannot consume the whole source image;
        // doing so makes UIButton render the background as a flat/broken fill.
        CGSize size = CGSizeMake(48.0, 44.0);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
        CGRect bounds = CGRectInset((CGRect){CGPointZero, size}, 1.0, 1.0);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:6.0];
        [path addClip];

        UIColor *effectiveBase = disabled ? [UIColor colorWithWhite:0.35 alpha:0.72] : baseColor;
        if (highlighted && !disabled) effectiveBase = waThemeAdjustedColor(effectiveBase, 0.70, 1.0);
        else if (selected && !disabled) effectiveBase = waThemeAdjustedColor(effectiveBase, 0.82, 1.0);
        // Fully flat iOS 7 style: solid fill, no gradient, no gloss.
        [effectiveBase setFill];
        UIRectFill((CGRect){CGPointZero, size});
        [[UIColor colorWithWhite:0.05 alpha:disabled ? 0.35 : (selected ? 0.88 : 0.78)] setStroke];
        path.lineWidth = 1.0;
        [path stroke];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [image resizableImageWithCapInsets:UIEdgeInsetsMake(8.0, 8.0, 8.0, 8.0)];
    }];
}

static UIImage *waSegmentImage(UIColor *base, BOOL selected, BOOL highlighted) {
    NSString *key = [NSString stringWithFormat:@"theme-segment:%@:%d:%d", [waTheme renderCacheKeyForColor:base], selected, highlighted];
    return [waTheme cachedImageForKey:key renderer:^UIImage *{
        CGSize size = CGSizeMake(80.0, 34.0);
        UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
        CGRect bounds = CGRectInset((CGRect){CGPointZero, size}, 1.0, 1.0);
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:6.0];
        [path addClip];
        CGFloat hue = 0.0, saturation = 0.0, brightness = 0.0, alpha = 1.0;
        [base getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha];
        CGFloat fillMultiplier = selected ? 1.0 : 0.55;
        if (highlighted) fillMultiplier = selected ? 0.70 : 0.45;
        UIColor *fill = [UIColor colorWithHue:hue saturation:saturation brightness:MAX(0.0, MIN(1.0, brightness * fillMultiplier)) alpha:1.0];
        // Fully flat iOS 7 style: solid fill, no gradient, no gloss.
        [fill setFill];
        UIRectFill((CGRect){CGPointZero, size});
        [[UIColor colorWithWhite:0.08 alpha:0.75] setStroke];
        path.lineWidth = 1.0;
        [path stroke];
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return [image resizableImageWithCapInsets:UIEdgeInsetsMake(7.0, 7.0, 7.0, 7.0)];
    }];
}

static UIImage *waSegmentDividerImage(void) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(1.0, 30.0), NO, 0.0);
    [[UIColor colorWithWhite:0.08 alpha:0.65] setFill];
    UIRectFill(CGRectMake(0.0, 0.0, 1.0, 30.0));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

+ (void)applySkeuomorphicStyleToSegmentedControl:(UISegmentedControl *)control {
    UIImage *normal = waSegmentImage([self barColor], NO, NO);
    UIImage *selected = waSegmentImage([self barColor], YES, NO);
    UIImage *highlighted = waSegmentImage([self barColor], NO, YES);
    [control setBackgroundImage:normal forState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [control setBackgroundImage:selected forState:UIControlStateSelected barMetrics:UIBarMetricsDefault];
    [control setBackgroundImage:highlighted forState:UIControlStateHighlighted barMetrics:UIBarMetricsDefault];
    [control setBackgroundImage:waSegmentImage([self barColor], YES, YES) forState:UIControlStateSelected | UIControlStateHighlighted barMetrics:UIBarMetricsDefault];
    UIImage *divider = waSegmentDividerImage();
    [control setDividerImage:divider forLeftSegmentState:UIControlStateNormal rightSegmentState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [control setDividerImage:divider forLeftSegmentState:UIControlStateSelected rightSegmentState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [control setDividerImage:divider forLeftSegmentState:UIControlStateNormal rightSegmentState:UIControlStateSelected barMetrics:UIBarMetricsDefault];
    UIFont *font = [self boldFontOfSize:15.0];
    NSDictionary *normalAttributes;
    NSDictionary *selectedAttributes;
    if ([self isModernSystem]) {
        // iOS 7 native: flat segmented titles, no shadow/emboss
        normalAttributes = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: [self primaryTextColor] };
        selectedAttributes = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: [UIColor whiteColor] };
    } else {
        normalAttributes = @{ UITextAttributeFont: font, UITextAttributeTextColor: [self primaryTextColor], UITextAttributeTextShadowColor: [UIColor colorWithWhite:1.0 alpha:0.55], UITextAttributeTextShadowOffset: [NSValue valueWithUIOffset:UIOffsetMake(0, 1)] };
        selectedAttributes = @{ UITextAttributeFont: font, UITextAttributeTextColor: [UIColor whiteColor], UITextAttributeTextShadowColor: [UIColor colorWithWhite:0.0 alpha:0.55], UITextAttributeTextShadowOffset: [NSValue valueWithUIOffset:UIOffsetMake(0, -1)] };
    }
    [control setTitleTextAttributes:normalAttributes forState:UIControlStateNormal];
    [control setTitleTextAttributes:selectedAttributes forState:UIControlStateSelected];
    control.tintColor = [self barColor];
}

+ (UIColor *)likeSelectedColor {
    return [UIColor colorWithRed:0.90 green:0.22 blue:0.28 alpha:1.0];
}

+ (UIImage *)tintedIcon:(UIImage *)image withColor:(UIColor *)color {
    if (!image) return nil;
    UIColor *effective = color ?: [self barColor];
    NSString *key = [NSString stringWithFormat:@"theme-icon:%p:%@", image.CGImage, [self renderCacheKeyForColor:effective]];
    return [self cachedImageForKey:key renderer:^UIImage *{
        UIGraphicsBeginImageContextWithOptions(image.size, NO, image.scale);
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGRect rect = CGRectMake(0.0, 0.0, image.size.width, image.size.height);
        CGContextSaveGState(context);
        CGContextTranslateCTM(context, 0.0, image.size.height);
        CGContextScaleCTM(context, 1.0, -1.0);
        CGContextClipToMask(context, rect, image.CGImage);
        CGContextSetFillColorWithColor(context, effective.CGColor);
        CGContextFillRect(context, rect);
        CGContextRestoreGState(context);
        UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        return result;
    }];
}

+ (UIView *)circularBackdropForSpinner:(UIActivityIndicatorView *)spinner {
    if (!spinner) return nil;
    // Translucent dark disc behind the spinner so it reads on any artwork
    // or content. Owns the spinner's frame: caller adds the returned view
    // (not the spinner) and keeps it frontmost with bringSubviewToFront:.
    CGFloat padding = spinner.activityIndicatorViewStyle == UIActivityIndicatorViewStyleWhiteLarge ? 16.0 : 12.0;
    CGSize size = spinner.bounds.size;
    if (size.width <= 0.0 || size.height <= 0.0) {
        CGFloat diameter = spinner.activityIndicatorViewStyle == UIActivityIndicatorViewStyleWhiteLarge ? 37.0 : 20.0;
        size = CGSizeMake(diameter, diameter);
    }
    CGFloat side = MAX(size.width, size.height) + padding * 2.0;
    UIView *backdrop = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, side, side)];
    backdrop.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    backdrop.layer.cornerRadius = side / 2.0;
    backdrop.layer.masksToBounds = YES;
    backdrop.autoresizingMask = spinner.autoresizingMask;
    backdrop.center = spinner.center;
    spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    spinner.center = CGPointMake(side / 2.0, side / 2.0);
    [backdrop addSubview:spinner];
    return backdrop;
}

+ (NSArray *)availableThemes {
    static NSArray *themes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ themes = @[@"Dark purple", @"Dark green", @"Dark red", @"Dark Aqua", @"Dark Gray + Aqua"]; });
    return themes;
}

+ (NSString *)normalizedThemeName {
    NSString *theme = [[waPreferences sharedPreferences].theme copy];
    return [[self availableThemes] containsObject:theme] ? theme : @"Dark purple";
}

+ (UIColor *)barColor {
    NSString *theme = [self normalizedThemeName];
    if ([theme isEqualToString:@"Dark green"]) return [UIColor colorWithRed:0.12 green:0.48 blue:0.29 alpha:1.0];
    if ([theme isEqualToString:@"Dark red"]) return [UIColor colorWithRed:0.62 green:0.16 blue:0.18 alpha:1.0];
    if ([theme isEqualToString:@"Dark Aqua"]) return [UIColor colorWithRed:0.04 green:0.58 blue:0.62 alpha:1.0];
    if ([theme isEqualToString:@"Dark Gray + Aqua"]) return [UIColor colorWithRed:0.04 green:0.58 blue:0.62 alpha:1.0];
    return [UIColor colorWithRed:0.48 green:0.24 blue:0.68 alpha:1.0];
}

+ (UIColor *)backgroundColor {
    NSString *theme = [self normalizedThemeName];
    if ([theme isEqualToString:@"Dark green"]) return [UIColor colorWithRed:0.035 green:0.10 blue:0.065 alpha:1.0];
    if ([theme isEqualToString:@"Dark red"]) return [UIColor colorWithRed:0.13 green:0.035 blue:0.04 alpha:1.0];
    if ([theme isEqualToString:@"Dark Aqua"]) return [UIColor colorWithRed:0.02 green:0.11 blue:0.12 alpha:1.0];
    if ([theme isEqualToString:@"Dark Gray + Aqua"]) return [UIColor colorWithRed:0.075 green:0.085 blue:0.095 alpha:1.0];
    return [UIColor colorWithRed:0.085 green:0.045 blue:0.13 alpha:1.0];
}

+ (UIColor *)primaryTextColor {
    return [UIColor colorWithWhite:0.94 alpha:1.0];
}

+ (UIColor *)secondaryTextColor {
    return [UIColor colorWithWhite:0.70 alpha:1.0];
}

+ (UIColor *)surfaceColor {
    NSString *theme = [self normalizedThemeName];
    if ([theme isEqualToString:@"Dark green"]) return [UIColor colorWithRed:0.065 green:0.15 blue:0.095 alpha:1.0];
    if ([theme isEqualToString:@"Dark red"]) return [UIColor colorWithRed:0.19 green:0.065 blue:0.075 alpha:1.0];
    if ([theme isEqualToString:@"Dark Aqua"]) return [UIColor colorWithRed:0.04 green:0.16 blue:0.17 alpha:1.0];
    if ([theme isEqualToString:@"Dark Gray + Aqua"]) return [UIColor colorWithRed:0.12 green:0.13 blue:0.145 alpha:1.0];
    return [UIColor colorWithRed:0.14 green:0.075 blue:0.20 alpha:1.0];
}

+ (UIColor *)selectedSurfaceColor { return [self barColor]; }
+ (UIColor *)separatorColor { return [UIColor colorWithWhite:1.0 alpha:0.16]; }
+ (UIColor *)destructiveColor { return [UIColor colorWithRed:0.88 green:0.20 blue:0.24 alpha:1.0]; }

+ (CGFloat)standardMargin { return 8.0; }
+ (CGFloat)compactMargin { return 6.0; }
+ (CGFloat)standardRowHeight { return 56.0; }
+ (CGFloat)compactRowHeight { return 52.0; }
+ (CGFloat)standardArtworkSize { return 44.0; }
+ (CGFloat)cornerRadius { return 5.0; }

+ (void)applyPrimaryTextStyleToLabel:(UILabel *)label {
    if (!label) return;
    label.font = [self mediumFontOfSize:17.0];
    label.textColor = [self primaryTextColor];
    label.backgroundColor = [UIColor clearColor];
}

+ (void)applySecondaryTextStyleToLabel:(UILabel *)label {
    if (!label) return;
    label.font = [self secondaryRegularFontOfSize:13.0];
    label.textColor = [self secondaryTextColor];
    label.backgroundColor = [UIColor clearColor];
}

+ (void)applySectionHeaderStyleToLabel:(UILabel *)label {
    if (!label) return;
    label.font = [self boldFontOfSize:14.0];
    label.textColor = [self secondaryTextColor];
    label.backgroundColor = [UIColor clearColor];
    if ([self isModernSystem]) {
        label.shadowColor = nil;
        label.shadowOffset = CGSizeZero;
    } else {
        label.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        label.shadowOffset = CGSizeMake(0.0, 1.0);
    }
}

+ (void)applySkeuomorphicStyleToButton:(UIButton *)button {
    if (!button) return;
    button.backgroundColor = [UIColor clearColor];
    button.layer.cornerRadius = [self cornerRadius];
    // The image already contains the rounded clipping. Keep the layer open so
    // callers can add the small external shadow used by the iOS 6 controls.
    button.layer.masksToBounds = NO;
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.72] forState:UIControlStateHighlighted];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateSelected];
    [button setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.82] forState:UIControlStateSelected | UIControlStateHighlighted];
    [button setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.48] forState:UIControlStateDisabled];
    [button setBackgroundImage:waButtonImage([self barColor], NO, NO, NO) forState:UIControlStateNormal];
    [button setBackgroundImage:waButtonImage([self barColor], YES, NO, NO) forState:UIControlStateHighlighted];
    [button setBackgroundImage:waButtonImage([self barColor], NO, YES, NO) forState:UIControlStateSelected];
    [button setBackgroundImage:waButtonImage([self barColor], YES, YES, NO) forState:UIControlStateSelected | UIControlStateHighlighted];
    [button setBackgroundImage:waButtonImage([self barColor], NO, NO, YES) forState:UIControlStateDisabled];
    objc_setAssociatedObject(button, waThemeButtonKey, [self normalizedThemeName], OBJC_ASSOCIATION_COPY_NONATOMIC);
}

+ (void)applyToView:(UIView *)view {
    if (!view) return;

    BOOL cacheApplication = waThemeViewCanCacheApplication(view);
    NSString *themeName = cacheApplication ? [self normalizedThemeName] : nil;
    if (cacheApplication && [objc_getAssociatedObject(view, waThemeAppliedKey) isEqualToString:themeName]) return;

    if ([view isKindOfClass:[UINavigationBar class]]) {
        UINavigationBar *bar = (UINavigationBar *)view;
        if ([self isModernSystem]) {
            // iOS 7+: opaque dark bar so frames match iOS 6 (edgesForExtendedLayout=0).
            // barTintColor tints the bar background; tintColor tints buttons.
            waSetGuardedProperty(bar, @"setTranslucent:", @"translucent", @(NO));
            bar.barStyle = UIBarStyleBlack;
            waSetGuardedBarColor(bar, @"setBarTintColor:", [self barColor]);
            bar.tintColor = [UIColor whiteColor];
            bar.titleTextAttributes = @{ NSFontAttributeName: [self boldFontOfSize:18.0], NSForegroundColorAttributeName: [UIColor whiteColor] };
        } else {
            bar.tintColor = [self barColor];
            bar.barStyle = UIBarStyleBlack;
            bar.titleTextAttributes = @{ UITextAttributeFont: [self boldFontOfSize:18.0], UITextAttributeTextColor: [UIColor whiteColor], UITextAttributeTextShadowColor: [UIColor colorWithWhite:0.0 alpha:0.45], UITextAttributeTextShadowOffset: [NSValue valueWithUIOffset:UIOffsetMake(0, 1)] };
        }
    } else if ([view isKindOfClass:[UITabBar class]]) {
        UITabBar *tabBar = (UITabBar *)view;
        if ([self isModernSystem]) {
            // iOS 7+: translucent dark blur, accent selected glyph.
            waSetGuardedProperty(tabBar, @"setTranslucent:", @"translucent", @(YES));
            waSetGuardedBarColor(tabBar, @"setBarTintColor:", [self backgroundColor]);
            tabBar.tintColor = [UIColor whiteColor];
            tabBar.selectedImageTintColor = [self barColor];
            // Unselected stays white at 0.6; selected pops in barColor.
            tabBar.barStyle = UIBarStyleBlack;
            tabBar.selectionIndicatorImage = nil;
        }
        // iOS 6: keep the native black glossy bar (see waAppDelegate).
    } else if ([view isKindOfClass:[UIToolbar class]]) {
        UIToolbar *toolbar = (UIToolbar *)view;
        if ([self isModernSystem]) {
            waSetGuardedProperty(toolbar, @"setTranslucent:", @"translucent", @(YES));
            waSetGuardedBarColor(toolbar, @"setBarTintColor:", [self barColor]);
            toolbar.tintColor = [UIColor whiteColor];
            toolbar.barStyle = UIBarStyleBlack;
        } else {
            toolbar.tintColor = [self barColor];
        }
    } else if ([view isKindOfClass:[UISwitch class]]) {
        ((UISwitch *)view).onTintColor = [self barColor];
    } else if ([view isKindOfClass:[UISearchBar class]]) {
        ((UISearchBar *)view).tintColor = [self barColor];
    } else if ([view isKindOfClass:[UIButton class]] && objc_getAssociatedObject(view, waThemeButtonKey)) {
        [self applySkeuomorphicStyleToButton:(UIButton *)view];
    } else if ([view isKindOfClass:[UITableView class]]) {
        view.backgroundColor = [self backgroundColor];
        ((UITableView *)view).separatorColor = [self separatorColor];
    } else if ([view isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *cell = (UITableViewCell *)view;
        cell.backgroundColor = [self surfaceColor];
        cell.contentView.backgroundColor = [self surfaceColor];
        UIView *background = cell.backgroundView;
        if (!background) {
            background = [[UIView alloc] initWithFrame:CGRectZero];
            cell.backgroundView = background;
        }
        background.backgroundColor = [self surfaceColor];
        background.layer.cornerRadius = 0.0;
        background.clipsToBounds = YES;
        UIView *selected = cell.selectedBackgroundView;
        if (!selected) {
            selected = [[UIView alloc] initWithFrame:CGRectZero];
            cell.selectedBackgroundView = selected;
        }
        selected.backgroundColor = [self selectedSurfaceColor];
        selected.layer.cornerRadius = 0.0;
        selected.clipsToBounds = YES;
        if (cell.accessoryType == UITableViewCellAccessoryDisclosureIndicator && !cell.accessoryView) {
            UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 0.0, 18.0, 32.0)];
            chevron.text = @"›";
            chevron.font = [UIFont systemFontOfSize:28.0];
            chevron.textAlignment = NSTextAlignmentCenter;
            chevron.textColor = [self barColor];
            chevron.backgroundColor = [UIColor clearColor];
            cell.accessoryView = chevron;
        }
    } else if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.contentView.backgroundColor = [self backgroundColor];
        header.textLabel.textColor = [self secondaryTextColor];
    } else if ([view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;
        if ([field.font.familyName hasPrefix:@"Helvetica"]) field.font = [self regularFontOfSize:field.font.pointSize];
        field.textColor = [self primaryTextColor];
    } else if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        if ([label.font.familyName hasPrefix:@"Helvetica"]) {
            NSString *fontName = [label.font.fontName lowercaseString];
            CGFloat size = label.font.pointSize;
            if ([fontName rangeOfString:@"black"].location != NSNotFound || [fontName rangeOfString:@"heavy"].location != NSNotFound) label.font = [self extraBoldFontOfSize:size];
            else if ([fontName rangeOfString:@"bold"].location != NSNotFound) label.font = [self boldFontOfSize:size];
            else if (size <= 12.0) label.font = [self lightFontOfSize:size];
            else label.font = [self regularFontOfSize:size];
        }
        if (label.textColor == nil || [label.textColor isEqual:[UIColor blackColor]]) label.textColor = [self primaryTextColor];
    }

    // Only update native controls in descendants. UIKit remains responsible
    // for grouped-table pinstripes, cell surfaces, separators and shadows.
    for (UIView *subview in view.subviews) [self applyToView:subview];

    if (cacheApplication) objc_setAssociatedObject(view, waThemeAppliedKey, themeName, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

+ (void)applyToWindow:(UIWindow *)window {
    window.backgroundColor = [self backgroundColor];
    [self applyToView:window];
}

+ (NSString *)renderCacheKeyForColor:(UIColor *)color {
    CGFloat hue = 0.0, saturation = 0.0, brightness = 0.0, alpha = 0.0;
    if ([color getHue:&hue saturation:&saturation brightness:&brightness alpha:&alpha]) {
        return [NSString stringWithFormat:@"h%.4f-s%.4f-b%.4f-a%.4f", hue, saturation, brightness, alpha];
    }
    CGFloat white = 0.0;
    if ([color getWhite:&white alpha:&alpha]) return [NSString stringWithFormat:@"w%.4f-a%.4f", white, alpha];
    return [color description] ?: @"unknown";
}

+ (UIImage *)cachedImageForKey:(NSString *)key renderer:(UIImage *(^)(void))renderer {
    if (!renderer) return nil;
    if (!key.length) return renderer();
    NSCache *cache = waThemeImageCache();
    UIImage *cached = [cache objectForKey:key];
    if (cached) return cached;
    @synchronized (cache) {
        cached = [cache objectForKey:key];
        if (cached) return cached;
        UIImage *image = renderer();
        if (image) [cache setObject:image forKey:key];
        return image;
    }
}

@end
