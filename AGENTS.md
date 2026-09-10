# AGENTS.md — wave

> Guía para agentes (humanos y AI) trabajando en este repo. Lee esto primero antes de tocar código.

## 1. Qué es esto

**wave** — `com.bytebox.wave` — Aplicación iOS jailbreak (no tweak) construida con **Theos**. Target **iOS 6.1+ con SDK 7.1** (binario único: deployment 6.1, base SDK 7.1 — UI opaca unificada que se ve idéntica en 6.1 y 7.x).

- **Estado actual:** no es boilerplate. App completa Last.fm/Deezer-like con 19 `Controllers`, 7 `Models`, 15 `Services`, `Audio/waAudioEngine` y 15 `Views`. Ver `docs/todo.md` — 36 TODOs de estabilización ya en `[x]`.
- **Stack:** ObjC + UIKit + ARC (`-fobjc-arc`). Sin Swift, sin Storyboards (usa `Resources/Info.plist` + `AppIcon*.png` + `Default.png` — `UILaunchStoryboardName` en `Info.plist:65` es warning en 6.1).
- **Arquitectura:** `UITabBarController` (5 tabs) con 4 `UINavigationController` + 1 modal Player. Ver `waAppDelegate.m:69-108`.

```
waAppDelegate.h:3       UIResponder <UIApplicationDelegate>, UIWindow + rootViewController (UITabBarController)
waAppDelegate.m:69      didFinishLaunching: crea UIWindow, [waTheme configureGlobalAppearance], 5 tabs:
                        home(waHomeViewController) | search(waListViewController) | library(waLibraryViewController:Grouped)
                        | settings(waSettingsViewController:Grouped) | player(modal waPlayerViewController)
                        + hideTabBarTitles con \u200B, remoteControl Next/Prev, themeDidChange observer
Controllers/            18 VCs: waHome/MediaDetail/MediaResults/Player/Lyrics/Queue/Playlist/Library/
                        DownloadedSongs/DownloadedAlbums/DeezerLogin/Profile/Settings/Theme/Logs + waList
Models/                 waSong/waAlbum/waArtist/waPlaylist/waMediaItem/waDownload/waPreferences
Services/               waAPIClient/waDeezerClient/waLastFMClient/waRPCClient/waDownloadManager/
                        waAudioPlayer (+Queue/+Engine)/waImageLoader/waKeychainStore/waTheme/waDebugLog
Audio/waAudioEngine.h   AVPlayer wrapper (playNext/Previous, remoteControlReceivedWithEvent)
Views/                  waPlaceholder/waArtworkCell/waMediaInfoCell/waHomeCardCell/waHomeSectionView/
                        waSegmentedControl/waAction/waActions/waMediaActionSheet/waEmptyView
Resources/Info.plist:40 CFBundleIdentifier com.bytebox.wave, 5 Executable wave, 12-16 AppIcons 18 PNGs
control:1-8             Package com.bytebox.wave 0.1.0 iphoneos-arm Utilities (bump incremental `0.1.0-N+debug`)
Makefile:1              TARGET := iphone:clang:7.1:6.1 (SDK 7.1 + deployment 6.1, ARCHS armv7 armv7s)
Makefile:14             APPLICATION_NAME=wave, 40+ FILES, FRAMEWORKS=UIKit CoreGraphics CoreFoundation
                        CoreMedia AVFoundation AudioToolbox MediaPlayer Security ImageIO QuartzCore, CFLAGS=-fobjc-arc
```

> Si ves `waRootViewController` en docs viejos, está obsoleto — fue reemplazado por `waHomeViewController` + `waLibraryViewController`. Cita siempre `path:line` real.

## 2. Entorno — dónde está todo

```
THEOS = /home/main/theos
SDK   = /home/main/theos/sdks/iPhoneOS7.1.sdk  (1.2G, CanonicalName iphoneos7.1, Deployment 7.1, Max 7.1.99) — build SDK
        deployment: 6.1 (compatible iOS 6.1+ via TARGET 7.1:6.1)
        fallback SDK 6.1: /home/main/theos/sdks/iPhoneOS6.1.sdk (515M) — conservado
        source: https://github.com/EachAndOther/Legacy-iOS-SDKs/tree/master/iPhoneOS6.1.sdk
        verificado: du -sh + cat SDKSettings.plist + ls Frameworks

Project = /home/main/projects/wave
Docs    = /home/main/projects/wave/docs/  (fuente de verdad — consultar siempre)
Book    = /home/main/programming-ios6/    (41 capítulos Programming iOS 6 Matt Neuburg - 31k líneas - ver README.md)
Convert = /home/main/convert_iosbook.py   (generador 2026-08-28, no editar Book a mano)
```

