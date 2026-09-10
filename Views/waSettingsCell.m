#import "waSettingsCell.h"
#import "../Services/waTheme.h"
#import <QuartzCore/QuartzCore.h>

@interface waSettingsCell ()
@property (nonatomic, strong) UILabel *chevronLabel;
@property (nonatomic, strong) UIView *hoverOverlay;
@end

@implementation waSettingsCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        UIView *hover = [[UIView alloc] initWithFrame:CGRectZero];
        hover.backgroundColor = [waTheme selectedSurfaceColor];
        hover.alpha = 0.0;
        hover.userInteractionEnabled = NO;
        hover.layer.masksToBounds = YES;
        [self insertSubview:hover belowSubview:self.contentView];
        self.hoverOverlay = hover;
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    void (^update)(void) = ^{
        self.hoverOverlay.backgroundColor = [waTheme selectedSurfaceColor];
        self.hoverOverlay.alpha = highlighted ? 1.0 : 0.0;
    };
    if (animated) [UIView animateWithDuration:0.15 animations:update];
    else update();
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    void (^update)(void) = ^{
        self.hoverOverlay.backgroundColor = [waTheme selectedSurfaceColor];
        self.hoverOverlay.alpha = selected ? 1.0 : (self.highlighted ? 1.0 : 0.0);
    };
    if (animated) [UIView animateWithDuration:0.15 animations:update];
    else update();
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.contentView.backgroundColor = [UIColor clearColor];
    CGFloat extension = MAX(0.0, self.frame.origin.x);
    self.backgroundView.frame = CGRectMake(-extension, 0.0, self.bounds.size.width + extension * 2.0, self.bounds.size.height);
    self.selectedBackgroundView.frame = self.backgroundView.frame;
    if (!self.backgroundView) {
        UIView *bg = [[UIView alloc] initWithFrame:self.backgroundView.frame];
        self.backgroundView = bg;
    }
    if (!self.selectedBackgroundView) {
        UIView *sel = [[UIView alloc] initWithFrame:self.selectedBackgroundView.frame];
        self.selectedBackgroundView = sel;
    }
    self.backgroundView.backgroundColor = [waTheme surfaceColor];
    self.backgroundView.layer.mask = nil;
    self.backgroundView.layer.cornerRadius = 0.0;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    if (!self.selectedBackgroundView) {
        self.selectedBackgroundView = [[UIView alloc] initWithFrame:self.backgroundView.frame];
    }
    self.selectedBackgroundView.backgroundColor = [waTheme selectedSurfaceColor];
    self.selectedBackgroundView.layer.mask = nil;
    self.selectedBackgroundView.layer.cornerRadius = 0.0;
    self.selectedBackgroundView.alpha = 0.0; // we use hoverOverlay instead
    self.hoverOverlay.frame = self.backgroundView.frame;
    self.hoverOverlay.backgroundColor = [waTheme selectedSurfaceColor];
    self.textLabel.textColor = [waTheme primaryTextColor];
    self.detailTextLabel.textColor = [waTheme secondaryTextColor];
    if (self.chevronLabel) self.chevronLabel.textColor = [waTheme barColor];
    self.textLabel.font = [waTheme mediumFontOfSize:17.0];
    self.detailTextLabel.font = [waTheme secondaryRegularFontOfSize:13.0];
    if (self.accessoryType == UITableViewCellAccessoryDisclosureIndicator && !self.accessoryView) {
        // cellForRow nils accessoryView on every configure; build the label
        // once per cell and reattach it instead of allocating each time.
        if (!self.chevronLabel) {
            UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 0.0, 18.0, 32.0)];
            chevron.text = @"›";
            chevron.font = [UIFont systemFontOfSize:28.0];
            chevron.textAlignment = NSTextAlignmentCenter;
            chevron.textColor = [waTheme barColor];
            chevron.backgroundColor = [UIColor clearColor];
            self.chevronLabel = chevron;
        }
        self.accessoryView = self.chevronLabel;
    }
}

@end

@implementation waSettingsHeader

- (void)layoutSubviews {
    [super layoutSubviews];
    self.contentView.backgroundColor = [waTheme backgroundColor];
    self.textLabel.font = [waTheme boldFontOfSize:14.0];
    self.textLabel.textColor = [waTheme secondaryTextColor];
}

@end
