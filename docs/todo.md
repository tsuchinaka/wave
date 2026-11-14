# Wave — TODO de estabilización

## Temas y UI
- [x] Mostrar `Liked Songs` como un único acceso a la lista, sin repetirlo por cada canción.
- [x] Reordenar Library en accesos de canciones/descargas y estantes horizontales para álbumes, artistas y playlists.
- [x] Hacer que los estantes horizontales de Library usen todo el ancho disponible de pantalla.

- [x] Aplicar el color claro del tema al fondo de ventanas, tablas, estados vacíos y vistas de contenido.
- [x] Aplicar el color principal del tema a navigation bars, tab bars, toolbars, botones, switches y action sheets.
- [x] Hacer que cambiar el tema persista y actualice inmediatamente toda la ventana.
- [x] Reparar el selector para usar índices estables y mostrar el tema actualmente seleccionado.
- [x] Eliminar fondos nativos `groupTableViewBackgroundColor` de las pantallas de Wave.
- [x] Centralizar métricas, tipografías, colores y estilos glossy de controles compartidos en `waTheme`.
- [x] Unificar estados vacíos de canciones y álbumes descargados con `waEmptyView`, incluyendo actualización al cambiar tema.
- [x] Hacer que cards y celdas de catálogo repinten sus colores y controles al cambiar tema.

## Flujo de contenido

- [x] Normalizar respuestas del endpoint Home aunque el API entregue aliases o secciones anidadas.
- [x] Añadir estado de carga, error, reintento y pull-to-refresh en Home.
- [x] Reparar la cancelación de todos los `UIActionSheet` y conservar su ciclo de vida mientras están visibles.
- [x] Convertir el detalle en una vista funcional para canciones, álbumes y artistas.
- [x] Cargar canciones de álbum/artista desde el catálogo y abrirlas para reproducción.

## Playback

- [x] Conectar la selección de canciones con el reproductor compartido.
- [x] Reproducir streams remotos con decodificación Origami/PCM propia, incluyendo pausa, reanudación, seek y fin de cola.
- [x] Eliminar `AVPlayer` y mezclar pistas PCM para permitir crossfade también en FLAC y formatos lossless.
- [x] Consumir MP3 y FLAC mediante piping HTTP progresivo, iniciando PCM con el primer buffer disponible sin precalentar la canción completa.
- [x] Mostrar en Player el bitrate codificado real detectado por Origami, incluyendo el promedio de formatos lossless.
- [x] Actualizar metadata de Now Playing y la pantalla Player en tiempo real.
- [x] Hacer Player adaptable a retrato, paisaje y pantallas pequeñas mediante layout calculado y scroll.

## Cuenta

- [x] Usar el token de Keychain como fuente de verdad de autenticación.
- [x] Conectar Profile con `/api/v1/auth/me`, likes y playlists.
- [x] Mostrar estado anónimo, error de sesión y datos reales del usuario.
- [x] Añadir login/logout funcionales desde Profile y Settings.
- [x] Mantener sincronizado el estado like/unlike de playlists entre detalle, búsqueda y Library.

## Calidad

- [x] Formatear el código modificado para que los estados y contratos sean legibles.
- [x] Separar playlists de Deezer, mapper/stats de Library, celdas y datos de Search, y cola/eventos de Audio en módulos dedicados.
- [x] Integrar StreamCache con el límite de caché de Settings (256 MB), limpieza LRU y borrado manual.
- [x] Alinear Settings con las capacidades reales de la cuenta Deezer y separar opciones operativas por dominio.
- [x] Validar el ARL al arrancar: credenciales rechazadas se limpian y los fallos de red transitorios no expulsan al usuario.
- [x] Centralizar en `waAPIClient` el estado y logout que consumen Settings/Profile, sin fallback silencioso al bridge LAN antiguo.
- [x] Mantener controles planos en iOS 7+ y conservar el fallback glossy únicamente para iOS 6.1.
- [x] Compilar con el SDK iPhoneOS7.1 y deployment iOS 6.1, generando el paquete `.deb`.
- [x] Deprecar iOS 6: deployment mínimo 7.0 y migrar únicamente las descargas de audio a `NSURLSessionDataTask`; streaming permanece sin cambios.

## Auditoría iOS 6.1 — 2026-09-04

Implementado; validación funcional en dispositivo pendiente:

Verificación local: `make clean && make -j4` correcto para armv7/armv7s; paquete `0.1.1-45+debug` inspeccionado con `dpkg-deb`. Comprobaciones estáticas de guards, snapshot y política de solicitudes correctas; no equivalen a tests de runtime. Persisten warnings del target legacy y símbolos de depuración de FLAC.

