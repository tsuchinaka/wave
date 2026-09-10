#import "waDownload.h"

static NSString *waDownloadCategoryKey(waDownloadCategory category) {
    switch (category) {
        case waDownloadCategoryAlbum: return @"album";
        case waDownloadCategoryPlaylist: return @"playlist";
        case waDownloadCategorySong: default: return @"song";
    }
}

@implementation waDownload
- (id)initWithIdentifier:(NSString *)identifier filePath:(NSString *)filePath {
    if ((self = [super init])) {
        _identifier = [identifier copy];
        _filePath = [filePath copy];
        _state = waDownloadStateQueued;
        _progress = 0.0f;
        _bytesExpected = 0;
        _categoryContexts = @{ @"song": identifier.length ? @[identifier] : @[] };
        _currentCategory = waDownloadCategorySong;
        _currentContextIdentifier = [identifier copy];
    }
    return self;
}

- (void)addCategory:(waDownloadCategory)category contextIdentifier:(NSString *)contextIdentifier {
    NSString *key = waDownloadCategoryKey(category);
    NSMutableDictionary *contexts = self.categoryContexts ? [self.categoryContexts mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableArray *identifiers = [contexts[key] isKindOfClass:[NSArray class]] ? [contexts[key] mutableCopy] : [NSMutableArray array];
    NSString *context = contextIdentifier.length ? contextIdentifier : (category == waDownloadCategorySong ? self.identifier : nil);
    if (context.length && ![identifiers containsObject:context]) [identifiers addObject:context];
    contexts[key] = [identifiers copy];
    self.categoryContexts = [contexts copy];
}

- (BOOL)belongsToCategory:(waDownloadCategory)category {
    return [self.categoryContexts[waDownloadCategoryKey(category)] count] > 0;
}

- (NSArray *)contextIdentifiersForCategory:(waDownloadCategory)category {
    id contexts = self.categoryContexts[waDownloadCategoryKey(category)];
    return [contexts isKindOfClass:[NSArray class]] ? contexts : @[];
}
@end
