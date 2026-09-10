#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@class waQRScannerViewController;

@protocol waQRScannerViewControllerDelegate <NSObject>
- (void)qrScanner:(waQRScannerViewController *)scanner didScanPayload:(NSString *)payload;
- (void)qrScannerDidCancel:(waQRScannerViewController *)scanner;
@end

@interface waQRScannerViewController : UIViewController <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, assign) id<waQRScannerViewControllerDelegate> delegate;
@end
