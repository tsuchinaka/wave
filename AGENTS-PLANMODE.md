# AGENTS-PLANMODE.md — wave

Contraparte de `AGENTS.md`. En este modo se inspecciona y se propone. No se modifica el proyecto. Si el modo es de build, leer `AGENTS.md`.

## 1. Qué es

**wave** — `com.bytebox.wave` — app Theos, no tweak. Target **iOS 5.1**, armv7, SDK `iPhoneOS5.1.sdk`. Cliente Deezer. Versión del paquete en `control:3`.

No es la app 0.1.x. No hay `Controllers/`, `Services/`, `Models/`, `Views/` ni `Audio/`.

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

## 2. No editar

No editar, crear, borrar, mover ni renombrar. No aplicar patches. No tocar `Makefile`, `Info.plist`, docs ni assets. No `git add`, `commit`, `push`, `reset`, `restore` ni `checkout` que cambie el árbol. No `make`, `make clean` ni `make package`. Un plan no autoriza el arreglo, aunque sea evidente: se describe, no se aplica.

Sí: leer, grep, `git status` / `diff` / `log` / `show`, listar headers del SDK, citar `path:line` verificado.

## 3. Entorno

```
THEOS = /home/main/theos
SDK   = /home/main/theos/sdks/iPhoneOS5.1.sdk
Project = /home/main/projects/wave
Docs    = /home/main/projects/wave/docs/
Book    = /home/main/programming-ios6/
```

El Book es iOS 6. Sirve para ObjC y tablas. No autoriza una API que no esté en el SDK 5.1. Si `sdks/` no tiene `iPhoneOS5.1.sdk`, el plan dice cómo restaurarlo y no lo restaura.

## 4. Docs

| Doc | Cuándo |
|-----|--------|
| `docs/README.md` | Mapa |
| `docs/ios6-interface-guide.md` | UI. El nombre es histórico; la piel es 5.1 |
| `docs/sdk-reference.md` | SDK |
| `docs/frameworks.md` | 46 públicos, 170 privados, los que linkea el Makefile |
| `docs/uikit-reference.md` | Headers 5.1 y APIs que no existen |
| `docs/build-guide.md` | Cómo se compilaría |
| `docs/todo.md` | Estado. El checklist 0.1.x no es contrato |
| `docs/lastfm-credentials.md` | No copiar secretos al plan |

## 5. Qué puede proponer el plan

- ObjC + UIKit + ARC. OrigamiEngine sigue en MRC.
- Frames y `autoresizingMask`. No `NSLayoutConstraint`.
- `presentModalViewController:animated:` / `dismissModalViewControllerAnimated:`.
- `UIAlertView` / `UIActionSheet` con delegate.
- `NSURLConnection` o `waTLS`. No `NSURLSession`.
- Deezer por `waDZAPI` y `waSession`. Playback por `waPlayer` y `waAudioCore`.
- Piel por `waSkin`.
- Un `.m` nuevo se anota en `CORE_FILES`, `SKIN_FILES` o `UI_FILES`. No se añade.
- Un framework nuevo solo si `ls` del SDK 5.1 lo confirma.

No proponer `UICollectionView`, `UIRefreshControl`, `UIAlertController`, `WKWebView`, `UIStackView`, `UIVisualEffectView`, SF Symbols ni SwiftUI.

## 6. Forma del plan

1. Hechos leídos, con `path:line`.
2. Qué está mal o qué falta.
3. Cambio propuesto: archivos, métodos, riesgo.
4. Qué no se toca.
5. Validación, como comando, sin ejecutarlo:

```
export THEOS=/home/main/theos
cd /home/main/projects/wave && make -j4
```

El `.deb` sale con la versión de `control`, no con la de `Info.plist`.
