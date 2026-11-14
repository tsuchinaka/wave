#import "waSkin.h"

// iOS 5.1 stock appearance. No custom drawing, no images. Every control
// keeps its UIKit factory look: blue bar, black tab bar, pinstripe paper,
// capsule buttons, bar segmented control, Helvetica typography.
@implementation waSkin

+ (void)install {
    UINavigationBar *navigation = [UINavigationBar appearance];
    navigation.barStyle = UIBarStyleDefault;
    navigation.tintColor = nil;
    UIBarButtonItem *button = [UIBarButtonItem appearance];
    button.tintColor = nil;
}

+ (UIColor *)tintColor { return nil; }
+ (UIColor *)navigationTint { return nil; }
+ (UIColor *)barTint { return nil; }
+ (UIColor *)tableBackground { return [UIColor groupTableViewBackgroundColor]; }
+ (UIColor *)tablePlainBackground { return [UIColor whiteColor]; }
+ (UIColor *)cellBackground { return [UIColor whiteColor]; }
+ (UIColor *)cellSelectedBackground { return [UIColor colorWithWhite:0.85 alpha:1.0]; }
+ (UIColor *)primaryText { return [UIColor blackColor]; }
+ (UIColor *)secondaryText { return [UIColor grayColor]; }
+ (UIColor *)separator { return [UIColor colorWithWhite:0.78 alpha:1.0]; }
+ (UIColor *)accentText { return [UIColor colorWithRed:0.0 green:0.32 blue:0.60 alpha:1.0]; }
+ (UIColor *)destructive { return [UIColor redColor]; }
+ (UIColor *)nowPlayingBackground { return [UIColor blackColor]; }

+ (UIFont *)bodyFont { return [UIFont systemFontOfSize:17.0]; }
+ (UIFont *)boldBodyFont { return [UIFont boldSystemFontOfSize:17.0]; }
+ (UIFont *)smallFont { return [UIFont systemFontOfSize:13.0]; }
+ (UIFont *)boldSmallFont { return [UIFont boldSystemFontOfSize:12.0]; }
+ (UIFont *)titleFont { return [UIFont boldSystemFontOfSize:18.0]; }
+ (UIFont *)cellTitleFont { return [UIFont boldSystemFontOfSize:16.0]; }
+ (UIFont *)cellSubtitleFont { return [UIFont systemFontOfSize:13.0]; }
+ (UIFont *)sectionFont { return [UIFont boldSystemFontOfSize:17.0]; }

+ (CGFloat)margin { return 10.0; }
+ (CGFloat)rowHeight { return 44.0; }
+ (CGFloat)artworkSize { return 44.0; }

+ (UIImage *)navigationBackground { return nil; }
+ (UIImage *)navigationBackgroundLandscape { return nil; }
+ (UIImage *)tabBarBackground { return nil; }
+ (UIImage *)tabBarSelection { return nil; }
+ (UIImage *)toolbarBackground { return nil; }
+ (UIImage *)buttonImageForState:(UIControlState)state { (void)state; return nil; }
+ (UIImage *)backButtonImageForState:(UIControlState)state { (void)state; return nil; }
+ (UIImage *)segmentImageForState:(UIControlState)state { (void)state; return nil; }
+ (UIImage *)segmentDividerImage { return nil; }
+ (UIImage *)searchBarBackground { return nil; }
+ (UIImage *)searchFieldBackground { return nil; }
+ (UIImage *)switchTrackImage { return nil; }
+ (UIImage *)sliderTrackImageForState:(UIControlState)state { (void)state; return nil; }
+ (UIImage *)sliderThumbImage { return nil; }
+ (UIImage *)progressTrackImage { return nil; }
+ (UIImage *)progressFillImage { return nil; }
+ (UIImage *)groupedCellBackgroundForPosition:(NSInteger)position { (void)position; return nil; }
+ (UIView *)groupedTableBackground { return nil; }

+ (void)styleBarButtonItem:(UIBarButtonItem *)item {
    if (!item) return;
    item.tintColor = nil;
}

+ (void)styleNavigationBar:(UINavigationBar *)bar {
    if (!bar) return;
    bar.barStyle = UIBarStyleDefault;
    bar.translucent = NO;
    bar.tintColor = nil;
    [bar setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
}

+ (void)styleTabBar:(UITabBar *)bar {
    if (!bar) return;
    bar.backgroundImage = nil;
    bar.selectionIndicatorImage = nil;
    bar.selectedImageTintColor = nil;
    bar.tintColor = nil;
}

+ (void)styleToolbar:(UIToolbar *)bar {
    if (!bar) return;
    bar.barStyle = UIBarStyleDefault;
    bar.tintColor = nil;
    [bar setBackgroundImage:nil forToolbarPosition:UIToolbarPositionAny barMetrics:UIBarMetricsDefault];
}

+ (void)styleSearchBar:(UISearchBar *)bar {
    if (!bar) return;
    bar.barStyle = UIBarStyleDefault;
    bar.translucent = NO;
    bar.backgroundImage = nil;
    bar.tintColor = nil;
    [bar setSearchFieldBackgroundImage:nil forState:UIControlStateNormal];
}

+ (void)styleSegmentedControl:(UISegmentedControl *)control {
    if (!control) return;
    control.segmentedControlStyle = UISegmentedControlStyleBar;
    control.tintColor = nil;
}

+ (void)styleSwitch:(UISwitch *)control {
    if (!control) return;
    control.onTintColor = nil;
}

+ (void)styleSlider:(UISlider *)slider {
    if (!slider) return;
    slider.minimumTrackTintColor = nil;
    slider.thumbTintColor = nil;
    [slider setThumbImage:nil forState:UIControlStateNormal];
    [slider setMinimumTrackImage:nil forState:UIControlStateNormal];
    [slider setMaximumTrackImage:nil forState:UIControlStateNormal];
}

+ (void)styleProgressView:(UIProgressView *)view {
    if (!view) return;
    view.progressImage = nil;
    view.trackImage = nil;
    view.progressTintColor = nil;
    view.trackTintColor = nil;
}

+ (void)styleTableView:(UITableView *)tableView grouped:(BOOL)grouped {
    if (!tableView) return;
    tableView.backgroundColor = grouped ? [UIColor groupTableViewBackgroundColor] : [UIColor whiteColor];
    tableView.separatorColor = [UIColor lightGrayColor];
    tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
}

+ (void)applyPlainCellFonts:(UITableViewCell *)cell {
    if (!cell) return;
    cell.textLabel.font = [UIFont boldSystemFontOfSize:17.0];
    cell.textLabel.textColor = [UIColor blackColor];
    cell.textLabel.highlightedTextColor = [UIColor whiteColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:13.0];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.detailTextLabel.highlightedTextColor = [UIColor whiteColor];
}

+ (void)applyValueCellFonts:(UITableViewCell *)cell {
    [self applyPlainCellFonts:cell];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
}

+ (void)applySubtitleCellFonts:(UITableViewCell *)cell {
    [self applyPlainCellFonts:cell];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:16.0];
}

@end