Si `ls /home/main/theos/sdks/` está vacío, el SDK se perdió — ver `docs/sdk-reference.md §4` para reinstalar.

## 3. Docs — lee antes de codificar

| Doc | Cuándo leerlo |
|-----|---------------|
| `docs/README.md` | Mapa rápido y snapshot del proyecto |
| `docs/ios6-interface-guide.md` | Diseñar UI — lenguaje skeuomórfico, texturas, gloss, sombras, qué NO hacer |
| `docs/sdk-reference.md` | Estructura del .sdk, SDKSettings.plist, validación |
| `docs/frameworks.md` | Qué frameworks existen (51 públicos + 213 privados), cómo linkear |
| `docs/uikit-reference.md` | Qué headers UIKit puedes importar (90 headers), novedades iOS 6 vs no-existe-en-6.1 |
| `docs/build-guide.md` | Cómo compilar, empaquetar, instalar, troubleshooting |
| `docs/todo.md` | 36 TODOs ya completados — referencia de contratos estabilizados |
| `docs/lastfm-credentials.md` | Credenciales Last.fm (no commitear) |

### 3.1 Biblioteca Programming iOS 6 (externa) — 41 capítulos

> Libro completo *Programming iOS 6* (Matt Neuburg) desglosado en markdown en `/home/main/programming-ios6/`. No está copiado en `docs/` para no inflar el repo. Índice: `/home/main/programming-ios6/README.md`. Generado por `convert_iosbook.py` el 2026-08-28.

| Tema | Archivo a leer en `Book` | Relevancia para wave |
|------|--------------------------|----------------------|
| **C / ObjC base** | `01-just-enough-c.md` (1027L), `02-object-based-programming.md` | Sintaxis C, structs, punteros |
| **ObjC objetos/mensajes** | `03-objective-c-objects-and-messages.md` (750L) | `id`, messaging, `nil` |
| **Clases / Instancias** | `04-objective-c-classes.md`, `05-objective-c-instances.md` | `@interface/@implementation`, `init` patterns |
| **Xcode / Proyecto** | `06-anatomy-of-an-xcode-project.md` (691L) | Theos vs Xcode, `TARGET`, `Info.plist` |
| **Nibs** | `07-nib-management.md` | Nib loading y `12:872` memoria; wave usa código, no XIB |
| **Documentación** | `08-documentation.md` | Dash, headers |
| **Ciclo vida proyecto** | `09-life-cycle-of-a-project.md` (1207L) | Debugging, Instruments, Distribution, Icons `09:999` |
| **Cocoa clases** | `10-cocoa-classes.md` (813L) | `NSString/NSArray/NSDictionary/NSDate` |
| **Eventos** | `11-cocoa-events.md` (736L) | Responder chain, `UIEvent`, `remoteControlReceivedWithEvent:` (usa `waAppDelegate.m:54`) |
| **Memoria / ARC** | `12-accessors-and-memory-management.md` (1293L) | **§194 Golden Rules, §220 Qué es ARC, §598 ARC ivars, §669 Retain Cycles `__weak`, §872 Nib memory** |
| **Comunicación** | `13-data-communication.md` | KVO, `NSNotificationCenter` (`waThemeDidChange` en `waAppDelegate.m:106`) |
| **Views** | `14-views.md` (1044L) | **§22 Window, §101 Superview, §171 Frame/Bounds, §314 Transform, §442 Layout, §472 Autoresizing (preferir), §535 Autolayout 1.0 limitado, §953 Layout Events** |
| **Drawing** | `15-drawing.md` (1181L) | `CGContext`, `drawRect:` |
| **Layers** | `16-layers.md` (692L) | `CALayer`, `CAGradientLayer`, sombras skeuomórficas |
| **Animation** | `17-animation.md` (1925L) | `UIView animation`, `CAAnimation` |
| **Touches** | `18-touches.md` (1028L) | `touchesBegan:/UIGestureRecognizer` |
| **View Controllers** | `19-view-controllers.md` (2518L) | **§70 Hierarchy, §138 Creation, §482 Rotation, §778 Presented VC, §1091 TabBar, §1182 Navigation, §1605 Container, §1725 Storyboards (NO usar), §1885 Lifetime Events, §2060 State Restoration** |
| **Scroll** | `20-scroll-views.md` (897L) | `UIScrollView`, zoom, paging |
| **Tablas / Colecciones** | `21-table-views-and-collection-views.md` (2399L) | **§70 Cells, §84 Built-in Styles, §690 Three Big Questions (dataSource), §1005 Refresh, §1235 Selection, §1682 Editing (Delete §1793/Insert §1908), §2133 UICollectionView ¡NUEVO iOS 6!** |
| **Popovers / Split** | `22-popovers-and-split-views.md` | `UIPopoverController`, `UISplitViewController` (iPad) |
| **Text** | `23-text.md` (1276L) | `UITextField/View`, `NSAttributedString` |
| **Web** | `24-web-views.md` | `UIWebView` (no `WKWebView`) |
| **Controls** | `25-controls-and-other-views.md` (1546L) | `UIButton/Slider/Switch/Stepper (¡NUEVO!)` |
| **Modals** | `26-modal-dialogs.md` | **§16 UIAlertView `initWithTitle:message:delegate:...` + `show` + `UIAlertViewDelegate`, §22 UIActionSheet (menu), no `UIAlertController`** |
| **Audio/Video** | `27-audio.md`, `28-video.md` | `AVFoundation`, `AVPlayer` (usa `waAudioEngine`), `MPMoviePlayer` |
| **Music/Photo** | `29-music-library.md`, `30-photo-library-and-image-capture.md` | `MPMediaPicker`, `UIImagePickerController` |
| **Address/Calendar/Mail** | `31-address-book.md`, `32-calendar.md`, `33-mail-and-messages.md` | `ABPeoplePicker`, `EKEventView`, `MFMailComposeViewController` |
| **Maps/Sensors** | `34-maps.md` (733L), `35-sensors.md` | `MKMapView`, `CLLocationManager`, `UIAccelerometer` |
| **Persistencia** | `36-persistent-storage.md` (1172L) | `NSUserDefaults`, `NSCoding`, `CoreData`, `NSFileManager` |
| **Red** | `37-basic-networking.md` | `NSURLConnection` (no `NSURLSession` en 6.1), `waAPIClient` |
| **Threads** | `38-threads.md` | `NSThread`, `GCD`, `NSOperationQueue` (`dispatch_async` en `waAppDelegate.m:102`) |
| **Undo/Epilogue** | `39-undo.md`, `40-epilogue.md` | `NSUndoManager` |

