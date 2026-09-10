# AGENTS-PLANMODE.md — wave · PLAN MODE ONLY

> **Este archivo es la contraparte de `AGENTS.md` para modo planificación.** El agente en este modo **inspecciona, investiga, razona y propone — nunca modifica el proyecto.** Si estás en modo `theos-sdk` (build), lee `AGENTS.md` en su lugar. Fuente de verdad del proyecto: `AGENTS.md` (BUILD) + `docs/`.

---

## 1. Qué es esto

**wave** — `com.bytebox.wave` — Aplicación iOS jailbreak (no tweak) construida con **Theos**. Target legacy **iOS 6.1** (último skeuomórfico antes de iOS 7 flat).

- **Estado actual:** no es boilerplate. App completa Last.fm/Deezer-like con 18 `Controllers`, 7 `Models`, 10 `Services`, `Audio/waAudioEngine`, 10 `Views`. Ver `docs/todo.md` — 36 TODOs de estabilización ya en `[x]`.
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
                        waAudioPlayer/waImageLoader/waKeychainStore/waTheme/waDebugLog
Audio/waAudioEngine.h   AVPlayer wrapper (playNext/Previous, remoteControlReceivedWithEvent)
Views/                  waPlaceholder/waArtworkCell/waMediaInfoCell/waHomeCardCell/waHomeSectionView/
                        waSegmentedControl/waAction/waActions/waMediaActionSheet/waEmptyView
Resources/Info.plist:40 CFBundleIdentifier com.bytebox.wave, 5 Executable wave, 12-16 AppIcons 18 PNGs
control:1-8             Package com.bytebox.wave 0.1.0 iphoneos-arm Utilities (bump a 0.1.0-42+debug)
Makefile:1              TARGET := iphone:clang:6.1:6.1 (lock exacto, no latest:7.0)
Makefile:14             APPLICATION_NAME=wave, 40+ FILES, FRAMEWORKS=UIKit CoreGraphics CoreFoundation
                        CoreMedia AVFoundation AudioToolbox MediaPlayer Security ImageIO QuartzCore, CFLAGS=-fobjc-arc
```

> Si ves `waRootViewController` en docs viejos, está obsoleto — fue reemplazado por `waHomeViewController` + `waLibraryViewController`. Cita siempre `path:line` real.

---

## 2. Regla absoluta — PLAN MODE ONLY

**NO EDITES NADA. NO CREES NADA. NO BORRES NADA.**

Este agente existe únicamente para:

1. Inspeccionar el estado actual del proyecto.
2. Leer código, configuración y documentación.
3. Investigar APIs disponibles en iOS 6.1.
4. Detectar problemas, riesgos y dependencias.
5. Diseñar una solución.
6. Entregar un plan de implementación claro y verificable.

### Está permitido

* `read`, `cat`, `grep`, `find`, `ls`, `tree`, `wc`, `head`, `tail`, `file`
* `git status`, `git diff`, `git log`, `git show`
* inspeccionar headers del SDK (`ls .../Frameworks/.../Headers/`)
* consultar documentación local (`docs/`) y el Book (`/home/main/programming-ios6/`)
* razonar sobre arquitectura, proponer archivos/clases/métodos/responsabilidades
* proponer cambios a `Makefile` (`wave_FILES`/`wave_FRAMEWORKS`) **sin aplicarlos**
* proponer comandos de validación
* señalar código obsoleto, spaghetti, dead code o boilerplate
* citar código existente mediante `path:line`

### Está prohibido

* editar/crear/borrar/mover/renombrar archivos, aplicar patches, `sed -i`, redirecciones `>`/`>>`
* modificar `Makefile`, `Info.plist`, docs, assets, dependencias
* instalar/eliminar dependencias, comandos destructivos
* `git add`/`commit`/`push`/`reset`/`restore`/`checkout` que altere working tree
* generar `.deb` u otros artefactos (`make`, `make clean`, `make package`) — **solo proponerlos en Validación**
* implementar parcial o totalmente la solución

**Una solicitud de plan nunca autoriza cambios.** Aunque la solución parezca trivial, **no la implementes**. Si descubres un arreglo evidente, descríbelo en el plan; no lo apliques.

---

## 3. Entorno — dónde está todo

```
THEOS = /home/main/theos
SDK   = /home/main/theos/sdks/iPhoneOS6.1.sdk  (515M, CanonicalName iphoneos6.1, Deployment 6.1, Max 6.1.99)
        source: https://github.com/EachAndOther/Legacy-iOS-SDKs/tree/master/iPhoneOS6.1.sdk
        verificado: du -sh + cat SDKSettings.plist + ls Frameworks

