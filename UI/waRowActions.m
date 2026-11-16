#import "waRowActions.h"
#import "waActions.h"
#import "waSession.h"
#import "waPlayer.h"
#import "waDownloader.h"
#import "waRootController.h"
#import "waPlaylistEditController.h"

static NSString *waLinkForItem(waItem *item) {
    NSString *kind = item.kind.lowercaseString;
    NSString *part = @"track";
    if ([kind isEqualToString:[@"album" lowercaseString]]) part = @"album";
    else if ([kind isEqualToString:[@"artist" lowercaseString]]) part = @"artist";
    else if ([kind isEqualToString:[@"playlist" lowercaseString]]) part = @"playlist";
    if (!item.identifier.length) return nil;
    return [NSString stringWithFormat:@"https://www.deezer.com/%@/%@", part, item.identifier];
}

@implementation waRowActions

+ (void)presentPlaylistPickerForTrack:(waTrack *)track from:(UIViewController *)presenter {
    if (!track || !presenter) return;
    waPlaylistEditController *picker = [[waPlaylistEditController alloc] initWithTrack:track];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    [presenter presentModalViewController:nav animated:YES];
}

+ (void)playItem:(waItem *)item tracks:(NSArray *)tracks presenter:(UIViewController *)presenter {
    if (!item) return;
    BOOL firstIsTrack = tracks.count && [[tracks objectAtIndex:0] isKindOfClass:[waTrack class]];
    if ([item isKindOfClass:[waTrack class]] || firstIsTrack) {
        NSMutableArray *list = [NSMutableArray arrayWithArray:tracks ?: [NSArray array]];
        NSUInteger index = NSNotFound;
        if ([item isKindOfClass:[waTrack class]]) {
            if (![list containsObject:item]) [list insertObject:item atIndex:0];
            index = [list indexOfObject:item];
        }
        if (!list.count) return;
        if (index == NSNotFound) index = 0;
        [[waPlayer shared] playTracks:list startAt:index context:presenter.title];
        [[waRootController shared] showPlayer];
        return;
    }
    NSString *identifier = item.identifier;
    if (!identifier.length) return;
    if ([item isKindOfClass:[waAlbum class]]) {
        [[waSession shared] albumTracks:identifier completion:^(NSArray *tracks, NSError *error) {
            (void)error;
            if (!tracks.count) return;
            [[waPlayer shared] playTracks:tracks startAt:0 context:item.title];
            [[waRootController shared] showPlayer];
        }];
    } else if ([item isKindOfClass:[waPlaylist class]]) {
        [[waSession shared] playlistTracks:identifier completion:^(NSArray *tracks, NSError *error) {
            (void)error;
            if (!tracks.count) return;
            [[waPlayer shared] playTracks:tracks startAt:0 context:item.title];
            [[waRootController shared] showPlayer];
        }];
    } else if ([item isKindOfClass:[waArtist class]]) {
        [[waSession shared] artistTop:identifier completion:^(NSArray *tracks, NSError *error) {
            (void)error;
            if (!tracks.count) return;
            [[waPlayer shared] playTracks:tracks startAt:0 context:item.title];
            [[waRootController shared] showPlayer];
        }];
    }
}