**Regla para el agente (Book):**
1. NO leas los 41 ficheros de golpe. Usa `grep` para buscar y luego `read` solo ese capítulo: `grep -rn "UIAlertView" /home/main/programming-ios6/` → `read /home/main/programming-ios6/26-modal-dialogs.md`.
2. Prioridad: primero verifica que existe en el SDK (`docs/uikit-reference.md` + `ls .../Frameworks`), luego consulta el Book para ver CÓMO se usaba en iOS 6.1.
3. Para dudas generales: `read /home/main/programming-ios6/README.md` y `grep` por keyword. Ver §9 para cheatsheet `grep`.

**Regla de oro (única):**
> Si no existe en `/home/main/theos/sdks/iPhoneOS7.1.sdk/System/Library/Frameworks` con deployment 6.1, no lo uses sin guard runtime. Consulta `docs/uikit-reference.md` antes de `import`.

No disponibles en 6.1 (requieren guard `isModernSystem` si vienes de SDK 7.1): `UIAlertController` (usa `UIAlertView`/`UIActionSheet` per `26-modal-dialogs.md:16`), `WKWebView` (usa `UIWebView`), `UIStackView`, `UIVisualEffectView`, `SF Symbols`, `SwiftUI`, `NSLayoutAnchor` (solo `NSLayoutConstraint` 1.0 limitado per `14-views.md:535`), `NSURLSession` (usa `NSURLConnection`), `UISearchController` (usa `UISearchDisplayController`). APIs iOS 7+ permitidas solo vía `waTheme isModernSystem` + `respondsToSelector`/`NSSelectorFromString` (ej. `setBarTintColor:`, `edgesForExtendedLayout`, `imageWithRenderingMode:`) — ver `Services/waTheme.m:60-96`.

## 4. Workflow del agente

