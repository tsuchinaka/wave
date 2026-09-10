# SDK Reference — iPhoneOS7.1.sdk (+ fallback 6.1)

> Build SDK: `/home/main/theos/sdks/iPhoneOS7.1.sdk` (1.2G, `iphoneos7.1`, Deployment 7.1, Max 7.1.99) con `TARGET := iphone:clang:7.1:6.1` (deployment 6.1, binario único 6.1–7.x). Fallback conservado: `/home/main/theos/sdks/iPhoneOS6.1.sdk` (515M).
> Verificado con `du -sh` + `cat SDKSettings.plist | strings` + `ls Frameworks`. Fuente: `EachAndOther/Legacy-iOS-SDKs`.

## 1. SDKSettings.plist (7.1 = build)

` /home/main/theos/sdks/iPhoneOS7.1.sdk/SDKSettings.plist`

```
CanonicalName: iphoneos7.1
Version: 7.1
DisplayName: iOS 7.1
MaximumDeploymentTarget: 7.1.99
IPHONEOS_DEPLOYMENT_TARGET: 7.1 (default) → proyecto fuerza 6.1 vía TARGET
PLATFORM_NAME: iphoneos
SUPPORTED_DEVICE_FAMILIES: 1 (iPhone), 2 (iPad)
ARCHS: armv7 armv7s (arm64 aún no default en 7.1)
CODE_SIGNING_REQUIRED: YES
```

Fallback 6.1 (solo referencia):
```
CanonicalName: iphoneos6.1, Version: 6.1, MaximumDeploymentTarget: 6.1.99, IPHONEOS_DEPLOYMENT_TARGET: 6.1
```

## 2. Estructura de directorios

```
iPhoneOS7.1.sdk/
├── SDKSettings.plist
├── Entitlements.plist
├── ResourceRules.plist
├── Developer/
└── System/
│   └── Library/
│       ├── Frameworks/           → 51+ públicos (UIKit, AVFoundation, etc.)
│       ├── PrivateFrameworks/    → 200+ privados
│       └── ...
└── usr/
    ├── include/                  → headers C/ObjC (objc/runtime.h, Availability.h, dispatch/, etc.)
    ├── lib/                      → dylibs (reparar symlinks si aparecen 0 bytes: ver §4)
    └── ...

iPhoneOS6.1.sdk/ (fallback, misma estructura, sin APIs 7+ como barTintColor/edgesForExtendedLayout)
```

## 3. Directorio usr/include (extracto)

`ls iPhoneOS7.1.sdk/usr/include | head`

```
aio.h, alloca.h, architecture/, arm/, arpa/, asl.h, assert.h, Availability.h,
AvailabilityInternal.h, AvailabilityMacros.h, Block.h, bsm/, bzlib.h, c++/,
CommonCrypto/, complex.h, dispatch/, dlfcn.h, dns.h, objc/{objc.h,runtime.h,message.h}, ...
```

→ Necesario para `wave_CFLAGS = -fobjc-arc`.

## 4. Verificación

```bash
ls /home/main/theos/sdks/                     # → iPhoneOS7.1.sdk iPhoneOS6.1.sdk
du -sh /home/main/theos/sdks/iPhoneOS7.1.sdk  # → 1.2G
du -sh /home/main/theos/sdks/iPhoneOS6.1.sdk  # → 515M
cat /home/main/theos/sdks/iPhoneOS7.1.sdk/SDKSettings.plist | strings | grep CanonicalName # → iphoneos7.1
ls System/Library/Frameworks | wc -w          # → 51+
ls System/Library/PrivateFrameworks | wc -w   # → 200+
# Si usr/lib tiene dylibs a 0 bytes (clon sparse roto):
find /home/main/theos/sdks/iPhoneOS7.1.sdk/usr/lib -size 0 -type f | head
```

Si falta, reinstalar:

```bash
rm -rf /tmp/Legacy-iOS-SDKs
git clone --depth 1 --filter=blob:none --sparse https://github.com/EachAndOther/Legacy-iOS-SDKs.git /tmp/Legacy-iOS-SDKs
git -C /tmp/Legacy-iOS-SDKs sparse-checkout set iPhoneOS6.1.sdk iPhoneOS7.1.sdk
cp -a /tmp/Legacy-iOS-SDKs/iPhoneOS6.1.sdk /home/main/theos/sdks/
cp -a /tmp/Legacy-iOS-SDKs/iPhoneOS7.1.sdk /home/main/theos/sdks/
# Si los dylibs siguen a 0, re-crear symlinks: ver script de reparación en historial
```

## 5. Relación con el proyecto wave

- `Makefile:1` `TARGET := iphone:clang:7.1:6.1` + `ARCHS = armv7 armv7s` → compila contra 7.1 pero corre en 6.1+.
- `wave_FRAMEWORKS = UIKit CoreGraphics ...` → paths:
  - `System/Library/Frameworks/UIKit.framework/Headers/UIKit.h` (7.1 incluye `barTintColor`, `edgesForExtendedLayout`, `NSShadow` etc.)
- Compat: todo lo iOS 7+ se guarda con `+[waTheme isModernSystem]` + `respondsToSelector:NSSelectorFromString(@"setBarTintColor:")` + KVC (ver `waTheme.m:60-96`, `waAppDelegate.m:122`). En iOS 6 ese código nunca corre.
- No añadir `SDK` manualmente a `CFLAGS`; Theos lo resuelve vía `$THEOS/sdks/`.
- UI unificada: `translucent=NO` + `barTintColor` + `UIRectEdgeNone` + `automaticallyAdjustsScrollViewInsets=NO` + `AlwaysOriginal` imágenes (ver `AGENTS.md §4`).