Project = /home/main/projects/wave
Docs    = /home/main/projects/wave/docs/  (fuente de verdad — consultar siempre)
Book    = /home/main/programming-ios6/    (41 capítulos Programming iOS 6 Matt Neuburg - 31k líneas - ver README.md)
Convert = /home/main/convert_iosbook.py   (generador 2026-08-28, no editar Book a mano)
```

Si `ls /home/main/theos/sdks/` está vacío, el SDK se perdió — ver `docs/sdk-reference.md §4` para reinstalar. **En PLAN MODE no lo reinstales**; explica en el plan cómo restaurarlo.

## 4. Docs — leer antes de planificar

| Doc | Cuándo leerlo |
|-----|---------------|
| `docs/README.md` | Mapa rápido y snapshot del proyecto |
| `docs/ios6-interface-guide.md` | Planes de UI: skeuomorphism, texturas, gloss, sombras, qué NO hacer |
| `docs/sdk-reference.md` | SDK, `SDKSettings.plist`, compatibilidad y validación |
| `docs/frameworks.md` | Frameworks disponibles (51 públicos + 213 privados) y cómo deberían linkearse |
| `docs/uikit-reference.md` | Headers UIKit disponibles (90) y APIs inexistentes en 6.1 |
| `docs/build-guide.md` | Planificar compilación, empaquetado, instalación y troubleshooting |
| `docs/todo.md` | 36 TODOs ya completados — referencia de contratos estabilizados |
| `docs/lastfm-credentials.md` | Credenciales Last.fm (no commitear) |

No propongas implementación basada solo en UIKit moderno. La documentación local y el SDK 6.1 tienen prioridad.

### 4.1 Biblioteca Programming iOS 6 (externa) — 41 capítulos

> Libro completo *Programming iOS 6* (Matt Neuburg) en `/home/main/programming-ios6/`. No está copiado en `docs/` para no inflar el repo. Índice: `/home/main/programming-ios6/README.md`. Generado por `convert_iosbook.py` el 2026-08-28.

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

**Regla para el agente (Book) — workflow de consulta:**
1. NO leas los 41 ficheros de golpe. Usa `grep` → `read` solo ese capítulo: `grep -rn "UIAlertView" /home/main/programming-ios6/` → `read /home/main/programming-ios6/26-modal-dialogs.md`.
2. Prioridad: primero verifica que existe en el SDK (`docs/uikit-reference.md` + `ls .../Frameworks`), luego consulta el Book para ver CÓMO se usaba en iOS 6.1.
3. Para dudas generales: `read /home/main/programming-ios6/README.md` y `grep` por keyword. Ver §10 cheatsheet.

**Prioridad de evidencia al investigar una API:**
```
SDK iOS 6.1 → docs/uikit-reference.md / docs/frameworks.md → Programming iOS 6 → código actual → plan
```

## 5. Regla de oro de compatibilidad

> Si no existe en `/home/main/theos/sdks/iPhoneOS6.1.sdk/System/Library/Frameworks`, no asumas que existe en iOS 6.1. Verifica headers reales antes de incluir una API en el plan.

```bash
grep -R "UIAlertView" /home/main/theos/sdks/iPhoneOS6.1.sdk/System/Library/Frameworks/UIKit.framework/Headers/
```

No disponibles en iOS 6.1: `UIAlertController` → `UIAlertView`/`UIActionSheet` (`26-modal-dialogs.md:16`), `WKWebView` → `UIWebView`, `UIStackView`, `UIVisualEffectView`, SF Symbols, SwiftUI, `NSLayoutAnchor` (solo `NSLayoutConstraint` 1.0 limitado per `14-views.md:535`), `NSURLSession` → `NSURLConnection`, `UISearchController` → `UISearchDisplayController`. No propongas equivalentes modernos porque sean mejores hoy. Objetivo: app auténticamente compatible con **iOS 6.1**.

---

## 6. Workflow obligatorio de planificación

### Fase 1 — Entender la petición
1. Identifica exactamente qué quiere el usuario.
2. Determina qué parte del proyecto afectaría (`Controllers/`, `Views/`, `Services/`, etc.).
3. Detecta ambigüedades importantes.
4. Si una decisión cambia sustancialmente arquitectura o UX y no puede inferirse del repo/docs, pregunta antes de cerrar el plan.
No hagas preguntas por detalles que puedan resolverse inspeccionando el proyecto.

### Fase 2 — Inspeccionar (solo lectura)
Para UI: `docs/uikit-reference.md` → `docs/ios6-interface-guide.md` → controller/view relevante → headers SDK → capítulo Book si hace falta.
Para build: `Makefile` → `docs/build-guide.md` → `docs/frameworks.md` → SDK/framework implicado.
Para arquitectura: archivos afectados → interfaces `.h` → implementaciones `.m` → `Makefile` → docs relevantes.
No inspecciones archivos irrelevantes solo para aparentar exhaustividad.

### Fase 3 — Verificar APIs
Por cada API/clase/framework propuesto: confirma que existe en iOS 6.1, confirma header, confirma framework, consulta el Book si uso histórico no está claro. **No inventes métodos.** Si no puedes verificar algo, indícalo como incertidumbre en el plan.

### Fase 4 — Analizar impacto
Determina: archivos existentes a modificar, archivos nuevos necesarios, frameworks adicionales, cambios en `wave_FILES`/`wave_FRAMEWORKS`, responsabilidades de cada clase, flujo de datos, ciclo de vida (`19:1885` `loadView→viewDidLoad→viewWillAppear→...`), ownership bajo ARC (`12:669` `__weak` para evitar cycles), compatibilidad iOS 6.1, impacto visual, posibles regresiones, cómo se validaría posteriormente. No propongas arquitectura innecesariamente compleja.

### Fase 5 — Diseñar la solución
Favorece: código legible, responsabilidades claras, métodos pequeños, nombres descriptivos, mínima duplicación, APIs nativas iOS 6. Evita: spaghetti/dead code/boilerplate sin propósito, abstracciones prematuras, clases "Manager" genéricas, wrappers innecesarios, helpers de un solo uso, capas que no aporten claridad, archivos diminutos para repartir código. La estructura puede crecer dinámicamente pero debe seguir **ordenada, poco profunda y fácil de navegar**.

---

## 7. Reglas específicas para UI (planificar, no implementar)

Todo plan de interfaz debe respetar iOS 6 skeuomórfico: `UINavigationBar` glossy, `UITableViewStyleGrouped` con pinstripes, fondos/texturas, botones con volumen, gradientes/gloss/highlights/sombras/bordes, Helvetica Neue, controles UIKit nativos. Consultar `docs/ios6-interface-guide.md §2-3` + `16-layers.md` para `CAGradientLayer`.

No introducir estética iOS 7+ por accidente: flat, `UIVisualEffectView` blur, SF Symbols, large titles, safe-area, system spacing moderno, SwiftUI. Si el usuario da diseño personalizado, busca cómo implementarlo con APIs 6.1 sin modernizarlo.

## 8. ARC y Objective-C (planificar con ARC)

Proyecto usa `Makefile: wave_CFLAGS=-fobjc-arc`. Todo plan debe asumir ARC. No propongas `retain`/`release`/`autorelease`/`dealloc` para ivars ARC-managed salvo razón histórica verificada (`12:220`, `12:598`). Usa `__weak` para delegates/blocks (`12:669`):
```objc
__weak typeof(self) weakSelf = self;
dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf hideTabBarLabelsInView:tabs.tabBar]; }); // cf. waAppDelegate.m:102
```
No `retain` a `IBOutlet` (`12:872`). ObjC + UIKit + ARC siempre; Swift solo si petición explícita.

## 9. Makefile — solo planificar cambios

Si la solución necesita `NuevoVC.h/m`, el plan debe indicar `NuevoVC.m` → `wave_FILES` (`Makefile:14`, 40+ archivos, orden por carpeta). Si necesita framework, → `wave_FRAMEWORKS` pero solo tras verificar `docs/frameworks.md` + `ls .../Frameworks`. Privados → `wave_PRIVATE_FRAMEWORKS`. **No modifiques el Makefile en PLAN MODE.**

## 10. Verificación sin mutación

Favorece comandos de solo lectura. **Permitidos:** `git status/diff/log/show`, `ls/find/grep/cat/head/tail/wc/file`, `dpkg-deb -c/-I existing-package.deb`. **Evitar en PLAN MODE:** `make`/`make clean`/`make package` que generen artefactos. En su lugar inclúyelos en Validación del plan:
```bash
export THEOS=/home/main/theos
cd /home/main/projects/wave && make clean && make -j4 && make package
# esperado: packages/com.bytebox.wave_0.1.0-42+debug_iphoneos-arm.deb
```
Explica qué resultado se espera.

### Comandos útiles de investigación

```bash
# Validar SDK
ls /home/main/theos/sdks/ && du -sh /home/main/theos/sdks/iPhoneOS6.1.sdk
cat /home/main/theos/sdks/iPhoneOS6.1.sdk/SDKSettings.plist | grep -E "CanonicalName|IPHONEOS_DEPLOYMENT_TARGET|MaximumDeploymentTarget"

