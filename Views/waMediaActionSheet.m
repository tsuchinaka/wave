#import "waMediaActionSheet.h"
#import "waActions.h"
#import "waAction.h"
#import "../Services/waAPIClient.h"
#import "../Services/waAudioPlayer.h"
#import "../Services/waDownloadManager.h"
#import "../Controllers/waMediaDetailViewController.h"

@interface waPlaylistPicker : NSObject <UIActionSheetDelegate>
@property (nonatomic, weak) UIViewController *viewController;
@property (nonatomic, strong) waMediaItem *song;
@property (nonatomic, strong) UIActionSheet *sheet;
@property (nonatomic, strong) NSArray *playlists;
- (id)initWithSong:(waMediaItem *)song viewController:(UIViewController *)viewController;
- (void)present;
@end

static NSMutableArray *waPlaylistPickers(void) {
    static NSMutableArray *pickers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ pickers = [NSMutableArray array]; });
    return pickers;
}

@implementation waPlaylistPicker

- (id)initWithSong:(waMediaItem *)song viewController:(UIViewController *)viewController {
    if ((self = [super init])) {
        _song = song;
        _viewController = viewController;
    }
    return self;
}

- (void)present {
    [[waAPIClient sharedClient] playlistsWithCompletion:^(NSArray *playlists, NSError *error) {
        if (error || !playlists.count) {
            [[[UIAlertView alloc] initWithTitle:@"Add to Playlist" message:error.localizedDescription ?: @"No playlists available." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
            [waPlaylistPickers() removeObjectIdenticalTo:self];
            return;
        }
        NSMutableArray *ownedPlaylists = [NSMutableArray array];
        for (NSDictionary *playlist in playlists) {
            if ([playlist[@"owned"] respondsToSelector:@selector(boolValue)] && [playlist[@"owned"] boolValue]) [ownedPlaylists addObject:playlist];
        }
        if (!ownedPlaylists.count) {
            [[[UIAlertView alloc] initWithTitle:@"Add to Playlist" message:@"You do not have any of your own playlists yet." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
            [waPlaylistPickers() removeObjectIdenticalTo:self];
            return;
        }
        self.playlists = ownedPlaylists;
        self.sheet = [[UIActionSheet alloc] initWithTitle:@"Add to Playlist" delegate:self cancelButtonTitle:@"Cancel" destructiveButtonTitle:nil otherButtonTitles:nil];
        for (NSDictionary *playlist in playlists) {
            NSString *title = playlist[@"title"] ?: playlist[@"name"] ?: @"Playlist";
            [self.sheet addButtonWithTitle:title];
        }
        UIView *view = self.viewController.tabBarController ? self.viewController.tabBarController.view : self.viewController.view;
        [self.sheet showInView:view];
    }];
}

- (void)actionSheet:(UIActionSheet *)actionSheet didDismissWithButtonIndex:(NSInteger)buttonIndex {
    if (buttonIndex != actionSheet.cancelButtonIndex && buttonIndex < self.playlists.count) {
        NSDictionary *playlist = self.playlists[buttonIndex];
        NSString *playlistID = playlist[@"id"] ?: playlist[@"playlist_id"];
        [[waAPIClient sharedClient] addSong:[self.song dictionaryRepresentation] toPlaylist:playlistID completion:^(NSDictionary *song, NSError *error) {
            (void)song;
            [[[UIAlertView alloc] initWithTitle:error ? @"Playlist" : @"Playlist" message:error.localizedDescription ?: @"Song added to playlist." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
        }];
    }
    [waPlaylistPickers() removeObjectIdenticalTo:self];
}

@end

NSString * const waMediaLikeDidChangeNotification = @"waMediaLikeDidChangeNotification";
NSString * const waMediaLikeIdentifierKey = @"identifier";
NSString * const waMediaLikeTypeKey = @"type";

static UIPopoverController *waSharePopover;

static void waPresentShareForItem(waMediaItem *item, UIViewController *viewController) {
    NSURL *link = [item deezerURL];
    if (!link || !viewController) return;
    NSString *artist = item.artistName.length ? item.artistName : item.subtitle;
    NSString *text = nil;
    if (item.type == waMediaItemTypeSong && artist.length) text = [NSString stringWithFormat:@"%@ — %@", item.title ?: @"", artist];
    else if (item.type == waMediaItemTypeAlbum && artist.length) text = [NSString stringWithFormat:@"%@ by %@", item.title ?: @"", artist];
    else text = item.title ?: @"";
    NSArray *activityItems = text.length ? @[text, link] : @[link];
    UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:activityItems applicationActivities:nil];
    controller.excludedActivityTypes = @[UIActivityTypePrint, UIActivityTypeAssignToContact, UIActivityTypeSaveToCameraRoll];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        [waSharePopover dismissPopoverAnimated:NO];
        waSharePopover = [[UIPopoverController alloc] initWithContentViewController:controller];
        UIView *view = viewController.view;
        CGRect anchor = CGRectMake(view.bounds.size.width / 2.0, view.bounds.size.height / 4.0, 1.0, 1.0);
        [waSharePopover presentPopoverFromRect:anchor inView:view permittedArrowDirections:UIPopoverArrowDirectionAny animated:YES];
    } else {
        [viewController presentViewController:controller animated:YES completion:nil];
    }
}

@implementation waMediaActionSheet

+ (void)presentForItem:(waMediaItem *)item inViewController:(UIViewController *)viewController albumItems:(NSArray *)albumItems {
    if (!item || !viewController) return;
    __weak UIViewController *weakController = viewController;
    NSArray *tracks = albumItems ?: @[];
    NSMutableArray *actions = [NSMutableArray array];

     BOOL album = item.type == waMediaItemTypeAlbum;
      BOOL artist = item.type == waMediaItemTypeArtist;
      BOOL playlist = item.type == waMediaItemTypePlaylist;
      NSString *likeTitle = album ? (item.isLiked ? @"Unlike Album" : @"Like Album") : (artist ? (item.isLiked ? @"Unlike Artist" : @"Like Artist") : (playlist ? (item.isLiked ? @"Remove Playlist" : @"Add Playlist") : (item.isLiked ? @"Unlike" : @"Like")));
    [actions addObject:[waAction actionWithIdentifier:@"media.like" title:likeTitle handler:^(waMediaItem *selected) {
        if (![[waAPIClient sharedClient] isAuthenticated]) {
            [[[UIAlertView alloc] initWithTitle:@"Like" message:@"Sign in to save this item." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
            return;
        }
        BOOL liked = !selected.isLiked;
        selected.liked = liked;
         void (^failure)(NSError *, NSString *) = ^(NSError *error, NSString *title) {
             if (error) selected.liked = !liked;
             else [[NSNotificationCenter defaultCenter] postNotificationName:waMediaLikeDidChangeNotification object:selected userInfo:@{waMediaLikeIdentifierKey: selected.identifier ?: @"", waMediaLikeTypeKey: @(selected.type)}];
             if (error) [[[UIAlertView alloc] initWithTitle:title message:error.localizedDescription ?: @"Unable to complete the action." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
         };
          if (album) [[waAPIClient sharedClient] setLiked:liked album:selected completion:^(BOOL success, NSError *error) { failure(success ? nil : error, @"Album"); }];
          else if (artist) [[waAPIClient sharedClient] setLiked:liked artist:selected completion:^(BOOL success, NSError *error) { failure(success ? nil : error, @"Artist"); }];
          else if (playlist) [[waAPIClient sharedClient] setLiked:liked playlist:selected completion:^(BOOL success, NSError *error) { failure(success ? nil : error, @"Playlist"); }];
          else [[waAPIClient sharedClient] setLiked:liked song:selected completion:^(BOOL success, NSError *error) { failure(success ? nil : error, @"Like"); }];
    }]];

     if (album) {
        if (tracks.count) {
            // Determine album download state
            BOOL hasCompleted = NO, hasActive = NO, hasMissing = NO;
            for (waMediaItem *track in tracks) {
                NSString *identifier = track.trackId.length ? track.trackId : track.identifier;
                waDownloadState state = [[waDownloadManager sharedManager] stateForIdentifier:identifier];
                if (state == waDownloadStateCompleted) hasCompleted = YES;
                else if (state == waDownloadStateQueued || state == waDownloadStateDownloading) hasActive = YES;
                else hasMissing = YES;
            }
            if (hasActive) {
                [actions addObject:[waAction actionWithIdentifier:@"media.cancelAlbum" title:@"Cancel Album Download" destructive:YES availability:nil handler:^(waMediaItem *selected) {
                    for (waMediaItem *track in tracks) { NSString *identifier = track.trackId.length ? track.trackId : track.identifier; if (identifier.length) [[waDownloadManager sharedManager] cancelDownloadWithIdentifier:identifier]; }
                }]];
            } else if (hasCompleted && !hasMissing) {
                [actions addObject:[waAction actionWithIdentifier:@"media.deleteAlbum" title:@"Delete Album Download" destructive:YES availability:nil handler:^(waMediaItem *selected) {
                    for (waMediaItem *track in tracks) { NSString *identifier = track.trackId.length ? track.trackId : track.identifier; if (identifier.length) [[waDownloadManager sharedManager] deleteDownloadWithIdentifier:identifier completion:nil]; }
                }]];
            } else {
                [actions addObject:[waAction actionWithIdentifier:@"media.downloadAlbum" title:@"Download Album" handler:^(waMediaItem *selected) {
                    NSString *context = selected.identifier.length ? selected.identifier : selected.title;
                    for (waMediaItem *track in tracks) { [[waDownloadManager sharedManager] enqueueDownloadWithItem:track category:waDownloadCategoryAlbum contextIdentifier:context groupTitle:selected.title]; }
                }]];
            }
            [actions addObject:[waAction actionWithIdentifier:@"media.queueAlbum" title:@"Add Album to Queue" handler:^(waMediaItem *selected) { (void)selected; [[waAudioPlayer sharedPlayer] addItemsToQueue:tracks]; }]];
            [actions addObject:[waAction actionWithIdentifier:@"media.nextAlbum" title:@"Play Album Next" handler:^(waMediaItem *selected) { (void)selected; [[waAudioPlayer sharedPlayer] playItemsNext:tracks]; }]];
        }
     } else if (!playlist && !artist) {
         NSString *identifier = item.trackId.length ? item.trackId : item.identifier;
        waDownloadState state = [[waDownloadManager sharedManager] stateForIdentifier:identifier];
        if (state == waDownloadStateCompleted) {
            [actions addObject:[waAction actionWithIdentifier:@"media.deleteDownload" title:@"Delete Download" destructive:YES availability:nil handler:^(waMediaItem *selected) {
                 NSString *idToDelete = selected.trackId.length ? selected.trackId : selected.identifier;
                if (idToDelete.length) [[waDownloadManager sharedManager] deleteDownloadWithIdentifier:idToDelete completion:nil];
            }]];
        } else if (state == waDownloadStateQueued || state == waDownloadStateDownloading) {
            [actions addObject:[waAction actionWithIdentifier:@"media.cancelDownload" title:@"Cancel Download" destructive:YES availability:nil handler:^(waMediaItem *selected) {
                 NSString *idToCancel = selected.trackId.length ? selected.trackId : selected.identifier;
                if (idToCancel.length) [[waDownloadManager sharedManager] cancelDownloadWithIdentifier:idToCancel];
            }]];
        } else {
            [actions addObject:[waAction actionWithIdentifier:@"media.download" title:@"Download" handler:^(waMediaItem *selected) {
                 [[waDownloadManager sharedManager] enqueueDownloadWithItem:selected category:waDownloadCategorySong contextIdentifier:selected.trackId.length ? selected.trackId : selected.identifier];
            }]];
        }
        [actions addObject:[waAction actionWithIdentifier:@"media.queue" title:@"Add to Queue" handler:^(waMediaItem *selected) { [[waAudioPlayer sharedPlayer] addItemToQueue:selected]; }]];
        [actions addObject:[waAction actionWithIdentifier:@"media.next" title:@"Play Next" handler:^(waMediaItem *selected) { [[waAudioPlayer sharedPlayer] playItemNext:selected]; }]];
        [actions addObject:[waAction actionWithIdentifier:@"media.addToPlaylist" title:@"Add to Playlist" handler:^(waMediaItem *selected) {
            if (![[waAPIClient sharedClient] isAuthenticated]) {
                [[[UIAlertView alloc] initWithTitle:@"Playlist" message:@"Sign in to manage playlists." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil] show];
                return;
            }
            waPlaylistPicker *picker = [[waPlaylistPicker alloc] initWithSong:selected viewController:weakController];
            [waPlaylistPickers() addObject:picker];
            [picker present];
        }]];
    }

    if (playlist) {
        NSDictionary *metadata = [item.metadata isKindOfClass:[NSDictionary class]] ? item.metadata : nil;
        BOOL owned = [metadata[@"owned"] respondsToSelector:@selector(boolValue)] && [metadata[@"owned"] boolValue];
        if (owned) {
            [actions addObject:[waAction actionWithIdentifier:@"media.editPlaylist" title:@"Edit Playlist" handler:^(waMediaItem *selected) {
                (void)selected;
                UIViewController *controller = weakController;
                if ([controller respondsToSelector:@selector(editPlaylist)]) [controller performSelector:@selector(editPlaylist)];
            }]];
        }
    }

    if (item.artistIdentifier.length) [actions addObject:[waAction actionWithIdentifier:@"media.artist" title:@"Go to Artist" handler:^(waMediaItem *selected) {
        UIViewController *controller = weakController; if (!controller) return;
        waMediaItem *destination = [[waMediaItem alloc] initWithIdentifier:selected.artistIdentifier title:selected.artistName.length ? selected.artistName : selected.subtitle subtitle:@"" type:waMediaItemTypeArtist];
        destination.thumbnailURL = selected.thumbnailURL;
        [controller.navigationController pushViewController:[[waMediaDetailViewController alloc] initWithMediaItem:destination] animated:YES];
    }]];
    if (!album && item.albumIdentifier.length) [actions addObject:[waAction actionWithIdentifier:@"media.album" title:@"Go to Album" handler:^(waMediaItem *selected) {
        UIViewController *controller = weakController; if (!controller) return;
        waMediaItem *destination = [[waMediaItem alloc] initWithIdentifier:selected.albumIdentifier title:selected.albumName.length ? selected.albumName : @"Album" subtitle:@"" type:waMediaItemTypeAlbum];
        destination.thumbnailURL = selected.thumbnailURL;
        [controller.navigationController pushViewController:[[waMediaDetailViewController alloc] initWithMediaItem:destination] animated:YES];
    }]];
    if ([item deezerURL]) [actions addObject:[waAction actionWithIdentifier:@"media.share" title:@"Share…" handler:^(waMediaItem *selected) {
        UIViewController *controller = weakController; if (!controller) return;
        waPresentShareForItem(selected, controller);
    }]];

     NSString *kind = album ? @"Album" : (artist ? @"Artist" : (playlist ? @"Playlist" : @"Song"));
    [[waActions sharedActions] presentTitle:item.title ?: kind actions:actions object:item fromViewController:viewController];
}

@end
