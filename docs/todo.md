# Wave — estado

Cliente Deezer para iOS 5.1. Paquete `com.bytebox.wave`. Versión de `control:3`. Árbol `Core/`, `Skin/`, `UI/`, `Support/`.

La rama 0.1.x (Controllers, Services, Models, Views, Audio, SDK 6.1/7.1, `waTheme`, `waAPIClient`) está retirada. Esos checklists no son contrato. Si un doc los cita como archivos vivos, está viejo.

## Qué hace el cliente actual

- [x] Cuatro pestañas: Home, Search, Library, Settings. Player modal y mini barra (`UI/waRootController.m:47-75`).
- [x] Sesión por ARL. `waSession` restaura al arrancar y no trata un fallo de red como logout (`UI/waAppDelegate.m:32`).
- [x] Catálogo, búsqueda, charts, radios, géneros, flow, historial, likes y playlists contra el gateway y `api.deezer.com` (`Core/waDZAPI.h`).
- [x] Stream firmado, descifrado BF_CBC_STRIPE y caché seekable. Calidad pedida nunca por encima de la que el ARL concede.
- [x] TLS 1.2 propio (`Core/waTLS`) para hosts que SecureTransport 5.1 no negocia.
- [x] Un `AudioQueue`, gapless o crossfade, EQ de 5 bandas y limitador (`Core/waAudioCore.h`, `Core/waPlayer.h`).
- [x] Descargas, letras locales y carátulas (`Core/waDownloader`, `Core/waLyrics`, `Core/waImageCache`).
- [x] Last.fm: `auth.getMobileSession`, now playing y scrobble al 50% o 4 min, mínimo 30 s (`Core/waLastFM.m`).
- [x] Piel única iOS 5.1 en `Skin/waSkin`. Sin storyboard.

## Abierto en dispositivo

No hay target de tests. Esto se mira en el teléfono, con `Documents/wave.log`.

- [ ] Login con ARL válido, probe FLAC → 320 → 128, y un preferido que no pueda pasar del máximo.
- [ ] Play, pausa, seek y siguiente sobre `deezer://`, incluido un host que solo responde por `waTLS`.
- [ ] Crossfade y EQ a volumen alto, sin clip duro.
- [ ] Descarga, cancelar mientras resuelve, reproducir el archivo offline.
- [ ] Scrobble real en Last.fm con el switch encendido, y silencio con el switch apagado.
- [ ] `wave://album/`, `wave://artist/`, `wave://playlist/`, `wave://tab/` y `wave://play/` abren lo que dicen (`UI/waAppDelegate.m:48`).

## Deriva conocida

`Resources/Info.plist` tiene `CFBundleShortVersionString` `0.3.0`. `control` es la versión del `.deb`. No igualarlas sin pedirlo.