### Antes de editar
1. `read` `docs/uikit-reference.md` y `docs/ios6-interface-guide.md` si tocas UI.
2. `read` el archivo que vas a modificar (`waAppDelegate.m`, `Controllers/*.m`, `Makefile`, `Resources/Info.plist`).
3. Verifica que la clase/framework existe en el SDK: `ls /home/main/theos/sdks/iPhoneOS7.1.sdk/System/Library/Frameworks/<Name>.framework/Headers/` (y deployment 6.1) y `grep -r "Clase" .../Headers/`.
4. Si dudas de API histórica, grepea el Book con §9 cheatsheet y `read` el capítulo de la tabla §3.1 (ej. `grep -rn "UITableViewDataSource" /home/main/programming-ios6/21-table*.md`).
5. Para VCs, lee `19-view-controllers.md §1885 Lifetime Events` (orden: `loadView → viewDidLoad → viewWillAppear → viewDidAppear → viewWillDisappear`). Para tablas, `21-table-views.md §690 Three Big Questions`.

### Al editar
- **ObjC + UIKit** siempre. No introduzcas Swift sin pedirlo.
- **ARC estricto** (`Makefile: wave_CFLAGS=-fobjc-arc`): no uses `retain/release/autorelease` manual. Ver `12-accessors-and-memory-management.md §220, §598`. Usa `__weak` para delegates/blocks y evitar retain cycles (`12:669`):
  ```objc
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf hideTabBarLabelsInView:tabs.tabBar]; }); // cf. waAppDelegate.m:102
  ```
- **Nibs:** no `retain` a `IBOutlet` (`12:872 Nib Loading and Memory Management`). Wave prefiere código sobre XIB/Storyboard (`19:1725` Storyboards existen pero prohibidos aquí).
- Si creas `NuevoVC.h/m`, añádelo a `wave_FILES` en `Makefile:14` (40+ archivos, orden alfabético por carpeta).
- Si necesitas nuevo framework, añádelo a `wave_FRAMEWORKS` en `Makefile` y verifica `docs/frameworks.md` §1 + `ls .../Frameworks`. Privados van a `wave_PRIVATE_FRAMEWORKS`.
- **Layout iOS 6/7 unificado:** prefiere `autoresizingMask` + frames (`14-views.md §472`). Solo usa `NSLayoutConstraint` 1.0 si imprescindible (`14:535` limitado, sin anchors):
  ```objc
  view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  ```
  En iOS 7+ aplica compat: `[waTheme applyLayoutCompatibilityToViewController:vc]` fija `edgesForExtendedLayout=0`, `extendedLayoutIncludesOpaqueBars=NO`, `automaticallyAdjustsScrollViewInsets=NO` (ver `waTheme.m:89`).
- **Barras opacas unificadas:** en iOS 7+ `waTheme` pone `translucent=NO` + `barTintColor=barColor/backgroundColor` + `barStyle=Black` para clonar la opacidad iOS 6. No uses `translucent=YES` salvo efecto buscado.
- **Tab icons iOS 7+:** `UIImageRenderingModeAlwaysOriginal` vía `waTheme isModernSystem` + `respondsToSelector` (ver `waAppDelegate.m:122`) para evitar template tint; `UITabBar`/`UINavigationBar` usan `NSFontAttributeName`/`NSForegroundColorAttributeName` en modern, `UITextAttribute*` en legacy (ver `waTheme.m:143,398`).
- **Estilo iOS 6:** `UINavigationBar` azul glossy `#6d8cb0→#3b5a7f` con gloss 50%, `UITableViewStyleGrouped` con pinstripes, `UIButton` gradiente + gloss, Helvetica Neue, `text-shadow` emboss. Ver `docs/ios6-interface-guide.md §2-3` + `16-layers.md` para `CAGradientLayer`/`shadow*`.
- **Modals iOS 6:** `UIAlertView`/`UIActionSheet` son modales pero el código NO lo es (`26-modal-dialogs.md:83`). Después de `show`, usa delegate:
  ```objc
  UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Title" message:@"msg" delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"OK", nil];
  [alert show];
  // - (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)idx { if(idx==1) ... }
  // UIActionSheet: initWithTitle:delegate:cancelButtonTitle:destructiveButtonTitle:otherButtonTitles: + showInView:
  ```
- APIs iOS 7+ solo con guard `isModernSystem`: si dudas, `grep -r "Clase" /home/main/theos/sdks/iPhoneOS7.1.sdk/.../Headers/` y `docs/uikit-reference.md §4`.
- **Citas:** al referenciar código, usa `path:line` (ej. `waAppDelegate.m:102`, `19-view-controllers.md:1885`).

