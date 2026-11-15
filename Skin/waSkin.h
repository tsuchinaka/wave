#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "waModel.h"

// iOS 5.1 native chrome. Every control is UIKit stock; the skin only resets
// appearance proxies back to the factory look Apple shipped in that era.
@interface waSkin : NSObject
+ (void)install;

+ (UIColor *)barTint;
+ (UIColor *)tableBackground;
+ (UIColor *)primaryText;
+ (UIColor *)secondaryText;
+ (UIColor *)destructive;

+ (void)styleNavigationBar:(UINavigationBar *)bar;
+ (void)styleTabBar:(UITabBar *)bar;
+ (void)styleSwitch:(UISwitch *)control;
+ (void)styleTableView:(UITableView *)tableView grouped:(BOOL)grouped;

+ (void)applyPlainCellFonts:(UITableViewCell *)cell;
+ (void)applyValueCellFonts:(UITableViewCell *)cell;
@end
