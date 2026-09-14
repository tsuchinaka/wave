#import "../Services/waTheme.h"
#import "../Services/waImageLoader.h"
#import "../Views/waPlaceholder.h"
#import "../Models/waMediaItem.h"
#import <QuartzCore/QuartzCore.h>

@interface waSearchSectionTitleCell : UITableViewCell
@property (nonatomic, strong) UILabel *sectionTitleLabel;
- (void)configureWithTitle:(NSString *)title;
@end

@implementation waSearchSectionTitleCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.sectionTitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.sectionTitleLabel.backgroundColor = [UIColor clearColor];
        self.sectionTitleLabel.textColor = [waTheme primaryTextColor];
        self.sectionTitleLabel.font = [waTheme boldFontOfSize:20.0];
        [self.contentView addSubview:self.sectionTitleLabel];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.sectionTitleLabel.text = nil;
}

- (void)configureWithTitle:(NSString *)title {
    self.sectionTitleLabel.text = title ?: @"";
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.sectionTitleLabel.frame = CGRectMake(18.0, 2.0, MAX(0.0, self.contentView.bounds.size.width - 36.0), 28.0);
}

@end