### Después de editar
1. Verifica sintaxis lógica (no inventes métodos — coteja con `uikit-reference.md` + Book).
2. Compila si es posible:
   ```bash
   export THEOS=/home/main/theos
   cd /home/main/projects/wave && make clean && make -j4
   make package  # genera packages/com.bytebox.wave_0.1.0-N+debug_iphoneos-arm.deb
   ```
   `make -j4` es el límite recomendado; un `-j$(nproc)` puede racear dirs en Theos legacy.
3. Si no puedes compilar, explica qué se verificó manualmente (SDK `ls`, Book `grep`, `uikit-reference.md`) y qué falta.
4. Actualiza `docs/todo.md` si cierras un contrato y bump `control:3 Version` si generas `.deb`.

## 5. Comandos clave

```bash
# Validar SDKs
ls /home/main/theos/sdks/ && du -sh /home/main/theos/sdks/iPhoneOS7.1.sdk && du -sh /home/main/theos/sdks/iPhoneOS6.1.sdk
cat /home/main/theos/sdks/iPhoneOS7.1.sdk/SDKSettings.plist | strings | grep -E "CanonicalName|IPHONEOS_DEPLOYMENT_TARGET|MaximumDeploymentTarget"

# Listar frameworks/headers disponibles (SDK build = 7.1)
ls /home/main/theos/sdks/iPhoneOS7.1.sdk/System/Library/Frameworks | sort
ls /home/main/theos/sdks/iPhoneOS7.1.sdk/System/Library/Frameworks/UIKit.framework/Headers | sort
grep -r "UIRefreshControl" /home/main/theos/sdks/iPhoneOS7.1.sdk/System/Library/Frameworks/UIKit.framework/Headers/ # ¡NUEVO iOS 6!

# Compilar (Theos)
export THEOS=/home/main/theos
cd /home/main/projects/wave && make clean && make -j4 && make package

# Inspeccionar paquete
dpkg-deb -c packages/com.bytebox.wave_*.deb
dpkg-deb -I packages/com.bytebox.wave_*.deb
ls -lh packages/ | tail -5

# Reinstalar SDKs (si se borraron)
rm -rf /tmp/Legacy-iOS-SDKs
git clone --depth 1 --filter=blob:none --sparse https://github.com/EachAndOther/Legacy-iOS-SDKs.git /tmp/Legacy-iOS-SDKs
git -C /tmp/Legacy-iOS-SDKs sparse-checkout set iPhoneOS6.1.sdk iPhoneOS7.1.sdk
cp -a /tmp/Legacy-iOS-SDKs/iPhoneOS6.1.sdk /home/main/theos/sdks/
cp -a /tmp/Legacy-iOS-SDKs/iPhoneOS7.1.sdk /home/main/theos/sdks/
# Reparar symlinks vacíos de usr/lib si quedan a 0 bytes:
# find /home/main/theos/sdks/iPhoneOS7.1.sdk/usr/lib -size 0 -type f -exec ls -l {} \;
```

## 6. Convenciones

- **Idioma**: código y comentarios en inglés; docs y comunicación en español (usuario habla español).
- **Commits**: no commitear sin pedirlo. Si se pide, usar mensajes cortos y `git status/diff` antes.
- **No crear archivos** innecesarios. Preferir editar existentes. Docs van en `docs/`, no en raíz. Nuevos VCs en `Controllers/`, celdas en `Views/`, modelos en `Models/`, red en `Services/`.
- **No asumir**: si el usuario pide algo ambiguo ("interfaz nativa"), preguntar con opciones (ver historial).
- **Verificación**: siempre verificar con ejecución/lectura local (`ls` SDK + `grep` Book), no con suposiciones.
- **Estilo commits/docs**: español para docs, inglés para código. `control` version `0.1.0-N+debug`.

## 7. Estructura esperada al entregar

