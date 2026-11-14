# Last.fm

Aplicación: Wave App. Registrada a nombre de tsuchinaka.

El cliente es `Core/waLastFM`. Endpoint `https://ws.audioscrobbler.com/2.0/`. Login con `auth.getMobileSession` (usuario y contraseña, sin callback). Now playing con `track.updateNowPlaying`. Scrobble con `track.scrobble` cuando la pista pasa el 50% o 4 minutos, y no si dura menos de 30 s o la posición no llega a 30 s (`Core/waLastFM.m`).

La API key y el shared secret identifican a la aplicación. Cada usuario recibe su propia session key. Esas dos constantes están en `Core/waLastFM.m`. No copiarlas a otro archivo, ni pegarlas en un issue, ni meterlas en el README.

No publicar este archivo fuera del repo. Ya está en el árbol; no hace falta repetir los valores aquí.
