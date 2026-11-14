# SDK Reference — iPhoneOS5.1.sdk

Build y deployment son el mismo SDK. `Makefile:1`:

```
TARGET := iphone:clang:5.1:5.1
ARCHS = armv7
```

Ruta: `/home/main/theos/sdks/iPhoneOS5.1.sdk` (338M). No hay SDK 6.1 ni 7.1 en `sdks/` de esta máquina. No documentar un fallback que no está instalado.

## SDKSettings.plist

`/home/main/theos/sdks/iPhoneOS5.1.sdk/SDKSettings.plist`

```
CanonicalName: iphoneos5.1
Version: 5.1
DisplayName: iOS 5.1
IsBaseSDK: YES
MaximumDeploymentTarget: 5.1.99
IPHONEOS_DEPLOYMENT_TARGET: 5.1
PLATFORM_NAME: iphoneos
SUPPORTED_DEVICE_FAMILIES: 1, 2
CODE_SIGNING_REQUIRED: YES
```

Familia 1 es iPhone, 2 es iPad. El binario de wave es armv7. Eso cubre iPhone 3GS, 4 y 4s, y el iPad de esa generación. No hay armv7s ni arm64 en el `Makefile`. `./deploy.sh --arch` puede pasar otro `ARCHS` a make; el default del proyecto es armv7.

## Layout útil

```
iPhoneOS5.1.sdk/
  SDKSettings.plist
  System/Library/Frameworks/          46 públicos
  System/Library/PrivateFrameworks/   170
  usr/include/
  usr/lib/
```

Validar:

```
ls /home/main/theos/sdks/
du -sh /home/main/theos/sdks/iPhoneOS5.1.sdk
ls /home/main/theos/sdks/iPhoneOS5.1.sdk/System/Library/Frameworks | wc -l
```

Si `sdks/` no contiene `iPhoneOS5.1.sdk`, el build no tiene SDK. Reinstalar desde los Legacy iOS SDKs el árbol `iPhoneOS5.1.sdk` y copiarlo a `/home/main/theos/sdks/`. No sustituir por 6.1 o 7.1: el código usa el shim de `Support/waIOS5Compat.h` y evita APIs posteriores.

## Qué no trae este SDK

Comprobado contra los headers:

- No `UICollectionView`, `UIRefreshControl`, `UIActivityViewController`
- No `UIAlertController` (sí `UIAlertView` y `UIActionSheet`)
- No `WKWebView` (sí `UIWebView`)
- No `UIStackView`, `UIVisualEffectView`, `NSLayoutAnchor`
- No `NSLayoutConstraint.h` en UIKit
- No `NSURLSession` (sí `NSURLConnection.h`)

`UIStepper`, `UIPageViewController`, `UIAppearance`, `UIDocument` y `UIStoryboard` sí están. Wave no usa storyboards: la UI se arma en código.

## Info.plist del proyecto

`Resources/Info.plist:79` fija `MinimumOSVersion` en `5.1`. `CFBundleShortVersionString` está en `0.3.0`. La versión que empaqueta Theos es `control:3` (`0.3.54` en el árbol actual). No asumir que coinciden.