- [x] Preparar buffers tras seek en pausa y serializar pausa/reanudación con stop/seek; descartar completions de seeks anteriores.
- [x] Invalidar preparación asíncrona de crossfade al cancelar, cambiar canción o insertar Play Next; verificar identidad y generación del destino.
- [x] Capturar snapshot de cola/posición en hilo principal y escribirlo en cola serial sin consultar estado vivo desde background.
- [x] Limitar carátulas a dos conexiones activas y 8 MB por respuesta; cancelar conexiones al limpiar caché. Decodificación sigue fuera de main.
- [x] Aplicar preferencia de datos móviles a solicitudes Deezer mediante constructor compartido.
- [x] Añadir nombres VoiceOver a pestañas y Show more; evitar invalidaciones de layout sin cambio de tamaño de celda.

### Regresión pendiente en dispositivo (MP3 y FLAC)

- [ ] Pausar → seek → esperar → reanudar: sonido y posición correctos.
- [ ] Seek → reanudar antes de terminar; seek → pausa; varios seeks rápidos: respetar última intención.
- [ ] Preparar crossfade A→B → Play Next C: debe sonar C y coincidir título/cola.
- [ ] Seek, pausa o cambio manual durante preparación de crossfade: no reaparece transición cancelada.
- [ ] Cambiar A en 120 s a B remoto; cerrar durante carga y restaurar: B no hereda 120 s.
- [ ] Scroll rápido con caché fría: comprobar máximo de dos conexiones de carátulas; limpiar caché durante descarga y volver a cargar.
- [ ] Respuesta de imagen >8 MB, HTTP 404 y corte de red: placeholder sin bloquear siguientes solicitudes.
- [ ] Desactivar datos móviles y apagar Wi-Fi: búsqueda/catálogo Deezer no usan red celular. Peticiones ya iniciadas no se cancelan por cambiar preferencia.
- [ ] VoiceOver identifica cinco pestañas y Show more; rotación conserva layout de estantes.
- [ ] Auriculares, interrupción telefónica, bloqueo y reproducción en background sin regresiones.

Pendiente adicional: cancelación individual de carátulas fuera de pantalla y pruebas automatizadas con runtime iOS. El límite de conexiones no sustituye mediciones de RAM/CPU en dispositivo.

## Rendimiento iPhone 4/4s/5 — 2026-09-05

Implementado; validación en dispositivo pendiente:

