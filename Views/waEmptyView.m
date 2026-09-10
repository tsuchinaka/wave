#import "waEmptyView.h"
#import "../Services/waTheme.h"
#import <QuartzCore/QuartzCore.h>

@interface waEmptyView ()
@property (nonatomic, assign, getter=isLoading) BOOL loading;
@end

@implementation waEmptyView

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.backgroundColor = [UIColor clearColor];
        _iconView.alpha = 0.22;
        [self addSubview:_iconView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.numberOfLines = 0;
        _titleLabel.backgroundColor = [UIColor clearColor];
        [self addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _subtitleLabel.textAlignment = NSTextAlignmentCenter;
        _subtitleLabel.numberOfLines = 0;
        _subtitleLabel.backgroundColor = [UIColor clearColor];
        [self addSubview:_subtitleLabel];

        _actionButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [waTheme applySkeuomorphicStyleToButton:_actionButton];
        _actionButton.hidden = YES;
        [self addSubview:_actionButton];

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        _spinner.hidesWhenStopped = YES;
        _spinnerBackdrop = [waTheme circularBackdropForSpinner:_spinner];
        [self addSubview:_spinnerBackdrop];
        [self bringSubviewToFront:_spinnerBackdrop];

        [self applyTheme];
    }
    return self;
}

- (void)applyTheme {
    self.backgroundColor = [UIColor clearColor];
    [waTheme applyPrimaryTextStyleToLabel:self.titleLabel];
    self.titleLabel.font = [waTheme boldFontOfSize:16.0];
    [waTheme applySecondaryTextStyleToLabel:self.subtitleLabel];
    self.subtitleLabel.font = [waTheme regularFontOfSize:14.0];
    [waTheme applySkeuomorphicStyleToButton:self.actionButton];
    self.actionButton.titleLabel.font = [waTheme boldFontOfSize:14.0];
    self.spinner.color = [UIColor whiteColor];
}

- (void)configureWithIcon:(UIImage *)icon title:(NSString *)title subtitle:(NSString *)subtitle actionTitle:(NSString *)actionTitle target:(id)target action:(SEL)action {
    self.iconView.image = icon;
    self.iconView.hidden = icon == nil;
    self.titleLabel.text = title;
    self.subtitleLabel.text = subtitle;
    self.subtitleLabel.hidden = subtitle.length == 0;
    if (actionTitle.length && target && action) {
        [self.actionButton setTitle:actionTitle forState:UIControlStateNormal];
        [self.actionButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        [self.actionButton addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
        self.actionButton.hidden = NO;
    } else {
        [self.actionButton setTitle:nil forState:UIControlStateNormal];
        [self.actionButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        self.actionButton.hidden = YES;
    }
    [self setLoading:self.loading];
    [self applyTheme];
    [self setNeedsLayout];
}

- (void)setLoading:(BOOL)loading {
    _loading = loading;
    if (loading) {
        self.spinnerBackdrop.hidden = NO;
        [self.spinner startAnimating];
        self.iconView.hidden = YES;
        self.titleLabel.hidden = YES;
        self.subtitleLabel.hidden = YES;
        self.actionButton.hidden = YES;
    } else {
        [self.spinner stopAnimating];
        // The backdrop owns the spinner, so hiding the indicator alone would
        // leave a dark disc permanently covering the empty-state content.
        self.spinnerBackdrop.hidden = YES;
        self.iconView.hidden = self.iconView.image == nil;
        self.titleLabel.hidden = self.titleLabel.text.length == 0;
        self.subtitleLabel.hidden = self.subtitleLabel.text.length == 0;
        self.actionButton.hidden = self.actionButton.currentTitle.length == 0;
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    BOOL loading = self.spinner.isAnimating;

    if (loading) {
        [self bringSubviewToFront:self.spinnerBackdrop];
        self.spinnerBackdrop.center = CGPointMake(width/2.0, height/2.0);
        return;
    }

    CGFloat y = 0;
    CGFloat padding = [waTheme standardMargin] * 2.0;
    CGFloat contentWidth = width - padding*2;

    if (!self.iconView.hidden && self.iconView.image) {
        CGFloat iconSize = MIN(72.0, MAX(48.0, MIN(width, height) * 0.15));
        self.iconView.frame = CGRectMake((width - iconSize)/2.0, y, iconSize, iconSize);
        y += iconSize + 12.0;
    }

    if (self.titleLabel.text.length) {
        CGSize size = [self.titleLabel sizeThatFits:CGSizeMake(contentWidth, 100)];
        CGFloat h = MIN(60, MAX(20, size.height));
        self.titleLabel.frame = CGRectMake(padding, y, contentWidth, h);
        y += h + 6.0;
    } else {
        self.titleLabel.frame = CGRectZero;
    }

    if (!self.subtitleLabel.hidden && self.subtitleLabel.text.length) {
        CGSize size = [self.subtitleLabel sizeThatFits:CGSizeMake(contentWidth, 60)];
        CGFloat h = MIN(40, MAX(16, size.height));
        self.subtitleLabel.frame = CGRectMake(padding, y, contentWidth, h);
        y += h + 14.0;
    } else {
        self.subtitleLabel.frame = CGRectZero;
    }

    if (!self.actionButton.hidden) {
        CGFloat btnW = MIN(180, contentWidth);
        CGFloat btnH = 36.0;
        self.actionButton.frame = CGRectMake((width - btnW)/2.0, y, btnW, btnH);
    } else {
        self.actionButton.frame = CGRectZero;
    }

    // Center vertically if content is short
    CGFloat totalH = CGRectGetMaxY(self.actionButton.hidden ? self.subtitleLabel.frame : self.actionButton.frame);
    if (!self.iconView.hidden) totalH = MAX(totalH, CGRectGetMaxY(self.iconView.frame));
    if (totalH < height) {
        CGFloat offset = (height - totalH)/2.0 - 20.0;
        for (UIView *v in @[self.iconView, self.titleLabel, self.subtitleLabel, self.actionButton]) {
            if (!v.hidden) v.frame = CGRectOffset(v.frame, 0, offset);
        }
    }
}

@end
