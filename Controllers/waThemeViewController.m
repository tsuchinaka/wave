#import "waThemeViewController.h"
#import "../Models/waPreferences.h"
#import "../Services/waTheme.h"
#import <QuartzCore/QuartzCore.h>

@interface waThemeViewController ()
@property (nonatomic, strong) NSArray *themes;
@end

@interface waThemeCell : UITableViewCell
@end

static void waApplyThemeCellCorners(UIView *view, NSInteger row, NSInteger count) {
    (void)row;
    (void)count;
    view.layer.mask = nil;
    view.layer.cornerRadius = 0.0;
}

@implementation waThemeCell
- (void)layoutSubviews {
    [super layoutSubviews];
    UITableView *tableView = nil;
    UIView *ancestor = self.superview;
    while (ancestor) {
        if ([ancestor isKindOfClass:[UITableView class]]) { tableView = (UITableView *)ancestor; break; }
        ancestor = ancestor.superview;
    }
    NSIndexPath *indexPath = tableView ? [tableView indexPathForCell:self] : nil;
    NSInteger count = tableView ? [tableView numberOfRowsInSection:indexPath.section] : 1;
    NSInteger row = indexPath ? indexPath.row : 0;
    self.contentView.backgroundColor = [UIColor clearColor];
    CGFloat extension = MAX(0.0, self.frame.origin.x);
    self.backgroundView.frame = CGRectMake(-extension, 0.0, self.bounds.size.width + extension * 2.0, self.bounds.size.height);
    self.selectedBackgroundView.frame = self.backgroundView.frame;
    self.backgroundView.backgroundColor = [waTheme surfaceColor];
    self.selectedBackgroundView.backgroundColor = [waTheme selectedSurfaceColor];
    waApplyThemeCellCorners(self.backgroundView, row, count);
    waApplyThemeCellCorners(self.selectedBackgroundView, row, count);
    self.textLabel.font = [waTheme mediumFontOfSize:17.0];
}
@end

@implementation waThemeViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Themes";
    self.themes = [waTheme availableThemes];
    self.tableView.backgroundColor = [waTheme backgroundColor];
    UIView *tableBackground = [[UIView alloc] initWithFrame:CGRectZero];
    tableBackground.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tableBackground.backgroundColor = [waTheme backgroundColor];
    self.tableView.backgroundView = tableBackground;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.themes.count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"theme"];
    if (!cell) cell = [[waThemeCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"theme"];
    NSString *theme = self.themes[indexPath.row];
    cell.textLabel.text = theme;
    cell.accessoryType = [theme isEqualToString:[waPreferences sharedPreferences].theme] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    [waTheme applyToView:cell];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [waPreferences sharedPreferences].theme = self.themes[indexPath.row];
    [tableView reloadData];
}
@end
