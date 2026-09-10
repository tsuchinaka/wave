TARGET := iphone:clang:7.1:6.1
ARCHS = armv7 armv7s
# Release schema: without this, this Theos variant forces DEBUG (-O0, no
# strip). -Os + strip is a large win on A4/A5 devices (DSP, JSON, image
# decode) and halves the binary that has to page in from disk.
FINALPACKAGE = 1
# Keep legacy Theos builds bounded; very high parallelism can race while
# creating per-architecture object directories on this toolchain.
MAKEFLAGS += -j4
INSTALL_TARGET_PROCESSES = wave
THEOS_DEVICE_IP = 192.168.1.8
THEOS_DEVICE_USER = root

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = wave

wave_FILES = main.m waAppDelegate.m Controllers/waHomeViewController.m Controllers/waListViewController.m Controllers/waListViewController+SearchData.m Controllers/waLibraryViewController.m Controllers/waMediaResultsViewController.m Controllers/waSettingsViewController.m Controllers/waStorageViewController.m Controllers/waDeezerLoginViewController.m Controllers/waLogsViewController.m Controllers/waMediaDetailViewController.m Controllers/waProfileViewController.m Controllers/waPlayerViewController.m Controllers/waLyricsViewController.m Controllers/waLikedSongsViewController.m Controllers/waDownloadedSongsViewController.m Controllers/waDownloadedAlbumsViewController.m Controllers/waDownloadedAlbumDetailViewController.m Controllers/waThemeViewController.m Controllers/waEQViewController.m Controllers/waPlaylistViewController.m Controllers/waQueueViewController.m Views/waPlaceholder.m Views/waArtworkCell.m Views/waSegmentedControl.m Views/waMediaInfoCell.m Views/waCatalogInfoCard.m Views/waCatalogTrackCell.m Views/waCatalogSectionHeaderView.m Views/waAction.m Views/waActions.m Views/waMediaActionSheet.m Views/waHomeCardCell.m Views/waHomeSectionView.m Views/waHomeSectionCell.m Views/waEmptyView.m Views/waSearchCells.m Views/waSettingsCell.m Models/waMediaItem.m Models/waPreferences.m Models/waSong.m Models/waAlbum.m Models/waArtist.m Models/waPlaylist.m Models/waDownload.m Services/waAPIClient.m Services/waDeezerClient.m Services/waDeezerClient+Playlists.m Services/waDownloadManager.m Services/waDownloadStats.m Services/waAudioPlayer.m Services/waAudioPlayer+Queue.m Services/waAudioPlayer+Engine.m Services/waImageLoader.m Services/waKeychainStore.m Services/waTheme.m Services/waLastFMClient.m Services/waRPCClient.m Services/waDebugLog.m Audio/waAudioEngine.m Audio/waPCMTrack.m Audio/waPCMMixer.m Audio/waEqualizer.m Audio/waCompressor.m Vendor/OrigamiEngine/ORGMAudioUnit.m Vendor/OrigamiEngine/ORGMInputUnit.m Vendor/OrigamiEngine/ORGMPluginManager.m Vendor/OrigamiEngine/ORGMQueues.m Vendor/OrigamiEngine/Plugins/CoreAudioDecoder.m Vendor/OrigamiEngine/Plugins/CueSheet.m Vendor/OrigamiEngine/Plugins/CueSheetContainer.m Vendor/OrigamiEngine/Plugins/CueSheetDecoder.m Vendor/OrigamiEngine/Plugins/CueSheetTrack.m Vendor/OrigamiEngine/Plugins/FileSource.m Vendor/OrigamiEngine/Plugins/HTTPSource.m Vendor/OrigamiEngine/Plugins/M3uContainer.m Vendor/OrigamiEngine/Plugins/FlacDecoder.m
wave_FRAMEWORKS = UIKit CoreGraphics CoreFoundation CoreVideo CoreMedia AVFoundation AudioToolbox MediaPlayer Security ImageIO QuartzCore
wave_FILES += Controllers/waDownloadsViewController.m Controllers/waTrackListViewController.m Controllers/waQRScannerViewController.m
wave_FILES += Services/waDeezerStreamClient.m Services/waDeezerBlowfish.c
wave_FILES += Vendor/quirc/decode.c Vendor/quirc/identify.c Vendor/quirc/quirc.c Vendor/quirc/version_db.c
wave_CFLAGS = -fobjc-arc -IVendor -IVendor/OrigamiEngine -IVendor/OrigamiEngine/Plugins
wave_LDFLAGS = -F$(THEOS_PROJECT_DIR)/Vendor -framework FLAC

include $(THEOS_MAKE_PATH)/application.mk

# OrigamiEngine is legacy MRC code; keep the application and wrapper ARC-safe.
$(foreach f,$(filter Vendor/OrigamiEngine/%,$(wave_FILES)),$(eval $(f)_CFLAGS += -fno-objc-arc))

# Hot DSP paths: -O3 + NEON. The EQ/compressor numerics were validated with
# the host response harness; FLAC/PCM loop code is pure C with no FP state
# that -O3 could reassociate unsafely.
$(foreach f,Audio/waEqualizer.m Audio/waCompressor.m Audio/waPCMTrack.m Audio/waPCMMixer.m Vendor/OrigamiEngine/Plugins/FlacDecoder.m,$(eval $(f)_CFLAGS += -O3 -mfpu=neon -mfloat-abi=softfp))
