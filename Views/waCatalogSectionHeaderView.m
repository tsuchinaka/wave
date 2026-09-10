#import "waCatalogSectionHeaderView.h"
#import "../Services/waTheme.h"

@interface waCatalogSectionHeaderView ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *actionButton;
@end

@implementation waCatalogSectionHeaderView

- (id)initWithTitle:(NSString *)title actionTitle:(NSString *)actionTitle action:(void (^)(void))action {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = [UIColor clearColor];
        self.title = title;
        self.actionTitle = actionTitle;
        self.action = action;
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        [waTheme applyPrimaryTextStyleToLabel:_titleLabel];
        _titleLabel.font = [waTheme extraBoldFontOfSize:22.0];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_titleLabel];
        _actionButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _actionButton.backgroundColor = [UIColor clearColor];
        _actionButton.titleLabel.font = [waTheme mediumFontOfSize:14.0];
        [_actionButton setTitleColor:[waTheme barColor] forState:UIControlStateNormal];
        [_actionButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.70] forState:UIControlStateHighlighted];
        _actionButton.titleLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        _actionButton.titleLabel.shadowOffset = CGSizeMake(0.0, 1.0);
        [_actionButton addTarget:self action:@selector(actionPressed:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_actionButton];
        [self updateLabels];
    }
    return self;
}

- (void)setTitle:(NSString *)title { _title = [title copy]; self.titleLabel.text = _title; }
- (void)setActionTitle:(NSString *)actionTitle { _actionTitle = [actionTitle copy]; [self.actionButton setTitle:_actionTitle forState:UIControlStateNormal]; self.actionButton.hidden = !_actionTitle.length; }

- (void)updateLabels {
    self.titleLabel.text = self.title;
    [self.actionButton setTitle:self.actionTitle forState:UIControlStateNormal];
    self.actionButton.hidden = !self.actionTitle.length;
    [self.actionButton setTitleColor:[waTheme barColor] forState:UIControlStateNormal];
    [self.actionButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.70] forState:UIControlStateHighlighted];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat actionWidth = self.actionButton.hidden ? 0.0 : 84.0;
    self.titleLabel.frame = CGRectMake(16.0, 4.0, MAX(0.0, width - 32.0 - actionWidth), 32.0);
    self.actionButton.frame = CGRectMake(width - actionWidth - 12.0, 4.0, actionWidth, 32.0);
}

- (void)actionPressed:(id)sender {
    (void)sender;
    if (self.action) self.action();
}

@end