# Frameworks
ls /home/main/theos/sdks/iPhoneOS6.1.sdk/System/Library/Frameworks | sort
ls /home/main/theos/sdks/iPhoneOS6.1.sdk/System/Library/Frameworks/UIKit.framework/Headers | sort

# Buscar API en SDK
grep -R "APIName" /home/main/theos/sdks/iPhoneOS6.1.sdk/System/Library/Frameworks/

# Buscar doc histórica
grep -rn "keyword" /home/main/programming-ios6/

# Estado repo
cd /home/main/projects/wave && git status; git diff; git log --oneline -10
```

## 11. Convenciones

- **Código/comentarios:** inglés. **Docs/comunicación:** español. **Target:** iOS 6.1. **Lenguaje:** ObjC. **UI:** UIKit. **Memory:** ARC. **Build:** Theos.
- **Git PLAN MODE:** no `git add/commit/push/reset/restore/checkout` que altere working tree. Sí `status/diff/log/show`.
- **Archivos:** no crear archivos. Si hace falta uno nuevo, especifica ruta, propósito, responsabilidad, relación con existentes, si va a `wave_FILES`.
- **Ambigüedad:** no asumas decisiones de producto importantes, pero tampoco preguntes lo que puedas resolver leyendo código/docs/SDK/Book. Investiga primero.
- **Citas:** usa `path:line` con líneas verificadas (`waAppDelegate.m:102`, `19-view-controllers.md:1885`, `Makefile:14`). No cites de memoria.

## 12. Estructura esperada

```
wave/
├── AGENTS.md               ← modo BUILD (edita/compila)
├── AGENTS-PLANMODE.md      ← este archivo (solo planifica)
├── docs/                   ← 8 guías (README, ios6-interface, sdk-reference, frameworks,
│                              uikit-reference, build-guide, todo, lastfm-credentials)
├── main.m                  ← UIApplicationMain → waAppDelegate
├── waAppDelegate.h/.m      ← UIWindow + UITabBarController (5 tabs) + Player modal + Themes
├── Controllers/            ← 18 VCs (Home, List, MediaDetail/Results, Player, Library, Downloaded*,
│                              Playlist, Queue, Theme, Settings, Profile, Logs, Lyrics, DeezerLogin)
├── Models/                 ← waSong, waAlbum, waArtist, waPlaylist, waMediaItem, waDownload, waPreferences
├── Services/               ← waAPIClient, waDeezer/LastFM/RPC, waDownloadManager, waAudioPlayer,
│                              waImageLoader, waKeychainStore, waTheme, waDebugLog
├── Audio/                  ← waAudioEngine (AVPlayer wrapper, remoteControl)
├── Views/                  ← waHomeCardCell, waHomeSectionView, waArtworkCell, waMediaInfoCell,
│                              waSegmentedControl, waAction/Actions, waMediaActionSheet, waEmptyView, waPlaceholder
├── Resources/              ← Info.plist + AppIcon*.png (18) + Default.png
├── Makefile                ← TARGET iphone:clang:6.1:6.1, 40+ FILES, FRAMEWORKS 11, -fobjc-arc
├── control                 ← com.bytebox.wave 0.1.0 iphoneos-arm Utilities
├── deploy.sh               ← deploy a device
└── .gitignore              ← ignora .theos/ y packages/
```

`AGENTS.md` y `AGENTS-PLANMODE.md` deben mantenerse sincronizados en §1/§3/§4.1/§5. Si `AGENTS.md` cambia, replica el snapshot aquí.

## 13. Formato obligatorio del plan final

El resultado de PLAN MODE debe ser accionable por otro agente (`theos-sdk` BUILD) sin necesidad de volver a diseñar.

### Objetivo
Resumen corto de qué se quiere conseguir.

### Estado actual relevante
Qué existe actualmente y qué partes participan. Usar `path:line`.

### Compatibilidad iOS 6.1
APIs/clases/frameworks verificados. Restricciones históricas. Cita SDK `ls`/`grep` y Book `cap:sección`.

### Cambios propuestos
Para cada archivo `path/al/archivo`: qué cambiar, por qué, responsabilidad resultante, APIs relevantes, interacción con otros. Para nuevos: `NEW — path/al/archivo`.

### Flujo de implementación
Orden preciso de cómo funcionaría la solución. Suficientemente detallado para implementar sin reinterpretar.

### Riesgos / edge cases
Solo riesgos reales y relevantes. No genéricos.

### Validación
Cómo comprobar después: `make -j4 && make package`, ejecución, comportamiento esperado, casos manuales.

### Archivos afectados
```
Modificar:
- ...