- [x] Compilar en schema release con `FINALPACKAGE = 1` en el Makefile: esta variante de Theos fuerza DEBUG (`-O0` sin strip) cuando falta (`common.mk:100-102` y `206-219`); el binario del `.deb` previo se confirmó construido en `.theos/obj/debug`.
- [x] Eliminar el teardown/rebuild de todas las secciones de Home (con sus `UICollectionView`) por cada evento de descarga (~4x/seg con descargas activas): las celdas del Home no muestran estado de descarga, así que el refresh era trabajo puro desperdiciado que además reseteaba el scroll de los carruseles.
- [x] Mover la caché del payload de Home de `NSUserDefaults` a archivo en `Caches/`, leído y escrito en cola serial en background (antes se serializaba el payload completo en el main thread en cada carga) y purgar la clave legado.
- [x] Romper el retain cycle del bloque `selection:` en los estantes de artista del detalle (`waMediaDetailViewController`): el VC completo quedaba vivo para siempre.
- [x] Cachear `UISwitch`/`UIStepper` por fila en Settings y el chevron-label en `waSettingsCell`/`waArtworkCell` (antes se alocaban en cada configure/reciclaje).
- [x] EQ: aplicar ganancias al motor en vivo durante el arrastre y persistir a preferencias solo al soltar (`TouchUpInside/UpOutside/Cancel`), igual para el compresor.
- [x] Descargas: exponer progreso agregado por bytes, conservar el total de pistas completadas en lotes de álbum/playlist, coalescer las actualizaciones de Library y mantener el límite de conexiones sin sobrepromocionar una descarga mientras resuelve su URL.
- [x] Library: mostrar `nombre del álbum/playlist` sobre una única barra 0–100% en la barra de navegación; las canciones sueltas mantienen el título genérico.
- [x] Search: un solo pase de layout (re-estilo del searchBar solo cuando cambia el tamaño de la vista), sin re-estilo del campo en cada tecla, anchos de filter pills medidos una vez, y like/notificación de like refresca solo las celdas visibles vía `refreshLikeState` en lugar de `reloadData` completo (conserva el scroll de los carruseles).
- [x] Ajustar la respuesta real del EQ (verificada con arnés de medición en host): lowshelf de bajos 60 Hz/S=1 → 90 Hz/S=1.8 (el refuerzo antes se diluía antes de llegar a los bajos musicales), y el trim anti-clip compensa solo la mitad del peak (la compensación completa hacía que "Bass Booster" (+7 dB) midiera -1 dB a 40 Hz). Corregido también el alpha RBJ de las bandas peaking (Q=1 restaurado). Respuestas -O0 y -Os bit a bit idénticas; el compresor (limitador) sigue atrapando los picos residuales.
- [x] Diagnosticado "FLAC no reproduce por timeout" con log a archivo (Documents/wave.log, nuevo mirror de waDebugLog): no hay timeout ni fallo; era la cap de streaming a MP3-320 en dispositivos ≤512 MB (waAudioPlayer). Ajuste posterior: la cap eliminada por completo — la calidad Lossless es elección del usuario en todos los dispositivos (A4 incluido); el watchdog de stall (20 s) es la única red de seguridad.
- [x] Eficiencia de decode (plan 3→2→4→1): backoff del pump de `waPCMTrack` cuando el ring está lleno (de ~100 wakeups/s a ~16 en estado estable); `FlacDecoder` emite little-endian nativo sin `OSSwap` (FLAC 16-bit/44.1k/stereo pasa por el fast-path de `waPCMTrack` sin capa `AudioConverter`); flags per-file `-O3 -mfpu=neon` en EQ/compresor/PCMTrack/PCMixer/FlacDecoder (EQ validado numéricamente idéntico a -Os con el arnés de respuesta); libFLAC recompilada 1.3.0→1.4.3 a -O3 con nuestro toolchain (framework reemplazado con backup en `FLAC.framework.bak-1.3.0`; upstream no tiene kernels NEON para ARMv7, solo ARM64 — pendiente kernel propio si hiciera falta más ganancia).
- [x] Relevancia de búsqueda Deezer (diagnosticado con la API real): `/search/album?q=adele 19` nunca devuelve el álbum "19" (índice de Deezer lo omite bajo cualquier variante, incluso strict/limit=100) y `/search/artist` pone a "Adèle Castillon" sobre la Adele real. Fixes: artistas ahora se re-ranquean con el scorer cliente (match de nombre + tie-break por fans, el famoso gana); para queries multi-token se resuelve el mejor artista y se fusiona su discografía oficial (`/artist/{id}/albums`, nuevo endpoint en waDeezerClient/waAPIClient) filtrada por los tokens de cola — "adele 19" ahora muestra el álbum "19" primero. Songs/álbumes ya re-ranqueados siguen intactos.
- [x] Search completo: el cliente conserva `items/total/next` de Deezer, la pantalla pagina con el índice del `next` sin duplicados, albums/artists tienen Load more, All tiene See all, Search comparte la cola de reproducción con resultados/Home y el cache guarda objetos compactos con límite de coste; versión 0.1.20 desplegada.
- [x] Search compacto: placeholder "Search Deezer", filtros y títulos con menor altura, y carruseles de Search ajustados al tamaño real de sus tarjetas; versión 0.1.23 desplegada.
- [x] Crossfade "muerto" en 4s/5: no era regresión sino una cap de diseño (≤512 MB → crossfade forzado a 0, waAudioPlayer). Eliminada junto con la cap de calidad: crossfade es decisión del usuario en todos los dispositivos, con 45 s de antelación para preparar el decoder siguiente y el watchdog de stall como red de seguridad.
- [x] Scrobbles a Last.fm "muertos": Now Playing funcionaba (HTTP 200) pero cero scrobbles en el log — la key `wa.lastfm.scrobbling` no existía en este install (boolForKey = NO) y el login no la activaba. Fix: login exitoso habilita scrobbling automáticamente (el switch de Settings sigue mandando después). Diagnóstico vía wave.log + plist del dispositivo.
- [x] Last.fm en el cliente iOS 5.1: `Core/waLastFM` con `auth.getMobileSession`, `track.updateNowPlaying` y `track.scrobble` (50% o 4 min, mínimo 30s). Login enciende scrobbling. Botón del logo en Now Playing rojo si activo, gris si no. Fila Account + switch. `0.3.46`.

## Serverless Deezer directo (MP3-only) — 2026-09-06

Implementado; validación en dispositivo pendiente (riesgo TLS asumido):

