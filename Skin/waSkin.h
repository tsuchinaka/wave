#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "waModel.h"

@class waTrack;

// iOS 5.1 native chrome. Every control is UIKit stock; the skin only supplies
// the gradient/gloss images and the Helvetica Neue typography Apple shipped
// in that era. No third-party look, no flat modern design.
@interface waSkin : NSObject
+ (void)install;

// palette (iOS 5 system blue-gray family)
+ (UIColor *)tintColor;            // #3a6ea5-ish grouped blue
+ (UIColor *)navigationTint;       // #4a6d99 bar fill
+ (UIColor *)barTint;              // gradient base for bars
+ (UIColor *)tableBackground;      // grouped pinstripe paper
+ (UIColor *)tablePlainBackground; // white
+ (UIColor *)cellBackground;
+ (UIColor *)cellSelectedBackground;
+ (UIColor *)primaryText;
+ (UIColor *)secondaryText;
+ (UIColor *)separator;
+ (UIColor *)accentText;
+ (UIColor *)destructive;
+ (UIColor *)nowPlayingBackground;

// fonts shipped on iOS 5.1
+ (UIFont *)bodyFont;
+ (UIFont *)boldBodyFont;
+ (UIFont *)smallFont;
+ (UIFont *)boldSmallFont;
+ (UIFont *)titleFont;             // nav title
+ (UIFont *)cellTitleFont;
+ (UIFont *)cellSubtitleFont;
+ (UIFont *)sectionFont;

// metrics
+ (CGFloat)margin;
+ (CGFloat)rowHeight;
+ (CGFloat)artworkSize;

// chrome
+ (UIImage *)navigationBackground;
+ (UIImage *)navigationBackgroundLandscape;
+ (UIImage *)tabBarBackground;
+ (UIImage *)tabBarSelection;
+ (UIImage *)toolbarBackground;
+ (UIImage *)buttonImageForState:(UIControlState)state;
+ (UIImage *)backButtonImageForState:(UIControlState)state;
+ (UIImage *)segmentImageForState:(UIControlState)state;
+ (UIImage *)segmentDividerImage;
+ (UIImage *)searchBarBackground;
+ (UIImage *)searchFieldBackground;
+ (UIImage *)switchTrackImage;
+ (UIImage *)sliderTrackImageForState:(UIControlState)state;
+ (UIImage *)sliderThumbImage;
+ (UIImage *)progressTrackImage;
+ (UIImage *)progressFillImage;
+ (UIImage *)groupedCellBackgroundForPosition:(NSInteger)position; // 0 top,1 middle,2 bottom,3 single
+ (UIView *)groupedTableBackground;
+ (void)styleBarButtonItem:(UIBarButtonItem *)item;
+ (void)styleNavigationBar:(UINavigationBar *)bar;
+ (void)styleTabBar:(UITabBar *)bar;
+ (void)styleToolbar:(UIToolbar *)bar;
+ (void)styleSearchBar:(UISearchBar *)bar;
+ (void)styleSegmentedControl:(UISegmentedControl *)control;
+ (void)styleSwitch:(UISwitch *)control;
+ (void)styleSlider:(UISlider *)slider;
+ (void)styleProgressView:(UIProgressView *)view;
+ (void)styleTableView:(UITableView *)tableView grouped:(BOOL)grouped;

// typography helpers for labels that UIKit gives us
+ (void)applyPlainCellFonts:(UITableViewCell *)cell;
+ (void)applyValueCellFonts:(UITableViewCell *)cell;
+ (void)applySubtitleCellFonts:(UITableViewCell *)cell;
@end
