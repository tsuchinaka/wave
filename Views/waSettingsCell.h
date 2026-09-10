#import <UIKit/UIKit.h>

// Shared grouped-table styling for Settings and its subviews (Storage…).
// Surface background, themed › chevron, section headers with themed font.
@interface waSettingsCell : UITableViewCell
@property (nonatomic, assign) NSInteger sectionPosition;
@end

@interface waSettingsHeader : UITableViewHeaderFooterView
@end
