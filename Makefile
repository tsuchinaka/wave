TARGET := iphone:clang:5.1:5.1
ARCHS = armv7
FINALPACKAGE = 1
MAKEFLAGS += -j4
INSTALL_TARGET_PROCESSES = wave

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = wave

CORE_FILES = Core/waModel.m Core/waCrypto.m Core/waAudioProbe.m Core/waDZAPI.m Core/waSession.m \
             Core/waDownloader.m Core/waImageCache.m Core/waLog.m Core/waAudioCore.m Core/waPlayer.m Core/waTLS.m \
             Core/waLyrics.m Core/waLastFM.m

SKIN_FILES = Skin/waSkin.m Skin/waCell.m Skin/waTileView.m Skin/waCarouselView.m Skin/waCoverView.m Skin/waLyricStage.m

UI_FILES = UI/waTableController.m UI/waRootController.m UI/waAppDelegate.m \
           UI/waHomeController.m UI/waSearchController.m UI/waDetailController.m UI/waLibraryController.m \
           UI/waChartsController.m UI/waRadioController.m UI/waGenresController.m UI/waDiscographyController.m UI/waDownloadsController.m \
           UI/waLoginController.m UI/waProfileController.m UI/waPlayerController.m UI/waQueueController.m \
           UI/waLyricsController.m UI/waSettingsController.m UI/waStorageController.m UI/waEQController.m \
           UI/waLogsController.m UI/waPlaylistEditController.m UI/waAboutController.m

VENDOR_FILES = Vendor/OrigamiEngine/ORGMAudioUnit.m Vendor/OrigamiEngine/ORGMQueues.m \
               Vendor/OrigamiEngine/ORGMInputUnit.m Vendor/OrigamiEngine/ORGMPluginManager.m \
               Vendor/OrigamiEngine/Plugins/FileSource.m Vendor/OrigamiEngine/Plugins/HTTPSource.m \
               Vendor/OrigamiEngine/Plugins/CoreAudioDecoder.m Vendor/OrigamiEngine/Plugins/FlacDecoder.m \
               Vendor/OrigamiEngine/Plugins/M3uContainer.m Vendor/OrigamiEngine/Plugins/CueSheetContainer.m \
               Vendor/OrigamiEngine/Plugins/CueSheetDecoder.m Vendor/OrigamiEngine/Plugins/CueSheet.m \
               Vendor/OrigamiEngine/Plugins/CueSheetTrack.m \
               Vendor/quirc/decode.c Vendor/quirc/identify.c Vendor/quirc/quirc.c Vendor/quirc/version_db.c

wave_FILES = main.m $(CORE_FILES) $(SKIN_FILES) $(UI_FILES) $(VENDOR_FILES) $(wildcard Vendor/mbedtls/library/*.c) Support/waIOS5Compat.m

wave_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore AVFoundation AudioToolbox MediaPlayer Security \
                  ImageIO CoreMedia CoreVideo SystemConfiguration CoreText
wave_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -include Support/waIOS5Compat.h -ISupport -ICore -ISkin -IUI -IVendor -IVendor/OrigamiEngine -IVendor/OrigamiEngine/Plugins -IVendor/mbedtls/include -IVendor/mbedtls/library
wave_LDFLAGS = -F$(THEOS_PROJECT_DIR)/Vendor -framework FLAC

include $(THEOS_MAKE_PATH)/application.mk

# OrigamiEngine is legacy MRC.
$(foreach f,$(filter Vendor/OrigamiEngine/%,$(wave_FILES)),$(eval $(f)_CFLAGS += -fno-objc-arc))

# Hot decode path. No NEON: the iPhone 3GS has no NEON unit and it is a
# supported iOS 5.1 device.
$(foreach f,Core/waAudioCore.m Core/waCrypto.m Vendor/OrigamiEngine/Plugins/FlacDecoder.m,$(eval $(f)_CFLAGS += -O3))
$(foreach f,$(wildcard Vendor/mbedtls/library/*.c),$(eval $(f)_CFLAGS += -O2))
