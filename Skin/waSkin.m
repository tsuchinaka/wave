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

+ (UIColor *)barTint { return nil; }
+ (UIColor *)tableBackground { return [UIColor groupTableViewBackgroundColor]; }
+ (UIColor *)primaryText { return [UIColor blackColor]; }
+ (UIColor *)secondaryText { return [UIColor grayColor]; }
+ (UIColor *)destructive { return [UIColor redColor]; }

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

+ (void)styleSwitch:(UISwitch *)control {
    if (!control) return;
    control.onTintColor = nil;
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

@end
