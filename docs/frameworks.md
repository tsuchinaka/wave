# Frameworks — iPhoneOS 6.1 (51 públicos + 213 privados)

> Inventario generado con `ls /home/main/theos/sdks/iPhoneOS6.1.sdk/System/Library/Frameworks` y `PrivateFrameworks` (27 Aug 2026).
> Linkeo en Theos: `wave_FRAMEWORKS = UIKit CoreGraphics` (`Makefile:9`). Añadir aquí otros si los necesitas.

## 1. Frameworks PÚBLICOS (51) — Seguro linkear

Estos son los únicos App Store-safe en iOS 6.1. Responden a `#import <Framework/Framework.h>`.

```
Accelerate.framework
Accounts.framework           → ACAccountStore (Facebook/Twitter integrado iOS 6)
AddressBook.framework + AddressBookUI.framework
AdSupport.framework          → ASIdentifierManager (Advertising Identifier, iOS 6+)
AssetsLibrary.framework      → ALAssetsLibrary (pre-Photos)
AudioToolbox.framework / AudioUnit.framework / AVFoundation.framework / CoreAudio.framework
CFNetwork.framework
CoreAudio / CoreBluetooth / CoreData / CoreFoundation / CoreGraphics / CoreImage
CoreLocation.framework
CoreMedia / CoreMIDI / CoreMotion / CoreTelephony / CoreText / CoreVideo
EventKit.framework + EventKitUI.framework
ExternalAccessory.framework
Foundation.framework
GameKit.framework
GLKit.framework + OpenGLES.framework + OpenAL.framework
GSS.framework
iAd.framework
ImageIO.framework
IOKit.framework
MapKit.framework             → MKMapView (vector engine nuevo iOS 6, reemplaza Google)
MediaPlayer.framework + MediaToolbox.framework
MessageUI.framework          → MFMailComposeViewController
MobileCoreServices.framework
NewsstandKit.framework       → NKLibrary (Newsstand estantería madera)
PassKit.framework            → PKPass (Passbook, nuevo iOS 6)
QuartzCore.framework         → CALayer, CAAnimation
QuickLook.framework
Security.framework
Social.framework             → SLComposeViewController (Facebook/Twitter share sheet iOS 6)
StoreKit.framework
SystemConfiguration.framework
Twitter.framework            → TWTweetComposeViewController (deprecated en favor de Social)
UIKit.framework              → (ver uikit-reference.md)
VideoToolbox.framework
```

### Notas por framework clave en iOS 6

- **Social vs Twitter/Accounts**: iOS 6 introduce `Social.framework` que unifica Facebook/Twitter. `Twitter.framework` queda legacy pero aún existe. Preferir `Social`.
- **PassKit**: Nuevo en iOS 6 para Passbook. No existe Wallet.
- **AdSupport**: Nuevo en iOS 6 para `AdvertisingIdentifier` + `Limit Ad Tracking`.
- **MapKit**: En iOS 6 cambia a motor vectorial de Apple (crisis de Maps). API igual pero tiles distintos.
- **CollectionView**: `UICollectionView` ¡NUEVO en iOS 6! (`UICollectionView.h` existe en este SDK). No existía en iOS 5.
- **Auto Layout**: `NSLayoutConstraint.h` aparece en iOS 6 pero es versión 1.0 (sin `layoutAnchors`, sin `UILayoutGuide` moderno). Usar con cautela; muchos proyectos 6.1 usaban springs/struts.
- **UIActivity**: `UIActivity.h` + `UIActivityViewController.h` nuevos en iOS 6 (Share Sheet grid de iconos).
- **PassKit, StoreKit, Newsstand**: todos disponibles.

## 2. Frameworks PRIVADOS (213) — NO linkear para App Store

`System/Library/PrivateFrameworks/` — Solo para tweaks/jailbreak. Ejemplos útiles para hookear:

```
AccessibilityUtilities, AccountSettings, AppSupport, BackBoardServices,
BluetoothManager, BulletinBoard, Celestial, ChatKit, CoreDAV, DataAccess,
GeoServices, GraphicsServices, SpringBoard, TelephonyUI, WeatherFramework,
... (213 total)
```

Listado completo:
```
AccessibilityUtilities.framework
AccountsDaemon.framework
AccountSettings.framework
AccountSettingsUI.framework
ACTFramework.framework
ActorKit.framework
AdminLite.framework
... (ver ls /home/main/theos/sdks/iPhoneOS6.1.sdk/System/Library/PrivateFrameworks)
```

**Uso**: En Theos, si haces tweak: `wave_PRIVATE_FRAMEWORKS = BulletinBoard ChatKit` etc. Para app `wave` actual (App Store-style) no usar.

## 3. Cómo añadir un framework a wave

```makefile
# Makefile:9
wave_FRAMEWORKS = UIKit CoreGraphics MapKit Social PassKit
# o privados (solo si es tweak/app jailbreak):
wave_PRIVATE_FRAMEWORKS = ChatKit BulletinBoard
```

Luego en código:

```objc
#import <MapKit/MapKit.h>
#import <Social/Social.h>
#import <PassKit/PassKit.h>
```

Verificar que el header exista:

```bash
ls /home/main/theos/sdks/iPhoneOS6.1.sdk/System/Library/Frameworks/MapKit.framework/Headers
```

## 4. Frameworks que NO existen en 6.1 (aparecen en iOS 7+)

Si los buscas y no están, es porque no existían:

- `HealthKit`, `HomeKit`, `CloudKit`, `Metal`, `ARKit`, `Vision`, `NaturalLanguage`
- `WebKit` (como framework público separado; en 6.1 es `UIWebView.h` dentro de UIKit, no `WKWebView`)
- `UserNotifications` (es `UILocalNotification.h`), `Intents`, `SafariServices`
- `AuthenticationServices`, `CryptoKit`, `Combine`, `SwiftUI`

Si necesitas uno de estos, estás fuera del rango iOS 6.1 — necesitas subir deployment target.

