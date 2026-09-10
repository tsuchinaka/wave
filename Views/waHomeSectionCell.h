#import <UIKit/UIKit.h>
#import "waHomeSectionView.h"

@interface waHomeSectionCell : UITableViewCell
@property (nonatomic, strong) waHomeSectionView *sectionView;
@property (nonatomic, assign) BOOL extendsToScreenEdges;
@end
