# Build Guide — wave + Theos + iPhoneOS7.1.sdk

> Theos: `/home/main/theos` | SDK build: `/home/main/theos/sdks/iPhoneOS7.1.sdk` (1.2G, `iphoneos7.1`) | Deployment: 6.1 (binario único) | Proyecto: `/home/main/projects/wave`
> Fallback: `iPhoneOS6.1.sdk` (515M) conservado pero no usado para build.

## 1. Makefile actual

El Makefile fuerza SDK 7.1 con deployment 6.1 (compat 6.1–7.x, un solo binario):

```makefile
TARGET := iphone:clang:7.1:6.1
ARCHS = armv7 armv7s
FINALPACKAGE = 1
MAKEFLAGS += -j4
wave_CFLAGS = -fobjc-arc -IVendor ...
```

Ver `SDKSettings.plist: MaximumDeploymentTarget=7.1.99` (build) + deployment 6.1 vía TARGET. `ARCHS` incluye `armv7s` para iPhone 5/5c sin perder `armv7` (iPhone 3GS/4).

## 2. Compilar

```bash
# desde cualquier shell con $THEOS=/home/main/theos
cd /home/main/projects/wave
make clean
make -j4                 # evita races del Theos legacy
make package             # → packages/com.bytebox.wave_0.1.0-N+debug_iphoneos-arm.deb
```

Outputs:
- `.theos/` (ignorado en `.gitignore:1`)
- `packages/` (ignorado en `.gitignore:2`)
- `control` → versión incremental `0.1.0-N+debug` (`control:3`)

## 3. Instalar (jailbreak device)

```bash
# vía Theos (si THEOS_DEVICE_IP configurado)
make package install

# manual
scp packages/com.bytebox.wave_*.deb root@<iphone-ip>:/tmp/
ssh root@<iphone-ip> "dpkg -i /tmp/com.bytebox.wave_*.deb && killall wave; uicache; killall SpringBoard"
```

Requiere `control:1 Package: com.bytebox.wave` y `Architecture: iphoneos-arm`. Probado en `192.168.1.8` (iPhone3,3 iOS 7.1.2) y compatible 6.1.

## 4. Añadir nuevos archivos

```makefile
# Añade el archivo a la lista wave_FILES del Makefile actual.
wave_FILES = ... Views/MyView.m
# Si usas nuevo framework:
wave_FRAMEWORKS = UIKit CoreGraphics MapKit Social
# Si necesitas privado (tweak):
wave_PRIVATE_FRAMEWORKS = ChatKit
```

Luego `make`. Si el framework es iOS 7+ (ej. `SpriteKit`), añade guard `isModernSystem` en runtime.

## 5. Troubleshooting

| Error | Causa | Fix |
|-------|-------|-----|
| `cannot find SDK iphoneos7.1` | SDK no instalado o `THEOS/sdks` vacío | Ver `sdk-reference.md §4`, reinstalar 7.1 |
| `UIKit/UIKit.h not found` | `$THEOS` no exportado | `export THEOS=/home/main/theos` |
| `ld: framework not found` | Framework mal escrito | Verifica `ls /home/main/theos/sdks/iPhoneOS7.1.sdk/System/Library/Frameworks/` (ver `frameworks.md`) |
| `use of undeclared identifier 'UIAlertController'` | Disponible solo iOS 8+ | Usa `UIAlertView` (ver `uikit-reference.md §4`) o guarda con `isModernSystem` si iOS 8+ |
| `Auto Layout errors` | `NSLayoutConstraint` 1.0 limitado | Usa `autoresizingMask` / frames |
| `no such file: WKWebView` | iOS 8+ | Usa `UIWebView` |
| `dylibs a 0 bytes en usr/lib` | Clone sparse defectuoso del SDK 7.1 | Reparar symlinks (ver `sdk-reference.md §4`) |
| `Code signing fails` | `CODE_SIGNING_REQUIRED=YES` en SDK | Theos firma con `ldid` automáticamente; no usar `codesign` de Xcode |
| `bars translucent/content under lap` | iOS 7+ layout extendido | Asegura `waTheme applyLayoutCompatibilityToViewController:` + `translucent=NO` + `barTintColor` (ver `AGENTS.md §4`) |

## 6. Validar el SDK

```bash
ls -ld /home/main/theos/sdks/iPhoneOS7.1.sdk  # → 1.2G
ls -ld /home/main/theos/sdks/iPhoneOS6.1.sdk  # → 515M fallback
cat /home/main/theos/sdks/iPhoneOS7.1.sdk/SDKSettings.plist | strings | grep -E "CanonicalName|IPHONEOS_DEPLOYMENT_TARGET"
ls /home/main/theos/sdks/iPhoneOS7.1.sdk/System/Library/Frameworks/UIKit.framework/Headers/UIKit.h
grep -r "barTintColor" /home/main/theos/sdks/iPhoneOS7.1.sdk/System/Library/Frameworks/UIKit.framework/Headers/UINavigationBar.h | head # solo en 7.1
```

Si falla, reinstalar (ver `sdk-reference.md` §4).

## 7. Estructura esperada de la .app

```
wave.app/
├── wave                (binario armv7/armv7s, ver Info.plist:61 UIRequiredDeviceCapabilities armv7)
├── Info.plist          (generado desde Resources/Info.plist)
├── Resources/AppIcon*.png
└── _CodeSignature/
```

`Resources/Info.plist:5 CFBundleExecutable=wave`, `40 CFBundleIdentifier=com.bytebox.wave`, `105 UIViewControllerBasedStatusBarAppearance=false` (requerido para `applyStatusBarAppearance` en iOS 7).

## 8. Checklist iOS 6–7 unificado

- [ ] `TARGET` = `7.1:6.1` y ambos SDKs presentes
- [ ] Solo imports de `uikit-reference.md`; iOS 7+ tras `isModernSystem` guard
- [ ] Iconos `Resources/AppIcon*.png` presentes
- [ ] `control` version bump al empaquetar
- [ ] Barras opacas (`translucent=NO` + `barTintColor` + `edgesForExtendedLayout=0`) probadas en device 7.1.2
- [ ] Probado en device iOS 6.x y 7.x (o simulado con `isModernSystem` NO/SÍ)
