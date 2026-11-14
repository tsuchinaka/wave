# Frameworks — iPhoneOS 5.1

Inventario de `/home/main/theos/sdks/iPhoneOS5.1.sdk/System/Library/Frameworks` (46) y `PrivateFrameworks` (170). Linkeo real en `Makefile:35-36`.

## Los que linkea wave

```
UIKit Foundation CoreGraphics QuartzCore AVFoundation AudioToolbox MediaPlayer Security
ImageIO CoreMedia CoreVideo SystemConfiguration CoreText
```

Más `-framework FLAC` desde `Vendor/` (`Makefile:38`). OrigamiEngine, quirc y mbedTLS entran como fuentes, no como frameworks del SDK.

No añadir un framework sin comprobar que el directorio existe en el SDK 5.1. Privados van a `wave_PRIVATE_FRAMEWORKS`, y solo si un header de ese SDK los declara.

## Públicos (46)

```
AVFoundation
Accelerate
Accounts
AddressBook
AddressBookUI
AssetsLibrary
AudioToolbox
AudioUnit
CFNetwork
CoreAudio
CoreBluetooth
CoreData
CoreFoundation
CoreGraphics
CoreImage
CoreLocation
CoreMIDI
CoreMedia
CoreMotion
CoreTelephony
CoreText
CoreVideo
EventKit
EventKitUI
ExternalAccessory
Foundation
GLKit
GSS
GameKit
IOKit
ImageIO
MapKit
MediaPlayer
MessageUI
MobileCoreServices
NewsstandKit
OpenAL
OpenGLES
QuartzCore
QuickLook
Security
StoreKit
SystemConfiguration
Twitter
UIKit
iAd
```

Notas que importan para este target:

- `Accounts` existe, pero wave no lo usa. El login de Deezer es un ARL, no `ACAccountStore`.
- `AVFoundation` está linkeado. El playback de pistas no pasa por `AVPlayer`: lo hace `waAudioCore` con `AudioQueue`.
- `CoreBluetooth`, `GLKit`, `NewsstandKit` y `Twitter` son de iOS 5. No usarlos por estar en la lista.
- No hay `AdSupport`, `Social` ni `PassKit` en este SDK. Esos llegan en iOS 6.

## Privados

170 directorios en `PrivateFrameworks`. No inventar un import. Si hace falta uno, `ls` del framework y leer el header antes de añadirlo al Makefile.
