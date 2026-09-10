# Docs — wave (iOS 6.1)

Proyecto **wave** — `com.bytebox.wave` — App Theos (`Makefile:6` `APPLICATION_NAME = wave`).

Este directorio es la fuente de verdad para no perderse trabajando con el SDK legacy.

## Mapa rápido

| Doc | Qué resuelve |
|-----|--------------|
| [ios6-interface-guide.md](ios6-interface-guide.md) | Lenguaje visual iOS 6 (skeuomorphism, colores, texturas, no hacer) |
| [sdk-reference.md](sdk-reference.md) | Inventario completo del `iPhoneOS6.1.sdk` instalado (estructura, plist, tamaños) |
| [uikit-reference.md](uikit-reference.md) | Todos los headers UIKit/CoreGraphics/QuartzCore disponibles en 6.1 + qué puedes importar |
| [build-guide.md](build-guide.md) | Cómo compilar `wave` con Theos + SDK 6.1 + troubleshooting |
| [frameworks.md](frameworks.md) | 51 frameworks públicos + 213 privados — cuándo linkear cada uno |

## SDK instalado

```
THEOS = /home/main/theos
SDK   = /home/main/theos/sdks/iPhoneOS6.1.sdk (515M)
  CanonicalName = iphoneos6.1
  IPHONEOS_DEPLOYMENT_TARGET = 6.1
  MaximumDeploymentTarget = 6.1.99
  IsBaseSDK = YES
  Source: https://github.com/EachAndOther/Legacy-iOS-SDKs/tree/master/iPhoneOS6.1.sdk
```

Verificado: `SDKSettings.plist` + `du -sh` + `ls /home/main/theos/sdks/`. Antes estaba vacío.

## Proyecto wave — snapshot

```
main.m:6                → UIApplicationMain con waAppDelegate
waAppDelegate.h:3       → UIWindow + UITabBarController
waAppDelegate.m:69-108  → Crea las cinco pestañas y el Player modal
Controllers/             → Home, Search, Library, Player, Queue, playlists y vistas de detalle
Services/                → API, Deezer, descargas, cachés, audio y telemetría
Views/                   → Celdas y componentes reutilizables de la interfaz
Resources/Info.plist:40  → CFBundleIdentifier com.bytebox.wave
Resources/AppIcon*.png  → 18 iconos (29/40/50/57/60/72/76 @1x/@2x/@3x)
control:3               → Versión incremental del paquete (rama actual `0.1.1-N+debug`)
Makefile:1,14           → TARGET iphone:clang:6.1:6.1 + frameworks + fuentes
```

## Organización interna actual

Las responsabilidades grandes están divididas en unidades pequeñas sin cambiar la API pública:

- `Services/waDeezerClient+Playlists.m`: creación, edición, likes y canciones de playlists.
- `Services/waLibraryMapper.m` y `Services/waDownloadStats.m`: transformación de datos y estadísticas de descargas.
- `Controllers/waListViewController+SearchData.m`: filtros, secciones, top result y normalización de Search.
- `Views/waSearchCells.m`: celdas específicas de Search.
- `Services/waAudioPlayer+Queue.m`: mutaciones y navegación de la cola.
- `Services/waAudioPlayer+Engine.m`: eventos del motor, stalls, fallback y finalización.
- `Audio/waAudioEngine.m`, `Audio/waPCMMixer.m` y `Audio/waPCMTrack.m`: motor PCM/AudioQueue con Origami; ya no usa AVPlayer.
- `Services/waImageLoader.m`: dos conexiones de carátulas activas, respuestas limitadas a 8 MB y decodificación en background.

La versión base local ya era `0.1.1`; se mantiene para no degradar los paquetes instalados. Checklist de regresión de la auditoría en `docs/todo.md`.

Los headers `+Private.h` contienen únicamente contratos internos para compartir propiedades y métodos entre la clase principal y sus categorías.

Settings refleja esta separación: Account muestra únicamente la cuenta Deezer, Last.fm y scrobbling; descargas, caché, reproducción, apariencia, privacidad, Bridge y diagnósticos viven en sus propias secciones. Deezer no se presenta con controles de perfil que la API no pueda modificar.

## Regla de oro iOS 6

> Si no existe en `/System/Library/Frameworks` de este SDK, no existe en iOS 6.1. Consultar `uikit-reference.md` antes de importar.

Ejemplos de cosas que NO existen en 6.1:
- `UIVisualEffectView`, `UIStackView`, `UIAlertController` (es `UIAlertView`/`UIActionSheet`)
- `SF Symbols`, `Dark Mode`, `Size Classes` completas, `Auto Layout` maduro (existe `NSLayoutConstraint.h` pero limitado)
- `WKWebView` (es `UIWebView.h`)
- `NSLayoutAnchor`, `UILayoutGuide` moderno

## Flujo de trabajo

1. Leer `ios6-interface-guide.md` para diseño
2. Consultar `uikit-reference.md` para ver qué clase/método existe
3. Añadir `.m` a `wave_FILES` en `Makefile:14` si creas archivos nuevos
4. Seguir `build-guide.md` para compilar
