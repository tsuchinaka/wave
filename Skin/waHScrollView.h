#import <UIKit/UIKit.h>

// A horizontal strip living inside a vertical list.
//
// UIKit gives the inner scroll view the pan first, so a drag that starts
// vertical used to move the strip sideways and leave the list where it was.
// UIScrollView keeps its pan recognizer's delegate for itself and throws if
// anything else assigns it, so the only hook left is this override: refuse the
// pan when the drag is mostly vertical and the list behind gets it instead.
@interface waHScrollView : UIScrollView
@end
