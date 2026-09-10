#import "waPlaceholder.h"

UIImage *waPlaceholderImage(void) {
    static UIImage *image;
    if (image) return image;

    UIGraphicsBeginImageContextWithOptions(CGSizeMake(40.0, 40.0), YES, 0.0);
    [[UIColor colorWithWhite:0.72 alpha:1.0] setFill];
    UIRectFill(CGRectMake(0.0, 0.0, 40.0, 40.0));
    image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}
