# Build — wave + Theos + iPhoneOS5.1.sdk

Theos: `/home/main/theos`. SDK: `/home/main/theos/sdks/iPhoneOS5.1.sdk`. Proyecto: `/home/main/projects/wave`.

## Makefile

```
TARGET := iphone:clang:5.1:5.1
ARCHS = armv7
FINALPACKAGE = 1
APPLICATION_NAME = wave
```

Fuentes en cuatro listas: `CORE_FILES`, `SKIN_FILES`, `UI_FILES`, `VENDOR_FILES`, más `Vendor/mbedtls/library/*.c` y `Support/waIOS5Compat.m` (`Makefile:11-33`).

`wave_CFLAGS` lleva `-fobjc-arc` y `-include Support/waIOS5Compat.h`. OrigamiEngine se compila con `-fno-objc-arc` (`Makefile:43`). `waAudioCore.m`, `waCrypto.m` y `FlacDecoder.m` van a `-O3`. mbedTLS a `-O2`. El comentario del Makefile prohíbe NEON: el 3GS no lo tiene.

Un `.m` nuevo que no esté en esas listas no entra al binario.

## Compilar

```
export THEOS=/home/main/theos
cd /home/main/projects/wave
make -j4
make package
```

`-j4` es el tope que usa el propio `Makefile`. Un `-j` más alto puede pisar directorios de Theos viejo.

Salida:

- `.theos/` — ignorado
- `packages/com.sokubit.wave_<version>_iphoneos-arm.deb` — ignorado
- versión del paquete: `control:3`

`make clean && make -j4` cuando cambian flags, frameworks o el estado de Theos no cuadra.

## Instalar

`./deploy.sh` compila e instala. `./deploy.sh --clean` limpia antes. `./deploy.sh --arch armv7` fuerza la arquitectura. El script define `THEOS_DEVICE_IP` y usa `sshpass`. No duplicar la contraseña en otros archivos.

El ejecutable tiene que quedar legible para `mobile`. El script lo corrige después del link: SpringBoard lanza la app como `mobile`, no como root.

Inspeccionar el paquete:

```
dpkg-deb -I packages/com.sokubit.wave_*.deb
dpkg-deb -c packages/com.sokubit.wave_*.deb
```

## Fallos típicos

- `sdks/` vacío o sin `iPhoneOS5.1.sdk`: no hay SDK. Ver `sdk-reference.md`.
- Símbolo de iOS 6 o 7 (`UICollectionView`, `NSURLSession`, `presentViewController:animated:completion:`): el header no está. Ver `uikit-reference.md`.
- Archivo nuevo compilado en el editor y ausente en el binario: falta en `Makefile:11-33`.
- Warning de `UILaunchStoryboardName` o de APIs 6+: no añadirlas para callar el warning. El deployment es 5.1.