```
wave/
├── AGENTS.md               ← este archivo
├── docs/                   ← 8 guías (README, ios6-interface, sdk-reference, frameworks,
│                              uikit-reference, build-guide, todo, lastfm-credentials)
├── main.m                  ← UIApplicationMain → waAppDelegate
├── waAppDelegate.h/.m      ← UIWindow + UITabBarController (5 tabs) + Player modal + Themes
├── Controllers/            ← 19 VCs (Home, List, MediaDetail/Results, Player, Library, Downloaded*,
│                              Playlist, Queue, Theme, Settings, Profile, Logs, Lyrics, DeezerLogin)
├── Models/                 ← waSong, waAlbum, waArtist, waPlaylist, waMediaItem, waDownload, waPreferences
├── Services/               ← waAPIClient, waDeezer/LastFM/RPC, waDownloadManager, waAudioPlayer,
│                              waAudioPlayer+Queue/+Engine, waImageLoader, waKeychainStore,
│                              waTheme, waDebugLog, waLibraryMapper, waDownloadStats
├── Audio/                  ← waAudioEngine (AVPlayer wrapper, remoteControl)
├── Views/                  ← waHomeCardCell, waHomeSectionView, waArtworkCell, waMediaInfoCell,
│                              waSearchCells, waSegmentedControl, waAction/Actions,
│                              waMediaActionSheet, waEmptyView, waPlaceholder
├── Resources/              ← Info.plist + AppIcon*.png (18) + Default.png
├── Makefile                ← TARGET iphone:clang:7.1:6.1, ARCHS armv7 armv7s, 40+ FILES, FRAMEWORKS 11, -fobjc-arc
├── control                 ← com.bytebox.wave 0.1.0 iphoneos-arm Utilities
├── deploy.sh               ← deploy a device
└── .gitignore              ← ignora .theos/ y packages/
```

`Makefile:1` está en `7.1:6.1` (SDK 7.1 + deployment 6.1) ver `build-guide.md:19` — `6.1:6.1` legacy conservado en `sdk-reference.md`.

## 8. Checklist rápido para el agente

- [ ] ¿Leí `docs/` relevante (`uikit-reference.md` + `ios6-interface-guide.md` si UI)?
- [ ] ¿El import existe en SDK 7.1 con deployment 6.1? (`ls .../Headers/` + `docs/uikit-reference.md §4`, guard `isModernSystem` si iOS 7+)?
- [ ] ¿Consulté Book con `grep` + `read` solo ese capítulo (§3.1, ver §9)?
- [ ] ¿Evité retain cycle (`__weak` per `12:669`) y `retain/release` manual?
- [ ] ¿Usé `autoresizingMask` no `NSLayoutAnchor` (`14:472` vs `14:535`)?
- [ ] ¿Alerts usan delegate no lógica lineal (`26:83`)?
- [ ] ¿Apliqué compat iOS 7 layout (`edgesForExtendedLayout=0` + `translucent=NO` + `AlwaysOriginal`) si toqué barras/tabs?
- [ ] ¿Actualicé `Makefile:14 wave_FILES` si añadí archivos y `wave_FRAMEWORKS` si framework?
- [ ] ¿Respeté diseño opaco unificado (gloss 50%, 2-3 sombras, luz arriba, sin translucidez)?
- [ ] ¿Probé `make -j4 && make package` o justifiqué por qué no?
- [ ] ¿Usé `path:line` al citar código (`waAppDelegate.m:102`, `19-view-controllers.md:1885`)?
- [ ] ¿Actualicé `docs/todo.md` y `control` version si aplica?

## 9. Consultas rápidas Book (grep cheatsheet)

```bash
# No leas 41 ficheros — grepea y lee solo el hit (ver §3.1 tabla para capítulo)
grep -rn "UIAlertView\|UIActionSheet" /home/main/programming-ios6/26-modal-dialogs.md
grep -rn "UITableViewDataSource\|Three Big Questions" /home/main/programming-ios6/21-table*.md
grep -rn "UICollectionView" /home/main/programming-ios6/21-table*.md          # ¡NUEVO iOS 6!
grep -rn "UIRefreshControl\|UIStepper\|UIActivityViewController" /home/main/programming-ios6/ # nuevos 6.0
grep -rn "autoresizingMask\|Autolayout" /home/main/programming-ios6/14-views.md
grep -rn "retain cycle\|__weak\|__strong" /home/main/programming-ios6/12-accessors*.md
grep -rn "viewDidLoad\|viewWillAppear\|viewDidAppear" /home/main/programming-ios6/19-view-controllers.md
grep -rn "NSNotification\|KVO" /home/main/programming-ios6/13-data-communication.md
grep -rn "AVPlayer\|AVFoundation" /home/main/programming-ios6/27-audio.md
grep -rn "CALayer\|CAGradientLayer" /home/main/programming-ios6/16-layers.md
grep -rn "remoteControlReceivedWithEvent" /home/main/programming-ios6/11-cocoa-events.md
# General: índice rápido
grep -rn "keyword" /home/main/programming-ios6/ | cut -d: -f1,2 | sort -u
read /home/main/programming-ios6/README.md  # mapa 41 caps
```

> Tip: `wc -l /home/main/programming-ios6/*.md` → 31k líneas. Nunca `cat` todo. Usa `grep -n "^##"` para ver secciones del capítulo antes de `read`.