- [x] Nuevo `Services/waDeezerStreamClient` (port de `Minuga-RC/deezer-tui/src/api.rs`): `getUserData` (SESSION_ID + license_token + checkForm) → `pageTrack` (TRACK_TOKEN) → `media.deezer.com/v1/get_url` (BF_CBC_STRIPE, MP3_128/MP3_320) → URL `deezer://` para el engine. Reintento 320→128 por track. Metadata vía `api.deezer.com/track/:id` público, sin bloquear playback.
- [x] Nuevo `Services/waDeezerBlowfish` (port de `crypto.rs`, key `md5_hex(trackID) XOR g4el58wc0zvf9na1`, cada 3er chunk 2048B, IV 0..7) sobre `CommonCrypto` (`kCCAlgorithmBlowfish` existe en 6.1, sin port de tablas). Vector `3135556 → 6c6c666b39662c37652575603c643439` verificado en host.
- [x] `HTTPSource` descifra en vuelo a fichero caché y registra esquema `deezer` en `ORGMPluginManager`; `waDownloadManager` descifra antes de escribir el `.mp3`.
- [x] Player/prefetch/fallback resuelven directo primero con fallback al backend (`/stream`) si Deezer rechaza. `trackDetails` backend ya no bloquea el inicio.
- [x] Lossless sacrificado: `deezerQuality/downloadQuality` clamp a 0/1 (`waPreferences`), Settings solo 128/320, descargas siempre `.mp3`. Paquete `0.1.3`.

### Regresión pendiente en dispositivo (serverless)- [ ] Play MP3_320 directo con ARL válido; forzar fallo 320 y comprobar reintento 128.
- [ ] Lossless directo (nuevo 0.1.4): elegir Lossless en Settings, comprobar etiqueta `FLAC • N kbps avg`, fallback FLAC→320→128 por track sin cortar, y descarga `.flac` que suena offline. En A4/512MB vigilar stalls (el watchdog degrada solo).
- [ ] Seek/pausa/crossfade sobre stream descifrado; `deezer://` no hereda posición entre tracks.
- [ ] Descarga completa MP3 y reproduce offline; cancelar durante `resolving` no deja conexión fantasma.
- [ ] Sin backend levantado: playback, search, likes y playlists funcionan; Genius/lyrics degradan sin colgar.
- [ ] Si TLS 6.1 falla contra `deezer.com/media/cdn`, documentar y valorar proxy mínimo.

## EQ bass refactor (safe, solo coefs) — 2026-09-06

Diagnosticado con arnés en host (`/tmp/eqtest`): el shelf 90Hz/S=1.8 apilaba el boost bajo 100Hz (inaudible en drivers pequeños) y el trim de medio pico dejaba suelo -3.5dB — Bass Booster neto +4dB subs sobre -3.5dB: delgado y plano.

- [x] Lowshelf 90Hz/S=1.8 → 110Hz/S=0.9 (energía 60-300Hz, sin hoyo low-mid); trim medio pico → cuarto de pico; eliminado `alpha` sombreado (idéntico numérico). Render intacto.
- [x] Verificado en arnés: Bass Booster neto +5.2@30/+4.7@60/+3.5@90/+2.1@130-250, suelo -1.75; extremos ±12dB acotados sin NaN; `-O0/-O3/-Os` bit a bit idénticos. Paquete `0.1.5`.
- [ ] Oído en dispositivo (auriculares + altavoz): Bass Booster pega sin embarrar; Rock/Pop sin cambios raros.

## EQ auto-gain + limiter (anti-quemado) — 2026-09-06

El trim de cuarto de pico subestimaba boosts apilados: Bass Booster quemaba (+5dB sobre full-scale, limiter OFF por defecto → clip duro).

- [x] `waEQSetGains` evalúa la respuesta compuesta real (64 puntos log 20Hz-20kHz, hilo UI) y trim = -(pico + 0.5dB). Tilt V4 intacto, techo matemático. Render sin tocar.
- [x] Limiter por defecto ON suave (strength 10 = threshold -4.5dB, solo caza transitorios); Bass Booster +7/+4 → +6/+3.
- [x] Verificado en arnés: tilt ~5.8dB preservado, techo ≤ -0.5dBFS en BB/Rock/ALL+12/Flat, extremos acotados sin NaN, `-O0/-O3/-Os` idénticos. Paquete `0.1.6`.
- [ ] Oído en dispositivo a volumen alto: cero distorsión; subir volumen compensa el nivel absoluto menor.

## Settings sin backend — 2026-09-06

- [x] Eliminadas filas API URL y API Port de Connections (solo UI; `waPreferences.apiURL/apiPort` y `waAPIClient.baseURL/port` quedan para el fallback). Fuera `editConnectionValue`, `embeddedPortInAPIURL`, `updateAPIClient` y tags 100/101. Ping y Bridge intactos. Paquete `0.1.7`.
