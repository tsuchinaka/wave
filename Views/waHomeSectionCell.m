#import "waHomeSectionCell.h"

@implementation waHomeSectionCell

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.extendsToScreenEdges = NO;
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = NO;
        self.contentView.clipsToBounds = NO;
        self.backgroundView = [[UIView alloc] initWithFrame:CGRectZero];
        self.backgroundView.backgroundColor = [UIColor clearColor];
        self.sectionView = [[waHomeSectionView alloc] initWithFrame:CGRectZero];
        self.sectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.contentView addSubview:self.sectionView];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    [self.sectionView clearCallbacks];
    [self.sectionView resetScrollPosition];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat extension = self.extendsToScreenEdges ? MAX(0.0, self.frame.origin.x) : 0.0;
    self.sectionView.frame = CGRectMake(-extension, 0.0, self.contentView.bounds.size.width + extension * 2.0, self.contentView.bounds.size.height);
}

@end
