#import "waQRScannerViewController.h"
#import "../Services/waTheme.h"
#import <QuartzCore/QuartzCore.h>
#import "../Vendor/quirc/quirc.h"
#import <CoreVideo/CoreVideo.h>

@interface waQRScannerViewController () <UIAlertViewDelegate>
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, assign) BOOL didFinish;
@property (nonatomic, assign) struct quirc *recognizer;
@property (nonatomic, assign) BOOL processingFrame;
@property (nonatomic, assign) int recognizerWidth;
@property (nonatomic, assign) int recognizerHeight;
@end

@implementation waQRScannerViewController

- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    view.backgroundColor = [UIColor blackColor];
    self.view = view;

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeCustom];
    cancel.frame = CGRectMake(12.0, 12.0, 124.0, 42.0);
    cancel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    [cancel setTitle:@"Cancel Scan" forState:UIControlStateNormal];
    [waTheme applySkeuomorphicStyleToButton:cancel];
    cancel.titleLabel.font = [waTheme boldFontOfSize:17.0];
    [cancel addTarget:self action:@selector(cancelTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:cancel];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(12.0, self.view.bounds.size.height - 62.0, self.view.bounds.size.width - 24.0, 42.0)];
    hint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    hint.text = @"Point the camera at the Discord Bridge QR code";
    hint.textAlignment = NSTextAlignmentCenter;
    hint.numberOfLines = 2;
    hint.textColor = [UIColor whiteColor];
    hint.shadowColor = [UIColor blackColor];
    hint.shadowOffset = CGSizeMake(0.0, 1.0);
    hint.backgroundColor = [UIColor clearColor];
    [self.view addSubview:hint];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startCapture];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.captureSession stopRunning];
}

- (void)startCapture {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        [self showUnavailableMessage:@"This device has no camera. Use Enter PIN instead."];
        return;
    }

    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    if (!device || !input || error) {
        [self showUnavailableMessage:@"The camera could not be opened. Use Enter PIN instead."];
        return;
    }

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    if (![session canAddInput:input] || ![session canAddOutput:output]) {
        [self showUnavailableMessage:@"The camera could not be configured. Use Enter PIN instead."];
        return;
    }
    [session addInput:input];
    [session addOutput:output];
    output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
    output.alwaysDiscardsLateVideoFrames = YES;
    dispatch_queue_t queue = dispatch_queue_create("com.bytebox.wave.qr-scanner", DISPATCH_QUEUE_SERIAL);
    [output setSampleBufferDelegate:self queue:queue];
    self.captureSession = session;
    self.videoOutput = output;
    self.recognizer = quirc_new();
    if (!self.recognizer) {
        [self showUnavailableMessage:@"QR scanner memory could not be allocated. Use Enter PIN instead."];
        return;
    }
    self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:session];
    self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.previewLayer.frame = self.view.bounds;
    [self.view.layer insertSublayer:self.previewLayer atIndex:0];
    [session startRunning];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.previewLayer.frame = self.view.bounds;
}

- (void)showUnavailableMessage:(NSString *)message {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Scan QR" message:message delegate:self cancelButtonTitle:@"Enter PIN" otherButtonTitles:nil];
    alert.tag = 801;
    [alert show];
}

- (void)cancelTapped:(id)sender {
    (void)sender;
    [self finishWithCancel];
}

- (void)finishWithCancel {
    if (self.didFinish) return;
    self.didFinish = YES;
    [self.captureSession stopRunning];
    [self.delegate qrScannerDidCancel:self];
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    (void)captureOutput;
    (void)connection;
    if (self.didFinish) return;
    if (self.processingFrame) return;
    self.processingFrame = YES;

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
    size_t width = CVPixelBufferGetWidthOfPlane(imageBuffer, 0);
    size_t height = CVPixelBufferGetHeightOfPlane(imageBuffer, 0);
    size_t stride = CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, 0);
    if (width == 0 || height == 0 || width > INT_MAX || height > INT_MAX) {
        CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
        self.processingFrame = NO;
        return;
    }
    if (self.recognizerWidth != (int)width || self.recognizerHeight != (int)height) {
        if (quirc_resize(self.recognizer, (int)width, (int)height) < 0) {
            CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);
            self.processingFrame = NO;
            return;
        }
        self.recognizerWidth = (int)width;
        self.recognizerHeight = (int)height;
    }
    int qrWidth = 0;
    int qrHeight = 0;
    uint8_t *target = quirc_begin(self.recognizer, &qrWidth, &qrHeight);
    const uint8_t *source = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, 0);
    for (size_t row = 0; row < height; row++) memcpy(target + row * width, source + row * stride, width);
    quirc_end(self.recognizer);
    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    int count = quirc_count(self.recognizer);
    for (int index = 0; index < count; index++) {
        struct quirc_code code;
        struct quirc_data data;
        quirc_extract(self.recognizer, index, &code);
        if (quirc_decode(&code, &data) != QUIRC_SUCCESS) continue;
        NSString *payload = [[NSString alloc] initWithBytes:data.payload length:(NSUInteger)data.payload_len encoding:NSUTF8StringEncoding];
        if (!payload.length) continue;
        self.didFinish = YES;
        [self.captureSession stopRunning];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate qrScanner:self didScanPayload:payload];
        });
        break;
    }
    self.processingFrame = NO;
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 801 && buttonIndex == 0) [self finishWithCancel];
}

- (void)dealloc {
    [self.captureSession stopRunning];
    [self.videoOutput setSampleBufferDelegate:nil queue:NULL];
    if (self.recognizer) quirc_destroy(self.recognizer);
}

@end