+ (NSDictionary *)menuForItem:(waItem *)item tracks:(NSArray *)tracks presenter:(UIViewController *)presenter {
    if (![item isKindOfClass:[waItem class]] || !item.identifier.length) return nil;
    __weak UIViewController *weakPresenter = presenter;
    NSMutableArray *actions = [NSMutableArray array];
    BOOL isTrack = [item isKindOfClass:[waTrack class]];

    [actions addObject:[waAction actionWithTitle:@"Play" destructive:NO handler:^{
        UIViewController *host = weakPresenter;
        if (host) [self playItem:item tracks:tracks presenter:host];
    }]];

    if (isTrack) {
        [actions addObject:[waAction actionWithTitle:@"Play Next" destructive:NO handler:^{
            [[waPlayer shared] appendTracks:[NSArray arrayWithObject:item] next:YES];
        }]];
    }

    BOOL canLike = [item isKindOfClass:[waTrack class]] || [item isKindOfClass:[waAlbum class]] || [item isKindOfClass:[waArtist class]];
    if (canLike) {
        BOOL liked = NO;
        if ([item isKindOfClass:[waTrack class]]) liked = ((waTrack *)item).liked;
        else if ([item isKindOfClass:[waAlbum class]]) liked = ((waAlbum *)item).liked;
        else liked = ((waArtist *)item).liked;
        NSString *title = liked ? @"Unlike" : @"Like";
        [actions addObject:[waAction actionWithTitle:title destructive:NO handler:^{
            void (^done)(BOOL, NSError *) = ^(BOOL ok, NSError *error) {
                (void)error;
                if (!ok) return;
                UIViewController *host = weakPresenter;
                if (host && [host respondsToSelector:@selector(reload)]) [host performSelector:@selector(reload)];
            };
            if ([item isKindOfClass:[waTrack class]]) [[waSession shared] setLiked:!liked track:(waTrack *)item completion:done];
            else if ([item isKindOfClass:[waAlbum class]]) [[waSession shared] setLiked:!liked album:(waAlbum *)item completion:done];
            else [[waSession shared] setLiked:!liked artist:(waArtist *)item completion:done];
        }]];
    }

    if (isTrack) {
        [actions addObject:[waAction actionWithTitle:@"Add to Playlist" destructive:NO handler:^{
            UIViewController *host = weakPresenter;
            if (host) [self presentPlaylistPickerForTrack:(waTrack *)item from:host];
        }]];
    }

    BOOL downloadable = isTrack || [item isKindOfClass:[waAlbum class]] || [item isKindOfClass:[waPlaylist class]];
    if (downloadable && ![[waDownloader shared] isDownloadedTrackID:item.identifier]) {
        [actions addObject:[waAction actionWithTitle:@"Download" destructive:NO handler:^{
            waQuality quality = [[waSession shared] downloadQuality];
            waDownloader *downloader = [waDownloader shared];
            if (isTrack) {
                [downloader enqueueTrack:(waTrack *)item quality:quality];
                return;
            }
            void (^enqueue)(NSArray *) = ^(NSArray *tracks) {
                if (!tracks.count) return;
                waDownloadCollection *collection = [[waDownloadCollection alloc] init];
                collection.identifier = item.identifier;
                collection.kind = [item isKindOfClass:[waAlbum class]] ? @"album" : @"playlist";
                collection.title = item.title;
                collection.artistName = item.subtitle;
                collection.artworkURL = [item bestArtworkURL];
                NSMutableArray *ids = [NSMutableArray array];
                for (waTrack *track in tracks) if (track.identifier.length) [ids addObject:track.identifier];
                collection.trackIDs = ids;
                [downloader enqueueTracks:tracks quality:quality collection:collection];
            };
            if ([item isKindOfClass:[waAlbum class]]) {
                [[waSession shared] albumTracks:item.identifier completion:^(NSArray *tracks, NSError *error) {
                    (void)error; enqueue(tracks);
                }];
            } else {
                [[waSession shared] playlistTracks:item.identifier completion:^(NSArray *tracks, NSError *error) {
                    (void)error; enqueue(tracks);
                }];
            }
        }]];
    }

    NSString *link = waLinkForItem(item);
    if (link.length) {
        [actions addObject:[waAction actionWithTitle:@"Copy Link" destructive:NO handler:^{
            [[UIPasteboard generalPasteboard] setString:link];
        }]];
    }

    if (!actions.count) return nil;
    return [NSDictionary dictionaryWithObjectsAndKeys:
            item.title.length ? item.title : @"", @"title",
            actions, @"actions",
            nil];
}

@end
