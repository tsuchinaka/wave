#import <UIKit/UIKit.h>
#import "waRootController.h"
#import "waCrash.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        [waCrash install];
        return UIApplicationMain(argc, argv, nil, @"waAppDelegate");
    }
}
