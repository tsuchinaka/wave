#import "waTableController.h"
#import "../Core/waSession.h"

// Full result list behind a "See All" on a search carousel. Pages come from
// the same /search endpoint the preview used, so the first 25 are the same
// items the user just saw.
@interface waResultsController : waTableController
- (id)initWithQuery:(NSString *)query kind:(waSearchKind)kind title:(NSString *)title;
@end