Crear:
- ...

Eliminar:
- ...

Frameworks:
- ...

Makefile:
- wave_FILES: ...
- wave_FRAMEWORKS: ...
```

## 14. Calidad y checklist antes de entregar un plan

Un buen plan es específico, verificable, compatible con iOS 6.1, basado en repo real, libre de pasos redundantes. No conviertas 20 líneas en 40 pasos ni reduzcas arquitectura a "crear clase X".

- [ ] ¿Entendí exactamente qué pide el usuario?
- [ ] ¿Inspeccioné archivos realmente relevantes (no todo por aparentar)?
- [ ] ¿Leí `docs/` relevante (`uikit-reference.md`, `ios6-interface-guide.md` si UI)?
- [ ] ¿Verifiqué APIs importantes contra SDK 6.1 (`ls`/`grep` Headers)?
- [ ] ¿Consulté el Book si había dudas históricas (`grep` → `read` cap)?
- [ ] ¿Evité APIs iOS 7+ (`UIAlertController`, `WKWebView`, `UIStackView`, `UIVisualEffectView`, `NSLayoutAnchor`)?
- [ ] ¿El diseño respeta iOS 6 skeuomórfico (`CAGradientLayer`, gloss 50%, `autoresizingMask` `14:472`)?
- [ ] ¿El plan mantiene ObjC + UIKit + ARC (`__weak` per `12:669`)?
- [ ] ¿Identifiqué cambios de `wave_FILES` / `wave_FRAMEWORKS`?
- [ ] ¿Evité spaghetti, dead code y boilerplate innecesario?
- [ ] ¿El plan es suficientemente preciso para que otro agente lo implemente?
- [ ] ¿Incluí estrategia de validación (`make -j4 && make package`)?
- [ ] ¿Usé `path:line` para código existente?
- [ ] ¿Evité modificar/crear/borrar cualquier archivo y comandos que muten working tree?

> **PLAN MODE significa PLAN MODE. Read. Verify. Reason. Plan. Never edit.**
