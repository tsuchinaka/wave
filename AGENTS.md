# AGENTS.md — wave

Guía para quien toque este repo. Leer esto antes de editar.

## 1. Qué es

**wave** — `com.bytebox.wave` — app iOS (no tweak) con Theos. Target **iOS 5.1**, armv7, SDK `iPhoneOS5.1.sdk`. Cliente Deezer. Versión del paquete en `control:3`.

No es la app 0.1.x. No hay `Controllers/`, `Services/`, `Models/`, `Views/` ni `Audio/`. No hay `waTheme`, `waAPIClient`, `waAudioPlayer` ni `waAppDelegate` en la raíz. Si un doc los cita como archivos vivos, el doc está viejo.

```
main.m                  UIApplicationMain → @"waAppDelegate"
UI/waAppDelegate.m:18   UIWindow, [waSkin install], waRootController, restore de waSession
UI/waRootController.m   UITabBarController, 4 tabs:
                        Home | Search | Library | Settings
                        mini player (UIToolbar); player grande modal
Core/                   waSession, waDZAPI, waPlayer, waAudioCore, waTLS,
                        waCrypto, waDownloader, waImageCache, waLyrics, waLastFM, waModel, waLog
Skin/                   waSkin y celdas/carruseles
Support/waIOS5Compat.h  subscripts, alineación, @YES
Vendor/                 OrigamiEngine (MRC), FLAC 1.4.3, quirc, mbedTLS 2.28
Makefile:1              TARGET := iphone:clang:5.1:5.1, ARCHS armv7, -fobjc-arc
```

## 2. Dónde está todo

```
THEOS = /home/main/theos
SDK   = /home/main/theos/sdks/iPhoneOS5.1.sdk
Project = /home/main/projects/wave
Docs    = /home/main/projects/wave/docs/
Book    = /home/main/programming-ios6/   (iOS 6; no autoriza APIs ausentes del SDK 5.1)
```

Si `ls /home/main/theos/sdks/` no muestra `iPhoneOS5.1.sdk`, no hay con qué compilar. `docs/sdk-reference.md`.

## 3. Docs

| Doc | Cuándo |
|-----|--------|
| `docs/README.md` | Mapa |
| `docs/ios6-interface-guide.md` | UI. El nombre del archivo es histórico; la piel es 5.1 |
| `docs/uikit-reference.md` | Antes de importar UIKit |
| `docs/sdk-reference.md` | SDK, arquitecturas, versiones |
| `docs/frameworks.md` | Qué se puede linkear |
| `docs/build-guide.md` | make, package, deploy |
| `docs/todo.md` | Estado. Ignorar checklists 0.1.x si reaparecen |
| `docs/lastfm-credentials.md` | No copiar secretos a otros archivos |

El Book describe iOS 6. Vale para ObjC, memoria, tablas y el ciclo `loadView → viewDidLoad → viewWillAppear`. No vale para `UICollectionView`, `UIRefreshControl`, `UIActivityViewController` ni Auto Layout: en 5.1 no están. Grep del capítulo, luego comprobar el header en el SDK.

Regla: si no está en `/home/main/theos/sdks/iPhoneOS5.1.sdk/System/Library/Frameworks`, no se usa.

## 4. Al editar

- ObjC + UIKit. Sin Swift. Sin storyboards. UI en código.
- ARC en el target (`-fobjc-arc`). OrigamiEngine es MRC (`Makefile:43`). No meter `retain`/`release` en `Core/`, `Skin/` ni `UI/`.
- `__weak` en bloques que capturan `self` si el bloque puede vivir más que la llamada.
- Layout: frames y `autoresizingMask`. No `NSLayoutConstraint`.
- Modales: `presentModalViewController:animated:` y `dismissModalViewControllerAnimated:`. Ver `UI/waAppDelegate.m:76`.
- Alertas: `UIAlertView` / `UIActionSheet` con delegate. No `UIAlertController`.
- Red: `NSURLConnection`, o `waTLS` si SecureTransport 5.1 no negocia el host. No `NSURLSession`.
- Deezer entra por `waDZAPI` y `waSession`. No reintroducir un backend LAN ni `waAPIClient`.
- Playback entra por `waPlayer` → `waAudioCore`. No volver a `AVPlayer` para las pistas.
- Piel: `waSkin`. No un segundo sistema de temas.
- Archivo nuevo: añadirlo a `CORE_FILES`, `SKIN_FILES` o `UI_FILES` en el `Makefile`.
- Framework nuevo: existe en el SDK 5.1 y se añade a `wave_FRAMEWORKS`. Privados, a `wave_PRIVATE_FRAMEWORKS`, con header leído.
- Citas: `path:line` real. `UI/waRootController.m:47`, no un `waAppDelegate.m` que ya no está.

## 5. Después de editar

```
export THEOS=/home/main/theos
cd /home/main/projects/wave && make -j4
```

`make package` o `./deploy.sh` si hay que instalar. Si no se puede compilar, decir qué se contrastó con el SDK y qué falta.

No subir la versión de `control` ni igualarla con `Info.plist` si no se pidió. Hoy discrepan: el `.deb` sale de `control`, el bundle corto dice `0.3.0`.

## 6. Convenciones

- Código y comentarios en inglés. Docs en español.
- No commitear sin pedirlo. Mensaje corto, en el estilo del repo.
- No crear archivos de más. Docs en `docs/`. Código nuevo en `Core/`, `Skin/` o `UI/`.
- No copiar la API key ni el shared secret de Last.fm a otro archivo.

## 7. Árbol

```
wave/
├── AGENTS.md
├── docs/
├── main.m
├── Core/            waSession waDZAPI waPlayer waAudioCore waTLS waCrypto
│                    waDownloader waImageCache waLyrics waLastFM waModel waLog waAudioProbe
├── Skin/            waSkin waCell waCarouselView waTileView waCoverView waLyricStage
├── UI/              waRootController waAppDelegate + pantallas
├── Support/         waIOS5Compat
├── Vendor/          OrigamiEngine, FLAC, quirc, mbedtls, certs
├── Resources/       Info.plist, iconos
├── Makefile
├── control
└── deploy.sh
```
