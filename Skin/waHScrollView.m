#import "waHScrollView.h"

@implementation waHScrollView

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer == self.panGestureRecognizer && [recognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGPoint velocity = [(UIPanGestureRecognizer *)recognizer velocityInView:self];
        if (fabs(velocity.y) > fabs(velocity.x)) return NO;
    }
    return YES;
}

@end
