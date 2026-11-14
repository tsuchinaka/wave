# Docs — wave (iOS 5.1)

Proyecto **wave** — `com.sokubit.wave` — app Theos, no tweak. Cliente Deezer para iOS 5.1, armv7.

El árbol `Controllers/`, `Services/`, `Models/`, `Views/` y `Audio/` de la rama 0.1.x ya no existe. La fuente de verdad es el código en `Core/`, `Skin/`, `UI/` y `Support/`.

## Mapa

| Doc | Qué resuelve |
|-----|--------------|
| [ios6-interface-guide.md](ios6-interface-guide.md) | Piel iOS 5.1 que implementa `Skin/waSkin`. El nombre del archivo es histórico. |
| [sdk-reference.md](sdk-reference.md) | `iPhoneOS5.1.sdk` instalado |
| [uikit-reference.md](uikit-reference.md) | Qué hay en UIKit 5.1 y qué no se puede importar |
| [frameworks.md](frameworks.md) | Frameworks públicos del SDK y los que linkea el Makefile |
| [build-guide.md](build-guide.md) | Compilar, empaquetar, instalar |
| [todo.md](todo.md) | Estado actual. El checklist 0.1.x no es contrato. |
| [lastfm-credentials.md](lastfm-credentials.md) | Credenciales de la aplicación Last.fm. No copiarlas a otros archivos. |

## SDK

```
THEOS = /home/main/theos
SDK   = /home/main/theos/sdks/iPhoneOS5.1.sdk
  CanonicalName = iphoneos5.1
  Version = 5.1
  IPHONEOS_DEPLOYMENT_TARGET = 5.1
  MaximumDeploymentTarget = 5.1.99
  IsBaseSDK = YES
  Frameworks públicos = 46
  UIKit headers = 99
```

`Makefile:1` fija `TARGET := iphone:clang:5.1:5.1` y `ARCHS = armv7`.

## Snapshot

```
main.m                         UIApplicationMain → waAppDelegate
UI/waAppDelegate.m:18          window + waRootController, waSkin install, restore de sesión
UI/waRootController.m:47-69    4 tabs: Home, Search, Library, Settings
UI/waRootController.h:8        UITabBarController + mini player; el player grande es modal
Core/waSession.h               catálogo, likes, playlists, stream URL
Core/waDZAPI.h                 gw-light, api.deezer.com, media.deezer.com/v1/get_url
Core/waPlayer.h                cola, crossfade, EQ, remote control
Core/waAudioCore.h             un AudioQueue, ring actual + siguiente
Core/waTLS.h                   TLS 1.2 (mbedTLS) para hosts que SecureTransport 5.1 no negocia
Skin/waSkin.h                  chrome nativo iOS 5.1
Resources/Info.plist:52        CFBundleIdentifier com.sokubit.wave
Resources/Info.plist:79        MinimumOSVersion 5.1
control:3                      versión del paquete
```

## Regla

Si no está en `/home/main/theos/sdks/iPhoneOS5.1.sdk/System/Library/Frameworks`, no se usa. `UICollectionView`, `UIRefreshControl`, `UIAlertController`, `NSURLSession` y `NSLayoutConstraint` no existen en este SDK.

## Flujo

1. Leer `ios6-interface-guide.md` si se toca UI.
2. Confirmar el header en el SDK 5.1 antes de importar.
3. Archivo nuevo: añadirlo a `CORE_FILES`, `SKIN_FILES` o `UI_FILES` en el `Makefile`.
4. Compilar con `build-guide.md`.
